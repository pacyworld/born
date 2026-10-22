//! Listening stream sockets on Windows (AcceptEx). Owned by born#19 (TCP:
//! openTcp, register, acceptNb, absorbCompletion, pendingOps, localAddress,
//! close) apart from `openUnix` and the `unix` field, which belong to
//! born#21 in unix_windows.zig.
//!
//! Model: `register` associates the listening socket with the port and
//! posts `ListenOptions.accept_depth` AcceptEx operations, each with its own
//! pre-created accept socket, address buffer and OVERLAPPED. The slots live
//! in one heap block owned by the Listener, so the Listener value itself
//! may move. Feed each listener completion to `absorbCompletion`, then call
//! `acceptNb` until `.want_accept`: it hands over completed sockets as
//! `PlainNb` streams and re-posts their AcceptEx.
//!
//! Teardown: `close` cancels outstanding accepts (CancelIoEx) and closes;
//! keep absorbing until `pendingOps() == 0`, which frees the slots and
//! releases WSAStartup (the PlainNb rule). `.balanced` is
//! error.Unsupported: Windows has no kernel-balanced port sharing.
//!
//! Failures: a completion whose peer is already gone (the NTSTATUS values
//! behind ERROR_NETNAME_DELETED, and connection aborted) re-posts that
//! slot silently. Any other failed completion is returned once by the next
//! `acceptNb`, which re-posts the slot. A re-post that fails leaves the
//! slot idle and every later `acceptNb` retries it and reports the error
//! (error.ResourceExhausted for WSAEMFILE/WSAENOBUFS). No completion arrives
//! for an idle slot. Resume as on POSIX: after closing connections call
//! `register` again with the same port and udata (it re-posts the idle
//! slots), then `acceptNb` until `.want_accept`. `unmonitorRead` is a
//! no-op on IOCP, so the pause step needs no special case.
//!
//! An AF_UNIX listener (born#21) is the same machinery: bind and listen
//! its socket, then `adoptListening` with its family and protocol.

const std = @import("std");
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const kernel32 = windows.kernel32;
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const unix_windows = @import("unix_windows.zig");
const PlainNb = @import("socket_windows.zig").PlainNb;

/// `~SO_REUSEADDR`; std has no constant for it.
const SO_EXCLUSIVEADDRUSE: i32 = ~@as(i32, ws2.SO.REUSEADDR);
const IPPROTO_IPV6: i32 = 41;

const AcceptExFn = *const fn (
    listen_socket: ws2.SOCKET,
    accept_socket: ws2.SOCKET,
    output_buffer: *anyopaque,
    receive_data_length: u32,
    local_address_length: u32,
    remote_address_length: u32,
    bytes_received: *u32,
    overlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

// WSAID_ACCEPTEX
const WSAID_ACCEPTEX: windows.GUID = .{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

/// AcceptEx room per address: the largest sockaddr plus the 16 bytes it
/// requires, so AF_UNIX fits too.
const addr_room: u32 = @sizeOf(ws2.sockaddr.storage) + 16;

/// One outstanding AcceptEx. `ov` and `addrs` stay in place while pending.
const Slot = struct {
    ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    /// The accept socket: posted, completed, or INVALID_SOCKET when idle.
    sock: ws2.SOCKET = ws2.INVALID_SOCKET,
    state: State = .idle,
    /// The error `acceptNb` returns for a `.failed` slot.
    fail: io.AcceptError = io.AcceptError.SocketError,
    addrs: [2 * addr_room]u8 = undefined,

    const State = enum { idle, pending, ready, failed };

    fn closeSocket(slot: *Slot) void {
        if (slot.sock != ws2.INVALID_SOCKET) _ = ws2.closesocket(slot.sock);
        slot.sock = ws2.INVALID_SOCKET;
    }
};

pub const Listener = struct {
    sock: ws2.SOCKET = ws2.INVALID_SOCKET,
    /// Unix-socket state (e.g. the bound path), owned by unix_windows.zig.
    unix: unix_windows.ListenerState = .{},
    /// Holds one WSAStartup reference until closed and drained.
    wsa_started: bool = false,
    /// Address family and protocol for the accept sockets.
    family: i32 = 0,
    protocol: i32 = 0,
    accept_ex: ?AcceptExFn = null,
    /// Accept slots, freed with `alloc` once closed and drained.
    slots: []Slot = &.{},
    alloc: ?std.mem.Allocator = null,
    /// The port from `register`; accepted streams are associated with it.
    evp: ?*evport.EvPort = null,
    /// The completion key from `register`; a resume must repeat it.
    udata: ?*anyopaque = null,

    /// TCP listener on `addr` (port 0 picks one; see `localAddress`) with
    /// SO_EXCLUSIVEADDRUSE. A backlog of 200 or more is requested exactly
    /// (SOMAXCONN_HINT); smaller values are passed as given.
    pub fn openTcp(alloc: std.mem.Allocator, addr: std.net.Address, opts: io.ListenOptions) io.ListenError!Listener {
        if (opts.reuse_port == .balanced) return io.ListenError.Unsupported;
        const family: i32 = addr.any.family;
        if (family != ws2.AF.INET and family != ws2.AF.INET6) return io.ListenError.SocketError;

        var wsa: ws2.WSADATA = undefined;
        if (ws2.WSAStartup(0x0202, &wsa) != 0) return io.ListenError.SocketError;
        const s = ws2.WSASocketW(family, ws2.SOCK.STREAM, ws2.IPPROTO.TCP, null, 0, ws2.WSA_FLAG_OVERLAPPED | ws2.WSA_FLAG_NO_HANDLE_INHERIT);
        if (s == ws2.INVALID_SOCKET) {
            const e = ws2.WSAGetLastError();
            _ = ws2.WSACleanup();
            return if (e == .WSAEACCES) io.ListenError.AccessDenied else io.ListenError.SocketError;
        }
        bindAndListen(s, addr, opts) catch |err| {
            _ = ws2.closesocket(s);
            _ = ws2.WSACleanup();
            return err;
        };
        return adoptListening(alloc, s, family, ws2.IPPROTO.TCP, opts.accept_depth);
    }

    /// Unix stream listener at `path`; see unix_windows.zig.
    pub fn openUnix(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
        return unix_windows.listen(alloc, path, opts);
    }

    /// Wrap a bound, listening overlapped socket `s` (`family`, `protocol`
    /// for its accept sockets): load AcceptEx and allocate `depth` slots
    /// (at least 1). Takes ownership of `s` and of the caller's WSAStartup
    /// reference; on failure both are released.
    pub fn adoptListening(alloc: std.mem.Allocator, s: ws2.SOCKET, family: i32, protocol: i32, depth: u16) io.ListenError!Listener {
        var self: Listener = .{ .sock = s, .wsa_started = true, .family = family, .protocol = protocol };
        errdefer self.close();
        self.accept_ex = acceptEx(s) catch return io.ListenError.SocketError;
        self.slots = alloc.alloc(Slot, @max(depth, 1)) catch return io.ListenError.OutOfMemory;
        self.alloc = alloc;
        for (self.slots) |*slot| slot.* = .{};
        return self;
    }

    /// Associate with the port under `udata` (every listener completion
    /// carries it) and post the AcceptEx operations. On failure, `close`
    /// and drain as usual.
    ///
    /// Called again with the same port and udata, it resumes (the POSIX
    /// pause/resume sequence): idle slots are re-posted and the rest are
    /// left alone. A re-post that fails here leaves its slot idle for the
    /// `acceptNb` drain that must follow, which reports the precise error.
    /// Another port or udata is error.SocketError: the completion key is
    /// fixed when the socket is associated.
    pub fn register(self: *Listener, evp: *evport.EvPort, udata: ?*anyopaque) io.ListenerRegisterError!void {
        if (self.sock == ws2.INVALID_SOCKET) return io.ListenerRegisterError.SocketError;
        if (self.evp) |registered| {
            if (registered != evp or self.udata != udata) return io.ListenerRegisterError.SocketError;
            for (self.slots) |*slot| {
                if (slot.state == .idle) self.post(slot) catch {}; // reported by acceptNb
            }
            return;
        }
        evp.associate(self.handle(), udata) catch return io.ListenerRegisterError.SocketError;
        self.evp = evp;
        self.udata = udata;
        for (self.slots) |*slot| self.post(slot) catch return io.ListenerRegisterError.SocketError;
    }

    /// Adopt one completed accept into `out` (constructed in place),
    /// associate it with the registered port under `key`, and re-post its
    /// AcceptEx; or report `.want_accept`. Completed sockets come first,
    /// then a failed completion's error, then a retry of any idle slot.
    /// error.SocketError before `register`.
    ///
    /// The peer address is `getpeername(out.handle())`.
    pub fn acceptNb(self: *Listener, out: *PlainNb, key: ?*anyopaque) io.AcceptError!io.AcceptResult {
        if (self.sock == ws2.INVALID_SOCKET or self.evp == null) return io.AcceptError.SocketError;
        for (self.slots) |*slot| {
            if (slot.state != .ready) continue;
            const accepted: types.Handle = @ptrCast(slot.sock);
            slot.sock = ws2.INVALID_SOCKET;
            slot.state = .idle;
            const adopted = out.adoptAccepted(accepted, self.evp, key);
            // A failed re-post leaves the slot idle; the next call reports it.
            self.post(slot) catch {};
            try adopted;
            return .accepted;
        }
        for (self.slots) |*slot| {
            if (slot.state != .failed) continue;
            slot.state = .idle;
            self.post(slot) catch {}; // as above
            return slot.fail;
        }
        for (self.slots) |*slot| {
            if (slot.state == .idle) try self.post(slot);
        }
        return .want_accept;
    }

    /// Match a completion to one outstanding AcceptEx (`.accept`), or
    /// `.unknown`. Call `acceptNb` afterwards; after `close` this only
    /// drains.
    pub fn absorbCompletion(self: *Listener, ov: ?*windows.OVERLAPPED, bytes: usize, err: ?usize) io.ListenerCompletion {
        _ = bytes; // AcceptEx posts with no receive buffer
        const o = ov orelse return .unknown;
        const slot = for (self.slots) |*s| {
            if (&s.ov == o and s.state == .pending) break s;
        } else return .unknown;
        defer self.releaseIfDrained();

        if (self.sock == ws2.INVALID_SOCKET) {
            slot.closeSocket();
            slot.state = .idle;
            return .accept;
        }
        if (err) |status| {
            slot.closeSocket();
            slot.state = .idle;
            if (peerGone(status)) {
                // A failed re-post leaves the slot idle; acceptNb reports it.
                self.post(slot) catch {};
            } else {
                slot.state = .failed;
                slot.fail = completionError(status);
            }
            return .accept;
        }
        const listen_sock = std.mem.asBytes(&self.sock);
        if (ws2.setsockopt(slot.sock, ws2.SOL.SOCKET, ws2.SO.UPDATE_ACCEPT_CONTEXT, listen_sock.ptr, @intCast(listen_sock.len)) != 0) {
            slot.closeSocket();
            slot.state = .failed;
            slot.fail = io.AcceptError.SocketError;
            return .accept;
        }
        slot.state = .ready;
        return .accept;
    }

    /// Outstanding AcceptEx operations; free the Listener only at 0.
    pub fn pendingOps(self: *const Listener) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot.state == .pending) n += 1;
        }
        return n;
    }

    /// The bound address (the chosen port after binding to port 0, or the
    /// path of a Unix listener).
    pub fn localAddress(self: *const Listener) io.LocalAddressError!std.net.Address {
        if (self.sock == ws2.INVALID_SOCKET) return io.LocalAddressError.SocketError;
        var ss: ws2.sockaddr.storage = undefined;
        var len: i32 = @sizeOf(ws2.sockaddr.storage);
        if (ws2.getsockname(self.sock, @ptrCast(&ss), &len) != 0) return io.LocalAddressError.SocketError;
        switch (ss.family) {
            ws2.AF.INET, ws2.AF.INET6 => return std.net.Address.initPosix(@ptrCast(&ss)),
            ws2.AF.UNIX => {
                if (comptime std.net.has_unix_sockets) {
                    // getsockname may omit the path's NUL; zero-fill so it stays terminated.
                    var un = std.mem.zeroes(ws2.sockaddr.un);
                    const n = @min(@as(usize, @intCast(len)), @sizeOf(ws2.sockaddr.un));
                    @memcpy(std.mem.asBytes(&un)[0..n], std.mem.asBytes(&ss)[0..n]);
                    return .{ .un = un };
                }
                return io.LocalAddressError.SocketError; // target predates AF_UNIX (Windows 10 1803)
            },
            else => return io.LocalAddressError.SocketError,
        }
    }

    pub fn handle(self: *const Listener) types.Handle {
        return @ptrCast(self.sock);
    }

    /// Cancels outstanding accepts, closes the socket and drops completed
    /// accepts not yet handed over. Pending completions still arrive and
    /// must be absorbed until `pendingOps() == 0`.
    pub fn close(self: *Listener) void {
        self.unix.deinit();
        if (self.sock != ws2.INVALID_SOCKET) {
            _ = kernel32.CancelIoEx(self.handle(), null);
            _ = ws2.closesocket(self.sock);
            self.sock = ws2.INVALID_SOCKET;
        }
        for (self.slots) |*slot| {
            if (slot.state == .pending) continue; // closed when its completion is absorbed
            slot.closeSocket();
            slot.state = .idle;
        }
        self.releaseIfDrained();
    }

    /// Post AcceptEx on an idle slot with a fresh accept socket. Even an
    /// inline success queues a completion, so the slot is pending either way.
    fn post(self: *Listener, slot: *Slot) io.AcceptError!void {
        std.debug.assert(slot.state == .idle and slot.sock == ws2.INVALID_SOCKET);
        while (true) {
            const a = ws2.WSASocketW(self.family, ws2.SOCK.STREAM, self.protocol, null, 0, ws2.WSA_FLAG_OVERLAPPED | ws2.WSA_FLAG_NO_HANDLE_INHERIT);
            if (a == ws2.INVALID_SOCKET) return wsaError(ws2.WSAGetLastError());
            slot.ov = std.mem.zeroes(windows.OVERLAPPED);
            var received: u32 = 0;
            const ok = self.accept_ex.?(self.sock, a, &slot.addrs, 0, addr_room, addr_room, &received, &slot.ov);
            const e = if (ok != 0) ws2.WinsockError.WSA_IO_PENDING else ws2.WSAGetLastError();
            if (e == .WSA_IO_PENDING) {
                slot.sock = a;
                slot.state = .pending;
                return;
            }
            _ = ws2.closesocket(a);
            // The peer left before AcceptEx took it: bounded by the backlog.
            if (e == .WSAECONNRESET) continue;
            return wsaError(e);
        }
    }

    /// Once closed with nothing pending: free the slots, release WSAStartup.
    fn releaseIfDrained(self: *Listener) void {
        if (self.sock != ws2.INVALID_SOCKET or self.pendingOps() != 0) return;
        if (self.alloc) |a| a.free(self.slots);
        self.slots = &.{};
        self.alloc = null;
        self.evp = null;
        self.udata = null;
        if (self.wsa_started) {
            _ = ws2.WSACleanup();
            self.wsa_started = false;
        }
    }
};

fn bindAndListen(s: ws2.SOCKET, addr: std.net.Address, opts: io.ListenOptions) io.ListenError!void {
    try setInt(s, ws2.SOL.SOCKET, SO_EXCLUSIVEADDRUSE, 1);
    if (addr.any.family == ws2.AF.INET6) try setInt(s, IPPROTO_IPV6, ws2.IPV6_V6ONLY, @intFromBool(opts.v6_only));
    if (ws2.bind(s, &addr.any, @intCast(addr.getOsSockLen())) != 0) return switch (ws2.WSAGetLastError()) {
        .WSAEADDRINUSE => io.ListenError.AddressInUse,
        .WSAEACCES => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
    // SOMAXCONN_HINT(n) is -n: Windows otherwise caps a plain backlog at 200.
    const backlog: i32 = if (opts.backlog >= 200) -@as(i32, opts.backlog) else opts.backlog;
    if (ws2.listen(s, backlog) != 0) return switch (ws2.WSAGetLastError()) {
        .WSAEADDRINUSE => io.ListenError.AddressInUse,
        else => io.ListenError.SocketError,
    };
}

/// Integer socket option; any refusal is error.SocketError.
fn setInt(s: ws2.SOCKET, level: i32, opt: i32, value: i32) io.ListenError!void {
    const v = std.mem.asBytes(&value);
    if (ws2.setsockopt(s, level, opt, v.ptr, @intCast(v.len)) != 0) return io.ListenError.SocketError;
}

fn acceptEx(s: ws2.SOCKET) error{SocketError}!AcceptExFn {
    var fn_ptr: ?AcceptExFn = null;
    var ret: u32 = 0;
    const rc = ws2.WSAIoctl(s, ws2.SIO_GET_EXTENSION_FUNCTION_POINTER, &WSAID_ACCEPTEX, @sizeOf(windows.GUID), @ptrCast(&fn_ptr), @sizeOf(?AcceptExFn), &ret, null, null);
    if (rc != 0 or fn_ptr == null) return error.SocketError;
    return fn_ptr.?;
}

fn wsaError(e: ws2.WinsockError) io.AcceptError {
    return switch (e) {
        .WSAEMFILE, .WSAENOBUFS => io.AcceptError.ResourceExhausted,
        else => io.AcceptError.SocketError,
    };
}

/// NTSTATUS of an AcceptEx whose connection died before it completed.
fn peerGone(status: usize) bool {
    return switch (status) {
        @intFromEnum(windows.NTSTATUS.CONNECTION_RESET),
        @intFromEnum(windows.NTSTATUS.LOCAL_DISCONNECT),
        @intFromEnum(windows.NTSTATUS.REMOTE_DISCONNECT),
        @intFromEnum(windows.NTSTATUS.CONNECTION_ABORTED),
        => true,
        else => false,
    };
}

fn completionError(status: usize) io.AcceptError {
    return switch (status) {
        @intFromEnum(windows.NTSTATUS.INSUFFICIENT_RESOURCES),
        @intFromEnum(windows.NTSTATUS.NO_MEMORY),
        => io.AcceptError.ResourceExhausted,
        else => io.AcceptError.SocketError,
    };
}

// Completion paths the contract tests cannot provoke on demand: the real
// AcceptEx is cancelled and its completion is absorbed with another status.

/// The next completion for `l`. One per wait, so none is dropped.
fn waitFor(port: *evport.EvPort, l: *Listener) !evport.Event {
    var events: [1]evport.Event = undefined;
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

fn drain(port: *evport.EvPort, l: *Listener) !void {
    l.close();
    while (l.pendingOps() != 0) {
        const ev = try waitFor(port, l);
        _ = l.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
    }
}

fn expectCompletionOutcome(status: windows.NTSTATUS, want: ?io.AcceptError) !void {
    const testing = std.testing;
    var wsa: ws2.WSADATA = undefined;
    try testing.expectEqual(@as(i32, 0), ws2.WSAStartup(0x0202, &wsa));
    defer _ = ws2.WSACleanup();
    var port = try evport.EvPort.init(testing.allocator);
    defer port.deinit();
    var l = try Listener.openTcp(testing.allocator, try std.net.Address.parseIp4("127.0.0.1", 0), .{ .accept_depth = 1 });
    try l.register(&port, &l);
    const slot = &l.slots[0];
    try testing.expect(kernel32.CancelIoEx(l.handle(), &slot.ov) != 0);
    const cancelled = try waitFor(&port, &l);
    try testing.expect(cancelled.overlapped == &slot.ov);
    try testing.expectEqual(io.ListenerCompletion.accept, l.absorbCompletion(cancelled.overlapped, cancelled.bytes, @intFromEnum(status)));

    var out: PlainNb = .{};
    if (want) |e| {
        try testing.expectEqual(@as(usize, 0), l.pendingOps());
        try testing.expectError(e, l.acceptNb(&out, &out));
    } else {
        try testing.expectEqual(@as(usize, 1), l.pendingOps());
    }
    // Re-posted either way: nothing more to report, and the next
    // connection is accepted.
    try testing.expectEqual(io.AcceptResult.want_accept, try l.acceptNb(&out, &out));
    try testing.expectEqual(@as(usize, 1), l.pendingOps());
    var client = try std.net.tcpConnectToAddress(try l.localAddress());
    defer client.close();
    const ev = try waitFor(&port, &l);
    try testing.expectEqual(io.ListenerCompletion.accept, l.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null));
    try testing.expectEqual(io.AcceptResult.accepted, try l.acceptNb(&out, &out));
    out.cancelAndClose();
    try drain(&port, &l);
}

test "listener_windows: a peer-gone completion re-posts its accept silently" {
    try expectCompletionOutcome(.CONNECTION_RESET, null);
    try expectCompletionOutcome(.REMOTE_DISCONNECT, null);
    try expectCompletionOutcome(.CONNECTION_ABORTED, null);
}

test "listener_windows: other failed completions surface once from acceptNb" {
    try expectCompletionOutcome(.INSUFFICIENT_RESOURCES, io.AcceptError.ResourceExhausted);
    try expectCompletionOutcome(.CANCELLED, io.AcceptError.SocketError);
}

test "listener_windows: register on the same port re-posts idle slots" {
    const testing = std.testing;
    var wsa: ws2.WSADATA = undefined;
    try testing.expectEqual(@as(i32, 0), ws2.WSAStartup(0x0202, &wsa));
    defer _ = ws2.WSACleanup();
    var port = try evport.EvPort.init(testing.allocator);
    defer port.deinit();
    var other = try evport.EvPort.init(testing.allocator);
    defer other.deinit();
    const depth = 2;
    var l = try Listener.openTcp(testing.allocator, try std.net.Address.parseIp4("127.0.0.1", 0), .{ .accept_depth = depth });
    try l.register(&port, &l);

    // Resuming with nothing idle posts nothing more.
    try l.register(&port, &l);
    try testing.expectEqual(@as(usize, depth), l.pendingOps());

    // Leave slot 0 as a failed re-post leaves it: its AcceptEx completed
    // (cancelled here) and no new one is outstanding.
    const slot = &l.slots[0];
    try testing.expect(kernel32.CancelIoEx(l.handle(), &slot.ov) != 0);
    const cancelled = try waitFor(&port, &l);
    try testing.expect(cancelled.overlapped == &slot.ov);
    slot.closeSocket();
    slot.state = .idle;
    try testing.expectEqual(@as(usize, depth - 1), l.pendingOps());

    // Another port or completion key is refused and changes nothing.
    try testing.expectError(io.ListenerRegisterError.SocketError, l.register(&other, &l));
    try testing.expectError(io.ListenerRegisterError.SocketError, l.register(&port, &other));
    try testing.expectEqual(@as(usize, depth - 1), l.pendingOps());

    // The POSIX resume sequence: pause (a no-op here), register, drain.
    port.unmonitorRead(l.handle());
    try l.register(&port, &l);
    try testing.expectEqual(@as(usize, depth), l.pendingOps());
    var out: PlainNb = .{};
    try testing.expectEqual(io.AcceptResult.want_accept, try l.acceptNb(&out, &out));

    // Every slot accepts again.
    var clients: [depth]std.net.Stream = undefined;
    for (&clients) |*c| c.* = try std.net.tcpConnectToAddress(try l.localAddress());
    defer for (&clients) |*c| c.close();
    var streams = [_]PlainNb{.{}} ** depth;
    var accepted: usize = 0;
    while (accepted < depth) {
        const ev = try waitFor(&port, &l);
        _ = l.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
        while (accepted < depth) {
            const s = &streams[accepted];
            switch (try l.acceptNb(s, s)) {
                .accepted => accepted += 1,
                .want_accept => break,
            }
        }
    }
    for (&streams) |*s| s.cancelAndClose();
    try drain(&port, &l);
}
