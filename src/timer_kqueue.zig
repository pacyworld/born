//! Timers on kqueue (EVFILT_TIMER). Owned by born#12: this file plus the
//! EvPort.addTimer/cancelTimer bodies in evport_kqueue.zig.
//!
//! Registration goes through `EvPort.stageRaw`; no kevent() call outside
//! wait(). wait() hands every EVFILT_TIMER kevent to `observe` before
//! translating it into Event{ .timer, .fired, .udata }.
//!
//! Stub until #12 lands: `add` returns error.Unsupported.

const std = @import("std");
const kq = @import("evport_kqueue.zig");
const EvPort = kq.EvPort;
const TimerError = kq.TimerError;
const TimerMode = kq.TimerMode;

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    pub fn deinit(self: *State, port: *EvPort) void {
        _ = self;
        _ = port;
    }
};

pub fn add(port: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
    _ = port;
    _ = id;
    _ = udata;
    _ = after_ms;
    _ = mode;
    return TimerError.Unsupported;
}

/// No timer can be live while `add` is a stub, so there is nothing to cancel.
pub fn cancel(port: *EvPort, id: u32) void {
    _ = port;
    _ = id;
}

/// Sees each EVFILT_TIMER kevent first; false suppresses it.
pub fn observe(port: *EvPort, kev: kq.Kevent) bool {
    _ = port;
    _ = kev;
    return true;
}
