/// Non-blocking read outcome.
pub const NbRead = union(enum) {
    data: usize, // > 0 bytes unless the caller supplied an empty buffer
    want_read, // drained or receive pending; wait for the next read event/completion
    want_write, // TLS-only (post-handshake control messages); never for plain
    eof, // clean close
};

/// Non-blocking write outcome.
pub const NbWrite = union(enum) {
    done: usize, // bytes accepted (may be a partial write)
    want_read, // TLS-only; never for plain
    want_write, // send buffer full or send pending; wait for the write event/completion
};

// Each stream operation returns exactly the errors it can produce, so
// consumers can switch over them with no `else` prong.

/// `PlainNb.startConnectInto` / `startConnect`.
pub const ConnectError = error{ ConnectFailed, SocketError, OutOfMemory };
/// `PlainNb.startConnectAddrInto`: no resolver, so no OutOfMemory.
pub const ConnectAddrError = error{ ConnectFailed, SocketError };
/// `PlainNb.connectDone`.
pub const ConnectDoneError = error{ ConnectFailed, SocketError };
/// `PlainNb.readNb`.
pub const ReadError = error{SocketError};
/// `PlainNb.writeNb`.
pub const WriteError = error{SocketError};

/// Every stream error. A catch-all for callers that want one bucket; it may
/// grow, so exhaustive switches belong on the per-operation sets above.
pub const IoError = ConnectError || ConnectDoneError || ReadError || WriteError;

// Which overlapped op a completion belongs to.
pub const CompletionKind = enum { recv, send, connect, unknown };

// ------------------------------------------------------------ listeners ----

/// `.balanced`: the kernel spreads connections across listeners bound to
/// one port (SO_REUSEPORT_LB on FreeBSD, SO_REUSEPORT on Linux). Targets
/// that can only share without balancing return error.Unsupported.
pub const ReusePort = enum { none, balanced };

pub const ListenOptions = struct {
    backlog: u31 = 511,
    reuse_port: ReusePort = .none,
    /// IPv6 addresses only: refuse IPv4-mapped connections.
    v6_only: bool = true,
    /// IOCP: AcceptEx operations kept outstanding (minimum 1). Ignored on
    /// POSIX, where `acceptNb` drains the kernel queue directly.
    accept_depth: u16 = 4,
};

pub const UnixOptions = struct {
    /// Permission bits applied to the socket file with no wider window.
    mode: u16 = 0o660,
    /// Replace a stale socket file (connect refused). A live listener at
    /// the path is never unlinked: error.AddressInUse.
    unlink_stale: bool = true,
};

/// `Listener.acceptNb` outcome. Drain until `.want_accept`.
pub const AcceptResult = enum { accepted, want_accept };

/// Which listener op a completion belongs to (IOCP AcceptEx). Separate from
/// CompletionKind: a stream never sees an accept, a listener never a recv.
pub const ListenerCompletion = enum { accept, unknown };

/// `Listener.openTcp` / `openUnix`.
pub const ListenError = error{
    /// Not available on this target, or `.balanced` where the kernel cannot
    /// balance (macOS, NetBSD, OpenBSD, Windows).
    Unsupported,
    /// A live listener holds the address or socket path.
    AddressInUse,
    /// Privileged port, or no permission on the socket path.
    AccessDenied,
    /// The Unix socket path does not fit `sun_path`; never truncated.
    NameTooLong,
    /// `unlink_stale` found a file at the path that is not a socket.
    PathNotASocket,
    SocketError,
    OutOfMemory,
};

/// `Listener.register`.
pub const ListenerRegisterError = error{SocketError};

/// `Listener.acceptNb`.
pub const AcceptError = error{
    /// Out of descriptors or kernel memory (EMFILE, ENFILE, ENOBUFS, ENOMEM).
    /// Pause the listener (`unmonitorRead`) instead of spinning; resume
    /// after closing connections.
    ResourceExhausted,
    SocketError,
};

/// `Listener.localAddress`.
pub const LocalAddressError = error{SocketError};

/// `PlainNb.startConnectUnixInto`.
pub const ConnectUnixError = error{
    Unsupported,
    NameTooLong,
    /// The listener's backlog is full (EAGAIN); reported, not retried.
    BacklogFull,
    ConnectFailed,
    SocketError,
    OutOfMemory,
};

// ------------------------------------------------------ readiness counts ----

/// Readiness count carried from `Event.avail` into the next drain loop
/// (POSIX streams and listeners). `left` is how many bytes or connections the
/// kernel reported; once consumed, the next call answers "drained" without a
/// syscall that could only return EAGAIN. Null means unknown: do the call.
///
/// Safe with edge-triggered readiness: anything that arrives after the kernel
/// took the count raises a new event, so stopping at the count never strands
/// data. Each readable event replaces the hint, and every error, EOF or
/// EAGAIN path clears it.
pub const ReadyHint = struct {
    left: ?usize = null,

    /// Take the count from a readable event. EOF events and unknown (0)
    /// counts leave the stream or listener draining to EAGAIN or EOF.
    pub fn arm(self: *ReadyHint, ev: @import("types.zig").Event) void {
        self.left = if (ev.avail > 0 and !ev.eof and !ev.err) ev.avail else null;
    }

    /// True once the reported count is used up. Clears the hint.
    pub fn exhausted(self: *ReadyHint) bool {
        const l = self.left orelse return false;
        if (l != 0) return false;
        self.left = null;
        return true;
    }

    /// `n` bytes or connections were taken from the kernel.
    pub fn consume(self: *ReadyHint, n: usize) void {
        if (self.left) |l| self.left = l -| n;
    }

    pub fn clear(self: *ReadyHint) void {
        self.left = null;
    }
};

test "ReadyHint counts down to exhaustion and clears" {
    const std = @import("std");
    var h: ReadyHint = .{};
    try std.testing.expect(!h.exhausted());
    h.arm(.{ .readable = true, .avail = 5 });
    try std.testing.expect(!h.exhausted());
    h.consume(2);
    try std.testing.expect(!h.exhausted());
    h.consume(9);
    try std.testing.expect(h.exhausted());
    try std.testing.expect(!h.exhausted());
    h.arm(.{ .readable = true, .avail = 0 });
    try std.testing.expectEqual(@as(?usize, null), h.left);
    h.arm(.{ .readable = true, .eof = true, .avail = 7 });
    try std.testing.expectEqual(@as(?usize, null), h.left);
    h.arm(.{ .readable = true, .avail = 3 });
    h.clear();
    try std.testing.expect(!h.exhausted());
}
