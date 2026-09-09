//! born -- an event port for Zig.
//!
//! One small, uniform seam over the platform's native readiness/completion
//! notification mechanism. Named for the Born rule: I/O waits in potential
//! until `wait()` collapses it into a concrete event.
//!
//!   FreeBSD / macOS / *BSD  kqueue   (evport_kqueue.zig)
//!   Linux                   epoll + eventfd  (evport_epoll.zig)
//!   Windows                 IOCP     (evport_iocp.zig)
//!
//! ## Programming models (see README for the portable socket companion)
//!
//!   - kqueue batches registrations and events in one kevent call; epoll
//!     applies registrations immediately with epoll_ctl. IOCP harvests completions.
//!   - POSIX socket reads are persistent and edge-triggered: fully drain.
//!     kqueue writes are one-shot; epoll writes remain armed until canceled.
//!     IOCP users submit overlapped operations, not readiness registrations.
//!   - POSIX: purge staged changes before closing at the end-of-batch reap
//!     point. unmonitorRead/cancelWrite apply to handles that remain open.
//!     Windows: cancel/close, then drain every pending completion before
//!     moving or freeing the stream's OVERLAPPED storage.
//!   - wake() signals the loop from another thread. POSIX wakeups coalesce;
//!     IOCP posts a completion per wake. Event.wake identifies either form.
//!   - A failed registration is never silent: epoll/IOCP return it as an
//!     error from the next non-empty wait(); kqueue delivers kernel
//!     rejections as Event.err/err_no and stashes allocation failures the
//!     same deferred way. Caution: epoll refuses regular files (EPERM)
//!     while kqueue accepts them as perpetually ready — classify inherited
//!     stdio before registering it.
//!
//! ## Provenance
//!
//! Extracted from mcp-bridge, where these backends have been in production
//! since 2026-08 and carry the scar tissue to prove it: the epoll `EPOLLET`
//! write deadlock (edge-triggering applies to the whole registration, so
//! EPOLLOUT goes edge-triggered after connect completes), the kqueue
//! changelist rule that one rejected entry makes the kernel abandon the rest
//! of the batch, and FreeBSD loopback connect returning ECONNREFUSED
//! synchronously under load.
//!
//! ## Platform status
//!
//!   freebsd            production (mcp-bridge, since 2026-08)
//!   linux              production (mcp-bridge, since 2026-08)
//!   windows            production (mcp-bridge, since 2026-08)
//!   aarch64/x86_64 macos: compile-only, NOT yet run on hardware
//!   x86_64 netbsd / openbsd: compile-only, NOT yet run on hardware
//!   Other selected OS tags are outside the checked target matrix.
//!
//! The checked triples are listed in build.zig and README. CI compiles
//! the actual test bodies rather than relying on lazy library analysis.
//! Cross-compilation is not runtime verification. Do not claim a platform
//! has been tested without executing its tests on that platform.

const std = @import("std");
const builtin = @import("builtin");

/// Comptime backend selection. The `@import`s behind a comptime-known
/// `builtin.os.tag` are never analyzed on other targets, so each platform
/// compiles only its own backend.
const impl = switch (builtin.os.tag) {
    .freebsd, .netbsd, .openbsd, .dragonfly => @import("evport_kqueue.zig"),
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => @import("evport_kqueue.zig"),
    .linux => @import("evport_epoll.zig"),
    .windows => @import("evport_iocp.zig"),
    else => @compileError("born: no event port backend for this OS"),
};

pub const EvPort = impl.EvPort;
pub const Handle = @import("types.zig").Handle;
pub const Event = @import("types.zig").Event;
pub const Error = impl.Error;
pub const socket = @import("socket.zig");

/// Which backend this build selected. Useful in diagnostics so a program can
/// report what it is actually running on rather than what it assumes.
pub const backend_name: []const u8 = switch (builtin.os.tag) {
    .freebsd, .netbsd, .openbsd, .dragonfly => "kqueue",
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => "kqueue",
    .linux => "epoll",
    .windows => "iocp",
    else => unreachable,
};

test {
    // Pull in the selected backend's own tests.
    std.testing.refAllDecls(impl);
    _ = impl;
    _ = @import("api_test.zig");
    _ = @import("socket_test.zig");
}
