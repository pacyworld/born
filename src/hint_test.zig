//! Readiness counts (`Event.avail`, `hintReadable`): the API is the same on
//! every target, the counts themselves exist only on kqueue, and the
//! drain-to-EAGAIN contract holds either way.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("root.zig");
const socket = born.socket;
const alloc = std.testing.allocator;

const is_windows = builtin.os.tag == .windows;
const have_counts = std.mem.eql(u8, born.backend_name, "kqueue");

test "hint: API shape is the same on every target" {
    const ev: born.Event = .{};
    try std.testing.expect(@TypeOf(ev.avail) == usize);
    try std.testing.expectEqual(@as(usize, 0), ev.avail);
    try std.testing.expect(@TypeOf(socket.PlainNb.hintReadable) == fn (*socket.PlainNb, born.Event) void);
    try std.testing.expect(@TypeOf(socket.Listener.hintReadable) == fn (*socket.Listener, born.Event) void);
}

/// Wait for the next readable event on `udata`.
fn nextReadable(port: *born.EvPort, udata: *anyopaque) !born.Event {
    var events: [8]born.Event = undefined;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        const n = try port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.udata == @as(?*anyopaque, udata) and ev.readable) return ev;
        }
    }
    return error.NoReadableEvent;
}

test "hint: stream count skips the trailing read, and a late arrival raises a new event" {
    if (is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer std.posix.close(fds[1]);
    for (fds) |fd| {
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(@as(std.posix.O, .{ .NONBLOCK = true }))));
    }
    var stream: socket.PlainNb = .{ .sock = fds[0] };
    defer {
        port.purgeFd(fds[0]);
        stream.deinit();
    }
    port.monitorRead(fds[0], &stream);

    _ = try std.posix.write(fds[1], "0123456789");
    const ev = try nextReadable(&port, &stream);
    try std.testing.expectEqual(if (have_counts) @as(usize, 10) else 0, ev.avail);
    stream.hintReadable(ev);

    var buf: [4]u8 = undefined;
    var got: usize = 0;
    // Exactly the reported bytes, with no read after the last of them.
    while (got < 10) {
        switch (try stream.readNb(&buf)) {
            .data => |n| got += n,
            else => return error.UnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 10), got);

    // One more byte arrives after the kernel took the count.
    _ = try std.posix.write(fds[1], "x");
    if (have_counts) {
        // The count is spent: no read, even though a byte is queued.
        try std.testing.expectEqual(born.socket.NbRead.want_read, try stream.readNb(&buf));
    }
    // The arrival raised a new edge, so nothing is stranded. Without counts
    // (epoll) the contract is the plain one: drain to EAGAIN.
    const ev2 = try nextReadable(&port, &stream);
    stream.hintReadable(ev2);
    switch (try stream.readNb(&buf)) {
        .data => |n| try std.testing.expectEqual(@as(usize, 1), n),
        else => return error.UnexpectedResult,
    }
    try std.testing.expectEqual(born.socket.NbRead.want_read, try stream.readNb(&buf));
}

test "hint: an EOF event keeps draining until the read that returns zero" {
    if (is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    _ = try std.posix.fcntl(fds[0], std.posix.F.SETFL, @as(u32, @bitCast(@as(std.posix.O, .{ .NONBLOCK = true }))));
    var stream: socket.PlainNb = .{ .sock = fds[0] };
    defer {
        port.purgeFd(fds[0]);
        stream.deinit();
    }
    port.monitorRead(fds[0], &stream);
    _ = try std.posix.write(fds[1], "ab");
    std.posix.close(fds[1]);

    const ev = try nextReadable(&port, &stream);
    try std.testing.expect(ev.eof);
    stream.hintReadable(ev);
    var buf: [8]u8 = undefined;
    switch (try stream.readNb(&buf)) {
        .data => |n| try std.testing.expectEqual(@as(usize, 2), n),
        else => return error.UnexpectedResult,
    }
    try std.testing.expectEqual(born.socket.NbRead.eof, try stream.readNb(&buf));
}

test "hint: listener count skips the trailing accept, and a late arrival raises a new event" {
    if (is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    var l = socket.Listener.openTcp(alloc, try std.net.Address.parseIp4("127.0.0.1", 0), .{}) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
    try l.register(&port, &l);
    defer {
        port.purgeFd(l.handle());
        l.close();
    }
    const addr = try l.localAddress();

    var clients: [3]std.net.Stream = undefined;
    for (&clients) |*c| c.* = try std.net.tcpConnectToAddress(addr);
    defer for (&clients) |*c| c.close();

    const ev = try nextReadable(&port, &l);
    try std.testing.expectEqual(if (have_counts) @as(usize, 3) else 0, ev.avail);
    l.hintReadable(ev);
    var streams: [4]socket.PlainNb = .{ .{}, .{}, .{}, .{} };
    defer for (&streams) |*s| s.deinit();
    for (streams[0..3]) |*s| {
        try std.testing.expectEqual(socket.AcceptResult.accepted, try l.acceptNb(s, null));
    }

    // A fourth connection arrives after the kernel took the count.
    var late = try std.net.tcpConnectToAddress(addr);
    defer late.close();
    if (have_counts) {
        // The count is spent: no accept, even though a connection is queued.
        try std.testing.expectEqual(socket.AcceptResult.want_accept, try l.acceptNb(&streams[3], null));
    }
    const ev2 = try nextReadable(&port, &l);
    l.hintReadable(ev2);
    try std.testing.expectEqual(socket.AcceptResult.accepted, try l.acceptNb(&streams[3], null));
    var spare: socket.PlainNb = .{};
    try std.testing.expectEqual(socket.AcceptResult.want_accept, try l.acceptNb(&spare, null));
}
