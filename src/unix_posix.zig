//! Unix domain stream sockets on POSIX: `Listener.openUnix` (via `listen`)
//! and `PlainNb.startConnectUnixInto` (via `connectInto`). Accepted streams
//! use the same accept path as TCP listeners.
//!
//! Paths: checked against `sun_path` (104 bytes on BSD and macOS, 108 on
//! Linux, counting the NUL) and refused with error.NameTooLong, never
//! truncated. An empty path or one containing a NUL byte (which the kernel
//! would cut short; Linux abstract names included) is refused too.
//!
//! Listen order: socket, open the parent directory, bind, fchmodat(opts.mode),
//! listen. A bound socket that is not yet listening refuses every connect
//! (ECONNREFUSED), so the file's mode from bind (0777 minus the umask) is never
//! usable by a client before `opts.mode` is in place. The umask is not touched:
//! it is process-wide, and changing it would race other threads creating files.
//!
//! Directory anchoring: the parent directory is opened once (O_PATH on Linux
//! and FreeBSD, O_SEARCH on NetBSD, else O_RDONLY) and bind, the stale-path
//! probe, and every post-bind operation (fstatat, fchmodat, unlinkat) target
//! that descriptor and the path's final component. This pins the directory
//! inode, so a writer who renames or replaces the parent cannot redirect those
//! operations to another directory. Bind and the probe are anchored where the
//! platform allows it: FreeBSD bindat/connectat with a relative sun_path, Linux
//! bind/connect through /proc/self/fd/<dir_fd>/<base>. fchmodat uses
//! AT_SYMLINK_NOFOLLOW (on Linux before 6.6 through compat's /proc fallback).
//!
//! Residual race: within the pinned directory the identity check and the
//! unlink are still separate operations, and POSIX has no atomic
//! compare-and-unlink. The socket's parent directory must therefore be
//! writable only by trusted users: an untrusted writer in that directory could
//! still replace the entry between the check and the unlink.
//!
//! On macOS, NetBSD and OpenBSD no anchored bind exists, so bind and the probe
//! resolve the full path: a parent swap between the anchor open and bind can
//! still create the socket in, or probe, another directory. The same window
//! opens on Linux when /proc is unavailable or the anchored path would not fit
//! sun_path and the full path is used instead. Anchored bind on FreeBSD and
//! Linux closes it. The O_RDONLY anchor on macOS and OpenBSD also needs read
//! permission on the parent, where a full-path bind needed only search.
//! `opts.mode` takes permission bits only (0o777); anything else is
//! error.SocketError.
//!
//! Stale paths (`unlink_stale`): when bind reports EADDRINUSE, the path is
//! classified before anything is removed:
//!   - not a socket (a symlink included): error.PathNotASocket, kept;
//!   - a socket file: probed with a datagram connect. No socket attached
//!     to the file answers ECONNREFUSED: stale, checked again before one
//!     unlink, and bind is retried once. Any bound socket answers
//!     EPROTOTYPE (another type) or accepts the connect: live,
//!     error.AddressInUse. A datagram probe never touches the accept queue,
//!     so it also classifies a live listener whose backlog is full (FreeBSD
//!     and macOS refuse a stream connect to it with ECONNREFUSED) and one
//!     that is bound but not yet listening (another instance starting up).
//! With `unlink_stale` false, EADDRINUSE is error.AddressInUse.
//!
//! Backlog: the kernel's limit (kern.ipc.soacceptqueue on FreeBSD,
//! net.core.somaxconn on Linux, kern.ipc.somaxconn on macOS); a larger
//! request is clamped to it.

const std = @import("std");
const builtin = @import("builtin");
const evport = @import("root.zig");
const io = @import("io_types.zig");
const Listener = @import("listener_posix.zig").Listener;
const PlainNb = @import("socket_posix.zig").PlainNb;
const compat = @import("compat");

const sun_path_len = @typeInfo(@FieldType(compat.sockaddr.un, "path")).array.len;
const Dev = @FieldType(compat.FileStat, "dev");
const Ino = @FieldType(compat.FileStat, "ino");

/// Unix-only listener state, a field of Listener (`unix`): the parent
/// directory this listener pinned, the final component it bound, and the
/// identity of the file bind created.
///
/// `close` (through `deinit`) checks all of these conditions before
/// unlinking the path:
///   - this listener created the file (openUnix bound it);
///   - the caller is the process that bound it: a child that inherited the
///     listener across fork closes its copy without unlinking;
///   - the path still names that file (same device and inode, checked
///     relative to the pinned directory before the descriptor closes, while
///     the socket keeps the inode alive, so the pair cannot have been reused).
///
/// Removal is relative to `dir_fd`, the parent directory opened at listen
/// time, so a parent-directory swap cannot redirect it. Within that directory
/// the identity check and unlink are separate operations: the parent must be
/// writable only by trusted users (see the module documentation).
///
/// If the unlink fails (permissions changed), the file stays as a stale
/// socket that the next openUnix with `unlink_stale` replaces.
pub const ListenerState = struct {
    /// Final component of the bound path, relative to `dir_fd`.
    path_buf: [sun_path_len]u8 = undefined,
    /// 0 when there is nothing to remove (TCP, or already removed).
    path_len: usize = 0,
    /// Pinned parent directory; -1 for TCP. Closed by `deinit`.
    dir_fd: compat.fd_t = -1,
    dev: Dev = 0,
    ino: Ino = 0,
    /// Whether dev/ino hold the bound file's identity. False until the
    /// post-bind stat records it, so cleanup of a just-bound path needs no check.
    identity_known: bool = false,
    pid: compat.pid_t = 0,

    fn path(self: *const ListenerState) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Called by Listener.close before the fd closes.
    pub fn deinit(self: *ListenerState) void {
        defer {
            if (self.dir_fd >= 0) {
                compat.close(self.dir_fd);
                self.dir_fd = -1;
            }
        }
        if (self.path_len == 0) return;
        // path_len != 0 implies a live dir_fd: the anchor is opened before bind
        // and closed only by the defer above, so unlinkat never sees a bad fd.
        defer self.path_len = 0;
        if (std.c.getpid() != self.pid) return;
        // Identity not yet recorded: bind just created the file under the
        // trusted-parent precondition, so remove it without an identity check.
        if (!self.identity_known) {
            compat.unlinkat(self.dir_fd, self.path(), 0) catch {};
            return;
        }
        if (!self.ownsPath()) return;
        compat.unlinkat(self.dir_fd, self.path(), 0) catch {};
    }

    /// The path still names the socket file this listener bound, checked
    /// relative to the pinned parent directory.
    fn ownsPath(self: *const ListenerState) bool {
        const st = compat.fstatat(self.dir_fd, self.path(), compat.AT.SYMLINK_NOFOLLOW) catch return false;
        return compat.S.ISSOCK(st.mode) and st.dev == self.dev and st.ino == self.ino;
    }
};

/// Why a path cannot become a sockaddr; mapped per operation.
const PathError = error{ NameTooLong, InvalidPath };

/// `path` as a NUL-terminated sockaddr_un, never truncated.
fn sockAddr(path: []const u8) PathError!compat.sockaddr.un {
    if (path.len == 0 or compat.findScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len + 1 > sun_path_len) return error.NameTooLong;
    var un = std.mem.zeroes(compat.sockaddr.un);
    un.family = compat.AF.UNIX;
    if (@hasField(compat.sockaddr.un, "len")) un.len = @sizeOf(compat.sockaddr.un);
    @memcpy(un.path[0..path.len], path);
    return un;
}

fn sockPtr(un: *const compat.sockaddr.un) *const compat.sockaddr {
    return @ptrCast(un);
}

const addr_len: compat.socklen_t = @sizeOf(compat.sockaddr.un);

/// Split a socket path into its parent directory and final component. A path
/// with no separator lives in the working directory; a leading separator names
/// the root.
fn splitPath(path: []const u8) struct { parent: []const u8, base: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return .{ .parent = if (i == 0) "/" else path[0..i], .base = path[i + 1 ..] };
    }
    return .{ .parent = ".", .base = path };
}

/// A bind/connect target for the Unix listener. `fd` is the pinned directory
/// for FreeBSD bindat/connectat (with a relative `un.path`), or AT.FDCWD when
/// `un` carries an absolute path: the Linux /proc anchor or the full-path
/// fallback.
const AnchoredAddr = struct {
    un: compat.sockaddr.un,
    fd: compat.fd_t,
};

/// Whether the Linux /proc/self/fd anchor is usable. Checked once per listen so
/// the stale-path probe never mistakes a missing /proc for a missing socket.
fn procAnchorAvailable() bool {
    if (comptime builtin.os.tag != .linux) return false;
    _ = compat.fstatat(compat.AT.FDCWD, "/proc/self/fd", 0) catch return false;
    return true;
}

/// Anchor the bind/connect address to the pinned directory where the platform
/// allows it: FreeBSD binds the relative final component through bindat; Linux
/// binds through /proc/self/fd/<dir_fd>/<base> when that fits sun_path. Other
/// targets, an over-long anchored path, or a missing /proc fall back to the
/// validated full path, leaving the open-to-bind window open (see module doc).
fn anchoredAddr(
    dir_fd: compat.fd_t,
    base: []const u8,
    full: *const compat.sockaddr.un,
    proc_ok: bool,
) AnchoredAddr {
    if (base.len != 0) {
        if (comptime builtin.os.tag == .freebsd) {
            if (sockAddr(base)) |un| return .{ .un = un, .fd = dir_fd } else |_| {}
        }
        if (comptime builtin.os.tag == .linux) {
            if (proc_ok) {
                var buf: [sun_path_len]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "/proc/self/fd/{d}/{s}", .{ dir_fd, base })) |p| {
                    if (sockAddr(p)) |un| return .{ .un = un, .fd = compat.AT.FDCWD } else |_| {}
                } else |_| {}
            }
        }
    }
    return .{ .un = full.*, .fd = compat.AT.FDCWD };
}

/// The post-bind identity stat, injectable so a test can force its failure.
const StatFn = fn (compat.fd_t, []const u8, u32) compat.FStatAtError!compat.FileStat;

/// Called after the parent directory is pinned and before bind. Production
/// passes a no-op; a test injects a parent swap to exercise the bind anchor.
const AfterAnchorFn = fn (ctx: ?*anyopaque) void;

fn noopAfterAnchor(_: ?*anyopaque) void {}

/// Open a Unix stream listener at `path` with `opts`.
///
/// The parent directory must be writable only by trusted users. See the
/// module documentation for path validation, stale-path handling, directory
/// anchoring, and the ownership checks used during cleanup.
pub fn listen(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
    return listenInner(alloc, path, opts, compat.fstatat, noopAfterAnchor, null);
}

fn listenInner(
    alloc: std.mem.Allocator,
    path: []const u8,
    opts: io.UnixOptions,
    comptime statFn: StatFn,
    comptime afterAnchor: AfterAnchorFn,
    hook_ctx: ?*anyopaque,
) io.ListenError!Listener {
    _ = alloc;
    if (opts.mode & ~@as(u16, 0o777) != 0) return io.ListenError.SocketError;
    const un = sockAddr(path) catch |err| return switch (err) {
        error.NameTooLong => io.ListenError.NameTooLong,
        error.InvalidPath => io.ListenError.SocketError,
    };

    const s = compat.socket(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0) catch |err| return switch (err) {
        error.AccessDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
    errdefer compat.close(s);

    // Pin the parent directory before bind so every later operation targets
    // this directory inode even if the path's parent is swapped.
    const split = splitPath(path);
    const dir_fd = compat.openDirAnchor(split.parent) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
    var state: ListenerState = .{ .dir_fd = dir_fd, .pid = std.c.getpid() };
    @memcpy(state.path_buf[0..split.base.len], split.base);
    // Owns dir_fd from here and removes the bound path on any later failure.
    errdefer state.deinit();

    // Anchor bind and the probe to the pinned directory, not the full path.
    const addr = anchoredAddr(dir_fd, split.base, &un, procAnchorAvailable());
    afterAnchor(hook_ctx);
    try bindPath(&addr, s, dir_fd, split.base, opts.unlink_stale);

    // bind created the file: arm removal before the fallible identity stat.
    state.path_len = split.base.len;
    const st = statFn(dir_fd, split.base, compat.AT.SYMLINK_NOFOLLOW) catch return io.ListenError.SocketError;
    if (!compat.S.ISSOCK(st.mode)) {
        // Replaced since bind by a non-socket: leave it, remove nothing.
        state.path_len = 0;
        return io.ListenError.SocketError;
    }
    state.dev = st.dev;
    state.ino = st.ino;
    state.identity_known = true;

    // Not listening yet: every connect is refused until listen below.
    compat.fchmodat(dir_fd, split.base, @intCast(opts.mode), compat.AT.SYMLINK_NOFOLLOW) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };

    switch (std.posix.errno(std.c.listen(s, std.math.maxInt(c_int)))) {
        .SUCCESS => {},
        else => return io.ListenError.SocketError,
    }
    return .{ .sock = s, .unix = state };
}

/// bind, replacing a stale socket file at most once.
fn bindPath(
    addr: *const AnchoredAddr,
    s: compat.fd_t,
    dir_fd: compat.fd_t,
    base: []const u8,
    unlink_stale: bool,
) io.ListenError!void {
    var retried = false;
    while (true) {
        switch (std.posix.errno(compat.bindUnixAt(addr.fd, s, sockPtr(&addr.un), addr_len))) {
            .SUCCESS => return,
            .ADDRINUSE => {
                if (!unlink_stale or retried) return io.ListenError.AddressInUse;
                retried = true;
                try removeStale(addr, dir_fd, base);
            },
            .ACCES, .PERM => return io.ListenError.AccessDenied,
            .NAMETOOLONG => return io.ListenError.NameTooLong,
            else => return io.ListenError.SocketError,
        }
    }
}

/// Unlink the file at `base` in `dir_fd` if it is a stale socket; return so the
/// caller retries bind. A live socket is error.AddressInUse, anything else
/// error.PathNotASocket; neither is touched. The stat, datagram probe and unlink
/// all target the pinned directory.
fn removeStale(addr: *const AnchoredAddr, dir_fd: compat.fd_t, base: []const u8) io.ListenError!void {
    const before = try lstat(dir_fd, base) orelse return; // gone since bind: retry
    if (!compat.S.ISSOCK(before.mode)) return io.ListenError.PathNotASocket;

    switch (try probe(addr)) {
        .live => return io.ListenError.AddressInUse,
        .gone => return,
        .stale => {},
    }

    // Leave an already-replaced path alone. Replacement after this check is
    // possible, so the parent directory must be writable only by trusted users.
    const now = try lstat(dir_fd, base) orelse return;
    if (now.dev != before.dev or now.ino != before.ino) return io.ListenError.AddressInUse;
    compat.unlinkat(dir_fd, base, 0) catch |err| return switch (err) {
        error.FileNotFound => {},
        error.AccessDenied, error.PermissionDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
}

/// The file at `base` in `dir_fd` without following a symlink; null when none.
fn lstat(dir_fd: compat.fd_t, base: []const u8) io.ListenError!?compat.FileStat {
    return compat.fstatat(dir_fd, base, compat.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => null,
        error.AccessDenied, error.PermissionDenied => io.ListenError.AccessDenied,
        error.NameTooLong => io.ListenError.NameTooLong,
        else => io.ListenError.SocketError,
    };
}

const Probe = enum { live, stale, gone };

/// Datagram connect to the socket file at the anchored address: ECONNREFUSED
/// means no socket is attached to it. See the module comment for why not a
/// stream.
fn probe(addr: *const AnchoredAddr) io.ListenError!Probe {
    const p = compat.socket(compat.AF.UNIX, compat.SOCK.DGRAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0) catch |err| return switch (err) {
        error.AccessDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
    defer compat.close(p);
    return switch (std.posix.errno(compat.connectUnixAt(addr.fd, p, sockPtr(&addr.un), addr_len))) {
        .CONNREFUSED => .stale,
        .NOENT => .gone,
        // A datagram socket accepted it, a socket of another type is bound,
        // or a datagram peer's queue is full: someone owns the path.
        .SUCCESS, .PROTOTYPE, .AGAIN, .NOBUFS => .live,
        .ACCES, .PERM => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
}

/// Non-blocking connect to the stream listener at `path`, completed through
/// the TCP contract: register write interest, then `connectDone` on the
/// first write event. EINPROGRESS is legal. A full backlog is
/// error.BacklogFull where the kernel reports it as such (Linux, EAGAIN);
/// FreeBSD and macOS refuse it (ECONNREFUSED), which is error.ConnectFailed.
/// Neither is retried. `stream` is untouched on failure. `alloc`, `evp`
/// and `key` are for the portable shape and unused here.
pub fn connectInto(stream: *PlainNb, alloc: std.mem.Allocator, path: []const u8, evp: *evport.EvPort, key: ?*anyopaque) io.ConnectUnixError!void {
    _ = alloc;
    _ = evp;
    _ = key;
    std.debug.assert(stream.sock == -1);
    const un = sockAddr(path) catch |err| return switch (err) {
        error.NameTooLong => io.ConnectUnixError.NameTooLong,
        error.InvalidPath => io.ConnectUnixError.ConnectFailed,
    };

    const s = compat.socket(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0) catch return io.ConnectUnixError.SocketError;
    errdefer compat.close(s);
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        if (std.posix.errno(std.c.setsockopt(s, compat.SOL.SOCKET, compat.SO.NOSIGPIPE, &one, @sizeOf(c_int))) != .SUCCESS)
            return io.ConnectUnixError.SocketError;
    }

    switch (std.posix.errno(std.c.connect(s, sockPtr(&un), addr_len))) {
        // EINTR: the connect continues asynchronously, like EINPROGRESS.
        .SUCCESS, .INPROGRESS, .INTR => {},
        .AGAIN => return io.ConnectUnixError.BacklogFull,
        .NAMETOOLONG => return io.ConnectUnixError.NameTooLong,
        else => return io.ConnectUnixError.ConnectFailed,
    }
    stream.* = .{ .sock = s };
}

// ------------------------------------------------------------------ tests ----
// POSIX-only cases beyond the portable contract in unix_test.zig.

const testing = std.testing;

const test_tmp_root = ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str;

/// A socket path relative to the workspace, short enough for BSD sun_path.
/// The root mirrors std.testing.tmpDir's `.zig-cache/tmp` layout. Tests run
/// from a writable working directory; manual runs create that layout there.
const TestPath = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    tmp: ?std.testing.TmpDir = null,

    fn init() !TestPath {
        var p: TestPath = .{};
        p.tmp = std.testing.tmpDir(.{});
        errdefer p.tmp.?.cleanup();
        p.len = (try std.fmt.bufPrint(
            &p.buf,
            test_tmp_root ++ "{s}" ++ std.fs.path.sep_str ++ "s",
            .{p.tmp.?.sub_path},
        )).len;
        return p;
    }

    fn get(self: *const TestPath) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *TestPath) void {
        compat.unlink(self.get()) catch {};
        if (self.tmp) |*tmp| tmp.cleanup();
    }
};

fn exists(path: []const u8) bool {
    _ = compat.fstatat(compat.AT.FDCWD, path, compat.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

/// Raw blocking stream connect; true when it succeeded.
fn rawConnect(path: []const u8) !bool {
    const un = try sockAddr(path);
    const c = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.CLOEXEC, 0);
    defer compat.close(c);
    return std.posix.errno(std.c.connect(c, sockPtr(&un), addr_len)) == .SUCCESS;
}

test "unix_posix: a socket bound but not yet listening is live, not stale" {
    var p = try TestPath.init();
    defer p.deinit();
    const un = try sockAddr(p.get());
    const raw = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.CLOEXEC, 0);
    defer compat.close(raw);
    try testing.expectEqual(compat.E.SUCCESS, std.posix.errno(std.c.bind(raw, sockPtr(&un), addr_len)));
    // A stream probe would see ECONNREFUSED here and unlink the path.
    try testing.expectError(error.AddressInUse, Listener.openUnix(testing.allocator, p.get(), .{}));
    try testing.expect(exists(p.get()));
}

test "unix_posix: a live listener with a full backlog is not stale" {
    var p = try TestPath.init();
    defer p.deinit();
    const un = try sockAddr(p.get());
    const srv = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.CLOEXEC, 0);
    defer compat.close(srv);
    try testing.expectEqual(compat.E.SUCCESS, std.posix.errno(std.c.bind(srv, sockPtr(&un), addr_len)));
    // Backlog 1, not 0: XNU replaces 0 with somaxconn.
    try testing.expectEqual(compat.E.SUCCESS, std.posix.errno(std.c.listen(srv, 1)));

    // Fill the queue with connections nobody accepts.
    var clients: [64]compat.fd_t = undefined;
    var n: usize = 0;
    defer for (clients[0..n]) |c| compat.close(c);
    var port = try evport.EvPort.init(testing.allocator);
    defer port.deinit();
    const full_err = while (n < clients.len) {
        var s: PlainNb = .{};
        if (connectInto(&s, testing.allocator, p.get(), &port, null)) {
            clients[n] = s.sock;
            n += 1;
        } else |err| break err;
    } else return error.BacklogNeverFilled;
    switch (builtin.os.tag) {
        .linux => try testing.expectEqual(error.BacklogFull, full_err),
        else => try testing.expectEqual(error.ConnectFailed, full_err),
    }

    try testing.expectError(error.AddressInUse, Listener.openUnix(testing.allocator, p.get(), .{}));
    try testing.expect(exists(p.get()));
}

test "unix_posix: close removes its own path and preserves a successor's" {
    var p = try TestPath.init();
    defer p.deinit();
    var first = try Listener.openUnix(testing.allocator, p.get(), .{});
    // Another instance takes the path over (removed by hand, rebound).
    try compat.unlink(p.get());
    var second = try Listener.openUnix(testing.allocator, p.get(), .{});
    first.close();
    try testing.expect(exists(p.get()));
    try testing.expect(try rawConnect(p.get()));
    second.close();
    try testing.expect(!exists(p.get()));
}

/// Format a NUL-terminated path into buf. std.fmt.bufPrintZ is gone in Zig
/// 0.17; bufPrint plus an explicit terminator is stable across toolchains.
fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.bufPrint(buf, fmt, args);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

test "unix_posix: close unlinks in the pinned directory after a parent swap" {
    // Pin the parent at listen time; renaming it must not redirect cleanup to
    // a successor directory created at the original path.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a_buf: [96]u8 = undefined;
    var b_buf: [96]u8 = undefined;
    var as_buf: [96]u8 = undefined;
    var bs_buf: [96]u8 = undefined;
    const a = try pathZ(&a_buf, test_tmp_root ++ "{s}/a", .{tmp.sub_path});
    const b = try pathZ(&b_buf, test_tmp_root ++ "{s}/b", .{tmp.sub_path});
    const a_sock = try pathZ(&as_buf, "{s}/s", .{a});
    const b_sock = try pathZ(&bs_buf, "{s}/s", .{b});
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(a.ptr, 0o755));

    var l = try Listener.openUnix(testing.allocator, a_sock, .{});
    // Swap the pinned parent away and put a successor directory in its place.
    try testing.expectEqual(@as(c_int, 0), std.c.rename(a.ptr, b.ptr));
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(a.ptr, 0o755));
    const un = try sockAddr(a_sock);
    const succ = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM | compat.SOCK.CLOEXEC, 0);
    defer compat.close(succ);
    try testing.expectEqual(compat.E.SUCCESS, std.posix.errno(std.c.bind(succ, sockPtr(&un), addr_len)));

    l.close();
    // Cleanup targeted the pinned (renamed) directory, not the successor.
    try testing.expect(!exists(b_sock));
    try testing.expect(exists(a_sock));
    compat.unlink(a_sock) catch {};
}

/// Renames the pinned parent away and puts a successor directory at the
/// original name, in the window between the anchor open and bind.
const SwapFixture = struct {
    a: [:0]const u8,
    b: [:0]const u8,

    fn swap(ctx: ?*anyopaque) void {
        const self: *SwapFixture = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(std.c.rename(self.a.ptr, self.b.ptr) == 0);
        std.debug.assert(std.c.mkdir(self.a.ptr, 0o755) == 0);
    }
};

test "unix_posix: bind lands in the pinned parent across a swap before bind" {
    // Only FreeBSD (bindat) and Linux (/proc/self/fd) anchor bind itself. The
    // other targets keep the full-path bind, so the swap would move the socket
    // to the successor; that open-to-bind window is documented, not tested here.
    if (comptime builtin.os.tag != .freebsd and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a_buf: [96]u8 = undefined;
    var b_buf: [96]u8 = undefined;
    var as_buf: [96]u8 = undefined;
    var bs_buf: [96]u8 = undefined;
    const a = try pathZ(&a_buf, test_tmp_root ++ "{s}/a", .{tmp.sub_path});
    const b = try pathZ(&b_buf, test_tmp_root ++ "{s}/b", .{tmp.sub_path});
    const a_sock = try pathZ(&as_buf, "{s}/s", .{a});
    const b_sock = try pathZ(&bs_buf, "{s}/s", .{b});
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(a.ptr, 0o755));

    var fixture = SwapFixture{ .a = a, .b = b };
    var l = try listenInner(testing.allocator, a_sock, .{}, compat.fstatat, SwapFixture.swap, &fixture);
    // The socket was created in the pinned directory (renamed to b), not in the
    // successor now at a.
    try testing.expect(exists(b_sock));
    try testing.expect(!exists(a_sock));
    l.close();
    // Cleanup removed it from the pinned directory and left the successor alone.
    try testing.expect(!exists(b_sock));
    try testing.expect(!exists(a_sock));
}

test "unix_posix: a failing post-bind identity stat still removes the bound path" {
    // Force the post-bind stat to fail; the cleanup guard armed before it must
    // remove the just-bound path rather than leak it.
    var p = try TestPath.init();
    defer p.deinit();
    const failing = struct {
        fn stat(_: compat.fd_t, _: []const u8, _: u32) compat.FStatAtError!compat.FileStat {
            return error.Unexpected;
        }
    }.stat;
    try testing.expectError(error.SocketError, listenInner(testing.allocator, p.get(), .{}, failing, noopAfterAnchor, null));
    try testing.expect(!exists(p.get()));
}

test "unix_posix: a post-bind non-socket replacement is refused and kept" {
    // The identity stat reports a non-socket (replaced since bind): refuse
    // without unlinking the replacement.
    var p = try TestPath.init();
    defer p.deinit();
    const replaced = struct {
        fn stat(_: compat.fd_t, _: []const u8, _: u32) compat.FStatAtError!compat.FileStat {
            return .{ .dev = 1, .ino = 1, .mode = compat.S.IFREG | 0o600 };
        }
    }.stat;
    try testing.expectError(error.SocketError, listenInner(testing.allocator, p.get(), .{}, replaced, noopAfterAnchor, null));
    try testing.expect(exists(p.get()));
}

test "unix_posix: a copy inherited by another process does not unlink" {
    var p = try TestPath.init();
    defer p.deinit();
    var l = try Listener.openUnix(testing.allocator, p.get(), .{});
    l.unix.pid +%= 1; // as seen from a forked child
    l.close();
    try testing.expect(exists(p.get()));
}

test "unix_posix: a symlink at the path is refused and kept" {
    var p = try TestPath.init();
    defer p.deinit();
    var target = try TestPath.init();
    defer target.deinit();
    var l = try Listener.openUnix(testing.allocator, target.get(), .{});
    defer l.close();
    var link_buf: [64]u8 = undefined;
    const link = try std.fmt.bufPrint(
        &link_buf,
        ".." ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "s",
        .{target.tmp.?.sub_path},
    );
    try compat.symlink(link, p.get());
    try testing.expectError(error.PathNotASocket, Listener.openUnix(testing.allocator, p.get(), .{}));
    const st = try compat.fstatat(compat.AT.FDCWD, p.get(), compat.AT.SYMLINK_NOFOLLOW);
    try testing.expect(compat.S.ISLNK(st.mode));
}

test "unix_posix: empty paths and embedded NULs are refused" {
    var port = try evport.EvPort.init(testing.allocator);
    defer port.deinit();
    for ([_][]const u8{ "", "born\x00cut" }) |bad| {
        try testing.expectError(error.SocketError, Listener.openUnix(testing.allocator, bad, .{}));
        var s: PlainNb = .{};
        try testing.expectError(error.ConnectFailed, connectInto(&s, testing.allocator, bad, &port, null));
        try testing.expectEqual(@as(compat.fd_t, -1), s.sock);
    }
}

test "unix_posix: the longest path that fits sun_path works, one more byte does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [sun_path_len]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &buf,
        test_tmp_root ++ "{s}" ++ std.fs.path.sep_str,
        .{tmp.sub_path},
    );
    @memset(buf[prefix.len..], 'x');
    const fits = buf[0 .. sun_path_len - 1];
    defer compat.unlink(fits) catch {};
    var l = try Listener.openUnix(testing.allocator, fits, .{});
    try testing.expect(try rawConnect(fits));
    l.close();
    try testing.expectError(error.NameTooLong, Listener.openUnix(testing.allocator, buf[0..sun_path_len], .{}));
}
