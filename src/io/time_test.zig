//! Time-route tests for the born.io shim (P5.2).
//!
//! These exercise the Scale model machinery and the Born evented time family:
//! sleep on Born's timers, monotonic now on Born's clock, cross-thread
//! submission from Threaded workers, cancellation through the loop's
//! cancelTimer path, and the caller-owned submission queue bound. The
//! delegation tests prove the remaining slots still run on Threaded while the
//! loop thread is live. Runtime evidence requires running these on each
//! kernel; a cross-build is not evidence.

const std = @import("std");
const born = @import("born");
const born_io = @import("root.zig");
const shim = @import("shim.zig");
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

fn initTimeIo(port: *born.EvPort) born_io.InitError!Io {
    return born_io.io(port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .time = .born_evented },
    });
}

fn elapsedNs(since: u64) error{Unsupported}!u64 {
    return (try born.nowNs()) - since;
}

test "time route constructs with the Born time vtable and deinits" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    // Slot contents, not vtable addresses: comptime constants may materialize
    // as distinct copies.
    try expect(std.meta.eql(interface.vtable.*, born_io.time_vtable));
    try expect(!std.meta.eql(interface.vtable.sleep, born_io.baseline_vtable.sleep));
    try expect(!std.meta.eql(interface.vtable.now, born_io.baseline_vtable.now));
    // The rest of the surface keeps delegating to Threaded.
    try expect(std.meta.eql(interface.vtable.async, born_io.baseline_vtable.async));
    try expect(std.meta.eql(interface.vtable.concurrent, born_io.baseline_vtable.concurrent));
    try expect(std.meta.eql(interface.vtable.cancel, born_io.baseline_vtable.cancel));
    try expect(std.meta.eql(interface.vtable.futexWait, born_io.baseline_vtable.futexWait));
    try expect(std.meta.eql(interface.vtable.clockResolution, born_io.baseline_vtable.clockResolution));
    try expect(std.meta.eql(interface.vtable.operate, born_io.baseline_vtable.operate));
}

test "time route sleep elapses the requested duration on the Born clock" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    const t0 = try born.nowNs();
    try Io.sleep(interface, .fromMilliseconds(40), .awake);
    const elapsed = try elapsedNs(t0);
    try expect(elapsed >= 40 * ms);
    try expect(elapsed < 5 * s);
}

test "time route sleep honors deadlines and past deadlines" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    const now_ns = try born.nowNs();
    const t0 = now_ns;
    try interface.vtable.sleep(interface.userdata, .{
        .deadline = .{ .raw = .fromNanoseconds(@intCast(now_ns + 30 * ms)), .clock = .awake },
    });
    const elapsed = try elapsedNs(t0);
    try expect(elapsed >= 30 * ms);
    try expect(elapsed < 5 * s);

    // A deadline already in the past returns without waiting.
    const t1 = try born.nowNs();
    try interface.vtable.sleep(interface.userdata, .{
        .deadline = .{ .raw = .fromNanoseconds(@intCast(t1 - 10 * ms)), .clock = .awake },
    });
    try expect(try elapsedNs(t1) < 1 * s);
}

test "time route sleep none and zero return immediately" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    // Threaded semantics: .none is no wait, not an infinite sleep.
    const t0 = try born.nowNs();
    try interface.vtable.sleep(interface.userdata, .none);
    try expect(try elapsedNs(t0) < 1 * s);

    const t1 = try born.nowNs();
    try Io.sleep(interface, .zero, .awake);
    try expect(try elapsedNs(t1) < 1 * s);
}

test "time route now reads the Born timer clock for awake and delegates other tags" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    // now(.awake) and the port's timer clock agree.
    const a: i128 = Io.Timestamp.now(interface, .awake).nanoseconds;
    const b: i128 = try born.nowNs();
    try expect(@abs(a - b) < 100 * ms);
    const c: i128 = Io.Timestamp.now(interface, .awake).nanoseconds;
    try expect(c >= a);

    // Other tags stay on Threaded: real tracks the wall-clock epoch (far
    // larger than any monotonic-since-boot value), cpu_thread is a small
    // process-lifetime value.
    const real: i128 = Io.Timestamp.now(interface, .real).nanoseconds;
    try expect(real > 1_600_000_000 * @as(i128, s));
    const awake: i128 = Io.Timestamp.now(interface, .awake).nanoseconds;
    try expect(awake >= 0 and awake < real);
    const cpu: i128 = Io.Timestamp.now(interface, .cpu_thread).nanoseconds;
    try expect(cpu >= 0 and cpu < 3600 * s);
}

fn sleeper(io: Io, done: *std.atomic.Value(u32)) Io.Cancelable!void {
    try Io.sleep(io, .fromMilliseconds(100), .awake);
    _ = done.fetchAdd(1, .acq_rel);
}

test "submission queue is bounded by caller storage: 64 concurrent sleepers" {
    // The review-156 queue bound: one caller-owned node per blocking call, so
    // 64 simultaneous submissions are all serviced. There is no fixed ring to
    // fill and no queue-full error path. Serialized execution would take
    // 64 * 100 ms = 6.4 s; the bound below proves the loop services them
    // concurrently through the cross-thread Scale model path.
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var done: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    const t0 = try born.nowNs();
    for (0..64) |_| try group.concurrent(interface, sleeper, .{ interface, &done });
    try group.await(interface);
    const elapsed = try elapsedNs(t0);
    try expectEqual(@as(u32, 64), done.load(.acquire));
    try expect(elapsed >= 100 * ms);
    try expect(elapsed < 5 * s);
}

fn longSleeper(io: Io) Io.Cancelable!void {
    try Io.sleep(io, .fromSeconds(10), .awake);
}

test "time route sleep is cancelable through the Born timer path" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var future = try Io.concurrent(interface, longSleeper, .{interface});
    // Let the worker submit and arm its timer.
    try Io.sleep(interface, .fromMilliseconds(50), .awake);
    const t0 = try born.nowNs();
    const result = future.cancel(interface);
    try expectError(error.Canceled, result);
    // Cancel must not wait out the 10 s sleep.
    try expect(try elapsedNs(t0) < 2 * s);
}

test "time route cancel races never hang or corrupt caller storage" {
    // Immediate cancel races the submission; each iteration reuses the same
    // stack, exercising the retire-before-unwind ownership rule.
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    for (0..50) |_| {
        var future = try Io.concurrent(interface, longSleeper, .{interface});
        try expectError(error.Canceled, future.cancel(interface));
    }
}

fn longSleeperCounted(io: Io, done: *std.atomic.Value(u32)) Io.Cancelable!void {
    try Io.sleep(io, .fromSeconds(10), .awake);
    _ = done.fetchAdd(1, .acq_rel);
}

test "time route group cancel drains Born sleepers and the group is reusable" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var done: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..8) |_| try group.concurrent(interface, longSleeperCounted, .{ interface, &done });
    try Io.sleep(interface, .fromMilliseconds(30), .awake);
    group.cancel(interface);
    try expectEqual(@as(u32, 0), done.load(.acquire));

    try group.concurrent(interface, sleeper, .{ interface, &done });
    try group.await(interface);
    try expectEqual(@as(u32, 1), done.load(.acquire));
}

test "time route sleep needs no Threaded workers" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try born_io.io(&port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .time = .born_evented },
        .threaded = .{ .async_limit = .nothing, .concurrent_limit = .nothing },
    });
    defer born_io.deinit(interface);

    const t0 = try born.nowNs();
    try Io.sleep(interface, .fromMilliseconds(20), .awake);
    try expect(try elapsedNs(t0) >= 20 * ms);
}

/// Counts every allocation routed through it, forwarding to the child.
const Counting = struct {
    child: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "time route sleep performs no shim allocations" {
    // Submission is an intrusive push of caller-owned storage; the sleep path
    // must not allocate. The port's own timer bookkeeping uses the port's
    // allocator, not the shim's.
    var counting: Counting = .{ .child = std.testing.allocator };
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try born_io.io(&port, .{
        .allocator = counting.allocator(),
        .capabilities = .{ .time = .born_evented },
    });
    defer born_io.deinit(interface);

    const baseline_count = counting.count.load(.monotonic);
    for (0..3) |_| try Io.sleep(interface, .fromMilliseconds(5), .awake);
    try expectEqual(baseline_count, counting.count.load(.monotonic));
}

fn addOne(x: u32) u32 {
    return x + 1;
}

test "time route keeps async and await on Threaded" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var future = Io.async(interface, addOne, .{@as(u32, 41)});
    try expectEqual(@as(u32, 42), future.await(interface));
}

fn futexWaiter(io: Io, word: *std.atomic.Value(u32)) Io.Cancelable!void {
    while (word.load(.acquire) == 0) {
        try io.vtable.futexWait(io.userdata, &word.raw, 0, .none);
    }
}

test "time route keeps futex delegation with cross-thread wake" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var word: std.atomic.Value(u32) = .init(0);
    var future = try Io.concurrent(interface, futexWaiter, .{ interface, &word });
    // The main thread sleeps on Born while the worker waits on a Threaded
    // futex; the wake then comes from the main thread.
    try Io.sleep(interface, .fromMilliseconds(30), .awake);
    word.store(1, .release);
    interface.vtable.futexWake(interface.userdata, &word.raw, 1);
    try future.await(interface);
}

test "time route cancels a Threaded futex wait" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var word: std.atomic.Value(u32) = .init(0);
    var future = try Io.concurrent(interface, futexWaiter, .{ interface, &word });
    try Io.sleep(interface, .fromMilliseconds(30), .awake);
    try expectError(error.Canceled, future.cancel(interface));
}

fn producer(io: Io, queue: *Io.Queue(u32)) (Io.Cancelable || error{Closed})!void {
    try queue.putAll(io, &.{7});
}

test "time route keeps queue delegation" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var buffer: [4]u32 = undefined;
    var queue: Io.Queue(u32) = .init(&buffer);
    var future = try Io.concurrent(interface, producer, .{ interface, &queue });
    var out: [1]u32 = undefined;
    try expectEqual(@as(usize, 1), try queue.get(interface, &out, 1));
    try expectEqual(@as(u32, 7), out[0]);
    try future.await(interface);
}

test "ceilMs rounds up, clamps, and saturates" {
    try expectEqual(@as(u32, 1), shim.ceilMs(1));
    try expectEqual(@as(u32, 1), shim.ceilMs(1 * ms));
    try expectEqual(@as(u32, 2), shim.ceilMs(1 * ms + 1));
    try expectEqual(@as(u32, std.math.maxInt(u32)), shim.ceilMs(std.math.maxInt(u64)));
    try expectEqual(
        @as(u32, std.math.maxInt(u32)),
        shim.ceilMs(@as(u64, std.math.maxInt(u32)) * ms + 1),
    );
}

test "pickTimerId skips live ids after a wrap" {
    var state: shim.Shim = undefined;
    state.next_timer_id = 5;
    state.id_wrapped = true;
    state.live = null;
    state.live_count = 0;

    var a: shim.SleepOp = .{ .timer_id = 5 };
    var b: shim.SleepOp = .{ .timer_id = 7 };
    a.live_next = &b;
    b.live_prev = &a;
    state.live = &a;
    state.live_count = 2;

    // 5 is armed: skip to 6.
    try expectEqual(@as(u32, 6), state.pickTimerId());
    // Arm 6 as the loop would, then the next candidate skips 6 and 7.
    var c: shim.SleepOp = .{ .timer_id = 6 };
    c.live_next = state.live;
    state.live.?.live_prev = &c;
    state.live = &c;
    state.live_count = 3;
    try expectEqual(@as(u32, 8), state.pickTimerId());

    // Before the first wrap, ids are unique by construction: no scan.
    state.id_wrapped = false;
    state.next_timer_id = 5;
    try expectEqual(@as(u32, 5), state.pickTimerId());
}
