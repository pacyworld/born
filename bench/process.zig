//! born.io process-route benchmark (P5.4). Built only by `zig build
//! bench-process` on Zig >= 0.16; it is not part of `test`, `test-bin` or
//! `check-targets`. Driver and acceptance rule: bench/quiet.sh.
//!
//!   born-process-bench [--route born|threaded|both] [--seconds S]
//!                      [--threads T] [--seq N] [--mode wait|kill]
//!
//! Measures the routed process family against the all-Threaded baseline:
//! sequential spawn round-trip latency and concurrent spawn throughput, each
//! with per-operation latency percentiles. `--mode wait` (default) spawns
//! `/bin/sh -c "exit 0"` and waits for the exit; `--mode kill` spawns
//! `/bin/sleep 30` and kills it, exercising the uncancelable kill drain. With
//! `--route both` it prints the Born-vs-Threaded ops/s ratio and p99 comparison
//! (informational; there is no written throughput target for the process
//! family). The per-route counters from `born_io.processStats` prove the
//! exchange ran on Born's reactor (zero `threaded_*` on the Born route).
//!
//! Child stdio is `.ignore` here so the measurement stays on the process
//! route. Piped child stdio is an explicit Threaded hybrid (design 5.3): the
//! parent pipe ends are Threaded-serviced file I/O, NOT claimed by these
//! counters, so a piped workload would add Threaded stream cost on top of the
//! numbers below. This is not a Born-reactor stream result. The measurement
//! clock is Born's monotonic clock on both routes. Accept results only on a
//! quiet host (bench/quiet.sh); record them in bench/RESULTS.md per release.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const born_io = @import("born.io");
const compat = @import("compat");
const Io = std.Io;

comptime {
    if (builtin.zig_version.minor < 16)
        @compileError("born-process-bench requires Zig >= 0.16 (born.io)");
    if (builtin.os.tag != .freebsd and builtin.os.tag != .linux)
        @compileError("born-process-bench is FreeBSD/Linux only (the process route)");
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
const Mode = enum { wait, kill };

const Options = struct {
    route: Route = .both,
    seconds: u32 = 5,
    threads: u32 = 16,
    seq: u32 = 100,
    mode: Mode = .wait,
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
        } else if (std.mem.eql(u8, arg, "--seq")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.seq = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[i], 0), 10);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= argv.len) return usage();
            o.mode = std.meta.stringToEnum(Mode, std.mem.sliceTo(argv[i], 0)) orelse return usage();
        } else return usage();
    }
    if (o.seconds == 0 or o.threads == 0 or o.threads > threads_max or
        o.seq == 0 or o.seq > seq_max) return usage();
    return o;
}

fn usage() error{Usage} {
    out(
        "usage: born-process-bench [--route born|threaded|both] [--seconds S]\n" ++
            "                          [--threads T] [--seq N] [--mode wait|kill]\n",
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

/// One spawn round-trip: spawn the mode's child, then wait for its exit
/// (`wait`) or kill it and drain the exit (`kill`). Stdio is `.ignore` so the
/// exchange stays on the process route (piped stdio is a Threaded hybrid).
fn roundTrip(io: Io, mode: Mode) !void {
    var child = try std.process.spawn(io, .{
        .argv = if (mode == .wait) &.{ "/bin/sh", "-c", "exit 0" } else &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    if (mode == .wait) {
        _ = try std.process.Child.wait(&child, io);
    } else {
        std.process.Child.kill(&child, io);
    }
}

const RouteResult = struct { ops_per_sec: f64, p99_us: f64 };

fn runRoute(alloc: std.mem.Allocator, route: Route, o: Options) !RouteResult {
    var port = try born.EvPort.init(alloc);
    defer port.deinit();
    const interface = try born_io.io(&port, .{
        .allocator = alloc,
        .capabilities = if (route == .born) .{ .process = .born_evented } else .{},
    });
    defer born_io.deinit(interface);
    const name = @tagName(route);

    // Sequential latency: one spawn round-trip at a time on the calling thread.
    const seq_samples = try alloc.alloc(u64, o.seq);
    defer alloc.free(seq_samples);
    for (seq_samples) |*s| {
        const t0 = nowNs();
        roundTrip(interface, o.mode) catch |err| {
            out("route={s} sequential round-trip failed: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        s.* = nowNs() - t0;
    }
    const seq = stats(seq_samples);
    out("route={s} mode={s} sequential ops={d} p50_us={d:.1} p99_us={d:.1} max_us={d:.1} mean_us={d:.1}\n", .{
        name, @tagName(o.mode), o.seq, seq.p50, seq.p99, seq.max, seq.mean,
    });

    // Concurrent throughput: raw blocking threads, one round-trip in flight per
    // thread, until the phase deadline. On the Born route every spawn/wait/kill
    // is a cross-thread submission through the loop thread. Snapshot the
    // counters to isolate this phase from the sequential round-trips above.
    const stats_before = born_io.processStats(interface);
    const ctx = try alloc.create(Concurrent);
    defer alloc.destroy(ctx);
    ctx.* = .{
        .io = interface,
        .mode = o.mode,
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
    if (taken == 0) {
        out("route={s} no completed round-trips\n", .{name});
        return error.NoRequests;
    }
    const conc = stats(ctx.samples[0..taken]);
    const ops_per_sec = @as(f64, @floatFromInt(requests)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
    out("route={s} mode={s} concurrent threads={d} seconds={d} requests={d} ops_per_sec={d:.0} p50_us={d:.1} p99_us={d:.1}\n", .{
        name, @tagName(o.mode), o.threads, o.seconds, requests, ops_per_sec, conc.p50, conc.p99,
    });
    const st = born_io.processStats(interface);
    out("route={s} counters spawn={d} wait={d} kill={d} threaded_spawn={d} threaded_wait={d} threaded_kill={d}\n", .{
        name,
        st.spawn - stats_before.spawn,
        st.wait - stats_before.wait,
        st.kill - stats_before.kill,
        st.threaded_spawn - stats_before.threaded_spawn,
        st.threaded_wait - stats_before.threaded_wait,
        st.threaded_kill - stats_before.threaded_kill,
    });
    return .{ .ops_per_sec = ops_per_sec, .p99_us = conc.p99 };
}

const Concurrent = struct {
    io: Io,
    mode: Mode,
    end_ns: u64,
    count: std.atomic.Value(u64) = .init(0),
    samples: []u64,
    sample_idx: std.atomic.Value(usize) = .init(0),
};

fn concurrentWorker(ctx: *Concurrent) void {
    while (nowNs() < ctx.end_ns) {
        const t0 = nowNs();
        roundTrip(ctx.io, ctx.mode) catch return;
        const dt = nowNs() - t0;
        _ = ctx.count.fetchAdd(1, .monotonic);
        const idx = ctx.sample_idx.fetchAdd(1, .monotonic);
        if (idx < ctx.samples.len) ctx.samples[idx] = dt;
    }
}

pub const main = if (builtin.zig_version.minor >= 16) mainWithInit else mainRaw;

fn mainWithInit(init: std.process.Init.Minimal) !void {
    return mainWithArgs(init.args.vector);
}

fn mainRaw() !void {
    return mainWithArgs(std.os.argv);
}

fn mainWithArgs(argv: anytype) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = if (compat.is_debug) gpa.allocator() else std.heap.smp_allocator;
    const o = parseArgs(argv) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => return err,
    };
    switch (o.route) {
        .born => _ = try runRoute(alloc, .born, o),
        .threaded => _ = try runRoute(alloc, .threaded, o),
        .both => {
            const threaded = try runRoute(alloc, .threaded, o);
            const born_result = try runRoute(alloc, .born, o);
            // Informational comparison (no written throughput target for the
            // process family). Accept only on a quiet host; record per release.
            const ratio = born_result.ops_per_sec / threaded.ops_per_sec;
            out("compare mode={s} threads={d} ops_ratio={d:.3} p99_born_us={d:.1} p99_threaded_us={d:.1}\n", .{
                @tagName(o.mode), o.threads, ratio, born_result.p99_us, threaded.p99_us,
            });
        },
    }
}
