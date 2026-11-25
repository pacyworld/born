//! Foundation tests for the born.io shim.
//!
//! These are semantic-analysis and composition-lifecycle tests for the
//! all-Threaded baseline. They validate the pinned interface shape, the
//! forwarding-thunk composition, and explicit capability rejection. A
//! Threaded-delegation run here is foundation evidence only; it is not evidence
//! that any operation runs on Born's reactor.

const std = @import("std");
const born = @import("born");
const born_io = @import("root.zig");
const shim = @import("shim.zig");
const assert = @import("assert.zig");

test "baseline vtable is a complete Io.VTable of forwarding thunks" {
    // Semantic analysis: force the whole explicit baseline and every thunk
    // signature to be analyzed against the selected toolchain's interface.
    comptime {
        assert.verify();
        if (@TypeOf(shim.baseline_vtable) != std.Io.VTable)
            @compileError("baseline_vtable is not an Io.VTable");
    }
    std.testing.refAllDecls(shim);
    try std.testing.expectEqual(assert.expected_count, assert.actualSlotCount());
}

test "io rejects an unimplemented Born route at construction" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();

    // No silent fallback: a Born route that is not implemented is a
    // construction error, not a delegation to Threaded. The network client
    // route and, on FreeBSD/Linux, the process route are implemented and
    // exercised in net_test.zig / process_test.zig; file remains rejected
    // everywhere, and process is rejected on targets without process
    // descriptors / pidfds. The time family always stays Threaded (#101).
    try std.testing.expectError(error.CapabilityUnsupported, born_io.io(&port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .file = .born_evented },
    }));
    if (!born_io.process_supported) {
        try std.testing.expectError(error.CapabilityUnsupported, born_io.io(&port, .{
            .allocator = std.testing.allocator,
            .capabilities = .{ .process = .born_evented },
        }));
    }
}

test "network Born route constructs with the network vtable and deinits" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();

    const interface = try born_io.io(&port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .network = .born_evented },
    });
    defer born_io.deinit(interface);
    try std.testing.expect(std.meta.eql(interface.vtable.*, born_io.network_vtable));
    // The time family stays on the baseline even with the network route live.
    try std.testing.expect(std.meta.eql(interface.vtable.sleep, born_io.baseline_vtable.sleep));
    try std.testing.expect(std.meta.eql(interface.vtable.now, born_io.baseline_vtable.now));
    try std.testing.expect(std.meta.eql(interface.vtable.clockResolution, born_io.baseline_vtable.clockResolution));
}

test "baseline io constructs, delegates to Threaded, and deinits" {
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();

    const interface = try born_io.io(&port, .{ .allocator = std.testing.allocator });
    defer born_io.deinit(interface);

    // The returned interface dispatches every slot through the explicit
    // baseline, carried by one userdata. Compare slot function pointers, not
    // the vtable address: comptime-known constants have no guaranteed unique
    // runtime address, so &baseline_vtable may materialize as distinct copies.
    try std.testing.expect(std.meta.eql(interface.vtable.*, born_io.baseline_vtable));
    try std.testing.expect(interface.userdata != null);

    // Foundation delegation through the forwarding thunks (Threaded, not Born).
    const t0 = std.Io.Timestamp.now(interface, .awake);
    try interface.vtable.sleep(interface.userdata, .{
        .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake },
    });
    const t1 = std.Io.Timestamp.now(interface, .awake);
    try std.testing.expect(t1.nanoseconds >= t0.nanoseconds);

    var buf: [8]u8 = undefined;
    interface.vtable.random(interface.userdata, &buf);
}

// ---- shared-machinery delegation (relocated from the retired time suite) ----
//
// These prove the non-Born slots keep delegating to Threaded while a Born
// route's loop thread is live. They run on the network route; the time family
// itself always stays Threaded (#101). The loop-death and deinit-ordering
// contracts are exercised through the network route in net_test.zig.

const Io = std.Io;

fn initNetIo(port: *born.EvPort) born_io.InitError!Io {
    return born_io.io(port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .network = .born_evented },
    });
}

fn addOne(x: u32) u32 {
    return x + 1;
}

test "network route keeps async and await on Threaded" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initNetIo(&port);
    defer born_io.deinit(interface);

    var future = Io.async(interface, addOne, .{@as(u32, 41)});
    try std.testing.expectEqual(@as(u32, 42), future.await(interface));
}

fn futexWaiter(io: Io, word: *std.atomic.Value(u32)) Io.Cancelable!void {
    while (word.load(.acquire) == 0) {
        try io.vtable.futexWait(io.userdata, &word.raw, 0, .none);
    }
}

test "network route keeps futex delegation with cross-thread wake" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initNetIo(&port);
    defer born_io.deinit(interface);

    var word: std.atomic.Value(u32) = .init(0);
    var future = try Io.concurrent(interface, futexWaiter, .{ interface, &word });
    // The main thread sleeps on Threaded while the worker waits on a Threaded
    // futex; the wake then comes from the main thread.
    try Io.sleep(interface, .fromMilliseconds(30), .awake);
    word.store(1, .release);
    interface.vtable.futexWake(interface.userdata, &word.raw, 1);
    try future.await(interface);
}

test "network route cancels a Threaded futex wait" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initNetIo(&port);
    defer born_io.deinit(interface);

    var word: std.atomic.Value(u32) = .init(0);
    var future = try Io.concurrent(interface, futexWaiter, .{ interface, &word });
    try Io.sleep(interface, .fromMilliseconds(30), .awake);
    try std.testing.expectError(error.Canceled, future.cancel(interface));
}

fn producer(io: Io, queue: *Io.Queue(u32)) (Io.Cancelable || error{Closed})!void {
    try queue.putAll(io, &.{7});
}

test "network route keeps queue delegation" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initNetIo(&port);
    defer born_io.deinit(interface);

    var buffer: [4]u32 = undefined;
    var queue: Io.Queue(u32) = .init(&buffer);
    var future = try Io.concurrent(interface, producer, .{ interface, &queue });
    var out: [1]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try queue.get(interface, &out, 1));
    try std.testing.expectEqual(@as(u32, 7), out[0]);
    try future.await(interface);
}

test "clampTimerNs clamps to the port ceiling without rounding" {
    const ms = std.time.ns_per_ms;
    try std.testing.expectEqual(@as(u64, 1), shim.clampTimerNs(1));
    try std.testing.expectEqual(@as(u64, 500_000), shim.clampTimerNs(500_000));
    try std.testing.expectEqual(@as(u64, 1 * ms), shim.clampTimerNs(1 * ms));
    try std.testing.expectEqual(born.timer_after_ns_max, shim.clampTimerNs(born.timer_after_ns_max));
    try std.testing.expectEqual(born.timer_after_ns_max, shim.clampTimerNs(born.timer_after_ns_max + 1));
    try std.testing.expectEqual(born.timer_after_ns_max, shim.clampTimerNs(std.math.maxInt(u64)));
}

test "InitError distinguishes loop spawn failure" {
    comptime {
        // The member must exist: a spawn failure is not an OutOfMemory.
        const e: born_io.InitError = error.LoopSpawnFailed;
        if (e != error.LoopSpawnFailed) @compileError("unreachable");
    }
}
