// BSD/macOS event port: kqueue backend.
//
// Global-rule discipline:
//   - Staged changelist: monitor*/unmonitor* accumulate struct kevent into a
//     local array; the next wait() submits changelist + eventlist in ONE
//     kevent() call. No kevent() call exists solely to register fds.
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

const std = @import("std");

// Use the target's struct kevent: FreeBSD 12+ needs its extended 64-byte
// layout (ext[4]), while NetBSD has wider filter/flags fields. A wrong
// stride corrupts multi-entry changelists and event buffers.
const Kevent = std.posix.Kevent;
const EVFILT_READ = std.posix.system.EVFILT.READ;
const EVFILT_WRITE = std.posix.system.EVFILT.WRITE;

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

pub const Handle = @import("types.zig").Handle;
pub const Event = @import("types.zig").Event;

pub const Error = error{
    KqueueFailed,
    PipeFailed,
    WaitFailed,
    OutOfMemory,
};

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

    pub fn init(alloc: std.mem.Allocator) Error!EvPort {
        const kq = std.posix.kqueue() catch return Error.KqueueFailed;
        errdefer _ = std.c.close(kq);

        const fds = std.posix.pipe2(PIPE2_FLAGS) catch return Error.PipeFailed;
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }

        var self = EvPort{ .kq = kq, .alloc = alloc, .wake_r = fds[0], .wake_w = fds[1] };
        self.monitorRead(self.wake_r, @as(?*anyopaque, &wake_sentinel));
        return self;
    }

    pub fn deinit(self: *EvPort) void {
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
        self.armed_write.put(self.alloc, fd, {}) catch return;
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
    pub fn purgeFd(self: *EvPort, fd: Handle) void {
        _ = self.armed_write.remove(fd);
        const ident: usize = @intCast(fd);
        var i: usize = 0;
        while (i < self.changes.items.len) {
            if (self.changes.items[i].ident == ident) {
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

    fn stage(self: *EvPort, kev: Kevent) void {
        self.changes.append(self.alloc, kev) catch {};
    }

    /// Flush the staged changelist and harvest events in ONE kevent() call.
    /// timeout_ms: null = block until an event; 0 = harvest without blocking.
    pub fn wait(self: *EvPort, events: []Event, timeout_ms: ?i32) Error!usize {
        if (events.len == 0) return 0;
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
            return Error.WaitFailed;
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
            events[out] = .{
                .udata = @ptrFromInt(kev.udata),
                .readable = kev.filter == EVFILT_READ,
                .writable = kev.filter == EVFILT_WRITE,
                .eof = (kev.flags & EV_EOF) != 0,
                .err = (kev.flags & EV_ERROR) != 0,
                .err_no = if ((kev.flags & EV_ERROR) != 0) @intCast(kev.data) else 0,
            };
            out += 1;
        }
        return out;
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
