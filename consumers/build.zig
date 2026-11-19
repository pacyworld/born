// Born P5.5 proof consumers build graph (design sections 3-7).
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
    const nats_options_mod = nats_options.createModule();
    const nats_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ nats_root, "src", "root.zig" }) },
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsync", .module = xsync_mod },
            .{ .name = "build_options", .module = nats_options_mod },
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

    // e2e suite (design 7.2, Q4): the vendored upstream tests tree,
    // hash-verified against the pin at configure time (carry-in 4), with
    // exactly one difference in the generated tree: tests/utils.zig is the
    // born-owned native-provisioning facade. Configs are verified too but
    // read at runtime from the CWD (tests/configs), not compiled.
    const vendored = verifyVendoredTests(b);
    const e2e_root = generateE2eTree(b, vendored);
    const e2e_options = b.addOptions();
    e2e_options.addOption(bool, "born_network", born_network);
    e2e_options.addOption([]const u8, "suite", "nats-e2e");
    const e2e_mod = b.createModule(.{
        .root_source_file = e2e_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nats", .module = nats_mod },
            .{ .name = "xsync", .module = xsync_mod },
            .{ .name = "build_options", .module = nats_options_mod },
            .{ .name = "std", .module = facade.std_mod },
            .{ .name = "born_io", .module = io_mod },
            .{ .name = "born", .module = core_mod },
            .{ .name = "consumer_options", .module = e2e_options.createModule() },
        },
    });
    linkPlatform(e2e_mod, target);
    const e2e_tests = b.addTest(.{
        .name = "nats-e2e",
        .root_module = e2e_mod,
        .test_runner = .{ .path = b.path("runner.zig"), .mode = .simple },
    });
    const run_e2e = b.addRunArtifact(e2e_tests);
    // Runtime CWD contract: tests/configs relative to the CWD (auth creds,
    // nkey/jwt server configs), same as upstream's package-root CWD.
    run_e2e.setCwd(b.path("nats"));
    b.step("test-e2e", "Run the nats e2e suite on born.io against native nats-server v2.15.0 (-Dborn-network=false for the all-Threaded baseline)").dependOn(&run_e2e.step);
    const install_e2e = b.addInstallArtifact(e2e_tests, .{});
    b.step("test-e2e-bin", "Install the nats e2e test executable without running it").dependOn(&install_e2e.step);

    // HTTP contract suite (design 7.3, Q2): born-owned std.http.Client
    // contracts against a plain-Threaded fixture server; carries the 0.17.1
    // born.io proof. -Dborn-network=false runs the all-Threaded control leg.
    const http_options = b.addOptions();
    http_options.addOption(bool, "born_network", born_network);
    http_options.addOption([]const u8, "suite", "http");
    const http_mod = b.createModule(.{
        .root_source_file = b.path("http/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "std", .module = facade.std_mod },
            .{ .name = "born_io", .module = io_mod },
            .{ .name = "born", .module = core_mod },
            .{ .name = "consumer_options", .module = http_options.createModule() },
        },
    });
    linkPlatform(http_mod, target);
    const http_tests = b.addTest(.{
        .name = "http-contract",
        .root_module = http_mod,
        .test_runner = .{ .path = b.path("runner.zig"), .mode = .simple },
    });
    const run_http = b.addRunArtifact(http_tests);
    b.step("test-http", "Run the std.http.Client contract suite on born.io (-Dborn-network=false for the all-Threaded control leg)").dependOn(&run_http.step);
    const install_http = b.addInstallArtifact(http_tests, .{});
    b.step("test-http-bin", "Install the HTTP contract test executable without running it").dependOn(&install_http.step);

    // On request only: the HTTP consumer benchmark (design section 9),
    // installed as zig-out/bin/born-http-bench. Driver and quiet-host rule:
    // bench/http.sh. No std facade: the benchmark runs on the real std and
    // injects born.io into the client explicitly. Never part of a test step.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "born_io", .module = io_mod },
            .{ .name = "born", .module = core_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });
    linkPlatform(bench_mod, target);
    const bench_exe = b.addExecutable(.{ .name = "born-http-bench", .root_module = bench_mod });
    b.step("bench-http", "Build the born-http-bench HTTP consumer benchmark (bench/http.sh)").dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
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

/// Filesystem path of the package build root. 0.16 has
/// Build.build_root (Cache.Directory); 0.17.1 replaced it with
/// Build.root (Cache.Path = root_dir + sub_path). The "." fallback
/// assumes the build was invoked from the package directory (CI does
/// `cd consumers`), matching Directory.path's null-handle case.
fn buildRootPath(b: *std.Build) []const u8 {
    if (comptime @hasField(std.Build, "build_root")) {
        return b.build_root.path orelse ".";
    } else {
        const dir_path = b.root.root_dir.path orelse ".";
        if (b.root.sub_path.len == 0) return dir_path;
        return b.pathJoin(&.{ dir_path, b.root.sub_path });
    }
}

const VendoredEntry = struct {
    path: []const u8,
    hash: [64]u8,
};

/// Hash-verify the vendored nats tests tree against the committed upstream
/// pin manifest (review 192 carry-in 4). nats's own .paths excludes tests/
/// from the fetched package, so the tree is vendored byte-identical from
/// the pin commit; every listed file must match its sha256 and every file
/// in the tree must be listed. Abort-and-report on any drift.
fn verifyVendoredTests(b: *std.Build) []const VendoredEntry {
    const io = b.graph.io;
    const alloc = b.allocator;
    const root = buildRootPath(b);
    const nats_dir = b.pathJoin(&.{ root, "nats" });
    const cwd = std.Io.Dir.cwd();
    const limit = std.Io.Limit.limited(1 << 20);
    const manifest = cwd.readFileAlloc(io, b.pathJoin(&.{ nats_dir, "manifest.sha256" }), alloc, limit) catch |err|
        std.debug.panic("consumers: cannot read nats/manifest.sha256 ({s})", .{@errorName(err)});

    const entries = alloc.alloc(VendoredEntry, 128) catch @panic("OOM");
    var entry_count: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const sep = std.mem.indexOf(u8, trimmed, "  ") orelse
            std.debug.panic("consumers: malformed manifest line: '{s}'", .{trimmed});
        const hex = trimmed[0..sep];
        const rel = trimmed[sep + 2 ..];
        if (hex.len != 64 or !std.mem.startsWith(u8, rel, "tests/"))
            std.debug.panic("consumers: malformed manifest entry: '{s}'", .{trimmed});
        const bytes = cwd.readFileAlloc(io, b.pathJoin(&.{ nats_dir, rel }), alloc, limit) catch |err|
            std.debug.panic("consumers: vendored file '{s}' missing or unreadable ({s})", .{ rel, @errorName(err) });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &actual, hex))
            std.debug.panic("consumers: vendored file '{s}' does not match the upstream pin hash (manifest {s}, actual {s}); aborting rather than running drifted tests", .{ rel, hex, actual });
        if (entry_count == entries.len) @panic("consumers: vendored manifest exceeds 128 entries");
        entries[entry_count] = .{ .path = rel, .hash = actual };
        entry_count += 1;
    }
    if (entry_count == 0) @panic("consumers: empty vendored manifest");

    // Completeness: every file in the vendored tree must be listed.
    var tests_dir = cwd.openDir(io, b.pathJoin(&.{ nats_dir, "tests" }), .{ .iterate = true }) catch |err|
        std.debug.panic("consumers: cannot open vendored tests dir ({s})", .{@errorName(err)});
    defer tests_dir.close(io);
    const walked = walkVerify(b, tests_dir, "tests", entries[0..entry_count]);
    if (walked != entry_count)
        std.debug.panic("consumers: manifest lists {d} files but the vendored tree has {d}", .{ entry_count, walked });
    return entries[0..entry_count];
}

fn walkVerify(b: *std.Build, dir: std.Io.Dir, prefix: []const u8, entries: []const VendoredEntry) usize {
    const io = b.graph.io;
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(io) catch |err| std.debug.panic("consumers: cannot iterate vendored tree ({s})", .{@errorName(err)})) |entry| {
        const rel = b.pathJoin(&.{ prefix, entry.name });
        switch (entry.kind) {
            .file => {
                const listed = for (entries) |e| {
                    if (std.mem.eql(u8, e.path, rel)) break true;
                } else false;
                if (!listed)
                    std.debug.panic("consumers: vendored file '{s}' is not in manifest.sha256; aborting rather than running unverified tests", .{rel});
                count += 1;
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err|
                    std.debug.panic("consumers: cannot open vendored dir '{s}' ({s})", .{ rel, @errorName(err) });
                defer sub.close(io);
                count += walkVerify(b, sub, rel, entries);
            },
            else => std.debug.panic("consumers: unexpected vendored entry kind in '{s}'", .{rel}),
        }
    }
    return count;
}

/// Generate the e2e tests tree: verified vendored bytes plus the born-owned
/// utils.zig facade, the only permitted difference (carry-in 4). Non-zig
/// entries (configs) are verified but not copied: they are runtime reads
/// relative to the CWD, which the run step sets to consumers/nats.
fn generateE2eTree(b: *std.Build, entries: []const VendoredEntry) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    var all_tests: ?std.Build.LazyPath = null;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".zig")) continue;
        if (std.mem.eql(u8, e.path, "tests/utils.zig")) continue; // replaced by the facade
        const lp = wf.addCopyFile(b.path(b.pathJoin(&.{ "nats", e.path })), e.path);
        if (std.mem.eql(u8, e.path, "tests/all_tests.zig")) all_tests = lp;
    }
    const root = buildRootPath(b);
    const facade = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathJoin(&.{ root, "nats", "utils.zig" }), b.allocator, std.Io.Limit.limited(1 << 20)) catch |err|
        std.debug.panic("consumers: cannot read nats/utils.zig facade ({s})", .{@errorName(err)});
    _ = wf.add("tests/utils.zig", facade);
    return all_tests orelse @panic("consumers: vendored tree has no tests/all_tests.zig");
}
