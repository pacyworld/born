//! Listening stream sockets for POSIX readiness event ports.
//!
//! `register` adds persistent edge-triggered read interest on the listening
//! descriptor. On each read event the consumer calls `acceptNb` until
//! `.want_accept`. Accepted streams are ordinary `PlainNb` streams.
//! `absorbCompletion` and `pendingOps` preserve the portable IOCP-facing shape
//! and are intentional no-ops here.
//!
//! `acceptNb`, `register`, `localAddress`, and `close` act on `sock` alone,
//! whatever its address family. A Unix listener has a listening AF_UNIX stream
//! socket in `sock` and is drained the same way as TCP.

const std = @import("std");
const builtin = @import("builtin");
const evport = @import("root.zig");
const types = @import("types.zig");
const io = @import("io_types.zig");
const unix_posix = @import("unix_posix.zig");
const PlainNb = @import("socket_posix.zig").PlainNb;
const compat = @import("compat");

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
    .freebsd => compat.SO.REUSEPORT_LB,
    .linux => compat.SO.REUSEPORT,
    else => null,
};

/// Non-blocking TCP and Unix domain stream listener for readiness event ports.
///
/// The listener owns its descriptor. Purge event-port registrations for that
/// descriptor before calling `close`.
pub const Listener = struct {
    sock: compat.fd_t = -1,
    /// Unix-socket state (e.g. the bound path), owned by unix_posix.zig.
    unix: unix_posix.ListenerState = .{},
    /// Connections the last readable event reported; see `hintReadable`.
    hint: io.ReadyHint = .{},

    /// TCP listener on `addr` (port 0 picks one; see `localAddress`).
    /// `.balanced` is SO_REUSEPORT_LB on FreeBSD and SO_REUSEPORT on Linux;
    /// error.Unsupported elsewhere. Every listener sharing the port must ask
    /// for `.balanced` (and, on Linux, run as the same user).
    pub fn openTcp(alloc: std.mem.Allocator, addr: compat.Address, opts: io.ListenOptions) io.ListenError!Listener {
        _ = alloc;
        const reuse: ?u32 = switch (opts.reuse_port) {
            .none => null,
            .balanced => balanced_option orelse return io.ListenError.Unsupported,
        };
        const family = addr.any.family;
        if (family != compat.AF.INET and family != compat.AF.INET6) return io.ListenError.SocketError;

        const s = compat.socket(family, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, compat.IPPROTO.TCP) catch |err| return switch (err) {
            error.AccessDenied => io.ListenError.AccessDenied,
            else => io.ListenError.SocketError,
        };
        errdefer compat.close(s);

        try setFlag(s, compat.SOL.SOCKET, compat.SO.REUSEADDR, true);
        if (family == compat.AF.INET6) try setFlag(s, compat.IPPROTO.IPV6, IPV6_V6ONLY, opts.v6_only);
        if (reuse) |opt| try setFlag(s, compat.SOL.SOCKET, opt, true);

        compat.bind(s, &addr.any, addr.getOsSockLen()) catch |err| return switch (err) {
            error.AddressInUse => io.ListenError.AddressInUse,
            error.AccessDenied => io.ListenError.AccessDenied,
            else => io.ListenError.SocketError,
        };
        compat.listen(s, opts.backlog) catch |err| return switch (err) {
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
        // Every exit but a successful accept forgets the count, so a resume
        // after ResourceExhausted drains to EAGAIN.
        errdefer self.hint.clear();
        while (true) {
            if (self.hint.exhausted()) return .want_accept;
            const rc = if (have_accept4)
                std.c.accept4(self.sock, null, null, compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC)
            else
                std.c.accept(self.sock, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => self.hint.consume(1),
                .INTR => continue,
                .AGAIN => {
                    self.hint.clear();
                    return .want_accept;
                },
                .CONNABORTED, .PROTO => {
                    self.hint.consume(1);
                    continue;
                },
                .MFILE, .NFILE, .NOBUFS, .NOMEM => return io.AcceptError.ResourceExhausted,
                else => |e| {
                    if (comptime builtin.os.tag == .linux) {
                        if (linuxSkip(e)) {
                            self.hint.consume(1);
                            continue;
                        }
                    }
                    return io.AcceptError.SocketError;
                },
            }
            const fd: compat.fd_t = @intCast(rc);
            if (!have_accept4) try setAcceptFlags(fd);
            out.adoptAccepted(fd, null, null) catch |err| switch (err) {
                // Darwin: the peer was gone before SO_NOSIGPIPE could be set.
                error.SocketError => continue,
                error.ResourceExhausted => return err,
            };
            return .accepted;
        }
    }

    /// Record the pending-connection count of a readable listener event
    /// (`Event.avail` on kqueue; unknown elsewhere). `acceptNb` then answers
    /// `.want_accept` without the accept that would only return EAGAIN once
    /// that many connections were taken. Call it on every readable event
    /// before the first `acceptNb`; each event replaces the previous count.
    pub fn hintReadable(self: *Listener, ev: types.Event) void {
        self.hint.arm(ev);
    }

    /// No overlapped accepts on POSIX.
    pub fn absorbCompletion(self: *Listener, ov: ?*compat.windows.OVERLAPPED, bytes: usize, err: ?usize) io.ListenerCompletion {
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

    /// The bound address: the chosen port after binding to port 0, or the
    /// caller's path for a Unix listener. A Unix listener returns its stored
    /// path rather than getsockname, because anchored bind records the final
    /// component (FreeBSD) or the /proc/self/fd form (Linux) in the kernel. A
    /// client's getpeername on those platforms reports that anchored name, not
    /// this path; the listener's own address is unaffected.
    pub fn localAddress(self: *const Listener) io.LocalAddressError!compat.Address {
        if (self.sock < 0) return io.LocalAddressError.SocketError;
        if (self.unix.local_un.family == compat.AF.UNIX) return .{ .un = self.unix.local_un };
        var ss: compat.sockaddr.storage = undefined;
        var len: compat.socklen_t = @sizeOf(compat.sockaddr.storage);
        compat.getsockname(self.sock, @ptrCast(&ss), &len) catch return io.LocalAddressError.SocketError;
        const sa: *const compat.sockaddr = @ptrCast(&ss);
        switch (sa.family) {
            compat.AF.INET, compat.AF.INET6 => return compat.Address.initPosix(@ptrCast(&ss)),
            else => return io.LocalAddressError.SocketError,
        }
    }

    /// Returns the listening descriptor without transferring ownership.
    pub fn handle(self: *const Listener) types.Handle {
        return self.sock;
    }

    /// Call `purgeFd(handle())` first, as for any descriptor.
    pub fn close(self: *Listener) void {
        self.unix.deinit();
        if (self.sock >= 0) compat.close(self.sock);
        self.sock = -1;
    }
};

/// Boolean socket option; any refusal is error.SocketError.
fn setFlag(s: compat.fd_t, level: i32, opt: u32, on: bool) io.ListenError!void {
    const v: c_int = @intFromBool(on);
    compat.setsockopt(s, level, opt, std.mem.asBytes(&v)) catch return io.ListenError.SocketError;
}

/// Errors Linux accept(2) reports for a connection that died while queued;
/// accept(2) says to treat them like EAGAIN and retry.
fn linuxSkip(e: compat.E) bool {
    return switch (e) {
        .NETDOWN, .NOPROTOOPT, .HOSTDOWN, .NONET, .HOSTUNREACH, .OPNOTSUPP, .NETUNREACH, .PERM => true,
        else => false,
    };
}

/// Darwin: accept4's flags by fcntl. A fork between accept and F_SETFD can
/// leak the fd into the child; Darwin offers no atomic form.
fn setAcceptFlags(fd: compat.fd_t) io.AcceptError!void {
    errdefer compat.close(fd);
    const fl = compat.fcntl(fd, compat.F.GETFL, 0) catch return io.AcceptError.SocketError;
    const nonblock: u32 = @bitCast(@as(compat.O, .{ .NONBLOCK = true }));
    _ = compat.fcntl(fd, compat.F.SETFL, fl | @as(usize, nonblock)) catch return io.AcceptError.SocketError;
    _ = compat.fcntl(fd, compat.F.SETFD, compat.FD_CLOEXEC) catch return io.AcceptError.SocketError;
}
