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

pub const NbRead = io.NbRead;
pub const NbWrite = io.NbWrite;
pub const ConnectError = io.ConnectError;
pub const ConnectDoneError = io.ConnectDoneError;
pub const ReadError = io.ReadError;
pub const WriteError = io.WriteError;
pub const IoError = io.IoError;
pub const CompletionKind = io.CompletionKind;
pub const PlainNb = impl.PlainNb;

pub const ReusePort = io.ReusePort;
pub const ListenOptions = io.ListenOptions;
pub const UnixOptions = io.UnixOptions;
pub const AcceptResult = io.AcceptResult;
pub const ListenerCompletion = io.ListenerCompletion;
pub const ListenError = io.ListenError;
pub const ListenerRegisterError = io.ListenerRegisterError;
pub const AcceptError = io.AcceptError;
pub const LocalAddressError = io.LocalAddressError;
pub const ConnectUnixError = io.ConnectUnixError;
pub const Listener = listener.Listener;
