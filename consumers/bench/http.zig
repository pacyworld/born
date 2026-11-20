//! HTTP consumer benchmark (P5.5, design section 9). Built only by
//! `zig build bench-http` in the consumers package on Zig >= 0.16; it is
//! not part of any test step. Driver and quiet-host rule:
//! consumers/bench/http.sh (born's bench/quiet.sh on FreeBSD).
//!
//!   born-http-bench [--route born|threaded|both] [--seconds S]
//!
//! One std.http.Client instance, keep-alive, sequential GET requests of a
//! fixed 1 KiB payload against a local plain-Threaded std.http.Server
//! fixture, for 5 s by default; reports ops/s, p50 and p99 per route. The
//! born route runs the client on born.io (capabilities.network =
//! .born_evented); the threaded route is the all-Threaded baseline through
//! the same shim. The fixture always runs on a dedicated plain Io.Threaded
//! instance on its own OS thread, so both routes talk to the same upstream
//! server stack. The measurement clock is Born's monotonic clock
//! (CLOCK_MONOTONIC / QPC) on both routes, independent of the route under
//! test. The first request of a route includes the connect. Results are a
//! per-release recording step (bench/RESULTS.md), not a per-push gate;
//! accept them only on a quiet host.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const born_io = @import("born_io");
const compat = @import("compat");
const Io = std.Io;
const http = std.http;

// Plain-HTTP benchmark, consistent with the contract suite and nats
// use_tls = false; compiling TLS out keeps the client's TLS-only fields
// void on both toolchains.
pub const std_options = std.Options{
    .http_disable_tls = true,
};

comptime {
    if (builtin.zig_version.minor < 16)
        @compileError("born-http-bench requires Zig >= 0.16 (born.io)");
}

const samples_max: usize = 1 << 20;
const payload_len: usize = 1024;

fn nowNs() u64 {
    return born.nowNs() catch @panic("monotonic clock failed");
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch @panic("stdout format failed");
    var written: usize = 0;
    while (written < text.len) {
        written += compat.write(1, text[written..]) catch @panic("stdout write failed");
    }
}

const Route = enum { born, threaded, both };

const Options = struct {
    route: Route = .both,
    seconds: u32 = 5,
};

fn parseArgs(argv: anytype) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(argv[i], 0);
        if (std.mem.eql(u8, arg, "--route")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.route = std.meta.stringToEnum(Route, std.mem.sliceTo(argv[i], 0)) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.seconds = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[i], 0), 10);
        } else return usage();
    }
    if (o.seconds == 0) return usage();
    return o;
}

fn usage() error{Usage} {
    out("usage: born-http-bench [--route born|threaded|both] [--seconds S]\n", .{});
    return error.Usage;
}

/// Latency percentiles in microseconds; sorts the sample span in place.
const Stats = struct { p50: f64, p99: f64, max: f64, mean: f64 };

fn stats(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const us = 1000.0;
    return .{
        .p50 = @as(f64, @floatFromInt(samples[samples.len * 50 / 100])) / us,
        .p99 = @as(f64, @floatFromInt(samples[@min(samples.len - 1, samples.len * 99 / 100)])) / us,
        .max = @as(f64, @floatFromInt(samples[samples.len - 1])) / us,
        .mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len)) / us,
    };
}

const RouteResult = struct { ops_per_sec: f64, p50_us: f64, p99_us: f64, ops: u64 };

// ---------------------------------------------------------------------------
// Fixture: plain Threaded io on a dedicated OS thread, one keep-alive
// connection answering every GET with the fixed 1 KiB payload. Never
// touches the route under test.
// ---------------------------------------------------------------------------

const Fixture = struct {
    port: std.atomic.Value(u16) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(f: *Fixture) !void {
        f.* = .{};
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
};

fn fixtureMain(f: *Fixture) void {
    var threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    fixtureMainInner(f, threaded.io()) catch |err| {
        std.log.err("http bench fixture failed: {s}", .{@errorName(err)});
        f.failed.store(true, .monotonic);
    };
}

fn fixtureMainInner(f: *Fixture, io: Io) !void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    f.port.store(listener.socket.address.ip4.port, .monotonic);

    var stream = try listener.accept(io);
    defer stream.close(io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);
    var server = http.Server.init(&sr.interface, &sw.interface);
    var payload: [payload_len]u8 = undefined;
    fillPattern(&payload);
    // The client's deinit closes the pool, which ends this loop via
    // HttpConnectionClosing.
    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try req.respond(&payload, .{});
    }
}

fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
}

// ---------------------------------------------------------------------------
// Route under test: one keep-alive client, sequential 1 KiB GETs.
// ---------------------------------------------------------------------------

fn runRoute(alloc: std.mem.Allocator, route: Route, o: Options) !RouteResult {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const io = try born_io.io(&port, .{
        .allocator = alloc,
        .capabilities = if (route == .born) .{ .network = .born_evented } else .{},
    });
    defer born_io.deinit(io);

    var f: Fixture = undefined;
    try f.start();
    // client.deinit closes the pool and ends the fixture loop; it must run
    // before f.join (defer LIFO: join registered first).
    defer f.join();
    const fport = try f.waitReady(io);

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{fport});
    defer alloc.free(url);
    const uri = try std.Uri.parse(url);
    var client: http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const samples = try alloc.alloc(u64, samples_max);
    defer alloc.free(samples);
    var body_buf: [payload_len]u8 = undefined;
    var redirect_buf: [1024]u8 = undefined;
    var transfer_buf: [4096]u8 = undefined;

    const wall_start = nowNs();
    const deadline_ns = wall_start + @as(u64, o.seconds) * std.time.ns_per_s;
    var count: usize = 0;
    while (nowNs() < deadline_ns) {
        if (count == samples.len) @panic("born-http-bench: sample buffer full");
        const t0 = nowNs();
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var resp = try req.receiveHead(&redirect_buf);
        if (resp.head.status != .ok) return error.UnexpectedStatus;
        try resp.reader(&transfer_buf).readSliceAll(&body_buf);
        samples[count] = nowNs() - t0;
        count += 1;
    }
    const wall_ns = nowNs() - wall_start;
    if (count == 0) return error.NoSamples;
    const s = stats(samples[0..count]);
    const ops_per_sec = @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(wall_ns)) / std.time.ns_per_s);
    out("{s}: {d:.0} ops/s, p50 {d:.1}us, p99 {d:.1}us, max {d:.1}us, mean {d:.1}us ({d} ops in {d:.2}s)\n", .{
        @tagName(route),
        ops_per_sec,
        s.p50,
        s.p99,
        s.max,
        s.mean,
        count,
        @as(f64, @floatFromInt(wall_ns)) / std.time.ns_per_s,
    });
    if (route == .born) {
        const ns = born_io.networkStats(io);
        out("networkStats: born connect={d} read={d} write={d}; threaded connect={d} read={d} write={d}\n", .{
            ns.connect,
            ns.read,
            ns.write,
            ns.threaded_connect,
            ns.threaded_read,
            ns.threaded_write,
        });
        if (ns.connect == 0 or ns.read == 0 or ns.write == 0)
            @panic("born-http-bench: born route counters are zero; the client did not run on Born");
        if (ns.threaded_connect != 0)
            @panic("born-http-bench: a client connect was delegated to Threaded");
    }
    return .{ .ops_per_sec = ops_per_sec, .p50_us = s.p50, .p99_us = s.p99, .ops = count };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = if (builtin.mode == std.builtin.OptimizeMode.Debug) gpa.allocator() else std.heap.smp_allocator;
    const o = parseArgs(init.args.vector) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => return err,
    };
    switch (o.route) {
        .born => _ = try runRoute(alloc, .born, o),
        .threaded => _ = try runRoute(alloc, .threaded, o),
        .both => {
            const threaded = try runRoute(alloc, .threaded, o);
            const born_result = try runRoute(alloc, .born, o);
            // Informational comparison; the consumer benchmark has no
            // written acceptance target (recording step, design section 9).
            out("comparison: ops_ratio={d:.3} p50_born_us={d:.1} p50_threaded_us={d:.1} p99_born_us={d:.1} p99_threaded_us={d:.1}\n", .{
                born_result.ops_per_sec / threaded.ops_per_sec,
                born_result.p50_us,
                threaded.p50_us,
                born_result.p99_us,
                threaded.p99_us,
            });
        },
    }
}
