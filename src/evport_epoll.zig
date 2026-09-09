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
//   - epoll_ctl refuses regular files with EPERM, but their I/O never
//     blocks, so "always ready" is the correct — and kqueue-matching —
//     answer. Regular files are pseudo registrations: detected with fstat,
//     kept out of the kernel's set, and reported ready by every wait().
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
    pending_error: ?Error = null,
    /// Live pseudo registrations: wait() must not block while any exist.
    pseudo_count: usize = 0,

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
        const kv = self.fds.fetchRemove(fd) orelse return;
        if (kv.value.pseudo) self.pseudo_count -= 1;
    }

    /// Wake a wait() blocked in another thread.
    pub fn wake(self: *EvPort) void {
        const one: u64 = 1;
        _ = std.posix.write(self.wake_fd, std.mem.asBytes(&one)) catch {};
    }

    /// Apply the fd's computed mask: ADD / MOD / DEL / pseudo as needed.
    ///
    /// epoll_ctl refuses regular files (EPERM), but "ready" is a true
    /// statement about them: their I/O never blocks. A regular file is
    /// therefore a PSEUDO registration — tracked in the map only and
    /// reported ready by every wait() — the same observable behaviour
    /// kqueue gives natively (issue #4).
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
            self.pending_error = Error.OutOfMemory;
            return;
        };
        if (!gop.found_existing) {
            // Fresh registration: classify before touching the kernel.
            // Raw linux.fstat: std.posix.fstat declares EBADF unreachable,
            // and a possibly-dead fd is exactly what must be classifiable.
            var stat: linux.Stat = undefined;
            if (linux.E.init(linux.fstat(fd, &stat)) != .SUCCESS) {
                _ = self.fds.remove(fd);
                self.pending_error = Error.RegisterFailed;
                return;
            }
            gop.value_ptr.* = st;
            if (stat.mode & linux.S.IFMT == linux.S.IFREG) {
                gop.value_ptr.pseudo = true;
                self.pseudo_count += 1;
                return;
            }
            var ev = makeEvent(st);
            if (linux.E.init(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) {
                _ = self.fds.remove(fd);
                self.pending_error = Error.RegisterFailed;
            }
            return;
        }
        if (!gop.value_ptr.pseudo) {
            var ev = makeEvent(st);
            if (linux.E.init(linux.epoll_ctl(self.ep, linux.EPOLL.CTL_MOD, fd, &ev)) != .SUCCESS) {
                _ = self.fds.remove(fd);
                self.pending_error = Error.RegisterFailed;
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
    /// fill whatever space the kernel left.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) Error!usize {
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

test "epoll: rejected descriptor is reported by the next wait, never half-recorded (issue #4)" {
    const alloc = std.testing.allocator;
    var evp = try EvPort.init(alloc);
    defer evp.deinit();

    var events: [8]Event = undefined;
    var tag: u8 = 6;
    // fstat fails EBADF before epoll_ctl is ever reached. Deliberately an
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
