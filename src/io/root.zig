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
//! forwarding thunks. With `capabilities.time = .born_evented` the time family
//! (`sleep`, monotonic `now`) runs on Born's reactor through the Scale model
//! machinery; every other slot keeps delegating. Later increments enable the
//! remaining families.
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
/// with `deinit`. The time route (`capabilities.time = .born_evented`) is
/// serviced by Born's reactor; Born routes for the other families are still
/// rejected at construction.
pub const io = shim.io;
/// Releases the composite created by `io`, joining the Threaded pool and the
/// time route's loop thread.
pub const deinit = shim.deinit;

/// The complete explicit Threaded-delegation baseline vtable. To check that an
/// interface uses it, compare slot contents (`std.meta.eql`), not the address:
/// comptime-known constants have no guaranteed unique runtime address.
pub const baseline_vtable = shim.baseline_vtable;

/// The time-route vtable: the baseline with `sleep` and monotonic `now`
/// serviced by Born's reactor. Compare slot contents, not the address.
pub const time_vtable = shim.time_vtable;

test {
    _ = @import("assert.zig");
    _ = @import("shim.zig");
    _ = @import("shim_test.zig");
    _ = @import("time_test.zig");
}

test "module exposes the pinned interface shape" {
    // Semantic analysis: the public surface and the baseline vtable must
    // type-check against the selected toolchain's std.Io.
    comptime {
        assert.verify();
        if (@TypeOf(baseline_vtable) != std.Io.VTable)
            @compileError("baseline_vtable is not an Io.VTable");
        if (@TypeOf(io) != fn (*born.EvPort, InitOptions) InitError!std.Io)
            @compileError("io constructor signature drifted");
    }
}
