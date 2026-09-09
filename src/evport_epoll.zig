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
//     registration (e.g. EPERM for a regular file) is NEVER a silent no-op:
//     like the IOCP backend's, a failure is stashed and returned as
//     error.RegisterFailed from the next non-empty wait().
//   - Cross-thread wakeup: eventfd (the pipe trick's Linux twin).
//   - purgeFd drops only the port's bookkeeping; the kernel removes a
//     closed fd's registration itself.

const std = @import("std");
const linux = std.os.linux;

pub const Handle = @import("types.zig").Handle;
pub const Event = @import("types.zig").Event;

pub const Error = error{
    InitFailed,
    RegisterFailed,
    WaitFailed,
    OutOfMemory,
};

/// Stable address used as the wake eventfd's udata tag.
var wake_sentinel: u8 = 0;

const READ_MASK: u32 = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP;
const WRITE_MASK: u32 = linux.EPOLL.OUT;

const FdState = struct {
    udata: ?*anyopaque = null,
    read: bool = false,
    write: bool = false, // EPOLLOUT currently in the mask
};

pub const EvPort = struct {
    ep: i32 = -1,
    alloc: std.mem.Allocator,
    wake_fd: i32 = -1,
    fds: std.AutoHashMapUnmanaged(i32, FdState) = .empty,
    /// Stashed registration failure (the IOCP backend's shape): a rejected
    /// epoll_ctl or an allocation failure is returned by the next non-empty
    /// wait() instead of being dropped on the floor.
    pending_error: ?Error = null,

    pub fn init(alloc: std.mem.Allocator) Error!EvPort {
        // Raw linux syscalls do not set libc errno; decode the return value
        // itself. std.posix.errno() would read libc's thread-local errno in
        // this libc-linked binary and report SUCCESS for failed syscalls.
        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.E.init(ep_rc) != .SUCCESS) return Error.InitFailed;
        const ep: i32 = @intCast(ep_rc);
        errdefer _ = std.c.close(ep);

        const wfd_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.E.init(wfd_rc) != .SUCCESS) return Error.InitFailed;
        const wfd: i32 = @intCast(wfd_rc);
        errdefer _ = std.c.close(wfd);

        var self = EvPort{ .ep = ep, .alloc = alloc, .wake_fd = wfd };
        self.register(wfd, true, false, @as(?*anyopaque, &wake_sentinel));
        return self;
    }

    pub fn deinit(self: *EvPort) void {
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
        _ = self.fds.remove(fd);
    }

    /// Wake a wait() blocked in another thread.
    pub fn wake(self: *EvPort) void {
        const one: u64 = 1;
        _ = std.posix.write(self.wake_fd, std.mem.asBytes(&one)) catch {};
    }

    /// Apply the fd's computed mask: ADD / MOD / DEL as needed.
    ///
    /// The map slot is reserved BEFORE epoll_ctl so a successful kernel
    /// registration can never be lost to an allocation failure afterwards
    /// (an untracked live registration turns the next apply() into a CTL_ADD
    /// that hits EEXIST, stranding the fd). Any failure — OOM before the
    /// syscall or a kernel rejection at it — is stashed in pending_error
    /// and leaves the map mirroring the kernel.
    fn apply(self: *EvPort, fd: Handle, st: FdState) void {
        if (!st.read and !st.write) {
            if (self.fds.contains(fd)) {
                _ = linux.epoll_ctl(self.ep, linux.EPOLL.CTL_DEL, fd, null);
                _ = self.fds.remove(fd);
            }
            return;
        }
        var mask: u32 = 0;
        if (st.read) mask |= READ_MASK;
        if (st.write) mask |= WRITE_MASK;
        var ev = linux.epoll_event{
            .events = mask,
            .data = .{ .ptr = @intFromPtr(st.udata) },
        };
        const gop = self.fds.getOrPut(self.alloc, fd) catch {
            self.pending_error = Error.OutOfMemory;
            return;
        };
        const op: u32 = if (gop.found_existing) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        if (linux.E.init(linux.epoll_ctl(self.ep, op, fd, &ev)) != .SUCCESS) {
            if (!gop.found_existing) _ = self.fds.remove(fd);
            self.pending_error = Error.RegisterFailed;
            return;
        }
        gop.value_ptr.* = st;
    }

    /// register is apply for init (fd not yet tracked).
    fn register(self: *EvPort, fd: Handle, read: bool, write: bool, udata: ?*anyopaque) void {
        self.apply(fd, .{ .udata = udata, .read = read, .write = write });
    }

    // ------------------------------------------------------------ wait ----

    /// Harvest events in one epoll_wait. timeout_ms: null = block until an
    /// event; 0 = harvest without blocking. A stashed registration failure
    /// is reported here, once, ahead of the syscall — an empty wait neither
    /// consumes nor reports it.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) Error!usize {
        if (events.len == 0) return 0;
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
        var ebuf: [64]linux.epoll_event = undefined;
        const cap = @min(events.len, ebuf.len);
        const timeout: i32 = timeout_ms orelse -1;

        const n_rc = linux.epoll_wait(self.ep, &ebuf, @intCast(cap), timeout);
        const n_err = linux.E.init(n_rc);
        if (n_err != .SUCCESS) {
            if (n_err == .INTR) return 0;
            return Error.WaitFailed;
        }

        var out: usize = 0;
        var woke = false;
        for (ebuf[0..@intCast(n_rc)]) |eev| {
            if (eev.data.ptr == @intFromPtr(&wake_sentinel)) {
                if (!woke) {
                    woke = true;
                    self.drainWake();
                    events[out] = .{ .wake = true };
                    out += 1;
                }
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

test "epoll: refused registration is reported by the next wait, never half-recorded (issue #4)" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("plain.txt", .{});
    defer file.close();
    // Non-empty with the offset rewound, so an accepting kernel
    // (epoll-over-kqueue runtimes) reports it readable rather than at-EOF.
    try file.writeAll("x");
    try file.seekTo(0);

    var tag: u8 = 5;
    evp.monitorRead(file.handle, &tag);
    var events: [8]Event = undefined;
    if (evp.fds.contains(file.handle)) {
        // Runtimes that implement epoll over kqueue (the FreeBSD
        // Linuxulator) accept the regular files native epoll(7) rejects
        // with EPERM. The refusal assertions below hold on a faithful
        // epoll; here, just verify the accepted registration behaves.
        const n = try evp.wait(&events, 1000);
        try std.testing.expect(n >= 1);
        try std.testing.expect(events[0].readable);
        evp.purgeFd(file.handle);
    } else {
        // epoll_ctl refused it: the IOCP-shaped contract — void call, hard
        // error from the next non-empty wait(), reported exactly once.
        var empty: [0]Event = .{};
        try std.testing.expectEqual(@as(usize, 0), try evp.wait(&empty, null));
        try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
        try std.testing.expectEqual(@as(usize, 0), try evp.wait(&events, 0));

        // Bookkeeping mirrors the kernel — no half-recorded registration,
        // so a retry reports the same rejection instead of stranding the fd
        // on EEXIST.
        evp.wantWrite(file.handle, &tag);
        try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
        try std.testing.expect(!evp.fds.contains(file.handle));
    }

    // An out-of-range descriptor fails through the same channel (EBADF) on
    // every epoll implementation, emulation included. Deliberately not a
    // dup'd-then-closed fd: the Linuxulator accepts recycled fd numbers.
    const bogus: Handle = 1 << 20;
    evp.monitorRead(bogus, &tag);
    try std.testing.expect(!evp.fds.contains(bogus));
    try std.testing.expectError(Error.RegisterFailed, evp.wait(&events, 0));
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
