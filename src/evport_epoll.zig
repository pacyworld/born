//! Linux event port backed by epoll and eventfd.
//!
//! Socket read interest is persistent and edge-triggered with EPOLLIN,
//! EPOLLET, and EPOLLRDHUP. Handlers must fully drain readable data, and
//! EPOLLRDHUP reports half-close as an event.
//!
//! Write interest is on-demand EPOLLOUT, armed by wantWrite and disarmed by
//! cancelWrite when the output queue drains. EPOLLET applies to the whole
//! descriptor registration, so EPOLLOUT is also edge-triggered when read
//! interest is armed. A still-writable socket therefore produces no second
//! writable event after connect. Stream writers must attempt to write first
//! and wait for write interest only after an actual EAGAIN. EPOLLONESHOT is
//! unsuitable because it disarms the whole registration, including persistent
//! read interest.
//!
//! Registrations apply immediately through epoll_ctl; there is no staged
//! changelist. A rejected registration, such as EBADF for a dead descriptor,
//! is stashed and returned as error.RegisterFailed from the next non-empty
//! wait instead of becoming a silent no-op.
//!
//! epoll_ctl returns EPERM for descriptors with no poll implementation,
//! including regular files, character devices such as /dev/null, and
//! directories. Their I/O never blocks, so they become pseudo registrations:
//! they stay out of the kernel set and every wait reports them ready, matching
//! kqueue. EPERM from the add operation performs the classification, so no
//! descriptor-type list is needed.
//!
//! eventfd provides cross-thread wakeup. purgeFd drops only the port's
//! bookkeeping; closing a descriptor removes its kernel registration.
//!
//! timer_epoll.zig, signal_epoll.zig, and process_epoll.zig each own at most
//! one timerfd, signalfd, or inner process epoll set per port. These internal
//! sources are level-triggered and use kind sentinels as epoll data. wait hands
//! a ready source to its harvest function, which drains it into events. A
//! source left ready because the caller's buffer filled is reported again by
//! the next wait, so nothing is dropped.

const std = @import("std");
const linux = std.os.linux;
const compat = @import("compat");
const types = @import("types.zig");
const timer_epoll = @import("timer_epoll.zig");
const signal_epoll = @import("signal_epoll.zig");
const process_epoll = @import("process_epoll.zig");

pub const Handle = types.Handle;
pub const Event = types.Event;
pub const Signal = types.Signal;
pub const TimerMode = types.TimerMode;

pub const InitError = error{InitFailed};
/// RegisterFailed and OutOfMemory are stashed registration failures;
/// SourceFailed is an internal source (timerfd, signalfd, the process set)
/// that could not be harvested or re-armed.
pub const WaitError = error{ WaitFailed, RegisterFailed, SourceFailed, OutOfMemory };
pub const TimerError = types.TimerError;
pub const SignalError = types.SignalError;
/// Errors returned by process-watch operations.
pub const ProcessError = types.ProcessError;
/// Every error this backend can return.
pub const Error = InitError || WaitError || TimerError || SignalError || ProcessError;

/// Block `sigs` in the calling thread; signalfd only sees blocked signals.
/// Call it in `main` before spawning threads; see signal_epoll.zig.
pub const blockSignals = signal_epoll.blockSignals;

/// Internal source kinds; each owns one slot in EvPort.internal.
pub const InternalKind = enum {
    /// timerfd deadline source.
    timer,
    /// signalfd signal source.
    signal,
    /// Inner epoll set of pidfds.
    process,
};

/// Stable addresses used as epoll data for internal sources, one per kind.
/// They cannot collide with a caller's udata, which never points here.
var internal_tags: [compat.enumFields(InternalKind).len]u8 = @splat(0);

fn internalKind(data: usize) ?InternalKind {
    const base = @intFromPtr(&internal_tags);
    if (data < base or data >= base + internal_tags.len) return null;
    return @enumFromInt(data - base);
}

/// Events a harvest may write at position `out` while `pending` kernel
/// events after it still need a slot each. Always at least 1, because
/// epoll_wait returned no more events than the buffer holds.
fn harvestRoom(len: usize, out: usize, pending: usize) usize {
    return len - out - pending;
}

/// Stable address used as the wake eventfd's udata tag.
var wake_sentinel: u8 = 0;

const READ_MASK: u32 = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP;
const WRITE_MASK: u32 = linux.EPOLL.OUT;

const FdState = struct {
    udata: ?*anyopaque = null,
    read: bool = false,
    write: bool = false, // EPOLLOUT currently in the mask
    /// Unpollable descriptor: tracked in the map only, never in epoll. Its
    /// I/O never blocks, so wait reports it ready on every call, matching
    /// kqueue's observable behavior.
    pseudo: bool = false,
};

/// An epoll event port with immediate kernel registrations and always-ready
/// pseudo registrations for descriptors that epoll cannot poll.
pub const EvPort = struct {
    ep: i32 = -1,
    alloc: std.mem.Allocator,
    wake_fd: i32 = -1,
    fds: std.AutoHashMapUnmanaged(i32, FdState) = .empty,
    /// Stashed registration failure (the IOCP backend's shape): a rejected
    /// epoll_ctl or an allocation failure is returned by the next non-empty
    /// wait() instead of being dropped on the floor.
    pending_error: ?WaitError = null,
    /// Live pseudo registrations: wait() must not block while any exist.
    pseudo_count: usize = 0,
    /// Internal source fd per kind, -1 when absent. The fd is owned by the
    /// kind's module, which closes it after removeInternal.
    internal: [compat.enumFields(InternalKind).len]i32 = @splat(-1),
    /// Timer bookkeeping, owned by timer_epoll.zig.
    timers: timer_epoll.State = .{},
    /// Signal-watch bookkeeping, owned by signal_epoll.zig.
    signals: signal_epoll.State = .{},
    /// Process-watch bookkeeping, owned by process_epoll.zig.
    processes: process_epoll.State = .{},

    /// Create an epoll instance and eventfd, using `alloc` for port bookkeeping.
    /// The wake registration is part of init: if it fails, init fails with
    /// everything released instead of returning a port without a wake source.
    pub fn init(alloc: std.mem.Allocator) InitError!EvPort {
        // Raw linux syscalls do not set libc errno; decode the return value
        // itself. std.posix.errno() would read libc's thread-local errno in
        // this libc-linked binary and report SUCCESS for failed syscalls.
        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (compat.linuxErrno(ep_rc) != .SUCCESS) return InitError.InitFailed;
        const ep: i32 = @intCast(ep_rc);
        errdefer compat.close(ep);

        const wfd_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (compat.linuxErrno(wfd_rc) != .SUCCESS) return InitError.InitFailed;
        const wfd: i32 = @intCast(wfd_rc);
        errdefer compat.close(wfd);

        var self = EvPort{
            .ep = ep,
            .alloc = alloc,
            .wake_fd = wfd,
            .timers = timer_epoll.State.init(alloc),
            .signals = signal_epoll.State.init(alloc),
        };
        self.register(wfd, true, false, @as(?*anyopaque, &wake_sentinel));
        if (self.pending_error != null) {
            // The wake source is unregistered: a port without reliable
            // cross-thread wakeup must not escape init. Free the bookkeeping;
            // the errdefers close ep and wfd.
            self.fds.deinit(alloc);
            return InitError.InitFailed;
        }
        return self;
    }

    /// Release port-owned internal sources, descriptors, and bookkeeping.
    /// Caller-owned `Child.handle` values stay open, and child lifetime and
    /// final reaping remain the caller's responsibility.
    pub fn deinit(self: *EvPort) void {
        self.signals.deinit(self);
        self.timers.deinit(self);
        self.processes.deinit(self);
        if (self.ep >= 0) compat.close(self.ep);
        if (self.wake_fd >= 0) compat.close(self.wake_fd);
        self.ep = -1;
        self.wake_fd = -1;
        self.fds.deinit(self.alloc);
    }

    // ------------------------------------------------------- interest ----

    /// Persistent edge-triggered read interest.
    pub fn monitorRead(self: *EvPort, fd: Handle, udata: ?*anyopaque) void {
        var st = self.fds.get(fd) orelse FdState{};
        st.read = true;
        st.udata = udata;
        self.apply(fd, st);
    }

    /// Arm write interest (connect completion / send-buffer space).
    /// No-op while already armed.
    pub fn wantWrite(self: *EvPort, fd: Handle, udata: ?*anyopaque) void {
        var st = self.fds.get(fd) orelse FdState{};
        if (st.write) return;
        st.write = true;
        st.udata = udata;
        self.apply(fd, st);
    }

    /// Disarm write interest on an fd that STAYS OPEN.
    pub fn cancelWrite(self: *EvPort, fd: Handle) void {
        var st = self.fds.get(fd) orelse return;
        if (!st.write) return;
        st.write = false;
        self.apply(fd, st);
    }

    /// Drop read interest on an fd that STAYS OPEN (e.g. stdin after EOF).
    pub fn unmonitorRead(self: *EvPort, fd: Handle) void {
        var st = self.fds.get(fd) orelse return;
        if (!st.read) return;
        st.read = false;
        self.apply(fd, st);
    }

    /// The fd is being closed: drop the port's bookkeeping (the kernel
    /// removes the registration on close(2) itself). A pidfd's process
    /// watch ends here too.
    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        process_epoll.purge(self, fd);
        const kv = self.fds.fetchRemove(fd) orelse return;
        if (kv.value.pseudo) self.pseudo_count -= 1;
    }

    /// Wake a wait() blocked in another thread.
    pub fn wake(self: *EvPort) void {
        const one: u64 = 1;
        _ = compat.write(self.wake_fd, std.mem.asBytes(&one)) catch {};
    }

    /// Arm a timer. `id` is caller-chosen and unique per port; re-adding a
    /// live id replaces it. Timers are deadlines, never I/O drivers.
    pub fn addTimer(self: *EvPort, id: u32, udata: ?*anyopaque, after_ms: u32, mode: TimerMode) TimerError!void {
        return timer_epoll.add(self, id, udata, after_ms, mode);
    }

    /// Disarm a timer. Unknown or already-expired ids are a no-op.
    pub fn cancelTimer(self: *EvPort, id: u32) void {
        timer_epoll.cancel(self, id);
    }

    /// Deliver `sig` as Event.signal. Process-wide: one port per signal.
    /// The signal must already be blocked (`blockSignals`).
    pub fn watchSignal(self: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
        return signal_epoll.watch(self, sig, udata);
    }

    /// Stop watching `sig`. Unwatched signals are a no-op.
    pub fn unwatchSignal(self: *EvPort, sig: Signal) void {
        signal_epoll.unwatch(self, sig);
    }

    /// Deliver one exit event for the child behind `handle`, a pidfd. A
    /// signal-0 probe rejects non-pidfds immediately. Successful harvest reaps
    /// the child and ends the watch. Uncollectable status instead produces an
    /// error event with `exit=null`. See process_epoll.zig.
    pub fn watchProcess(self: *EvPort, handle: Handle, udata: ?*anyopaque) ProcessError!void {
        return process_epoll.watch(self, handle, udata);
    }

    /// End a process watch on a pidfd that stays open. Unwatched handles are a
    /// no-op; before closing, `purgeFd` is enough. A removal failure is
    /// deferred as `error.RegisterFailed` from the next non-empty `wait()`.
    pub fn unwatchProcess(self: *EvPort, handle: Handle) void {
        process_epoll.unwatch(self, handle);
    }

    /// Internal hook: register `fd` as the port's `kind` source,
    /// level-triggered EPOLLIN. One source per kind.
    pub fn addInternal(self: *EvPort, kind: InternalKind, fd: i32) error{ InvalidArgument, SystemResources }!void {
        const slot = &self.internal[@intFromEnum(kind)];
        if (slot.* != -1 or fd < 0) return error.InvalidArgument;
        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(&internal_tags[@intFromEnum(kind)]) },
        };
        if (compat.linuxErrno(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS)
            return error.SystemResources;
        slot.* = fd;
    }

    /// Internal hook: drop the `kind` source before its owner closes the fd.
    /// A refused CTL_DEL is stashed as error.SourceFailed for the next wait,
    /// unless an earlier error is already pending.
    pub fn removeInternal(self: *EvPort, kind: InternalKind) void {
        const slot = &self.internal[@intFromEnum(kind)];
        if (slot.* == -1) return;
        if (compat.linuxErrno(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_DEL, slot.*, null)) != .SUCCESS and
            self.pending_error == null)
        {
            self.pending_error = WaitError.SourceFailed;
        }
        slot.* = -1;
    }

    /// The fd registered for `kind`, or null.
    pub fn internalFd(self: *const EvPort, kind: InternalKind) ?i32 {
        const fd = self.internal[@intFromEnum(kind)];
        return if (fd == -1) null else fd;
    }

    /// Apply the descriptor's computed mask with ADD, MOD, DEL, or a pseudo
    /// registration as needed.
    ///
    /// epoll_ctl returns EPERM for a descriptor it cannot poll. I/O on these
    /// descriptors never blocks, so they become pseudo registrations tracked
    /// only in the map and reported ready by every wait, matching kqueue's
    /// observable behavior.
    ///
    /// EPERM from ADD classifies these descriptors directly. The kernel is the
    /// authority on what it cannot poll, covering character devices and
    /// directories as well as regular files without a descriptor-type list or
    /// an extra syscall.
    ///
    /// The map slot is reserved before any kernel call so a successful
    /// registration cannot be lost to a later allocation failure. An untracked
    /// live registration would turn the next apply into a CTL_ADD that hits
    /// EEXIST and strands the descriptor. Any other failure, whether allocation
    /// failure before the syscall or an epoll_ctl rejection such as EBADF, is
    /// stashed in pending_error.
    ///
    /// A failed CTL_MOD keeps the prior bookkeeping while the kernel
    /// registration stays live (EBADF, EINVAL, ENOMEM, EPERM): the old state
    /// still mirrors it and a later apply retries MOD rather than CTL_ADD into
    /// EEXIST. ENOENT is the exception: the kernel has no registration for the
    /// fd, because every descriptor for the old open file description was
    /// closed without purgeFd and the number was reused. The stale entry is
    /// dropped and the descriptor re-ADDed in the same call.
    ///
    /// An empty mask drops the bookkeeping whatever CTL_DEL returns, since no
    /// later call could address the entry. ENOENT already matches the
    /// requested state. Any other refusal, typically EBADF after a close
    /// without purgeFd while a dup keeps the registration live, is stashed.
    fn apply(self: *EvPort, fd: Handle, st: FdState) void {
        if (!st.read and !st.write) {
            if (self.fds.getPtr(fd)) |cur| {
                if (cur.pseudo) {
                    self.pseudo_count -= 1;
                } else switch (compat.linuxErrno(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_DEL, fd, null))) {
                    .SUCCESS, .NOENT => {},
                    else => self.pending_error = WaitError.RegisterFailed,
                }
                _ = self.fds.remove(fd);
            }
            return;
        }
        if (self.fds.getPtr(fd)) |cur| {
            if (cur.pseudo) {
                cur.* = st;
                return;
            }
            var ev = makeEvent(st);
            switch (compat.linuxErrno(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_MOD, fd, &ev))) {
                .SUCCESS => {
                    cur.* = st;
                    return;
                },
                // No live registration: drop the stale entry and re-ADD below.
                .NOENT => _ = self.fds.remove(fd),
                // Prior registration still live; keep bookkeeping for a MOD retry.
                else => {
                    self.pending_error = WaitError.RegisterFailed;
                    return;
                },
            }
        }
        self.addRegistration(fd, st);
    }

    /// Reserve the map slot, then CTL_ADD (reserve rationale in `apply`).
    fn addRegistration(self: *EvPort, fd: Handle, st: FdState) void {
        const gop = self.fds.getOrPut(self.alloc, fd) catch {
            self.pending_error = WaitError.OutOfMemory;
            return;
        };
        gop.value_ptr.* = st;
        var ev = makeEvent(st);
        switch (compat.linuxErrno(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_ADD, fd, &ev))) {
            .SUCCESS => {},
            // "I cannot poll this": the pseudo registration above.
            .PERM => {
                gop.value_ptr.pseudo = true;
                self.pseudo_count += 1;
            },
            // Anything else (EBADF for a dead descriptor, ENOMEM, ...)
            // is a real rejection and must reach the caller.
            else => {
                _ = self.fds.remove(fd);
                self.pending_error = WaitError.RegisterFailed;
            },
        }
    }

    fn makeEvent(st: FdState) linux.epoll_event {
        var mask: u32 = 0;
        if (st.read) mask |= READ_MASK;
        if (st.write) mask |= WRITE_MASK;
        return .{
            .events = mask,
            .data = .{ .ptr = @intFromPtr(st.udata) },
        };
    }

    /// register is apply for init (fd not yet tracked).
    fn register(self: *EvPort, fd: Handle, read: bool, write: bool, udata: ?*anyopaque) void {
        self.apply(fd, .{ .udata = udata, .read = read, .write = write });
    }

    // ------------------------------------------------------------ wait ----

    /// Harvest events in one epoll_wait call. `timeout_ms` must be null or
    /// nonnegative. null blocks until an event, zero harvests without blocking,
    /// and positive values wait that many milliseconds. A stashed registration
    /// failure is reported here once, ahead of the syscall. An empty wait
    /// neither consumes nor reports it. Pseudo registrations for unpollable
    /// descriptors are always ready: while any exist the syscall never blocks,
    /// and they fill whatever space the kernel left. A ready internal source
    /// goes to its kind's harvest, which may emit several events or none, so
    /// wait can return zero before its timeout.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) WaitError!usize {
        if (events.len == 0) return 0;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        var ebuf: [64]linux.epoll_event = undefined;
        const cap = @min(events.len, ebuf.len);
        const timeout: i32 = if (self.pseudo_count == 0) timeout_ms orelse -1 else 0;

        const n_rc = linux.epoll_wait(self.ep, &ebuf, @intCast(cap), timeout);
        const n_err = compat.linuxErrno(n_rc);
        if (n_err != .SUCCESS) {
            if (n_err == .INTR) return 0;
            return WaitError.WaitFailed;
        }

        const n: usize = @intCast(n_rc);
        var out: usize = 0;
        var woke = false;
        for (ebuf[0..n], 0..) |eev, i| {
            if (eev.data.ptr == @intFromPtr(&wake_sentinel)) {
                if (!woke) {
                    woke = true;
                    self.drainWake();
                    events[out] = .{ .wake = true };
                    out += 1;
                }
                continue;
            }
            if (internalKind(eev.data.ptr)) |kind| {
                const room = events[out..][0..harvestRoom(events.len, out, n - i - 1)];
                out += switch (kind) {
                    .timer => timer_epoll.harvest(self, room),
                    .signal => signal_epoll.harvest(self, room),
                    .process => process_epoll.harvest(self, room),
                };
                continue;
            }
            const udata: ?*anyopaque = @ptrFromInt(eev.data.ptr);
            events[out] = .{
                .udata = udata,
                .readable = (eev.events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP)) != 0,
                .writable = (eev.events & (linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0,
                .eof = (eev.events & (linux.EPOLL.RDHUP | linux.EPOLL.HUP)) != 0,
                .err = (eev.events & linux.EPOLL.ERR) != 0,
            };
            out += 1;
        }
        if (self.pseudo_count != 0) {
            var it = self.fds.iterator();
            while (out < cap) {
                const entry = it.next() orelse break;
                const st = entry.value_ptr;
                if (!st.pseudo) continue;
                events[out] = .{
                    .udata = st.udata,
                    .readable = st.read,
                    .writable = st.write,
                };
                out += 1;
            }
        }
        return out;
    }

    fn drainWake(self: *EvPort) void {
        var tmp: [8]u8 = undefined;
        while (true) {
            _ = compat.read(self.wake_fd, &tmp) catch break;
        }
    }
};

// --------------------------------------------------------------- tests ----

test "epoll: socket read readiness + ET edge semantics" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);

    var tag: u8 = 1;
    evp.monitorRead(fds[0], &tag);
    _ = try compat.write(fds[1], "ab");

    var events: [8]Event = undefined;
    const n = try evp.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));

    // ET: full drain -> silence until a new edge.
    var buf: [4]u8 = undefined;
    while (true) {
        _ = compat.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));

    _ = try compat.write(fds[1], "c");
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
}

test "epoll: write interest arms and disarms" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);

    var tag: u8 = 2;
    evp.wantWrite(fds[1], &tag);

    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].writable);

    // Level-triggered: still armed, so a second wait re-reports writability.
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
    // Disarm: silence.
    evp.cancelWrite(fds[1]);
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: peer close delivers eof" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
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

test "epoll: wake posts a single coalesced event" {
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
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: regular file is an always-ready pseudo registration" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var path_buffer: [160:0]u8 = undefined;
    const stamp = try compat.monotonicNs();
    const printed = try std.fmt.bufPrint(
        &path_buffer,
        "born-epoll-pseudo-{d}-{d}",
        .{ std.c.getpid(), stamp },
    );
    path_buffer[printed.len] = 0;
    const path = path_buffer[0..printed.len :0];
    const file = try compat.open(path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
    }, 0o600);
    defer compat.close(file);
    defer compat.unlink(path) catch {};

    // epoll_ctl would refuse this fd with EPERM; born keeps it out of the
    // kernel set and answers readiness itself, matching kqueue.
    var tag: u8 = 5;
    evp.monitorRead(file, &tag);
    try std.testing.expect(evp.fds.get(file).?.pseudo);
    try std.testing.expectEqual(@as(usize, 1), evp.pseudo_count);
    evp.wantWrite(file, &tag);

    var events: [8]Event = undefined;
    const n = try evp.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?*anyopaque, &tag), events[0].udata);
    try std.testing.expect(events[0].readable and events[0].writable);
    try std.testing.expect(!events[0].err and !events[0].eof);

    // Always ready: a second, non-blocking wait repeats the report.
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
    try std.testing.expect(events[0].readable and events[0].writable);

    // Interest changes touch the map only; birth and death leave no kernel
    // residue behind.
    evp.unmonitorRead(file);
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
    try std.testing.expect(events[0].writable and !events[0].readable);
    evp.purgeFd(file);
    try std.testing.expectEqual(@as(usize, 0), evp.pseudo_count);
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: unpollable descriptors other than regular files are pseudo too" {
    // epoll_ctl answers EPERM for character devices and directories just as
    // it does for regular files. Classifying on EPERM rather than on a
    // descriptor-type test is what keeps these working: `prog < /dev/null`
    // is an ordinary way to launch a service.
    const alloc = std.testing.allocator;

    const cases = [_][]const u8{ "/dev/null", "/dev/zero" };
    for (cases) |path| {
        var evp = try EvPort.init(alloc);
        defer evp.deinit();
        const f = try compat.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        defer compat.close(f);

        var tag: u8 = 7;
        evp.monitorRead(f, &tag);

        var events: [4]Event = undefined;
        // No pending_error: the descriptor was accepted, not rejected.
        try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
        try std.testing.expect(evp.fds.get(f).?.pseudo);
        try std.testing.expectEqual(@as(usize, 1), evp.pseudo_count);
        try std.testing.expect(events[0].readable);
        try std.testing.expect(!events[0].err);
    }

    // A directory opened for reading is refused the same way. An O_PATH
    // directory fd is refused with EBADF instead and must remain a hard
    // error, so classification keys on EPERM rather than treating every
    // epoll_ctl rejection as unpollable.
    var evp = try EvPort.init(alloc);
    defer evp.deinit();
    const dfd = try compat.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer compat.close(dfd);

    var tag: u8 = 8;
    evp.monitorRead(dfd, &tag);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
    try std.testing.expect(evp.fds.get(dfd).?.pseudo);
    try std.testing.expect(events[0].readable and !events[0].err);
}

test "epoll: rejected descriptor is reported by the next wait, never half-recorded" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var events: [8]Event = undefined;
    var tag: u8 = 6;
    // epoll_ctl rejects this with EBADF, which is NOT EPERM and so must
    // surface rather than becoming a pseudo registration. Deliberately an
    // out-of-range fd, not dup+close: the Linuxulator accepts recycled fd
    // numbers.
    const bogus: Handle = 1 << 20;
    evp.monitorRead(bogus, &tag);
    try std.testing.expect(!evp.fds.contains(bogus));
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&empty, null));
    try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
    // Reported exactly once, and a retry reports the same rejection. There
    // is no half-recorded state to trip over.
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
    evp.wantWrite(bogus, &tag);
    try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
    try std.testing.expect(!evp.fds.contains(bogus));
}

test "epoll: failed CTL_MOD keeps prior bookkeeping so a retry re-mods" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);

    var tag: u8 = 9;
    evp.monitorRead(fds[0], &tag);
    try std.testing.expect(evp.fds.get(fds[0]).?.read);

    // epoll(7): a registration is dropped only once every descriptor referring
    // to the underlying open file description is closed. dup keeps that
    // description, and the live registration, alive while the original fd
    // number turns invalid, so the next CTL_MOD fails with EBADF without
    // unregistering anything.
    const saved = try compat.dup(fds[0]);
    defer compat.close(saved);
    compat.close(fds[0]);

    evp.wantWrite(fds[0], &tag);
    // MOD failed: the prior bookkeeping must survive, mirroring the still-live
    // kernel registration (read armed, write not).
    try std.testing.expect(evp.fds.contains(fds[0]));
    const st = evp.fds.get(fds[0]).?;
    try std.testing.expect(st.read);
    try std.testing.expect(!st.write);

    var events: [8]Event = undefined;
    try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));

    // Restore the original fd number onto the same description. The kernel
    // registration was never removed, so the retry must CTL_MOD (not CTL_ADD
    // into EEXIST) and arm write interest.
    try compat.dup2(saved, fds[0]);
    evp.wantWrite(fds[0], &tag);
    try std.testing.expect(evp.fds.get(fds[0]).?.write);
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].writable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
}

test "epoll: CTL_MOD ENOENT drops stale bookkeeping and re-adds the reused fd" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[1]);

    // Allocate the replacement pair while fds[0] is still open so the kernel
    // cannot hand the soon-to-be-freed number to it.
    var fds2: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds2));
    defer compat.close(fds2[1]);

    var tag: u8 = 10;
    evp.monitorRead(fds[0], &tag);
    try std.testing.expect(evp.fds.get(fds[0]).?.read);

    // Close without purgeFd: the last descriptor of the open file description
    // is gone, so the kernel drops the registration while the bookkeeping
    // entry for the fd number survives.
    compat.close(fds[0]);

    // Reuse the number for the fresh description, which has no registration.
    try compat.dup2(fds2[0], fds[0]);
    compat.close(fds2[0]);
    defer compat.close(fds[0]);

    var tag2: u8 = 11;
    evp.monitorRead(fds[0], &tag2);
    // MOD hit ENOENT: the stale entry was dropped and the new descriptor
    // re-ADDed in the same call, so no error is stashed.
    try std.testing.expect(evp.fds.get(fds[0]).?.read);
    try std.testing.expect(evp.pending_error == null);

    _ = try compat.write(fds2[1], "x");
    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag2));
}

test "epoll: a refused CTL_DEL is reported by the next wait" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[1]);

    var tag: u8 = 12;
    evp.monitorRead(fds[0], &tag);

    // The dup keeps the description and its registration alive while the
    // fd number turns invalid, so CTL_DEL fails with EBADF.
    const saved = try compat.dup(fds[0]);
    defer compat.close(saved);
    compat.close(fds[0]);

    evp.unmonitorRead(fds[0]);
    // No later call could address the entry, so it is gone either way.
    try std.testing.expect(!evp.fds.contains(fds[0]));

    var events: [8]Event = undefined;
    try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: CTL_DEL ENOENT drops the entry without an error" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[1]);
    var fds2: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds2));
    defer compat.close(fds2[1]);

    var tag: u8 = 13;
    evp.monitorRead(fds[0], &tag);

    // Closing the only descriptor drops the kernel registration; reusing the
    // number for an unregistered description makes CTL_DEL return ENOENT.
    compat.close(fds[0]);
    try compat.dup2(fds2[0], fds[0]);
    compat.close(fds2[0]);
    defer compat.close(fds[0]);

    evp.unmonitorRead(fds[0]);
    try std.testing.expect(!evp.fds.contains(fds[0]));
    try std.testing.expect(evp.pending_error == null);

    _ = try compat.write(fds2[1], "x");
    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: a refused internal-source CTL_DEL is reported once, never overwriting" {
    var evp = try EvPort.init(std.testing.allocator);
    defer evp.deinit();
    var events: [4]Event = undefined;

    inline for (.{ false, true }) |earlier| {
        const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        try std.testing.expectEqual(linux.E.SUCCESS, compat.linuxErrno(rc));
        const fd: i32 = @intCast(rc);
        try evp.addInternal(.timer, fd);
        // Closing the only descriptor drops the registration, so the
        // remove's CTL_DEL fails with EBADF.
        compat.close(fd);
        if (earlier) evp.pending_error = WaitError.OutOfMemory;
        evp.removeInternal(.timer);
        try std.testing.expect(evp.internalFd(.timer) == null);
        const expected: WaitError = if (earlier) WaitError.OutOfMemory else WaitError.SourceFailed;
        try std.testing.expectError(expected, evp.wait(&events, 0));
        try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
    }
}

test "epoll: init fails when the wake registration cannot allocate" {
    // fail_index 0 lands inside init's wake-fd registration. Init must
    // fail, not construct a port whose wake source is unregistered.
    const before = try openFdCount();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(Error.InitFailed, EvPort.init(failing.allocator()));
    // Complete cleanup: no leaked bookkeeping, no leaked descriptors.
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expectEqual(before, try openFdCount());

    // A retry constructs a working port whose wake delivers an event.
    var evp = try EvPort.init(std.testing.allocator);
    defer evp.deinit();
    try std.testing.expect(evp.fds.contains(evp.wake_fd));
    evp.wake();
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].wake);
}

test "epoll: allocation failure after init is reported by the next wait, once" {
    var evp = try EvPort.init(std.testing.allocator);
    defer evp.deinit();
    try std.testing.expect(evp.fds.contains(evp.wake_fd));
    // Force the next registration to allocate: drop the map buffer and
    // switch to an allocator that fails on its first allocation. The
    // kernel wake registration stays live; only bookkeeping is dropped.
    evp.fds.clearAndFree(evp.alloc);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    evp.alloc = failing.allocator();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0, &fds));
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);
    evp.monitorRead(fds[0], null);
    try std.testing.expect(!evp.fds.contains(fds[0]));
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&empty, null));
    var events: [1]Event = undefined;
    try std.testing.expectError(Error.OutOfMemory, evp.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

/// Open descriptor count via /proc/self/fd, for init-cleanup assertions.
fn openFdCount() error{FdCountFailed}!usize {
    const rc = linux.open("/proc/self/fd", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (compat.linuxErrno(rc) != .SUCCESS) return error.FdCountFailed;
    const dir: i32 = @intCast(rc);
    defer compat.close(dir);
    var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    var count: usize = 0;
    while (true) {
        const n_rc = linux.getdents64(dir, &buf, buf.len);
        if (compat.linuxErrno(n_rc) != .SUCCESS) return error.FdCountFailed;
        const n: usize = @intCast(n_rc);
        if (n == 0) return count;
        var off: usize = 0;
        while (off < n) {
            const dent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            off += dent.reclen;
            count += 1;
        }
    }
}

test "epoll: non-blocking connect completes via write interest" {
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

test "epoll: internal source tags never match caller data" {
    var tag: u8 = 1;
    try std.testing.expect(internalKind(@intFromPtr(&tag)) == null);
    try std.testing.expect(internalKind(@intFromPtr(&wake_sentinel)) == null);
    try std.testing.expect(internalKind(0) == null);
    inline for (comptime compat.enumFields(InternalKind)) |field| {
        const kind: InternalKind = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?InternalKind, kind), internalKind(@intFromPtr(&internal_tags[field.value])));
    }
}

test "epoll: harvest room keeps a slot for every later kernel event" {
    // 8 slots, harvest at 2, 3 kernel events still to translate.
    try std.testing.expectEqual(@as(usize, 3), harvestRoom(8, 2, 3));
    // Worst case the kernel filled the buffer: exactly one slot each.
    try std.testing.expectEqual(@as(usize, 1), harvestRoom(4, 3, 0));
}

test "epoll: internal source table is one fd per kind" {
    var evp = try EvPort.init(std.testing.allocator);
    defer evp.deinit();
    const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, compat.linuxErrno(rc));
    const fd: i32 = @intCast(rc);
    defer compat.close(fd);

    try std.testing.expect(evp.internalFd(.timer) == null);
    try evp.addInternal(.timer, fd);
    try std.testing.expectEqual(@as(?i32, fd), evp.internalFd(.timer));
    try std.testing.expectError(error.InvalidArgument, evp.addInternal(.timer, fd));
    try std.testing.expectError(error.InvalidArgument, evp.addInternal(.signal, -1));
    // Not ready: the source is silent and is not a caller registration.
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
    try std.testing.expect(!evp.fds.contains(fd));

    evp.removeInternal(.timer);
    try std.testing.expect(evp.internalFd(.timer) == null);
    evp.removeInternal(.timer);
    try evp.addInternal(.timer, fd);
    evp.removeInternal(.timer);
}
