const std = @import("std");
const born = @import("born");

// A consumer is free to use std.Io in its own sources. born's isolation gate
// scans only born's core, so this reference must not fail the consumer build.
pub fn main() !void {
    const limit = std.Io.Limit.limited(4096);
    std.debug.assert(limit != .nothing);

    var port = try born.EvPort.init(std.heap.page_allocator);
    defer port.deinit();
}
