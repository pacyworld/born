//! Timers on epoll: one timerfd per port plus the deadline heap
//! (timer_heap.zig). Owned by born#13: this file plus the
//! EvPort.addTimer/cancelTimer bodies in evport_epoll.zig.
//!
//! The first `add` creates a CLOCK_MONOTONIC timerfd and registers it with
//! `EvPort.addInternal(.timer, fd)` (level-triggered). The timerfd is kept
//! armed, absolute (TFD_TIMER_ABSTIME), at the heap's earliest deadline:
//! `add`, `cancel` and `harvest` re-arm it when the head changes, and an
//! empty heap disarms it. Thousands of timers cost one descriptor.
//!
//! wait() calls `harvest` when the timerfd is ready. It reads the timerfd,
//! expires the heap at the current monotonic time and writes one Event per
//! expired timer. Timers that do not fit in the caller's buffer stay due in
//! the heap; the timerfd is then armed at their deadline, which is already
//! past, so it is ready again and the next wait() reports them.
//!
//! Re-arming failures (timerfd_settime, the clock) and read failures are
//! stashed in `port.pending_error` as error.SourceFailed, which wait()
//! returns before blocking, so a timer that can no longer fire is never
//! silent.

const std = @import("std");
const linux = std.os.linux;
const timer_heap = @import("timer_heap.zig");
const ep = @import("evport_epoll.zig");
const EvPort = ep.EvPort;
const Event = ep.Event;
const TimerError = ep.TimerError;
const TimerMode = ep.TimerMode;

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    /// The timerfd, -1 until the first `add`.
    fd: i32 = -1,
    heap: timer_heap.TimerHeap = .empty,
    /// Absolute CLOCK_MONOTONIC deadline the timerfd is armed at, null
    /// while it is disarmed or has already fired and been read.
    armed: ?u64 = null,

    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Removes the internal source, closes the timerfd and frees the heap.
    pub fn deinit(self: *State, port: *EvPort) void {
        if (self.fd != -1) {
            port.removeInternal(.timer);
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
        self.heap.deinit(port.alloc);
        self.heap = .empty;
        self.armed = null;
    }

    /// Creates and registers the timerfd if it does not exist yet.
    fn ensureFd(self: *State, port: *EvPort) TimerError!void {
        if (self.fd != -1) return;
        const rc = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.E.init(rc) != .SUCCESS) return TimerError.SystemResources;
        const fd: i32 = @intCast(rc);
        port.addInternal(.timer, fd) catch |err| {
            _ = std.c.close(fd);
            return switch (err) {
                // The timer slot belongs to this module and is empty
                // whenever self.fd is -1.
                error.InvalidArgument => unreachable,
                error.SystemResources => TimerError.SystemResources,
            };
        };
        self.fd = fd;
    }

    /// Arms the timerfd at the heap's earliest deadline, or disarms it when
    /// the heap is empty. A deadline already in the past makes the timerfd
    /// ready at once. Skips the syscall when nothing changed.
    fn rearm(self: *State, port: *EvPort) void {
        if (self.fd == -1) return;
        const want = self.heap.next();
        if (want == self.armed) return;
        // An all-zero it_value disarms, so a deadline of 0 ns is armed at
        // 1 ns: equally past, still ready.
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = if (want) |ns| timespecOf(@max(ns, 1)) else .{ .sec = 0, .nsec = 0 },
        };
        if (linux.E.init(linux.timerfd_settime(self.fd, .{ .ABSTIME = true }, &spec, null)) != .SUCCESS) {
            self.armed = null;
            stashFailure(port);
            return;
        }
        self.armed = want;
    }
};

/// Arms timer `id` to fire `after_ms` from now, every `after_ms` for
/// `.repeat`. Re-adding a live id replaces it. A `.once` with 0 is due at
/// the next wait(); a `.repeat` with 0 is error.InvalidArgument.
/// OutOfMemory leaves every live timer as it was.
pub fn add(port: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
    if (mode == .repeat and after_ms == 0) return TimerError.InvalidArgument;
    const st = &port.timers;
    try st.ensureFd(port);
    const now = timer_heap.nowNs() catch return TimerError.SystemResources;
    const after_ns = @as(u64, after_ms) * std.time.ns_per_ms;
    const period_ns: u64 = if (mode == .repeat) after_ns else 0;
    st.heap.add(port.alloc, now, id, udata, after_ns, period_ns) catch return TimerError.OutOfMemory;
    st.rearm(port);
}

/// Disarms timer `id`. Unknown or already-expired ids are a no-op.
pub fn cancel(port: *EvPort, id: u32) void {
    const st = &port.timers;
    if (!st.heap.cancel(id)) return;
    st.rearm(port);
}

/// Turns a ready timerfd into at most `out.len` (>= 1) events and returns
/// the count, earliest deadline first. Failures are stashed in
/// `port.pending_error` as error.SourceFailed, never dropped.
pub fn harvest(port: *EvPort, out: []Event) usize {
    const st = &port.timers;
    if (st.fd == -1) return 0;
    var ticks: u64 = 0;
    while (true) {
        const rc = linux.read(st.fd, std.mem.asBytes(&ticks), @sizeOf(u64));
        switch (linux.E.init(rc)) {
            // The armed expiration is consumed: the timerfd is disarmed.
            .SUCCESS => {
                if (rc != @sizeOf(u64)) stashFailure(port);
                st.armed = null;
            },
            .INTR => continue,
            // Re-armed or disarmed since it became ready; the heap decides.
            .AGAIN => {},
            else => stashFailure(port),
        }
        break;
    }
    const now = timer_heap.nowNs() catch {
        // Nothing can be expired without the clock. Re-arming keeps any due
        // timer ready for the wait() after the reported failure.
        stashFailure(port);
        st.armed = null;
        st.rearm(port);
        return 0;
    };
    var expired: [32]timer_heap.Expired = undefined;
    var n: usize = 0;
    while (n < out.len) {
        const want = @min(expired.len, out.len - n);
        const got = st.heap.expire(now, expired[0..want]);
        for (expired[0..got]) |e| {
            out[n] = .{ .timer = true, .fired = e.fired, .udata = e.udata };
            n += 1;
        }
        if (got < want) break;
    }
    st.rearm(port);
    return n;
}

fn timespecOf(ns: u64) linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

/// Keeps the first stashed failure; wait() reports one per call.
fn stashFailure(port: *EvPort) void {
    if (port.pending_error == null) port.pending_error = error.SourceFailed;
}

// --------------------------------------------------------------- tests ----

const testing = std.testing;

/// The timerfd's absolute expiry in ns, or null while disarmed.
fn armedAt(fd: i32) !?u64 {
    var cur: linux.itimerspec = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.E.init(linux.timerfd_gettime(fd, &cur)));
    if (cur.it_value.sec == 0 and cur.it_value.nsec == 0) return null;
    // timerfd_gettime reports the time remaining, not the absolute value.
    const now = try timer_heap.nowNs();
    return now + @as(u64, @intCast(cur.it_value.sec)) * std.time.ns_per_s + @as(u64, @intCast(cur.it_value.nsec));
}

test "timer_epoll: one lazily created timerfd serves every timer" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    try testing.expect(port.internalFd(.timer) == null);
    var a: u8 = 0;
    try port.addTimer(1, &a, 1000, .once);
    const fd = port.internalFd(.timer).?;
    try testing.expectEqual(fd, port.timers.fd);
    var i: u32 = 2;
    while (i < 200) : (i += 1) try port.addTimer(i, &a, 1000 + i, .repeat);
    try testing.expectEqual(fd, port.internalFd(.timer).?);
    try testing.expectEqual(@as(usize, 199), port.timers.heap.count());
}

test "timer_epoll: the timerfd follows the heap head and disarms when empty" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var a: u8 = 0;
    try port.addTimer(1, &a, 5000, .once);
    const fd = port.timers.fd;
    try testing.expectEqual(port.timers.heap.next(), port.timers.armed);
    const late = (try armedAt(fd)).?;

    // A sooner timer moves the head and the kernel deadline with it.
    try port.addTimer(2, &a, 1000, .once);
    try testing.expectEqual(port.timers.heap.next(), port.timers.armed);
    try testing.expect((try armedAt(fd)).? < late);

    // Cancelling the head falls back to the next deadline.
    port.cancelTimer(2);
    try testing.expectEqual(port.timers.heap.deadlineOf(1), port.timers.armed);

    // Cancelling an unknown id changes nothing.
    port.cancelTimer(77);
    try testing.expectEqual(port.timers.heap.deadlineOf(1), port.timers.armed);

    port.cancelTimer(1);
    try testing.expect(port.timers.armed == null);
    try testing.expect((try armedAt(fd)) == null);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    try testing.expect(port.pending_error == null);
}

test "timer_epoll: a full buffer leaves the timerfd ready for the rest" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tags: [5]u8 = undefined;
    for (&tags, 0..) |*t, i| try port.addTimer(@intCast(i), t, 0, .once);

    // One slot per wait(): every timer arrives, one per call, without
    // blocking, because the timerfd is re-armed in the past each time.
    var seen = [_]bool{false} ** tags.len;
    var events: [1]Event = undefined;
    for (0..tags.len) |_| {
        try testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
        try testing.expect(events[0].timer and events[0].fired == 1);
        const idx = @intFromPtr(events[0].udata.?) - @intFromPtr(&tags[0]);
        try testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    try testing.expectEqual(@as(usize, 0), port.timers.heap.count());
    try testing.expect(port.timers.armed == null);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "timer_epoll: more expirations than one expire chunk fill a large buffer" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    const count = 100;
    var tags: [count]u8 = undefined;
    for (&tags, 0..) |*t, i| try port.addTimer(@intCast(i), t, 0, .once);
    var events: [128]Event = undefined;
    try testing.expectEqual(@as(usize, count), try port.wait(&events, 1000));
    for (events[0..count]) |ev| try testing.expect(ev.timer);
}

test "timer_epoll: deinit closes the timerfd" {
    var port = try EvPort.init(testing.allocator);
    var a: u8 = 0;
    try port.addTimer(1, &a, 1000, .repeat);
    const fd = port.timers.fd;
    port.deinit();
    try testing.expectEqual(linux.E.BADF, linux.E.init(linux.fcntl(fd, linux.F.GETFD, 0)));
}
