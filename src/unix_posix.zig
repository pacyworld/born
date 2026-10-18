//! Unix domain stream sockets on POSIX. Owned by born#20: this file, which
//! implements `Listener.openUnix` (via `listen`) and
//! `PlainNb.startConnectUnixInto` (via `connectInto`).
//!
//! Rules #20 implements:
//!   - the path is checked against `sun_path` and refused with
//!     error.NameTooLong, never truncated;
//!   - `unlink_stale`: on EADDRINUSE, a connect probe that is refused means
//!     a stale file, unlinked once; a live listener is error.AddressInUse;
//!     a non-socket file is error.PathNotASocket;
//!   - `mode` is applied after bind and before listen, so no client can
//!     connect while the file has the wrong permissions;
//!   - accepted streams use the TCP listener's accept path (#18).
//!
//! Stub until #20 lands: both entry points return error.Unsupported.

const std = @import("std");
const evport = @import("root.zig");
const io = @import("io_types.zig");
const Listener = @import("listener_posix.zig").Listener;
const PlainNb = @import("socket_posix.zig").PlainNb;

/// Unix-only listener state, a field of Listener (`unix`).
pub const ListenerState = struct {
    /// Called by Listener.close before the fd closes.
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
