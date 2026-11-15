//! born.io time-route benchmark (P5.2). Built only by `zig build bench-time`
//! on Zig >= 0.16; it is not part of `test`, `test-bin` or `check-targets`.
//! Driver and acceptance rule: bench/time.sh, bench/quiet.sh.
//!
//!   born-time-bench [--route born|threaded|both] [--seconds S]
//!                   [--threads N] [--sleep-ms M] [--seq N]
//!                   [--instances N]
//!
//! Measures the routed time family against the all-Threaded baseline:
//! sequential sleep latency and concurrent sleep throughput, each with
//! per-operation latency percentiles. With `--route both` it also checks
//! the written target (bench/README.md): at 64 sleepers Born must reach
//! >= 95% of Threaded's ops/s with p99 no worse, and prints the Born
//! route's per-sleep latency breakdown from `born_io.timeStats`.
//! `--instances N` spreads the sleepers over N port/instance pairs (the
//! scale model's thread-per-core deployment shape); the default is one
//! instance. The measurement clock is Born's monotonic clock
//! (CLOCK_MONOTONIC / QPC) on both routes, independent of the route under
//! test. Accept results only on a quiet host.

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
    instances: u32 = 1,
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
        } else if (std.mem.eql(u8, arg, "--instances")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.instances = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[i], 0), 10);
        } else return usage();
    }
    if (o.seconds == 0 or o.threads == 0 or o.threads > threads_max or
        o.sleep_ms == 0 or o.seq == 0 or o.seq > seq_max or
        o.instances == 0 or o.instances > o.threads) return usage();
    return o;
}

fn usage() error{Usage} {
    out(
        "usage: born-time-bench [--route born|threaded|both] [--seconds S]\n" ++
            "                       [--threads N] [--sleep-ms M] [--seq N]\n" ++
            "                       [--instances N]\n",
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

/// Concurrent-phase result, used for the written target check.
const RouteResult = struct { ops_per_sec: f64, p99_us: f64 };

fn runRoute(alloc: std.mem.Allocator, route: Route, o: Options) !RouteResult {
    // One port and one instance per scale-model shard; the default is a
    // single instance. Sleepers are spread round-robin over the instances.
    const ports = try alloc.alloc(born.EvPort, o.instances);
    defer alloc.free(ports);
    const interfaces = try alloc.alloc(Io, o.instances);
    defer alloc.free(interfaces);
    for (ports, 0..) |*port, i| {
        port.* = try born.EvPort.init(alloc);
        interfaces[i] = try born_io.io(port, .{
            .allocator = alloc,
            .capabilities = if (route == .born) .{ .time = .born_evented } else .{},
        });
    }
    defer for (ports, 0..) |*port, i| {
        born_io.deinit(interfaces[i]);
        port.deinit();
    };
    const interface = interfaces[0];
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
    // cross-thread submission through its instance's loop thread.
    // Stats snapshot: isolate the concurrent phase from the sequential
    // sleeps above (the accumulators span each instance's lifetime).
    const stats_before = try alloc.alloc(born_io.TimeStats, o.instances);
    defer alloc.free(stats_before);
    for (interfaces, 0..) |io, i| stats_before[i] = born_io.timeStats(io);
    const ctx = try alloc.create(Concurrent);
    defer alloc.destroy(ctx);
    ctx.* = .{
        .ios = interfaces,
        .dur = dur,
        .end_ns = nowNs() + @as(u64, o.seconds) * std.time.ns_per_s,
        .samples = try alloc.alloc(u64, samples_max),
    };
    defer alloc.free(ctx.samples);
    const threads = try alloc.alloc(std.Thread, o.threads);
    defer alloc.free(threads);
    const phase_start = nowNs();
    for (threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, concurrentWorker, .{ ctx, i });
    for (threads) |t| t.join();
    const elapsed_ns = nowNs() - phase_start;
    const requests = ctx.count.load(.monotonic);
    const taken = @min(ctx.sample_idx.load(.monotonic), ctx.samples.len);
    const conc = stats(ctx.samples[0..taken]);
    const ops_per_sec = @as(f64, @floatFromInt(requests)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
    out("route={s} concurrent threads={d} instances={d} seconds={d} sleep_ms={d} requests={d} ops_per_sec={d:.0} p50_us={d:.1} p99_us={d:.1}\n", .{
        name, o.threads, o.instances, o.seconds, o.sleep_ms, requests, ops_per_sec, conc.p50, conc.p99,
    });
    if (route == .born) {
        var ops: u64 = 0;
        var wakes: u64 = 0;
        var submit_wake_ns: u64 = 0;
        var queue_arm_ns: u64 = 0;
        var timer_span_ns: u64 = 0;
        var futex_return_ns: u64 = 0;
        for (interfaces, 0..) |io, i| {
            const s = born_io.timeStats(io);
            ops += s.ops - stats_before[i].ops;
            wakes += s.wakes - stats_before[i].wakes;
            submit_wake_ns += s.submit_wake_ns - stats_before[i].submit_wake_ns;
            queue_arm_ns += s.queue_arm_ns - stats_before[i].queue_arm_ns;
            timer_span_ns += s.timer_span_ns - stats_before[i].timer_span_ns;
            futex_return_ns += s.futex_return_ns - stats_before[i].futex_return_ns;
        }
        if (ops > 0) {
            // Per-sleep means in microseconds. queue_arm includes
            // submit_wake; loop_handoff is their difference. kernel_slack
            // is the armed span minus the request (negative when the
            // handoff consumed part of the requested sleep).
            const n = @as(f64, @floatFromInt(ops));
            const us = 1000.0;
            const submit_wake = @as(f64, @floatFromInt(submit_wake_ns)) / n / us;
            const queue_arm = @as(f64, @floatFromInt(queue_arm_ns)) / n / us;
            const timer_span = @as(f64, @floatFromInt(timer_span_ns)) / n / us;
            const futex_return = @as(f64, @floatFromInt(futex_return_ns)) / n / us;
            const requested_us = @as(f64, @floatFromInt(o.sleep_ms)) * 1000.0;
            out("route=born breakdown ops={d} wakes={d} submit_wake_us={d:.1} queue_arm_us={d:.1} loop_handoff_us={d:.1} timer_span_us={d:.1} kernel_slack_us={d:.1} futex_return_us={d:.1}\n", .{
                ops,
                wakes,
                submit_wake,
                queue_arm,
                queue_arm - submit_wake,
                timer_span,
                timer_span - requested_us,
                futex_return,
            });
        }
    }
    return .{ .ops_per_sec = ops_per_sec, .p99_us = conc.p99 };
}

const Concurrent = struct {
    ios: []Io,
    dur: Io.Duration,
    end_ns: u64,
    count: std.atomic.Value(u64) = .init(0),
    samples: []u64,
    sample_idx: std.atomic.Value(usize) = .init(0),
};

fn concurrentWorker(ctx: *Concurrent, worker_index: usize) void {
    const io = ctx.ios[worker_index % ctx.ios.len];
    while (nowNs() < ctx.end_ns) {
        const t0 = nowNs();
        Io.sleep(io, ctx.dur, .awake) catch return;
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
        .born => _ = try runRoute(alloc, .born, o),
        .threaded => _ = try runRoute(alloc, .threaded, o),
        .both => {
            const threaded = try runRoute(alloc, .threaded, o);
            const born_result = try runRoute(alloc, .born, o);
            // Written target (bench/README.md): at 64 sleepers Born reaches
            // >= 95% of Threaded's concurrent ops/s with p99 no worse.
            const ratio = born_result.ops_per_sec / threaded.ops_per_sec;
            const met = ratio >= 0.95 and born_result.p99_us <= threaded.p99_us;
            out("target threads={d} instances={d} sleep_ms={d} ops_ratio={d:.3} (need >= 0.950) p99_born_us={d:.1} p99_threaded_us={d:.1} (need born <= threaded): {s}\n", .{
                o.threads,
                o.instances,
                o.sleep_ms,
                ratio,
                born_result.p99_us,
                threaded.p99_us,
                if (met) "MET" else "UNMET",
            });
        },
    }
}
