//! Unix domain stream sockets on POSIX (born#20): `Listener.openUnix` (via
//! `listen`) and `PlainNb.startConnectUnixInto` (via `connectInto`).
//! Accepted streams use the TCP listener's accept path (#18) unchanged.
//!
//! Paths: checked against `sun_path` (104 bytes on BSD and macOS, 108 on
//! Linux, counting the NUL) and refused with error.NameTooLong, never
//! truncated. An empty path or one containing a NUL byte (which the kernel
//! would cut short; Linux abstract names included) is refused too.
//!
//! Listen order: socket, bind, fchmodat(opts.mode), listen. A bound socket
//! that is not yet listening refuses every connect (ECONNREFUSED), so the
//! file's mode from bind (0777 minus the umask) is never usable by a client
//! before `opts.mode` is in place. The umask is not touched: it is
//! process-wide, and changing it would race other threads creating files.
//! fchmodat goes by path with AT_SYMLINK_NOFOLLOW (on Linux before 6.6
//! through std's /proc fallback); keep the socket in a directory that
//! untrusted users cannot write, as for any socket file. `opts.mode` takes
//! permission bits only (0o777); anything else is error.SocketError.
//!
//! Stale paths (`unlink_stale`): when bind reports EADDRINUSE, the path is
//! classified before anything is removed:
//!   - not a socket (a symlink included): error.PathNotASocket, kept;
//!   - a socket file: probed with a datagram connect. No socket attached
//!     to the file answers ECONNREFUSED: stale, unlinked once (if it is
//!     still the same file) and bind is retried once. Any bound socket
//!     answers EPROTOTYPE (another type) or accepts the connect: live,
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
const posix = std.posix;

const sun_path_len = @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len;
const Dev = @FieldType(posix.Stat, "dev");
const Ino = @FieldType(posix.Stat, "ino");

/// Unix-only listener state, a field of Listener (`unix`): the path this
/// process bound, and the identity of the file bind created.
///
/// `close` (through `deinit`) unlinks the path only when all of these hold,
/// so it never removes a path a different listener now owns:
///   - this listener created the file (openUnix bound it);
///   - the caller is the process that bound it: a child that inherited the
///     listener across fork closes its copy without unlinking;
///   - the path still names that file (same device and inode, checked
///     before the descriptor closes, while the socket keeps the inode
///     alive, so the pair cannot have been reused).
/// If the unlink fails (permissions changed), the file stays as a stale
/// socket that the next openUnix with `unlink_stale` replaces.
pub const ListenerState = struct {
    path_buf: [sun_path_len]u8 = undefined,
    /// 0 when there is nothing to remove (TCP, or already removed).
    path_len: usize = 0,
    dev: Dev = 0,
    ino: Ino = 0,
    pid: posix.pid_t = 0,

    fn path(self: *const ListenerState) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Called by Listener.close before the fd closes.
    pub fn deinit(self: *ListenerState) void {
        if (self.path_len == 0) return;
        defer self.path_len = 0;
        if (std.c.getpid() != self.pid) return;
        if (!self.ownsPath()) return;
        posix.unlink(self.path()) catch {};
    }

    /// The path still names the socket file this listener bound.
    fn ownsPath(self: *const ListenerState) bool {
        const st = posix.fstatat(posix.AT.FDCWD, self.path(), posix.AT.SYMLINK_NOFOLLOW) catch return false;
        return posix.S.ISSOCK(st.mode) and st.dev == self.dev and st.ino == self.ino;
    }
};

/// Why a path cannot become a sockaddr; mapped per operation.
const PathError = error{ NameTooLong, InvalidPath };

/// `path` as a NUL-terminated sockaddr_un, never truncated.
fn sockAddr(path: []const u8) PathError!posix.sockaddr.un {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len + 1 > sun_path_len) return error.NameTooLong;
    var un = std.mem.zeroes(posix.sockaddr.un);
    un.family = posix.AF.UNIX;
    if (@hasField(posix.sockaddr.un, "len")) un.len = @sizeOf(posix.sockaddr.un);
    @memcpy(un.path[0..path.len], path);
    return un;
}

fn sockPtr(un: *const posix.sockaddr.un) *const posix.sockaddr {
    return @ptrCast(un);
}

const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

pub fn listen(alloc: std.mem.Allocator, path: []const u8, opts: io.UnixOptions) io.ListenError!Listener {
    _ = alloc;
    if (opts.mode & ~@as(u16, 0o777) != 0) return io.ListenError.SocketError;
    const un = sockAddr(path) catch |err| return switch (err) {
        error.NameTooLong => io.ListenError.NameTooLong,
        error.InvalidPath => io.ListenError.SocketError,
    };

    const s = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch |err| return switch (err) {
        error.AccessDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
    errdefer posix.close(s);

    try bindPath(s, &un, path, opts.unlink_stale);

    // bind created the file: record it, and remove it again on failure.
    var state: ListenerState = .{ .path_len = path.len, .pid = std.c.getpid() };
    @memcpy(state.path_buf[0..path.len], path);
    const st = posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW) catch return io.ListenError.SocketError;
    if (!posix.S.ISSOCK(st.mode)) return io.ListenError.SocketError; // replaced since bind
    state.dev = st.dev;
    state.ino = st.ino;
    errdefer state.deinit();

    // Not listening yet: every connect is refused until listen below.
    posix.fchmodat(posix.AT.FDCWD, path, @intCast(opts.mode), posix.AT.SYMLINK_NOFOLLOW) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };

    switch (posix.errno(std.c.listen(s, std.math.maxInt(c_int)))) {
        .SUCCESS => {},
        else => return io.ListenError.SocketError,
    }
    return .{ .sock = s, .unix = state };
}

/// bind, replacing a stale socket file at most once.
fn bindPath(s: posix.fd_t, un: *const posix.sockaddr.un, path: []const u8, unlink_stale: bool) io.ListenError!void {
    var retried = false;
    while (true) {
        switch (posix.errno(std.c.bind(s, sockPtr(un), addr_len))) {
            .SUCCESS => return,
            .ADDRINUSE => {
                if (!unlink_stale or retried) return io.ListenError.AddressInUse;
                retried = true;
                try removeStale(un, path);
            },
            .ACCES, .PERM => return io.ListenError.AccessDenied,
            .NAMETOOLONG => return io.ListenError.NameTooLong,
            else => return io.ListenError.SocketError,
        }
    }
}

/// Unlink the file at `path` if it is a stale socket; return so the caller
/// retries bind. A live socket is error.AddressInUse, anything else
/// error.PathNotASocket; neither is touched.
fn removeStale(un: *const posix.sockaddr.un, path: []const u8) io.ListenError!void {
    const before = try lstat(path) orelse return; // gone since bind: retry
    if (!posix.S.ISSOCK(before.mode)) return io.ListenError.PathNotASocket;

    switch (try probe(un)) {
        .live => return io.ListenError.AddressInUse,
        .gone => return,
        .stale => {},
    }

    // Unlink only the file that was probed; a replacement belongs to
    // whoever created it.
    const now = try lstat(path) orelse return;
    if (now.dev != before.dev or now.ino != before.ino) return io.ListenError.AddressInUse;
    switch (posix.errno(std.c.unlink(@ptrCast(&un.path)))) {
        .SUCCESS, .NOENT => {},
        .ACCES, .PERM => return io.ListenError.AccessDenied,
        else => return io.ListenError.SocketError,
    }
}

/// The file at `path` without following a symlink; null when there is none.
fn lstat(path: []const u8) io.ListenError!?posix.Stat {
    return posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => null,
        error.AccessDenied, error.PermissionDenied => io.ListenError.AccessDenied,
        error.NameTooLong => io.ListenError.NameTooLong,
        else => io.ListenError.SocketError,
    };
}

const Probe = enum { live, stale, gone };

/// Datagram connect to the socket file at `un`: ECONNREFUSED means no
/// socket is attached to it. See the module comment for why not a stream.
fn probe(un: *const posix.sockaddr.un) io.ListenError!Probe {
    const p = posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch |err| return switch (err) {
        error.AccessDenied => io.ListenError.AccessDenied,
        else => io.ListenError.SocketError,
    };
    defer posix.close(p);
    return switch (posix.errno(std.c.connect(p, sockPtr(un), addr_len))) {
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

    const s = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch return io.ConnectUnixError.SocketError;
    errdefer posix.close(s);
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        if (posix.errno(std.c.setsockopt(s, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int))) != .SUCCESS)
            return io.ConnectUnixError.SocketError;
    }

    switch (posix.errno(std.c.connect(s, sockPtr(&un), addr_len))) {
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

const TestPath = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn init() !TestPath {
        var p: TestPath = .{};
        p.len = (try std.fmt.bufPrint(&p.buf, "/tmp/born-up-{x}.sock", .{std.crypto.random.int(u64)})).len;
        return p;
    }

    fn get(self: *const TestPath) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *const TestPath) void {
        posix.unlink(self.get()) catch {};
    }
};

fn exists(path: []const u8) bool {
    _ = posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

/// Raw blocking stream connect; true when it succeeded.
fn rawConnect(path: []const u8) !bool {
    const un = try sockAddr(path);
    const c = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(c);
    return posix.errno(std.c.connect(c, sockPtr(&un), addr_len)) == .SUCCESS;
}

test "unix_posix: a socket bound but not yet listening is live, not stale" {
    const p = try TestPath.init();
    defer p.deinit();
    const un = try sockAddr(p.get());
    const raw = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(raw);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(std.c.bind(raw, sockPtr(&un), addr_len)));
    // A stream probe would see ECONNREFUSED here and unlink the path.
    try testing.expectError(error.AddressInUse, Listener.openUnix(testing.allocator, p.get(), .{}));
    try testing.expect(exists(p.get()));
}

test "unix_posix: a live listener with a full backlog is not stale" {
    const p = try TestPath.init();
    defer p.deinit();
    const un = try sockAddr(p.get());
    const srv = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(srv);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(std.c.bind(srv, sockPtr(&un), addr_len)));
    // Backlog 1, not 0: XNU replaces 0 with somaxconn.
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(std.c.listen(srv, 1)));

    // Fill the queue with connections nobody accepts.
    var clients: [64]posix.fd_t = undefined;
    var n: usize = 0;
    defer for (clients[0..n]) |c| posix.close(c);
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

test "unix_posix: close removes its own path, never a successor's" {
    const p = try TestPath.init();
    defer p.deinit();
    var first = try Listener.openUnix(testing.allocator, p.get(), .{});
    // Another instance takes the path over (removed by hand, rebound).
    try posix.unlink(p.get());
    var second = try Listener.openUnix(testing.allocator, p.get(), .{});
    first.close();
    try testing.expect(exists(p.get()));
    try testing.expect(try rawConnect(p.get()));
    second.close();
    try testing.expect(!exists(p.get()));
}

test "unix_posix: a copy inherited by another process does not unlink" {
    const p = try TestPath.init();
    defer p.deinit();
    var l = try Listener.openUnix(testing.allocator, p.get(), .{});
    l.unix.pid +%= 1; // as seen from a forked child
    l.close();
    try testing.expect(exists(p.get()));
}

test "unix_posix: a symlink at the path is refused and kept" {
    const p = try TestPath.init();
    defer p.deinit();
    const target = try TestPath.init();
    defer target.deinit();
    var l = try Listener.openUnix(testing.allocator, target.get(), .{});
    defer l.close();
    try posix.symlink(target.get(), p.get());
    try testing.expectError(error.PathNotASocket, Listener.openUnix(testing.allocator, p.get(), .{}));
    const st = try posix.fstatat(posix.AT.FDCWD, p.get(), posix.AT.SYMLINK_NOFOLLOW);
    try testing.expect(posix.S.ISLNK(st.mode));
}

test "unix_posix: empty paths and embedded NULs are refused" {
    var port = try evport.EvPort.init(testing.allocator);
    defer port.deinit();
    for ([_][]const u8{ "", "/tmp/born\x00cut" }) |bad| {
        try testing.expectError(error.SocketError, Listener.openUnix(testing.allocator, bad, .{}));
        var s: PlainNb = .{};
        try testing.expectError(error.ConnectFailed, connectInto(&s, testing.allocator, bad, &port, null));
        try testing.expectEqual(@as(posix.fd_t, -1), s.sock);
    }
}

test "unix_posix: the longest path that fits sun_path works, one more byte does not" {
    var buf: [sun_path_len]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buf, "/tmp/born-up-{x}-", .{std.crypto.random.int(u64)});
    @memset(buf[prefix.len..], 'x');
    const fits = buf[0 .. sun_path_len - 1];
    defer posix.unlink(fits) catch {};
    var l = try Listener.openUnix(testing.allocator, fits, .{});
    try testing.expect(try rawConnect(fits));
    l.close();
    try testing.expectError(error.NameTooLong, Listener.openUnix(testing.allocator, buf[0..sun_path_len], .{}));
}
