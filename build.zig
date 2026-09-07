const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("born", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "born",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the event port tests").dependOn(&run_tests.step);

    // Compile-only proof that every claimed platform still builds. Nothing is
    // run; the binaries are discarded.
    const check = b.step("check-targets", "Cross-compile every supported platform");
    for ([_][]const u8{
        "x86_64-freebsd",
        "x86_64-linux-gnu",
        "aarch64-macos",
        "x86_64-macos",
        "x86_64-windows-gnu",
        "x86_64-netbsd",
        "x86_64-openbsd",
    }) |triple| {
        const q = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch @panic("bad triple");
        const cross = b.addLibrary(.{
            .name = b.fmt("born-{s}", .{triple}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = b.resolveTargetQuery(q),
                .optimize = .Debug,
            }),
        });
        check.dependOn(&cross.step);
    }
}
