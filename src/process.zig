//! Child processes behind a descriptor: `spawn` starts a program and returns
//! a `Child` whose handle `EvPort.watchProcess` turns into an exit event.
//!
//!   FreeBSD  pdfork(PD_CLOEXEC) process descriptor, pdkill
//!   Linux    clone(CLONE_PIDFD) pidfd, pidfd_send_signal; kernel 5.4+,
//!            probed at spawn (CLONE_PIDFD is 5.2, waitid(P_PIDFD) is 5.4)
//!   others   error.Unsupported
//!
//! `spawn` allocates nothing: argv, envp and the descriptor map are ready
//! before the fork, and between fork and execve the child makes only
//! async-signal-safe calls (libc calls after libthr's pdfork on FreeBSD, raw
//! syscalls after a raw clone on Linux). On FreeBSD libthr runs the
//! program's pthread_atfork handlers around pdfork, so any handler must
//! obey the same rule; born registers none. A multi-threaded caller is
//! safe. The child:
//!   - starts with every signal at its default disposition and an empty
//!     signal mask, whatever the parent ignores, handles or blocks;
//!   - gets `stdin`, `stdout`, `stderr` as asked and `fds[i]` as fd 3 + i;
//!   - has every other descriptor closed before execve.
//! A close-on-exec pipe carries a setup or execve failure back, so `spawn`
//! returns it as an error and reaps the failed child. `spawn` therefore
//! returns once the child has called execve, as posix_spawn does.
//!
//! Lifetime and reaping:
//!   - FreeBSD: the kernel keeps the exited child as a zombie until
//!     `Child.close` closes the descriptor, which reaps it. Closing the
//!     descriptor of a running child kills it with SIGKILL and leaves the
//!     reaping to its reaper (init), without waiting. A pdfork child sends
//!     no SIGCHLD and is invisible to wait(2) for any child.
//!   - Linux: the wait() that reports a watched child's exit reaps it.
//!     `Child.close` reaps a child that was never reported and never blocks
//!     the caller: an exited child is collected on the spot, a running one
//!     gets SIGKILL and its pidfd goes to a lazily spawned background
//!     reaper thread (only an allocation failure there degrades to a
//!     blocking reap). The parent gets SIGCHLD as usual, and a wait(2) for
//!     any child elsewhere in the program can steal the status (the exit
//!     event then arrives with `err` set).
//! Event-loop code should still `kill`, wait for the exit event, then
//! `purgeFd` and `close`, which keeps every reap on the spot.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Handle = types.Handle;

const os = builtin.os.tag;
/// Process descriptors exist on this target (FreeBSD and Linux).
pub const supported = os == .freebsd or os == .linux;

/// Most caller handles `SpawnOptions.fds` may map.
pub const max_fds = 64;

/// What a child's standard descriptor is.
pub const Stdio = union(enum) {
    /// The parent's descriptor of the same number.
    inherit,
    /// /dev/null, opened read-write.
    devnull,
    /// A caller handle, duplicated onto the descriptor.
    handle: Handle,
};

/// Spawn-time options; the module comment describes the child's starting
/// state. All fields default to inheriting the parent.
pub const SpawnOptions = struct {
    /// Program to execute; argv[0] when null. No PATH search.
    path: ?[*:0]const u8 = null,
    /// The child's fd 0.
    stdin: Stdio = .inherit,
    /// The child's fd 1.
    stdout: Stdio = .inherit,
    /// The child's fd 2.
    stderr: Stdio = .inherit,
    /// Caller handles that become the child's fds 3, 4, ... in order. They
    /// need not be inheritable; the child gets its own copies.
    fds: []const Handle = &.{},
};

/// `spawn`.
pub const SpawnError = error{
    /// No process descriptors on this target, or a Linux kernel too old
    /// for pidfd child watching: both features are probed at spawn
    /// (CLONE_PIDFD needs 5.2, waitid(P_PIDFD) needs 5.4).
    Unsupported,
    /// No program (null `path` and empty argv), more than `max_fds`
    /// handles, or a negative handle.
    InvalidArgument,
    /// The kernel refused a process, descriptor or memory (EAGAIN, EMFILE,
    /// ENFILE, ENOMEM, E2BIG).
    SystemResources,
    /// execve: the program or a directory on its path does not exist.
    FileNotFound,
    /// execve: permission denied.
    AccessDenied,
    /// execve: not an executable format, or busy for writing.
    InvalidExe,
    /// The child could not set up its descriptors or signals before
    /// execve, e.g. a mapped handle that is not open.
    SetupFailed,
    /// execve failed for another reason.
    ExecFailed,
};

/// `Child.kill`.
pub const KillError = error{
    Unsupported,
    /// Linux: the child has been reaped (its exit was reported or `close`
    /// ran). FreeBSD keeps an exited child signalable, a no-op, until its
    /// descriptor is closed, so there a signal after the exit succeeds.
    Exited,
    InvalidSignal,
    /// The handle is not open or not a process descriptor.
    BadHandle,
    AccessDenied,
};

/// A spawned child: its descriptor (watchable with `EvPort.watchProcess`)
/// and pid. See the module comment for lifetime and reaping.
pub const Child = struct {
    /// Process descriptor (FreeBSD) or pidfd (Linux); pass it to
    /// `EvPort.watchProcess`. Close-on-exec in the parent.
    handle: Handle,
    pid: i32,

    /// Sends signal number `sig` (`std.posix.SIG`) through the descriptor,
    /// so it can never reach a recycled pid.
    pub fn kill(self: Child, sig: u8) KillError!void {
        if (comptime !supported) return KillError.Unsupported;
        return sys.kill(self.handle, sig);
    }

    /// Closes the descriptor; see the module comment for what happens to
    /// the process. Call `EvPort.purgeFd(child.handle)` first if a port
    /// watches it.
    pub fn close(self: *Child) void {
        if (comptime !supported) return;
        sys.close(self.handle);
        self.handle = -1;
    }
};

/// Starts `path` (or argv[0]) with `argv` and `envp` and returns its
/// descriptor. Returns after the child has called execve; see the module
/// comment for the child's starting state.
pub fn spawn(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    opts: SpawnOptions,
) SpawnError!Child {
    if (comptime !supported) return SpawnError.Unsupported;
    return spawnPosix(argv, envp, opts);
}

// ----------------------------------------------------------- shared ----

/// Child setup stages a failure report names.
const Stage = enum(u32) { setup = 1, exec = 2 };

/// What the child writes to the error pipe before exiting with 127.
const Report = extern struct { stage: u32, errno: u32 };

/// Everything the child needs, prepared before the fork.
const Plan = struct {
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// Source for child fd i, or -1 to leave fd i as inherited.
    src: [3 + max_fds]i32 = .{-1} ** (3 + max_fds),
    /// Child fds 0 .. count-1 are the targets.
    count: usize,
    err_w: i32,
};

fn spawnPosix(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    opts: SpawnOptions,
) SpawnError!Child {
    const path = opts.path orelse argv[0] orelse return SpawnError.InvalidArgument;
    if (opts.fds.len > max_fds) return SpawnError.InvalidArgument;
    for (opts.fds) |fd| if (fd < 0) return SpawnError.InvalidArgument;
    const stdio = [_]Stdio{ opts.stdin, opts.stdout, opts.stderr };

    var devnull: i32 = -1;
    defer if (devnull != -1) closeFd(devnull);
    for (stdio) |s| switch (s) {
        .inherit => {},
        .handle => |h| if (h < 0) return SpawnError.InvalidArgument,
        .devnull => if (devnull == -1) {
            devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(std.c.mode_t, 0));
            if (devnull < 0) return switch (std.posix.errno(devnull)) {
                .MFILE, .NFILE, .NOMEM => SpawnError.SystemResources,
                else => SpawnError.SetupFailed,
            };
        },
    };

    const pipe = std.posix.pipe2(.{ .CLOEXEC = true }) catch return SpawnError.SystemResources;
    const err_r: i32 = pipe[0];
    defer closeFd(err_r);
    var err_w: i32 = pipe[1];
    defer if (err_w != -1) closeFd(err_w);

    var plan: Plan = .{ .path = path, .argv = argv, .envp = envp, .count = 3 + opts.fds.len, .err_w = err_w };
    for (stdio, 0..) |s, i| plan.src[i] = switch (s) {
        .inherit => -1,
        .devnull => devnull,
        .handle => |h| h,
    };
    for (opts.fds, 3..) |fd, i| plan.src[i] = fd;

    // Every signal stays blocked from before the fork until the child has
    // reset its dispositions, so no parent handler runs in the child.
    var all = std.posix.sigfillset();
    var saved: std.posix.sigset_t = undefined;
    if (std.c.pthread_sigmask(std.posix.SIG.SETMASK, &all, &saved) != 0) return SpawnError.SystemResources;
    const forked = sys.fork(&plan);
    // Restoring a mask pthread_sigmask just returned cannot fail.
    _ = std.c.pthread_sigmask(std.posix.SIG.SETMASK, &saved, &all);
    var child = try forked;

    closeFd(err_w);
    err_w = -1;
    var report: Report = undefined;
    const got = readReport(err_r, &report) catch {
        child.close();
        return SpawnError.SystemResources;
    };
    if (!got) return child;
    child.close();
    return switch (@as(Stage, @enumFromInt(report.stage))) {
        .setup => SpawnError.SetupFailed,
        .exec => execError(report.errno),
    };
}

/// True with the child's report, false at EOF (the pipe closed on execve).
fn readReport(fd: i32, out: *Report) error{ReadFailed}!bool {
    const bytes = std.mem.asBytes(out);
    var have: usize = 0;
    while (have < bytes.len) {
        const rc = std.c.read(fd, bytes[have..].ptr, bytes.len - have);
        if (rc < 0) switch (std.posix.errno(rc)) {
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (rc == 0) break;
        have += @intCast(rc);
    }
    if (have == 0) return false;
    if (have != bytes.len) return error.ReadFailed;
    if (out.stage != @intFromEnum(Stage.setup) and out.stage != @intFromEnum(Stage.exec)) return error.ReadFailed;
    return true;
}

fn execError(errno: u32) SpawnError {
    const e: std.posix.E = @enumFromInt(errno);
    return switch (e) {
        .NOENT, .NOTDIR => SpawnError.FileNotFound,
        .ACCES, .PERM => SpawnError.AccessDenied,
        .NOEXEC, .TXTBSY => SpawnError.InvalidExe,
        .NOMEM, .@"2BIG", .MFILE, .NFILE, .AGAIN => SpawnError.SystemResources,
        else => SpawnError.ExecFailed,
    };
}

fn closeFd(fd: i32) void {
    _ = std.c.close(fd);
}

/// The child side, generic over the OS's async-signal-safe calls. Each
/// call returns an errno, 0 on success. Never returns: execve, or a report
/// and exit(127).
fn runChild(comptime S: type, plan: *const Plan) noreturn {
    const n: i32 = @intCast(plan.count);
    var e = S.blockAll();
    if (e != 0) S.fail(plan.err_w, .setup, e);
    // Keep the error pipe clear of the target range.
    var err_w: i32 = -1;
    e = S.dupAbove(plan.err_w, n, &err_w);
    if (e != 0) S.fail(plan.err_w, .setup, e);
    e = S.defaultSignals();
    if (e != 0) S.fail(err_w, .setup, e);
    // Copy every source above the targets first, so placing one target
    // never overwrites another's source.
    var high: [3 + max_fds]i32 = undefined;
    for (0..plan.count) |i| {
        high[i] = -1;
        if (plan.src[i] < 0) continue;
        e = S.dupAbove(plan.src[i], n, &high[i]);
        if (e != 0) S.fail(err_w, .setup, e);
    }
    for (0..plan.count) |i| {
        if (high[i] < 0) continue;
        e = S.dup2(high[i], @intCast(i));
        if (e != 0) S.fail(err_w, .setup, e);
    }
    // Everything from n up goes, except the close-on-exec error pipe.
    if (err_w > n) {
        e = S.closeRange(@intCast(n), @intCast(err_w - 1));
        if (e != 0) S.fail(err_w, .setup, e);
    }
    e = S.closeRange(@intCast(err_w + 1), std.math.maxInt(u32));
    if (e != 0) S.fail(err_w, .setup, e);
    e = S.emptyMask();
    if (e != 0) S.fail(err_w, .setup, e);
    S.fail(err_w, .exec, S.execve(plan.path, plan.argv, plan.envp));
}

// ---------------------------------------------------------- FreeBSD ----

const freebsd = struct {
    extern "c" fn pdfork(fdp: *c_int, flags: c_int) std.c.pid_t;
    extern "c" fn pdkill(fd: c_int, signum: c_int) c_int;
    extern "c" fn close_range(lowfd: c_uint, highfd: c_uint, flags: c_int) c_int;
    const PD_CLOEXEC: c_int = 0x2;
    /// _SIG_MAXSIG.
    const sig_max = 128;

    fn fork(plan: *const Plan) SpawnError!Child {
        var pd: c_int = -1;
        const pid = pdfork(&pd, PD_CLOEXEC);
        // pdfork fails with EAGAIN, ENOMEM, EMFILE or ENFILE.
        if (pid < 0) return SpawnError.SystemResources;
        if (pid == 0) runChild(ChildSide, plan);
        return .{ .handle = pd, .pid = pid };
    }

    fn kill(fd: c_int, sig: u8) KillError!void {
        if (pdkill(fd, sig) == 0) return;
        return switch (std.posix.errno(@as(c_int, -1))) {
            .SRCH => KillError.Exited,
            // procdesc_find answers EINVAL for a descriptor of another type.
            .INVAL => if (sig > sig_max) KillError.InvalidSignal else KillError.BadHandle,
            .BADF => KillError.BadHandle,
            else => KillError.AccessDenied,
        };
    }

    /// The kernel reaps or kills; nothing to wait for.
    fn close(fd: c_int) void {
        _ = std.c.close(fd);
    }

    /// libc after libthr's pdfork, which re-initializes its locks in the
    /// child as for fork(2); every call here is async-signal-safe.
    const ChildSide = struct {
        fn errno() u32 {
            return @intFromEnum(std.posix.errno(@as(c_int, -1)));
        }

        fn blockAll() u32 {
            const all = std.posix.sigfillset();
            return if (std.c.sigprocmask(std.posix.SIG.SETMASK, &all, null) == 0) 0 else errno();
        }

        fn dupAbove(fd: i32, min: i32, out: *i32) u32 {
            const rc = std.c.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, min);
            if (rc < 0) return errno();
            out.* = rc;
            return 0;
        }

        fn dup2(from: i32, to: i32) u32 {
            return if (std.c.dup2(from, to) < 0) errno() else 0;
        }

        fn closeRange(lo: u32, hi: u32) u32 {
            return if (close_range(lo, hi, 0) < 0) errno() else 0;
        }

        fn defaultSignals() u32 {
            const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
            var sig: c_int = 1;
            while (sig <= sig_max) : (sig += 1) {
                if (sig == std.posix.SIG.KILL or sig == std.posix.SIG.STOP) continue;
                if (std.c.sigaction(sig, &dfl, null) == 0) continue;
                // EINVAL: a signal libthr reserves for itself (SIGTHR).
                const e = errno();
                if (e != @intFromEnum(std.posix.E.INVAL)) return e;
            }
            return 0;
        }

        fn emptyMask() u32 {
            const none = std.posix.sigemptyset();
            return if (std.c.sigprocmask(std.posix.SIG.SETMASK, &none, null) == 0) 0 else errno();
        }

        fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) u32 {
            _ = std.c.execve(path, argv, envp);
            return errno();
        }

        fn fail(fd: i32, stage: Stage, e: u32) noreturn {
            const report: Report = .{ .stage = @intFromEnum(stage), .errno = e };
            // Nothing is left to report a failed write to; the exit code
            // still says the child never ran its program.
            _ = std.c.write(fd, std.mem.asBytes(&report), @sizeOf(Report));
            std.c._exit(127);
        }
    };
};

// ------------------------------------------------------------ Linux ----

const linux_impl = struct {
    const linux = std.os.linux;
    /// F_LINUX_SPECIFIC_BASE + 6, the same on every architecture.
    const F_DUPFD_CLOEXEC = 1030;

    fn fork(plan: *const Plan) SpawnError!Child {
        var pidfd: i32 = -1;
        // A raw clone with no new stack forks; CLONE_PIDFD stores the pidfd
        // (close-on-exec) through the parent_tid argument.
        const rc = linux.syscall5(.clone, linux.CLONE.PIDFD | linux.SIG.CHLD, 0, @intFromPtr(&pidfd), 0, 0);
        switch (linux.E.init(rc)) {
            .SUCCESS => {},
            .INVAL, .NOSYS => return SpawnError.Unsupported,
            else => return SpawnError.SystemResources,
        }
        if (rc == 0) runChild(ChildSide, plan);
        const pid: i32 = @intCast(rc);
        if (!pidfdUsable(pidfd, pid)) return SpawnError.Unsupported;
        return .{ .handle = pidfd, .pid = pid };
    }

    /// True when the child is fully watchable. Legacy clone ignores flags
    /// it does not know, so below 5.2 a successful clone stores no pidfd,
    /// and waitid learned P_PIDFD only in 5.4; both are probed here. An
    /// unwatchable child is killed by pid and reaped (a spawn error path
    /// only, never on a loop).
    fn pidfdUsable(pidfd: i32, pid: i32) bool {
        if (pidfd >= 0) {
            var probe: linux.siginfo_t = undefined;
            while (true) {
                // A running child answers success with si_pid set to zero.
                const prc = linux.waitid(.PIDFD, pidfd, &probe, linux.W.EXITED | linux.W.NOHANG);
                switch (linux.E.init(prc)) {
                    .INTR => continue,
                    .SUCCESS => return true,
                    else => break,
                }
            }
        }
        _ = linux.kill(pid, linux.SIG.KILL);
        var info: linux.siginfo_t = undefined;
        while (linux.E.init(linux.waitid(.PID, pid, &info, linux.W.EXITED)) == .INTR) {}
        if (pidfd >= 0) _ = std.c.close(pidfd);
        return false;
    }

    fn kill(fd: i32, sig: u8) KillError!void {
        return switch (linux.E.init(linux.pidfd_send_signal(fd, sig, null, 0))) {
            .SUCCESS => {},
            .SRCH => KillError.Exited,
            // EINVAL is also a descriptor that is not a pidfd.
            .INVAL => if (sig >= linux.NSIG) KillError.InvalidSignal else KillError.BadHandle,
            .BADF => KillError.BadHandle,
            .NOSYS => KillError.Unsupported,
            else => KillError.AccessDenied,
        };
    }

    /// SIGKILL (ESRCH once the child has exited), then reap without
    /// waiting on the caller: a collected status reaps here, an already
    /// reaped child is ECHILD, and a child that still runs goes to the
    /// reaper thread. Only an allocation failure in `reaper.take` degrades
    /// to a blocking reap.
    fn close(fd: i32) void {
        _ = linux.pidfd_send_signal(fd, linux.SIG.KILL, null, 0);
        var info: linux.siginfo_t = undefined;
        var werr: linux.E = .INTR;
        while (werr == .INTR) {
            info = undefined;
            werr = linux.E.init(linux.waitid(.PIDFD, fd, &info, linux.W.EXITED | linux.W.NOHANG));
        }
        // Anything but a successful WNOHANG with nothing collected is
        // finished work; a zero si_pid means the SIGKILLed child is still
        // exiting (address-space teardown takes time), and its reaping is
        // handed off below.
        if (werr != .SUCCESS or info.fields.common.first.piduid.pid != 0) {
            _ = std.c.close(fd);
            return;
        }
        if (reaper.take(fd)) return;
        while (linux.E.init(linux.waitid(.PIDFD, fd, &info, linux.W.EXITED)) == .INTR) {}
        _ = std.c.close(fd);
    }

    /// A lazily spawned thread that reaps children whose pidfds a caller
    /// closed while they still ran: close never blocks a loop thread. The
    /// list is protected by the mutex; page_allocator is thread-safe.
    const reaper = struct {
        var lock: std.Thread.Mutex = .{};
        var ready: std.Thread.Condition = .{};
        var pending: std.ArrayListUnmanaged(i32) = .empty;
        var started = false;

        /// Moves the pidfd to the reaper; false (and the caller keeps it)
        /// only when spawning the thread or queuing the fd fails.
        fn take(fd: i32) bool {
            lock.lock();
            defer lock.unlock();
            if (!started) {
                const t = std.Thread.spawn(.{}, run, .{}) catch return false;
                t.setName("born-reaper") catch {};
                t.detach();
                started = true;
            }
            pending.append(std.heap.page_allocator, fd) catch return false;
            ready.signal();
            return true;
        }

        fn run() void {
            while (true) {
                lock.lock();
                while (pending.items.len == 0) ready.wait(&lock);
                const fd = pending.orderedRemove(0);
                lock.unlock();
                var info: linux.siginfo_t = undefined;
                while (linux.E.init(linux.waitid(.PIDFD, fd, &info, linux.W.EXITED)) == .INTR) {}
                _ = std.c.close(fd);
            }
        }
    };

    /// Raw syscalls only: glibc is never entered after the raw clone.
    const ChildSide = struct {
        fn errno(rc: usize) u32 {
            return @intFromEnum(linux.E.init(rc));
        }

        fn blockAll() u32 {
            const all = linux.sigfillset();
            return errno(linux.sigprocmask(linux.SIG.SETMASK, &all, null));
        }

        fn dupAbove(fd: i32, min: i32, out: *i32) u32 {
            const rc = linux.fcntl(fd, F_DUPFD_CLOEXEC, @intCast(min));
            if (errno(rc) != 0) return errno(rc);
            out.* = @intCast(rc);
            return 0;
        }

        fn dup2(from: i32, to: i32) u32 {
            return errno(linux.dup2(from, to));
        }

        fn closeRange(lo: u32, hi: u32) u32 {
            const rc = linux.syscall3(.close_range, lo, hi, 0);
            if (linux.E.init(rc) != .NOSYS) return errno(rc);
            // Before Linux 5.9: close each descriptor below the limit.
            var lim: linux.rlimit = undefined;
            const lrc = linux.getrlimit(.NOFILE, &lim);
            if (errno(lrc) != 0) return errno(lrc);
            const top: u64 = @min(lim.cur, @as(u64, hi) + 1);
            var fd: u64 = lo;
            // EBADF for numbers that are not open is the expected answer.
            while (fd < top) : (fd += 1) _ = linux.close(@intCast(fd));
            return 0;
        }

        fn defaultSignals() u32 {
            const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
            var sig: u8 = 1;
            while (sig < linux.NSIG) : (sig += 1) {
                if (sig == linux.SIG.KILL or sig == linux.SIG.STOP) continue;
                const e = errno(linux.sigaction(sig, &dfl, null));
                if (e != 0) return e;
            }
            return 0;
        }

        fn emptyMask() u32 {
            const none = linux.sigemptyset();
            return errno(linux.sigprocmask(linux.SIG.SETMASK, &none, null));
        }

        fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) u32 {
            return errno(linux.execve(path, argv, envp));
        }

        fn fail(fd: i32, stage: Stage, e: u32) noreturn {
            const report: Report = .{ .stage = @intFromEnum(stage), .errno = e };
            // Nothing is left to report a failed write to; the exit code
            // still says the child never ran its program.
            _ = linux.write(fd, std.mem.asBytes(&report), @sizeOf(Report));
            linux.exit_group(127);
        }
    };
};

const sys = switch (os) {
    .freebsd => freebsd,
    .linux => linux_impl,
    else => struct {
        fn fork(plan: *const Plan) SpawnError!Child {
            _ = plan;
            return SpawnError.Unsupported;
        }
        fn kill(fd: Handle, sig: u8) KillError!void {
            _ = fd;
            _ = sig;
            return KillError.Unsupported;
        }
        fn close(fd: Handle) void {
            _ = fd;
        }
    },
};

test "process: wait status decodes to exits" {
    try std.testing.expectEqual(types.ProcessExit{ .code = 0 }, types.ProcessExit.fromWaitStatus(0).?);
    try std.testing.expectEqual(types.ProcessExit{ .code = 255 }, types.ProcessExit.fromWaitStatus(255 << 8).?);
    try std.testing.expectEqual(types.ProcessExit{ .signal = 9 }, types.ProcessExit.fromWaitStatus(9).?);
    // Core-dump flag (0x80) does not change the signal.
    try std.testing.expectEqual(types.ProcessExit{ .signal = 11 }, types.ProcessExit.fromWaitStatus(0x80 | 11).?);
    // Stopped: not an exit.
    try std.testing.expect(types.ProcessExit.fromWaitStatus((19 << 8) | 0x7f) == null);
}
