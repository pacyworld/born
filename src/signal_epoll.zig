//! Signals on epoll: one signalfd per port. Owned by born#16: this file plus
//! the EvPort.watchSignal/unwatchSignal bodies in evport_epoll.zig, and
//! `blockSignals` (exported as `born.blockSignals`).
//!
//! signalfd only sees signals blocked in every thread, so programs call
//! `blockSignals` in `main` before spawning threads, and `watch` refuses a
//! signal that is not blocked in the calling thread with
//! error.SignalNotBlocked. The first watch creates the signalfd and registers
//! it with `EvPort.addInternal(.signal, fd)`; later watches and unwatches
//! rewrite its mask, and the last unwatch closes it. `harvest` runs in the
//! wait() thread, reads siginfo records and folds repeats of one signal into
//! one Event with `.fired = count`.
//!
//! Ownership is process-wide: a signal is watched by at most one port, and a
//! second port gets error.SignalInUse until the first unwatches it or is
//! deinitialized. Dispositions and the thread mask are never changed by a
//! watch, so unwatch leaves the process as it was before the watch.

const std = @import("std");
const linux = std.os.linux;
const ep = @import("evport_epoll.zig");
const EvPort = ep.EvPort;
const Event = ep.Event;
const SignalError = ep.SignalError;
const Signal = ep.Signal;

const SignalSet = std.EnumSet(Signal);
const signal_count = std.meta.fields(Signal).len;
const Siginfo = linux.signalfd_siginfo;

/// Owning port id per signal, 0 when unwatched. Guarded by `owners_lock`
/// because ports on different threads watch and unwatch concurrently.
var owners = [_]u64{0} ** signal_count;
var owners_lock: std.Thread.Mutex = .{};
/// Source of port ids; an id survives the port value being moved.
var next_id = std.atomic.Value(u64).init(1);

/// Per-port watch bookkeeping, a field of EvPort (`signals`).
pub const State = struct {
    /// The signalfd, -1 while nothing is watched.
    fd: i32 = -1,
    /// Ownership id, assigned on the first watch.
    id: u64 = 0,
    watched: SignalSet = .{},
    udata: [signal_count]?*anyopaque = .{null} ** signal_count,

    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Releases process-wide ownership, removes the internal source and
    /// closes the signalfd.
    pub fn deinit(self: *State, port: *EvPort) void {
        var it = self.watched.iterator();
        while (it.next()) |sig| release(self.id, sig);
        self.watched = .{};
        self.udata = .{null} ** signal_count;
        self.closeFd(port);
    }

    /// Points the signalfd at `set`: creates and registers it when absent,
    /// rewrites its mask otherwise, and closes it when `set` is empty.
    fn setMask(self: *State, port: *EvPort, set: SignalSet) SignalError!void {
        if (set.count() == 0) {
            self.closeFd(port);
            return;
        }
        const mask = kernelMask(set);
        if (self.fd != -1) {
            if (linux.E.init(linux.signalfd(self.fd, &mask, 0)) != .SUCCESS)
                return SignalError.SystemResources;
            return;
        }
        const rc = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
        if (linux.E.init(rc) != .SUCCESS) return SignalError.SystemResources;
        const fd: i32 = @intCast(rc);
        port.addInternal(.signal, fd) catch |err| {
            _ = std.c.close(fd);
            return switch (err) {
                // The signal slot belongs to this module and is empty
                // whenever self.fd is -1.
                error.InvalidArgument => unreachable,
                error.SystemResources => SignalError.SystemResources,
            };
        };
        self.fd = fd;
    }

    fn closeFd(self: *State, port: *EvPort) void {
        if (self.fd == -1) return;
        port.removeInternal(.signal);
        _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

/// Deliver `sig` as Event{ .signal, .fired, .udata } from the port's wait().
/// Watching a signal the port already watches replaces its udata.
pub fn watch(port: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
    if (!try blockedInThread(sig)) return SignalError.SignalNotBlocked;
    const st = &port.signals;
    if (st.watched.contains(sig)) {
        st.udata[@intFromEnum(sig)] = udata;
        return;
    }
    if (st.id == 0) st.id = next_id.fetchAdd(1, .monotonic);
    try claim(st.id, sig);
    errdefer release(st.id, sig);
    var next = st.watched;
    next.insert(sig);
    try st.setMask(port, next);
    st.watched = next;
    st.udata[@intFromEnum(sig)] = udata;
}

/// Stop watching `sig` and release it to other ports. Unwatched signals are
/// a no-op. The signal stays blocked: the mask belongs to the program.
pub fn unwatch(port: *EvPort, sig: Signal) void {
    const st = &port.signals;
    if (!st.watched.contains(sig)) return;
    var next = st.watched;
    next.remove(sig);
    st.setMask(port, next) catch {
        // A signalfd that cannot be narrowed would keep consuming the
        // released signal, so replace it with one for the remaining set.
        st.closeFd(port);
        st.setMask(port, next) catch stashFailure(port);
    };
    st.watched = next;
    st.udata[@intFromEnum(sig)] = null;
    release(st.id, sig);
}

/// Turns a ready signalfd into at most `out.len` (>= 1) events and returns
/// the count. Reads until EAGAIN, folding every record of one signal into a
/// single event. Once `out` is full the mask is narrowed to the signals
/// already emitted, so other pending signals stay queued and the
/// level-triggered fd is reported again by the next wait(). Failures are
/// stashed in `port.pending_error` as error.SourceFailed, never dropped.
pub fn harvest(port: *EvPort, out: []Event) usize {
    const st = &port.signals;
    if (st.fd == -1) return 0;
    const watched_count = st.watched.count();
    var buf: [8]Siginfo = undefined;
    var n: usize = 0;
    var narrowed = false;
    while (true) {
        if (n == out.len and n < watched_count and !narrowed) {
            var emitted: SignalSet = .{};
            for (out[0..n]) |ev| emitted.insert(ev.signal.?);
            const mask = kernelMask(emitted);
            if (linux.E.init(linux.signalfd(st.fd, &mask, 0)) != .SUCCESS) {
                stashFailure(port);
                break;
            }
            narrowed = true;
        }
        // A batch may hold any watched signal, so it is read only while
        // every signal not yet emitted still has a slot; otherwise one
        // record per read keeps a new signal from overrunning `out`.
        const batch: usize = if (narrowed or out.len - n >= watched_count - n) buf.len else 1;
        const rc = linux.read(st.fd, @ptrCast(&buf), batch * @sizeOf(Siginfo));
        switch (linux.E.init(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => break,
            else => {
                stashFailure(port);
                break;
            },
        }
        if (rc == 0 or rc % @sizeOf(Siginfo) != 0) {
            stashFailure(port);
            break;
        }
        for (buf[0 .. rc / @sizeOf(Siginfo)]) |rec| {
            const sig = Signal.fromPosix(rec.signo) orelse {
                stashFailure(port);
                continue;
            };
            if (!st.watched.contains(sig)) {
                stashFailure(port);
                continue;
            }
            for (out[0..n]) |*ev| {
                if (ev.signal == sig) {
                    ev.fired +|= 1;
                    break;
                }
            } else {
                out[n] = .{ .signal = sig, .fired = 1, .udata = st.udata[@intFromEnum(sig)] };
                n += 1;
            }
        }
    }
    if (narrowed) {
        const mask = kernelMask(st.watched);
        if (linux.E.init(linux.signalfd(st.fd, &mask, 0)) != .SUCCESS) stashFailure(port);
    }
    return n;
}

/// `pthread_sigmask(SIG_BLOCK)` for `sigs` in the calling thread. Threads
/// inherit the mask, so call it in `main` before spawning any.
pub fn blockSignals(sigs: []const Signal) SignalError!void {
    var set = std.posix.sigemptyset();
    for (sigs) |sig| std.posix.sigaddset(&set, sig.toPosix());
    var old: std.posix.sigset_t = undefined;
    // pthread_sigmask fails only with EINVAL for an invalid `how`.
    if (std.c.pthread_sigmask(std.posix.SIG.BLOCK, &set, &old) != 0)
        return SignalError.SystemResources;
}

/// Whether `sig` is blocked in the calling thread.
fn blockedInThread(sig: Signal) SignalError!bool {
    const none = std.posix.sigemptyset();
    var cur: std.posix.sigset_t = undefined;
    if (std.c.pthread_sigmask(std.posix.SIG.BLOCK, &none, &cur) != 0)
        return SignalError.SystemResources;
    return std.posix.sigismember(&cur, sig.toPosix());
}

fn kernelMask(set: SignalSet) linux.sigset_t {
    var mask = linux.sigemptyset();
    var it = set.iterator();
    while (it.next()) |sig| linux.sigaddset(&mask, sig.toPosix());
    return mask;
}

fn claim(id: u64, sig: Signal) SignalError!void {
    owners_lock.lock();
    defer owners_lock.unlock();
    const slot = &owners[@intFromEnum(sig)];
    if (slot.* != 0 and slot.* != id) return SignalError.SignalInUse;
    slot.* = id;
}

fn release(id: u64, sig: Signal) void {
    owners_lock.lock();
    defer owners_lock.unlock();
    const slot = &owners[@intFromEnum(sig)];
    if (slot.* == id) slot.* = 0;
}

/// Keeps the first stashed failure; wait() reports one per call.
fn stashFailure(port: *EvPort) void {
    if (port.pending_error == null) port.pending_error = error.SourceFailed;
}

// --------------------------------------------------------------- tests ----

/// Blocks or unblocks `sigs` in the calling thread; `restore` puts the
/// previous mask back.
const MaskGuard = struct {
    saved: std.posix.sigset_t,

    fn set(how: u32, sigs: []const Signal) MaskGuard {
        var g: MaskGuard = undefined;
        var set_: std.posix.sigset_t = std.posix.sigemptyset();
        for (sigs) |sig| std.posix.sigaddset(&set_, sig.toPosix());
        std.debug.assert(std.c.pthread_sigmask(@intCast(how), &set_, &g.saved) == 0);
        return g;
    }

    fn restore(self: *const MaskGuard) void {
        var ignored: std.posix.sigset_t = undefined;
        std.debug.assert(std.c.pthread_sigmask(std.posix.SIG.SETMASK, &self.saved, &ignored) == 0);
    }
};

fn raiseInThread(sig: Signal) !void {
    try std.posix.raise(sig.toPosix());
}

test "signal_epoll: watching an unblocked signal fails with SignalNotBlocked" {
    const guard = MaskGuard.set(std.posix.SIG.UNBLOCK, &.{.hangup});
    defer guard.restore();
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 0;
    try std.testing.expectError(error.SignalNotBlocked, port.watchSignal(.hangup, &tag));
    // Nothing was claimed or created: the port holds no signalfd and
    // another port can still watch the signal once it is blocked.
    try std.testing.expect(port.internalFd(.signal) == null);
    try blockSignals(&.{.hangup});
    var other = try EvPort.init(std.testing.allocator);
    defer other.deinit();
    try other.watchSignal(.hangup, &tag);
    other.unwatchSignal(.hangup);
}

test "signal_epoll: the signalfd lives exactly as long as some watch" {
    const guard = MaskGuard.set(std.posix.SIG.BLOCK, &.{ .hangup, .user2 });
    defer guard.restore();
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 0;
    try port.watchSignal(.hangup, &tag);
    const fd = port.internalFd(.signal).?;
    try port.watchSignal(.user2, &tag);
    try std.testing.expectEqual(@as(?i32, fd), port.internalFd(.signal));
    port.unwatchSignal(.hangup);
    try std.testing.expectEqual(@as(?i32, fd), port.internalFd(.signal));
    port.unwatchSignal(.user2);
    try std.testing.expect(port.internalFd(.signal) == null);
    try std.testing.expectEqual(@as(i32, -1), port.signals.fd);
}

test "signal_epoll: deinit releases ownership" {
    const guard = MaskGuard.set(std.posix.SIG.BLOCK, &.{.hangup});
    defer guard.restore();
    var tag: u8 = 0;
    {
        var first = try EvPort.init(std.testing.allocator);
        defer first.deinit();
        try first.watchSignal(.hangup, &tag);
    }
    var second = try EvPort.init(std.testing.allocator);
    defer second.deinit();
    try second.watchSignal(.hangup, &tag);
}

test "signal_epoll: re-watching replaces the udata" {
    const guard = MaskGuard.set(std.posix.SIG.BLOCK, &.{.hangup});
    defer guard.restore();
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var a: u8 = 0;
    var b: u8 = 0;
    try port.watchSignal(.hangup, &a);
    try port.watchSignal(.hangup, &b);
    try raiseInThread(.hangup);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expectEqual(@as(?Signal, .hangup), events[0].signal);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &b));
    port.unwatchSignal(.hangup);
}

test "signal_epoll: a full buffer leaves other signals for the next wait" {
    const guard = MaskGuard.set(std.posix.SIG.BLOCK, &.{ .hangup, .user2 });
    defer guard.restore();
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var hup: u8 = 0;
    var usr2: u8 = 0;
    try port.watchSignal(.hangup, &hup);
    try port.watchSignal(.user2, &usr2);
    try raiseInThread(.hangup);
    try raiseInThread(.user2);

    var seen = SignalSet{};
    var one: [1]Event = undefined;
    for (0..2) |_| {
        try std.testing.expectEqual(@as(usize, 1), try port.wait(&one, 1000));
        const sig = one[0].signal.?;
        try std.testing.expect(!seen.contains(sig));
        try std.testing.expectEqual(@as(u32, 1), one[0].fired);
        const want: *u8 = if (sig == .hangup) &hup else &usr2;
        try std.testing.expect(one[0].udata == @as(?*anyopaque, want));
        seen.insert(sig);
    }
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&one, 0));
    // The narrowed mask was restored: both signals still arrive.
    try raiseInThread(.user2);
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&one, 1000));
    try std.testing.expectEqual(@as(?Signal, .user2), one[0].signal);
    port.unwatchSignal(.hangup);
    port.unwatchSignal(.user2);
}

test "signal_epoll: ports on other threads contend for one owner" {
    const guard = MaskGuard.set(std.posix.SIG.BLOCK, &.{.hangup});
    defer guard.restore();
    const Racer = struct {
        won: std.atomic.Value(u32) = .init(0),
        refused: std.atomic.Value(u32) = .init(0),

        fn run(self: *@This(), done: *std.Thread.ResetEvent, release_: *std.Thread.ResetEvent) void {
            var port = EvPort.init(std.heap.page_allocator) catch {
                done.set();
                return;
            };
            defer port.deinit();
            // The thread inherited the blocked mask from its creator.
            port.watchSignal(.hangup, null) catch |err| {
                if (err == error.SignalInUse) _ = self.refused.fetchAdd(1, .monotonic);
                done.set();
                return;
            };
            _ = self.won.fetchAdd(1, .monotonic);
            done.set();
            release_.wait();
        }
    };
    var racer: Racer = .{};
    var done: [4]std.Thread.ResetEvent = .{ .{}, .{}, .{}, .{} };
    var release_: std.Thread.ResetEvent = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads, &done) |*t, *d| t.* = try std.Thread.spawn(.{}, Racer.run, .{ &racer, d, &release_ });
    for (&done) |*d| d.wait();
    try std.testing.expectEqual(@as(u32, 1), racer.won.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), racer.refused.load(.monotonic));
    release_.set();
    for (threads) |t| t.join();
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    try port.watchSignal(.hangup, null);
}
