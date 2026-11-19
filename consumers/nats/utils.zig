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
// std.testing.io (born). The nats-server binary is resolved from PATH by
// std.process.spawn's argv[0] resolution and version-checked against the
// v2.15.0 pin; CI prepends the pinned tarball's binary directory to PATH.
// Server logs and per-node JetStream store directories live under
// .zig-cache/nats-test-store relative to the CWD, which must contain
// tests/configs (the same runtime contract as upstream). Store directories
// survive restart/stop/start; down removes them (review 192 carry-in 5).

const std = @import("std");
const nats = @import("nats");

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

        if (total_count > 0 and healthy_count == total_count and allServerPortsOpen(io)) {
            return;
        }

        blockingIo().sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

/// Docker reporting a container healthy is not the same as the NATS client
/// port accepting connections; probe the real thing so a test never starts
/// against a server that is still coming up. Facade difference: the three
/// TLS nodes are not provisioned (use_tls = false), so only the seven
/// non-TLS nodes are probed. Node.unknown is intentionally absent: it must
/// stay server-free for the wrong-port tests.
fn allServerPortsOpen(io: std.Io) bool {
    for ([_]Node{ .node1, .node2, .node3, .token_auth, .user_pass, .nkey_auth, .jwt_auth }) |node| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(@intFromEnum(node)) };
        const stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return false;
        stream.close(io);
    }
    return true;
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

fn checkServerVersion(allocator: std.mem.Allocator) !void {
    if (version_checked) return;
    const result = std.process.run(allocator, blockingIo(), .{
        .argv = &.{ "nats-server", "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| {
        log.err("cannot run 'nats-server --version' ({s}); is the pinned v2.15.0 binary on PATH?", .{@errorName(err)});
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

fn provisionUp(allocator: std.mem.Allocator) !void {
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
    errdefer stopAll();
    for (services, 0..) |_, i| try spawnService(allocator, i);
}

fn provisionDown() !void {
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
    // Ports must be free before a (re)spawn is reported healthy (carry-in 5).
    if (!portFree(io, svc.client_port)) {
        log.err("port {d} ({s}) is not free before spawn", .{ svc.client_port, svc.name });
        return error.PortNotFree;
    }

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "nats-server";
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
    const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    const child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
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
    for (services, 0..) |svc, i| {
        const state: []const u8 = if (children[i] == null)
            "exited"
        else if (healthzOk(svc.monitor_port))
            "healthy"
        else
            "starting";
        try out.writer.print("{s}\n", .{state});
    }
    return try allocator.dupe(u8, out.written());
}

fn healthzOk(port: u16) bool {
    const io = blockingIo();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = address.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch return false;
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    writer.interface.writeAll("GET /healthz HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n") catch return false;
    writer.interface.flush() catch return false;

    // The monitor answers the status line immediately; readSliceShort
    // returns the first available bytes without waiting for a full buffer.
    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const n = reader.interface.readSliceShort(&rbuf) catch return false;
    const head = rbuf[0..n];
    return std.mem.startsWith(u8, head, "HTTP/1.0 200") or std.mem.startsWith(u8, head, "HTTP/1.1 200");
}
