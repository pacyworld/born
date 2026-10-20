//! Timers on IOCP: one thread-pool timer per port plus the deadline heap
//! (timer_heap.zig). Owned by born#14: this file plus the
//! EvPort.addTimer/cancelTimer bodies in evport_iocp.zig.
//!
//! Deadlines live in the heap, on the QueryPerformanceCounter clock
//! (`timer_heap.nowNs`). The first `add` creates the port's thread-pool
//! timer; it is armed one-shot, relative, for the heap's earliest deadline.
//! Its callback touches no born state: it only
//! `post(EvPort.internalKey(.timer), null, fire_payload)`. wait() hands that
//! completion to `harvest` on the loop thread, which expires the heap at
//! now, writes one Event per expired timer and re-arms for the new head, or
//! disarms when no timer is left.
//!
//! Due timers that do not fit in wait()'s buffer stay in the heap, and
//! `harvest` posts one completion from the loop thread (`repost_payload`)
//! so the next wait() reports them. A `.once` timer with `after_ms = 0` is
//! due at once and takes the same path. Reposts coalesce: at most one is
//! queued at a time.
//!
//! The thread-pool timer is re-armed only when a new deadline is earlier
//! than the armed one, and `cancel` leaves it armed unless the heap is
//! empty. A firing with nothing due (a cancelled head, a stale firing, or
//! the thread-pool clock running slightly ahead of QPC) harvests no events
//! and re-arms, so wait() can return 0 before its timeout.
//!
//! The callback holds the EvPort's address: the port must not move from
//! its first `addTimer` until `deinit`. `add` and `harvest` panic if it did.
//! `State.deinit`, which EvPort.deinit calls before the port handle closes,
//! stops the timer and waits for running callbacks, so no post can race
//! CloseHandle (the #5 lifetime rule).

const std = @import("std");
const windows = std.os.windows;
const iocp = @import("evport_iocp.zig");
const timer_heap = @import("timer_heap.zig");
const EvPort = iocp.EvPort;
const Event = iocp.Event;
const TimerError = iocp.TimerError;
const TimerMode = iocp.TimerMode;

// Thread-pool timer API (threadpoolapiset.h), exported by kernel32.dll
// since Windows Vista and listed in mingw-w64's kernel32.def. Zig 0.15's
// std.os.windows does not declare it. All use the WINAPI convention.

/// PTP_TIMER: an opaque thread-pool timer object.
const TpTimer = opaque {};
/// PTP_CALLBACK_INSTANCE: identifies the running callback (unused here).
const TpCallbackInstance = opaque {};

/// PTP_TIMER_CALLBACK: `VOID CALLBACK (PTP_CALLBACK_INSTANCE, PVOID, PTP_TIMER)`.
const TimerCallback = *const fn (?*TpCallbackInstance, ?*anyopaque, *TpTimer) callconv(.winapi) void;

/// Returns null on failure. `pcbe` null selects the process default pool.
extern "kernel32" fn CreateThreadpoolTimer(
    pfnti: TimerCallback,
    pv: ?*anyopaque,
    pcbe: ?*anyopaque,
) callconv(.winapi) ?*TpTimer;

/// `pftDueTime` null stops the timer; a negative value is a relative due
/// time in 100 ns units. `msPeriod` 0 is one-shot; `msWindowLength` 0
/// disables coalescing. Replaces any earlier setting.
extern "kernel32" fn SetThreadpoolTimer(
    pti: *TpTimer,
    pftDueTime: ?*const windows.FILETIME,
    msPeriod: windows.DWORD,
    msWindowLength: windows.DWORD,
) callconv(.winapi) void;

/// Waits for running callbacks; TRUE also cancels queued ones.
extern "kernel32" fn WaitForThreadpoolTimerCallbacks(
    pti: *TpTimer,
    fCancelPendingCallbacks: windows.BOOL,
) callconv(.winapi) void;

extern "kernel32" fn CloseThreadpoolTimer(pti: *TpTimer) callconv(.winapi) void;

/// TRUE from SetThreadpoolTimer with a due time until SetThreadpoolTimer
/// with null. An expired one-shot still reports TRUE (Windows 11 26100).
extern "kernel32" fn IsThreadpoolTimerSet(pti: *TpTimer) callconv(.winapi) windows.BOOL;

/// Internal timer completion payloads (the posted byte count).
const fire_payload: usize = 0;
const repost_payload: usize = 1;

/// Expired entries taken from the heap per `expire` call in `harvest`.
const expire_batch = 64;

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    /// From EvPort.init; null only in a port not built by init.
    alloc: ?std.mem.Allocator = null,
    heap: timer_heap.TimerHeap = .empty,
    /// The thread-pool timer, created by the first `add`.
    tp: ?*TpTimer = null,
    /// The port address the callback posts to.
    owner: ?*EvPort = null,
    /// Deadline the thread-pool timer was last armed for, null when
    /// disarmed. Until the next harvest it may already have fired.
    armed_ns: ?u64 = null,
    /// A repost completion is queued and not yet harvested.
    reposted: bool = false,

    pub fn init(alloc: std.mem.Allocator) State {
        return .{ .alloc = alloc };
    }

    /// Stops the thread-pool timer, cancels queued callbacks and waits for
    /// running ones, then frees the heap. Queued timer completions die with
    /// the port; they carry no OVERLAPPED.
    pub fn deinit(self: *State, port: *EvPort) void {
        _ = port;
        if (self.tp) |tp| {
            SetThreadpoolTimer(tp, null, 0, 0);
            WaitForThreadpoolTimerCallbacks(tp, windows.TRUE);
            CloseThreadpoolTimer(tp);
        }
        if (self.alloc) |gpa| self.heap.deinit(gpa);
        self.* = .{};
    }

    /// The thread-pool timer, created on first use with `port` as the
    /// callback context.
    fn timer(self: *State, port: *EvPort) TimerError!*TpTimer {
        if (self.tp) |tp| {
            checkOwner(self, port);
            return tp;
        }
        const tp = CreateThreadpoolTimer(onTimer, port, null) orelse return TimerError.SystemResources;
        self.tp = tp;
        self.owner = port;
        return tp;
    }

    /// Makes sure the heap head is reported: re-posts when it is already
    /// due, arms the thread-pool timer when nothing armed fires by then.
    fn schedule(self: *State, port: *EvPort, now_ns: u64) void {
        const due = self.heap.next() orelse return;
        if (due <= now_ns) return self.repost(port);
        // An armed deadline in the past is a firing still in flight, or one
        // whose post failed (reported as error.PostFailed): arm again.
        if (self.armed_ns) |armed| {
            if (armed <= due and armed > now_ns) return;
        }
        self.arm(due, now_ns);
    }

    /// Arms the thread-pool timer, one-shot, for `due_ns` (> `now_ns`).
    fn arm(self: *State, due_ns: u64, now_ns: u64) void {
        const ticks = relativeTicks(due_ns - now_ns);
        const ft = relativeDueTime(ticks);
        SetThreadpoolTimer(self.tp.?, &ft, 0, 0);
        self.armed_ns = due_ns;
    }

    fn disarm(self: *State) void {
        if (self.tp) |tp| SetThreadpoolTimer(tp, null, 0, 0);
        self.armed_ns = null;
    }

    /// Queues one repost completion from the loop thread unless one is
    /// already queued. A failed post is stashed by post() and returned as
    /// error.PostFailed; the next repost then tries again.
    fn repost(self: *State, port: *EvPort) void {
        if (self.reposted) return;
        self.reposted = true;
        port.post(EvPort.internalKey(.timer), null, repost_payload);
        if (port.post_failed.load(.acquire)) self.reposted = false;
    }
};

/// Thread-pool callback. Touches no born state: one post, whose failure
/// post() stashes for the next wait().
fn onTimer(instance: ?*TpCallbackInstance, context: ?*anyopaque, tp: *TpTimer) callconv(.winapi) void {
    _ = instance;
    _ = tp;
    const port: *EvPort = @ptrCast(@alignCast(context.?));
    port.post(EvPort.internalKey(.timer), null, fire_payload);
}

fn checkOwner(state: *const State, port: *EvPort) void {
    if (state.owner) |owner| {
        if (owner != port) @panic("born: EvPort moved after its first addTimer");
    }
}

/// Nanoseconds to whole 100 ns ticks, rounded up so a timer never fires
/// before its deadline because of rounding.
fn relativeTicks(delta_ns: u64) u64 {
    return delta_ns / 100 + @intFromBool(delta_ns % 100 != 0);
}

/// A FILETIME holding the negative (relative) due time of `ticks`.
fn relativeDueTime(ticks: u64) windows.FILETIME {
    const clamped: i64 = @intCast(@min(ticks, std.math.maxInt(i64)));
    const raw: u64 = @bitCast(-clamped);
    return .{ .dwLowDateTime = @truncate(raw), .dwHighDateTime = @truncate(raw >> 32) };
}

/// QueryPerformanceCounter cannot fail on Windows XP and later, so
/// nowNs has no failing path on this backend.
fn now() u64 {
    return timer_heap.nowNs() catch |err| switch (err) {
        error.Unsupported => unreachable,
    };
}

/// Arms `id` on the port's thread-pool timer. Replaces a live id. On error
/// the port's timers are unchanged.
pub fn add(port: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
    if (mode == .repeat and after_ms == 0) return TimerError.InvalidArgument;
    const state = &port.timers;
    const gpa = state.alloc orelse return TimerError.Unsupported;
    _ = try state.timer(port);
    const after_ns = @as(u64, after_ms) * std.time.ns_per_ms;
    const period_ns: u64 = if (mode == .repeat) after_ns else 0;
    const now_ns = now();
    state.heap.add(gpa, now_ns, id, udata, after_ns, period_ns) catch |err| switch (err) {
        error.OutOfMemory => return TimerError.OutOfMemory,
    };
    state.schedule(port, now_ns);
}

/// Removes `id`; unknown or expired ids are a no-op. Disarms the
/// thread-pool timer when no timer is left.
pub fn cancel(port: *EvPort, id: u32) void {
    const state = &port.timers;
    if (!state.heap.cancel(id)) return;
    if (state.heap.count() == 0) state.disarm();
}

/// Handles one internal timer completion (`payload` is its byte count).
/// Writes at most `out.len` (>= 1) events and returns the count; timers
/// that do not fit stay due and are reposted for the next wait().
pub fn harvest(port: *EvPort, payload: usize, out: []Event) usize {
    const state = &port.timers;
    checkOwner(state, port);
    if (payload == repost_payload) state.reposted = false;
    const now_ns = now();
    var expired: [expire_batch]timer_heap.Expired = undefined;
    var n: usize = 0;
    while (n < out.len) {
        const want = @min(expired.len, out.len - n);
        const got = state.heap.expire(now_ns, expired[0..want]);
        for (expired[0..got]) |e| {
            out[n] = .{ .udata = e.udata, .timer = true, .fired = e.fired };
            n += 1;
        }
        if (got < want) break;
    }
    // This completion may be the armed firing, so the armed state is
    // unknown: set it again from the heap.
    if (state.heap.next()) |due| {
        if (due <= now_ns) {
            state.armed_ns = null;
            state.repost(port);
        } else {
            state.arm(due, now_ns);
        }
    } else {
        state.disarm();
    }
    return n;
}

// --------------------------------------------------------------- tests ----

const testing = std.testing;

extern "kernel32" fn GetProcessHandleCount(
    hProcess: windows.HANDLE,
    pdwHandleCount: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

fn handleCount() !u32 {
    var count: windows.DWORD = 0;
    if (GetProcessHandleCount(windows.GetCurrentProcess(), &count) == 0) return error.Unexpected;
    return count;
}

/// Spins on QPC for `us` microseconds; Sleep is too coarse for the
/// sub-millisecond offsets the teardown test needs.
fn spinUs(us: u64) void {
    const start = now();
    while (now() - start < us * std.time.ns_per_us) std.atomic.spinLoopHint();
}

/// Waits up to `window_ms` for at least one event.
fn waitOne(port: *EvPort, events: []Event, window_ms: i32) !usize {
    var t = try std.time.Timer.start();
    while (true) {
        const elapsed: i32 = @intCast(t.read() / std.time.ns_per_ms);
        if (elapsed >= window_ms) return 0;
        const n = try port.wait(events, window_ms - elapsed);
        if (n != 0) return n;
    }
}

test "timer_iocp: relative due times round up to 100 ns ticks" {
    try testing.expectEqual(@as(u64, 0), relativeTicks(0));
    try testing.expectEqual(@as(u64, 1), relativeTicks(1));
    try testing.expectEqual(@as(u64, 1), relativeTicks(100));
    try testing.expectEqual(@as(u64, 2), relativeTicks(101));
    try testing.expectEqual(@as(u64, 10_000), relativeTicks(std.time.ns_per_ms));
    const ft = relativeDueTime(10_000);
    const raw = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    try testing.expectEqual(@as(i64, -10_000), @as(i64, @bitCast(raw)));
    const far = relativeDueTime(std.math.maxInt(u64));
    const far_raw = (@as(u64, far.dwHighDateTime) << 32) | far.dwLowDateTime;
    try testing.expectEqual(-@as(i64, std.math.maxInt(i64)), @as(i64, @bitCast(far_raw)));
}

test "timer_iocp: the thread-pool timer is created lazily and armed for the head" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    try testing.expect(port.timers.tp == null);
    var tag: u8 = 1;
    try add(&port, 1, &tag, 5000, .once);
    const tp = port.timers.tp.?;
    try testing.expect(port.timers.owner == &port);
    try testing.expect(IsThreadpoolTimerSet(tp) != 0);
    try testing.expectEqual(port.timers.heap.deadlineOf(1), port.timers.armed_ns);
    // A later deadline keeps the earlier arm; an earlier one re-arms.
    try add(&port, 2, &tag, 9000, .once);
    try testing.expectEqual(port.timers.heap.deadlineOf(1), port.timers.armed_ns);
    try add(&port, 3, &tag, 2000, .once);
    try testing.expectEqual(port.timers.heap.deadlineOf(3), port.timers.armed_ns);
    try testing.expect(port.timers.tp.? == tp);
}

test "timer_iocp: cancelling the last timer disarms the thread-pool timer" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    try add(&port, 1, &tag, 30, .once);
    try add(&port, 2, &tag, 40, .repeat);
    cancel(&port, 1);
    try testing.expect(IsThreadpoolTimerSet(port.timers.tp.?) != 0);
    cancel(&port, 2);
    try testing.expect(IsThreadpoolTimerSet(port.timers.tp.?) == 0);
    try testing.expect(port.timers.armed_ns == null);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 80));
}

test "timer_iocp: re-adding a live id with an earlier deadline re-arms" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var a: u8 = 1;
    var b: u8 = 2;
    try add(&port, 1, &a, 60_000, .once);
    try add(&port, 1, &b, 10, .once);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 1000));
    try testing.expect(events[0].timer and events[0].udata == @as(?*anyopaque, &b));
    try testing.expectEqual(@as(u32, 1), events[0].fired);
    try testing.expectEqual(@as(usize, 0), port.timers.heap.count());
}

test "timer_iocp: due-now timers coalesce into one repost" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tags: [5]u8 = undefined;
    for (&tags, 0..) |*tag, i| try add(&port, @intCast(i), tag, 0, .once);
    try testing.expect(port.timers.reposted);
    var events: [16]Event = undefined;
    try testing.expectEqual(@as(usize, 5), try port.wait(&events, 1000));
    try testing.expect(!port.timers.reposted);
    // One completion carried all five: nothing else is queued.
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "timer_iocp: a short buffer reposts the rest for the next wait" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tags: [4]u8 = undefined;
    for (&tags, 0..) |*tag, i| try add(&port, @intCast(i), tag, 0, .once);
    var events: [1]Event = undefined;
    var seen: usize = 0;
    while (seen < tags.len) {
        try testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
        try testing.expect(events[0].timer);
        seen += 1;
        try testing.expectEqual(seen < tags.len, port.timers.reposted);
    }
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "timer_iocp: a firing with nothing due re-arms and reports nothing" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    try add(&port, 1, &tag, 40, .once);
    // A stale firing, as from a cancelled head or an early thread-pool tick.
    port.post(EvPort.internalKey(.timer), null, fire_payload);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    try testing.expect(IsThreadpoolTimerSet(port.timers.tp.?) != 0);
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 1000));
    try testing.expect(events[0].timer and events[0].udata == @as(?*anyopaque, &tag));
}

test "timer_iocp: repeat reports missed periods in fired" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    try add(&port, 1, &tag, 5, .repeat);
    // Miss several periods before the first harvest.
    std.Thread.sleep(60 * std.time.ns_per_ms);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 1000));
    try testing.expect(events[0].fired >= 2);
    cancel(&port, 1);
}

test "timer_iocp: allocation failure in add leaves the timers unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var port = try EvPort.init(failing.allocator());
    defer port.deinit();
    var tag: u8 = 1;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(TimerError.OutOfMemory, add(&port, 1, &tag, 0, .once));
    try testing.expectEqual(@as(usize, 0), port.timers.heap.count());
    try testing.expect(!port.timers.reposted);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 20));
    failing.fail_index = std.math.maxInt(usize);
    try add(&port, 1, &tag, 0, .once);
    try testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
}

test "timer_iocp: 1000 create/arm/deinit cycles with a timer due at teardown" {
    // Thread-pool timers fire on the system clock tick, so a 1 ms timer
    // fires 1 to about 16 ms after add. Measure that latency (the longest
    // of five, since it depends on the tick phase), then tear each cycle's
    // port down at an offset spread over twice it: deinit
    // meets a timer that is pending, a callback that is queued or running,
    // or a completion already posted. testing.allocator catches heap
    // leaks and the handle count leaked ports. A post racing CloseHandle
    // would fail and set post_failed.
    var tag: u8 = 1;
    var latency_us: u64 = 0;
    for (0..5) |_| {
        var warm = try EvPort.init(testing.allocator);
        defer warm.deinit();
        var events: [4]Event = undefined;
        const start = now();
        try add(&warm, 1, &tag, 1, .once);
        try testing.expectEqual(@as(usize, 1), try waitOne(&warm, &events, 1000));
        latency_us = @max(latency_us, (now() - start) / std.time.ns_per_us);
    }
    const steps = 33;
    const step_us = @max(1, 2 * latency_us / (steps - 1));
    const before = try handleCount();
    // Cycles that harvest before teardown, and how many saw their timer.
    var harvested: usize = 0;
    var fired: usize = 0;
    for (0..1000) |i| {
        var port = try EvPort.init(testing.allocator);
        try add(&port, @intCast(i), &tag, 1, if (i % 2 == 0) .once else .repeat);
        // 7 is coprime to 33, so every offset recurs in each residue class.
        spinUs((i * 7 % steps) * step_us);
        if (i % 8 == 7) {
            var events: [4]Event = undefined;
            harvested += 1;
            if (try port.wait(&events, 0) != 0) fired += 1;
        }
        port.deinit();
        try testing.expect(!port.post_failed.load(.acquire));
        try testing.expect(port.timers.tp == null);
    }
    // The offsets fall on both sides of the firing.
    try testing.expect(fired > 0 and fired < harvested);
    std.Thread.sleep(20 * std.time.ns_per_ms);
    // The thread pool may add worker threads (one handle each); a leaked
    // port per cycle would add about a thousand.
    const after = try handleCount();
    try testing.expect(after <= before + 32);
}
