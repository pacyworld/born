//! Windows event port backed by I/O completion ports.
//!
//! IOCP reports completions rather than readiness. monitorRead associates a
//! handle with the port. wantWrite and cancelWrite are no-ops because the
//! stream layer posts overlapped sends and receives their completions.
//! purgeFd is also a no-op; the stream layer owns closesocket and CancelIoEx
//! teardown.
//!
//! Events carry the completion key, raw OVERLAPPED pointer, and byte count.
//! The owning connection in socket_windows.zig identifies the completed
//! operation by comparing OVERLAPPED addresses. wait harvests a batch in one
//! GetQueuedCompletionStatusEx call.
//!
//! Cross-thread wakeup uses PostQueuedCompletionStatus with the wake key.
//! Stdio relay threads for blocking pipes also post chunks with caller-chosen
//! keys. post is shared by relay threads and the owning thread; a failed post
//! is stashed atomically and returned as error.PostFailed from the next
//! non-empty wait, like a pending association failure.
//!
//! timer_iocp.zig's thread-pool timer and signal_windows.zig's console handler
//! only post completions keyed by internalKey, with a payload in the byte
//! count. wait hands those completions to the owning module's harvest function
//! on the event-loop thread.

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const types = @import("types.zig");
const timer_iocp = @import("timer_iocp.zig");
const signal_windows = @import("signal_windows.zig");

// Zig 0.15's OVERLAPPED_ENTRY declares lpOverlapped non-null, but posted
// completions may carry null. Keep the native layout with a nullable field.
const CompletionEntry = extern struct {
    lpCompletionKey: usize,
    lpOverlapped: ?*windows.OVERLAPPED,
    Internal: usize,
    dwNumberOfBytesTransferred: u32,
};

pub const Handle = types.Handle;
pub const Event = types.Event;
pub const Signal = types.Signal;
pub const TimerMode = types.TimerMode;

pub const InitError = error{InitFailed};
/// Failure to associate a handle with an I/O completion port.
pub const AssociateError = error{AssociateFailed};
/// AssociateFailed is a stashed monitorRead failure, PostFailed a stashed
/// post()/wake() failure, OutOfMemory an internal harvest that could not
/// allocate.
pub const WaitError = error{ WaitFailed, AssociateFailed, PostFailed, OutOfMemory };
pub const TimerError = types.TimerError;
pub const SignalError = types.SignalError;
pub const ProcessError = types.ProcessError;
/// Every error this backend can return.
pub const Error = InitError || AssociateError || WaitError || TimerError || SignalError || ProcessError;

/// Windows has no signal mask: a documented no-op; see signal_windows.zig.
pub const blockSignals = signal_windows.blockSignals;

/// Internal post kinds, each with its own completion key.
pub const InternalKind = enum { timer, signal };

/// Stable addresses used as internal completion keys, one per kind.
var internal_keys = [_]u8{0} ** std.meta.fields(InternalKind).len;

fn internalKind(key: usize) ?InternalKind {
    const base = @intFromPtr(&internal_keys);
    if (key < base or key >= base + internal_keys.len) return null;
    return @enumFromInt(key - base);
}

/// An I/O completion port and its timer and signal state.
///
/// The port must not move after its first `addTimer` call until `deinit`, or
/// while it watches a signal, because timer and console callbacks retain its
/// address.
pub const EvPort = struct {
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    /// Stashed association failure (owning thread via monitorRead only):
    /// returned once by the next non-empty wait().
    pending_error: ?WaitError = null,
    /// Timer bookkeeping, owned by timer_iocp.zig.
    timers: timer_iocp.State = .{},
    /// Signal-watch bookkeeping, owned by signal_windows.zig.
    signals: signal_windows.State = .{},
    /// Set by post or wake from any thread on a failed
    /// PostQueuedCompletionStatus; the next non-empty wait reports it once
    /// as error.PostFailed. Atomic because post may run from relay threads
    /// while the owning thread is inside wait.
    post_failed: std.atomic.Value(bool) = .init(false),

    /// Create an I/O completion port and initialize its helper state with `alloc`.
    pub fn init(alloc: std.mem.Allocator) InitError!EvPort {
        const port = kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse
            return InitError.InitFailed;
        return .{
            .iocp = port,
            .timers = timer_iocp.State.init(alloc),
            .signals = signal_windows.State.init(alloc),
        };
    }

    /// Stop helper callbacks, release their state, and close the port handle.
    pub fn deinit(self: *EvPort) void {
        // Helpers post() from other threads: stop them before the port
        // handle closes.
        self.signals.deinit(self);
        self.timers.deinit(self);
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

    /// Associate `handle` with the port and use `udata` as its completion key.
    pub fn associate(self: *EvPort, handle: Handle, udata: ?*anyopaque) AssociateError!void {
        if (handle == windows.INVALID_HANDLE_VALUE or self.iocp == windows.INVALID_HANDLE_VALUE)
            return AssociateError.AssociateFailed;
        const port = kernel32.CreateIoCompletionPort(handle, self.iocp, @intFromPtr(udata), 0) orelse
            return AssociateError.AssociateFailed;
        if (port != self.iocp) return AssociateError.AssociateFailed;
    }

    /// Writes are driven by the stream layer's overlapped sends; interest
    /// registration does not exist on IOCP.
    pub fn wantWrite(self: *EvPort, fd: Handle, udata: ?*anyopaque) void {
        _ = self;
        _ = fd;
        _ = udata;
    }

    /// No-op: overlapped writes have no interest registration to cancel.
    pub fn cancelWrite(self: *EvPort, fd: Handle) void {
        _ = self;
        _ = fd;
    }

    /// No-op: IOCP has no read-interest registration to remove.
    pub fn unmonitorRead(self: *EvPort, fd: Handle) void {
        _ = self;
        _ = fd;
    }

    /// No-op: the stream layer owns closesocket and CancelIoEx teardown.
    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        _ = self;
        _ = fd;
    }

    /// Wake a wait blocked in another thread. Callable from any thread.
    pub fn wake(self: *EvPort) void {
        self.post(&wake_sentinel, null, 0);
    }

    /// Post a completion with an arbitrary key. Stdio relay threads use their
    /// sentinel addresses, and `overlapped` may be null. Callable from any
    /// thread. A failed post is stashed atomically and returned as
    /// error.PostFailed by the next non-empty wait. When the failed post is
    /// itself a wake, nothing wakes the blocked wait, so the error reaches the
    /// consumer at the next naturally arriving completion.
    pub fn post(self: *EvPort, key: *anyopaque, overlapped: ?*windows.OVERLAPPED, bytes: usize) void {
        if (kernel32.PostQueuedCompletionStatus(self.iocp, @intCast(bytes), @intFromPtr(key), overlapped) == 0) {
            self.post_failed.store(true, .release);
        }
    }

    /// Return the completion key used to identify wake events.
    pub fn wakeKey() *anyopaque {
        return &wake_sentinel;
    }

    /// Internal hook: the completion key a helper thread posts for `kind`.
    /// The post's byte count carries the kind's payload.
    pub fn internalKey(kind: InternalKind) *anyopaque {
        return &internal_keys[@intFromEnum(kind)];
    }

    /// Arm a timer. `id` is caller-chosen and unique per port; re-adding a
    /// live id replaces it. Timers are deadlines, never I/O drivers.
    pub fn addTimer(self: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
        return timer_iocp.add(self, id, udata, after_ms, mode);
    }

    /// Disarm a timer. Unknown or already-expired ids are a no-op.
    pub fn cancelTimer(self: *EvPort, id: u32) void {
        timer_iocp.cancel(self, id);
    }

    /// Deliver `sig` as Event.signal. Process-wide: one port per signal.
    pub fn watchSignal(self: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
        return signal_windows.watch(self, sig, udata);
    }

    /// Stop watching `sig`. Unwatched signals are a no-op.
    pub fn unwatchSignal(self: *EvPort, sig: Signal) void {
        signal_windows.unwatch(self, sig);
    }

    /// Process watches are not implemented on IOCP.
    pub fn watchProcess(self: *EvPort, handle: Handle, udata: ?*anyopaque) ProcessError!void {
        _ = self;
        _ = handle;
        _ = udata;
        return ProcessError.Unsupported;
    }

    /// No-op because IOCP has no process watch to remove.
    pub fn unwatchProcess(self: *EvPort, handle: Handle) void {
        _ = self;
        _ = handle;
    }

    /// Harvest one batch of completions in one GetQueuedCompletionStatusEx
    /// call. `timeout_ms` must be null or nonnegative. null blocks until a
    /// completion, zero harvests without blocking, and positive values wait
    /// that many milliseconds. Internal posts go to their kind's harvest,
    /// which may emit several events or none, so wait can return zero before
    /// its timeout.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) WaitError!usize {
        if (events.len == 0) return 0;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        if (self.post_failed.swap(false, .acq_rel)) return WaitError.PostFailed;
        var entries: [64]CompletionEntry = undefined;
        const cap = @min(events.len, entries.len);
        var removed: u32 = 0;
        const ms: u32 = if (timeout_ms) |t| @intCast(@max(t, 0)) else 0xFFFFFFFF; // INFINITE
        const ok = kernel32.GetQueuedCompletionStatusEx(self.iocp, @ptrCast(&entries), @intCast(cap), &removed, ms, 0);
        if (ok == 0) {
            const err = windows.GetLastError();
            if (err == .WAIT_TIMEOUT) return 0;
            return WaitError.WaitFailed;
        }

        var out: usize = 0;
        for (entries[0..removed], 0..) |entry, i| {
            if (internalKind(entry.lpCompletionKey)) |kind| {
                // Leave one slot for every completion still to translate.
                const room = events[out..][0 .. events.len - out - (removed - i - 1)];
                const payload: usize = entry.dwNumberOfBytesTransferred;
                out += switch (kind) {
                    .timer => timer_iocp.harvest(self, payload, room),
                    .signal => signal_windows.harvest(self, payload, room),
                };
                continue;
            }
            events[out] = completionEvent(entry);
            out += 1;
        }
        return out;
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

test "iocp: failed post is stashed and returned by the next wait" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();

    // A working post first: success stashes nothing.
    var tag: u8 = 1;
    port.post(&tag, null, 7);
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    try std.testing.expectEqual(@as(usize, 7), events[0].bytes);

    // Invalidate the port: PostQueuedCompletionStatus now fails.
    const saved = port.iocp;
    port.iocp = windows.INVALID_HANDLE_VALUE;
    defer port.iocp = saved;

    // A relay thread lost its chunk. The port must say so at its next wait
    // instead of letting the loop wait on a completion that never arrives.
    // An empty wait preserves the stashed error, as elsewhere.
    port.post(&tag, null, 7);
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    try std.testing.expectError(Error.PostFailed, port.wait(&events, 0));
    // Reported once; a repeat post stashes it again.
    try std.testing.expect(!port.post_failed.load(.acquire));
    port.wake();
    try std.testing.expectError(Error.PostFailed, port.wait(&events, 0));
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

test "iocp: internal completion keys are distinct from wake and caller keys" {
    var tag: u8 = 1;
    try std.testing.expect(internalKind(@intFromPtr(&tag)) == null);
    try std.testing.expect(internalKind(@intFromPtr(EvPort.wakeKey())) == null);
    try std.testing.expect(internalKind(0) == null);
    inline for (std.meta.fields(InternalKind)) |field| {
        const kind: InternalKind = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?InternalKind, kind), internalKind(@intFromPtr(EvPort.internalKey(kind))));
        try std.testing.expect(EvPort.internalKey(kind) != EvPort.wakeKey());
    }
}
