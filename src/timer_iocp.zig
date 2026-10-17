//! Timers on IOCP: one thread-pool timer per port plus the deadline heap
//! (timer_heap.zig). Owned by born#14: this file plus the
//! EvPort.addTimer/cancelTimer bodies in evport_iocp.zig.
//!
//! The thread-pool callback touches no born state: it only
//! `post(EvPort.internalKey(.timer), null, 0)`. wait() hands that completion
//! to `harvest` on the loop thread, which expires the heap, writes one Event
//! per expired timer and re-arms the thread-pool timer. `State.deinit` stops
//! and drains the callback before the port handle closes.
//!
//! Stub until #14 lands: `add` returns error.Unsupported.

const std = @import("std");
const iocp = @import("evport_iocp.zig");
const EvPort = iocp.EvPort;
const Event = iocp.Event;
const TimerError = iocp.TimerError;
const TimerMode = iocp.TimerMode;

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Cancels the thread-pool timer and waits for its callbacks.
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

/// Handles one internal timer completion (`payload` is its byte count).
/// Writes at most `out.len` (>= 1) events and returns the count; timers
/// that do not fit stay due for the next wait().
pub fn harvest(port: *EvPort, payload: usize, out: []Event) usize {
    _ = port;
    _ = payload;
    _ = out;
    // Unreachable by construction: the stub `add` never starts a timer.
    @panic("born: timer_iocp.harvest without a running timer");
}
