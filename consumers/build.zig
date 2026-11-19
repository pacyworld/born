// Born P5.5 proof consumers build graph (design sections 3-5).
//
// Separate package: born's root build.zig/zon/.paths are unchanged and
// consumers/ never ships downstream. Zero b.dependency calls on any
// toolchain: on 0.17.1 dependency() constructs std.Build.package_map, which
// force-analyzes every available package's build.zig, and nats's build.zig
// calls the removed std.zon.parse.fromSliceAlloc there. nats, xsync and born
// are wired from source via pkgBuildRoot instead, so no dependency build.zig
// is ever analyzed.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const born_network = b.option(bool, "born-network", "Route consumer network ops through Born (false = all-Threaded baseline/control leg)") orelse true;

    const facade = generateFacade(b, target, optimize);

    // born core + compat + io from the path dependency's source, mirroring
    // born's own module wiring (born's build() never runs here).
    const born_root = pkgBuildRoot(b, "born");
    const compat_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ born_root, "src", "compat.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    linkPlatform(compat_mod, target);
    const core_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ born_root, "src", "root.zig" }) },
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "compat", .module = compat_mod }},
    });
    linkPlatform(core_mod, target);
    const io_options = b.addOptions();
    // Route proof needs the network counters (review 192 carry-in 1); the
    // three flags mirror born's own shim test wiring.
    io_options.addOption(bool, "time_stats", true);
    io_options.addOption(bool, "network_stats", true);
    io_options.addOption(bool, "process_stats", true);
    const io_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ born_root, "src", "io", "root.zig" }) },
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "born", .module = core_mod },
            .{ .name = "born_io_options", .module = io_options.createModule() },
            .{ .name = "compat", .module = compat_mod },
        },
    });
    linkPlatform(io_mod, target);

    // nats + xsync from source. nats's lazy tls dep stays unfetched; TLS is
    // compiled out (use_tls = false, tls_stub wired as an anonymous import).
    const nats_root = pkgBuildRoot(b, "nats");
    const xsync_root = pkgBuildRoot(b, "xsync");
    const xsync_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ xsync_root, "src", "root.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const nats_options = b.addOptions();
    nats_options.addOption([]const u8, "version", "0.0.0");
    nats_options.addOption([]const u8, "name", "nats.zig");
    nats_options.addOption([]const u8, "lang", "zig");
    nats_options.addOption(bool, "use_tls", false);
    const nats_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ nats_root, "src", "root.zig" }) },
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsync", .module = xsync_mod },
            .{ .name = "build_options", .module = nats_options.createModule() },
        },
    });
    nats_mod.addAnonymousImport("tls", .{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ nats_root, "src", "tls_stub.zig" }) },
    });
    linkPlatform(nats_mod, target);

    // The consumer module IS the test root module (upstream test-unit shape),
    // so its unit tests are collected. The runner shares this import table;
    // nats source never references the extra imports.
    nats_mod.addImport("std", facade.std_mod);
    nats_mod.addImport("born_io", io_mod);
    nats_mod.addImport("born", core_mod);
    const unit_options = b.addOptions();
    unit_options.addOption(bool, "born_network", born_network);
    unit_options.addOption([]const u8, "suite", "nats-unit");
    nats_mod.addImport("consumer_options", unit_options.createModule());

    const unit_tests = b.addTest(.{
        .name = "nats-unit",
        .root_module = nats_mod,
        .test_runner = .{ .path = b.path("runner.zig"), .mode = .simple },
    });
    const run_unit = b.addRunArtifact(unit_tests);
    b.step("test-unit", "Run the nats unit suite on born.io (-Dborn-network=false for the all-Threaded baseline)").dependOn(&run_unit.step);
    const install_unit = b.addInstallArtifact(unit_tests, .{});
    b.step("test-bin", "Install the consumer test executable without running it").dependOn(&install_unit.step);
}

fn linkPlatform(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("kernel32", .{});
    } else {
        mod.link_libc = true;
    }
}

/// Resolve the installed toolchain's lib/std directory (design 4.4,
/// review 192 carry-in 3).
fn resolveLibStd(b: *std.Build) []const u8 {
    // 0.16.0 exposes Graph.zig_lib_directory (Cache.Directory). 0.17.1
    // dropped that field; search for a replacement before falling back:
    // Graph has no other lib field (only zig_exe), std.Build.zig_lib is a
    // LazyPath base with no eager configure-time accessor, and ZIG_LIB_DIR
    // is absent from graph.environ_map on both toolchains (probed). The
    // fallback is the official tarball layout: lib/ next to the zig exe.
    const lib_dir = graphLibDir(b) orelse blk: {
        const exe_dir = std.fs.path.dirname(b.graph.zig_exe) orelse
            std.debug.panic("consumers facade: cannot derive lib dir from zig_exe '{s}'", .{b.graph.zig_exe});
        break :blk b.pathJoin(&.{ exe_dir, "lib" });
    };
    const lib_std = b.pathJoin(&.{ lib_dir, "std" });
    // Existence assert naming the resolved path: a packaged Zig may place
    // lib/ elsewhere; abort-and-report rather than silently mis-redirect.
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, lib_std, .{}) catch |err|
        std.debug.panic("consumers facade: std lib dir '{s}' not accessible ({s}); expected <zig install>/lib/std", .{ lib_std, @errorName(err) });
    dir.close(io);
    return lib_std;
}

fn graphLibDir(b: *std.Build) ?[]const u8 {
    if (comptime @hasField(@TypeOf(b.graph.*), "zig_lib_directory")) {
        return b.graph.zig_lib_directory.path;
    }
    return null;
}

const Facade = struct {
    std_mod: *std.Build.Module,
};

/// Generate the std facade at configure time from the installed toolchain
/// (design 4.2/4.4). The real std.zig stays the "std" module root (all its
/// relative imports stay legal); only testing.zig is overridden through the
/// module import table, with exactly one semantic change: testing.io becomes
/// a writable var the runner assigns a fresh born-backed Io to. Facade copies
/// of testing/FailingAllocator.zig and testing/Smith.zig are required because
/// Zig enforces single-module file ownership: the std module owns lib/std,
/// so the facade's relative imports must resolve to facade-owned copies.
fn generateFacade(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Facade {
    const lib_std = resolveLibStd(b);
    const io = b.graph.io;
    const alloc = b.allocator;
    var lib_dir = std.Io.Dir.cwd().openDir(io, lib_std, .{}) catch |err|
        std.debug.panic("consumers facade: cannot open '{s}' ({s})", .{ lib_std, @errorName(err) });
    defer lib_dir.close(io);
    const limit = std.Io.Limit.limited(1 << 20);
    const testing_src = lib_dir.readFileAlloc(io, "testing.zig", alloc, limit) catch |err|
        std.debug.panic("consumers facade: cannot read '{s}/testing.zig' ({s})", .{ lib_std, @errorName(err) });
    const failing_src = lib_dir.readFileAlloc(io, "testing/FailingAllocator.zig", alloc, limit) catch |err|
        std.debug.panic("consumers facade: cannot read '{s}/testing/FailingAllocator.zig' ({s})", .{ lib_std, @errorName(err) });
    const smith_src = lib_dir.readFileAlloc(io, "testing/Smith.zig", alloc, limit) catch |err|
        std.debug.panic("consumers facade: cannot read '{s}/testing/Smith.zig' ({s})", .{ lib_std, @errorName(err) });

    const io_line = "pub const io = if (builtin.is_test) io_instance.io() else @compileError(\"not testing\");";
    const io_var = "pub var io: Io = if (builtin.is_test) undefined else @compileError(\"not testing\");";
    var testing = replaceOnce(alloc, testing_src, io_line, io_var, "testing.zig: testing.io const->var");
    testing = replaceOnce(alloc, testing, "@import(\"std.zig\")", "@import(\"std\")", "testing.zig: std import");
    const failing = replaceOnce(alloc, failing_src, "@import(\"../std.zig\")", "@import(\"std\")", "testing/FailingAllocator.zig: std import");
    const smith = replaceOnce(alloc, smith_src, "@import(\"../std.zig\")", "@import(\"std\")", "testing/Smith.zig: std import");

    const wf = b.addWriteFiles();
    const testing_path = wf.add("testing.zig", testing);
    _ = wf.add("testing/FailingAllocator.zig", failing);
    _ = wf.add("testing/Smith.zig", smith);

    const std_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ lib_std, "std.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const facade_mod = b.createModule(.{
        .root_source_file = testing_path,
        .target = target,
        .optimize = optimize,
    });
    facade_mod.addImport("std", std_mod);
    std_mod.addImport("testing.zig", facade_mod);
    // Serves std.zig's debug.assert(@import("std") == @This()). Every import
    // of std_mod must be named exactly "std": the canonical emitted -M name
    // is the first registered import name.
    std_mod.addImport("std", std_mod);
    return .{ .std_mod = std_mod };
}

/// Drift guard (abort-and-report): the pattern must occur exactly once. If a
/// future toolchain changes testing.zig's shape, the build aborts with a
/// clear message rather than silently mis-redirecting.
fn replaceOnce(alloc: std.mem.Allocator, src: []const u8, needle: []const u8, replacement: []const u8, what: []const u8) []const u8 {
    const n = std.mem.count(u8, src, needle);
    if (n != 1) std.debug.panic(
        "consumers facade drift: {s}: expected exactly 1 occurrence of '{s}', found {d}; the toolchain's testing.zig shape changed, aborting rather than mis-redirecting",
        .{ what, needle, n },
    );
    const i = std.mem.indexOf(u8, src, needle).?;
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ src[0..i], replacement, src[i + needle.len ..] }) catch @panic("OOM");
}

/// Resolve a declared dependency's fetched source root without evaluating
/// its build.zig: reads the same generated package table std.Build.dependency
/// itself reads. build_root is the fetched source directory.
fn pkgBuildRoot(b: *std.Build, name: []const u8) []const u8 {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const hash = for (b.available_deps) |d| {
        if (std.mem.eql(u8, d[0], name)) break d[1];
    } else std.debug.panic("dependency '{s}' not declared", .{name});
    const ti = @typeInfo(deps.packages).@"struct";
    // 0.17.1 renamed Type.Struct.decls to decl_names (plain strings).
    if (comptime @hasField(@TypeOf(ti), "decl_names")) {
        inline for (ti.decl_names) |decl_name| {
            if (std.mem.eql(u8, decl_name, hash)) return pkgRoot(deps.packages, decl_name, name);
        }
    } else {
        inline for (ti.decls) |decl| {
            if (std.mem.eql(u8, decl.name, hash)) return pkgRoot(deps.packages, decl.name, name);
        }
    }
    std.debug.panic("package for '{s}' not fetched", .{name});
}

fn pkgRoot(comptime packages: type, comptime pkg_name: []const u8, dep_name: []const u8) []const u8 {
    const pkg = @field(packages, pkg_name);
    if (!@hasDecl(pkg, "build_root")) std.debug.panic("package '{s}' not fetched", .{dep_name});
    return pkg.build_root;
}
