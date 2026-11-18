//! born.io network-client echo benchmark (P5.3, review 619 should-fix 6).
//! Built only by `zig build bench-net` on Zig >= 0.16; it is not part of
//! `test`, `test-bin` or `check-targets`.
//!
//!   born-net-bench serve  [--port P] [--size N] [--delay-ms M]
//!   born-net-bench client --port P [--route born|threaded] [--seconds S]
//!                         [--threads T] [--size N]
//!
//! The server is a plain blocking-thread echo peer (its own Io.Threaded) that
//! delays each reply by --delay-ms (default 1) so the client's read genuinely
//! parks. The client is the born.io network client route, or the all-Threaded
//! baseline: it writes a request and reads the echo, recording round-trip
//! latency. The delayed echo forces one parked read per request, which is
//! exactly where persistent read interest (arm once at connect, remove only at
//! close) removes the per-read unmonitor/re-arm registrations.
//!
//! Measure syscalls/req by wrapping the client in strace (Linux, epoll shows
//! the epoll_ctl delta) or truss (FreeBSD, kqueue batches changelists) and
//! dividing the syscall count by the printed `requests=` total. Compare the
//! same driver built against the pre-persistent-interest head and this one.
//! Accept latency results only on a quiet host (bench/quiet.sh).

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const born_io = @import("born.io");
const compat = @import("compat");
const Io = std.Io;

comptime {
    if (builtin.zig_version.minor < 16)
        @compileError("born-net-bench requires Zig >= 0.16 (born.io)");
    if (builtin.os.tag == .windows)
        @compileError("born-net-bench is POSIX only");
}

const threads_max: usize = 256;
const samples_max: usize = 1 << 21;
/// Largest request/response the stack buffers hold.
const size_max: usize = 16 * 1024;

fn nowNs() u64 {
    return born.nowNs() catch @panic("monotonic clock failed");
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch @panic("stdout format failed");
    var written: usize = 0;
    while (written < text.len) {
        written += compat.write(1, text[written..]) catch @panic("stdout write failed");
    }
}

const Route = enum { born, threaded };

const Options = struct {
    cmd: enum { serve, client } = .serve,
    route: Route = .born,
    port: u16 = 0,
    seconds: u32 = 5,
    threads: u32 = 1,
    size: usize = 64,
    delay_ms: u32 = 1,
};

fn parseArgs(argv: anytype) !Options {
    var o: Options = .{};
    if (argv.len < 2) return usage();
    o.cmd = std.meta.stringToEnum(@TypeOf(o.cmd), std.mem.sliceTo(argv[1], 0)) orelse return usage();
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const k = std.mem.sliceTo(argv[i], 0);
        i += 1;
        if (i >= argv.len) return usage();
        const v = std.mem.sliceTo(argv[i], 0);
        if (std.mem.eql(u8, k, "--route")) {
            o.route = std.meta.stringToEnum(Route, v) orelse return usage();
        } else if (std.mem.eql(u8, k, "--port")) {
            o.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, k, "--seconds")) {
            o.seconds = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--threads")) {
            o.threads = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--size")) {
            o.size = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, k, "--delay-ms")) {
            o.delay_ms = try std.fmt.parseInt(u32, v, 10);
        } else return usage();
    }
    if (o.seconds == 0 or o.threads == 0 or o.threads > threads_max or
        o.size == 0 or o.size > size_max) return usage();
    return o;
}

fn usage() error{Usage} {
    out(
        "usage: born-net-bench serve [--port P] [--size N] [--delay-ms M]\n" ++
            "       born-net-bench client --port P [--route born|threaded] [--seconds S]\n" ++
            "                             [--threads T] [--size N]\n",
        .{},
    );
    return error.Usage;
}

pub const main = if (builtin.zig_version.minor >= 16) mainWithInit else mainRaw;

fn mainWithInit(init: std.process.Init.Minimal) !void {
    return mainWithArgs(init.args.vector);
}

fn mainRaw() !void {
    return mainWithArgs(std.os.argv);
}

fn mainWithArgs(argv: anytype) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = if (builtin.mode == std.builtin.OptimizeMode.Debug) gpa.allocator() else std.heap.smp_allocator;
    const opts = parseArgs(argv) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => return err,
    };
    switch (opts.cmd) {
        .serve => try serve(alloc, opts),
        .client => try client(alloc, opts),
    }
}

/// Latency percentiles over an unsorted sample span, in microseconds.
const Stats = struct { p50: f64, p99: f64, max: f64, mean: f64 };

fn stats(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const us = 1000.0;
    return .{
        .p50 = @as(f64, @floatFromInt(samples[samples.len * 50 / 100])) / us,
        .p99 = @as(f64, @floatFromInt(samples[@min(samples.len - 1, samples.len * 99 / 100)])) / us,
        .max = @as(f64, @floatFromInt(samples[samples.len - 1])) / us,
        .mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len)) / us,
    };
}

// ----------------------------------------------------------------- server ----

fn serve(alloc: std.mem.Allocator, o: Options) !void {
    var threaded = Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(o.port) };
    var server = try addr.listen(fio, .{});
    defer server.deinit(fio);
    out("port={d} size={d} delay_ms={d}\n", .{ server.socket.address.ip4.port, o.size, o.delay_ms });
    while (true) {
        const peer = try server.accept(fio);
        const t = std.Thread.spawn(.{}, echoConn, .{ alloc, fio, peer, o.size, o.delay_ms }) catch {
            peer.close(fio);
            continue;
        };
        t.detach();
    }
}

/// One blocking echo connection: read a whole request, delay, write it back.
/// The delay is what forces the client's read to park on the reactor.
fn echoConn(alloc: std.mem.Allocator, fio: Io, peer: Io.net.Stream, size: usize, delay_ms: u32) void {
    defer peer.close(fio);
    const msg = alloc.alloc(u8, size) catch return;
    defer alloc.free(msg);
    var rbuf: [4096]u8 = undefined;
    var reader = peer.reader(fio, &rbuf);
    var wbuf: [4096]u8 = undefined;
    var writer = peer.writer(fio, &wbuf);
    while (true) {
        var iov = [_][]u8{msg};
        reader.interface.readVecAll(&iov) catch return;
        if (delay_ms > 0) Io.sleep(fio, .fromMilliseconds(delay_ms), .awake) catch return;
        writer.interface.writeAll(msg) catch return;
        writer.interface.flush() catch return;
    }
}

// ----------------------------------------------------------------- client ----

const ClientCtx = struct {
    io: Io,
    target: Io.net.IpAddress,
    size: usize,
    end_ns: u64,
    count: std.atomic.Value(u64) = .init(0),
    samples: []u64,
    sample_idx: std.atomic.Value(usize) = .init(0),
};

fn client(alloc: std.mem.Allocator, o: Options) !void {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const io = try born_io.io(&port, .{
        .allocator = alloc,
        .capabilities = if (o.route == .born) .{ .network = .born_evented } else .{},
    });
    defer born_io.deinit(io);
    const target: Io.net.IpAddress = .{ .ip4 = .loopback(o.port) };

    const ctx = try alloc.create(ClientCtx);
    defer alloc.destroy(ctx);
    ctx.* = .{
        .io = io,
        .target = target,
        .size = o.size,
        .end_ns = nowNs() + @as(u64, o.seconds) * std.time.ns_per_s,
        .samples = try alloc.alloc(u64, samples_max),
    };
    defer alloc.free(ctx.samples);
    const threads = try alloc.alloc(std.Thread, o.threads);
    defer alloc.free(threads);

    const stats_before = born_io.networkStats(io);
    const phase_start = nowNs();
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, clientWorker, .{ctx});
    for (threads) |t| t.join();
    const elapsed_ns = nowNs() - phase_start;

    const requests = ctx.count.load(.monotonic);
    const taken = @min(ctx.sample_idx.load(.monotonic), ctx.samples.len);
    if (taken == 0) {
        out("route={s} no completed requests (server unreachable?)\n", .{@tagName(o.route)});
        return error.NoRequests;
    }
    const s = stats(ctx.samples[0..taken]);
    const ops_per_sec = @as(f64, @floatFromInt(requests)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
    out("route={s} threads={d} seconds={d} size={d} requests={d} ops_per_sec={d:.0} p50_us={d:.1} p99_us={d:.1} max_us={d:.1} mean_us={d:.1}\n", .{
        @tagName(o.route), o.threads, o.seconds, o.size, requests, ops_per_sec, s.p50, s.p99, s.max, s.mean,
    });
    const st = born_io.networkStats(io);
    out("route={s} counters connect={d} read={d} write={d} threaded_connect={d} threaded_read={d} threaded_write={d}\n", .{
        @tagName(o.route),
        st.connect - stats_before.connect,
        st.read - stats_before.read,
        st.write - stats_before.write,
        st.threaded_connect - stats_before.threaded_connect,
        st.threaded_read - stats_before.threaded_read,
        st.threaded_write - stats_before.threaded_write,
    });
}

/// One connection per worker: write a request, read the delayed echo, record
/// the round-trip latency. Stack buffers keep the hot path allocation-free.
fn clientWorker(ctx: *ClientCtx) void {
    var stream = ctx.target.connect(ctx.io, .{ .mode = .stream }) catch return;
    defer stream.close(ctx.io);
    var msg: [size_max]u8 = undefined;
    var got: [size_max]u8 = undefined;
    @memset(msg[0..ctx.size], 'x');
    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(ctx.io, &rbuf);
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(ctx.io, &wbuf);
    while (nowNs() < ctx.end_ns) {
        const t0 = nowNs();
        writer.interface.writeAll(msg[0..ctx.size]) catch return;
        writer.interface.flush() catch return;
        var iov = [_][]u8{got[0..ctx.size]};
        reader.interface.readVecAll(&iov) catch return;
        const dt = nowNs() - t0;
        const idx = ctx.sample_idx.fetchAdd(1, .monotonic);
        if (idx < ctx.samples.len) ctx.samples[idx] = dt;
        _ = ctx.count.fetchAdd(1, .monotonic);
    }
}
