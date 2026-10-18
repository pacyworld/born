//! Signals on kqueue (EVFILT_SIGNAL). Owned by born#15: this file plus the
//! EvPort.watchSignal/unwatchSignal bodies in evport_kqueue.zig.
//!
//! `watch` attaches EVFILT_SIGNAL (EV_ADD | EV_CLEAR) with one immediate,
//! non-blocking kevent() call, then sets the disposition to SIG_IGN so the
//! default action (usually terminate) cannot run. EVFILT_SIGNAL records
//! deliveries even for ignored signals; wait() reports them as
//! Event{ .signal, .fired = deliveries since the last report, .udata }.
//! `unwatch` restores the saved disposition, then deletes the filter the
//! same way. `State.deinit` restores every disposition the port changed.
//!
//! Watch and unwatch are the one exception to staging changes into wait():
//! they are one-time setup calls, and a staged add would leave a gap until
//! the next wait() in which an ignored signal is discarded with nothing
//! recording it. Descriptor, timer and every hot-path registration stay
//! staged. libevent's kqueue backend does the same (kq_sig_add, kq_sig_del).
//!
//! Dispositions are process-wide, so is ownership: at most one port in the
//! process watches a given signal. A second port gets error.SignalInUse
//! until the first unwatches it or is deinitialized. The owner table is
//! keyed by the port's kqueue descriptor, which is unique while the port
//! is open and survives the port being moved.
//!
//! On macOS only process-directed signals (kill(2), external senders such
//! as the terminal or launchd) reach a watch; a thread-directed raise(3) or
//! pthread_kill(3) is ignored there without an event. FreeBSD reports both.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const kq = @import("evport_kqueue.zig");
const EvPort = kq.EvPort;
const Kevent = kq.Kevent;
const SignalError = kq.SignalError;
const Signal = kq.Signal;

const EV = posix.system.EV;
// Zig 0.15 omits ERROR on NetBSD (sys/event.h).
const EV_ERROR = if (@hasDecl(EV, "ERROR")) EV.ERROR else 0x4000;

fn ignore() posix.Sigaction {
    return .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
}

/// A process-wide watch: the owning port's kqueue and the disposition
/// `watch` replaced.
const Owner = struct { kq: c_int, prior: posix.Sigaction };

var owners: std.EnumArray(Signal, ?Owner) = .initFill(null);
var owners_lock: std.Thread.Mutex = .{};

/// Per-port watch bookkeeping, a field of EvPort (`signals`).
pub const State = struct {
    /// Signals this port watches.
    watched: std.EnumSet(Signal) = .initEmpty(),
    /// Unwatched signals whose immediate delete failed, so their filter may
    /// still deliver. `observe` drops those deliveries; a staged delete
    /// retries the removal.
    stale: std.EnumSet(Signal) = .initEmpty(),

    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Restores every disposition the port changed. The filters need no
    /// delete: closing the kqueue removes them.
    pub fn deinit(self: *State, port: *EvPort) void {
        var it = self.watched.iterator();
        while (it.next()) |sig| release(port, sig);
        self.* = .{};
    }
};

/// Re-watching a signal the port already watches only replaces udata.
pub fn watch(port: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
    owners_lock.lock();
    defer owners_lock.unlock();
    const owner = owners.getPtr(sig);
    if (owner.*) |o| {
        if (o.kq != port.kq) return SignalError.SignalInUse;
    }
    // Attach before ignoring, so every delivery after `watch` returns is
    // recorded and none runs the default action. On failure the
    // disposition is untouched.
    if (apply(port, change(sig, EV.ADD | EV.CLEAR, udata)) != .SUCCESS) return SignalError.SystemResources;
    // Staged changes for this signal predate the attach and must not undo it.
    purgeStaged(port, sig);
    if (owner.* == null) {
        const ign = ignore();
        var prior: posix.Sigaction = undefined;
        posix.sigaction(sig.toPosix(), &ign, &prior);
        owner.* = .{ .kq = port.kq, .prior = prior };
    }
    port.signals.watched.insert(sig);
    port.signals.stale.remove(sig);
}

/// Stop watching `sig` and restore the disposition `watch` replaced.
/// A signal this port does not watch is a no-op.
pub fn unwatch(port: *EvPort, sig: Signal) void {
    if (!port.signals.watched.contains(sig)) return;
    port.signals.watched.remove(sig);
    // Restore first: a delivery before the delete is recorded by the filter
    // instead of running the default action.
    release(port, sig);
    purgeStaged(port, sig);
    switch (apply(port, change(sig, EV.DELETE, null))) {
        .SUCCESS, .NOENT => {},
        else => {
            // Retry through the changelist; wait() reports a failure of
            // that delete as an error event, or a stage failure as
            // OutOfMemory.
            port.signals.stale.insert(sig);
            port.stageRaw(change(sig, EV.DELETE, null));
        },
    }
}

/// Sees each EVFILT_SIGNAL kevent first; false suppresses it.
pub fn observe(port: *EvPort, kev: Kevent) bool {
    const sig = Signal.fromPosix(kev.ident) orelse return true; // translate reports it
    if (port.signals.watched.contains(sig)) return true;
    if (kev.flags & EV_ERROR != 0) {
        // A retried delete for a filter that is already gone is expected.
        return kev.data != @intFromEnum(posix.E.NOENT);
    }
    // A late delivery from a filter whose delete is still pending.
    return !port.signals.stale.contains(sig);
}

/// kqueue needs no blocked mask: EVFILT_SIGNAL records deliveries under any
/// disposition. A documented no-op so portable programs call it always.
pub fn blockSignals(sigs: []const Signal) SignalError!void {
    _ = sigs;
}

/// Restores the saved disposition and gives up ownership, if this port
/// owns `sig`.
fn release(port: *EvPort, sig: Signal) void {
    owners_lock.lock();
    defer owners_lock.unlock();
    const owner = owners.getPtr(sig);
    const o = owner.* orelse return;
    if (o.kq != port.kq) return;
    posix.sigaction(sig.toPosix(), &o.prior, null);
    owner.* = null;
}

// NetBSD's 40-byte kevent ABI is __kevent50 with size_t counts (see
// evport_kqueue.zig).
const netbsd = struct {
    extern "c" fn __kevent50(
        kq: c_int,
        changelist: [*]const Kevent,
        nchanges: usize,
        eventlist: ?[*]Kevent,
        nevents: usize,
        timeout: ?*const std.c.timespec,
    ) c_int;
};

/// Applies one change now: kevent() with no eventlist and a zero timeout,
/// so it neither waits nor harvests. Returns the change's errno.
fn apply(port: *EvPort, kev: Kevent) posix.E {
    const one = [1]Kevent{kev};
    const zero: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = if (builtin.os.tag == .netbsd)
            netbsd.__kevent50(port.kq, &one, 1, null, 0, &zero)
        else
            std.c.kevent(port.kq, &one, 1, undefined, 0, &zero);
        if (rc >= 0) return .SUCCESS;
        const e = posix.errno(@as(isize, rc));
        if (e != .INTR) return e;
    }
}

/// Drops staged, unflushed changes for `sig`'s filter.
fn purgeStaged(port: *EvPort, sig: Signal) void {
    const ident: usize = sig.toPosix();
    var i: usize = 0;
    while (i < port.changes.items.len) {
        const kev = port.changes.items[i];
        if (kev.ident == ident and kev.filter == kq.EVFILT_SIGNAL) {
            _ = port.changes.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn change(sig: Signal, flags: @FieldType(Kevent, "flags"), udata: ?*anyopaque) Kevent {
    var kev = std.mem.zeroes(Kevent);
    kev.ident = sig.toPosix();
    kev.filter = kq.EVFILT_SIGNAL;
    kev.flags = flags;
    kev.udata = @intFromPtr(udata);
    return kev;
}

// --------------------------------------------------------------- tests ----

fn disposition(sig: Signal) posix.Sigaction {
    var now: posix.Sigaction = undefined;
    posix.sigaction(sig.toPosix(), null, &now);
    return now;
}

/// Process-directed: macOS EVFILT_SIGNAL does not see a thread-directed raise(3).
fn send(sig: Signal) !void {
    try posix.kill(std.c.getpid(), sig.toPosix());
}

test "signal_kqueue: watch and unwatch stage nothing" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    const staged = port.changes.items.len;
    try watch(&port, .user1, &tag);
    try std.testing.expectEqual(staged, port.changes.items.len);
    unwatch(&port, .user1);
    try std.testing.expectEqual(staged, port.changes.items.len);
}

test "signal_kqueue: unwatch then watch before a wait stays attached" {
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    var other: u8 = 2;
    try watch(&port, .user1, &tag);
    unwatch(&port, .user1);
    try watch(&port, .user1, &other);
    try send(.user1);
    var events: [4]kq.Event = undefined;
    var n: usize = 0;
    while (n == 0) n = try port.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?Signal, .user1), events[0].signal);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &other));
    unwatch(&port, .user1);
}

test "signal_kqueue: re-watch keeps the saved disposition" {
    const before = disposition(.user2);
    var port = try EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tag: u8 = 1;
    try watch(&port, .user2, &tag);
    try watch(&port, .user2, &tag);
    unwatch(&port, .user2);
    try std.testing.expect(disposition(.user2).handler.handler == before.handler.handler);
}

test "signal_kqueue: deinit restores every disposition and frees ownership" {
    const before = disposition(.hangup);
    var port = try EvPort.init(std.testing.allocator);
    var tag: u8 = 1;
    try watch(&port, .hangup, &tag);
    try std.testing.expect(disposition(.hangup).handler.handler == posix.SIG.IGN);
    port.deinit();
    try std.testing.expect(disposition(.hangup).handler.handler == before.handler.handler);
    var other = try EvPort.init(std.testing.allocator);
    defer other.deinit();
    try watch(&other, .hangup, &tag);
}
