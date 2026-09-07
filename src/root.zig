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
//! ## Contract, common to every backend
//!
//!   - ONE syscall per `wait()` carries staged registrations AND harvests
//!     events. Registration is never a separate call.
//!   - Sockets: read interest is persistent and edge-triggered, so handlers
//!     MUST fully drain. Write interest is one-shot, re-armed on demand via
//!     `wantWrite`.
//!   - fds are never deleted while closed or recycled. The caller defers
//!     `close()` to a reap point immediately after `wait()` has flushed the
//!     staged changelist. `unmonitorRead`/`cancelWrite` are for fds that STAY
//!     OPEN.
//!   - `wake()` posts a loop wakeup from any thread (pipe / eventfd / IOCP
//!     post) and is delivered as a single `Event{ .wake = true }`.
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
//!   macos / ios / ...  compiles clean, NOT yet run on hardware
//!   netbsd / openbsd / dragonfly
//!                      compiles clean, NOT yet run on hardware
//!
//! The kqueue backend uses only `std.c` and `std.posix` with no
//! FreeBSD-specific syscalls or `builtin.os.tag` branching, which is why the
//! other kqueue platforms come along for free. "Free" here means it builds,
//! not that anyone has run it. Do not claim otherwise without a test run.

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
pub const Event = impl.Event;
pub const Error = impl.Error;

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
}
