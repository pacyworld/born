//! Child processes behind a descriptor: `spawn` starts a program and returns
//! a `Child` whose handle `EvPort.watchProcess` turns into an exit event.
//!
//!   FreeBSD  pdfork(PD_CLOEXEC) process descriptor, pdkill
//!   Linux    clone(CLONE_PIDFD) pidfd, pidfd_send_signal; kernel 5.4+,
//!            probed at spawn (CLONE_PIDFD is 5.2, waitid(P_PIDFD) is 5.4)
//!   others   error.Unsupported
//!
//! `spawn` allocates nothing on its success path: argv, envp and the
//! descriptor map are ready before the fork, and between fork and execve the
//! child makes only async-signal-safe calls (libc calls after libthr's pdfork
//! on FreeBSD, raw syscalls after a raw clone on Linux). On FreeBSD libthr runs
//! the program's pthread_atfork handlers around pdfork, so any handler must
//! obey the same rule; born registers none. A multi-threaded caller is safe.
//! The child:
//!   - resets signals to their default dispositions, except FreeBSD
//!     libthr-reserved signals such as SIGTHR, and starts with an empty signal
//!     mask, whatever the parent ignores, handles or blocks;
//!   - gets `stdin`, `stdout`, `stderr` as asked and `fds[i]` as fd 3 + i;
//!   - has every other descriptor closed before execve.
//! A close-on-exec pipe carries a setup or execve failure back, so `spawn`
//! returns it as an error and cleans up the failed child, possibly
//! asynchronously as described below. On success, `spawn` returns once the
//! child has called execve, as posix_spawn does.
//!
//! Lifetime and reaping:
//!   - FreeBSD: unless another caller reaps with pdwait/wait6, the kernel
//!     keeps the exited child as a zombie until the last process descriptor
//!     closes. That close reaps an exited child; if the child is running, it
//!     sends SIGKILL and leaves the reaping to init without waiting. A pdfork
//!     child sends no SIGCHLD and is invisible to wait(2) for any child.
//!   - Linux: the wait() that reports a watched child's exit reaps it.
//!     `Child.close` cleans up a child that was never reported: an exited
//!     child is collected on the spot, a running one gets SIGKILL, and one
//!     still exiting after a nonblocking wait has its pidfd handed to a
//!     lazily spawned background reaper thread without waiting for the exit.
//!     If spawning that thread or queueing the pidfd fails, close instead
//!     performs a blocking reap. The parent gets SIGCHLD as usual, and a
//!     wait(2) for any child elsewhere in the program can steal the status
//!     (the exit event then arrives with `err` set).
//! Event-loop code should still `kill`, wait for the exit event, then
//! `purgeFd` and `close`, which keeps every reap on the spot.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const compat = @import("compat");
const Handle = types.Handle;

const os = builtin.os.tag;
/// Compile-time target support for process descriptors (FreeBSD and Linux).
/// Linux kernels older than 5.4 still fail `spawn` with error.Unsupported.
pub const supported = os == .freebsd or os == .linux;

/// Maximum number of caller handles `SpawnOptions.fds` may map.
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
/// state. By default the program comes from argv[0], standard descriptors
/// inherit the parent's, and `fds` is empty.
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
    /// Process signaling is unavailable on this target or kernel.
    Unsupported,
    /// Linux: the child has already been reaped by Born's exit reporting or
    /// close, or by a wait elsewhere in the program. FreeBSD keeps an exited
    /// child signalable, a no-op, until its descriptor is closed, so there a
    /// signal after the exit succeeds.
    Exited,
    /// The signal number is outside the native valid range.
    InvalidSignal,
    /// The handle is not open or not a process descriptor.
    BadHandle,
    /// The kernel refused to signal the child, normally for lack of permission.
    AccessDenied,
};

/// A spawned child: its descriptor (watchable with `EvPort.watchProcess`)
/// and pid. See the module comment for lifetime and reaping.
pub const Child = struct {
    /// Process descriptor (FreeBSD) or pidfd (Linux); pass it to
    /// `EvPort.watchProcess`. Close-on-exec in the parent.
    handle: Handle,
    /// Native process ID returned by pdfork or clone, not the watch handle.
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
/// descriptor. On success, returns after the child has called execve; see the
/// module comment for the child's starting state and failure cleanup.
pub fn spawn(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    opts: SpawnOptions,
) SpawnError!Child {
    if (comptime !supported) return SpawnError.Unsupported;
    return spawnPosix(argv, envp, opts);
}

// ----------------------------------------------------------- shared ----

/// Stages named in a child setup or exec failure report.
const Stage = enum(u32) { setup = 1, exec = 2 };

/// What the child writes to the error pipe before exiting with 127.
const Report = extern struct { stage: u32, errno: u32 };

/// Everything the child needs, prepared before the fork.
const Plan = struct {
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// Source for child fd i, or -1 to leave fd i as inherited.
    src: [3 + max_fds]i32 = @splat(-1),
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

    const pipe = compat.pipe2(.{ .CLOEXEC = true }) catch return SpawnError.SystemResources;
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
    var all = compat.sigfillset();
    var saved: compat.sigset_t = undefined;
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
    compat.close(fd);
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
        compat.close(fd);
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
                if (sig == compat.signalNumber(std.posix.SIG.KILL) or sig == compat.signalNumber(std.posix.SIG.STOP)) continue;
                if (std.c.sigaction(compat.nativeSignal(@intCast(sig)), &dfl, null) == 0) continue;
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
        const rc = linux.syscall5(.clone, linux.CLONE.PIDFD | @as(usize, compat.signalNumber(linux.SIG.CHLD)), 0, @intFromPtr(&pidfd), 0, 0);
        switch (compat.linuxErrno(rc)) {
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
                // WNOWAIT: otherwise the probe reaps an already-exited
                // child and discards its status.
                const prc = compat.waitid(.PIDFD, pidfd, &probe, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT);
                switch (compat.linuxErrno(prc)) {
                    .INTR => continue,
                    .SUCCESS => return true,
                    else => break,
                }
            }
        }
        _ = linux.kill(pid, compat.nativeSignal(compat.signalNumber(linux.SIG.KILL)));
        var info: linux.siginfo_t = undefined;
        while (compat.linuxErrno(compat.waitid(.PID, pid, &info, linux.W.EXITED)) == .INTR) {}
        if (pidfd >= 0) compat.close(pidfd);
        return false;
    }

    fn kill(fd: i32, sig: u8) KillError!void {
        return switch (compat.linuxErrno(linux.pidfd_send_signal(fd, compat.nativeSignal(sig), null, 0))) {
            .SUCCESS => {},
            .SRCH => KillError.Exited,
            // EINVAL is also a descriptor that is not a pidfd.
            .INVAL => if (sig >= linux.NSIG) KillError.InvalidSignal else KillError.BadHandle,
            .BADF => KillError.BadHandle,
            .NOSYS => KillError.Unsupported,
            else => KillError.AccessDenied,
        };
    }

    /// SIGKILL (ESRCH once the child has exited), then try to reap without
    /// waiting on the caller: a collected status reaps here, an already
    /// reaped child is ECHILD, and a child that still runs goes to the
    /// reaper thread. Failure to spawn that thread or queue the pidfd in
    /// `reaper.take` falls back to a blocking reap.
    fn close(fd: i32) void {
        _ = linux.pidfd_send_signal(fd, compat.nativeSignal(compat.signalNumber(linux.SIG.KILL)), null, 0);
        var info: linux.siginfo_t = undefined;
        var werr: linux.E = .INTR;
        while (werr == .INTR) {
            info = undefined;
            werr = compat.linuxErrno(compat.waitid(.PIDFD, fd, &info, linux.W.EXITED | linux.W.NOHANG));
        }
        // Anything but a successful WNOHANG with nothing collected is
        // finished work; a zero si_pid means the SIGKILLed child is still
        // exiting (address-space teardown takes time), and its reaping is
        // handed off below.
        if (werr != .SUCCESS or info.fields.common.first.piduid.pid != 0) {
            compat.close(fd);
            return;
        }
        if (reaper.take(fd)) return;
        while (compat.linuxErrno(compat.waitid(.PIDFD, fd, &info, linux.W.EXITED)) == .INTR) {}
        compat.close(fd);
    }

    /// A lazily spawned detached thread that reaps children whose pidfds a
    /// caller closed while they still ran. Close normally avoids blocking a
    /// loop thread; failure to spawn the thread or queue a pidfd falls back
    /// to a blocking reap in the caller. The list is protected by the mutex;
    /// page_allocator is thread-safe.
    /// Known limitation (#52): pidfds are reaped oldest-first with a
    /// blocking waitid, so a child whose exit stalls (D-state, a large
    /// exit_mmap) delays later entries until it finishes.
    const reaper = struct {
        var lock: compat.Mutex = .{};
        var ready: compat.Condition = .{};
        var pending: std.ArrayList(i32) = .empty;
        var started = false;
        /// Pid of the process the running thread belongs to; a fork keeps
        /// `started` but not the thread.
        var owner: i32 = 0;

        /// Moves the pidfd to the reaper; false (and the caller keeps it)
        /// only when spawning the thread or queuing the fd fails.
        fn take(fd: i32) bool {
            lock.lock();
            defer lock.unlock();
            const me = linux.getpid();
            if (started and owner != me) {
                // In a forked child the reaper thread does not exist; the
                // inherited pidfds refer to children of the parent, which a
                // restarted reaper could never wait on. Discard them.
                for (pending.items) |pfd| compat.close(pfd);
                pending.clearRetainingCapacity();
                started = false;
            }
            if (!started) {
                // The thread inherits this thread's signal mask, so block
                // everything around the spawn: a reaper with the caller's
                // mask could eat a process-directed signal destined for
                // signalfd (which needs it blocked in every thread).
                const all = linux.sigfillset();
                var saved: linux.sigset_t = undefined;
                _ = linux.sigprocmask(linux.SIG.SETMASK, &all, &saved);
                const spawned = std.Thread.spawn(.{}, run, .{});
                _ = linux.sigprocmask(linux.SIG.SETMASK, &saved, null);
                const t = spawned catch return false;
                compat.setThreadName(t, "born-reaper");
                t.detach();
                owner = me;
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
                while (compat.linuxErrno(compat.waitid(.PIDFD, fd, &info, linux.W.EXITED)) == .INTR) {}
                compat.close(fd);
            }
        }
    };

    /// Raw syscalls only: glibc is never entered after the raw clone.
    const ChildSide = struct {
        fn errno(rc: usize) u32 {
            return @intFromEnum(compat.linuxErrno(rc));
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
            if (compat.linuxErrno(rc) != .NOSYS) return errno(rc);
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
                if (sig == compat.signalNumber(linux.SIG.KILL) or sig == compat.signalNumber(linux.SIG.STOP)) continue;
                const e = errno(linux.sigaction(compat.nativeSignal(sig), &dfl, null));
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

test "process: the spawn probe leaves an exited child's status in place" {
    if (comptime os != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exit 5" };
    const envp = [_:null]?[*:0]const u8{};
    var child = spawn(&argv, &envp, .{}) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
    defer child.close();
    var info: linux.siginfo_t = undefined;
    // Wait for the exit without reaping, so the probe meets a child that
    // has already exited.
    while (compat.linuxErrno(compat.waitid(.PIDFD, child.handle, &info, linux.W.EXITED | linux.W.NOWAIT)) == .INTR) {}
    try std.testing.expect(linux_impl.pidfdUsable(child.handle, child.pid));
    // The status survives the probe: a WNOHANG waitid still collects it.
    info = std.mem.zeroes(linux.siginfo_t);
    try std.testing.expectEqual(linux.E.SUCCESS, compat.linuxErrno(compat.waitid(.PIDFD, child.handle, &info, linux.W.EXITED | linux.W.NOHANG)));
    try std.testing.expectEqual(child.pid, info.fields.common.first.piduid.pid);
}
