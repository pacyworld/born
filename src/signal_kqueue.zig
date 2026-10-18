//! Signals on kqueue (EVFILT_SIGNAL). Owned by born#15: this file plus the
//! EvPort.watchSignal/unwatchSignal bodies in evport_kqueue.zig.
//!
//! Registration goes through `EvPort.stageRaw`. wait() hands every
//! EVFILT_SIGNAL kevent to `observe` before translating it into
//! Event{ .signal, .fired, .udata }.
//!
//! Stub until #15 lands: `watch` returns error.Unsupported.

const std = @import("std");
const kq = @import("evport_kqueue.zig");
const EvPort = kq.EvPort;
const SignalError = kq.SignalError;
const Signal = kq.Signal;

/// Per-port watch bookkeeping, a field of EvPort (`signals`).
pub const State = struct {
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Restores every disposition the port changed.
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

/// Sees each EVFILT_SIGNAL kevent first; false suppresses it.
pub fn observe(port: *EvPort, kev: kq.Kevent) bool {
    _ = port;
    _ = kev;
    return true;
}

/// kqueue needs no blocked mask: EVFILT_SIGNAL records deliveries under any
/// disposition. A documented no-op so portable programs call it always.
pub fn blockSignals(sigs: []const Signal) SignalError!void {
    _ = sigs;
}
