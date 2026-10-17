//! Listening stream sockets on Windows (AcceptEx). Owned by born#19 (TCP:
//! openTcp, register, acceptNb, absorbCompletion, pendingOps, localAddress,
//! close) apart from `openUnix` and the `unix` field, which belong to
//! born#21 in unix_windows.zig.
//!
//! Model: a few AcceptEx operations stay outstanding, each with its own
//! accept socket and OVERLAPPED storage, so a Listener must not move after
//! `register`. Feed each listener completion to `absorbCompletion`, then
//! call `acceptNb` until `.want_accept`. On teardown call `close`, keep
//! absorbing until `pendingOps() == 0`, then free the Listener (the
//! PlainNb rule). `.balanced` is error.Unsupported: Windows has no
//! kernel-balanced port sharing.
//!
//! Stub until #19 lands: `openTcp` returns error.Unsupported, so no open
//! Listener can exist and the other methods only refuse a closed one.

const std = @import("std");
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const unix_windows = @import("unix_windows.zig");
const PlainNb = @import("socket_windows.zig").PlainNb;

pub const Listener = struct {
    sock: ws2.SOCKET = ws2.INVALID_SOCKET,
    /// Unix-socket state (e.g. the bound path), owned by unix_windows.zig.
    unix: unix_windows.ListenerState = .{},

    pub fn openTcp(alloc: std.mem.Allocator, addr: std.net.Address, opts: io.ListenOptions) io.ListenError!Listener {
        _ = alloc;
        _ = addr;
        _ = opts;
        return io.ListenError.Unsupported;
    }

    /// Unix stream listener at `path`; see unix_windows.zig.
    pub fn openUnix(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
        return unix_windows.listen(alloc, path, opts);
    }

    /// Associate with the port and post the initial AcceptEx operations.
    pub fn register(self: *Listener, evp: *evport.EvPort, udata: ?*anyopaque) io.ListenerRegisterError!void {
        _ = evp;
        _ = udata;
        if (self.sock == ws2.INVALID_SOCKET) return io.ListenerRegisterError.SocketError;
        @panic("born: Listener.register before born#19");
    }

    /// Adopt one completed accept into `out` (constructed in place),
    /// associate it with the registered port under `key`, and re-post its
    /// AcceptEx; or report `.want_accept`.
    pub fn acceptNb(self: *Listener, out: *PlainNb, key: ?*anyopaque) io.AcceptError!io.AcceptResult {
        _ = out;
        _ = key;
        if (self.sock == ws2.INVALID_SOCKET) return io.AcceptError.SocketError;
        @panic("born: Listener.acceptNb before born#19");
    }

    /// Match a completion to one outstanding AcceptEx.
    pub fn absorbCompletion(self: *Listener, ov: ?*windows.OVERLAPPED, bytes: usize, err: ?usize) io.ListenerCompletion {
        _ = self;
        _ = ov;
        _ = bytes;
        _ = err;
        return .unknown;
    }

    /// Outstanding AcceptEx operations; free the Listener only at 0.
    pub fn pendingOps(self: *const Listener) usize {
        _ = self;
        return 0;
    }

    pub fn localAddress(self: *const Listener) io.LocalAddressError!std.net.Address {
        if (self.sock == ws2.INVALID_SOCKET) return io.LocalAddressError.SocketError;
        @panic("born: Listener.localAddress before born#19");
    }

    pub fn handle(self: *const Listener) types.Handle {
        return @ptrCast(self.sock);
    }

    /// Cancels outstanding accepts and closes the socket; completions still
    /// arrive and must be absorbed until `pendingOps() == 0`.
    pub fn close(self: *Listener) void {
        self.unix.deinit();
        if (self.sock != ws2.INVALID_SOCKET) _ = ws2.closesocket(self.sock);
        self.sock = ws2.INVALID_SOCKET;
    }
};
