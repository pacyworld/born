//! Born `std.Io` compatibility shim: composite state and baseline vtable.
//!
//! The shim composes Born's event port with upstream's `Io.Threaded` worker
//! pool behind a single `std.Io`. One `Io.userdata` pointer carries the whole
//! composite (`Shim`); every vtable slot is a forwarding thunk that recovers
//! the composite and re-invokes the saved Threaded vtable with the Threaded's
//! own userdata. This is the explicit per-slot routing seam: later increments
//! replace individual thunks with Born evented implementations while the rest
//! keep delegating to Threaded.
//!
//! The foundation baseline delegates every slot to Threaded. It is a
//! compatibility foundation only and is not evidence that any operation runs
//! on Born's reactor.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const Io = std.Io;

const is_017 = builtin.zig_version.minor >= 17;

/// Where a capability family is serviced.
pub const Route = enum {
    /// Born's event port (kqueue/epoll/IOCP). Enabled per family in later
    /// increments; rejected at construction until implemented.
    born_evented,
    /// Upstream `Io.Threaded` worker pool.
    threaded,
};

/// Explicit, compile-time-visible capability routing for the hybrid. The
/// foundation baseline services every family on Threaded; requesting a Born
/// route before it is implemented is a construction rejection, never a silent
/// fallback.
pub const Capabilities = struct {
    time: Route = .threaded,
    network: Route = .threaded,
    file: Route = .threaded,
    process: Route = .threaded,

    pub fn anyBorn(c: Capabilities) bool {
        return c.time == .born_evented or
            c.network == .born_evented or
            c.file == .born_evented or
            c.process == .born_evented;
    }
};

/// Construction options for `io`.
pub const InitOptions = struct {
    /// Thread-safe allocator backing the composite and the Threaded pool.
    allocator: std.mem.Allocator,
    /// Options forwarded verbatim to `Io.Threaded.init`.
    threaded: Io.Threaded.InitOptions = .{},
    /// Capability routing. Defaults to the all-Threaded foundation baseline.
    capabilities: Capabilities = .{},
};

/// Construction failures. Capability rejection is explicit; no slot error is
/// invented here.
pub const InitError = error{
    OutOfMemory,
    CapabilityUnsupported,
};

/// The composite carried by the single `Io.userdata` pointer.
pub const Shim = struct {
    port: *born.EvPort,
    allocator: std.mem.Allocator,
    capabilities: Capabilities,
    threaded: Io.Threaded,
    threaded_io: Io,
};

fn shimFrom(userdata: ?*anyopaque) *Shim {
    return @ptrCast(@alignCast(userdata.?));
}

/// Builds a `std.Io` over Born's event port. The returned interface owns a
/// heap-allocated composite; release it with `deinit`. The foundation baseline
/// rejects any Born capability route at construction.
pub fn io(port: *born.EvPort, opts: InitOptions) InitError!Io {
    if (opts.capabilities.anyBorn()) return error.CapabilityUnsupported;
    const shim = opts.allocator.create(Shim) catch return error.OutOfMemory;
    errdefer opts.allocator.destroy(shim);
    shim.* = .{
        .port = port,
        .allocator = opts.allocator,
        .capabilities = opts.capabilities,
        .threaded = Io.Threaded.init(opts.allocator, opts.threaded),
        .threaded_io = undefined,
    };
    shim.threaded_io = shim.threaded.io();
    return .{ .userdata = shim, .vtable = &baseline_vtable };
}

/// Releases the composite created by `io`, joining the Threaded pool first.
pub fn deinit(interface: Io) void {
    const shim = shimFrom(interface.userdata);
    const allocator = shim.allocator;
    shim.threaded.deinit();
    allocator.destroy(shim);
}

/// Forwarding thunks shared by both pinned interfaces (identical signatures).
/// Each recovers the composite and delegates to the saved Threaded vtable.
const fwd = struct {
    fn crashHandler(userdata: ?*anyopaque) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.crashHandler(self.threaded_io.userdata);
    }
    fn async(
        userdata: ?*anyopaque,
        result: []u8,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*Io.AnyFuture {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.async(self.threaded_io.userdata, result, result_alignment, context, context_alignment, start);
    }
    fn concurrent(
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Io.ConcurrentError!*Io.AnyFuture {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.concurrent(self.threaded_io.userdata, result_len, result_alignment, context, context_alignment, start);
    }
    fn await(
        userdata: ?*anyopaque,
        any_future: *Io.AnyFuture,
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.await(self.threaded_io.userdata, any_future, result, result_alignment);
    }
    fn cancel(
        userdata: ?*anyopaque,
        any_future: *Io.AnyFuture,
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.cancel(self.threaded_io.userdata, any_future, result, result_alignment);
    }
    fn groupAsync(
        userdata: ?*anyopaque,
        group: *Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.groupAsync(self.threaded_io.userdata, group, context, context_alignment, start);
    }
    fn groupConcurrent(
        userdata: ?*anyopaque,
        group: *Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) Io.ConcurrentError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.groupConcurrent(self.threaded_io.userdata, group, context, context_alignment, start);
    }
    fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.groupAwait(self.threaded_io.userdata, group, token);
    }
    fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.groupCancel(self.threaded_io.userdata, group, token);
    }
    fn recancel(userdata: ?*anyopaque) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.recancel(self.threaded_io.userdata);
    }
    fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.swapCancelProtection(self.threaded_io.userdata, new);
    }
    fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.checkCancel(self.threaded_io.userdata);
    }
    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.futexWait(self.threaded_io.userdata, ptr, expected, timeout);
    }
    fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, ptr, expected);
    }
    fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.futexWake(self.threaded_io.userdata, ptr, max_waiters);
    }
    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.operate(self.threaded_io.userdata, operation);
    }
    fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.batchAwaitAsync(self.threaded_io.userdata, batch);
    }
    fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.batchAwaitConcurrent(self.threaded_io.userdata, batch, timeout);
    }
    fn batchCancel(userdata: ?*anyopaque, batch: *Io.Batch) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.batchCancel(self.threaded_io.userdata, batch);
    }
    fn dirCreateDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirCreateDir(self.threaded_io.userdata, dir, sub_path, permissions);
    }
    fn dirCreateDirPath(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirCreateDirPath(self.threaded_io.userdata, dir, sub_path, permissions);
    }
    fn dirCreateDirPathOpen(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirCreateDirPathOpen(self.threaded_io.userdata, dir, sub_path, permissions, options);
    }
    fn dirOpenDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirOpenDir(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirStat(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirStat(self.threaded_io.userdata, dir);
    }
    fn dirStatFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirStatFile(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirAccess(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirAccess(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirCreateFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirCreateFile(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirCreateFileAtomic(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirCreateFileAtomic(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirOpenFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirOpenFile(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirClose(self.threaded_io.userdata, dirs);
    }
    fn dirRead(userdata: ?*anyopaque, reader: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirRead(self.threaded_io.userdata, reader, entries);
    }
    fn dirRealPath(userdata: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirRealPath(self.threaded_io.userdata, dir, out_buffer);
    }
    fn dirRealPathFile(userdata: ?*anyopaque, dir: Io.Dir, path_name: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirRealPathFile(self.threaded_io.userdata, dir, path_name, out_buffer);
    }
    fn dirDeleteFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirDeleteFile(self.threaded_io.userdata, dir, sub_path);
    }
    fn dirDeleteDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirDeleteDir(self.threaded_io.userdata, dir, sub_path);
    }
    fn dirRename(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirRename(self.threaded_io.userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
    fn dirRenamePreserve(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirRenamePreserve(self.threaded_io.userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
    fn dirSymLink(userdata: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirSymLink(self.threaded_io.userdata, dir, target_path, sym_link_path, flags);
    }
    fn dirReadLink(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirReadLink(self.threaded_io.userdata, dir, sub_path, buffer);
    }
    fn dirSetOwner(userdata: ?*anyopaque, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirSetOwner(self.threaded_io.userdata, dir, uid, gid);
    }
    fn dirSetFileOwner(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirSetFileOwner(self.threaded_io.userdata, dir, sub_path, uid, gid, options);
    }
    fn dirSetPermissions(userdata: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirSetPermissions(self.threaded_io.userdata, dir, permissions);
    }
    fn dirSetFilePermissions(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirSetFilePermissions(self.threaded_io.userdata, dir, sub_path, permissions, options);
    }
    fn dirSetTimestamps(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirSetTimestamps(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirHardLink(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.dirHardLink(self.threaded_io.userdata, old_dir, old_sub_path, new_dir, new_sub_path, options);
    }
    fn fileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileStat(self.threaded_io.userdata, file);
    }
    fn fileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileLength(self.threaded_io.userdata, file);
    }
    fn fileClose(userdata: ?*anyopaque, files: []const Io.File) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileClose(self.threaded_io.userdata, files);
    }
    fn fileWritePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileWritePositional(self.threaded_io.userdata, file, header, data, splat, offset);
    }
    fn fileWriteFileStreaming(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.File.Writer.WriteFileError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileWriteFileStreaming(self.threaded_io.userdata, file, header, reader, limit);
    }
    fn fileWriteFilePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit, offset: u64) Io.File.WriteFilePositionalError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileWriteFilePositional(self.threaded_io.userdata, file, header, reader, limit, offset);
    }
    fn fileReadPositional(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileReadPositional(self.threaded_io.userdata, file, data, offset);
    }
    fn fileSeekBy(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSeekBy(self.threaded_io.userdata, file, relative_offset);
    }
    fn fileSeekTo(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSeekTo(self.threaded_io.userdata, file, absolute_offset);
    }
    fn fileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSync(self.threaded_io.userdata, file);
    }
    fn fileIsTty(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileIsTty(self.threaded_io.userdata, file);
    }
    fn fileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileEnableAnsiEscapeCodes(self.threaded_io.userdata, file);
    }
    fn fileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSupportsAnsiEscapeCodes(self.threaded_io.userdata, file);
    }
    fn fileSetLength(userdata: ?*anyopaque, file: Io.File, length: u64) Io.File.SetLengthError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSetLength(self.threaded_io.userdata, file, length);
    }
    fn fileSetOwner(userdata: ?*anyopaque, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.File.SetOwnerError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSetOwner(self.threaded_io.userdata, file, uid, gid);
    }
    fn fileSetPermissions(userdata: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSetPermissions(self.threaded_io.userdata, file, permissions);
    }
    fn fileSetTimestamps(userdata: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileSetTimestamps(self.threaded_io.userdata, file, options);
    }
    fn fileLock(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileLock(self.threaded_io.userdata, file, lock);
    }
    fn fileTryLock(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!bool {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileTryLock(self.threaded_io.userdata, file, lock);
    }
    fn fileUnlock(userdata: ?*anyopaque, file: Io.File) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileUnlock(self.threaded_io.userdata, file);
    }
    fn fileDowngradeLock(userdata: ?*anyopaque, file: Io.File) Io.File.DowngradeLockError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileDowngradeLock(self.threaded_io.userdata, file);
    }
    fn fileRealPath(userdata: ?*anyopaque, file: Io.File, out_buffer: []u8) Io.File.RealPathError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileRealPath(self.threaded_io.userdata, file, out_buffer);
    }
    fn fileHardLink(userdata: ?*anyopaque, file: Io.File, dir: Io.Dir, sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileHardLink(self.threaded_io.userdata, file, dir, sub_path, options);
    }
    fn fileMemoryMapCreate(userdata: ?*anyopaque, file: Io.File, options: Io.File.MemoryMap.CreateOptions) Io.File.MemoryMap.CreateError!Io.File.MemoryMap {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileMemoryMapCreate(self.threaded_io.userdata, file, options);
    }
    fn fileMemoryMapDestroy(userdata: ?*anyopaque, map: *Io.File.MemoryMap) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileMemoryMapDestroy(self.threaded_io.userdata, map);
    }
    fn fileMemoryMapSetLength(userdata: ?*anyopaque, map: *Io.File.MemoryMap, length: usize) Io.File.MemoryMap.SetLengthError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileMemoryMapSetLength(self.threaded_io.userdata, map, length);
    }
    fn fileMemoryMapRead(userdata: ?*anyopaque, map: *Io.File.MemoryMap) Io.File.ReadPositionalError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileMemoryMapRead(self.threaded_io.userdata, map);
    }
    fn fileMemoryMapWrite(userdata: ?*anyopaque, map: *Io.File.MemoryMap) Io.File.WritePositionalError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.fileMemoryMapWrite(self.threaded_io.userdata, map);
    }
    fn processExecutableOpen(userdata: ?*anyopaque, options: Io.Dir.OpenFileOptions) std.process.OpenExecutableError!Io.File {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processExecutableOpen(self.threaded_io.userdata, options);
    }
    fn processExecutablePath(userdata: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processExecutablePath(self.threaded_io.userdata, buffer);
    }
    fn lockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.lockStderr(self.threaded_io.userdata, mode);
    }
    fn tryLockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.tryLockStderr(self.threaded_io.userdata, mode);
    }
    fn unlockStderr(userdata: ?*anyopaque) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.unlockStderr(self.threaded_io.userdata);
    }
    fn processCurrentPath(userdata: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processCurrentPath(self.threaded_io.userdata, buffer);
    }
    fn processSetCurrentDir(userdata: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processSetCurrentDir(self.threaded_io.userdata, dir);
    }
    fn processSetCurrentPath(userdata: ?*anyopaque, sub_path: []const u8) std.process.SetCurrentPathError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processSetCurrentPath(self.threaded_io.userdata, sub_path);
    }
    fn processReplace(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processReplace(self.threaded_io.userdata, options);
    }
    fn processSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processSpawn(self.threaded_io.userdata, options);
    }
    fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.childWait(self.threaded_io.userdata, child);
    }
    fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.childKill(self.threaded_io.userdata, child);
    }
    fn progressParentFile(userdata: ?*anyopaque) std.Progress.ParentFileError!Io.File {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.progressParentFile(self.threaded_io.userdata);
    }
    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.now(self.threaded_io.userdata, clock);
    }
    fn clockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.clockResolution(self.threaded_io.userdata, clock);
    }
    fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.sleep(self.threaded_io.userdata, timeout);
    }
    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.random(self.threaded_io.userdata, buffer);
    }
    fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.randomSecure(self.threaded_io.userdata, buffer);
    }
    fn netListenIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Socket {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netListenIp(self.threaded_io.userdata, address, options);
    }
    fn netAccept(userdata: ?*anyopaque, server: Io.net.Socket.Handle, options: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netAccept(self.threaded_io.userdata, server, options);
    }
    fn netBindIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netBindIp(self.threaded_io.userdata, address, options);
    }
    fn netConnectIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netConnectIp(self.threaded_io.userdata, address, options);
    }
    fn netListenUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress, options: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netListenUnix(self.threaded_io.userdata, address, options);
    }
    fn netConnectUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netConnectUnix(self.threaded_io.userdata, address);
    }
    fn netSocketCreatePair(userdata: ?*anyopaque, options: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netSocketCreatePair(self.threaded_io.userdata, options);
    }
    fn netWriteFile(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netWriteFile(self.threaded_io.userdata, handle, header, reader, limit);
    }
    fn netShutdown(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netShutdown(self.threaded_io.userdata, handle, how);
    }
    fn netInterfaceNameResolve(userdata: ?*anyopaque, name: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netInterfaceNameResolve(self.threaded_io.userdata, name);
    }
    fn netInterfaceName(userdata: ?*anyopaque, interface: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netInterfaceName(self.threaded_io.userdata, interface);
    }
    fn netLookup(userdata: ?*anyopaque, hostname: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netLookup(self.threaded_io.userdata, hostname, queue, options);
    }
};

/// Slots present only on the 0.16.x interface (plus its `netClose` signature).
const fwd016 = if (!is_017) struct {
    fn processReplacePath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processReplacePath(self.threaded_io.userdata, dir, options);
    }
    fn processSpawnPath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.processSpawnPath(self.threaded_io.userdata, dir, options);
    }
    fn netSend(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netSend(self.threaded_io.userdata, handle, messages, flags);
    }
    fn netRead(userdata: ?*anyopaque, src: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netRead(self.threaded_io.userdata, src, data);
    }
    fn netWrite(userdata: ?*anyopaque, dest: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netWrite(self.threaded_io.userdata, dest, header, data, splat);
    }
    fn netClose(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netClose(self.threaded_io.userdata, handles);
    }
} else struct {};

/// Slots present only on the 0.17.x interface (plus its `netClose` signature).
const fwd017 = if (is_017) struct {
    fn inheritParentDir(userdata: ?*anyopaque, handle: Io.Dir.Handle) Io.InheritParentHandleError!Io.Dir {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.inheritParentDir(self.threaded_io.userdata, handle);
    }
    fn inheritParentFile(userdata: ?*anyopaque, handle: Io.File.Handle, flags: Io.File.Flags) Io.InheritParentHandleError!Io.File {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.inheritParentFile(self.threaded_io.userdata, handle, flags);
    }
    fn netClose(userdata: ?*anyopaque, sockets: []const Io.net.Socket) void {
        const self = shimFrom(userdata);
        return self.threaded_io.vtable.netClose(self.threaded_io.userdata, sockets);
    }
} else struct {};

/// Complete explicit Threaded-delegation baseline vtable for the selected
/// toolchain. Every slot is a forwarding thunk; the written-out signatures are
/// the function-type half of the compatibility gate (any upstream signature
/// drift fails at the assignment). Only the taken branch is analyzed.
pub const baseline_vtable: Io.VTable = if (is_017) .{
    .crashHandler = fwd.crashHandler,
    .async = fwd.async,
    .concurrent = fwd.concurrent,
    .await = fwd.await,
    .cancel = fwd.cancel,
    .groupAsync = fwd.groupAsync,
    .groupConcurrent = fwd.groupConcurrent,
    .groupAwait = fwd.groupAwait,
    .groupCancel = fwd.groupCancel,
    .recancel = fwd.recancel,
    .swapCancelProtection = fwd.swapCancelProtection,
    .checkCancel = fwd.checkCancel,
    .futexWait = fwd.futexWait,
    .futexWaitUncancelable = fwd.futexWaitUncancelable,
    .futexWake = fwd.futexWake,
    .operate = fwd.operate,
    .batchAwaitAsync = fwd.batchAwaitAsync,
    .batchAwaitConcurrent = fwd.batchAwaitConcurrent,
    .batchCancel = fwd.batchCancel,
    .dirCreateDir = fwd.dirCreateDir,
    .dirCreateDirPath = fwd.dirCreateDirPath,
    .dirCreateDirPathOpen = fwd.dirCreateDirPathOpen,
    .dirOpenDir = fwd.dirOpenDir,
    .dirStat = fwd.dirStat,
    .dirStatFile = fwd.dirStatFile,
    .dirAccess = fwd.dirAccess,
    .dirCreateFile = fwd.dirCreateFile,
    .dirCreateFileAtomic = fwd.dirCreateFileAtomic,
    .dirOpenFile = fwd.dirOpenFile,
    .dirClose = fwd.dirClose,
    .dirRead = fwd.dirRead,
    .dirRealPath = fwd.dirRealPath,
    .dirRealPathFile = fwd.dirRealPathFile,
    .dirDeleteFile = fwd.dirDeleteFile,
    .dirDeleteDir = fwd.dirDeleteDir,
    .dirRename = fwd.dirRename,
    .dirRenamePreserve = fwd.dirRenamePreserve,
    .dirSymLink = fwd.dirSymLink,
    .dirReadLink = fwd.dirReadLink,
    .dirSetOwner = fwd.dirSetOwner,
    .dirSetFileOwner = fwd.dirSetFileOwner,
    .dirSetPermissions = fwd.dirSetPermissions,
    .dirSetFilePermissions = fwd.dirSetFilePermissions,
    .dirSetTimestamps = fwd.dirSetTimestamps,
    .dirHardLink = fwd.dirHardLink,
    .fileStat = fwd.fileStat,
    .fileLength = fwd.fileLength,
    .fileClose = fwd.fileClose,
    .fileWritePositional = fwd.fileWritePositional,
    .fileWriteFileStreaming = fwd.fileWriteFileStreaming,
    .fileWriteFilePositional = fwd.fileWriteFilePositional,
    .fileReadPositional = fwd.fileReadPositional,
    .fileSeekBy = fwd.fileSeekBy,
    .fileSeekTo = fwd.fileSeekTo,
    .fileSync = fwd.fileSync,
    .fileIsTty = fwd.fileIsTty,
    .fileEnableAnsiEscapeCodes = fwd.fileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = fwd.fileSupportsAnsiEscapeCodes,
    .fileSetLength = fwd.fileSetLength,
    .fileSetOwner = fwd.fileSetOwner,
    .fileSetPermissions = fwd.fileSetPermissions,
    .fileSetTimestamps = fwd.fileSetTimestamps,
    .fileLock = fwd.fileLock,
    .fileTryLock = fwd.fileTryLock,
    .fileUnlock = fwd.fileUnlock,
    .fileDowngradeLock = fwd.fileDowngradeLock,
    .fileRealPath = fwd.fileRealPath,
    .fileHardLink = fwd.fileHardLink,
    .fileMemoryMapCreate = fwd.fileMemoryMapCreate,
    .fileMemoryMapDestroy = fwd.fileMemoryMapDestroy,
    .fileMemoryMapSetLength = fwd.fileMemoryMapSetLength,
    .fileMemoryMapRead = fwd.fileMemoryMapRead,
    .fileMemoryMapWrite = fwd.fileMemoryMapWrite,
    .processExecutableOpen = fwd.processExecutableOpen,
    .processExecutablePath = fwd.processExecutablePath,
    .lockStderr = fwd.lockStderr,
    .tryLockStderr = fwd.tryLockStderr,
    .unlockStderr = fwd.unlockStderr,
    .processCurrentPath = fwd.processCurrentPath,
    .processSetCurrentDir = fwd.processSetCurrentDir,
    .processSetCurrentPath = fwd.processSetCurrentPath,
    .processReplace = fwd.processReplace,
    .processSpawn = fwd.processSpawn,
    .childWait = fwd.childWait,
    .childKill = fwd.childKill,
    .progressParentFile = fwd.progressParentFile,
    .inheritParentDir = fwd017.inheritParentDir,
    .inheritParentFile = fwd017.inheritParentFile,
    .now = fwd.now,
    .clockResolution = fwd.clockResolution,
    .sleep = fwd.sleep,
    .random = fwd.random,
    .randomSecure = fwd.randomSecure,
    .netListenIp = fwd.netListenIp,
    .netAccept = fwd.netAccept,
    .netBindIp = fwd.netBindIp,
    .netConnectIp = fwd.netConnectIp,
    .netListenUnix = fwd.netListenUnix,
    .netConnectUnix = fwd.netConnectUnix,
    .netSocketCreatePair = fwd.netSocketCreatePair,
    .netWriteFile = fwd.netWriteFile,
    .netClose = fwd017.netClose,
    .netShutdown = fwd.netShutdown,
    .netInterfaceNameResolve = fwd.netInterfaceNameResolve,
    .netInterfaceName = fwd.netInterfaceName,
    .netLookup = fwd.netLookup,
} else .{
    .crashHandler = fwd.crashHandler,
    .async = fwd.async,
    .concurrent = fwd.concurrent,
    .await = fwd.await,
    .cancel = fwd.cancel,
    .groupAsync = fwd.groupAsync,
    .groupConcurrent = fwd.groupConcurrent,
    .groupAwait = fwd.groupAwait,
    .groupCancel = fwd.groupCancel,
    .recancel = fwd.recancel,
    .swapCancelProtection = fwd.swapCancelProtection,
    .checkCancel = fwd.checkCancel,
    .futexWait = fwd.futexWait,
    .futexWaitUncancelable = fwd.futexWaitUncancelable,
    .futexWake = fwd.futexWake,
    .operate = fwd.operate,
    .batchAwaitAsync = fwd.batchAwaitAsync,
    .batchAwaitConcurrent = fwd.batchAwaitConcurrent,
    .batchCancel = fwd.batchCancel,
    .dirCreateDir = fwd.dirCreateDir,
    .dirCreateDirPath = fwd.dirCreateDirPath,
    .dirCreateDirPathOpen = fwd.dirCreateDirPathOpen,
    .dirOpenDir = fwd.dirOpenDir,
    .dirStat = fwd.dirStat,
    .dirStatFile = fwd.dirStatFile,
    .dirAccess = fwd.dirAccess,
    .dirCreateFile = fwd.dirCreateFile,
    .dirCreateFileAtomic = fwd.dirCreateFileAtomic,
    .dirOpenFile = fwd.dirOpenFile,
    .dirClose = fwd.dirClose,
    .dirRead = fwd.dirRead,
    .dirRealPath = fwd.dirRealPath,
    .dirRealPathFile = fwd.dirRealPathFile,
    .dirDeleteFile = fwd.dirDeleteFile,
    .dirDeleteDir = fwd.dirDeleteDir,
    .dirRename = fwd.dirRename,
    .dirRenamePreserve = fwd.dirRenamePreserve,
    .dirSymLink = fwd.dirSymLink,
    .dirReadLink = fwd.dirReadLink,
    .dirSetOwner = fwd.dirSetOwner,
    .dirSetFileOwner = fwd.dirSetFileOwner,
    .dirSetPermissions = fwd.dirSetPermissions,
    .dirSetFilePermissions = fwd.dirSetFilePermissions,
    .dirSetTimestamps = fwd.dirSetTimestamps,
    .dirHardLink = fwd.dirHardLink,
    .fileStat = fwd.fileStat,
    .fileLength = fwd.fileLength,
    .fileClose = fwd.fileClose,
    .fileWritePositional = fwd.fileWritePositional,
    .fileWriteFileStreaming = fwd.fileWriteFileStreaming,
    .fileWriteFilePositional = fwd.fileWriteFilePositional,
    .fileReadPositional = fwd.fileReadPositional,
    .fileSeekBy = fwd.fileSeekBy,
    .fileSeekTo = fwd.fileSeekTo,
    .fileSync = fwd.fileSync,
    .fileIsTty = fwd.fileIsTty,
    .fileEnableAnsiEscapeCodes = fwd.fileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = fwd.fileSupportsAnsiEscapeCodes,
    .fileSetLength = fwd.fileSetLength,
    .fileSetOwner = fwd.fileSetOwner,
    .fileSetPermissions = fwd.fileSetPermissions,
    .fileSetTimestamps = fwd.fileSetTimestamps,
    .fileLock = fwd.fileLock,
    .fileTryLock = fwd.fileTryLock,
    .fileUnlock = fwd.fileUnlock,
    .fileDowngradeLock = fwd.fileDowngradeLock,
    .fileRealPath = fwd.fileRealPath,
    .fileHardLink = fwd.fileHardLink,
    .fileMemoryMapCreate = fwd.fileMemoryMapCreate,
    .fileMemoryMapDestroy = fwd.fileMemoryMapDestroy,
    .fileMemoryMapSetLength = fwd.fileMemoryMapSetLength,
    .fileMemoryMapRead = fwd.fileMemoryMapRead,
    .fileMemoryMapWrite = fwd.fileMemoryMapWrite,
    .processExecutableOpen = fwd.processExecutableOpen,
    .processExecutablePath = fwd.processExecutablePath,
    .lockStderr = fwd.lockStderr,
    .tryLockStderr = fwd.tryLockStderr,
    .unlockStderr = fwd.unlockStderr,
    .processCurrentPath = fwd.processCurrentPath,
    .processSetCurrentDir = fwd.processSetCurrentDir,
    .processSetCurrentPath = fwd.processSetCurrentPath,
    .processReplace = fwd.processReplace,
    .processReplacePath = fwd016.processReplacePath,
    .processSpawn = fwd.processSpawn,
    .processSpawnPath = fwd016.processSpawnPath,
    .childWait = fwd.childWait,
    .childKill = fwd.childKill,
    .progressParentFile = fwd.progressParentFile,
    .now = fwd.now,
    .clockResolution = fwd.clockResolution,
    .sleep = fwd.sleep,
    .random = fwd.random,
    .randomSecure = fwd.randomSecure,
    .netListenIp = fwd.netListenIp,
    .netAccept = fwd.netAccept,
    .netBindIp = fwd.netBindIp,
    .netConnectIp = fwd.netConnectIp,
    .netListenUnix = fwd.netListenUnix,
    .netConnectUnix = fwd.netConnectUnix,
    .netSocketCreatePair = fwd.netSocketCreatePair,
    .netSend = fwd016.netSend,
    .netRead = fwd016.netRead,
    .netWrite = fwd016.netWrite,
    .netWriteFile = fwd.netWriteFile,
    .netClose = fwd016.netClose,
    .netShutdown = fwd.netShutdown,
    .netInterfaceNameResolve = fwd.netInterfaceNameResolve,
    .netInterfaceName = fwd.netInterfaceName,
    .netLookup = fwd.netLookup,
};
