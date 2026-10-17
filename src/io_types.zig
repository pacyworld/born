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
