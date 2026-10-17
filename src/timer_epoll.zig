//! Timers on epoll: one timerfd per port plus the deadline heap
//! (timer_heap.zig). Owned by born#13: this file plus the
//! EvPort.addTimer/cancelTimer bodies in evport_epoll.zig.
//!
//! The timerfd is registered with `EvPort.addInternal(.timer, fd)`. wait()
//! calls `harvest` when it is ready; harvest reads it, expires the heap and
//! writes one Event per expired timer. Timers that do not fit stay due and
//! the timerfd is re-armed so the next wait() reports them.
//!
//! Stub until #13 lands: `add` returns error.Unsupported.

const std = @import("std");
const ep = @import("evport_epoll.zig");
const EvPort = ep.EvPort;
const Event = ep.Event;
const TimerError = ep.TimerError;
const TimerMode = ep.TimerMode;

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Removes the internal source and closes the timerfd.
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

/// No timer can be live while `add` is a stub.
pub fn cancel(port: *EvPort, id: u32) void {
    _ = port;
    _ = id;
}

/// Turns a ready timerfd into at most `out.len` (>= 1) events and returns
/// the count. Failures are stashed in `port.pending_error` as
/// error.SourceFailed, never dropped.
pub fn harvest(port: *EvPort, out: []Event) usize {
    _ = port;
    _ = out;
    // Unreachable by construction: the stub `add` never registers a timerfd.
    @panic("born: timer_epoll.harvest without a registered timerfd");
}
