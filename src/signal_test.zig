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
    const BOOL = std.os.windows.BOOL;
    const HANDLE = std.os.windows.HANDLE;
    extern "kernel32" fn GenerateConsoleCtrlEvent(dwCtrlEvent: u32, dwProcessGroupId: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn AllocConsole() callconv(.winapi) BOOL;
    extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
    extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleProcessList(lpdwProcessList: [*]u32, dwProcessCount: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetStdHandle(nStdHandle: u32, hHandle: ?HANDLE) callconv(.winapi) BOOL;
    const ATTACH_PARENT_PROCESS: u32 = 0xFFFFFFFF;
    /// STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE.
    const std_ids = [3]u32{ 0xFFFFFFF6, 0xFFFFFFF5, 0xFFFFFFF4 };

    /// This process is the only one attached to its console.
    fn consoleIsOwn() bool {
        var pids: [4]u32 = undefined;
        const n = GetConsoleProcessList(&pids, pids.len);
        return n == 1 and pids[0] == GetCurrentProcessId();
    }
};

/// Windows: a console event generated for process group 0 reaches every
/// process on the console, which can include the runner's parents (the
/// ssh shell, `zig build`, the CI step's PowerShell). `isolate` moves the
/// test process onto a new console of its own and checks that it is alone
/// there, so `raise` reaches only this process. Changing consoles clears
/// the process's console handlers, so isolate before watching. The standard
/// handles are kept, and `restore` returns to the parent's console. A
/// no-op on POSIX.
const Console = struct {
    saved: [3]?win.HANDLE = .{ null, null, null },
    attached: bool = false,

    fn isolate() !Console {
        if (!is_windows) return .{};
        var self: Console = .{};
        for (win.std_ids, &self.saved) |id, *h| h.* = win.GetStdHandle(id);
        self.attached = win.FreeConsole() != 0;
        if (win.AllocConsole() == 0) {
            const err = std.os.windows.GetLastError();
            self.restore();
            std.debug.print("skip: AllocConsole failed ({t}); console events need a console of the test's own\n", .{err});
            return error.SkipZigTest;
        }
        self.keepStdHandles();
        if (!win.consoleIsOwn()) {
            self.restore();
            return error.TestUnexpectedResult;
        }
        return self;
    }

    fn restore(self: Console) void {
        if (!is_windows) return;
        _ = win.FreeConsole();
        if (self.attached) _ = win.AttachConsole(win.ATTACH_PARENT_PROCESS);
        self.keepStdHandles();
    }

    fn keepStdHandles(self: Console) void {
        for (win.std_ids, self.saved) |id, h| _ = win.SetStdHandle(id, h);
    }
};

fn raise(sig: Signal) !void {
    if (is_windows) {
        const ctrl: u32 = switch (sig) {
            .interrupt => 0, // CTRL_C_EVENT
            .terminate => 1, // CTRL_BREAK_EVENT
            else => return error.TestUnexpectedResult,
        };
        // Never signal a console shared with other processes.
        if (!win.consoleIsOwn()) return error.TestUnexpectedResult;
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
    const console = try Console.isolate();
    defer console.restore();
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
    const console = try Console.isolate();
    defer console.restore();
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
    const console = try Console.isolate();
    defer console.restore();
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
    const console = try Console.isolate();
    defer console.restore();
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, .terminate, &tag);
    defer port.unwatchSignal(.terminate);
    inline for (.{ Signal.hangup, Signal.user1, Signal.user2 }) |sig| {
        try std.testing.expectError(error.Unsupported, port.watchSignal(sig, &tag));
    }
}

test "signal: Windows CTRL_C arrives as interrupt and unwatch restores CTRL+C ignoring" {
    if (!is_windows) return error.SkipZigTest;
    const console = try Console.isolate();
    defer console.restore();
    const windows = std.os.windows;
    const params = windows.peb().ProcessParameters;
    const ignored_before = params.ConsoleFlags & 1 != 0;
    defer _ = windows.kernel32.SetConsoleCtrlHandler(null, @intFromBool(ignored_before));
    // Start ignoring CTRL+C, as a process in a new process group does: the
    // watch must clear that and its unwatch set it again.
    if (windows.kernel32.SetConsoleCtrlHandler(null, windows.TRUE) == 0) return error.TestUnexpectedResult;

    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var tag: u8 = 0;
    try watchOrSkip(&port, .interrupt, &tag);
    try std.testing.expect(params.ConsoleFlags & 1 == 0);
    try raise(.interrupt);
    var seen: std.ArrayList(Event) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, .interrupt, &seen, 2000, 1);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].udata == @as(?*anyopaque, &tag));
    try std.testing.expectEqual(@as(u32, 1), seen.items[0].fired);
    port.unwatchSignal(.interrupt);
    try std.testing.expect(params.ConsoleFlags & 1 != 0);
}
