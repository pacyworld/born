// POSIX non-blocking socket layer for the event core (issue #7):
// EINPROGRESS connect, WouldBlock-mapped reads/writes, MSG_NOSIGNAL sends
// (the bridge never takes SIGPIPE). The legacy blocking streams and
// timeout plumbing retired with the serial core.

const std = @import("std");
const builtin = @import("builtin");
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const unix_posix = @import("unix_posix.zig");
const NbRead = io.NbRead;
const NbWrite = io.NbWrite;

// ------------------------------------------------------- non-blocking ----

/// MSG_NOSIGNAL per target (std.os.freebsd exposes no MSG constants).
/// send()-only flag: writes to a torn-down socket return EPIPE instead of
/// raising SIGPIPE.
const MSG_NOSIGNAL: u32 = switch (builtin.os.tag) {
    .freebsd => 0x00020000,
    .linux => 0x00004000,
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => 0,
    else => std.posix.MSG.NOSIGNAL,
};

/// Non-blocking plaintext TCP stream for the event core.
pub const PlainNb = struct {
    sock: std.posix.fd_t = -1,
    /// Latched connect outcome. SO_ERROR is READ-AND-CLEAR, so the second
    /// getsockopt returns 0 and a refused connect would look like success.
    /// Anything that reads it first — a second connectDone(), or a caller
    /// doing its own getsockopt — must not be able to erase the verdict
    /// (issue #8).
    connect_err: bool = false,

    /// Every stream error; each method returns its own narrower set.
    pub const Error = io.IoError;

    pub fn handle(self: *const PlainNb) types.Handle {
        return self.sock;
    }

    pub fn startConnectInto(self: *PlainNb, alloc: std.mem.Allocator, host: []const u8, port: u16, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectError!void {
        std.debug.assert(self.sock == -1);
        _ = evp;
        _ = key;
        self.* = try startConnect(alloc, host, port);
    }

    /// Non-blocking connect to a Unix stream socket at `path`, completed
    /// through the same wantWrite + connectDone contract as TCP. `self` is
    /// left untouched on failure. Implemented in unix_posix.zig (born#20).
    pub fn startConnectUnixInto(self: *PlainNb, alloc: std.mem.Allocator, path: []const u8, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectUnixError!void {
        return unix_posix.connectInto(self, alloc, path, evp, key);
    }

    /// Wrap `h`, a connected non-blocking stream socket from accept, as
    /// this stream; `Listener.acceptNb` adopts through here. Takes ownership:
    /// on failure `h` is closed and `self` is untouched. `evp` and `key` are
    /// for IOCP association and unused here: register read interest
    /// yourself. Darwin sets SO_NOSIGPIPE, which a socket whose peer is
    /// already gone refuses (EINVAL): error.SocketError.
    pub fn adoptAccepted(self: *PlainNb, h: types.Handle, evp: ?*evport.EvPort, key: ?*anyopaque) io.AcceptError!void {
        std.debug.assert(self.sock == -1);
        _ = evp;
        _ = key;
        if (comptime builtin.os.tag.isDarwin()) {
            const one: c_int = 1;
            switch (std.posix.errno(std.c.setsockopt(h, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &one, @sizeOf(c_int)))) {
                .SUCCESS => {},
                .NOBUFS, .NOMEM => {
                    std.posix.close(h);
                    return io.AcceptError.ResourceExhausted;
                },
                else => {
                    std.posix.close(h);
                    return io.AcceptError.SocketError;
                },
            }
        }
        self.* = .{ .sock = h };
    }

    /// socket(SOCK_NONBLOCK) + connect(). On success the fd is either in
    /// EINPROGRESS state or instantly connected (loopback) — register write
    /// interest and confirm with connectDone() on the first write event.
    pub fn startConnect(alloc: std.mem.Allocator, host: []const u8, port: u16) io.ConnectError!PlainNb {
        const addr_list = std.net.getAddressList(alloc, host, port) catch |err| return switch (err) {
            error.OutOfMemory => io.ConnectError.OutOfMemory,
            else => io.ConnectError.ConnectFailed,
        };
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return io.ConnectError.ConnectFailed;

        for (addr_list.addrs) |addr| {
            const s = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0) catch continue;
            if (comptime builtin.os.tag.isDarwin()) {
                std.posix.setsockopt(s, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, std.mem.asBytes(&@as(c_int, 1))) catch {
                    std.posix.close(s);
                    continue;
                };
            }
            std.posix.connect(s, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => return .{ .sock = s }, // EINPROGRESS
                else => {
                    std.posix.close(s);
                    continue;
                },
            };
            return .{ .sock = s }; // connected immediately
        }
        return io.ConnectError.ConnectFailed;
    }

    /// Confirm the connect after the first write event (SO_ERROR).
    pub fn connectDone(self: *PlainNb) io.ConnectDoneError!void {
        if (self.sock < 0) return io.ConnectDoneError.SocketError;
        if (self.connect_err) return io.ConnectDoneError.ConnectFailed; // already latched
        var so_error: c_int = 0;
        std.posix.getsockopt(self.sock, std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&so_error)) catch return io.ConnectDoneError.SocketError;
        if (so_error != 0) {
            self.connect_err = true;
            return io.ConnectDoneError.ConnectFailed;
        }
    }

    pub fn readNb(self: *PlainNb, out: []u8) io.ReadError!NbRead {
        if (self.sock < 0) return io.ReadError.SocketError;
        if (out.len == 0) return .{ .data = 0 };
        const n = std.posix.read(self.sock, out) catch |err| switch (err) {
            error.WouldBlock => return .want_read,
            else => return io.ReadError.SocketError,
        };
        if (n == 0) return .eof;
        return .{ .data = n };
    }

    pub fn writeNb(self: *PlainNb, data: []const u8) io.WriteError!NbWrite {
        if (self.sock < 0) return io.WriteError.SocketError;
        // An empty write is a no-op, and must not reach send(2): Linux
        // answers EFAULT for a zero-length buffer whose pointer is the
        // dangling one an empty slice carries, and std.posix.send maps
        // EFAULT to unreachable — a panic, not an error. readNb and the
        // Windows backend already guard this; POSIX writeNb was the
        // outlier.
        if (data.len == 0) return .{ .done = 0 };
        const n = std.posix.send(self.sock, data, MSG_NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => return .want_write,
            else => return io.WriteError.SocketError,
        };
        return .{ .done = n };
    }

    pub fn absorbCompletion(self: *PlainNb, ov: ?*std.os.windows.OVERLAPPED, bytes: usize, err: ?usize) io.CompletionKind {
        _ = self;
        _ = ov;
        _ = bytes;
        _ = err;
        return .unknown;
    }

    pub fn pendingOps(self: *const PlainNb) usize {
        _ = self;
        return 0;
    }

    pub fn cancelAndClose(self: *PlainNb) void {
        self.deinit();
    }

    pub fn closeNotify(self: *PlainNb) void {
        _ = self;
    }

    pub fn deinit(self: *PlainNb) void {
        if (self.sock >= 0) std.posix.close(self.sock);
        self.sock = -1;
    }
};
