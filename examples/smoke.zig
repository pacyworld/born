//! Integration smoke for the born examples: real sockets through the shared
//! echo engine on the selected backend. Runs natively in CI on FreeBSD
//! (kqueue), Linux (epoll) and Windows (IOCP) like the core suite, so the
//! examples have runtime evidence, not just cross-compilation.
//!
//! Covers: echo round trip, idle-timeout close, large-payload partial writes
//! and buffer backpressure, cross-thread wake shutdown, SIGTERM drain
//! (POSIX), and kernel-balanced listeners (FreeBSD/Linux).

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const echo = @import("echo.zig");

const alloc = std.testing.allocator;
const is_windows = builtin.os.tag == .windows;
const PlainNb = born.socket.PlainNb;
const Listener = born.socket.Listener;
const Address = born.socket.Address;
const ns_per_ms = std.time.ns_per_ms;

/// Winsock setsockopt for the test-only socket-buffer cap below. born
/// exposes no public socket-option setter; a consumer declares its own
/// ws2_32 extern with born.windows.SOCKET (pointer-sized, the UINT_PTR
/// ABI) and casts the handle at the boundary, matching the callconv born
/// uses for ws2_32. Referenced only in the Windows branch, so POSIX builds
/// never link ws2_32.
extern "ws2_32" fn setsockopt(s: born.windows.SOCKET, level: c_int, optname: c_int, optval: ?[*]const u8, optlen: c_int) callconv(.winapi) c_int;

/// Test-only: bound a socket's buffer so loopback kernel buffers cannot
/// absorb the whole payload. With default buffers Linux autotunes large
/// loopback windows and the server echoes everything without ever stalling,
/// hiding the full-buffer resume path the backpressure test exercises.
/// Capping the client receive window keeps the peer's congestion window from
/// ramping; capping the server send buffer bounds queued data directly (Linux
/// sizes the send buffer from cwnd and the large loopback MSS, so autotuning
/// alone is not a reliable ceiling). Together the write pends deterministically
/// on kqueue, epoll and IOCP. 32 KiB is far below the ~1 MiB payload yet large
/// enough that the resume phase drains at full speed, not a crawling window.
fn capSockBuf(handle: born.Handle, snd: bool) !void {
    var val: c_int = 32 * 1024;
    if (is_windows) {
        const sock: born.windows.SOCKET = @ptrCast(handle);
        // SOL_SOCKET = 0xffff; SO_SNDBUF = 0x1001, SO_RCVBUF = 0x1002.
        const optname: c_int = if (snd) 0x1001 else 0x1002;
        if (setsockopt(sock, 0xffff, optname, std.mem.asBytes(&val).ptr, @sizeOf(c_int)) != 0)
            return error.SmokeSocketOpt;
    } else {
        const optname: u32 = if (snd) std.posix.SO.SNDBUF else std.posix.SO.RCVBUF;
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, optname, std.mem.asBytes(&val)) catch
            return error.SmokeSocketOpt;
    }
}

/// One port driving both the engine (listener + accepted stream) and a
/// client companion. Constructed in place: the port, listener and client
/// register udata pointers into this storage and must never move.
const Single = struct {
    port: born.EvPort,
    listener: Listener,
    engine: *echo.Echo,
    client: PlainNb = .{},
    out: []u8,
    connected: bool = false,
    client_closed: bool = false,
    client_eof: bool = false,
    /// When false the client sends but does not read, forcing the server's
    /// echo buffer to fill and its write to pend (backpressure regression).
    read_enabled: bool = true,
    sent: usize = 0,
    recvd: usize = 0,

    fn init(self: *Single, opts: echo.Options, out_len: usize) !void {
        self.* = .{ .port = undefined, .listener = .{}, .engine = undefined, .out = &.{} };
        self.port = try born.EvPort.init(alloc);
        errdefer self.port.deinit();
        self.out = try alloc.alloc(u8, out_len);
        errdefer alloc.free(self.out);
        self.listener = try Listener.openTcp(alloc, try Address.parseIp4("127.0.0.1", 0), .{});
        var engine_owned = false;
        errdefer if (!engine_owned) self.listener.close();
        self.engine = try echo.Echo.init(alloc, &self.port, &self.listener, opts);
        engine_owned = true;
        errdefer self.engine.deinit();
        try self.listener.register(&self.port, &self.listener);
        try self.client.startConnectAddrInto(try self.listener.localAddress(), &self.port, &self.client);
        if (!is_windows) self.port.wantWrite(self.client.handle(), &self.client);
    }

    fn deinit(self: *Single) void {
        self.closeClient();
        self.engine.deinit();
        alloc.free(self.out);
        self.port.deinit();
    }

    /// One non-blocking progress pass plus one wait. Client events feed the
    /// client state machine; the whole batch also goes to the engine, which
    /// ignores events naming other port users. Each side loops until it wants
    /// readiness/completion: IOCP reports a completed send without posting the
    /// next one and returns buffered reads without posting a receive, so a
    /// single op per step would idle out the wait with nothing in flight.
    fn step(self: *Single, payload: []const u8, deadline_ns: u64) !void {
        if (try born.nowNs() > deadline_ns) return error.SmokeTimeout;
        if (self.connected and self.sent < payload.len) {
            while (self.sent < payload.len) {
                switch (try self.client.writeNb(payload[self.sent..])) {
                    .done => |n| self.sent += n,
                    .want_write => {
                        if (!is_windows) self.port.wantWrite(self.client.handle(), &self.client);
                        break;
                    },
                    .want_read => return error.SmokeUnexpected,
                }
            }
        }
        if (self.read_enabled and self.connected and !self.client_eof and !self.client_closed and self.recvd < self.out.len) {
            while (self.recvd < self.out.len) {
                switch (try self.client.readNb(self.out[self.recvd..])) {
                    .data => |n| {
                        if (n == 0) break;
                        self.recvd += n;
                    },
                    .want_read, .want_write => break,
                    .eof => {
                        self.client_eof = true;
                        break;
                    },
                }
            }
        }
        var events: [32]born.Event = undefined;
        const n = try self.port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.udata == @as(?*anyopaque, &self.client)) try self.onClientEvent(ev);
        }
        try self.engine.handleBatch(events[0..n]);
    }

    /// Wait + engine dispatch only, for after the client is closed.
    fn pumpEngine(self: *Single, deadline_ns: u64) !void {
        if (try born.nowNs() > deadline_ns) return error.SmokeTimeout;
        var events: [32]born.Event = undefined;
        const n = try self.port.wait(&events, 100);
        try self.engine.handleBatch(events[0..n]);
    }

    fn onClientEvent(self: *Single, ev: born.Event) !void {
        if (is_windows) {
            const kind = self.client.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
            if (ev.err) return error.SmokeClientError;
            if (kind == .connect) {
                try self.client.connectDone();
                self.connected = true;
            }
        } else {
            if (ev.err) return error.SmokeClientError;
            if (ev.writable) {
                self.port.cancelWrite(self.client.handle());
                if (!self.connected) {
                    try self.client.connectDone();
                    self.connected = true;
                    self.port.monitorRead(self.client.handle(), &self.client);
                }
            }
        }
    }

    fn closeClient(self: *Single) void {
        if (self.client_closed) return;
        self.client_closed = true;
        self.port.purgeFd(self.client.handle());
        self.client.cancelAndClose();
        if (is_windows) {
            // Absorb the client's close completions; feed everything else
            // to the engine so no server-side completion is swallowed.
            var events: [8]born.Event = undefined;
            var spins: usize = 0;
            while (self.client.pendingOps() != 0) : (spins += 1) {
                if (spins > 100) @panic("smoke: client completion drain timed out");
                const n = self.port.wait(&events, 100) catch return;
                for (events[0..n]) |ev| {
                    if (ev.udata == @as(?*anyopaque, &self.client)) {
                        _ = self.client.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
                    }
                }
                self.engine.handleBatch(events[0..n]) catch {};
            }
        }
        self.client.deinit();
    }
};

test "example smoke: echo round trip and clean drain" {
    var s: Single = undefined;
    try s.init(.{}, 64);
    defer s.deinit();
    const payload = "born echo round trip 0123456789";
    const deadline = try born.nowNs() + 10_000 * ns_per_ms;
    while (s.recvd < payload.len) try s.step(payload, deadline);
    try std.testing.expectEqualSlices(u8, payload, s.out[0..payload.len]);
    try std.testing.expectEqual(@as(usize, 1), s.engine.accepted_total);
    s.closeClient();
    while (s.engine.activeCount() != 0) try s.pumpEngine(deadline);
    try s.engine.beginDrain();
    try std.testing.expect(!s.engine.running());
    try std.testing.expectEqual(payload.len, s.engine.echoed_bytes);
}

test "example smoke: idle timeout closes a silent connection" {
    var s: Single = undefined;
    try s.init(.{ .idle_ms = 150, .sweep_ms = 50 }, 16);
    defer s.deinit();
    const deadline = try born.nowNs() + 5_000 * ns_per_ms;
    // Connect and stay silent; the sweep timer must close the server side.
    while (!s.client_eof) try s.step("", deadline);
    try std.testing.expectEqual(@as(usize, 1), s.engine.accepted_total);
    try std.testing.expectEqual(@as(usize, 0), s.engine.activeCount());
}

test "example smoke: large payload drains partial writes both ways" {
    const len = 256 * 1024;
    var s: Single = undefined;
    try s.init(.{}, len);
    defer s.deinit();
    const payload = try alloc.alloc(u8, len);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    const deadline = try born.nowNs() + 15_000 * ns_per_ms;
    while (s.recvd < len) try s.step(payload, deadline);
    try std.testing.expectEqualSlices(u8, payload, s.out);
    s.closeClient();
    while (s.engine.activeCount() != 0) try s.pumpEngine(deadline);
    try s.engine.beginDrain();
    try std.testing.expect(!s.engine.running());
    try std.testing.expectEqual(len, s.engine.echoed_bytes);
}

test "example smoke: full echo buffer resumes reading after the write drains" {
    const len = 1024 * 1024;
    var s: Single = undefined;
    try s.init(.{}, len);
    defer s.deinit();
    s.read_enabled = false;
    const payload = try alloc.alloc(u8, len);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    const deadline = try born.nowNs() + 20_000 * ns_per_ms;
    // Force the stall on every backend by bounding both socket buffers (see
    // capSockBuf). Apply the caps to established sockets before any payload
    // flows: an empty payload steps connect/accept to completion without
    // sending. The client receive window must be set on a connected socket
    // (Windows ignores SO_RCVBUF set during a pending ConnectEx), and the
    // server send buffer on an accepted stream.
    while (!s.connected) try s.step("", deadline);
    try capSockBuf(s.client.handle(), false);
    while (s.engine.activeCount() == 0) try s.step("", deadline);
    for (s.engine.conns) |*c| {
        if (c.active) try capSockBuf(c.stream.handle(), true);
    }
    // Phase 1: send without reading. The server echoes until its buffer fills
    // and the send pends against the client's closed window; echoed_bytes then
    // plateaus. This forces the full-buffer resume path on every backend, not
    // only IOCP: POSIX loopback never returns EAGAIN for a 4 KiB write unless
    // the peer stops reading, so the stranding bug would otherwise hide there.
    var last_echoed: usize = 0;
    var stall: usize = 0;
    while (stall < 16) {
        try s.step(payload, deadline);
        if (s.engine.echoed_bytes == last_echoed) {
            stall += 1;
        } else {
            stall = 0;
            last_echoed = s.engine.echoed_bytes;
        }
    }
    // The server stalled before echoing everything: backpressure actually hit.
    try std.testing.expect(s.engine.echoed_bytes < len);
    // Phase 2: resume reading. The writable event (POSIX) or send completion
    // (IOCP) frees the buffer and drive re-enters the read side; the transfer
    // must complete rather than hang until the idle sweep.
    s.read_enabled = true;
    while (s.recvd < len) try s.step(payload, deadline);
    try std.testing.expectEqualSlices(u8, payload, s.out);
    s.closeClient();
    while (s.engine.activeCount() != 0) try s.pumpEngine(deadline);
    try s.engine.beginDrain();
    try std.testing.expect(!s.engine.running());
    try std.testing.expectEqual(len, s.engine.echoed_bytes);
}

/// One full client lifecycle on its own port: connect, echo, verify, close.
fn echoOnce(addr: Address, payload: []const u8) !void {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var client: PlainNb = .{};
    var connected = false;
    var sent: usize = 0;
    var recvd: usize = 0;
    const out = try alloc.alloc(u8, payload.len);
    defer alloc.free(out);
    try client.startConnectAddrInto(addr, &port, &client);
    if (!is_windows) port.wantWrite(client.handle(), &client);
    var events: [16]born.Event = undefined;
    const deadline = try born.nowNs() + 10_000 * ns_per_ms;
    while (recvd < payload.len) {
        if (try born.nowNs() > deadline) return error.SmokeTimeout;
        if (connected and sent < payload.len) {
            while (sent < payload.len) {
                switch (try client.writeNb(payload[sent..])) {
                    .done => |n| sent += n,
                    .want_write => {
                        if (!is_windows) port.wantWrite(client.handle(), &client);
                        break;
                    },
                    .want_read => return error.SmokeUnexpected,
                }
            }
        }
        if (connected) {
            while (recvd < payload.len) {
                switch (try client.readNb(out[recvd..])) {
                    .data => |n| {
                        if (n == 0) break;
                        recvd += n;
                    },
                    .want_read, .want_write => break,
                    .eof => return error.SmokeUnexpectedEof,
                }
            }
        }
        if (recvd >= payload.len) break;
        const n = try port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.udata != @as(?*anyopaque, &client)) continue;
            if (is_windows) {
                const kind = client.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
                if (ev.err) return error.SmokeClientError;
                if (kind == .connect) {
                    try client.connectDone();
                    connected = true;
                }
            } else {
                if (ev.err) return error.SmokeClientError;
                if (ev.writable) {
                    port.cancelWrite(client.handle());
                    if (!connected) {
                        try client.connectDone();
                        connected = true;
                        port.monitorRead(client.handle(), &client);
                    }
                }
            }
        }
    }
    try std.testing.expectEqualSlices(u8, payload, out);
    port.purgeFd(client.handle());
    client.cancelAndClose();
    if (is_windows) {
        var spins: usize = 0;
        while (client.pendingOps() != 0) : (spins += 1) {
            if (spins > 100) return error.SmokeTimeout;
            const n = try port.wait(&events, 100);
            for (events[0..n]) |ev| {
                if (ev.udata == @as(?*anyopaque, &client))
                    _ = client.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
            }
        }
    }
    client.deinit();
}

test "example smoke: cross-thread wake drains a worker" {
    try born.blockSignals(&.{ .terminate, .interrupt });
    var main_port = try born.EvPort.init(alloc);
    defer main_port.deinit();
    const workers = try alloc.alloc(echo.Worker, 1);
    defer alloc.free(workers);
    workers[0] = .{
        .alloc = alloc,
        .notify = &main_port,
        .addr = try Address.parseIp4("127.0.0.1", 0),
        .reuse = .none,
    };
    try workers[0].spawn();
    try std.testing.expectEqual(echo.Startup.ready, try echo.waitReady(workers, &main_port, 10_000));
    const payload = "cross-thread wake drain payload";
    try echoOnce(workers[0].bound, payload);
    try echo.Worker.shutdownAll(workers, &main_port);
    try std.testing.expectEqual(@as(usize, 1), workers[0].final_accepted);
    try std.testing.expectEqual(payload.len, workers[0].final_echoed);
}

test "example smoke: SIGTERM drains a watching worker" {
    // Windows signals are console control events; a CI service has no
    // console, and raising one in-process would end the test runner.
    if (is_windows) return error.SkipZigTest;
    try born.blockSignals(&.{ .terminate, .interrupt });
    var main_port = try born.EvPort.init(alloc);
    defer main_port.deinit();
    const workers = try alloc.alloc(echo.Worker, 1);
    defer alloc.free(workers);
    workers[0] = .{
        .alloc = alloc,
        .notify = &main_port,
        .addr = try Address.parseIp4("127.0.0.1", 0),
        .reuse = .none,
        .opts = .{ .watch_signals = true },
    };
    try workers[0].spawn();
    try std.testing.expectEqual(echo.Startup.ready, try echo.waitReady(workers, &main_port, 10_000));
    const payload = "signal drain payload";
    try echoOnce(workers[0].bound, payload);
    try std.posix.raise(std.posix.SIG.TERM);
    try echo.Worker.shutdownAll(workers, &main_port);
    try std.testing.expectEqual(@as(usize, 1), workers[0].final_accepted);
    try std.testing.expectEqual(payload.len, workers[0].final_echoed);
}

test "example smoke: balanced listeners spread and drain" {
    switch (builtin.os.tag) {
        .freebsd, .linux => {},
        else => return error.SkipZigTest, // .balanced needs kernel load balancing
    }
    try born.blockSignals(&.{ .terminate, .interrupt });
    var main_port = try born.EvPort.init(alloc);
    defer main_port.deinit();
    const workers = try alloc.alloc(echo.Worker, 2);
    defer alloc.free(workers);
    workers[0] = .{
        .alloc = alloc,
        .notify = &main_port,
        .addr = try Address.parseIp4("127.0.0.1", 0),
        .reuse = .balanced,
    };
    try workers[0].spawn();
    try std.testing.expectEqual(echo.Startup.ready, try echo.waitReady(workers[0..1], &main_port, 10_000));
    workers[1] = .{
        .alloc = alloc,
        .notify = &main_port,
        .addr = workers[0].bound,
        .reuse = .balanced,
    };
    try workers[1].spawn();
    try std.testing.expectEqual(echo.Startup.ready, try echo.waitReady(workers, &main_port, 10_000));

    const payload = "balanced echo 0123456789";
    const rounds = 128;
    for (0..rounds) |_| try echoOnce(workers[0].bound, payload);
    try echo.Worker.shutdownAll(workers, &main_port);
    try std.testing.expectEqual(rounds, workers[0].final_accepted + workers[1].final_accepted);
    try std.testing.expect(workers[0].final_accepted > 0 and workers[1].final_accepted > 0);
    try std.testing.expectEqual(rounds * payload.len, workers[0].final_echoed + workers[1].final_echoed);
}
