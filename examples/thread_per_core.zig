//! born-echo-per-core: the thread-per-core echo server. N worker threads
//! each own one event port and one `.balanced` listener on the same TCP
//! port; the kernel spreads connections across them (SO_REUSEPORT_LB on
//! FreeBSD, SO_REUSEPORT on Linux). The main thread watches SIGTERM/Ctrl+C
//! and shuts workers down with cross-thread `wake()`.
//!
//! Usage: born-echo-per-core [port] [threads]
//!   port     default 7001 (0 picks an ephemeral port), binds 127.0.0.1
//!   threads  default: one per CPU, clamped to 1..64
//!
//! `.balanced` needs kernel load balancing: FreeBSD and Linux run this
//! program; macOS, NetBSD, OpenBSD and Windows report Unsupported and the
//! program exits cleanly with a message. It compiles on all seven targets.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const echo = @import("echo.zig");

/// 0.16+ passes process args through main(init); 0.15.2 has no such
/// parameter and uses argsAlloc. Select the entry shape at comptime so each
/// toolchain only analyzes the branch it compiles.
const use_init_main = builtin.zig_version.minor >= 16;
pub const main = if (use_init_main) mainInit else mainPlain;

fn mainPlain() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    return run(alloc, args);
}

fn mainInit(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var it = try init.args.iterateAllocator(alloc);
    defer it.deinit();
    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(alloc);
    while (it.next()) |a| try args.append(alloc, a);
    return run(alloc, args.items);
}

fn run(alloc: std.mem.Allocator, args: anytype) !void {
    // The main thread services the signal port; the workers each run their
    // own Born loop and mark themselves in echo.Worker.run.
    born.loop_thread.mark();
    defer born.loop_thread.unmark();
    // Signals are process-wide and must be blocked in every thread on
    // epoll, so block them in main before spawning workers.
    try born.blockSignals(&.{ .terminate, .interrupt });

    const port: u16 = if (args.len > 1)
        try std.fmt.parseInt(u16, args[1], 10)
    else
        7001;
    const n: usize = if (args.len > 2)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        std.Thread.getCpuCount() catch 4;
    if (n == 0 or n > 64) {
        std.log.err("thread count must be 1..64", .{});
        return error.InvalidArgument;
    }

    var main_port = try born.EvPort.init(alloc);
    defer main_port.deinit();
    // Only the main port watches signals; workers shut down by wake().
    try main_port.watchSignal(.terminate, null);
    try main_port.watchSignal(.interrupt, null);

    const workers = try alloc.alloc(echo.Worker, n);
    defer alloc.free(workers);
    const addr = try born.socket.Address.parseIp4("127.0.0.1", port);
    for (workers) |*w| w.* = .{ .alloc = alloc, .notify = &main_port, .addr = addr };

    // Worker 0 binds first (port 0 picks the ephemeral port); the rest bind
    // the same actual address with .balanced so the kernel spreads load.
    try workers[0].spawn();
    switch (try echo.waitReady(workers[0..1], &main_port, 10_000)) {
        .ready => {},
        .signal => {
            try echo.Worker.shutdownAll(workers[0..1], &main_port);
            return;
        },
        .failed, .timeout => {
            const err = workers[0].last_error orelse error.WorkerStartupTimeout;
            try echo.Worker.shutdownAll(workers[0..1], &main_port);
            if (err == error.Unsupported) {
                std.log.info("born-echo-per-core: kernel-balanced reuse-port is unavailable on this platform (FreeBSD SO_REUSEPORT_LB or Linux SO_REUSEPORT required); nothing to do", .{});
                return;
            }
            return err;
        },
    }
    for (workers[1..]) |*w| {
        w.addr = workers[0].bound;
        try w.spawn();
    }
    switch (try echo.waitReady(workers, &main_port, 10_000)) {
        .ready => {},
        .signal => {
            try echo.Worker.shutdownAll(workers, &main_port);
            return;
        },
        .failed, .timeout => {
            try echo.Worker.shutdownAll(workers, &main_port);
            return error.WorkerStartupFailed;
        },
    }

    std.log.info("born-echo-per-core: {s} backend, {d} workers listening on 127.0.0.1:{d}; SIGTERM or Ctrl+C drains", .{
        born.backend_name, n, workers[0].bound.getPort(),
    });

    // Block until a signal arrives; wake events from startup are ignored.
    var events: [16]born.Event = undefined;
    var signaled = false;
    while (!signaled) {
        const count = try main_port.wait(&events, null);
        for (events[0..count]) |ev| {
            if (ev.signal != null) signaled = true;
        }
    }

    try echo.Worker.shutdownAll(workers, &main_port);
    var accepted: usize = 0;
    var echoed: usize = 0;
    for (workers) |*w| {
        accepted += w.final_accepted;
        echoed += w.final_echoed;
    }
    std.log.info("born-echo-per-core: drained, {d} connections, {d} bytes echoed", .{ accepted, echoed });
}
