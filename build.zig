const std = @import("std");

pub const supported_targets = [_][]const u8{
    "x86_64-freebsd",
    "x86_64-linux-gnu",
    "aarch64-macos",
    "x86_64-macos",
    "x86_64-windows-gnu",
    "x86_64-netbsd",
    "x86_64-openbsd",
};

pub fn build(b: *std.Build) void {
    const readme = @embedFile("README.md");
    if (std.mem.count(u8, readme, "| `") != supported_targets.len)
        @panic("README platform table must match supported_targets");
    inline for (supported_targets) |triple| {
        if (std.mem.indexOf(u8, readme, "| `" ++ triple ++ "` |") == null)
            @panic("README platform table is missing " ++ triple);
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("born", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPlatform(mod, target);

    const lib = b.addLibrary(.{
        .name = "born",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .name = "born-tests", .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the event port tests").dependOn(&run_tests.step);
    const install_tests = b.addInstallArtifact(tests, .{});
    b.step("test-bin", "Install the selected target's test executable without running it").dependOn(&install_tests.step);

    // Compile-only proof that every claimed platform still builds. Nothing is
    // run; the binaries are discarded.
    const check = b.step("check-targets", "Cross-compile every supported platform");
    for (supported_targets) |triple| {
        const q = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch @panic("bad triple");
        const cross_target = b.resolveTargetQuery(q);
        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        linkPlatform(cross_mod, cross_target);
        const cross = b.addTest(.{
            .name = b.fmt("born-{s}", .{triple}),
            .root_module = cross_mod,
        });
        check.dependOn(&cross.step);
    }
}

fn linkPlatform(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("kernel32", .{});
    } else {
        mod.link_libc = true;
    }
}
