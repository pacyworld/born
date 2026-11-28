//! Loop-thread marker (internal). A Born-native loop driver, and the born.io
//! shim's Born route loop thread, mark the calling thread at start and clear
//! the mark at exit. A blocking I/O call on a Born loop thread stalls every
//! connection the loop services, so blocking shim thunks assert the marker in
//! Debug and ReleaseSafe; ReleaseFast elides the check. Not a stable API:
//! only `mark`, `unmark` and `isMarked` are usable, and the mark must be
//! cleared wherever the thread can be rejoined and reused.

threadlocal var marked: bool = false;

/// Mark the calling thread as a Born loop. Pair with `unmark` at thread exit.
pub fn mark() void {
    marked = true;
}

/// Unmark the calling thread. Pair with `mark` at thread entry.
pub fn unmark() void {
    marked = false;
}

/// Whether the calling thread is marked as a Born loop thread.
pub fn isMarked() bool {
    return marked;
}

test "loop_thread: mark is per-thread, unmark clears it" {
    const builtin = @import("builtin");
    const std = @import("std");
    if (builtin.single_threaded) return error.SkipZigTest;

    try std.testing.expect(!isMarked());

    const Probe = struct {
        fn run(seen: *bool) void {
            seen.* = isMarked();
        }
    };

    mark();
    try std.testing.expect(isMarked());

    // A fresh thread starts unmarked while this thread is marked.
    var seen: bool = true;
    const t = try std.Thread.spawn(.{}, Probe.run, .{&seen});
    t.join();
    try std.testing.expect(!seen);
    try std.testing.expect(isMarked());

    unmark();
    try std.testing.expect(!isMarked());
}
