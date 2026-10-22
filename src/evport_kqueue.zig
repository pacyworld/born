// BSD/macOS event port: kqueue backend.
//
// Global-rule discipline:
//   - Staged changelist: monitor*/unmonitor* accumulate struct kevent into a
//     local array; the next wait() submits changelist + eventlist in ONE
//     kevent() call. No kevent() call exists solely to register fds.
//   - A kernel-rejected change comes back at wait() as Event{ .err, .err_no }.
//     An ALLOCATION failure never reaches the kernel, so it is stashed and
//     returned as error.OutOfMemory from the next non-empty wait() instead
//     (the IOCP backend's shape) — no failure is a silent drop.
//   - EV_CLEAR (edge-triggered) on EVFILT_READ: read handlers must fully
//     drain buffered data (plain: read to EAGAIN; TLS: SSL_read to
//     WANT_READ, which implies the socket hit EAGAIN).
//   - EV_ONESHOT on EVFILT_WRITE: connect completion and buffer-space
//     events are single-shot; the connection re-arms on demand.
//   - Cross-thread wakeup: pipe trick (EVFILT_SIGNAL is unreliable for
//     that). wake() writes 1 byte; wait() coalesces/drains to one event.
//   - Closing fds need no unmonitoring: close(2) removes all filters. The
//     core defers close() until just after a wait() flush so staged entries
//     never reference a closed (and possibly recycled) fd.
//   - Timers (timer_kqueue.zig) register through stageRaw like any other
//     change. The one exception: signal watch/unwatch (signal_kqueue.zig)
//     are one-time setup calls that apply their change with an immediate
//     kevent(), so no delivery is lost before the next wait(). wait()
//     translates EVFILT_TIMER and EVFILT_SIGNAL into
//     Event.timer/.signal/.fired after each module's observe() hook has
//     seen the kevent.

const std = @import("std");
const types = @import("types.zig");
const timer_kqueue = @import("timer_kqueue.zig");
const signal_kqueue = @import("signal_kqueue.zig");

// Use the target's struct kevent: FreeBSD 12+ needs its extended 64-byte
// layout (ext[4]), while NetBSD has wider filter/flags fields. A wrong
// stride corrupts multi-entry changelists and event buffers.
pub const Kevent = std.posix.Kevent;
const EVFILT_READ = std.posix.system.EVFILT.READ;
const EVFILT_WRITE = std.posix.system.EVFILT.WRITE;
pub const EVFILT_TIMER = std.posix.system.EVFILT.TIMER;
pub const EVFILT_SIGNAL = std.posix.system.EVFILT.SIGNAL;

const EV_ADD = std.posix.system.EV.ADD;
const EV_DELETE = std.posix.system.EV.DELETE;
const EV_ONESHOT = std.posix.system.EV.ONESHOT;
const EV_CLEAR = std.posix.system.EV.CLEAR;
// Zig 0.15 omits EOF on FreeBSD/NetBSD and ERROR on NetBSD (sys/event.h).
const EV_EOF = if (@hasDecl(std.posix.system.EV, "EOF")) std.posix.system.EV.EOF else 0x8000;
const EV_ERROR = if (@hasDecl(std.posix.system.EV, "ERROR")) std.posix.system.EV.ERROR else 0x4000;

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

// Target-native pipe flags; std.posix.pipe2 uses pipe + fcntl on macOS.
const PIPE2_FLAGS: std.posix.O = .{ .NONBLOCK = true, .CLOEXEC = true };

pub const Handle = types.Handle;
pub const Event = types.Event;
pub const Signal = types.Signal;
pub const TimerMode = types.TimerMode;

pub const InitError = error{ KqueueFailed, PipeFailed };
/// A stashed allocation failure is reported as OutOfMemory; kernel
/// rejections of staged changes arrive as Event.err instead.
pub const WaitError = error{ WaitFailed, OutOfMemory };
pub const TimerError = types.TimerError;
pub const SignalError = types.SignalError;
/// Every error this backend can return.
pub const Error = InitError || WaitError || TimerError || SignalError;

/// Block `sigs` in the calling thread so a signal-watching port can receive
/// them. Call it in `main` before spawning threads; see signal_kqueue.zig.
pub const blockSignals = signal_kqueue.blockSignals;

/// Stable address used as the wake pipe's udata tag (module-level so a
/// by-value EvPort return never leaves it dangling).
var wake_sentinel: u8 = 0;

pub const EvPort = struct {
    kq: c_int = -1,
    alloc: std.mem.Allocator,
    /// Staged changelist, flushed by the next wait().
    changes: std.ArrayList(Kevent) = .empty,
    wake_r: c_int = -1,
    wake_w: c_int = -1,
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

    pub fn init(alloc: std.mem.Allocator) InitError!EvPort {
        const kq = std.posix.kqueue() catch return InitError.KqueueFailed;
        errdefer _ = std.c.close(kq);

        const fds = std.posix.pipe2(PIPE2_FLAGS) catch return InitError.PipeFailed;
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }

        var self = EvPort{
            .kq = kq,
            .alloc = alloc,
            .wake_r = fds[0],
            .wake_w = fds[1],
            .timers = timer_kqueue.State.init(alloc),
            .signals = signal_kqueue.State.init(alloc),
        };
        self.monitorRead(self.wake_r, @as(?*anyopaque, &wake_sentinel));
        return self;
    }

    pub fn deinit(self: *EvPort) void {
        // Signal dispositions are process-wide: restore them while the
        // port can still describe what it changed.
        self.signals.deinit(self);
        self.timers.deinit(self);
        if (self.kq >= 0) _ = std.c.close(self.kq);
        if (self.wake_r >= 0) _ = std.c.close(self.wake_r);
        if (self.wake_w >= 0) _ = std.c.close(self.wake_w);
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
        // Reserve the dedup slot before staging so the armed bit and the
        // staged change agree even when the stage append later fails.
        self.armed_write.ensureUnusedCapacity(self.alloc, 1) catch {
            self.pending_error = WaitError.OutOfMemory;
            return;
        };
        self.armed_write.putAssumeCapacity(fd, {});
        self.stage(change(fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, udata));
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
    /// equals the fd number is not the fd's.
    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        _ = self.armed_write.remove(fd);
        const ident: usize = @intCast(fd);
        var i: usize = 0;
        while (i < self.changes.items.len) {
            const kev = self.changes.items[i];
            if (kev.ident == ident and (kev.filter == EVFILT_READ or kev.filter == EVFILT_WRITE)) {
                _ = self.changes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Wake a wait() blocked in another thread. Non-blocking; a full pipe
    /// means the loop is already awake (coalesced).
    pub fn wake(self: *EvPort) void {
        const b = [1]u8{1};
        _ = std.c.write(self.wake_w, &b, 1);
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

    /// Flush the staged changelist and harvest events in ONE kevent() call.
    /// timeout_ms: null = block until an event; 0 = harvest without blocking.
    /// A stashed allocation failure is reported here, once, ahead of the
    /// syscall — an empty wait neither consumes nor reports it.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) WaitError!usize {
        if (events.len == 0) return 0;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        var kbuf: [64]Kevent = undefined;
        const cap = @min(events.len, kbuf.len);

        var ts: std.c.timespec = undefined;
        var tsp: ?*const std.c.timespec = null;
        if (timeout_ms) |ms| {
            ts = .{ .sec = @intCast(@divTrunc(ms, 1000)), .nsec = @intCast(@mod(ms, 1000) * 1_000_000) };
            tsp = &ts;
        }

        const n = if (@import("builtin").os.tag == .netbsd)
            netbsd.__kevent50(self.kq, self.changes.items.ptr, self.changes.items.len, &kbuf, cap, tsp)
        else
            std.c.kevent(self.kq, self.changes.items.ptr, @intCast(self.changes.items.len), &kbuf, @intCast(cap), tsp);
        self.changes.clearRetainingCapacity();
        if (n < 0) {
            const e = std.posix.errno(@as(isize, n));
            if (e == .INTR) return 0;
            return WaitError.WaitFailed;
        }

        var out: usize = 0;
        var woke = false;
        for (kbuf[0..@intCast(n)]) |kev| {
            if (kev.udata == @intFromPtr(&wake_sentinel)) {
                if (!woke) {
                    woke = true;
                    self.drainWake();
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
            else
                true;
            if (!keep) continue;
            events[out] = translate(kev);
            out += 1;
        }
        return out;
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
            _ = std.posix.read(self.wake_r, &tmp) catch break;
        }
    }
};

// --------------------------------------------------------------- tests ----

test "kqueue: target-native layout and change encoding" {
    const os = @import("builtin").os.tag;
    try std.testing.expect(Kevent == std.posix.Kevent);
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
    try std.testing.expectEqual(std.posix.system.EVFILT.READ, kev.filter);
    try std.testing.expectEqual(std.posix.system.EV.ADD | std.posix.system.EV.CLEAR, kev.flags);
    try std.testing.expectEqual(@as(u32, 0), kev.fflags);
    try std.testing.expectEqual(@as(i64, 0), kev.data);
    try std.testing.expectEqual(@intFromPtr(&tag), kev.udata);
    const untagged = EvPort.change(7, EVFILT_WRITE, EV_DELETE, null);
    try std.testing.expectEqual(@as(usize, 0), untagged.udata);
    if (@hasField(Kevent, "_ext")) {
        for (kev._ext) |value| try std.testing.expectEqual(@as(u64, 0), value);
    }
}

test "kqueue: wake pipe is nonblocking and close-on-exec on both ends" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    for ([_]Handle{ port.wake_r, port.wake_w }) |fd| {
        const flags: std.posix.O = @bitCast(@as(u32, @truncate(try std.posix.fcntl(fd, std.posix.F.GETFL, 0))));
        try std.testing.expect(flags.NONBLOCK);
        const fd_flags = try std.posix.fcntl(fd, std.posix.F.GETFD, 0);
        try std.testing.expect(fd_flags & std.posix.FD_CLOEXEC != 0);
    }
}

test "kqueue: registration error survives empty wait with errno payload" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    const fd = try std.posix.dup(port.wake_r);
    std.posix.close(fd);
    var tag: u8 = 1;
    port.monitorRead(fd, &tag);
    var empty: [0]Event = .{};
    const staged = port.changes.items.len;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    try std.testing.expectEqual(staged, port.changes.items.len);
    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 0));
    try std.testing.expect(events[0].err);
    try std.testing.expectEqual(@as(usize, @intFromEnum(std.posix.E.BADF)), events[0].err_no);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    // A failed registration is not readiness (issue #4 addendum).
    try std.testing.expect(!events[0].readable);
    try std.testing.expect(!events[0].writable);
}

test "kqueue: allocation failure is reported by the next wait, once" {
    // fail_index 0 lands inside init's wake-pipe monitorRead stage: the
    // port constructs, but the changelist append failed.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var port = try EvPort.init(failing.allocator());
    defer port.deinit();
    try std.testing.expectEqual(@as(usize, 0), port.changes.items.len);
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    var events: [1]Event = undefined;
    try std.testing.expectError(Error.OutOfMemory, port.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "kqueue: socket read readiness + EV_CLEAR edge semantics" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    for (fds) |fd| {
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(@as(std.posix.O, .{ .NONBLOCK = true }))));
        _ = try std.posix.fcntl(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
    }

    var tag: u8 = 1;
    evp.monitorRead(fds[0], &tag);

    _ = try std.posix.write(fds[1], "ab");

    var events: [8]Event = undefined;
    const n = try evp.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));

    // The EV_CLEAR contract the core relies on: a handler that fully drains
    // (read to EAGAIN) gets exactly-once delivery per edge — no re-fire
    // until new data arrives.
    var buf: [4]u8 = undefined;
    while (true) {
        _ = std.posix.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));

    // New write = new edge.
    _ = try std.posix.write(fds[1], "c");
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
}

test "kqueue: one-shot write interest re-arms on demand" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    const fds = try std.posix.pipe2(PIPE2_FLAGS);
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

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

test "kqueue: peer close delivers eof" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    const fds = try std.posix.pipe2(PIPE2_FLAGS);
    defer _ = std.c.close(fds[0]);

    var tag: u8 = 3;
    evp.monitorRead(fds[0], &tag);
    _ = std.c.close(fds[1]);

    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].eof);
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(fds[0], &one));
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
    // Pipe drained: no further wake events.
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "kqueue: non-blocking connect completes via write filter" {
    const alloc = std.testing.allocator;

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    const s = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(s);

    std.posix.connect(s, &server.listen_address.any, server.listen_address.getOsSockLen()) catch |err| switch (err) {
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
    try std.posix.getsockopt(s, std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&so_error));
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
    kev.data = @intFromEnum(std.posix.E.NOENT);
    const failed = EvPort.translate(kev);
    try std.testing.expect(failed.err and !failed.timer);
    try std.testing.expectEqual(@as(u32, 0), failed.fired);
    try std.testing.expectEqual(@as(usize, @intFromEnum(std.posix.E.NOENT)), failed.err_no);

    // A signal outside Signal is reported, not dropped or mislabelled.
    const unknown = EvPort.translate(EvPort.change(std.posix.SIG.WINCH, EVFILT_SIGNAL, EV_ADD, &tag));
    try std.testing.expect(unknown.err and unknown.signal == null);

    // Descriptor events leave the new fields inert.
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

test "kqueue: stageRaw timer is submitted by the next wait and fires once" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    // Milliseconds are the default unit (fflags 0) on every kqueue target.
    var kev = EvPort.change(42, EVFILT_TIMER, EV_ADD | EV_ONESHOT, &tag);
    kev.data = 5;
    port.stageRaw(kev);
    try std.testing.expectEqual(@as(usize, 2), port.changes.items.len);
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
    var prior: std.posix.Sigaction = undefined;
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(signo, &ignore, &prior);
    defer std.posix.sigaction(signo, &prior, null);

    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    port.stageRaw(EvPort.change(signo, EVFILT_SIGNAL, EV_ADD | EV_CLEAR, &tag));
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    // Process-directed: XNU's EVFILT_SIGNAL does not see a thread-directed raise(3).
    try std.posix.kill(std.c.getpid(), signo);
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
    const fd = port.wake_r;
    var tag: u8 = 1;
    port.monitorRead(fd, &tag);
    var kev = EvPort.change(fd, EVFILT_TIMER, EV_ADD | EV_ONESHOT, &tag);
    kev.data = 1000;
    port.stageRaw(kev);
    port.purgeFd(fd);
    try std.testing.expectEqual(@as(usize, 1), port.changes.items.len);
    try std.testing.expectEqual(EVFILT_TIMER, port.changes.items[0].filter);
}
