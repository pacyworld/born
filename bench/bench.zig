//! born kqueue hot-path benchmark. Built only by `zig build bench`; it is not
//! part of `test`, `test-bin` or `check-targets`. Method and commands:
//! bench/README.md, driver: bench/run.sh.
//!
//!   born-bench serve  [--seconds S] [--buf N]            server on born (prints its port)
//!   born-bench client --port P --mode echo|storm|bulk    load generator (blocking threads)
//!   born-bench wake   [--seconds S]                      cross-thread wake round trips
//!
//! The server is one born loop: listener, accepted streams, a deadline timer
//! that ends the run. It echoes whatever it reads, draining reads to EAGAIN,
//! attempting writes first and arming write interest only on a short write.
//! The client side is plain blocking sockets, one thread per connection, so the
//! only born code measured is the server loop and the wake path.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const posix = std.posix;

const Listener = born.socket.Listener;
const PlainNb = born.socket.PlainNb;

comptime {
    if (builtin.os.tag == .windows) @compileError("born-bench is POSIX only");
}

const events_per_wait = 256;
const conns_max: usize = 4096;
const samples_max: usize = 1 << 21;
const threads_max: usize = 256;
const listen_backlog: u31 = 4096;
/// bulk and reply mode: bytes per request.
const request_len = 16;
/// Reply mode: the most one write() offers.
const pattern_len = 1 << 20;

// ------------------------------------------------------------------ time ----

fn nowNs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch @panic("clock_gettime failed");
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------- options ----

const Mode = enum { echo, storm, bulk };

const Options = struct {
    cmd: enum { serve, client, wake } = .serve,
    mode: Mode = .echo,
    port: u16 = 0,
    seconds: u32 = 5,
    threads: u32 = 1,
    size: usize = 64,
    /// bulk: reply bytes per 16-byte request. serve: nonzero answers each
    /// request with that many bytes instead of echoing.
    reply: usize = 0,
    buf: usize = 64 * 1024,
    /// serve: SO_ACCEPTFILTER accf_data (the opt-in listener option, once adopted).
    accept_filter: bool = false,
};

fn parseArgs(alloc: std.mem.Allocator) !Options {
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    var o: Options = .{};
    if (argv.len < 2) return usage();
    o.cmd = std.meta.stringToEnum(@TypeOf(o.cmd), argv[1]) orelse return usage();
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (std.mem.eql(u8, k, "--accept-filter")) {
            o.accept_filter = true;
            continue;
        }
        i += 1;
        if (i >= argv.len) return usage();
        const v = argv[i];
        if (std.mem.eql(u8, k, "--mode")) {
            o.mode = std.meta.stringToEnum(Mode, v) orelse return usage();
        } else if (std.mem.eql(u8, k, "--port")) {
            o.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, k, "--seconds")) {
            o.seconds = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--threads")) {
            o.threads = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--size")) {
            o.size = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, k, "--reply")) {
            o.reply = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, k, "--buf")) {
            o.buf = try std.fmt.parseInt(usize, v, 10);
        } else return usage();
    }
    if (o.threads == 0 or o.threads > threads_max or o.size == 0 or o.buf == 0) return usage();
    return o;
}

fn usage() error{Usage} {
    std.debug.print(
        "usage: born-bench serve [--seconds S] [--buf N] [--reply N] [--accept-filter]\n" ++
            "       born-bench client --port P [--mode echo|storm|bulk] [--threads T] [--seconds S] [--size N] [--reply N]\n" ++
            "       born-bench wake [--seconds S]\n",
        .{},
    );
    return error.Usage;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    w.interface.print(fmt, args) catch @panic("stdout write failed");
    w.interface.flush() catch @panic("stdout flush failed");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;
    const opts = parseArgs(alloc) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => return err,
    };
    switch (opts.cmd) {
        .serve => try serve(alloc, opts),
        .client => try client(alloc, opts),
        .wake => try wakeBench(alloc, opts),
    }
}

// ----------------------------------------------------------------- server ----

const Conn = struct {
    stream: PlainNb = .{},
    buf: []u8,
    /// Bytes read and not yet fully written, and how many of them were sent.
    len: usize = 0,
    off: usize = 0,
    /// Reply mode: request bytes not yet a whole request, and reply bytes owed.
    partial: usize = 0,
    owed: usize = 0,
    closing: bool = false,
    next_free: ?*Conn = null,
};

const Stats = struct {
    waits: u64 = 0,
    events: u64 = 0,
    accepts: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    short_writes: u64 = 0,
    closed: u64 = 0,
    /// Streams closed on a socket error (the storm clients reset on close).
    resets: u64 = 0,
    errors: u64 = 0,
};

const Server = struct {
    port: born.EvPort,
    listener: Listener,
    conns: []Conn,
    free: ?*Conn = null,
    closing: [events_per_wait + 1]*Conn = undefined,
    closing_len: usize = 0,
    stats: Stats = .{},
    done: bool = false,
    /// Reply mode (nonzero): reply bytes per request, sent from `pattern`.
    reply: usize = 0,
    pattern: []const u8 = &.{},

    fn serviceListener(self: *Server, ev: born.Event) !void {
        _ = ev;
        while (true) {
            const slot = self.free orelse {
                self.stats.errors += 1;
                return error.OutOfSlots;
            };
            switch (try self.listener.acceptNb(&slot.stream, slot)) {
                .want_accept => return,
                .accepted => {
                    self.free = slot.next_free;
                    slot.* = .{ .stream = slot.stream, .buf = slot.buf };
                    self.port.monitorRead(slot.stream.handle(), slot);
                    self.stats.accepts += 1;
                    // Large replies: a Nagle-held tail waits on a delayed ACK.
                    if (self.reply != 0) {
                        const one: c_int = 1;
                        try posix.setsockopt(slot.stream.handle(), posix.IPPROTO.TCP, TCP_NODELAY, std.mem.asBytes(&one));
                    }
                },
            }
        }
    }

    fn serviceConn(self: *Server, c: *Conn, ev: born.Event) void {
        if (c.closing) return;
        if (ev.err) return self.closeLater(c, true);

        self.pump(c) catch |err| switch (err) {
            error.Closed => self.closeLater(c, false),
            error.SocketError => self.closeLater(c, true),
        };
    }

    /// Flush buffered output, then read to EAGAIN, echoing each read.
    fn pump(self: *Server, c: *Conn) error{ Closed, SocketError }!void {
        while (true) {
            while (c.owed > 0) {
                self.stats.writes += 1;
                const chunk = self.pattern[0..@min(c.owed, self.pattern.len)];
                switch (try c.stream.writeNb(chunk)) {
                    .done => |n| c.owed -= n,
                    .want_write, .want_read => {
                        self.stats.short_writes += 1;
                        self.port.wantWrite(c.stream.handle(), c);
                        return;
                    },
                }
            }
            while (c.off < c.len) {
                self.stats.writes += 1;
                switch (try c.stream.writeNb(c.buf[c.off..c.len])) {
                    .done => |n| c.off += n,
                    .want_write, .want_read => {
                        self.stats.short_writes += 1;
                        self.port.wantWrite(c.stream.handle(), c);
                        return;
                    },
                }
            }
            c.off = 0;
            c.len = 0;
            self.stats.reads += 1;
            switch (try c.stream.readNb(c.buf)) {
                .data => |n| if (self.reply == 0) {
                    c.len = n;
                } else {
                    c.partial += n;
                    c.owed += (c.partial / request_len) * self.reply;
                    c.partial %= request_len;
                },
                .want_read, .want_write => return,
                .eof => return error.Closed,
            }
        }
    }

    fn closeLater(self: *Server, c: *Conn, is_error: bool) void {
        if (is_error) self.stats.resets += 1;
        c.closing = true;
        self.closing[self.closing_len] = c;
        self.closing_len += 1;
    }

    /// End-of-batch reap: purge staged changes before the close.
    fn reap(self: *Server) void {
        for (self.closing[0..self.closing_len]) |c| {
            self.port.purgeFd(c.stream.handle());
            c.stream.deinit();
            c.next_free = self.free;
            self.free = c;
            self.stats.closed += 1;
        }
        self.closing_len = 0;
    }
};

fn serve(alloc: std.mem.Allocator, opts: Options) !void {
    var srv: Server = undefined;
    srv = .{
        .port = try born.EvPort.init(alloc),
        .listener = undefined,
        .conns = try alloc.alloc(Conn, conns_max),
    };
    defer srv.port.deinit();
    defer alloc.free(srv.conns);

    const pool = try alloc.alloc(u8, conns_max * opts.buf);
    defer alloc.free(pool);
    for (srv.conns, 0..) |*c, i| {
        c.* = .{ .buf = pool[i * opts.buf ..][0..opts.buf], .next_free = srv.free };
        srv.free = c;
    }

    srv.reply = opts.reply;
    const pattern = try alloc.alloc(u8, pattern_len);
    defer alloc.free(pattern);
    @memset(pattern, 'r');
    srv.pattern = pattern;

    const addr = try std.net.Address.parseIp4("127.0.0.1", opts.port);
    srv.listener = try Listener.openTcp(alloc, addr, .{ .backlog = listen_backlog });
    defer srv.listener.close();
    try srv.listener.register(&srv.port, &srv.listener);
    var timer_tag: u8 = 0;
    try srv.port.addTimer(1, &timer_tag, opts.seconds * 1000, .once);

    const bound = try srv.listener.localAddress();
    out("port={d}\n", .{bound.getPort()});

    var events: [events_per_wait]born.Event = undefined;
    while (!srv.done) {
        const n = try srv.port.wait(&events, null);
        srv.stats.waits += 1;
        srv.stats.events += n;
        for (events[0..n]) |ev| {
            if (ev.timer) {
                srv.done = true;
            } else if (ev.udata == @as(?*anyopaque, &srv.listener)) {
                try srv.serviceListener(ev);
            } else if (ev.udata) |p| {
                srv.serviceConn(@ptrCast(@alignCast(p)), ev);
            }
        }
        srv.reap();
    }
    const s = srv.stats;
    std.debug.print(
        "server waits={d} events={d} accepts={d} reads={d} writes={d} short_writes={d} closed={d} resets={d} errors={d}\n",
        .{ s.waits, s.events, s.accepts, s.reads, s.writes, s.short_writes, s.closed, s.resets, s.errors },
    );
}

// ----------------------------------------------------------------- client ----

/// <netinet/tcp.h> TCP_NODELAY is 1 on FreeBSD, Linux and macOS.
const TCP_NODELAY: u32 = 1;

const Linger = extern struct { onoff: c_int, linger: c_int };

const Worker = struct {
    addr: std.net.Address,
    mode: Mode,
    size: usize,
    /// Reply bytes per request (equal to `size` when the server echoes).
    reply: usize,
    deadline_ns: u64,
    samples: []u32,
    count: usize = 0,
    dropped: u64 = 0,
    failures: u64 = 0,

    fn record(self: *Worker, start_ns: u64) void {
        const dt = nowNs() - start_ns;
        if (self.count < self.samples.len) {
            self.samples[self.count] = @intCast(@min(dt, std.math.maxInt(u32)));
            self.count += 1;
        } else self.dropped += 1;
    }
};

fn connectTo(addr: std.net.Address, linger0: bool) !posix.socket_t {
    const s = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(s);
    const one: c_int = 1;
    try posix.setsockopt(s, posix.IPPROTO.TCP, TCP_NODELAY, std.mem.asBytes(&one));
    // Storm: reset on close so 16k ephemeral ports are not parked in TIME_WAIT.
    if (linger0) {
        const l: Linger = .{ .onoff = 1, .linger = 0 };
        try posix.setsockopt(s, posix.SOL.SOCKET, posix.SO.LINGER, std.mem.asBytes(&l));
    }
    try posix.connect(s, &addr.any, addr.getOsSockLen());
    return s;
}

fn readExact(s: posix.socket_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.read(s, buf[got..]);
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }
}

fn workerEcho(w: *Worker, alloc: std.mem.Allocator) !void {
    const msg = try alloc.alloc(u8, w.size);
    defer alloc.free(msg);
    const reply = try alloc.alloc(u8, w.reply);
    defer alloc.free(reply);
    @memset(msg, 'x');
    const s = try connectTo(w.addr, false);
    defer posix.close(s);
    while (nowNs() < w.deadline_ns) {
        const t0 = nowNs();
        var sent: usize = 0;
        while (sent < msg.len) sent += try posix.write(s, msg[sent..]);
        try readExact(s, reply);
        w.record(t0);
    }
}

fn workerStorm(w: *Worker) !void {
    var b: [1]u8 = .{'x'};
    while (nowNs() < w.deadline_ns) {
        const t0 = nowNs();
        const s = connectTo(w.addr, true) catch {
            w.failures += 1;
            continue;
        };
        defer posix.close(s);
        _ = try posix.write(s, &b);
        try readExact(s, &b);
        w.record(t0);
    }
}

fn workerMain(w: *Worker, alloc: std.mem.Allocator) void {
    const r = switch (w.mode) {
        .echo, .bulk => workerEcho(w, alloc),
        .storm => workerStorm(w),
    };
    r catch |err| {
        std.debug.print("client worker failed: {s}\n", .{@errorName(err)});
        w.failures += 1;
    };
}

fn client(alloc: std.mem.Allocator, opts: Options) !void {
    if (opts.port == 0) return error.PortRequired;
    const addr = try std.net.Address.parseIp4("127.0.0.1", opts.port);
    const size: usize = switch (opts.mode) {
        .echo => opts.size,
        .storm => 1,
        .bulk => request_len,
    };
    const reply: usize = if (opts.mode == .bulk) (if (opts.reply == 0) 256 * 1024 else opts.reply) else size;
    const workers = try alloc.alloc(Worker, opts.threads);
    defer alloc.free(workers);
    const threads = try alloc.alloc(std.Thread, opts.threads);
    defer alloc.free(threads);
    const start = nowNs();
    const deadline = start + @as(u64, opts.seconds) * std.time.ns_per_s;
    for (workers, threads) |*w, *t| {
        w.* = .{
            .addr = addr,
            .mode = opts.mode,
            .size = size,
            .reply = reply,
            .deadline_ns = deadline,
            .samples = try alloc.alloc(u32, samples_max),
        };
        t.* = try std.Thread.spawn(.{}, workerMain, .{ w, alloc });
    }
    for (threads) |t| t.join();
    const elapsed_ns = nowNs() - start;

    var total: usize = 0;
    var dropped: u64 = 0;
    var failures: u64 = 0;
    for (workers) |w| {
        total += w.count;
        dropped += w.dropped;
        failures += w.failures;
    }
    const all = try alloc.alloc(u32, total);
    defer alloc.free(all);
    var at: usize = 0;
    for (workers) |w| {
        @memcpy(all[at..][0..w.count], w.samples[0..w.count]);
        at += w.count;
        alloc.free(w.samples);
    }
    reportLatency("client", @tagName(opts.mode), all, elapsed_ns, dropped, failures, size);
}

fn reportLatency(role: []const u8, mode: []const u8, samples: []u32, elapsed_ns: u64, dropped: u64, failures: u64, size: usize) void {
    std.mem.sort(u32, samples, {}, std.sort.asc(u32));
    const n = samples.len;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    out(
        "{s} mode={s} size={d} requests={d} seconds={d:.3} rps={d:.0} p50_us={d:.1} p99_us={d:.1} p999_us={d:.1} max_us={d:.1} dropped={d} failures={d}\n",
        .{
            role,                                                mode,                 size,
            n,                                                   secs,                 @as(f64, @floatFromInt(n)) / secs,
            percentileUs(samples, 50.0),                         percentileUs(samples, 99.0), percentileUs(samples, 99.9),
            if (n == 0) 0.0 else @as(f64, @floatFromInt(samples[n - 1])) / 1000.0, dropped, failures,
        },
    );
}

fn percentileUs(sorted: []const u32, pct: f64) f64 {
    if (sorted.len == 0) return 0;
    const rank = @as(f64, @floatFromInt(sorted.len)) * pct / 100.0;
    const idx = @min(sorted.len - 1, @as(usize, @intFromFloat(rank)));
    return @as(f64, @floatFromInt(sorted[idx])) / 1000.0;
}

// ------------------------------------------------------------------- wake ----

/// Two ports on two threads bounce a wake: A wakes B, B's loop wakes A. One
/// round trip is two wake()s, two loop wakeups and no I/O descriptors.
const WakeCtx = struct {
    a: born.EvPort,
    b: born.EvPort,
    rtts: []u32,
    count: usize = 0,
};

fn wakeB(ctx: *WakeCtx, seconds: u32) !void {
    var tag: u8 = 0;
    // Deadline only: the loop ends when A stops bouncing.
    try ctx.b.addTimer(1, &tag, seconds * 1000 + 500, .once);
    var events: [8]born.Event = undefined;
    while (true) {
        const n = try ctx.b.wait(&events, null);
        for (events[0..n]) |ev| {
            if (ev.timer) return;
            if (ev.wake) ctx.a.wake();
        }
    }
}

fn wakeBench(alloc: std.mem.Allocator, opts: Options) !void {
    var ctx: WakeCtx = .{
        .a = try born.EvPort.init(alloc),
        .b = try born.EvPort.init(alloc),
        .rtts = try alloc.alloc(u32, samples_max),
    };
    defer {
        ctx.a.deinit();
        ctx.b.deinit();
        alloc.free(ctx.rtts);
    }
    const t = try std.Thread.spawn(.{}, wakeB, .{ &ctx, opts.seconds });
    const start = nowNs();
    const deadline = start + @as(u64, opts.seconds) * std.time.ns_per_s;
    var t0 = nowNs();
    ctx.b.wake();
    var events: [8]born.Event = undefined;
    var waits: u64 = 0;
    while (true) {
        const n = try ctx.a.wait(&events, null);
        waits += 1;
        const now = nowNs();
        var woke = false;
        for (events[0..n]) |ev| woke = woke or ev.wake;
        if (!woke) continue;
        if (ctx.count < ctx.rtts.len) {
            ctx.rtts[ctx.count] = @intCast(@min(now - t0, std.math.maxInt(u32)));
            ctx.count += 1;
        }
        if (now >= deadline) break;
        t0 = nowNs();
        ctx.b.wake();
    }
    t.join();
    const elapsed = nowNs() - start;
    out("a_waits={d}\n", .{waits});
    reportLatency("wake", "roundtrip", ctx.rtts[0..ctx.count], elapsed, 0, 0, 0);
}
