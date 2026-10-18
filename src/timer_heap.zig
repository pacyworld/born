//! Portable deadline heap for backends with one kernel timer per port
//! (timer_epoll.zig, timer_iocp.zig). Owned by born#11: this file and its
//! unit tests. kqueue does not use it (native EVFILT_TIMER per timer).
//!
//! A binary min-heap of { deadline_ns, id, udata, period_ns } plus an
//! id -> heap position index, so add, cancel and each popped entry of
//! expire are O(log n). Deadlines are nanoseconds on the monotonic clock
//! read by `nowNs`, never wall time. The heap never reads the clock
//! itself: every time-dependent call takes `now_ns`, so tests and backends
//! control time explicitly.
//!
//! ## API
//!
//!   var heap: TimerHeap = .empty;
//!   defer heap.deinit(gpa);
//!   try heap.ensureTotalCapacity(gpa, n)      // optional pre-size
//!   try heap.add(gpa, now_ns, id, udata, after_ns, period_ns)
//!   heap.cancel(id) bool                      // true if id was live
//!   heap.next() ?u64                          // earliest deadline_ns
//!   heap.expire(now_ns, out: []Expired) usize // due entries, earliest first
//!   heap.count() usize, heap.contains(id) bool, heap.deadlineOf(id) ?u64
//!   nowNs() error{Unsupported}!u64           // the clock deadlines use
//!
//! ## Semantics
//!
//!   - `add` sets the deadline to `now_ns + after_ns` (saturating). An id
//!     that is already live is replaced in place: new deadline, udata and
//!     period, no allocation. `period_ns == 0` is a one-shot; any other
//!     value repeats every `period_ns`.
//!   - Only `add` of a new id and `ensureTotalCapacity` allocate, through
//!     the allocator passed to them. error.OutOfMemory is returned with
//!     the heap unchanged. Once capacity covers the live timer count no
//!     operation allocates (see the steady-state test).
//!   - `expire` pops every entry with `deadline_ns <= now_ns`, up to
//!     `out.len`. A one-shot is removed and reports `fired = 1`. A
//!     repeating entry reports `fired = 1 + missed periods` and is
//!     re-inserted at `deadline + fired * period_ns`, the first slot of its
//!     original phase after `now_ns`, so it never drifts. Entries that do
//!     not fit in `out` stay due and are returned by the next call.
//!   - Equal deadlines expire in the order they were added or re-armed.
//!   - `next()` is what a backend arms its single kernel timer to (timerfd
//!     with CLOCK_MONOTONIC and TFD_TIMER_ABSTIME on epoll, a relative
//!     thread-pool due time of `next - nowNs()` on IOCP). It may already
//!     be in the past when `expire` was given a short `out`.
//!   - Ids are the caller's (EvPort.addTimer ids). The heap holds at most
//!     one entry per id, so positions always fit in u32.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// One timer returned by `expire`.
pub const Expired = struct {
    id: u32,
    udata: ?*anyopaque,
    /// Expirations since this timer was last reported: 1 for a one-shot,
    /// 1 + missed periods for a repeating timer. Saturates at maxInt(u32).
    fired: u32,
};

const Entry = struct {
    deadline_ns: u64,
    /// Insertion order, the tie-break for equal deadlines.
    seq: u64,
    period_ns: u64,
    udata: ?*anyopaque,
    id: u32,

    fn before(a: Entry, b: Entry) bool {
        if (a.deadline_ns != b.deadline_ns) return a.deadline_ns < b.deadline_ns;
        return a.seq < b.seq;
    }
};

pub const TimerHeap = struct {
    heap: std.ArrayListUnmanaged(Entry) = .empty,
    /// id -> position in `heap`. An array hash map removes without
    /// tombstones, so lookups stay O(1) under add/cancel churn.
    index: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty,
    seq: u64 = 0,

    pub const empty: TimerHeap = .{};

    pub fn deinit(self: *TimerHeap, gpa: Allocator) void {
        self.heap.deinit(gpa);
        self.index.deinit(gpa);
        self.* = undefined;
    }

    /// Reserves room for `n` live timers so later adds do not allocate.
    pub fn ensureTotalCapacity(self: *TimerHeap, gpa: Allocator, n: usize) Error!void {
        try self.heap.ensureTotalCapacity(gpa, n);
        try self.index.ensureTotalCapacity(gpa, n);
    }

    pub fn count(self: *const TimerHeap) usize {
        return self.heap.items.len;
    }

    pub fn contains(self: *const TimerHeap, id: u32) bool {
        return self.index.contains(id);
    }

    /// The live deadline of `id`, or null if it is not live.
    pub fn deadlineOf(self: *const TimerHeap, id: u32) ?u64 {
        const pos = self.index.get(id) orelse return null;
        return self.heap.items[pos].deadline_ns;
    }

    /// Arms `id` to expire at `now_ns + after_ns`, repeating every
    /// `period_ns` unless it is 0. Replaces a live entry with the same id.
    pub fn add(
        self: *TimerHeap,
        gpa: Allocator,
        now_ns: u64,
        id: u32,
        udata: ?*anyopaque,
        after_ns: u64,
        period_ns: u64,
    ) Error!void {
        const entry: Entry = .{
            .deadline_ns = now_ns +| after_ns,
            .seq = self.nextSeq(),
            .period_ns = period_ns,
            .udata = udata,
            .id = id,
        };
        if (self.index.get(id)) |pos| {
            self.heap.items[pos] = entry;
            self.fix(pos);
            return;
        }
        // Reserve both before mutating so a failure leaves the heap as it was.
        try self.heap.ensureUnusedCapacity(gpa, 1);
        try self.index.ensureUnusedCapacity(gpa, 1);
        const pos = self.heap.items.len;
        self.heap.appendAssumeCapacity(entry);
        self.index.putAssumeCapacityNoClobber(id, @intCast(pos));
        self.siftUp(pos);
    }

    /// Removes `id`. Returns false if it was not live.
    pub fn cancel(self: *TimerHeap, id: u32) bool {
        const kv = self.index.fetchSwapRemove(id) orelse return false;
        self.removeAt(kv.value);
        return true;
    }

    /// The earliest deadline, or null when no timer is live.
    pub fn next(self: *const TimerHeap) ?u64 {
        if (self.heap.items.len == 0) return null;
        return self.heap.items[0].deadline_ns;
    }

    /// Writes up to `out.len` due timers (deadline <= now_ns), earliest
    /// first, and returns how many. One-shots are removed; repeating timers
    /// are re-armed on their original phase after `now_ns`.
    pub fn expire(self: *TimerHeap, now_ns: u64, out: []Expired) usize {
        var n: usize = 0;
        while (n < out.len and self.heap.items.len != 0) : (n += 1) {
            const top = &self.heap.items[0];
            if (top.deadline_ns > now_ns) break;
            if (top.period_ns == 0) {
                out[n] = .{ .id = top.id, .udata = top.udata, .fired = 1 };
                _ = self.index.swapRemove(top.id);
                self.removeAt(0);
            } else {
                const periods = (now_ns - top.deadline_ns) / top.period_ns + 1;
                out[n] = .{
                    .id = top.id,
                    .udata = top.udata,
                    .fired = std.math.cast(u32, periods) orelse std.math.maxInt(u32),
                };
                top.deadline_ns = top.deadline_ns +| (periods *| top.period_ns);
                top.seq = self.nextSeq();
                self.siftDown(0);
            }
        }
        return n;
    }

    fn nextSeq(self: *TimerHeap) u64 {
        const s = self.seq;
        self.seq +%= 1;
        return s;
    }

    /// Drops the entry at `pos`, whose id is already out of the index.
    fn removeAt(self: *TimerHeap, pos: usize) void {
        const last = self.heap.pop().?;
        if (pos == self.heap.items.len) return;
        self.heap.items[pos] = last;
        self.fix(pos);
    }

    /// Restores heap order around `pos` after its entry changed.
    fn fix(self: *TimerHeap, pos: usize) void {
        const items = self.heap.items;
        if (pos > 0 and items[pos].before(items[(pos - 1) / 2])) {
            self.siftUp(pos);
        } else {
            self.siftDown(pos);
        }
    }

    fn siftUp(self: *TimerHeap, start: usize) void {
        const items = self.heap.items;
        const e = items[start];
        var pos = start;
        while (pos > 0) {
            const parent = (pos - 1) / 2;
            if (!e.before(items[parent])) break;
            self.place(pos, items[parent]);
            pos = parent;
        }
        self.place(pos, e);
    }

    fn siftDown(self: *TimerHeap, start: usize) void {
        const items = self.heap.items;
        const e = items[start];
        var pos = start;
        while (true) {
            var child = 2 * pos + 1;
            if (child >= items.len) break;
            if (child + 1 < items.len and items[child + 1].before(items[child])) child += 1;
            if (!items[child].before(e)) break;
            self.place(pos, items[child]);
            pos = child;
        }
        self.place(pos, e);
    }

    /// Stores `e` at `pos` and points its index entry there.
    fn place(self: *TimerHeap, pos: usize, e: Entry) void {
        self.heap.items[pos] = e;
        self.index.getPtr(e.id).?.* = @intCast(pos);
    }
};

/// Current time on the clock deadlines are measured in, in nanoseconds:
/// CLOCK_MONOTONIC on POSIX, QueryPerformanceCounter on Windows. Never
/// wall time. error.Unsupported if the kernel refuses the clock.
pub fn nowNs() error{Unsupported}!u64 {
    if (builtin.os.tag == .windows) {
        const ticks = std.os.windows.QueryPerformanceCounter();
        const freq = std.os.windows.QueryPerformanceFrequency();
        return (ticks / freq) * std.time.ns_per_s + (ticks % freq) * std.time.ns_per_s / freq;
    }
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return error.Unsupported;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const max_ns = std.math.maxInt(u64);

/// Checks the heap property and that the index maps every id to its slot.
fn validate(h: *const TimerHeap) !void {
    const items = h.heap.items;
    try testing.expectEqual(items.len, h.index.count());
    for (items, 0..) |e, i| {
        if (i > 0) try testing.expect(!e.before(items[(i - 1) / 2]));
        try testing.expectEqual(@as(?u32, @intCast(i)), h.index.get(e.id));
    }
}

fn tag(n: usize) ?*anyopaque {
    return @ptrFromInt(0x1000 + n * 8);
}

test "timer_heap: 10 000 random deadlines expire in order" {
    const gpa = testing.allocator;
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x11_b0e1);
    const rand = prng.random();

    const n = 10_000;
    var deadline: [n]u64 = undefined;
    var seen = [_]bool{false} ** n;
    for (0..n) |i| {
        deadline[i] = rand.uintLessThan(u64, 1_000_000_000);
        try h.add(gpa, 0, @intCast(i), tag(i), deadline[i], 0);
    }
    try validate(&h);
    try testing.expectEqual(@as(usize, n), h.count());

    // Advance time in steps: each call returns only due entries, in
    // deadline order, and next() never moves backwards.
    var out: [64]Expired = undefined;
    var last: u64 = 0;
    var total: usize = 0;
    var now: u64 = 0;
    while (h.count() != 0) {
        now += 7_000_000;
        while (true) {
            const got = h.expire(now, &out);
            for (out[0..got]) |e| {
                const d = deadline[e.id];
                try testing.expect(d <= now);
                try testing.expect(d >= last);
                try testing.expect(!seen[e.id]);
                try testing.expectEqual(tag(e.id), e.udata);
                try testing.expectEqual(@as(u32, 1), e.fired);
                seen[e.id] = true;
                last = d;
            }
            total += got;
            if (got < out.len) break;
        }
        if (h.next()) |nx| try testing.expect(nx > now and nx >= last);
    }
    try testing.expectEqual(@as(usize, n), total);
    try testing.expectEqual(@as(?u64, null), h.next());
}

test "timer_heap: random add/cancel/replace keeps heap and index consistent" {
    const gpa = testing.allocator;
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const ids = 512;
    var live = [_]?u64{null} ** ids;
    for (0..20_000) |_| {
        const id = rand.uintLessThan(u32, ids);
        if (rand.boolean()) {
            const after = rand.uintLessThan(u64, 1_000_000);
            try h.add(gpa, 0, id, null, after, 0);
            live[id] = after;
        } else {
            try testing.expectEqual(live[id] != null, h.cancel(id));
            live[id] = null;
        }
    }
    try validate(&h);
    var min: ?u64 = null;
    for (live, 0..) |d, id| {
        try testing.expectEqual(d, h.deadlineOf(@intCast(id)));
        if (d) |v| min = if (min) |m| @min(m, v) else v;
    }
    try testing.expectEqual(min, h.next());
}

test "timer_heap: cancel head, middle and absent id" {
    const gpa = testing.allocator;
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);
    for (1..6) |i| try h.add(gpa, 0, @intCast(i), tag(i), i * 10, 0);
    try testing.expectEqual(@as(?u64, 10), h.next());

    try testing.expect(h.cancel(1)); // head
    try testing.expectEqual(@as(?u64, 20), h.next());
    try validate(&h);

    try testing.expect(h.cancel(3)); // middle
    try testing.expect(!h.contains(3));
    try validate(&h);

    try testing.expect(!h.cancel(99)); // never added
    try testing.expect(!h.cancel(3)); // already cancelled
    try testing.expectEqual(@as(usize, 3), h.count());

    var out: [8]Expired = undefined;
    const got = h.expire(max_ns, &out);
    try testing.expectEqual(@as(usize, 3), got);
    const want = [_]u32{ 2, 4, 5 };
    for (want, out[0..got]) |id, e| try testing.expectEqual(id, e.id);
    try testing.expectEqual(@as(?u64, null), h.next());
    try testing.expect(!h.cancel(2)); // one-shot already expired
}

test "timer_heap: add replaces a live id" {
    const gpa = testing.allocator;
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);
    var a: u8 = 0;
    var b: u8 = 0;
    try h.add(gpa, 0, 1, null, 300, 0);
    try h.add(gpa, 0, 2, null, 200, 0);
    try h.add(gpa, 0, 7, &a, 100, 0);

    // Later deadline, new udata, now repeating: moves down past the others.
    try h.add(gpa, 0, 7, &b, 400, 50);
    try testing.expectEqual(@as(usize, 3), h.count());
    try testing.expectEqual(@as(?u64, 200), h.next());
    try testing.expectEqual(@as(?u64, 400), h.deadlineOf(7));
    try validate(&h);

    // Earlier deadline: moves back to the head.
    try h.add(gpa, 0, 7, &b, 50, 0);
    try testing.expectEqual(@as(?u64, 50), h.next());
    try validate(&h);

    var out: [8]Expired = undefined;
    try testing.expectEqual(@as(usize, 1), h.expire(50, &out));
    try testing.expectEqual(@as(u32, 7), out[0].id);
    try testing.expect(out[0].udata == @as(?*anyopaque, &b));
    try testing.expectEqual(@as(u32, 1), out[0].fired);
    try testing.expect(!h.contains(7)); // replaced as a one-shot, so it is gone
    try testing.expectEqual(@as(usize, 2), h.count());
}

test "timer_heap: repeating timer reports 3 missed periods and keeps its phase" {
    const gpa = testing.allocator;
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);
    // Armed at t=7 with period 100: deadlines 107, 207, 307, ...
    try h.add(gpa, 7, 1, null, 100, 100);
    var out: [4]Expired = undefined;

    try testing.expectEqual(@as(usize, 0), h.expire(106, &out));
    try testing.expectEqual(@as(usize, 1), h.expire(107, &out));
    try testing.expectEqual(@as(u32, 1), out[0].fired);
    try testing.expectEqual(@as(?u64, 207), h.next());

    // Loop stalls until 457: 207, 307 and 407 have all passed.
    try testing.expectEqual(@as(usize, 1), h.expire(457, &out));
    try testing.expectEqual(@as(u32, 3), out[0].fired);
    try testing.expectEqual(@as(?u64, 507), h.next()); // still 7 mod 100

    try testing.expectEqual(@as(usize, 0), h.expire(506, &out));
    try testing.expectEqual(@as(usize, 1), h.expire(507, &out));
    try testing.expectEqual(@as(u32, 1), out[0].fired);
    try testing.expectEqual(@as(?u64, 607), h.next());
    try testing.expect(h.contains(1));
}

test "timer_heap: expire stops at out.len and leaves the rest due" {
    const gpa = testing.allocator;
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);
    for (0..5) |i| try h.add(gpa, 0, @intCast(i), null, 10, 0);
    try h.add(gpa, 0, 9, null, 10, 10); // repeating, same deadline, added last

    try testing.expectEqual(@as(usize, 0), h.expire(100, &.{}));
    var out: [2]Expired = undefined;
    var order: [6]u32 = undefined;
    var n: usize = 0;
    while (true) {
        const got = h.expire(15, &out);
        if (got == 0) break;
        for (out[0..got]) |e| {
            order[n] = e.id;
            n += 1;
        }
        if (h.next()) |nx| try testing.expect(nx <= 15 or nx == 20);
    }
    // Equal deadlines expire in the order they were added.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 9 }, order[0..n]);
    try testing.expectEqual(@as(?u64, 20), h.next());
}

test "timer_heap: no allocation in steady state with a fixed timer count" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var h: TimerHeap = .empty;
    defer h.deinit(gpa);

    const live = 256;
    for (0..live) |i| try h.add(gpa, 0, @intCast(i), null, i * 1000, if (i % 2 == 0) 5000 else 0);

    // From here on any allocation or resize fails the test with OutOfMemory.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const allocations = failing.allocations;

    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var next_id: u32 = live;
    var now: u64 = 0;
    var out: [16]Expired = undefined;
    for (0..100_000) |_| {
        now += rand.uintLessThan(u64, 2000);
        // Expired one-shots are replaced by fresh ids to hold the count.
        const got = h.expire(now, &out);
        for (out[0..got]) |e| {
            if (!h.contains(e.id)) {
                try h.add(gpa, now, next_id, null, rand.uintLessThan(u64, 300_000), 0);
                next_id +%= 1;
            }
        }
        // Churn: cancel a live id and add a new one, and replace in place.
        const victim = h.heap.items[rand.uintLessThan(usize, h.count())].id;
        try testing.expect(h.cancel(victim));
        try h.add(gpa, now, next_id, null, rand.uintLessThan(u64, 300_000), rand.uintLessThan(u64, 3) * 4000);
        next_id +%= 1;
        const keep = h.heap.items[rand.uintLessThan(usize, h.count())].id;
        try h.add(gpa, now, keep, null, rand.uintLessThan(u64, 300_000), 0);
        try testing.expectEqual(@as(usize, live), h.count());
    }
    try validate(&h);
    try testing.expectEqual(allocations, failing.allocations);
    try testing.expect(!failing.has_induced_failure);
}

test "timer_heap: allocation failure is returned and leaves the heap unchanged" {
    // Fail at every allocation index in turn until 64 adds need fewer
    // allocations; the heap must keep exactly the timers whose add
    // succeeded.
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_at,
            .resize_fail_index = fail_at,
        });
        const gpa = failing.allocator();
        var h: TimerHeap = .empty;
        defer h.deinit(gpa);
        var added: u32 = 0;
        var failed: ?Error = null;
        while (added < 64) : (added += 1) {
            h.add(gpa, 0, added, null, 1000 - added, 0) catch |err| {
                failed = err;
                break;
            };
        }
        if (failed == null) {
            // Index 0 must fail, and at least the index header growth past
            // the linear-scan size must have been covered.
            try testing.expect(fail_at >= 3);
            break;
        }
        try testing.expectEqual(@as(?Error, error.OutOfMemory), failed);
        try testing.expectEqual(@as(usize, added), h.count());
        try testing.expect(!h.contains(added));
        try validate(&h);
        // Replacing a live id still works without allocating.
        if (added != 0) try h.add(gpa, 0, 0, null, 1, 0);
        try testing.expectEqual(@as(?u64, if (added != 0) 1 else null), h.next());
    }
}

test "timer_heap: nowNs is monotonic" {
    const a = try nowNs();
    const b = try nowNs();
    try testing.expect(b >= a);
    try testing.expect(a > 0);
}
