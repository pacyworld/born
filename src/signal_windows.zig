//! Signals on Windows: console control events. Owned by born#17: this file
//! plus the EvPort.watchSignal/unwatchSignal bodies in evport_iocp.zig.
//!
//! One SetConsoleCtrlHandler routine maps CTRL_C_EVENT to `.interrupt` and
//! CTRL_BREAK/CLOSE/SHUTDOWN_EVENT to `.terminate`. It only
//! `post(EvPort.internalKey(.signal), null, @intFromEnum(sig))`; wait()
//! hands that to `harvest`. `.hangup`, `.user1` and `.user2` are
//! error.Unsupported. The handler is removed before the port closes.
//!
//! Stub until #17 lands: `watch` returns error.Unsupported.

const std = @import("std");
const iocp = @import("evport_iocp.zig");
const EvPort = iocp.EvPort;
const Event = iocp.Event;
const SignalError = iocp.SignalError;
const Signal = iocp.Signal;

/// Per-port watch bookkeeping, a field of EvPort (`signals`).
pub const State = struct {
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Removes the console handler if this port installed it.
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

/// Handles one internal signal completion (`payload` is the Signal
/// ordinal). Writes at most `out.len` (>= 1) events and returns the count.
pub fn harvest(port: *EvPort, payload: usize, out: []Event) usize {
    _ = port;
    _ = payload;
    _ = out;
    // Unreachable by construction: the stub `watch` never installs a handler.
    @panic("born: signal_windows.harvest without a console handler");
}

/// Windows has no signal mask to set: a documented no-op so portable
/// programs call it unconditionally.
pub fn blockSignals(sigs: []const Signal) SignalError!void {
    _ = sigs;
}
