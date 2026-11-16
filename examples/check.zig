//! Cross-target compile gate for the examples. Referencing every public
//! declaration forces semantic analysis of the two `main` bodies and the
//! shared engine; importing the smoke file compiles its test bodies. Built
//! as a test with no binary consumer, so each triple emits -fno-emit-bin:
//! this proves the examples compile everywhere, not that they link or run.

const std = @import("std");

test "examples compile for the selected target" {
    std.testing.refAllDecls(@import("echo_server.zig"));
    std.testing.refAllDecls(@import("thread_per_core.zig"));
    _ = @import("smoke.zig");
}
