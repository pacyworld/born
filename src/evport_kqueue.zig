//! BSD and macOS event port backed by kqueue.
//!
//! Descriptor interest changes use a staged changelist. The next wait submits
//! the accumulated `Kevent` values and the eventlist in one kevent call.
//! A kernel-rejected change is returned as an error event. An allocation
//! failure never reaches the kernel, so it is stashed and returned as
//! error.OutOfMemory from the next non-empty wait instead of being silently
//! dropped.
//!
//! Read interest uses EV_CLEAR and is edge-triggered. Read handlers must fully
//! drain buffered data: plain reads continue to EAGAIN, and TLS reads continue
//! to WANT_READ, which implies the socket reached EAGAIN. Write interest uses
//! EV_ONESHOT for connect completion and buffer-space events; the connection
//! re-arms it on demand.
//!
//! Cross-thread wakeup uses EVFILT_USER on FreeBSD and macOS. Initialization
//! registers the wake knote immediately so a wake from another thread before
//! the first wait is not lost. wake triggers it with NOTE_TRIGGER through a
//! kevent call with no eventlist; triggers coalesce into one event. NetBSD and
//! OpenBSD use a nonblocking pipe instead: wake writes one byte and wait drains
//! the pipe to one event. EVFILT_SIGNAL is not a wake channel.
//!
//! Closing a descriptor removes its live filters. At the end-of-batch reap
//! point, callers use purgeFd before close so staged entries cannot apply to
//! a recycled descriptor number.
//!
//! Timers register through stageRaw like other staged changes. Signal watch
//! and unwatch operations apply their changes immediately so no delivery is
//! lost while the signal disposition changes. wait translates timer and signal
//! kevents into Event.timer, Event.signal, and Event.fired after each owning
//! module's observe hook has seen the kevent.
//!
//! FreeBSD process watches use EVFILT_PROCDESC, staged like descriptor changes
//! and translated into Event.exited and Event.exit. purgeFd removes their
//! staged changes too. Other kqueue targets report error.Unsupported.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const types = @import("types.zig");
const timer_kqueue = @import("timer_kqueue.zig");
const signal_kqueue = @import("signal_kqueue.zig");
const process_kqueue = @import("process_kqueue.zig");

// Use the target's struct kevent: FreeBSD 12+ needs its extended 64-byte
// layout (ext[4]), while NetBSD has wider filter/flags fields. A wrong
// stride corrupts multi-entry changelists and event buffers.
pub const Kevent = compat.Kevent;
const EVFILT_READ = std.c.EVFILT.READ;
const EVFILT_WRITE = std.c.EVFILT.WRITE;
pub const EVFILT_TIMER = std.c.EVFILT.TIMER;
pub const EVFILT_SIGNAL = std.c.EVFILT.SIGNAL;

/// EVFILT_USER exists on FreeBSD and macOS only.
const have_user = switch (builtin.os.tag) {
    .freebsd, .macos, .ios, .tvos, .watchos, .visionos => true,
    else => false,
};
const EVFILT_USER = if (have_user) std.c.EVFILT.USER else 0;
/// sys/event.h NOTE_TRIGGER, the same value on FreeBSD and macOS.
const NOTE_TRIGGER: u32 = 0x01000000;
/// The wake knote's ident (EVFILT_USER idents are free-form).
const wake_ident: usize = 0;

const EV_ADD = std.c.EV.ADD;
const EV_DELETE = std.c.EV.DELETE;
const EV_ONESHOT = std.c.EV.ONESHOT;
const EV_CLEAR = std.c.EV.CLEAR;
// Zig 0.15 omits EOF on FreeBSD/NetBSD and ERROR on NetBSD (sys/event.h).
const EV_EOF = if (@hasDecl(std.c.EV, "EOF")) std.c.EV.EOF else 0x8000;
const EV_ERROR = if (@hasDecl(std.c.EV, "ERROR")) std.c.EV.ERROR else 0x4000;

// NetBSD's 40-byte kevent ABI uses __kevent50 and size_t counts; Zig 0.15's
// unversioned std.c.kevent declaration instead uses int counts.
const netbsd = struct {
    extern "c" fn __kevent50(
        kq: c_int,
        changelist: [*]const Kevent,
        nchanges: usize,
        eventlist: [*]Kevent,
        nevents: usize,
        timeout: ?*const std.c.timespec,
    ) c_int;
};

// Target-native pipe flags; compat.pipe2 uses pipe + fcntl on macOS.
const PIPE2_FLAGS: compat.O = .{ .NONBLOCK = true, .CLOEXEC = true };

pub const Handle = types.Handle;
pub const Event = types.Event;
pub const Signal = types.Signal;
pub const TimerMode = types.TimerMode;

/// OutOfMemory: the wake-pipe registration could not be staged during init.
pub const InitError = error{ KqueueFailed, PipeFailed, OutOfMemory };
/// A stashed allocation failure is reported as OutOfMemory; kernel
/// rejections of staged changes arrive as Event.err instead.
pub const WaitError = error{ WaitFailed, OutOfMemory };
pub const TimerError = types.TimerError;
pub const SignalError = types.SignalError;
/// Errors returned by process-watch operations.
pub const ProcessError = types.ProcessError;
/// Every error this backend can return.
pub const Error = InitError || WaitError || TimerError || SignalError || ProcessError;

/// No-op on kqueue: watched signals are recorded by EVFILT_SIGNAL without
/// being blocked in the calling thread. Portable callers invoke this before
/// spawning threads because epoll requires blocked signals.
pub const blockSignals = signal_kqueue.blockSignals;

/// Stable address used as the wake source's udata tag (module-level so a
/// by-value EvPort return never leaves it dangling).
var wake_sentinel: u8 = 0;

/// A kqueue event port with staged descriptor, timer, and signal registrations.
pub const EvPort = struct {
    kq: c_int = -1,
    alloc: std.mem.Allocator,
    /// Staged changelist, flushed by the next wait().
    changes: std.ArrayList(Kevent) = .empty,
    /// Wake pipe ends; -1 where EVFILT_USER does the waking.
    wake_r: c_int = -1,
    wake_w: c_int = -1,
    /// Set by a wake() whose trigger the kernel refused; the next
    /// non-empty wait() reports it as WaitFailed. EVFILT_USER targets only.
    wake_failed: std.atomic.Value(bool) = .init(false),
    /// fds with write interest currently registered (staged or live).
    /// Deduplicates wantWrite/cancelWrite across the one-shot lifecycle:
    /// delivery clears the bit, so a blocked writer re-arms exactly once.
    armed_write: std.AutoHashMapUnmanaged(c_int, void) = .empty,
    /// Stashed registration failure (the IOCP backend's shape): an
    /// allocation failure in monitor*/want*/cancel*/unmonitor* is returned
    /// by the next non-empty wait() instead of silently dropping the change.
    pending_error: ?WaitError = null,
    /// Timer bookkeeping, owned by timer_kqueue.zig.
    timers: timer_kqueue.State = .{},
    /// Signal-watch bookkeeping, owned by signal_kqueue.zig.
    signals: signal_kqueue.State = .{},
    /// Process-watch bookkeeping, owned by process_kqueue.zig.
    processes: process_kqueue.State = .{},

    /// Create a kqueue and its wake source, using `alloc` for port bookkeeping.
    /// The wake registration is part of init: if it fails, init fails with
    /// everything released instead of returning a port without a wake source.
    pub fn init(alloc: std.mem.Allocator) InitError!EvPort {
        const kq = compat.kqueue() catch return InitError.KqueueFailed;
        errdefer compat.close(kq);

        var fds = [2]c_int{ -1, -1 };
        if (have_user) {
            var kev = change(wake_ident, EVFILT_USER, EV_ADD | EV_CLEAR, &wake_sentinel);
            kevent1(kq, &kev) catch return InitError.KqueueFailed;
        } else {
            fds = compat.pipe2(PIPE2_FLAGS) catch return InitError.PipeFailed;
        }
        errdefer if (!have_user) {
            compat.close(fds[0]);
            compat.close(fds[1]);
        };

        var self = EvPort{
            .kq = kq,
            .alloc = alloc,
            .wake_r = fds[0],
            .wake_w = fds[1],
            .timers = timer_kqueue.State.init(alloc),
            .signals = signal_kqueue.State.init(alloc),
        };
        if (!have_user) {
            self.monitorRead(self.wake_r, @as(?*anyopaque, &wake_sentinel));
            if (self.pending_error != null) {
                // The wake pipe is unmonitored: a port without reliable
                // cross-thread wakeup must not escape init. Free the
                // bookkeeping; the errdefers close the kqueue and pipe ends.
                self.changes.deinit(alloc);
                return InitError.OutOfMemory;
            }
        }
        return self;
    }

    /// Apply one change immediately (one-time setup and the wake trigger;
    /// everything else is staged for wait()). No eventlist, so a rejected
    /// entry is the call's errno.
    fn kevent1(kq: c_int, kev: *Kevent) error{KeventFailed}!void {
        while (true) {
            const rc = std.c.kevent(kq, @ptrCast(kev), 1, @ptrCast(kev), 0, null);
            if (rc >= 0) return;
            switch (std.posix.errno(@as(isize, rc))) {
                .INTR => continue,
                else => return error.KeventFailed,
            }
        }
    }

    /// Restore signal state and release port-owned descriptors and bookkeeping.
    /// Caller-owned `Child.handle` values stay open, and child lifetime and
    /// final reaping remain the caller's responsibility.
    pub fn deinit(self: *EvPort) void {
        // Signal dispositions are process-wide: restore them while the
        // port can still describe what it changed.
        self.signals.deinit(self);
        self.timers.deinit(self);
        self.processes.deinit(self);
        if (self.kq >= 0) compat.close(self.kq);
        if (self.wake_r >= 0) compat.close(self.wake_r);
        if (self.wake_w >= 0) compat.close(self.wake_w);
        self.kq = -1;
        self.wake_r = -1;
        self.wake_w = -1;
        self.changes.deinit(self.alloc);
        self.armed_write.deinit(self.alloc);
    }

    /// Persistent edge-triggered read interest (EV_ADD | EV_CLEAR).
    pub fn monitorRead(self: *EvPort, fd: Handle, udata: ?*anyopaque) void {
        self.stage(change(fd, EVFILT_READ, EV_ADD | EV_CLEAR, udata));
    }

    /// One-shot write interest (EV_ADD | EV_ONESHOT): connect completion or
    /// send-buffer space after a short write. No-op while already armed.
    pub fn wantWrite(self: *EvPort, fd: Handle, udata: ?*anyopaque) void {
        if (self.armed_write.contains(fd)) return;
        // Reserve both collections before mutating either, then commit with
        // infallible operations. A failed reservation leaves the armed bit
        // clear and nothing staged, so a retry re-arms cleanly.
        self.armed_write.ensureUnusedCapacity(self.alloc, 1) catch {
            self.pending_error = WaitError.OutOfMemory;
            return;
        };
        self.changes.ensureUnusedCapacity(self.alloc, 1) catch {
            self.pending_error = WaitError.OutOfMemory;
            return;
        };
        self.armed_write.putAssumeCapacity(fd, {});
        self.changes.appendAssumeCapacity(change(fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, udata));
    }

    /// Drop write interest on an fd that STAYS OPEN (flow control only).
    pub fn cancelWrite(self: *EvPort, fd: Handle) void {
        if (!self.armed_write.remove(fd)) return;
        self.stage(change(fd, EVFILT_WRITE, EV_DELETE, null));
    }

    /// Drop read interest on an fd that STAYS OPEN (e.g. stdin after EOF).
    pub fn unmonitorRead(self: *EvPort, fd: Handle) void {
        self.stage(change(fd, EVFILT_READ, EV_DELETE, null));
    }

    /// Drop STAGED (unflushed) changelist entries for an fd about to be
    /// closed, plus its armed-write bit. close(2) itself removes the fd's
    /// live filters; this prevents staged entries from applying to a
    /// recycled fd number at the next wait() flush.
    /// Only descriptor filters match: a staged timer or signal whose ident
    /// equals the fd number is not the fd's. A process descriptor's watch
    /// ends here too.
    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        _ = self.armed_write.remove(fd);
        process_kqueue.purge(self, fd);
        const ident: usize = @intCast(fd);
        var i: usize = 0;
        while (i < self.changes.items.len) {
            const kev = self.changes.items[i];
            if (kev.ident == ident and isFdFilter(kev.filter)) {
                _ = self.changes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn isFdFilter(filter: @FieldType(Kevent, "filter")) bool {
        if (filter == EVFILT_READ or filter == EVFILT_WRITE) return true;
        return process_kqueue.have_procdesc and filter == process_kqueue.EVFILT_PROCDESC;
    }

    /// Wake a wait() blocked in another thread. Non-blocking; wakes that
    /// land before the loop runs coalesce into one event. EVFILT_USER: a
    /// refused trigger is reported by the next non-empty wait().
    pub fn wake(self: *EvPort) void {
        if (have_user) {
            var kev = change(wake_ident, EVFILT_USER, 0, &wake_sentinel);
            kev.fflags = NOTE_TRIGGER;
            kevent1(self.kq, &kev) catch self.wake_failed.store(true, .release);
        } else {
            const b = [1]u8{1};
            _ = std.c.write(self.wake_w, &b, 1);
        }
    }

    fn change(fd: Handle, filter: @FieldType(Kevent, "filter"), flags: @FieldType(Kevent, "flags"), udata: ?*anyopaque) Kevent {
        var kev = std.mem.zeroes(Kevent);
        kev.ident = @intCast(fd);
        kev.filter = filter;
        kev.flags = flags;
        kev.udata = @intFromPtr(udata);
        return kev;
    }

    /// Arm a timer. `id` is caller-chosen and unique per port; re-adding a
    /// live id replaces it. Timers are deadlines, never I/O drivers.
    pub fn addTimer(self: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
        return timer_kqueue.add(self, id, udata, after_ms, mode);
    }

    /// Disarm a timer. Unknown or already-expired ids are a no-op.
    pub fn cancelTimer(self: *EvPort, id: u32) void {
        timer_kqueue.cancel(self, id);
    }

    /// Deliver `sig` as Event.signal. Process-wide: one port per signal.
    pub fn watchSignal(self: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
        return signal_kqueue.watch(self, sig, udata);
    }

    /// Stop watching `sig` and restore its prior disposition. Unwatched
    /// signals are a no-op.
    pub fn unwatchSignal(self: *EvPort, sig: Signal) void {
        signal_kqueue.unwatch(self, sig);
    }

    /// Deliver one exit event for the child behind `handle`, a FreeBSD process
    /// descriptor, staged into the next non-empty `wait()`. Invalid negative
    /// handles and allocation failures are immediate call errors; ordinary
    /// kernel refusals arrive as `Event.err` with native `err_no`, `exited=false`,
    /// and `exit=null`. Exit delivery ends the watch but does not reap the child.
    pub fn watchProcess(self: *EvPort, handle: Handle, udata: ?*anyopaque) ProcessError!void {
        return process_kqueue.watch(self, handle, udata);
    }

    /// End a process watch on a descriptor that stays open. Unwatched
    /// handles are a no-op; before closing, `purgeFd` is enough.
    pub fn unwatchProcess(self: *EvPort, handle: Handle) void {
        process_kqueue.unwatch(self, handle);
    }

    /// Internal hook for timer_kqueue.zig and signal_kqueue.zig: stage an
    /// arbitrary change for the next wait(). Never call kevent() to
    /// register; an allocation failure is stashed like any other stage.
    pub fn stageRaw(self: *EvPort, kev: Kevent) void {
        self.stage(kev);
    }

    fn stage(self: *EvPort, kev: Kevent) void {
        self.changes.append(self.alloc, kev) catch {
            self.pending_error = WaitError.OutOfMemory;
        };
    }

    /// Submit every staged change before blocking, harvesting records as they
    /// arrive. Earlier records are returned first; the next wait continues
    /// with any remaining changes. `timeout_ms` must be null or nonnegative.
    /// null blocks until an event, zero harvests without blocking, and
    /// positive values wait that many milliseconds. A stashed allocation
    /// failure is reported here once, ahead of the syscall. An empty wait
    /// neither consumes nor reports it.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) WaitError!usize {
        if (events.len == 0) return 0;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        if (have_user and self.wake_failed.swap(false, .acquire)) return WaitError.WaitFailed;
        var kbuf: [64]Kevent = undefined;
        const cap = @min(events.len, kbuf.len);

        var ts: std.c.timespec = undefined;
        var tsp: ?*const std.c.timespec = null;
        if (timeout_ms) |ms| {
            ts = .{ .sec = @intCast(@divTrunc(ms, 1000)), .nsec = @intCast(@mod(ms, 1000) * 1_000_000) };
            tsp = &ts;
        }
        const zero_ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };

        var consumed: usize = 0;
        var out: usize = 0;
        var woke = false;
        while (true) {
            const remaining = self.changes.items.len - consumed;
            const submitted = @min(remaining, cap);
            const last = submitted == remaining;
            const n = if (builtin.os.tag == .netbsd)
                netbsd.__kevent50(self.kq, self.changes.items[consumed..].ptr, submitted, &kbuf, cap, if (last) tsp else &zero_ts)
            else
                std.c.kevent(self.kq, self.changes.items[consumed..].ptr, @intCast(submitted), &kbuf, @intCast(cap), if (last) tsp else &zero_ts);
            process_kqueue.flushed(self, self.changes.items[consumed..][0..submitted]);
            consumed += submitted;
            if (n < 0) {
                self.consumeChanges(consumed);
                const e = std.posix.errno(@as(isize, n));
                if (e == .INTR) return 0;
                return WaitError.WaitFailed;
            }

            for (kbuf[0..@intCast(n)]) |kev| {
                if (kev.udata == @intFromPtr(&wake_sentinel)) {
                    if (!woke) {
                        woke = true;
                        if (!have_user) self.drainWake();
                        events[out] = .{ .wake = true };
                        out += 1;
                    }
                    continue;
                }
                if (kev.filter == EVFILT_WRITE) {
                    // One-shot consumed: the writer must re-arm explicitly.
                    _ = self.armed_write.remove(@intCast(kev.ident));
                }
                // The owning module sees its kevents first (live-id bookkeeping,
                // or suppressing an expected ENOENT from a late delete).
                const keep = if (kev.filter == EVFILT_TIMER)
                    timer_kqueue.observe(self, kev)
                else if (kev.filter == EVFILT_SIGNAL)
                    signal_kqueue.observe(self, kev)
                else if (process_kqueue.have_procdesc and kev.filter == process_kqueue.EVFILT_PROCDESC)
                    process_kqueue.observe(self, kev)
                else
                    true;
                if (!keep) continue;
                events[out] = translate(kev);
                out += 1;
            }
            if (out != 0) {
                self.consumeChanges(consumed);
                return out;
            }
            if (last) {
                self.changes.clearRetainingCapacity();
                return 0;
            }
        }
    }

    fn consumeChanges(self: *EvPort, consumed: usize) void {
        const remaining = self.changes.items.len - consumed;
        std.mem.copyForwards(Kevent, self.changes.items[0..remaining], self.changes.items[consumed..]);
        self.changes.items.len = remaining;
    }

    /// kevent to Event. A failed change (e.g. EV_ADD on a dead fd) must not
    /// masquerade as readiness, a timer or a signal: those stay clear when
    /// err is set. A signal number outside `Signal` is reported as an error
    /// event rather than dropped.
    fn translate(kev: Kevent) Event {
        const is_err = (kev.flags & EV_ERROR) != 0;
        var ev: Event = .{
            .udata = @ptrFromInt(kev.udata),
            .eof = (kev.flags & EV_EOF) != 0,
            .err = is_err,
            .err_no = if (is_err) @intCast(kev.data) else 0,
        };
        if (is_err) return ev;
        if (kev.filter == EVFILT_READ) {
            ev.readable = true;
            // Bytes buffered, or connections queued on a listener.
            ev.avail = if (kev.data > 0) std.math.cast(usize, kev.data) orelse std.math.maxInt(usize) else 0;
        } else if (kev.filter == EVFILT_WRITE) {
            ev.writable = true;
        } else if (kev.filter == EVFILT_TIMER) {
            ev.timer = true;
            ev.fired = firedCount(kev.data);
        } else if (kev.filter == EVFILT_SIGNAL) {
            if (Signal.fromPosix(kev.ident)) |sig| {
                ev.signal = sig;
                ev.fired = firedCount(kev.data);
            } else {
                ev.err = true;
            }
        } else if (process_kqueue.have_procdesc and kev.filter == process_kqueue.EVFILT_PROCDESC) {
            // An exit is not end-of-file; epoll never sets it. One event
            // contract on every backend.
            ev.eof = false;
            ev.exited = true;
            // NOTE_EXIT data is the wait(2) status, which is always an exit.
            ev.exit = types.ProcessExit.fromWaitStatus(@truncate(@as(u64, @bitCast(@as(i64, kev.data)))));
            if (ev.exit == null) ev.err = true;
        }
        return ev;
    }

    fn firedCount(data: @FieldType(Kevent, "data")) u32 {
        if (data <= 0) return 1;
        return std.math.cast(u32, data) orelse std.math.maxInt(u32);
    }

    fn drainWake(self: *EvPort) void {
        var tmp: [64]u8 = undefined;
        while (true) {
            _ = compat.read(self.wake_r, &tmp) catch break;
        }
    }
};

// --------------------------------------------------------------- tests ----

test "kqueue: target-native layout and change encoding" {
    const os = builtin.os.tag;
    try std.testing.expect(Kevent == compat.Kevent);
    const expected_size: usize = switch (os) {
        .freebsd => 64,
        .netbsd => 40,
        .macos, .openbsd => 32,
        else => unreachable,
    };
    try std.testing.expectEqual(expected_size, @sizeOf(Kevent));
    try std.testing.expectEqual(@as(usize, if (os == .netbsd) 4 else 2), @sizeOf(@FieldType(Kevent, "filter")));
    try std.testing.expectEqual(@as(usize, if (os == .netbsd) 4 else 2), @sizeOf(@FieldType(Kevent, "flags")));
    try std.testing.expect(@FieldType(Kevent, "udata") == usize);
    try std.testing.expectEqual(@as(i32, if (os == .netbsd) 0 else -1), EVFILT_READ);
    try std.testing.expectEqual(@as(i32, if (os == .netbsd) 1 else -2), EVFILT_WRITE);
    var tag: u8 = 1;
    const kev = EvPort.change(7, EVFILT_READ, EV_ADD | EV_CLEAR, &tag);
    try std.testing.expectEqual(@as(usize, 7), kev.ident);
    try std.testing.expectEqual(std.c.EVFILT.READ, kev.filter);
    try std.testing.expectEqual(std.c.EV.ADD | std.c.EV.CLEAR, kev.flags);
    try std.testing.expectEqual(@as(u32, 0), kev.fflags);
    try std.testing.expectEqual(@as(i64, 0), kev.data);
    try std.testing.expectEqual(@intFromPtr(&tag), kev.udata);
    const untagged = EvPort.change(7, EVFILT_WRITE, EV_DELETE, null);
    try std.testing.expectEqual(@as(usize, 0), untagged.udata);
    if (@hasField(Kevent, "_ext")) {
        for (kev._ext) |value| try std.testing.expectEqual(@as(u64, 0), value);
    }
}

test "kqueue: wake source is a user knote or a nonblocking close-on-exec pipe" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    if (have_user) {
        // EVFILT_USER needs no descriptors beyond the kqueue itself.
        try std.testing.expectEqual(@as(c_int, -1), port.wake_r);
        try std.testing.expectEqual(@as(c_int, -1), port.wake_w);
        return;
    }
    for ([_]Handle{ port.wake_r, port.wake_w }) |fd| {
        const flags: compat.O = @bitCast(@as(u32, @truncate(try compat.fcntl(fd, compat.F.GETFL, 0))));
        try std.testing.expect(flags.NONBLOCK);
        const fd_flags = try compat.fcntl(fd, compat.F.GETFD, 0);
        try std.testing.expect(fd_flags & compat.FD_CLOEXEC != 0);
    }
}

test "kqueue: registration error survives empty wait with errno payload" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    const closed = try compat.pipe2(PIPE2_FLAGS);
    compat.close(closed[0]);
    compat.close(closed[1]);
    const fd = closed[0];
    var tag: u8 = 1;
    port.monitorRead(fd, &tag);
    var empty: [0]Event = .{};
    const staged = port.changes.items.len;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    try std.testing.expectEqual(staged, port.changes.items.len);
    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 0));
    try std.testing.expect(events[0].err);
    try std.testing.expectEqual(@as(usize, @intFromEnum(compat.E.BADF)), events[0].err_no);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    // A failed registration is not readiness.
    try std.testing.expect(!events[0].readable);
    try std.testing.expect(!events[0].writable);
}

test "kqueue: eventlist capacity preserves rejected changes and the suffix" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    const closed = try compat.pipe2(PIPE2_FLAGS);
    compat.close(closed[0]);
    compat.close(closed[1]);
    var tags: [2]u8 = .{ 1, 2 };
    port.monitorRead(closed[0], &tags[0]);
    port.monitorRead(closed[1], &tags[1]);
    var timer_tag: u8 = 3;
    try port.addTimer(99, &timer_tag, 1, .once);

    var event: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&event, 0));
    try std.testing.expect(event[0].err and event[0].udata == @as(?*anyopaque, &tags[0]));
    try std.testing.expectEqual(@as(usize, @intFromEnum(compat.E.BADF)), event[0].err_no);
    try std.testing.expectEqual(@as(usize, 2), port.changes.items.len);

    try std.testing.expectEqual(@as(usize, 1), try port.wait(&event, 0));
    try std.testing.expect(event[0].err and event[0].udata == @as(?*anyopaque, &tags[1]));
    try std.testing.expectEqual(@as(usize, @intFromEnum(compat.E.BADF)), event[0].err_no);
    try std.testing.expectEqual(@as(usize, 1), port.changes.items.len);

    try std.testing.expectEqual(@as(usize, 1), try port.wait(&event, 1000));
    try std.testing.expect(event[0].timer and event[0].udata == @as(?*anyopaque, &timer_tag));
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
}

test "kqueue: 65 rejections cross the 64-slot boundary without loss" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    // The single-threaded test runner keeps these closed numbers distinct;
    // parallel descriptor activity could reuse them.
    var closed: [65]Handle = undefined;
    for (&closed) |*fd| fd.* = try compat.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    for (closed) |fd| compat.close(fd);
    var tags: [65]u8 = @splat(0);
    for (&tags, 0..) |*tag, i| port.monitorRead(closed[i], tag);
    var timer_tag: u8 = 1;
    try port.addTimer(100, &timer_tag, 1, .once);

    var events: [64]Event = undefined;
    try std.testing.expectEqual(@as(usize, 64), try port.wait(&events, 0));
    for (events) |event| try std.testing.expect(event.err);
    try std.testing.expectEqual(@as(usize, 2), port.changes.items.len);

    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 0));
    try std.testing.expect(events[0].err);
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);

    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].timer and events[0].udata == @as(?*anyopaque, &timer_tag));
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
}

test "kqueue: readiness beyond the eventlist cap is submitted before timeout" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    const idle = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(idle[0]);
    defer compat.close(idle[1]);
    const ready = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(ready[0]);
    defer compat.close(ready[1]);
    var tags: [2]u8 = .{ 1, 2 };
    port.monitorRead(idle[0], &tags[0]);
    port.monitorRead(ready[0], &tags[1]);
    _ = try compat.write(ready[1], "x");

    var event: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&event, 2000));
    try std.testing.expect(event[0].readable and event[0].udata == @as(?*anyopaque, &tags[1]));
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
}

test "kqueue: null timeout submits readiness beyond the eventlist cap" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    const idle = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(idle[0]);
    defer compat.close(idle[1]);
    const ready = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(ready[0]);
    defer compat.close(ready[1]);
    var tags: [2]u8 = .{ 1, 2 };
    port.monitorRead(idle[0], &tags[0]);
    port.monitorRead(ready[0], &tags[1]);
    _ = try compat.write(ready[1], "x");

    // The wake only bounds a regression; correct code returns the readable
    // event before the helper fires instead of sleeping with changes staged.
    const Waker = struct {
        fn run(p: *EvPort) void {
            compat.sleepNs(50 * std.time.ns_per_ms);
            p.wake();
        }
    };
    const thread = try std.Thread.spawn(.{}, Waker.run, .{&port});
    defer thread.join();
    var event: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&event, null));
    try std.testing.expect(event[0].readable and event[0].udata == @as(?*anyopaque, &tags[1]));
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
}

test "kqueue: allocation failure is reported by the next wait, once" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    // Submit init's staged wake registration (pipe targets), then force
    // the next stage to allocate: drop the changelist buffer and switch
    // to an allocator that fails on its first allocation.
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    port.changes.clearAndFree(port.alloc);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    port.alloc = failing.allocator();
    const pipe_fds = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(pipe_fds[0]);
    defer compat.close(pipe_fds[1]);
    port.monitorRead(pipe_fds[0], null);
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    try std.testing.expectError(Error.OutOfMemory, port.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "kqueue: init fails when the wake-pipe registration cannot be staged" {
    if (have_user) return error.SkipZigTest;
    // fail_index 0: init's wake-pipe monitorRead append fails. Init must
    // fail, not construct a port whose wake pipe is unmonitored.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(Error.OutOfMemory, EvPort.init(failing.allocator()));
    // Complete cleanup: no leaked bookkeeping.
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);

    // A retry constructs a working port whose pipe wake delivers an event.
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    port.wake();
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].wake);
}

test "kqueue: socket read readiness + EV_CLEAR edge semantics" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM, 0, &fds));
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);
    for (fds) |fd| {
        _ = try compat.fcntl(fd, compat.F.SETFL, @as(u32, @bitCast(@as(compat.O, .{ .NONBLOCK = true }))));
        _ = try compat.fcntl(fd, compat.F.SETFD, compat.FD_CLOEXEC);
    }

    var tag: u8 = 1;
    evp.monitorRead(fds[0], &tag);

    _ = try compat.write(fds[1], "ab");

    var events: [8]Event = undefined;
    const n = try evp.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));

    // The EV_CLEAR contract the core relies on: a handler that fully drains
    // (read to EAGAIN) gets exactly-once delivery per edge, with no re-fire
    // until new data arrives.
    var buf: [4]u8 = undefined;
    while (true) {
        _ = compat.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));

    // New write = new edge.
    _ = try compat.write(fds[1], "c");
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
}

test "kqueue: one-shot write interest re-arms on demand" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    const fds = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);

    var tag: u8 = 2;
    evp.wantWrite(fds[1], &tag);

    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].writable);

    // One-shot consumed: no second delivery without re-arming.
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));

    evp.wantWrite(fds[1], &tag);
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].writable);
}

test "kqueue: wantWrite retries after a changelist allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var port = try EvPort.init(alloc);
    defer port.deinit();
    const fds = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);

    var tags: [2]u8 = .{ 1, 2 };
    port.monitorRead(fds[0], &tags[0]);
    // Flush everything staged (including init's wake monitorRead on pipe
    // targets) and release the changelist capacity, so the next staging
    // append is guaranteed to allocate on every kqueue platform.
    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    port.changes.clearAndFree(alloc);

    // Fail the changelist reservation, the second allocation in wantWrite.
    // Failing the first (armed_write) reservation instead would leave the
    // armed bit clear even without the fix, hiding the lost write interest.
    failing.fail_index = failing.alloc_index + 1;
    port.wantWrite(fds[1], &tags[1]);
    try std.testing.expect(!port.armed_write.contains(fds[1]));
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);

    // Recover and retry: the arm must stage a fresh change.
    failing.fail_index = std.math.maxInt(usize);
    port.wantWrite(fds[1], &tags[1]);
    try std.testing.expect(port.armed_write.contains(fds[1]));
    try std.testing.expectEqual(@as(usize, 1), port.changes.items.len);

    // The stashed failure is reported once, then the retried change is
    // submitted and the pipe write end delivers writability.
    try std.testing.expectError(Error.OutOfMemory, port.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].writable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tags[1]));
    try std.testing.expect(!port.armed_write.contains(fds[1]));
}

test "kqueue: peer close delivers eof" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    const fds = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(fds[0]);

    var tag: u8 = 3;
    evp.monitorRead(fds[0], &tag);
    compat.close(fds[1]);

    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].eof);
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try compat.read(fds[0], &one));
}

test "kqueue: wake posts a single coalesced event" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    evp.wake();
    evp.wake();
    evp.wake();

    var events: [8]Event = undefined;
    const n = try evp.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(events[0].wake);
    // Drained: no further wake events.
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
    // A later wake is a new event.
    evp.wake();
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].wake);
}

test "kqueue: wakes from another thread before the first wait are not lost" {
    var evp = try EvPort.init(std.testing.allocator);
    defer evp.deinit();
    const Waker = struct {
        fn run(p: *EvPort) void {
            for (0..100) |_| p.wake();
        }
    };
    const t = try std.Thread.spawn(.{}, Waker.run, .{&evp});
    t.join();
    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].wake);
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "kqueue: a refused wake trigger is reported by the next wait" {
    if (!have_user) return error.SkipZigTest;
    var evp = try EvPort.init(std.testing.allocator);
    defer evp.deinit();
    // Break the wake source: dropping the knote makes NOTE_TRIGGER fail.
    var del = EvPort.change(wake_ident, EVFILT_USER, EV_DELETE, null);
    try EvPort.kevent1(evp.kq, &del);
    evp.wake();
    var events: [4]Event = undefined;
    try std.testing.expectError(Error.WaitFailed, evp.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "kqueue: non-blocking connect completes via write filter" {
    const alloc = std.testing.allocator;

    const addr = try compat.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    const s = try compat.socket(compat.AF.INET, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0);
    defer compat.close(s);

    compat.connect(s, &server.listen_address.any, server.listen_address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {}, // EINPROGRESS: expected
        else => return err,
    };

    var evp = try EvPort.init(alloc);
    defer evp.deinit();
    var tag: u8 = 4;
    evp.wantWrite(s, &tag);

    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].writable);

    var so_error: c_int = -1;
    try compat.getsockopt(s, compat.SOL.SOCKET, compat.SO.ERROR, std.mem.asBytes(&so_error));
    try std.testing.expectEqual(@as(c_int, 0), so_error);
}

test "kqueue: timer and signal kevents translate to their event fields" {
    var tag: u8 = 1;
    var kev = EvPort.change(9, EVFILT_TIMER, EV_ADD, &tag);
    kev.data = 3;
    const timer = EvPort.translate(kev);
    try std.testing.expect(timer.timer and timer.signal == null);
    try std.testing.expectEqual(@as(u32, 3), timer.fired);
    try std.testing.expect(timer.udata == @as(?*anyopaque, &tag));
    try std.testing.expect(!timer.readable and !timer.writable and !timer.err);

    kev.data = std.math.maxInt(@FieldType(Kevent, "data"));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), EvPort.translate(kev).fired);

    var sig = EvPort.change(Signal.hangup.toPosix(), EVFILT_SIGNAL, EV_ADD, &tag);
    sig.data = 2;
    const hup = EvPort.translate(sig);
    try std.testing.expectEqual(@as(?Signal, .hangup), hup.signal);
    try std.testing.expectEqual(@as(u32, 2), hup.fired);
    try std.testing.expect(!hup.timer and !hup.err);

    // A rejected timer change is an error, never a firing.
    kev.flags = EV_ERROR;
    kev.data = @intFromEnum(compat.E.NOENT);
    const failed = EvPort.translate(kev);
    try std.testing.expect(failed.err and !failed.timer);
    try std.testing.expectEqual(@as(u32, 0), failed.fired);
    try std.testing.expectEqual(@as(usize, @intFromEnum(compat.E.NOENT)), failed.err_no);

    // A signal outside Signal is reported, not dropped or mislabelled.
    const unknown = EvPort.translate(EvPort.change(compat.signalNumber(std.posix.SIG.WINCH), EVFILT_SIGNAL, EV_ADD, &tag));
    try std.testing.expect(unknown.err and unknown.signal == null);

    // Descriptor events leave the timer and signal fields inert.
    const read = EvPort.translate(EvPort.change(5, EVFILT_READ, EV_ADD, &tag));
    try std.testing.expect(read.readable and !read.timer and read.signal == null);
    try std.testing.expectEqual(@as(u32, 0), read.fired);
    try std.testing.expectEqual(@as(usize, 0), read.avail);

    // Readable events carry the kernel's count; nothing else does.
    var counted = EvPort.change(5, EVFILT_READ, EV_ADD, &tag);
    counted.data = 4096;
    try std.testing.expectEqual(@as(usize, 4096), EvPort.translate(counted).avail);
    counted.data = -1;
    try std.testing.expectEqual(@as(usize, 0), EvPort.translate(counted).avail);
    counted.filter = EVFILT_WRITE;
    counted.data = 4096;
    try std.testing.expectEqual(@as(usize, 0), EvPort.translate(counted).avail);
}

test "kqueue: process descriptor kevents translate to the exit fields" {
    if (!process_kqueue.have_procdesc) return error.SkipZigTest;
    var tag: u8 = 1;
    var kev = EvPort.change(5, process_kqueue.EVFILT_PROCDESC, EV_ADD | EV_EOF, &tag);
    kev.data = 7 << 8;
    const coded = EvPort.translate(kev);
    try std.testing.expect(coded.exited and !coded.err and !coded.readable and !coded.timer);
    // An exit is not end-of-file on any backend, even with EV_EOF fed.
    try std.testing.expect(!coded.eof);
    try std.testing.expectEqual(types.ProcessExit{ .code = 7 }, coded.exit.?);
    kev.data = compat.signalNumber(std.posix.SIG.KILL);
    try std.testing.expectEqual(types.ProcessExit{ .signal = compat.signalNumber(std.posix.SIG.KILL) }, EvPort.translate(kev).exit.?);
    // A refused watch is an error, never an exit.
    kev.flags = EV_ERROR;
    kev.data = @intFromEnum(compat.E.BADF);
    const refused = EvPort.translate(kev);
    try std.testing.expect(refused.err and !refused.exited and refused.exit == null);
    // Other filters leave the exit fields inert.
    const read = EvPort.translate(EvPort.change(5, EVFILT_READ, EV_ADD, &tag));
    try std.testing.expect(!read.exited and read.exit == null);
}

test "kqueue: purgeFd drops a staged process watch" {
    if (!process_kqueue.have_procdesc) return error.SkipZigTest;
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    _ = try port.wait(&events, 0);
    var tag: u8 = 1;
    try port.watchProcess(901, &tag);
    port.purgeFd(901);
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
    try std.testing.expect(!port.processes.live.contains(901));
}

test "kqueue: stageRaw timer is submitted by the next wait and fires once" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    // Milliseconds are the default unit (fflags 0) on every kqueue target.
    var kev = EvPort.change(42, EVFILT_TIMER, EV_ADD | EV_ONESHOT, &tag);
    kev.data = 5;
    const staged = port.changes.items.len;
    port.stageRaw(kev);
    try std.testing.expectEqual(staged + 1, port.changes.items.len);
    var events: [4]Event = undefined;
    var n: usize = 0;
    while (n == 0) n = try port.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(events[0].timer);
    try std.testing.expectEqual(@as(u32, 1), events[0].fired);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 20));
}

test "kqueue: stageRaw signal is delivered as Event.signal" {
    const signo = Signal.user2.toPosix();
    // EVFILT_SIGNAL records deliveries under any disposition; ignore the
    // signal so the default action cannot end the test process.
    var prior: compat.Sigaction = undefined;
    const ignore: compat.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = compat.sigemptyset(),
        .flags = 0,
    };
    compat.sigaction(signo, &ignore, &prior);
    defer compat.sigaction(signo, &prior, null);

    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    port.stageRaw(EvPort.change(signo, EVFILT_SIGNAL, EV_ADD | EV_CLEAR, &tag));
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    // Process-directed: XNU's EVFILT_SIGNAL does not see a thread-directed raise(3).
    try compat.kill(std.c.getpid(), signo);
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expectEqual(@as(?Signal, .user2), events[0].signal);
    try std.testing.expect(events[0].fired >= 1);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    port.stageRaw(EvPort.change(signo, EVFILT_SIGNAL, EV_DELETE, null));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "kqueue: purgeFd leaves a staged timer whose ident equals the fd" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var events: [4]Event = undefined;
    _ = try port.wait(&events, 0);
    const pipe_fds = try compat.pipe2(PIPE2_FLAGS);
    defer compat.close(pipe_fds[0]);
    defer compat.close(pipe_fds[1]);
    const fd = pipe_fds[0];
    var tag: u8 = 1;
    port.monitorRead(fd, &tag);
    var kev = EvPort.change(fd, EVFILT_TIMER, EV_ADD | EV_ONESHOT, &tag);
    kev.data = 1000;
    port.stageRaw(kev);
    port.purgeFd(fd);
    try std.testing.expectEqual(@as(usize, 1), port.changes.items.len);
    try std.testing.expectEqual(EVFILT_TIMER, port.changes.items[0].filter);
}
