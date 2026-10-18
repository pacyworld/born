//! Timers on kqueue (EVFILT_TIMER). Owned by born#12: this file plus the
//! EvPort.addTimer/cancelTimer bodies in evport_kqueue.zig.
//!
//! Each timer is one EVFILT_TIMER knote: ident = id, data = after_ms in
//! milliseconds, udata = the caller's. Changes go through `EvPort.stageRaw`
//! into the next wait(); no kevent() call outside wait(). `.once` adds
//! EV_ONESHOT, so the kernel drops the knote when wait() harvests its
//! firing. wait() translates the firing into Event{ .timer, .fired, .udata }
//! after `observe` has seen it.
//!
//! Late deletes: State tracks live ids, and `cancel` stages EV_DELETE only
//! for a live one, so cancelling an unknown or expired id stages nothing.
//! A `.once` id leaves the live set when `observe` sees its firing; until
//! then its knote exists (an unharvested firing stays queued on it), so the
//! delete finds it and also discards that firing. This keeps an expected
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
//! Timer units (sys/event.h, EVFILT_TIMER fflags). Every target defaults to
//! milliseconds with fflags 0; born passes the explicit millisecond unit:
//!   FreeBSD: bit flags, NOTE_MSECONDS = 0x2 (SECONDS 0x1, USECONDS 0x4,
//!            NSECONDS 0x8, ABSTIME 0x10).
//!   macOS:   no NOTE_MSECONDS; milliseconds is fflags 0 (NOTE_SECONDS 0x1,
//!            NOTE_USECONDS 0x2, NOTE_NSECONDS 0x4, NOTE_ABSOLUTE 0x8).
//!   NetBSD:  unit enum, NOTE_MSECONDS = 0 (SECONDS 1, USECONDS 2,
//!            NSECONDS 3, ABSTIME 0x10).
//!   OpenBSD: unit enum, NOTE_MSECONDS = 0 (SECONDS 1, USECONDS 2,
//!            NSECONDS 3, ABSTIME 0x10).
//! 0x2 is microseconds on macOS, NetBSD and OpenBSD, so the value is
//! per target. Zig 0.15 std defines NOTE.MSECONDS for FreeBSD only.

const std = @import("std");
const builtin = @import("builtin");
const kq = @import("evport_kqueue.zig");
const EvPort = kq.EvPort;
const Kevent = kq.Kevent;
const TimerError = kq.TimerError;
const TimerMode = kq.TimerMode;

const EV_ADD = std.posix.system.EV.ADD;
const EV_DELETE = std.posix.system.EV.DELETE;
const EV_ONESHOT = std.posix.system.EV.ONESHOT;
// Zig 0.15 omits ERROR on NetBSD (sys/event.h); same value as evport_kqueue.zig.
const EV_ERROR = if (@hasDecl(std.posix.system.EV, "ERROR")) std.posix.system.EV.ERROR else 0x4000;
const ENOENT = @intFromEnum(std.posix.E.NOENT);

/// EVFILT_TIMER fflags selecting milliseconds; see the unit table above.
const NOTE_MSECONDS: @FieldType(Kevent, "fflags") = switch (builtin.os.tag) {
    .freebsd => 0x2,
    .netbsd, .openbsd => 0,
    else => if (builtin.os.tag.isDarwin()) 0 else @compileError("born: unknown EVFILT_TIMER millisecond unit"),
};

/// Per-port timer bookkeeping, a field of EvPort (`timers`).
pub const State = struct {
    /// Armed ids and their mode. An id is live from add until cancel, or
    /// until `observe` sees a `.once` firing.
    live: std.AutoHashMapUnmanaged(u32, TimerMode) = .empty,

    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Closing the kqueue drops every knote; only the bookkeeping is freed.
    pub fn deinit(self: *State, port: *EvPort) void {
        self.live.deinit(port.alloc);
    }
};

/// Stages the timer for the next wait(). Allocation happens up front, so
/// OutOfMemory leaves the port unchanged. A kernel refusal of the EV_ADD
/// arrives at wait() as Event{ .err, .err_no } with the timer's udata.
pub fn add(port: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
    if (mode == .repeat and after_ms == 0) return TimerError.InvalidArgument;
    port.changes.ensureUnusedCapacity(port.alloc, 2) catch return TimerError.OutOfMemory;
    const slot = port.timers.live.getOrPut(port.alloc, id) catch return TimerError.OutOfMemory;
    if (slot.found_existing) port.stageRaw(change(id, EV_DELETE, null, 0));
    slot.value_ptr.* = mode;
    const flags: @FieldType(Kevent, "flags") = if (mode == .once) EV_ADD | EV_ONESHOT else EV_ADD;
    port.stageRaw(change(id, flags, udata, after_ms));
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

/// Sees each EVFILT_TIMER kevent first; false suppresses it. Retires a
/// fired `.once` id and drops the ENOENT of a delete that found no knote.
pub fn observe(port: *EvPort, kev: Kevent) bool {
    if ((kev.flags & EV_ERROR) != 0) return kev.data != ENOENT;
    const id = std.math.cast(u32, kev.ident) orelse return true;
    if (port.timers.live.get(id)) |mode| {
        if (mode == .once) _ = port.timers.live.remove(id);
    }
    return true;
}

fn change(id: u32, flags: @FieldType(Kevent, "flags"), udata: ?*anyopaque, after_ms: u32) Kevent {
    var kev = std.mem.zeroes(Kevent);
    kev.ident = id;
    kev.filter = kq.EVFILT_TIMER;
    kev.flags = flags;
    kev.fflags = NOTE_MSECONDS;
    kev.data = after_ms;
    kev.udata = @intFromPtr(udata);
    return kev;
}

// --------------------------------------------------------------- tests ----

const testing = std.testing;
const Event = kq.Event;

/// Waits up to `window_ms` for one event.
fn waitOne(port: *EvPort, events: []Event, window_ms: i32) !usize {
    var timer = try std.time.Timer.start();
    while (true) {
        const elapsed: i32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= window_ms) return 0;
        const n = try port.wait(events, window_ms - elapsed);
        if (n != 0) return n;
    }
}

test "timer_kqueue: change encoding uses the target's millisecond unit" {
    var tag: u8 = 1;
    const kev = change(7, EV_ADD | EV_ONESHOT, &tag, 250);
    try testing.expectEqual(@as(usize, 7), kev.ident);
    try testing.expectEqual(kq.EVFILT_TIMER, kev.filter);
    try testing.expectEqual(EV_ADD | EV_ONESHOT, kev.flags);
    try testing.expectEqual(@as(@TypeOf(kev.data), 250), kev.data);
    try testing.expectEqual(@intFromPtr(&tag), kev.udata);
    const expected: u32 = switch (builtin.os.tag) {
        .freebsd => std.c.NOTE.MSECONDS,
        else => 0,
    };
    try testing.expectEqual(expected, kev.fflags);
}

test "timer_kqueue: cancelling an expired or unknown id stages nothing" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    var tag: u8 = 1;
    try add(&port, 1, &tag, 1, .once);
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
    try add(&port, 2, &tag, 5, .once);
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    std.Thread.sleep(30 * std.time.ns_per_ms);
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
    try port.timers.live.put(testing.allocator, 3, .repeat);
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
    kev.data = @intFromEnum(std.posix.E.INVAL);
    try testing.expect(observe(&port, kev));
    kev.data = ENOENT;
    try testing.expect(!observe(&port, kev));
}

test "timer_kqueue: replacing a live id changes its mode" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [8]Event = undefined;
    var a: u8 = 1;
    var b: u8 = 2;
    // repeat -> once: exactly one firing, then the id is retired.
    try add(&port, 5, &a, 5, .repeat);
    try add(&port, 5, &b, 5, .once);
    try testing.expectEqual(@as(usize, 1), try waitOne(&port, &events, 1000));
    try testing.expect(events[0].udata == @as(?*anyopaque, &b));
    try testing.expect(!port.timers.live.contains(5));
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
    // once -> repeat: keeps firing until cancelled.
    try add(&port, 6, &a, 1000, .once);
    try add(&port, 6, &b, 5, .repeat);
    var fired: usize = 0;
    while (fired < 3) {
        const n = try waitOne(&port, &events, 1000);
        try testing.expect(n != 0);
        for (events[0..n]) |ev| {
            try testing.expect(ev.timer and ev.udata == @as(?*anyopaque, &b));
            fired += 1;
        }
    }
    try testing.expectEqual(@as(?TimerMode, .repeat), port.timers.live.get(6));
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
    try testing.expectError(TimerError.OutOfMemory, add(&port, 8, &tag, 10, .once));
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
    try add(&port, 9, &tag, 5, .repeat);
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
