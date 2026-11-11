//! Process exits on epoll: pidfds in one inner epoll set per port.
//!
//! A pidfd becomes readable when its process exits. The first watch creates
//! an inner epoll instance and registers it with
//! `EvPort.addInternal(.process, fd)` (level-triggered), and every watched
//! pidfd joins the inner set with its descriptor number as data. When the
//! inner set is ready, wait() calls `harvest`, which takes at most as many
//! ready pidfds as the caller's buffer has room for and reaps each one with
//! `waitid(P_PIDFD, WEXITED | WNOHANG)`. The reap gives the status and ends
//! the watch (the pidfd leaves the inner set). Ready pidfds that did not fit
//! stay ready, so the next wait() reports them.
//!
//! Reaping: a watched child is reaped by the wait() that reports its exit;
//! `Child.close` reaps one that was never reported. waitid needs the
//! process to be a child of the caller: when it cannot collect a status
//! (ECHILD because someone else reaped it), the event still arrives with
//! `exited` and `err` set and the errno in `err_no`. A pidfd that is
//! readable with nothing collectable (si_pid stays zero) carries the same
//! meaning with `err_no` zero: the status belongs to someone else, e.g. a
//! tracer that attached to the child. The event ends the watch either way,
//! because a level-triggered pidfd without a collectible status would keep
//! wait() ready forever. A failed epoll_wait on the inner set is stashed as
//! error.SourceFailed for the next wait().

const std = @import("std");
const linux = std.os.linux;
const compat = @import("compat");
const ep = @import("evport_epoll.zig");
const types = @import("types.zig");
const EvPort = ep.EvPort;
const Event = ep.Event;
const ProcessError = types.ProcessError;

/// siginfo si_code values for SIGCHLD (CLD_EXITED, CLD_KILLED, CLD_DUMPED).
const CLD_EXITED = 1;
const CLD_KILLED = 2;
const CLD_DUMPED = 3;

/// Per-port watch bookkeeping, a field of EvPort (`processes`).
pub const State = struct {
    /// The inner epoll set, -1 until the first watch.
    fd: i32 = -1,
    /// Watched pidfds and their udata.
    watches: std.AutoHashMapUnmanaged(i32, ?*anyopaque) = .empty,

    /// Removes the internal source, closes the inner set and frees the map.
    pub fn deinit(self: *State, port: *EvPort) void {
        if (self.fd != -1) {
            port.removeInternal(.process);
            compat.close(self.fd);
        }
        self.watches.deinit(port.alloc);
        self.* = .{};
    }

    fn ensureFd(self: *State, port: *EvPort) ProcessError!void {
        if (self.fd != -1) return;
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (ep.rawErrno(rc) != .SUCCESS) return ProcessError.SystemResources;
        const fd: i32 = @intCast(rc);
        port.addInternal(.process, fd) catch |err| {
            compat.close(fd);
            return switch (err) {
                // The process slot belongs to this module and is empty
                // whenever self.fd is -1.
                error.InvalidArgument => unreachable,
                error.SystemResources => ProcessError.SystemResources,
            };
        };
        self.fd = fd;
    }
};

/// Adds the pidfd to the inner set. Watching a watched pidfd replaces its
/// udata. OutOfMemory and every refusal leave the watches as they were. A
/// non-pidfd pollable descriptor (a pipe, say) is refused up front:
/// signal 0 probes the descriptor, and pidfd_send_signal exists since
/// 5.1, well below the 5.4 floor from `process.spawn`.
pub fn watch(port: *EvPort, fd: i32, udata: ?*anyopaque) ProcessError!void {
    if (fd < 0) return ProcessError.BadHandle;
    // ESRCH (an exited child is still watchable) and EPERM both confirm a
    // real pidfd; EINVAL marks any other pollable descriptor.
    switch (ep.rawErrno(linux.pidfd_send_signal(fd, compat.nativeSignal(0), null, 0))) {
        .SUCCESS, .SRCH, .PERM => {},
        .NOSYS => return ProcessError.Unsupported,
        .BADF, .INVAL => return ProcessError.BadHandle,
        else => return ProcessError.SystemResources,
    }
    const st = &port.processes;
    try st.ensureFd(port);
    const gop = st.watches.getOrPut(port.alloc, fd) catch return ProcessError.OutOfMemory;
    errdefer if (!gop.found_existing) st.watches.removeByPtr(gop.key_ptr);
    var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
    switch (ep.rawErrno(linux.epoll_ctl(st.fd, linux.EPOLL.CTL_ADD, fd, &ev))) {
        .SUCCESS => {},
        // Already in the set: a re-watch, or a stale entry for a reused
        // descriptor number.
        .EXIST => {},
        .BADF, .PERM => return ProcessError.BadHandle,
        else => return ProcessError.SystemResources,
    }
    gop.value_ptr.* = udata;
}

/// Ends the watch on a pidfd that stays open. Unwatched pidfds are a no-op.
/// A refused removal is stashed as error.RegisterFailed for the next wait().
pub fn unwatch(port: *EvPort, fd: i32) void {
    const st = &port.processes;
    if (!st.watches.remove(fd)) return;
    switch (ep.rawErrno(linux.epoll_ctl(st.fd, linux.EPOLL.CTL_DEL, fd, null))) {
        .SUCCESS => {},
        else => if (port.pending_error == null) {
            port.pending_error = error.RegisterFailed;
        },
    }
}

/// `EvPort.purgeFd` hook: the pidfd is about to be closed. Its inner-set
/// entry goes now, so a reused descriptor number starts clean.
pub fn purge(port: *EvPort, fd: i32) void {
    const st = &port.processes;
    if (!st.watches.remove(fd)) return;
    drop(port, fd);
}

/// Turns ready pidfds into at most `out.len` (>= 1) exit events and returns
/// the count. A pidfd that is ready but whose status is not collectable
/// (owned by a tracer or a racing wait) is reported once with err set and
/// leaves the set, so wait() cannot spin on it.
pub fn harvest(port: *EvPort, out: []Event) usize {
    const st = &port.processes;
    if (st.fd == -1) return 0;
    var buf: [64]linux.epoll_event = undefined;
    const cap = @min(out.len, buf.len);
    const rc = linux.epoll_wait(st.fd, &buf, @intCast(cap), 0);
    switch (ep.rawErrno(rc)) {
        .SUCCESS => {},
        .INTR => return 0,
        else => {
            if (port.pending_error == null) port.pending_error = error.SourceFailed;
            return 0;
        },
    }
    var n: usize = 0;
    for (buf[0..rc]) |ready| {
        const fd = ready.data.fd;
        const udata = st.watches.get(fd) orelse {
            // Not watched any more: drop the leftover entry.
            drop(port, fd);
            continue;
        };
        var ev: Event = .{ .udata = udata, .exited = true };
        var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
        const wrc = while (true) {
            const r = compat.waitid(.PIDFD, fd, &info, linux.W.EXITED | linux.W.NOHANG);
            if (ep.rawErrno(r) != .INTR) break r;
        };
        switch (ep.rawErrno(wrc)) {
            .SUCCESS => {
                // WNOHANG with nothing to collect leaves si_pid zero: the
                // status belongs to someone else (a tracer, or a racing
                // wait in this process). The pidfd stays level-triggered
                // readable with nothing ever collectable, so dropping this
                // onto the floor would spin wait(); report the exit once
                // with err set and err_no zero, and end the watch.
                if (info.fields.common.first.piduid.pid == 0) {
                    ev.err = true;
                } else {
                    ev.exit = exitOf(info);
                    if (ev.exit == null) ev.err = true;
                }
            },
            else => |e| {
                ev.err = true;
                ev.err_no = @intFromEnum(e);
            },
        }
        _ = st.watches.remove(fd);
        drop(port, fd);
        out[n] = ev;
        n += 1;
    }
    return n;
}

/// Removes `fd` from the inner set. A failure would leave a reaped pidfd
/// ready forever, so it is stashed as error.SourceFailed.
fn drop(port: *EvPort, fd: i32) void {
    switch (ep.rawErrno(linux.epoll_ctl(port.processes.fd, linux.EPOLL.CTL_DEL, fd, null))) {
        .SUCCESS => {},
        else => if (port.pending_error == null) {
            port.pending_error = error.SourceFailed;
        },
    }
}

fn exitOf(info: linux.siginfo_t) ?types.ProcessExit {
    const status = info.fields.common.second.sigchld.status;
    return switch (info.code) {
        CLD_EXITED => .{ .code = @truncate(@as(u32, @bitCast(status))) },
        CLD_KILLED, CLD_DUMPED => .{ .signal = std.math.cast(u8, status) orelse return null },
        else => null,
    };
}

// --------------------------------------------------------------- tests ----

const testing = std.testing;

test "process_epoll: a descriptor epoll cannot poll is BadHandle" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    const file = try compat.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer compat.close(file);
    var tag: u8 = 1;
    try testing.expectError(ProcessError.BadHandle, watch(&port, file, &tag));
    try testing.expect(!port.processes.watches.contains(file));
    try testing.expectError(ProcessError.BadHandle, watch(&port, -1, &tag));
}

test "process_epoll: unwatch and purge forget the pidfd" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    // Own-pid pidfd: real pidfd (5.3, below the floor is fine here), and
    // this process never exits, so nothing becomes readable.
    const prc = linux.pidfd_open(linux.getpid(), 0);
    try testing.expectEqual(linux.E.SUCCESS, ep.rawErrno(prc));
    const fd: i32 = @intCast(prc);
    defer compat.close(fd);
    var tag: u8 = 1;
    try watch(&port, fd, &tag);
    try watch(&port, fd, &tag);
    unwatch(&port, fd);
    try testing.expect(!port.processes.watches.contains(fd));
    try watch(&port, fd, &tag);
    purge(&port, fd);
    try testing.expect(!port.processes.watches.contains(fd));
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
}

test "process_epoll: a pollable non-pidfd (pipe) is BadHandle" {
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    const fds = try compat.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);
    var tag: u8 = 1;
    // Epoll would take the pipe; the probe refuses it like kqueue does.
    try testing.expectError(ProcessError.BadHandle, watch(&port, fds[0], &tag));
    try testing.expect(!port.processes.watches.contains(fds[0]));
}

test "process_epoll: siginfo decodes to an exit" {
    var info = std.mem.zeroes(linux.siginfo_t);
    info.code = CLD_EXITED;
    info.fields.common.second.sigchld.status = 7;
    try testing.expectEqual(types.ProcessExit{ .code = 7 }, exitOf(info).?);
    info.code = CLD_KILLED;
    info.fields.common.second.sigchld.status = compat.signalNumber(linux.SIG.TERM);
    try testing.expectEqual(types.ProcessExit{ .signal = compat.signalNumber(linux.SIG.TERM) }, exitOf(info).?);
    info.code = CLD_DUMPED;
    try testing.expect(exitOf(info) != null);
    info.code = 5; // CLD_STOPPED
    try testing.expect(exitOf(info) == null);
}
