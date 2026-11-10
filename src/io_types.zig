/// Non-blocking read outcome.
pub const NbRead = union(enum) {
    /// Bytes read; greater than zero unless the caller supplied an empty buffer.
    data: usize,
    /// Drained or receive pending; wait for the next read event or completion.
    want_read,
    /// TLS-only control-message result; plain streams never return it.
    want_write,
    /// Clean peer close.
    eof,
};

/// Non-blocking write outcome.
pub const NbWrite = union(enum) {
    /// Bytes accepted, possibly a partial write.
    done: usize,
    /// TLS-only control-message result; plain streams never return it.
    want_read,
    /// Send buffer full or send pending; wait for the write event or completion.
    want_write,
};

// Each stream operation returns exactly the errors it can produce, so
// consumers can switch over them with no `else` prong.

/// `PlainNb.startConnectInto` and POSIX `PlainNb.startConnect`.
pub const ConnectError = error{
    /// The connection could not be established.
    ConnectFailed,
    /// A native socket operation failed.
    SocketError,
    /// Hostname resolution allocation failed.
    OutOfMemory,
};
/// `PlainNb.startConnectAddrInto`: no resolver, so no `OutOfMemory`.
pub const ConnectAddrError = error{
    /// The connection could not be established.
    ConnectFailed,
    /// A native socket operation failed.
    SocketError,
};
/// `PlainNb.connectDone`.
pub const ConnectDoneError = error{
    /// The connection was refused or did not complete successfully.
    ConnectFailed,
    /// The stream is closed or its native socket state is invalid.
    SocketError,
};
/// `PlainNb.readNb`.
pub const ReadError = error{
    /// The native receive operation failed or the stream is closed.
    SocketError,
};
/// `PlainNb.writeNb`.
pub const WriteError = error{
    /// The native send operation failed or the stream is closed.
    SocketError,
};

/// Every plain stream setup and established-stream I/O error, including Unix
/// connects and accepted-stream adoption. This catch-all may grow, so
/// exhaustive switches belong on the per-operation sets.
pub const IoError =
    ConnectError ||
    ConnectUnixError ||
    AcceptError ||
    ConnectDoneError ||
    ReadError ||
    WriteError;

/// Overlapped stream operation classified by `PlainNb.absorbCompletion`.
pub const CompletionKind = enum {
    /// Receive completion.
    recv,
    /// Send completion.
    send,
    /// Connect completion.
    connect,
    /// No operation owned by this stream, or a POSIX no-op absorption.
    unknown,
};

/// Listener port-sharing policy.
pub const ReusePort = enum {
    /// Do not request port sharing.
    none,
    /// Spread connections across listeners bound to one port using
    /// `SO_REUSEPORT_LB` on FreeBSD or `SO_REUSEPORT` on Linux. Targets that
    /// can only share without balancing return `error.Unsupported`.
    balanced,
};

/// Options for `Listener.openTcp`.
pub const ListenOptions = struct {
    /// Maximum pending connection backlog requested from the kernel.
    backlog: u31 = 511,
    /// Port-sharing policy.
    reuse_port: ReusePort = .none,
    /// IPv6 addresses only: refuse IPv4-mapped connections.
    v6_only: bool = true,
    /// IOCP AcceptEx operations kept outstanding, with a minimum of one.
    /// Ignored on POSIX, where `acceptNb` drains the kernel queue directly.
    accept_depth: u16 = 4,
};

/// Options for `Listener.openUnix` on POSIX. Windows Unix socket operations
/// currently return `error.Unsupported`.
pub const UnixOptions = struct {
    /// Permission bits applied to the socket file with no wider window.
    mode: u16 = 0o660,
    /// Replace a stale socket file after a refused connect. A live listener
    /// returns `error.AddressInUse`. Path-based ownership checks require a
    /// trusted parent directory.
    unlink_stale: bool = true,
};

/// `Listener.acceptNb` outcome. Drain until `.want_accept`; later arrivals
/// can produce another event.
pub const AcceptResult = enum {
    /// One stream was accepted into the caller's destination.
    accepted,
    /// The currently reported or available accepts are drained, or all IOCP
    /// accept slots are occupied. Later arrivals can produce another event.
    want_accept,
};

/// Listener operation classified by `Listener.absorbCompletion` on IOCP.
pub const ListenerCompletion = enum {
    /// AcceptEx completion.
    accept,
    /// No accept operation owned by this listener, or a POSIX no-op absorption.
    unknown,
};

/// `Listener.openTcp` and `Listener.openUnix`.
pub const ListenError = error{
    /// Not available on this target, or `.balanced` where the kernel cannot
    /// balance (macOS, NetBSD, OpenBSD, Windows).
    Unsupported,
    /// The address or path is already bound. For Unix paths this includes a
    /// live listener and a stale path when `unlink_stale` is false.
    AddressInUse,
    /// Privileged port, or no permission on the socket path.
    AccessDenied,
    /// The Unix socket path does not fit `sun_path`; never truncated.
    NameTooLong,
    /// `unlink_stale` found a file at the path that is not a socket.
    PathNotASocket,
    /// A native socket operation failed.
    SocketError,
    /// Listener setup or accept-slot allocation failed.
    OutOfMemory,
};

/// `Listener.register`.
pub const ListenerRegisterError = error{
    /// Registration failed or the listener is closed.
    SocketError,
};

/// `Listener.acceptNb` and accepted-stream adoption.
pub const AcceptError = error{
    /// Out of descriptors or kernel memory (`EMFILE`, `ENFILE`, `ENOBUFS`, or
    /// `ENOMEM`). On POSIX, pause with `unmonitorRead`, close connections, then
    /// resume with `register`. On IOCP, `unmonitorRead` is a no-op; release
    /// resources and use `register` to replenish accept slots.
    ResourceExhausted,
    /// The listener is closed or unregistered, or native accept, stream
    /// adoption, Winsock setup, or event-port association failed.
    SocketError,
};

/// `Listener.localAddress`.
pub const LocalAddressError = error{
    /// The native address query failed or the listener is closed.
    SocketError,
};

/// `PlainNb.startConnectUnixInto`.
pub const ConnectUnixError = error{
    /// Unix sockets are not available on this target.
    Unsupported,
    /// The path does not fit `sun_path`; never truncated.
    NameTooLong,
    /// The listener's backlog is full (`EAGAIN`); reported, not retried.
    BacklogFull,
    /// The Unix connection could not be established.
    ConnectFailed,
    /// A native socket operation failed.
    SocketError,
};

/// Readiness count carried from `Event.avail` into the next drain loop on
/// POSIX streams and listeners. `left` is how many bytes or connections the
/// kernel reported; once consumed, the next call answers "drained" without a
/// syscall that could only return `EAGAIN`. Null means unknown: do the call.
///
/// Safe with edge-triggered readiness: anything that arrives after the kernel
/// took the count raises a new event, so stopping at the count never strands
/// data. Each readable event replaces the hint, and every error, EOF, or
/// `EAGAIN` path clears it.
pub const ReadyHint = struct {
    /// Remaining reported bytes or connections, or null when unknown.
    left: ?usize = null,

    /// Take the count from a readable event. EOF events and unknown (0)
    /// counts leave the stream or listener draining to `EAGAIN` or EOF.
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

    /// Record `n` bytes or connections taken from the kernel.
    pub fn consume(self: *ReadyHint, n: usize) void {
        if (self.left) |l| self.left = l -| n;
    }

    /// Discard the hint and restore drain-to-`EAGAIN` behavior.
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
