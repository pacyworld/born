const std = @import("std");

// Regression fixture for the back-edge isolation gate: a downstream consumer
// path-depends on born and uses std.Io in its own sources. born's build() runs
// in this process, so the gate must scan born's tree (via the build root), not
// the consumer's working directory, and must skip entirely when born is not the
// root package. If the gate regresses to scanning cwd, this build panics.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const born = b.dependency("born", .{}).module("born");

    const exe = b.addExecutable(.{
        .name = "born-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "born", .module = born }},
        }),
    });
    b.installArtifact(exe);
}
