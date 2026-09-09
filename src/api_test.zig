const std = @import("std");
const builtin = @import("builtin");
const backend = switch (builtin.os.tag) {
    .freebsd, .macos, .netbsd, .openbsd => @import("evport_kqueue.zig"),
    .linux => @import("evport_epoll.zig"),
    .windows => @import("evport_iocp.zig"),
    else => @compileError("Unsupported platform"),
};

test "reactor has exact non-generic handle and event API" {
    const Port = backend.EvPort;
    const Handle = backend.Handle;
    const NativeHandle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t;
    try std.testing.expect(Handle == NativeHandle);
    try std.testing.expect(Handle == @import("types.zig").Handle);
    try std.testing.expect(backend.Event == @import("types.zig").Event);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(@TypeOf(Port.associate) == fn (*Port, Handle, ?*anyopaque) backend.Error!void);
        try std.testing.expect(@TypeOf(Port.post) == fn (*Port, *anyopaque, ?*std.os.windows.OVERLAPPED, usize) void);
        try std.testing.expect(@TypeOf(Port.wakeKey) == fn () *anyopaque);
    }
    try std.testing.expect(@TypeOf(Port.init) == fn (std.mem.Allocator) backend.Error!Port);
    try std.testing.expect(@TypeOf(Port.deinit) == fn (*Port) void);
    inline for (.{ "monitorRead", "wantWrite" }) |name| {
        try std.testing.expect(@TypeOf(@field(Port, name)) == fn (*Port, Handle, ?*anyopaque) void);
    }
    inline for (.{ "cancelWrite", "unmonitorRead", "purgeFd" }) |name| {
        try std.testing.expect(@TypeOf(@field(Port, name)) == fn (*Port, Handle) void);
    }
    try std.testing.expect(@TypeOf(Port.wake) == fn (*Port) void);
    try std.testing.expect(@TypeOf(Port.wait) == fn (*Port, []backend.Event, ?i32) backend.Error!usize);
    const event = backend.Event{};
    try std.testing.expect(@TypeOf(event.udata) == ?*anyopaque);
    try std.testing.expect(@TypeOf(event.err_no) == usize);
    try std.testing.expect(@TypeOf(event.overlapped) == ?*std.os.windows.OVERLAPPED);
    try std.testing.expect(@TypeOf(event.bytes) == usize);
    inline for (.{ "readable", "writable", "eof", "err", "wake" }) |name| {
        try std.testing.expect(@TypeOf(@field(event, name)) == bool);
        try std.testing.expect(!@field(event, name));
    }
    try std.testing.expect(event.udata == null);
    try std.testing.expect(event.overlapped == null);
    try std.testing.expectEqual(@as(usize, 0), event.err_no);
    try std.testing.expectEqual(@as(usize, 0), event.bytes);
}

test "reactor interest methods execute with native handles" {
    var port = try backend.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const handles = if (builtin.os.tag == .windows)
        [_]backend.Handle{ std.os.windows.INVALID_HANDLE_VALUE, std.os.windows.INVALID_HANDLE_VALUE }
    else
        try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer if (builtin.os.tag != .windows) {
        std.posix.close(handles[0]);
        std.posix.close(handles[1]);
    };
    var tag: u8 = 1;
    port.monitorRead(handles[0], &tag);
    port.wantWrite(handles[1], &tag);
    port.cancelWrite(handles[1]);
    port.unmonitorRead(handles[0]);
    port.purgeFd(handles[0]);
    port.purgeFd(handles[1]);
    var events: [8]backend.Event = undefined;
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(backend.Error.AssociateFailed, port.wait(&events, 0));
    } else {
        try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    }
}

test "registering a regular file is a loud failure, not a hang (issue #4)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var port = try backend.EvPort.init(std.testing.allocator);
    defer port.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("registration-target", .{});
    defer file.close();
    var tag: u8 = 1;
    if (builtin.os.tag == .linux) {
        // epoll refuses regular files with EPERM. The void registration API
        // must report that as a hard error from the next non-empty wait —
        // the exact trap (silent EPERM → wait forever) this issue is about.
        // Runtimes implementing epoll over kqueue (the FreeBSD Linuxulator)
        // accept regular files, matching kqueue's branch below instead.
        port.monitorRead(file.handle, &tag);
        var events: [8]backend.Event = undefined;
        const n = port.wait(&events, 0) catch |err| blk: {
            try std.testing.expectEqual(backend.Error.RegisterFailed, err);
            break :blk 0;
        };
        if (n != 0) try std.testing.expect(events[0].readable);
    } else {
        // kqueue accepts regular files; nothing to report.
        port.monitorRead(file.handle, &tag);
        port.wantWrite(file.handle, &tag);
        port.purgeFd(file.handle);
    }
}

test "empty wait preserves queued wake" {
    var port = try backend.EvPort.init(std.testing.allocator);
    defer port.deinit();
    port.wake();
    var empty: [0]backend.Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    var events: [1]backend.Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].wake);
    try std.testing.expect(events[0].overlapped == null);
    try std.testing.expectEqual(@as(usize, 0), events[0].bytes);
    try std.testing.expectEqual(@as(usize, 0), events[0].err_no);
}

test "empty wait preserves readiness registrations and events" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var port = try backend.EvPort.init(std.testing.allocator);
    defer port.deinit();
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    var tag: u8 = 1;
    port.monitorRead(fds[0], &tag);
    port.wantWrite(fds[0], &tag);
    const staged = if (@hasField(backend.EvPort, "changes")) port.changes.items.len else 0;
    var empty: [0]backend.Event = .{};
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    if (@hasField(backend.EvPort, "changes")) {
        try std.testing.expectEqual(staged, port.changes.items.len);
        try std.testing.expect(port.armed_write.contains(fds[0]));
    }
    try std.testing.expectEqual(@as(usize, 1), try std.posix.write(fds[1], "x"));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, 0));
    var events: [8]backend.Event = undefined;
    const n = try port.wait(&events, 1000);
    var readable = false;
    var writable = false;
    for (events[0..n]) |event| {
        try std.testing.expect(event.udata == @as(?*anyopaque, &tag));
        try std.testing.expect(!event.err);
        try std.testing.expectEqual(@as(usize, 0), event.err_no);
        try std.testing.expect(event.overlapped == null);
        try std.testing.expectEqual(@as(usize, 0), event.bytes);
        readable = readable or event.readable;
        writable = writable or event.writable;
    }
    try std.testing.expect(readable);
    try std.testing.expect(writable);
    port.cancelWrite(fds[0]);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(fds[0], &byte));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&events, 0));
    try std.testing.expectEqual(@as(usize, 1), try std.posix.write(fds[1], "y"));
    try std.testing.expectEqual(@as(usize, 0), try port.wait(&empty, null));
    try std.testing.expectEqual(@as(usize, 1), try port.wait(&events, 1000));
    try std.testing.expect(events[0].readable);
    try std.testing.expect(events[0].udata == @as(?*anyopaque, &tag));
}
