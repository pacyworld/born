// Born-owned test runner for the P5.5 proof consumers (design section 6).
// Adaptation of upstream nats test_runner.zig: keeps std_options, LogCapture,
// setup/teardown name-prefix handling, the per-test leak check and the
// slow-test tracker; replaces upstream's per-test Threaded io_instance
// reinit with a FRESH born-backed Io assigned to the facade's writable
// std.testing.io, for setup/teardown tests too (review 192 carry-in 6).
// Prints the born-format summary CI greps for, a networkStats route-evidence
// line, and enforces the route-proof pass/fail gate (review 192 carry-in 1)
// both suite-wide and per test: threaded read/write is attributed to the
// named vendored fixture-server tests only (review 665 R3).
//
// In your build.zig, specify this custom test runner:
// const tests = b.addTest(.{
//    .root_module = $MODULE_BEING_TESTED,
//    .test_runner = .{ .path = b.path("runner.zig"), .mode = .simple },
// });

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .warn },
    },
    .logFn = customLogFn,
    // The HTTP contract suite is plain-HTTP only (design 7.3), consistent
    // with nats use_tls = false; compiling TLS out keeps the client's
    // TLS-only fields void on both toolchains.
    .http_disable_tls = true,
};

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const born_io = @import("born_io");
const consumer_options = @import("consumer_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const is_017 = builtin.zig_version.minor >= 17;

// 80 '=' characters; array multiplication (**) was removed in Zig 0.17.
const BORDER = "================================================================================";

// Log capture for suppressing logs in passing tests.
// The Io is stashed at startup so the global log callback can perform mutex
// operations without having to thread `Io` through every call site. This is
// runner infrastructure on init.io (Threaded), not the consumer path.
const LogCapture = struct {
    capture_writer: ?*std.Io.Writer = null,
    mutex: Io.Mutex = .init,
    io: ?Io = null,

    pub fn logFn(
        self: *@This(),
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const io = self.io orelse {
            // No Io available yet: fall back to raw stderr.
            const scope_prefix = "(" ++ @tagName(scope) ++ "/" ++ @tagName(level) ++ "): ";
            std.debug.print(scope_prefix ++ format ++ "\n", args);
            return;
        };
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const scope_prefix = "(" ++ @tagName(scope) ++ "/" ++ @tagName(level) ++ "): ";

        if (self.capture_writer) |writer| {
            // Write to capture buffer
            writer.print(scope_prefix ++ format ++ "\n", args) catch return;
        } else {
            // Write to stderr (std.debug.print handles its own locking)
            std.debug.print(scope_prefix ++ format ++ "\n", args);
        }
    }

    pub fn startCapture(self: *@This(), io: Io, writer: *std.Io.Writer) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.capture_writer = writer;
    }

    pub fn stopCapture(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.capture_writer = null;
    }
};

var log_capture = LogCapture{};

pub fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_capture.logFn(level, scope, format, args);
}

// use in custom panic handler
var current_test: ?[]const u8 = null;

// Fresh born reactor per test (and per setup/teardown test). The port lives
// in the caller's frame: born_io.io borrows its address, so init in place
// rather than returning the struct by value. The caller owns the port;
// born_io.deinit does not deinit it.
const TestIo = struct {
    port: born.EvPort = undefined,
    tio: Io = undefined,

    fn init(self: *TestIo, gpa: Allocator) !void {
        self.port = try born.EvPort.init(gpa);
        errdefer self.port.deinit();
        self.tio = try born_io.io(&self.port, .{
            .allocator = gpa,
            .capabilities = .{
                // Time/file/process stay Threaded (design section 1); the
                // baseline leg routes network to Threaded as well.
                .network = if (consumer_options.born_network) .born_evented else .threaded,
            },
        });
    }

    fn deinit(self: *TestIo) void {
        born_io.deinit(self.tio);
        self.port.deinit();
    }
};

// Accumulated route evidence across every test and setup/teardown body.
const Totals = struct {
    born_connect: u64 = 0,
    born_read: u64 = 0,
    born_write: u64 = 0,
    threaded_connect: u64 = 0,
    threaded_read: u64 = 0,
    threaded_write: u64 = 0,

    fn add(self: *Totals, s: born_io.NetworkStats) void {
        self.born_connect += s.connect;
        self.born_read += s.read;
        self.born_write += s.write;
        self.threaded_connect += s.threaded_connect;
        self.threaded_read += s.threaded_read;
        self.threaded_write += s.threaded_write;
    }
};

// Vendored e2e tests that run fake servers via listen/accept on
// std.testing.io (keepalive_test's SilentServer, reconnect_limits_test's
// FlakyServer). The shim's adjudicated client-only profile (P5.3 Option B)
// routes listen/accept to Threaded, so reads/writes on those Threaded-owned
// fixture handles forward and count. Only these tests may move threaded
// read/write on a born e2e leg; any other test doing so is a consumer
// delegation and fails (review 665 R3). Names as builtin.test_functions
// reports them.
const fixture_threaded_tests = [_][]const u8{
    "keepalive_test.test.stale connection detected on unresponsive server",
    "reconnect_limits_test.test.handshake failures count against max_reconnect",
};

fn fixtureThreadedAllowed(name: []const u8) bool {
    if (!std.mem.eql(u8, consumer_options.suite, "nats-e2e")) return false;
    for (fixture_threaded_tests) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

/// Per-test route attribution (review 665 R3). Each test runs on a fresh
/// born reactor, so its networkStats are exactly its own traffic (plus its
/// per-test setup, which shares the io). threaded_connect is never allowed;
/// threaded read/write only in the named fixture-server tests. Returns the
/// failure reason, or null.
fn testRouteProof(s: born_io.NetworkStats, name: []const u8) ?[]const u8 {
    if (!consumer_options.born_network) return null;
    if (s.threaded_connect != 0)
        return "threaded connect nonzero: a consumer connect was delegated";
    if (s.threaded_read == 0 and s.threaded_write == 0) return null;
    if (fixtureThreadedAllowed(name)) return null;
    return "threaded read/write nonzero outside the fixture-server tests";
}

/// Route-proof gate (review 192 carry-in 1, design section 6). Born counters
/// increment only on Born-route completions; the baseline-vtable forwards do
/// not increment threaded counters, so born connect > 0 is positive proof
/// the reactor served the traffic. Returns the failure reason, or null.
///
/// Consumer sockets (nats client, std.http.Client) are created only by
/// connect, so threaded_connect == 0 proves no consumer connect was
/// delegated to Threaded; reads/writes on those Born-owned handles cannot
/// silently forward (provenance gate). The nats-e2e suite additionally
/// carries fixture-side threaded read/write: the vendored keepalive and
/// reconnect_limits tests run fake servers via listen/accept on
/// std.testing.io, and the shim's adjudicated client-only profile (P5.3
/// Option B) routes listen/accept to Threaded, so reads/writes on those
/// Threaded-owned handles forward and count. That is fixture traffic, not
/// consumer traffic; the vendored bytes cannot be changed (carry-in 4).
/// testRouteProof attributes that allowance per test, so a consumer
/// read/write delegation in any other e2e test still fails the leg.
fn routeProof(t: *const Totals) ?[]const u8 {
    if (consumer_options.born_network) {
        if (t.threaded_connect != 0)
            return "threaded connect nonzero on a born leg: a consumer connect was delegated";
        if (t.born_connect == 0)
            return "born connect == 0: no Born-route traffic";
        const is_unit = std.mem.eql(u8, consumer_options.suite, "nats-unit");
        const is_e2e = std.mem.eql(u8, consumer_options.suite, "nats-e2e");
        if (!is_e2e and (t.threaded_read != 0 or t.threaded_write != 0))
            return "threaded network counters nonzero on a born leg";
        // The unit suite is parse/serialize-heavy: only connect is exercised
        // (net_util tests). e2e and HTTP must also prove read and write.
        if (!is_unit) {
            if (t.born_read == 0)
                return "born read == 0: no Born-route traffic";
            if (t.born_write == 0)
                return "born write == 0: no Born-route traffic";
        }
    } else {
        if (t.born_connect != 0 or t.born_read != 0 or t.born_write != 0)
            return "born network counters nonzero on the all-Threaded baseline leg";
    }
    return null;
}

// 0.16 testing.allocator_instance is a DebugAllocator (default-constructs,
// deinit returns .ok/.leak); 0.17.1 is a SafeAllocator (explicit init,
// deinit returns the leak count).
fn resetTestAllocator() void {
    if (comptime is_017) {
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
    } else {
        std.testing.allocator_instance = .{};
    }
}

fn testAllocatorLeaked() bool {
    if (comptime is_017) {
        return std.testing.allocator_instance.deinit() != 0;
    } else {
        return std.testing.allocator_instance.deinit() == .leak;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    if (!born_io.network_stats_enabled)
        @panic("consumers runner: born_io_options.network_stats must be true for route proof");

    log_capture.io = io;
    defer log_capture.io = null;

    var env = Env.init(gpa, init.environ_map);
    defer env.deinit(gpa);

    // e2e only: hand the pinned nats-server binary path and the process
    // environment to the fixture facade before any test runs (born#110 W1,
    // born#124). The facade spawns this exact absolute path with an explicit
    // child environ_map; unit and http never read it. The import is
    // comptime-dead outside the e2e suite, so those roots need no consumer_env
    // module.
    if (comptime std.mem.eql(u8, consumer_options.suite, "nats-e2e")) {
        const consumer_env = @import("consumer_env");
        consumer_env.setNatsServer(init.environ_map.get("NATS_SERVER"));
        consumer_env.setEnvironMap(init.environ_map);
    }

    var slowest = SlowTracker.init(io, 5);
    defer slowest.deinit(gpa);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var totals: Totals = .{};

    var log_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer log_buffer.deinit();

    var failed_tests: std.ArrayList([]const u8) = .empty;
    defer failed_tests.deinit(gpa);

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    // Global setup, each on its own fresh born io (carry-in 6).
    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            var test_io: TestIo = .{};
            try test_io.init(gpa);
            defer test_io.deinit();
            std.testing.io = test_io.tio;
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
            const stats = born_io.networkStats(test_io.tio);
            if (testRouteProof(stats, t.name)) |reason| {
                Printer.status(.fail, "\nsetup \"{s}\" route proof: {s}\n", .{ t.name, reason });
                return error.RouteProofFailed;
            }
            totals.add(stats);
        }
    }

    // Count total tests to run
    const test_count = blk: {
        var count: usize = 0;
        for (builtin.test_functions) |t| {
            if (isSetup(t) or isTeardown(t) or isPerTestSetup(t)) continue;
            const is_unnamed_test = isUnnamed(t);
            if (env.filters.items.len > 0) {
                if (is_unnamed_test) continue;
                var matches = false;
                for (env.filters.items) |f| {
                    if (std.mem.indexOf(u8, t.name, f) != null) {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            count += 1;
        }
        break :blk count;
    };

    const root_node = if (env.verbose == .off) std.Progress.start(io, .{
        .root_name = "Running tests",
        .estimated_total_items = test_count,
    }) else std.Progress.Node.none;

    var test_index: usize = 0;

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t) or isPerTestSetup(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming(io);

        const is_unnamed_test = isUnnamed(t);
        if (env.filters.items.len > 0) {
            if (is_unnamed_test) {
                continue;
            }
            var matches = false;
            for (env.filters.items) |f| {
                if (std.mem.indexOf(u8, t.name, f) != null) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                continue;
            }
        }

        const friendly_name = t.name;

        // Update progress
        if (root_node.index != .none) {
            root_node.setCompletedItems(test_index);
            // Progress truncates long names, so show the end of long names
            const display_name = if (friendly_name.len <= std.Progress.Node.max_name_len)
                friendly_name
            else
                friendly_name[friendly_name.len - std.Progress.Node.max_name_len ..];
            root_node.setName(display_name);
        }

        test_index += 1;

        current_test = friendly_name;
        resetTestAllocator();
        // Fresh born reactor per test, mirroring upstream's per-test
        // io_instance reinit; the facade makes testing.io a writable var.
        var test_io: TestIo = .{};
        try test_io.init(gpa);
        defer test_io.deinit();
        std.testing.io = test_io.tio;

        // Run per-test setup functions (e.g. the e2e health gate; tests that
        // restart servers rely on this running again before the next test).
        // They share this test's fresh io: same test boundary.
        for (builtin.test_functions) |setup_t| {
            if (isPerTestSetup(setup_t)) {
                setup_t.func() catch |err| {
                    Printer.status(.fail, "\nper-test setup \"{s}\" failed: {}\n", .{ setup_t.name, err });
                    return err;
                };
            }
        }

        if (env.do_log_capture) {
            log_buffer.clearRetainingCapacity();
            log_capture.startCapture(io, &log_buffer.writer);
        }

        // Print test name before running (for debugging hangs)
        switch (env.verbose) {
            .naming => Printer.fmt("{s} .. ", .{friendly_name}),
            .tracing => Printer.fmt("{s}\n", .{friendly_name}),
            .off => {},
        }

        const result = t.func();

        if (env.do_log_capture) {
            log_capture.stopCapture(io);
        }

        current_test = null;

        const ns_taken = slowest.endTiming(io, gpa, friendly_name);

        const stats = born_io.networkStats(test_io.tio);
        if (env.route_trace and (stats.threaded_connect != 0 or stats.threaded_read != 0 or stats.threaded_write != 0)) {
            Printer.fmt("route trace: {s}: threaded connect={d} read={d} write={d}\n", .{ friendly_name, stats.threaded_connect, stats.threaded_read, stats.threaded_write });
        }
        const delegation = testRouteProof(stats, friendly_name);
        totals.add(stats);
        // test_io deinits via defer at iteration end; its internals allocate
        // from gpa, so the per-test allocator verdict is independent.
        const leaked = testAllocatorLeaked();
        if (leaked) {
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }
        if (delegation) |reason| {
            Printer.status(.fail, "\n{s}\n\"{s}\" - route proof: {s}\n{s}\n", .{ BORDER, friendly_name, reason, BORDER });
        }
        // A leaking or delegating test counts once, as a failure, never also
        // as a pass or skip (review 665 N2/R3).
        const runner_fail = leaked or delegation != null;

        var fail_err: ?anyerror = null;
        if (result) |_| {
            if (runner_fail) {
                status = .fail;
                fail += 1;
                failed_tests.append(gpa, friendly_name) catch {};
            } else {
                pass += 1;
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                if (runner_fail) {
                    status = .fail;
                    fail += 1;
                    failed_tests.append(gpa, friendly_name) catch {};
                } else {
                    skip += 1;
                    status = .skip;
                }
            },
            else => {
                status = .fail;
                fail += 1;
                fail_err = err;
                failed_tests.append(gpa, friendly_name) catch {};
            },
        }

        const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
        const status_str = switch (status) {
            .pass => "OK",
            .fail => "FAIL",
            .skip => "SKIP",
            .text => "",
        };
        switch (env.verbose) {
            .naming => {
                Printer.status(status, "{s}", .{status_str});
                Printer.fmt(" ({d:.2}ms)\n", .{ms});
            },
            .tracing => {
                Printer.fmt("  ", .{});
                Printer.status(status, "{s}", .{status_str});
                Printer.fmt(" ({d:.2}ms)\n", .{ms});
            },
            .off => {},
        }

        // Print error details for failures (in non-verbose mode, progress will show above this)
        if (fail_err) |err| {
            Printer.fmt("{s}\n", .{BORDER});
            Printer.status(.fail, "\"{s}\" - {s}\n", .{ friendly_name, @errorName(err) });

            // Print captured logs for failed tests
            if (log_buffer.written().len > 0) {
                Printer.fmt("Test output:\n{s}", .{log_buffer.written()});
            }

            Printer.fmt("{s}\n", .{BORDER});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
            if (env.fail_first) {
                break;
            }
        }
    }

    // Global teardown, each on its own fresh born io (carry-in 6).
    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            var test_io: TestIo = .{};
            try test_io.init(gpa);
            defer test_io.deinit();
            std.testing.io = test_io.tio;
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
            const stats = born_io.networkStats(test_io.tio);
            if (testRouteProof(stats, t.name)) |reason| {
                Printer.status(.fail, "\nteardown \"{s}\" route proof: {s}\n", .{ t.name, reason });
                return error.RouteProofFailed;
            }
            totals.add(stats);
        }
    }

    // End progress before printing summary
    if (root_node.index != .none) {
        root_node.end();
    }

    // Evaluate the route gate before the summary so the printed verdict
    // covers the whole leg (review 665 R4). The summary, networkStats and
    // route-proof lines are plain text (no ANSI): the CI jobs grep them
    // anchored.
    const gate = routeProof(&totals);
    const leg_ok = fail == 0 and gate == null;
    Printer.fmt("\n{d} passed; {d} skipped; {d} failed.\n", .{ pass, skip, fail });
    if (failed_tests.items.len > 0) {
        Printer.fmt("\n", .{});
        Printer.fmt("Failed tests:\n", .{});
        for (failed_tests.items) |name| {
            Printer.fmt("  {s}\n", .{name});
        }
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    Printer.fmt("networkStats: born connect={d} read={d} write={d}; threaded connect={d} read={d} write={d}\n", .{
        totals.born_connect,     totals.born_read,     totals.born_write,
        totals.threaded_connect, totals.threaded_read, totals.threaded_write,
    });
    if (gate) |reason| {
        Printer.fmt("route proof: FAIL: {s}\n", .{reason});
    } else {
        Printer.fmt("route proof: PASS\n", .{});
    }
    std.process.exit(if (leg_ok) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    started: Io.Clock.Timestamp,

    fn init(io: Io, count: u32) SlowTracker {
        return .{
            .max = count,
            .started = .now(io, .awake),
            .slowest = SlowestQueue.initContext({}),
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker, allocator: Allocator) void {
        self.slowest.deinit(allocator);
    }

    fn startTiming(self: *SlowTracker, io: Io) void {
        self.started = .now(io, .awake);
    }

    fn endTiming(self: *SlowTracker, io: Io, allocator: Allocator, test_name: []const u8) u64 {
        const now = Io.Clock.Timestamp.now(io, .awake);
        const ns: u64 = @intCast(self.started.durationTo(now).raw.nanoseconds);

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin();
        slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    const Verbose = enum { off, naming, tracing };

    verbose: Verbose,
    fail_first: bool,
    filters: std.ArrayList([]const u8),
    do_log_capture: bool,
    route_trace: bool,

    fn init(allocator: Allocator, environ_map: *std.process.Environ.Map) Env {
        var filters: std.ArrayList([]const u8) = .empty;

        if (environ_map.get("TEST_FILTER")) |filter_str| {
            var iter = std.mem.splitScalar(u8, filter_str, '|');
            while (iter.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len > 0) {
                    const owned = allocator.dupe(u8, trimmed) catch @panic("OOM");
                    filters.append(allocator, owned) catch @panic("OOM");
                }
            }
        }

        return .{
            .verbose = readEnvVerbose(environ_map),
            .fail_first = readEnvBool(environ_map, "TEST_FAIL_FIRST", false),
            .filters = filters,
            .do_log_capture = readEnvBool(environ_map, "TEST_LOG_CAPTURE", true),
            .route_trace = readEnvBool(environ_map, "TEST_ROUTE_TRACE", false),
        };
    }

    fn deinit(self: *Env, allocator: Allocator) void {
        for (self.filters.items) |f| {
            allocator.free(f);
        }
        self.filters.deinit(allocator);
    }

    fn readEnvBool(environ_map: *std.process.Environ.Map, key: []const u8, deflt: bool) bool {
        const value = environ_map.get(key) orelse return deflt;
        return std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "1");
    }

    fn readEnvVerbose(environ_map: *std.process.Environ.Map) Verbose {
        const value = environ_map.get("TEST_VERBOSE") orelse return .off;
        if (std.ascii.eqlIgnoreCase(value, "2")) return .tracing;
        if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "1")) return .naming;
        return .off;
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isPerTestSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeEach");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
