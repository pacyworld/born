const std = @import("std");
const builtin = @import("builtin");

pub const Handle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;

pub const Event = struct {
    udata: ?*anyopaque = null,
    readable: bool = false, // unused on IOCP (the conn classifies)
    writable: bool = false, // unused on IOCP
    eof: bool = false,
    err: bool = false,
    /// EV_ERROR payload (errno) when err is set on kqueue.
    err_no: usize = 0, // NTSTATUS from the completion's Internal field on IOCP
    wake: bool = false,
    /// Which operation completed (conn classifies by address). Null when
    /// the completion carries no op (relay posts), or on POSIX.
    overlapped: ?*std.os.windows.OVERLAPPED = null,
    bytes: usize = 0,
};
