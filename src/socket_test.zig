const std = @import("std");
const builtin = @import("builtin");
const born = @import("root.zig");
const socket = @import("socket.zig");
const PlainNb = socket.PlainNb;
const windows = std.os.windows;
const is_windows = builtin.os.tag == .windows;
const alloc = std.testing.allocator;

const Pair = struct {
    port: born.EvPort,
    client: PlainNb = .{},
    peer: PlainNb = .{},
    wsa_started: bool = false,
    server: ?std.net.Server = null,
    accept_ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    accept_buf: [2 * (@sizeOf(std.net.Address) + 16)]u8 = undefined,
    accept_pending: bool = false,
    connected: bool = false,
    /// Set by the refusal test. epoll reports a refused connect as
    /// EPOLLOUT|EPOLLERR|EPOLLHUP, so Event.err is legitimately set there;
    /// kqueue reports EV_EOF without EV_ERROR. The blanket !event.err
    /// assertion below is a kqueue-shaped assumption (issue #8).
    expect_connect_err: bool = false,

    fn init(self: *Pair) !void {
        self.* = .{ .port = try born.EvPort.init(alloc) };
        errdefer self.deinit();
        if (is_windows) {
            var wsa: windows.ws2_32.WSADATA = undefined;
            try std.testing.expectEqual(@as(c_int, 0), windows.ws2_32.WSAStartup(0x0202, &wsa));
            self.wsa_started = true;
        }
        const address = try std.net.Address.parseIp4("127.0.0.1", 0);
        self.server = try address.listen(.{ .force_nonblocking = true });
        if (is_windows) {
            try self.postAccept();
        } else {
            self.port.monitorRead(self.server.?.stream.handle, self);
            self.accept_pending = true;
        }
        try self.client.startConnectInto(alloc, "127.0.0.1", self.server.?.listen_address.getPort(), &self.port, &self.client);
        try std.testing.expectEqual(@as(usize, if (is_windows) 1 else 0), self.client.pendingOps());
        if (is_windows) {
            try std.testing.expectError(error.ConnectFailed, self.client.connectDone());
        } else {
            self.port.wantWrite(self.client.handle(), &self.client);
        }
        while (!self.connected or self.accept_pending) try self.waitOne();
        try std.testing.expectEqual(@as(usize, 0), self.client.pendingOps());
        try self.client.connectDone();
        if (is_windows) {
            try std.testing.expectEqual(@as(c_int, 0), windows.ws2_32.setsockopt(self.peer.sock, windows.ws2_32.SOL.SOCKET, 0x700b, @ptrCast(&self.server.?.stream.handle), @sizeOf(windows.ws2_32.SOCKET)));
            try self.port.associate(self.peer.handle(), &self.peer);
        } else {
            if (comptime builtin.os.tag.isDarwin()) {
                try std.posix.setsockopt(self.peer.sock, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, std.mem.asBytes(&@as(c_int, 1)));
            }
            self.port.monitorRead(self.client.handle(), &self.client);
            self.port.monitorRead(self.peer.handle(), &self.peer);
        }
        self.closeServer();
    }

    fn postAccept(self: *Pair) !void {
        const ws2 = windows.ws2_32;
        const AcceptEx = *const fn (ws2.SOCKET, ws2.SOCKET, *anyopaque, u32, u32, u32, *u32, *windows.OVERLAPPED) callconv(.winapi) windows.BOOL;
        const guid = windows.GUID{ .Data1 = 0xb5367df1, .Data2 = 0xcbac, .Data3 = 0x11cf, .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 } };
        var accept_ex: ?AcceptEx = null;
        var bytes: u32 = 0;
        const listener = self.server.?.stream.handle;
        try std.testing.expectEqual(@as(c_int, 0), ws2.WSAIoctl(listener, 0xc8000006, &guid, @sizeOf(windows.GUID), @ptrCast(&accept_ex), @sizeOf(?AcceptEx), &bytes, null, null));
        self.peer.sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
        try self.port.associate(@ptrCast(listener), self);
        const rc = accept_ex.?(listener, self.peer.sock, &self.accept_buf, 0, self.accept_buf.len / 2, self.accept_buf.len / 2, &bytes, &self.accept_ov);
        try std.testing.expect(rc != 0 or ws2.WSAGetLastError() == .WSA_IO_PENDING);
        self.accept_pending = true;
    }

    fn closeServer(self: *Pair) void {
        if (self.server) |*server| {
            self.port.purgeFd(if (is_windows) @ptrCast(server.stream.handle) else server.stream.handle);
            server.deinit();
            self.server = null;
        }
        if (!is_windows) self.accept_pending = false;
    }

    fn waitOne(self: *Pair) !void {
        try self.waitOneTimeout(2000);
    }

    fn waitOneTimeout(self: *Pair, timeout_ms: i32) !void {
        var events: [8]born.Event = undefined;
        const count = try self.port.wait(&events, timeout_ms);
        if (count == 0) return error.SocketEventTimeout;
        for (events[0..count]) |event| {
            try std.testing.expect(!event.wake);
            if (event.udata == @as(?*anyopaque, self)) {
                if (is_windows) {
                    try std.testing.expect(event.overlapped == &self.accept_ov and self.accept_pending);
                    if (self.server != null) try std.testing.expect(!event.err);
                } else {
                    try std.testing.expect(!event.err);
                    self.peer.sock = std.posix.accept(self.server.?.stream.handle, null, null, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        else => return err,
                    };
                }
                self.accept_pending = false;
                continue;
            }
            const stream: *PlainNb = if (event.udata == @as(?*anyopaque, &self.client)) &self.client else if (event.udata == @as(?*anyopaque, &self.peer)) &self.peer else return error.TestUnexpectedResult;
            if (is_windows) {
                const kind = stream.absorbCompletion(event.overlapped, event.bytes, if (event.err) event.err_no else null);
                try std.testing.expect(kind != .unknown);
                if (kind == .connect) self.connected = true;
            } else {
                if (!self.expect_connect_err) try std.testing.expect(!event.err);
                if (event.writable or event.err) {
                    self.port.cancelWrite(stream.handle());
                    self.connected = true;
                }
            }
        }
    }

    fn close(self: *Pair, stream: *PlainNb) void {
        if (is_windows) {
            if (stream.sock != windows.ws2_32.INVALID_SOCKET) self.port.purgeFd(stream.handle());
        } else {
            if (stream.sock >= 0) self.port.purgeFd(stream.handle());
        }
        stream.cancelAndClose();
    }

    fn drain(self: *Pair) !void {
        while (self.client.pendingOps() + self.peer.pendingOps() != 0 or self.accept_pending) try self.waitOne();
    }

    fn deinit(self: *Pair) void {
        self.closeServer();
        self.close(&self.client);
        self.close(&self.peer);
        self.drain() catch @panic("socket completion drain failed");
        self.client.deinit();
        self.peer.deinit();
        self.port.deinit();
        if (is_windows and self.wsa_started) {
            _ = windows.ws2_32.WSACleanup();
        }
    }

    fn transfer(self: *Pair, sender: *PlainNb, receiver: *PlainNb, data: []const u8, out: []u8) !void {
        try std.testing.expectEqual(data.len, out.len);
        var sent: usize = 0;
        var received: usize = 0;
        while (sent < data.len or received < out.len) {
            var progress = false;
            if (sent < data.len) {
                switch (try sender.writeNb(data[sent..])) {
                    .done => |n| {
                        try std.testing.expect(n > 0 and n <= data.len - sent);
                        sent += n;
                        progress = true;
                    },
                    .want_write => if (!is_windows) {
                        self.port.wantWrite(sender.handle(), sender);
                    },
                    .want_read => return error.TestUnexpectedResult,
                }
            }
            if (received < out.len) {
                switch (try receiver.readNb(out[received..@min(out.len, received + 257)])) {
                    .data => |n| {
                        try std.testing.expect(n > 0 and n <= out.len - received);
                        received += n;
                        progress = true;
                    },
                    .want_read => {},
                    else => return error.TestUnexpectedResult,
                }
            }
            if (!progress) try self.waitOne();
        }
        try std.testing.expectEqualSlices(u8, data, out);
    }
};

test "plain socket has the same companion API on every target" {
    try std.testing.expect(@TypeOf(PlainNb.startConnectInto) == fn (*PlainNb, std.mem.Allocator, []const u8, u16, *born.EvPort, ?*anyopaque) socket.IoError!void);
    try std.testing.expect(@TypeOf(PlainNb.connectDone) == fn (*PlainNb) socket.IoError!void);
    try std.testing.expect(@TypeOf(PlainNb.readNb) == fn (*PlainNb, []u8) socket.IoError!socket.NbRead);
    try std.testing.expect(@TypeOf(PlainNb.writeNb) == fn (*PlainNb, []const u8) socket.IoError!socket.NbWrite);
    try std.testing.expect(@TypeOf(PlainNb.absorbCompletion) == fn (*PlainNb, ?*windows.OVERLAPPED, usize, ?usize) socket.CompletionKind);
    try std.testing.expect(@TypeOf(PlainNb.pendingOps) == fn (*const PlainNb) usize);
    try std.testing.expect(@TypeOf(PlainNb.handle) == fn (*const PlainNb) born.Handle);
    inline for (.{ "closeNotify", "cancelAndClose", "deinit" }) |name| {
        try std.testing.expect(@TypeOf(@field(PlainNb, name)) == fn (*PlainNb) void);
    }
    if (!is_windows) {
        try std.testing.expect(@TypeOf(PlainNb.startConnect) == fn (std.mem.Allocator, []const u8, u16) socket.IoError!PlainNb);
    }
}

test "plain socket loopback round trip, partial drains, and EOF" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    var empty: [0]u8 = .{};
    try std.testing.expectEqual(socket.NbRead{ .data = 0 }, try pair.client.readNb(&empty));
    try std.testing.expectEqual(socket.NbWrite{ .done = 0 }, try pair.client.writeNb(&empty));
    try std.testing.expectEqual(@as(usize, 0), pair.client.pendingOps());
    try std.testing.expectEqual(socket.CompletionKind.unknown, pair.client.absorbCompletion(null, 0, null));
    var unrelated = std.mem.zeroes(windows.OVERLAPPED);
    try std.testing.expectEqual(socket.CompletionKind.unknown, pair.client.absorbCompletion(&unrelated, 0, null));
    var scratch = [_]u8{0xa5} ** 7;
    try std.testing.expectEqual(socket.NbRead.want_read, try pair.client.readNb(&scratch));
    try std.testing.expectEqual(socket.NbRead.want_read, try pair.client.readNb(&scratch));
    try std.testing.expectEqual(@as(usize, if (is_windows) 1 else 0), pair.client.pendingOps());

    var payload: [40000]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    var received: [payload.len]u8 = undefined;
    try pair.transfer(&pair.client, &pair.peer, &payload, &received);
    try pair.transfer(&pair.peer, &pair.client, &received, &payload);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 7), &scratch);
    try std.testing.expectEqual(socket.NbRead.want_read, try pair.client.readNb(&scratch));
    pair.peer.closeNotify();
    pair.close(&pair.peer);
    while (true) {
        switch (try pair.client.readNb(&scratch)) {
            .want_read => try pair.waitOne(),
            .eof => break,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), pair.client.pendingOps());
    try std.testing.expectEqual(socket.NbRead.eof, try pair.client.readNb(&scratch));
}

test "plain socket cancellation retains pending operations until absorbed" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    var scratch: [8]u8 = undefined;
    try std.testing.expectEqual(socket.NbRead.want_read, try pair.client.readNb(&scratch));
    const result = try pair.client.writeNb("cancel me");
    if (is_windows) {
        try std.testing.expectEqual(socket.NbWrite.want_write, result);
        try std.testing.expectEqual(@as(usize, 2), pair.client.pendingOps());
        try std.testing.expectEqual(socket.NbWrite.want_write, try pair.client.writeNb("cancel me"));
    }
    const pending = pair.client.pendingOps();
    pair.close(&pair.client);
    pair.client.deinit();
    try std.testing.expectEqual(pending, pair.client.pendingOps());
    if (is_windows) try std.testing.expect(pair.client.wsa_started);
    try pair.drain();
    try std.testing.expectEqual(@as(usize, 0), pair.client.pendingOps());
    if (is_windows) try std.testing.expect(!pair.client.wsa_started);
    pair.client.deinit();
    try std.testing.expectError(error.SocketError, pair.client.readNb(&scratch));
    try std.testing.expectError(error.SocketError, pair.client.writeNb("closed"));
}

test "plain socket connect refusal surfaces at connectDone" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const refused_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(refused_socket);
    try std.posix.bind(refused_socket, &address.any, address.getOsSockLen());
    var address_len = address.getOsSockLen();
    try std.posix.getsockname(refused_socket, &address.any, &address_len);
    const refused_port = address.getPort();
    pair.close(&pair.client);
    try pair.drain();
    pair.client.deinit();
    pair.connected = false;
    pair.expect_connect_err = true;
    pair.client.startConnectInto(alloc, "127.0.0.1", refused_port, &pair.port, &pair.client) catch |err| {
        try std.testing.expectEqual(error.ConnectFailed, err);
        try std.testing.expectEqual(@as(usize, 0), pair.client.pendingOps());
        return;
    };
    if (!is_windows) pair.port.wantWrite(pair.client.handle(), &pair.client);
    while (!pair.connected) try pair.waitOneTimeout(10000);
    try std.testing.expectError(error.ConnectFailed, pair.client.connectDone());
    // SO_ERROR is read-and-clear, so without a latch this second call would
    // report success and a consumer would proceed on a dead socket.
    try std.testing.expectError(error.ConnectFailed, pair.client.connectDone());
}

test "plain socket cancellation before connect completion is absorbed" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    pair.close(&pair.client);
    pair.client.deinit();
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .force_nonblocking = true });
    defer server.deinit();
    try pair.client.startConnectInto(alloc, "127.0.0.1", server.listen_address.getPort(), &pair.port, &pair.client);
    const pending = pair.client.pendingOps();
    try std.testing.expectEqual(@as(usize, if (is_windows) 1 else 0), pending);
    pair.close(&pair.client);
    try std.testing.expectEqual(pending, pair.client.pendingOps());
    try pair.drain();
}

test "plain socket allocation failure releases startup state" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var client: PlainNb = .{};
    defer client.deinit();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, client.startConnectInto(failing.allocator(), "127.0.0.1", 1, &port, null));
    try std.testing.expectEqual(@as(usize, 0), client.pendingOps());
    if (is_windows) {
        try std.testing.expect(!client.wsa_started);
        try std.testing.expect(client.sock == windows.ws2_32.INVALID_SOCKET);
    } else {
        try std.testing.expectEqual(@as(std.posix.fd_t, -1), client.sock);
    }
}

test "plain socket association failure releases Winsock and socket" {
    if (!is_windows) return error.SkipZigTest;
    var port: born.EvPort = .{};
    var client: PlainNb = .{};
    defer client.deinit();
    try std.testing.expectError(error.SocketError, client.startConnectInto(alloc, "127.0.0.1", 1, &port, null));
    try std.testing.expectEqual(@as(usize, 0), client.pendingOps());
    try std.testing.expect(!client.wsa_started);
    try std.testing.expect(client.sock == windows.ws2_32.INVALID_SOCKET);
}

test "plain socket write after send shutdown reports an error without SIGPIPE" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    try std.posix.shutdown(pair.client.sock, .send);
    try std.testing.expectError(error.SocketError, pair.client.writeNb("closed"));
    try std.testing.expectEqual(@as(usize, 0), pair.client.pendingOps());
}

test "plain socket overlapped send owns its submitted buffer" {
    if (!is_windows) return error.SkipZigTest;
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    var source = [_]u8{0x37} ** 8192;
    const expected = source;
    try std.testing.expectEqual(socket.NbWrite.want_write, try pair.client.writeNb(&source));
    @memset(&source, 0xa5);
    try std.testing.expectEqualSlices(u8, &expected, pair.client.send_buf[0..source.len]);
    var received: [source.len]u8 = undefined;
    try pair.transfer(&pair.client, &pair.peer, &expected, &received);
}
