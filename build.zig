const std = @import("std");
const builtin = @import("builtin");
const compat = @import("src/compat.zig");

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
    enforceIsolation(b);

    const readme = @embedFile("README.md");
    if (std.mem.count(u8, readme, "| `") != supported_targets.len)
        @panic("README platform table must match supported_targets");
    inline for (supported_targets) |triple| {
        if (compat.find(u8, readme, "| `" ++ triple ++ "` |") == null)
            @panic("README platform table is missing " ++ triple);
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const compat_mod = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPlatform(compat_mod, target);
    const mod = b.addModule("born", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "compat", .module = compat_mod }},
    });
    linkPlatform(mod, target);

    const lib = b.addLibrary(.{
        .name = "born",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .name = "born-tests", .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the event port tests");
    test_step.dependOn(&run_tests.step);
    const install_tests = b.addInstallArtifact(tests, .{});
    b.step("test-bin", "Install the selected target's test executable without running it").dependOn(&install_tests.step);

    // born.io: the std.Io compatibility shim over the event port, exported
    // only where std.Io exists (Zig >= 0.16). On 0.15.2 this block is
    // comptime-dead and the build graph is unchanged. The core never imports
    // the shim; enforceIsolation gates that back edge on every toolchain.
    if (builtin.zig_version.minor >= 16) {
        const io_mod = b.addModule("born.io", .{
            .root_source_file = b.path("src/io/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "born", .module = mod }},
        });
        linkPlatform(io_mod, target);
        const io_tests = b.addTest(.{ .name = "born-io-tests", .root_module = io_mod });
        test_step.dependOn(&b.addRunArtifact(io_tests).step);
    }

    const docs_obj = b.addObject(.{
        .name = "born-docs",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation").dependOn(&install_docs.step);

    // On request only (never part of test, test-bin or check-targets): the
    // kqueue hot-path benchmark, installed as zig-out/bin/born-bench. Method
    // and driver: bench/README.md and bench/run.sh.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "born", .module = mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });
    const bench_exe = b.addExecutable(.{ .name = "born-bench", .root_module = bench_mod });
    b.step("bench", "Build the born-bench benchmark (bench/README.md)").dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    // Compile-only proof that every claimed platform still builds. No test
    // binary is emitted or run.
    const check = b.step("check-targets", "Cross-compile every supported platform");
    for (supported_targets) |triple| {
        const q = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch @panic("bad triple");
        const cross_target = b.resolveTargetQuery(q);
        const cross_compat_mod = b.createModule(.{
            .root_source_file = b.path("src/compat.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        linkPlatform(cross_compat_mod, cross_target);
        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "compat", .module = cross_compat_mod }},
        });
        linkPlatform(cross_mod, cross_target);
        const cross = b.addTest(.{
            .name = b.fmt("born-{s}", .{triple}),
            .root_module = cross_mod,
        });
        check.dependOn(&cross.step);

        // The shim is part of the claimed surface on Zig >= 0.16: prove it
        // semantically compiles for every supported target too.
        if (builtin.zig_version.minor >= 16) {
            const cross_io_mod = b.createModule(.{
                .root_source_file = b.path("src/io/root.zig"),
                .target = cross_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "born", .module = cross_mod }},
            });
            linkPlatform(cross_io_mod, cross_target);
            const cross_io = b.addTest(.{
                .name = b.fmt("born-io-{s}", .{triple}),
                .root_module = cross_io_mod,
            });
            check.dependOn(&cross_io.step);
        }
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

/// Back-edge isolation gate: the born.io shim (src/io/) imports the core, but
/// no core source may reference std.Io or the shim. Runs at graph construction
/// on every toolchain, so a violation fails the build itself, not just review.
/// Only born's own tree is scanned, and only when born is the root package; as
/// a dependency the gate is skipped so consumers never pay for it.
fn enforceIsolation(b: *std.Build) void {
    // As a dependency, born's build() runs in the consumer's process with the
    // consumer's working directory. Scanning there would read the consumer's
    // sources, not born's, so only gate when born is the root package.
    if (b.pkg_hash.len != 0) return;

    if (builtin.zig_version.minor >= 16) {
        const io = b.graph.io;
        const root = if (builtin.zig_version.minor >= 17) b.root.root_dir.handle else b.build_root.handle;
        var src = root.openDir(io, "src", .{ .iterate = true }) catch
            @panic("isolation gate: cannot open src/");
        defer src.close(io);
        var walker = src.walk(b.allocator) catch @panic("isolation gate: cannot walk src/");
        defer walker.deinit();
        while (walker.next(io) catch @panic("isolation gate: cannot walk src/")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.startsWith(u8, entry.path, "io/")) continue;
            const text = src.readFileAlloc(io, entry.path, b.allocator, std.Io.Limit.limited(1 << 20)) catch
                @panic("isolation gate: cannot read source file");
            defer b.allocator.free(text);
            scanCoreSource(entry.path, text);
        }
    } else {
        var src = b.build_root.handle.openDir("src", .{ .iterate = true }) catch
            @panic("isolation gate: cannot open src/");
        defer src.close();
        var walker = src.walk(b.allocator) catch @panic("isolation gate: cannot walk src/");
        defer walker.deinit();
        while (walker.next() catch @panic("isolation gate: cannot walk src/")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.startsWith(u8, entry.path, "io/")) continue;
            const text = src.readFileAlloc(b.allocator, entry.path, 1 << 20) catch
                @panic("isolation gate: cannot read source file");
            defer b.allocator.free(text);
            scanCoreSource(entry.path, text);
        }
    }
}

/// Hard text boundary: a needle matches anywhere in the file, including doc
/// comments, so a core comment that merely mentions std.Io also fails the gate.
fn scanCoreSource(path: []const u8, text: []const u8) void {
    const needles = [_][]const u8{ "std.Io", "@import(\"io/", "@import(\"born.io\")" };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null)
            std.debug.panic("isolation gate: src/{s} references {s}; the core must not import std.Io or the born.io shim", .{ path, needle });
    }
}
