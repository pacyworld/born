//! Unix domain stream socket entry points on Windows.
//!
//! `Listener.openUnix` and `PlainNb.startConnectUnixInto` currently return
//! `error.Unsupported`.

const std = @import("std");
const evport = @import("root.zig");
const io = @import("io_types.zig");
const Listener = @import("listener_windows.zig").Listener;
const PlainNb = @import("socket_windows.zig").PlainNb;

/// Unix-only listener state, a field of Listener (`unix`).
pub const ListenerState = struct {
    /// Called by Listener.close before the socket closes.
    pub fn deinit(self: *ListenerState) void {
        _ = self;
    }
};

/// Return `error.Unsupported` for every path and options.
pub fn listen(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
    _ = alloc;
    _ = path;
    _ = opts;
    return io.ListenError.Unsupported;
}

/// Return `error.Unsupported` without modifying `stream`.
pub fn connectInto(stream: *PlainNb, alloc: std.mem.Allocator, path: []const u8, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectUnixError!void {
    _ = stream;
    _ = alloc;
    _ = path;
    _ = evp;
    _ = key;
    return io.ConnectUnixError.Unsupported;
}
