//! Unix domain stream socket contract (born 0.3.0). Every test calls the
//! real API and skips while the backend returns error.Unsupported; a Unix
//! socket implementation issue is done when these run and pass on its OS.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("root.zig");
const socket = born.socket;
const Listener = socket.Listener;
const PlainNb = socket.PlainNb;
const alloc = std.testing.allocator;
const is_windows = builtin.os.tag == .windows;

/// A short unique socket path. POSIX uses /tmp so the path fits sun_path
/// (104 bytes on BSD and macOS) wherever the checkout lives.
const SockPath = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    tmp: ?std.testing.TmpDir = null,

    fn init(self: *SockPath) !void {
        const id = std.crypto.random.int(u64);
        if (is_windows) {
            self.tmp = std.testing.tmpDir(.{});
            const dir = try self.tmp.?.dir.realpath(".", &self.buf);
            self.len = (try std.fmt.bufPrint(self.buf[dir.len..], "\\{x}.sock", .{id})).len + dir.len;
        } else {
            self.len = (try std.fmt.bufPrint(&self.buf, "/tmp/born-ut-{x}.sock", .{id})).len;
        }
    }

    fn get(self: *const SockPath) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *SockPath) void {
        std.fs.deleteFileAbsolute(self.get()) catch {};
        if (self.tmp) |*t| t.cleanup();
    }
};

fn openOrSkip(path: []const u8, opts: socket.UnixOptions) !Listener {
    return Listener.openUnix(alloc, path, opts) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

/// Skip unless openUnix works on this backend.
fn requireUnix() !void {
    var p: SockPath = .{};
    try p.init();
    defer p.deinit();
    var l = try openOrSkip(p.get(), .{});
    l.close();
}

fn wsaStart() !void {
    if (!is_windows) return;
    var wsa: std.os.windows.ws2_32.WSADATA = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.os.windows.ws2_32.WSAStartup(0x0202, &wsa));
}

fn wsaStop() void {
    if (is_windows) _ = std.os.windows.ws2_32.WSACleanup();
}

/// One listener, one client, one accepted peer on one port; stable in
/// place because Windows streams own OVERLAPPED storage.
const Echo = struct {
    port: born.EvPort,
    listener: Listener,
    client: PlainNb = .{},
    peer: PlainNb = .{},
    accepted: bool = false,
    connected: bool = false,

    fn pump(self: *Echo) !void {
        var events: [8]born.Event = undefined;
        const n = try self.port.wait(&events, 2000);
        if (n == 0) return error.UnixEventTimeout;
        for (events[0..n]) |ev| {
            if (ev.udata == @as(?*anyopaque, &self.listener)) {
                _ = self.listener.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null);
                if (!self.accepted and try self.listener.acceptNb(&self.peer, &self.peer) == .accepted) {
                    self.accepted = true;
                    if (!is_windows) self.port.monitorRead(self.peer.handle(), &self.peer);
                }
                continue;
            }
            const stream: *PlainNb = if (ev.udata == @as(?*anyopaque, &self.client)) &self.client else if (ev.udata == @as(?*anyopaque, &self.peer)) &self.peer else return error.TestUnexpectedResult;
            if (is_windows) {
                if (stream.absorbCompletion(ev.overlapped, ev.bytes, if (ev.err) ev.err_no else null) == .connect) self.connected = true;
            } else if (stream == &self.client and !self.connected and (ev.writable or ev.err)) {
                self.port.cancelWrite(self.client.handle());
                self.port.monitorRead(self.client.handle(), &self.client);
                self.connected = true;
            }
        }
    }

    /// Send `data` from `from` and read it all at `to`.
    fn transfer(self: *Echo, from: *PlainNb, to: *PlainNb, data: []const u8, out: []u8) !void {
        var sent: usize = 0;
        var got: usize = 0;
        while (got < data.len) {
            var progress = false;
            if (sent < data.len) switch (try from.writeNb(data[sent..])) {
                .done => |k| {
                    sent += k;
                    progress = k != 0;
                },
                .want_write => if (!is_windows) self.port.wantWrite(from.handle(), from),
                .want_read => return error.TestUnexpectedResult,
            };
            switch (try to.readNb(out[got..data.len])) {
                .data => |k| {
                    got += k;
                    progress = true;
                },
                .want_read => {},
                else => return error.TestUnexpectedResult,
            }
            if (!progress) try self.pump();
        }
        try std.testing.expectEqualSlices(u8, data, out[0..data.len]);
    }

    fn close(self: *Echo) !void {
        for ([_]*PlainNb{ &self.client, &self.peer }) |s| {
            if (is_windows) {
                if (s.sock != std.os.windows.ws2_32.INVALID_SOCKET) self.port.purgeFd(s.handle());
            } else if (s.sock >= 0) self.port.purgeFd(s.handle());
            s.cancelAndClose();
        }
        self.port.purgeFd(self.listener.handle());
        self.listener.close();
        while (self.client.pendingOps() + self.peer.pendingOps() + self.listener.pendingOps() != 0) try self.pump();
        self.client.deinit();
        self.peer.deinit();
    }
};

test "unix: API shape is the same on every target" {
    try std.testing.expect(@TypeOf(PlainNb.startConnectUnixInto) == fn (*PlainNb, std.mem.Allocator, []const u8, *born.EvPort, ?*anyopaque) socket.ConnectUnixError!void);
    const opts: socket.UnixOptions = .{};
    try std.testing.expectEqual(@as(u16, 0o660), opts.mode);
    try std.testing.expect(opts.unlink_stale);
}

test "unix: connect and echo" {
    try wsaStart();
    defer wsaStop();
    var path: SockPath = .{};
    try path.init();
    defer path.deinit();
    const e = try alloc.create(Echo);
    defer alloc.destroy(e);
    e.* = .{ .port = try born.EvPort.init(alloc), .listener = undefined };
    defer e.port.deinit();
    e.listener = try openOrSkip(path.get(), .{});
    try e.listener.register(&e.port, &e.listener);
    try e.client.startConnectUnixInto(alloc, path.get(), &e.port, &e.client);
    if (!is_windows) e.port.wantWrite(e.client.handle(), &e.client);
    while (!e.connected or !e.accepted) try e.pump();
    try e.client.connectDone();

    var buf: [64]u8 = undefined;
    try e.transfer(&e.client, &e.peer, "ping over a unix socket", &buf);
    try e.transfer(&e.peer, &e.client, buf[0..23], buf[32..]);
    try e.close();
}

test "unix: a stale socket file is replaced, a live listener is refused" {
    if (is_windows) return error.SkipZigTest; // POSIX fixture; #21 adds its own
    try requireUnix();
    var path: SockPath = .{};
    try path.init();
    defer path.deinit();

    // Stale: bound once, never listened on, closed without unlinking.
    const raw = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    const addr = try std.net.Address.initUnix(path.get());
    try std.posix.bind(raw, &addr.any, addr.getOsSockLen());
    std.posix.close(raw);

    try std.testing.expectError(error.AddressInUse, Listener.openUnix(alloc, path.get(), .{ .unlink_stale = false }));
    var live = try Listener.openUnix(alloc, path.get(), .{});
    defer live.close();
    // The live listener keeps its path whatever unlink_stale says.
    try std.testing.expectError(error.AddressInUse, Listener.openUnix(alloc, path.get(), .{}));
    _ = try std.posix.fstatat(std.posix.AT.FDCWD, path.get(), 0);
}

test "unix: a non-socket file at the path is refused and kept" {
    if (is_windows) return error.SkipZigTest;
    try requireUnix();
    var path: SockPath = .{};
    try path.init();
    defer path.deinit();
    const f = try std.fs.createFileAbsolute(path.get(), .{});
    f.close();
    try std.testing.expectError(error.PathNotASocket, Listener.openUnix(alloc, path.get(), .{}));
    const st = try std.posix.fstatat(std.posix.AT.FDCWD, path.get(), 0);
    try std.testing.expect(std.posix.S.ISREG(st.mode));
}

test "unix: the requested mode is applied" {
    if (is_windows) return error.SkipZigTest;
    try requireUnix();
    for ([_]u16{ 0o600, 0o660 }) |mode| {
        var path: SockPath = .{};
        try path.init();
        defer path.deinit();
        var l = try Listener.openUnix(alloc, path.get(), .{ .mode = mode });
        defer l.close();
        const st = try std.posix.fstatat(std.posix.AT.FDCWD, path.get(), 0);
        try std.testing.expect(std.posix.S.ISSOCK(st.mode));
        try std.testing.expectEqual(@as(u32, mode), @as(u32, @intCast(st.mode)) & 0o777);
    }
}

test "unix: an over-long path is an error, never truncated" {
    try requireUnix();
    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    const prefix = if (is_windows) "C:\\" else "/tmp/";
    @memcpy(long[0..prefix.len], prefix);
    try std.testing.expectError(error.NameTooLong, Listener.openUnix(alloc, &long, .{}));
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var client: PlainNb = .{};
    defer client.deinit();
    try std.testing.expectError(error.NameTooLong, client.startConnectUnixInto(alloc, &long, &port, &client));
}
