//! Process contract: spawn, watchProcess and the exit event. Every test
//! calls the real API and skips where the target returns
//! error.Unsupported (every target but FreeBSD and Linux).

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const born = @import("root.zig");
const process = born.process;
const Event = born.Event;
const alloc = std.testing.allocator;
const posix = compat;

const no_env = [_:null]?[*:0]const u8{};

fn spawnOrSkip(argv: [*:null]const ?[*:0]const u8, opts: process.SpawnOptions) !process.Child {
    return process.spawn(argv, &no_env, opts) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

fn sh(comptime script: [:0]const u8) [*:null]const ?[*:0]const u8 {
    const argv = struct {
        const v = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
    };
    return &argv.v;
}

const sleep_long = [_:null]?[*:0]const u8{ "/bin/sleep", "30" };

/// Waits up to `window_ms` for the exit event carrying `udata`. Wake events
/// are ignored; any other event must be that exit, with no readiness, timer,
/// or signal fields set.
fn waitExit(port: *born.EvPort, udata: *anyopaque, window_ms: u64) !Event {
    var events: [8]Event = undefined;
    const start = try compat.monotonicNs();
    while (true) {
        const elapsed = (try compat.monotonicNs() - start) / std.time.ns_per_ms;
        if (elapsed >= window_ms) return error.TestExpectedExit;
        const n = try port.wait(&events, @intCast(window_ms - elapsed));
        for (events[0..n]) |ev| {
            if (ev.wake) continue;
            try std.testing.expect(ev.udata == udata);
            try std.testing.expect(ev.exited);
            try std.testing.expect(!ev.readable and !ev.writable and !ev.timer and ev.signal == null);
            return ev;
        }
    }
}

/// The process table no longer holds `pid`, zombie or not. Polls for up to
/// two seconds: a running FreeBSD child whose descriptor was closed is
/// reaped by init.
fn expectGone(pid: i32) !void {
    const start = try compat.monotonicNs();
    while (try compat.monotonicNs() - start < 2 * std.time.ns_per_s) {
        if (try gone(pid)) return;
        compat.sleepNs(10 * std.time.ns_per_ms);
    }
    return error.TestProcessNotReaped;
}

fn gone(pid: i32) !bool {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var info: linux.siginfo_t = undefined;
            // ECHILD: no child with this pid is left to wait for.
            const rc = compat.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT);
            return compat.linuxErrno(rc) == .CHILD;
        },
        .freebsd => {
            // kern.proc.pid lists zombies too.
            const mib = [4]c_int{ 1, 14, 1, pid }; // CTL_KERN, KERN_PROC, KERN_PROC_PID
            var len: usize = 0;
            if (std.c.sysctl(&mib, mib.len, null, &len, null, 0) != 0) {
                return switch (std.posix.errno(@as(c_int, -1))) {
                    .SRCH => true,
                    else => error.Unexpected,
                };
            }
            return len == 0;
        },
        else => return error.SkipZigTest,
    }
}

fn close(fd: posix.fd_t) void {
    posix.close(fd);
}

test "process: exit code arrives through wait and the child is reaped" {
    if (!process.supported) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var child = try spawnOrSkip(sh("exit 7"), .{});
    var tag: u8 = 0;
    try port.watchProcess(child.handle, &tag);
    const ev = try waitExit(&port, &tag, 5000);
    try std.testing.expect(!ev.err);
    try std.testing.expectEqual(born.ProcessExit{ .code = 7 }, ev.exit.?);
    // The watch ended with the event.
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 50));
    port.purgeFd(child.handle);
    child.close();
    try expectGone(child.pid);
}

test "process: a signal-killed child reports the signal" {
    if (!process.supported) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    // Block and ignore SIGTERM here: the child must still start with an
    // empty mask and default dispositions, so the signal ends it.
    const signo = compat.signalNumber(std.posix.SIG.TERM);
    var term = posix.sigemptyset();
    posix.sigaddset(&term, signo);
    var mask: posix.sigset_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), compat.pthreadSigmask(std.posix.SIG.BLOCK, &term, &mask));
    defer _ = compat.pthreadSigmask(std.posix.SIG.SETMASK, &mask, &term);
    const ignore: posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    var prior: posix.Sigaction = undefined;
    posix.sigaction(signo, &ignore, &prior);
    defer posix.sigaction(signo, &prior, null);

    var child = try spawnOrSkip(&sleep_long, .{});
    defer child.close();
    var tag: u8 = 0;
    try port.watchProcess(child.handle, &tag);
    try child.kill(signo);
    const ev = try waitExit(&port, &tag, 5000);
    try std.testing.expect(!ev.err);
    try std.testing.expectEqual(born.ProcessExit{ .signal = signo }, ev.exit.?);
    // Linux reaped the child in wait(); FreeBSD keeps the zombie, which
    // still accepts (and ignores) signals until close.
    if (builtin.os.tag == .linux) {
        try std.testing.expectError(error.Exited, child.kill(signo));
    } else {
        try child.kill(signo);
    }
    port.purgeFd(child.handle);
}

test "process: mapped handles become fds 3 and up, nothing else is inherited" {
    if (!process.supported) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var pair: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &pair));
    defer close(pair[0]);
    const out = try posix.pipe2(.{ .CLOEXEC = true });
    defer close(out[0]);
    // Inheritable on purpose: only the child's closefrom keeps it out.
    const stray = try posix.pipe2(.{ .NONBLOCK = true });
    defer close(stray[0]);

    var child = try spawnOrSkip(sh("echo three >&3; echo four >&4; exec 3>&- 4>&-; sleep 1"), .{
        .stdin = .devnull,
        .fds = &.{ out[1], pair[1] },
    });
    defer child.close();
    close(out[1]);
    close(pair[1]);
    close(stray[1]);
    var tag: u8 = 0;
    try port.watchProcess(child.handle, &tag);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("three\n", buf[0..try readAll(out[0], &buf)]);
    try std.testing.expectEqualStrings("four\n", buf[0..try readAll(pair[0], &buf)]);
    // EOF, not WouldBlock, while the child still runs: it never held the
    // stray write end.
    try std.testing.expectEqual(@as(usize, 0), try posix.read(stray[0], &buf));
    const ev = try waitExit(&port, &tag, 5000);
    try std.testing.expectEqual(born.ProcessExit{ .code = 0 }, ev.exit.?);
    port.purgeFd(child.handle);
}

/// Reads until EOF (blocking descriptors).
fn readAll(fd: posix.fd_t, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const got = try posix.read(fd, buf[n..]);
        if (got == 0) break;
        n += got;
    }
    return n;
}

test "process: unwatch then close kills a running child" {
    if (!process.supported) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const life = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer close(life[0]);
    var child = try spawnOrSkip(&sleep_long, .{ .fds = &.{life[1]} });
    close(life[1]);
    var tag: u8 = 0;
    try port.watchProcess(child.handle, &tag);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 20));
    port.unwatchProcess(child.handle);
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    // sleep holds the pipe's write end as fd 3 until it dies.
    var pipe_tag: u8 = 0;
    port.monitorRead(life[0], &pipe_tag);
    child.close();
    const start = try compat.monotonicNs();
    var eof = false;
    while (!eof and try compat.monotonicNs() - start < 5 * std.time.ns_per_s) {
        const n = try port.wait(&events, 1000);
        for (events[0..n]) |ev| {
            try std.testing.expect(ev.udata == @as(?*anyopaque, &pipe_tag));
            try std.testing.expect(!ev.exited);
            eof = eof or ev.eof;
        }
    }
    try std.testing.expect(eof);
    try expectGone(child.pid);
    port.purgeFd(life[0]);
}

test "process: an exit is delivered among timer and descriptor events" {
    if (!process.supported) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var pair: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0, &pair));
    defer close(pair[0]);
    defer close(pair[1]);
    var child = try spawnOrSkip(sh("exit 3"), .{});
    defer child.close();
    var exit_tag: u8 = 0;
    var timer_tag: u8 = 0;
    var sock_tag: u8 = 0;
    try port.watchProcess(child.handle, &exit_tag);
    try port.addTimer(1, &timer_tag, 10, .once);
    port.monitorRead(pair[0], &sock_tag);
    _ = try posix.write(pair[1], "x");

    var saw_exit = false;
    var saw_timer = false;
    var saw_sock = false;
    var events: [8]Event = undefined;
    const start = try compat.monotonicNs();
    while (!(saw_exit and saw_timer and saw_sock) and try compat.monotonicNs() - start < 5 * std.time.ns_per_s) {
        const n = try port.wait(&events, 1000);
        for (events[0..n]) |ev| {
            try std.testing.expect(!ev.err);
            if (ev.udata == @as(?*anyopaque, &exit_tag)) {
                try std.testing.expect(ev.exited and !ev.timer and !ev.readable);
                try std.testing.expectEqual(born.ProcessExit{ .code = 3 }, ev.exit.?);
                saw_exit = true;
            } else if (ev.udata == @as(?*anyopaque, &timer_tag)) {
                try std.testing.expect(ev.timer and !ev.exited);
                saw_timer = true;
            } else if (ev.udata == @as(?*anyopaque, &sock_tag)) {
                try std.testing.expect(ev.readable and !ev.exited and ev.exit == null);
                saw_sock = true;
            } else return error.TestUnexpectedEvent;
        }
    }
    try std.testing.expect(saw_exit and saw_timer and saw_sock);
    port.purgeFd(pair[0]);
    port.purgeFd(child.handle);
}

test "process: watching a child that already exited fires at once" {
    if (!process.supported) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var child = try spawnOrSkip(sh("exit 0"), .{});
    defer child.close();
    // Establish the exit without reaping, so the premise is never a race.
    // Linux: a blocking WNOWAIT waitid (does not reap). FreeBSD: harvest
    // the exit on a first port (which ends that watch), then the zombie is
    // known good for the second watch below.
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var info: linux.siginfo_t = undefined;
            while (compat.linuxErrno(compat.waitid(.PIDFD, child.handle, &info, linux.W.EXITED | linux.W.NOWAIT)) == .INTR) {}
        },
        .freebsd => {
            var first = try born.EvPort.init(alloc);
            try first.watchProcess(child.handle, null);
            var events: [4]Event = undefined;
            var saw = false;
            const start = try compat.monotonicNs();
            while (!saw and try compat.monotonicNs() - start < 5 * std.time.ns_per_s) {
                const n = try first.wait(&events, 1000);
                for (events[0..n]) |ev| saw = saw or ev.exited;
            }
            first.deinit();
            try std.testing.expect(saw);
        },
        else => return error.SkipZigTest,
    }
    var tag: u8 = 0;
    try port.watchProcess(child.handle, &tag);
    const ev = try waitExit(&port, &tag, 5000);
    try std.testing.expectEqual(born.ProcessExit{ .code = 0 }, ev.exit.?);
    port.purgeFd(child.handle);
}

test "process: rapid spawn of a short program never loses the exit status" {
    if (!process.supported) return error.SkipZigTest;
    // Smoke test: a short program may exit before spawn's feature probe
    // runs; every exit must still arrive with the status, never err.
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var child = try spawnOrSkip(sh("exit 0"), .{});
        var tag = i;
        try port.watchProcess(child.handle, &tag);
        const ev = try waitExit(&port, &tag, 5000);
        try std.testing.expect(!ev.err);
        try std.testing.expectEqual(born.ProcessExit{ .code = 0 }, ev.exit.?);
        port.purgeFd(child.handle);
        child.close();
        try expectGone(child.pid);
    }
}

test "process: exec and setup failures are spawn errors" {
    if (!process.supported) return error.SkipZigTest;
    const missing = [_:null]?[*:0]const u8{"/nonexistent/born-test-program"};
    try std.testing.expectError(error.FileNotFound, spawnOrSkip(&missing, .{}));
    // fd 1000 is not open, so the child cannot map it.
    try std.testing.expectError(error.SetupFailed, spawnOrSkip(&sleep_long, .{ .fds = &.{1000} }));
    const empty = [_:null]?[*:0]const u8{};
    try std.testing.expectError(error.InvalidArgument, spawnOrSkip(&empty, .{}));
}

test "process: unsupported targets refuse spawn and watch" {
    if (process.supported) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, process.spawn(&sleep_long, &no_env, .{}));
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const handle: born.Handle = if (builtin.os.tag == .windows) compat.windows.INVALID_HANDLE_VALUE else 0;
    try std.testing.expectError(error.Unsupported, port.watchProcess(handle, null));
    port.unwatchProcess(handle);
}
