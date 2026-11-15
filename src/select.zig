//! Single compile-time backend selection point.
//!
//! Every module that needs a platform backend resolves it here, so the
//! supported target set is stated once and stays aligned with
//! `supported_targets` in build.zig and the README platform table. Targets
//! outside that set fail here instead of selecting a backend whose
//! companion modules do not implement their ABI.

const builtin = @import("builtin");

/// Native notification mechanism behind the event port.
pub const Backend = enum { kqueue, epoll, iocp };

/// Backend for this build; the supported target set lives here.
pub const backend: Backend = switch (builtin.os.tag) {
    .freebsd, .netbsd, .openbsd, .macos => .kqueue,
    .linux => .epoll,
    .windows => .iocp,
    else => @compileError("born: unsupported target; supported triples are listed in build.zig"),
};

/// Event port module for the selected backend. The `@import`s behind the
/// comptime-known switch are never analyzed on other targets, so each
/// platform compiles only its own backend.
pub const impl = switch (backend) {
    .kqueue => @import("evport_kqueue.zig"),
    .epoll => @import("evport_epoll.zig"),
    .iocp => @import("evport_iocp.zig"),
};

/// Plain stream socket module for the selected backend.
pub const socket_impl = switch (backend) {
    .kqueue, .epoll => @import("socket_posix.zig"),
    .iocp => @import("socket_windows.zig"),
};

/// Listener module for the selected backend.
pub const listener_impl = switch (backend) {
    .kqueue, .epoll => @import("listener_posix.zig"),
    .iocp => @import("listener_windows.zig"),
};
