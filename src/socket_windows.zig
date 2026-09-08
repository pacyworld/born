const std = @import("std");
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const kernel32 = windows.kernel32;
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const NbRead = io.NbRead;
const NbWrite = io.NbWrite;
const IoError = io.IoError;
const CompletionKind = io.CompletionKind;

const SIO_GET_EXTENSION_FUNCTION_POINTER: u32 = 0xC8000006;
const SO_UPDATE_CONNECT_CONTEXT: i32 = 0x7010;

const ConnectExFn = *const fn (
    s: ws2.SOCKET,
    name: *const ws2.sockaddr,
    namelen: i32,
    lpSendBuffer: ?*anyopaque,
    dwSendDataLength: u32,
    lpdwBytesSent: ?*u32,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) i32;

// WSAID_CONNECTEX
const WSAID_CONNECTEX: windows.GUID = .{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

fn ensureWsa() IoError!void {
    var wsa: ws2.WSADATA = undefined;
    if (ws2.WSAStartup(0x0202, &wsa) != 0) return IoError.SocketError;
}

fn connectEx(sock: ws2.SOCKET) IoError!ConnectExFn {
    var connect_ex_ptr: ?ConnectExFn = null; // resolved for this socket
    var ret: u32 = 0;
    const rc = ws2.WSAIoctl(
        sock,
        SIO_GET_EXTENSION_FUNCTION_POINTER,
        &WSAID_CONNECTEX,
        @sizeOf(windows.GUID),
        @ptrCast(&connect_ex_ptr),
        @sizeOf(?ConnectExFn),
        &ret,
        null,
        null,
    );
    if (rc != 0 or connect_ex_ptr == null) return IoError.SocketError;
    return connect_ex_ptr.?;
}

/// Non-blocking TCP stream over overlapped WSA sockets. Owns the socket.
pub const PlainNb = struct {
    pub const Error = IoError;

    sock: ws2.SOCKET = ws2.INVALID_SOCKET,
    wsa_started: bool = false,

    // OVERLAPPED structs: addresses registered with in-flight ops.
    conn_ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    recv_ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    send_ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),

    // connect state
    connect_pending: bool = false,
    connect_done: bool = false,
    connect_err: ?usize = null,

    // recv state
    recv_buf: [16384]u8 = undefined,
    recv_off: usize = 0,
    recv_have: usize = 0,
    recv_pending: bool = false,
    recv_eof: bool = false,
    recv_err: ?usize = null,

    // send state
    send_buf: [16384]u8 = undefined,
    send_len: usize = 0,
    send_pending: bool = false,
    send_just_done: ?usize = null,
    send_err: ?usize = null,

    pub fn handle(self: *const PlainNb) types.Handle {
        return @ptrCast(self.sock);
    }

    /// Overlapped connect to host:port, CONSTRUCTED IN PLACE at `dest`
    /// (the OVERLAPPED structs are registered with in-flight ops — a
    /// by-value return would orphan the connect completion's address).
    /// The socket is associated with the event port (`key` = the conn)
    /// before ConnectEx posts.
    pub fn startConnectInto(self: *PlainNb, alloc: std.mem.Allocator, host: []const u8, port: u16, evp: *evport.EvPort, key: ?*anyopaque) IoError!void {
        std.debug.assert(self.sock == ws2.INVALID_SOCKET and self.pendingOps() == 0 and !self.wsa_started);
        self.* = .{};
        try ensureWsa();
        self.wsa_started = true;
        errdefer self.deinit();
        const addr_list = std.net.getAddressList(alloc, host, port) catch |err| return switch (err) {
            error.OutOfMemory => IoError.OutOfMemory,
            else => IoError.ConnectFailed,
        };
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return IoError.ConnectFailed;

        var last_err: IoError = IoError.ConnectFailed;
        for (addr_list.addrs) |addr| {
            const s = ws2.WSASocketW(addr.any.family, ws2.SOCK.STREAM, 0, null, 0, ws2.WSA_FLAG_OVERLAPPED | ws2.WSA_FLAG_NO_HANDLE_INHERIT);
            if (s == ws2.INVALID_SOCKET) continue;

            // ConnectEx requires the socket bound first (wildcard, target's
            // address family — use a std.net.Address so the layout is
            // target-correct).
            const any_addr = switch (addr.any.family) {
                ws2.AF.INET => std.net.Address.parseIp4("0.0.0.0", 0) catch unreachable,
                else => std.net.Address.parseIp6("::", 0) catch unreachable,
            };
            if (ws2.bind(s, &any_addr.any, @intCast(any_addr.getOsSockLen())) != 0) {
                _ = ws2.closesocket(s);
                continue;
            }

            self.sock = s;
            evp.associate(self.handle(), key) catch return IoError.SocketError; // associate with the port

            const cx = connectEx(s) catch {
                _ = ws2.closesocket(s);
                self.sock = ws2.INVALID_SOCKET;
                last_err = IoError.SocketError;
                continue;
            };
            self.conn_ov = std.mem.zeroes(windows.OVERLAPPED);
            const rc = cx(s, @ptrCast(&addr.any), @intCast(addr.getOsSockLen()), null, 0, null, &self.conn_ov);
            if (rc != 0) {
                // Completed inline.
                self.connect_pending = true;
                return;
            }
            const e = ws2.WSAGetLastError();
            if (e != .WSA_IO_PENDING) {
                _ = ws2.closesocket(s);
                self.sock = ws2.INVALID_SOCKET;
                last_err = IoError.ConnectFailed;
                continue;
            }
            self.connect_pending = true;
            return;
        }
        return last_err;
    }

    fn postConnectSetup(self: *PlainNb) IoError!void {
        if (ws2.setsockopt(self.sock, ws2.SOL.SOCKET, SO_UPDATE_CONNECT_CONTEXT, null, 0) != 0) return IoError.SocketError;
    }

    /// Confirm the connect after its completion (or inline completion).
    pub fn connectDone(self: *PlainNb) IoError!void {
        if (self.connect_err != null or !self.connect_done or self.connect_pending) return IoError.ConnectFailed;
        if (self.sock == ws2.INVALID_SOCKET) return IoError.SocketError;
        try self.postConnectSetup();
    }

    /// Feed a completion from the port. Returns which op completed.
    pub fn absorbCompletion(self: *PlainNb, ov: ?*windows.OVERLAPPED, bytes: usize, err: ?usize) CompletionKind {
        defer self.releaseWsaIfClosed();
        if (ov == null) return .unknown;
        const o = ov.?;
        if (o == &self.conn_ov and self.connect_pending) {
            self.connect_pending = false;
            if (err) |e| self.connect_err = e else self.connect_done = true;
            return .connect;
        }
        if (o == &self.recv_ov and self.recv_pending) {
            self.recv_pending = false;
            if (err) |e| {
                self.recv_err = e;
            } else if (bytes == 0) {
                self.recv_eof = true;
            } else if (bytes > self.recv_buf.len) {
                self.recv_err = @intFromEnum(ws2.WinsockError.WSAEMSGSIZE);
            } else {
                self.recv_off = 0;
                self.recv_have = bytes;
            }
            return .recv;
        }
        if (o == &self.send_ov and self.send_pending) {
            self.send_pending = false;
            if (err) |e| {
                self.send_err = e;
            } else if (bytes > self.send_len) {
                self.send_err = @intFromEnum(ws2.WinsockError.WSAEMSGSIZE);
            } else {
                self.send_just_done = bytes;
            }
            return .send;
        }
        return .unknown;
    }

    pub fn readNb(self: *PlainNb, out: []u8) IoError!NbRead {
        if (self.sock == ws2.INVALID_SOCKET or self.recv_err != null) return IoError.SocketError;
        if (out.len == 0) return .{ .data = 0 };
        // Serve buffered bytes first (they arrived via completion).
        if (self.recv_have > 0) {
            const n = @min(out.len, self.recv_have - self.recv_off);
            @memcpy(out[0..n], self.recv_buf[self.recv_off .. self.recv_off + n]);
            self.recv_off += n;
            if (self.recv_off == self.recv_have) self.recv_have = 0;
            return .{ .data = n };
        }
        if (self.recv_eof) return .eof;
        if (self.recv_pending) return .want_read;
        // Post the next overlapped read. Sockets ALWAYS queue a completion
        // (even on inline success), so all data arrives via absorbCompletion.
        self.recv_ov = std.mem.zeroes(windows.OVERLAPPED);
        var buf = ws2.WSABUF{ .len = self.recv_buf.len, .buf = &self.recv_buf };
        var flags: u32 = 0;
        const rc = ws2.WSARecv(self.sock, @ptrCast(&buf), 1, null, &flags, &self.recv_ov, null);
        if (rc == 0 or ws2.WSAGetLastError() == .WSA_IO_PENDING) {
            self.recv_pending = true;
            return .want_read;
        }
        return IoError.SocketError;
    }

    pub fn writeNb(self: *PlainNb, data: []const u8) IoError!NbWrite {
        if (self.sock == ws2.INVALID_SOCKET or self.send_err != null) return IoError.SocketError;
        // Account for a completed pending send first (completions carry the
        // byte count — inline WSASend success still queues a completion).
        if (self.send_just_done) |n| {
            self.send_just_done = null;
            return .{ .done = n };
        }
        if (self.send_pending) return .want_write;
        if (data.len == 0) return .{ .done = 0 };

        self.send_ov = std.mem.zeroes(windows.OVERLAPPED);
        self.send_len = @min(data.len, self.send_buf.len);
        @memcpy(self.send_buf[0..self.send_len], data[0..self.send_len]);
        var buf = ws2.WSABUF{ .len = @intCast(self.send_len), .buf = &self.send_buf };
        const rc = ws2.WSASend(self.sock, @ptrCast(&buf), 1, null, 0, &self.send_ov, null);
        if (rc == 0 or ws2.WSAGetLastError() == .WSA_IO_PENDING) {
            self.send_pending = true;
            return .want_write;
        }
        return IoError.SocketError;
    }

    /// In-flight op count (for the core's deferred reap).
    pub fn pendingOps(self: *const PlainNb) usize {
        var n: usize = 0;
        if (self.connect_pending) n += 1;
        if (self.recv_pending) n += 1;
        if (self.send_pending) n += 1;
        return n;
    }

    /// Abort in-flight ops (their completions still arrive — absorbed as
    /// errors) and close the socket.
    pub fn cancelAndClose(self: *PlainNb) void {
        if (self.sock != ws2.INVALID_SOCKET) {
            _ = kernel32.CancelIoEx(self.handle(), null);
            _ = ws2.closesocket(self.sock);
            self.sock = ws2.INVALID_SOCKET;
        }
        self.releaseWsaIfClosed();
    }

    pub fn closeNotify(self: *PlainNb) void {
        _ = self;
    }

    pub fn deinit(self: *PlainNb) void {
        self.cancelAndClose();
    }

    fn releaseWsaIfClosed(self: *PlainNb) void {
        if (self.sock == ws2.INVALID_SOCKET and self.pendingOps() == 0 and self.wsa_started) {
            _ = ws2.WSACleanup();
            self.wsa_started = false;
        }
    }
};
