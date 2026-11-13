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

    // No silent fallback: a Born route that the baseline does not implement is
    // a construction error, not a delegation to Threaded.
    try std.testing.expectError(error.CapabilityUnsupported, born_io.io(&port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .time = .born_evented },
    }));
    try std.testing.expectError(error.CapabilityUnsupported, born_io.io(&port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .network = .born_evented },
    }));
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
