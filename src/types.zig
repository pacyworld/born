const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

/// Platform-native descriptor: a Windows `HANDLE` or a POSIX file descriptor.
pub const Handle = if (builtin.os.tag == .windows) compat.windows.HANDLE else compat.fd_t;

/// Signals a port can watch (`EvPort.watchSignal`). Windows maps console
/// control events onto `interrupt` and `terminate` only.
pub const Signal = enum {
    /// Interactive interrupt, such as Ctrl+C or `SIGINT`.
    interrupt,
    /// Termination request, such as `SIGTERM` or a Windows console close event.
    terminate,
    /// Terminal hangup (`SIGHUP`) on POSIX.
    hangup,
    /// Application-defined signal 1 (`SIGUSR1`) on POSIX.
    user1,
    /// Application-defined signal 2 (`SIGUSR2`) on POSIX.
    user2,

    /// Native signal number. POSIX targets only.
    pub fn toPosix(self: Signal) u8 {
        const SIG = std.posix.SIG;
        return switch (self) {
            .interrupt => compat.signalNumber(SIG.INT),
            .terminate => compat.signalNumber(SIG.TERM),
            .hangup => compat.signalNumber(SIG.HUP),
            .user1 => compat.signalNumber(SIG.USR1),
            .user2 => compat.signalNumber(SIG.USR2),
        };
    }

    /// Inverse of `toPosix`; null for any signal outside this enum.
    pub fn fromPosix(signo: usize) ?Signal {
        inline for (comptime compat.enumFields(Signal)) |field| {
            const sig: Signal = @enumFromInt(field.value);
            if (signo == sig.toPosix()) return sig;
        }
        return null;
    }
};

/// `EvPort.addTimer` mode.
pub const TimerMode = enum {
    /// Fire once, then remove the timer.
    once,
    /// Fire repeatedly every `after_ms` until cancelled.
    repeat,
};

/// `EvPort.init`, the same on every backend.
pub const InitError = error{
    /// The kernel refused the port or its wake source (epoll set, eventfd,
    /// kqueue, `EVFILT_USER` knote, wake pipe, completion port).
    SystemResources,
    /// Port bookkeeping allocation failed.
    OutOfMemory,
};

/// `EvPort.addTimer`, the same on every backend.
pub const TimerError = error{
    /// Timers are not available on this backend or target.
    Unsupported,
    /// `.repeat` with `after_ms == 0`.
    InvalidArgument,
    /// The kernel refused a timer resource (timerfd, thread-pool timer).
    SystemResources,
    /// Timer bookkeeping allocation failed.
    OutOfMemory,
};

/// `EvPort.watchSignal` and `blockSignals`, the same on every backend.
pub const SignalError = error{
    /// The signal cannot be watched on this backend (e.g. `.user1` on Windows).
    Unsupported,
    /// Another port in this process already watches the signal.
    SignalInUse,
    /// epoll only: the signal is not blocked in the calling thread, so
    /// signalfd would never see it. Call `blockSignals` first.
    SignalNotBlocked,
    /// The kernel refused a signal resource (signalfd, console handler).
    SystemResources,
    /// Signal bookkeeping allocation failed.
    OutOfMemory,
};

/// `EvPort.watchProcess`, the same on every backend.
pub const ProcessError = error{
    /// Process watches are not available on this backend or target.
    Unsupported,
    /// The handle is not open or not a process descriptor. Supported FreeBSD
    /// and epoll paths reject negative handles immediately; epoll also rejects
    /// non-pidfds with a signal-0 probe. An ordinary FreeBSD kernel refusal is
    /// deferred to `wait()` as `err=true`, native `err_no`, `exited=false`,
    /// and `exit=null`, ending that watch.
    BadHandle,
    /// The kernel refused a watch resource (the epoll process set).
    SystemResources,
    /// Process-watch bookkeeping allocation failed.
    OutOfMemory,
};

/// How a watched process ended (`Event.exit`).
pub const ProcessExit = union(enum) {
    /// exit(2) status, 0 to 255.
    code: u8,
    /// Number of the signal that terminated the process.
    signal: u8,

    /// Decodes a wait(2) status word. Null for a stopped or continued
    /// status, which is not an exit.
    pub fn fromWaitStatus(status: u32) ?ProcessExit {
        const sig: u8 = @intCast(status & 0x7f);
        if (sig == 0) return .{ .code = @intCast((status >> 8) & 0xff) };
        if (sig == 0x7f) return null;
        return .{ .signal = sig };
    }
};

/// Notification harvested by `EvPort.wait` on every backend.
pub const Event = struct {
    /// Caller token supplied at registration or post time, if any.
    udata: ?*anyopaque = null,
    /// POSIX read readiness. Always false for raw IOCP completions.
    readable: bool = false,
    /// POSIX write readiness. Always false for raw IOCP completions.
    writable: bool = false,
    /// The native source reported end-of-stream or an equivalent hangup.
    eof: bool = false,
    /// A native error or registration rejection was reported.
    err: bool = false,
    /// Optional native error payload: kqueue errno for a rejected change,
    /// epoll `waitid` errno for a process-harvest failure, or IOCP NTSTATUS
    /// from the completion's `Internal` field. Zero when no payload is
    /// available, including epoll readiness errors.
    err_no: usize = 0,
    /// Cross-thread wakeup requested through `wake()` or an IOCP wake post.
    wake: bool = false,
    /// Which operation completed (the companion classifies by address). Null
    /// for relay posts without an operation and on POSIX.
    overlapped: ?*compat.windows.OVERLAPPED = null,
    /// Byte count supplied by an IOCP completion or post; zero on POSIX.
    bytes: usize = 0,
    /// A timer fired; `udata` is the timer's.
    timer: bool = false,
    /// A watched signal arrived; `udata` is the watch's.
    signal: ?Signal = null,
    /// Number of timer expirations or watched signal deliveries represented
    /// by this event. Zero for every other event.
    fired: u32 = 0,
    /// Readiness count the kernel attached to a readable event: bytes buffered
    /// on a stream or connections queued on a listener (kqueue `data` of
    /// `EVFILT_READ`). Zero means unknown and is all epoll and IOCP report.
    /// Pass the event to `PlainNb.hintReadable` or `Listener.hintReadable` to
    /// avoid the trailing `EAGAIN` call after consuming the reported count.
    avail: usize = 0,
    /// A watched process exited; `udata` is the watch's. The watch ends
    /// with this event. With `err` clear, `exit` says how it ended; with
    /// `err` set (epoll: the status could not be collected), `exit` is null
    /// and `err_no` holds the errno, or is zero when the status is owned by
    /// a tracer or a racing wait outside born.
    exited: bool = false,
    /// Exit code or terminating signal when `exited` is set and `err` is
    /// clear; null for other events and when the status cannot be collected.
    exit: ?ProcessExit = null,
};
