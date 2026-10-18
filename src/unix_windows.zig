//! Unix domain stream sockets on Windows (AF_UNIX, Windows 10 1803+).
//! Owned by born#21: this file, which implements `Listener.openUnix` (via
//! `listen`) and `PlainNb.startConnectUnixInto` (via `connectInto`). It
//! reuses the AcceptEx machinery from listener_windows.zig (#19). Older
//! Windows (WSAEAFNOSUPPORT) reports error.Unsupported.
//!
//! Stub until #21 lands (it may follow 0.3.0): both entry points return
//! error.Unsupported.

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

pub fn listen(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
    _ = alloc;
    _ = path;
    _ = opts;
    return io.ListenError.Unsupported;
}

pub fn connectInto(stream: *PlainNb, alloc: std.mem.Allocator, path: []const u8, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectUnixError!void {
    _ = stream;
    _ = alloc;
    _ = path;
    _ = evp;
    _ = key;
    return io.ConnectUnixError.Unsupported;
}
