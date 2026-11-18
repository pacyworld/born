//! Network-route tests for the born.io shim (P5.3, Option B client path).
//!
//! These exercise the Born evented network client family: IP and pathname Unix
//! connect, stream read/write (partial, vectored, splat, EOF, reset), close,
//! shutdown, the provenance gate, the coarse error map, try-before-park, the
//! stale-fd generation guard, the batch construction-time exclusion, and the
//! per-route counters that prove a client ran on Born's reactor. The fixture
//! peer runs on its own `Io.Threaded` so the shim interface only ever sees
//! Born-owned client operations; a zero `threaded_*` counter after an exchange
//! is the provenance-gate evidence. Runtime evidence requires running these on
//! each kernel; a cross-build is not evidence.

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
const is_windows = builtin.os.tag == .windows;
const has_unix = !is_windows;

fn initNetIo(port: *born.EvPort) born_io.InitError!Io {
    return born_io.io(port, .{
        .allocator = std.testing.allocator,
        .capabilities = .{ .network = .born_evented },
    });
}

/// Toolchain-dispatched low-level stream read. Returns the byte count (0 on
/// EOF); the error set is the pinned `Stream.Reader.Error` on both toolchains.
fn rawRead(io: Io, h: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    if (is_017) {
        const res = try io.operate(.{ .net_read = .{ .socket_handle = h, .data = data } });
        return (try res.net_read).data_len;
    } else {
        return io.vtable.netRead(io.userdata, h, data);
    }
}

/// Toolchain-dispatched low-level stream write (header + data + splat).
fn rawWrite(io: Io, h: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
    if (is_017) {
        const res = try io.operate(.{ .net_write = .{ .socket_handle = h, .header = header, .data = data, .splat = splat } });
        return try res.net_write;
    } else {
        return io.vtable.netWrite(io.userdata, h, header, data, splat);
    }
}

/// Fill every iovec in `data` by looping low-level reads (a stream read returns
/// a partial count whenever fewer bytes have arrived than the iovecs hold).
/// Stops early on EOF; returns the total bytes read.
fn readFull(io: Io, h: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    var off: usize = 0;
    var total: usize = 0;
    while (true) {
        var rem: [8][]u8 = undefined;
        var nrem: usize = 0;
        var skip = off;
        for (data) |buf| {
            if (skip >= buf.len) {
                skip -= buf.len;
                continue;
            }
            rem[nrem] = buf[skip..];
            nrem += 1;
            skip = 0;
        }
        if (nrem == 0) break;
        const n = try rawRead(io, h, rem[0..nrem]);
        if (n == 0) break;
        off += n;
        total += n;
    }
    return total;
}

/// Force the next close of `h` to send RST instead of FIN (SO_LINGER {1,0}),
/// so the peer's read/write deterministically observe a connection reset.
fn forceResetOnClose(h: Io.net.Socket.Handle) void {
    // Windows compat socket calls take ws2_32.SOCKET, not the raw HANDLE.
    const sock: compat.socket_t = if (is_windows) @ptrCast(h) else h;
    if (is_windows) {
        // Winsock SO_LINGER (0x0080). compat.SO enumerates only the options
        // Born core uses, so the fixture names the value it needs locally.
        const SO_LINGER: u32 = 0x0080;
        const l: extern struct { onoff: u16, linger: u16 } = .{ .onoff = 1, .linger = 0 };
        compat.setsockopt(sock, @intCast(compat.SOL.SOCKET), SO_LINGER, std.mem.asBytes(&l)) catch {};
    } else {
        const l: extern struct { onoff: c_int, linger: c_int } = .{ .onoff = 1, .linger = 0 };
        compat.setsockopt(sock, @intCast(compat.SOL.SOCKET), @intCast(compat.SO.LINGER), std.mem.asBytes(&l)) catch {};
    }
}

/// A connected pair: `client` is Born-owned (connected through the shim), the
/// listener and accepted `peer` are Threaded-owned on the caller's fixture.
fn setupPair(io: Io, fixture: *Io.Threaded, server: *Io.net.Server, client: *Io.net.Stream, peer: *Io.net.Stream) !void {
    const fio = fixture.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    server.* = try addr.listen(fio, .{});
    const bound = server.socket.address;
    client.* = try bound.connect(io, .{ .mode = .stream });
    peer.* = try server.accept(fio);
}

test "network route constructs with the Born network vtable and deinits" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const interface = try initNetIo(&port);
    defer born_io.deinit(interface);

    try expect(std.meta.eql(interface.vtable.*, born_io.network_vtable));
    try expect(!std.meta.eql(interface.vtable.netConnectIp, born_io.baseline_vtable.netConnectIp));
    try expect(!std.meta.eql(interface.vtable.netClose, born_io.baseline_vtable.netClose));
    // Listen/accept, DNS and the time family keep delegating to Threaded.
    try expect(std.meta.eql(interface.vtable.netListenIp, born_io.baseline_vtable.netListenIp));
    try expect(std.meta.eql(interface.vtable.netAccept, born_io.baseline_vtable.netAccept));
    try expect(std.meta.eql(interface.vtable.netLookup, born_io.baseline_vtable.netLookup));
    try expect(std.meta.eql(interface.vtable.sleep, born_io.baseline_vtable.sleep));
}

test "TCP client consumer runs on Born: per-route counters prove the reactor path" {
    // Done-when evidence (should-fix 4): a real client exchange through the
    // high-level Stream reader/writer, asserting Born connect/read/write
    // completions are non-zero and the Threaded-forward counters stay zero (the
    // provenance gate never forwarded a Born-owned handle). The fixture peer is
    // a separate Threaded instance, so its I/O does not touch the shim counters.
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);

    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fio);
    defer client.close(io);
    defer server.deinit(fio);

    // Client writes "hello born" (two buffered writes, one flush).
    var wbuf: [128]u8 = undefined;
    var writer = client.writer(io, &wbuf);
    try writer.interface.writeAll("hello ");
    try writer.interface.writeAll("born");
    try writer.interface.flush();

    // Peer reads the 10 bytes and echoes them back.
    var pbuf: [64]u8 = undefined;
    var preader = peer.reader(fio, &pbuf);
    var echo: [10]u8 = undefined;
    var echo_iov = [_][]u8{echo[0..]};
    try preader.interface.readVecAll(&echo_iov);
    var pwriter = peer.writer(fio, &pbuf);
    try pwriter.interface.writeAll(&echo);
    try pwriter.interface.flush();

    // Client reads the echo.
    var rbuf: [64]u8 = undefined;
    var reader = client.reader(io, &rbuf);
    var got: [10]u8 = undefined;
    var got_iov = [_][]u8{got[0..]};
    try reader.interface.readVecAll(&got_iov);
    try expectEqualSlices(u8, "hello born", &got);

    const st = born_io.networkStats(io);
    if (born_io.network_stats_enabled) {
        try expect(st.connect > 0);
        try expect(st.read > 0);
        try expect(st.write > 0);
        try expectEqual(@as(u64, 0), st.threaded_connect);
        try expectEqual(@as(u64, 0), st.threaded_read);
        try expectEqual(@as(u64, 0), st.threaded_write);
    } else {
        // Default config: the snapshot reports the documented zeros.
        try expectEqual(@as(u64, 0), st.connect);
        try expectEqual(@as(u64, 0), st.read);
        try expectEqual(@as(u64, 0), st.write);
        try expectEqual(@as(u64, 0), st.threaded_connect);
        try expectEqual(@as(u64, 0), st.threaded_read);
        try expectEqual(@as(u64, 0), st.threaded_write);
    }
}

test "connect populates the local address and an ephemeral port" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // The connect thunk fills address via getsockname: loopback family, a
    // non-zero ephemeral local port distinct from the server's port.
    const local = client.socket.address;
    try expect(local == .ip4);
    try expectEqual(@as(u8, 127), local.ip4.bytes[0]);
    try expect(local.ip4.port != 0);
    try expect(local.ip4.port != server.socket.address.ip4.port);
}

test "connect to a closed port returns ConnectionRefused" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();

    // Bind a loopback port, note it, then close the listener so the port refuses.
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(fio, .{});
    const refused_addr = server.socket.address;
    server.deinit(fio);

    try expectError(error.ConnectionRefused, refused_addr.connect(io, .{ .mode = .stream }));
}

test "connect with an expired deadline returns Timeout without connecting" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);

    const now_ns = try born.nowNs();
    const target: Io.net.IpAddress = .{ .ip4 = .loopback(9) };
    // A deadline already in the past expires before any socket is created.
    try expectError(error.Timeout, target.connect(io, .{
        .mode = .stream,
        .timeout = .{ .deadline = .{ .raw = .fromNanoseconds(@intCast(now_ns - 10 * std.time.ns_per_ms)), .clock = .awake } },
    }));
    // A zero duration is an immediate deadline (now), also Timeout.
    try expectError(error.Timeout, target.connect(io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(0), .clock = .awake } },
    }));
}

test "connect rejects non-stream modes and non-TCP protocols with OptionUnsupported" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    const target: Io.net.IpAddress = .{ .ip4 = .loopback(9) };
    try expectError(error.OptionUnsupported, target.connect(io, .{ .mode = .dgram }));
    try expectError(error.OptionUnsupported, target.connect(io, .{ .mode = .stream, .protocol = .udp }));
}

test "Unix pathname connect and echo run on Born" {
    if (!has_unix or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A relative pathname keeps the fixture portable: Threaded's
    // realPathFile is unsupported on NetBSD, and both the Threaded listener
    // and the Born client resolve it against the same process cwd. The path
    // is far below every platform's sun_path capacity.
    var path_buf: [128]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/s", .{tmp.sub_path});

    const ua: Io.net.UnixAddress = .{ .path = sock_path };
    var userver = try ua.listen(fio, .{});
    defer userver.deinit(fio);

    const handle = try io.vtable.netConnectUnix(io.userdata, &ua);
    const client: Io.net.Stream = .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } } };
    defer client.close(io);
    var peer = try userver.accept(fio);
    defer peer.close(fio);

    var msg = [_][]const u8{"unix-born"};
    try expectEqual(@as(usize, 9), try rawWrite(io, handle, &.{}, &msg, 1));
    var buf: [9]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectEqual(@as(usize, 9), try rawRead(io, peer.socket.handle, &iov));
    try expectEqualSlices(u8, "unix-born", &buf);

    if (born_io.network_stats_enabled) {
        const st = born_io.networkStats(io);
        try expect(st.connect > 0);
        try expect(st.write > 0);
        try expectEqual(@as(u64, 0), st.threaded_connect);
    }
}

test "Unix connect on Windows returns AddressFamilyUnsupported" {
    if (!is_windows or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    const ua: Io.net.UnixAddress = .{ .path = "born-test.sock" };
    try expectError(error.AddressFamilyUnsupported, io.vtable.netConnectUnix(io.userdata, &ua));
}

test "Unix abstract address forwards to Threaded (provenance fallback)" {
    if (!has_unix or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);

    // An abstract address (leading NUL) is delegated to Threaded per call. The
    // forward is proven by the threaded_connect counter regardless of whether
    // the platform supports abstract sockets; the handle is never Born-owned.
    const abstract: Io.net.UnixAddress = .{ .path = "\x00born-abstract-test" };
    const before = born_io.networkStats(io).threaded_connect;
    const result = io.vtable.netConnectUnix(io.userdata, &abstract);
    if (born_io.network_stats_enabled) {
        try expectEqual(before + 1, born_io.networkStats(io).threaded_connect);
    }
    if (result) |handle| {
        // A successful abstract connect is Threaded-owned; close routes through
        // the provenance gate (forwarded to Threaded).
        const sock: Io.net.Socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } };
        sock.close(io);
    } else |_| {
        // Platforms without abstract sockets (e.g. FreeBSD) refuse; the forward
        // still happened, which is the contract under test.
    }
}

test "Unix over-long pathname maps NameTooLong to FileNotFound" {
    if (!has_unix or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    // 108 bytes passes std's max_len (108) but exceeds Born's sun_path on
    // every POSIX platform (104 on BSD/macOS, 108 on Linux, counting the NUL),
    // so Born refuses NameTooLong; the coarse map degrades it to FileNotFound.
    var long_buf: [108]u8 = undefined;
    @memset(&long_buf, 'a');
    const ua: Io.net.UnixAddress = .{ .path = &long_buf };
    try expectError(error.FileNotFound, io.vtable.netConnectUnix(io.userdata, &ua));
}

test "Unix connect to a missing pathname surfaces the coarse ConnectFailed row" {
    if (!has_unix or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    // A path that fits sun_path but names no socket: the kernel answers ENOENT,
    // which Born folds into ConnectFailed (no errno until the post-0.3.0
    // lastErrno() accessor). The coarse map surfaces the ConnectFailed row:
    // Unexpected on 0.16, ConnectionRefused on 0.17. Threaded itself maps
    // ENOENT to FileNotFound; that distinction is the documented loss of the
    // coarse map (design section 8), not a silent fallback.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/m", .{tmp.sub_path});
    const ua: Io.net.UnixAddress = .{ .path = path };
    const st_before = born_io.networkStats(io).connect;
    const result = io.vtable.netConnectUnix(io.userdata, &ua);
    if (is_017) {
        try expectError(error.ConnectionRefused, result);
    } else {
        try expectError(error.Unexpected, result);
    }
    if (born_io.network_stats_enabled) {
        // A failed connect is not a Born connect completion.
        try expectEqual(st_before, born_io.networkStats(io).connect);
    }
}

test "stream write flattens header, vectored data and splat; read drains vectored" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // header "AB" + data ["CDE","FG"] + pattern "x" splat 3 => "ABCDEFGxxx" (10).
    const data = [_][]const u8{ "CDE", "FG", "x" };
    try expectEqual(@as(usize, 10), try rawWrite(io, client.socket.handle, "AB", &data, 3));

    // Peer drains the flattened stream (looping partial reads).
    var pbuf: [10]u8 = undefined;
    var piov = [_][]u8{pbuf[0..]};
    try expectEqual(@as(usize, 10), try readFull(fixture.io(), peer.socket.handle, &piov));
    try expectEqualSlices(u8, "ABCDEFGxxx", &pbuf);

    // Peer echoes it back; the Born client reads into two iovecs (4 + 6),
    // exercising the vectored read cursor across a partial arrival.
    var echo = [_][]const u8{pbuf[0..]};
    try expectEqual(@as(usize, 10), try rawWrite(fixture.io(), peer.socket.handle, &.{}, &echo, 1));
    var buf: [10]u8 = undefined;
    var iov = [_][]u8{ buf[0..4], buf[4..10] };
    try expectEqual(@as(usize, 10), try readFull(io, client.socket.handle, &iov));
    try expectEqualSlices(u8, "ABCDEFGxxx", &buf);
}

test "read returns a partial count and EOF is zero bytes" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer client.close(io);
    defer server.deinit(fixture.io());

    // Peer sends 4 bytes then closes its write side: the client reads the 4
    // bytes (partial relative to a larger iovec), then EOF (0).
    var msg = [_][]const u8{"four"};
    try expectEqual(@as(usize, 4), try rawWrite(fixture.io(), peer.socket.handle, &.{}, &msg, 1));
    try peer.shutdown(fixture.io(), .send);

    var buf: [16]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectEqual(@as(usize, 4), try rawRead(io, client.socket.handle, &iov));
    try expectEqualSlices(u8, "four", buf[0..4]);
    try expectEqual(@as(usize, 0), try rawRead(io, client.socket.handle, &iov));
    peer.close(fixture.io());
}

test "try-before-park: two small reads drain one larger peer write" {
    // Review-168 contract: the first small read fills its iovec and completes
    // with bytes still queued; the second read's try-first readNb drains the
    // remainder without a fresh readiness event. A mutation that arms-and-parks
    // without the try-first attempt strands the second read (born#103 shape).
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // One larger peer write (16 bytes), no further data arrives after it.
    var msg = [_][]const u8{"0123456789abcdef"};
    try expectEqual(@as(usize, 16), try rawWrite(fixture.io(), peer.socket.handle, &.{}, &msg, 1));

    // Two consecutive small reads (8 bytes each) must both complete.
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    var iov_a = [_][]u8{a[0..]};
    var iov_b = [_][]u8{b[0..]};
    try expectEqual(@as(usize, 8), try rawRead(io, client.socket.handle, &iov_a));
    try expectEqual(@as(usize, 8), try rawRead(io, client.socket.handle, &iov_b));
    try expectEqualSlices(u8, "01234567", &a);
    try expectEqualSlices(u8, "89abcdef", &b);
}

test "shutdown(.recv) completes a pending Born read with EOF (Blocker 1)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // A Born read parks (no data yet). POSIX shutdown(2) wakes it with EOF;
    // Windows shutdown() does not complete the pending WSARecv, so the shim
    // cancels it and the loop maps the abort to EOF. Either way the parked
    // read must complete with EOF (0 bytes), not hang or reset.
    var outcome: std.atomic.Value(u32) = .init(0); // 0 pending, 1 eof, 2 error
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ioc: Io, h: Io.net.Socket.Handle, out: *std.atomic.Value(u32)) void {
            var buf: [8]u8 = undefined;
            var iov = [_][]u8{buf[0..]};
            const n = rawRead(ioc, h, &iov) catch {
                out.store(2, .release);
                return;
            };
            out.store(if (n == 0) 1 else 2, .release);
        }
    }.run, .{ io, client.socket.handle, &outcome });
    // Let the reader submit and park.
    try Io.sleep(fixture.io(), .fromMilliseconds(50), .awake);
    try client.shutdown(io, .recv);
    thread.join();
    try expectEqual(@as(u32, 1), outcome.load(.acquire));
}

test "shutdown(.send) gives the peer EOF" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    try client.shutdown(io, .send);
    var buf: [8]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectEqual(@as(usize, 0), try rawRead(fixture.io(), peer.socket.handle, &iov));
}

test "shutdown(.send) completes a pending Born write with an error (Windows)" {
    // Windows shutdown(SD_SEND) does not complete a pending overlapped WSASend;
    // the shim cancels it and the abort retires through the coarse write error
    // (ConnectionResetByPeer). POSIX plain shutdown(2) is the Threaded baseline
    // and is covered by the peer-EOF test above.
    if (!is_windows or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // The peer never reads, so a write larger than the loopback send buffers
    // parks on a pending WSASend.
    const big = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    var outcome: std.atomic.Value(u32) = .init(0); // 0 pending, 1 error, 2 full write
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ioc: Io, h: Io.net.Socket.Handle, data: []const u8, out: *std.atomic.Value(u32)) void {
            var iov = [_][]const u8{data};
            const n = rawWrite(ioc, h, &.{}, &iov, 1) catch {
                out.store(1, .release);
                return;
            };
            out.store(if (n == data.len) 2 else 1, .release);
        }
    }.run, .{ io, client.socket.handle, big, &outcome });
    // Let the writer submit and park.
    try Io.sleep(fixture.io(), .fromMilliseconds(50), .awake);
    try client.shutdown(io, .send);
    thread.join();
    try expectEqual(@as(u32, 1), outcome.load(.acquire));
}

test "shutdown(.recv) drains buffered bytes then EOF (Windows)" {
    // Bytes already absorbed into the shim's recv buffer before the shutdown
    // still drain; the next read completes with EOF. Windows-only: POSIX
    // shutdown(SHUT_RD) kernel-buffer semantics differ per OS.
    if (!is_windows or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    var msg = [_][]const u8{"0123456789abcdef"};
    try expectEqual(@as(usize, 16), try rawWrite(fixture.io(), peer.socket.handle, &.{}, &msg, 1));
    // Reading only 8 of the 16 bytes leaves the rest in the shim's recv
    // buffer (the completion absorbed all 16 before the partial retire).
    var a: [8]u8 = undefined;
    var iov_a = [_][]u8{a[0..]};
    try expectEqual(@as(usize, 8), try rawRead(io, client.socket.handle, &iov_a));
    try client.shutdown(io, .recv);
    var b: [8]u8 = undefined;
    var iov_b = [_][]u8{b[0..]};
    try expectEqual(@as(usize, 8), try rawRead(io, client.socket.handle, &iov_b));
    try expectEqualSlices(u8, "01234567", &a);
    try expectEqualSlices(u8, "89abcdef", &b);
    var c: [8]u8 = undefined;
    var iov_c = [_][]u8{c[0..]};
    try expectEqual(@as(usize, 0), try rawRead(io, client.socket.handle, &iov_c));
}

test "close cancels a pending Born read" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer server.deinit(fixture.io());

    // Park a Born read, then close the socket from another thread: the pending
    // read retires as Canceled and close itself completes (infallible).
    var outcome: std.atomic.Value(u32) = .init(0); // 0 pending, 1 canceled, 2 other
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ioc: Io, h: Io.net.Socket.Handle, out: *std.atomic.Value(u32)) void {
            var buf: [8]u8 = undefined;
            var iov = [_][]u8{buf[0..]};
            _ = rawRead(ioc, h, &iov) catch |err| {
                out.store(if (err == error.Canceled) 1 else 2, .release);
                return;
            };
            out.store(2, .release);
        }
    }.run, .{ io, client.socket.handle, &outcome });
    try Io.sleep(fixture.io(), .fromMilliseconds(50), .awake);
    client.close(io);
    thread.join();
    try expectEqual(@as(u32, 1), outcome.load(.acquire));
}

test "peer reset maps read and write failures to ConnectionResetByPeer" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer client.close(io);
    defer server.deinit(fixture.io());

    // Client sends data the peer never reads, then the peer closes with
    // SO_LINGER {1,0} so the kernel sends RST. The client's next read and write
    // both fail; the coarse map collapses every native read/write failure to
    // ConnectionResetByPeer.
    var msg = [_][]const u8{"unread"};
    try expectEqual(@as(usize, 6), try rawWrite(io, client.socket.handle, &.{}, &msg, 1));
    forceResetOnClose(peer.socket.handle);
    peer.close(fixture.io());

    var buf: [8]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectError(error.ConnectionResetByPeer, rawRead(io, client.socket.handle, &iov));
    try expectError(error.ConnectionResetByPeer, rawWrite(io, client.socket.handle, &.{}, &msg, 1));
}

test "message I/O on a Born-owned handle is excluded with tag Unexpected" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    const before = born_io.networkStats(io);
    if (is_017) {
        const send_res = try io.operate(.{ .net_send = .{ .socket_handle = client.socket.handle, .messages = &.{}, .flags = .{} } });
        try expectEqual(@as(?Io.net.Socket.SendError, error.Unexpected), send_res.net_send[0]);
        try expectEqual(@as(usize, 0), send_res.net_send[1]);
        const recv_res = try io.operate(.{ .net_receive = .{ .socket_handle = client.socket.handle, .message_buffer = &.{}, .data_buffer = &.{}, .flags = .{} } });
        try expectEqual(@as(?Io.net.Socket.ReceiveError, error.Unexpected), recv_res.net_receive[0]);
        // A control buffer on a stream read is excluded too.
        var buf: [4]u8 = undefined;
        var iov = [_][]u8{buf[0..]};
        var ctrl: [16]u8 = undefined;
        const ctrl_res = try io.operate(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &iov, .control = &ctrl } });
        try expectError(error.Unexpected, ctrl_res.net_read);
    } else {
        const send_res = io.vtable.netSend(io.userdata, client.socket.handle, &.{}, .{});
        try expectEqual(@as(?Io.net.Socket.SendError, error.Unexpected), send_res[0]);
        try expectEqual(@as(usize, 0), send_res[1]);
        const recv_res = try io.operate(.{ .net_receive = .{ .socket_handle = client.socket.handle, .message_buffer = &.{}, .data_buffer = &.{}, .flags = .{} } });
        try expectEqual(@as(?Io.net.Socket.ReceiveError, error.Unexpected), recv_res.net_receive[0]);
    }
    // Exclusions never forward to Threaded and never count as Born completions.
    if (born_io.network_stats_enabled) {
        const after = born_io.networkStats(io);
        try expectEqual(before.threaded_read, after.threaded_read);
        try expectEqual(before.threaded_write, after.threaded_write);
        try expectEqual(before.read, after.read);
        try expectEqual(before.write, after.write);
    }
}

test "bind-only and socketpair are declared rejections" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    try expectError(error.OptionUnsupported, io.vtable.netBindIp(io.userdata, &addr, .{ .mode = .stream }));
    try expectError(error.OperationUnsupported, io.vtable.netSocketCreatePair(io.userdata, .{}));
}

test "netWriteFile: 0.17 declares Unimplemented, 0.16 copies internally" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fio = fixture.io();
    const file = try tmp.dir.createFile(fio, "payload", .{ .read = true });
    defer file.close(fio);
    try file.writeStreamingAll(fio, "file-payload");
    // The File.Reader reads positionally from offset 0; no seek needed.
    var frbuf: [64]u8 = undefined;
    var fr = file.reader(fio, &frbuf);

    if (is_017) {
        // No Born sendfile primitive: declared Unimplemented before touching the
        // socket. Io.Writer.sendFile catches it and re-enters the routed copy.
        try expectError(error.Unimplemented, io.vtable.netWriteFile(io.userdata, client.socket.handle, "H", &fr, .unlimited));
    } else {
        // 0.16 WriteFileError has no Unimplemented and Threaded 0.16 panics, so
        // the shim performs an internal read/copy through the routed write path.
        const n = try io.vtable.netWriteFile(io.userdata, client.socket.handle, "H", &fr, .unlimited);
        try expectEqual(@as(usize, 13), n); // "H" + "file-payload"
        var buf: [13]u8 = undefined;
        var iov = [_][]u8{buf[0..]};
        try expectEqual(@as(usize, 13), try readFull(fixture.io(), peer.socket.handle, &iov));
        try expectEqualSlices(u8, "Hfile-payload", &buf);
    }
}

test "batch over a Born-owned member completes Unexpected and awaits normally" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // The client writes data the peer can read, so a Threaded-owned batch
    // member (the peer handle) has a real completion to forward.
    var msg = [_][]const u8{"batch"};
    try expectEqual(@as(usize, 5), try rawWrite(io, client.socket.handle, &.{}, &msg, 1));

    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    if (is_017) {
        var cbuf: [5]u8 = undefined;
        var ciov = [_][]u8{cbuf[0..]};
        var pbuf: [5]u8 = undefined;
        var piov = [_][]u8{pbuf[0..]};
        // Born-owned member (no incoming data: would park, but is excluded).
        _ = batch.add(.{ .net_read = .{ .socket_handle = client.socket.handle, .data = &ciov } });
        // Threaded-owned member (the peer handle has the client's 5 bytes).
        _ = batch.add(.{ .net_read = .{ .socket_handle = peer.socket.handle, .data = &piov } });
        try io.vtable.batchAwaitAsync(io.userdata, &batch);
        try expect(batch.submitted.head == .none);
        // Both members completed: the Born one with tag Unexpected, the peer
        // one with a real read. Walk the completed list.
        var saw_born_unexpected = false;
        var saw_peer_read = false;
        var idx = batch.completed.head;
        while (idx != .none) {
            const st = &batch.storage[idx.toIndex()];
            switch (st.completion.result) {
                .net_read => |r| {
                    if (r) |rr| {
                        if (rr.data_len == 5) saw_peer_read = true;
                    } else |err| {
                        if (err == error.Unexpected) saw_born_unexpected = true;
                    }
                },
                else => {},
            }
            idx = st.completion.node.next;
        }
        try expect(saw_born_unexpected);
        try expect(saw_peer_read);
        try expectEqualSlices(u8, "batch", &pbuf);
    } else {
        // 0.16 batches carry only net_receive (message I/O, already excluded).
        _ = batch.add(.{ .net_receive = .{ .socket_handle = client.socket.handle, .message_buffer = &.{}, .data_buffer = &.{}, .flags = .{} } });
        try io.vtable.batchAwaitAsync(io.userdata, &batch);
        try expect(batch.submitted.head == .none);
        const st = &batch.storage[batch.completed.head.toIndex()];
        try expectEqual(@as(?Io.net.Socket.ReceiveError, error.Unexpected), st.completion.result.net_receive[0]);
    }
}

test "provenance gate: Threaded-owned handles forward, Born-owned never do" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // The accepted peer handle is Threaded-owned (not in Born's registry). A
    // read/write on it through the shim forwards to Threaded and increments the
    // threaded_* counters; the Born client handle never forwards.
    var msg = [_][]const u8{"gate"};
    try expectEqual(@as(usize, 4), try rawWrite(io, client.socket.handle, &.{}, &msg, 1));
    var buf: [4]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectEqual(@as(usize, 4), try rawRead(io, peer.socket.handle, &iov));

    if (born_io.network_stats_enabled) {
        const st = born_io.networkStats(io);
        try expect(st.write > 0); // Born client write
        try expect(st.threaded_read > 0); // peer read forwarded
        try expectEqual(@as(u64, 0), st.threaded_write); // client write never forwarded
        try expectEqual(@as(u64, 0), st.threaded_connect); // client connect never forwarded
    }
}

test "resolve composes Threaded resolution with a Born connect" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(fio, .{});
    defer server.deinit(fio);
    const bound_port = server.socket.address.ip4.port;

    // Resolution stays Threaded (netLookup delegation is pinned in the vtable
    // test); a literal address resolves without a resolver dependency, and the
    // resolved address then connects on Born.
    const resolved = try Io.net.IpAddress.resolve(io, "127.0.0.1", bound_port);
    var client = try resolved.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var peer = try server.accept(fio);
    defer peer.close(fio);
    if (born_io.network_stats_enabled) {
        try expect(born_io.networkStats(io).connect > 0);
    }
}

test "close and reconnect repeatedly never corrupts the registry (stale-fd guard)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(fio, .{});
    defer server.deinit(fio);
    const bound = server.socket.address;

    // Rapid close/reconnect reuses fd numbers and registry slots; the generation
    // guard must drop stale events for a closed-and-reused fd. Each iteration
    // exchanges a byte and closes both ends.
    for (0..40) |_| {
        var client = try bound.connect(io, .{ .mode = .stream });
        var peer = try server.accept(fio);
        var msg = [_][]const u8{"x"};
        try expectEqual(@as(usize, 1), try rawWrite(io, client.socket.handle, &.{}, &msg, 1));
        var buf: [1]u8 = undefined;
        var iov = [_][]u8{buf[0..]};
        try expectEqual(@as(usize, 1), try rawRead(fio, peer.socket.handle, &iov));
        peer.close(fio);
        client.close(io);
    }
    try expect(born_io.loopError(io) == null);
}

test "network route keeps listen, accept and DNS on Threaded" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);

    // Listen/accept on the shim interface itself still forward to Threaded and
    // produce a working Threaded-owned server (the hybrid path).
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const bound = server.socket.address;
    var client = try bound.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var peer = try server.accept(io);
    defer peer.close(io);
    var msg = [_][]const u8{"hybrid"};
    try expectEqual(@as(usize, 6), try rawWrite(io, client.socket.handle, &.{}, &msg, 1));
    var buf: [6]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectEqual(@as(usize, 6), try rawRead(io, peer.socket.handle, &iov));
    try expectEqualSlices(u8, "hybrid", &buf);
}

/// Counts every allocation routed through it, forwarding to the child.
const Counting = struct {
    child: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "steady-state Born read and write perform no shim allocations" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var counting: Counting = .{ .child = std.testing.allocator };
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try born_io.io(&port, .{
        .allocator = counting.allocator(),
        .capabilities = .{ .network = .born_evented },
    });
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fixture.io());
    defer client.close(io);
    defer server.deinit(fixture.io());

    // After connect (which may grow the registry map), the read/write hot path
    // is an intrusive push of caller-owned storage: no shim allocation.
    const baseline_count = counting.count.load(.monotonic);
    var msg = [_][]const u8{"noalloc"};
    var buf: [7]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    for (0..3) |_| {
        try expectEqual(@as(usize, 7), try rawWrite(io, client.socket.handle, &.{}, &msg, 1));
        try expectEqual(@as(usize, 7), try rawRead(fixture.io(), peer.socket.handle, &iov));
    }
    try expectEqual(baseline_count, counting.count.load(.monotonic));
}

test "loop death retires network ops as Unexpected, not Canceled" {
    // Required 3: a persistently broken port kills the loop; a driven connect
    // is retired as route_dead (Unexpected), and a later connect's submit
    // refusal also surfaces Unexpected, never the caller's Canceled. kqueue
    // and epoll: the port descriptor is closed BEFORE the loop starts, so its
    // first waits fail deterministically (closing a descriptor behind an
    // already-blocked kqueue wait would not wake it, since the wait holds a
    // reference). No event is ever delivered, so the connect cannot complete;
    // the failure exit retires it route_dead. Parked-read retirement on a
    // failure exit is asserted by the shim unit (netRetireAll stopped=false).
    if (builtin.single_threaded) return error.SkipZigTest;
    const has_kq = @hasField(born.EvPort, "kq");
    const has_ep = @hasField(born.EvPort, "ep");
    if (!has_kq and !has_ep) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    if (has_kq) {
        _ = std.c.close(port.kq);
        port.kq = -1;
    } else {
        _ = std.c.close(port.ep);
        port.ep = -1;
    }
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(fio, .{});
    defer server.deinit(fio);

    // The connect is driven then retired at the failure exit (or refused at
    // the dead queue); both map route_dead to Unexpected.
    try expectError(error.Unexpected, server.socket.address.connect(io, .{ .mode = .stream }));
    try expect(born_io.loopError(io) != null);
    // The queue is dead: a second connect's submit is refused, also Unexpected.
    try expectError(error.Unexpected, server.socket.address.connect(io, .{ .mode = .stream }));
}

test "handle reuse after close routes a Threaded socket away from Born (POSIX)" {
    // Required 1: after a Born socket closes, its fd number can be reused by a
    // Threaded socket in the same process. The provenance gate must forward that
    // handle to Threaded, not route it to the dying Born slot. dup2 a fixture
    // socket onto the closed Born fd number and read through the shim. (The
    // unregister-before-close ordering itself is asserted by the Windows drain
    // unit, where the drain window makes it observable.)
    if (is_windows or builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fio);
    defer server.deinit(fio);

    const born_fd = client.socket.handle;
    const before = born_io.networkStats(io);
    client.close(io); // closes born_fd and unregisters it

    // Reuse the fd number for a Threaded socket: a fresh Threaded connection
    // whose client end is forced onto the closed Born fd number via dup2.
    const c2 = try server.socket.address.connect(fio, .{ .mode = .stream });
    var p2 = try server.accept(fio);
    defer p2.close(fio);
    const c2fd = c2.socket.handle;
    if (c2fd != born_fd) {
        try compat.dup2(c2fd, born_fd);
        compat.close(c2fd); // born_fd now holds this Threaded end
    }
    defer compat.close(born_fd);
    _ = try compat.write(p2.socket.handle, "Z");

    // A read through the shim at the reused fd must go to Threaded and succeed.
    var buf: [1]u8 = undefined;
    var iov = [_][]u8{buf[0..]};
    try expectEqual(@as(usize, 1), try rawRead(io, born_fd, &iov));
    try expectEqualSlices(u8, "Z", &buf);
    if (born_io.network_stats_enabled) {
        const after = born_io.networkStats(io);
        try expect(after.threaded_read > before.threaded_read);
        try expectEqual(before.read, after.read); // no Born read completion
    }
}

test "deinit with two parked Born reads retires them and drains promptly" {
    // Required 2 (the Windows multi-socket deinit drain): two Born sockets with
    // parked reads open at deinit. deinit stops the loop, retires the reads as
    // canceled, and drains every completion before freeing the socket state.
    // On Windows the old polled drain could swallow a sibling's completion; the
    // two-phase exit drain frees both promptly. All platforms: deinit returns
    // promptly and both readers observe cancellation.
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(fio, .{});
    defer server.deinit(fio);
    const bound = server.socket.address;
    var clients: [2]Io.net.Stream = undefined;
    var peers: [2]Io.net.Stream = undefined;
    for (&clients, &peers) |*c, *p| {
        c.* = try bound.connect(io, .{ .mode = .stream });
        p.* = try server.accept(fio);
    }
    defer peers[0].close(fio);
    defer peers[1].close(fio);

    var results: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) }; // 0 pending, 1 canceled, 2 other
    var threads: [2]std.Thread = undefined;
    for (&clients, &results, &threads) |*c, *r, *t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(ioc: Io, h: Io.net.Socket.Handle, out: *std.atomic.Value(u32)) void {
                var buf: [1]u8 = undefined;
                var iov = [_][]u8{buf[0..]};
                _ = rawRead(ioc, h, &iov) catch |err| {
                    out.store(if (err == error.Canceled) 1 else 2, .release);
                    return;
                };
                out.store(2, .release);
            }
        }.run, .{ io, c.socket.handle, r });
    }
    try Io.sleep(fio, .fromMilliseconds(50), .awake); // let both reads park

    const t0 = try born.nowNs();
    born_io.deinit(io);
    const elapsed = (try born.nowNs()) - t0;
    try expect(elapsed < 2 * std.time.ns_per_s);
    for (&threads, &results) |*t, *r| {
        t.join();
        try expectEqual(@as(u32, 1), r.load(.acquire)); // canceled (stop path)
    }
}

test "connect timeouts on non-awake clocks stay on the Born route" {
    // Should-fix 5: a .real/.boot timeout is converted to a Born deadline, not
    // forwarded to Threaded. A past deadline expires without connecting; a
    // refused connect with a future .real deadline and a successful connect with
    // a .boot duration both run on Born (the Threaded-forward counter stays zero).
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    const target: Io.net.IpAddress = .{ .ip4 = .loopback(0) };

    // A past .real deadline (the Unix epoch) expires before any socket is made.
    try expectError(error.Timeout, target.connect(io, .{
        .mode = .stream,
        .timeout = .{ .deadline = .{ .clock = .real, .raw = .{ .nanoseconds = 1 } } },
    }));
    // A zero .boot duration is already expired.
    try expectError(error.Timeout, target.connect(io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .{ .nanoseconds = 0 } } },
    }));

    // A refused connect with a future .real deadline runs on Born (refused
    // before the deadline), never forwarded to Threaded.
    const closed_port = blk: {
        var s = try target.listen(fio, .{});
        const p = s.socket.address.ip4.port;
        s.deinit(fio);
        break :blk p;
    };
    const refused: Io.net.IpAddress = .{ .ip4 = .loopback(closed_port) };
    const real_now = fio.vtable.now(fio.userdata, .real);
    try expectError(error.ConnectionRefused, refused.connect(io, .{
        .mode = .stream,
        .timeout = .{ .deadline = .{ .clock = .real, .raw = .{ .nanoseconds = real_now.nanoseconds + 5 * std.time.ns_per_s } } },
    }));

    // A successful connect with a generous .boot duration stays on Born.
    var server = try target.listen(fio, .{});
    defer server.deinit(fio);
    var client = try server.socket.address.connect(io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .clock = .boot, .raw = .{ .nanoseconds = 5 * std.time.ns_per_s } } },
    });
    defer client.close(io);
    var peer = try server.accept(fio);
    defer peer.close(fio);
    if (born_io.network_stats_enabled) {
        const st = born_io.networkStats(io);
        try expect(st.connect > 0);
        try expectEqual(@as(u64, 0), st.threaded_connect);
    }
}

test "a concurrent read on a parked Born read returns Unexpected" {
    // Minor 8 end-to-end: a second read while one is parked is rejected
    // (Unexpected), not orphaned; the parked read still completes when data
    // arrives.
    if (builtin.single_threaded) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    const io = try initNetIo(&port);
    defer born_io.deinit(io);
    var fixture: Io.Threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer fixture.deinit();
    const fio = fixture.io();
    var server: Io.net.Server = undefined;
    var client: Io.net.Stream = undefined;
    var peer: Io.net.Stream = undefined;
    try setupPair(io, &fixture, &server, &client, &peer);
    defer peer.close(fio);
    defer client.close(io);
    defer server.deinit(fio);

    var result: std.atomic.Value(u32) = .init(0); // 0 pending, 1 got byte, 2 error
    var got: [1]u8 = undefined;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ioc: Io, h: Io.net.Socket.Handle, buf: []u8, out: *std.atomic.Value(u32)) void {
            var iov = [_][]u8{buf};
            const n = rawRead(ioc, h, &iov) catch {
                out.store(2, .release);
                return;
            };
            out.store(if (n == 1) 1 else 2, .release);
        }
    }.run, .{ io, client.socket.handle, got[0..], &result });
    try Io.sleep(fio, .fromMilliseconds(50), .awake); // let the first read park

    // A second concurrent read is rejected with Unexpected.
    var buf2: [1]u8 = undefined;
    var iov2 = [_][]u8{buf2[0..]};
    try expectError(error.Unexpected, rawRead(io, client.socket.handle, &iov2));

    // The parked read still completes when the peer sends a byte.
    var msg = [_][]const u8{"Z"};
    try expectEqual(@as(usize, 1), try rawWrite(fio, peer.socket.handle, &.{}, &msg, 1));
    thread.join();
    try expectEqual(@as(u32, 1), result.load(.acquire));
    try expectEqualSlices(u8, "Z", &got);
}
