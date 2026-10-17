//! Timer contract (born 0.3.0). Every test calls the real API and skips
//! while the backend returns error.Unsupported; a timer implementation
//! issue is done when these run and pass on its OS.

const std = @import("std");
const born = @import("root.zig");
const Event = born.Event;
const alloc = std.testing.allocator;

fn addOrSkip(port: *born.EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: born.TimerMode) !void {
    port.addTimer(id, udata, after_ms, mode) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

const Seen = struct { udata: ?*anyopaque, fired: u32, batch: usize };

/// Timer events harvested within `window_ms`, stopping early once `stop`
/// have arrived. Each records which wait() batch delivered it.
fn collect(port: *born.EvPort, seen: *std.ArrayList(Seen), window_ms: u64, stop: usize, buf_len: usize) !void {
    var buf: [16]Event = undefined;
    const events = buf[0..buf_len];
    var timer = try std.time.Timer.start();
    var batch: usize = 0;
    while (seen.items.len < stop) {
        const elapsed = timer.read() / std.time.ns_per_ms;
        if (elapsed >= window_ms) break;
        const n = try port.wait(events, @intCast(window_ms - elapsed));
        for (events[0..n]) |ev| {
            if (ev.wake) continue;
            try std.testing.expect(ev.timer);
            try std.testing.expect(ev.signal == null);
            try std.testing.expect(!ev.readable and !ev.writable and !ev.err);
            try std.testing.expect(ev.fired >= 1);
            try seen.append(alloc, .{ .udata = ev.udata, .fired = ev.fired, .batch = batch });
        }
        if (n != 0) batch += 1;
    }
}

test "timer: one-shot fires exactly once" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    try addOrSkip(&port, 1, &a, 20, .once);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 1000, 1, 16);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].udata == @as(?*anyopaque, &a));
    try std.testing.expectEqual(@as(u32, 1), seen.items[0].fired);
    try collect(&port, &seen, 100, std.math.maxInt(usize), 16);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
}

test "timer: repeat fires again until cancelled" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    try addOrSkip(&port, 2, &a, 10, .repeat);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 2000, 3, 16);
    var fired: u32 = 0;
    for (seen.items) |s| {
        try std.testing.expect(s.udata == @as(?*anyopaque, &a));
        fired += s.fired;
    }
    try std.testing.expect(fired >= 3);
    port.cancelTimer(2);
    seen.clearRetainingCapacity();
    try collect(&port, &seen, 60, std.math.maxInt(usize), 16);
    try std.testing.expectEqual(@as(usize, 0), seen.items.len);
}

test "timer: cancel before expiry delivers nothing" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    try addOrSkip(&port, 3, &a, 30, .once);
    port.cancelTimer(3);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 150, std.math.maxInt(usize), 16);
    try std.testing.expectEqual(@as(usize, 0), seen.items.len);
}

test "timer: a cancelled id is reusable" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    var b: u8 = 0;
    try addOrSkip(&port, 4, &a, 1000, .once);
    port.cancelTimer(4);
    try port.addTimer(4, &b, 10, .once);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 1000, 1, 16);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].udata == @as(?*anyopaque, &b));
    port.cancelTimer(4);
}

test "timer: re-adding a live id replaces it" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    var b: u8 = 0;
    try addOrSkip(&port, 5, &a, 30, .once);
    try port.addTimer(5, &b, 60, .once);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 300, std.math.maxInt(usize), 16);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].udata == @as(?*anyopaque, &b));
}

test "timer: cancelling an unknown or expired id is a no-op" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    try addOrSkip(&port, 6, &a, 5, .once);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 1000, 1, 16);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    // Neither may surface later as an error event or a wait() error.
    port.cancelTimer(6);
    port.cancelTimer(999);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 20));
}

test "timer: deadlines are delivered in order across waits" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const count = 12;
    var tags: [count]u8 = undefined;
    // Added in reverse so insertion order cannot pass for deadline order.
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        try addOrSkip(&port, @intCast(100 + i), &tags[i], @intCast(10 + 15 * i), .once);
    }
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 3000, count, 16);
    try std.testing.expectEqual(@as(usize, count), seen.items.len);
    // Within one batch order is free; across batches every deadline in a
    // later batch is no earlier than every deadline in an earlier one.
    var delivered = [_]bool{false} ** count;
    var earlier_max: usize = 0;
    var batch_max: usize = 0;
    var batch: usize = 0;
    for (seen.items) |s| {
        const idx = (@intFromPtr(s.udata.?) - @intFromPtr(&tags[0]));
        try std.testing.expect(idx < count and !delivered[idx]);
        delivered[idx] = true;
        if (s.batch != batch) {
            batch = s.batch;
            earlier_max = @max(earlier_max, batch_max);
            batch_max = 0;
        }
        try std.testing.expect(idx >= earlier_max);
        batch_max = @max(batch_max, idx);
    }
}

test "timer: expirations beyond the event buffer wait for the next wait()" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const count = 8;
    var tags: [count]u8 = undefined;
    for (&tags, 0..) |*tag, i| try addOrSkip(&port, @intCast(200 + i), tag, 5, .once);
    // Let every timer fall due before the first harvest.
    std.Thread.sleep(40 * std.time.ns_per_ms);
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 2000, count, 3);
    try std.testing.expectEqual(@as(usize, count), seen.items.len);
    var delivered = [_]bool{false} ** count;
    for (seen.items) |s| {
        const idx = @intFromPtr(s.udata.?) - @intFromPtr(&tags[0]);
        try std.testing.expect(idx < count and !delivered[idx]);
        delivered[idx] = true;
    }
}

test "timer: zero delays" {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var a: u8 = 0;
    // A zero one-shot is due at the next wait(); a zero period is refused.
    try addOrSkip(&port, 7, &a, 0, .once);
    try std.testing.expectError(error.InvalidArgument, port.addTimer(8, &a, 0, .repeat));
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(alloc);
    try collect(&port, &seen, 500, 1, 16);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expect(seen.items[0].udata == @as(?*anyopaque, &a));
}
