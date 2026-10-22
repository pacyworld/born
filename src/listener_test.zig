//! TCP listener contract (born 0.3.0). Every test calls the real API and
//! skips while the backend returns error.Unsupported; a listener
//! implementation issue is done when these run and pass on its OS.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("root.zig");
const socket = born.socket;
const Listener = socket.Listener;
const PlainNb = socket.PlainNb;
const alloc = std.testing.allocator;
const is_windows = builtin.os.tag == .windows;

fn openOrSkip(addr: std.net.Address, opts: socket.ListenOptions) !Listener {
    return Listener.openTcp(alloc, addr, opts) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

fn wsaStart() !void {
    if (!is_windows) return;
    var wsa: std.os.windows.ws2_32.WSADATA = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.os.windows.ws2_32.WSAStartup(0x0202, &wsa));
}

fn wsaStop() void {
    if (is_windows) _ = std.os.windows.ws2_32.WSACleanup();
}

/// Accepts into `streams` as listener events arrive: absorb, then drain
/// until `.want_accept`, the edge-triggered contract.
const Acceptor = struct {
    listener: *Listener,
    streams: []PlainNb,
    count: usize = 0,

    fn onEvent(self: *Acceptor, ev: born.Event) !bool {
        if (ev.udata != @as(?*anyopaque, self.listener)) return false;
        _ = self.listener.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
        while (self.count < self.streams.len) {
            const slot = &self.streams[self.count];
            switch (try self.listener.acceptNb(slot, slot)) {
                .accepted => self.count += 1,
                .want_accept => break,
            }
        }
        return true;
    }

    fn deinit(self: *Acceptor) void {
        for (self.streams[0..self.count]) |*s| s.cancelAndClose();
    }
};

fn pump(port: *born.EvPort, acceptors: []const *Acceptor, total: usize, window_ms: u64) !void {
    var events: [32]born.Event = undefined;
    var timer = try std.time.Timer.start();
    while (true) {
        var have: usize = 0;
        for (acceptors) |a| have += a.count;
        if (have >= total) return;
        const elapsed = timer.read() / std.time.ns_per_ms;
        if (elapsed >= window_ms) return error.ListenerAcceptTimeout;
        const n = try port.wait(&events, @intCast(window_ms - elapsed));
        for (events[0..n]) |ev| {
            for (acceptors) |a| {
                if (try a.onEvent(ev)) break;
            }
        }
    }
}

/// Close `l` and absorb its completions until no operation is pending.
fn closeListener(port: *born.EvPort, l: *Listener) !void {
    port.purgeFd(l.handle());
    l.close();
    var events: [8]born.Event = undefined;
    var spins: usize = 0;
    while (l.pendingOps() != 0) : (spins += 1) {
        if (spins > 100) return error.ListenerDrainTimeout;
        const n = try port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.udata == @as(?*anyopaque, l))
                _ = l.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
        }
    }
}

fn connectClients(clients: []std.net.Stream, addr: std.net.Address) !void {
    for (clients) |*c| c.* = try std.net.tcpConnectToAddress(addr);
}

test "listener: API shape is the same on every target" {
    const T = Listener;
    try std.testing.expect(@TypeOf(T.openTcp) == fn (std.mem.Allocator, std.net.Address, socket.ListenOptions) socket.ListenError!T);
    try std.testing.expect(@TypeOf(T.openUnix) == fn (std.mem.Allocator, []const u8, socket.UnixOptions) socket.ListenError!T);
    try std.testing.expect(@TypeOf(T.register) == fn (*T, *born.EvPort, ?*anyopaque) socket.ListenerRegisterError!void);
    try std.testing.expect(@TypeOf(T.acceptNb) == fn (*T, *PlainNb, ?*anyopaque) socket.AcceptError!socket.AcceptResult);
    try std.testing.expect(@TypeOf(T.absorbCompletion) == fn (*T, ?*std.os.windows.OVERLAPPED, usize, ?usize) socket.ListenerCompletion);
    try std.testing.expect(@TypeOf(T.pendingOps) == fn (*const T) usize);
    try std.testing.expect(@TypeOf(T.localAddress) == fn (*const T) socket.LocalAddressError!std.net.Address);
    try std.testing.expect(@TypeOf(T.handle) == fn (*const T) born.Handle);
    try std.testing.expect(@TypeOf(T.close) == fn (*T) void);
    const opts: socket.ListenOptions = .{};
    try std.testing.expectEqual(@as(u31, 511), opts.backlog);
    try std.testing.expectEqual(socket.ReusePort.none, opts.reuse_port);
    try std.testing.expect(opts.v6_only);
    // A never-opened listener refuses instead of acting on a dead handle.
    var closed: Listener = .{};
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    try std.testing.expectError(error.SocketError, closed.register(&port, null));
    try std.testing.expectError(error.SocketError, closed.localAddress());
    try std.testing.expectEqual(@as(usize, 0), closed.pendingOps());
    try std.testing.expectEqual(socket.ListenerCompletion.unknown, closed.absorbCompletion(null, 0, null));
    closed.close();
}

test "listener: one edge drains a queued backlog" {
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var l = try openOrSkip(try std.net.Address.parseIp4("127.0.0.1", 0), .{});
    try l.register(&port, &l);
    const addr = try l.localAddress();
    try std.testing.expect(addr.getPort() != 0);

    const n = 64;
    const streams = try alloc.alloc(PlainNb, n);
    defer alloc.free(streams);
    for (streams) |*s| s.* = .{};
    var acceptor: Acceptor = .{ .listener = &l, .streams = streams };
    defer acceptor.deinit();
    var clients: [n]std.net.Stream = undefined;
    // Every connection is queued before the first wait().
    try connectClients(&clients, addr);
    defer for (&clients) |*c| c.close();

    try pump(&port, &.{&acceptor}, n, 5000);
    try std.testing.expectEqual(@as(usize, n), acceptor.count);
    try closeListener(&port, &l);
}

test "listener: .balanced spreads connections over two listeners" {
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var first = try openOrSkip(try std.net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_port = .balanced });
    const addr = try first.localAddress();
    var second = try Listener.openTcp(alloc, addr, .{ .reuse_port = .balanced });
    try first.register(&port, &first);
    try second.register(&port, &second);

    const n = 200;
    const streams = try alloc.alloc(PlainNb, 2 * n);
    defer alloc.free(streams);
    for (streams) |*s| s.* = .{};
    var a: Acceptor = .{ .listener = &first, .streams = streams[0..n] };
    defer a.deinit();
    var b: Acceptor = .{ .listener = &second, .streams = streams[n..] };
    defer b.deinit();
    const clients = try alloc.alloc(std.net.Stream, n);
    defer alloc.free(clients);
    try connectClients(clients, addr);
    defer for (clients) |*c| c.close();

    try pump(&port, &.{ &a, &b }, n, 10000);
    try std.testing.expectEqual(@as(usize, n), a.count + b.count);
    try std.testing.expect(a.count > 0 and b.count > 0);
    try closeListener(&port, &first);
    try closeListener(&port, &second);
}

test "listener: .balanced is Unsupported where the kernel cannot balance" {
    switch (builtin.os.tag) {
        .macos, .netbsd, .openbsd, .windows => {},
        else => return error.SkipZigTest, // FreeBSD and Linux balance
    }
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const any = try std.net.Address.parseIp4("127.0.0.1", 0);
    var l = try openOrSkip(any, .{});
    try closeListener(&port, &l);
    try std.testing.expectError(error.Unsupported, Listener.openTcp(alloc, any, .{ .reuse_port = .balanced }));
}

test "listener: close with accepts outstanding drains cleanly, 1000 times" {
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const loopback = try std.net.Address.parseIp4("127.0.0.1", 0);
    const depth: usize = if (is_windows) (socket.ListenOptions{}).accept_depth else 0;
    for (0..1000) |_| {
        var l = try openOrSkip(loopback, .{});
        try l.register(&port, &l);
        try std.testing.expectEqual(depth, l.pendingOps());
        try closeListener(&port, &l);
    }
    // No completion outlived its listener.
    var events: [8]born.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "listener: close drops completed connections that were never accepted" {
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var l = try openOrSkip(try std.net.Address.parseIp4("127.0.0.1", 0), .{});
    try l.register(&port, &l);
    var clients: [2]std.net.Stream = undefined;
    try connectClients(&clients, try l.localAddress());
    defer for (&clients) |*c| c.close();
    // Absorb every listener event of the batch, but accept none.
    var events: [8]born.Event = undefined;
    var absorbed: usize = 0;
    var spins: usize = 0;
    while (absorbed == 0) : (spins += 1) {
        if (spins > 50) return error.ListenerEventTimeout;
        const n = try port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.udata != @as(?*anyopaque, &l)) continue;
            _ = l.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
            absorbed += 1;
        }
    }
    try closeListener(&port, &l);
}

test {
    // Windows-only completion paths (listener_windows.zig).
    if (is_windows) _ = @import("listener_windows.zig");
}

/// A born handle as a socket for std.posix calls (a HANDLE on Windows).
fn socketOf(h: born.Handle) std.posix.socket_t {
    return if (is_windows) @ptrCast(h) else h;
}

/// The next event for `l`, within five seconds.
fn waitFor(port: *born.EvPort, l: *Listener) !born.Event {
    var events: [8]born.Event = undefined;
    var timer = try std.time.Timer.start();
    while (true) {
        const elapsed = timer.read() / std.time.ns_per_ms;
        if (elapsed >= 5000) return error.ListenerEventTimeout;
        const n = try port.wait(&events, @intCast(5000 - elapsed));
        for (events[0..n]) |ev| {
            if (ev.udata == @as(?*anyopaque, l)) return ev;
        }
    }
}

test "listener: pause with unmonitorRead, resume with register and drain" {
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var l = try openOrSkip(try std.net.Address.parseIp4("127.0.0.1", 0), .{});
    try l.register(&port, &l);
    port.unmonitorRead(l.handle());

    const n = 4;
    var streams = [_]PlainNb{.{}} ** n;
    var acceptor: Acceptor = .{ .listener = &l, .streams = &streams };
    defer acceptor.deinit();
    var clients: [n]std.net.Stream = undefined;
    try connectClients(&clients, try l.localAddress());
    defer for (&clients) |*c| c.close();

    // Resume: register again, then drain at once, since connections
    // already queued produce no new edge on POSIX.
    try l.register(&port, &l);
    try std.testing.expect(try acceptor.onEvent(.{ .udata = &l }));
    try pump(&port, &.{&acceptor}, n, 5000);
    try std.testing.expectEqual(@as(usize, n), acceptor.count);
    try closeListener(&port, &l);
}

test "listener: an accepted stream reports its peer address" {
    try wsaStart();
    defer wsaStop();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var l = try openOrSkip(try std.net.Address.parseIp4("127.0.0.1", 0), .{});
    try l.register(&port, &l);
    var streams = [_]PlainNb{.{}};
    var acceptor: Acceptor = .{ .listener = &l, .streams = &streams };
    defer acceptor.deinit();
    var client = try std.net.tcpConnectToAddress(try l.localAddress());
    defer client.close();

    try pump(&port, &.{&acceptor}, 1, 5000);
    var peer: std.posix.sockaddr.storage = undefined;
    var peer_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getpeername(socketOf(streams[0].handle()), @ptrCast(&peer), &peer_len);
    var local: std.posix.sockaddr.storage = undefined;
    var local_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(client.handle, @ptrCast(&local), &local_len);
    try std.testing.expect(std.net.Address.initPosix(@ptrCast(&peer)).eql(std.net.Address.initPosix(@ptrCast(&local))));
    try closeListener(&port, &l);
}

test "listener: descriptor exhaustion is ResourceExhausted and the drain resumes" {
    // RLIMIT_NOFILE is POSIX; AcceptEx creates its sockets ahead of time.
    if (is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var l = try openOrSkip(try std.net.Address.parseIp4("127.0.0.1", 0), .{});
    try l.register(&port, &l);
    const n = 4;
    var streams = [_]PlainNb{.{}} ** n;
    var acceptor: Acceptor = .{ .listener = &l, .streams = &streams };
    defer acceptor.deinit();
    var clients: [n]std.net.Stream = undefined;
    try connectClients(&clients, try l.localAddress());
    defer for (&clients) |*c| c.close();
    const ev = try waitFor(&port, &l);

    // Every descriptor below the lowest free one is open, so a limit equal
    // to it fails the next allocation with EMFILE.
    const saved = try std.posix.getrlimit(.NOFILE);
    const probe = try std.posix.dup(l.handle());
    std.posix.close(probe);
    var low = saved;
    low.cur = @intCast(probe);
    try std.posix.setrlimit(.NOFILE, low);
    const exhausted = acceptor.onEvent(ev);
    try std.posix.setrlimit(.NOFILE, saved);
    try std.testing.expectError(error.ResourceExhausted, exhausted);
    try std.testing.expectEqual(@as(usize, 0), acceptor.count);

    // The connections stayed queued; resuming drains them without a new edge.
    // Darwin's kernel drops the connection whose accept hit the limit.
    try std.testing.expect(try acceptor.onEvent(ev));
    const kept: usize = if (builtin.os.tag.isDarwin()) n - 1 else n;
    try std.testing.expectEqual(kept, acceptor.count);
    try closeListener(&port, &l);
}
