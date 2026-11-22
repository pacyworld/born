//! Time-route tests for the born.io shim (P5.2).
//!
//! These exercise the Scale model machinery and the Born evented time family:
//! sleep on Born's timers, monotonic now on Born's clock, cross-thread
//! submission from Threaded workers, cancellation through the loop's cancel
//! list, the loop-owned slot table's stale-fire guard, and the caller-owned
//! submission queue bound. The delegation tests prove the remaining slots
//! still run on Threaded while the loop thread is live. Runtime evidence
//! requires running these on each kernel; a cross-build is not evidence.

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

/// Event-driven wait until `n` sleepers have submitted (#117, the #116
/// pattern). A fixed sleep races thread startup under scheduler load; the
/// hook counts actual submissions, so the wait is deterministic.
fn waitSubmitted(io: Io, submitted: *std.atomic.Value(u32), n: u32) void {
    while (true) {
        const cur = submitted.load(.acquire);
        if (cur >= n) return;
        Io.futexWaitUncancelable(io, u32, &submitted.raw, cur);
    }
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

    // Wait for the worker's actual submission, not a fixed sleep (#117).
    // Install before spawning so a fast submit cannot miss the bump.
    var submitted: std.atomic.Value(u32) = .init(0);
    shim.testTimeSubmitHook(interface, &submitted);
    var future = try Io.concurrent(interface, longSleeper, .{interface});
    waitSubmitted(interface, &submitted, 1);
    shim.testTimeSubmitHook(interface, null);
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
    // Wait for all eight actual submissions, not a fixed sleep (#117).
    var submitted: std.atomic.Value(u32) = .init(0);
    shim.testTimeSubmitHook(interface, &submitted);
    for (0..8) |_| try group.concurrent(interface, longSleeperCounted, .{ interface, &done });
    waitSubmitted(interface, &submitted, 8);
    shim.testTimeSubmitHook(interface, null);
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
    // Submission is an intrusive push of caller-owned storage into the slot
    // table preallocated at construction; the steady-state sleep path must
    // not allocate. The port's own timer bookkeeping uses the port's
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

test "cancel list retires only the canceled sleeper" {
    // One cancel among eight armed sleepers must disarm exactly that node:
    // the dedicated cancel list replaces the scan of the whole armed
    // population, and the other seven keep sleeping.
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    var done: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    // Wait for all eight actual submissions, not a fixed sleep (#117).
    var submitted: std.atomic.Value(u32) = .init(0);
    shim.testTimeSubmitHook(interface, &submitted);
    for (0..7) |_| try group.concurrent(interface, longSleeperCounted, .{ interface, &done });
    var future = try Io.concurrent(interface, longSleeperCounted, .{ interface, &done });
    waitSubmitted(interface, &submitted, 8);
    shim.testTimeSubmitHook(interface, null);

    const t0 = try born.nowNs();
    try expectError(error.Canceled, future.cancel(interface));
    try expect(try elapsedNs(t0) < 2 * s);
    // The other seven are still armed: none was retired by the cancel.
    try expectEqual(@as(u32, 0), done.load(.acquire));
    group.cancel(interface);
    try expectEqual(@as(u32, 0), done.load(.acquire));
}

test "wakes fire only on empty-to-non-empty queue transitions" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    if (!born_io.time_stats_enabled) {
        // Default config: the sleep path performs no shared writes, and the
        // snapshot reports the documented zeros.
        try Io.sleep(interface, .fromMilliseconds(5), .awake);
        const z = born_io.timeStats(interface);
        try expectEqual(@as(u64, 0), z.ops);
        try expectEqual(@as(u64, 0), z.wakes);
        try expectEqual(@as(u64, 0), z.submit_wake_ns);
        try expectEqual(@as(u64, 0), z.queue_arm_ns);
        try expectEqual(@as(u64, 0), z.timer_span_ns);
        try expectEqual(@as(u64, 0), z.futex_return_ns);
        return;
    }

    // Sequential sleeps: the queue is empty at every submit, so each one
    // wakes exactly once.
    const before = born_io.timeStats(interface).wakes;
    for (0..3) |_| try Io.sleep(interface, .fromMilliseconds(5), .awake);
    try expectEqual(before + 3, born_io.timeStats(interface).wakes);

    // 64 concurrent submits: pushes onto a non-empty queue are covered by
    // the pending drain, so the wake count cannot exceed the submit count.
    const start = born_io.timeStats(interface).wakes;
    var done: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..64) |_| try group.concurrent(interface, sleeper, .{ interface, &done });
    try group.await(interface);
    const wakes = born_io.timeStats(interface).wakes - start;
    try expectEqual(@as(u32, 64), done.load(.acquire));
    try expect(wakes >= 1 and wakes <= 64);
}

test "loop death latches the wait failure and rejects later sleeps" {
    // kqueue only: closing the port's descriptor behind the shim makes every
    // wait fail; after wait_fail_limit consecutive failures the loop retires
    // everything and exits. The latch must expose the cause that sleep's
    // error set cannot carry.
    if (!@hasField(born.EvPort, "kq")) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);
    defer born_io.deinit(interface);

    try expectEqual(@as(?anyerror, null), born_io.loopError(interface));
    _ = std.c.close(port.kq);
    port.kq = -1;

    const t0 = try born.nowNs();
    try expectError(error.Canceled, Io.sleep(interface, .fromSeconds(10), .awake));
    try expect(try elapsedNs(t0) < 2 * s);
    try expect(born_io.loopError(interface) != null);
    // The queue is dead: later submits are rejected at the slot.
    try expectError(error.Canceled, Io.sleep(interface, .fromMilliseconds(5), .awake));
}

test "deinit stops the loop before Threaded and retires pending sleepers" {
    // Shutdown order regression: the loop calls into Threaded (mutex,
    // futexWake) until it exits, so it must be stopped and joined first.
    // retireAll cancels the pending 10 s sleeper, so deinit returns promptly
    // instead of waiting out the timer or touching a deinit'd Threaded. The
    // sleeper is a raw thread (no Threaded future to await): sleep composes
    // from any thread, as the no-workers test proves.
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initTimeIo(&port);

    // Wait on the sleeper's actual submission (#117, the #116 pattern). A
    // fixed sleep races thread startup under scheduler load: a sleeper whose
    // first call lands after deinit freed the Shim faults in the entry gate
    // itself, which no gate can guard. Once the count shows the submission,
    // the sleeper holds an entry-gate count, so deinit's drain waits for it.
    // Install before spawning so a fast submit cannot miss the bump.
    var submitted: std.atomic.Value(u32) = .init(0);
    shim.testTimeSubmitHook(interface, &submitted);
    var outcome: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(io: Io, out: *std.atomic.Value(u32)) void {
            Io.sleep(io, .fromSeconds(10), .awake) catch {
                out.store(1, .release);
                return;
            };
            out.store(2, .release);
        }
    }.run, .{ interface, &outcome });
    waitSubmitted(interface, &submitted, 1);
    shim.testTimeSubmitHook(interface, null);
    const t0 = try born.nowNs();
    born_io.deinit(interface);
    try expect(try elapsedNs(t0) < 2 * s);
    thread.join();
    try expectEqual(@as(u32, 1), outcome.load(.acquire));
}

test "InitError distinguishes loop spawn failure" {
    comptime {
        // The member must exist: a spawn failure is not an OutOfMemory.
        const e: born_io.InitError = error.LoopSpawnFailed;
        if (e != error.LoopSpawnFailed) @compileError("unreachable");
    }
}
