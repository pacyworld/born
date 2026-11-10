//! POSIX non-blocking stream sockets use EINPROGRESS connects, WouldBlock-mapped
//! reads and writes, and MSG_NOSIGNAL sends to avoid SIGPIPE.

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

/// Plaintext stream socket (TCP and Unix where supported) for readiness I/O.
///
/// The stream owns its descriptor. Purge event-port registrations for that
/// descriptor before closing it.
pub const PlainNb = struct {
    sock: std.posix.fd_t = -1,
    /// Latches a refusal observed by `connectDone` because SO_ERROR is
    /// read-and-clear.
    connect_err: bool = false,
    /// Bytes the last readable event reported; see `hintReadable`.
    hint: io.ReadyHint = .{},

    /// Every stream error; each method returns its own narrower set.
    pub const Error = io.IoError;

    /// Returns the underlying descriptor without transferring ownership.
    pub fn handle(self: *const PlainNb) types.Handle {
        return self.sock;
    }

    /// Resolves `host` and starts a non-blocking TCP connect in `self`.
    /// `evp` and `key` are unused on POSIX. Register write interest after
    /// success, then confirm the result with `connectDone`. `self` is left
    /// untouched on failure.
    pub fn startConnectInto(self: *PlainNb, alloc: std.mem.Allocator, host: []const u8, port: u16, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectError!void {
        std.debug.assert(self.sock == -1);
        _ = evp;
        _ = key;
        self.* = try startConnect(alloc, host, port);
    }

    /// Non-blocking connect to an already resolved `addr`, with no resolver
    /// and no allocation: the call to use from an event loop. Same contract
    /// as `startConnectInto` (wantWrite, then connectDone). `self` is left
    /// untouched on failure.
    pub fn startConnectAddrInto(self: *PlainNb, addr: std.net.Address, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectAddrError!void {
        std.debug.assert(self.sock == -1);
        _ = evp;
        _ = key;
        self.* = try connectAddr(addr);
    }

    /// socket(SOCK_NONBLOCK) + connect() to one address. A synchronous
    /// refusal (FreeBSD loopback under load) is ConnectFailed.
    fn connectAddr(addr: std.net.Address) io.ConnectAddrError!PlainNb {
        const s = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0) catch return io.ConnectAddrError.SocketError;
        if (comptime builtin.os.tag.isDarwin()) {
            std.posix.setsockopt(s, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, std.mem.asBytes(&@as(c_int, 1))) catch {
                std.posix.close(s);
                return io.ConnectAddrError.SocketError;
            };
        }
        std.posix.connect(s, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => return .{ .sock = s }, // EINPROGRESS
            else => {
                std.posix.close(s);
                return io.ConnectAddrError.ConnectFailed;
            },
        };
        return .{ .sock = s }; // connected immediately
    }

    /// Non-blocking connect to a Unix stream socket at `path`, completed
    /// through the same write-readiness and `connectDone` contract as TCP.
    /// `self` is left untouched on failure.
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
    /// EINPROGRESS state or instantly connected (loopback): register write
    /// interest and confirm with `connectDone` on the first write event.
    pub fn startConnect(alloc: std.mem.Allocator, host: []const u8, port: u16) io.ConnectError!PlainNb {
        const addr_list = std.net.getAddressList(alloc, host, port) catch |err| return switch (err) {
            error.OutOfMemory => io.ConnectError.OutOfMemory,
            else => io.ConnectError.ConnectFailed,
        };
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return io.ConnectError.ConnectFailed;

        for (addr_list.addrs) |addr| {
            return connectAddr(addr) catch continue;
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

    /// Record the readiness count of a readable event (`Event.avail`, bytes
    /// buffered on kqueue; unknown elsewhere). `readNb` then answers
    /// `.want_read` without the read that would only return EAGAIN once that
    /// many bytes were taken. Call it on every readable event before the
    /// first `readNb`: each event replaces the previous count, and a count
    /// that outlives a partial drain would strand the rest.
    pub fn hintReadable(self: *PlainNb, ev: types.Event) void {
        self.hint.arm(ev);
    }

    /// Reads available bytes without blocking. Drain after each readable event
    /// until `.want_read` or `.eof`; an empty buffer returns zero bytes.
    pub fn readNb(self: *PlainNb, out: []u8) io.ReadError!NbRead {
        if (self.sock < 0) return io.ReadError.SocketError;
        if (out.len == 0) return .{ .data = 0 };
        if (self.hint.exhausted()) return .want_read;
        const n = std.posix.read(self.sock, out) catch |err| {
            self.hint.clear();
            return switch (err) {
                error.WouldBlock => .want_read,
                else => io.ReadError.SocketError,
            };
        };
        if (n == 0) {
            self.hint.clear();
            return .eof;
        }
        self.hint.consume(n);
        return .{ .data = n };
    }

    /// Writes as much as possible without blocking, returning `.done` or
    /// `.want_write`. An empty write succeeds without a system call.
    pub fn writeNb(self: *PlainNb, data: []const u8) io.WriteError!NbWrite {
        if (self.sock < 0) return io.WriteError.SocketError;
        // Do not pass an empty slice to send(2): on Linux its dangling pointer
        // can produce EFAULT, which std.posix.send treats as unreachable.
        if (data.len == 0) return .{ .done = 0 };
        const n = std.posix.send(self.sock, data, MSG_NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => return .want_write,
            else => return io.WriteError.SocketError,
        };
        return .{ .done = n };
    }

    /// Intentionally returns `.unknown` without inspecting the completion;
    /// POSIX readiness sockets have no overlapped operations to absorb.
    pub fn absorbCompletion(self: *PlainNb, ov: ?*std.os.windows.OVERLAPPED, bytes: usize, err: ?usize) io.CompletionKind {
        _ = self;
        _ = ov;
        _ = bytes;
        _ = err;
        return .unknown;
    }

    /// Always returns zero because POSIX streams have no completions to drain.
    pub fn pendingOps(self: *const PlainNb) usize {
        _ = self;
        return 0;
    }

    /// Closes the socket immediately, equivalent to `deinit` on POSIX. Call
    /// `EvPort.purgeFd(handle())` first to remove staged registrations.
    pub fn cancelAndClose(self: *PlainNb) void {
        self.deinit();
    }

    /// Intentionally does nothing; POSIX close requires no completion notice.
    pub fn closeNotify(self: *PlainNb) void {
        _ = self;
    }

    /// Closes the descriptor if open and marks the socket closed. Call
    /// `EvPort.purgeFd(handle())` first; no completion drain is required.
    pub fn deinit(self: *PlainNb) void {
        if (self.sock >= 0) std.posix.close(self.sock);
        self.sock = -1;
    }
};
