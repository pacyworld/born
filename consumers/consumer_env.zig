//! Narrow runtime channel for the pinned nats-server binary path (born#110
//! W1). The fixture facade spawns nats-server through a Threaded io whose
//! environ defaults to .empty, so a bare "nats-server" argv[0] resolves only
//! against std.Io.Threaded.default_PATH (/usr/local/bin:/bin/:/usr/bin) and
//! never sees the step's PATH. The runner publishes the absolute binary path
//! from NATS_SERVER once, before any test runs; the e2e facade spawns that
//! exact path. Only the e2e suite reads it; unit and http never require it.

var nats_server_path: ?[]const u8 = null;

/// Called once by the runner before any test runs. The value borrows the
/// process environment (init.environ_map), which outlives every test.
pub fn setNatsServer(path: ?[]const u8) void {
    nats_server_path = path;
}

/// The pinned nats-server binary path, or null when NATS_SERVER is unset.
pub fn natsServer() ?[]const u8 {
    return nats_server_path;
}
