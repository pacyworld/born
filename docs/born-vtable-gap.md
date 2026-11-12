# Born `std.Io.VTable` gap map: Zig 0.17.1

This source analysis maps the requirements for a future Born `std.Io` shim. It
is not a claim that the shim exists.

## Source count and mechanical scope

**The authoritative Zig 0.17.1 source contains 106 `Io.VTable` fields, not
136.** The 0.16.0 source contains 109. A mechanical scan of every declaration
between `pub const VTable = struct` and its closing `};` produces the 106 names
below, in declaration order, with no omissions or duplicates. Producing 136
rows would invent 30 slots that are not in the ABI. A shim compatibility gate
should assert 106 for 0.17.1 and 109 for 0.16.0, and should also compare field
names and function types so that same-count drift cannot pass.

The field declarations are at `I:51-244` and `I16:51-255`. `Io.Operation` is a
separate seven-tag union (`I:246-255`), not seven extra vtable fields.
`Io.Select` is a generic built on groups and queues (`I:1489-1667`), not a
vtable field.

### Sources and notation

- **Zig 0.17.1**: [upstream `lib/std`](https://codeberg.org/ziglang/zig/src/tag/0.17.1/lib/std).
  **I** is `Io.zig`, **K** is `Io/Kqueue.zig`, **T** is `Io/Threaded.zig`,
  **N** is `Io/net.zig`, **P** is `process.zig`, and **PC** is
  `process/Child.zig`. Citations are relative to that tag's `lib/std` tree.
- **Zig 0.16.0**: [upstream `lib/std`](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std).
  **I16** is `Io.zig` and **K16** is `Io/Kqueue.zig`. Citations are relative to
  that tag's `lib/std` tree.
- **Born**: [commit `36677d7c61a3451d3beb5dbbd950dc05f36ca28e`](https://pacyworld.dev/pacyworld/born/commit/36677d7c61a3451d3beb5dbbd950dc05f36ca28e).
  Born citations below are repository-relative paths at this commit.

In signatures, `U` means `?*anyopaque`, `A` means `std.mem.Alignment`,
`StartR` means `*const fn (*const anyopaque, *anyopaque) void`, and `StartG`
means `*const fn (*const anyopaque) void`. Other type names are the `Io`
source's names. `real` means a Kqueue vtable entry has a substantive body with
no observed TODO-only path; it is source status, not runtime evidence. `TODO`
includes entries whose body is wholly `@panic("TODO")` and partial bodies with
an unimplemented path. `missing` means the Kqueue initializer has no entry for
the current field. The initializer itself is at `K:610-662`.

Born coverage describes the shim disposition supported by current Born
primitives:

- **direct**: `EvPort` supplies the evented mechanism.
- **companion**: `born.socket` or `born.process` supplies the operation, with a
  shim state machine and error adaptation still required.
- **hybrid with Io.Threaded**: an explicit, statically selected Threaded slot or
  worker is required. This is composition, not a retry after Born fails.
- **explicit Unsupported**: Born must not claim the operation. The shim must use
  the exact unsupported/concurrency error admitted by that slot's signature.
- **N/A**: no Born primitive is relevant; a concrete hybrid or unsupported
  disposition is still required to construct a complete vtable.
- **construction/capability rejection**: the requested Born-backed profile is
  not exposed. Select an explicit Threaded implementation during initialization,
  or reject that configuration before calls can arrive. This is required when
  the invocation signature has no honest unsupported error.

**Rejection timing is part of the API contract.** Invocation-time rejection is
valid only when the slot's declared error set contains the error being returned:
for example `OptionUnsupported` for IP listen/connect options (`N:200-244`,
`N:309-342`), `OperationUnsupported` for socket pairs and process spawn
(`N:1251-1265`, `P:342-381`), and `Unimplemented` for `netWriteFile`
(`N:1429-1439`). `netShutdown`, `childWait`, `Operation.net_receive`,
`Operation.net_send`, and stream control-buffer operations have no such error
(`N:1000-1008`, `PC:145-152`, `I:345-488`). They require an implementation or
construction/capability rejection, never an invented `error.Unsupported`, a
misleading `NetworkDown`/`Unexpected`, or a panic.

## Concise coverage summary

- Of the **106 actual 0.17.1 fields**, upstream Kqueue has **4 real**, **32
  TODO**, and **70 missing** entries. The real entries are `async`,
  `concurrent`, `await`, and `netBindIp`. These counts describe source bodies
  only. Kqueue is not a usable baseline: its initializer still names removed
  fields including `fileWriteStreaming`, `fileReadStreaming`, `netRead`,
  `netSend`, and `netReceive` (`K:630-660`), while streaming and network
  operations now live behind `operate` (`I:144-147`, `I:246-255`).
- Born directly covers readiness, event batching, wake, timers, and low-level
  cancellation. `EvPort.wait` submits staged kqueue changes and harvests events
  in one call (`src/evport_kqueue.zig:332-397`); wake is at
  `src/evport_kqueue.zig:259-271`; timer add/cancel is at
  `src/evport_kqueue.zig:282-291`.
- Companions cover TCP and Unix listen/accept/connect, stream read/write/close,
  and child spawn/exit/kill on supported targets. They do **not** cover UDP or
  message-oriented send/receive, bind-only sockets, `socketpair`, `shutdown`,
  `sendfile`, asynchronous DNS, or std's complete error taxonomy. Born's narrow
  error sets are visible at `src/io_types.zig:26-69` and `src/io_types.zig:135-190`.
- All 26 dir slots and 28 file slots need the Threaded hybrid. Born can report
  regular-file readiness but has no file/dir operation API
  (`README.md:97-104`). Task/future/group/futex, terminal, cwd, random, and
  interface helpers also need hybrid implementations or explicit rejection.
- `processSpawn`, `childWait`, and `childKill` have a real Born companion only
  on FreeBSD and Linux. Other targets must reject spawn explicitly; Born's
  support contract is at `src/process.zig:1-7` and `src/process.zig:51-53`.
- There is no `Io.Select` slot to fill. Select becomes usable only when group,
  queue, futex, and cancellation semantics work together (`I:1496-1667`).
  `Io.Batch` has four actual slots, `operate`, `batchAwaitAsync`,
  `batchAwaitConcurrent`, and `batchCancel`, with strict completion and cancel
  invariants (`I:573-727`).

## Complete field map

### Runtime, cancellation, futex, operations, and batching (1-19)

| # | VTable slot and signature/purpose | Upstream 0.17 Kqueue | Born coverage | Relevant Born primitive/module |
|---:|---|---|---|---|
| 1 | `crashHandler(U) void` (`I:52`): mark runtime state after a crash. | missing (`K:613-660`) | hybrid with Io.Threaded | No Born task runtime; Threaded handler `T:2106-2112`. |
| 2 | `async(U, result: []u8, result_alignment: A, context: []const u8, context_alignment: A, start: StartR) ?*AnyFuture` (`I:58-70`): run eagerly or return a future. | real (`K:664-676`) | hybrid with Io.Threaded | No Born scheduler/future; `EvPort.wake` is only a completion notification (`src/evport_kqueue.zig:259-271`). |
| 3 | `concurrent(U, result_len: usize, result_alignment: A, context: []const u8, context_alignment: A, start: StartR) ConcurrentError!*AnyFuture` (`I:72-81`): require concurrency. | real (`K:678-727`) | hybrid with Io.Threaded | No Born worker/future runtime; Threaded implementation `T:2170-2214`. |
| 4 | `await(U, any_future: *AnyFuture, result: []u8, result_alignment: A) void` (`I:85-94`): wait and copy the result. | real (`K:729-741`) | hybrid with Io.Threaded | No Born future storage; event waiting is `EvPort.wait` (`src/evport_kqueue.zig:332-397`). |
| 5 | `cancel(U, any_future: *AnyFuture, result: []u8, result_alignment: A) void` (`I:100-109`): cancel, await, and copy the result. | TODO (`K:743-755`) | direct + hybrid with Io.Threaded | `cancelTimer`, `cancelWrite`, `unmonitorRead`, `unwatchProcess`, `purgeFd` (`src/evport_kqueue.zig:221-252`, `src/evport_kqueue.zig:288-317`); future cancellation itself is N/A. |
| 6 | `groupAsync(U, group: *Group, context: []const u8, context_alignment: A, start: StartG) void` (`I:112-121`): add an async group task. | TODO (`K:763-777`) | hybrid with Io.Threaded | No Born group runtime; Select calls this slot at `I:1535-1555`. |
| 7 | `groupConcurrent(U, group: *Group, context: []const u8, context_alignment: A, start: StartG) ConcurrentError!void` (`I:123-132`): add a concurrent group task. | TODO (`K:779-793`) | hybrid with Io.Threaded | No Born group runtime; Select call site `I:1572-1592`. |
| 8 | `groupAwait(U, group: *Group, token: *anyopaque) Cancelable!void` (`I:133`): await all group tasks. | TODO (`K:795-801`) | hybrid with Io.Threaded | No Born group lifetime/token machinery; contract `I:1395-1412`. |
| 9 | `groupCancel(U, group: *Group, token: *anyopaque) void` (`I:134`): cancel and drain all group tasks. | TODO (`K:803-809`) | direct + hybrid with Io.Threaded | Born cancellation primitives can interrupt evented members; no group runtime. Select calls this at `I:1638-1664`. |
| 10 | `recancel(U) void` (`I:136`): re-arm a consumed cancellation request. | missing (`K:613-660`) | hybrid with Io.Threaded | No Born task-local cancellation state; public semantics `I:1434-1441`. |
| 11 | `swapCancelProtection(U, new: CancelProtection) CancelProtection` (`I:137`): swap task cancellation protection. | missing (`K:613-660`) | hybrid with Io.Threaded | No Born task-local state; semantics `I:1443-1473`. |
| 12 | `checkCancel(U) Cancelable!void` (`I:138`): introduce a cancellation point. | missing (`K:613-660`; helper always false at `K:757-761`, `K:1456-1458`) | hybrid with Io.Threaded | No Born task-local cancellation state; semantics `I:1475-1487`. |
| 13 | `futexWait(U, ptr: *const u32, expected: u32, timeout: Timeout) Cancelable!void` (`I:140`): cancelable timed futex wait. | missing (`K:613-660`) | hybrid with Io.Threaded | No Born futex; Threaded path `T:2560-2567`. Needed by `Io.Mutex`, `Condition`, and queues (`I:1716-1746`). |
| 14 | `futexWaitUncancelable(U, ptr: *const u32, expected: u32) void` (`I:141`): uncancelable futex wait. | missing (`K:613-660`) | hybrid with Io.Threaded | No Born futex; Threaded path `T:2569-2574`. |
| 15 | `futexWake(U, ptr: *const u32, max_waiters: u32) void` (`I:142`): wake futex waiters. | missing (`K:613-660`) | hybrid with Io.Threaded | `EvPort.wake` wakes an event loop, not a futex word; Threaded path `T:2576-2581`. |
| 16 | `operate(U, operation: Operation) Cancelable!Operation.Result` (`I:144`): execute one of seven operation tags. | missing; obsolete non-vtable helpers remain at `K:1104-1269` | companion + hybrid with Io.Threaded + construction/capability rejection | `net_read`/`net_write`: `PlainNb` (`src/socket_posix.zig:160-193`). File/device: Threaded. `net_receive`/`net_send` and control-capable operations require Threaded or capability rejection at construction; their error sets admit no invocation-time Unsupported (`I:345-488`). |
| 17 | `batchAwaitAsync(U, batch: *Batch) Cancelable!void` (`I:145`): submit and await at least one completion, without promising task concurrency. | missing (`K:613-660`) | direct + companion + hybrid with Io.Threaded | `EvPort.wait` plus socket state machines; kqueue's staged batch submission `src/evport_kqueue.zig:326-397`. |
| 18 | `batchAwaitConcurrent(U, batch: *Batch, timeout: Timeout) Batch.AwaitConcurrentError!void` (`I:146`): concurrent batch wait with timeout. | missing (`K:613-660`) | direct + companion + hybrid with Io.Threaded | Born I/O concurrency plus `addTimer` deadline (`src/evport_kqueue.zig:282-291`); hybrid file work needs Threaded workers. |
| 19 | `batchCancel(U, batch: *Batch) void` (`I:147`): cancel and drain pending operations, preserving batch invariants. | missing (`K:613-660`) | direct + companion + hybrid with Io.Threaded | `purgeFd`, timer/write cancellation (`src/evport_kqueue.zig:221-252`, `src/evport_kqueue.zig:288-291`); IOCP completion draining `README.md:123-130`. |

### Directory slots (20-45)

Born has no directory operation module. Every row in this section is therefore
**hybrid with Io.Threaded**, not a direct Born implementation. Threaded fills
this complete range at `T:1883-1908`. Offloading must not block a Born loop
thread.

| # | VTable slot and signature/purpose | Upstream 0.17 Kqueue | Born coverage | Relevant Born primitive/module |
|---:|---|---|---|---|
| 20 | `dirCreateDir(U, Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void` (`I:149`): create one directory. | TODO (`K:811-818`) | hybrid with Io.Threaded | N/A; no Born dir API. |
| 21 | `dirCreateDirPath(U, Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus` (`I:150`): create a directory path. | TODO (`K:820-832`) | hybrid with Io.Threaded | N/A. |
| 22 | `dirCreateDirPathOpen(U, Dir, sub_path: []const u8, permissions: Dir.Permissions, options: Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir` (`I:151`): create path and open it. | TODO (`K:834-848`) | hybrid with Io.Threaded | N/A. |
| 23 | `dirOpenDir(U, Dir, sub_path: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir` (`I:152`): open a child directory. | TODO (`K:894-901`) | hybrid with Io.Threaded | N/A. |
| 24 | `dirStat(U, Dir) Dir.StatError!Dir.Stat` (`I:153`): stat a directory. | TODO (`K:850-855`) | hybrid with Io.Threaded | N/A. |
| 25 | `dirStatFile(U, Dir, sub_path: []const u8, options: Dir.StatFileOptions) Dir.StatFileError!File.Stat` (`I:154`): stat a child file. | TODO (`K:857-869`) | hybrid with Io.Threaded | N/A. |
| 26 | `dirAccess(U, Dir, sub_path: []const u8, options: Dir.AccessOptions) Dir.AccessError!void` (`I:155`): test child access. | TODO (`K:870-877`) | hybrid with Io.Threaded | N/A. |
| 27 | `dirCreateFile(U, Dir, sub_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File` (`I:156`): create/open a child file. | TODO (`K:878-885`) | hybrid with Io.Threaded | N/A. |
| 28 | `dirCreateFileAtomic(U, Dir, sub_path: []const u8, options: Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!File.Atomic` (`I:157`): create an atomic-file helper. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 29 | `dirOpenFile(U, Dir, sub_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File` (`I:158`): open a child file. | TODO (`K:886-893`) | hybrid with Io.Threaded | N/A. |
| 30 | `dirClose(U, dirs: []const Dir) void` (`I:159`): close directories. | TODO (`K:902-907`) | hybrid with Io.Threaded | N/A. Void return means no runtime `Unsupported` escape. |
| 31 | `dirRead(U, reader: *Dir.Reader, entries: []Dir.Entry) Dir.Reader.Error!usize` (`I:160`): read directory entries. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 32 | `dirRealPath(U, Dir, out_buffer: []u8) Dir.RealPathError!usize` (`I:161`): resolve a directory path. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 33 | `dirRealPathFile(U, Dir, path_name: []const u8, out_buffer: []u8) Dir.RealPathFileError!usize` (`I:162`): resolve a child path. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 34 | `dirDeleteFile(U, Dir, sub_path: []const u8) Dir.DeleteFileError!void` (`I:163`): delete a child file. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 35 | `dirDeleteDir(U, Dir, sub_path: []const u8) Dir.DeleteDirError!void` (`I:164`): delete a child directory. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 36 | `dirRename(U, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenameError!void` (`I:165`): rename across directories. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 37 | `dirRenamePreserve(U, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenamePreserveError!void` (`I:166`): rename without replacing. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 38 | `dirSymLink(U, Dir, target_path: []const u8, sym_link_path: []const u8, flags: Dir.SymLinkFlags) Dir.SymLinkError!void` (`I:167`): create a symlink. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 39 | `dirReadLink(U, Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize` (`I:168`): read a symlink. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 40 | `dirSetOwner(U, Dir, uid: ?File.Uid, gid: ?File.Gid) Dir.SetOwnerError!void` (`I:169`): change directory owner. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 41 | `dirSetFileOwner(U, Dir, sub_path: []const u8, uid: ?File.Uid, gid: ?File.Gid, options: Dir.SetFileOwnerOptions) Dir.SetFileOwnerError!void` (`I:170`): change child owner. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 42 | `dirSetPermissions(U, Dir, permissions: Dir.Permissions) Dir.SetPermissionsError!void` (`I:171`): change directory permissions. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 43 | `dirSetFilePermissions(U, Dir, sub_path: []const u8, permissions: File.Permissions, options: Dir.SetFilePermissionsOptions) Dir.SetFilePermissionsError!void` (`I:172`): change child permissions. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 44 | `dirSetTimestamps(U, Dir, sub_path: []const u8, options: Dir.SetTimestampsOptions) Dir.SetTimestampsError!void` (`I:173`): change child timestamps. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 45 | `dirHardLink(U, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, options: Dir.HardLinkOptions) Dir.HardLinkError!void` (`I:174`): create a hard link. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |

### File and memory-map slots (46-73)

All rows here are **hybrid with Io.Threaded**. The complete Threaded wiring is
at `T:1910-1938`. Born's regular-file readiness does not supply positional I/O,
metadata, locking, terminal handling, or mapping operations.

| # | VTable slot and signature/purpose | Upstream 0.17 Kqueue | Born coverage | Relevant Born primitive/module |
|---:|---|---|---|---|
| 46 | `fileStat(U, File) File.StatError!File.Stat` (`I:176`): stat a file. | TODO (`K:908-913`) | hybrid with Io.Threaded | N/A; regular-file readiness only (`README.md:97-104`). |
| 47 | `fileLength(U, File) File.LengthError!u64` (`I:177`): get file length. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 48 | `fileClose(U, files: []const File) void` (`I:178`): close files. | TODO (`K:915-920`) | hybrid with Io.Threaded | N/A. Void return means no runtime `Unsupported` escape. |
| 49 | `fileWritePositional(U, File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) File.WritePositionalError!usize` (`I:179`): positioned vectored write. | TODO (`K:938-954`) | hybrid with Io.Threaded | N/A. |
| 50 | `fileWriteFileStreaming(U, File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) File.Writer.WriteFileError!usize` (`I:180`): stream a reader into a file. | missing; removed `fileWriteStreaming` remains TODO (`K:637`, `K:922-936`) | hybrid with Io.Threaded | N/A. |
| 51 | `fileWriteFilePositional(U, File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit, offset: u64) File.WriteFilePositionalError!usize` (`I:181`): positioned reader-to-file copy. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 52 | `fileReadPositional(U, File, data: []const []u8, offset: u64) File.ReadPositionalError!usize` (`I:183`): positioned vectored read. | TODO (`K:964-971`); removed streaming entry also remains (`K:639`) | hybrid with Io.Threaded | N/A. |
| 53 | `fileSeekBy(U, File, relative_offset: i64) File.SeekError!void` (`I:184`): relative seek. | TODO (`K:972-978`) | hybrid with Io.Threaded | N/A. |
| 54 | `fileSeekTo(U, File, absolute_offset: u64) File.SeekError!void` (`I:185`): absolute seek. | TODO (`K:979-985`) | hybrid with Io.Threaded | N/A. |
| 55 | `fileSync(U, File) File.SyncError!void` (`I:186`): sync file data/metadata. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 56 | `fileIsTty(U, File) Cancelable!bool` (`I:187`): test terminal type. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 57 | `fileEnableAnsiEscapeCodes(U, File) File.EnableAnsiEscapeCodesError!void` (`I:188`): enable terminal ANSI mode. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 58 | `fileSupportsAnsiEscapeCodes(U, File) Cancelable!bool` (`I:189`): query ANSI support. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 59 | `fileSetLength(U, File, length: u64) File.SetLengthError!void` (`I:190`): resize a file. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 60 | `fileSetOwner(U, File, uid: ?File.Uid, gid: ?File.Gid) File.SetOwnerError!void` (`I:191`): change file owner. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 61 | `fileSetPermissions(U, File, permissions: File.Permissions) File.SetPermissionsError!void` (`I:192`): change file permissions. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 62 | `fileSetTimestamps(U, File, options: File.SetTimestampsOptions) File.SetTimestampsError!void` (`I:193`): change file timestamps. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 63 | `fileLock(U, File, lock: File.Lock) File.LockError!void` (`I:194`): acquire a file lock. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 64 | `fileTryLock(U, File, lock: File.Lock) File.LockError!bool` (`I:195`): try a file lock. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 65 | `fileUnlock(U, File) void` (`I:196`): release a file lock. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. Void return means no runtime `Unsupported` escape. |
| 66 | `fileDowngradeLock(U, File) File.DowngradeLockError!void` (`I:197`): downgrade a file lock. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 67 | `fileRealPath(U, File, out_buffer: []u8) File.RealPathError!usize` (`I:198`): resolve an open file path. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 68 | `fileHardLink(U, File, new_dir: Dir, new_sub_path: []const u8, options: File.HardLinkOptions) File.HardLinkError!void` (`I:199`): hard-link an open file. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 69 | `fileMemoryMapCreate(U, File, options: File.MemoryMap.CreateOptions) File.MemoryMap.CreateError!File.MemoryMap` (`I:201`): create a memory map. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 70 | `fileMemoryMapDestroy(U, map: *File.MemoryMap) void` (`I:202`): destroy a memory map. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. Void return means no runtime `Unsupported` escape. |
| 71 | `fileMemoryMapSetLength(U, map: *File.MemoryMap, length: usize) File.MemoryMap.SetLengthError!void` (`I:203`): resize a memory map. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 72 | `fileMemoryMapRead(U, map: *File.MemoryMap) File.ReadPositionalError!void` (`I:204`): read map contents from storage. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 73 | `fileMemoryMapWrite(U, map: *File.MemoryMap) File.WritePositionalError!void` (`I:205`): write map contents to storage. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |

### Process, terminal, inheritance, clocks, and random (74-93)

| # | VTable slot and signature/purpose | Upstream 0.17 Kqueue | Born coverage | Relevant Born primitive/module |
|---:|---|---|---|---|
| 74 | `processExecutableOpen(U, options: Dir.OpenFileOptions) std.process.OpenExecutableError!File` (`I:207`): open the current executable. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; Born process API spawns children only. |
| 75 | `processExecutablePath(U, buffer: []u8) std.process.ExecutablePathError!usize` (`I:208`): get executable path. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 76 | `lockStderr(U, mode: ?Terminal.Mode) Cancelable!LockedStderr` (`I:209`): lock and optionally configure stderr. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; no terminal/lock module. |
| 77 | `tryLockStderr(U, mode: ?Terminal.Mode) Cancelable!?LockedStderr` (`I:210`): try stderr lock/configuration. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 78 | `unlockStderr(U) void` (`I:211`): unlock stderr. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. Void return means no runtime `Unsupported` escape. |
| 79 | `processCurrentPath(U, buffer: []u8) std.process.CurrentPathError!usize` (`I:212`): get current working directory. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 80 | `processSetCurrentDir(U, Dir) std.process.SetCurrentDirError!void` (`I:213`): set cwd from a directory. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 81 | `processSetCurrentPath(U, path: []const u8) std.process.SetCurrentPathError!void` (`I:214`): set cwd from a path. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 82 | `processReplace(U, options: std.process.ReplaceOptions) std.process.ReplaceError` (`I:215`): replace the current process image. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; Born `process.spawn` always creates a child (`src/process.zig:152-162`). |
| 83 | `processSpawn(U, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child` (`I:216`): spawn a child. | missing (`K:613-660`) | companion; invocation-time `error.OperationUnsupported` off FreeBSD/Linux | `born.process.spawn` (`src/process.zig:152-162`). Options translation must handle no PATH search (`src/process.zig:67-82`). `OperationUnsupported` is declared at `P:342-345`. |
| 84 | `childWait(U, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term` (`I:217`): wait for child termination. | missing (`K:613-660`) | companion on supported targets; construction/capability rejection elsewhere | `EvPort.watchProcess` and `Event.exit` (`src/evport_kqueue.zig:304-317`, `src/types.zig:149-157`). `WaitError` has no Unsupported (`PC:145-152`), so reject the process capability at construction or spawn, not by inventing a wait error. Reap and clean resources, then invalidate `id` (`src/process.zig:26-42`, `T:15770-15836`, `T:15893-15907`). |
| 85 | `childKill(U, child: *std.process.Child) void` (`I:218`): kill a child. | missing (`K:613-660`) | companion after successful supported spawn | `Child.kill` (`src/process.zig:126-149`) is only the signal step. Std requires an uncancelable exit wait/drain, reap, full resource cleanup, idempotence, and `id = null` (`PC:128-143`, `T:15668-15676`, `T:15849-15907`). The shim must finish all of these; unsupported spawn is rejected before a child exists. |
| 86 | `progressParentFile(U) std.Progress.ParentFileError!File` (`I:220`): obtain progress-reporting parent file. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A. |
| 87 | `inheritParentDir(U, handle: Dir.Handle) InheritParentHandleError!Dir` (`I:221`): inherit a parent directory handle. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; new in 0.17, Threaded body `T:17961-17966`. |
| 88 | `inheritParentFile(U, handle: File.Handle, flags: File.Flags) InheritParentHandleError!File` (`I:222`): inherit a parent file handle. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; new in 0.17, Threaded body `T:17968-17977`. |
| 89 | `now(U, clock: Clock) Timestamp` (`I:224`): read any supported clock. | TODO and stale signature (`K:987-992`) | direct for monotonic only + hybrid with Io.Threaded for full `Clock` | `timer_heap.nowNs` reads only monotonic/QPC (`src/timer_heap.zig:250-255`); Threaded supports all clock tags (`T:11865-11932`). |
| 90 | `clockResolution(U, clock: Clock) Clock.ResolutionError!Duration` (`I:225`): query clock resolution. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; Threaded body `T:11884-11932`. |
| 91 | `sleep(U, timeout: Timeout) Cancelable!void` (`I:226`): sleep to duration/deadline with cancellation. | TODO and stale signature (`K:993-998`) | direct | `EvPort.addTimer`/`cancelTimer`/`wait` (`src/evport_kqueue.zig:282-291`, `src/evport_kqueue.zig:332-397`); deadline/cancel adapter required. |
| 92 | `random(U, buffer: []u8) void` (`I:228`): fill with non-secure random bytes. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; no Born RNG. Threaded CSPRNG `T:17984-18019`. |
| 93 | `randomSecure(U, buffer: []u8) RandomSecureError!void` (`I:229`): fill with secure random bytes. | missing (`K:613-660`) | hybrid with Io.Threaded | N/A; no Born OS entropy wrapper. Threaded body `T:18062-18099`. |

### Network slots (94-106)

| # | VTable slot and signature/purpose | Upstream 0.17 Kqueue | Born coverage | Relevant Born primitive/module |
|---:|---|---|---|---|
| 94 | `netListenIp(U, address: *const net.IpAddress, options: net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Socket` (`I:231`): bind/listen an IP socket. | TODO (`K:1000-1010`) | companion only after option/capability adaptation | `Listener.openTcp` (`src/listener_posix.zig:50-83`). Non-TCP `mode`/`protocol` is invocation-time `OptionUnsupported`; `reuse_address` and forced `SO_REUSEADDR`/V6ONLY/`SO_EXCLUSIVEADDRUSE` mismatches require construction/capability rejection until configurable. Populate `net.Socket.address` through `Listener.localAddress`. See below. |
| 95 | `netAccept(U, server: net.Socket.Handle, options: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket` (`I:232`): accept a connection. | TODO (`K:1011-1017`) | companion | `Listener.register`/`acceptNb` (`src/listener_posix.zig:90-162`), then accepted-stream registration. Populate the result's `net.Socket.address` with `getpeername(out.handle())` as required by both Born listener backends (`src/listener_posix.zig:117-118`, `src/listener_windows.zig:178-185`). |
| 96 | `netBindIp(U, address: *const net.IpAddress, options: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket` (`I:233`): bind without requiring listen. | real (`K:1018-1033`) | invocation-time `error.OptionUnsupported` | Born only exposes bind as part of `Listener.openTcp`; no bind-only/datagram socket API. `OptionUnsupported` is declared (`N:258-282`). |
| 97 | `netConnectIp(U, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket` (`I:234`): connect an IP socket. | TODO: timeout and `EAGAIN` panic (`K:1034-1058`) | companion | `PlainNb.startConnectAddrInto`, `wantWrite`, `connectDone` (`src/socket_posix.zig:56-85`, `src/socket_posix.zig:138-148`). Adapt only `.stream` with `protocol == null or .tcp`; reject other protocols at invocation with `OptionUnsupported`. Implement timeout and populate `net.Socket.address` from the local address/`getsockname`. |
| 98 | `netListenUnix(U, address: *const net.UnixAddress, options: net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle` (`I:235`): listen on a Unix socket. | TODO (`K:1083-1093`) | restricted companion; generic std profile requires Threaded or construction/capability rejection | `Listener.openUnix` (`src/listener_posix.zig:85-88`) cannot preserve std backlog, abstract/NUL, close-unlink, stale-unlink, or chmod semantics. Reject the generic Born capability at construction until these are configurable; Windows maps to declared `AddressFamilyUnsupported` (`N:876-890`). |
| 99 | `netConnectUnix(U, address: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle` (`I:236`): connect a Unix socket. | TODO (`K:1094-1102`) | restricted pathname companion; abstract/NUL requires construction/capability rejection | `PlainNb.startConnectUnixInto` (`src/socket_posix.zig:87-92`) rejects empty/embedded-NUL and Linux abstract addresses (`src/unix_posix.zig:96-108`). Select Threaded for an unrestricted profile; Windows maps to declared `AddressFamilyUnsupported` (`N:910-926`). |
| 100 | `netSocketCreatePair(U, options: net.Socket.CreatePairOptions) net.Socket.CreatePairError![2]net.Socket` (`I:237`): create a connected socket pair. | missing (`K:613-660`) | explicit Unsupported | No public Born socketpair constructor. Test-only `std.c.socketpair` calls are not a companion API (`src/evport_kqueue.zig:543-555`). Invocation-time `error.OperationUnsupported` is declared (`N:1251-1265`). |
| 101 | `netWriteFile(U, handle: net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) net.Stream.Writer.WriteFileError!usize` (`I:238`): stream a file to a socket. | missing (`K:613-660`) | invocation-time `error.Unimplemented` | No Born sendfile/file-to-socket primitive; `PlainNb.writeNb` accepts bytes only (`src/socket_posix.zig:181-193`). `Unimplemented` explicitly requests caller read/copy fallback (`N:1429-1439`, `N:1478-1497`). |
| 102 | `netClose(U, sockets: []const net.Socket) void` (`I:239`): close sockets. | missing; removed TODO `netClose` existed in 0.16 | companion | Purge then `PlainNb.deinit`/`Listener.close` (`src/socket_posix.zig:211-227`, `src/listener_posix.zig:209-219`). Unix close must not inherit Born's automatic unlink when emulating std; see below. |
| 103 | `netShutdown(U, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void` (`I:240`): shut down receive/send/both. | TODO (`K:1271-1277`) | construction/capability rejection or explicit Threaded hybrid | No Born `shutdown(2)` wrapper in `socket.zig` or `socket_posix.zig`; close is not equivalent. `ShutdownError` has no Unsupported (`N:1000-1008`), so select Threaded at construction or reject the capability, never return an invented invocation-time error. |
| 104 | `netInterfaceNameResolve(U, name: *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface` (`I:241`): resolve interface name to index. | TODO (`K:1279-1287`) | hybrid with Io.Threaded | N/A; no Born interface module. Threaded body starts `T:13740-13769`. |
| 105 | `netInterfaceName(U, interface: net.Interface) net.Interface.NameError!net.Interface.Name` (`I:242`): resolve interface index to name. | TODO (`K:1289-1294`) | hybrid with Io.Threaded | N/A; no Born interface module. |
| 106 | `netLookup(U, host_name: net.HostName, results: *Queue(net.HostName.LookupResult), options: net.HostName.LookupOptions) net.HostName.LookupError!void` (`I:243`): asynchronously queue DNS results. | TODO (`K:1296-1308`) | hybrid with Io.Threaded | Born's hostname connect uses the synchronous resolver (`src/socket_posix.zig:45-54`, `README.md:234-240`); no async DNS queue. |

### IP listener/connect adaptation and `net.Socket.address`

Std's IP listen options are `kernel_backlog`, `reuse_address`, `mode`, and
`protocol` (`N:226-244`). Born's TCP listener is not a drop-in implementation
of those options:

- Born accepts only TCP. Validate `mode == .stream` and `protocol == .tcp` for
  `netListenIp`; other connection-oriented modes and protocols admitted by std,
  including `.seqpacket`, `.tp`, `.dccp`, and `.sctp`, need their own
  implementation or invocation-time `error.OptionUnsupported`, which
  `ListenError` declares (`N:200-244`). Do not pass them silently to Born's
  hardcoded `SOCK.STREAM`/`IPPROTO.TCP` (`src/listener_posix.zig:54-82`,
  `src/listener_windows.zig:109-130`).
- Std applies POSIX `SO_REUSEADDR` and `SO_REUSEPORT` only when
  `reuse_address = true` (`T:12110-12126`). Born always sets `SO_REUSEADDR`,
  and its `.balanced` choice selects `SO_REUSEPORT_LB` on FreeBSD rather than
  std's generic `SO_REUSEPORT` (`src/listener_posix.zig:31-37`,
  `src/listener_posix.zig:54-82`). These are different sharing semantics,
  not a rename that the shim may paper over.
- Std IP listen has no `ip6_only` option and Threaded does not force V6ONLY
  (`N:226-244`, `T:12110-12150`). Born always sets V6ONLY from a non-optional
  Born option whose default is `true` (`src/io_types.zig:93-104`,
  `src/listener_posix.zig:63-71`, `src/listener_windows.zig:349-351`).
  Passing Born defaults therefore changes the OS-default behavior std requests.
- On Windows, Born always sets `SO_EXCLUSIVEADDRUSE`
  (`src/listener_windows.zig:42-43`, `src/listener_windows.zig:349-350`).
  Std sets `SO_REUSEADDR` only for `reuse_address = true` and does not force the
  exclusive option (`T:12153-12180`). Born cannot represent either std value
  exactly today.

Consequently, unsupported `mode`/`protocol` values can be rejected at invocation
with `OptionUnsupported`, but the forced option behavior also affects default
calls. A generic std-compatible shim profile must reject Born-backed IP listen
at construction and explicitly select Threaded until Born exposes exact
`reuse_address`, V6ONLY, and Windows reuse semantics. A restricted Born profile
must not be presented as std-compatible.

For `netConnectIp`, std supplies `mode`, optional `protocol`, and `timeout`
(`N:338-342`). Born's companion can adapt only `.stream` with `protocol == null`
or `.tcp`: null follows the normal stream/TCP default, while `.tcp` is explicit.
Other values return declared `error.OptionUnsupported` rather than being
truncated to TCP. Threaded's full mode/protocol mapping illustrates the wider
surface (`T:14552-14573`). The shim must also implement the timeout with a Born
deadline plus connect cancellation; Born's `startConnectAddrInto` alone does not
provide it (`src/socket_posix.zig:56-85`).

Every IP operation returning `net.Socket` must populate its `address`, including
an ephemeral port selected by the kernel (`N:1071-1075`). Use
`Listener.localAddress` after listen (`src/listener_posix.zig:188-207`,
`src/listener_windows.zig:264-285`), `getsockname` for the local address after
connect, and `getpeername(out.handle())` for an accepted peer
(`src/listener_posix.zig:117-118`, `src/listener_windows.zig:178-185`).
This matches Threaded's post-listen and post-connect address queries
(`T:12149-12150`, `T:12521-12525`). Returning an undefined address or merely
copying the requested address is not coverage.

### Unix listener/connect capability decisions

The following differences prevent a generic std-compatible Born Unix profile:

- **Backlog:** std passes `UnixAddress.ListenOptions.kernel_backlog` to
  `listen` (`N:892-897`, `T:12183-12221`). Born ignores any requested value and
  calls `listen(std.math.maxInt(c_int))` (`src/unix_posix.zig:146-155`).
  Until Born accepts a per-listener backlog, reject this capability at
  construction and select Threaded. `UnixAddress.ListenError` has no honest
  invocation-time OptionUnsupported (`N:876-890`).
- **Abstract and embedded-NUL addresses:** std represents abstract addresses by
  an empty path or leading NUL and passes length-delimited paths through its
  conversion (`N:857-874`, `T:14488-14508`). Born rejects every empty path and
  every embedded NUL, explicitly including Linux abstract names
  (`src/unix_posix.zig:5-8`, `src/unix_posix.zig:96-108`). A generic
  unrestricted profile must select Threaded at construction. Born is usable
  only in an explicitly restricted pathname-only profile; it must not turn
  these inputs into `SocketError` or `ConnectFailed` and claim std coverage.
- **Close-unlink:** Born `Listener.close` automatically unlinks the pathname it
  owns after process/inode checks (`src/unix_posix.zig:51-87`,
  `src/listener_posix.zig:214-219`). Std's `netListenUnix` returns only a
  handle and Threaded `netClose` only closes it; it does not unlink the path
  (`T:12183-12221`, `T:13677-13685`). Since `netClose` returns void, this cannot
  be repaired by invocation-time rejection. Generic std compatibility requires
  a no-unlink Born close option or Threaded selected at construction.
- **Stale unlink:** Born also defaults `unlink_stale = true` and may remove a
  stale socket before rebinding (`src/io_types.zig:106-115`,
  `src/unix_posix.zig:159-199`). Threaded's bind reports `AddressInUse`
  without that stale-path removal (`T:12183-12217`). The shim must not opt into
  Born's destructive default while emulating std.
- **chmod:** Born performs `fchmodat(opts.mode)` before listen, with Born's
  default mode `0o660` (`src/io_types.zig:106-115`,
  `src/unix_posix.zig:10-20`, `src/unix_posix.zig:146-155`). Threaded does
  no chmod between bind and listen (`T:12183-12221`), so the socket retains the
  mode produced by bind and the process umask. Preserving std requires a Born
  no-chmod option or construction-time Threaded selection.

The decision for an unrestricted std Unix profile is therefore explicit:
**use Threaded at construction until all of these semantics are configurable**.
A restricted Born Unix listener must document that it is not std-compatible.
Where Born has no Unix support, such as its current Windows backend, map to
std's declared `error.AddressFamilyUnsupported`, not a nonexistent
`error.Unsupported` (`N:876-926`, `README.md:381-385`).

### Process wait/kill lifecycle adaptation

`processSpawn` may reject an unsupported OS at invocation with declared
`error.OperationUnsupported` (`P:342-345`). `childWait` is different: its
`WaitError` contains only `AccessDenied`, `Canceled`, and `Unexpected`
(`PC:145-152`). Unsupported process waiting must therefore be settled by
construction/capability rejection or by the earlier spawn rejection, never by
returning `error.Unsupported` from `childWait`.

Std `Child.kill` is uncancelable and idempotent: it requests termination, waits
for the exit, cleans every resource, and leaves `child.id == null`
(`PC:128-143`). Born `Child.kill` only sends a signal and `Child.close` has
platform-specific reaping behavior (`src/process.zig:126-149`,
`src/process.zig:26-42`). A conforming adapter must therefore:

1. send the std-expected termination signal (`SIGTERM` on POSIX, as at
   `T:15849-15861`), not mistake the signal call for completion;
2. wait uncancelably for and drain the Born exit event, ending any process watch
   and removing staged registrations with `unwatchProcess`/`purgeFd`;
3. reap according to the platform, through Linux's pidfd/`waitid` exit path or
   FreeBSD's final process-descriptor close (`src/process.zig:26-42`);
4. close the process descriptor and all child stdin/stdout/stderr resources,
   release shim-owned watch/result state, and finish cleanup even when the
   signal operation reports an error, matching Threaded's cleanup path
   (`T:15668-15676`, `T:15893-15907`); and
5. invalidate `child.id` by setting it to null so the public idempotence
   assertion holds and later `kill` is a no-op (`PC:128-143`).

`childWait` likewise returns a `Term` only after exit collection, resource
cleanup, and `id` invalidation (`T:15770-15836`, `T:15893-15907`). A Born exit
notification by itself is not the full std wait or kill contract.

## `Operation`, `Io.Batch`, and `Io.Select`

### The seven operation tags behind slot 16

`operate` must dispatch all seven tags and return the matching
`Operation.Result` (`I:246-255`, `I:491-501`). These are not additional VTable
rows.

| Operation tag | Payload/result source | Born disposition |
|---|---|---|
| `file_read_streaming` | `FileReadStreaming` (`I:259-287`) | hybrid with Io.Threaded on a worker. |
| `file_write_streaming` | `FileWriteStreaming` (`I:289-321`) | hybrid with Io.Threaded on a worker. |
| `device_io_control` | `DeviceIoControl` (`I:323-343`) | hybrid with Io.Threaded; no Born device wrapper. |
| `net_receive` | `NetReceive` (`I:345-382`) | Born has no UDP/message receive companion. Its error set has no Unsupported, so use Threaded or reject message-socket capability at construction; there is no valid invocation-time `error.Unsupported`. |
| `net_send` | `NetSend` (`I:384-428`) | Born has no UDP/message send companion. Its error set has no Unsupported, so use Threaded or reject message-socket capability at construction; there is no valid invocation-time `error.Unsupported`. |
| `net_read` | `NetRead` (`I:430-448`) | companion for byte/vector reads through `PlainNb.readNb`. A nonempty control buffer needs recvmsg support or explicit Threaded selection/capability rejection at construction; do not discard it or invent an invocation-time Unsupported absent from this error set. |
| `net_write` | `NetWrite` (`I:450-489`) | companion for vector/splat byte writes through `PlainNb.writeNb`. A nonempty control buffer needs sendmsg support or explicit Threaded selection/capability rejection at construction; do not discard it or invent an invocation-time Unsupported absent from this error set. |

A full generic `operate` cannot rely on a runtime caller voluntarily avoiding
message tags or control buffers. Because those tags' error sets do not admit an
unsupported response (`I:345-488`), the initialization decision must route them
to a valid implementation or withhold the corresponding capability. Returning
success with empty control metadata would silently change the operation.

### Batching requirements

`Batch.add`/`addAt` only queue submissions. `awaitAsync` and `awaitConcurrent`
wait for at least one completion and `next` dequeues completions
(`I:573-697`). `batchCancel` must leave submitted and pending lists empty and
`userdata == null` (`I:699-727`). A shim therefore needs its own per-operation
state, registration ownership, result storage, and cancellation draining; a
single call to `EvPort.wait` is necessary but not sufficient.

Born's kqueue registration batching is directly useful: stage changes, then
submit changelist and eventlist in one `kevent` (`src/evport_kqueue.zig:326-397`).
Do not copy Threaded's `poll` implementation (`T:2646-2800`), because Born's
contract is kqueue/epoll/IOCP only. On IOCP, cancellation and close do not make
`OVERLAPPED` storage immediately reusable; all completions must be drained
(`README.md:123-130`, `src/socket_windows.zig:347-370`).

### Select requirements

`Select(U)` stores an `Io`, a `Group`, and a `Queue(U)` (`I:1496-1513`). Its
`async` and `concurrent` methods call the group slots (`I:1535-1592`), its await
methods dequeue results (`I:1594-1619`), and cancellation combines group and
queue cancellation (`I:1621-1665`). Consequently:

1. Implementing only network operations does not make Select work.
2. Group task result resources must be released as each task finishes, not only
   at group await (`I:1328-1337`).
3. Queue wakeups depend on futex/cancellation behavior, so a fake futex or a
   no-op group cancel is not a valid shortcut.
4. Select cancellation can deadlock if its result buffer is too small for all
   outstanding results; this is an upstream caller contract, not something the
   shim may hide (`I:1621-1629`).

## 0.16.0 to 0.17.1 drift

The VTable shrank by three fields, **109 to 106**, rather than growing to 136.
The declarations are `I16:51-255` and `I:51-244`.

- Removed process slots: `processReplacePath` and `processSpawnPath`
  (`I16:222-225`). Added parent-handle slots: `inheritParentDir` and
  `inheritParentFile` (`I:220-222`).
- Removed direct network slots: `netSend`, `netRead`, and `netWrite`
  (`I16:245-249`). Their 0.17 equivalents are `Operation.net_send`,
  `Operation.net_read`, and `Operation.net_write` behind `operate`
  (`I:246-255`). `Operation` had only four tags in 0.16 (`I16:257-264`) and has
  seven in 0.17.
- `netClose` changed from `[]const net.Socket.Handle` to
  `[]const net.Socket` (`I16:250`, `I:239`).
- Kqueue was not brought up to the new shape. It still initializes removed
  `fileWriteStreaming`, `fileReadStreaming`, `netRead`, `netSend`, and
  `netReceive` fields (`K:637-660`). Its `now` returns
  `Io.Clock.Error!Io.Timestamp` and `sleep` returns `Io.SleepError!void`
  (`K:987-998`), while the 0.17 VTable returns `Timestamp` and
  `Cancelable!void` respectively (`I:224-226`).
- The Kqueue diff is mostly container/builtin renames, but not exclusively:
  0.17 removes the old `netWrite` and `netClose` bodies, fixes `ip6_only` to use
  the requested value, and adds bind `AccessDenied` handling (`K:1383-1390`,
  `K:1393-1418`; compare `K16` at the corresponding `openSocketPosix` and
  `posixBind` bodies). Do not treat the backend as functionally maintained just
  because much of the diff is mechanical.
- 0.17 relaxes the `async`/`groupAsync` comments that guaranteed assignment of
  a unit of concurrency in 0.16 (`I16:54-60`, `I16:114-118`; current
  declarations `I:54-70`, `I:111-121`). Shim behavior must follow the targeted
  tag, not a shared assumption across tags.
- `operateTimeout(.none)` now calls `operate` directly; non-none timeouts use a
  one-element batch (`I:559-570`). This makes correct `operate` necessary even
  for callers that never explicitly construct a large batch.

A shim needs a per-tag compile-time assertion on field count, ordered field
names, and function signatures. A count-only assertion would miss the
`netClose` type change and could miss future remove/add pairs.

## Shim design constraints

1. **Dependency isolation is a hard boundary.** Shim code lives under
   `src/io/`; Born core must never import `std.Io` or `src/io/`. The public core
   exports `EvPort`, native/event and error types, signal helpers, backend
   identification, and the `socket` and `process` companions
   (`src/root.zig:54-101`). CI must reject a back-edge, and the 0.15.2 core
   build must remain independent of `std.Io`.
2. **Never silently fall back.** Hybrid means an explicit per-slot composition
   selected during initialization and visible in `InitOptions`, not
   `born_call() catch -> Threaded`. Network rows marked explicit Unsupported
   must not quietly become blocking Threaded network calls.
3. **Never use `@panic` for missing support.** Return only an error in the
   slot's declared error set. Std does not use one universal error name:
   signatures variously admit `Unsupported`, `OperationUnsupported`,
   `UnsupportedOperation`, `ConcurrencyUnavailable`, or `Unimplemented`.
   `netWriteFile` specifically returns `error.Unimplemented` to request the
   caller's read/copy fallback (`N:1429-1439`). If the needed error is absent,
   as for `netShutdown`, message operations, control buffers, and `childWait`,
   the shim must use construction/capability rejection rather than inventing an
   invocation-time error.
4. **Void slots need up-front policy, not runtime traps.** `groupAsync`,
   `cancel`, `recancel`, `futexWake`, close/unlock functions, `childKill`, and
   `random` cannot return `Unsupported`. They require a valid implementation,
   normally hybrid, or rejection of the feature/configuration before such a
   call can occur. A null function pointer, `unreachable`, or `@panic` is not an
   acceptable substitute.
5. **One `Io.userdata` means adapter thunks are mandatory.** `Io` has one
   userdata pointer and one vtable pointer (`I:25-26`). Born and Threaded expect
   different concrete state, so their raw function pointers cannot simply be
   interleaved with incompatible userdata. Each composed slot needs a thunk
   from the shim state to the correct Born port or Threaded instance.
6. **Hybrid file/dir work must not block the event loop.** Threaded provides
   full slot coverage (`T:1854-1998`), but directly invoking a blocking
   Threaded file operation on a Born loop thread violates Born's event-driven
   contract. Run it on the Threaded worker side and post completion back through
   `EvPort.wake`; preserve cancellation and result lifetime until delivery.
7. **Cancellation is a drain protocol, not a flag.** Future/group/batch cancel
   must wake blocked loops, remove registrations/timers, await hybrid work, and
   leave no stale userdata. On Windows, `cancelAndClose` cancels and closes the
   socket, but the stream storage must remain stable while every completion is
   absorbed (`src/socket_windows.zig:347-370`, `README.md:123-130`). Sleep must
   tie a Born timer to the calling operation's cancellation state.
8. **Preserve readiness semantics.** POSIX reads are edge-triggered and must be
   drained; kqueue writes are one-shot and re-armed on demand
   (`src/evport_kqueue.zig:202-230`). Purge staged changes before close
   (`src/evport_kqueue.zig:232-252`). The shim cannot translate std calls into
   a level-triggered or close-first model without changing behavior.
9. **Error adaptation is part of coverage.** Born's coarse `SocketError`,
   `ConnectFailed`, and `ReadError`/`WriteError` sets do not carry all std
   network errors (`src/io_types.zig:26-69`). A companion row is not complete
   until native errors are preserved or explicitly mapped without inventing
   success. Keep required core additions explicit and independent of the shim
   compatibility layer.
10. **Process support is narrower than std's.** Born has no PATH search and has
    platform-specific descriptor/reaping rules (`src/process.zig:26-42`,
    `src/process.zig:67-107`). Translate supported `SpawnOptions`, reject
    unsupported options explicitly, and adapt `Child`/termination ownership.
    Windows process spawn returns declared `error.OperationUnsupported`, never
    a silent Threaded child that later bypasses Born's wait/cancel model. Both
    wait and kill must drain exit, reap, clean all resources, and invalidate
    `child.id`; kill must also preserve its uncancelable, idempotent contract
    (`PC:128-152`, `T:15658-15676`, `T:15893-15907`).
11. **No timer-driven I/O and no poll/select fallback.** Timers implement
    deadlines only (`README.md:389-390`). I/O waits use Born's native backend.
    Batch concurrency comes from independent native operations and explicit
    Threaded workers, not from periodically polling descriptors.
12. **Gate the actual matrix and real consumers.** Compile every vtable field
    for each supported Zig tag, exercise body references, and run FreeBSD,
    Linux, and Windows runtime tests. Born's test root imports its API and
    companion test modules (`src/root.zig:103-118`); its API tests check exact
    reactor method types (`src/api_test.zig:12-70`) and execute reactor interest
    methods with native handles (`src/api_test.zig:92-116`). Apply that same
    body-reference standard to shim tests rather than relying on declarations
    alone. Use a real `std.Io` consumer. Cross-compilation and a populated
    vtable alone prove neither cancellation nor runtime behavior.

