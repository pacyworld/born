//! born-echo-server: a single-threaded TCP echo server on one event port.
//!
//! Demonstrates the listener, accepted-stream I/O, an idle-timeout sweep
//! timer, and SIGTERM/Ctrl+C drain: on signal the listener closes and
//! established connections finish (or hit the drain deadline) before exit.
//!
//! Usage: born-echo-server [port]     (default 7000, binds 127.0.0.1)
//!
//! Runs on every supported backend. On Windows the signal watch maps to
//! console control events and needs a console; without one, init reports
//! error.Unsupported.

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
    // Required on epoll before any thread exists; a no-op on kqueue/Windows.
    try born.blockSignals(&.{ .terminate, .interrupt });

    const port: u16 = if (args.len > 1)
        try std.fmt.parseInt(u16, args[1], 10)
    else
        7000;

    var port_ev = try born.EvPort.init(alloc);
    defer port_ev.deinit();

    const addr = try born.socket.Address.parseIp4("127.0.0.1", port);
    var listener = try born.socket.Listener.openTcp(alloc, addr, .{});
    errdefer listener.close();
    const engine = try echo.Echo.init(alloc, &port_ev, &listener, .{ .watch_signals = true });
    defer engine.deinit();
    try listener.register(&port_ev, &listener);

    const bound = try listener.localAddress();
    std.log.info("born-echo-server: {s} backend, listening on 127.0.0.1:{d}, idle timeout {d} ms; SIGTERM or Ctrl+C drains", .{
        born.backend_name, bound.getPort(), engine.opts.idle_ms,
    });

    // Timers, signals and socket events all arrive through wait(); nothing
    // polls and no extra thread exists on POSIX.
    while (engine.running()) _ = try engine.waitAndHandle(null);

    std.log.info("born-echo-server: drained, {d} connections, {d} bytes echoed", .{
        engine.accepted_total, engine.echoed_bytes,
    });
}
