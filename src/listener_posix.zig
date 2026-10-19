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
//! `acceptNb`, `register`, `localAddress` and `close` act on `sock` alone,
//! whatever its address family: a Unix listener is a `Listener` whose
//! `sock` is a listening AF_UNIX stream socket, drained the same way.

const std = @import("std");
const builtin = @import("builtin");
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const unix_posix = @import("unix_posix.zig");
const PlainNb = @import("socket_posix.zig").PlainNb;
const posix = std.posix;

/// Darwin has no accept4; its flags are applied with fcntl after accept.
const have_accept4 = !builtin.os.tag.isDarwin();

/// IPV6_V6ONLY per target (std has no BSD value).
const IPV6_V6ONLY: u32 = switch (builtin.os.tag) {
    .linux => 26,
    else => 27, // FreeBSD, NetBSD, OpenBSD, Darwin
};

/// The socket option behind `.balanced`, or null where the kernel can only
/// share a port without balancing.
const balanced_option: ?u32 = switch (builtin.os.tag) {
    .freebsd => posix.SO.REUSEPORT_LB,
    .linux => posix.SO.REUSEPORT,
    else => null,
};

pub const Listener = struct {
    sock: posix.fd_t = -1,
    /// Unix-socket state (e.g. the bound path), owned by unix_posix.zig.
    unix: unix_posix.ListenerState = .{},

    /// TCP listener on `addr` (port 0 picks one; see `localAddress`).
    /// `.balanced` is SO_REUSEPORT_LB on FreeBSD and SO_REUSEPORT on Linux;
    /// error.Unsupported elsewhere. Every listener sharing the port must ask
    /// for `.balanced` (and, on Linux, run as the same user).
    pub fn openTcp(alloc: std.mem.Allocator, addr: std.net.Address, opts: io.ListenOptions) io.ListenError!Listener {
        _ = alloc;
        const reuse: ?u32 = switch (opts.reuse_port) {
            .none => null,
            .balanced => balanced_option orelse return io.ListenError.Unsupported,
        };
        const family = addr.any.family;
        if (family != posix.AF.INET and family != posix.AF.INET6) return io.ListenError.SocketError;

        const s = posix.socket(family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch |err| return switch (err) {
            error.AccessDenied => io.ListenError.AccessDenied,
            else => io.ListenError.SocketError,
        };
        errdefer posix.close(s);

        try setFlag(s, posix.SOL.SOCKET, posix.SO.REUSEADDR, true);
        if (family == posix.AF.INET6) try setFlag(s, posix.IPPROTO.IPV6, IPV6_V6ONLY, opts.v6_only);
        if (reuse) |opt| try setFlag(s, posix.SOL.SOCKET, opt, true);

        posix.bind(s, &addr.any, addr.getOsSockLen()) catch |err| return switch (err) {
            error.AddressInUse => io.ListenError.AddressInUse,
            error.AccessDenied => io.ListenError.AccessDenied,
            else => io.ListenError.SocketError,
        };
        posix.listen(s, opts.backlog) catch |err| return switch (err) {
            error.AddressInUse => io.ListenError.AddressInUse,
            else => io.ListenError.SocketError,
        };
        return .{ .sock = s };
    }

    /// Unix stream listener at `path`; see unix_posix.zig.
    pub fn openUnix(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
        return unix_posix.listen(alloc, path, opts);
    }

    /// Persistent edge-triggered read interest on the listening fd. A
    /// refused registration surfaces from the next `wait()`.
    pub fn register(self: *Listener, evp: *evport.EvPort, udata: ?*anyopaque) io.ListenerRegisterError!void {
        if (self.sock < 0) return io.ListenerRegisterError.SocketError;
        evp.monitorRead(self.sock, udata);
    }

    /// Accept one connection into `out` (constructed in place), or report
    /// `.want_accept` when the backlog is drained. Peer resets before
    /// accept are skipped; descriptor exhaustion is error.ResourceExhausted.
    /// `key` is the stream's udata for IOCP association, unused here:
    /// register the accepted stream's read interest yourself, as after
    /// startConnectInto.
    ///
    /// Skipped inside the call: ECONNABORTED and EPROTO everywhere; on
    /// Linux also the network errors accept(2) passes through from the new
    /// connection (ENETDOWN, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH,
    /// EOPNOTSUPP, ENETUNREACH) and EPERM (firewall). Each skip consumes one
    /// dead connection, so the loop is bounded by the backlog.
    ///
    /// error.ResourceExhausted (EMFILE, ENFILE, ENOBUFS, ENOMEM) leaves the
    /// connection queued on FreeBSD and Linux; Darwin's kernel drops that
    /// one connection instead. Pause the listener with `unmonitorRead(handle())`
    /// rather than spinning; after closing connections, `register` again and
    /// call `acceptNb` until `.want_accept` at once, since the connections
    /// already queued produce no new edge.
    ///
    /// The peer address is `getpeername(out.handle())`.
    pub fn acceptNb(self: *Listener, out: *PlainNb, key: ?*anyopaque) io.AcceptError!io.AcceptResult {
        _ = key;
        if (self.sock < 0) return io.AcceptError.SocketError;
        std.debug.assert(out.sock == -1);
        while (true) {
            const rc = if (have_accept4)
                std.c.accept4(self.sock, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC)
            else
                std.c.accept(self.sock, null, null);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return .want_accept,
                .CONNABORTED, .PROTO => continue,
                .MFILE, .NFILE, .NOBUFS, .NOMEM => return io.AcceptError.ResourceExhausted,
                else => |e| {
                    if (comptime builtin.os.tag == .linux) {
                        if (linuxSkip(e)) continue;
                    }
                    return io.AcceptError.SocketError;
                },
            }
            const fd: posix.fd_t = @intCast(rc);
            if (!have_accept4) try setAcceptFlags(fd);
            out.adoptAccepted(fd, null, null) catch |err| switch (err) {
                // Darwin: the peer was gone before SO_NOSIGPIPE could be set.
                error.SocketError => continue,
                error.ResourceExhausted => return err,
            };
            return .accepted;
        }
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

    /// The bound address (the chosen port after binding to port 0, or the
    /// path of a Unix listener).
    pub fn localAddress(self: *const Listener) io.LocalAddressError!std.net.Address {
        if (self.sock < 0) return io.LocalAddressError.SocketError;
        var ss: posix.sockaddr.storage = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(self.sock, @ptrCast(&ss), &len) catch return io.LocalAddressError.SocketError;
        const sa: *const posix.sockaddr = @ptrCast(&ss);
        switch (sa.family) {
            posix.AF.INET, posix.AF.INET6 => return std.net.Address.initPosix(@ptrCast(&ss)),
            posix.AF.UNIX => {
                // getsockname may omit the path's NUL; zero-fill so it stays terminated.
                var un = std.mem.zeroes(posix.sockaddr.un);
                const n = @min(@as(usize, len), @sizeOf(posix.sockaddr.un));
                @memcpy(std.mem.asBytes(&un)[0..n], std.mem.asBytes(&ss)[0..n]);
                return .{ .un = un };
            },
            else => return io.LocalAddressError.SocketError,
        }
    }

    pub fn handle(self: *const Listener) types.Handle {
        return self.sock;
    }

    /// Call `purgeFd(handle())` first, as for any descriptor.
    pub fn close(self: *Listener) void {
        self.unix.deinit();
        if (self.sock >= 0) posix.close(self.sock);
        self.sock = -1;
    }
};

/// Boolean socket option; any refusal is error.SocketError.
fn setFlag(s: posix.fd_t, level: i32, opt: u32, on: bool) io.ListenError!void {
    const v: c_int = @intFromBool(on);
    posix.setsockopt(s, level, opt, std.mem.asBytes(&v)) catch return io.ListenError.SocketError;
}

/// Errors Linux accept(2) reports for a connection that died while queued;
/// accept(2) says to treat them like EAGAIN and retry.
fn linuxSkip(e: posix.E) bool {
    return switch (e) {
        .NETDOWN, .NOPROTOOPT, .HOSTDOWN, .NONET, .HOSTUNREACH, .OPNOTSUPP, .NETUNREACH, .PERM => true,
        else => false,
    };
}

/// Darwin: accept4's flags by fcntl. A fork between accept and F_SETFD can
/// leak the fd into the child; Darwin offers no atomic form.
fn setAcceptFlags(fd: posix.fd_t) io.AcceptError!void {
    errdefer posix.close(fd);
    const fl = posix.fcntl(fd, posix.F.GETFL, 0) catch return io.AcceptError.SocketError;
    _ = posix.fcntl(fd, posix.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"))) catch return io.AcceptError.SocketError;
    _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch return io.AcceptError.SocketError;
}
