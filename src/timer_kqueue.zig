//! Timers on kqueue (EVFILT_TIMER).
//!
//! Each timer is one EVFILT_TIMER knote: ident = id, udata = the caller's.
//! State tracks every live id's absolute monotonic deadline (and repeat
//! period), and both modes arm EV_ONESHOT: the kernel fires one chunk and
//! drops the knote. A chunk is at most `State.cap_ns`, the largest delay the
//! running kernel converts exactly; `observe` re-arms the remainder of an
//! early firing internally and delivers nothing, so a deadline never fires
//! early for any accepted `after_ns`, however far beyond one chunk. A due
//! `.once` firing retires the id; a due `.repeat` firing delivers the elapsed
//! periods and re-arms on the original phase, like the epoll/IOCP deadline
//! heap. Changes go through `EvPort.stageRaw` into the next wait(); no
//! kevent() call outside wait(). wait() translates a delivered firing into
//! Event{ .timer, .fired, .udata } after `observe` has seen it.
//!
//! Late deletes: State tracks live ids, and `cancel` stages EV_DELETE only
//! for a live one, so cancelling an unknown or expired id stages nothing.
//! A `.once` id leaves the live set when `observe` sees its due firing; until
//! then its knote exists (an unharvested firing stays queued on it), so the
//! delete finds it and also discards that firing. Between an early chunk
//! firing and its staged re-arm the knote is gone; a delete there is the
//! documented ENOENT no-op. This keeps an expected
//! ENOENT out of the changelist entirely: a change error needs an eventlist
//! slot, and with none free kevent() fails the whole wait() and skips the
//! rest of the changelist. The one ENOENT left is a delete for an id whose
//! EV_ADD the kernel refused (already reported as an error event, and the
//! id stays tracked); EV_ADD never returns ENOENT, so `observe` suppresses
//! every EVFILT_TIMER ENOENT as the documented cancel no-op.
//!
//! Replacing a live id stages EV_DELETE then EV_ADD. An EV_ADD on an
//! existing knote keeps the flags it was created with (FreeBSD
//! kqueue_register updates only udata, data and fflags), so a mode change
//! would not take, and the delete also discards an unharvested firing of
//! the old timer.
//!
//! Timer units (sys/event.h, EVFILT_TIMER fflags). born passes nanoseconds
//! via NOTE_NSECONDS where the target's header defines it; a target without
//! it falls back to NOTE_USECONDS with the value rounded up, so a deadline
//! never fires early:
//!   FreeBSD: bit flags, NOTE_NSECONDS = 0x8 (SECONDS 0x1, MSECONDS 0x2,
//!            USECONDS 0x4, ABSTIME 0x10). Header and kernel verified,
//!            runtime-tested on the FreeBSD CI backend.
//!   macOS:   NOTE_NSECONDS = 0x4 (SECONDS 0x1, USECONDS 0x2,
//!            NOTE_ABSOLUTE 0x8); no NOTE_MSECONDS, milliseconds is fflags 0.
//!            Header and kernel verified, runtime-tested on macOS 26 arm64.
//!   NetBSD:  unit enum, NOTE_NSECONDS = 3 (MSECONDS 0, SECONDS 1,
//!            USECONDS 2, ABSTIME 0x10). First release 10.0; kernels <= 9
//!            ignore fflags and read data as milliseconds. Header and kernel
//!            verified, runtime-tested on NetBSD 10.1.
//!   OpenBSD: unit enum, NOTE_NSECONDS = 3 (MSECONDS 0, SECONDS 1,
//!            USECONDS 2, ABSTIME 0x10). First release 7.4; kernels <= 7.3
//!            ignore fflags and read data as milliseconds. Source-verified
//!            only: compile-only target, no runtime evidence.
//! The NOTE_NSECONDS value is per target (0x8 / 0x4 / 0x3), so it is selected
//! at comptime. The firing's `data` is the expiration count on every target,
//! independent of the unit flag. NetBSD and OpenBSD round the deadline up to
//! a callout tick (1/hz); FreeBSD and macOS arm at sub-millisecond precision.
//!
//! Per-platform arm cap (`State.cap_ns`), the largest delay the kernel
//! converts exactly, verified against kernel source:
//!   FreeBSD: half the sbintime seconds range (~34 years). timer2sbintime
//!            converts exactly below SBT_MAX (~68 years), but filt_timerstart
//!            adds the current uptime (next = to + sbinuptime()); a value at
//!            SBT_MAX overflows that add, wraps into the past and fires at
//!            once. Half the range leaves headroom for any uptime below it.
//!   macOS:   derived from mach_timebase_info at init. The kernel computes
//!            (ns/1e9)*divisor + (ns%1e9)*divisor/1e9 with divisor =
//!            floor(1e9*denom/numer) ticks/sec (osfmk/arm/rtclock.c; Intel is
//!            identity). The cap keeps seconds*divisor below u64 max; the
//!            deadline add saturates at UINT64_MAX (os_add_overflow), never
//!            wraps. At the shipping 24 MHz and 1:1 timebases the full API
//!            ceiling converts exactly.
//!   NetBSD/OpenBSD: (INT_MAX - 1024) callout ticks, from kern.clockrate's
//!            tick (usec) read once at init. tstohz/tvtohz round up and add
//!            one tick, then saturate at INT_MAX ticks (248 days at hz 100,
//!            24.8 days at hz 1000), which would fire early; staying below
//!            INT_MAX keeps the conversion exact.
//! A failed sysctl/timebase read falls back to a one-hour cap, below every
//! supported kernel's representable maximum. Every port arms at the real
//! platform cap; only the multi-re-arm tests lower their own port's cap to
//! 2 ms so a short deadline spans several internal re-arms.
//!
//! A re-arm staged in a batch that also delivers events is submitted on the
//! caller's next wait(), so that chunk fires late by the caller's processing
//! time. Late, never early.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const kq = @import("evport_kqueue.zig");
const EvPort = kq.EvPort;
const Kevent = kq.Kevent;
const TimerError = kq.TimerError;
const TimerMode = kq.TimerMode;
const timer_after_ns_max = kq.timer_after_ns_max;

const EV_ADD = std.c.EV.ADD;
const EV_DELETE = std.c.EV.DELETE;
const EV_ONESHOT = std.c.EV.ONESHOT;
// Zig 0.15 omits ERROR on NetBSD (sys/event.h); same value as evport_kqueue.zig.
const EV_ERROR = if (@hasDecl(std.c.EV, "ERROR")) std.c.EV.ERROR else 0x4000;
const ENOENT = @intFromEnum(compat.E.NOENT);

/// NOTE_NSECONDS value per target, or null where sys/event.h does not define
/// it; see the unit table above. All four supported kqueue targets define it.
const note_nseconds: ?@FieldType(Kevent, "fflags") = switch (builtin.os.tag) {
    .freebsd => 0x8,
    .macos => 0x4,
    .netbsd, .openbsd => 0x3,
    else => null,
};

/// NOTE_USECONDS value per target: the fallback unit when NOTE_NSECONDS is
/// absent. The nanosecond value is rounded up to whole microseconds so a
/// deadline never fires early because of rounding.
const note_useconds: @FieldType(Kevent, "fflags") = switch (builtin.os.tag) {
    .freebsd => 0x4,
    .macos, .netbsd, .openbsd => 0x2,
    else => @compileError("born: unknown EVFILT_TIMER microsecond unit"),
};

/// Nanoseconds to whole microseconds, rounded up. Used only on targets
/// without NOTE_NSECONDS; comptime-dead on every supported kqueue target.
fn ceilUs(ns: u64) u64 {
    return ns / std.time.ns_per_us + @intFromBool(ns % std.time.ns_per_us != 0);
}

/// FreeBSD arm cap in nanoseconds: half the sbintime seconds range
/// (~34 years). timer2sbintime converts exactly below SBT_MAX (~68 years),
/// but filt_timerstart adds the current uptime (next = to + sbinuptime());
/// a value at SBT_MAX overflows that add, wraps into the past and fires at
/// once. Half the range leaves headroom for any uptime below the same bound.
const freebsd_cap_ns: u64 = ((@as(u64, std.math.maxInt(i64)) >> 32) / 2) * std.time.ns_per_s;

/// Fallback cap when the kernel's clockrate/timebase cannot be read: one
/// hour, below every supported kernel's representable maximum (the BSD tick
/// cap would need hz > 596523 to overflow INT_MAX in an hour).
const fallback_cap_ns: u64 = 3600 * std.time.ns_per_s;

/// Small cap the multi-re-arm tests set on their own port so a short deadline
/// spans several internal re-arms. Production ports always use platformCapNs().
const test_cap_ns: u64 = 2 * std.time.ns_per_ms;

/// The largest arm the running kernel converts exactly, in nanoseconds.
/// Values above it are chunked and re-armed internally, never saturated.
fn platformCapNs() u64 {
    switch (builtin.os.tag) {
        .freebsd => return freebsd_cap_ns,
        .macos => {
            const tb = compat.machTimebase() orelse return fallback_cap_ns;
            if (tb.numer == 0 or tb.denom == 0) return fallback_cap_ns;
            // Kernel ticks per second: floor(1e9 * denom / numer). The
            // conversion's only overflow candidate is whole_seconds*divisor;
            // the remainder term stays below divisor. One second of margin
            // keeps the sum under u64 max.
            const divisor: u64 = @intCast((@as(u128, std.time.ns_per_s) * tb.denom) / tb.numer);
            if (divisor == 0) return fallback_cap_ns;
            const max_seconds = std.math.maxInt(u64) / divisor - 1;
            const cap = @as(u128, max_seconds) * std.time.ns_per_s;
            return @intCast(@min(cap, timer_after_ns_max));
        },
        .netbsd, .openbsd => {
            const ci = compat.kernClockrate() orelse return fallback_cap_ns;
            if (ci.tick <= 0) return fallback_cap_ns;
            // tvtohz rounds up and adds one tick, then saturates at INT_MAX.
            // 1024 ticks of margin keep the rounded result below INT_MAX.
            const ticks: u64 = std.math.maxInt(i32) - 1024;
            return ticks * @as(u64, @intCast(ci.tick)) * std.time.ns_per_us;
        },
        else => @compileError("born: unknown kqueue timer cap platform"),
    }
}

/// Per-id bookkeeping: mode, the caller's udata, the absolute monotonic
/// deadline, and the repeat period (0 for `.once`). Mirrors timer_heap.Entry.
const Entry = struct {
    mode: TimerMode,
    udata: ?*anyopaque,
    deadline_ns: u64,
    period_ns: u64,
};

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    /// Armed ids and their deadline state. An id is live from add until
    /// cancel, or until `observe` sees a due `.once` firing.
    live: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    /// Largest single arm the running kernel converts exactly (ns). Longer
    /// deadlines are chunked and re-armed internally.
    cap_ns: u64 = 0,
    /// Early chunk firings re-armed without delivery (diagnostic and test
    /// seam; monotonic, never reset).
    early_rearms: u64 = 0,

    /// Returns state with no live timers and the real platform arm cap. Tests
    /// that exercise internal re-arm lower `cap_ns` on their own port.
    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{ .cap_ns = platformCapNs() };
    }

    /// Closing the kqueue drops every knote; only the bookkeeping is freed.
    pub fn deinit(self: *State, port: *EvPort) void {
        self.live.deinit(port.alloc);
    }
};

/// Stages the timer for the next wait(). `after_ns` is nanoseconds; above
/// `timer_after_ns_max` is InvalidArgument. The absolute deadline is tracked
/// on the monotonic clock; the first arm is at most `State.cap_ns` and
/// `observe` re-arms the remainder until the deadline. Allocation happens up
/// front, so OutOfMemory leaves the port unchanged. A kernel refusal of the
/// EV_ADD arrives at wait() as Event{ .err, .err_no } with the timer's udata.
pub fn add(port: *EvPort, id: u32, udata: ?*anyopaque, after_ns: u64, mode: TimerMode) TimerError!void {
    if (after_ns > timer_after_ns_max) return TimerError.InvalidArgument;
    if (mode == .repeat and after_ns == 0) return TimerError.InvalidArgument;
    const now = compat.monotonicNs() catch return TimerError.SystemResources;
    port.changes.ensureUnusedCapacity(port.alloc, 2) catch return TimerError.OutOfMemory;
    const slot = port.timers.live.getOrPut(port.alloc, id) catch return TimerError.OutOfMemory;
    if (slot.found_existing) port.stageRaw(change(id, EV_DELETE, null, 0));
    slot.value_ptr.* = .{
        .mode = mode,
        .udata = udata,
        .deadline_ns = now +| after_ns,
        .period_ns = if (mode == .repeat) after_ns else 0,
    };
    port.stageRaw(change(id, EV_ADD | EV_ONESHOT, udata, @min(after_ns, port.timers.cap_ns)));
}

/// Stages EV_DELETE for a live id; anything else is a no-op. If the
/// changelist cannot grow, the id stays live so a retry can cancel it, and
/// the next wait() reports OutOfMemory like any failed stage.
pub fn cancel(port: *EvPort, id: u32) void {
    if (!port.timers.live.contains(id)) return;
    port.changes.ensureUnusedCapacity(port.alloc, 1) catch {
        port.pending_error = error.OutOfMemory;
        return;
    };
    _ = port.timers.live.remove(id);
    port.stageRaw(change(id, EV_DELETE, null, 0));
}

/// Sees each EVFILT_TIMER kevent first; false suppresses it. The tracked
/// deadline is authoritative: a firing before it is an early chunk (or
/// kernel rounding) and is re-armed for the remainder with no delivery; a
/// due `.once` firing retires the id; a due `.repeat` firing delivers the
/// elapsed periods and re-arms on the original phase. Drops the ENOENT of a
/// delete that found no knote. May set kev.data to the delivered period
/// count. A clock failure stashes WaitFailed and keeps the timer armed.
pub fn observe(port: *EvPort, kev: *Kevent) bool {
    if ((kev.flags & EV_ERROR) != 0) return kev.data != ENOENT;
    const id = std.math.cast(u32, kev.ident) orelse return true;
    const entry = port.timers.live.getPtr(id) orelse return true;
    const now = compat.monotonicNs() catch {
        if (port.pending_error == null) port.pending_error = error.WaitFailed;
        rearm(port, id, entry.udata, port.timers.cap_ns);
        return false;
    };
    if (now < entry.deadline_ns) {
        port.timers.early_rearms += 1;
        rearm(port, id, entry.udata, @min(entry.deadline_ns - now, port.timers.cap_ns));
        return false;
    }
    if (entry.mode == .once) {
        _ = port.timers.live.remove(id);
        return true;
    }
    const periods = (now - entry.deadline_ns) / entry.period_ns +| 1;
    kev.data = @intCast(@min(periods, std.math.maxInt(u32)));
    entry.deadline_ns = entry.deadline_ns +| (periods *| entry.period_ns);
    rearm(port, id, entry.udata, @min(entry.deadline_ns - now, port.timers.cap_ns));
    return true;
}

/// Stages the next one-shot chunk for a live id. A staging allocation
/// failure is stashed by stageRaw and reported by the next wait().
fn rearm(port: *EvPort, id: u32, udata: ?*anyopaque, arm_ns: u64) void {
    port.stageRaw(change(id, EV_ADD | EV_ONESHOT, udata, arm_ns));
}

/// Pure encoder of one arm into a kevent; the cap is applied by add/rearm,
/// not here. `arm_ns` is at most `timer_after_ns_max`, so it fits the signed
/// data field on every target.
fn change(id: u32, flags: @FieldType(Kevent, "flags"), udata: ?*anyopaque, arm_ns: u64) Kevent {
    var kev = std.mem.zeroes(Kevent);
    kev.ident = id;
    kev.filter = kq.EVFILT_TIMER;
    kev.flags = flags;
    if (note_nseconds) |unit| {
        kev.fflags = unit;
        kev.data = @intCast(arm_ns);
    } else {
        kev.fflags = note_useconds;
        kev.data = @intCast(ceilUs(arm_ns));
    }
    kev.udata = @intFromPtr(udata);
    return kev;
}

// --------------------------------------------------------------- tests ----

const testing = std.testing;
const Event = kq.Event;

/// Waits up to `window_ms` for one event.
fn waitOne(port: *EvPort, events: []Event, window_ms: i32) !usize {
    const started_ns = try compat.monotonicNs();
    while (true) {
        const elapsed_ns = (try compat.monotonicNs()) - started_ns;
        const elapsed: i32 = @intCast(elapsed_ns / std.time.ns_per_ms);
        if (elapsed >= window_ms) return 0;
        const n = try port.wait(events, window_ms - elapsed);
        if (n != 0) return n;
    }
}

/// Effective chunk granularity for the multi-re-arm tests. On sub-millisecond
/// kernels it is the test cap; on NetBSD/OpenBSD the kernel rounds each arm up
/// to a callout tick (and tstohz adds one), so a deadline must span several
/// ticks, not several caps, to exercise multiple re-arms at any hz.
fn testChunkNs(cap: u64) u64 {
    const tick_ns: u64 = if (compat.kernClockrate()) |ci|
        @as(u64, @intCast(ci.tick)) * std.time.ns_per_us
    else
        0;
    return @max(cap, tick_ns);
}

test "timer_kqueue: change encoding uses the target's nanosecond unit" {
    var tag: u8 = 1;
    const after_ns: u64 = 250 * std.time.ns_per_ms;
    const kev = change(7, EV_ADD | EV_ONESHOT, &tag, after_ns);
    try testing.expectEqual(@as(usize, 7), kev.ident);
    try testing.expectEqual(kq.EVFILT_TIMER, kev.filter);
    try testing.expectEqual(EV_ADD | EV_ONESHOT, kev.flags);
    try testing.expectEqual(@intFromPtr(&tag), kev.udata);
    if (note_nseconds) |unit| {
        try testing.expectEqual(unit, kev.fflags);
        try testing.expectEqual(@as(@TypeOf(kev.data), @intCast(after_ns)), kev.data);
    } else {
        try testing.expectEqual(note_useconds, kev.fflags);
        try testing.expectEqual(@as(@TypeOf(kev.data), @intCast(ceilUs(after_ns))), kev.data);
    }
}

test "timer_kqueue: a sub-millisecond deadline keeps nanosecond precision" {
    var tag: u8 = 1;
    const kev = change(8, EV_ADD | EV_ONESHOT, &tag, 500_000);
    if (note_nseconds) |unit| {
        try testing.expectEqual(unit, kev.fflags);
        try testing.expectEqual(@as(@TypeOf(kev.data), 500_000), kev.data);
    } else {
        try testing.expectEqual(note_useconds, kev.fflags);
        try testing.expectEqual(@as(@TypeOf(kev.data), 500), kev.data);
    }
}

test "timer_kqueue: ceilUs rounds up to whole microseconds" {
    try testing.expectEqual(@as(u64, 0), ceilUs(0));
    try testing.expectEqual(@as(u64, 1), ceilUs(1));
    try testing.expectEqual(@as(u64, 1), ceilUs(std.time.ns_per_us));
    try testing.expectEqual(@as(u64, 2), ceilUs(std.time.ns_per_us + 1));
}

test "timer_kqueue: the arm cap is bounded and add never stages beyond it" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    // Configure a small cap on this port so the bounding is observable; init
    // otherwise uses the real platform cap (the production one-shot path).
    port.timers.cap_ns = test_cap_ns;
    try testing.expect(port.timers.cap_ns >= 1);
    try testing.expect(port.timers.cap_ns <= timer_after_ns_max);
    if (builtin.is_test) try testing.expectEqual(test_cap_ns, port.timers.cap_ns);
    var tag: u8 = 1;
    try add(&port, 10, &tag, timer_after_ns_max, .once);
    const kev = port.changes.items[port.changes.items.len - 1];
    try testing.expectEqual(EV_ADD | EV_ONESHOT, kev.flags);
    try testing.expectEqual(@as(@TypeOf(kev.data), @intCast(port.timers.cap_ns)), kev.data);
    // A repeat period above the cap is tracked in full, not truncated.
    try add(&port, 11, &tag, timer_after_ns_max, .repeat);
    try testing.expectEqual(timer_after_ns_max, port.timers.live.get(11).?.period_ns);
    cancel(&port, 10);
    cancel(&port, 11);
}

test "timer_kqueue: the runtime platform cap is bounded and converts exactly" {
    // Exercises the real derivation (mach timebase / kern.clockrate), not the
    // is_test seam, so each runtime host proves its own cap.
    const cap = platformCapNs();
    try testing.expect(cap >= 1);
    try testing.expect(cap <= timer_after_ns_max);
    switch (builtin.os.tag) {
        .freebsd => try testing.expectEqual(freebsd_cap_ns, cap),
        .netbsd, .openbsd => {
            // Below INT_MAX callout ticks, so tvtohz never saturates.
            if (compat.kernClockrate()) |ci| {
                const tick_ns = @as(u64, @intCast(ci.tick)) * std.time.ns_per_us;
                try testing.expect(cap / tick_ns < std.math.maxInt(i32));
            }
        },
        .macos => {
            // whole_seconds*divisor stays below u64 max (one second margin).
            if (compat.machTimebase()) |tb| {
                if (tb.numer != 0 and tb.denom != 0) {
                    const divisor = (@as(u128, std.time.ns_per_s) * tb.denom) / tb.numer;
                    try testing.expect((@as(u128, cap / std.time.ns_per_s) + 1) * divisor <= std.math.maxInt(u64));
                }
            }
        },
        else => {},
    }
}

test "timer_kqueue: a delay within the platform cap arms in one shot, never early" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    // The production path: init uses the real platform cap, so a delay below
    // it arms in a single shot with no internal chunking. Well above the test
    // cap, so a global is_test seam would have chunked this delay instead.
    const delay = 20 * test_cap_ns;
    try testing.expect(delay < port.timers.cap_ns);
    const armed = try compat.monotonicNs();
    try add(&port, 14, &tag, delay, .once);
    // One shot: the staged arm carries the full delay, not a capped chunk.
    const kev = port.changes.items[port.changes.items.len - 1];
    try testing.expectEqual(@as(@TypeOf(kev.data), @intCast(delay)), kev.data);
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 5000));
    try testing.expect(events[0].timer);
    try testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    try testing.expectEqual(@as(u32, 1), events[0].fired);
    const elapsed = (try compat.monotonicNs()) - armed;
    try testing.expect(elapsed >= delay);
    try testing.expect(!port.timers.live.contains(14));
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
}

test "timer_kqueue: a deadline beyond the cap re-arms internally and fires once, never early" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    // Lower this port's cap so a short deadline spans several re-arms; other
    // ports keep the real platform cap.
    port.timers.cap_ns = test_cap_ns;
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    const cap = port.timers.cap_ns;
    // Ten chunks of the effective granularity: several early re-arms before
    // the final one on every runtime backend, whatever its tick resolution.
    const delay = 10 * testChunkNs(cap);
    const armed = try compat.monotonicNs();
    try add(&port, 12, &tag, delay, .once);
    const before = port.timers.early_rearms;
    // --- #144 diagnostics: name the failing assertion under load ---------
    std.debug.print("#144 setup armed={d} delay={d} cap={d} chunk={d} before={d} early_rearms={d}\n", .{ armed, delay, cap, testChunkNs(cap), before, port.timers.early_rearms });
    const n0 = try waitOne(&port, &events, 5000);
    std.debug.print("#144 waitOne n={d}\n", .{n0});
    std.debug.print("#144 CHECK n==1 (line 454): n={d}\n", .{n0});
    try testing.expectEqual(@as(usize, 1), n0);
    std.debug.print("#144 CHECK ev.timer (line 455): timer={any} udata_ok={any} fired={d}\n", .{ events[0].timer, events[0].udata == @as(?*anyopaque, &tag), events[0].fired });
    try testing.expect(events[0].timer);
    try testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    try testing.expectEqual(@as(u32, 1), events[0].fired);
    const elapsed = (try compat.monotonicNs()) - armed;
    std.debug.print("#144 CHECK elapsed>=delay (line 459): elapsed={d} delay={d} pass={any}\n", .{ elapsed, delay, elapsed >= delay });
    try testing.expect(elapsed >= delay);
    const delta = port.timers.early_rearms - before;
    std.debug.print("#144 CHECK early_rearms-before>=3 (line 460): early_rearms={d} before={d} delta={d} pass={any}\n", .{ port.timers.early_rearms, before, delta, delta >= 3 });
    try testing.expect(port.timers.early_rearms - before >= 3);
    std.debug.print("#144 CHECK !live.contains(12) (line 461): contains={any}\n", .{port.timers.live.contains(12)});
    try testing.expect(!port.timers.live.contains(12));
    const n1 = try port.wait(&events, 50);
    std.debug.print("#144 CHECK re-wait==0 (line 462): n={d}\n", .{n1});
    try testing.expectEqual(@as(usize, 0), n1);
}

test "timer_kqueue: a repeat period beyond the cap keeps its phase across re-arms" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    // Lower this port's cap so a short period spans several re-arms; other
    // ports keep the real platform cap.
    port.timers.cap_ns = test_cap_ns;
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    const cap = port.timers.cap_ns;
    // Eight chunks per period keeps the phase across several re-arms on every
    // runtime backend, whatever its tick resolution.
    const period = 8 * testChunkNs(cap);
    const armed = try compat.monotonicNs();
    try add(&port, 13, &tag, period, .repeat);
    const before = port.timers.early_rearms;
    var fired: u64 = 0;
    while (fired < 2) {
        const n = try waitOne(&port, &events, 5000);
        try testing.expect(n != 0);
        for (events[0..n]) |ev| {
            try testing.expect(ev.timer and ev.udata == @as(?*anyopaque, &tag));
            try testing.expect(ev.fired >= 1);
            fired += ev.fired;
        }
    }
    const elapsed = (try compat.monotonicNs()) - armed;
    try testing.expect(elapsed >= 2 * period);
    try testing.expect(port.timers.early_rearms - before >= 2);
    cancel(&port, 13);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
}

test "timer_kqueue: cancelling an expired or unknown id stages nothing" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    try add(&port, 1, &tag, 1 * std.time.ns_per_ms, .once);
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 1000));
    try testing.expect(events[0].timer);
    try testing.expect(!port.timers.live.contains(1));
    cancel(&port, 1);
    cancel(&port, 77);
    try testing.expectEqual(@as(usize, 0), port.changes.items.len);
}

test "timer_kqueue: cancel discards a fired but unharvested one-shot" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    try add(&port, 2, &tag, 5 * std.time.ns_per_ms, .once);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    compat.sleepNs(30 * std.time.ns_per_ms);
    // Fired in the kernel, not yet harvested: still live, so the delete
    // finds the knote and takes the queued firing with it.
    try testing.expect(port.timers.live.contains(2));
    cancel(&port, 2);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
}

test "timer_kqueue: a delete that finds no knote is suppressed" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    // The state a refused EV_ADD leaves: tracked as live, no knote.
    try port.timers.live.put(testing.allocator, 3, .{
        .mode = .repeat,
        .udata = null,
        .deadline_ns = 0,
        .period_ns = 1,
    });
    cancel(&port, 3);
    try testing.expectEqual(@as(usize, 1), port.changes.items.len);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 20));
}

test "timer_kqueue: other change errors still surface" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    var kev = change(4, EV_ADD, &tag, 0);
    kev.flags = EV_ERROR;
    kev.data = @intFromEnum(compat.E.INVAL);
    try testing.expect(observe(&port, &kev));
    kev.data = ENOENT;
    try testing.expect(!observe(&port, &kev));
}

test "timer_kqueue: replacing a live id changes its mode" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [8]Event = undefined;
    var a: u8 = 1;
    var b: u8 = 2;
    // repeat -> once: exactly one firing, then the id is retired.
    try add(&port, 5, &a, 5 * std.time.ns_per_ms, .repeat);
    try add(&port, 5, &b, 5 * std.time.ns_per_ms, .once);
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 1000));
    try testing.expect(events[0].udata == @as(?*anyopaque, &b));
    try testing.expect(!port.timers.live.contains(5));
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
    // once -> repeat: keeps firing until cancelled.
    try add(&port, 6, &a, 1000 * std.time.ns_per_ms, .once);
    try add(&port, 6, &b, 5 * std.time.ns_per_ms, .repeat);
    var fired: usize = 0;
    while (fired < 3) {
        const n = try waitOne(&port, &events, 1000);
        try testing.expect(n != 0);
        for (events[0..n]) |ev| {
            try testing.expect(ev.timer and ev.udata == @as(?*anyopaque, &b));
            fired += 1;
        }
    }
    try testing.expectEqual(@as(?TimerMode, .repeat), if (port.timers.live.get(6)) |e| e.mode else null);
    cancel(&port, 6);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
}

test "timer_kqueue: allocation failure in add leaves the port unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var port = try EvPort.init(failing.allocator());
    defer port.deinit();
    const staged = port.changes.items.len;
    failing.fail_index = failing.alloc_index;
    var tag: u8 = 1;
    try testing.expectError(TimerError.OutOfMemory, add(&port, 8, &tag, 10 * std.time.ns_per_ms, .once));
    try testing.expectEqual(staged, port.changes.items.len);
    try testing.expect(!port.timers.live.contains(8));
    try testing.expect(port.pending_error == null);
}

test "timer_kqueue: allocation failure in cancel keeps the id cancellable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var port = try EvPort.init(failing.allocator());
    defer port.deinit();
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    try add(&port, 9, &tag, 5 * std.time.ns_per_ms, .repeat);
    // Flush, then leave the changelist with no spare capacity.
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    port.changes.shrinkAndFree(failing.allocator(), 0);
    failing.fail_index = failing.alloc_index;
    cancel(&port, 9);
    try testing.expect(port.timers.live.contains(9));
    try testing.expectError(error.OutOfMemory, port.wait(&events, 0));
    failing.fail_index = std.math.maxInt(usize);
    cancel(&port, 9);
    try testing.expect(!port.timers.live.contains(9));
    // The delete also takes the firings queued since the flush.
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
}
