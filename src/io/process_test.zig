//! Process-route tests for the born.io shim (P5.4, Option B).
//!
//! These exercise the Born evented process family on FreeBSD and Linux:
//! spawn/wait/kill through process descriptors / pidfds, PATH resolution, the
//! stdio pipe hybrid, the provenance gate, the coarse error map, wait-cancel
//! abandon, the dead-loop kill fallback, and the per-route counters that prove
//! the family ran on Born's reactor. On other targets the capability is a
//! construction rejection and these tests skip. A zero `threaded_*` counter
//! after a spawn/wait/kill exchange is the provenance-gate evidence; child
//! stream I/O on the pipe parent ends stays Threaded-serviced and is not
//! claimed by these counters. Runtime evidence requires running these on each
//! kernel; a cross-build is not evidence.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const born_io = @import("root.zig");
const shim = @import("shim.zig");
const compat = @import("compat");
const Io = std.Io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const is_017 = builtin.zig_version.minor >= 17;

/// The process route needs process descriptors / pidfds and a loop thread.
/// A comptime constant so the whole test body is pruned (never analyzed) on
/// targets without the route, where the POSIX-only probes would not compile.
const skip_unsupported = !born_io.process_supported or builtin.single_threaded;

fn initProcIo(port: *born.EvPort) born_io.InitError!Io {
    return born_io.io(port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .process = .born_evented },
    });
}

/// Read a pipe parent end to EOF (Threaded file I/O, 5.3). Caller frees.
fn readPipeToEnd(io: Io, file: Io.File) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return r.interface.allocRemaining(std.testing.allocator, .limited(1 << 20));
}

// libc environment mutators (std.c declares getenv but not setenv/unsetenv).
// Referenced only from process-supported test bodies, which are comptime-pruned
// on other targets, so they never force a link dependency there.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Set the parent PATH. resolvePath reads the live std.c.environ, not a snapshot.
fn setPath(value: [:0]const u8) void {
    if (setenv("PATH", value.ptr, 1) != 0) @panic("setenv PATH failed");
}

/// Remove the parent PATH so resolvePath falls back to the toolchain default.
fn clearPath() void {
    if (unsetenv("PATH") != 0) @panic("unsetenv PATH failed");
}

/// Save the current PATH for restoration. Tests run sequentially and the Born
/// loop never reads PATH, so a process-wide mutation is safe within one test.
fn savePath() ?[:0]u8 {
    const p = std.c.getenv("PATH") orelse return null;
    return std.testing.allocator.dupeSentinel(u8, std.mem.span(p), 0) catch @panic("oom saving PATH");
}

fn restorePath(saved: ?[:0]u8) void {
    if (saved) |p| {
        setPath(p);
        std.testing.allocator.free(p);
    } else clearPath();
}

/// Build the PATH-search fixture tree under `d` (a std.testing.tmpDir dir).
/// Relative PATH entries resolve against it after fchdir. Layout:
///   bornp54prog           executable script, exit 42 (cwd candidate)
///   d_exec/bornp54prog    executable script, exit 43
///   d_nonexec/bornp54prog regular file, mode 0644 (latches AccessDenied)
///   d_dir/bornp54prog     a directory (execute bit set, but not a regular file)
///   d_link/bornp54prog    symlink to ../d_exec/bornp54prog (accepted via stat)
fn makePathFixtures(io: Io, d: Io.Dir) !void {
    inline for (.{ "d_exec", "d_nonexec", "d_dir", "d_link" }) |sub| {
        var sd = try d.createDirPathOpen(io, sub, .{});
        sd.close(io);
    }
    try d.writeFile(io, .{ .sub_path = "bornp54prog", .data = "#!/bin/sh\nexit 42\n" });
    try d.writeFile(io, .{ .sub_path = "d_exec/bornp54prog", .data = "#!/bin/sh\nexit 43\n" });
    try d.writeFile(io, .{ .sub_path = "d_nonexec/bornp54prog", .data = "#!/bin/sh\nexit 44\n" });
    var dd = try d.createDirPathOpen(io, "d_dir/bornp54prog", .{});
    dd.close(io);
    try d.symLink(io, "../d_exec/bornp54prog", "d_link/bornp54prog", .{});
    const fd = d.handle;
    if (std.c.fchmodat(fd, "bornp54prog", 0o755, 0) != 0) return error.TestUnexpectedResult;
    if (std.c.fchmodat(fd, "d_exec/bornp54prog", 0o755, 0) != 0) return error.TestUnexpectedResult;
    if (std.c.fchmodat(fd, "d_nonexec/bornp54prog", 0o644, 0) != 0) return error.TestUnexpectedResult;
}

/// Saves the working directory and chdirs into `d`; deinit restores it. Relative
/// PATH entries and the cwd candidate resolve against `d` while it is the cwd.
const CwdGuard = struct {
    saved: [:0]u8,
    fn init(d: Io.Dir) !CwdGuard {
        var buf: [4096]u8 = undefined;
        const p = std.c.getcwd(&buf, buf.len) orelse return error.TestUnexpectedResult;
        const saved = try std.testing.allocator.dupeSentinel(u8, std.mem.span(@as([*:0]u8, @ptrCast(p))), 0);
        errdefer std.testing.allocator.free(saved);
        if (std.c.fchdir(d.handle) != 0) return error.TestUnexpectedResult;
        return .{ .saved = saved };
    }
    fn deinit(self: *CwdGuard) void {
        if (std.c.chdir(self.saved.ptr) != 0) @panic("chdir restore failed");
        std.testing.allocator.free(self.saved);
    }
};

/// Park a wait on a Threaded worker so a public future.cancel can abandon it.
fn waiter(io: Io, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return std.process.Child.wait(child, io);
}

/// Poll until `pid` is gone (killed and reaped). born's FreeBSD close leaves the
/// reap to init (async zombie); Linux reaps on close. A child that was never
/// killed would still run `sleep 30` and keep answering kill(pid, 0).
fn expectPidGone(pid: i32) !void {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| {
            if (err == error.ProcessNotFound) return;
        };
        compat.sleepNs(10 * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

test "process Born route constructs with the process vtable and deinits" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();

    const interface = try initProcIo(&port);
    defer born_io.deinit(interface);
    try expect(std.meta.eql(interface.vtable.*, born_io.process_vtable));

    // All three routes active select the combined vtable.
    var port2 = try born.EvPort.init(std.testing.allocator);
    defer port2.deinit();
    const all = try born_io.io(&port2, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .time = .born_evented, .network = .born_evented, .process = .born_evented },
    });
    defer born_io.deinit(all);
    try expect(std.meta.eql(all.vtable.*, born_io.time_network_process_vtable));
}

test "spawn and wait collect an exit code on Born, then invalidate the child" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 7" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try expect(child.id != null);
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 7), term.exited);
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
    try expectEqual(@as(?Io.File, null), child.stdin);
    try expectEqual(@as(?Io.File, null), child.stdout);
    try expectEqual(@as(?Io.File, null), child.stderr);

    if (born_io.process_stats_enabled) {
        const s = born_io.processStats(io);
        try expect(s.spawn > 0);
        try expect(s.wait > 0);
        try expectEqual(@as(u64, 0), s.threaded_spawn);
        try expectEqual(@as(u64, 0), s.threaded_wait);
    }
}

test "wait collects a signal termination as Term.signal" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "kill -TERM $$" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(std.posix.SIG.TERM, term.signal);
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
}

test "spawn with a stdout pipe: child stream I/O is Threaded, exit is Born" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    try expect(child.stdout != null);
    const out = try readPipeToEnd(io, child.stdout.?);
    defer std.testing.allocator.free(out);
    try expectEqualSlices(u8, "hello", out);

    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 0), term.exited);
    try expectEqual(@as(?Io.File, null), child.stdout);
}

test "spawn honors an explicit environ_map" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("BORN_P54_VAR", "quux");

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf $BORN_P54_VAR" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const out = try readPipeToEnd(io, child.stdout.?);
    defer std.testing.allocator.free(out);
    try expectEqualSlices(u8, "quux", out);
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 0), term.exited);
}

test "spawn with stdin and stdout pipes: parent writes stdin, reads stdout" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    // The child reads one line from stdin and echoes it without the newline,
    // then exits. This exercises all four pipe orientations: the parent writes
    // stdin's write end and reads stdout's read end; the child reads stdin's
    // read end and writes stdout's write end. On half-duplex pipes (Linux) a
    // swapped end is EBADF, so this catches an orientation regression that
    // FreeBSD's full-duplex pipes would mask. The caller does not close the
    // pipes; wait closes the parent ends (the std contract).
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "read line; printf %s \"$line\"" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    try expect(child.stdin != null);
    try expect(child.stdout != null);
    try child.stdin.?.writeStreamingAll(io, "hello\n");
    const out = try readPipeToEnd(io, child.stdout.?);
    defer std.testing.allocator.free(out);
    try expectEqualSlices(u8, "hello", out);
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 0), term.exited);
    try expectEqual(@as(?Io.File, null), child.stdin);
    try expectEqual(@as(?Io.File, null), child.stdout);
}

test "caller-closed stdin end is not closed again by wait (fd-reuse guard)" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    // R1: the std EOF pattern closes child.stdin and nulls the field before
    // waiting. The shim must not close a stale copy of the same end: a fresh
    // pipe opened in between reuses the fd number, and a double close would
    // destroy the fresh pipe's end. The wait thunk owns the close now.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "read line; exit 0" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const stdin_fd = child.stdin.?.handle;
    child.stdin.?.close(io);
    child.stdin = null;

    // The freed number is reusable: a fresh pipe takes it. The child's stdin
    // read end (closed after the fork) is lower than the parent write end, so
    // either fresh end may land on stdin_fd.
    const ends = try compat.pipe2(.{ .CLOEXEC = true });
    defer compat.close(ends[0]);
    defer compat.close(ends[1]);
    try expect(ends[0] == stdin_fd or ends[1] == stdin_fd);

    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 0), term.exited);
    try expectEqual(@as(?Io.File, null), child.stdin);
    // Both fresh ends survived the wait: still open descriptors.
    try expect(std.c.fcntl(ends[0], std.c.F.GETFD) != -1);
    try expect(std.c.fcntl(ends[1], std.c.F.GETFD) != -1);
}

test "caller-closed stdout/stderr ends are not closed again by kill (fd-reuse guard)" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    // R1 kill variant: the caller closes stdout/stderr and nulls the fields
    // before killing. The kill thunk must not double-close the stale ends;
    // fresh pipes reuse the numbers and must survive the kill.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const stdout_fd = child.stdout.?.handle;
    const stderr_fd = child.stderr.?.handle;
    child.stdout.?.close(io);
    child.stdout = null;
    child.stderr.?.close(io);
    child.stderr = null;

    const p1 = try compat.pipe2(.{ .CLOEXEC = true });
    defer compat.close(p1[0]);
    defer compat.close(p1[1]);
    const p2 = try compat.pipe2(.{ .CLOEXEC = true });
    defer compat.close(p2[0]);
    defer compat.close(p2[1]);
    try expect(p1[0] == stdout_fd or p1[1] == stdout_fd or p2[0] == stdout_fd or p2[1] == stdout_fd);
    try expect(p1[0] == stderr_fd or p1[1] == stderr_fd or p2[0] == stderr_fd or p2[1] == stderr_fd);

    std.process.Child.kill(&child, io);
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
    try expectEqual(@as(?Io.File, null), child.stdout);
    try expectEqual(@as(?Io.File, null), child.stderr);
    // All four fresh ends survived the kill.
    try expect(std.c.fcntl(p1[0], std.c.F.GETFD) != -1);
    try expect(std.c.fcntl(p1[1], std.c.F.GETFD) != -1);
    try expect(std.c.fcntl(p2[0], std.c.F.GETFD) != -1);
    try expect(std.c.fcntl(p2[1], std.c.F.GETFD) != -1);
}

test "spawn resolves argv[0] against PATH when it has no slash" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 0), term.exited);
}

test "spawn of a missing program returns FileNotFound" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    try expectError(error.FileNotFound, std.process.spawn(io, .{
        .argv = &.{"/nonexistent/born-p54-no-such-program"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }));
}

test "spawn rejects options born.process cannot express with OperationUnsupported" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    const argv = &.{ "/bin/sh", "-c", "exit 0" };
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .expand_arg0 = .expand }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .stdin = .close }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .stdout = .close }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .stderr = .close }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = "/tmp" } }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .uid = 0 }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .gid = 0 }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .pgid = 0 }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .start_suspended = true }));
    try expectError(error.OperationUnsupported, std.process.spawn(io, .{ .argv = argv, .request_resource_usage_statistics = true }));
}

test "kill terminates a running child, is idempotent, and invalidates the child" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try expect(child.id != null);
    std.process.Child.kill(&child, io);
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
    try expectEqual(@as(?Io.File, null), child.stdin);
    // A second kill is a no-op (the public wrapper asserts id == null).
    std.process.Child.kill(&child, io);
    try expectEqual(@as(?std.process.Child.Id, null), child.id);

    if (born_io.process_stats_enabled) {
        const s = born_io.processStats(io);
        try expect(s.kill > 0);
        try expectEqual(@as(u64, 0), s.threaded_kill);
    }
}

test "kill of an already-exited unwaited child collects the latch and cleans up" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // Let the child exit and the loop latch its exit before killing.
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    std.process.Child.kill(&child, io);
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
}

test "provenance gate: a Threaded-owned child forwards, never serviced on Born" {
    if (skip_unsupported) return error.SkipZigTest;
    var port_b = try born.EvPort.init(std.testing.allocator);
    defer port_b.deinit();
    const baseline = try born_io.io(&port_b, .{ .allocator = std.testing.allocator });
    defer born_io.deinit(baseline);

    var port_p = try born.EvPort.init(std.testing.allocator);
    defer port_p.deinit();
    const io = try initProcIo(&port_p);
    defer born_io.deinit(io);

    // Spawned through the all-Threaded baseline: not in the process registry.
    var child = try std.process.spawn(baseline, .{
        .argv = &.{ "/bin/sh", "-c", "exit 3" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 3), term.exited);

    if (born_io.process_stats_enabled) {
        const s = born_io.processStats(io);
        try expect(s.threaded_wait > 0);
        try expectEqual(@as(u64, 0), s.wait);
    }
}

test "per-route counters prove a spawn/wait/kill exchange ran on Born" {
    if (skip_unsupported) return error.SkipZigTest;
    if (!born_io.process_stats_enabled) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var waited = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try std.process.Child.wait(&waited, io);

    var killed = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    std.process.Child.kill(&killed, io);

    const s = born_io.processStats(io);
    try expect(s.spawn >= 2);
    try expect(s.wait >= 1);
    try expect(s.kill >= 1);
    try expectEqual(@as(u64, 0), s.threaded_spawn);
    try expectEqual(@as(u64, 0), s.threaded_wait);
    try expectEqual(@as(u64, 0), s.threaded_kill);
}

test "process counters report zero when the process_stats option is off" {
    if (skip_unsupported) return error.SkipZigTest;
    if (born_io.process_stats_enabled) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try std.process.Child.wait(&child, io);

    const s = born_io.processStats(io);
    try expectEqual(@as(u64, 0), s.spawn);
    try expectEqual(@as(u64, 0), s.wait);
    try expectEqual(@as(u64, 0), s.kill);
    try expectEqual(@as(u64, 0), s.threaded_spawn);
    try expectEqual(@as(u64, 0), s.threaded_wait);
    try expectEqual(@as(u64, 0), s.threaded_kill);
}

test "deinit kills a still-running child the caller never waited or killed" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    // deinit (no wait/kill) must SIGKILL and reap the running child via
    // childRegistryCloseAll, leaving no zombie.
    born_io.deinit(io);
    child.id = null;
    // deinit SIGKILLs the running child; poll until the pid is gone.
    try expectPidGone(pid);
}

test "PATH search skips a directory candidate and keeps searching" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePathFixtures(io, tmp.dir);
    var cwd = try CwdGuard.init(tmp.dir);
    defer cwd.deinit();
    const saved_path = savePath();
    defer restorePath(saved_path);

    // d_dir/bornp54prog is a directory: it passes an execute-bit test but is not
    // a regular file, so the probe skips it and the search finds d_exec's script.
    setPath("d_dir:d_exec");
    var child = try std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 43), term.exited);
}

test "PATH search accepts a symlink to an executable via stat, not lstat" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePathFixtures(io, tmp.dir);
    var cwd = try CwdGuard.init(tmp.dir);
    defer cwd.deinit();
    const saved_path = savePath();
    defer restorePath(saved_path);

    // d_link/bornp54prog is a symlink; stat follows it to a regular executable.
    // lstat would see a non-regular file and skip it (FileNotFound).
    setPath("d_link");
    var child = try std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 43), term.exited);
}

test "PATH search skips empty tokens: no implicit cwd entry" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePathFixtures(io, tmp.dir);
    var cwd = try CwdGuard.init(tmp.dir);
    defer cwd.deinit();
    const saved_path = savePath();
    defer restorePath(saved_path);

    // The cwd holds an executable bornp54prog (exit 42). An all-empty PATH
    // tokenizes to nothing, so there is no implicit cwd entry: FileNotFound.
    setPath("::");
    try expectError(error.FileNotFound, std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }));
    // Empty tokens around a real entry are skipped; the entry still resolves.
    setPath(":d_exec:");
    var child = try std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 43), term.exited);
}

test "PATH search latches AccessDenied over FileNotFound" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePathFixtures(io, tmp.dir);
    var cwd = try CwdGuard.init(tmp.dir);
    defer cwd.deinit();
    const saved_path = savePath();
    defer restorePath(saved_path);

    const argv = &.{"bornp54prog"};
    const opts = std.process.SpawnOptions{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    };
    // A regular non-executable candidate latches AccessDenied.
    setPath("d_nonexec");
    try expectError(error.AccessDenied, std.process.spawn(io, opts));
    // A missing candidate continues the search; the latched AccessDenied wins.
    setPath("d_nonexec:d_missing");
    try expectError(error.AccessDenied, std.process.spawn(io, opts));
    setPath("d_missing:d_nonexec");
    try expectError(error.AccessDenied, std.process.spawn(io, opts));
    // Nothing matched and nothing latched: FileNotFound.
    setPath("d_missing");
    try expectError(error.FileNotFound, std.process.spawn(io, opts));
}

test "PATH execute-bit probe uses faccessat AT_EACCESS (effective uid)" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePathFixtures(io, tmp.dir);
    var cwd = try CwdGuard.init(tmp.dir);
    defer cwd.deinit();
    const saved_path = savePath();
    defer restorePath(saved_path);

    // The probe is faccessat(AT_FDCWD, path, X_OK, AT_EACCESS): effective uid,
    // matching execve, not access(X_OK) (real uid, which diverges for a setuid
    // parent). The test process has real == effective uid, so the two probes
    // coincide here; the setuid divergence is covered by the code path using
    // AT_EACCESS on both kernels. Observable contract: a non-executable regular
    // file is denied, an executable regular file is accepted.
    setPath("d_nonexec");
    try expectError(error.AccessDenied, std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }));
    setPath("d_exec");
    var child = try std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 43), term.exited);
}

test "PATH resolution uses the parent environ, never environ_map's PATH" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePathFixtures(io, tmp.dir);
    var cwd = try CwdGuard.init(tmp.dir);
    defer cwd.deinit();
    const saved_path = savePath();
    defer restorePath(saved_path);

    // Parent PATH points at d_exec; environ_map's PATH is a dead directory.
    // argv[0] must resolve via the parent PATH (exit 43), not environ_map's.
    setPath("d_exec");
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent/born-p54");
    var child = try std.process.spawn(io, .{
        .argv = &.{"bornp54prog"},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 43), term.exited);
}

test "spawn uses the per-toolchain default PATH when the parent has none" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    // The shim mirrors each toolchain's own Io.Threaded.default_PATH at comptime.
    const expected = if (is_017) "/usr/local/bin:/bin:/usr/bin" else "/usr/local/bin:/bin/:/usr/bin";
    try expectEqualSlices(u8, expected, Io.Threaded.default_PATH);

    const saved_path = savePath();
    defer restorePath(saved_path);
    clearPath();
    // "sh" has no slash: resolvePath falls back to the default PATH (/bin/sh).
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try std.process.Child.wait(&child, io);
    try expectEqual(@as(u8, 0), term.exited);
}

test "canceled wait abandons the child: running, stdio closed, id null, Canceled" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    const stdout_fd = child.stdout.?.handle;

    // Park a wait on a worker, then cancel it through the public future API.
    var future = try Io.concurrent(io, waiter, .{ io, &child });
    try Io.sleep(io, .fromMilliseconds(50), .awake);
    try expectError(error.Canceled, future.cancel(io));

    // Abandon (6.3): the caller's fields are invalidated, the child still runs.
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
    try expectEqual(@as(?Io.File, null), child.stdin);
    try expectEqual(@as(?Io.File, null), child.stdout);
    try expectEqual(@as(?Io.File, null), child.stderr);
    try std.posix.kill(pid, @enumFromInt(0));
    // The wait thunk's cancel path closed the pipe parent end (review R1):
    // the descriptor is no longer open.
    try expect(std.c.fcntl(stdout_fd, std.c.F.GETFD) == -1);

    // The loop reaps the abandoned child when its exit arrives (still watched).
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    try expectPidGone(pid);
}

test "deinit kills a still-running abandoned child" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    var future = try Io.concurrent(io, waiter, .{ io, &child });
    try Io.sleep(io, .fromMilliseconds(50), .awake);
    try expectError(error.Canceled, future.cancel(io));
    try expectEqual(@as(?std.process.Child.Id, null), child.id);
    // Abandoned and still running; deinit must SIGKILL and reap it.
    try std.posix.kill(pid, @enumFromInt(0));
    born_io.deinit(io);
    try expectPidGone(pid);
}

const ConcurrentSpawn = struct {
    io: Io,
    iterations: u32,
    success: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    // First-failure capture: the failure count alone throws away the error
    // name, which the #114 signature needs. First writer wins the claim;
    // the slot is read after join, when every writer has finished.
    claimed: std.atomic.Value(bool) = .init(false),
    first_failure: ?SpawnFailure = null,

    fn recordFailure(self: *ConcurrentSpawn, failure: SpawnFailure) void {
        _ = self.failed.fetchAdd(1, .monotonic);
        if (self.claimed.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
            self.first_failure = failure;
        }
    }
};

const SpawnFailure = struct {
    worker: usize,
    iteration: u32,
    kind: enum { spawn, wait, term },
    err_name: ?[]const u8 = null,
    term: ?std.process.Child.Term = null,
};

fn concurrentSpawnWorker(ctx: *ConcurrentSpawn, worker: usize) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        var child = std.process.spawn(ctx.io, .{
            .argv = &.{ "/bin/sh", "-c", "exit 0" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            ctx.recordFailure(.{ .worker = worker, .iteration = i, .kind = .spawn, .err_name = @errorName(err) });
            return;
        };
        const term = std.process.Child.wait(&child, ctx.io) catch |err| {
            ctx.recordFailure(.{ .worker = worker, .iteration = i, .kind = .wait, .err_name = @errorName(err) });
            return;
        };
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (ok) {
            _ = ctx.success.fetchAdd(1, .monotonic);
        } else {
            ctx.recordFailure(.{ .worker = worker, .iteration = i, .kind = .term, .term = term });
        }
    }
}

test "concurrent spawn/wait from many workers runs on Born without lost wakeups" {
    if (skip_unsupported) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initProcIo(&port);
    defer born_io.deinit(io);

    // Regression guard for the FreeBSD arm-flush lost wakeup: the flush sits
    // between the queue drain and the blocking wait and can harvest a worker's
    // wake for an op queued during the flush, leaving the loop blocked on a
    // non-empty queue. Many concurrent spawn/wait round-trips exercise that
    // race; a lost wakeup stalls a worker forever (the join never returns).
    const workers = 16;
    const iterations = 24;
    var ctx = ConcurrentSpawn{ .io = io, .iterations = iterations };
    var threads: [workers]std.Thread = undefined;
    for (&threads, 0..) |*t, wi| t.* = try std.Thread.spawn(.{}, concurrentSpawnWorker, .{ &ctx, wi });
    for (threads) |t| t.join();
    if (ctx.first_failure) |f| {
        std.debug.print("first spawn/wait failure: worker {d} iteration {d}: ", .{ f.worker, f.iteration });
        switch (f.kind) {
            .spawn => std.debug.print("spawn error {s}\n", .{f.err_name.?}),
            .wait => std.debug.print("wait error {s}\n", .{f.err_name.?}),
            .term => switch (f.term.?) {
                .exited => |code| std.debug.print("child exited {d}\n", .{code}),
                .signal => |sig| std.debug.print("child killed by signal {s}\n", .{@tagName(sig)}),
                .stopped => |sig| std.debug.print("child stopped by signal {s}\n", .{@tagName(sig)}),
                .unknown => |v| std.debug.print("child unknown termination {d}\n", .{v}),
            },
        }
    }
    try expectEqual(@as(u64, 0), ctx.failed.load(.monotonic));
    try expectEqual(@as(u64, workers * iterations), ctx.success.load(.monotonic));
    if (born_io.process_stats_enabled) {
        const s = born_io.processStats(io);
        try expect(s.spawn >= workers * iterations);
        try expect(s.wait >= workers * iterations);
        try expectEqual(@as(u64, 0), s.threaded_spawn);
        try expectEqual(@as(u64, 0), s.threaded_wait);
        try expectEqual(@as(u64, 0), s.threaded_kill);
    }
}
