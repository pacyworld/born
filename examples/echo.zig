//! Shared echo engine for the born examples, and the reference shape for
//! downstream ports: one event port drives a TCP listener, a fixed table of
//! accepted streams, an idle-timeout sweep timer, and an optional drain
//! deadline. Timers measure deadlines only; every byte moves on readiness
//! (kqueue/epoll) or completions (IOCP).
//!
//! Rules this engine demonstrates:
//! - Accepted streams live in stable heap slots; a slot is never reused on
//!   Windows until its close completions are absorbed.
//! - Reads drain to EAGAIN (or a posted receive on IOCP); a full echo buffer
//!   stops reading and resumes after the pending write drains, so no edge is
//!   stranded and peers see flow control.
//! - Write interest is armed only on `want_write` and canceled on the
//!   writable event, per the portable companion contract.
//! - Listener exhaustion and a full connection table pause the listener with
//!   `unmonitorRead`; closing a connection resumes it and drains at once,
//!   because queued connections produce no new edge.
//! - SIGTERM/Ctrl+C (optional) closes the listener and drains established
//!   connections until they finish or the drain deadline fires.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");

const is_windows = builtin.os.tag == .windows;
const PlainNb = born.socket.PlainNb;
const Listener = born.socket.Listener;

pub const Options = struct {
    /// Connection table size. Slots are allocated once and never move.
    max_conns: usize = 128,
    /// Close a connection with no read or write progress for this long.
    idle_ms: u32 = 30_000,
    /// Idle sweep period (a deadline timer, never an I/O driver).
    sweep_ms: u32 = 1_000,
    /// After drain begins, force-close remaining connections after this long.
    drain_ms: u32 = 5_000,
    /// Watch `.terminate` and `.interrupt` on the port and drain on either.
    /// Signals are process-wide: only one port in a process may watch them.
    watch_signals: bool = false,
};

const Conn = struct {
    stream: PlainNb = .{},
    active: bool = false,
    /// Windows only: closed, waiting for completions before the slot frees.
    closing: bool = false,
    peer_eof: bool = false,
    buf: [4096]u8 = undefined,
    /// Bytes in `buf` awaiting echo; `off` bytes of them already written.
    len: usize = 0,
    off: usize = 0,
    last_ns: u64 = 0,
};

const sweep_id: u32 = 1;
const drain_id: u32 = 2;

pub const Echo = struct {
    alloc: std.mem.Allocator,
    port: *born.EvPort,
    listener: *Listener,
    opts: Options,
    conns: []Conn,
    draining: bool = false,
    paused: bool = false,
    listener_closed: bool = false,
    accepted_total: usize = 0,
    /// Bytes read from peers for echo (a pending tail may be cut by drain).
    echoed_bytes: usize = 0,
    // Timer events carry no id; distinct udata sentinels tell them apart.
    sweep_tag: u8 = 0,
    drain_tag: u8 = 0,

    /// Heap-constructs the engine so its timer sentinels never move. The
    /// listener must already be open; the engine closes it on drain/deinit.
    /// Call `listener.register` after init.
    pub fn init(alloc: std.mem.Allocator, port: *born.EvPort, listener: *Listener, opts: Options) !*Echo {
        std.debug.assert(opts.max_conns > 0 and opts.sweep_ms > 0);
        const self = try alloc.create(Echo);
        errdefer alloc.destroy(self);
        const conns = try alloc.alloc(Conn, opts.max_conns);
        errdefer alloc.free(conns);
        for (conns) |*c| c.* = .{};
        self.* = .{
            .alloc = alloc,
            .port = port,
            .listener = listener,
            .opts = opts,
            .conns = conns,
        };
        try port.addTimer(sweep_id, &self.sweep_tag, opts.sweep_ms, .repeat);
        errdefer port.cancelTimer(sweep_id);
        if (opts.watch_signals) {
            try port.watchSignal(.terminate, null);
            errdefer port.unwatchSignal(.terminate);
            try port.watchSignal(.interrupt, null);
        }
        return self;
    }

    /// Closes the listener and every connection, absorbs this engine's
    /// pending Windows completions, and frees all storage. Other users of
    /// the port must be closed first: the drain only absorbs this engine's
    /// completion keys. Do not wait on the port afterwards.
    pub fn deinit(self: *Echo) void {
        self.closeListener();
        for (self.conns) |*c| {
            if (c.active) self.closeConn(c);
        }
        if (is_windows) self.drainCompletions();
        self.port.cancelTimer(sweep_id);
        self.port.cancelTimer(drain_id);
        if (self.opts.watch_signals) {
            self.port.unwatchSignal(.terminate);
            self.port.unwatchSignal(.interrupt);
        }
        const alloc = self.alloc;
        alloc.free(self.conns);
        alloc.destroy(self);
    }

    /// The loop condition: run until drain begins, then until every
    /// established connection has finished or been force-closed.
    pub fn running(self: *const Echo) bool {
        return !self.draining or self.activeCount() > 0;
    }

    pub fn activeCount(self: *const Echo) usize {
        var n: usize = 0;
        for (self.conns) |*c| {
            if (c.active) n += 1;
        }
        return n;
    }

    /// One `wait()` plus dispatch. `null` blocks until an event arrives;
    /// timers, signals and wakes all arrive through the same call.
    pub fn waitAndHandle(self: *Echo, timeout_ms: ?i32) !usize {
        var events: [64]born.Event = undefined;
        const n = try self.port.wait(&events, timeout_ms);
        try self.handleBatch(events[0..n]);
        return n;
    }

    /// Dispatch a harvested batch. Events naming other port users (or stale
    /// events for closed descriptors) fall through untouched.
    pub fn handleBatch(self: *Echo, events: []const born.Event) !void {
        for (events) |ev| {
            if (ev.wake) continue; // the loop owner interprets wakes
            if (ev.signal) |sig| {
                switch (sig) {
                    .terminate, .interrupt => try self.beginDrain(),
                    else => {},
                }
                continue;
            }
            if (ev.timer) {
                if (ev.udata == @as(?*anyopaque, &self.sweep_tag)) {
                    try self.sweep();
                } else if (ev.udata == @as(?*anyopaque, &self.drain_tag)) {
                    self.closeAll();
                }
                continue;
            }
            if (ev.udata == @as(?*anyopaque, self.listener)) {
                try self.onListenerEvent(ev);
                continue;
            }
            if (self.connFrom(ev.udata)) |c| try self.onConnEvent(c, ev);
        }
    }

    /// Stop accepting and drain established connections. Idempotent. If the
    /// drain deadline timer cannot be armed, close everything at once rather
    /// than wait for idle peers forever.
    pub fn beginDrain(self: *Echo) !void {
        if (self.draining) return;
        self.draining = true;
        self.closeListener();
        self.port.addTimer(drain_id, &self.drain_tag, self.opts.drain_ms, .once) catch {
            self.closeAll();
        };
    }

    pub fn closeAll(self: *Echo) void {
        for (self.conns) |*c| {
            if (c.active) self.closeConn(c);
        }
    }

    fn closeListener(self: *Echo) void {
        if (self.listener_closed) return;
        self.listener_closed = true;
        self.paused = false;
        self.port.purgeFd(self.listener.handle());
        self.listener.close();
    }

    fn onListenerEvent(self: *Echo, ev: born.Event) !void {
        if (is_windows) {
            _ = self.listener.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
            if (self.listener_closed) return; // teardown: drain only
        }
        if (ev.err) {
            std.log.err("echo: listener event error {d}", .{ev.err_no});
            try self.beginDrain();
            return;
        }
        if (self.draining) return;
        self.listener.hintReadable(ev);
        try self.acceptLoop();
    }

    fn acceptLoop(self: *Echo) !void {
        while (!self.draining) {
            const c = self.freeSlot() orelse {
                self.pauseListener();
                return;
            };
            const res = self.listener.acceptNb(&c.stream, c) catch |err| switch (err) {
                error.ResourceExhausted => {
                    self.pauseListener();
                    return;
                },
                else => return err,
            };
            switch (res) {
                .accepted => {
                    c.active = true;
                    c.peer_eof = false;
                    c.len = 0;
                    c.off = 0;
                    c.last_ns = try born.nowNs();
                    self.accepted_total += 1;
                    // POSIX: register read interest yourself after accept.
                    // Windows: acceptNb already associated the stream; the
                    // first readNb below posts its receive.
                    if (!is_windows) self.port.monitorRead(c.stream.handle(), c);
                    self.drive(c) catch self.closeConn(c);
                },
                .want_accept => return,
            }
        }
    }

    fn freeSlot(self: *Echo) ?*Conn {
        for (self.conns) |*c| {
            if (!c.active and !c.closing) return c;
        }
        return null;
    }

    /// Resolve an event's udata to its connection slot in O(1). udata is the
    /// `*Conn` registered at accept; range-check it against the slot table so
    /// events naming other port users fall through. The reference shape avoids
    /// a per-event linear scan of the table.
    fn connFrom(self: *Echo, udata: ?*anyopaque) ?*Conn {
        const p = udata orelse return null;
        const base = @intFromPtr(self.conns.ptr);
        const addr = @intFromPtr(p);
        if (addr < base or addr >= base + self.conns.len * @sizeOf(Conn)) return null;
        if ((addr - base) % @sizeOf(Conn) != 0) return null;
        const c: *Conn = @ptrCast(@alignCast(p));
        if (!c.active and !c.closing) return null;
        return c;
    }

    fn pauseListener(self: *Echo) void {
        if (self.paused or self.listener_closed) return;
        self.paused = true;
        self.port.unmonitorRead(self.listener.handle());
    }

    /// A freed slot may let queued connections in: re-register and drain at
    /// once, since connections already queued produce no new edge.
    fn resumeListener(self: *Echo) void {
        if (!self.paused or self.draining or self.listener_closed) return;
        self.paused = false;
        self.listener.register(self.port, self.listener) catch |err| {
            std.log.err("echo: listener resume failed: {s}", .{@errorName(err)});
            return;
        };
        self.acceptLoop() catch |err| {
            std.log.err("echo: accept after resume failed: {s}", .{@errorName(err)});
        };
    }

    fn onConnEvent(self: *Echo, c: *Conn, ev: born.Event) !void {
        if (is_windows) {
            _ = c.stream.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
            if (c.closing) {
                if (c.stream.pendingOps() == 0) {
                    c.stream.deinit();
                    c.closing = false;
                    self.resumeListener();
                }
                return;
            }
            if (ev.err) {
                self.closeConn(c);
                return;
            }
        } else {
            if (ev.err) {
                self.closeConn(c);
                return;
            }
            if (ev.writable) self.port.cancelWrite(c.stream.handle());
            if (ev.readable) c.stream.hintReadable(ev);
        }
        self.drive(c) catch self.closeConn(c);
    }

    /// Read into the echo buffer and flush it, looping until neither
    /// direction can progress. Flushing first frees the buffer before the
    /// next read, so a full buffer resumes reading after the pending write
    /// drains (its completion on IOCP, the writable event on POSIX) without
    /// waiting for a new read edge. Reading only once per drive would strand
    /// buffered input (IOCP recv_buf, or socket data behind EV_CLEAR/EPOLLET)
    /// whenever the buffer filled mid-transfer.
    fn drive(self: *Echo, c: *Conn) !void {
        while (c.active) {
            try self.flush(c);
            // Send still pending: resume on its completion or writable event.
            if (c.off != c.len) return;
            if (c.peer_eof) return self.closeConn(c);
            switch (try c.stream.readNb(c.buf[0..])) {
                .data => |n| {
                    if (n == 0) return;
                    c.len = n;
                    c.last_ns = try born.nowNs();
                    self.echoed_bytes += n;
                },
                .want_read, .want_write => return,
                .eof => c.peer_eof = true,
            }
        }
    }

    /// Consume partial writes until the buffer drains or the send side
    /// wants write readiness (POSIX) or a send completion (Windows).
    fn flush(self: *Echo, c: *Conn) !void {
        while (c.active and c.off < c.len) {
            switch (try c.stream.writeNb(c.buf[c.off..c.len])) {
                .done => |n| {
                    c.off += n;
                    c.last_ns = try born.nowNs();
                },
                .want_write => {
                    if (!is_windows) self.port.wantWrite(c.stream.handle(), c);
                    return;
                },
                // Plain streams never return want_read; treat it as a dead
                // peer so the connection closes instead of spinning.
                .want_read => return error.SocketError,
            }
        }
        if (c.off == c.len) {
            c.off = 0;
            c.len = 0;
        }
    }

    fn closeConn(self: *Echo, c: *Conn) void {
        if (!c.active) return;
        c.active = false;
        self.port.purgeFd(c.stream.handle());
        c.stream.cancelAndClose();
        if (is_windows) {
            if (c.stream.pendingOps() == 0) {
                c.stream.deinit();
            } else {
                c.closing = true; // slot frees once completions are absorbed
            }
        }
        self.resumeListener();
    }

    fn sweep(self: *Echo) !void {
        const now = try born.nowNs();
        const idle_ns = @as(u64, self.opts.idle_ms) * std.time.ns_per_ms;
        for (self.conns) |*c| {
            if (c.active and now - c.last_ns >= idle_ns) self.closeConn(c);
        }
    }

    fn pendingOps(self: *const Echo) usize {
        var n = self.listener.pendingOps();
        for (self.conns) |*c| n += c.stream.pendingOps();
        return n;
    }

    /// Windows teardown: absorb this engine's completions until nothing is
    /// pending, so no OVERLAPPED storage is freed under a live operation.
    fn drainCompletions(self: *Echo) void {
        var events: [16]born.Event = undefined;
        var spins: usize = 0;
        while (self.pendingOps() != 0) : (spins += 1) {
            if (spins > 200) @panic("echo: completion drain timed out");
            const n = self.port.wait(&events, 100) catch return;
            for (events[0..n]) |ev| {
                if (ev.udata == @as(?*anyopaque, self.listener)) {
                    _ = self.listener.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
                    continue;
                }
                if (self.connFrom(ev.udata)) |c| {
                    _ = c.stream.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
                    if (c.closing and c.stream.pendingOps() == 0) {
                        c.stream.deinit();
                        c.closing = false;
                    }
                }
            }
        }
    }
};

/// One thread-per-core worker: its own event port and listener, constructed
/// in place inside heap storage so nothing moves while operations pend.
/// The main thread coordinates through atomics and cross-thread `wake()`.
pub const Worker = struct {
    alloc: std.mem.Allocator,
    /// Main thread's port: woken on ready or failure.
    notify: *born.EvPort,
    /// Bind address; port 0 picks an ephemeral port (read `bound` after ready).
    addr: born.socket.Address,
    reuse: born.socket.ReusePort = .balanced,
    opts: Options = .{},

    port: born.EvPort = undefined,
    listener: Listener = .{},
    echo: ?*Echo = null,
    /// Actual bound address, valid once `ready` is set.
    bound: born.socket.Address = undefined,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Setup failure cause, valid once `failed` is set.
    last_error: ?anyerror = null,
    /// Final stats, valid after `thread.join()`.
    final_accepted: usize = 0,
    final_echoed: usize = 0,
    /// Set when the worker loop has finished and its echo engine is freed.
    /// The port stays alive until `shutdownAll` joins and deinits it, so a
    /// wake never lands on a deinitialized port.
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reaped: bool = false,
    thread: std.Thread = undefined,

    pub fn spawn(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Worker) void {
        self.setup() catch |err| {
            self.last_error = err;
            self.failed.store(true, .release);
            self.notify.wake();
            return;
        };
        self.ready.store(true, .release);
        self.notify.wake();
        // A shutdown requested during startup is honored before the first wait.
        if (self.shutdown.load(.acquire)) self.echo.?.beginDrain() catch self.echo.?.closeAll();
        while (self.echo.?.running()) {
            _ = self.echo.?.waitAndHandle(null) catch |err| {
                std.log.err("echo worker: wait failed: {s}", .{@errorName(err)});
                break;
            };
            if (self.shutdown.load(.acquire) and !self.echo.?.draining) {
                self.echo.?.beginDrain() catch self.echo.?.closeAll();
            }
        }
        self.final_accepted = self.echo.?.accepted_total;
        self.final_echoed = self.echo.?.echoed_bytes;
        self.echo.?.deinit();
        // The port stays alive until shutdownAll joins this thread and
        // deinits it, so a cross-thread wake never lands on a freed port.
        self.exited.store(true, .release);
    }

    fn setup(self: *Worker) !void {
        self.port = try born.EvPort.init(self.alloc);
        errdefer self.port.deinit();
        // openTcp posts no operations before register, so the value move
        // into this heap slot is safe; after register it never moves.
        self.listener = try Listener.openTcp(self.alloc, self.addr, .{ .reuse_port = self.reuse });
        var echo_owned = false;
        errdefer if (!echo_owned) self.listener.close();
        self.echo = try Echo.init(self.alloc, &self.port, &self.listener, self.opts);
        echo_owned = true;
        errdefer self.echo.?.deinit();
        try self.listener.register(&self.port, &self.listener);
        self.bound = try self.listener.localAddress();
    }

    /// Request shutdown on every worker, join them all, and deinit the
    /// ports of workers that started (failed workers cleaned up in setup).
    /// Workers still starting observe the flag when they report ready;
    /// workers that already exited are joined without a wake.
    pub fn shutdownAll(workers: []Worker, notify: *born.EvPort) !void {
        for (workers) |*w| w.shutdown.store(true, .release);
        var events: [16]born.Event = undefined;
        var remaining = workers.len;
        while (remaining > 0) {
            for (workers) |*w| {
                if (w.reaped) continue;
                if (w.ready.load(.acquire)) {
                    if (!w.exited.load(.acquire)) w.port.wake();
                    w.thread.join();
                    w.port.deinit();
                    w.reaped = true;
                    remaining -= 1;
                } else if (w.failed.load(.acquire)) {
                    w.thread.join();
                    w.reaped = true;
                    remaining -= 1;
                }
            }
            if (remaining == 0) break;
            _ = try notify.wait(&events, null);
        }
    }
};

pub const Startup = enum { ready, signal, failed, timeout };

/// Wait until every worker reports ready, one fails, a signal arrives on
/// `notify`, or the deadline passes. The wait timeout bounds the startup
/// deadline; it never drives I/O.
pub fn waitReady(workers: []const Worker, notify: *born.EvPort, timeout_ms: u32) !Startup {
    var events: [16]born.Event = undefined;
    const deadline = try born.nowNs() + @as(u64, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        var ready: usize = 0;
        for (workers) |*w| {
            if (w.failed.load(.acquire)) return .failed;
            if (w.ready.load(.acquire)) ready += 1;
        }
        if (ready == workers.len) return .ready;
        const now = try born.nowNs();
        if (now >= deadline) return .timeout;
        const ms: i32 = @intCast(@min((deadline - now) / std.time.ns_per_ms, 1000));
        const n = try notify.wait(&events, ms);
        for (events[0..n]) |ev| {
            if (ev.signal != null) return .signal;
        }
    }
}
