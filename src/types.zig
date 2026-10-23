const std = @import("std");
const builtin = @import("builtin");

pub const Handle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;

/// Signals a port can watch (`EvPort.watchSignal`). Windows maps console
/// control events onto `interrupt` and `terminate` only.
pub const Signal = enum {
    interrupt,
    terminate,
    hangup,
    user1,
    user2,

    /// Native signal number. POSIX targets only.
    pub fn toPosix(self: Signal) u8 {
        const SIG = std.posix.SIG;
        return switch (self) {
            .interrupt => SIG.INT,
            .terminate => SIG.TERM,
            .hangup => SIG.HUP,
            .user1 => SIG.USR1,
            .user2 => SIG.USR2,
        };
    }

    /// Inverse of `toPosix`; null for any signal outside this enum.
    pub fn fromPosix(signo: usize) ?Signal {
        inline for (std.meta.fields(Signal)) |field| {
            const sig: Signal = @enumFromInt(field.value);
            if (signo == sig.toPosix()) return sig;
        }
        return null;
    }
};

/// `EvPort.addTimer` mode. `.repeat` re-fires every `after_ms`.
pub const TimerMode = enum { once, repeat };

/// `EvPort.addTimer`, the same on every backend.
pub const TimerError = error{
    /// Timers are not available on this backend or target.
    Unsupported,
    /// `.repeat` with `after_ms == 0`.
    InvalidArgument,
    /// The kernel refused a timer resource (timerfd, thread-pool timer).
    SystemResources,
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
    OutOfMemory,
};

pub const Event = struct {
    udata: ?*anyopaque = null,
    readable: bool = false, // unused on IOCP (the conn classifies)
    writable: bool = false, // unused on IOCP
    eof: bool = false,
    err: bool = false,
    /// EV_ERROR payload (errno) when err is set on kqueue.
    err_no: usize = 0, // NTSTATUS from the completion's Internal field on IOCP
    wake: bool = false,
    /// Which operation completed (conn classifies by address). Null when
    /// the completion carries no op (relay posts), or on POSIX.
    overlapped: ?*std.os.windows.OVERLAPPED = null,
    bytes: usize = 0,
    /// A timer fired; `udata` is the timer's.
    timer: bool = false,
    /// A watched signal arrived; `udata` is the watch's.
    signal: ?Signal = null,
    /// Timer expirations or signal deliveries coalesced into this event
    /// (kqueue `data`, timerfd count, signalfd count; 1 on IOCP). Zero
    /// for every other event.
    fired: u32 = 0,
    /// Readiness count the kernel attached to a readable event: bytes
    /// buffered on a stream, connections queued on a listener (kqueue
    /// `data` of EVFILT_READ). 0 means unknown, and is all that epoll and
    /// IOCP ever report. Pass the event to `PlainNb.hintReadable` or
    /// `Listener.hintReadable` to skip the trailing EAGAIN call.
    avail: usize = 0,
};
