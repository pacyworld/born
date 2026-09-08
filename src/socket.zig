const builtin = @import("builtin");
const io = @import("io_types.zig");
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

pub const NbRead = io.NbRead;
pub const NbWrite = io.NbWrite;
pub const IoError = io.IoError;
pub const CompletionKind = io.CompletionKind;
pub const PlainNb = impl.PlainNb;
