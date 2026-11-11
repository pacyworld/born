//! born: an event port for Zig.
//!
//! One small, uniform seam over the platform's native readiness/completion
//! notification mechanism. Named for the Born rule: I/O waits in potential
//! until `wait()` collapses it into a concrete event.
//!
//! - FreeBSD, macOS, and other supported BSD targets use kqueue.
//! - Linux uses epoll and eventfd.
//! - Windows uses IOCP.
//!
//! ## Programming models
//!
//! - kqueue batches registrations and events in one kevent call; epoll applies
//!   registrations immediately with epoll_ctl. IOCP harvests completions.
//! - POSIX socket reads are persistent and edge-triggered: fully drain. kqueue
//!   writes are one-shot; epoll writes remain armed until canceled. IOCP users
//!   submit overlapped operations, not readiness registrations.
//! - POSIX callers purge staged changes before closing at the end-of-batch reap
//!   point. Windows callers cancel and close, then drain every pending
//!   completion before moving or freeing overlapped storage.
//! - `wake()` signals the loop from another thread. POSIX wakeups coalesce;
//!   IOCP posts one completion per wake. `Event.wake` identifies either form.
//! - Registration failures use backend-specific reporting. epoll and IOCP
//!   `monitorRead` failures are deferred to the next non-empty `wait()`; IOCP
//!   `associate` fails immediately. kqueue reports kernel rejections as
//!   `Event.err` and `Event.err_no`, and stashes allocation failures for the
//!   same deferred channel. IOCP post and wake failures use that channel too.
//!   The kqueue eventlist-overflow exception is documented in docs/kqueue.md.
//! - Regular files are portable readiness sources. kqueue reports them ready
//!   natively, and epoll emulates that with always-ready pseudo registrations.
//! - Process exits from `EvPort.watchProcess` arrive as `Event.exited` and
//!   `Event.exit`: EVFILT_PROCDESC on FreeBSD, pidfds on Linux 5.4+ after a
//!   spawn-time probe, and `error.Unsupported` elsewhere.
//! - Timers, signals, TCP listeners, and Unix sockets share `wait()`. Windows
//!   Unix socket operations currently return `error.Unsupported`.
//!
//! The checked target triples and runtime evidence are listed in the README.
//! Cross-compilation is not runtime verification.

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

/// Event port for the compile-time-selected native backend.
pub const EvPort = impl.EvPort;
/// Native descriptor or Windows handle used by the event port.
pub const Handle = @import("types.zig").Handle;
/// Notification harvested by `EvPort.wait`.
pub const Event = @import("types.zig").Event;
/// Signal that can be watched through `EvPort`.
pub const Signal = @import("types.zig").Signal;
/// One-shot or repeating timer mode.
pub const TimerMode = @import("types.zig").TimerMode;
/// Exit status reported for a watched child process.
pub const ProcessExit = @import("types.zig").ProcessExit;
/// Errors produced while initializing an event port.
pub const InitError = impl.InitError;
/// Event-loop and deferred registration or post errors from `EvPort.wait`.
pub const WaitError = impl.WaitError;
/// Errors produced by timer operations.
pub const TimerError = impl.TimerError;
/// Errors produced by signal operations.
pub const SignalError = impl.SignalError;
/// Errors produced by process watch operations.
pub const ProcessError = impl.ProcessError;
/// Union of event-port operation error sets.
pub const Error = impl.Error;
/// Block signals in the calling thread before watching them. Required on
/// epoll (signalfd), a no-op on kqueue and Windows. Call it in `main`
/// before spawning threads.
pub const blockSignals = impl.blockSignals;
/// Portable plaintext stream and listener companions.
pub const socket = @import("socket.zig");
/// Child processes behind a descriptor, for `EvPort.watchProcess`.
pub const process = @import("process.zig");

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
    // Supplement real calls with declaration analysis for the selected backend.
    std.testing.refAllDecls(impl);
    _ = @import("api_test.zig");
    _ = @import("socket_test.zig");
    _ = @import("timer_heap.zig");
    _ = @import("timer_test.zig");
    _ = @import("signal_test.zig");
    _ = @import("listener_test.zig");
    _ = @import("unix_test.zig");
    _ = @import("io_types.zig");
    _ = @import("hint_test.zig");
    _ = @import("process.zig");
    _ = @import("process_test.zig");
    _ = @import("compat_test.zig");
}
