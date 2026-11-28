//! born.io: a `std.Io` compatibility shim over Born's event port.
//!
//! This module is an isolated compatibility layer. It imports the `born` core
//! module; the core never imports it. It is exported only on Zig >= 0.16,
//! where `std.Io` exists, and it makes no change to the core API.
//!
//! The shim composes Born's reactor with upstream's `Io.Threaded` worker pool
//! behind one `std.Io`. Capability routing is explicit and compile-time
//! visible: each family is serviced either by Born's event port or by
//! Threaded, and an unimplemented route is rejected at construction rather
//! than silently falling back.
//!
//! The all-Threaded baseline delegates every vtable slot to Threaded through
//! forwarding thunks. With `capabilities.network = .born_evented` the network client
//! path (IP and pathname Unix connect, stream read/write, close, shutdown) runs
//! on Born; listen/accept, DNS and message I/O stay Threaded hybrids or declared
//! exclusions. With `capabilities.process = .born_evented` on FreeBSD or Linux
//! the process family (`processSpawn`, `childWait`, `childKill`) runs on Born
//! through process descriptors / pidfds; other targets reject the capability at
//! construction. The time family (`sleep`, `now`, `clockResolution`) always
//! stays on Threaded. Every other slot keeps delegating.
//!
//! Removal is `git rm -r src/io` plus the conditional export lines in
//! `build.zig`; nothing in the core depends on this module.

const std = @import("std");
const born = @import("born");

const assert = @import("assert.zig");
const shim = @import("shim.zig");

// Enforce the pinned Io.VTable shape whenever this module is analyzed.
comptime {
    assert.verify();
}

/// Where a capability family is serviced.
pub const Route = shim.Route;
/// Explicit capability routing for the hybrid.
pub const Capabilities = shim.Capabilities;
/// Construction options for `io`.
pub const InitOptions = shim.InitOptions;
/// Construction failures, including explicit capability rejection.
pub const InitError = shim.InitError;
/// The composite carried by the single `Io.userdata` pointer.
pub const Shim = shim.Shim;

/// Builds a `std.Io` over Born's event port. Release the returned interface
/// with `deinit`. The network client route (`capabilities.network = .born_evented`)
/// and, on FreeBSD or Linux, the process route (`capabilities.process = .born_evented`)
/// are serviced by Born's reactor; the file family (no Born route exists on
/// any target) and the process family on other targets are rejected at
/// construction. The time family stays Threaded.
pub const io = shim.io;
/// Releases the composite created by `io`. Stops and joins the Born route's
/// loop thread first, then joins the Threaded pool.
pub const deinit = shim.deinit;

/// The first route-level failure latched by a Born route (wait refusal,
/// connect-deadline timer-arm refusal, slot-table growth refusal, process
/// arm/flush refusal), or null. This exposes the cause behind a refused or
/// dead route.
pub const loopError = shim.loopError;

/// Per-route network counters (Born connect/read/write completions and
/// Threaded-forward counts).
pub const NetworkStats = shim.NetworkStats;
/// Snapshot of the network route's per-route counters. Reports zeros when the
/// `network_stats` build option is off (the default).
pub const networkStats = shim.networkStats;
/// Comptime gate for the per-route network counters (`network_stats` build
/// option): off by default, enabled in the test and bench builds.
pub const network_stats_enabled = shim.network_stats_enabled;

/// Per-route process counters (Born spawn/wait/kill completions and
/// Threaded-forward counts). Child stream I/O on pipe parent ends stays
/// Threaded-serviced, so these claim only spawn/wait/kill on Born.
pub const ProcessStats = shim.ProcessStats;
/// Snapshot of the process route's per-route counters. Reports zeros when the
/// `process_stats` build option is off (the default).
pub const processStats = shim.processStats;
/// Comptime gate for the per-route process counters (`process_stats` build
/// option): off by default, enabled in the test and bench builds.
pub const process_stats_enabled = shim.process_stats_enabled;
/// Compile-time target support for the process route (FreeBSD and Linux).
pub const process_supported = shim.process_supported;

/// The complete explicit Threaded-delegation baseline vtable. To check that an
/// interface uses it, compare slot contents (`std.meta.eql`), not the address:
/// comptime-known constants have no guaranteed unique runtime address.
pub const baseline_vtable = shim.baseline_vtable;

/// The network-route vtable: the baseline with the client-path network slots
/// serviced by Born's reactor. Compare slot contents, not the address.
pub const network_vtable = shim.network_vtable;

/// The process-route vtable: the baseline with `processSpawn`, `childWait` and
/// `childKill` serviced by Born's reactor (FreeBSD and Linux). Compare slot
/// contents, not the address.
pub const process_vtable = shim.process_vtable;

/// The network and process routes active.
pub const network_process_vtable = shim.network_process_vtable;

test {
    _ = @import("assert.zig");
    _ = @import("shim.zig");
    _ = @import("shim_test.zig");
    _ = @import("net_test.zig");
    _ = @import("process_test.zig");
}

test "module exposes the pinned interface shape" {
    // Semantic analysis: the public surface and the baseline vtable must
    // type-check against the selected toolchain's std.Io.
    comptime {
        assert.verify();
        if (@TypeOf(baseline_vtable) != std.Io.VTable)
            @compileError("baseline_vtable is not an Io.VTable");
        if (@TypeOf(io) != fn (InitOptions) InitError!std.Io)
            @compileError("io constructor signature drifted");
    }
}
