//! Per-tag `std.Io.VTable` compatibility assertions.
//!
//! The shim targets a pinned upstream interface. These comptime checks fail
//! the build if the selected toolchain's `Io.VTable` drifts from the shape the
//! shim was written against: a different field count, a renamed/added/removed
//! slot, a reordered slot, or a changed slot signature. Count-only checks are
//! not sufficient (0.16.0 and 0.17.1 differ by add/remove pairs and by the
//! `netClose` parameter type), so names and function types are pinned too.
//!
//! The complete function-type contract is additionally enforced by the
//! explicit baseline vtable in `shim.zig`: every slot is assigned a forwarding
//! thunk with a written-out signature, so any upstream signature change is a
//! compile error at that assignment.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// True on the 0.17.x interface (106 slots); false on 0.16.x (109 slots).
pub const is_017 = builtin.zig_version.minor >= 17;

/// Expected slot count for the selected toolchain.
pub const expected_count: usize = if (is_017) 106 else 109;

/// Slot names in declaration order, Zig 0.16.0 (`Io.zig:51-255`).
const names_016 = [_][]const u8{
    "crashHandler",
    "async",
    "concurrent",
    "await",
    "cancel",
    "groupAsync",
    "groupConcurrent",
    "groupAwait",
    "groupCancel",
    "recancel",
    "swapCancelProtection",
    "checkCancel",
    "futexWait",
    "futexWaitUncancelable",
    "futexWake",
    "operate",
    "batchAwaitAsync",
    "batchAwaitConcurrent",
    "batchCancel",
    "dirCreateDir",
    "dirCreateDirPath",
    "dirCreateDirPathOpen",
    "dirOpenDir",
    "dirStat",
    "dirStatFile",
    "dirAccess",
    "dirCreateFile",
    "dirCreateFileAtomic",
    "dirOpenFile",
    "dirClose",
    "dirRead",
    "dirRealPath",
    "dirRealPathFile",
    "dirDeleteFile",
    "dirDeleteDir",
    "dirRename",
    "dirRenamePreserve",
    "dirSymLink",
    "dirReadLink",
    "dirSetOwner",
    "dirSetFileOwner",
    "dirSetPermissions",
    "dirSetFilePermissions",
    "dirSetTimestamps",
    "dirHardLink",
    "fileStat",
    "fileLength",
    "fileClose",
    "fileWritePositional",
    "fileWriteFileStreaming",
    "fileWriteFilePositional",
    "fileReadPositional",
    "fileSeekBy",
    "fileSeekTo",
    "fileSync",
    "fileIsTty",
    "fileEnableAnsiEscapeCodes",
    "fileSupportsAnsiEscapeCodes",
    "fileSetLength",
    "fileSetOwner",
    "fileSetPermissions",
    "fileSetTimestamps",
    "fileLock",
    "fileTryLock",
    "fileUnlock",
    "fileDowngradeLock",
    "fileRealPath",
    "fileHardLink",
    "fileMemoryMapCreate",
    "fileMemoryMapDestroy",
    "fileMemoryMapSetLength",
    "fileMemoryMapRead",
    "fileMemoryMapWrite",
    "processExecutableOpen",
    "processExecutablePath",
    "lockStderr",
    "tryLockStderr",
    "unlockStderr",
    "processCurrentPath",
    "processSetCurrentDir",
    "processSetCurrentPath",
    "processReplace",
    "processReplacePath",
    "processSpawn",
    "processSpawnPath",
    "childWait",
    "childKill",
    "progressParentFile",
    "now",
    "clockResolution",
    "sleep",
    "random",
    "randomSecure",
    "netListenIp",
    "netAccept",
    "netBindIp",
    "netConnectIp",
    "netListenUnix",
    "netConnectUnix",
    "netSocketCreatePair",
    "netSend",
    "netRead",
    "netWrite",
    "netWriteFile",
    "netClose",
    "netShutdown",
    "netInterfaceNameResolve",
    "netInterfaceName",
    "netLookup",
};

/// Slot names in declaration order, Zig 0.17.1 (`Io.zig:51-244`).
const names_017 = [_][]const u8{
    "crashHandler",
    "async",
    "concurrent",
    "await",
    "cancel",
    "groupAsync",
    "groupConcurrent",
    "groupAwait",
    "groupCancel",
    "recancel",
    "swapCancelProtection",
    "checkCancel",
    "futexWait",
    "futexWaitUncancelable",
    "futexWake",
    "operate",
    "batchAwaitAsync",
    "batchAwaitConcurrent",
    "batchCancel",
    "dirCreateDir",
    "dirCreateDirPath",
    "dirCreateDirPathOpen",
    "dirOpenDir",
    "dirStat",
    "dirStatFile",
    "dirAccess",
    "dirCreateFile",
    "dirCreateFileAtomic",
    "dirOpenFile",
    "dirClose",
    "dirRead",
    "dirRealPath",
    "dirRealPathFile",
    "dirDeleteFile",
    "dirDeleteDir",
    "dirRename",
    "dirRenamePreserve",
    "dirSymLink",
    "dirReadLink",
    "dirSetOwner",
    "dirSetFileOwner",
    "dirSetPermissions",
    "dirSetFilePermissions",
    "dirSetTimestamps",
    "dirHardLink",
    "fileStat",
    "fileLength",
    "fileClose",
    "fileWritePositional",
    "fileWriteFileStreaming",
    "fileWriteFilePositional",
    "fileReadPositional",
    "fileSeekBy",
    "fileSeekTo",
    "fileSync",
    "fileIsTty",
    "fileEnableAnsiEscapeCodes",
    "fileSupportsAnsiEscapeCodes",
    "fileSetLength",
    "fileSetOwner",
    "fileSetPermissions",
    "fileSetTimestamps",
    "fileLock",
    "fileTryLock",
    "fileUnlock",
    "fileDowngradeLock",
    "fileRealPath",
    "fileHardLink",
    "fileMemoryMapCreate",
    "fileMemoryMapDestroy",
    "fileMemoryMapSetLength",
    "fileMemoryMapRead",
    "fileMemoryMapWrite",
    "processExecutableOpen",
    "processExecutablePath",
    "lockStderr",
    "tryLockStderr",
    "unlockStderr",
    "processCurrentPath",
    "processSetCurrentDir",
    "processSetCurrentPath",
    "processReplace",
    "processSpawn",
    "childWait",
    "childKill",
    "progressParentFile",
    "inheritParentDir",
    "inheritParentFile",
    "now",
    "clockResolution",
    "sleep",
    "random",
    "randomSecure",
    "netListenIp",
    "netAccept",
    "netBindIp",
    "netConnectIp",
    "netListenUnix",
    "netConnectUnix",
    "netSocketCreatePair",
    "netWriteFile",
    "netClose",
    "netShutdown",
    "netInterfaceNameResolve",
    "netInterfaceName",
    "netLookup",
};

const expected_names: []const []const u8 = if (is_017) &names_017 else &names_016;

/// One Io.VTable slot: declared name and function-pointer type.
pub const Slot = struct {
    name: []const u8,
    type: type,
};

/// Actual Io.VTable slot count reported by the selected toolchain.
pub fn actualSlotCount() usize {
    const info = @typeInfo(Io.VTable).@"struct";
    return if (is_017) info.field_names.len else info.fields.len;
}

/// Ordered Io.VTable slots. 0.16 exposes @typeInfo fields; 0.17 exposes
/// parallel field_names/field_types arrays. Call only after verify() has
/// pinned the count.
pub fn slots() [expected_count]Slot {
    @setEvalBranchQuota(4000);
    const info = @typeInfo(Io.VTable).@"struct";
    var result: [expected_count]Slot = undefined;
    if (is_017) {
        for (info.field_names, info.field_types, 0..) |name, t, i| {
            result[i] = .{ .name = name, .type = t };
        }
    } else {
        for (info.fields, 0..) |field, i| {
            result[i] = .{ .name = field.name, .type = field.type };
        }
    }
    return result;
}

/// Every slot is a `*const fn` whose first parameter is the erased userdata.
fn checkSlotShape(comptime name: []const u8, comptime T: type) void {
    const ptr = @typeInfo(T);
    if (ptr != .pointer)
        @compileError("Io.VTable." ++ name ++ " is not a function pointer");
    // 0.16 exposes is_const; 0.17 moved pointer attributes into attrs.
    const is_const = if (is_017) ptr.pointer.attrs.@"const" else ptr.pointer.is_const;
    if (!is_const)
        @compileError("Io.VTable." ++ name ++ " is not a *const function pointer");
    const fn_info = @typeInfo(ptr.pointer.child);
    if (fn_info != .@"fn")
        @compileError("Io.VTable." ++ name ++ " does not point to a function");
    // 0.16 exposes params: []const Param; 0.17 exposes param_types: []const ?type.
    const param_count = if (is_017) fn_info.@"fn".param_types.len else fn_info.@"fn".params.len;
    if (param_count == 0)
        @compileError("Io.VTable." ++ name ++ " has no userdata parameter");
    const first = (if (is_017) fn_info.@"fn".param_types[0] else fn_info.@"fn".params[0].type) orelse
        @compileError("Io.VTable." ++ name ++ " has a generic first parameter");
    if (first != ?*anyopaque)
        @compileError("Io.VTable." ++ name ++ " first parameter is not ?*anyopaque");
}

/// Runs all compatibility assertions at comptime. Called from the module root
/// so any analysis of `born.io` enforces them, and from a dedicated test.
pub fn verify() void {
    @setEvalBranchQuota(20000);
    const count = actualSlotCount();

    if (count != expected_count)
        @compileError(std.fmt.comptimePrint(
            "Io.VTable has {d} slots; the shim expects {d} for Zig 0.{d}",
            .{ count, expected_count, builtin.zig_version.minor },
        ));

    if (expected_names.len != expected_count)
        @compileError("expected-name table length does not match expected_count");

    inline for (slots(), 0..) |slot, i| {
        if (!std.mem.eql(u8, slot.name, expected_names[i]))
            @compileError(std.fmt.comptimePrint(
                "Io.VTable slot {d} is '{s}'; the shim expects '{s}'",
                .{ i, slot.name, expected_names[i] },
            ));
        checkSlotShape(slot.name, slot.type);
    }

    // Pin the parameter type of the slot that changed between the two pinned
    // releases without changing the slot count or name. A count/name check
    // alone cannot see this drift.
    const net_close = @TypeOf(@field(@as(Io.VTable, undefined), "netClose"));
    const expected_net_close = if (is_017)
        *const fn (?*anyopaque, []const Io.net.Socket) void
    else
        *const fn (?*anyopaque, []const Io.net.Socket.Handle) void;
    if (net_close != expected_net_close)
        @compileError("Io.VTable.netClose signature drifted from the pinned interface");
}

test "per-tag Io.VTable compatibility assertions" {
    comptime {
        verify();
    }
}
