//! Process exits on kqueue (EVFILT_PROCDESC). FreeBSD only: the other
//! kqueue targets have no process descriptors and return error.Unsupported.
//!
//! A watch is one EVFILT_PROCDESC knote on the process descriptor with
//! NOTE_EXIT, staged through `EvPort.stageRaw` into the next wait() like any
//! descriptor change. When the process exits the kernel sets EV_EOF and
//! EV_ONESHOT on the knote and puts the wait(2) status in `data`; harvesting
//! it deletes the knote, so the exit event ends the watch. A watch added
//! after the process exited fires at once.
//!
//! The kernel keeps the zombie until the last process descriptor is closed
//! (`Child.close`), whether or not an exit was harvested; closing the
//! descriptor of a running process kills it with SIGKILL and its reaper
//! collects it. Born never reaps on kqueue.
//!
//! State tracks watched descriptors and whether their add has reached the
//! kernel, so `unwatch` stages EV_DELETE only for a knote that exists and
//! drops a still-staged add instead. Deliveries for a descriptor that is no
//! longer watched (a delete that could not be staged) are suppressed, as is
//! the ENOENT of a delete that found no knote.

const std = @import("std");
const builtin = @import("builtin");
const kq = @import("evport_kqueue.zig");
const types = @import("types.zig");
const EvPort = kq.EvPort;
const Kevent = kq.Kevent;
const ProcessError = types.ProcessError;

pub const have_procdesc = builtin.os.tag == .freebsd;
/// EVFILT_PROCDESC, or 0 where it does not exist (never compared there).
pub const EVFILT_PROCDESC = if (have_procdesc) std.c.EVFILT.PROCDESC else 0;
/// sys/event.h NOTE_EXIT.
const NOTE_EXIT: u32 = 0x80000000;

const EV_ADD = std.posix.system.EV.ADD;
const EV_DELETE = std.posix.system.EV.DELETE;
const EV_ERROR = if (@hasDecl(std.posix.system.EV, "ERROR")) std.posix.system.EV.ERROR else 0x4000;
const ENOENT = @intFromEnum(std.posix.E.NOENT);

/// Per-port watch bookkeeping, a field of EvPort (`processes`).
pub const State = struct {
    /// Watched descriptors; the value is true once a wait() has submitted
    /// the add, so a knote exists.
    live: std.AutoHashMapUnmanaged(c_int, bool) = .empty,
    /// Descriptors whose add is staged and not yet submitted.
    unflushed: std.ArrayListUnmanaged(c_int) = .empty,

    /// Closing the kqueue drops every knote; only the bookkeeping is freed.
    pub fn deinit(self: *State, port: *EvPort) void {
        self.live.deinit(port.alloc);
        self.unflushed.deinit(port.alloc);
        self.* = .{};
    }
};

/// Stages the watch for the next wait(). Allocation happens up front, so
/// OutOfMemory leaves the port unchanged. Watching a watched descriptor
/// replaces its udata. A kernel refusal (EBADF, or a descriptor that is not
/// a process descriptor) arrives at wait() as Event{ .err, .err_no } with
/// the watch's udata and ends the watch.
pub fn watch(port: *EvPort, fd: c_int, udata: ?*anyopaque) ProcessError!void {
    if (!have_procdesc) return ProcessError.Unsupported;
    if (fd < 0) return ProcessError.BadHandle;
    const st = &port.processes;
    port.changes.ensureUnusedCapacity(port.alloc, 1) catch return ProcessError.OutOfMemory;
    st.unflushed.ensureUnusedCapacity(port.alloc, 1) catch return ProcessError.OutOfMemory;
    const gop = st.live.getOrPut(port.alloc, fd) catch return ProcessError.OutOfMemory;
    if (!gop.found_existing) {
        gop.value_ptr.* = false;
        st.unflushed.appendAssumeCapacity(fd);
    }
    port.stageRaw(change(fd, EV_ADD, udata));
}

/// Ends a watch on a descriptor that stays open. A staged add is dropped;
/// a submitted one gets a staged EV_DELETE. Unwatched descriptors are a
/// no-op. For a descriptor about to be closed, `EvPort.purgeFd` is enough.
pub fn unwatch(port: *EvPort, fd: c_int) void {
    if (!have_procdesc) return;
    const kv = port.processes.live.fetchRemove(fd) orelse return;
    purgeStaged(port, fd);
    if (kv.value) port.stageRaw(change(fd, EV_DELETE, null));
}

/// `EvPort.purgeFd` hook: the descriptor is about to be closed, which
/// removes its knote; forget the watch.
pub fn purge(port: *EvPort, fd: c_int) void {
    if (!have_procdesc) return;
    _ = port.processes.live.remove(fd);
}

/// wait() hook after the changelist reached the kernel.
pub fn flushed(port: *EvPort) void {
    const st = &port.processes;
    for (st.unflushed.items) |fd| {
        if (st.live.getPtr(fd)) |in_kernel| in_kernel.* = true;
    }
    st.unflushed.clearRetainingCapacity();
}

/// Sees each EVFILT_PROCDESC kevent first; false suppresses it. An exit or
/// a refused add ends the watch.
pub fn observe(port: *EvPort, kev: Kevent) bool {
    const fd = std.math.cast(c_int, kev.ident) orelse return true;
    if ((kev.flags & EV_ERROR) != 0) {
        if (kev.data == ENOENT) return false;
        _ = port.processes.live.remove(fd);
        return true;
    }
    return port.processes.live.remove(fd);
}

fn purgeStaged(port: *EvPort, fd: c_int) void {
    const ident: usize = @intCast(fd);
    var i: usize = 0;
    while (i < port.changes.items.len) {
        const kev = port.changes.items[i];
        if (kev.ident == ident and kev.filter == EVFILT_PROCDESC) {
            _ = port.changes.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn change(fd: c_int, flags: @FieldType(Kevent, "flags"), udata: ?*anyopaque) Kevent {
    var kev = std.mem.zeroes(Kevent);
    kev.ident = @intCast(fd);
    kev.filter = EVFILT_PROCDESC;
    kev.flags = flags;
    kev.fflags = NOTE_EXIT;
    kev.udata = @intFromPtr(udata);
    return kev;
}

// --------------------------------------------------------------- tests ----

const testing = std.testing;

test "process_kqueue: unwatch before a wait drops the staged add" {
    if (!have_procdesc) return error.SkipZigTest;
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    var events: [4]kq.Event = undefined;
    _ = try port.wait(&events, 0);
    var tag: u8 = 1;
    // Any descriptor number will do: nothing reaches the kernel.
    try watch(&port, 900, &tag);
    try testing.expectEqual(@as(usize, 1), port.changes.items.len);
    unwatch(&port, 900);
    try testing.expectEqual(@as(usize, 0), port.changes.items.len);
    try testing.expect(!port.processes.live.contains(900));
}

test "process_kqueue: a refused add is an error event and ends the watch" {
    if (!have_procdesc) return error.SkipZigTest;
    var port = try EvPort.init(testing.allocator);
    defer port.deinit();
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    var tag: u8 = 1;
    // A pipe is not a process descriptor.
    try watch(&port, fds[0], &tag);
    var events: [4]kq.Event = undefined;
    try testing.expectEqual(@as(usize, 1), try port.wait(&events, 0));
    try testing.expect(events[0].err and !events[0].exited);
    try testing.expect(events[0].udata == @as(?*anyopaque, &tag));
    try testing.expect(!port.processes.live.contains(fds[0]));
    unwatch(&port, fds[0]);
    try testing.expectEqual(@as(usize, 0), port.changes.items.len);
}

test "process_kqueue: allocation failure in watch leaves the port unchanged" {
    if (!have_procdesc) return error.SkipZigTest;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var port = try EvPort.init(failing.allocator());
    defer port.deinit();
    const staged = port.changes.items.len;
    failing.fail_index = failing.alloc_index;
    var tag: u8 = 1;
    try testing.expectError(ProcessError.OutOfMemory, watch(&port, 900, &tag));
    try testing.expectEqual(staged, port.changes.items.len);
    try testing.expect(!port.processes.live.contains(900));
    try testing.expect(port.pending_error == null);
}
