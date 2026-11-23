// Born-owned born#133 regression test (no vendored counterpart; added to the
// generated e2e tree by generateE2eTree and imported by the born-owned
// all_tests.zig override).
//
// The born-side patch checks io_util.expired at the top of publishMsgInternal's
// NoResponders branch, before the retries_left guard, so an expired overall
// request deadline always ends the retries with Timeout, never NoStreamResponse.
//
// Determinism: the asserted invariant (expired deadline => Timeout) holds on
// every iteration with the patch. Unpatched, the failure is a load-dependent
// race no public-API test can force deterministically: waitForResponse and the
// retry loop's post-sleep check both already return Timeout on the common paths,
// leaving only a narrow expiry window. See PR #135 for the captured unpatched
// failure and the patched clean runs.

const std = @import("std");
const testing = std.testing;
const nats = @import("nats");
const utils = @import("utils.zig");

test "JetStream publish: an expired request deadline yields Timeout, not NoStreamResponse (#133)" {
    const io = std.testing.io;

    const conn = try utils.createDefaultConnection(io);
    defer utils.closeConnection(conn);

    var js = conn.jetstream(.{
        .request_timeout = .{ .duration = .{ .raw = .fromMilliseconds(25), .clock = .awake } },
    });

    const stream_name = try utils.generateUniqueStreamName(testing.allocator);
    defer testing.allocator.free(stream_name);
    const subject = try std.fmt.allocPrint(testing.allocator, "{s}.missing", .{stream_name});
    defer testing.allocator.free(subject);

    // retry_wait exceeds the overall deadline, so the retry sleep is clipped to
    // the remaining deadline and consumes it; retries_left reaches 0 on the
    // first NoResponders. Once the deadline expires, every subsequent
    // NoResponders must surface Timeout, never NoStreamResponse. Repeat to
    // exercise the expiry window across many attempts.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const start = std.Io.Timestamp.now(io, .awake);
        try testing.expectError(error.Timeout, js.publish(subject, "timeout", .{
            .retry_wait = .fromSeconds(2),
            .retry_attempts = 1,
        }));
        const elapsed = start.untilNow(io, .awake);
        // The retry wait is clipped to the overall deadline, not added to it.
        try testing.expect(elapsed.nanoseconds < std.time.ns_per_s);
    }
}
