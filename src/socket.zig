//! `PlainNb` is the portable plaintext stream socket, and `Listener` is its
//! accept-side companion.
//!
//! POSIX uses readiness notifications: callers drain non-blocking operations
//! until a `want_*` result. Windows uses IOCP: callers submit overlapped
//! operations and pass each completion to `absorbCompletion` before continuing.
//!
//! The POSIX `startConnect` convenience returns `PlainNb` by value because it
//! has no overlapped storage. Windows constructs streams in caller-provided
//! storage, which must remain stable until every completion is drained.
//! AcceptEx slots and their address buffers live in a stable listener-owned
//! allocation, independently of the listener value's address.

const builtin = @import("builtin");
const io = @import("io_types.zig");
const is_windows = builtin.os.tag == .windows;
const impl = switch (builtin.os.tag) {
    .windows => @import("socket_windows.zig"),
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .linux,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .driverkit,
    => @import("socket_posix.zig"),
    else => @compileError("born: no plain socket backend for this OS"),
};
const listener = if (is_windows) @import("listener_windows.zig") else @import("listener_posix.zig");

/// Non-blocking read outcome.
pub const NbRead = io.NbRead;
/// Non-blocking write outcome.
pub const NbWrite = io.NbWrite;
/// Hostname TCP connect errors.
pub const ConnectError = io.ConnectError;
/// Resolved-address TCP connect errors.
pub const ConnectAddrError = io.ConnectAddrError;
/// Connect completion errors.
pub const ConnectDoneError = io.ConnectDoneError;
/// Stream read errors.
pub const ReadError = io.ReadError;
/// Stream write errors.
pub const WriteError = io.WriteError;
/// Union of plain stream setup and established-stream I/O errors.
pub const IoError = io.IoError;
/// Overlapped stream operation classification.
pub const CompletionKind = io.CompletionKind;
/// Portable plaintext stream socket.
pub const PlainNb = impl.PlainNb;

/// Listener port-sharing policy.
pub const ReusePort = io.ReusePort;
/// TCP listener options.
pub const ListenOptions = io.ListenOptions;
/// Unix listener options on POSIX.
pub const UnixOptions = io.UnixOptions;
/// Non-blocking accept outcome.
pub const AcceptResult = io.AcceptResult;
/// Overlapped listener operation classification.
pub const ListenerCompletion = io.ListenerCompletion;
/// Listener creation errors.
pub const ListenError = io.ListenError;
/// Listener event-port registration errors.
pub const ListenerRegisterError = io.ListenerRegisterError;
/// Accept and accepted-stream adoption errors.
pub const AcceptError = io.AcceptError;
/// Listener local-address query errors.
pub const LocalAddressError = io.LocalAddressError;
/// Unix stream connect errors.
pub const ConnectUnixError = io.ConnectUnixError;
/// Portable non-blocking stream listener.
pub const Listener = listener.Listener;
