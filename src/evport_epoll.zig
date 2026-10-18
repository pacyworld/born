// Linux event port: epoll + eventfd backend (issue #7).
//
// Same contract as the kqueue backend:
//   - Sockets: read interest is persistent edge-triggered (EPOLLIN |
//     EPOLLET | EPOLLRDHUP; handlers fully drain — the EV_CLEAR
//     equivalent). EPOLLRDHUP gives half-close as an event.
//   - Write interest is on-demand "level-triggered" EPOLLOUT: armed by
//     wantWrite, disarmed by cancelWrite when the queue drains. NOTE:
//     EPOLLET in the shared mask applies to the fd's WHOLE registration,
//     so with read interest armed (always, for conns) EPOLLOUT is
//     effectively EDGE-triggered: a still-writable socket produces no
//     second writable event after connect. Conn write paths must attempt
//     the write FIRST and wait only after an actual want_write (EAGAIN) —
//     see driveWrite / driveProxyTunnel. (EPOLLONESHOT is unusable here
//     because it disarms the fd's WHOLE registration, including the
//     persistent read side.)
//   - Registrations apply immediately (epoll_ctl has no batching); the
//     kqueue-side "staged changelist" rule is kqueue-specific. A rejected
//     registration (e.g. EBADF for a dead descriptor) is NEVER a silent
//     no-op: like the IOCP backend's, a failure is stashed and returned as
//     error.RegisterFailed from the next non-empty wait().
//   - epoll_ctl answers EPERM for any descriptor with no poll
//     implementation — regular files, character devices such as
//     /dev/null, directories. Their I/O never blocks, so "always ready"
//     is the correct — and kqueue-matching — answer. These are pseudo
//     registrations: kept out of the kernel's set and reported ready by
//     every wait(). The kernel does the classifying: EPERM from the ADD
//     is the signal, so no descriptor-type list has to be maintained.
//   - Cross-thread wakeup: eventfd (the pipe trick's Linux twin).
//   - purgeFd drops only the port's bookkeeping; the kernel removes a
//     closed fd's registration itself.
//   - Internal sources (timer_epoll.zig's timerfd, signal_epoll.zig's
//     signalfd): at most one fd per kind per port, registered
//     level-triggered with a kind sentinel as epoll data. wait() hands a
//     ready one to its kind's harvest(), which drains it into Events. A
//     source left ready (the caller's buffer filled) is re-reported by the
//     next wait(), so nothing is dropped.

const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const timer_epoll = @import("timer_epoll.zig");
const signal_epoll = @import("signal_epoll.zig");

pub const Handle = types.Handle;
pub const Event = types.Event;
pub const Signal = types.Signal;
pub const TimerMode = types.TimerMode;

pub const InitError = error{InitFailed};
/// RegisterFailed and OutOfMemory are stashed registration failures;
/// SourceFailed is an internal source (timerfd, signalfd) that could not
/// be harvested or re-armed.
pub const WaitError = error{ WaitFailed, RegisterFailed, SourceFailed, OutOfMemory };
pub const TimerError = types.TimerError;
pub const SignalError = types.SignalError;
/// Every error this backend can return.
pub const Error = InitError || WaitError || TimerError || SignalError;

/// Block `sigs` in the calling thread; signalfd only sees blocked signals.
/// Call it in `main` before spawning threads; see signal_epoll.zig.
pub const blockSignals = signal_epoll.blockSignals;

/// Internal source kinds; each owns one slot in EvPort.internal.
pub const InternalKind = enum { timer, signal };

/// Stable addresses used as epoll data for internal sources, one per kind.
/// They cannot collide with a caller's udata, which never points here.
var internal_tags = [_]u8{0} ** std.meta.fields(InternalKind).len;

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
    /// Regular file: tracked in the map only, never in epoll. I/O on a
    /// regular file never blocks, so wait() reports it ready on every call
    /// — the same observable behaviour kqueue gives natively.
    pseudo: bool = false,
};

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
    internal: [std.meta.fields(InternalKind).len]i32 = .{-1} ** std.meta.fields(InternalKind).len,
    /// Timer bookkeeping, owned by timer_epoll.zig.
    timers: timer_epoll.State = .{},
    /// Signal-watch bookkeeping, owned by signal_epoll.zig.
    signals: signal_epoll.State = .{},

    pub fn init(alloc: std.mem.Allocator) InitError!EvPort {
        // Raw linux syscalls do not set libc errno; decode the return value
        // itself. std.posix.errno() would read libc's thread-local errno in
        // this libc-linked binary and report SUCCESS for failed syscalls.
        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.E.init(ep_rc) != .SUCCESS) return InitError.InitFailed;
        const ep: i32 = @intCast(ep_rc);
        errdefer _ = std.c.close(ep);

        const wfd_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.E.init(wfd_rc) != .SUCCESS) return InitError.InitFailed;
        const wfd: i32 = @intCast(wfd_rc);
        errdefer _ = std.c.close(wfd);

        var self = EvPort{
            .ep = ep,
            .alloc = alloc,
            .wake_fd = wfd,
            .timers = timer_epoll.State.init(alloc),
            .signals = signal_epoll.State.init(alloc),
        };
        self.register(wfd, true, false, @as(?*anyopaque, &wake_sentinel));
        return self;
    }

    pub fn deinit(self: *EvPort) void {
        self.signals.deinit(self);
        self.timers.deinit(self);
        if (self.ep >= 0) _ = std.c.close(self.ep);
        if (self.wake_fd >= 0) _ = std.c.close(self.wake_fd);
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
    /// removes the registration on close(2) itself).
    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        const kv = self.fds.fetchRemove(fd) orelse return;
        if (kv.value.pseudo) self.pseudo_count -= 1;
    }

    /// Wake a wait() blocked in another thread.
    pub fn wake(self: *EvPort) void {
        const one: u64 = 1;
        _ = std.posix.write(self.wake_fd, std.mem.asBytes(&one)) catch {};
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

    /// Internal hook: register `fd` as the port's `kind` source,
    /// level-triggered EPOLLIN. One source per kind.
    pub fn addInternal(self: *EvPort, kind: InternalKind, fd: i32) error{ InvalidArgument, SystemResources }!void {
        const slot = &self.internal[@intFromEnum(kind)];
        if (slot.* != -1 or fd < 0) return error.InvalidArgument;
        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(&internal_tags[@intFromEnum(kind)]) },
        };
        if (linux.E.init(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS)
            return error.SystemResources;
        slot.* = fd;
    }

    /// Internal hook: drop the `kind` source before its owner closes the fd.
    pub fn removeInternal(self: *EvPort, kind: InternalKind) void {
        const slot = &self.internal[@intFromEnum(kind)];
        if (slot.* == -1) return;
        _ = linux.epoll_ctl(self.ep, linux.EPOLL.CTL_DEL, slot.*, null);
        slot.* = -1;
    }

    /// The fd registered for `kind`, or null.
    pub fn internalFd(self: *const EvPort, kind: InternalKind) ?i32 {
        const fd = self.internal[@intFromEnum(kind)];
        return if (fd == -1) null else fd;
    }

    /// Apply the fd's computed mask: ADD / MOD / DEL / pseudo as needed.
    ///
    /// epoll_ctl answers EPERM for a descriptor it cannot poll, and
    /// "ready" is a true statement about every such descriptor: their I/O
    /// never blocks. Those become PSEUDO registrations — tracked in the
    /// map only and reported ready by every wait() — the same observable
    /// behaviour kqueue gives natively (issue #4).
    ///
    /// EPERM from the ADD is what classifies them, rather than an fstat
    /// against a hand-maintained list of descriptor types: the kernel's
    /// idea of what it cannot poll is the only authority that stays
    /// correct, and it covers character devices and directories as well
    /// as regular files. It also saves a syscall on the common path.
    ///
    /// The map slot is reserved BEFORE any kernel call so a successful
    /// registration can never be lost to an allocation failure afterwards
    /// (an untracked live registration turns the next apply() into a CTL_ADD
    /// that hits EEXIST, stranding the fd). Any other failure — OOM before
    /// the syscall, or an fstat/epoll_ctl rejection such as EBADF — is
    /// stashed in pending_error and leaves the map mirroring reality.
    fn apply(self: *EvPort, fd: Handle, st: FdState) void {
        if (!st.read and !st.write) {
            if (self.fds.getPtr(fd)) |cur| {
                if (cur.pseudo) {
                    self.pseudo_count -= 1;
                } else {
                    _ = linux.epoll_ctl(self.ep, linux.EPOLL.CTL_DEL, fd, null);
                }
                _ = self.fds.remove(fd);
            }
            return;
        }
        const gop = self.fds.getOrPut(self.alloc, fd) catch {
            self.pending_error = WaitError.OutOfMemory;
            return;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = st;
            var ev = makeEvent(st);
            switch (linux.E.init(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_ADD, fd, &ev))) {
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
            return;
        }
        if (!gop.value_ptr.pseudo) {
            var ev = makeEvent(st);
            if (linux.E.init(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_MOD, fd, &ev)) != .SUCCESS) {
                _ = self.fds.remove(fd);
                self.pending_error = WaitError.RegisterFailed;
                return;
            }
        }
        gop.value_ptr.* = st;
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

    /// Harvest events in one epoll_wait. timeout_ms: null = block until an
    /// event; 0 = harvest without blocking. A stashed registration failure
    /// is reported here, once, ahead of the syscall — an empty wait neither
    /// consumes nor reports it. Pseudo registrations (regular files) are
    /// always ready: while any exist the syscall never blocks, and they
    /// fill whatever space the kernel left. A ready internal source goes to
    /// its kind's harvest, which may emit several events or none (wait()
    /// can then return 0 before its timeout).
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
        const n_err = linux.E.init(n_rc);
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
            _ = std.posix.read(self.wake_fd, &tmp) catch break;
        }
    }
};

// --------------------------------------------------------------- tests ----

test "epoll: socket read readiness + ET edge semantics" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var tag: u8 = 1;
    evp.monitorRead(fds[0], &tag);
    _ = try std.posix.write(fds[1], "ab");

    var events: [8]Event = undefined;
    const n = try evp.wait(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));

    // ET: full drain → silence until a new edge.
    var buf: [4]u8 = undefined;
    while (true) {
        _ = std.posix.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));

    _ = try std.posix.write(fds[1], "c");
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
}

test "epoll: write interest arms and disarms" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var tag: u8 = 2;
    evp.wantWrite(fds[1], &tag);

    var events: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 1000));
    try std.testing.expect(events[0].writable);

    // Level-triggered: still armed — a second wait re-reports writability.
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
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0, &fds));
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

test "epoll: regular file is an always-ready pseudo registration (issue #4)" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("plain.txt", .{});
    defer file.close();
    try file.writeAll("x");
    try file.seekTo(0);

    // epoll_ctl would refuse this fd with EPERM; born keeps it out of the
    // kernel set and answers readiness itself, matching kqueue.
    var tag: u8 = 5;
    evp.monitorRead(file.handle, &tag);
    try std.testing.expect(evp.fds.get(file.handle).?.pseudo);
    try std.testing.expectEqual(@as(usize, 1), evp.pseudo_count);
    evp.wantWrite(file.handle, &tag);

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
    evp.unmonitorRead(file.handle);
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
    try std.testing.expect(events[0].writable and !events[0].readable);
    evp.purgeFd(file.handle);
    try std.testing.expectEqual(@as(usize, 0), evp.pseudo_count);
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: unpollable descriptors other than regular files are pseudo too (issue #4)" {
    // epoll_ctl answers EPERM for character devices and directories just as
    // it does for regular files. Classifying on EPERM rather than on a
    // descriptor-type test is what keeps these working: `prog < /dev/null`
    // is an ordinary way to launch a service.
    const alloc = std.testing.allocator;

    const cases = [_][]const u8{ "/dev/null", "/dev/zero" };
    for (cases) |path| {
        var evp = try EvPort.init(alloc);
        defer evp.deinit();
        const f = try std.fs.openFileAbsolute(path, .{});
        defer f.close();

        var tag: u8 = 7;
        evp.monitorRead(f.handle, &tag);

        var events: [4]Event = undefined;
        // No pending_error: the descriptor was accepted, not rejected.
        try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
        try std.testing.expect(evp.fds.get(f.handle).?.pseudo);
        try std.testing.expectEqual(@as(usize, 1), evp.pseudo_count);
        try std.testing.expect(events[0].readable);
        try std.testing.expect(!events[0].err);
    }

    // A directory opened for reading is refused the same way. (An O_PATH
    // directory fd is refused with EBADF instead, and must therefore stay
    // a hard error — which is exactly why the classification keys on EPERM
    // and not on "epoll_ctl said no".)
    var evp = try EvPort.init(alloc);
    defer evp.deinit();
    const dfd = try std.posix.open("/tmp", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer std.posix.close(dfd);

    var tag: u8 = 8;
    evp.monitorRead(dfd, &tag);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try evp.wait(&events, 0));
    try std.testing.expect(evp.fds.get(dfd).?.pseudo);
    try std.testing.expect(events[0].readable and !events[0].err);
}

test "epoll: rejected descriptor is reported by the next wait, never half-recorded (issue #4)" {
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
    // Reported exactly once, and a retry reports the same rejection — no
    // half-recorded state to trip over.
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
    evp.wantWrite(bogus, &tag);
    try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
    try std.testing.expect(!evp.fds.contains(bogus));
}

test "epoll: allocation failure is reported by the next wait, once" {
    // fail_index 0 lands inside init's wake-fd registration: the port
    // constructs, but the bookkeeping slot never gets reserved.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var evp = try EvPort.init(failing.allocator());
    defer evp.deinit();
    try std.testing.expect(!evp.fds.contains(evp.wake_fd));
    var empty: [0]Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&empty, null));
    var events: [1]Event = undefined;
    try std.testing.expectError(Error.OutOfMemory, evp.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));
}

test "epoll: non-blocking connect completes via write interest" {
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

test "epoll: internal source tags never match caller data" {
    var tag: u8 = 1;
    try std.testing.expect(internalKind(@intFromPtr(&tag)) == null);
    try std.testing.expect(internalKind(@intFromPtr(&wake_sentinel)) == null);
    try std.testing.expect(internalKind(0) == null);
    inline for (std.meta.fields(InternalKind)) |field| {
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
    try std.testing.expectEqual(linux.E.SUCCESS, linux.E.init(rc));
    const fd: i32 = @intCast(rc);
    defer _ = std.c.close(fd);

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
