// Born-owned std.http.Client contract suite (design 7.3, adjudicated Q2).
// std.http.Client has no upstream test suite on 0.16.0/0.17.1, so this is a
// born-owned contract suite, not an upstream port. Cross-Io proof: the
// CLIENT runs on born.io (Client.io = std.testing.io, assigned per test by
// the runner); the FIXTURE server runs on a dedicated plain Io.Threaded
// instance on its own OS thread, wrapping accepted socket streams into the
// sans-I/O std.http.Server. Client and server on different Io
// implementations proves the shim interoperates with upstream's own
// Threaded stack, not just with itself. The same suite runs with the client
// on all-Threaded (-Dborn-network=false) as the control leg; results must be
// identical. TLS is compiled out via the runner's std_options
// .http_disable_tls = true, consistent with nats use_tls = false.
//
// Contracts: GET round-trip (status/headers/body); POST body echo; chunked
// transfer-encoding both directions; keep-alive reuse (fixture accept
// count); large body streaming both directions (multi-buffer); connection
// refusal maps to the declared connect error, never a hang (bound
// non-listening port; Windows refusal completions can exceed two seconds,
// so no timeout is set); peer close mid-request surfaces a declared
// peer-close error, never Unexpected, and the Born route stays alive (a
// follow-up request on the same client succeeds); fixture teardown is
// deterministic and prompt even when a test fails early and never sends the
// follow-up (interruptible accept, no join timeout, #126).

const std = @import("std");
const born_io = @import("born_io");
const born = @import("born");

const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const post_body = "contract post body 0123456789";
const get_body = "hello from fixture";
const large_len = 1 << 20;

// ---------------------------------------------------------------------------
// Fixture: plain Threaded io on a dedicated OS thread. Never touches
// std.testing.io or std.testing.allocator (the per-test born io and leak
// checker belong to the client side).
// ---------------------------------------------------------------------------

const Behavior = enum {
    get,
    post_echo,
    chunked_echo,
    large_response,
    large_request,
    keep_alive,
    peer_close_then_get,
};

const Fixture = struct {
    behavior: Behavior,
    port: std.atomic.Value(u16) = .init(0),
    accepts: std.atomic.Value(u32) = .init(0),
    events: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(f: *Fixture, behavior: Behavior) !void {
        f.* = .{ .behavior = behavior };
        f.thread = try std.Thread.spawn(.{}, fixtureMain, .{f});
    }

    /// Bounded wait for the fixture's ephemeral port (bound on port 0).
    fn waitReady(f: *Fixture, io: Io) !u16 {
        var tries: usize = 0;
        while (f.port.load(.monotonic) == 0) : (tries += 1) {
            if (f.failed.load(.monotonic)) return error.FixtureFailed;
            if (tries >= 5000) return error.FixtureNotReady;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return f.port.load(.monotonic);
    }

    fn join(f: *Fixture) void {
        if (f.thread) |t| t.join();
        f.thread = null;
    }

    /// One wake connection: connect to the fixture's loopback port and close
    /// immediately. A blocked accept returns a stream whose receiveHead sees
    /// EOF (HttpConnectionClosing), so the fixture exits on its own. A refused
    /// connect (listener already closed) is ignored.
    fn wakeOnce(address: Io.net.IpAddress, io: Io) void {
        if (address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        } else |_| {}
    }

    /// Number of accepts the behavior performs before it exits on EOF.
    fn totalAccepts(behavior: Behavior) u32 {
        return if (behavior == .peer_close_then_get) 2 else 1;
    }

    /// Record an event the teardown waiter cares about (an accept or the
    /// fixture's exit) in the events futex word and wake any waiter. Every such
    /// event MUST advance this word: waitReact compares-and-sleeps on it, so an
    /// event that only set a separate flag (exited) without changing this word
    /// would be a lost wakeup and hang teardown. The release publish pairs with
    /// the waiter's acquire snapshot, so accepts is visible to the post-wait
    /// check.
    fn noteEvent(f: *Fixture, io: Io) void {
        _ = f.events.fetchAdd(1, .release);
        std.Io.futexWake(io, u32, &f.events.raw, 1);
    }

    /// Block until the fixture reacts to a wake: any accept or exit advances
    /// the events word past the snapshot. Futex wait on events (noteEvent bumps
    /// and wakes it on every accept and on exit), so the compare-and-sleep sees
    /// the exit too; no sleep loop, no lost wakeup. accepts stays the count the
    /// tests assert on.
    fn waitReact(f: *Fixture, io: Io, snapshot: u32) void {
        while (f.events.load(.acquire) == snapshot) {
            std.Io.futexWait(io, u32, &f.events.raw, snapshot) catch return;
        }
    }

    /// Wake any accept the fixture is blocked in, then join. The wake is a
    /// loopback self-connect (closed immediately) on a dedicated plain Threaded
    /// instance, independent of the client route under test: accept returns a
    /// stream whose receiveHead sees EOF and the fixture exits on its own. No
    /// join timeout, no leaked thread. Listener close cannot wake: FreeBSD
    /// close() does not interrupt a blocked accept; Windows CloseHandle panics
    /// std's netAcceptWindows (.CANCELLED => unreachable). shutdown() does not
    /// wake on Windows (STATUS_INVALID_PARAMETER).
    ///
    /// Invariant: the events snapshot is taken before the exited check. An exit
    /// before the snapshot is visible through the release/acquire pair, so
    /// teardown joins directly with no connect; an exit after it advances events
    /// past the snapshot, so waitReact returns. Either way teardown cannot hang.
    /// A second wake is issued only if the fixture accepted again but has not
    /// reached its final accept; after its last accept it exits on EOF itself,
    /// so the regression path never pays a slow refused connect.
    fn teardown(f: *Fixture) void {
        const snapshot = f.events.load(.acquire);
        const port = f.port.load(.monotonic);
        if (port != 0 and !f.exited.load(.acquire)) {
            var threaded = Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
            wakeOnce(address, io);
            waitReact(f, io, snapshot);
            if (!f.exited.load(.acquire) and f.accepts.load(.acquire) < totalAccepts(f.behavior)) {
                wakeOnce(address, io);
            }
        }
        f.join();
    }
};

fn fixtureMain(f: *Fixture) void {
    var threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    fixtureMainInner(f, threaded.io()) catch |err| {
        std.log.err("http fixture ({s}) failed: {s}", .{ @tagName(f.behavior), @errorName(err) });
        f.failed.store(true, .monotonic);
    };
    // fixtureMainInner's defer closed the listener before it returned, so the
    // port is dead once this flag is set; teardown then skips the wake connect.
    f.exited.store(true, .release);
    f.noteEvent(threaded.io());
}

fn fixtureMainInner(f: *Fixture, io: Io) !void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    f.port.store(listener.socket.address.ip4.port, .monotonic);

    if (f.behavior == .peer_close_then_get) {
        // Accept the first connection, read a few request bytes, then close
        // without responding: a peer close mid-request.
        var first = try listener.accept(io);
        _ = f.accepts.fetchAdd(1, .monotonic);
        f.noteEvent(io);
        var rbuf: [64]u8 = undefined;
        var r = first.reader(io, &rbuf);
        // readSliceShort fills the destination or reads to end of stream.
        // 16 bytes are guaranteed within the request head, so this returns
        // promptly without waiting for the client to close. The destination
        // must not alias the reader's own buffer.
        var head: [16]u8 = undefined;
        _ = r.interface.readSliceShort(&head) catch {};
        first.close(io);
    }

    var stream = try listener.accept(io);
    _ = f.accepts.fetchAdd(1, .monotonic);
    f.noteEvent(io);
    defer stream.close(io);
    try serveConnection(f, io, &stream, f.behavior == .keep_alive);
}

fn serveConnection(f: *Fixture, io: Io, stream: *Io.net.Stream, loop: bool) !void {
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);
    var server = http.Server.init(&sr.interface, &sw.interface);
    // Bounded request count per connection; the keep-alive test closes the
    // client pool after three requests, which ends the loop via
    // HttpConnectionClosing well before the bound.
    var served: usize = 0;
    while (served < 8) : (served += 1) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        const keep_alive = req.head.keep_alive;
        try handleRequest(f, &req);
        if (!loop or !keep_alive) return;
    }
}

fn handleRequest(f: *Fixture, req: *http.Server.Request) !void {
    const gpa = std.heap.page_allocator;
    switch (f.behavior) {
        .get, .peer_close_then_get, .keep_alive => {
            const body = if (f.behavior == .keep_alive) "ok" else get_body;
            try req.respond(body, .{
                .extra_headers = &.{.{ .name = "x-contract", .value = "born" }},
            });
        },
        .post_echo => {
            var buf: [4096]u8 = undefined;
            const body = try readAll(req.readerExpectNone(&buf), gpa);
            defer gpa.free(body);
            if (!std.mem.eql(u8, body, post_body)) return error.ContractPostBodyMismatch;
            try req.respond(body, .{});
        },
        .chunked_echo => {
            if (req.head.transfer_encoding != .chunked) return error.ContractExpectedChunkedRequest;
            var buf: [4096]u8 = undefined;
            const body = try readAll(req.readerExpectNone(&buf), gpa);
            defer gpa.free(body);
            var bw = try req.respondStreaming(&.{}, .{
                .respond_options = .{ .transfer_encoding = .chunked },
            });
            const mid = body.len / 2;
            try bw.writer.writeAll(body[0..mid]);
            try bw.flush();
            try bw.writer.writeAll(body[mid..]);
            try bw.end();
        },
        .large_response => {
            const payload = try gpa.alloc(u8, large_len);
            defer gpa.free(payload);
            fillPattern(payload);
            var bw = try req.respondStreaming(&.{}, .{ .content_length = large_len });
            var off: usize = 0;
            while (off < payload.len) {
                const n = @min(payload.len - off, 64 * 1024);
                try bw.writer.writeAll(payload[off..][0..n]);
                try bw.flush();
                off += n;
            }
            try bw.end();
        },
        .large_request => {
            var buf: [64 * 1024]u8 = undefined;
            const body = try readAll(req.readerExpectNone(&buf), gpa);
            defer gpa.free(body);
            if (body.len != large_len or !checkPattern(body)) return error.ContractLargeBodyMismatch;
            try req.respond("ok", .{});
        },
    }
}

// ---------------------------------------------------------------------------
// Client-side helpers (born.io via std.testing.io).
// ---------------------------------------------------------------------------

fn readAll(reader: *Io.Reader, allocator: Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try reader.appendRemainingUnlimited(allocator, &list);
    return try list.toOwnedSlice(allocator);
}

fn urlFor(allocator: Allocator, port: u16, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
}

fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
}

fn checkPattern(buf: []const u8) bool {
    for (buf, 0..) |b, i| {
        if (b != @as(u8, @truncate(i *% 31 +% 7))) return false;
    }
    return true;
}

/// The first request must fail with a DECLARED peer-close error: EOF
/// (HttpConnectionClosing / HttpRequestTruncated / EndOfStream) or a reset
/// (ConnectionResetByPeer), never Unexpected and never a hang. The
/// ReadFailed/WriteFailed wrappers are resolved to the underlying stream
/// error and held to the same set, so a Born route death cannot hide behind
/// them (design correction C1). Any other error propagates and fails the
/// test; a successful response fails the contract.
fn expectPeerClose(client: *http.Client, uri: std.Uri) !void {
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    req.sendBodiless() catch |err| return checkPeerCloseError(&req, err);
    var redirect_buf: [1024]u8 = undefined;
    const resp = req.receiveHead(&redirect_buf) catch |err| return checkPeerCloseError(&req, err);
    _ = resp;
    return error.ContractExpectedPeerClose;
}

fn checkPeerCloseError(req: *http.Client.Request, err: anyerror) !void {
    switch (err) {
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.ConnectionResetByPeer,
        error.EndOfStream,
        => {},
        error.ReadFailed => {
            const conn = req.connection orelse return err;
            try checkDeclaredPeerClose(conn.getReadError() orelse return err);
        },
        error.WriteFailed => {
            const conn = req.connection orelse return err;
            try checkDeclaredPeerClose(conn.stream_writer.err orelse return err);
        },
        else => return err,
    }
}

fn checkDeclaredPeerClose(err: anyerror) !void {
    switch (err) {
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.ConnectionResetByPeer,
        error.EndOfStream,
        => {},
        else => return err,
    }
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

test "GET round-trip: status, headers, body" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.get);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/hello");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(url), .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    try testing.expectEqual(@as(?u64, get_body.len), resp.head.content_length);
    // head.bytes is invalidated by reader(); check headers first.
    try testing.expect(std.mem.indexOf(u8, resp.head.bytes, "x-contract: born\r\n") != null);
    var transfer_buf: [4096]u8 = undefined;
    const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(get_body, body);
    try testing.expect(!f.failed.load(.monotonic));
}

test "POST request body is received and echoed" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.post_echo);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/echo");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.POST, try std.Uri.parse(url), .{});
    defer req.deinit();
    var body_copy: [post_body.len]u8 = post_body.*;
    try req.sendBodyComplete(&body_copy);
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    var transfer_buf: [4096]u8 = undefined;
    const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(post_body, body);
    try testing.expect(!f.failed.load(.monotonic));
}

test "chunked transfer-encoding both directions" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.chunked_echo);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/chunked");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.POST, try std.Uri.parse(url), .{});
    defer req.deinit();
    req.transfer_encoding = .chunked;
    var bw_buf: [512]u8 = undefined;
    var bw = try req.sendBody(&bw_buf);
    const part1 = "chunked contract part one;";
    const part2 = "part two completes the body.";
    try bw.writer.writeAll(part1);
    try bw.flush();
    try bw.writer.writeAll(part2);
    try bw.end();

    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    // The fixture echoed via respondStreaming(.chunked): the response must
    // be chunked too (both directions proven).
    try testing.expectEqual(http.TransferEncoding.chunked, resp.head.transfer_encoding);
    var transfer_buf: [4096]u8 = undefined;
    const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(part1 ++ part2, body);
    try testing.expect(!f.failed.load(.monotonic));
}

test "keep-alive connection reuse across requests" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.keep_alive);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/keep");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    // client.deinit closes the pool, which ends the fixture's accept loop;
    // it must run before f.teardown (defer LIFO: teardown registered first).
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var redirect_buf: [1024]u8 = undefined;
    var transfer_buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var resp = try req.receiveHead(&redirect_buf);
        try testing.expectEqual(http.Status.ok, resp.head.status);
        const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
        defer testing.allocator.free(body);
        try testing.expectEqualStrings("ok", body);
    }
    // Three requests, one accepted connection: the pool reused it.
    try testing.expectEqual(@as(u32, 1), f.accepts.load(.monotonic));
    try testing.expect(!f.failed.load(.monotonic));
}

test "large response body streaming (multi-buffer)" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.large_response);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/large");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(url), .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    try testing.expectEqual(@as(?u64, large_len), resp.head.content_length);
    // Transfer buffer smaller than the body forces multiple fills.
    var transfer_buf: [4096]u8 = undefined;
    const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqual(@as(usize, large_len), body.len);
    try testing.expect(checkPattern(body));
    try testing.expect(!f.failed.load(.monotonic));
}

test "large request body streaming" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.large_request);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/upload");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    const payload = try testing.allocator.alloc(u8, large_len);
    defer testing.allocator.free(payload);
    fillPattern(payload);

    var req = try client.request(.POST, try std.Uri.parse(url), .{});
    defer req.deinit();
    try req.sendBodyComplete(payload);
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    var transfer_buf: [4096]u8 = undefined;
    const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("ok", body);
    try testing.expect(!f.failed.load(.monotonic));
}

test "connection refusal maps to the connect error, not a hang" {
    const io = testing.io;
    // Reserve a bound non-listening port on a fixture Threaded instance:
    // bind-only sockets are outside the shim's client profile
    // (OptionUnsupported), so the reservation cannot use std.testing.io.
    var threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const sock = try address.bind(tio, .{ .mode = .stream });
    defer sock.close(tio);
    const port = sock.address.ip4.port;

    const url = try urlFor(testing.allocator, port, "/");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    // No timeout: Windows refusal completions can exceed two seconds; the
    // contract is that the refusal surfaces as the declared connect error
    // rather than hanging.
    const uri = try std.Uri.parse(url);
    if (client.request(.GET, uri, .{})) |req| {
        var r = req;
        r.deinit();
        return error.ContractExpectedRefusal;
    } else |err| {
        try testing.expectEqual(error.ConnectionRefused, err);
    }
}

test "peer close mid-request: declared error, route stays alive" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.peer_close_then_get);
    defer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/close");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    try expectPeerClose(&client, uri);

    // A follow-up request on the SAME client must succeed: the peer close
    // was not route death; Born's reactor is still serving traffic.
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    var transfer_buf: [4096]u8 = undefined;
    const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(get_body, body);
    try testing.expectEqual(@as(u32, 2), f.accepts.load(.monotonic));
    try testing.expect(!f.failed.load(.monotonic));
}

test "fixture teardown is prompt when the follow-up never arrives (#126)" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.start(.peer_close_then_get);
    errdefer f.teardown();
    const port = try f.waitReady(io);

    const url = try urlFor(testing.allocator, port, "/close");
    defer testing.allocator.free(url);
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();

    // Trigger the peer close, then never send the follow-up: the fixture is
    // left blocked on its second accept. Any error from the first request is
    // tolerated here; this test's contract is teardown promptness, not the
    // peer-close error mapping (the sibling test owns that, and it fails on
    // threaded Zig 0.16.0 Windows). On master the join below hangs forever;
    // with the interruptible-accept fix it returns promptly on every kernel.
    const uri = try std.Uri.parse(url);
    expectPeerClose(&client, uri) catch {};

    const t0 = Io.Timestamp.now(io, .awake);
    f.teardown();
    const elapsed_ns = Io.Timestamp.now(io, .awake).nanoseconds - t0.nanoseconds;
    try testing.expect(elapsed_ns < 5 * std.time.ns_per_s);
}

test "fixture teardown has no lost-wakeup hang under interleaving (#126)" {
    const io = testing.io;
    // Regression bound for the teardown exit race: start a single-accept
    // fixture, drive a full GET so it is finishing on its own, then teardown
    // right as it exits. The no-hang guarantee comes from teardown's
    // snapshot-before-exited-check ordering and the events word every accept
    // and exit advances, not from the iteration count (most iterations take the
    // exited fast path). teardown runs on a worker and each iteration is bounded
    // by a futex timeout, so a reintroduced lost wakeup is a reportable failure,
    // not a wedged suite.
    const iterations = 3000;
    const bound_ns: i96 = 5 * std.time.ns_per_s;
    const gpa = std.heap.page_allocator;

    const State = struct {
        f: Fixture,
        io: Io,
        done: std.atomic.Value(u32) = .init(0),
    };
    const Worker = struct {
        fn run(st: *State) void {
            st.f.teardown();
            st.done.store(1, .release);
            std.Io.futexWake(st.io, u32, &st.done.raw, 1);
        }
    };

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const st = try gpa.create(State);
        st.* = .{ .f = .{ .behavior = .get }, .io = io };
        // Until the worker takes over, this frame owns teardown and the state.
        var worker_owned = false;
        defer {
            if (!worker_owned) {
                st.f.teardown();
                gpa.destroy(st);
            }
        }
        try st.f.start(.get);

        const port = try st.f.waitReady(io);
        const url = try urlFor(testing.allocator, port, "/");
        defer testing.allocator.free(url);
        var client: http.Client = .{ .allocator = testing.allocator, .io = io };
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [1024]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);
        try testing.expectEqual(http.Status.ok, resp.head.status);
        var transfer_buf: [4096]u8 = undefined;
        const body = try readAll(resp.reader(&transfer_buf), testing.allocator);
        defer testing.allocator.free(body);
        try testing.expectEqualStrings(get_body, body);

        // The fixture has served its one request and is exiting; teardown now
        // races its exit path. The worker owns teardown from here.
        const worker = try std.Thread.spawn(.{}, Worker.run, .{st});
        worker_owned = true;
        const deadline = Io.Timestamp.now(io, .awake).nanoseconds + bound_ns;
        var finished = false;
        while (true) {
            if (st.done.load(.acquire) != 0) {
                finished = true;
                break;
            }
            const remaining = deadline - Io.Timestamp.now(io, .awake).nanoseconds;
            if (remaining <= 0) break;
            // Returns normally on wake AND on timeout; re-check the word and
            // the deadline (spurious wakes too).
            std.Io.futexWaitTimeout(io, u32, &st.done.raw, 0, .{ .duration = .{ .raw = std.Io.Duration.fromNanoseconds(remaining), .clock = .awake } }) catch break;
        }
        if (!finished) {
            // Teardown hung: a lost wakeup. Detach the worker (it still
            // references st, so st is intentionally leaked) and fail reportably.
            worker.detach();
            std.log.err("teardown lost-wakeup hang at iteration {d}/{d} (#126)", .{ i + 1, iterations });
            return error.TeardownLostWakeup;
        }
        worker.join();
        gpa.destroy(st);
    }
}
