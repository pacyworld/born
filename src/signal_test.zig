//! Signal contract (born 0.3.0). Every test calls the real API and skips
//! while the backend returns error.Unsupported; a signal implementation
//! issue is done when these run and pass on its OS.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("root.zig");
const Event = born.Event;
const Signal = born.Signal;
const alloc = std.testing.allocator;
const is_windows = builtin.os.tag == .windows;

/// The signal the portable tests raise: SIGUSR1 on POSIX, CTRL_BREAK
/// (`.terminate`) on Windows, where `.user1` does not exist.
const probe: Signal = if (is_windows) .terminate else .user1;

const win = struct {
    extern "kernel32" fn GenerateConsoleCtrlEvent(dwCtrlEvent: u32, dwProcessGroupId: u32) callconv(.winapi) std.os.windows.BOOL;
};

fn raise(sig: Signal) !void {
    if (is_windows) {
        const ctrl: u32 = switch (sig) {
            .interrupt => 0, // CTRL_C_EVENT
            .terminate => 1, // CTRL_BREAK_EVENT
            else => return error.TestUnexpectedResult,
        };
        if (win.GenerateConsoleCtrlEvent(ctrl, 0) == 0) return error.TestUnexpectedResult;
    } else {
        // Process-directed: XNU's EVFILT_SIGNAL does not see a thread-directed raise(3).
        try std.posix.kill(std.c.getpid(), sig.toPosix());
    }
}

/// blockSignals then watchSignal, skipping while either is Unsupported.
fn watchOrSkip(port: *born.EvPort, sig: Signal, udata: ?*anyopaque) !void {
    born.blockSignals(&.{sig}) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
    port.watchSignal(sig, udata) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

/// Signal events for `sig` harvested within `window_ms`, stopping early
/// once `stop` have arrived.
fn collect(port: *born.EvPort, sig: Signal, seen: *std.ArrayList(Event), window_ms: u64, stop: usize) !void {
    var events: [8]Event = undefined;
    var timer = try std.time.Timer.start();
    while (seen.items.len < stop) {
        const elapsed = timer.read() / std.time.ns_per_ms;
        if (elapsed >= window_ms) break;
        const n = try port.wait(&events, @intCast(window_ms - elapsed));
        for (events[0..n]) |ev| {
            if (ev.wake) continue;
            try std.testing.expectEqual(@as(?Signal, sig), ev.signal);
            try std.testing.expect(!ev.timer and !ev.readable and !ev.writable and !ev.err);
            try std.testing.expect(ev.fired >= 1);
            try seen.append(alloc, ev);
        }
    }
}

test "signal: Signal maps to and from POSIX numbers" {
    if (is_windows) return error.SkipZigTest;
    inline for (std.meta.fields(Signal)) |field| {
        const sig: Signal = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?Signal, sig), Signal.fromPosix(sig.toPosix()));
    }
    try std.testing.expectEqual(@as(u8, std.posix.SIG.TERM), Signal.terminate.toPosix());
    try std.testing.expect(Signal.fromPosix(std.posix.SIG.WINCH) == null);
    try std.testing.expect(Signal.fromPosix(0) == null);
}

test "signal: a raised signal arrives as one event" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, probe, &tag);
    defer port.unwatchSignal(probe);
    try raise(probe);
    var seen: std.ArrayList(Event) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, probe, &seen, 2000, 1);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].udata == @as(?*anyopaque, &tag));
    try collect(&port, probe, &seen, 50, std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
}

test "signal: raises before a wait coalesce into one event" {
    // Windows posts one completion per console event; coalescing is the
    // POSIX contract (kqueue data, signalfd's single pending instance).
    if (is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, probe, &tag);
    defer port.unwatchSignal(probe);
    try raise(probe);
    try raise(probe);
    var seen: std.ArrayList(Event) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, probe, &seen, 300, std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].fired >= 1);
}

test "signal: terminate is delivered instead of ending the process" {
    if (is_windows) return error.SkipZigTest; // the portable test uses it there
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, .terminate, &tag);
    defer port.unwatchSignal(.terminate);
    try raise(.terminate);
    var seen: std.ArrayList(Event) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, .terminate, &seen, 2000, 1);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
}

var user2_hits: u32 = 0;
fn onUser2(_: c_int) callconv(.c) void {
    user2_hits += 1;
}

test "signal: unwatch restores the prior disposition" {
    if (is_windows) return error.SkipZigTest;
    const signo = Signal.user2.toPosix();
    var original: std.posix.Sigaction = undefined;
    const custom: std.posix.Sigaction = .{ .handler = .{ .handler = onUser2 }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(signo, &custom, &original);
    defer std.posix.sigaction(signo, &original, null);

    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, .user2, &tag);
    port.unwatchSignal(.user2);
    var now: std.posix.Sigaction = undefined;
    std.posix.sigaction(signo, null, &now);
    try std.testing.expect(now.handler.handler == custom.handler.handler);
}

test "signal: a second port cannot watch the same signal" {
    var first = try born.EvPort.init(alloc);
    defer first.deinit();
    var second = try born.EvPort.init(alloc);
    defer second.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&first, probe, &tag);
    try std.testing.expectError(error.SignalInUse, second.watchSignal(probe, &tag));
    first.unwatchSignal(probe);
    try second.watchSignal(probe, &tag);
    second.unwatchSignal(probe);
}

test "signal: unwatching an unwatched signal is a no-op" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, probe, &tag);
    port.unwatchSignal(probe);
    port.unwatchSignal(probe);
    port.unwatchSignal(.hangup);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "signal: Windows has only interrupt and terminate" {
    if (!is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, .terminate, &tag);
    defer port.unwatchSignal(.terminate);
    inline for (.{ Signal.hangup, Signal.user1, Signal.user2 }) |sig| {
        try std.testing.expectError(error.Unsupported, port.watchSignal(sig, &tag));
    }
}
