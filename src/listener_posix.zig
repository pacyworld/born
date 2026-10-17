//! Listening stream sockets on POSIX (kqueue and epoll targets). Owned by
//! born#18 (TCP: openTcp, register, acceptNb, localAddress, close) apart
//! from `openUnix` and the `unix` field, which belong to born#20 in
//! unix_posix.zig.
//!
//! Model: `register` adds persistent edge-triggered read interest on the
//! listening fd; on each read event the consumer calls `acceptNb` until
//! `.want_accept`. Accepted streams are ordinary `PlainNb` streams.
//! `absorbCompletion` and `pendingOps` exist for the portable IOCP shape and
//! are no-ops here.
//!
//! Stub until #18 lands: `openTcp` returns error.Unsupported, so no open
//! Listener can exist and the other methods only refuse a closed one.

const std = @import("std");
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const unix_posix = @import("unix_posix.zig");
const PlainNb = @import("socket_posix.zig").PlainNb;

pub const Listener = struct {
    sock: std.posix.fd_t = -1,
    /// Unix-socket state (e.g. the bound path), owned by unix_posix.zig.
    unix: unix_posix.ListenerState = .{},

    /// TCP listener on `addr` (port 0 picks one; see `localAddress`).
    /// `.balanced` is SO_REUSEPORT_LB on FreeBSD and SO_REUSEPORT on Linux;
    /// error.Unsupported elsewhere.
    pub fn openTcp(alloc: std.mem.Allocator, addr: std.net.Address, opts: io.ListenOptions) io.ListenError!Listener {
        _ = alloc;
        _ = addr;
        _ = opts;
        return io.ListenError.Unsupported;
    }

    /// Unix stream listener at `path`; see unix_posix.zig.
    pub fn openUnix(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
        return unix_posix.listen(alloc, path, opts);
    }

    /// Persistent edge-triggered read interest on the listening fd.
    pub fn register(self: *Listener, evp: *evport.EvPort, udata: ?*anyopaque) io.ListenerRegisterError!void {
        _ = evp;
        _ = udata;
        if (self.sock < 0) return io.ListenerRegisterError.SocketError;
        @panic("born: Listener.register before born#18");
    }

    /// Accept one connection into `out` (constructed in place), or report
    /// `.want_accept` when the backlog is drained. Peer resets before
    /// accept are skipped; descriptor exhaustion is error.ResourceExhausted.
    /// `key` is the stream's udata for IOCP association, unused here:
    /// register the accepted stream's read interest yourself, as after
    /// startConnectInto.
    pub fn acceptNb(self: *Listener, out: *PlainNb, key: ?*anyopaque) io.AcceptError!io.AcceptResult {
        _ = out;
        _ = key;
        if (self.sock < 0) return io.AcceptError.SocketError;
        @panic("born: Listener.acceptNb before born#18");
    }

    /// No overlapped accepts on POSIX.
    pub fn absorbCompletion(self: *Listener, ov: ?*std.os.windows.OVERLAPPED, bytes: usize, err: ?usize) io.ListenerCompletion {
        _ = self;
        _ = ov;
        _ = bytes;
        _ = err;
        return .unknown;
    }

    /// Always 0 on POSIX: closing the fd ends every operation.
    pub fn pendingOps(self: *const Listener) usize {
        _ = self;
        return 0;
    }

    /// The bound address (the chosen port after binding to port 0).
    pub fn localAddress(self: *const Listener) io.LocalAddressError!std.net.Address {
        if (self.sock < 0) return io.LocalAddressError.SocketError;
        @panic("born: Listener.localAddress before born#18");
    }

    pub fn handle(self: *const Listener) types.Handle {
        return self.sock;
    }

    /// Call `purgeFd(handle())` first, as for any descriptor.
    pub fn close(self: *Listener) void {
        self.unix.deinit();
        if (self.sock >= 0) std.posix.close(self.sock);
        self.sock = -1;
    }
};
