//! born.io time-route benchmark (P5.2). Built only by `zig build bench-time`
//! on Zig >= 0.16; it is not part of `test`, `test-bin` or `check-targets`.
//! Driver and acceptance rule: bench/time.sh, bench/quiet.sh.
//!
//!   born-time-bench [--route born|threaded|both] [--seconds S]
//!                   [--threads N] [--sleep-ms M] [--seq N]
//!
//! Measures the routed time family against the all-Threaded baseline:
//! sequential sleep latency and concurrent sleep throughput, each with
//! per-operation latency percentiles. The measurement clock is Born's
//! monotonic clock (CLOCK_MONOTONIC / QPC) on both routes, independent of
//! the route under test. Accept results only on a quiet host.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const born_io = @import("born.io");
const compat = @import("compat");
const Io = std.Io;

comptime {
    if (builtin.zig_version.minor < 16)
        @compileError("born-time-bench requires Zig >= 0.16 (born.io)");
}

const threads_max: usize = 256;
const seq_max: usize = 4096;
const samples_max: usize = 1 << 20;

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
    threads: u32 = 64,
    sleep_ms: u32 = 1,
    seq: u32 = 200,
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
        } else if (std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.threads = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[i], 0), 10);
        } else if (std.mem.eql(u8, arg, "--sleep-ms")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.sleep_ms = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[i], 0), 10);
        } else if (std.mem.eql(u8, arg, "--seq")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.seq = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[i], 0), 10);
        } else return usage();
    }
    if (o.seconds == 0 or o.threads == 0 or o.threads > threads_max or
        o.sleep_ms == 0 or o.seq == 0 or o.seq > seq_max) return usage();
    return o;
}

fn usage() error{Usage} {
    out(
        "usage: born-time-bench [--route born|threaded|both] [--seconds S]\n" ++
            "                       [--threads N] [--sleep-ms M] [--seq N]\n",
        .{},
    );
    return error.Usage;
}

/// Latency percentiles over an unsorted sample span, in microseconds.
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

fn runRoute(alloc: std.mem.Allocator, route: Route, o: Options) !void {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const interface = try born_io.io(&port, .{
        .allocator = alloc,
        .capabilities = if (route == .born) .{ .time = .born_evented } else .{},
    });
    defer born_io.deinit(interface);
    const name = @tagName(route);
    const dur: Io.Duration = .fromMilliseconds(o.sleep_ms);

    // Sequential latency: one sleep at a time on the calling thread.
    const seq_samples = try alloc.alloc(u64, o.seq);
    defer alloc.free(seq_samples);
    for (seq_samples) |*s| {
        const t0 = nowNs();
        Io.sleep(interface, dur, .awake) catch |err| {
            out("route={s} sequential sleep failed: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        s.* = nowNs() - t0;
    }
    const seq = stats(seq_samples);
    out("route={s} sequential sleeps={d} sleep_ms={d} p50_us={d:.1} p99_us={d:.1} max_us={d:.1} mean_us={d:.1}\n", .{
        name, o.seq, o.sleep_ms, seq.p50, seq.p99, seq.max, seq.mean,
    });

    // Concurrent throughput: raw blocking threads, one sleep in flight per
    // thread, until the phase deadline. On the Born route every sleep is a
    // cross-thread submission through the shim's loop thread.
    const ctx = try alloc.create(Concurrent);
    defer alloc.destroy(ctx);
    ctx.* = .{
        .io = interface,
        .dur = dur,
        .end_ns = nowNs() + @as(u64, o.seconds) * std.time.ns_per_s,
        .samples = try alloc.alloc(u64, samples_max),
    };
    defer alloc.free(ctx.samples);
    const threads = try alloc.alloc(std.Thread, o.threads);
    defer alloc.free(threads);
    const phase_start = nowNs();
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, concurrentWorker, .{ctx});
    for (threads) |t| t.join();
    const elapsed_ns = nowNs() - phase_start;
    const requests = ctx.count.load(.monotonic);
    const taken = @min(ctx.sample_idx.load(.monotonic), ctx.samples.len);
    const conc = stats(ctx.samples[0..taken]);
    const ops_per_sec = @as(f64, @floatFromInt(requests)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
    out("route={s} concurrent threads={d} seconds={d} sleep_ms={d} requests={d} ops_per_sec={d:.0} p50_us={d:.1} p99_us={d:.1}\n", .{
        name, o.threads, o.seconds, o.sleep_ms, requests, ops_per_sec, conc.p50, conc.p99,
    });
}

const Concurrent = struct {
    io: Io,
    dur: Io.Duration,
    end_ns: u64,
    count: std.atomic.Value(u64) = .init(0),
    samples: []u64,
    sample_idx: std.atomic.Value(usize) = .init(0),
};

fn concurrentWorker(ctx: *Concurrent) void {
    while (nowNs() < ctx.end_ns) {
        const t0 = nowNs();
        Io.sleep(ctx.io, ctx.dur, .awake) catch return;
        const dt = nowNs() - t0;
        _ = ctx.count.fetchAdd(1, .monotonic);
        const idx = ctx.sample_idx.fetchAdd(1, .monotonic);
        if (idx < ctx.samples.len) ctx.samples[idx] = dt;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;
    const o = parseArgs(init.args.vector) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => return err,
    };
    switch (o.route) {
        .born => try runRoute(alloc, .born, o),
        .threaded => try runRoute(alloc, .threaded, o),
        .both => {
            try runRoute(alloc, .threaded, o);
            try runRoute(alloc, .born, o);
        },
    }
}
