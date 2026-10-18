//! Signals on epoll: one signalfd per port. Owned by born#16: this file plus
//! the EvPort.watchSignal/unwatchSignal bodies in evport_epoll.zig, and
//! `blockSignals` (exported as `born.blockSignals`).
//!
//! signalfd only sees signals blocked in every thread, so programs call
//! `blockSignals` in `main` before spawning threads, and `watch` refuses an
//! unblocked signal with error.SignalNotBlocked. The signalfd is registered
//! with `EvPort.addInternal(.signal, fd)`; `harvest` reads siginfo records
//! and folds repeats of one signal into one Event with `.fired = count`.
//!
//! Stub until #16 lands: `watch` and `blockSignals` return error.Unsupported.

const std = @import("std");
const ep = @import("evport_epoll.zig");
const EvPort = ep.EvPort;
const Event = ep.Event;
const SignalError = ep.SignalError;
const Signal = ep.Signal;

/// Per-port watch bookkeeping, a field of EvPort (`signals`).
pub const State = struct {
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Releases process-wide ownership, removes the internal source and
    /// closes the signalfd.
    pub fn deinit(self: *State, port: *EvPort) void {
        _ = self;
        _ = port;
    }
};

pub fn watch(port: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
    _ = port;
    _ = sig;
    _ = udata;
    return SignalError.Unsupported;
}

/// No watch can be live while `watch` is a stub.
pub fn unwatch(port: *EvPort, sig: Signal) void {
    _ = port;
    _ = sig;
}

/// Turns a ready signalfd into at most `out.len` (>= 1) events and returns
/// the count. Failures are stashed in `port.pending_error` as
/// error.SourceFailed, never dropped.
pub fn harvest(port: *EvPort, out: []Event) usize {
    _ = port;
    _ = out;
    // Unreachable by construction: the stub `watch` never registers a signalfd.
    @panic("born: signal_epoll.harvest without a registered signalfd");
}

/// `pthread_sigmask(SIG_BLOCK)` for `sigs` in the calling thread.
pub fn blockSignals(sigs: []const Signal) SignalError!void {
    _ = sigs;
    return SignalError.Unsupported;
}
