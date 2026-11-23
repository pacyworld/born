// Born-owned override of the vendored tests/all_tests.zig (upstream pin
// b8ffdd9), compiled in its place by generateE2eTree; the vendored original
// stays byte-identical for provenance and hash verification (same carry-in 4
// pattern as utils.zig and pending_msgs_test.zig). Difference from upstream:
// imports the born-owned born#133 deadline regression test
// (tests/deadline_133_test.zig, an e2e_extra with no vendored counterpart).
// All other imports and the lifecycle hooks are unchanged.

const std = @import("std");
const nats = @import("nats");
const utils = @import("utils.zig");

test {
    _ = @import("minimal_test.zig");
    _ = @import("auth_test.zig");
    // The TLS tests connect to real TLS servers; with TLS compiled out
    // they could only fail with TlsNotConfigured.
    if (@import("build_options").use_tls) {
        _ = @import("tls_test.zig");
    }
    _ = @import("headers_test.zig");
    _ = @import("subscribe_test.zig");
    _ = @import("autounsubscribe_test.zig");
    _ = @import("pending_msgs_test.zig");
    _ = @import("drain_test.zig");
    _ = @import("core_request_reply_test.zig");
    _ = @import("reconnection_test.zig");
    _ = @import("reconnect_limits_test.zig");
    _ = @import("keepalive_test.zig");
    _ = @import("callbacks_test.zig");
    _ = @import("drain_race_test.zig");
    _ = @import("jetstream_test.zig");
    _ = @import("deadline_133_test.zig");
    _ = @import("jetstream_stream_test.zig");
    _ = @import("jetstream_push_test.zig");
    _ = @import("jetstream_nak_test.zig");
    _ = @import("jetstream_sync_test.zig");
    _ = @import("jetstream_stream_purge_test.zig");
    _ = @import("jetstream_pull_test.zig");
    _ = @import("jetstream_get_msg_test.zig");
    _ = @import("jetstream_get_msg_direct_test.zig");
    _ = @import("jetstream_delete_msg_test.zig");
    _ = @import("jetstream_duplicate_ack_test.zig");
    _ = @import("jetstream_large_list_test.zig");
    _ = @import("jetstream_kv_simple_test.zig");
    _ = @import("jetstream_kv_test.zig");
    _ = @import("jetstream_kv_history_test.zig");
    _ = @import("jetstream_objstore_test.zig");
    _ = @import("jetstream_objstore_streaming_test.zig");
}

test "tests:beforeEach" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try utils.waitForHealthyServices(allocator, .fromSeconds(10));
}

test "tests:beforeAll" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try utils.runDockerCompose(allocator, &.{ "up", "-d" });
}

test "tests:afterAll" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try utils.runDockerCompose(allocator, &.{"down"});
}
