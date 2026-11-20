// Born-owned fixture facade for the vendored nats e2e suite (design 7.2,
// adjudicated Q4). The public surface matches upstream tests/utils.zig at
// pin b8ffdd9; every helper except the provisioning pair is byte-identical
// to upstream. runDockerComposeCapture maps the bounded compose command
// surface (up -d / down / restart|stop|start <service> / ps -a --format
// "{{ .Health }}") onto native nats-server v2.15.0 child processes
// replicating docker-compose.test.yml's topology and flags.
// allServerPortsOpen probes only the seven non-TLS nodes (TLS is compiled
// out, use_tls = false); Node.unknown (14226) must stay server-free.
//
// Provisioning runs on the fixture blockingIo (Threaded): it is environment,
// not the consumer path under proof. nats client traffic stays on
// std.testing.io (born). The nats-server binary is the absolute path the
// runner publishes from NATS_SERVER (consumer_env): the fixture Threaded io
// has an empty environ, so a bare argv[0] would resolve only against
// std.Io.Threaded.default_PATH and never see the step's PATH (born#110 W1).
// Spawning the exact absolute path bypasses PATH search entirely and the
// v2.15.0 pin check covers the binary that actually runs; an unset or
// non-absolute NATS_SERVER fails loudly. The child environment is likewise
// built explicitly from the runner's environ_map (born#124): the empty io
// environ would otherwise leave the Windows nats-server without SystemRoot,
// failing every socket call with WSAEPROVIDERFAILEDINIT (10106). Server logs
// and per-node JetStream
// store directories live under .zig-cache/nats-test-store relative to the
// CWD, which must contain tests/configs (the same runtime contract as
// upstream). Store directories survive restart/stop/start; down removes them
// (review 192 carry-in 5).

const std = @import("std");
const builtin = @import("builtin");
const nats = @import("nats");
const consumer_env = @import("consumer_env");

const log = std.log.default;

/// Duration-form `std.Io.Timeout` on the awake clock, for xsync wait calls.
pub fn ioTimeout(duration: std.Io.Duration) std.Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

// Blocking `std.Io` instance for test utilities that must outlive any
// per-test io instance (server provisioning, sleeps). Lazily initialized,
// never deinitialized; lives for the whole test process.
var blocking_io_instance: ?std.Io.Threaded = null;

fn blockingIo() std.Io {
    if (blocking_io_instance == null) {
        blocking_io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return blocking_io_instance.?.io();
}

// Child environment for the spawned nats-server (born#124). blockingIo has an
// empty environ, so without an explicit environ_map the child inherits an
// empty environment block; on Windows a Go binary without SystemRoot cannot
// load Winsock providers and every socket call fails WSAEPROVIDERFAILEDINIT
// (10106). Build the child map once from the runner's published environment,
// copying only the allowlisted variables the server needs. No fallback to the
// empty io environ or the global block. Same whole-process lifetime contract
// as blockingIo: page_allocator, never deinitialized.
var child_environ_instance: ?std.process.Environ.Map = null;

fn childEnviron() !*const std.process.Environ.Map {
    if (child_environ_instance) |*map| return map;
    const runner_map = consumer_env.environMap() orelse {
        log.err("runner did not publish its environment (consumer_env.environMap is null); cannot build the nats-server child environment", .{});
        return error.EnvironMapUnset;
    };
    var map = std.process.Environ.Map.init(std.heap.page_allocator);
    // Map.put copies keys and values; Windows key lookup is case-insensitive.
    const allowlist = [_][]const u8{ "SystemRoot", "TEMP", "TMP" };
    for (allowlist) |key| {
        if (runner_map.get(key)) |value| try map.put(key, value);
    }
    if (comptime builtin.os.tag == .windows) {
        if (map.get("SystemRoot") == null) {
            log.err("child environment lacks SystemRoot; nats-server would fail every socket call with WSAEPROVIDERFAILEDINIT (10106); the runner environment must carry SystemRoot", .{});
            return error.SystemRootMissing;
        }
        inline for (.{ "TEMP", "TMP" }) |key| {
            if (map.get(key) == null) {
                log.err("child environment lacks {s}; the Windows nats-server child environment is incomplete", .{key});
                return error.ChildEnvironIncomplete;
            }
        }
    }
    child_environ_instance = map;
    return &child_environ_instance.?;
}

pub const Node = enum(u16) {
    node1 = 14222,
    node2 = 14223,
    node3 = 14224,
    token_auth = 14225,
    unknown = 14226,
    user_pass = 14227,
    nkey_auth = 14228,
    jwt_auth = 14229,
    tls = 14230,
    tls_first = 14231,
    tls_mtls = 14232,
};

pub fn createConnection(io: std.Io, node: Node, opts: nats.ConnectionOptions) !*nats.Connection {
    const port = @intFromEnum(node);
    const url = try std.fmt.allocPrint(std.testing.allocator, "nats://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(url);

    return createConnectionWithUrl(io, url, opts);
}

pub fn createConnectionWithUrl(io: std.Io, url: []const u8, opts: nats.ConnectionOptions) !*nats.Connection {
    var conn = try std.testing.allocator.create(nats.Connection);
    errdefer std.testing.allocator.destroy(conn);

    conn.* = nats.Connection.init(std.testing.allocator, io, opts);
    errdefer conn.deinit();

    try conn.connect(url);

    return conn;
}

pub fn createDefaultConnection(io: std.Io) !*nats.Connection {
    return createConnection(io, .node1, .{});
}

pub fn createConnectionWrongPort(io: std.Io) !*nats.Connection {
    return createConnection(io, .unknown, .{});
}

pub fn closeConnection(conn: *nats.Connection) void {
    conn.deinit();
    std.testing.allocator.destroy(conn);
}

pub fn runDockerComposeCapture(allocator: std.mem.Allocator, compose_args: []const []const u8) !std.process.RunResult {
    if (compose_args.len == 2 and std.mem.eql(u8, compose_args[0], "up") and std.mem.eql(u8, compose_args[1], "-d")) {
        try provisionUp(allocator);
        return okResult(allocator);
    }
    if (compose_args.len == 1 and std.mem.eql(u8, compose_args[0], "down")) {
        try provisionDown();
        return okResult(allocator);
    }
    if (compose_args.len == 2 and std.mem.eql(u8, compose_args[0], "restart")) {
        try restartService(allocator, compose_args[1]);
        return okResult(allocator);
    }
    if (compose_args.len == 2 and std.mem.eql(u8, compose_args[0], "stop")) {
        try stopService(compose_args[1]);
        return okResult(allocator);
    }
    if (compose_args.len == 2 and std.mem.eql(u8, compose_args[0], "start")) {
        try startService(allocator, compose_args[1]);
        return okResult(allocator);
    }
    if (compose_args.len == 4 and
        std.mem.eql(u8, compose_args[0], "ps") and
        std.mem.eql(u8, compose_args[1], "-a") and
        std.mem.eql(u8, compose_args[2], "--format") and
        std.mem.eql(u8, compose_args[3], "{{ .Health }}"))
    {
        const stdout = try healthReport(allocator);
        errdefer allocator.free(stdout);
        const stderr = try allocator.dupe(u8, "");
        return .{ .term = .{ .exited = 0 }, .stdout = stdout, .stderr = stderr };
    }
    log.err("unsupported compose command surface: {s}", .{compose_args[0]});
    return error.UnsupportedComposeCommand;
}

pub fn runDockerCompose(allocator: std.mem.Allocator, compose_args: []const []const u8) !void {
    const result = try runDockerComposeCapture(allocator, compose_args);
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
}

pub fn waitForHealthyServices(allocator: std.mem.Allocator, timeout: std.Io.Duration) !void {
    const io = blockingIo();
    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        if (start.untilNow(io, .awake).nanoseconds > timeout.nanoseconds) {
            // Surface the last probe state per service so a timeout names
            // the server, stage and error instead of hiding the cause.
            log.err("services not healthy within {d} ms; last probe state per service:", .{@divTrunc(timeout.nanoseconds, std.time.ns_per_ms)});
            for (services, 0..) |svc, i| {
                log.err("  {s} (client {d}, monitor {d}): spawned={}, client_connect={s}, healthz={s}, healthz_stage={s}", .{
                    svc.name,
                    svc.client_port,
                    svc.monitor_port,
                    children[i] != null,
                    if (port_last_err[i]) |e| @errorName(e) else "open",
                    if (healthz_last[i]) |h| @errorName(h.err) else "ok",
                    if (healthz_last[i]) |h| @tagName(h.stage) else "-",
                });
            }
            return error.ServicesNotHealthy;
        }

        // Check service health status; one line per service, no header.
        const result = try runDockerComposeCapture(allocator, &.{ "ps", "-a", "--format", "{{ .Health }}" });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // Count service health states in the output; require every service
        // to be healthy, so that a server restarted by a previous test
        // cannot slip through while it is still coming up.
        var healthy_count: u32 = 0;
        var total_count: u32 = 0;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            total_count += 1;
            if (std.mem.eql(u8, trimmed, "healthy")) {
                healthy_count += 1;
            }
        }

        // Probe the client ports every round, even while healthz is still
        // failing, so the timeout diagnostics cover every service.
        const ports_open = allServerPortsOpen(io);
        if (total_count > 0 and healthy_count == total_count and ports_open) {
            return;
        }

        blockingIo().sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

/// Last probe failure per provisioned service, surfaced by
/// waitForHealthyServices on timeout. Probe control flow never branches on
/// error identity: any connect failure means "not open yet", so the Zig
/// 0.16.0 Threaded Windows refusal mapping (CONNECTION_REFUSED 0xC0000236
/// -> error.Unexpected, fixed in 0.17.1; tracked in born#118) cannot change
/// probe behavior. Refusals during startup are expected on every platform;
/// the recorded error names only feed the timeout diagnostics.
const HealthzStage = enum { connect, write, read };
var port_last_err: [services.len]?anyerror = @splat(null);
var healthz_last: [services.len]?struct { stage: HealthzStage, err: anyerror } = @splat(null);

/// Probe order matches the services array (asserted below).
const probe_nodes = [_]Node{ .node1, .node2, .node3, .token_auth, .user_pass, .nkey_auth, .jwt_auth };
comptime {
    std.debug.assert(probe_nodes.len == services.len);
    for (probe_nodes, 0..) |node, i| {
        std.debug.assert(@intFromEnum(node) == services[i].client_port);
    }
}

/// Docker reporting a container healthy is not the same as the NATS client
/// port accepting connections; probe the real thing so a test never starts
/// against a server that is still coming up. Facade difference: the three
/// TLS nodes are not provisioned (use_tls = false), so only the seven
/// non-TLS nodes are probed. Node.unknown is intentionally absent: it must
/// stay server-free for the wrong-port tests. Every node is probed each
/// round (no short-circuit) so the timeout diagnostics cover all ports.
fn allServerPortsOpen(io: std.Io) bool {
    var all_open = true;
    for (probe_nodes, 0..) |node, i| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(@intFromEnum(node)) };
        const stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
            port_last_err[i] = err;
            all_open = false;
            continue;
        };
        port_last_err[i] = null;
        stream.close(io);
    }
    return all_open;
}

/// Publish into a JetStream stream and wait for the PubAck, so the message
/// is durably stored before the test goes on to read stream state. A core
/// publish + flush only confirms the connected server processed the message;
/// in a cluster the stream may not have stored it yet.
pub fn jsPublish(js: *nats.JetStream, subject: []const u8, data: []const u8) !void {
    var result = try js.publish(subject, data, .{});
    result.deinit();
}

var global_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn generateUniqueName(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const timestamp = @divTrunc(std.Io.Timestamp.now(blockingIo(), .real).nanoseconds, std.time.ns_per_us);
    const counter = global_counter.fetchAdd(1, .monotonic);

    return std.fmt.allocPrint(allocator, "{s}_{d}_{d}", .{ prefix, timestamp, counter });
}

pub fn generateUniqueStreamName(allocator: std.mem.Allocator) ![]u8 {
    return generateUniqueName(allocator, "TEST_STREAM");
}

pub fn generateUniqueConsumerName(allocator: std.mem.Allocator) ![]u8 {
    return generateUniqueName(allocator, "TEST_CONSUMER");
}

pub fn generateSubjectFromStreamName(allocator: std.mem.Allocator, stream_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.*", .{stream_name});
}

// ---------------------------------------------------------------------------
// Native provisioning (facade-only; replaces the docker compose machinery).
// ---------------------------------------------------------------------------

const store_root = ".zig-cache/nats-test-store";
const pinned_version = "nats-server: v2.15.0";

const Service = struct {
    name: []const u8,
    client_port: u16,
    monitor_port: u16,
    /// Cluster route port, when the service joins the NATS_TEST cluster.
    cluster_port: ?u16 = null,
    /// Flags after argv[0], in docker-compose.test.yml order.
    argv: []const []const u8,
    /// JetStream node: append a per-node -sd store directory.
    store: bool,
};

const services = [_]Service{
    .{
        .name = "nats-1",
        .client_port = 14222,
        .monitor_port = 18222,
        .cluster_port = 16222,
        .argv = &.{
            "--cluster_name", "NATS_TEST",
            "--cluster",      "nats://127.0.0.1:16222",
            "--routes",       "nats://127.0.0.1:16223,nats://127.0.0.1:16224",
            "--addr",         "127.0.0.1",
            "--port",         "14222",
            "--http_port",    "18222",
            "--js",           "-D",
            "--server_name",  "nats-1",
        },
        .store = true,
    },
    .{
        .name = "nats-2",
        .client_port = 14223,
        .monitor_port = 18223,
        .cluster_port = 16223,
        .argv = &.{
            "--cluster_name", "NATS_TEST",
            "--cluster",      "nats://127.0.0.1:16223",
            "--routes",       "nats://127.0.0.1:16222,nats://127.0.0.1:16224",
            "--addr",         "127.0.0.1",
            "--port",         "14223",
            "--http_port",    "18223",
            "--js",           "-D",
            "--server_name",  "nats-2",
        },
        .store = true,
    },
    .{
        .name = "nats-3",
        .client_port = 14224,
        .monitor_port = 18224,
        .cluster_port = 16224,
        .argv = &.{
            "--cluster_name", "NATS_TEST",
            "--cluster",      "nats://127.0.0.1:16224",
            "--routes",       "nats://127.0.0.1:16222,nats://127.0.0.1:16223",
            "--addr",         "127.0.0.1",
            "--port",         "14224",
            "--http_port",    "18224",
            "--js",           "-D",
            "--server_name",  "nats-3",
        },
        .store = true,
    },
    .{
        .name = "nats-token-auth",
        .client_port = 14225,
        .monitor_port = 18225,
        .argv = &.{
            "--addr",          "127.0.0.1",
            "--port",          "14225",
            "--http_port",     "18225",
            "--auth",          "test_token_123",
            "-D",              "--server_name",
            "nats-token-auth",
        },
        .store = false,
    },
    .{
        .name = "nats-user-pass",
        .client_port = 14227,
        .monitor_port = 18227,
        .argv = &.{
            "--addr",         "127.0.0.1",
            "--port",         "14227",
            "--http_port",    "18227",
            "--user",         "test_user",
            "--pass",         "test_password",
            "-D",             "--server_name",
            "nats-user-pass",
        },
        .store = false,
    },
    .{
        .name = "nats-nkey-auth",
        .client_port = 14228,
        .monitor_port = 18228,
        .argv = &.{ "--config", "tests/configs/nkey.conf", "-D" },
        .store = false,
    },
    .{
        .name = "nats-jwt-auth",
        .client_port = 14229,
        .monitor_port = 18229,
        .argv = &.{ "--config", "tests/configs/jwt.conf", "-D" },
        .store = false,
    },
};

// Client, monitor and cluster ports of the provisioned topology, plus the
// wrong-port node: all must be free before provisioning (a stale server
// from a crashed run must not be silently reused).
const required_free_ports = [_]u16{
    14222, 14223, 14224, 14225, 14226, 14227, 14228, 14229,
    16222, 16223, 16224, 18222, 18223, 18224, 18225, 18227,
    18228, 18229,
};

var children = [_]?std.process.Child{ null, null, null, null, null, null, null };
var version_checked = false;

fn okResult(allocator: std.mem.Allocator) !std.process.RunResult {
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, "");
    return .{ .term = .{ .exited = 0 }, .stdout = stdout, .stderr = stderr };
}

fn serviceIndex(name: []const u8) !usize {
    for (services, 0..) |svc, i| {
        if (std.mem.eql(u8, svc.name, name)) return i;
    }
    log.err("unknown compose service: {s}", .{name});
    return error.UnknownService;
}

/// The pinned nats-server binary as an absolute path (born#110 W1). The
/// fixture Threaded io has an empty environ, so a bare name would resolve
/// only against default_PATH; spawning the exact absolute path bypasses PATH
/// search. Fail loudly when NATS_SERVER is unset or not absolute rather than
/// silently picking up some other nats-server.
fn serverBinary() ![]const u8 {
    const path = consumer_env.natsServer() orelse {
        log.err("NATS_SERVER is not set; export the absolute path of the pinned nats-server v2.15.0 binary (the fixture spawns it directly, no PATH search)", .{});
        return error.NatsServerUnset;
    };
    if (!std.fs.path.isAbsolute(path)) {
        log.err("NATS_SERVER must be an absolute path, got '{s}' (a relative or bare name could resolve to the wrong binary)", .{path});
        return error.NatsServerNotAbsolute;
    }
    return path;
}

fn checkServerVersion(allocator: std.mem.Allocator) !void {
    if (version_checked) return;
    const bin = try serverBinary();
    const argv = [_][]const u8{ bin, "--version" };
    const result = std.process.run(allocator, blockingIo(), .{
        .argv = &argv,
        .environ_map = try childEnviron(),
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| {
        log.err("cannot run '{s} --version' ({s}); is the pinned v2.15.0 binary present at NATS_SERVER?", .{ bin, @errorName(err) });
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, pinned_version)) {
        log.err("nats-server pin mismatch: expected '{s}', got '{s}'", .{ pinned_version, trimmed });
        return error.NatsServerVersionMismatch;
    }
    version_checked = true;
}

/// A loopback connect that succeeds means the port is occupied; refusal is
/// immediate on loopback. No connect timeout: Io.Threaded's connect panics
/// on a non-none timeout on both POSIX and Windows (0.16 and 0.17.1), and
/// a listening server accepts promptly while spawn fails with AddressInUse
/// if a stale server holds the port.
fn portFree(io: std.Io, port: u16) bool {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = address.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch return true;
    stream.close(io);
    return false;
}

/// Host-global e2e suite lock (#118). The e2e topology binds fixed loopback
/// ports (14222-14229, monitors 18222+), a host-global resource. Forgejo does
/// not enforce strategy.max-parallel, so matrix legs and overlapping
/// dispatches run concurrently on one runner host; without arbitration a
/// leg's beforeAll sees a sibling leg's servers and fails with PortsNotFree.
/// The lock is held from `up -d` (provisionUp) to `down` (provisionDown),
/// serializing whole suites on the host. The kernel releases it when the
/// holder exits, so a crashed or cancelled leg cannot wedge the host.
/// stopAll's Child.kill reaps each server (Threaded childKill waits for
/// exit), so the ports are free before the lock changes hands. Linux legs
/// run in per-job containers with private network namespaces and a private
/// /tmp, so the lock never contends there.
///
/// The wait is bounded well under the 30-minute suite job timeout (review
/// 694): a stuck holder fails the leg with a named error instead of hanging
/// it until the job timeout. Acquisition logs a line so a run shows whether
/// the lock was taken (on Windows this also proves the Global\ namespace
/// privilege, since CreateMutexW there would otherwise fail).
const suite_lock = if (builtin.os.tag == .windows) struct {
    // A named mutex in the Global namespace is host-wide across job
    // sessions; like flock it is released by the kernel on holder death.
    // WAIT_ABANDONED still grants ownership (the previous holder died).
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\born-nats-e2e-suite");
    const wait_limit_ms: u32 = 15 * 60 * 1000; // 900 s, half the job timeout
    const wait_object_0: u32 = 0x0;
    const wait_abandoned: u32 = 0x80;
    const wait_timeout: u32 = 258;
    const wait_failed: u32 = 0xFFFFFFFF;

    extern "kernel32" fn CreateMutexW(attrs: ?*anyopaque, initial_owner: c_int, mutex_name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn ReleaseMutex(handle: *anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;

    var mutex: ?*anyopaque = null;

    fn logWin32(comptime what: []const u8, e: std.os.windows.Win32Error) void {
        log.err("{s} for the e2e suite lock (Global\\born-nats-e2e-suite): {s} ({d})", .{
            what,
            std.enums.tagName(std.os.windows.Win32Error, e) orelse "unknown",
            @intFromEnum(e),
        });
    }

    fn acquire() !void {
        if (mutex != null) return;
        const h = CreateMutexW(null, 0, name) orelse {
            logWin32("CreateMutexW failed", std.os.windows.GetLastError());
            return error.SuiteLockCreateFailed;
        };
        errdefer _ = CloseHandle(h);
        const status = WaitForSingleObject(h, 0);
        if (status == wait_failed) {
            logWin32("WaitForSingleObject failed", std.os.windows.GetLastError());
            return error.SuiteLockWaitFailed;
        }
        if (status != wait_object_0 and status != wait_abandoned) {
            log.info("e2e ports held by another suite; waiting on the suite lock", .{});
            const waited = WaitForSingleObject(h, wait_limit_ms);
            switch (waited) {
                wait_object_0, wait_abandoned => {},
                wait_timeout => {
                    log.err("e2e suite lock wait timed out after {d} ms: Global\\born-nats-e2e-suite", .{wait_limit_ms});
                    return error.SuiteLockTimeout;
                },
                else => {
                    logWin32("WaitForSingleObject failed", std.os.windows.GetLastError());
                    return error.SuiteLockWaitFailed;
                },
            }
        }
        mutex = h;
        log.info("e2e suite lock acquired (Global\\born-nats-e2e-suite)", .{});
    }

    fn release() void {
        if (mutex) |h| {
            _ = ReleaseMutex(h);
            _ = CloseHandle(h);
            mutex = null;
        }
    }
} else struct {
    // Same-user CI jobs share the file; 0666 keeps it openable if the runner
    // account changes. flock is per open-file-description, so a second
    // acquire in this process would also succeed; the guard keeps one hold.
    const path = "/tmp/born-nats-e2e.lock";
    const wait_limit_ns: i96 = 15 * std.time.ns_per_min; // 900 s, half the job timeout

    var lock_fd: ?std.posix.fd_t = null;

    fn acquire() !void {
        if (lock_fd != null) return;
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o666);
        // flockBounded owns fd on every error path: it closes fd unless it
        // detached a helper that may still acquire on it (the kernel then
        // releases the lock when this process exits).
        try flockBounded(fd, path, wait_limit_ns);
        lock_fd = fd;
        log.info("e2e suite lock acquired ({s})", .{path});
    }

    fn release() void {
        if (lock_fd) |fd| {
            _ = std.c.flock(fd, std.c.LOCK.UN);
            _ = std.c.close(fd);
            lock_fd = null;
        }
    }

    fn monoNowNs() i96 {
        var ts: std.c.timespec = undefined;
        switch (std.posix.errno(std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts))) {
            .SUCCESS => return @as(i96, ts.sec) * std.time.ns_per_s + ts.nsec,
            else => unreachable, // CLOCK_MONOTONIC cannot fail
        }
    }

    // Heap-allocated: on timeout or a futex wait error the helper is detached
    // and may outlive the call frame. done: 0 pending, 1 acquired, 2 failed;
    // err is written before the release store of done.
    const WaitState = struct {
        fd: std.posix.fd_t,
        io: std.Io,
        err: std.c.E = .SUCCESS,
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };

    fn lockHelper(st: *WaitState) void {
        while (true) {
            switch (std.posix.errno(std.c.flock(st.fd, std.c.LOCK.EX))) {
                .SUCCESS => {
                    st.done.store(1, .release);
                    std.Io.futexWake(st.io, u32, &st.done.raw, 1);
                    return;
                },
                .INTR => continue, // retry; the caller's deadline bounds the wait
                else => |e| {
                    st.err = e;
                    st.done.store(2, .release);
                    std.Io.futexWake(st.io, u32, &st.done.raw, 1);
                    return;
                },
            }
        }
    }

    /// Bounded exclusive flock, no signals (review 697): a process-directed
    /// alarm can land on any thread that does not block it, including the
    /// fixture's long-lived Threaded workers, leaving the flock uninterruptible
    /// and EINTR-ing unrelated syscalls. A non-blocking try first; on
    /// contention a helper thread blocks in flock(2) (a kernel lock wait, not
    /// a sleep loop) and reports through a futex word, while the caller waits
    /// on that word against a CLOCK_MONOTONIC deadline. On timeout or a futex
    /// wait error the helper is detached and its state and fd are intentionally
    /// leaked: if it later acquires, the kernel releases the lock when this
    /// process exits. The caller is a failed leg about to exit, so the hold is
    /// bounded by the process lifetime. On every other error no helper is live
    /// and fd is closed here; the caller owns fd only on success.
    fn flockBounded(fd: std.posix.fd_t, label: []const u8, limit_ns: i96) !void {
        switch (std.posix.errno(std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB))) {
            .SUCCESS => return,
            .AGAIN => {}, // EWOULDBLOCK == EAGAIN on both Linux and FreeBSD
            else => |e| {
                _ = std.c.close(fd);
                log.err("flock({s}) failed: {s}", .{ label, std.enums.tagName(std.posix.E, e) orelse "unknown" });
                return error.SuiteLockFailed;
            },
        }
        log.info("e2e ports held by another suite; waiting on the suite lock ({s})", .{label});

        const st = std.heap.page_allocator.create(WaitState) catch {
            _ = std.c.close(fd);
            return error.SuiteLockFailed;
        };
        st.* = .{ .fd = fd, .io = blockingIo() };
        const th = std.Thread.spawn(.{}, lockHelper, .{st}) catch |err| {
            std.heap.page_allocator.destroy(st);
            _ = std.c.close(fd);
            log.err("suite lock helper spawn ({s}) failed: {s}", .{ label, @errorName(err) });
            return error.SuiteLockFailed;
        };

        const deadline = monoNowNs() + limit_ns;
        while (true) {
            const w = st.done.load(.acquire);
            if (w != 0) {
                th.join();
                const e = st.err;
                std.heap.page_allocator.destroy(st);
                if (w == 1) return;
                _ = std.c.close(fd);
                log.err("flock({s}) failed while waiting: {s}", .{ label, std.enums.tagName(std.posix.E, e) orelse "unknown" });
                return error.SuiteLockFailed;
            }
            const remaining = deadline - monoNowNs();
            if (remaining <= 0) {
                th.detach(); // st and fd intentionally leaked; see doc comment
                log.err("e2e suite lock wait timed out after {d} s: {s}", .{ @divTrunc(limit_ns, std.time.ns_per_s), label });
                return error.SuiteLockTimeout;
            }
            // futexWaitTimeout returns normally on wake AND on timeout; the
            // loop re-checks the word and the deadline (spurious wakes too).
            // On error (e.g. Canceled) detach as on timeout: the helper may
            // still acquire, so st and fd stay with the kernel until exit.
            std.Io.futexWaitTimeout(st.io, u32, &st.done.raw, 0, ioTimeout(std.Io.Duration.fromNanoseconds(remaining))) catch |err| {
                th.detach();
                log.err("suite lock futex wait ({s}) failed: {s}", .{ label, @errorName(err) });
                return error.SuiteLockFailed;
            };
        }
    }
};

/// Bounded-wait regression for the suite lock (#118, review 694 point 2).
/// POSIX-only: a named Windows mutex is recursive per thread, so an
/// in-process holder cannot contend with itself; the Windows bounded wait is
/// exercised by the Windows CI legs instead. Uses a throwaway lock file, not
/// the suite lock path, which provisionUp holds for the whole suite.
const suite_lock_wait_test = if (builtin.os.tag == .windows) struct {
    fn run() !void {
        return error.SkipZigTest;
    }
} else struct {
    fn run() !void {
        const allocator = std.testing.allocator;
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/born-nats-e2e-lock-test-{d}", .{std.c.getpid()});
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        // Two independent open file descriptions on one file: flock is per
        // OFD, so the holder's exclusive lock contends with the target fd.
        const holder = try std.posix.openat(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
        defer _ = std.c.close(holder);
        defer _ = std.c.unlinkat(std.posix.AT.FDCWD, path_z, 0);
        if (std.c.flock(holder, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return error.Unexpected;

        const target = try std.posix.openat(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0o600);
        defer _ = std.c.close(target);

        // Contended: the bounded wait must time out (helper thread + futex
        // deadline), not block forever. The timed-out helper is detached and
        // may still acquire on the target's OFD after the holder releases.
        try std.testing.expectError(error.SuiteLockTimeout, suite_lock.flockBounded(target, path, 300 * std.time.ns_per_ms));

        // Release the holder; the same fd now acquires. flock does not
        // self-contend within one OFD, so this succeeds whether or not the
        // detached helper got there first.
        if (std.c.flock(holder, std.c.LOCK.UN) != 0) return error.Unexpected;
        try suite_lock.flockBounded(target, path, 300 * std.time.ns_per_ms);
        if (std.c.flock(target, std.c.LOCK.UN) != 0) return error.Unexpected;
    }
};

test "suite lock: bounded wait times out, then acquires (#118)" {
    try suite_lock_wait_test.run();
}

fn provisionUp(allocator: std.mem.Allocator) !void {
    try suite_lock.acquire();
    errdefer suite_lock.release();
    try checkServerVersion(allocator);
    const io = blockingIo();
    for (required_free_ports) |port| {
        if (!portFree(io, port)) {
            log.err("port {d} is not free before provisioning (stale nats-server?)", .{port});
            return error.PortsNotFree;
        }
    }
    const cwd = std.Io.Dir.cwd();
    // Fresh per-run store: a crashed previous run must not leak state.
    // deleteTree is a silent no-op when the path does not exist.
    try cwd.deleteTree(io, store_root);
    try cwd.createDirPath(io, store_root);
    for (services) |svc| {
        if (!svc.store) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_root, svc.name });
        defer allocator.free(path);
        try cwd.createDirPath(io, path);
    }
    @memset(&port_last_err, null);
    @memset(&healthz_last, null);
    errdefer stopAll();
    for (services, 0..) |_, i| try spawnService(allocator, i);
}

fn provisionDown() !void {
    defer suite_lock.release();
    stopAll();
    // deleteTree is a silent no-op when the path does not exist.
    try std.Io.Dir.cwd().deleteTree(blockingIo(), store_root);
}

fn stopAll() void {
    const io = blockingIo();
    for (&children) |*slot| {
        if (slot.*) |*child| {
            child.kill(io);
            slot.* = null;
        }
    }
}

fn stopService(name: []const u8) !void {
    const idx = try serviceIndex(name);
    if (children[idx]) |*child| {
        child.kill(blockingIo());
        children[idx] = null;
    }
}

fn startService(allocator: std.mem.Allocator, name: []const u8) !void {
    const idx = try serviceIndex(name);
    if (children[idx] != null) return; // docker start on a running service is a no-op
    try spawnService(allocator, idx);
}

fn restartService(allocator: std.mem.Allocator, name: []const u8) !void {
    const idx = try serviceIndex(name);
    if (children[idx]) |*child| {
        child.kill(blockingIo());
        children[idx] = null;
    }
    // The store directory is preserved: JetStream state survives the
    // restart the way the compose container filesystem does.
    try spawnService(allocator, idx);
}

fn spawnService(allocator: std.mem.Allocator, idx: usize) !void {
    const svc = services[idx];
    const io = blockingIo();
    // Every port the service binds (client, monitor, cluster) must be free
    // before a (re)spawn is reported healthy (carry-in 5): a stale instance
    // can still hold the monitor or cluster port after the client port frees.
    var ports_buf: [3]u16 = .{ svc.client_port, svc.monitor_port, 0 };
    var port_count: usize = 2;
    if (svc.cluster_port) |port| {
        ports_buf[2] = port;
        port_count = 3;
    }
    for (ports_buf[0..port_count]) |port| {
        if (!portFree(io, port)) {
            log.err("port {d} ({s}) is not free before spawn", .{ port, svc.name });
            return error.PortNotFree;
        }
    }

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = try serverBinary();
    argc += 1;
    for (svc.argv) |arg| {
        argv_buf[argc] = arg;
        argc += 1;
    }
    var store_path: ?[]u8 = null;
    defer if (store_path) |p| allocator.free(p);
    if (svc.store) {
        store_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_root, svc.name });
        argv_buf[argc] = "-sd";
        argc += 1;
        argv_buf[argc] = store_path.?;
        argc += 1;
    }
    std.debug.assert(argc <= argv_buf.len);

    const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ store_root, svc.name });
    defer allocator.free(log_path);
    // Append across (re)spawns so a restart keeps the whole server sequence
    // for post-mortem. The Io file API has no O_APPEND or seek: rewrite the
    // previous bytes, then the child's stderr continues after them (the
    // spawned stderr dup shares this handle's file offset).
    const previous = std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (previous) |bytes| allocator.free(bytes);
    const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    if (previous) |bytes| {
        var wbuf: [4096]u8 = undefined;
        var writer = log_file.writer(io, &wbuf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }
    const child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .environ_map = try childEnviron(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = log_file },
    });
    log_file.close(io);
    children[idx] = child;
}

/// Emulates `docker compose ps -a --format "{{ .Health }}"`: one health line
/// per service, no header. A service is healthy when its monitor /healthz
/// answers 200 (the compose healthcheck probe).
fn healthReport(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (services, 0..) |_, i| {
        const state: []const u8 = if (children[i] == null)
            "exited"
        else if (healthzOk(i))
            "healthy"
        else
            "starting";
        try out.writer.print("{s}\n", .{state});
    }
    return try allocator.dupe(u8, out.written());
}

fn healthzOk(idx: usize) bool {
    const io = blockingIo();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(services[idx].monitor_port) };
    const stream = address.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch |err| {
        healthz_last[idx] = .{ .stage = .connect, .err = err };
        return false;
    };
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    writer.interface.writeAll("GET /healthz HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n") catch |err| {
        healthz_last[idx] = .{ .stage = .write, .err = err };
        return false;
    };
    writer.interface.flush() catch |err| {
        healthz_last[idx] = .{ .stage = .write, .err = err };
        return false;
    };

    // readSliceShort fills the destination or reads to end of stream; it
    // does not return early on the first available bytes. The monitor
    // answers the HTTP/1.0 request and closes, so this returns the response
    // head at EOF. The destination must not alias the reader's own buffer.
    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var head_buf: [512]u8 = undefined;
    const n = reader.interface.readSliceShort(&head_buf) catch |err| {
        healthz_last[idx] = .{ .stage = .read, .err = err };
        return false;
    };
    const head = head_buf[0..n];
    const ok = std.mem.startsWith(u8, head, "HTTP/1.0 200") or std.mem.startsWith(u8, head, "HTTP/1.1 200");
    healthz_last[idx] = if (ok) null else .{ .stage = .read, .err = error.BadHealthzResponse };
    return ok;
}
