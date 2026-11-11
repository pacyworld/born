//! Real-call tests for Born's native compatibility layer.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const testing = std.testing;

const native_os = builtin.os.tag;

const TestEnum = enum { first, second };

fn uniquePath(buffer: *[160:0]u8, label: []const u8) ![:0]u8 {
    const stamp = try compat.monotonicNs();
    const printed = try std.fmt.bufPrint(
        buffer,
        ".zig-cache/born-compat-{s}-{d}-{d}",
        .{ label, std.c.getpid(), stamp },
    );
    buffer[printed.len] = 0;
    return buffer[0..printed.len :0];
}

test "meta helpers use the active toolchain's real implementations" {
    var set = compat.emptyEnumSet(TestEnum);
    try testing.expect(!set.contains(.first));
    set.insert(.second);
    try testing.expect(set.contains(.second));
    try testing.expectEqual(@as(?usize, 2), compat.find(u8, "ab+=c=d", "+="));
    try testing.expectEqual(@as(?usize, 2), compat.findScalar(u8, "ab+c", '+'));
    try testing.expectEqual(@as(?usize, null), compat.find(u8, "abc", "z"));
    try testing.expectEqual(@as(?usize, null), compat.findScalar(u8, "abc", 'z'));

    const fields = compat.enumFields(TestEnum);
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("first", fields[0].name);
    try testing.expectEqual(@as(i64, 1), fields[1].value);
    const names = compat.errorSetNames(error{ First, Second });
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("Second", names[1]);
}

test "signals keep Born's u8 API over native signal values" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    const term = compat.signalNumber(std.posix.SIG.TERM);
    try testing.expectEqual(@as(u8, 15), term);
    try testing.expectEqual(term, compat.signalNumber(compat.nativeSignal(term)));
    var set = compat.sigemptyset();
    try testing.expect(!compat.sigismember(&set, term));
    compat.sigaddset(&set, term);
    try testing.expect(compat.sigismember(&set, term));
    const full = compat.sigfillset();
    try testing.expect(compat.sigismember(&full, term));
    try compat.kill(std.c.getpid(), 0);
}

var signal_delivered: std.atomic.Value(u32) = .init(0);

fn onSignalOld(signal: i32) callconv(.c) void {
    _ = signal;
    signal_delivered.store(1, .release);
}

fn onSignalNew(signal: compat.NativeSignal) callconv(.c) void {
    _ = signal;
    signal_delivered.store(1, .release);
}

test "sigaction, raise, and pthread signal masks make native calls" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    const signal = compat.signalNumber(std.posix.SIG.USR2);
    const handler: compat.Sigaction.handler_fn = if (builtin.zig_version.minor < 16)
        onSignalOld
    else
        onSignalNew;
    const action: compat.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = compat.sigemptyset(),
        .flags = 0,
    };
    var original: compat.Sigaction = undefined;
    compat.sigaction(signal, &action, &original);
    defer compat.sigaction(signal, &original, null);

    var empty = compat.sigemptyset();
    var saved: compat.sigset_t = undefined;
    try testing.expectEqual(
        @as(c_int, 0),
        compat.pthreadSigmask(std.posix.SIG.SETMASK, &empty, &saved),
    );
    defer compat.sigprocmask(std.posix.SIG.SETMASK, &saved, null);
    signal_delivered.store(0, .monotonic);
    try compat.raise(signal);
    try testing.expect(signal_delivered.load(.acquire) != 0);
}

test "waitid passes the required null usage pointer on Linux" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    const rc = compat.waitid(.PIDFD, -1, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT);
    const err = if (builtin.zig_version.minor < 16) linux.E.init(rc) else linux.errno(rc);
    try testing.expectEqual(linux.E.INVAL, err);
}

test "pipe, descriptor, and nonblocking I/O wrappers make native calls" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    const fds = try compat.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer compat.close(fds[0]);
    defer compat.close(fds[1]);

    const descriptor_flags = try compat.fcntl(fds[0], compat.F.GETFD, 0);
    try testing.expect((descriptor_flags & compat.FD_CLOEXEC) != 0);
    const status_flags = try compat.fcntl(fds[0], compat.F.GETFL, 0);
    const nonblock: u32 = @bitCast(@as(compat.O, .{ .NONBLOCK = true }));
    try testing.expect((status_flags & nonblock) != 0);

    var empty: [1]u8 = undefined;
    try testing.expectError(error.WouldBlock, compat.read(fds[0], &empty));
    try testing.expectEqual(@as(usize, 4), try compat.write(fds[1], "ping"));
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try compat.read(fds[0], &buffer));
    try testing.expectEqualSlices(u8, "ping", &buffer);

    const duplicate = try compat.dup(fds[0]);
    defer compat.close(duplicate);
    try testing.expect(duplicate != fds[0]);
    try compat.dup2(fds[0], duplicate);
    try testing.expectError(error.WouldBlock, compat.read(duplicate, &empty));
    try testing.expectError(error.WouldBlock, compat.read(fds[0], &empty));
}

test "read and write caps match the target ABI" {
    const expected: usize = if (native_os == .linux)
        0x7ffff000
    else if (native_os.isDarwin())
        std.math.maxInt(i32)
    else
        std.math.maxInt(isize);
    try testing.expectEqual(expected, compat.max_io_count);
}

test "descriptor and socket-name failures retain their native mappings" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    const fds = try compat.pipe2(.{ .CLOEXEC = true });
    compat.close(fds[0]);
    defer compat.close(fds[1]);
    var byte: [1]u8 = undefined;
    try testing.expectError(error.NotOpenForReading, compat.read(fds[0], &byte));
    try testing.expectError(error.NotOpenForWriting, compat.write(fds[0], &byte));

    var address: compat.sockaddr.storage = undefined;
    var length: compat.socklen_t = @sizeOf(compat.sockaddr.storage);
    try testing.expectError(
        error.FileDescriptorNotASocket,
        compat.getsockname(fds[1], @ptrCast(&address), &length),
    );
    length = @sizeOf(compat.sockaddr.storage);
    try testing.expectError(
        error.FileDescriptorNotASocket,
        compat.getpeername(fds[1], @ptrCast(&address), &length),
    );
}

test "file identity and chmod work through the native stat and fallback APIs" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    var file_buffer: [160:0]u8 = undefined;
    var link_buffer: [160:0]u8 = undefined;
    const path = try uniquePath(&file_buffer, "file");
    const link_path = try uniquePath(&link_buffer, "link");
    const flags: compat.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
    };
    const fd = try compat.open(path, flags, 0o600);
    compat.close(fd);
    defer compat.unlink(path) catch {};

    const initial = try compat.fstatat(compat.AT.FDCWD, path, 0);
    try testing.expect((initial.mode & compat.S.IFMT) == compat.S.IFREG);
    try testing.expect(initial.ino != 0);
    try compat.fchmodat(compat.AT.FDCWD, path, 0o640, compat.AT.SYMLINK_NOFOLLOW);
    const changed = try compat.fstatat(compat.AT.FDCWD, path, 0);
    try testing.expectEqual(initial.dev, changed.dev);
    try testing.expectEqual(initial.ino, changed.ino);
    try testing.expectEqual(@as(u32, 0o640), changed.mode & 0o777);

    try compat.symlink(std.fs.path.basename(path), link_path);
    defer compat.unlink(link_path) catch {};
    const link_stat = try compat.fstatat(compat.AT.FDCWD, link_path, compat.AT.SYMLINK_NOFOLLOW);
    try testing.expect((link_stat.mode & compat.S.IFMT) == compat.S.IFLNK);

    try compat.fchmodat(compat.AT.FDCWD, path, 0o600, 0);
    if (comptime native_os == .linux) {
        try compat.fchmodat(compat.AT.FDCWD, link_path, 0o640, 0);
        const followed = try compat.fstatat(compat.AT.FDCWD, path, 0);
        try testing.expectEqual(@as(u32, 0o640), followed.mode & 0o777);
        try compat.fchmodatWithPolicy(
            compat.AT.FDCWD,
            path,
            0o640,
            compat.AT.SYMLINK_NOFOLLOW,
            true,
        );
        const forced = try compat.fstatat(compat.AT.FDCWD, path, 0);
        try testing.expectEqual(@as(u32, 0o640), forced.mode & 0o777);
        try testing.expectError(
            error.OperationNotSupported,
            compat.fchmodatWithPolicy(
                compat.AT.FDCWD,
                link_path,
                0o600,
                compat.AT.SYMLINK_NOFOLLOW,
                true,
            ),
        );
    }
    try compat.unlink(link_path);
    try testing.expectError(error.FileNotFound, compat.fstatat(compat.AT.FDCWD, link_path, 0));
}

test "Address owns native IPv4, IPv6, and Unix layouts" {
    const ipv4 = try compat.Address.parseIp4("127.0.0.1", 4321);
    try testing.expectEqual(@as(u16, 4321), ipv4.getPort());
    try testing.expectEqual(
        @as(compat.socklen_t, @sizeOf(compat.sockaddr.in)),
        ipv4.getOsSockLen(),
    );
    const ipv4_copy = compat.Address.initPosix(@ptrCast(@alignCast(&ipv4.any)));
    try testing.expect(ipv4.eql(ipv4_copy));
    try testing.expectError(error.NonCanonical, compat.Address.parseIp4("127.00.0.1", 0));
    try testing.expectError(error.Incomplete, compat.Address.parseIp4("127.0.0", 0));

    const ipv6 = try compat.Address.parseIp6("::1", 8080);
    try testing.expectEqual(@as(u16, 8080), ipv6.getPort());
    try testing.expectEqual(@as(u8, 1), ipv6.in6.addr[15]);
    const mapped = try compat.Address.parseIp6("::ffff:192.0.2.1", 0);
    try testing.expectEqual(@as(u8, 0xff), mapped.in6.addr[10]);
    try testing.expectEqual(@as(u8, 192), mapped.in6.addr[12]);
    try testing.expectError(
        error.InvalidIpv4Mapping,
        compat.Address.parseIp6("2001:db8::192.0.2.1", 0),
    );

    if (comptime compat.has_unix_sockets) {
        const unix = try compat.Address.initUnix("born-test.sock");
        try testing.expectEqual(
            @as(compat.socklen_t, @sizeOf(compat.sockaddr.un)),
            unix.getOsSockLen(),
        );
        try testing.expectEqualSlices(u8, "born-test.sock", std.mem.sliceTo(&unix.un.path, 0));
        if (@hasField(compat.sockaddr.un, "len")) {
            try testing.expectEqual(@as(u8, @sizeOf(compat.sockaddr.un)), unix.un.len);
        }
        var too_long: [unix.un.path.len]u8 = @splat('x');
        try testing.expectError(error.NameTooLong, compat.Address.initUnix(&too_long));
    }
}

test "Unix Address binds, listens, and accepts with native sun_len" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    var path_buffer: [160:0]u8 = undefined;
    const path = try uniquePath(&path_buffer, "unix");
    defer compat.unlink(path) catch {};
    const address = try compat.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var client = try compat.tcpConnectToAddress(address);
    defer client.close();
    var connection = try server.accept();
    defer connection.stream.close();
    try testing.expectEqual(@as(usize, 2), try client.write("ok"));
    var buffer: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try connection.stream.read(&buffer));
    try testing.expectEqualSlices(u8, "ok", &buffer);
}

test "getAddressList allocates and releases native resolver results" {
    const list = try compat.getAddressList(testing.allocator, "localhost", 8080);
    defer list.deinit();
    try testing.expect(list.addrs.len != 0);
    for (list.addrs) |address| {
        const ip_family = address.any.family == compat.AF.INET or
            address.any.family == compat.AF.INET6;
        try testing.expect(ip_family);
        try testing.expectEqual(@as(u16, 8080), address.getPort());
    }
}

test "raw Stream and Server carry blocking TCP traffic" {
    const address = try compat.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{
        .force_nonblocking = true,
        .reuse_address = true,
    });
    defer server.deinit();
    try testing.expect(server.listen_address.getPort() != 0);
    try testing.expectError(error.WouldBlock, server.accept());
    if (comptime native_os == .windows) {
        var blocking: u32 = 0;
        const rc = compat.windows.ws2_32.ioctlsocket(
            server.stream.handle,
            compat.windows.ws2_32.FIONBIO,
            &blocking,
        );
        try testing.expectEqual(@as(i32, 0), rc);
    } else {
        const status = try compat.fcntl(server.stream.handle, compat.F.GETFL, 0);
        const nonblock: u32 = @bitCast(@as(compat.O, .{ .NONBLOCK = true }));
        _ = try compat.fcntl(server.stream.handle, compat.F.SETFL, status & ~nonblock);
    }

    var client = try compat.tcpConnectToAddress(server.listen_address);
    defer client.close();
    var connection = try server.accept();
    defer connection.stream.close();

    try testing.expectEqual(@as(usize, 4), try compat.send(client.handle, "ping", 0));
    var input: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try connection.stream.read(&input));
    try testing.expectEqualSlices(u8, "ping", &input);
    try testing.expectEqual(@as(usize, 4), try connection.stream.write("pong"));
    try testing.expectEqual(@as(usize, 4), try client.read(&input));
    try testing.expectEqualSlices(u8, "pong", &input);

    var socket_error: c_int = -1;
    try compat.getsockopt(
        client.handle,
        compat.SOL.SOCKET,
        compat.SO.ERROR,
        std.mem.asBytes(&socket_error),
    );
    try testing.expectEqual(@as(c_int, 0), socket_error);
    var local: compat.sockaddr.storage = undefined;
    var local_length: compat.socklen_t = @sizeOf(compat.sockaddr.storage);
    try compat.getsockname(client.handle, @ptrCast(&local), &local_length);
    var peer: compat.sockaddr.storage = undefined;
    var peer_length: compat.socklen_t = @sizeOf(compat.sockaddr.storage);
    try compat.getpeername(connection.stream.handle, @ptrCast(&peer), &peer_length);
    const local_address = compat.Address.initPosix(@ptrCast(&local));
    const peer_address = compat.Address.initPosix(@ptrCast(&peer));
    try testing.expect(local_address.eql(peer_address));

    try compat.shutdown(client.handle, .send);
    try testing.expectEqual(@as(usize, 0), try connection.stream.read(&input));
}

test "kqueue returns a native descriptor on kqueue targets" {
    switch (native_os) {
        .freebsd, .netbsd, .openbsd, .macos, .ios, .tvos, .watchos, .visionos, .driverkit => {},
        else => return error.SkipZigTest,
    }
    const fd = try compat.kqueue();
    compat.close(fd);
}

test "monotonic time and sleep advance without wall-clock assumptions" {
    const before = try compat.monotonicNs();
    compat.sleepNs(2 * std.time.ns_per_ms);
    const after = try compat.monotonicNs();
    try testing.expect(after >= before);
    try testing.expect(after - before >= std.time.ns_per_ms);
}

const ConditionContext = struct {
    mutex: compat.Mutex = .{},
    condition: compat.Condition = .{},
    ready: bool = false,
    finished: bool = false,

    fn worker(self: *ConditionContext) void {
        self.mutex.lock();
        while (!self.ready) self.condition.wait(&self.mutex);
        self.finished = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn namedWorker(self: *ConditionContext) void {
        _ = self;
    }
};

test "raw mutex and condition synchronize a real thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var context: ConditionContext = .{};
    defer context.condition.deinit();
    defer context.mutex.deinit();
    const thread = try std.Thread.spawn(.{}, ConditionContext.worker, .{&context});
    compat.setThreadName(thread, "born-compat");
    context.mutex.lock();
    context.ready = true;
    context.condition.signal();
    context.mutex.unlock();
    thread.join();
    try testing.expect(context.finished);
}

test "Condition returns a real nonzero timeout" {
    var mutex: compat.Mutex = .{};
    defer mutex.deinit();
    var condition: compat.Condition = .{};
    defer condition.deinit();
    const before = try compat.monotonicNs();
    mutex.lock();
    defer mutex.unlock();
    try testing.expectError(error.Timeout, condition.timedWait(&mutex, 5 * std.time.ns_per_ms));
    const after = try compat.monotonicNs();
    try testing.expect(after - before >= std.time.ns_per_ms);
}

const ContentionContext = struct {
    start: compat.ResetEvent = .{},
    event: compat.ResetEvent = .{},
    mutex: compat.Mutex = .{},
    condition: compat.Condition = .{},
    completed: std.atomic.Value(usize) = .init(0),

    fn worker(self: *ContentionContext) void {
        self.start.wait();
        self.mutex.lock();
        self.condition.timedWait(&self.mutex, std.time.ns_per_ms) catch |err| switch (err) {
            error.Timeout => {},
        };
        self.mutex.unlock();
        self.event.timedWait(std.time.ns_per_ms) catch |err| switch (err) {
            error.Timeout => {},
        };
        _ = self.completed.fetchAdd(1, .release);
    }
};

test "first use is safe under mutex, condition, and ResetEvent contention" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var context: ContentionContext = .{};
    defer context.start.deinit();
    defer context.event.deinit();
    defer context.condition.deinit();
    defer context.mutex.deinit();
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, ContentionContext.worker, .{&context});
    }
    context.start.set();
    for (threads) |thread| thread.join();
    try testing.expectEqual(@as(usize, threads.len), context.completed.load(.acquire));
}

test "ResetEvent wakes waiters and reports timeout" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const Context = struct {
        event: compat.ResetEvent = .{},

        fn worker(self: *@This()) void {
            compat.sleepNs(std.time.ns_per_ms);
            self.event.set();
        }
    };
    var context: Context = .{};
    defer context.event.deinit();
    try testing.expect(!context.event.isSet());
    try testing.expectError(error.Timeout, context.event.timedWait(0));
    const before = try compat.monotonicNs();
    try testing.expectError(error.Timeout, context.event.timedWait(5 * std.time.ns_per_ms));
    const after = try compat.monotonicNs();
    try testing.expect(after - before >= std.time.ns_per_ms);
    const thread = try std.Thread.spawn(.{}, Context.worker, .{&context});
    try context.event.timedWait(std.time.ns_per_s);
    thread.join();
    context.event.wait();
    try testing.expect(context.event.isSet());
    context.event.reset();
    try testing.expect(!context.event.isSet());
}

fn expectWindowsLayouts() !void {
    const windows = compat.windows;
    if (@sizeOf(windows.BOOL) != 4) return error.LayoutBool;
    if (@sizeOf(windows.OVERLAPPED_ENTRY) != 4 * @sizeOf(usize)) {
        return error.LayoutOverlappedEntry;
    }
    if (@offsetOf(windows.OVERLAPPED_ENTRY, "lpOverlapped") != @sizeOf(usize)) {
        return error.LayoutOverlappedEntryPointer;
    }
    if (@offsetOf(windows.OVERLAPPED, "Internal") != 0) return error.LayoutOverlappedInternal;
    if (@offsetOf(windows.OVERLAPPED, "DUMMYUNIONNAME") != 16) {
        return error.LayoutOverlappedUnion;
    }
    if (@offsetOf(windows.OVERLAPPED, "hEvent") != 24) return error.LayoutOverlappedEvent;
    if (@sizeOf(windows.ws2_32.WSADATA) != 408) return error.LayoutWsadata;
    if (@sizeOf(windows.ws2_32.WSABUF) != 2 * @sizeOf(usize)) return error.LayoutWsabuf;
}

fn timerCallback(
    instance: ?*compat.windows.kernel32.TpCallbackInstance,
    context: ?*anyopaque,
    timer: *compat.windows.kernel32.TpTimer,
) callconv(.winapi) void {
    _ = instance;
    _ = timer;
    const count: *std.atomic.Value(u32) = @ptrCast(@alignCast(context.?));
    _ = count.fetchAdd(1, .release);
}

test "Windows ABI declarations make real QPC, IOCP, timer, and Winsock calls" {
    if (comptime native_os != .windows) return error.SkipZigTest;
    try expectWindowsLayouts();
    const windows = compat.windows;
    const kernel32 = windows.kernel32;
    const ws2 = windows.ws2_32;

    _ = try compat.monotonicNs();
    const port = kernel32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse
        return error.IocpCreateFailed;
    defer _ = kernel32.CloseHandle(port);
    var key: u8 = 0;
    var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
    const posted = kernel32.PostQueuedCompletionStatus(
        port,
        7,
        @intFromPtr(&key),
        &overlapped,
    );
    if (posted == 0) return error.IocpPostFailed;
    var entries: [1]windows.OVERLAPPED_ENTRY = undefined;
    var removed: u32 = 0;
    const harvested = kernel32.GetQueuedCompletionStatusEx(
        port,
        &entries,
        1,
        &removed,
        1000,
        0,
    );
    if (harvested == 0) return error.IocpHarvestFailed;
    if (removed != 1) return error.IocpHarvestCount;
    if (entries[0].lpCompletionKey != @intFromPtr(&key)) return error.IocpCompletionKey;
    if (entries[0].dwNumberOfBytesTransferred != 7) return error.IocpCompletionBytes;
    if (entries[0].lpOverlapped != &overlapped) return error.IocpCompletionOverlapped;
    _ = kernel32.CancelIoEx(port, null);
    var console_pid: [1]u32 = undefined;
    _ = kernel32.GetConsoleProcessList(&console_pid, 1);

    var callback_count: std.atomic.Value(u32) = .init(0);
    const timer = kernel32.CreateThreadpoolTimer(timerCallback, &callback_count, null) orelse
        return error.ThreadpoolTimerCreateFailed;
    defer kernel32.CloseThreadpoolTimer(timer);
    const due: windows.FILETIME = .{ .dwLowDateTime = 0xffff_ffff, .dwHighDateTime = 0xffff_ffff };
    kernel32.SetThreadpoolTimer(timer, &due, 0, 0);
    if (kernel32.IsThreadpoolTimerSet(timer) == 0) return error.ThreadpoolTimerNotSet;
    kernel32.Sleep(20);
    kernel32.WaitForThreadpoolTimerCallbacks(timer, windows.FALSE);
    if (callback_count.load(.acquire) == 0) return error.ThreadpoolTimerDidNotFire;
    kernel32.SetThreadpoolTimer(timer, null, 0, 0);

    var wsa: ws2.WSADATA = undefined;
    if (ws2.WSAStartup(0x0202, &wsa) != 0) return error.WsaStartupFailed;
    defer _ = ws2.WSACleanup();
    var server = try (try compat.Address.parseIp4("127.0.0.1", 0)).listen(.{});
    defer server.deinit();
    var client = try compat.tcpConnectToAddress(server.listen_address);
    defer client.close();
    var connection = try server.accept();
    defer connection.stream.close();

    var accept_ex: ?*anyopaque = null;
    var returned: u32 = 0;
    const guid: windows.GUID = .{
        .Data1 = 0xb5367df1,
        .Data2 = 0xcbac,
        .Data3 = 0x11cf,
        .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
    };
    const ioctl_rc = ws2.WSAIoctl(
        server.stream.handle,
        ws2.SIO_GET_EXTENSION_FUNCTION_POINTER,
        &guid,
        @sizeOf(windows.GUID),
        @ptrCast(&accept_ex),
        @sizeOf(?*anyopaque),
        &returned,
        null,
        null,
    );
    if (ioctl_rc != 0) return error.AcceptExIoctlFailed;
    if (accept_ex == null) return error.AcceptExResolutionFailed;

    var send_buffer = [_]u8{ 'o', 'k' };
    var send_wsa: ws2.WSABUF = .{ .len = send_buffer.len, .buf = &send_buffer };
    var sent: u32 = 0;
    const send_rc = ws2.WSASend(
        client.handle,
        @ptrCast(&send_wsa),
        1,
        &sent,
        0,
        null,
        null,
    );
    if (send_rc != 0) return error.WsaSendFailed;
    try testing.expectEqual(@as(u32, 2), sent);
    var receive_buffer: [2]u8 = undefined;
    var receive_wsa: ws2.WSABUF = .{ .len = receive_buffer.len, .buf = &receive_buffer };
    var flags: u32 = 0;
    var received: u32 = 0;
    const receive_rc = ws2.WSARecv(
        connection.stream.handle,
        @ptrCast(&receive_wsa),
        1,
        &received,
        &flags,
        null,
        null,
    );
    if (receive_rc != 0) return error.WsaRecvFailed;
    try testing.expectEqual(@as(u32, 2), received);
    try testing.expectEqualSlices(u8, "ok", &receive_buffer);

    // compat.socket uses the already-held WSAStartup reference above.
    const raw = try compat.socket(
        compat.AF.INET,
        compat.SOCK.STREAM | compat.SOCK.CLOEXEC | compat.SOCK.NONBLOCK,
        compat.IPPROTO.TCP,
    );
    defer _ = ws2.closesocket(raw);
    const raw_address = try compat.Address.parseIp4("127.0.0.1", 0);
    try compat.bind(raw, &raw_address.any, raw_address.getOsSockLen());
    try compat.listen(raw, 1);
    try testing.expectError(
        error.WouldBlock,
        compat.accept(raw, null, null, compat.SOCK.CLOEXEC),
    );
}

test "resolver errors and first nonnull canonical name retain native semantics" {
    if (comptime native_os == .windows) return error.SkipZigTest;
    try testing.expectEqual(
        error.HostLacksNetworkAddresses,
        compat.mapGaiError(.ADDRFAMILY),
    );
    try testing.expectEqual(
        error.HostLacksNetworkAddresses,
        compat.mapGaiError(.NODATA),
    );

    var storage: compat.sockaddr.storage align(8) = undefined;
    @memset(std.mem.asBytes(&storage), 0);
    storage.family = compat.AF.INET;
    if (@hasField(@TypeOf(storage), "len")) storage.len = @sizeOf(compat.sockaddr.in);
    const canonical_name: [*:0]u8 = @constCast("canonical");
    var second: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = compat.AF.INET,
        .socktype = compat.SOCK.STREAM,
        .protocol = compat.IPPROTO.TCP,
        .addrlen = @sizeOf(compat.sockaddr.in),
        .canonname = canonical_name,
        .addr = @ptrCast(&storage),
        .next = null,
    };
    var first: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = compat.AF.INET,
        .socktype = compat.SOCK.STREAM,
        .protocol = compat.IPPROTO.TCP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = &second,
    };
    const list = try compat.addressListFromPosix(testing.allocator, &first);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.addrs.len);
    try testing.expectEqualStrings("canonical", list.canon_name.?);
}
