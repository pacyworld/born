// Windows event port: IOCP backend (issue #7).
//
// Same contract as the kqueue/epoll backends, with the completion-model
// differences handled here:
//   - No readiness registration: monitorRead(fd, udata) ASSOCIATES the
//     handle (socket) with the port; wantWrite/cancelWrite are no-ops
//     (overlapped sends are posted by the stream layer and always
//     complete). purgeFd is a no-op (closesocket/CancelIoEx teardown is
//     the stream layer's job).
//   - Events carry the completion key (udata) plus the raw OVERLAPPED
//     pointer and byte count; the owning conn classifies which operation
//     completed by comparing OVERLAPPED addresses (nb_win.zig).
//   - wait() harvests a batch in ONE GetQueuedCompletionStatusEx call.
//   - Cross-thread wakeup: PostQueuedCompletionStatus with the wake key.
//   - stdio relay threads (libuv pattern for blocking pipes) post their
//     chunks here via PQCS with the caller-chosen key.

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

// Zig 0.15's OVERLAPPED_ENTRY declares lpOverlapped non-null, but posted
// completions may carry null. Keep the native layout with a nullable field.
const CompletionEntry = extern struct {
    lpCompletionKey: usize,
    lpOverlapped: ?*windows.OVERLAPPED,
    Internal: usize,
    dwNumberOfBytesTransferred: u32,
};

pub const Handle = @import("types.zig").Handle;
pub const Event = @import("types.zig").Event;

pub const Error = error{
    InitFailed,
    AssociateFailed,
    WaitFailed,
    OutOfMemory,
};

pub const EvPort = struct {
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    pending_error: ?Error = null,

    pub fn init(alloc: std.mem.Allocator) Error!EvPort {
        _ = alloc;
        const port = kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse
            return Error.InitFailed;
        return .{ .iocp = port };
    }

    pub fn deinit(self: *EvPort) void {
        if (self.iocp != windows.INVALID_HANDLE_VALUE) _ = windows.CloseHandle(self.iocp);
        self.iocp = windows.INVALID_HANDLE_VALUE;
    }

    /// Associate a handle with the port (sockets at conn start; the
    /// overlappable stdin pipe when present). No-op bookkeeping otherwise.
    pub fn monitorRead(self: *EvPort, handle: Handle, udata: ?*anyopaque) void {
        self.associate(handle, udata) catch |err| {
            self.pending_error = err;
        };
    }

    pub fn associate(self: *EvPort, handle: Handle, udata: ?*anyopaque) Error!void {
        if (handle == windows.INVALID_HANDLE_VALUE or self.iocp == windows.INVALID_HANDLE_VALUE)
            return Error.AssociateFailed;
        const port = kernel32.CreateIoCompletionPort(handle, self.iocp, @intFromPtr(udata), 0) orelse
            return Error.AssociateFailed;
        if (port != self.iocp) return Error.AssociateFailed;
    }

    /// Writes are driven by the stream layer's overlapped sends; interest
    /// registration does not exist on IOCP.
    pub fn wantWrite(self: *EvPort, fd: Handle, udata: ?*anyopaque) void {
        _ = self;
        _ = fd;
        _ = udata;
    }

    pub fn cancelWrite(self: *EvPort, fd: Handle) void {
        _ = self;
        _ = fd;
    }

    pub fn unmonitorRead(self: *EvPort, fd: Handle) void {
        _ = self;
        _ = fd;
    }

    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        _ = self;
        _ = fd;
    }

    /// Wake a wait() blocked anywhere (relay threads, future helpers).
    pub fn wake(self: *EvPort) void {
        self.post(&wake_sentinel, null, 0);
    }

    /// Post a completion with an arbitrary key (stdio relay threads use
    /// their sentinel addresses; overlapped may be null).
    pub fn post(self: *EvPort, key: *anyopaque, overlapped: ?*windows.OVERLAPPED, bytes: usize) void {
        _ = kernel32.PostQueuedCompletionStatus(self.iocp, @intCast(bytes), @intFromPtr(key), overlapped);
    }

    pub fn wakeKey() *anyopaque {
        return &wake_sentinel;
    }

    /// Harvest one batch of completions in ONE GetQueuedCompletionStatusEx
    /// call. timeout_ms: null = block until a completion; 0 = don't block.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) Error!usize {
        if (events.len == 0) return 0;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        var entries: [64]CompletionEntry = undefined;
        const cap = @min(events.len, entries.len);
        var removed: u32 = 0;
        const ms: u32 = if (timeout_ms) |t| @intCast(@max(t, 0)) else 0xFFFFFFFF; // INFINITE
        const ok = kernel32.GetQueuedCompletionStatusEx(self.iocp, @ptrCast(&entries), @intCast(cap), &removed, ms, 0);
        if (ok == 0) {
            const err = windows.GetLastError();
            if (err == .WAIT_TIMEOUT) return 0;
            return Error.WaitFailed;
        }

        for (entries[0..removed], 0..) |entry, i| {
            events[i] = completionEvent(entry);
        }
        return removed;
    }
};

fn completionEvent(entry: CompletionEntry) Event {
    const key: ?*anyopaque = @ptrFromInt(entry.lpCompletionKey);
    if (key == @as(?*anyopaque, &wake_sentinel)) return .{ .wake = true };
    const internal = if (entry.lpOverlapped != null) entry.Internal else 0;
    return .{
        .udata = key,
        .overlapped = entry.lpOverlapped,
        .bytes = entry.dwNumberOfBytesTransferred,
        .err = internal != 0,
        .err_no = internal,
    };
}

/// Stable address used as the wake key.
var wake_sentinel: u8 = 0;

test "iocp: association failure is immediate or deferred without consuming completions" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    try std.testing.expectError(Error.AssociateFailed, port.associate(windows.INVALID_HANDLE_VALUE, null));
    try std.testing.expectError(Error.AssociateFailed, port.associate(port.iocp, null));
    port.monitorRead(port.iocp, null);
    port.wake();
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    var events: [1]Event = undefined;
    try std.testing.expectError(Error.AssociateFailed, port.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].wake);
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "iocp: empty wait preserves raw posted completions" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    port.post(&tag, null, 7);
    port.post(&tag, &overlapped, 11);
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    var events: [1]Event = undefined;
    for ([_]usize{ 7, 11 }, 0..) |bytes, i| {
        try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
        try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
        try std.testing.expectEqual(bytes, events[0].bytes);
        try std.testing.expect(events[0].overlapped == (if (i == 0) @as(?*windows.OVERLAPPED, null) else &overlapped));
        try std.testing.expect(!events[0].err);
        try std.testing.expect(!events[0].wake);
        try std.testing.expectEqual(@as(usize, 0), events[0].err_no);
    }
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "iocp: nullable completion entry matches native ABI" {
    try std.testing.expectEqual(@sizeOf(windows.OVERLAPPED_ENTRY), @sizeOf(CompletionEntry));
    try std.testing.expectEqual(@alignOf(windows.OVERLAPPED_ENTRY), @alignOf(CompletionEntry));
    inline for (.{ "lpCompletionKey", "lpOverlapped", "Internal", "dwNumberOfBytesTransferred" }) |name| {
        try std.testing.expectEqual(@offsetOf(windows.OVERLAPPED_ENTRY, name), @offsetOf(CompletionEntry, name));
    }
}

test "iocp: completion status is raw while relay and wake sentinels have no error" {
    var tag: u8 = 1;
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    var entry = CompletionEntry{
        .lpCompletionKey = @intFromPtr(&tag),
        .lpOverlapped = &overlapped,
        .Internal = 0xC0000120,
        .dwNumberOfBytesTransferred = 3,
    };
    const failed = completionEvent(entry);
    try std.testing.expect(failed.err);
    try std.testing.expectEqual(@as(usize, 0xC0000120), failed.err_no);
    try std.testing.expect(failed.udata == @as(?*anyopaque, &tag));
    try std.testing.expect(failed.overlapped == &overlapped);
    try std.testing.expectEqual(@as(usize, 3), failed.bytes);
    try std.testing.expect(!failed.readable and !failed.writable and !failed.eof and !failed.wake);
    entry.Internal = 0;
    const success = completionEvent(entry);
    try std.testing.expect(!success.err);
    try std.testing.expectEqual(@as(usize, 0), success.err_no);
    entry.Internal = 0xC0000120;
    entry.lpOverlapped = null;
    const relay = completionEvent(entry);
    try std.testing.expect(!relay.err);
    try std.testing.expectEqual(@as(usize, 0), relay.err_no);
    try std.testing.expectEqual(@as(usize, 3), relay.bytes);
    try std.testing.expect(relay.udata == @as(?*anyopaque, &tag));
    try std.testing.expect(relay.overlapped == null);
    entry.lpCompletionKey = @intFromPtr(EvPort.wakeKey());
    entry.lpOverlapped = &overlapped;
    const wake_event = completionEvent(entry);
    try std.testing.expect(wake_event.wake);
    try std.testing.expect(!wake_event.err);
    try std.testing.expectEqual(@as(usize, 0), wake_event.err_no);
    try std.testing.expectEqual(@as(usize, 0), wake_event.bytes);
    try std.testing.expect(wake_event.udata == null and wake_event.overlapped == null);
}
