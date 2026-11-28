//! Born `std.Io` compatibility shim: composite state and per-slot routing.
//!
//! The shim composes Born's event port with upstream's `Io.Threaded` worker
//! pool behind a single `std.Io`. One `Io.userdata` pointer carries the whole
//! composite (`Shim`); every vtable slot is a thunk that recovers the composite
//! and either services the slot on Born's reactor or re-invokes the saved
//! Threaded vtable with the Threaded's own userdata. This is the explicit
//! per-slot routing seam: a capability replaces individual thunks with Born
//! evented implementations while the rest keep delegating to Threaded.
//!
//! The all-Threaded baseline (`baseline_vtable`) delegates every slot to
//! Threaded and spawns no loop thread. `capabilities.network = .born_evented`
//! selects `network_vtable` (the client socket path on Born's reactor);
//! `capabilities.process = .born_evented` selects `process_vtable` (spawn,
//! wait, kill on FreeBSD and Linux). The two compose into
//! `network_process_vtable`. The time family (`sleep`, `now`,
//! `clockResolution`) always stays on the Threaded baseline: a blocking sleep
//! routed through the loop would cost two cross-thread hops and buy nothing,
//! so it is not a Born route (#101).
//!
//! ## Shared loop machinery (network and process routes)
//!
//! - Loop ownership: one dedicated loop thread per instance is the sole caller
//!   of `EvPort.wait` and the sole mutator of port state. After `io()` returns,
//!   the caller must not drive the port itself.
//! - Cross-thread submission: a blocking call stack-allocates one operation
//!   node (`NetOp` / `ProcOp`), takes a slot in the loop-owned slot table,
//!   enqueues the node on the route's mutex-protected intrusive queue, and
//!   calls `wake()` only when the queue went from empty to non-empty. `wake()`
//!   is the only cross-thread port call. The loop swaps the whole queue out
//!   under the mutex and drives the ops on its own thread.
//! - Slot identity: a registry id is the slot index and the port's `udata`
//!   encodes (generation, index) via `slotUdata`. The slot tables are
//!   loop-owned storage in fixed-size chunks that never move: growth allocates
//!   a new chunk and publishes its pointer with release under the queue mutex,
//!   and readers load it with acquire, so the loop never chases a reallocation.
//!   The port never holds a pointer into caller stack. On an event the loop
//!   drops it if the slot is free or the generation does not match, and only
//!   then touches the node. Stale events are normal (a cancel's `EV_DELETE`
//!   can fail to stage under memory pressure), so this check is the structural
//!   use-after-free guard, not an optimization. Connect-deadline timers carry
//!   `net_timer_bit` (bit 63) so their fires route only to
//!   `connectDeadlineFired`; slot generations are masked to 31 bits to keep the
//!   tag space disjoint.
//! - Completion return: the submitter blocks on a cancelable Threaded futex
//!   wait on the node's state word. The loop publishes the terminal state with
//!   a release store and frees the slot under the queue mutex (atomic with the
//!   cancel path's occupancy check), then signals the futex outside the mutex
//!   with a plain `futexWake`. The wake is address-keyed and never reads the
//!   word, so it is safe even if the submitter has already returned and reused
//!   the frame; the store precedes the wake, so no wakeup is lost. Cancellation
//!   composes: Threaded's cancel interrupts the submitter's futex wait; the
//!   submitter sets `cancel_requested` and pushes the slot index on a
//!   dedicated cancel list (links live in the slot table, never in caller
//!   storage), waking the loop only on an empty-to-non-empty transition. The
//!   loop drains that list each cycle and disarms only the canceled nodes; it
//!   never scans the pending population. The submitter drains uncancelably
//!   until retirement before returning, so the loop never touches stack
//!   storage after the call unwinds.
//! - Failure visibility: route-level refusals (port wait failures,
//!   connect-deadline timer-arm refusals, slot-table growth failures, process
//!   arm/flush refusals) are latched in the composite and exposed by
//!   `loopError(io)`. After `wait_fail_limit` consecutive wait failures the
//!   loop retires everything and exits; later submits are rejected.
//! - Deployment is thread-per-core: one port and one instance per core.
//!
//! ## Process route (P5.4)
//!
//! With `capabilities.process = .born_evented` on FreeBSD or Linux,
//! `processSpawn`, `childWait` and `childKill` run on Born's reactor through
//! `born.process` (process descriptors / pidfds) and `EvPort.watchProcess`.
//! Other targets reject the capability at construction. The route adds a
//! second operation family to the shared loop machinery: an uncancelable arm
//! confirmation (spawn parks it until the loop confirms the exit watch), a
//! cancelable exit wait (cancellation abandons the wait; the child stays
//! registered and shim-owned until kill or deinit), and an uncancelable kill
//! drain (caller SIGTERM, then watch teardown, platform reap, descriptor
//! close and slot release on the loop). The caller's `Child` fields are the
//! sole owners of the parent pipe ends after spawn returns (review R1); the
//! wait/kill thunks close and null them on the caller thread, never the
//! loop. One `proc_queue` mutex
//! protects the submission queue, the proc-op slot table and the child
//! registry (pid map plus non-moving chunks). `proc_udata_bit` (bit 16) tags
//! child-registry udata so a failed registration (no filter information)
//! routes to the child registry instead of the socket registry.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const compat = @import("compat");
const io_options = @import("born_io_options");
const neterr016 = @import("neterr016.zig");
const Io = std.Io;

const is_017 = builtin.zig_version.minor >= 17;
const is_windows = builtin.os.tag == .windows;
const is_freebsd = builtin.os.tag == .freebsd;
const is_linux = builtin.os.tag == .linux;

/// Compile-time target support for the process route: process descriptors /
/// pidfds exist only on FreeBSD and Linux. Elsewhere the capability is a
/// construction rejection, never a silent fallback.
pub const process_supported = born.process.supported;

/// Comptime gate for the process-route provenance counters: when false the
/// process path performs no shared counter writes and `processStats` reports
/// zeros. Set by the `process_stats` build option.
pub const process_stats_enabled: bool = io_options.process_stats;

/// Where a capability family is serviced.
pub const Route = enum {
    /// Born's event port (kqueue/epoll/IOCP). Implemented for the stream
    /// client family (IP and pathname Unix connect, stream read/write, close,
    /// shutdown) on every target, and for the process family (spawn, wait,
    /// kill) on FreeBSD and Linux only. Requesting a family that is not
    /// implemented rejects at construction (`CapabilityUnsupported`), never
    /// silently delegates.
    born_evented,
    /// Upstream `Io.Threaded` worker pool.
    threaded,
};

/// Explicit, compile-time-visible capability routing for the hybrid. Every
/// unimplemented Born route is a construction rejection, never a silent
/// fallback. The three remaining families, each with its exact validity:
/// - `network`: the stream client path is implemented on Born on every target.
/// - `process`: implemented on Born on FreeBSD and Linux only (process
///   descriptors / pidfds); elsewhere `.born_evented` rejects at construction.
/// - `file`: no Born route exists on any target; `.born_evented` rejects at
///   construction everywhere. The field is kept so capability routing stays
///   explicit and a future file route has a seam; it carries no route today.
pub const Capabilities = struct {
    /// Stream client path on Born. Valid on every target.
    network: Route = .threaded,
    /// No Born route on any target; `.born_evented` rejects at construction.
    file: Route = .threaded,
    /// Born process descriptors / pidfds. FreeBSD and Linux only.
    process: Route = .threaded,

    pub fn anyBorn(c: Capabilities) bool {
        return c.network == .born_evented or
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
    /// The shim's own event port could not be created (the kernel refused
    /// the reactor or its wake source). A port bookkeeping allocation
    /// failure surfaces as `error.OutOfMemory`.
    SystemResources,
    /// A Born route's loop thread could not be spawned
    /// (`std.Thread.SpawnError`: thread quota, system resources, memory).
    /// Distinct from `OutOfMemory`, which reports composite/pool allocation.
    LoopSpawnFailed,
};

/// Encode a slot identity as the port's opaque timer `udata`.
pub fn slotUdata(index: u32, generation: u32) ?*anyopaque {
    comptime {
        if (@bitSizeOf(usize) < 64) @compileError("born.io slot identity needs a 64-bit usize");
    }
    const encoded: u64 = (@as(u64, generation) << 32) | index;
    return @ptrFromInt(@as(usize, @intCast(encoded)));
}

/// Decode a timer `udata` produced by `slotUdata`.
pub fn decodeSlotUdata(udata: ?*anyopaque) struct { index: u32, generation: u32 } {
    const encoded: u64 = @intCast(@intFromPtr(udata.?));
    return .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
}

// ------------------------------------------------------ network engine ----
//
// The network engine uses the shared loop machinery: a caller-owned `NetOp`
// node, a non-moving net-op slot table with a cancel list and deferred free,
// and a sole-driver loop. A separate socket registry maps the raw std handle
// to a stable `SocketState` (the `PlainNb` plus its pending ops and a
// generation for stale-event rejection). The loop thread is shared:
// `loopMain` drives connect-deadline fires and socket events in one `wait`.

/// Comptime gate for the per-route network counters: when false the network
/// path performs no shared counter writes and `networkStats` reports zeros.
/// Set by the `network_stats` build option.
pub const network_stats_enabled: bool = io_options.network_stats;

/// Provenance of a socket handle. The registry holds Born-owned sockets only;
/// a handle absent from the registry is Threaded-owned and is forwarded to the
/// saved Threaded vtable. A Born-owned handle is never handed to Threaded
/// (Blocker 1): POSIX Born sockets are non-blocking and Windows Born sockets
/// are associated with Born's IOCP port.
const Provenance = enum { born };

/// Born-level outcome of a network operation, set by the loop and mapped to a
/// declared std error by the thunk (section 8 coarse mapping). Synthetic tags
/// disambiguate outcomes that share a Born error name (e.g. setup vs mid-connect
/// `SocketError`).
const NetError = enum {
    connect_refused,
    connect_setup,
    connect_state,
    timeout,
    read_failed,
    write_failed,
    unix_refused,
    unix_setup,
    unix_name_too_long,
    unix_backlog_full,
    unix_unsupported,
    canceled,
    route_dead,
    busy,
};

/// Caller-owned network operation node: one per blocking std network call,
/// stack-allocated by the submitter. Ownership: the submitter
/// owns it until enqueue, the loop from dequeue until the terminal `state`
/// store, the submitter again afterwards. The loop never touches it after
/// retirement. `cursor` is loop-only after enqueue (read/write byte progress).
pub const NetOp = struct {
    /// Submission-queue link (submitter writes before enqueue, loop reads after).
    next: ?*NetOp = null,
    /// Net-op slot index assigned at submit under the net queue mutex.
    slot_index: u32 = 0,
    /// Registry index of the target socket. Read/write/close resolve it at
    /// submit; connect assigns it when the loop creates the socket.
    sock_index: u32 = 0,
    /// Futex word: 0 = pending, 1 = terminal (loop releases, submitter acquires).
    state: std.atomic.Value(u32) = .init(0),
    /// Submitter sets this (release) when its wait observes cancellation.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Loop sets this before the terminal store for a cancel or stop drain.
    /// A close drain sets it only for an op whose submitter requested
    /// cancellation; other parked ops retire route_dead (#106).
    outcome_canceled: bool = false,
    kind: Kind,
    payload: Payload,
    result: Result = .{},
    /// Read/write byte progress; loop-only after enqueue.
    cursor: usize = 0,

    pub const Kind = enum { connect, read, write, close };

    pub const Payload = union(enum) {
        connect: Connect,
        read: Read,
        write: Write,
        close: void,
    };

    pub const Connect = struct {
        target: union(enum) { ip: born.socket.Address, unix: []const u8 },
        /// Born monotonic deadline in ns; 0 = no timeout.
        deadline_ns: u64 = 0,
    };

    pub const Read = struct {
        /// Destination iovecs; caller-owned, valid until completion.
        data: [][]u8,
    };

    pub const Write = struct {
        header: []const u8,
        data: []const []const u8,
        splat: usize,
    };

    pub const Result = struct {
        /// Born-level failure; null on success. The thunk maps it to std.
        err: ?NetError = null,
        /// Connect: the created handle.
        handle: born.Handle = invalidHandle(),
        /// Connect: local address from getsockname.
        address: born.socket.Address = undefined,
        /// Read/write: bytes transferred.
        count: usize = 0,
        /// Read: clean peer close (count bytes may precede it).
        eof: bool = false,
    };
};

/// The platform invalid-handle sentinel for `NetOp.Result.handle`.
fn invalidHandle() born.Handle {
    return if (is_windows) @ptrCast(born.windows.INVALID_SOCKET) else -1;
}

/// Loop-owned net-op slot: occupancy plus cancel-list and free-list links,
/// mirroring the timer `Slot` minus the timer-only `armed`/`generation` (socket
/// events carry the registry generation, not the net-op slot's). All fields
/// are protected by the net queue mutex. Slots live in non-moving chunks.
const NetSlot = struct {
    op: ?*NetOp = null,
    next_free: ?u32 = null,
    cancel_next: ?u32 = null,
    on_cancel_list: bool = false,
};

const net_slots_per_chunk: usize = 64;
const max_net_chunks: usize = 1024;

const NetSlotChunk = struct {
    slots: [net_slots_per_chunk]NetSlot,
};

/// A registered Born-owned socket. The `PlainNb` is embedded so its storage
/// (including Windows OVERLAPPED buffers) stays at a stable address for the
/// socket's lifetime. `generation` is bumped when the slot is handed to a new
/// socket; socket `udata` carries (generation, index) so a stale event for a
/// closed-and-reused fd is dropped. Occupancy/generation/free-list are registry
/// mutex protected; the pending-op pointers and armed flags are loop-only.
const SocketState = struct {
    plain: born.socket.PlainNb = .{},
    provenance: Provenance = .born,
    generation: u32 = 0,
    handle: born.Handle = invalidHandle(),
    occupied: bool = false,
    next_free: ?u32 = null,
    /// Registry index of this slot, set when the loop hands it to a socket.
    /// Lets the loop arm interest without scanning the chunk table.
    index: u32 = 0,
    pending_connect: ?*NetOp = null,
    pending_read: ?*NetOp = null,
    pending_write: ?*NetOp = null,
    read_armed: bool = false,
    write_armed: bool = false,
    deadline_armed: bool = false,
    /// Teardown claimed the slot: closeDrive (POSIX) or cancelAndClose
    /// (Windows) is draining it. New consumer lookups refuse with a dead error
    /// instead of forwarding to Threaded onto a descriptor about to close
    /// (#115). Windows keeps the slot occupied/closing until socketEvent
    /// absorbs every completion; the generation guard protects late ones.
    /// Atomic so `sockUserExit`'s last-release fast path reads it lock-free;
    /// written (release) under the registry mutex, read (acquire) elsewhere.
    closing: std.atomic.Value(bool) = .init(false),
    /// In-flight consumer thunks that resolved this handle through the
    /// counting lookup (`lookupBorn`). The socket is not freed until this
    /// drains to zero, so no recv/send is in flight on the descriptor at close
    /// (#115). The closer itself (`netClose`) and the profile-excluded ops use
    /// the non-counting `sockClassify` and do not contribute.
    users: std.atomic.Value(u32) = .init(0),
    /// A runtime close deferred until `users` drains (#115): closeDrive claims
    /// the slot and retires parked ops, but if callers are still in flight it
    /// stores the close op here and returns without retiring it. The loop's
    /// `netCloseDrain` pass finalizes (sockRetire + retire the close op) once
    /// `users` reaches zero, woken by `sockUserExit`. Null when no close is
    /// pending. Loop-only after closeDrive stores it.
    pending_close: ?*NetOp = null,
    /// Intrusive link in the loop's deferred-close list (#115, review 690 B3).
    /// closeDrive pushes a deferred slot here; `netCloseDrain` walks the list
    /// and pops only entries whose `users` drained to zero, so a wake costs
    /// O(deferred closes), not O(total sockets). Loop-owned; null when not
    /// deferred. Reset by sockFreeLocked so a reused slot starts clean.
    deferred_next: ?*SocketState = null,
    /// Windows: shutdown(.recv/.both) issued. shutdown() does not complete a
    /// pending overlapped WSARecv, so netShutdown cancels it and the loop maps
    /// the abort completion (or a recv posted after shutdown) to EOF.
    shutdown_recv: std.atomic.Value(bool) = .init(false),
};

/// Consumer socket lookup result under the registry mutex (#115). `live`
/// carries the registry index; the counting `lookupBorn` has already
/// incremented the socket's `users`, so the caller must release it with
/// `sockUserExit` on return. `closing` means teardown claimed the slot: return
/// a dead error, never forward to Threaded (the descriptor is about to close).
/// `absent` means the handle is not a Born socket: forward to Threaded.
const SockLookup = union(enum) {
    live: u32,
    closing,
    absent,
};

/// Sockets per registry chunk. `SocketState` embeds a `PlainNb`, which on
/// Windows carries two 16 KiB buffers, so chunks are smaller than the timer
/// table's to bound the preallocated footprint.
const sock_per_chunk: usize = 16;
const max_sock_chunks: usize = 4096;

const SockChunk = struct {
    socks: [sock_per_chunk]SocketState,
};

/// Tag bit marking a connect-deadline timer `udata` in the shared `ev.timer`
/// dispatch. The tag is decisive: a net-tagged fire goes only to
/// `connectDeadlineFired` (a stale one is dropped there). Slot generations are
/// masked to 31 bits so a packed udata never sets the tag accidentally.
const net_timer_bit: u64 = 1 << 63;
/// Slot generations stay below bit 31, which `slotUdata` shifts into bit 63
/// (the network tag). Wrapping at 2^31 reuses keeps the tag space disjoint.
const slot_generation_mask: u32 = 0x7fff_ffff;
/// Connect-deadline timer ids live in the high half of the u32 id space so they
/// never collide with registry slot indices (< 65536).
const net_timer_id_base: u32 = 0x8000_0000;

/// Encode a connect-deadline timer identity (registry index + generation) with
/// the network tag bit set.
fn netTimerUdata(index: u32, generation: u32) ?*anyopaque {
    const base: u64 = @intCast(@intFromPtr(slotUdata(index, generation)));
    return @ptrFromInt(@as(usize, @intCast(base | net_timer_bit)));
}

// ---------------------------------------------------- process machinery ----
//
// P5.4 generalizes the same engine to the process family on FreeBSD and
// Linux: a caller-owned `ProcOp` node (arm confirmation, cancelable exit
// wait, uncancelable kill drain), a non-moving proc-op slot table, and a
// child registry (pid map plus non-moving `ChildState` chunks). One
// `proc_queue` mutex protects all three, the P5.3 discipline unchanged.

/// Tag bit distinguishing a child-registry `udata` from a socket-registry
/// `udata` in the shared event dispatch. The tag is decisive for error
/// events: `translate` returns early on `EV_ERROR` with no filter
/// information, so kind alone cannot separate a failed socket registration
/// from a failed child registration. A tagged error routes to the child
/// registry; an untagged error routes to `socketEvent` unchanged. Child
/// indices stay below bit 16 (the registry ceiling) and child generations
/// are masked to 31 bits, so a child udata carries neither the socket tag
/// space nor `net_timer_bit`.
const proc_udata_bit: u64 = 1 << 16;

/// Encode a child identity (registry index + generation) with the process
/// tag bit set.
fn procUdata(index: u32, generation: u32) ?*anyopaque {
    const base: u64 = @intCast(@intFromPtr(slotUdata(index, generation & slot_generation_mask)));
    return @ptrFromInt(@as(usize, @intCast(base | proc_udata_bit)));
}

/// Decode a child `udata` produced by `procUdata`, stripping the tag. The
/// return type is `decodeSlotUdata`'s own anonymous struct so the two decode
/// paths share one type.
fn decodeProcUdata(udata: ?*anyopaque) @TypeOf(decodeSlotUdata(null)) {
    const raw: u64 = @intCast(@intFromPtr(udata.?));
    return decodeSlotUdata(@ptrFromInt(@as(usize, @intCast(raw & ~proc_udata_bit))));
}

/// Born-level outcome of a process operation, set by the loop and mapped to
/// a declared std error by the thunk (section 8 coarse mapping).
const ProcError = enum {
    /// The exit watch could not be armed (submit refusal, watchProcess
    /// refusal, staged EV_ERROR, or a failed confirming flush).
    arm_failed,
    /// The exit could not be collected (port wait failure, stolen reap).
    wait_failed,
    /// The wait was canceled: the child is abandoned, still shim-owned.
    canceled,
    /// The loop exited before the operation completed.
    route_dead,
    /// A second wait or kill parked on a child that already has one.
    busy,
};

/// Caller-owned process operation node: one per blocking std process call,
/// stack-allocated by the submitter. Ownership follows `NetOp`:
/// the submitter owns it until enqueue, the loop from dequeue until the
/// terminal `state` store, the submitter again afterwards. `arm_next` is
/// loop-only (the FreeBSD staged-arm confirmation list).
pub const ProcOp = struct {
    /// Submission-queue link (submitter writes before enqueue, loop reads after).
    next: ?*ProcOp = null,
    /// Proc-op slot index assigned at submit under the proc queue mutex.
    slot_index: u32 = 0,
    /// Child-registry index of the target child, resolved at submit.
    child_index: u32 = 0,
    /// Child generation at submit; the dead-loop fallback validates it.
    child_gen: u32 = 0,
    /// Futex word: 0 = pending, 1 = terminal (loop releases, submitter acquires).
    state: std.atomic.Value(u32) = .init(0),
    /// Submitter sets this (release) when its wait observes cancellation.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Loop sets this before the terminal store for a cancel/stop drain.
    outcome_canceled: bool = false,
    kind: Kind,
    result: Result = .{},
    /// FreeBSD staged-arm confirmation list link; loop-only.
    arm_next: ?*ProcOp = null,

    pub const Kind = enum { arm, wait, kill };

    pub const Result = struct {
        /// Born-level failure; null on success. The thunk maps it to std.
        err: ?ProcError = null,
        /// Wait: the collected exit. Null when err is set.
        exit: ?born.ProcessExit = null,
    };
};

/// Loop-owned proc-op slot: occupancy plus cancel-list and free-list links,
/// mirroring `NetSlot`. All fields are protected by the proc queue mutex.
const ProcSlot = struct {
    op: ?*ProcOp = null,
    next_free: ?u32 = null,
    cancel_next: ?u32 = null,
    on_cancel_list: bool = false,
};

const proc_slots_per_chunk: usize = 64;
const max_proc_chunks: usize = 1024;

const ProcSlotChunk = struct {
    slots: [proc_slots_per_chunk]ProcSlot,
};

/// A registered shim-owned child. Occupancy/generation/free-list and the
/// pid map are proc queue mutex protected; the pending-op pointers, the
/// exit latch and the watch flags are loop-only. `generation` is bumped
/// when the slot is handed to a new child so a stale exit event for a
/// closed-and-reused descriptor is dropped. The std `Child` fields returned
/// to the caller are the sole owners of the parent pipe ends (review R1);
/// the registry holds only the descriptor and pid, never the stdio ends.
const ChildState = struct {
    // The handle sentinel is platform-typed: -1 on the process-supported
    // POSIX targets, undefined elsewhere (the field is dead storage there and
    // is always overwritten at reservation before any read).
    child: born.process.Child = .{ .handle = if (process_supported) -1 else undefined, .pid = 0 },
    generation: u32 = 0,
    occupied: bool = false,
    next_free: ?u32 = null,
    /// Registry index of this slot, set at reservation.
    index: u32 = 0,
    /// Parked uncancelable arm confirmation (at most one).
    pending_arm: ?*ProcOp = null,
    /// Parked cancelable exit wait (at most one).
    pending_wait: ?*ProcOp = null,
    /// Parked uncancelable kill drain (at most one).
    pending_kill: ?*ProcOp = null,
    /// Exit collected from the event, consumed by wait or kill.
    exit: ?born.ProcessExit = null,
    /// The exit could not be collected (stolen reap, port failure); latched
    /// so a later wait or kill reports Unexpected instead of parking.
    exit_failed: bool = false,
    /// The exit watch is confirmed live in the kernel (synchronous arm).
    watch_armed: bool = false,
    /// The arm failed; the spawn cleanup kill op drives teardown.
    arm_failed: bool = false,
    /// A canceled wait abandoned the child: still watched, no longer
    /// addressable by pid; the loop reaps it on exit, deinit kills it.
    abandoned: bool = false,
};

/// Children per registry chunk and the chunk ceiling: at most
/// `proc_per_chunk * max_child_chunks` (65536) concurrent shim-owned
/// children per instance, the same bound as the timer and net-op tables.
const proc_per_chunk: usize = 64;
const max_child_chunks: usize = 1024;

const ChildChunk = struct {
    children: [proc_per_chunk]ChildState,
};

comptime {
    // Every registry index is encoded in the low 32 bits of a udata, below
    // the process tag bit; a ceiling above it would alias the tag space.
    if (net_slots_per_chunk * max_net_chunks > proc_udata_bit)
        @compileError("net-op slot ceiling exceeds the process udata tag bit");
    if (sock_per_chunk * max_sock_chunks > proc_udata_bit)
        @compileError("socket registry ceiling exceeds the process udata tag bit");
    if (proc_slots_per_chunk * max_proc_chunks > proc_udata_bit)
        @compileError("proc-op slot ceiling exceeds the process udata tag bit");
    if (proc_per_chunk * max_child_chunks > proc_udata_bit)
        @compileError("child registry ceiling exceeds the process udata tag bit");
}

// ---------------------------------------------------- network helpers ----

/// born.Handle -> compat socket argument. On Windows born.Handle is the raw
/// HANDLE (*anyopaque) while compat socket calls take ws2_32.SOCKET; POSIX
/// keeps the fd integer unchanged.
fn compatSock(h: born.Handle) compat.socket_t {
    return if (is_windows) @ptrCast(h) else h;
}

/// Local address of a connected socket via getsockname (section 5.2).
fn localAddress(handle: born.Handle) born.socket.Address {
    var addr: born.socket.Address = undefined;
    var len: compat.socklen_t = @intCast(@sizeOf(born.socket.Address));
    compat.getsockname(compatSock(handle), &addr.any, &len) catch {
        // The connect already succeeded; a refused getsockname degrades to a
        // zero address rather than failing the connection.
        return .{ .in = .{ .port = 0, .addr = 0 } };
    };
    return addr;
}

/// std IpAddress (native-endian port) -> Born native sockaddr (big-endian port).
fn ipToBorn(address: *const Io.net.IpAddress) born.socket.Address {
    return switch (address.*) {
        .ip4 => |a| .{ .in = .{
            .port = std.mem.nativeToBig(u16, a.port),
            .addr = @bitCast(a.bytes),
        } },
        .ip6 => |a| .{ .in6 = .{
            .port = std.mem.nativeToBig(u16, a.port),
            .flowinfo = a.flow,
            .addr = a.bytes,
            .scope_id = a.interface.index,
        } },
    };
}

/// Born native sockaddr -> std IpAddress. Only inet/inet6 reach here (the
/// connect thunk validated the family); anything else degrades to loopback.
fn bornToIp(addr: born.socket.Address) Io.net.IpAddress {
    return switch (addr.any.family) {
        compat.AF.INET => .{ .ip4 = .{
            .bytes = @bitCast(addr.in.addr),
            .port = std.mem.bigToNative(u16, addr.in.port),
        } },
        compat.AF.INET6 => .{ .ip6 = .{
            .bytes = addr.in6.addr,
            .port = std.mem.bigToNative(u16, addr.in6.port),
            .flow = addr.in6.flowinfo,
            .interface = .{ .index = addr.in6.scope_id },
        } },
        else => .{ .ip4 = .loopback(0) },
    };
}

/// First unread destination byte across the read iovecs at byte offset `off`,
/// or null when every iovec is full.
fn readSliceAt(data: [][]u8, off: usize) ?[]u8 {
    var pos = off;
    for (data) |buf| {
        if (pos < buf.len) return buf[pos..];
        pos -= buf.len;
    }
    return null;
}

/// Total bytes a std write describes: header once, each data buffer except the
/// last once, and the last buffer (the pattern) repeated `splat` times.
fn writeTotal(header: []const u8, data: []const []const u8, splat: usize) usize {
    var total = header.len;
    if (data.len == 0) return total;
    for (data[0 .. data.len - 1]) |buf| total += buf.len;
    total += splat * data[data.len - 1].len;
    return total;
}

/// The slice to write at byte offset `off` of the flattened header+data+splat
/// stream, or null when the stream is exhausted. A one-byte pattern is expanded
/// into `fill` (a 64-byte run, matching Threaded's splat_buffer_size); a longer
/// pattern is written one repetition at a time. `fill` is caller stack storage
/// valid for the returned slice's lifetime (one writeNb call).
fn writeSliceAt(header: []const u8, data: []const []const u8, splat: usize, off: usize, fill: *[64]u8) ?[]const u8 {
    var pos = off;
    if (pos < header.len) return header[pos..];
    pos -= header.len;
    if (data.len == 0) return null;
    for (data[0 .. data.len - 1]) |buf| {
        if (pos < buf.len) return buf[pos..];
        pos -= buf.len;
    }
    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0) return null;
    const splat_total = splat * pattern.len;
    if (pos >= splat_total) return null;
    if (pattern.len == 1) {
        const n = @min(splat_total - pos, fill.len);
        @memset(fill[0..n], pattern[0]);
        return fill[0..n];
    }
    return pattern[pos % pattern.len ..];
}

/// Coarse read/write error map (section 8): a failed Born read/write becomes
/// ConnectionResetByPeer; anything else Unexpected. Cancellation is raised by
/// the thunk as the outer error, never mapped here.
fn mapIoError(e: NetError) error{ ConnectionResetByPeer, Unexpected } {
    return switch (e) {
        .read_failed, .write_failed => error.ConnectionResetByPeer,
        else => error.Unexpected,
    };
}

/// Coarse IP connect error map (section 8).
fn mapConnectIpError(e: NetError) Io.net.IpAddress.ConnectError {
    return switch (e) {
        .connect_refused => error.ConnectionRefused,
        .connect_setup => error.SystemResources,
        .connect_state => error.Unexpected,
        .timeout => error.Timeout,
        else => error.Unexpected,
    };
}

/// Coarse Unix connect error map (section 8). 0.16's UnixAddress.ConnectError
/// lacks ConnectionRefused, so a refusal degrades to Unexpected there (mirrors
/// Threaded 0.16); 0.17 carries it.
fn mapConnectUnixError(e: NetError) Io.net.UnixAddress.ConnectError {
    return switch (e) {
        .unix_refused => if (is_017) error.ConnectionRefused else error.Unexpected,
        .unix_setup => error.SystemResources,
        .unix_name_too_long => error.FileNotFound,
        .unix_backlog_full => error.WouldBlock,
        .unix_unsupported => error.AddressFamilyUnsupported,
        else => error.Unexpected,
    };
}

/// Coarse shutdown error map (section 8): compat.shutdown's richer set folded
/// into std ShutdownError.
fn mapShutdownError(e: compat.ShutdownError) Io.net.ShutdownError {
    return switch (e) {
        error.ConnectionAborted => error.ConnectionAborted,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.SocketNotConnected => error.SocketUnconnected,
        error.NetworkSubsystemFailed => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.BlockingOperationInProgress, error.Unexpected => error.Unexpected,
    };
}

/// Consecutive `wait` failures with no successful wait between them before
/// the loop retires everything and exits. One-shot stashed failures (a refused
/// wake trigger, a transient allocation failure) are retried; a persistently
/// broken port must not spin the loop. The first failure is latched and
/// readable via `loopError`.
const wait_fail_limit: u32 = 8;

fn shimFrom(userdata: ?*anyopaque) *Shim {
    return @ptrCast(@alignCast(userdata.?));
}

/// Dead-route result for a consumer thunk refused by the instance entry gate
/// (#113): the instance is tearing down, so the call returns without touching
/// any route mutex, `threaded_io` or descriptor. Error-bearing results follow
/// the shim's route-death convention (`error.Unexpected` where the set declares
/// it, else `error.Canceled`, else the first declared error); infallible
/// results get a zero value. The pick is comptime-checked against the slot's
/// declared return type, so a wrong choice fails to compile.
fn deadResult(comptime T: type) T {
    switch (@typeInfo(T)) {
        .error_union => |eu| return deadError(eu.error_set),
        .error_set => return deadError(T),
        .void => {},
        .optional => return null,
        else => return std.mem.zeroes(T),
    }
}

/// The dead-route error for an error set: prefer `error.Unexpected`, then
/// `error.Canceled`, then the first declared error. `inline for` with comptime
/// guards analyzes each literal's set membership only where it applies;
/// `compat.errorSetNames` normalizes the two reflection layouts (0.16 optional
/// fields, 0.17 `error_names`).
fn deadError(comptime E: type) E {
    const names = comptime compat.errorSetNames(E);
    inline for (names) |name| {
        if (comptime std.mem.eql(u8, name, "Unexpected")) return error.Unexpected;
    }
    inline for (names) |name| {
        if (comptime std.mem.eql(u8, name, "Canceled")) return error.Canceled;
    }
    return @field(anyerror, names[0]);
}

/// Dead-route refusal for an infallible value producer (review 690 B1, group c).
/// These slots have no error channel, so a refusal that returns a fabricated
/// value silently corrupts the caller: `async` returning null means "start ran
/// inline" (it did not, so the result is uninitialized); `await`/`cancel`
/// returning without writing `result` leaves garbage; `random` leaves stale
/// bytes; `now` returns a zero timestamp that corrupts deadlines. The contract
/// failure is therefore loud: panic naming the call. `async` could instead run
/// `start` inline, but a uniform panic is simpler and equally correct on a dead
/// route. `futexWaitUncancelable` joins this group: a silent post-gate return
/// would let a mutex/condvar waiter proceed without the lock, and forwarding
/// uncounted could block deinit forever, so it panics too.
fn deadPanic(comptime call: []const u8) noreturn {
    @panic("Io." ++ call ++ " used during or after deinit");
}

/// Test-only poison for the owned port: the loop-death test sets this before
/// constructing the instance, `io()` closes the port's kernel descriptor(s)
/// right after creation and clears the flag, so the loop's first waits fail
/// deterministically. Read and cleared only inside test builds; no effect in
/// any other build.
pub var test_poison_port: bool = false;

/// Test-only interception of the group (c) refusal. The 0.16 standalone test
/// runner has no `--test-filter`, so an in-suite subprocess cannot assert the
/// real `@panic` abort portably; instead a test installs `test_dead_panic_hook`
/// and `deadRefuse` records the exact contract message and returns, letting the
/// test assert the refusal path without aborting the suite. Production (and any
/// test without the hook) takes `deadPanic` and aborts. The real abort is also
/// exercised by the stress suite and the #108-style external rc=134 checks.
var test_dead_panic_hook: ?*const fn (msg: []const u8) void = null;

/// Group (c) refusal with a return type: panic in production, record-and-return
/// under the test hook. The returned value is undefined and only ever observed
/// by a test that asserts the hook fired (never used as a real result).
fn deadRefuse(comptime call: []const u8, comptime T: type) T {
    if (builtin.is_test) {
        if (test_dead_panic_hook) |hook| {
            hook("Io." ++ call ++ " used during or after deinit");
            return undefined;
        }
    }
    deadPanic(call);
}

/// Result of a successful submission: the assigned slot and whether the
/// queue went from empty to non-empty (the only case that needs a wake).
const SubmitResult = struct { index: u32, was_empty: bool };

/// Interception of the loop-thread guard for tests, mirroring the
/// `test_dead_panic_hook` seam: installing this hook replaces the abort with a
/// message record so the guard can be observed without killing the suite.
var test_loop_guard_hook: ?*const fn (msg: []const u8) void = null;

/// Slots that never wait and so stay callable on a Born loop thread. Names
/// are checked at comptime against the active Io.VTable (below).
const loop_exempt = [_][]const u8{
    "now",                  "clockResolution",    "checkCancel", "random",     "randomSecure",
    "swapCancelProtection", "async",              "concurrent",  "groupAsync", "groupConcurrent",
    "crashHandler",         "progressParentFile",
};

comptime {
    // Toolchain drift in a slot name must be a build error, not a silently
    // dead exemption.
    for (loop_exempt) |name| {
        if (!@hasField(Io.VTable, name)) @compileError("blockingLoopCheck exemption '" ++ name ++ "' is not an Io.VTable field on this toolchain");
    }
}

/// Guard against a Born loop thread entering a blocking I/O call.
/// Exempt slots never park (they do not wait for Threaded or the reactor):
/// query/status and pure submission slots. Debug and ReleaseSafe trip;
/// ReleaseFast elides the check entirely. Returns true when the check
/// tripped under the test hook, so the caller takes its dead-route refusal
/// instead of forwarding; in production the check panics instead of
/// returning.
fn blockingLoopCheck(comptime caller: []const u8) bool {
    inline for (loop_exempt) |e| {
        if (comptime std.mem.eql(u8, caller, e)) return false;
    }
    if (!compat.asserts_active) return false;
    if (!born.loop_thread.isMarked()) return false;
    if (builtin.is_test) {
        if (test_loop_guard_hook) |hook| {
            hook("Io." ++ caller ++ " called on a Born loop thread");
            return true;
        }
    }
    std.debug.panic("Io.{s} called on a Born loop thread", .{caller});
}

/// The composite carried by the single `Io.userdata` pointer.
pub const Shim = struct {
    /// Born's event port, created and owned by the shim; `deinit` tears it
    /// down. With a Born route enabled the loop thread is its sole driver;
    /// the baseline leaves it untouched.
    port: born.EvPort,
    allocator: std.mem.Allocator,
    capabilities: Capabilities,
    threaded: Io.Threaded,
    threaded_io: Io,
    /// The Born routes' loop thread; null on the all-Threaded baseline.
    loop: ?std.Thread = null,
    /// Set by `deinit`; the loop retires every pending operation and exits.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Instance entry gate and in-flight consumer-call count (teardown drain,
    /// #113). Bit 31 is `closing`, set by `deinit` before any free; bits 0..30
    /// count the consumer vtable calls currently inside a thunk. A call claims
    /// a slot with a CAS that refuses once `closing` is set, so a thunk rejects
    /// with its dead-route error before touching any route mutex, `threaded_io`
    /// or descriptor. `deinit` drains the count to zero before freeing the
    /// composite: the word outlives every counted caller, so no thunk touches
    /// freed storage. The count is bounded by live caller threads (asserted).
    entry: std.atomic.Value(u32) = .init(0),
    /// Set (release) by closeDrive when it defers a runtime close awaiting the
    /// socket's `users` drain (#115); the loop's `netCloseDrain` pass runs only
    /// while this is set and clears it (acquire) once no deferred close remains.
    /// The normal loop path pays a single atomic load per iteration.
    has_deferred_close: std.atomic.Value(bool) = .init(false),
    /// Head of the intrusive deferred-close list (#115, review 690 B3).
    /// closeDrive pushes; netCloseDrain pops entries whose `users` reached
    /// zero. Loop-owned (both run on the loop thread); the push happens under
    /// the registry mutex only to pair the closing claim with sockUserExit.
    deferred_close_head: ?*SocketState = null,
    /// First route-level failure (wait refusal, timer-arm refusal, slot
    /// growth refusal), as `@intFromError`; 0 = none. First writer wins.
    loop_error: std.atomic.Value(u16) = .init(0),

    // ------------------------------------------------ network route state ----

    /// Network submission queue: intrusive FIFO of caller-owned `NetOp` nodes
    /// (O(1) critical sections, never held across `wait`, uncancelable, `dead`
    /// after the loop exits). Its mutex also protects the net-op slot table's
    /// occupancy, free list and cancel list.
    net_queue: struct {
        mutex: Io.Mutex = .init,
        head: ?*NetOp = null,
        tail: ?*NetOp = null,
        dead: bool = false,
        /// Idle-gate: set (release) under the mutex when a submit or cancel
        /// request takes a list empty-to-non-empty; the loop's drain reads it
        /// acquire and skips the lock when empty, clearing it under the mutex
        /// after the swap. A racing submit re-sets it and wakes the loop
        /// (was_empty), so a skipped drain is always followed by another cycle.
        pending: std.atomic.Value(bool) = .init(false),
    } = .{},
    /// Loop-owned net-op slot table (non-moving chunks).
    net_chunks: [max_net_chunks]std.atomic.Value(?*NetSlotChunk) = @splat(.init(null)),
    net_chunk_count: usize = 0,
    net_free_head: ?u32 = null,
    net_cancel_head: ?u32 = null,

    /// Socket registry: handle -> registry index, plus the non-moving
    /// `SocketState` chunk table. The mutex protects the map and the table's
    /// occupancy/generation/free list; the loop never holds it across `wait`.
    /// Submitters resolve a handle to its index under this mutex, release it,
    /// then enqueue under `net_queue.mutex` (never both at once, so no lock
    /// order inversion with the loop).
    registry: struct {
        mutex: Io.Mutex = .init,
        map: std.AutoHashMap(born.Handle, u32) = undefined,
        chunks: [max_sock_chunks]std.atomic.Value(?*SockChunk) = @splat(.init(null)),
        chunk_count: usize = 0,
        free_head: ?u32 = null,
        initialized: bool = false,
        /// Set when the Windows exit drain's wait fails (#106): completions
        /// may still reference the chunk table's OVERLAPPED storage, so
        /// registryDeinit leaks the table instead of freeing it. Loop-only
        /// at exit.
        exit_drain_failed: bool = false,
    } = .{},

    /// Per-route network counters, fed by the loop on Born-route completions
    /// and by the thunks on Threaded forwards; read via `networkStats`.
    net_stats: struct {
        connect: std.atomic.Value(u64) = .init(0),
        read: std.atomic.Value(u64) = .init(0),
        write: std.atomic.Value(u64) = .init(0),
        threaded_connect: std.atomic.Value(u64) = .init(0),
        threaded_read: std.atomic.Value(u64) = .init(0),
        threaded_write: std.atomic.Value(u64) = .init(0),
    } = .{},

    // ------------------------------------------------ process route state ----

    /// Process submission queue: intrusive FIFO of caller-owned `ProcOp`
    /// nodes, the same discipline as `net_queue`. Its mutex also protects
    /// the proc-op slot table, the child registry's occupancy/generation/
    /// free list and the pid map: one lock for the whole family, so a
    /// submitter reserves a child slot and enqueues its arm op atomically.
    proc_queue: struct {
        mutex: Io.Mutex = .init,
        head: ?*ProcOp = null,
        tail: ?*ProcOp = null,
        dead: bool = false,
        /// Idle-gate: see net_queue.pending.
        pending: std.atomic.Value(bool) = .init(false),
    } = .{},
    /// Loop-owned proc-op slot table (non-moving chunks).
    proc_chunks: [max_proc_chunks]std.atomic.Value(?*ProcSlotChunk) = @splat(.init(null)),
    proc_chunk_count: usize = 0,
    proc_free_head: ?u32 = null,
    proc_cancel_head: ?u32 = null,

    /// Child registry: pid -> registry index, plus the non-moving
    /// `ChildState` chunk table. Protected by `proc_queue.mutex` (one lock
    /// for queue, op slots and registry). The pid entry is removed before
    /// the reaping close so a recycled pid never resolves to a dying slot.
    child_registry: struct {
        map: std.AutoHashMap(i32, u32) = undefined,
        chunks: [max_child_chunks]std.atomic.Value(?*ChildChunk) = @splat(.init(null)),
        chunk_count: usize = 0,
        free_head: ?u32 = null,
        initialized: bool = false,
    } = .{},

    /// FreeBSD staged-arm confirmation list: arm ops whose EV_ADD is staged
    /// and awaits the zero-timeout flush. Loop-only.
    proc_arm_head: ?*ProcOp = null,

    /// Test-only fault injection: when true, the next arm flush reports a
    /// wait failure without touching the port (review R2 flush-failure
    /// unit). Reset by the flush. The flush check is guarded by
    /// `builtin.is_test`, so the hook is comptime-dead outside test builds.
    test_flush_fault: bool = false,
    /// Test-only fault injection: when non-null, procRetireOp overwrites the
    /// retiring node's slot_index with this value right after the terminal
    /// store, simulating a submitter that returned and reused its frame
    /// (born#111). Reset by the retirement. The check is guarded by
    /// `builtin.is_test`, so the hook is comptime-dead outside test builds.
    test_proc_frame_reuse: ?u32 = null,
    /// Test-only reuse injection (#114): when non-null, childCleanup calls it
    /// with the just-freed slot index after the unlock and before the close,
    /// simulating a worker that reserves and publishes the same slot in that
    /// window. Reset by childCleanup. The check is guarded by `builtin.is_test`,
    /// so the hook is comptime-dead outside test builds.
    test_child_cleanup_reuse: ?*const fn (*Shim, u32) void = null,
    /// Test-only park counter address (#116): when non-zero, the read/write
    /// drive paths bump the pointed-to counter each time an op parks and wake
    /// its waiters, so tests synchronize on the actual park instead of a
    /// fixed sleep that races thread startup under scheduler load. Atomic
    /// because the test installs/clears it while the loop runs. Guarded by
    /// `builtin.is_test`, so the signal is comptime-dead outside test builds.
    test_net_parked: std.atomic.Value(usize) = .init(0),
    /// Test-only deferred-close wake counter (#117 B2): bumped at the
    /// sockUserExit slow path's port.wake, so the racing closer/releaser test
    /// asserts "a deferred close implies a wake" without a running loop.
    /// Comptime-dead outside test builds.
    test_exit_wakes: std.atomic.Value(u32) = .init(0),

    /// Per-route process counters, fed by the loop on Born-route completions
    /// and by the thunks on Threaded forwards; read via `processStats`.
    proc_stats: struct {
        spawn: std.atomic.Value(u64) = .init(0),
        wait: std.atomic.Value(u64) = .init(0),
        kill: std.atomic.Value(u64) = .init(0),
        threaded_spawn: std.atomic.Value(u64) = .init(0),
        threaded_wait: std.atomic.Value(u64) = .init(0),
        threaded_kill: std.atomic.Value(u64) = .init(0),
    } = .{},

    /// Latch the first route-level failure; later failures do not overwrite.
    fn latch(self: *Shim, err: anyerror) void {
        const code: u16 = @intFromError(err);
        _ = self.loop_error.cmpxchgStrong(0, code, .acq_rel, .monotonic);
    }

    /// The latched failure, if any. Internal form used by `loopError`.
    fn latchedError(self: *const Shim) ?anyerror {
        const code = self.loop_error.load(.acquire);
        if (code == 0) return null;
        return @errorFromInt(code);
    }

    /// Entry-gate bit layout: bit 31 = closing, bit 30 = dead, bits 0..29 =
    /// in-flight count. `closing` refuses new consumer entries; `dead` is set
    /// only after the drain completes (before `threaded.deinit`) and stops
    /// release thunks from counting, since Threaded is about to be freed.
    const entry_closing: u32 = 1 << 31;
    const entry_dead: u32 = 1 << 30;
    const entry_count_mask: u32 = entry_dead - 1;

    /// Claim an in-flight slot at consumer-thunk entry, before any route mutex,
    /// `threaded_io` or descriptor touch. Returns false once `deinit` has set
    /// the closing gate, so the thunk rejects with its dead-route error. The
    /// CAS pairs the closing check with the increment: a call that observes
    /// `closing` never increments, and `deinit`'s drain sees every call that
    /// incremented before the gate was set.
    fn entryEnter(self: *Shim) bool {
        var w = self.entry.load(.monotonic);
        while (true) {
            if (w & entry_closing != 0) return false;
            std.debug.assert(w & entry_count_mask < entry_count_mask);
            w = self.entry.cmpxchgWeak(w, w + 1, .acq_rel, .monotonic) orelse return true;
        }
    }

    /// Claim an in-flight slot for a wake/release thunk. Unlike `entryEnter`,
    /// this counts through the drain window (`closing` set, Threaded still
    /// alive): release contracts must hold until `threaded.deinit` runs
    /// (unlockStderr releasing a counted lockStderr waiter, groupCancel awaiting
    /// its tasks, fileClose closing fds). Only `dead`, set after the drain,
    /// makes the call uncounted. The CAS pairs the dead check with the increment
    /// so no release slips in between the drain's zero-count check and its dead
    /// store (review 6231).
    fn releaseEnter(self: *Shim) bool {
        var w = self.entry.load(.monotonic);
        while (true) {
            if (w & entry_dead != 0) return false;
            std.debug.assert(w & entry_count_mask < entry_count_mask);
            w = self.entry.cmpxchgWeak(w, w + 1, .acq_rel, .monotonic) orelse return true;
        }
    }

    /// Release an in-flight slot at consumer-thunk return. When the last caller
    /// exits, wake the teardown drain. The fetchSub touches only the count bits
    /// (the closing and dead bits, once set, stay set); the wake is address-keyed
    /// and never reads the word, mirroring the retire wake discipline.
    fn entryExit(self: *Shim) void {
        const prev = self.entry.fetchSub(1, .acq_rel);
        if (prev & entry_count_mask == 1) {
            self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &self.entry.raw, 1);
        }
    }

    /// Teardown drain: set the closing gate, wait until every in-flight thunk
    /// has returned, then set `dead` before `threaded.deinit`. Event-driven
    /// (futex on the entry word, no timer or poll). Consumer entries refuse once
    /// `closing` is set, but release thunks still count through the drain window,
    /// so the count can rise again until `dead` is stored. The final CAS pairs
    /// the zero-count check with the dead store: a release that observes !dead
    /// increments first, failing the CAS, and the drain waits for it too.
    /// `threaded_io` is live throughout (before `threaded.deinit`); the loop has
    /// already retired the parked operations the thunks were waiting on.
    /// Termination assumes finite drain-window releases: a caller looping on a
    /// release thunk forever is misuse and would hold the count above zero.
    fn entryCloseAndDrain(self: *Shim) void {
        var w = self.entry.fetchOr(entry_closing, .acq_rel) | entry_closing;
        while (true) {
            if (w & entry_count_mask == 0) {
                w = self.entry.cmpxchgWeak(w, w | entry_dead, .acq_rel, .acquire) orelse return;
                continue;
            }
            self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &self.entry.raw, w);
            w = self.entry.load(.acquire);
        }
    }

    /// The loop thread: sole driver of the port for the network and process
    /// routes. Each cycle drains the network cancel list and swaps out the
    /// network submission queue, then the process cancel list and queue;
    /// drives the swapped network ops (try-before-park) and the swapped
    /// process ops (synchronous arm, wait/kill drive); blocks in `wait`;
    /// dispatches connect-deadline timer fires, socket events and child
    /// exits. Retires everything on stop or persistent port failure.
    fn loopMain(self: *Shim) void {
        born.loop_thread.mark();
        defer born.loop_thread.unmark();
        var events: [64]born.Event = undefined;
        var fail_streak: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            const net_batch = self.netDrainLocked();
            self.netArmBatch(net_batch);
            const proc_batch = self.procDrainLocked();
            self.procArmBatch(proc_batch);
            const n = self.port.wait(&events, null) catch |err| {
                self.latch(err);
                fail_streak += 1;
                if (fail_streak >= wait_fail_limit) break;
                // The next cycle drains the cancel lists again, so requests
                // carried by a refused wake are still serviced.
                continue;
            };
            fail_streak = 0;
            for (events[0..n]) |ev| {
                self.dispatchEvent(ev);
            }
            // Finalize any runtime close whose socket users drained (#115).
            if (self.has_deferred_close.load(.acquire)) self.netCloseDrain();
        }
        const stopped = self.stopping.load(.acquire);
        self.netRetireAll(stopped);
        self.procRetireAll(stopped);
    }

    /// Kind-first event dispatch, shared by the main wait and the FreeBSD
    /// arm-confirming flush. Timer fires are connect deadlines (`net_timer_bit`);
    /// child exits and tagged errors split on `proc_udata_bit`; everything else
    /// is a socket event. Error events carry no filter information, so the
    /// udata tag is decisive there (section 4.3).
    fn dispatchEvent(self: *Shim, ev: born.Event) void {
        if (ev.timer) {
            // The only timers are connect deadlines (network route); the tag
            // is set by netTimerUdata and a stale fire is dropped inside
            // connectDeadlineFired.
            _ = self.connectDeadlineFired(ev.udata);
        } else if (ev.wake) {
            // Cross-thread wakeup only; the queues were drained above.
        } else if (ev.exited or (ev.err and ev.udata != null and
            @as(u64, @intCast(@intFromPtr(ev.udata.?))) & proc_udata_bit != 0))
        {
            self.childEvent(ev);
        } else {
            self.socketEvent(ev);
        }
    }

    // -------------------------------------------- network engine methods ----

    /// Resolve a net-op slot index to its stable storage (acquire pairs with the
    /// release publication at growth). Field access follows the net queue mutex
    /// discipline.
    fn netSlotAt(self: *Shim, index: u32) *NetSlot {
        const chunk = self.net_chunks[index / net_slots_per_chunk].load(.acquire).?;
        return &chunk.slots[index % net_slots_per_chunk];
    }

    /// Allocate one net-op chunk and thread its slots onto the free list. Net
    /// queue mutex held, or construction before the loop starts.
    fn netGrowLocked(self: *Shim) error{OutOfMemory}!void {
        if (self.net_chunk_count >= max_net_chunks) return error.OutOfMemory;
        const chunk = self.allocator.create(NetSlotChunk) catch return error.OutOfMemory;
        chunk.* = .{ .slots = undefined };
        const base = self.net_chunk_count * net_slots_per_chunk;
        var i: usize = net_slots_per_chunk;
        while (i > 0) {
            i -= 1;
            chunk.slots[i] = .{ .next_free = self.net_free_head };
            self.net_free_head = @intCast(base + i);
        }
        self.net_chunks[self.net_chunk_count].store(chunk, .release);
        self.net_chunk_count += 1;
    }

    fn netAllocSlotLocked(self: *Shim) error{OutOfMemory}!u32 {
        if (self.net_free_head == null) try self.netGrowLocked();
        const head = self.net_free_head.?;
        self.net_free_head = self.netSlotAt(head).next_free;
        return head;
    }

    fn netFreeSlotLocked(self: *Shim, index: u32) void {
        const slot = self.netSlotAt(index);
        slot.next_free = self.net_free_head;
        self.net_free_head = index;
    }

    fn netFreeChunks(self: *Shim) void {
        for (&self.net_chunks) |*c| {
            if (c.load(.monotonic)) |chunk| self.allocator.destroy(chunk);
        }
    }

    /// Enqueue a caller-owned network node into a fresh net-op slot. Returns
    /// null after the loop exits (`net_queue.dead`) or on a growth refusal.
    fn netSubmit(self: *Shim, op: *NetOp) ?SubmitResult {
        self.net_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.net_queue.mutex.unlock(self.threaded_io);
        if (self.net_queue.dead) return null;
        const index = self.netAllocSlotLocked() catch {
            self.latch(error.OutOfMemory);
            return null;
        };
        const slot = self.netSlotAt(index);
        slot.op = op;
        slot.cancel_next = null;
        op.slot_index = index;
        op.next = null;
        const was_empty = self.net_queue.head == null;
        if (self.net_queue.tail) |tail| tail.next = op else self.net_queue.head = op;
        self.net_queue.tail = op;
        if (was_empty) self.net_queue.pending.store(true, .release);
        return .{ .index = index, .was_empty = was_empty };
    }

    /// Push the node's net-op slot on the cancel list unless retired or already
    /// linked. Returns whether the list went empty-to-non-empty.
    fn netRequestCancel(self: *Shim, op: *NetOp) bool {
        self.net_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.net_queue.mutex.unlock(self.threaded_io);
        const slot = self.netSlotAt(op.slot_index);
        if (slot.op != op) return false;
        if (slot.on_cancel_list) return false;
        const was_empty = self.net_cancel_head == null;
        slot.cancel_next = self.net_cancel_head;
        slot.on_cancel_list = true;
        self.net_cancel_head = op.slot_index;
        if (was_empty) self.net_queue.pending.store(true, .release);
        return was_empty;
    }

    /// One critical section: drain the network cancel list, then swap out the
    /// whole submission list. Driven ops on the cancel list are chained for
    /// disarm/retire/wake OUTSIDE the mutex (port calls and futexWake must not
    /// lengthen the submitter-facing lock, the `netRetireOp` shape); entries
    /// for ops still in the swapped queue are left to `netArmOrRetire`'s
    /// `cancel_requested` check.
    fn netDrainLocked(self: *Shim) ?*NetOp {
        // Idle-gate: skip the drain lock when the pending flag reads empty.
        // The load is acquire, pairing with the submitter's release store under
        // the mutex, so the happens-before edge holds by the memory model rather
        // than by platform practice. A submission racing this check sets pending
        // under the lock and, finding the queue empty, wakes the loop (was_empty),
        // so the next cycle drains it; no submission is lost.
        if (!self.net_queue.pending.load(.acquire)) return null;
        self.net_queue.mutex.lockUncancelable(self.threaded_io);
        var driven: ?*NetOp = null;
        var idx = self.net_cancel_head;
        self.net_cancel_head = null;
        while (idx) |i| {
            const slot = self.netSlotAt(i);
            const next = slot.cancel_next;
            slot.cancel_next = null;
            slot.on_cancel_list = false;
            if (slot.op) |op| {
                if (self.opIsPending(op)) {
                    // A driven op is off the submission queue, so its stale
                    // batch link is reusable as the cancel-chain link. A
                    // cancel re-push before the retire below defers the slot
                    // free (on_cancel_list), which the next drain completes.
                    op.next = driven;
                    driven = op;
                }
            } else {
                self.netFreeSlotLocked(i);
            }
            idx = next;
        }
        const head = self.net_queue.head;
        self.net_queue.head = null;
        self.net_queue.tail = null;
        // Both lists are now empty under the lock; clear pending here so a
        // concurrent enqueue (after unlock) re-sets it and wakes the loop.
        self.net_queue.pending.store(false, .monotonic);
        self.net_queue.mutex.unlock(self.threaded_io);
        var node = driven;
        while (node) |op| {
            const next = op.next;
            self.netRetireOp(op, true);
            node = next;
        }
        return head;
    }

    /// Whether the loop has already driven this op (its socket pending pointer
    /// refers to it). Loop-only field access, no registry mutex needed.
    fn opIsPending(self: *Shim, op: *NetOp) bool {
        const state = self.sockAt(op.sock_index) orelse return false;
        return switch (op.kind) {
            .connect => state.pending_connect == op,
            .read => state.pending_read == op,
            .write => state.pending_write == op,
            .close => false,
        };
    }

    fn netArmBatch(self: *Shim, head: ?*NetOp) void {
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.netArmOrRetire(op);
            node = next;
        }
    }

    fn netArmOrRetire(self: *Shim, op: *NetOp) void {
        // A close must always run (std netClose is infallible), even if the
        // submitter requested cancellation; every other op retires as canceled.
        if (op.kind != .close and op.cancel_requested.load(.acquire)) return self.netRetireOp(op, true);
        switch (op.kind) {
            .connect => self.connectArm(op),
            .read => self.readDrive(op),
            .write => self.writeDrive(op),
            .close => self.closeDrive(op),
        }
    }

    /// Mark the net queue dead and retire every queued and driven network op,
    /// then close any remaining registered sockets. Loop thread, just before
    /// exit. A stop request retires ops as canceled; a failure exit retires
    /// them as route_dead (the thunks map it to Unexpected), never as the
    /// caller's cancellation.
    fn netRetireAll(self: *Shim, stopped: bool) void {
        self.net_queue.mutex.lockUncancelable(self.threaded_io);
        self.net_queue.dead = true;
        const head = self.net_queue.head;
        self.net_queue.head = null;
        self.net_queue.tail = null;
        self.net_queue.pending.store(false, .monotonic);
        var idx = self.net_cancel_head;
        self.net_cancel_head = null;
        while (idx) |i| {
            const slot = self.netSlotAt(i);
            const next = slot.cancel_next;
            slot.cancel_next = null;
            slot.on_cancel_list = false;
            if (slot.op == null) self.netFreeSlotLocked(i);
            idx = next;
        }
        const chunk_count = self.net_chunk_count;
        self.net_queue.mutex.unlock(self.threaded_io);
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.netRetireRoute(op, stopped);
            node = next;
        }
        var ci: usize = 0;
        while (ci < chunk_count) : (ci += 1) {
            const chunk = self.net_chunks[ci].load(.acquire).?;
            for (&chunk.slots) |*slot| {
                if (slot.op) |op| self.netRetireRoute(op, stopped);
            }
        }
        self.registryCloseAll();
    }

    /// Retire one op whose route died: a user close of its socket (stopped
    /// false) or the loop's failure exit. Canceled only for a stop request or
    /// an op whose submitter already requested cancellation; route_dead
    /// otherwise. Route death is not the caller's cancellation (section 4.5);
    /// the thunks map route_dead to Unexpected so a consumer sees the dead
    /// route instead of a quiet stop.
    fn netRetireRoute(self: *Shim, op: *NetOp, stopped: bool) void {
        const canceled = stopped or op.cancel_requested.load(.acquire);
        if (!canceled) op.result.err = .route_dead;
        self.netRetireOp(op, canceled);
    }

    /// Disarm interest and clear the socket pending pointer for a retiring op.
    /// Loop-only fields and port calls; no registry mutex (the pending pointers
    /// and armed flags are written only by the loop).
    fn disarmOp(self: *Shim, op: *NetOp) void {
        const state = self.sockAt(op.sock_index) orelse return;
        switch (op.kind) {
            .connect => {
                if (state.pending_connect == op) {
                    state.pending_connect = null;
                    if (state.deadline_armed) {
                        self.port.cancelTimer(net_timer_id_base + op.slot_index);
                        state.deadline_armed = false;
                    }
                    if (state.write_armed) {
                        self.port.cancelWrite(state.handle);
                        state.write_armed = false;
                    }
                }
            },
            .read => {
                if (state.pending_read == op) {
                    state.pending_read = null;
                    // Read interest is persistent (armed once at connect,
                    // removed only at close): a readable event with no pending
                    // read just records the hint, so a completed parked read
                    // does not unmonitor/re-arm on the hot path.
                }
            },
            .write => {
                if (state.pending_write == op) {
                    state.pending_write = null;
                    if (state.write_armed) {
                        self.port.cancelWrite(state.handle);
                        state.write_armed = false;
                    }
                }
            },
            .close => {},
        }
    }

    /// Disarm, publish the terminal state and free the net-op slot under the net
    /// queue mutex, then wake the submitter outside it.
    fn netRetireOp(self: *Shim, op: *NetOp, canceled: bool) void {
        self.disarmOp(op);
        self.net_queue.mutex.lockUncancelable(self.threaded_io);
        self.netRetireLocked(op, op.slot_index, canceled);
        self.net_queue.mutex.unlock(self.threaded_io);
        self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &op.state.raw, 1);
    }

    /// Net queue mutex held: terminal store plus slot release, no wake. A slot
    /// still on the cancel list is deferred (its entry must drain first).
    fn netRetireLocked(self: *Shim, op: *NetOp, index: u32, canceled: bool) void {
        op.outcome_canceled = canceled;
        op.state.store(1, .release);
        const slot = self.netSlotAt(index);
        slot.op = null;
        if (!slot.on_cancel_list) self.netFreeSlotLocked(index);
    }

    fn netRetireOk(self: *Shim, op: *NetOp, count: usize, eof: bool) void {
        op.result.count = count;
        op.result.eof = eof;
        self.netRetireOp(op, false);
    }

    fn netRetireErr(self: *Shim, op: *NetOp, e: NetError) void {
        op.result.err = e;
        self.netRetireOp(op, false);
    }

    /// Submitter-side completion wait for a network op: enqueue, conditional
    /// wake, cancelable futex wait, and on cancellation request the disarm then
    /// drain uncancelably until the
    /// loop retires the node (it must never touch this stack storage after we
    /// return). Returns error.Canceled on any cancellation path; a submit
    /// refusal (dead queue or growth OOM) completes the op with route_dead,
    /// which the thunk maps to Unexpected. On normal completion the thunk
    /// inspects `op.result`.
    fn netWait(self: *Shim, op: *NetOp) Io.Cancelable!void {
        const submitted = self.netSubmit(op) orelse {
            op.result.err = .route_dead;
            return;
        };
        if (submitted.was_empty) self.port.wake();
        while (true) {
            self.threaded_io.vtable.futexWait(self.threaded_io.userdata, &op.state.raw, 0, .none) catch |err| switch (err) {
                error.Canceled => {
                    op.cancel_requested.store(true, .release);
                    if (self.netRequestCancel(op)) self.port.wake();
                    while (op.state.load(.acquire) == 0) {
                        self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &op.state.raw, 0);
                    }
                    return error.Canceled;
                },
            };
            if (op.state.load(.acquire) != 0) break;
        }
        if (op.outcome_canceled) return error.Canceled;
    }

    /// Uncancelable completion wait for a close op. std `netClose` is void and
    /// infallible and must close even while the calling task unwinds from
    /// cancellation, so this never honors a cancel request: it drains until the
    /// loop retires the close. `closeDrive` always closes the socket regardless
    /// of `cancel_requested`. If the loop is already dead the socket is closed
    /// by `registryCloseAll` at exit instead.
    fn netCloseWait(self: *Shim, op: *NetOp) void {
        const submitted = self.netSubmit(op) orelse return;
        if (submitted.was_empty) self.port.wake();
        while (op.state.load(.acquire) == 0) {
            self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &op.state.raw, 0);
        }
    }

    /// Batch provenance gate (section 10): walk the submitted list, detach every
    /// Born-owned socket member and complete it with its tag result
    /// `error.Unexpected` (no socket touch, never submitted to Born or Threaded).
    /// Threaded-owned and file/device members stay in `submitted` for the
    /// forwarded Threaded await, which appends its completions after these.
    /// Returns whether any Born-owned member was completed.
    fn batchPartitionBorn(self: *Shim, batch: *Io.Batch) bool {
        var found = false;
        var prev: Io.Operation.OptionalIndex = .none;
        var index = batch.submitted.head;
        while (index != .none) {
            const storage = &batch.storage[index.toIndex()];
            const next = storage.submission.node.next;
            const handle = net01x.batchSocketHandle(storage.submission.operation);
            const is_born = if (handle) |h| self.sockClassify(h) != .absent else false;
            if (is_born) {
                found = true;
                switch (prev) {
                    .none => batch.submitted.head = next,
                    else => |p| batch.storage[p.toIndex()].submission.node.next = next,
                }
                if (next == .none) batch.submitted.tail = prev;
                const result = net01x.batchUnexpectedResult(storage.submission.operation);
                switch (batch.completed.tail) {
                    .none => batch.completed.head = index,
                    else => |t| batch.storage[t.toIndex()].completion.node.next = index,
                }
                storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
                batch.completed.tail = index;
            } else {
                prev = index;
            }
            index = next;
        }
        return found;
    }

    // ---------------------------------------------------- socket registry ----

    /// Resolve a registry index to its stable storage, or null if the index is
    /// past the chunk ceiling or the chunk was never published, so a stale
    /// event udata drops before any table access. Lock-free acquire load;
    /// field access follows the registry
    /// mutex (occupancy/generation) or loop-only ownership (pending pointers,
    /// armed flags).
    fn sockAt(self: *Shim, index: u32) ?*SocketState {
        const chunk_index = index / sock_per_chunk;
        if (chunk_index >= max_sock_chunks) return null;
        const chunk = self.registry.chunks[chunk_index].load(.acquire) orelse return null;
        return &chunk.socks[index % sock_per_chunk];
    }

    /// Initialize the registry map and preallocate the first socket chunk.
    /// Construction, before the loop starts.
    fn registryInit(self: *Shim) error{OutOfMemory}!void {
        self.registry.map = std.AutoHashMap(born.Handle, u32).init(self.allocator);
        self.registry.initialized = true;
        try self.sockGrowLocked();
    }

    fn sockGrowLocked(self: *Shim) error{OutOfMemory}!void {
        if (self.registry.chunk_count >= max_sock_chunks) return error.OutOfMemory;
        const chunk = self.allocator.create(SockChunk) catch return error.OutOfMemory;
        chunk.* = .{ .socks = undefined };
        const base = self.registry.chunk_count * sock_per_chunk;
        var i: usize = sock_per_chunk;
        while (i > 0) {
            i -= 1;
            chunk.socks[i] = .{ .next_free = self.registry.free_head };
            self.registry.free_head = @intCast(base + i);
        }
        self.registry.chunks[self.registry.chunk_count].store(chunk, .release);
        self.registry.chunk_count += 1;
    }

    fn sockAllocLocked(self: *Shim) error{OutOfMemory}!u32 {
        if (self.registry.free_head == null) try self.sockGrowLocked();
        const head = self.registry.free_head.?;
        self.registry.free_head = self.sockAt(head).?.next_free;
        return head;
    }

    fn sockFreeLocked(self: *Shim, index: u32) void {
        const state = self.sockAt(index).?;
        state.occupied = false;
        // Reset teardown state so a reused slot starts clean (#115): a stale
        // `closing` would make the next closeDrive early-return, and a stale
        // `users`/`pending_close`/`deferred_next` would corrupt the next drain.
        state.closing.store(false, .monotonic);
        state.users.store(0, .monotonic);
        state.pending_close = null;
        state.deferred_next = null;
        state.next_free = self.registry.free_head;
        self.registry.free_head = index;
    }

    fn sockFreeChunks(self: *Shim) void {
        for (&self.registry.chunks) |*c| {
            if (c.load(.monotonic)) |chunk| {
                self.allocator.destroy(chunk);
                // Null the published pointer so the table never references
                // freed storage.
                c.store(null, .monotonic);
            }
        }
    }

    /// Release the registry map and socket chunks. Called at deinit after the
    /// loop has closed every remaining socket, and on construction failure.
    /// If the Windows exit drain's wait failed (#106), completions may still
    /// reference the chunk table's OVERLAPPED storage: leak the table rather
    /// than free it (closing a handle does not make pending completion
    /// storage safe to free). A bounded leak at instance teardown on a rare
    /// double-failure path.
    fn registryDeinit(self: *Shim) void {
        if (!self.registry.initialized) return;
        self.registry.map.deinit();
        if (!self.registry.exit_drain_failed) self.sockFreeChunks();
        self.registry.initialized = false;
    }

    /// Submit-time provenance gate: resolve a std handle to its registry index,
    /// or null if it is not Born-owned (forward to Threaded). Registry mutex.
    /// Counting consumer lookup (#115): resolve a handle to its registry index
    /// and claim a `users` hold so the socket outlives this thunk. A closing
    /// slot returns `.closing` (the caller returns a dead error, never forwards
    /// onto a descriptor about to close); an unmapped handle returns `.absent`
    /// (forward to Threaded). The hold is released by `sockUserExit`.
    fn lookupBorn(self: *Shim, handle: born.Handle) SockLookup {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        defer self.registry.mutex.unlock(self.threaded_io);
        switch (self.sockClassifyLocked(handle)) {
            .live => |index| {
                _ = self.sockAt(index).?.users.fetchAdd(1, .acq_rel);
                return .{ .live = index };
            },
            else => |r| return r,
        }
    }

    /// Non-counting classification (#115): same tri-state as `lookupBorn` but
    /// without a `users` hold. Used by the closer itself (which must not count
    /// against its own drain), the batch provenance gate, and the
    /// profile-excluded ops that return a dead result without touching the fd.
    fn sockClassify(self: *Shim, handle: born.Handle) SockLookup {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        defer self.registry.mutex.unlock(self.threaded_io);
        return self.sockClassifyLocked(handle);
    }

    /// Registry mutex held: map membership plus closing tri-state. A mapped
    /// handle always refers to an occupied slot in production (sockRetire
    /// unregisters and frees under this same mutex), so membership is the
    /// source of truth; `closing` distinguishes a slot under teardown.
    fn sockClassifyLocked(self: *Shim, handle: born.Handle) SockLookup {
        if (!self.registry.initialized) return .absent;
        const index = self.registry.map.get(handle) orelse return .absent;
        const state = self.sockAt(index) orelse return .absent;
        if (state.closing.load(.acquire)) return .closing;
        return .{ .live = index };
    }

    /// Release a counting-lookup hold (#115). The slot is stable while
    /// `users` > 0 (it is not freed until the drain completes), so the
    /// lock-free `sockAt` is safe. On the last release, wake a blocking exit
    /// drain (`sockDrainUsers`) and, if the slot is closing, wake the loop to
    /// finalize a deferred runtime close (`netCloseDrain`). The common exit
    /// (slot not closing) returns without the registry mutex (review 690 B2);
    /// only a closing slot takes the mutex to re-check occupancy, pairing with
    /// the finalize pass, which frees the slot under the same mutex.
    fn sockUserExit(self: *Shim, index: u32) void {
        const state = self.sockAt(index) orelse return;
        if (state.users.fetchSub(1, .seq_cst) != 1) return;
        self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &state.users.raw, 1);
        // Fast path: a non-closing slot needs no lock. seq_cst pairs with
        // closeDrive's seq_cst closing store + users load (store-buffer
        // pattern; the total-order argument is at closeDrive): if closeDrive
        // deferred (read users > 0 after its store), this load must observe
        // closing, so the last release always wakes the loop.
        if (!state.closing.load(.seq_cst)) return;
        self.registry.mutex.lockUncancelable(self.threaded_io);
        const wake = state.occupied and state.closing.load(.acquire);
        self.registry.mutex.unlock(self.threaded_io);
        if (wake) {
            if (builtin.is_test) _ = self.test_exit_wakes.fetchAdd(1, .monotonic);
            self.port.wake();
        }
    }

    /// Blocking drain of a socket's in-flight consumer thunks before close,
    /// used only by the exit path (`registryCloseAll`) where the net queue is
    /// already dead and every parked op retired, so no caller can park anew
    /// and the count only falls to zero. Event-driven futex on `users`; the
    /// runtime close path defers instead (`closeDrive`/`netCloseDrain`) because
    /// the live loop must keep servicing submissions while callers drain.
    fn sockDrainUsers(self: *Shim, state: *SocketState) void {
        while (true) {
            const n = state.users.load(.acquire);
            if (n == 0) return;
            self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &state.users.raw, n);
        }
    }

    fn registerHandle(self: *Shim, handle: born.Handle, index: u32) error{OutOfMemory}!void {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        defer self.registry.mutex.unlock(self.threaded_io);
        self.registry.map.put(handle, index) catch return error.OutOfMemory;
    }

    /// Remove the handle mapping only if it still refers to this index (a newer
    /// connect may have reused the fd number and overwritten the entry).
    fn unregisterHandle(self: *Shim, handle: born.Handle, index: u32) void {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        defer self.registry.mutex.unlock(self.threaded_io);
        self.unregisterHandleLocked(handle, index);
    }

    /// Registry mutex held: remove the handle mapping only if it still refers
    /// to this index (a newer connect may have reused the fd number and
    /// overwritten the entry).
    fn unregisterHandleLocked(self: *Shim, handle: born.Handle, index: u32) void {
        if (self.registry.map.get(handle)) |cur| {
            if (cur == index) _ = self.registry.map.remove(handle);
        }
    }

    /// Snapshot a registered socket under the registry mutex, checking occupancy.
    fn sockSnapshot(self: *Shim, index: u32) ?*SocketState {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        defer self.registry.mutex.unlock(self.threaded_io);
        const state = self.sockAt(index) orelse return null;
        if (!state.occupied) return null;
        return state;
    }

    /// Free a socket slot and remove its handle mapping. Registry mutex.
    fn sockFree(self: *Shim, state: *SocketState, index: u32) void {
        self.unregisterHandle(state.handle, index);
        self.registry.mutex.lockUncancelable(self.threaded_io);
        self.sockFreeLocked(index);
        self.registry.mutex.unlock(self.threaded_io);
    }

    /// Retire a socket on the loop thread. POSIX purges staged registrations,
    /// then closes the descriptor, drops the handle mapping and frees the slot
    /// under ONE registry mutex hold, so a consumer lookup never resolves the
    /// handle to a closed fd (#115); `closing` is already set and `users`
    /// drained before this runs. Holding the mutex across close assumes close
    /// does not block (no `SO_LINGER` with a nonzero linger on these sockets).
    /// Windows unregisters before cancelAndClose and keeps the slot
    /// occupied/closing until socketEvent absorbs every completion (the stable
    /// OVERLAPPED storage must outlive the drain); the generation guard still
    /// protects late completions.
    fn sockRetire(self: *Shim, state: *SocketState, index: u32) void {
        if (is_windows) {
            self.unregisterHandle(state.handle, index);
            state.plain.cancelAndClose();
            state.closing.store(true, .release);
            if (state.plain.pendingOps() == 0) self.sockFree(state, index);
        } else {
            self.port.purgeFd(state.handle);
            self.registry.mutex.lockUncancelable(self.threaded_io);
            state.plain.deinit();
            self.unregisterHandleLocked(state.handle, index);
            self.sockFreeLocked(index);
            self.registry.mutex.unlock(self.threaded_io);
        }
    }

    /// Total outstanding overlapped ops across occupied registry slots (the
    /// Windows exit-drain termination condition). Loop-only at exit: every op
    /// is retired and the net queue is dead, so no submitter can post more.
    fn registryPendingOps(self: *Shim) usize {
        if (!is_windows) return 0;
        var total: usize = 0;
        var ci: usize = 0;
        while (ci < self.registry.chunk_count) : (ci += 1) {
            const chunk = self.registry.chunks[ci].load(.acquire).?;
            for (&chunk.socks) |*state| {
                if (state.occupied) total += state.plain.pendingOps();
            }
        }
        return total;
    }

    /// Close every remaining registered socket (loop exit). Loop thread.
    /// Phase 1 retires each socket (unregister before close; Windows keeps
    /// occupied/closing slots for the drain). Phase 2 (Windows) dispatches the
    /// drained completions through socketEvent with no timeout until the total
    /// outstanding ops reach zero, so each completion reaches its OWN socket's
    /// absorbCompletion and no OVERLAPPED storage is freed with ops pending.
    /// A failed phase-2 wait latches the error and marks the chunk table
    /// leaked (registryDrainFailed): the drain cannot prove the completions
    /// are done, so registryDeinit must not free the storage (#106).
    fn registryCloseAll(self: *Shim) void {
        if (!self.registry.initialized) return;
        self.has_deferred_close.store(false, .release);
        self.deferred_close_head = null;
        const chunk_count = self.registry.chunk_count;
        var ci: usize = 0;
        while (ci < chunk_count) : (ci += 1) {
            const chunk = self.registry.chunks[ci].load(.acquire).?;
            for (&chunk.socks, 0..) |*state, si| {
                if (state.occupied) {
                    const index: u32 = @intCast(ci * sock_per_chunk + si);
                    // Exit drain (#115): netRetireAll already killed the queue
                    // and retired every parked op (including any deferred close
                    // op), so no caller can park anew. Claim the slot and wait
                    // for in-flight consumer thunks to release their users hold
                    // before the descriptor closes; the count only falls.
                    self.registry.mutex.lockUncancelable(self.threaded_io);
                    state.closing.store(true, .release);
                    state.pending_close = null;
                    state.deferred_next = null;
                    self.registry.mutex.unlock(self.threaded_io);
                    self.sockDrainUsers(state);
                    self.sockRetire(state, index);
                }
            }
        }
        if (is_windows) {
            var events: [64]born.Event = undefined;
            while (self.registryPendingOps() != 0) {
                const n = self.port.wait(&events, null) catch |err| {
                    self.registryDrainFailed(err);
                    break;
                };
                for (events[0..n]) |ev| {
                    if (ev.timer or ev.wake) continue;
                    self.socketEvent(ev);
                }
            }
        }
    }

    /// The exit drain's wait failed (#106): completions may still be
    /// outstanding, so latch the cause and mark the chunk table leaked.
    /// registryDeinit then frees the map but keeps the OVERLAPPED storage.
    fn registryDrainFailed(self: *Shim, err: anyerror) void {
        self.latch(err);
        self.registry.exit_drain_failed = true;
    }

    // ------------------------------------------------- connect path (5.x) ----

    /// Convert a std connect timeout to an absolute Born monotonic deadline in
    /// ns (0 = no timeout), keeping the connect on the Born route for every
    /// clock. A `.duration` is relative on any clock. A `.deadline` on `.awake`
    /// is already on Born's timeline; on `.real`/`.boot` it becomes remaining =
    /// deadline - that clock's now (read via the Threaded vtable). A clock read
    /// refusal (born.nowNs, or a zero Threaded timestamp) fails the connect with
    /// Unexpected rather than silently dropping the timeout. A past deadline
    /// maps to now so the connect arm sees it as already expired.
    fn timeoutToDeadline(self: *Shim, timeout: Io.Timeout) error{Unexpected}!u64 {
        const now_ns = born.nowNs() catch return error.Unexpected;
        return switch (timeout) {
            .none => 0,
            .duration => |d| blk: {
                if (d.raw.nanoseconds <= 0) break :blk now_ns;
                const ns: u64 = @intCast(@min(d.raw.nanoseconds, @as(i96, std.math.maxInt(u64))));
                break :blk now_ns +| ns;
            },
            .deadline => |d| blk: {
                if (d.clock == .awake) {
                    if (d.raw.nanoseconds <= 0) break :blk now_ns;
                    break :blk @intCast(@min(d.raw.nanoseconds, @as(i96, std.math.maxInt(u64))));
                }
                const clock_now = self.threaded_io.vtable.now(self.threaded_io.userdata, d.clock);
                if (clock_now.nanoseconds == 0) break :blk error.Unexpected;
                const remaining = d.raw.nanoseconds - clock_now.nanoseconds;
                if (remaining <= 0) break :blk now_ns;
                break :blk now_ns +| @as(u64, @intCast(@min(remaining, @as(i96, std.math.maxInt(u64)))));
            },
        };
    }

    /// Create the socket and initiate the non-blocking connect on the loop
    /// thread, then arm write interest (POSIX) and the optional deadline timer.
    /// Windows ConnectEx is posted and associated by `startConnectAddrInto`.
    fn connectArm(self: *Shim, op: *NetOp) void {
        // A deadline already in the past expires the connect before any socket
        // is created (std returns Timeout without connecting). A clock read
        // refusal fails the connect rather than silently dropping the timeout.
        const c0 = op.payload.connect;
        if (c0.deadline_ns != 0) {
            const now_ns = born.nowNs() catch return self.netRetireErr(op, .route_dead);
            if (c0.deadline_ns <= now_ns) return self.netRetireErr(op, .timeout);
        }
        const index = blk: {
            self.registry.mutex.lockUncancelable(self.threaded_io);
            defer self.registry.mutex.unlock(self.threaded_io);
            break :blk self.sockAllocLocked() catch {
                self.latch(error.OutOfMemory);
                return self.netRetireErr(op, .route_dead);
            };
        };
        const state = self.sockAt(index).?;
        state.generation +%= 1;
        state.occupied = true;
        state.closing.store(false, .monotonic);
        state.index = index;
        state.pending_connect = op;
        state.pending_read = null;
        state.pending_write = null;
        state.read_armed = false;
        state.write_armed = false;
        state.deadline_armed = false;
        op.sock_index = index;
        const udata = slotUdata(index, state.generation);
        const c = op.payload.connect;
        const start_err: ?NetError = blk: {
            switch (c.target) {
                .ip => |addr| {
                    state.plain.startConnectAddrInto(addr, &self.port, udata) catch |err| break :blk switch (err) {
                        error.ConnectFailed => NetError.connect_refused,
                        error.SocketError => NetError.connect_setup,
                    };
                },
                .unix => |path| {
                    state.plain.startConnectUnixInto(self.allocator, path, &self.port, udata) catch |err| break :blk switch (err) {
                        error.ConnectFailed => NetError.unix_refused,
                        error.SocketError => NetError.unix_setup,
                        error.NameTooLong => NetError.unix_name_too_long,
                        error.BacklogFull => NetError.unix_backlog_full,
                        error.Unsupported => NetError.unix_unsupported,
                    };
                },
            }
            break :blk null;
        };
        if (start_err) |e| {
            self.registry.mutex.lockUncancelable(self.threaded_io);
            state.occupied = false;
            self.sockFreeLocked(index);
            self.registry.mutex.unlock(self.threaded_io);
            return self.netRetireErr(op, e);
        }
        state.handle = state.plain.handle();
        self.registerHandle(state.handle, index) catch {
            self.latch(error.OutOfMemory);
            self.sockRetire(state, index);
            return self.netRetireErr(op, .route_dead);
        };
        if (c.deadline_ns != 0) {
            const now_ns = born.nowNs() catch {
                self.sockRetire(state, index);
                return self.netRetireErr(op, .route_dead);
            };
            if (c.deadline_ns > now_ns) {
                self.port.addTimer(net_timer_id_base + op.slot_index, netTimerUdata(index, state.generation), clampTimerNs(c.deadline_ns - now_ns), .once) catch |err| {
                    self.latch(err);
                    self.sockRetire(state, index);
                    return self.netRetireErr(op, .route_dead);
                };
                state.deadline_armed = true;
            }
        }
        if (!is_windows) {
            self.port.wantWrite(state.handle, udata);
            state.write_armed = true;
        }
    }

    /// Confirm the connect after a writable event (POSIX) or connect completion
    /// (Windows). On success populate the local address, arm persistent read
    /// interest and keep the socket registered; on failure retire it.
    fn connectComplete(self: *Shim, op: *NetOp, state: *SocketState) void {
        if (op.cancel_requested.load(.acquire)) {
            self.sockRetire(state, op.sock_index);
            return self.netRetireOp(op, true);
        }
        state.plain.connectDone() catch |err| {
            const e: NetError = switch (err) {
                error.ConnectFailed => .connect_refused,
                error.SocketError => .connect_state,
            };
            self.sockRetire(state, op.sock_index);
            return self.netRetireErr(op, e);
        };
        // Success: cancel the deadline, disarm write interest, keep the socket.
        if (state.deadline_armed) {
            self.port.cancelTimer(net_timer_id_base + op.slot_index);
            state.deadline_armed = false;
        }
        if (state.write_armed) {
            self.port.cancelWrite(state.handle);
            state.write_armed = false;
        }
        state.pending_connect = null;
        // Persistent read interest: arm once here, remove only at close. A
        // readable event with no pending read records the hint (no re-arm).
        self.armRead(state);
        op.result.handle = state.handle;
        op.result.address = localAddress(state.handle);
        if (network_stats_enabled) _ = self.net_stats.connect.fetchAdd(1, .monotonic);
        self.netRetireOp(op, false);
    }

    /// Handle a connect-deadline timer fire. Returns true if it consumed a live
    /// network deadline; the tag bit is decisive, so loopMain never forwards a
    /// net-tagged fire to the sleep timer path and a stale fire is dropped here.
    /// Timeout retires the socket (unregister before close) and the op on both
    /// OSes; Windows keeps the stable SocketState occupied/closing until the
    /// connect completion is absorbed by socketEvent (5.2).
    fn connectDeadlineFired(self: *Shim, udata: ?*anyopaque) bool {
        const raw: u64 = @intCast(@intFromPtr(udata.?));
        const id = decodeSlotUdata(@ptrFromInt(@as(usize, @intCast(raw & ~net_timer_bit))));
        const state = blk: {
            self.registry.mutex.lockUncancelable(self.threaded_io);
            defer self.registry.mutex.unlock(self.threaded_io);
            const s = self.sockAt(id.index) orelse break :blk null;
            if (!s.occupied) break :blk null;
            if (s.generation != id.generation) break :blk null;
            break :blk s;
        };
        const s = state orelse return false;
        const op = s.pending_connect orelse return true; // stale deadline, drop
        op.result.err = .timeout;
        // Clear the pending pointer before the drain so the absorbed connect
        // completion does not re-enter connectComplete.
        s.pending_connect = null;
        if (s.deadline_armed) {
            self.port.cancelTimer(net_timer_id_base + op.slot_index);
            s.deadline_armed = false;
        }
        self.sockRetire(s, id.index);
        self.netRetireOp(op, false);
        return true;
    }

    // ------------------------------------------- read/write/close (6.x) ----

    /// Try-before-park read: drain `readNb` into the op's iovecs, completing on
    /// EOF, on a partial drain with bytes already read, or when the iovecs fill;
    /// park (arm read interest) only when no bytes are available yet.
    fn readDrive(self: *Shim, op: *NetOp) void {
        const state = self.sockSnapshot(op.sock_index) orelse return self.netRetireErr(op, .read_failed);
        if (state.closing.load(.acquire)) return self.netRetireErr(op, .read_failed);
        // A second concurrent read would orphan the parked op and hang its
        // submitter; reject it with busy (mapped to Unexpected). The completion
        // re-entry from socketEvent has p == op and proceeds.
        if (state.pending_read) |p| {
            if (p != op) return self.netRetireErr(op, .busy);
        }
        state.pending_read = op;
        const data = op.payload.read.data;
        while (true) {
            const slice = readSliceAt(data, op.cursor) orelse {
                if (network_stats_enabled) _ = self.net_stats.read.fetchAdd(1, .monotonic);
                return self.netRetireOk(op, op.cursor, false);
            };
            // Windows: after shutdown(.recv) no new data can arrive. Drain
            // buffered bytes through readNb, then complete with EOF without
            // posting a WSARecv (which would fail WSAESHUTDOWN). A real error
            // latched before the shutdown still wins.
            const shut_eof = is_windows and state.shutdown_recv.load(.acquire) and
                state.plain.recv_have == 0 and state.plain.recv_err == null;
            const r: born.socket.NbRead = if (shut_eof) .eof else state.plain.readNb(slice) catch {
                return self.netRetireErr(op, .read_failed);
            };
            switch (r) {
                .data => |n| {
                    op.cursor += n;
                    if (n < slice.len) {
                        if (network_stats_enabled) _ = self.net_stats.read.fetchAdd(1, .monotonic);
                        return self.netRetireOk(op, op.cursor, false);
                    }
                },
                .want_read => {
                    if (op.cursor > 0) {
                        if (network_stats_enabled) _ = self.net_stats.read.fetchAdd(1, .monotonic);
                        return self.netRetireOk(op, op.cursor, false);
                    }
                    self.armRead(state);
                    self.testParkSignal();
                    return;
                },
                .eof => {
                    if (network_stats_enabled) _ = self.net_stats.read.fetchAdd(1, .monotonic);
                    return self.netRetireOk(op, op.cursor, true);
                },
                // PlainNb.readNb never returns want_write; a 0-byte non-EOF
                // completion would read as EndOfStream, so fail it instead.
                .want_write => return self.netRetireErr(op, .read_failed),
            }
        }
    }

    /// Try-before-park write: flatten header + data + splat into a cursor and
    /// drive `writeNb` until the full length is written (std all-or-error),
    /// parking on `want_write`.
    fn writeDrive(self: *Shim, op: *NetOp) void {
        const state = self.sockSnapshot(op.sock_index) orelse return self.netRetireErr(op, .write_failed);
        if (state.closing.load(.acquire)) return self.netRetireErr(op, .write_failed);
        // Reject a concurrent write rather than orphaning the parked op.
        if (state.pending_write) |p| {
            if (p != op) return self.netRetireErr(op, .busy);
        }
        state.pending_write = op;
        const w = op.payload.write;
        const total = writeTotal(w.header, w.data, w.splat);
        var fill: [64]u8 = undefined;
        while (true) {
            const slice = writeSliceAt(w.header, w.data, w.splat, op.cursor, &fill) orelse {
                if (network_stats_enabled) _ = self.net_stats.write.fetchAdd(1, .monotonic);
                return self.netRetireOk(op, op.cursor, false);
            };
            const r = state.plain.writeNb(slice) catch {
                return self.netRetireErr(op, .write_failed);
            };
            switch (r) {
                .done => |n| {
                    op.cursor += n;
                    if (op.cursor >= total) {
                        if (network_stats_enabled) _ = self.net_stats.write.fetchAdd(1, .monotonic);
                        return self.netRetireOk(op, op.cursor, false);
                    }
                },
                .want_write => {
                    self.armWrite(state);
                    self.testParkSignal();
                    return;
                },
                .want_read => return self.netRetireErr(op, .write_failed),
            }
        }
    }

    /// Drive a user close on the loop thread (#115). Claim the slot under the
    /// registry mutex so new consumer lookups refuse with a dead error rather
    /// than forward to Threaded onto a descriptor about to close, then retire
    /// the parked Born ops (waking their submitters). A close kills the
    /// socket's route, so parked ops retire route_dead (Unexpected at the
    /// thunk), never as the caller's Canceled (#106, section 4.5), unless the
    /// submitter itself requested cancellation. If no consumer thunk is in
    /// flight (`users` == 0, read under the same mutex hold that sets closing)
    /// the socket retires immediately. Otherwise the close is DEFERRED: the
    /// live loop must keep servicing submissions (a counted caller may still
    /// arm a read/write that the drive path refuses on the closing slot, or
    /// complete a Threaded forward), so blocking here would deadlock. Store the
    /// close op in `pending_close`, push the slot onto the deferred-close list
    /// and return without retiring it; `sockUserExit` wakes the loop when
    /// `users` reaches zero and `netCloseDrain` finalizes. A second close on an
    /// already-closing slot completes immediately (the first close owns the
    /// teardown). Windows keeps the stable SocketState alive until every
    /// completion is absorbed (4.4).
    fn closeDrive(self: *Shim, op: *NetOp) void {
        const state = self.sockSnapshot(op.sock_index) orelse return self.netRetireOk(op, 0, false);
        self.registry.mutex.lockUncancelable(self.threaded_io);
        if (state.closing.load(.acquire)) {
            self.registry.mutex.unlock(self.threaded_io);
            return self.netRetireOk(op, 0, false);
        }
        state.closing.store(true, .seq_cst);
        // Store-buffer (Dekker) pairing with sockUserExit: the closer stores
        // closing then loads users; the releaser subtracts users then loads
        // closing. Under acquire/release both loads can read the old value —
        // the closer defers (users > 0) while the releaser fast-paths
        // (closing == false), and nobody wakes the loop. The mutex does not
        // help: the releaser's fast path never takes it. All four operations
        // are seq_cst, so in the single total order the closer's store precedes
        // its users load and the releaser's fetchSub precedes its closing load:
        // the closer reading users > 0 while the releaser reads closing == false
        // would cycle that order, so it cannot happen. Either the closer sees
        // users == 0 and retires now, or the releaser sees closing and wakes.
        const users = state.users.load(.seq_cst);
        self.registry.mutex.unlock(self.threaded_io);
        if (state.pending_read) |rop| self.netRetireRoute(rop, false);
        if (state.pending_write) |wop| self.netRetireRoute(wop, false);
        if (state.pending_connect) |cop| self.netRetireRoute(cop, false);
        if (users == 0) {
            self.sockRetire(state, op.sock_index);
            return self.netRetireOk(op, 0, false);
        }
        state.pending_close = op;
        state.deferred_next = self.deferred_close_head;
        self.deferred_close_head = state;
        self.has_deferred_close.store(true, .release);
    }

    /// Loop finalize pass for deferred runtime closes (#115). Runs only while
    /// `has_deferred_close` is set. Walks the intrusive deferred-close list
    /// (review 690 B3) and pops only entries whose `users` drained to zero:
    /// retire the socket and complete its stored close op (waking
    /// `netCloseWait`). O(deferred closes) per wake, not O(total sockets). The
    /// registry mutex serializes with `sockUserExit`'s last-release re-check
    /// and with `sockRetire`'s atomic close+unregister, so a slot is never
    /// freed while a counting caller still holds it. Clears the flag once no
    /// deferred close remains.
    fn netCloseDrain(self: *Shim) void {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        var any = false;
        var prev: ?*SocketState = null;
        var cur = self.deferred_close_head;
        while (cur) |state| {
            const next = state.deferred_next;
            if (state.users.load(.acquire) != 0) {
                any = true;
                prev = state;
                cur = next;
                continue;
            }
            // users drained: unlink, then retire outside the mutex (sockRetire
            // takes it internally for the atomic close+unregister).
            if (prev) |p| {
                p.deferred_next = next;
            } else {
                self.deferred_close_head = next;
            }
            const op = state.pending_close.?;
            state.pending_close = null;
            state.deferred_next = null;
            const index = state.index;
            self.registry.mutex.unlock(self.threaded_io);
            self.sockRetire(state, index);
            self.netRetireOk(op, 0, false);
            self.registry.mutex.lockUncancelable(self.threaded_io);
            cur = next;
        }
        if (!any) self.has_deferred_close.store(false, .release);
        self.registry.mutex.unlock(self.threaded_io);
    }

    /// Test-only park signal (#116): bump the installed counter and wake its
    /// waiters. Called from the drive paths' park branches on every platform
    /// (on Windows the overlapped post already happened inside readNb/writeNb;
    /// armRead/armWrite are no-ops there). Comptime-dead outside test builds.
    fn testParkSignal(self: *Shim) void {
        if (!builtin.is_test) return;
        const addr = self.test_net_parked.load(.acquire);
        if (addr == 0) return;
        const c: *std.atomic.Value(u32) = @ptrFromInt(addr);
        _ = c.fetchAdd(1, .release);
        self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &c.raw, 1);
    }

    fn armRead(self: *Shim, state: *SocketState) void {
        if (is_windows) return; // readNb already posted WSARecv
        if (!state.read_armed) {
            self.port.monitorRead(state.handle, slotUdata(state.index, state.generation));
            state.read_armed = true;
        }
    }

    fn armWrite(self: *Shim, state: *SocketState) void {
        if (is_windows) return; // writeNb already posted WSASend
        self.port.wantWrite(state.handle, slotUdata(state.index, state.generation));
        state.write_armed = true;
    }

    /// Windows only: cancel the in-flight WSARecv/WSASend so their abort
    /// completions reach the loop, which completes a parked read with EOF
    /// (shutdown_recv) and a parked write with the coarse write error. The
    /// registry mutex makes the slot lookup atomic with sockFree, so the
    /// OVERLAPPED addresses belong to this handle's live slot; CancelIoEx on
    /// an ov with no pending op is a harmless ERROR_NOT_FOUND. The wake covers
    /// a cancel racing the loop's next post.
    fn shutdownCancelPending(self: *Shim, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) void {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        const slot: ?*SocketState = blk: {
            const index = self.registry.map.get(handle) orelse break :blk null;
            const s = self.sockAt(index) orelse break :blk null;
            if (!s.occupied) break :blk null;
            break :blk s;
        };
        if (slot) |s| {
            if (how == .recv or how == .both) {
                s.shutdown_recv.store(true, .release);
                _ = compat.windows.kernel32.CancelIoEx(handle, &s.plain.recv_ov);
            }
            if (how == .send or how == .both) {
                _ = compat.windows.kernel32.CancelIoEx(handle, &s.plain.send_ov);
            }
        }
        self.registry.mutex.unlock(self.threaded_io);
        self.port.wake();
    }

    /// Dispatch one socket readiness (POSIX) or completion (Windows) event after
    /// the generation check drops stale events for a closed-and-reused fd.
    fn socketEvent(self: *Shim, ev: born.Event) void {
        const id = decodeSlotUdata(ev.udata);
        const state = blk: {
            self.registry.mutex.lockUncancelable(self.threaded_io);
            defer self.registry.mutex.unlock(self.threaded_io);
            const s = self.sockAt(id.index) orelse break :blk null;
            if (!s.occupied) break :blk null;
            if (s.generation != id.generation) break :blk null;
            break :blk s;
        };
        const s = state orelse return; // stale event dropped

        if (is_windows) {
            const err: ?usize = if (ev.err) ev.err_no else null;
            const kind = s.plain.absorbCompletion(ev.overlapped, ev.bytes, err);
            switch (kind) {
                .connect => if (s.pending_connect) |op| self.connectComplete(op, s),
                .recv => {
                    // A shutdown(.recv) abort (or a recv posted after shutdown)
                    // completes the read with EOF, not the abort error; bytes
                    // buffered before the shutdown still drain first.
                    if (s.shutdown_recv.load(.acquire)) {
                        s.plain.recv_eof = true;
                        s.plain.recv_err = null;
                    }
                    if (s.pending_read) |op| self.readDrive(op);
                },
                .send => if (s.pending_write) |op| self.writeDrive(op),
                .unknown => {},
            }
            if (s.closing.load(.acquire) and s.plain.pendingOps() == 0) self.sockFree(s, id.index);
            return;
        }

        if (ev.err) {
            // A native error on the registration: fail the pending ops.
            if (s.pending_read) |op| self.netRetireErr(op, .read_failed);
            if (s.pending_write) |op| self.netRetireErr(op, .write_failed);
            if (s.pending_connect) |op| {
                self.sockRetire(s, id.index);
                self.netRetireErr(op, .connect_refused);
            }
            return;
        }
        if (ev.readable or ev.eof) {
            // Persistent read interest: record the hint even with no pending
            // read, so a later try-before-park read sees the buffered count.
            s.plain.hintReadable(ev);
            if (s.pending_read) |op| self.readDrive(op);
        }
        if (ev.writable) {
            // kqueue consumes the one-shot write registration on delivery.
            s.write_armed = false;
            if (s.pending_connect) |op| {
                self.connectComplete(op, s);
            } else if (s.pending_write) |op| {
                self.writeDrive(op);
            }
        }
    }

    // ---------------------------------------------------- process engine ----

    fn procSlotAt(self: *Shim, index: u32) ?*ProcSlot {
        const chunk_index = index / proc_slots_per_chunk;
        if (chunk_index >= max_proc_chunks) return null;
        const chunk = self.proc_chunks[chunk_index].load(.acquire) orelse return null;
        return &chunk.slots[index % proc_slots_per_chunk];
    }

    fn procGrowLocked(self: *Shim) error{OutOfMemory}!void {
        if (self.proc_chunk_count >= max_proc_chunks) return error.OutOfMemory;
        const chunk = self.allocator.create(ProcSlotChunk) catch return error.OutOfMemory;
        chunk.* = .{ .slots = undefined };
        const base = self.proc_chunk_count * proc_slots_per_chunk;
        var i: usize = proc_slots_per_chunk;
        while (i > 0) {
            i -= 1;
            chunk.slots[i] = .{ .next_free = self.proc_free_head };
            self.proc_free_head = @intCast(base + i);
        }
        self.proc_chunks[self.proc_chunk_count].store(chunk, .release);
        self.proc_chunk_count += 1;
    }

    fn procAllocSlotLocked(self: *Shim) error{OutOfMemory}!u32 {
        if (self.proc_free_head == null) try self.procGrowLocked();
        const head = self.proc_free_head.?;
        self.proc_free_head = self.procSlotAt(head).?.next_free;
        return head;
    }

    fn procFreeSlotLocked(self: *Shim, index: u32) void {
        const slot = self.procSlotAt(index).?;
        slot.next_free = self.proc_free_head;
        self.proc_free_head = index;
    }

    fn procFreeChunks(self: *Shim) void {
        for (&self.proc_chunks) |*c| {
            if (c.load(.monotonic)) |chunk| self.allocator.destroy(chunk);
        }
    }

    fn childAt(self: *Shim, index: u32) ?*ChildState {
        const chunk_index = index / proc_per_chunk;
        if (chunk_index >= max_child_chunks) return null;
        const chunk = self.child_registry.chunks[chunk_index].load(.acquire) orelse return null;
        return &chunk.children[index % proc_per_chunk];
    }

    /// Initialize the pid map and preallocate the first child chunk.
    /// Construction, before the loop starts.
    fn childRegistryInit(self: *Shim) error{ SystemResources, OutOfMemory }!void {
        self.child_registry.map = std.AutoHashMap(i32, u32).init(self.allocator);
        self.child_registry.initialized = true;
        try self.childGrowLocked();
    }

    fn childGrowLocked(self: *Shim) error{ SystemResources, OutOfMemory }!void {
        if (self.child_registry.chunk_count >= max_child_chunks) return error.SystemResources;
        const chunk = self.allocator.create(ChildChunk) catch return error.OutOfMemory;
        chunk.* = .{ .children = undefined };
        const base = self.child_registry.chunk_count * proc_per_chunk;
        var i: usize = proc_per_chunk;
        while (i > 0) {
            i -= 1;
            chunk.children[i] = .{ .next_free = self.child_registry.free_head };
            self.child_registry.free_head = @intCast(base + i);
        }
        self.child_registry.chunks[self.child_registry.chunk_count].store(chunk, .release);
        self.child_registry.chunk_count += 1;
    }

    fn childAllocLocked(self: *Shim) error{ SystemResources, OutOfMemory }!u32 {
        if (self.child_registry.free_head == null) try self.childGrowLocked();
        const head = self.child_registry.free_head.?;
        self.child_registry.free_head = self.childAt(head).?.next_free;
        return head;
    }

    fn childFreeLocked(self: *Shim, index: u32) void {
        const child = self.childAt(index).?;
        child.occupied = false;
        child.next_free = self.child_registry.free_head;
        self.child_registry.free_head = index;
    }

    fn childFreeChunks(self: *Shim) void {
        for (&self.child_registry.chunks) |*c| {
            if (c.load(.monotonic)) |chunk| self.allocator.destroy(chunk);
        }
    }

    fn childRegistryDeinit(self: *Shim) void {
        if (!self.child_registry.initialized) return;
        self.child_registry.map.deinit();
        self.childFreeChunks();
        self.child_registry.initialized = false;
    }

    /// Close every remaining shim-owned child (deinit, after the loop joins).
    /// Claim each occupied slot under the proc queue mutex, then purge staged
    /// registrations and close outside it: `Child.close` SIGKILLs a running
    /// child on both OSes and reaps per platform (Linux hands a still-exiting
    /// child to the background reaper, so this does not block on exits). The
    /// loop is dead, so no next submission can apply a staged entry; purgeFd
    /// only drops changelist state and is safe without a driver. The caller's
    /// `Child` still owns any parent pipe ends (review R1); deinit never
    /// closes them.
    fn childRegistryCloseAll(self: *Shim) void {
        // Dead on targets without the process route: no child is ever
        // registered there.
        if (comptime !process_supported) return;
        var ci: usize = 0;
        while (ci < self.child_registry.chunk_count) : (ci += 1) {
            const chunk = self.child_registry.chunks[ci].load(.acquire).?;
            for (&chunk.children) |*child| {
                if (!child.occupied) continue;
                self.proc_queue.mutex.lockUncancelable(self.threaded_io);
                const handle = child.child.handle;
                const pid = child.child.pid;
                if (!child.abandoned) _ = self.child_registry.map.fetchRemove(pid);
                self.childFreeLocked(child.index);
                self.proc_queue.mutex.unlock(self.threaded_io);
                self.port.purgeFd(handle);
                var dead: born.process.Child = .{ .handle = handle, .pid = pid };
                dead.close();
            }
        }
    }

    /// Reserve a child slot BEFORE spawn (S1): occupy it and bump the
    /// generation so a stale exit event for a previous occupant is dropped.
    /// The ceiling is a named resource bound (SystemResources), an allocator
    /// refusal is OutOfMemory (N2); neither creates a child. Proc queue mutex.
    fn childReserve(self: *Shim) error{ SystemResources, OutOfMemory }!struct { index: u32, generation: u32 } {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        const index = try self.childAllocLocked();
        const child = self.childAt(index).?;
        child.generation = (child.generation +% 1) & slot_generation_mask;
        child.occupied = true;
        child.index = index;
        child.child = .{ .handle = -1, .pid = 0 };
        child.pending_arm = null;
        child.pending_wait = null;
        child.pending_kill = null;
        child.exit = null;
        child.exit_failed = false;
        child.watch_armed = false;
        child.arm_failed = false;
        child.abandoned = false;
        return .{ .index = index, .generation = child.generation };
    }

    /// Publish a spawned child into its reserved slot: store the descriptor
    /// and pid, and insert the pid mapping. The parent pipe ends stay with
    /// the caller's `Child` (review R1); the registry never holds them. Proc
    /// queue mutex. An OOM inserting the mapping leaves the slot occupied;
    /// the caller kills, closes and releases it.
    fn childPublish(self: *Shim, index: u32, child: born.process.Child) error{OutOfMemory}!void {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        const slot = self.childAt(index).?;
        slot.child = child;
        self.child_registry.map.put(child.pid, index) catch return error.OutOfMemory;
    }

    /// Release a reserved slot whose spawn failed before publication (no pid
    /// mapping exists yet). Proc queue mutex.
    fn childRelease(self: *Shim, index: u32) void {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        self.childFreeLocked(index);
    }

    /// Submit-time provenance gate: resolve a pid to its registry index and
    /// generation, or null if the child is not shim-owned (forward to
    /// Threaded). Proc queue mutex.
    fn lookupChild(self: *Shim, pid: i32) ?struct { index: u32, generation: u32 } {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        if (!self.child_registry.initialized) return null;
        const index = self.child_registry.map.get(pid) orelse return null;
        const child = self.childAt(index) orelse return null;
        if (!child.occupied) return null;
        return .{ .index = index, .generation = child.generation };
    }

    /// Snapshot a registered child under the proc queue mutex, checking
    /// occupancy and generation (the stale-event guard).
    fn childSnapshot(self: *Shim, index: u32, generation: u32) ?*ChildState {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        const child = self.childAt(index) orelse return null;
        if (!child.occupied) return null;
        if (child.generation != generation) return null;
        return child;
    }

    /// Enqueue a caller-owned node into a fresh proc-op slot. Returns null
    /// after the loop has exited (`proc_queue.dead`) or on a slot-table
    /// growth refusal; the caller then reports the failure at the slot.
    fn procSubmit(self: *Shim, op: *ProcOp) ?SubmitResult {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        if (self.proc_queue.dead) return null;
        const index = self.procAllocSlotLocked() catch {
            self.latch(error.OutOfMemory);
            return null;
        };
        const slot = self.procSlotAt(index).?;
        slot.op = op;
        slot.cancel_next = null;
        op.slot_index = index;
        op.next = null;
        const was_empty = self.proc_queue.head == null;
        if (self.proc_queue.tail) |tail| tail.next = op else self.proc_queue.head = op;
        self.proc_queue.tail = op;
        if (was_empty) self.proc_queue.pending.store(true, .release);
        return .{ .index = index, .was_empty = was_empty };
    }

    /// Push the node's proc-op slot on the cancel list unless retired or
    /// already linked. Returns whether the list went empty-to-non-empty.
    fn procRequestCancel(self: *Shim, op: *ProcOp) bool {
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        defer self.proc_queue.mutex.unlock(self.threaded_io);
        const slot = self.procSlotAt(op.slot_index).?;
        if (slot.op != op) return false;
        if (slot.on_cancel_list) return false;
        const was_empty = self.proc_cancel_head == null;
        slot.cancel_next = self.proc_cancel_head;
        slot.on_cancel_list = true;
        self.proc_cancel_head = op.slot_index;
        if (was_empty) self.proc_queue.pending.store(true, .release);
        return was_empty;
    }

    /// One critical section: drain the process cancel list, then swap out
    /// the whole submission list. Driven wait ops on the cancel list are
    /// chained for abandon/retire/wake OUTSIDE the mutex; entries for ops
    /// still in the swapped queue are left to `procArmOrRetire`'s
    /// `cancel_requested` check.
    fn procDrainLocked(self: *Shim) ?*ProcOp {
        if (comptime !process_supported) return null;
        // Idle-gate: see netDrainLocked (acquire load pairs with the release store).
        if (!self.proc_queue.pending.load(.acquire)) return null;
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        var driven: ?*ProcOp = null;
        var idx = self.proc_cancel_head;
        self.proc_cancel_head = null;
        while (idx) |i| {
            const slot = self.procSlotAt(i).?;
            const next = slot.cancel_next;
            slot.cancel_next = null;
            slot.on_cancel_list = false;
            if (slot.op) |op| {
                if (self.procOpIsPending(op)) {
                    op.next = driven;
                    driven = op;
                }
            } else {
                self.procFreeSlotLocked(i);
            }
            idx = next;
        }
        const head = self.proc_queue.head;
        self.proc_queue.head = null;
        self.proc_queue.tail = null;
        // Both lists empty under the lock; clear pending (see netDrainLocked).
        self.proc_queue.pending.store(false, .monotonic);
        self.proc_queue.mutex.unlock(self.threaded_io);
        var node = driven;
        while (node) |op| {
            const next = op.next;
            self.procCancelOp(op);
            node = next;
        }
        return head;
    }

    /// Whether the loop has already parked this op on its child. Loop-only
    /// field access, no mutex needed (the pending pointers are loop-written).
    fn procOpIsPending(self: *Shim, op: *ProcOp) bool {
        const child = self.childAt(op.child_index) orelse return false;
        return switch (op.kind) {
            .arm => child.pending_arm == op,
            .wait => child.pending_wait == op,
            .kill => child.pending_kill == op,
        };
    }

    fn procArmBatch(self: *Shim, head: ?*ProcOp) void {
        if (comptime !process_supported) return;
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.procArmOrRetire(op);
            node = next;
        }
        // FreeBSD: every staged EV_ADD is confirmed by a zero-timeout flush
        // before any arm op retires (synchronous arm, section 4.3). Linux
        // arms synchronously in watchProcess and never stages.
        if (comptime is_freebsd) {
            if (self.proc_arm_head != null) self.procFlushArms();
        }
    }

    fn procArmOrRetire(self: *Shim, op: *ProcOp) void {
        // Arm and kill are uncancelable; only a wait honors a cancel request.
        if (op.kind == .wait and op.cancel_requested.load(.acquire))
            return self.procCancelOp(op);
        switch (op.kind) {
            .arm => self.armDrive(op),
            .wait => self.waitDrive(op),
            .kill => self.killDrive(op),
        }
    }

    /// FreeBSD only: submit every staged change with zero-timeout waits,
    /// dispatching harvested events normally, until the changelist is empty;
    /// then retire every arm op this flush was confirming. A failed flush
    /// retires all of them as failed (N1). An EV_ERROR for an arm slot marks
    /// that child's arm failed (childEvent); an exit delivered during the
    /// flush confirms the arm and latches the exit for the future wait.
    fn procFlushArms(self: *Shim) void {
        if (comptime is_freebsd) {
            var events: [64]born.Event = undefined;
            var flush_failed = false;
            var saw_wake = false;
            // Coupled to the port's staging buffer (N1): the loop drains
            // exactly the changelist `watchProcess` accumulated, and each
            // `wait` consumes the prefix it submits. A refused wait leaves
            // the remainder staged for the next submission; cleanup purges
            // it before closing the descriptor.
            while (self.port.changes.items.len != 0) {
                if (builtin.is_test and self.test_flush_fault) {
                    // Test-only refusal (R2): report a failed flush without
                    // touching the port, leaving the staged EV_ADD in place.
                    self.test_flush_fault = false;
                    self.latch(error.Unexpected);
                    flush_failed = true;
                    break;
                }
                const n = self.port.wait(&events, 0) catch |err| {
                    self.latch(err);
                    flush_failed = true;
                    break;
                };
                for (events[0..n]) |ev| {
                    if (ev.wake) saw_wake = true;
                    self.dispatchEvent(ev);
                }
            }
            // The flush sits between the queue drain and the blocking wait, so
            // a wake it harvests is cleared (EVFILT_USER EV_CLEAR) without a
            // re-drain: an op a worker queued during the flush would otherwise
            // leave the loop blocked on a non-empty queue (lost wakeup). Re-
            // trigger so the main wait returns and the next cycle drains it.
            if (saw_wake) self.port.wake();
            var node = self.proc_arm_head;
            self.proc_arm_head = null;
            while (node) |op| {
                const next = op.arm_next;
                op.arm_next = null;
                const child = self.childAt(op.child_index).?;
                child.pending_arm = null;
                if (flush_failed or child.arm_failed) {
                    // R2: a failed flush must mark the child arm_failed, not
                    // just retire the op: the spawn thunk's cleanup kill op
                    // then drives armFailedCleanup instead of parking on an
                    // exit that can never arrive (the watch never registered).
                    if (flush_failed) child.arm_failed = true;
                    self.procRetireErr(op, .arm_failed);
                } else {
                    child.watch_armed = true;
                    self.procRetireOk(op);
                }
                node = next;
            }
        }
    }

    /// Arm the exit watch. Linux watchProcess is synchronous (epoll_ctl);
    /// FreeBSD stages EV_ADD NOTE_EXIT and the flush confirms it. Any
    /// refusal retires the arm as failed; the spawn thunk then kills and
    /// cleans up the child (section 5.5). Loop thread.
    fn armDrive(self: *Shim, op: *ProcOp) void {
        const child = self.childAt(op.child_index).?;
        child.pending_arm = op;
        self.port.watchProcess(child.child.handle, procUdata(child.index, child.generation)) catch |err| {
            self.latch(err);
            child.arm_failed = true;
            child.pending_arm = null;
            return self.procRetireErr(op, .arm_failed);
        };
        if (comptime is_freebsd) {
            op.arm_next = self.proc_arm_head;
            self.proc_arm_head = op;
        } else {
            child.watch_armed = true;
            child.pending_arm = null;
            self.procRetireOk(op);
        }
    }

    /// Park a cancelable exit wait, or complete it immediately from the
    /// latched exit (the child exited during the arm flush or before this
    /// wait submitted). Loop thread.
    fn waitDrive(self: *Shim, op: *ProcOp) void {
        const child = self.childAt(op.child_index).?;
        if (child.exit != null or child.exit_failed)
            return self.waitComplete(op, child);
        if (child.pending_wait != null)
            return self.procRetireErr(op, .busy);
        child.pending_wait = op;
    }

    /// Park an uncancelable kill drain, or finish immediately from the
    /// latched exit. An arm-failed child (never returned to the caller) is
    /// cleaned up without waiting for an exit: the spawn thunk already
    /// SIGKILLed it and Child.close reaps per platform. Loop thread.
    fn killDrive(self: *Shim, op: *ProcOp) void {
        const child = self.childAt(op.child_index).?;
        if (child.arm_failed) return self.armFailedCleanup(op, child);
        if (child.exit != null or child.exit_failed)
            return self.killFinish(op, child);
        if (child.pending_kill != null)
            return self.procRetireErr(op, .busy);
        child.pending_kill = op;
    }

    /// Dispatch one child exit or tagged error event after the generation
    /// check drops stale events for a closed-and-reused descriptor. An
    /// EV_ERROR during the arm flush marks the arm failed; any other tagged
    /// error latches a wait failure (stolen reap, port failure). Loop thread.
    fn childEvent(self: *Shim, ev: born.Event) void {
        if (comptime !process_supported) return;
        if (ev.udata == null) return;
        const id = decodeProcUdata(ev.udata);
        const child = self.childSnapshot(id.index, id.generation) orelse return;
        if (ev.err) {
            if (child.pending_arm != null and !child.watch_armed) {
                child.arm_failed = true;
                return;
            }
            child.exit_failed = true;
            child.exit = null;
        } else if (ev.exited) {
            child.watch_armed = true;
            child.exit = ev.exit;
            if (child.exit == null) child.exit_failed = true;
        } else return;
        if (child.pending_wait) |op| {
            self.waitComplete(op, child);
        } else if (child.pending_kill) |op| {
            self.killFinish(op, child);
        } else if (child.abandoned) {
            self.childCleanup(child);
        }
        // Otherwise the exit stays latched for a future wait or kill.
    }

    /// Complete a parked wait from the latched exit: full teardown (6.2),
    /// then retire with the Term (or the coarse wait failure). Loop thread.
    fn waitComplete(self: *Shim, op: *ProcOp, child: *ChildState) void {
        const exit = child.exit;
        const failed = child.exit_failed;
        self.childCleanup(child);
        if (failed or exit == null) {
            op.result.err = .wait_failed;
        } else {
            op.result.exit = exit;
        }
        self.procRetireOp(op, false);
    }

    /// Finish a kill drain: the exit is collected (or latched failed), so
    /// end the watch, remove the pid entry before the reaping close, close
    /// the descriptor, release the slot. The caller's stdio ends are closed
    /// by the kill thunk, not here (review R1). Loop thread.
    fn killFinish(self: *Shim, op: *ProcOp, child: *ChildState) void {
        self.childCleanup(child);
        self.procRetireOk(op);
    }

    /// Clean up an arm-failed child on the loop: the spawn thunk SIGKILLed
    /// it and never returned it, so no exit collection is needed.
    /// Child.close reaps an exited child and SIGKILLs a running one per
    /// platform (non-blocking: Linux hands a still-exiting child to the
    /// background reaper). Loop thread.
    fn armFailedCleanup(self: *Shim, op: *ProcOp, child: *ChildState) void {
        self.childCleanup(child);
        self.procRetireOk(op);
    }

    /// Full teardown of an exited (or arm-failed) child on the loop thread:
    /// end the watch, drop the pid mapping BEFORE the reaping close so a
    /// recycled pid never resolves to this dying slot, release the slot, then
    /// close a local copy of the descriptor taken under the mutex. The slot
    /// may be reserved and published by a worker the instant it goes free, so
    /// the close never runs through the slot (#114). FreeBSD reaps the exited
    /// child on the spot; Linux harvest already reaped, so close just ends it.
    /// The parent pipe ends belong to the caller's `Child` (review R1); the
    /// wait/kill thunk closes and nulls them on the caller thread.
    fn childCleanup(self: *Shim, child: *ChildState) void {
        // A unit test may close the descriptor itself and invalidate the
        // handle to -1 (N3); skip the port teardown then, since purgeFd casts
        // the handle to usize. A published child always holds a valid handle
        // here, so this guard is inert in normal operation.
        if (child.child.handle >= 0) {
            self.port.unwatchProcess(child.child.handle);
            self.port.purgeFd(child.child.handle);
        }
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        if (!child.abandoned) _ = self.child_registry.map.fetchRemove(child.child.pid);
        // Copy the descriptor and index out before releasing the slot: a
        // worker may reserve and publish this slot the instant it goes free,
        // so the close below runs on a local, never through the slot (#114).
        var dead = child.child;
        const index = child.index;
        self.childFreeLocked(index);
        self.proc_queue.mutex.unlock(self.threaded_io);
        if (builtin.is_test) {
            if (self.test_child_cleanup_reuse) |hook| {
                self.test_child_cleanup_reuse = null;
                hook(self, index);
            }
        }
        dead.close();
    }

    /// Abandon a canceled wait (6.3): unpublish the pid, but keep the
    /// descriptor open and watched. The loop reaps the child when its exit
    /// arrives; only deinit kills it if still running. If the exit already
    /// latched, clean up fully instead. The caller's stdio ends are closed
    /// by the wait thunk's cancel path, not here (review R1). Loop thread;
    /// the submitter drains uncancelably until the op retires.
    fn abandonWait(self: *Shim, op: *ProcOp) void {
        const child = self.childAt(op.child_index).?;
        if (child.exit != null or child.exit_failed) {
            self.childCleanup(child);
        } else {
            self.proc_queue.mutex.lockUncancelable(self.threaded_io);
            if (!child.abandoned) {
                _ = self.child_registry.map.fetchRemove(child.child.pid);
                child.abandoned = true;
            }
            if (child.pending_wait == op) child.pending_wait = null;
            self.proc_queue.mutex.unlock(self.threaded_io);
        }
        self.procRetireOp(op, true);
    }

    /// Retire a canceled wait op: abandon the child, then publish the
    /// terminal canceled state. Loop thread, outside the queue mutex.
    fn procCancelOp(self: *Shim, op: *ProcOp) void {
        if (op.kind == .wait) return self.abandonWait(op);
        self.procRetireOp(op, true);
    }

    /// Clear the child pending pointer for a retiring op. Loop-only fields,
    /// no mutex (the pending pointers are written only by the loop).
    fn procDisarmOp(self: *Shim, op: *ProcOp) void {
        const child = self.childAt(op.child_index) orelse return;
        switch (op.kind) {
            .arm => if (child.pending_arm == op) {
                child.pending_arm = null;
            },
            .wait => if (child.pending_wait == op) {
                child.pending_wait = null;
            },
            .kill => if (child.pending_kill == op) {
                child.pending_kill = null;
            },
        }
    }

    /// Disarm, publish the terminal state and free the proc-op slot under
    /// the proc queue mutex, then wake the submitter outside it. The slot
    /// index is snapshotted before the terminal store: the submitter may
    /// return and reuse its frame past that point, so no field of the node
    /// is read after it (the wake is address-keyed, see `retire`).
    fn procRetireOp(self: *Shim, op: *ProcOp, canceled: bool) void {
        self.procDisarmOp(op);
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        const index = op.slot_index;
        op.outcome_canceled = canceled;
        op.state.store(1, .release);
        if (builtin.is_test) {
            if (self.test_proc_frame_reuse) |poison| {
                self.test_proc_frame_reuse = null;
                op.slot_index = poison;
            }
        }
        const slot = self.procSlotAt(index).?;
        slot.op = null;
        if (!slot.on_cancel_list) self.procFreeSlotLocked(index);
        self.proc_queue.mutex.unlock(self.threaded_io);
        self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &op.state.raw, 1);
    }

    fn procRetireOk(self: *Shim, op: *ProcOp) void {
        self.procRetireOp(op, false);
    }

    fn procRetireErr(self: *Shim, op: *ProcOp, e: ProcError) void {
        op.result.err = e;
        self.procRetireOp(op, false);
    }

    /// Mark the proc queue dead and retire every queued and parked process
    /// op. Published and abandoned children KEEP their occupied slots and
    /// open descriptors: the caller still owns a published `std.process.Child`
    /// (dead-loop kill fallback, section 7), and deinit kills abandoned ones.
    /// Loop thread, just before exit.
    fn procRetireAll(self: *Shim, stopped: bool) void {
        if (comptime !process_supported) return;
        self.proc_queue.mutex.lockUncancelable(self.threaded_io);
        self.proc_queue.dead = true;
        const head = self.proc_queue.head;
        self.proc_queue.head = null;
        self.proc_queue.tail = null;
        self.proc_queue.pending.store(false, .monotonic);
        var idx = self.proc_cancel_head;
        self.proc_cancel_head = null;
        while (idx) |i| {
            const slot = self.procSlotAt(i).?;
            const next = slot.cancel_next;
            slot.cancel_next = null;
            slot.on_cancel_list = false;
            if (slot.op == null) self.procFreeSlotLocked(i);
            idx = next;
        }
        const chunk_count = self.proc_chunk_count;
        self.proc_queue.mutex.unlock(self.threaded_io);
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.procRetireRoute(op, stopped);
            node = next;
        }
        var ci: usize = 0;
        while (ci < chunk_count) : (ci += 1) {
            const chunk = self.proc_chunks[ci].load(.acquire).?;
            for (&chunk.slots) |*slot| {
                if (slot.op) |op| self.procRetireRoute(op, stopped);
            }
        }
        self.proc_arm_head = null;
    }

    /// Retire one op at loop exit: canceled for a stop request or an op whose
    /// submitter already requested cancellation, route_dead otherwise.
    fn procRetireRoute(self: *Shim, op: *ProcOp, stopped: bool) void {
        const canceled = stopped or op.cancel_requested.load(.acquire);
        if (!canceled) op.result.err = .route_dead;
        self.procRetireOp(op, canceled);
    }

    /// Submitter-side completion wait for a cancelable process op (wait):
    /// the `netWait` retry shape. Returns error.Canceled on any cancellation
    /// path; a submit refusal completes the op with route_dead. On normal
    /// completion the thunk inspects `op.result`.
    fn procWait(self: *Shim, op: *ProcOp) Io.Cancelable!void {
        const submitted = self.procSubmit(op) orelse {
            op.result.err = .route_dead;
            return;
        };
        if (submitted.was_empty) self.port.wake();
        while (true) {
            self.threaded_io.vtable.futexWait(self.threaded_io.userdata, &op.state.raw, 0, .none) catch |err| switch (err) {
                error.Canceled => {
                    op.cancel_requested.store(true, .release);
                    if (self.procRequestCancel(op)) self.port.wake();
                    // Drain uncancelably until the loop retires the node: it
                    // must never touch this stack storage after we return.
                    while (op.state.load(.acquire) == 0) {
                        self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &op.state.raw, 0);
                    }
                    return error.Canceled;
                },
            };
            if (op.state.load(.acquire) != 0) break;
        }
        if (op.outcome_canceled) return error.Canceled;
    }

    /// Submitter-side completion wait for an uncancelable process op (arm,
    /// kill): enqueue and drain without a cancellation path. A submit
    /// refusal completes the op with route_dead; the caller falls back to
    /// caller-thread cleanup (sections 5.5, 7).
    fn procWaitUncancelable(self: *Shim, op: *ProcOp) void {
        const submitted = self.procSubmit(op) orelse {
            op.result.err = .route_dead;
            return;
        };
        if (submitted.was_empty) self.port.wake();
        while (op.state.load(.acquire) == 0) {
            self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &op.state.raw, 0);
        }
    }

    /// Dead-loop fallback (sections 5.5, 7): claim an occupied child under
    /// the proc queue mutex (remove the pid entry, copy the descriptor and
    /// pid to locals, release the slot), then SIGKILL/SIGTERM and blocking
    /// reap on the caller thread. No port calls: the loop is dead, so no
    /// next submission can apply a staged entry to a recycled fd
    /// (synchronous arm already flushed every published watch live). The
    /// caller's stdio ends are closed by the thunk, not here (review R1).
    /// Returns false if the slot was already cleaned up (deinit raced).
    fn childDeadClaim(self: *Shim, op: *ProcOp, sig: u8) bool {
        if (comptime process_supported) {
            self.proc_queue.mutex.lockUncancelable(self.threaded_io);
            const child = self.childAt(op.child_index) orelse {
                self.proc_queue.mutex.unlock(self.threaded_io);
                return false;
            };
            if (!child.occupied or child.generation != op.child_gen) {
                self.proc_queue.mutex.unlock(self.threaded_io);
                return false;
            }
            const handle = child.child.handle;
            const pid = child.child.pid;
            if (!child.abandoned) _ = self.child_registry.map.fetchRemove(pid);
            self.childFreeLocked(child.index);
            self.proc_queue.mutex.unlock(self.threaded_io);
            // Plain syscalls only, safe from any thread through the descriptor.
            var dead: born.process.Child = .{ .handle = handle, .pid = pid };
            dead.kill(sig) catch {};
            if (comptime is_linux) {
                var info: std.os.linux.siginfo_t = undefined;
                while (compat.linuxErrno(compat.waitid(.PIDFD, handle, &info, std.os.linux.W.EXITED)) == .INTR) {}
            }
            if (comptime is_freebsd) {
                var status: c_int = 0;
                while (true) {
                    const rc = freebsd_wait.wait6(0, @intCast(pid), &status, std.c.W.EXITED, null, null);
                    if (rc >= 0) break;
                    if (std.posix.errno(@as(isize, rc)) != .INTR) break;
                }
            }
            compat.close(handle);
            return true;
        } else return false;
    }
};

/// FreeBSD wait6 (FBSD_1.3, every supported release): the dead-loop fallback
/// reaps a pdfork child by pid while the descriptor stays open, so the pid
/// cannot be recycled (pdfork(2) guarantees it). pdwait is 15.1-only
/// (FBSD_1.9) and would impose an implicit floor; born declares neither, so
/// the shim adds this extern. P_PID = 0 (sys/wait.h idtype_t).
const freebsd_wait = if (is_freebsd) struct {
    extern "c" fn wait6(idtype: c_int, id: i64, status: *c_int, options: c_int, wrusage: ?*anyopaque, siginfo: ?*anyopaque) std.c.pid_t;
} else struct {};

/// Clamp a remaining nanosecond span to the port's uniform timer ceiling
/// (`born.timer_after_ns_max`) so an arm never exceeds it. Nanosecond
/// granularity: no rounding here, the kernel rounds up to its own resolution
/// so a deadline never fires early. `remaining_ns` > 0.
pub fn clampTimerNs(remaining_ns: u64) u64 {
    return @min(remaining_ns, born.timer_after_ns_max);
}

/// Test-only: break the port so every `wait()` fails. Mirrors the old
/// caller-side poison (`std.c.close(port.kq)` / `std.c.close(port.ep)`) that
/// the loop-death test relies on; nothing blocks on the port yet at the time
/// the shim calls this, so the wait fails instead of hanging. No-op on
/// targets without a descriptor of this shape.
fn poisonOwnedPort(port: *born.EvPort) void {
    if (comptime @hasField(born.EvPort, "kq")) {
        if (port.kq >= 0) {
            _ = std.c.close(port.kq);
            port.kq = -1;
        }
        return;
    }
    if (comptime @hasField(born.EvPort, "ep")) {
        if (port.ep >= 0) {
            _ = std.c.close(port.ep);
            port.ep = -1;
        }
        return;
    }
    // Windows IOCP has no descriptor-of-this-shape to close here: closing
    // the owned port's handle makes the connect fail synchronously
    // (observed SystemResources) before any wait-boundary failure, so the
    // loop-death retirement path is not reachable this way.
}

/// Builds a `std.Io` over Born's event port. The returned interface owns a
/// heap-allocated composite, including its event port; release it with
/// `deinit`. One instance per core is the intended shape: each instance
/// carries its own port, loop thread and slot tables. A Born route
/// (`capabilities.network` or `.process = .born_evented`) spawns the
/// loop thread and services that family on Born; `sleep`, `now` and
/// `clockResolution` always delegate to Threaded. The network route services
/// the client path (IP and pathname Unix connect, stream read/write, close,
/// shutdown); the process route (FreeBSD and Linux only) services
/// `processSpawn`, `childWait` and `childKill`. The file family and the
/// process family on other targets are rejected at construction, never
/// silently delegated.
pub fn io(opts: InitOptions) InitError!Io {
    const caps = opts.capabilities;
    if (caps.file == .born_evented)
        return error.CapabilityUnsupported;
    if (caps.process == .born_evented and !process_supported)
        return error.CapabilityUnsupported;
    const net_born = caps.network == .born_evented;
    const proc_born = caps.process == .born_evented;
    // The Born routes need a loop thread; a single-threaded build cannot host
    // one, so the profile is rejected rather than silently degraded.
    if ((net_born or proc_born) and builtin.single_threaded)
        return error.CapabilityUnsupported;
    const shim = opts.allocator.create(Shim) catch return error.OutOfMemory;
    errdefer opts.allocator.destroy(shim);
    shim.* = .{
        .port = try born.EvPort.init(opts.allocator),
        .allocator = opts.allocator,
        .capabilities = caps,
        .threaded = Io.Threaded.init(opts.allocator, opts.threaded),
        .threaded_io = undefined,
    };
    errdefer shim.port.deinit();
    if (comptime builtin.is_test) {
        if (test_poison_port) poisonOwnedPort(&shim.port);
        test_poison_port = false;
    }
    shim.threaded_io = shim.threaded.io();
    errdefer shim.threaded.deinit();
    if (net_born or proc_born) {
        // Preallocate the first chunk of each active route so its steady-state
        // path performs no shim allocation; growth beyond capacity is on demand.
        if (net_born) {
            shim.netGrowLocked() catch return error.OutOfMemory;
            shim.registryInit() catch return error.OutOfMemory;
        }
        errdefer shim.netFreeChunks();
        errdefer shim.registryDeinit();
        if (proc_born) {
            shim.procGrowLocked() catch return error.OutOfMemory;
            shim.childRegistryInit() catch return error.OutOfMemory;
        }
        errdefer shim.procFreeChunks();
        errdefer shim.childRegistryDeinit();
        shim.loop = std.Thread.spawn(.{}, Shim.loopMain, .{shim}) catch return error.LoopSpawnFailed;
    }
    // bit 0 = network, bit 1 = process (section 10).
    const index: usize = @as(usize, @intFromBool(net_born)) |
        (@as(usize, @intFromBool(proc_born)) << 1);
    return .{
        .userdata = shim,
        .vtable = &vtable_table[index],
    };
}

/// Releases the composite created by `io`. As with `Io.Threaded`, every task
/// must have been awaited or canceled first. Sets the instance entry gate so
/// new consumer calls reject with their dead-route error (infallible value
/// producers panic; wake/release calls still forward), then stops and joins
/// the Born route's loop thread (retiring any operation still pending as
/// canceled and closing any remaining registered socket): the loop calls into
/// Threaded until it exits. Drains every in-flight consumer thunk before
/// freeing anything it touches (#113). The drain BLOCKS until each counted
/// call returns, including a Threaded forward that can block indefinitely
/// (`netAccept`, `childWait`, `futexWait`/`futexWaitUncancelable`): a caller
/// parked in one of those must be woken or canceled by its peer before deinit
/// can finish, exactly as `Io.Threaded.deinit` requires its tasks awaited.
/// Then closes any remaining shim-owned child (killing one still running),
/// joins the Threaded pool and frees the composite.
pub fn deinit(interface: Io) void {
    const shim = shimFrom(interface.userdata);
    const allocator = shim.allocator;
    // Set the gate before stopping the loop: a consumer call arriving during
    // the retire window rejects at entry instead of touching route state.
    _ = shim.entry.fetchOr(Shim.entry_closing, .acq_rel);
    if (shim.loop) |loop| {
        shim.stopping.store(true, .release);
        shim.port.wake();
        loop.join();
    }
    // The loop retired the parked operations; wait for their submitters (and
    // every other in-flight thunk) to return before any free/close below.
    shim.entryCloseAndDrain();
    shim.childRegistryCloseAll();
    shim.threaded.deinit();
    shim.netFreeChunks();
    shim.registryDeinit();
    shim.procFreeChunks();
    shim.childRegistryDeinit();
    shim.port.deinit();
    allocator.destroy(shim);
}

/// Test-only: install the park counter hook (#116), or null to clear it.
/// Comptime-dead outside test builds. See `Shim.test_net_parked`.
pub fn testParkHook(interface: Io, hook: ?*std.atomic.Value(u32)) void {
    if (!builtin.is_test) return;
    shimFrom(interface.userdata).test_net_parked.store(if (hook) |h| @intFromPtr(h) else 0, .release);
}

/// The first route-level failure latched by any Born route: a port `wait`
/// refusal, a connect-deadline timer-arm refusal (`born.TimerError`), a
/// slot-table growth refusal, or a process-route refusal (arm failure, failed
/// arm flush). This accessor exposes the cause so an application can tell a
/// failed or dead route from ordinary cancellation. Returns null while no
/// failure has occurred. The latch is instance-wide: a per-child refusal (one
/// child's arm or flush failing) latches the whole instance, the same scope as
/// the network route's per-socket refusal latch (P5.3 `sockRetire`, accepted
/// as-is); it does not by itself stop the loop or other children. The loop
/// exits after `wait_fail_limit` consecutive wait failures; once it has, every
/// later Born-route submission is rejected. The baseline route never latches
/// and always returns null.
pub fn loopError(interface: Io) ?anyerror {
    return shimFrom(interface.userdata).latchedError();
}

/// Per-route network counters (should-fix 4, done-when evidence). `connect`,
/// `read` and `write` count Born-route completions fed by the loop; the
/// `threaded_*` fields count forwards to the saved Threaded vtable fed by the
/// thunks. A TCP client consumer asserts the Born counts are non-zero after an
/// exchange, proving the client ran on Born's reactor (passing over the
/// all-Threaded baseline, which reports zero Born counts, is not evidence).
/// With the `network_stats` build option off (the default) no counter is ever
/// written and every field reports zero.
pub const NetworkStats = struct {
    connect: u64,
    read: u64,
    write: u64,
    threaded_connect: u64,
    threaded_read: u64,
    threaded_write: u64,
};

/// Snapshot of the network route's per-route counters. Reports zeros when the
/// `network_stats` build option is off.
pub fn networkStats(interface: Io) NetworkStats {
    if (!network_stats_enabled) return .{
        .connect = 0,
        .read = 0,
        .write = 0,
        .threaded_connect = 0,
        .threaded_read = 0,
        .threaded_write = 0,
    };
    const s = &shimFrom(interface.userdata).net_stats;
    return .{
        .connect = s.connect.load(.monotonic),
        .read = s.read.load(.monotonic),
        .write = s.write.load(.monotonic),
        .threaded_connect = s.threaded_connect.load(.monotonic),
        .threaded_read = s.threaded_read.load(.monotonic),
        .threaded_write = s.threaded_write.load(.monotonic),
    };
}

/// Per-route process counters: `spawn`/`wait`/`kill` count operations serviced
/// on Born's reactor; `threaded_*` count operations forwarded to Threaded (a
/// Threaded-owned child, or the all-Threaded baseline). A zero `threaded_*`
/// count after a spawn/wait/kill exchange is the provenance-gate evidence that
/// the family ran on Born. Behind the `process_stats` build option: when off no
/// counter is written and every field reports zero.
pub const ProcessStats = struct {
    spawn: u64,
    wait: u64,
    kill: u64,
    threaded_spawn: u64,
    threaded_wait: u64,
    threaded_kill: u64,
};

/// Snapshot of the process route's per-route counters. Reports zeros when the
/// `process_stats` build option is off.
pub fn processStats(interface: Io) ProcessStats {
    if (!process_stats_enabled) return .{
        .spawn = 0,
        .wait = 0,
        .kill = 0,
        .threaded_spawn = 0,
        .threaded_wait = 0,
        .threaded_kill = 0,
    };
    const s = &shimFrom(interface.userdata).proc_stats;
    return .{
        .spawn = s.spawn.load(.monotonic),
        .wait = s.wait.load(.monotonic),
        .kill = s.kill.load(.monotonic),
        .threaded_spawn = s.threaded_spawn.load(.monotonic),
        .threaded_wait = s.threaded_wait.load(.monotonic),
        .threaded_kill = s.threaded_kill.load(.monotonic),
    };
}

/// Forwarding thunks shared by both pinned interfaces (identical signatures).
/// Each recovers the composite and delegates to the saved Threaded vtable.
const fwd = struct {
    fn crashHandler(userdata: ?*anyopaque) void {
        const self = shimFrom(userdata);
        // Wake/release class (review 690 B1 group b): never refuse. Counted
        // through the drain window so the drain protects an in-flight call;
        // post-dead it still forwards uncounted (thread-local, stateless;
        // refusing a crash handler would strand teardown).
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
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
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("async", ?*Io.AnyFuture);
        if (!self.entryEnter()) return deadRefuse("async", ?*Io.AnyFuture);
        defer self.entryExit();
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
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.ConcurrentError!*Io.AnyFuture);
        if (!self.entryEnter()) return deadResult(Io.ConcurrentError!*Io.AnyFuture);
        defer self.entryExit();
        return self.threaded_io.vtable.concurrent(self.threaded_io.userdata, result_len, result_alignment, context, context_alignment, start);
    }
    fn await(
        userdata: ?*anyopaque,
        any_future: *Io.AnyFuture,
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("await", void);
        if (!self.entryEnter()) return deadRefuse("await", void);
        defer self.entryExit();
        return self.threaded_io.vtable.await(self.threaded_io.userdata, any_future, result, result_alignment);
    }
    fn cancel(
        userdata: ?*anyopaque,
        any_future: *Io.AnyFuture,
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("cancel", void);
        if (!self.entryEnter()) return deadRefuse("cancel", void);
        defer self.entryExit();
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
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("groupAsync", void);
        if (!self.entryEnter()) return deadRefuse("groupAsync", void);
        defer self.entryExit();
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
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.ConcurrentError!void);
        if (!self.entryEnter()) return deadResult(Io.ConcurrentError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.groupConcurrent(self.threaded_io.userdata, group, context, context_alignment, start);
    }
    fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!void);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!void);
        defer self.entryExit();
        return self.threaded_io.vtable.groupAwait(self.threaded_io.userdata, group, token);
    }
    fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
        const self = shimFrom(userdata);
        // Wake/release class (group b): never refuse. Counted through the drain
        // window so the forward waits for the group's running tasks before
        // returning (the caller may free the group right after); only post-dead
        // is it the no-op below.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        // Post-dead no-op: Threaded.groupCancel waits on running tasks through
        // the Threaded object (cancelThreads/signalAllCanceledSyscalls), which
        // deinit frees. deinit joins every worker, so no group task can still
        // run after it and cancellation is vacuous. The caller-owned group word
        // is left untouched.
        if (!entered) return;
        return self.threaded_io.vtable.groupCancel(self.threaded_io.userdata, group, token);
    }
    fn recancel(userdata: ?*anyopaque) void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("recancel", void);
        if (!self.entryEnter()) return deadRefuse("recancel", void);
        defer self.entryExit();
        return self.threaded_io.vtable.recancel(self.threaded_io.userdata);
    }
    fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("swapCancelProtection", Io.CancelProtection);
        if (!self.entryEnter()) return deadRefuse("swapCancelProtection", Io.CancelProtection);
        defer self.entryExit();
        return self.threaded_io.vtable.swapCancelProtection(self.threaded_io.userdata, new);
    }
    fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!void);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!void);
        defer self.entryExit();
        return self.threaded_io.vtable.checkCancel(self.threaded_io.userdata);
    }
    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!void);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!void);
        defer self.entryExit();
        return self.threaded_io.vtable.futexWait(self.threaded_io.userdata, ptr, expected, timeout);
    }
    fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("futexWaitUncancelable", void);
        if (!self.entryEnter()) return deadRefuse("futexWaitUncancelable", void);
        defer self.entryExit();
        return self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, ptr, expected);
    }
    fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        const self = shimFrom(userdata);
        // Wake/release class (group b): never refuse. A counted waiter blocked
        // in futexWaitUncancelable whose waker arrives during deinit MUST still
        // be woken, or entryCloseAndDrain hangs forever (review 690 B1). Counted
        // through the drain window; the forward is a stateless futex wake on the
        // caller's word, safe uncounted post-dead.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.futexWake(self.threaded_io.userdata, ptr, max_waiters);
    }
    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!Io.Operation.Result);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!Io.Operation.Result);
        defer self.entryExit();
        return self.threaded_io.vtable.operate(self.threaded_io.userdata, operation);
    }
    fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!void);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!void);
        defer self.entryExit();
        return self.threaded_io.vtable.batchAwaitAsync(self.threaded_io.userdata, batch);
    }
    fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Batch.AwaitConcurrentError!void);
        if (!self.entryEnter()) return deadResult(Io.Batch.AwaitConcurrentError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.batchAwaitConcurrent(self.threaded_io.userdata, batch, timeout);
    }
    fn batchCancel(userdata: ?*anyopaque, batch: *Io.Batch) void {
        const self = shimFrom(userdata);
        // Wake/release class (group b): never refuse. Counted through the drain
        // window so an in-flight cancel is drained before any free.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        // Post-dead POSIX no-op: Threaded.batchCancel frees the batch's poll
        // storage through t.allocator, which deinit frees; the caller-owned
        // storage leaks at instance teardown (bounded). The Windows path is
        // stateless (NtCancelIoFileEx on the caller's handles plus an
        // alertable NtDelayExecution), so it still forwards and cancels
        // pending I/O out of the caller-owned batch storage.
        if (!entered and !is_windows) return;
        return self.threaded_io.vtable.batchCancel(self.threaded_io.userdata, batch);
    }
    fn dirCreateDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.CreateDirError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.CreateDirError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirCreateDir(self.threaded_io.userdata, dir, sub_path, permissions);
    }
    fn dirCreateDirPath(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus);
        if (!self.entryEnter()) return deadResult(Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus);
        defer self.entryExit();
        return self.threaded_io.vtable.dirCreateDirPath(self.threaded_io.userdata, dir, sub_path, permissions);
    }
    fn dirCreateDirPathOpen(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.CreateDirPathOpenError!Io.Dir);
        if (!self.entryEnter()) return deadResult(Io.Dir.CreateDirPathOpenError!Io.Dir);
        defer self.entryExit();
        return self.threaded_io.vtable.dirCreateDirPathOpen(self.threaded_io.userdata, dir, sub_path, permissions, options);
    }
    fn dirOpenDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.OpenError!Io.Dir);
        if (!self.entryEnter()) return deadResult(Io.Dir.OpenError!Io.Dir);
        defer self.entryExit();
        return self.threaded_io.vtable.dirOpenDir(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirStat(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.StatError!Io.Dir.Stat);
        if (!self.entryEnter()) return deadResult(Io.Dir.StatError!Io.Dir.Stat);
        defer self.entryExit();
        return self.threaded_io.vtable.dirStat(self.threaded_io.userdata, dir);
    }
    fn dirStatFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.StatFileError!Io.File.Stat);
        if (!self.entryEnter()) return deadResult(Io.Dir.StatFileError!Io.File.Stat);
        defer self.entryExit();
        return self.threaded_io.vtable.dirStatFile(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirAccess(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.AccessError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.AccessError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirAccess(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirCreateFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.OpenError!Io.File);
        if (!self.entryEnter()) return deadResult(Io.File.OpenError!Io.File);
        defer self.entryExit();
        return self.threaded_io.vtable.dirCreateFile(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirCreateFileAtomic(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.CreateFileAtomicError!Io.File.Atomic);
        if (!self.entryEnter()) return deadResult(Io.Dir.CreateFileAtomicError!Io.File.Atomic);
        defer self.entryExit();
        return self.threaded_io.vtable.dirCreateFileAtomic(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirOpenFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.OpenError!Io.File);
        if (!self.entryEnter()) return deadResult(Io.File.OpenError!Io.File);
        defer self.entryExit();
        return self.threaded_io.vtable.dirOpenFile(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window,
        // stateless close(2)/CloseHandle forward uncounted post-dead.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.dirClose(self.threaded_io.userdata, dirs);
    }
    fn dirRead(userdata: ?*anyopaque, reader: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.Reader.Error!usize);
        if (!self.entryEnter()) return deadResult(Io.Dir.Reader.Error!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.dirRead(self.threaded_io.userdata, reader, entries);
    }
    fn dirRealPath(userdata: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.RealPathError!usize);
        if (!self.entryEnter()) return deadResult(Io.Dir.RealPathError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.dirRealPath(self.threaded_io.userdata, dir, out_buffer);
    }
    fn dirRealPathFile(userdata: ?*anyopaque, dir: Io.Dir, path_name: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.RealPathFileError!usize);
        if (!self.entryEnter()) return deadResult(Io.Dir.RealPathFileError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.dirRealPathFile(self.threaded_io.userdata, dir, path_name, out_buffer);
    }
    fn dirDeleteFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.DeleteFileError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.DeleteFileError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirDeleteFile(self.threaded_io.userdata, dir, sub_path);
    }
    fn dirDeleteDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.DeleteDirError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.DeleteDirError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirDeleteDir(self.threaded_io.userdata, dir, sub_path);
    }
    fn dirRename(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.RenameError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.RenameError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirRename(self.threaded_io.userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
    fn dirRenamePreserve(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.RenamePreserveError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.RenamePreserveError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirRenamePreserve(self.threaded_io.userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
    fn dirSymLink(userdata: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.SymLinkError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.SymLinkError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirSymLink(self.threaded_io.userdata, dir, target_path, sym_link_path, flags);
    }
    fn dirReadLink(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.ReadLinkError!usize);
        if (!self.entryEnter()) return deadResult(Io.Dir.ReadLinkError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.dirReadLink(self.threaded_io.userdata, dir, sub_path, buffer);
    }
    fn dirSetOwner(userdata: ?*anyopaque, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.SetOwnerError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.SetOwnerError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirSetOwner(self.threaded_io.userdata, dir, uid, gid);
    }
    fn dirSetFileOwner(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.SetFileOwnerError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.SetFileOwnerError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirSetFileOwner(self.threaded_io.userdata, dir, sub_path, uid, gid, options);
    }
    fn dirSetPermissions(userdata: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.SetPermissionsError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.SetPermissionsError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirSetPermissions(self.threaded_io.userdata, dir, permissions);
    }
    fn dirSetFilePermissions(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.SetFilePermissionsError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.SetFilePermissionsError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirSetFilePermissions(self.threaded_io.userdata, dir, sub_path, permissions, options);
    }
    fn dirSetTimestamps(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.SetTimestampsError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.SetTimestampsError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirSetTimestamps(self.threaded_io.userdata, dir, sub_path, options);
    }
    fn dirHardLink(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Dir.HardLinkError!void);
        if (!self.entryEnter()) return deadResult(Io.Dir.HardLinkError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.dirHardLink(self.threaded_io.userdata, old_dir, old_sub_path, new_dir, new_sub_path, options);
    }
    fn fileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.StatError!Io.File.Stat);
        if (!self.entryEnter()) return deadResult(Io.File.StatError!Io.File.Stat);
        defer self.entryExit();
        return self.threaded_io.vtable.fileStat(self.threaded_io.userdata, file);
    }
    fn fileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.LengthError!u64);
        if (!self.entryEnter()) return deadResult(Io.File.LengthError!u64);
        defer self.entryExit();
        return self.threaded_io.vtable.fileLength(self.threaded_io.userdata, file);
    }
    fn fileClose(userdata: ?*anyopaque, files: []const Io.File) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window,
        // stateless close(2)/CloseHandle forward uncounted post-dead.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.fileClose(self.threaded_io.userdata, files);
    }
    fn fileWritePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.WritePositionalError!usize);
        if (!self.entryEnter()) return deadResult(Io.File.WritePositionalError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.fileWritePositional(self.threaded_io.userdata, file, header, data, splat, offset);
    }
    fn fileWriteFileStreaming(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.File.Writer.WriteFileError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.Writer.WriteFileError!usize);
        if (!self.entryEnter()) return deadResult(Io.File.Writer.WriteFileError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.fileWriteFileStreaming(self.threaded_io.userdata, file, header, reader, limit);
    }
    fn fileWriteFilePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit, offset: u64) Io.File.WriteFilePositionalError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.WriteFilePositionalError!usize);
        if (!self.entryEnter()) return deadResult(Io.File.WriteFilePositionalError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.fileWriteFilePositional(self.threaded_io.userdata, file, header, reader, limit, offset);
    }
    fn fileReadPositional(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.ReadPositionalError!usize);
        if (!self.entryEnter()) return deadResult(Io.File.ReadPositionalError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.fileReadPositional(self.threaded_io.userdata, file, data, offset);
    }
    fn fileSeekBy(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SeekError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SeekError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSeekBy(self.threaded_io.userdata, file, relative_offset);
    }
    fn fileSeekTo(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SeekError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SeekError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSeekTo(self.threaded_io.userdata, file, absolute_offset);
    }
    fn fileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SyncError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SyncError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSync(self.threaded_io.userdata, file);
    }
    fn fileIsTty(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!bool);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!bool);
        defer self.entryExit();
        return self.threaded_io.vtable.fileIsTty(self.threaded_io.userdata, file);
    }
    fn fileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.EnableAnsiEscapeCodesError!void);
        if (!self.entryEnter()) return deadResult(Io.File.EnableAnsiEscapeCodesError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileEnableAnsiEscapeCodes(self.threaded_io.userdata, file);
    }
    fn fileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!bool);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!bool);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSupportsAnsiEscapeCodes(self.threaded_io.userdata, file);
    }
    fn fileSetLength(userdata: ?*anyopaque, file: Io.File, length: u64) Io.File.SetLengthError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SetLengthError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SetLengthError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSetLength(self.threaded_io.userdata, file, length);
    }
    fn fileSetOwner(userdata: ?*anyopaque, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.File.SetOwnerError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SetOwnerError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SetOwnerError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSetOwner(self.threaded_io.userdata, file, uid, gid);
    }
    fn fileSetPermissions(userdata: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SetPermissionsError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SetPermissionsError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSetPermissions(self.threaded_io.userdata, file, permissions);
    }
    fn fileSetTimestamps(userdata: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.SetTimestampsError!void);
        if (!self.entryEnter()) return deadResult(Io.File.SetTimestampsError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileSetTimestamps(self.threaded_io.userdata, file, options);
    }
    fn fileLock(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.LockError!void);
        if (!self.entryEnter()) return deadResult(Io.File.LockError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileLock(self.threaded_io.userdata, file, lock);
    }
    fn fileTryLock(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!bool {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.LockError!bool);
        if (!self.entryEnter()) return deadResult(Io.File.LockError!bool);
        defer self.entryExit();
        return self.threaded_io.vtable.fileTryLock(self.threaded_io.userdata, file, lock);
    }
    fn fileUnlock(userdata: ?*anyopaque, file: Io.File) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window,
        // stateless flock/NtUnlockFile forward uncounted post-dead.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.fileUnlock(self.threaded_io.userdata, file);
    }
    fn fileDowngradeLock(userdata: ?*anyopaque, file: Io.File) Io.File.DowngradeLockError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.DowngradeLockError!void);
        if (!self.entryEnter()) return deadResult(Io.File.DowngradeLockError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileDowngradeLock(self.threaded_io.userdata, file);
    }
    fn fileRealPath(userdata: ?*anyopaque, file: Io.File, out_buffer: []u8) Io.File.RealPathError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.RealPathError!usize);
        if (!self.entryEnter()) return deadResult(Io.File.RealPathError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.fileRealPath(self.threaded_io.userdata, file, out_buffer);
    }
    fn fileHardLink(userdata: ?*anyopaque, file: Io.File, dir: Io.Dir, sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.HardLinkError!void);
        if (!self.entryEnter()) return deadResult(Io.File.HardLinkError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileHardLink(self.threaded_io.userdata, file, dir, sub_path, options);
    }
    fn fileMemoryMapCreate(userdata: ?*anyopaque, file: Io.File, options: Io.File.MemoryMap.CreateOptions) Io.File.MemoryMap.CreateError!Io.File.MemoryMap {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.MemoryMap.CreateError!Io.File.MemoryMap);
        if (!self.entryEnter()) return deadResult(Io.File.MemoryMap.CreateError!Io.File.MemoryMap);
        defer self.entryExit();
        return self.threaded_io.vtable.fileMemoryMapCreate(self.threaded_io.userdata, file, options);
    }
    fn fileMemoryMapDestroy(userdata: ?*anyopaque, map: *Io.File.MemoryMap) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        // Post-dead: a file-backed mapping (section non-null) destroys through
        // munmap / NtUnmapViewOfSection + CloseHandle, stateless, so it still
        // forwards. An anonymous mapping (section null) frees through
        // t.allocator, which deinit frees; skip it (bounded leak at teardown).
        if (!entered and map.section == null) return;
        return self.threaded_io.vtable.fileMemoryMapDestroy(self.threaded_io.userdata, map);
    }
    fn fileMemoryMapSetLength(userdata: ?*anyopaque, map: *Io.File.MemoryMap, length: usize) Io.File.MemoryMap.SetLengthError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.MemoryMap.SetLengthError!void);
        if (!self.entryEnter()) return deadResult(Io.File.MemoryMap.SetLengthError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileMemoryMapSetLength(self.threaded_io.userdata, map, length);
    }
    fn fileMemoryMapRead(userdata: ?*anyopaque, map: *Io.File.MemoryMap) Io.File.ReadPositionalError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.ReadPositionalError!void);
        if (!self.entryEnter()) return deadResult(Io.File.ReadPositionalError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileMemoryMapRead(self.threaded_io.userdata, map);
    }
    fn fileMemoryMapWrite(userdata: ?*anyopaque, map: *Io.File.MemoryMap) Io.File.WritePositionalError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.File.WritePositionalError!void);
        if (!self.entryEnter()) return deadResult(Io.File.WritePositionalError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.fileMemoryMapWrite(self.threaded_io.userdata, map);
    }
    fn processExecutableOpen(userdata: ?*anyopaque, options: Io.Dir.OpenFileOptions) std.process.OpenExecutableError!Io.File {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.OpenExecutableError!Io.File);
        if (!self.entryEnter()) return deadResult(std.process.OpenExecutableError!Io.File);
        defer self.entryExit();
        return self.threaded_io.vtable.processExecutableOpen(self.threaded_io.userdata, options);
    }
    fn processExecutablePath(userdata: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.ExecutablePathError!usize);
        if (!self.entryEnter()) return deadResult(std.process.ExecutablePathError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.processExecutablePath(self.threaded_io.userdata, buffer);
    }
    fn lockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!Io.LockedStderr);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!Io.LockedStderr);
        defer self.entryExit();
        return self.threaded_io.vtable.lockStderr(self.threaded_io.userdata, mode);
    }
    fn tryLockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!?Io.LockedStderr);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!?Io.LockedStderr);
        defer self.entryExit();
        return self.threaded_io.vtable.tryLockStderr(self.threaded_io.userdata, mode);
    }
    fn unlockStderr(userdata: ?*anyopaque) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse. Counted through the drain
        // window: a counted lockStderr waiter may still be blocked on
        // t.stderr_mutex, so this MUST forward to release it or the drain hangs.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        // Post-dead no-op: the stderr lock, lock count and buffered writer are
        // Threaded fields that deinit destroys, so there is nothing left to
        // unlock or flush. lockStderr refuses post-gate (group a), so no new
        // lock can contend with the skipped unlock.
        if (!entered) return;
        return self.threaded_io.vtable.unlockStderr(self.threaded_io.userdata);
    }
    fn processCurrentPath(userdata: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.CurrentPathError!usize);
        if (!self.entryEnter()) return deadResult(std.process.CurrentPathError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.processCurrentPath(self.threaded_io.userdata, buffer);
    }
    fn processSetCurrentDir(userdata: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.SetCurrentDirError!void);
        if (!self.entryEnter()) return deadResult(std.process.SetCurrentDirError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.processSetCurrentDir(self.threaded_io.userdata, dir);
    }
    fn processSetCurrentPath(userdata: ?*anyopaque, sub_path: []const u8) std.process.SetCurrentPathError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.SetCurrentPathError!void);
        if (!self.entryEnter()) return deadResult(std.process.SetCurrentPathError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.processSetCurrentPath(self.threaded_io.userdata, sub_path);
    }
    fn processReplace(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.ReplaceError);
        if (!self.entryEnter()) return deadResult(std.process.ReplaceError);
        defer self.entryExit();
        return self.threaded_io.vtable.processReplace(self.threaded_io.userdata, options);
    }
    fn processSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.SpawnError!std.process.Child);
        if (!self.entryEnter()) return deadResult(std.process.SpawnError!std.process.Child);
        defer self.entryExit();
        return self.threaded_io.vtable.processSpawn(self.threaded_io.userdata, options);
    }
    fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.Child.WaitError!std.process.Child.Term);
        if (!self.entryEnter()) return deadResult(std.process.Child.WaitError!std.process.Child.Term);
        defer self.entryExit();
        return self.threaded_io.vtable.childWait(self.threaded_io.userdata, child);
    }
    fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window,
        // stateless kill forward uncounted post-dead. The Born-route override
        // (process_route.childKill) handles Born children.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.childKill(self.threaded_io.userdata, child);
    }
    fn progressParentFile(userdata: ?*anyopaque) std.Progress.ParentFileError!Io.File {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.Progress.ParentFileError!Io.File);
        if (!self.entryEnter()) return deadResult(std.Progress.ParentFileError!Io.File);
        defer self.entryExit();
        return self.threaded_io.vtable.progressParentFile(self.threaded_io.userdata);
    }
    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("now", Io.Timestamp);
        if (!self.entryEnter()) return deadRefuse("now", Io.Timestamp);
        defer self.entryExit();
        return self.threaded_io.vtable.now(self.threaded_io.userdata, clock);
    }
    fn clockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Clock.ResolutionError!Io.Duration);
        if (!self.entryEnter()) return deadResult(Io.Clock.ResolutionError!Io.Duration);
        defer self.entryExit();
        return self.threaded_io.vtable.clockResolution(self.threaded_io.userdata, clock);
    }
    fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!void);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!void);
        defer self.entryExit();
        return self.threaded_io.vtable.sleep(self.threaded_io.userdata, timeout);
    }
    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadRefuse("random", void);
        if (!self.entryEnter()) return deadRefuse("random", void);
        defer self.entryExit();
        return self.threaded_io.vtable.random(self.threaded_io.userdata, buffer);
    }
    fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.RandomSecureError!void);
        if (!self.entryEnter()) return deadResult(Io.RandomSecureError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.randomSecure(self.threaded_io.userdata, buffer);
    }
    fn netListenIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Socket {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.IpAddress.ListenError!Io.net.Socket);
        if (!self.entryEnter()) return deadResult(Io.net.IpAddress.ListenError!Io.net.Socket);
        defer self.entryExit();
        return self.threaded_io.vtable.netListenIp(self.threaded_io.userdata, address, options);
    }
    fn netAccept(userdata: ?*anyopaque, server: Io.net.Socket.Handle, options: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Server.AcceptError!Io.net.Socket);
        if (!self.entryEnter()) return deadResult(Io.net.Server.AcceptError!Io.net.Socket);
        defer self.entryExit();
        return self.threaded_io.vtable.netAccept(self.threaded_io.userdata, server, options);
    }
    fn netBindIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.IpAddress.BindError!Io.net.Socket);
        if (!self.entryEnter()) return deadResult(Io.net.IpAddress.BindError!Io.net.Socket);
        defer self.entryExit();
        return self.threaded_io.vtable.netBindIp(self.threaded_io.userdata, address, options);
    }
    fn netConnectIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.IpAddress.ConnectError!Io.net.Socket);
        if (!self.entryEnter()) return deadResult(Io.net.IpAddress.ConnectError!Io.net.Socket);
        defer self.entryExit();
        // Windows + 0.16: the shim owns connect to keep the CONNECT NTSTATUS
        // observable (std 0.16 discards it); elsewhere forward unchanged.
        if (is_windows and !is_017) return neterr016.connect(self.threaded_io, address, options);
        return self.threaded_io.vtable.netConnectIp(self.threaded_io.userdata, address, options);
    }
    fn netListenUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress, options: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.UnixAddress.ListenError!Io.net.Socket.Handle);
        if (!self.entryEnter()) return deadResult(Io.net.UnixAddress.ListenError!Io.net.Socket.Handle);
        defer self.entryExit();
        return self.threaded_io.vtable.netListenUnix(self.threaded_io.userdata, address, options);
    }
    fn netConnectUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle);
        if (!self.entryEnter()) return deadResult(Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle);
        defer self.entryExit();
        return self.threaded_io.vtable.netConnectUnix(self.threaded_io.userdata, address);
    }
    fn netSocketCreatePair(userdata: ?*anyopaque, options: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Socket.CreatePairError![2]Io.net.Socket);
        if (!self.entryEnter()) return deadResult(Io.net.Socket.CreatePairError![2]Io.net.Socket);
        defer self.entryExit();
        return self.threaded_io.vtable.netSocketCreatePair(self.threaded_io.userdata, options);
    }
    fn netWriteFile(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Stream.Writer.WriteFileError!usize);
        if (!self.entryEnter()) return deadResult(Io.net.Stream.Writer.WriteFileError!usize);
        defer self.entryExit();
        return self.threaded_io.vtable.netWriteFile(self.threaded_io.userdata, handle, header, reader, limit);
    }
    fn netShutdown(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.ShutdownError!void);
        if (!self.entryEnter()) return deadResult(Io.net.ShutdownError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.netShutdown(self.threaded_io.userdata, handle, how);
    }
    fn netInterfaceNameResolve(userdata: ?*anyopaque, name: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Interface.Name.ResolveError!Io.net.Interface);
        if (!self.entryEnter()) return deadResult(Io.net.Interface.Name.ResolveError!Io.net.Interface);
        defer self.entryExit();
        return self.threaded_io.vtable.netInterfaceNameResolve(self.threaded_io.userdata, name);
    }
    fn netInterfaceName(userdata: ?*anyopaque, interface: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Interface.NameError!Io.net.Interface.Name);
        if (!self.entryEnter()) return deadResult(Io.net.Interface.NameError!Io.net.Interface.Name);
        defer self.entryExit();
        return self.threaded_io.vtable.netInterfaceName(self.threaded_io.userdata, interface);
    }
    fn netLookup(userdata: ?*anyopaque, hostname: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.HostName.LookupError!void);
        if (!self.entryEnter()) return deadResult(Io.net.HostName.LookupError!void);
        defer self.entryExit();
        return self.threaded_io.vtable.netLookup(self.threaded_io.userdata, hostname, queue, options);
    }
};

/// Slots present only on the 0.16.x interface (plus its `netClose` signature).
const fwd016 = if (!is_017) struct {
    fn processReplacePath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.ReplaceError);
        if (!self.entryEnter()) return deadResult(std.process.ReplaceError);
        defer self.entryExit();
        return self.threaded_io.vtable.processReplacePath(self.threaded_io.userdata, dir, options);
    }
    fn processSpawnPath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.SpawnError!std.process.Child);
        if (!self.entryEnter()) return deadResult(std.process.SpawnError!std.process.Child);
        defer self.entryExit();
        return self.threaded_io.vtable.processSpawnPath(self.threaded_io.userdata, dir, options);
    }
    fn netSend(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return .{ error.Unexpected, 0 };
        if (!self.entryEnter()) return .{ error.Unexpected, 0 };
        defer self.entryExit();
        const result = self.threaded_io.vtable.netSend(self.threaded_io.userdata, handle, messages, flags);
        // Windows: recover the sticky terminal state behind error.Unexpected;
        // success and non-terminal errors forward unchanged.
        if (is_windows) {
            if (result[0]) |err| {
                if (err == error.Unexpected) {
                    if (neterr016.sendError(self.threaded_io, handle)) |mapped| return .{ mapped, result[1] };
                }
            }
        }
        return result;
    }
    fn netRead(userdata: ?*anyopaque, src: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Stream.Reader.Error!usize);
        if (!self.entryEnter()) return deadResult(Io.net.Stream.Reader.Error!usize);
        defer self.entryExit();
        // Windows: recover the sticky terminal state behind error.Unexpected;
        // success and non-terminal errors forward unchanged.
        if (is_windows) {
            return self.threaded_io.vtable.netRead(self.threaded_io.userdata, src, data) catch |err| {
                if (err == error.Unexpected) {
                    if (neterr016.readError(self.threaded_io, src)) |mapped| return mapped;
                }
                return err;
            };
        }
        return self.threaded_io.vtable.netRead(self.threaded_io.userdata, src, data);
    }
    fn netWrite(userdata: ?*anyopaque, dest: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Stream.Writer.Error!usize);
        if (!self.entryEnter()) return deadResult(Io.net.Stream.Writer.Error!usize);
        defer self.entryExit();
        // Windows: recover the sticky terminal state behind error.Unexpected;
        // success and non-terminal errors forward unchanged.
        if (is_windows) {
            return self.threaded_io.vtable.netWrite(self.threaded_io.userdata, dest, header, data, splat) catch |err| {
                if (err == error.Unexpected) {
                    if (neterr016.writeError(self.threaded_io, dest)) |mapped| return mapped;
                }
                return err;
            };
        }
        return self.threaded_io.vtable.netWrite(self.threaded_io.userdata, dest, header, data, splat);
    }
    fn netClose(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window,
        // stateless close forward uncounted post-dead. This is the pure Threaded
        // forward; the Born route override is net01x.netClose.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.netClose(self.threaded_io.userdata, handles);
    }
} else struct {};

/// Slots present only on the 0.17.x interface (plus its `netClose` signature).
const fwd017 = if (is_017) struct {
    fn inheritParentDir(userdata: ?*anyopaque, handle: Io.Dir.Handle) Io.InheritParentHandleError!Io.Dir {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.InheritParentHandleError!Io.Dir);
        if (!self.entryEnter()) return deadResult(Io.InheritParentHandleError!Io.Dir);
        defer self.entryExit();
        return self.threaded_io.vtable.inheritParentDir(self.threaded_io.userdata, handle);
    }
    fn inheritParentFile(userdata: ?*anyopaque, handle: Io.File.Handle, flags: Io.File.Flags) Io.InheritParentHandleError!Io.File {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.InheritParentHandleError!Io.File);
        if (!self.entryEnter()) return deadResult(Io.InheritParentHandleError!Io.File);
        defer self.entryExit();
        return self.threaded_io.vtable.inheritParentFile(self.threaded_io.userdata, handle, flags);
    }
    fn netClose(userdata: ?*anyopaque, sockets: []const Io.net.Socket) void {
        const self = shimFrom(userdata);
        // Release class (group b): never refuse; counted through the drain window,
        // stateless close forward uncounted post-dead.
        const entered = self.releaseEnter();
        defer if (entered) self.entryExit();
        return self.threaded_io.vtable.netClose(self.threaded_io.userdata, sockets);
    }
} else struct {};

/// Complete explicit Threaded-delegation baseline vtable for the selected
/// toolchain. Every slot is a forwarding thunk; the written-out signatures are
/// the function-type half of the compatibility gate (any upstream signature
/// drift fails at the assignment). Only the taken branch is analyzed. Private:
/// the public `baseline_vtable` alias below is `vtable_table[0]`.
const base_vtable: Io.VTable = if (is_017) .{
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

/// Born evented implementations of the process family (P5.4, Option B).
/// FreeBSD and Linux only (`process_supported`); every other target rejects
/// `capabilities.process = .born_evented` at construction, so these thunks'
/// Born bodies are comptime-pruned there and the forwarding branch is the
/// only live path. Spawn resolves PATH shim-side (5.2), creates close-on-exec
/// stdio pipes (5.3), reserves a registry slot before the fork (S1), spawns
/// through `born.process`, and parks an uncancelable arm confirmation so the
/// exit watch is confirmed live before the child is returned (synchronous
/// arm, 4.3). Wait parks a cancelable exit op (cancellation abandons the
/// child, 6.3); kill is an uncancelable drain (caller SIGTERM, loop teardown,
/// 7). Child stream I/O on the pipe parent ends stays Threaded-serviced (5.3).
const process_route = struct {
    fn processSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.SpawnError!std.process.Child);
        if (!self.entryEnter()) return deadResult(std.process.SpawnError!std.process.Child);
        defer self.entryExit();
        if (self.capabilities.process != .born_evented) {
            if (process_stats_enabled) _ = self.proc_stats.threaded_spawn.fetchAdd(1, .monotonic);
            return fwd.processSpawn(userdata, options);
        }
        if (comptime process_supported) {
            try rejectSpawnOptions(options);

            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const argv_buf = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
            for (options.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeSentinel(u8, arg, 0)).ptr;

            const envp_buf = try arena.allocSentinel(?[*:0]const u8, envCount(options), null);
            if (options.environ_map) |env| {
                const keys = env.keys();
                const values = env.values();
                for (keys, values, 0..) |k, v, i|
                    envp_buf[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ k, v }, 0)).ptr;
            } else {
                var i: usize = 0;
                while (std.c.environ[i]) |entry| : (i += 1)
                    envp_buf[i] = (try arena.dupeSentinel(u8, std.mem.span(entry), 0)).ptr;
            }

            var pipes = try makePipes(options);
            // The shim owns every pipe end until spawn returns the Child
            // (review R1). Any failure before return destroys the remaining
            // ends; the success path nulls `pipes` to transfer ownership to
            // the caller's Child fields, which then own them alone.
            errdefer destroyPipes(&pipes);
            var published = false;

            // Reserve the slot BEFORE the fork (S1): a ceiling/OOM refusal
            // creates no child. The generation guards stale exit events.
            const reserved = try self.childReserve();
            errdefer if (!published) self.childRelease(reserved.index);

            const resolved = try resolvePath(arena, options.argv[0]);

            var born_child = born.process.spawn(argv_buf.ptr, envp_buf.ptr, .{
                .path = resolved.ptr,
                .stdin = bornStdio(options.stdin, pipes[0]),
                .stdout = bornStdio(options.stdout, pipes[1]),
                .stderr = bornStdio(options.stderr, pipes[2]),
            }) catch |err| return mapSpawnError(err);

            // The child exists and has exec'd. Close the child-end pipe
            // copies (the child dup'd them onto 0/1/2); the parent keeps the
            // parent ends. Mark the child ends closed so a later destroyPipes
            // closes only the parent ends.
            for (&pipes) |*p| if (p.*) |*pp| {
                compat.close(pp.child_end);
                pp.child_end = -1;
            };
            const stdin_parent = parentPipe(pipes[0]);
            const stdout_parent = parentPipe(pipes[1]);
            const stderr_parent = parentPipe(pipes[2]);

            self.childPublish(reserved.index, born_child) catch {
                // OOM inserting the pid mapping: kill and close the child.
                // The errdefers release the reserved slot and destroy the
                // pipes; the catch must not also release (a double free-list
                // push would corrupt the registry).
                born_child.kill(compat.signalNumber(std.posix.SIG.KILL)) catch {};
                born_child.close();
                return error.OutOfMemory;
            };
            published = true;

            // Synchronous arm (4.3): park the uncancelable arm confirmation
            // and wait for the loop to confirm the exit watch live. Any
            // refusal kills and cleans up the child; it is never returned (5.5).
            var arm: ProcOp = .{ .kind = .arm, .child_index = reserved.index, .child_gen = reserved.generation };
            self.procWaitUncancelable(&arm);
            if (arm.result.err != null) {
                born_child.kill(compat.signalNumber(std.posix.SIG.KILL)) catch {};
                var kop: ProcOp = .{ .kind = .kill, .child_index = reserved.index, .child_gen = reserved.generation };
                self.procWaitUncancelable(&kop);
                if (kop.result.err == .route_dead)
                    _ = self.childDeadClaim(&kop, compat.signalNumber(std.posix.SIG.KILL));
                return error.Unexpected;
            }

            if (process_stats_enabled) _ = self.proc_stats.spawn.fetchAdd(1, .monotonic);
            // Ownership of the parent ends transfers to the returned Child
            // (review R1); the shim keeps no copy. Null `pipes` so the
            // errdefer destroyPipes is a no-op on this success path.
            pipes = .{ null, null, null };
            return .{
                .id = born_child.pid,
                .thread_handle = {},
                .stdin = filePipe(stdin_parent),
                .stdout = filePipe(stdout_parent),
                .stderr = filePipe(stderr_parent),
                .request_resource_usage_statistics = false,
            };
        } else return error.OperationUnsupported;
    }

    fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(std.process.Child.WaitError!std.process.Child.Term);
        if (!self.entryEnter()) return deadResult(std.process.Child.WaitError!std.process.Child.Term);
        defer self.entryExit();
        if (self.capabilities.process != .born_evented) {
            if (process_stats_enabled) _ = self.proc_stats.threaded_wait.fetchAdd(1, .monotonic);
            return fwd.childWait(userdata, child);
        }
        if (comptime process_supported) {
            const pid = child.id orelse return fwd.childWait(userdata, child);
            const found = self.lookupChild(pid) orelse {
                // Threaded-owned child: forward unchanged (provenance gate).
                if (process_stats_enabled) _ = self.proc_stats.threaded_wait.fetchAdd(1, .monotonic);
                return fwd.childWait(userdata, child);
            };
            var op: ProcOp = .{ .kind = .wait, .child_index = found.index, .child_gen = found.generation };
            self.procWait(&op) catch |err| switch (err) {
                error.Canceled => {
                    // Abandon (6.3): the loop kept the descriptor watched and
                    // unpublished the pid. Close the caller's remaining stdio
                    // ends on the caller thread (review R1) and invalidate.
                    closeChildStdio(child);
                    child.id = null;
                    return error.Canceled;
                },
            };
            // A completed wait tears the slot down on the loop; a dead-loop
            // refusal leaves the child registered for deinit. Either way the
            // caller's stdio ends close here and the fields invalidate, so a
            // stale id never reaches a later wait or kill (review R1).
            closeChildStdio(child);
            child.id = null;
            if (op.result.err != null) return error.Unexpected;
            const exit = op.result.exit orelse return error.Unexpected;
            if (process_stats_enabled) _ = self.proc_stats.wait.fetchAdd(1, .monotonic);
            return termFromExit(exit);
        } else return error.Unexpected;
    }

    fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
        const self = shimFrom(userdata);
        // Release class (review 690 B1): never refuse. Counted pre-gate; the
        // pre-gate path is unchanged. Post-gate the loop is joined, so a
        // Born-owned child gets the descriptor SIGTERM (a plain syscall) and
        // its caller stdio closed, but no proc-queue submission;
        // childRegistryCloseAll reaps it at deinit. Threaded-owned children
        // forward to Threaded.
        const entered = self.entryEnter();
        defer if (entered) self.entryExit();
        if (self.capabilities.process != .born_evented) {
            if (process_stats_enabled) _ = self.proc_stats.threaded_kill.fetchAdd(1, .monotonic);
            return fwd.childKill(userdata, child);
        }
        if (comptime process_supported) {
            const pid = child.id orelse return; // idempotent no-op
            const found = self.lookupChild(pid) orelse {
                if (process_stats_enabled) _ = self.proc_stats.threaded_kill.fetchAdd(1, .monotonic);
                return fwd.childKill(userdata, child);
            };
            // Caller SIGTERM through the descriptor (7.3): a plain syscall,
            // safe from any thread, never reaching a recycled pid. An error
            // (e.g. already exited) does not abort cleanup.
            if (self.childSnapshot(found.index, found.generation)) |cs| {
                var bc = cs.child;
                bc.kill(compat.signalNumber(std.posix.SIG.TERM)) catch {};
            }
            if (!entered) {
                // Post-gate: skip the dead proc queue; close the caller's stdio
                // ends and invalidate the id (review R1) so no stale id survives.
                closeChildStdio(child);
                child.id = null;
                return;
            }
            var op: ProcOp = .{ .kind = .kill, .child_index = found.index, .child_gen = found.generation };
            self.procWaitUncancelable(&op);
            if (op.result.err == .route_dead)
                _ = self.childDeadClaim(&op, compat.signalNumber(std.posix.SIG.TERM));
            // Close the caller's remaining stdio ends on the caller thread
            // (review R1); the loop never touched them.
            closeChildStdio(child);
            child.id = null;
            if (process_stats_enabled) _ = self.proc_stats.kill.fetchAdd(1, .monotonic);
        }
    }

    /// 0.16-only slot: the shim has no dir-relative spawn (5.1). Removed on
    /// 0.17, where the vtable has no such slot.
    fn processSpawnPath(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        _ = userdata;
        _ = dir;
        _ = options;
        return error.OperationUnsupported;
    }
};

/// Reject the spawn options `born.process` cannot express (5.1). Every
/// rejection uses the declared `error.OperationUnsupported`; none invents an
/// error. `create_no_window`/`disable_aslr` are Windows/Darwin-only and absent
/// from the supported targets' option set, so they need no row.
fn rejectSpawnOptions(options: std.process.SpawnOptions) std.process.SpawnError!void {
    // std declares no InvalidArgument tag; empty argv (no exe to resolve) is
    // coarse-mapped to the declared Unexpected, like SetupFailed/ExecFailed.
    if (options.argv.len == 0) return error.Unexpected;
    if (options.expand_arg0 == .expand) return error.OperationUnsupported;
    if (options.stdin == .close or options.stdout == .close or options.stderr == .close)
        return error.OperationUnsupported;
    if (options.cwd != .inherit) return error.OperationUnsupported;
    if (options.uid != null or options.gid != null or options.pgid != null)
        return error.OperationUnsupported;
    if (options.start_suspended) return error.OperationUnsupported;
    if (options.progress_node.index != .none) return error.OperationUnsupported;
    if (options.request_resource_usage_statistics) return error.OperationUnsupported;
    if (comptime is_017) {
        switch (options.exe) {
            .detect, .search => {},
            .path, .file, .explicit => return error.OperationUnsupported,
        }
        if (options.inherit_dirs.len != 0 or options.inherit_files.len != 0)
            return error.OperationUnsupported;
    }
}

/// One shim-created stdio pipe: the child end (passed to `born.process` as
/// `.handle`, dup'd onto 0/1/2 by the child) and the parent end (wrapped as a
/// blocking `Io.File`). `child_end` is set to -1 once closed after the fork.
const ProcPipe = struct { child_end: compat.fd_t, parent_end: compat.fd_t };

/// Create a `pipe2(O_CLOEXEC)` pair for each `.pipe` stdio slot (5.3). Both
/// ends are close-on-exec before the fork so a racing spawn never inherits
/// them. `pipe2` returns [read, write]: stdin's child end is the read end
/// (the child reads it) and the parent keeps the write end; stdout/stderr's
/// child end is the write end (the child writes it) and the parent keeps the
/// read end. The orientation matters on half-duplex pipes (Linux): reading a
/// write end or writing a read end is EBADF. FreeBSD's full-duplex pipes mask
/// a swap, so the contract tests must run on Linux too. On any failure every
/// pipe created so far is destroyed (both ends).
fn makePipes(options: std.process.SpawnOptions) std.process.SpawnError![3]?ProcPipe {
    var pipes: [3]?ProcPipe = .{ null, null, null };
    errdefer destroyPipes(&pipes);
    const modes = [3]std.process.SpawnOptions.StdIo{ options.stdin, options.stdout, options.stderr };
    for (modes, 0..) |mode, i| {
        if (mode != .pipe) continue;
        const ends = compat.pipe2(.{ .CLOEXEC = true }) catch |err| switch (err) {
            error.SystemFdQuotaExceeded, error.ProcessFdQuotaExceeded => return error.SystemResources,
            else => return error.Unexpected,
        };
        pipes[i] = .{
            .child_end = if (i == 0) ends[0] else ends[1],
            .parent_end = if (i == 0) ends[1] else ends[0],
        };
    }
    return pipes;
}

/// Close every remaining end of each created pipe and null the slot. A
/// `child_end` of -1 (already closed after the fork) is skipped, so this closes
/// only the parent ends once the child exists.
fn destroyPipes(pipes: *[3]?ProcPipe) void {
    for (pipes) |*p| {
        if (p.*) |pp| {
            if (pp.child_end >= 0) compat.close(pp.child_end);
            compat.close(pp.parent_end);
            p.* = null;
        }
    }
}

fn parentPipe(p: ?ProcPipe) ?compat.fd_t {
    return if (p) |pp| pp.parent_end else null;
}

/// Wrap a shim-created parent pipe end as a blocking `Io.File` (5.3): the
/// Threaded file slots expect blocking ends. Null for inherit/ignore/file.
fn filePipe(fd: ?compat.fd_t) ?Io.File {
    return if (fd) |f| .{ .handle = f, .flags = .{ .nonblocking = false } } else null;
}

/// Close the parent pipe ends still held by the caller's `Child` and null
/// the fields (review R1): after spawn returns, the std `Child` fields are
/// the sole owners of the shim-created ends. The wait/kill thunks and the
/// cancel path call this on the caller thread; the loop never closes them.
/// Only shim-created pipe ends ever appear here (inherit/ignore/file leave
/// the fields null), so this never closes a caller-owned descriptor.
fn closeChildStdio(child: *std.process.Child) void {
    if (child.stdin) |f| {
        compat.close(f.handle);
        child.stdin = null;
    }
    if (child.stdout) |f| {
        compat.close(f.handle);
        child.stdout = null;
    }
    if (child.stderr) |f| {
        compat.close(f.handle);
        child.stderr = null;
    }
}

/// Map a std stdio mode to a `born.process.Stdio` (5.1). `.pipe` uses the
/// shim-created child end; `.file` is caller-owned (never closed by the shim).
fn bornStdio(mode: std.process.SpawnOptions.StdIo, pipe: ?ProcPipe) born.process.Stdio {
    return switch (mode) {
        .inherit => .inherit,
        .ignore => .devnull,
        .file => |f| .{ .handle = f.handle },
        .pipe => .{ .handle = pipe.?.child_end },
        .close => unreachable, // rejected by rejectSpawnOptions
    };
}

/// Number of environment entries the child will receive: the explicit map's
/// size, or the parent's global environ count.
fn envCount(options: std.process.SpawnOptions) usize {
    if (options.environ_map) |env| return env.keys().len;
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    return n;
}

/// Resolve argv[0] against the parent environment PATH, mirroring std's exec
/// search (5.2). argv[0] with '/' passes through unchanged. PATH is tokenized
/// on ':' with empty tokens skipped (no implicit cwd entry); each candidate is
/// probed with `stat` (not `lstat`, so a symlink to a regular executable is
/// accepted) requiring a regular file, then `faccessat(AT_FDCWD, X_OK,
/// AT_EACCESS)` (effective uid, matching execve). A regular non-executable
/// candidate latches AccessDenied and the search continues; the first regular
/// executable wins. Nothing matched: AccessDenied if latched, else FileNotFound.
/// The PATH source is the parent's global environ, never `environ_map`'s PATH;
/// the default mirrors each toolchain's own `Io.Threaded.default_PATH`.
fn resolvePath(arena: std.mem.Allocator, argv0: []const u8) std.process.SpawnError![:0]const u8 {
    if (std.mem.indexOfScalar(u8, argv0, '/') != null)
        return try arena.dupeSentinel(u8, argv0, 0);
    const path_env = blk: {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const e = std.mem.span(entry);
            if (std.mem.startsWith(u8, e, "PATH=")) break :blk e["PATH=".len..];
        }
        break :blk Io.Threaded.default_PATH;
    };
    var access_denied = false;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try arena.allocSentinel(u8, dir.len + 1 + argv0.len, 0);
        @memcpy(candidate[0..dir.len], dir);
        candidate[dir.len] = '/';
        @memcpy(candidate[dir.len + 1 ..][0..argv0.len], argv0);
        if (comptime is_freebsd) {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(std.c.AT.FDCWD, candidate.ptr, &st, 0) != 0) continue;
            if (!std.c.S.ISREG(@as(u32, st.mode))) continue;
            const rc = std.c.faccessat(std.c.AT.FDCWD, candidate.ptr, std.c.X_OK, std.c.AT.EACCESS);
            if (rc != 0) {
                if (std.posix.errno(@as(isize, rc)) == .ACCES) access_denied = true;
                continue;
            }
        } else {
            var stx: std.os.linux.Statx = undefined;
            const sr = std.os.linux.statx(std.os.linux.AT.FDCWD, candidate.ptr, 0, .{ .TYPE = true, .MODE = true }, &stx);
            if (compat.linuxErrno(sr) != .SUCCESS) continue;
            if (stx.mode & std.posix.S.IFMT != std.posix.S.IFREG) continue;
            // AT_EACCESS (0x100): effective uid, matching execve. std's Linux
            // AT struct does not name it, so the value is spelled out.
            const ar = std.os.linux.faccessat(std.os.linux.AT.FDCWD, candidate.ptr, std.os.linux.X_OK, 0x100);
            switch (compat.linuxErrno(ar)) {
                .SUCCESS => {},
                .ACCES => {
                    access_denied = true;
                    continue;
                },
                else => continue,
            }
        }
        return candidate;
    }
    return if (access_denied) error.AccessDenied else error.FileNotFound;
}

/// Coarse `born.process.SpawnError` -> `std.process.SpawnError` map (5.4).
/// `SetupFailed`/`ExecFailed` collapse to `Unexpected` (no std setup/exec tag);
/// `InvalidArgument` also collapses to `Unexpected` because std declares no
/// `InvalidArgument` tag (the design table named a non-existent tag). The loss
/// is documented, not hidden.
fn mapSpawnError(err: born.process.SpawnError) std.process.SpawnError {
    return switch (err) {
        error.Unsupported => error.OperationUnsupported,
        error.InvalidArgument => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.InvalidExe => error.InvalidExe,
        error.SetupFailed, error.ExecFailed => error.Unexpected,
    };
}

/// Map a collected exit to a std `Term` (6.1). The exit watch only reports
/// exits, so `.stopped`/`.unknown` are never produced.
fn termFromExit(exit: born.ProcessExit) std.process.Child.Term {
    return switch (exit) {
        .code => |c| .{ .exited = c },
        .signal => |s| .{ .signal = compat.nativeSignal(s) },
    };
}

/// Born evented implementations of the network client path (P5.3, Option B).
/// Shared thunks have identical signatures on both toolchains; the
/// toolchain-specific slots live in `net016`/`net017`. Every other slot keeps
/// its baseline forwarding thunk; `network_vtable` is a comptime copy of the
/// baseline with only these slots replaced, so the two cannot drift.
const network_route = struct {
    /// IP connect on Born. Only `.stream` with `protocol == null or .tcp` is
    /// adapted; other values return declared `OptionUnsupported` (never
    /// truncated to TCP). Timeouts on any clock are converted to a Born
    /// monotonic deadline (`.duration` relative; `.deadline` on `.real`/`.boot`
    /// via that clock's now), so the connect stays on the Born route; a clock
    /// read refusal fails with Unexpected. The loop creates the socket, drives
    /// the non-blocking connect and the deadline race, and populates the local
    /// address via getsockname (section 5).
    fn netConnectIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.IpAddress.ConnectError!Io.net.Socket);
        if (!self.entryEnter()) return deadResult(Io.net.IpAddress.ConnectError!Io.net.Socket);
        defer self.entryExit();
        if (options.mode != .stream) return error.OptionUnsupported;
        if (options.protocol) |p| {
            if (p != .tcp) return error.OptionUnsupported;
        }
        var op: NetOp = .{
            .kind = .connect,
            .payload = .{ .connect = .{
                .target = .{ .ip = ipToBorn(address) },
                .deadline_ns = self.timeoutToDeadline(options.timeout) catch return error.Unexpected,
            } },
        };
        try self.netWait(&op);
        if (op.result.err) |e| return mapConnectIpError(e);
        return .{ .handle = op.result.handle, .address = bornToIp(op.result.address) };
    }

    /// Unix connect: pathname -> Born; abstract/embedded-NUL -> Threaded (honest
    /// std coverage, never a fake refusal); Windows -> AddressFamilyUnsupported
    /// (section 5.4). The Threaded fallback produces a Threaded-owned handle
    /// that later read/write/close dispatch correctly via the provenance gate.
    fn netConnectUnix(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle);
        if (!self.entryEnter()) return deadResult(Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle);
        defer self.entryExit();
        if (is_windows) return error.AddressFamilyUnsupported;
        const path = address.path;
        if (address.isAbstract() or std.mem.indexOfScalar(u8, path, 0) != null) {
            if (network_stats_enabled) _ = self.net_stats.threaded_connect.fetchAdd(1, .monotonic);
            return fwd.netConnectUnix(userdata, address);
        }
        var op: NetOp = .{
            .kind = .connect,
            .payload = .{ .connect = .{ .target = .{ .unix = path }, .deadline_ns = 0 } },
        };
        try self.netWait(&op);
        if (op.result.err) |e| return mapConnectUnixError(e);
        return op.result.handle;
    }

    /// Shutdown on a Born-owned socket: POSIX is a plain shutdown(2), which
    /// wakes a parked read with EOF. Windows shutdown() does not complete
    /// pending overlapped ops, so a recv/send shutdown also cancels the
    /// in-flight WSARecv/WSASend (shutdownCancelPending). Threaded-owned
    /// forwards (section 6, Q6).
    fn netShutdown(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.ShutdownError!void);
        if (!self.entryEnter()) return deadResult(Io.net.ShutdownError!void);
        defer self.entryExit();
        const index = switch (self.lookupBorn(handle)) {
            .absent => return fwd.netShutdown(userdata, handle, how),
            .closing => return error.Unexpected,
            .live => |i| i,
        };
        defer self.sockUserExit(index);
        const born_how: compat.ShutdownHow = switch (how) {
            .recv => .recv,
            .send => .send,
            .both => .both,
        };
        compat.shutdown(compatSock(handle), born_how) catch |e| return mapShutdownError(e);
        if (is_windows) self.shutdownCancelPending(handle, how);
    }

    /// Bind-only sockets are outside the stream-only client profile (section
    /// 14): declared OptionUnsupported, never a silent Threaded fallback.
    fn netBindIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
        _ = userdata;
        _ = address;
        _ = options;
        return error.OptionUnsupported;
    }

    /// Socketpair is outside the client profile (section 14): declared
    /// OperationUnsupported.
    fn netSocketCreatePair(userdata: ?*anyopaque, options: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
        _ = userdata;
        _ = options;
        return error.OperationUnsupported;
    }

    /// Batch provenance gate (section 10): complete each Born-owned member with
    /// its tag result error.Unexpected, then forward the remaining
    /// Threaded-owned/file/device members. Returns normally with per-op failures
    /// for the Born members, never a canceled await.
    fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!void);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!void);
        defer self.entryExit();
        _ = self.batchPartitionBorn(batch);
        if (batch.submitted.head == .none) return;
        return fwd.batchAwaitAsync(userdata, batch);
    }

    fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Batch.AwaitConcurrentError!void);
        if (!self.entryEnter()) return deadResult(Io.Batch.AwaitConcurrentError!void);
        defer self.entryExit();
        _ = self.batchPartitionBorn(batch);
        if (batch.submitted.head == .none) return;
        return fwd.batchAwaitConcurrent(userdata, batch, timeout);
    }
};

/// Network slots specific to the 0.16.x interface: direct netRead/netWrite/
/// netSend slots, netClose over []const Socket.Handle, the net_receive-only
/// operate, and the non-panicking internal-copy netWriteFile.
const net016 = if (!is_017) struct {
    fn netRead(userdata: ?*anyopaque, src: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Stream.Reader.Error!usize);
        if (!self.entryEnter()) return deadResult(Io.net.Stream.Reader.Error!usize);
        defer self.entryExit();
        const index = switch (self.lookupBorn(src)) {
            .absent => {
                if (network_stats_enabled) _ = self.net_stats.threaded_read.fetchAdd(1, .monotonic);
                return fwd016.netRead(userdata, src, data);
            },
            .closing => return error.Unexpected,
            .live => |i| i,
        };
        defer self.sockUserExit(index);
        var op: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = data } } };
        try self.netWait(&op);
        if (op.result.err) |e| return mapIoError(e);
        return op.result.count; // 0 on EOF; the Reader converts it to EndOfStream
    }

    fn netWrite(userdata: ?*anyopaque, dest: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Stream.Writer.Error!usize);
        if (!self.entryEnter()) return deadResult(Io.net.Stream.Writer.Error!usize);
        defer self.entryExit();
        const index = switch (self.lookupBorn(dest)) {
            .absent => {
                if (network_stats_enabled) _ = self.net_stats.threaded_write.fetchAdd(1, .monotonic);
                return fwd016.netWrite(userdata, dest, header, data, splat);
            },
            .closing => return error.Unexpected,
            .live => |i| i,
        };
        defer self.sockUserExit(index);
        var op: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = header, .data = data, .splat = splat } } };
        try self.netWait(&op);
        if (op.result.err) |e| return mapIoError(e);
        return op.result.count;
    }

    /// Message send is excluded by the stream-only profile: a Born-owned handle
    /// completes with the per-message tag result error.Unexpected (section 8).
    fn netSend(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return .{ error.Unexpected, 0 };
        if (!self.entryEnter()) return .{ error.Unexpected, 0 };
        defer self.entryExit();
        if (self.sockClassify(handle) == .absent) return fwd016.netSend(userdata, handle, messages, flags);
        return .{ error.Unexpected, 0 };
    }

    fn netClose(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
        const self = shimFrom(userdata);
        // Release class (review 690 B1): never refuse. Counted pre-gate; the
        // pre-gate path is unchanged. Post-gate the loop is joined, so a
        // Born-owned slot is skipped (the loop's netRetireAll closes it at deinit,
        // no leak) instead of submitting to the dead net queue; Threaded-owned
        // handles still forward to Threaded.
        const entered = self.entryEnter();
        defer if (entered) self.entryExit();
        for (handles) |h| {
            switch (self.sockClassify(h)) {
                .live => |index| {
                    if (!entered) continue;
                    var op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
                    self.netCloseWait(&op);
                },
                .closing => {}, // another close already owns this slot's teardown
                .absent => {
                    const one: [1]Io.net.Socket.Handle = .{h};
                    fwd016.netClose(userdata, &one);
                },
            }
        }
    }

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!Io.Operation.Result);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!Io.Operation.Result);
        defer self.entryExit();
        switch (operation) {
            .net_receive => |o| {
                if (self.sockClassify(o.socket_handle) == .absent) return fwd.operate(userdata, operation);
                return .{ .net_receive = .{ error.Unexpected, 0 } };
            },
            else => return fwd.operate(userdata, operation),
        }
    }

    /// 0.16 WriteFileError has no Unimplemented and Threaded 0.16 netWriteFile
    /// @panics, so the shim performs an internal read/copy for both provenances:
    /// read from the file reader through its Io.Reader interface, write to the
    /// socket through the provenance-routed write path (section 8). Never
    /// forwards to Threaded's panicking slot.
    fn netWriteFile(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.net.Stream.Writer.WriteFileError!usize);
        if (!self.entryEnter()) return deadResult(Io.net.Stream.Writer.WriteFileError!usize);
        defer self.entryExit();
        var written: usize = 0;
        var remaining = limit;
        if (header.len != 0) {
            const data: [1][]const u8 = .{header};
            _ = net016.netWrite(userdata, handle, &.{}, &data, 1) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.Unexpected,
            };
            written += header.len;
            remaining = remaining.subtract(header.len) orelse return written;
        }
        var buf: [16384]u8 = undefined;
        while (remaining.nonzero()) {
            const slice = remaining.slice(&buf);
            var data: [1][]u8 = .{slice};
            const n = reader.interface.readVec(&data) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return error.Unexpected,
            };
            if (n == 0) break;
            const wdata: [1][]const u8 = .{slice[0..n]};
            _ = net016.netWrite(userdata, handle, &.{}, &wdata, 1) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.Unexpected,
            };
            written += n;
            remaining = remaining.subtract(n) orelse break;
        }
        return written;
    }

    fn batchSocketHandle(operation: Io.Operation) ?Io.net.Socket.Handle {
        return switch (operation) {
            .net_receive => |o| o.socket_handle,
            else => null,
        };
    }

    fn batchUnexpectedResult(operation: Io.Operation) Io.Operation.Result {
        return switch (operation) {
            .net_receive => .{ .net_receive = .{ error.Unexpected, 0 } },
            else => unreachable,
        };
    }
} else struct {};

/// Network slots specific to the 0.17.x interface: netRead/netWrite/netSend/
/// netReceive are operate tags, netClose takes []const Socket, and netWriteFile
/// returns declared Unimplemented for both provenances.
const net017 = if (is_017) struct {
    fn netClose(userdata: ?*anyopaque, sockets: []const Io.net.Socket) void {
        const self = shimFrom(userdata);
        // Release class (review 690 B1): never refuse. Post-gate a Born-owned
        // slot is skipped (the loop's netRetireAll closes it); Threaded-owned
        // sockets forward to Threaded. See net016.netClose.
        const entered = self.entryEnter();
        defer if (entered) self.entryExit();
        for (sockets) |s| {
            switch (self.sockClassify(s.handle)) {
                .live => |index| {
                    if (!entered) continue;
                    var op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
                    self.netCloseWait(&op);
                },
                .closing => {}, // another close already owns this slot's teardown
                .absent => {
                    const one: [1]Io.net.Socket = .{s};
                    fwd017.netClose(userdata, &one);
                },
            }
        }
    }

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = shimFrom(userdata);
        if (blockingLoopCheck(@src().fn_name)) return deadResult(Io.Cancelable!Io.Operation.Result);
        if (!self.entryEnter()) return deadResult(Io.Cancelable!Io.Operation.Result);
        defer self.entryExit();
        switch (operation) {
            .net_read => |o| {
                const index = switch (self.lookupBorn(o.socket_handle)) {
                    .absent => {
                        if (network_stats_enabled) _ = self.net_stats.threaded_read.fetchAdd(1, .monotonic);
                        return fwd.operate(userdata, operation);
                    },
                    .closing => return .{ .net_read = error.Unexpected },
                    .live => |i| i,
                };
                defer self.sockUserExit(index);
                // Control-buffer I/O is excluded by the stream-only profile.
                if (o.control.len != 0) return .{ .net_read = error.Unexpected };
                var op: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = o.data } } };
                try self.netWait(&op);
                if (op.result.err) |e| return .{ .net_read = mapIoError(e) };
                return .{ .net_read = .{ .data_len = op.result.count } };
            },
            .net_write => |o| {
                const index = switch (self.lookupBorn(o.socket_handle)) {
                    .absent => {
                        if (network_stats_enabled) _ = self.net_stats.threaded_write.fetchAdd(1, .monotonic);
                        return fwd.operate(userdata, operation);
                    },
                    .closing => return .{ .net_write = error.Unexpected },
                    .live => |i| i,
                };
                defer self.sockUserExit(index);
                if (o.control.len != 0) return .{ .net_write = error.Unexpected };
                var op: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = o.header, .data = o.data, .splat = o.splat } } };
                try self.netWait(&op);
                if (op.result.err) |e| return .{ .net_write = mapIoError(e) };
                return .{ .net_write = op.result.count };
            },
            .net_send => |o| {
                if (self.sockClassify(o.socket_handle) == .absent) return fwd.operate(userdata, operation);
                return .{ .net_send = .{ error.Unexpected, 0 } };
            },
            .net_receive => |o| {
                if (self.sockClassify(o.socket_handle) == .absent) return fwd.operate(userdata, operation);
                return .{ .net_receive = .{ error.Unexpected, 0 } };
            },
            else => return fwd.operate(userdata, operation),
        }
    }

    /// No Born sendfile primitive: declared Unimplemented for both provenances,
    /// returned before touching the socket. Io.Writer.sendFile catches it and
    /// re-enters the routed read/write, so the copy still runs on Born for a
    /// Born-owned handle (section 8).
    fn netWriteFile(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, limit: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
        _ = userdata;
        _ = handle;
        _ = header;
        _ = reader;
        _ = limit;
        return error.Unimplemented;
    }

    fn batchSocketHandle(operation: Io.Operation) ?Io.net.Socket.Handle {
        return switch (operation) {
            .net_read => |o| o.socket_handle,
            .net_write => |o| o.socket_handle,
            .net_send => |o| o.socket_handle,
            .net_receive => |o| o.socket_handle,
            else => null,
        };
    }

    fn batchUnexpectedResult(operation: Io.Operation) Io.Operation.Result {
        return switch (operation) {
            .net_read => .{ .net_read = error.Unexpected },
            .net_write => .{ .net_write = error.Unexpected },
            .net_send => .{ .net_send = .{ error.Unexpected, 0 } },
            .net_receive => .{ .net_receive = .{ error.Unexpected, 0 } },
            else => unreachable,
        };
    }
} else struct {};

/// The toolchain-selected network slot implementations.
const net01x = if (is_017) net017 else net016;

/// The capability-indexed vtable table (section 10). Bit 0 = network, bit 1 =
/// process; `io()` selects `vtable_table[index]` from the runtime capability
/// bits. Each entry is a comptime copy of `base_vtable` with only the active
/// routes' slots replaced, so an inactive slot is byte-identical to the
/// baseline by construction and the routes cannot drift. `sleep`, `now` and
/// `clockResolution` always stay on the Threaded baseline. The process
/// overrides apply only on `process_supported` targets; elsewhere the
/// process-bit entries equal their non-process counterparts (and `io()` never
/// selects them, the capability being a construction rejection).
const vtable_table: [4]Io.VTable = blk: {
    var table: [4]Io.VTable = undefined;
    for (&table, 0..) |*v, index| {
        v.* = base_vtable;
        if (index & 1 != 0) {
            v.netConnectIp = network_route.netConnectIp;
            v.netConnectUnix = network_route.netConnectUnix;
            v.netShutdown = network_route.netShutdown;
            v.netBindIp = network_route.netBindIp;
            v.netSocketCreatePair = network_route.netSocketCreatePair;
            v.netWriteFile = net01x.netWriteFile;
            v.netClose = net01x.netClose;
            v.operate = net01x.operate;
            v.batchAwaitAsync = network_route.batchAwaitAsync;
            v.batchAwaitConcurrent = network_route.batchAwaitConcurrent;
            if (!is_017) {
                v.netRead = net016.netRead;
                v.netWrite = net016.netWrite;
                v.netSend = net016.netSend;
            }
        }
        if (process_supported) {
            if (index & 2 != 0) {
                v.processSpawn = process_route.processSpawn;
                v.childWait = process_route.childWait;
                v.childKill = process_route.childKill;
                if (!is_017) v.processSpawnPath = process_route.processSpawnPath;
            }
        }
    }
    break :blk table;
};

/// Public capability-combination aliases into `vtable_table`, kept for the
/// existing tests and downstream callers. The all-Threaded baseline delegates
/// every slot; each Born alias replaces only its active routes' slots.
pub const baseline_vtable: Io.VTable = vtable_table[0];
pub const network_vtable: Io.VTable = vtable_table[1];
pub const process_vtable: Io.VTable = vtable_table[2];
pub const network_process_vtable: Io.VTable = vtable_table[3];

test "slot identity round-trips through udata" {
    const id = decodeSlotUdata(slotUdata(123, 456));
    try std.testing.expectEqual(@as(u32, 123), id.index);
    try std.testing.expectEqual(@as(u32, 456), id.generation);
    const max = decodeSlotUdata(slotUdata(std.math.maxInt(u32), std.math.maxInt(u32)));
    try std.testing.expectEqual(std.math.maxInt(u32), max.index);
    try std.testing.expectEqual(std.math.maxInt(u32), max.generation);
}

test "failure latch keeps the first route-level error" {
    var state: Shim = undefined;
    state.loop_error = .init(0);
    try std.testing.expectEqual(@as(?anyerror, null), state.latchedError());
    state.latch(error.WaitFailed);
    state.latch(error.OutOfMemory);
    try std.testing.expectEqual(@as(?anyerror, error.WaitFailed), state.latchedError());
}

/// Minimal composite for queue-mechanism unit tests: a real Threaded for
/// the uncancelable mutex, no loop thread, and no port call on these paths.
fn testShim(state: *Shim) void {
    state.* = .{
        .port = undefined,
        .allocator = std.testing.allocator,
        .capabilities = .{},
        .threaded = Io.Threaded.init(std.testing.allocator, .{}),
        .threaded_io = undefined,
    };
    state.threaded_io = state.threaded.io();
    state.port = born.EvPort.init(std.testing.allocator) catch @panic("test port create failed");
}

fn testShimDeinit(state: *Shim) void {
    state.threaded.deinit();
    state.port.deinit();
}

// ------------------------------------------- network mechanism units (P5.3) ----
//
// These drive the network engine's queue, registry and dispatch mechanics
// directly (private access), with a real Threaded for the uncancelable mutex
// and a real EvPort only where a port call is on the path. No loop thread runs:
// the test steps submit/cancel/retire/drain/fire in the exact race order.
// The per-slot behavioral contracts (connect, read/write,
// close, shutdown, exclusions, counters) live in net_test.zig on real sockets.

/// Publish `count` net-op chunks for network queue-mechanism unit tests,
/// mirroring construction-time net growth (no loop thread runs).
fn testNetGrow(state: *Shim, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try state.netGrowLocked();
}

/// Fake handle for registry/dispatch units that never touch a real socket:
/// an fd integer on POSIX, a raw HANDLE pointer on Windows.
fn testHandle(n: usize) born.Handle {
    return if (is_windows) @ptrFromInt(n) else @intCast(n);
}

test "net submit reports only the empty-to-non-empty transition" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 1);
    defer state.netFreeChunks();

    var a: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    var b: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    const ra = state.netSubmit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ra.was_empty);
    const rb = state.netSubmit(&b) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!rb.was_empty);
    try std.testing.expectEqual(&a, state.net_queue.head.?);
    try std.testing.expectEqual(&b, state.net_queue.tail.?);
    try std.testing.expectEqual(&b, a.next.?);
    try std.testing.expectEqual(@as(?*NetOp, null), b.next);
    try std.testing.expectEqual(@as(u32, 0), a.slot_index);
    try std.testing.expectEqual(@as(u32, 1), b.slot_index);
    try std.testing.expectEqual(&a, state.netSlotAt(0).op.?);
    try std.testing.expectEqual(&b, state.netSlotAt(1).op.?);
}

test "idle gate: a submission racing the emptiness check drains on the next cycle" {
    // The loop's emptiness read can race a submission: the check reads
    // empty, then the submitter enqueues and, finding the queue empty, wakes the
    // loop (was_empty). The next cycle must drain the op. This is the
    // deterministic simulation of that interleaving; the was_empty wake is the
    // production guarantee that a skipped drain is followed by another cycle.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 1);
    defer state.netFreeChunks();

    // Cycle 1: empty queue, the drain returns nothing (the gate skips the lock
    // entirely on the empty acquire read).
    try std.testing.expectEqual(@as(?*NetOp, null), state.netDrainLocked());
    try std.testing.expect(!state.net_queue.pending.load(.monotonic));

    // The submission races the check: it enqueues after the empty read.
    var a: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    const ra = state.netSubmit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ra.was_empty);
    try std.testing.expect(state.net_queue.pending.load(.monotonic));

    // Cycle 2: drains the racing submission, then reads empty again.
    try std.testing.expectEqual(&a, state.netDrainLocked().?);
    try std.testing.expect(!state.net_queue.pending.load(.monotonic));
    try std.testing.expectEqual(@as(?*NetOp, null), state.netDrainLocked());

    // The same race on the cancel list: a cancel pushed after an empty read sets
    // pending, and the next drain completes the deferred slot free.
    const index = try state.netAllocSlotLocked();
    var op: NetOp = .{ .kind = .read, .slot_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    state.netSlotAt(index).op = &op;
    try std.testing.expect(state.netRequestCancel(&op));
    try std.testing.expect(state.net_queue.pending.load(.monotonic));
    state.netRetireLocked(&op, index, true);
    _ = state.netDrainLocked();
    try std.testing.expectEqual(@as(?u32, null), state.net_cancel_head);
    try std.testing.expectEqual(@as(?u32, index), state.net_free_head);
    try std.testing.expect(!state.net_queue.pending.load(.monotonic));
}

test "idle gate: concurrent submissions are never lost across emptiness checks" {
    // The real race: a submitter enqueues while the drainer sweeps. A drain
    // whose acquire read saw empty skips the lock; the was_empty wake guarantees
    // another cycle in production. Here the drainer retires each drained op
    // (freeing its slot) and sweeps until every op is accounted for; thread join
    // makes the final stores visible, so the sweep terminates. Bounded spins
    // fail loudly instead of hanging.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 4);
    defer state.netFreeChunks();

    const n = 256;
    var ops: [n]NetOp = undefined;
    for (&ops) |*op| op.* = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };

    const S = struct {
        fn run(st: *Shim, items: []NetOp) void {
            for (items) |*op| {
                var tries: u32 = 0;
                while (st.netSubmit(op) == null) : (tries += 1) {
                    if (tries > 1_000_000) @panic("net submit starved");
                    std.atomic.spinLoopHint();
                }
            }
        }
    };
    const t = try std.Thread.spawn(.{}, S.run, .{ &state, &ops });
    var drained: usize = 0;
    var spins: u64 = 0;
    while (drained < n) : (spins += 1) {
        if (spins > 100_000_000) @panic("net drain starved");
        var node = state.netDrainLocked();
        var got: usize = 0;
        while (node) |op| {
            const next = op.next;
            state.net_queue.mutex.lockUncancelable(state.threaded_io);
            state.netRetireLocked(op, op.slot_index, true);
            state.net_queue.mutex.unlock(state.threaded_io);
            drained += 1;
            got += 1;
            node = next;
        }
        if (got == 0) std.atomic.spinLoopHint();
    }
    t.join();
    try std.testing.expectEqual(n, drained);
}

test "net cancel request skips a retired slot and refuses a double push" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 1);
    defer state.netFreeChunks();

    const index = try state.netAllocSlotLocked();
    var op: NetOp = .{ .kind = .read, .slot_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    state.netSlotAt(index).op = &op;
    // Occupied: the request pushes and reports the transition.
    try std.testing.expect(state.netRequestCancel(&op));
    try std.testing.expectEqual(@as(?u32, index), state.net_cancel_head);
    // Already linked: a second push must not corrupt the list.
    try std.testing.expect(!state.netRequestCancel(&op));
    try std.testing.expectEqual(@as(?u32, index), state.net_cancel_head);
    // Retired while the entry is pending: the slot is deferred, not freed.
    state.netRetireLocked(&op, index, true);
    try std.testing.expectEqual(@as(?*NetOp, null), state.netSlotAt(index).op);
    try std.testing.expectEqual(@as(?u32, index + 1), state.net_free_head);
    // The occupancy check refuses a push for the retired occupant.
    try std.testing.expect(!state.netRequestCancel(&op));
    // Drain frees the deferred slot and clears the list.
    _ = state.netDrainLocked();
    try std.testing.expectEqual(@as(?u32, index), state.net_free_head);
    try std.testing.expectEqual(@as(?u32, null), state.net_cancel_head);
    try std.testing.expect(!state.netSlotAt(index).on_cancel_list);
}

test "net retired slot pending a cancel entry is not reallocated until drained" {
    // The cancel-drain interleaving: a read completes and retires while its
    // cancel entry is still queued. A new submit must not take the deferred
    // slot (that would reset cancel_next and drop the entry); only the drain
    // frees it for reuse. Deterministic: no loop thread, no socket.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 1);
    defer state.netFreeChunks();

    var a: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    const ra = state.netSubmit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.netRequestCancel(&a));
    state.netRetireLocked(&a, ra.index, true);
    try std.testing.expect(state.netSlotAt(ra.index).on_cancel_list);
    try std.testing.expectEqual(@as(?*NetOp, null), state.netSlotAt(ra.index).op);

    // A fresh submit takes a different slot; the deferred one stays off the
    // free list so its cancel_next is preserved.
    var b: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    const rb = state.netSubmit(&b) orelse return error.TestUnexpectedResult;
    try std.testing.expect(rb.index != ra.index);
    try std.testing.expectEqual(@as(?u32, ra.index), state.net_cancel_head);

    // Drain frees the deferred slot; only now is it reusable.
    _ = state.netDrainLocked();
    try std.testing.expect(!state.netSlotAt(ra.index).on_cancel_list);
    try std.testing.expectEqual(@as(?u32, null), state.net_cancel_head);
    var c: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    const rc = state.netSubmit(&c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ra.index, rc.index);
}

test "net slot table grows in non-moving chunks up to the ceiling" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    defer state.netFreeChunks();
    try testNetGrow(&state, 1);
    const first = state.netSlotAt(0);
    // Exhaust the first chunk: the next allocation grows a second chunk.
    var last: u32 = 0;
    var i: usize = 0;
    while (i < net_slots_per_chunk + 1) : (i += 1) {
        last = try state.netAllocSlotLocked();
    }
    try std.testing.expectEqual(@as(usize, 2), state.net_chunk_count);
    try std.testing.expectEqual(@as(u32, @intCast(net_slots_per_chunk)), last);
    // Growth never moved the first chunk's storage.
    try std.testing.expect(first == state.netSlotAt(0));
    // Fill to the named ceiling; the next allocation is a resource refusal.
    while (state.net_chunk_count < max_net_chunks) try state.netGrowLocked();
    while (state.net_free_head != null) _ = try state.netAllocSlotLocked();
    try std.testing.expectError(error.OutOfMemory, state.netAllocSlotLocked());
}

test "registry maps handles to indices and unregisters conditionally" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.registryInit();
    defer state.registryDeinit();

    const h100 = testHandle(100);
    const h101 = testHandle(101);
    // A handle absent from the registry is Threaded-owned (lookup miss).
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(h100));
    const idx0 = try state.sockAllocLocked();
    const s0 = state.sockAt(idx0).?;
    s0.generation +%= 1;
    s0.occupied = true;
    s0.handle = h100;
    s0.index = idx0;
    try state.registerHandle(h100, idx0);
    try std.testing.expectEqual(SockLookup{ .live = idx0 }, state.sockClassify(h100));
    try std.testing.expectEqual(@as(u32, 1), s0.generation);

    // A second socket takes a different slot with a fresh generation.
    const idx1 = try state.sockAllocLocked();
    const s1 = state.sockAt(idx1).?;
    s1.generation +%= 1;
    s1.occupied = true;
    s1.handle = h101;
    s1.index = idx1;
    try state.registerHandle(h101, idx1);
    try std.testing.expect(idx1 != idx0);
    try std.testing.expectEqual(SockLookup{ .live = idx1 }, state.sockClassify(h101));
    try std.testing.expectEqual(@as(u32, 1), s1.generation);

    // Reusing handle 100 for a newer socket overwrites the mapping; unregistering
    // the OLD index must not remove the newer entry (stale-fd guard).
    const idx2 = try state.sockAllocLocked();
    try state.registerHandle(h100, idx2);
    try std.testing.expectEqual(SockLookup{ .live = idx2 }, state.sockClassify(h100));
    state.unregisterHandle(h100, idx0); // stale index: no-op
    try std.testing.expectEqual(SockLookup{ .live = idx2 }, state.sockClassify(h100));
    state.unregisterHandle(h100, idx2); // current index: removed
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(h100));

    // Free returns the slot to the free list and clears occupancy.
    state.sockFree(s1, idx1);
    try std.testing.expect(!s1.occupied);
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(h101));
    try std.testing.expectEqual(@as(?u32, idx1), state.registry.free_head);
}

test "stale socket events drop without touching the pending op" {
    // The use-after-free guard for a closed-and-reused fd: an event whose
    // generation predates the current occupant, whose slot is unoccupied,
    // whose chunk was never published, or whose index is past the chunk
    // ceiling must drop before any access to the caller's node or socket.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.registryInit();
    defer state.registryDeinit();

    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation = 7;
    s.occupied = true;
    s.index = index;
    s.handle = testHandle(100);
    var op: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    s.pending_read = &op;

    // Stale generation: the fd was closed and reused for a newer socket.
    state.socketEvent(.{ .udata = slotUdata(index, 6), .readable = true });
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    try std.testing.expectEqual(&op, s.pending_read.?);
    // Unoccupied slot: retirement already freed it.
    s.occupied = false;
    state.socketEvent(.{ .udata = slotUdata(index, 7), .readable = true });
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    s.occupied = true;
    // Unpublished chunk (index 99 lives in chunk 6, never grown).
    state.socketEvent(.{ .udata = slotUdata(99, 7), .readable = true });
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    // Index past the chunk ceiling (sockAt's bounds guard drops it).
    state.socketEvent(.{ .udata = slotUdata(max_sock_chunks * sock_per_chunk, 7), .readable = true });
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    // The live op is still pending and untouched throughout.
    try std.testing.expectEqual(&op, s.pending_read.?);
}

test "connect deadline fire retires Timeout and frees the socket (POSIX)" {
    // Windows timeout is an explicit completion drain (5.2), covered by the
    // Windows drain unit below; this unit covers the POSIX purge-before-deinit
    // retire on a real unconnected socket.
    if (is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    // A real unconnected non-blocking socket: sockRetire purges and closes it.
    const fd = try compat.socket(compat.AF.INET, compat.SOCK.STREAM | compat.SOCK.NONBLOCK | compat.SOCK.CLOEXEC, 0);
    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.index = index;
    s.handle = fd;
    s.plain.sock = fd;
    try state.registerHandle(fd, index);

    var op: NetOp = .{ .kind = .connect, .sock_index = index, .payload = .{ .connect = .{ .target = .{ .ip = .{ .in = .{ .port = 0, .addr = 0 } } } } } };
    op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(op.slot_index).op = &op;
    s.pending_connect = &op;
    // Arm a real far-future deadline timer so the retire path cancels it.
    try state.port.addTimer(net_timer_id_base + op.slot_index, netTimerUdata(index, s.generation), 60_000 * std.time.ns_per_ms, .once);
    s.deadline_armed = true;

    // The deadline fires: Timeout retire (not canceled), socket closed and
    // unregistered, slot freed, deadline disarmed.
    try std.testing.expect(state.connectDeadlineFired(netTimerUdata(index, s.generation)));
    try std.testing.expectEqual(@as(?NetError, .timeout), op.result.err);
    try std.testing.expectEqual(@as(u32, 1), op.state.load(.acquire));
    try std.testing.expect(!op.outcome_canceled);
    try std.testing.expect(!s.occupied);
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(fd));
    try std.testing.expectEqual(@as(compat.fd_t, -1), s.plain.sock);
    try std.testing.expectEqual(@as(?*NetOp, null), s.pending_connect);
    try std.testing.expect(!s.deadline_armed);

    // A stale deadline fire for the freed slot is dropped by the network path:
    // connectDeadlineFired checks the generation before touching the slot.
    try std.testing.expect(!state.connectDeadlineFired(netTimerUdata(index, s.generation)));
}

test "connect deadline fire drains the pending ConnectEx before freeing (Windows)" {
    // Windows timeout is an explicit completion drain (5.2): cancelAndClose
    // aborts the in-flight ConnectEx, but the stable SocketState must stay
    // occupied until that completion is absorbed. No loop thread runs here, so
    // the completion waits in the IOCP queue and the drain is driven manually
    // through socketEvent. Freeing the slot unconditionally (the should-fix 2
    // mutation) leaves the aborted completion unabsorbed and fails the
    // occupied assertion below.
    if (!is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    // A real loopback listener: ConnectEx posts (pending or inline) and its
    // completion stays queued because nothing dequeues it before the deadline.
    const fio = state.threaded_io;
    const listen: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen.listen(fio, .{});
    defer server.deinit(fio);
    const target_std: Io.net.IpAddress = .{ .ip4 = .loopback(server.socket.address.ip4.port) };
    const target = ipToBorn(&target_std);

    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.closing.store(false, .monotonic);
    s.index = index;
    s.pending_connect = null;
    s.pending_read = null;
    s.pending_write = null;
    s.read_armed = false;
    s.write_armed = false;
    s.deadline_armed = false;
    s.plain = .{};
    const udata = slotUdata(index, s.generation);
    try s.plain.startConnectAddrInto(target, &state.port, udata);
    s.handle = s.plain.handle();
    try state.registerHandle(s.handle, index);
    try std.testing.expectEqual(@as(usize, 1), s.plain.pendingOps());

    var op: NetOp = .{ .kind = .connect, .sock_index = index, .payload = .{ .connect = .{ .target = .{ .ip = target } } } };
    op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(op.slot_index).op = &op;
    s.pending_connect = &op;
    try state.port.addTimer(net_timer_id_base + op.slot_index, netTimerUdata(index, s.generation), 60_000 * std.time.ns_per_ms, .once);
    s.deadline_armed = true;

    // The deadline fires while ConnectEx is pending: Timeout retire (not
    // canceled), cancel/close, deadline disarmed, but the slot stays occupied
    // until the completion drains.
    try std.testing.expect(state.connectDeadlineFired(netTimerUdata(index, s.generation)));
    try std.testing.expectEqual(@as(?NetError, .timeout), op.result.err);
    try std.testing.expectEqual(@as(u32, 1), op.state.load(.acquire));
    try std.testing.expect(!op.outcome_canceled);
    try std.testing.expect(s.closing.load(.acquire));
    try std.testing.expectEqual(@as(?*NetOp, null), s.pending_connect);
    try std.testing.expect(!s.deadline_armed);
    try std.testing.expect(s.occupied);
    try std.testing.expectEqual(@as(usize, 1), s.plain.pendingOps());
    // Required 1: the handle mapping is dropped BEFORE the drain completes, so
    // a reused SOCKET value opened by another thread never resolves to this
    // dying slot even while it is still occupied/closing.
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(s.handle));

    // Drain the aborted completion through the real event path; the slot is
    // freed only once pendingOps() reaches zero.
    var events: [8]born.Event = undefined;
    var guard: u32 = 0;
    while (s.occupied and guard < 100) : (guard += 1) {
        const n = try state.port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.timer or ev.wake) continue;
            state.socketEvent(ev);
        }
    }
    try std.testing.expect(!s.occupied);
    try std.testing.expectEqual(@as(usize, 0), s.plain.pendingOps());
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(s.handle));
}

test "registryCloseAll drains two sockets' completions to their owners (Windows)" {
    // Required 2: the exit drain must route each completion to its OWN socket.
    // Socket B has a completed recv queued (the peer sent a byte) while socket
    // A's recv is still pending. The old per-socket polled drain fed every
    // completion to one socket's absorbCompletion, dropping B's, so B freed with
    // pendingOps != 0 after a 100 s guard. The two-phase drain (cancel all, then
    // dispatch through socketEvent with no timeout) frees both promptly.
    if (!is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const fio = state.threaded_io;
    const listen: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen.listen(fio, .{});
    defer server.deinit(fio);
    const target_std: Io.net.IpAddress = .{ .ip4 = .loopback(server.socket.address.ip4.port) };
    const target = ipToBorn(&target_std);

    var idx: [2]u32 = undefined;
    var peers: [2]Io.net.Stream = undefined;
    for (&idx, 0..) |*index, i| {
        index.* = try state.sockAllocLocked();
        const s = state.sockAt(index.*).?;
        s.generation +%= 1;
        s.occupied = true;
        s.closing.store(false, .monotonic);
        s.index = index.*;
        s.pending_connect = null;
        s.pending_read = null;
        s.pending_write = null;
        s.read_armed = false;
        s.write_armed = false;
        s.deadline_armed = false;
        try s.plain.startConnectAddrInto(target, &state.port, slotUdata(index.*, s.generation));
        s.handle = s.plain.handle();
        try state.registerHandle(s.handle, index.*);
        peers[i] = try server.accept(fio);
        // Absorb the connect completion (no loop thread runs), confirm, then
        // post a WSARecv that stays pending until data or cancellation.
        var events: [8]born.Event = undefined;
        var guard: u32 = 0;
        while (!s.plain.connect_done and guard < 100) : (guard += 1) {
            const n = try state.port.wait(&events, 100);
            for (events[0..n]) |ev| {
                if (ev.timer or ev.wake) continue;
                state.socketEvent(ev);
            }
        }
        try s.plain.connectDone();
        var buf: [1]u8 = undefined;
        _ = try s.plain.readNb(&buf); // posts WSARecv into the internal buffer
        try std.testing.expectEqual(@as(usize, 1), s.plain.pendingOps());
    }
    defer peers[0].close(fio);
    defer peers[1].close(fio);

    // Send a byte to socket B's peer: its recv completes into the IOCP queue,
    // undrained. Socket A's recv stays pending. Use the Threaded peer's writer
    // (a Threaded handle is not a born.Handle, so compatSock would mis-cast it).
    var pbuf: [8]u8 = undefined;
    var pwriter = peers[1].writer(fio, &pbuf);
    try pwriter.interface.writeAll("x");
    try pwriter.interface.flush();
    try Io.sleep(fio, .fromMilliseconds(50), .awake);

    const t0 = try born.nowNs();
    state.registryCloseAll();
    const elapsed = (try born.nowNs()) - t0;
    // Prompt drain: the old code waited out a 100 s guard on socket B.
    try std.testing.expect(elapsed < 2 * std.time.ns_per_s);
    for (idx) |index| {
        const s = state.sockAt(index).?;
        try std.testing.expect(!s.occupied);
        try std.testing.expectEqual(@as(usize, 0), s.plain.pendingOps());
        try std.testing.expectEqual(SockLookup.absent, state.sockClassify(s.handle));
    }
}

test "net submit refusal and loop-exit retirement distinguish route_dead from canceled" {
    // Required 3: a dead route is not the caller's cancellation. A submit
    // refusal completes the op with route_dead, and a failure exit retires
    // queued ops as route_dead (both map to Unexpected); a stop request or an
    // op whose submitter requested cancellation stays canceled.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    // Submit refusal (dead queue): netWait returns normally with route_dead.
    state.net_queue.dead = true;
    var refused: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    try state.netWait(&refused);
    try std.testing.expectEqual(@as(?NetError, .route_dead), refused.result.err);
    try std.testing.expect(!refused.outcome_canceled);
    try std.testing.expectEqual(error.Unexpected, mapIoError(.route_dead));
    try std.testing.expectEqual(error.Unexpected, mapConnectIpError(.route_dead));
    try std.testing.expectEqual(error.Unexpected, mapConnectUnixError(.route_dead));

    // Failure exit (stopped=false): a queued op retires as route_dead.
    state.net_queue.dead = false;
    var q1: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    _ = state.netSubmit(&q1).?;
    state.netRetireAll(false);
    try std.testing.expectEqual(@as(?NetError, .route_dead), q1.result.err);
    try std.testing.expect(!q1.outcome_canceled);
    try std.testing.expectEqual(@as(u32, 1), q1.state.load(.acquire));

    // Stop request (stopped=true): a queued op retires as canceled.
    state.net_queue.dead = false;
    var q2: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    _ = state.netSubmit(&q2).?;
    state.netRetireAll(true);
    try std.testing.expect(q2.outcome_canceled);
    try std.testing.expectEqual(@as(?NetError, null), q2.result.err);

    // A submitter-requested cancellation stays canceled even on a failure exit.
    state.net_queue.dead = false;
    var q3: NetOp = .{ .kind = .read, .payload = .{ .read = .{ .data = &.{} } } };
    _ = state.netSubmit(&q3).?;
    q3.cancel_requested.store(true, .release);
    state.netRetireAll(false);
    try std.testing.expect(q3.outcome_canceled);
    try std.testing.expectEqual(@as(?NetError, null), q3.result.err);
}

test "close retires parked ops as route_dead, not the caller's Canceled (#106)" {
    // A user close kills the socket's route: parked read/write/connect retire
    // route_dead (Unexpected at the thunk), never as the caller's Canceled
    // (section 4.5). An op whose submitter already requested cancellation
    // stays canceled. POSIX unit: a real unconnected socket stands in for the
    // connection; the full close path on every kernel is covered by the
    // net_test close contract, and the Windows drain by registryCloseAll.
    if (is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const fd = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.index = index;
    s.handle = fd;
    s.plain.sock = fd; // sockRetire's deinit closes it
    try state.registerHandle(fd, index);

    var rop: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    rop.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(rop.slot_index).op = &rop;
    s.pending_read = &rop;
    var wop: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = &.{}, .data = &.{}, .splat = 0 } } };
    wop.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(wop.slot_index).op = &wop;
    s.pending_write = &wop;
    var cop: NetOp = .{ .kind = .connect, .sock_index = index, .payload = .{ .connect = .{ .target = .{ .ip = ipToBorn(&.{ .ip4 = .loopback(9) }) } } } };
    cop.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(cop.slot_index).op = &cop;
    s.pending_connect = &cop;

    var close_op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
    close_op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(close_op.slot_index).op = &close_op;
    state.closeDrive(&close_op);

    for ([_]*NetOp{ &rop, &wop, &cop }) |parked| {
        try std.testing.expectEqual(@as(?NetError, .route_dead), parked.result.err);
        try std.testing.expect(!parked.outcome_canceled);
        try std.testing.expectEqual(@as(u32, 1), parked.state.load(.acquire));
    }
    try std.testing.expectEqual(@as(?NetError, null), close_op.result.err);
    try std.testing.expectEqual(@as(u32, 1), close_op.state.load(.acquire));
    try std.testing.expect(!s.occupied);
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(fd));

    // A parked read whose submitter requested cancellation stays canceled.
    const fd2 = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
    const index2 = try state.sockAllocLocked();
    const s2 = state.sockAt(index2).?;
    s2.generation +%= 1;
    s2.occupied = true;
    s2.index = index2;
    s2.handle = fd2;
    s2.plain.sock = fd2;
    try state.registerHandle(fd2, index2);
    var rop2: NetOp = .{ .kind = .read, .sock_index = index2, .payload = .{ .read = .{ .data = &.{} } } };
    rop2.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(rop2.slot_index).op = &rop2;
    rop2.cancel_requested.store(true, .release);
    s2.pending_read = &rop2;
    var close2: NetOp = .{ .kind = .close, .sock_index = index2, .payload = .{ .close = {} } };
    close2.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(close2.slot_index).op = &close2;
    state.closeDrive(&close2);
    try std.testing.expect(rop2.outcome_canceled);
    try std.testing.expectEqual(@as(?NetError, null), rop2.result.err);
    try std.testing.expectEqual(@as(u32, 1), rop2.state.load(.acquire));
}

test "registryDeinit frees the chunk table on a clean drain" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.registryInit();
    try std.testing.expect(state.registry.chunks[0].load(.monotonic) != null);
    state.registryDeinit();
    try std.testing.expectEqual(@as(?*SockChunk, null), state.registry.chunks[0].load(.monotonic));
    try std.testing.expect(!state.registry.initialized);
}

test "failed exit drain latches and leaks the chunk table (#106)" {
    // A failed phase-2 wait cannot prove the completions are done: latch the
    // cause and keep the chunk table (the port may still reference its
    // OVERLAPPED storage). The decision is platform-independent; the wait
    // itself only runs on Windows. Mutation: freeing the table despite the
    // flag must fail (a freed chunk's published pointer is nulled).
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.registryInit();
    const chunk = state.registry.chunks[0].load(.monotonic).?;
    const free_head = chunk.socks[0].next_free;
    state.registryDrainFailed(error.WaitFailed);
    try std.testing.expectEqual(@as(?anyerror, error.WaitFailed), state.latchedError());
    try std.testing.expect(state.registry.exit_drain_failed);
    state.registryDeinit();
    const kept = state.registry.chunks[0].load(.monotonic).?;
    try std.testing.expectEqual(chunk, kept);
    try std.testing.expectEqual(free_head, kept.socks[0].next_free);
    // The leak is deliberate; release it for the testing allocator.
    state.allocator.destroy(kept);
}

test "concurrent read or write on a parked op is rejected busy, not orphaned" {
    // Minor 8: a second concurrent read/write must not overwrite the parked
    // pending pointer (which would orphan the first op and hang its submitter).
    // It retires busy (mapped to Unexpected); the parked op stays pending.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.index = index;
    s.handle = testHandle(100);

    var parked: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    parked.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(parked.slot_index).op = &parked;
    s.pending_read = &parked;

    var second: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    second.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(second.slot_index).op = &second;
    state.readDrive(&second);
    try std.testing.expectEqual(@as(?NetError, .busy), second.result.err);
    try std.testing.expectEqual(@as(u32, 1), second.state.load(.acquire));
    try std.testing.expectEqual(error.Unexpected, mapIoError(.busy));
    // The parked read is untouched: still pending, not retired.
    try std.testing.expectEqual(&parked, s.pending_read.?);
    try std.testing.expectEqual(@as(u32, 0), parked.state.load(.monotonic));

    // Same guard for a concurrent write.
    s.pending_read = null;
    var wparked: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = &.{}, .data = &.{}, .splat = 0 } } };
    wparked.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(wparked.slot_index).op = &wparked;
    s.pending_write = &wparked;
    var wsecond: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = &.{}, .data = &.{}, .splat = 0 } } };
    wsecond.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(wsecond.slot_index).op = &wsecond;
    state.writeDrive(&wsecond);
    try std.testing.expectEqual(@as(?NetError, .busy), wsecond.result.err);
    try std.testing.expectEqual(&wparked, s.pending_write.?);
    try std.testing.expectEqual(@as(u32, 0), wparked.state.load(.monotonic));
}

test "batch partition detaches Born members with tag Unexpected, keeps Threaded" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.registryInit();
    defer state.registryDeinit();

    // Register a Born-owned handle; the peer handle stays Threaded-owned.
    // batchPartitionBorn only does a registry lookup and builds the tag result,
    // so the handles need not be live sockets.
    const born_h = testHandle(200);
    const peer_h = testHandle(201);
    const bi = try state.sockAllocLocked();
    const bs = state.sockAt(bi).?;
    bs.occupied = true;
    bs.handle = born_h;
    bs.index = bi;
    try state.registerHandle(born_h, bi);
    try std.testing.expect(state.sockClassify(born_h) == .live);
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(peer_h));

    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    var bbuf: [4]u8 = undefined;
    var pbuf: [4]u8 = undefined;
    var biov = [_][]u8{bbuf[0..]};
    var piov = [_][]u8{pbuf[0..]};
    const born_idx = batch.add(if (is_017)
        .{ .net_read = .{ .socket_handle = born_h, .data = &biov } }
    else
        .{ .net_receive = .{ .socket_handle = born_h, .message_buffer = &.{}, .data_buffer = &.{}, .flags = .{} } });
    const peer_idx = batch.add(if (is_017)
        .{ .net_read = .{ .socket_handle = peer_h, .data = &piov } }
    else
        .{ .net_receive = .{ .socket_handle = peer_h, .message_buffer = &.{}, .data_buffer = &.{}, .flags = .{} } });

    try std.testing.expect(state.batchPartitionBorn(&batch));
    // The Born member moved to completed with its tag Unexpected; the peer
    // member alone remains submitted for the forwarded Threaded await.
    try std.testing.expectEqual(peer_idx, batch.submitted.head.toIndex());
    try std.testing.expect(batch.storage[peer_idx].submission.node.next == .none);
    try std.testing.expectEqual(born_idx, batch.completed.head.toIndex());
    try std.testing.expect(batch.storage[born_idx].completion.node.next == .none);
    if (is_017) {
        try std.testing.expectError(error.Unexpected, batch.storage[born_idx].completion.result.net_read);
    } else {
        try std.testing.expectEqual(@as(?Io.net.Socket.ReceiveError, error.Unexpected), batch.storage[born_idx].completion.result.net_receive[0]);
    }
    // A second pass finds no Born member and leaves the batch unchanged.
    try std.testing.expect(!state.batchPartitionBorn(&batch));
    try std.testing.expectEqual(peer_idx, batch.submitted.head.toIndex());
}

test "coarse error maps cover every section 8 row" {
    const IoMapErr = error{ ConnectionResetByPeer, Unexpected };
    const IpErr = Io.net.IpAddress.ConnectError;
    const UnixErr = Io.net.UnixAddress.ConnectError;
    const ShErr = Io.net.ShutdownError;

    // Read/write map: a failed read/write becomes ConnectionResetByPeer;
    // anything else (including the synthetic cancel/route-dead tags) Unexpected.
    try std.testing.expectEqual(@as(IoMapErr, error.ConnectionResetByPeer), mapIoError(.read_failed));
    try std.testing.expectEqual(@as(IoMapErr, error.ConnectionResetByPeer), mapIoError(.write_failed));
    try std.testing.expectEqual(@as(IoMapErr, error.Unexpected), mapIoError(.canceled));
    try std.testing.expectEqual(@as(IoMapErr, error.Unexpected), mapIoError(.route_dead));
    try std.testing.expectEqual(@as(IoMapErr, error.Unexpected), mapIoError(.timeout));

    // IP connect map.
    try std.testing.expectEqual(@as(IpErr, error.ConnectionRefused), mapConnectIpError(.connect_refused));
    try std.testing.expectEqual(@as(IpErr, error.SystemResources), mapConnectIpError(.connect_setup));
    try std.testing.expectEqual(@as(IpErr, error.Unexpected), mapConnectIpError(.connect_state));
    try std.testing.expectEqual(@as(IpErr, error.Timeout), mapConnectIpError(.timeout));
    try std.testing.expectEqual(@as(IpErr, error.Unexpected), mapConnectIpError(.route_dead));

    // Unix connect map: 0.16's ConnectError lacks ConnectionRefused, so a
    // refusal degrades to Unexpected there (mirrors Threaded 0.16); 0.17 has it.
    if (is_017) {
        try std.testing.expectEqual(@as(UnixErr, error.ConnectionRefused), mapConnectUnixError(.unix_refused));
    } else {
        try std.testing.expectEqual(@as(UnixErr, error.Unexpected), mapConnectUnixError(.unix_refused));
    }
    try std.testing.expectEqual(@as(UnixErr, error.SystemResources), mapConnectUnixError(.unix_setup));
    try std.testing.expectEqual(@as(UnixErr, error.FileNotFound), mapConnectUnixError(.unix_name_too_long));
    try std.testing.expectEqual(@as(UnixErr, error.WouldBlock), mapConnectUnixError(.unix_backlog_full));
    try std.testing.expectEqual(@as(UnixErr, error.AddressFamilyUnsupported), mapConnectUnixError(.unix_unsupported));
    try std.testing.expectEqual(@as(UnixErr, error.Unexpected), mapConnectUnixError(.connect_refused));

    // Shutdown map: compat's richer set folded into std ShutdownError.
    try std.testing.expectEqual(@as(ShErr, error.ConnectionAborted), mapShutdownError(error.ConnectionAborted));
    try std.testing.expectEqual(@as(ShErr, error.ConnectionResetByPeer), mapShutdownError(error.ConnectionResetByPeer));
    try std.testing.expectEqual(@as(ShErr, error.SocketUnconnected), mapShutdownError(error.SocketNotConnected));
    try std.testing.expectEqual(@as(ShErr, error.NetworkDown), mapShutdownError(error.NetworkSubsystemFailed));
    try std.testing.expectEqual(@as(ShErr, error.SystemResources), mapShutdownError(error.SystemResources));
    try std.testing.expectEqual(@as(ShErr, error.Unexpected), mapShutdownError(error.BlockingOperationInProgress));
    try std.testing.expectEqual(@as(ShErr, error.Unexpected), mapShutdownError(error.Unexpected));
}

// ------------------------------------------------ process mechanism units ----
//
// P5.4 design section 11. The process route exists only on FreeBSD and Linux
// (`process_supported`); every unit below skips elsewhere (the construction
// rejection and unchanged baseline are those targets' evidence). Pure
// registry/queue/tag units use the `testShim` composite (port=undefined, no
// loop thread); the drive paths that touch the port or a real child use a real
// `EvPort` and a real `born.process` child, driven manually exactly as the loop
// would. Each mechanism's mutation check is noted inline.

/// Publish `count` proc-op chunks for queue-mechanism units (no loop thread).
fn testProcGrow(state: *Shim, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try state.procGrowLocked();
}

/// Spawn a real `/bin/sh -c cmd` child for the port-touching units. A minimal
/// PATH lets shell utilities resolve; stdio is /dev/null so no pipe is created.
/// The caller owns the returned child (the drive paths or an explicit close
/// reap it).
fn testSpawnSh(comptime cmd: [:0]const u8) born.process.SpawnError!born.process.Child {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
    const envp = [_:null]?[*:0]const u8{"PATH=/bin:/usr/bin:/usr/local/bin"};
    return born.process.spawn(&argv, &envp, .{ .stdin = .devnull, .stdout = .devnull, .stderr = .devnull });
}

/// Poll until `pid` is gone (killed and reaped). born's FreeBSD procdesc close
/// SIGKILLs a running child and leaves the reap to init (async zombie); a
/// child that was never killed would still run `sleep 30` and keep answering
/// kill(pid, 0). Referenced only from FreeBSD-only test bodies.
fn expectPidGone(pid: std.posix.pid_t) !void {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| {
            if (err == error.ProcessNotFound) return;
        };
        compat.sleepNs(10 * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

/// Refuses only the registry chunk allocation (size == ChildChunk), forwarding
/// every other request to the backing allocator. Targets registry-growth OOM
/// deterministically, independent of how many backing allocations the spawn
/// arena makes (which differs across toolchains). `chunk_refused` records that
/// the growth allocation was actually attempted and refused.
const ChunkFailAllocator = struct {
    backing: std.mem.Allocator,
    chunk_refused: bool = false,

    fn allocator(self: *ChunkFailAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ChunkFailAllocator = @ptrCast(@alignCast(ctx));
        if (n == @sizeOf(ChildChunk)) {
            self.chunk_refused = true;
            return null;
        }
        return self.backing.rawAlloc(n, alignment, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *ChunkFailAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(mem, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *ChunkFailAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(mem, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ChunkFailAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(mem, alignment, ra);
    }
};

test "proc submit reports only the empty-to-non-empty transition" {
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    defer state.procFreeChunks();

    var a: ProcOp = .{ .kind = .arm };
    var b: ProcOp = .{ .kind = .wait };
    var c: ProcOp = .{ .kind = .kill };
    const ra = state.procSubmit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ra.was_empty);
    const rb = state.procSubmit(&b) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!rb.was_empty);
    const rc = state.procSubmit(&c) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!rc.was_empty);
    try std.testing.expectEqual(&a, state.proc_queue.head.?);
    try std.testing.expectEqual(&c, state.proc_queue.tail.?);
    try std.testing.expectEqual(&b, a.next.?);
    try std.testing.expectEqual(&c, b.next.?);
    try std.testing.expectEqual(@as(?*ProcOp, null), c.next);
    try std.testing.expectEqual(&a, state.procSlotAt(ra.index).?.op.?);
    try std.testing.expectEqual(&c, state.procSlotAt(rc.index).?.op.?);
}

test "idle gate: a proc submission racing the emptiness check drains on the next cycle" {
    // Proc mirror of the net race test: the emptiness read can race a
    // submission; the was_empty wake guarantees the next cycle drains it.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    defer state.procFreeChunks();

    try std.testing.expectEqual(@as(?*ProcOp, null), state.procDrainLocked());
    try std.testing.expect(!state.proc_queue.pending.load(.monotonic));

    var a: ProcOp = .{ .kind = .arm };
    const ra = state.procSubmit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ra.was_empty);
    try std.testing.expect(state.proc_queue.pending.load(.monotonic));

    try std.testing.expectEqual(&a, state.procDrainLocked().?);
    try std.testing.expect(!state.proc_queue.pending.load(.monotonic));
    try std.testing.expectEqual(@as(?*ProcOp, null), state.procDrainLocked());
}

test "proc cancel request skips a retired slot and refuses a double push" {
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testProcGrow(&state, 1);
    defer state.procFreeChunks();

    const index = try state.procAllocSlotLocked();
    var op: ProcOp = .{ .kind = .wait, .slot_index = index };
    state.procSlotAt(index).?.op = &op;
    // Occupied: the request pushes and reports the transition.
    try std.testing.expect(state.procRequestCancel(&op));
    try std.testing.expectEqual(@as(?u32, index), state.proc_cancel_head);
    // Already linked: a second push must not corrupt the list.
    try std.testing.expect(!state.procRequestCancel(&op));
    try std.testing.expectEqual(@as(?u32, index), state.proc_cancel_head);
    // Retired while the entry is pending: the slot is deferred, not freed.
    state.procRetireOp(&op, true);
    try std.testing.expectEqual(@as(?*ProcOp, null), state.procSlotAt(index).?.op);
    try std.testing.expectEqual(@as(?u32, index + 1), state.proc_free_head);
    // The occupancy check refuses a push for the retired occupant.
    try std.testing.expect(!state.procRequestCancel(&op));
    // Drain frees the deferred slot and clears the list.
    _ = state.procDrainLocked();
    try std.testing.expectEqual(@as(?u32, index), state.proc_free_head);
    try std.testing.expectEqual(@as(?u32, null), state.proc_cancel_head);
    try std.testing.expect(!state.procSlotAt(index).?.on_cancel_list);
}

test "proc retirement snapshots the slot index before the terminal store" {
    // born#111: the terminal store releases the submitter, which may return
    // and reuse its frame; a read of op.slot_index past the store then sees
    // garbage. The test_proc_frame_reuse hook overwrites the node's slot
    // index right after the store, deterministically simulating the reuse.
    // Out-of-range poison: a post-store read panics on the null slot (the
    // CI run 349 crash shape).
    // Mutation: reading op.slot_index after the store must fail.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testProcGrow(&state, 1);
    defer state.procFreeChunks();

    const index = try state.procAllocSlotLocked();
    var op: ProcOp = .{ .kind = .wait, .slot_index = index };
    state.procSlotAt(index).?.op = &op;

    state.test_proc_frame_reuse = std.math.maxInt(u32);
    state.procRetireOp(&op, false);
    try std.testing.expectEqual(@as(?u32, null), state.test_proc_frame_reuse); // hook fired and reset
    try std.testing.expectEqual(@as(u32, 1), op.state.load(.acquire));
    // The op's own slot was released despite the frame overwrite.
    try std.testing.expectEqual(@as(?*ProcOp, null), state.procSlotAt(index).?.op);
    try std.testing.expectEqual(@as(?u32, index), state.proc_free_head);
}

test "proc retirement under frame reuse leaves other slots occupied" {
    // The silent born#111 variant: a reused frame holding another live
    // slot's index must not free that slot. Poison the retiring node with
    // the victim's index; the victim keeps its occupant and only the
    // retiring slot goes on the free list.
    // Mutation: reading op.slot_index after the store must fail.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testProcGrow(&state, 1);
    defer state.procFreeChunks();

    const ia = try state.procAllocSlotLocked();
    const ib = try state.procAllocSlotLocked();
    var a: ProcOp = .{ .kind = .wait, .slot_index = ia };
    var b: ProcOp = .{ .kind = .wait, .slot_index = ib };
    state.procSlotAt(ia).?.op = &a;
    state.procSlotAt(ib).?.op = &b;

    state.test_proc_frame_reuse = ib;
    state.procRetireOp(&a, false);
    try std.testing.expectEqual(@as(?u32, null), state.test_proc_frame_reuse); // hook fired and reset
    try std.testing.expectEqual(@as(u32, 1), a.state.load(.acquire));
    try std.testing.expectEqual(@as(?*ProcOp, &b), state.procSlotAt(ib).?.op);
    try std.testing.expectEqual(@as(?*ProcOp, null), state.procSlotAt(ia).?.op);
    try std.testing.expectEqual(@as(?u32, ia), state.proc_free_head);
}

test "proc retired slot pending a cancel entry is not reallocated until drained" {
    // The cancel-drain interleaving: a wait retires while its cancel entry is
    // still queued. A new submit must not take the deferred slot (that would
    // reset cancel_next and drop the entry); only the drain frees it for reuse.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try testProcGrow(&state, 1);
    defer state.procFreeChunks();

    var a: ProcOp = .{ .kind = .wait };
    const ra = state.procSubmit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.procRequestCancel(&a));
    state.procRetireOp(&a, true);
    try std.testing.expect(state.procSlotAt(ra.index).?.on_cancel_list);
    try std.testing.expectEqual(@as(?*ProcOp, null), state.procSlotAt(ra.index).?.op);

    // A fresh submit takes a different slot; the deferred one stays off the
    // free list so its cancel_next is preserved.
    var b: ProcOp = .{ .kind = .wait };
    const rb = state.procSubmit(&b) orelse return error.TestUnexpectedResult;
    try std.testing.expect(rb.index != ra.index);
    try std.testing.expectEqual(@as(?u32, ra.index), state.proc_cancel_head);

    // Drain frees the deferred slot; only now is it reusable.
    _ = state.procDrainLocked();
    try std.testing.expect(!state.procSlotAt(ra.index).?.on_cancel_list);
    try std.testing.expectEqual(@as(?u32, null), state.proc_cancel_head);
    var c: ProcOp = .{ .kind = .wait };
    const rc = state.procSubmit(&c) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ra.index, rc.index);
}

test "proc slot table grows in non-moving chunks up to the ceiling" {
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    defer state.procFreeChunks();
    try testProcGrow(&state, 1);
    const first = state.procSlotAt(0);
    // Exhaust the first chunk: the next allocation grows a second chunk.
    var last: u32 = 0;
    var i: usize = 0;
    while (i < proc_slots_per_chunk + 1) : (i += 1) {
        last = try state.procAllocSlotLocked();
    }
    try std.testing.expectEqual(@as(usize, 2), state.proc_chunk_count);
    try std.testing.expectEqual(@as(u32, @intCast(proc_slots_per_chunk)), last);
    // Growth never moved the first chunk's storage.
    try std.testing.expect(first == state.procSlotAt(0));
    // Fill to the named ceiling; the next allocation is a resource refusal.
    while (state.proc_chunk_count < max_proc_chunks) try state.procGrowLocked();
    while (state.proc_free_head != null) _ = try state.procAllocSlotLocked();
    try std.testing.expectError(error.OutOfMemory, state.procAllocSlotLocked());
}

test "proc udata round-trips and the route tag bits never collide" {
    if (comptime !process_supported) return error.SkipZigTest;
    const id = decodeProcUdata(procUdata(12345, 678));
    try std.testing.expectEqual(@as(u32, 12345), id.index);
    try std.testing.expectEqual(@as(u32, 678), id.generation);
    // The process tag is bit 16; the connect-deadline tag is bit 63. They never
    // overlap, and a plain socket/timer udata carries no process tag.
    try std.testing.expectEqual(@as(u64, 0), proc_udata_bit & net_timer_bit);
    const tagged: u64 = @intCast(@intFromPtr(procUdata(0, 0).?));
    try std.testing.expect(tagged & proc_udata_bit != 0);
    const plain: u64 = @intCast(@intFromPtr(slotUdata(12345, 678).?));
    try std.testing.expectEqual(@as(u64, 0), plain & proc_udata_bit);
}

test "child reservation bumps generation; a stale exit cannot complete a new occupant" {
    // R4 recycled-pid guard: reservation bumps the generation, and an exit
    // whose generation predates the current occupant drops before any access.
    // Mutation: removing the generation check in childSnapshot must fail this.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.childRegistryInit();
    defer state.childRegistryDeinit();

    const r1 = try state.childReserve();
    try std.testing.expectEqual(@as(u32, 1), r1.generation);
    try std.testing.expect(state.childSnapshot(r1.index, r1.generation) != null);
    try std.testing.expect(state.childSnapshot(r1.index, r1.generation -% 1) == null);
    // Release and re-reserve: the slot is reused with a fresh generation.
    state.childRelease(r1.index);
    const r2 = try state.childReserve();
    try std.testing.expectEqual(r1.index, r2.index);
    try std.testing.expectEqual(r1.generation + 1, r2.generation);
    // A stale exit for the previous occupant drops before touching the new one
    // (childEvent's snapshot check returns before any port call).
    state.childEvent(.{ .exited = true, .exit = .{ .code = 9 }, .udata = procUdata(r2.index, r1.generation) });
    const child = state.childAt(r2.index).?;
    try std.testing.expectEqual(@as(?born.ProcessExit, null), child.exit);
    try std.testing.expect(child.occupied);
}

test "child provenance lookup hits a published child and misses once unpublished" {
    // The submit-time provenance gate (Born hit vs Threaded miss) and the
    // remove-before-reap ordering: the pid mapping is dropped BEFORE the
    // reaping close, so a recycled pid never resolves to the dying slot.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.childRegistryInit();
    defer state.childRegistryDeinit();

    // Unregistered pid: Threaded-owned (lookup miss).
    try std.testing.expect(state.lookupChild(424242) == null);
    const r = try state.childReserve();
    try state.childPublish(r.index, .{ .handle = -1, .pid = 424242 });
    const found = state.lookupChild(424242).?;
    try std.testing.expectEqual(r.index, found.index);
    try std.testing.expectEqual(r.generation, found.generation);
    // Drop the mapping (the first half of childCleanup), before any close.
    state.proc_queue.mutex.lockUncancelable(state.threaded_io);
    _ = state.child_registry.map.fetchRemove(424242);
    state.proc_queue.mutex.unlock(state.threaded_io);
    try std.testing.expect(state.lookupChild(424242) == null);
    // The slot stays occupied until childFreeLocked (the close has not run).
    try std.testing.expect(state.childAt(r.index).?.occupied);
    state.childRelease(r.index);
}

test "childCleanup closes a local copy, not a reused slot (#114)" {
    // #114: childCleanup releases the slot under the proc queue mutex, then
    // closes the descriptor. A worker can reserve and publish the same slot
    // in the window between the unlock and the close; closing through the
    // slot then closes the new occupant's descriptor and writes -1 into it,
    // leaking the old one. The test-only seam reserves and publishes a second
    // real child into the freed slot in that exact window. Mutation: closing
    // through the slot (child.child.close(), as on master) must fail the
    // closed-first-descriptor and intact-second-handle assertions.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    // The first child has already exited, so Child.close reaps it synchronously
    // on both OSes. A still-running Linux child would hand its pidfd to the
    // born-reaper thread (SIGKILL + WNOHANG sees it still exiting), keeping the
    // descriptor open and defeating the closed-fd probe below.
    const first = try testSpawnSh("exit 0");
    // Establish the exit without reaping, so the premise is never a race:
    // Linux WNOWAIT waitid(P_PIDFD), FreeBSD wait6(P_PID, WNOWAIT).
    if (comptime is_linux) {
        var info: std.os.linux.siginfo_t = undefined;
        while (compat.linuxErrno(compat.waitid(.PIDFD, first.handle, &info, std.os.linux.W.EXITED | std.os.linux.W.NOWAIT)) == .INTR) {}
    }
    if (comptime is_freebsd) {
        var status: c_int = 0;
        while (true) {
            const rc = freebsd_wait.wait6(0, @intCast(first.pid), &status, std.c.W.EXITED | std.c.W.NOWAIT, null, null);
            if (rc >= 0) break;
            if (std.posix.errno(@as(isize, rc)) != .INTR) break;
        }
    }
    const r = try state.childReserve();
    try state.childPublish(r.index, first);

    // The seam runs between childCleanup's unlock and its close. The freed
    // slot is the free-list head, so childReserve reuses it; publish a second
    // real child there, exactly as a racing worker would.
    const Reuse = struct {
        var second: born.process.Child = undefined;
        var reused_index: u32 = std.math.maxInt(u32);
        fn hook(shim: *Shim, _: u32) void {
            const rr = shim.childReserve() catch unreachable;
            shim.childPublish(rr.index, second) catch unreachable;
            reused_index = rr.index;
        }
    };
    Reuse.second = try testSpawnSh("sleep 30");
    state.test_child_cleanup_reuse = &Reuse.hook;

    state.childCleanup(state.childAt(r.index).?);
    try std.testing.expect(state.test_child_cleanup_reuse == null); // hook fired and reset
    try std.testing.expectEqual(r.index, Reuse.reused_index);

    // The first descriptor was closed by the cleanup. Raw fcntl returns -1 on
    // a closed fd (compat.fcntl treats BADF as unreachable, so it cannot probe).
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(first.handle, std.c.F.GETFD));
    // The second child's descriptor is intact and still published in the slot.
    try std.testing.expect(std.c.fcntl(Reuse.second.handle, std.c.F.GETFD) != -1);
    const reused = state.childAt(r.index).?;
    try std.testing.expect(reused.occupied);
    try std.testing.expectEqual(Reuse.second.handle, reused.child.handle);
    try std.testing.expectEqual(Reuse.second.pid, reused.child.pid);
    try std.testing.expect(state.lookupChild(Reuse.second.pid) != null);
    try std.testing.expect(state.lookupChild(first.pid) == null);

    // Clean up the second child on the caller thread (kill, blocking reap,
    // close, release), leaving no zombie and no occupied slot.
    var kop: ProcOp = .{ .kind = .kill, .child_index = r.index, .child_gen = reused.generation };
    try std.testing.expect(state.childDeadClaim(&kop, compat.signalNumber(std.posix.SIG.KILL)));
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(Reuse.second.pid) == null);
}

test "child reservation refuses at the registry ceiling with SystemResources" {
    // S1/N2: the ceiling is a named resource bound; no child is created.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    while (state.child_registry.chunk_count < max_child_chunks) try state.childGrowLocked();
    while (state.child_registry.free_head != null) _ = try state.childAllocLocked();
    try std.testing.expectError(error.SystemResources, state.childReserve());
}

test "child registry growth reports OutOfMemory on allocator refusal" {
    // N2: an allocator refusal is OutOfMemory, distinct from the ceiling's
    // SystemResources; neither creates a child.
    if (comptime !process_supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    state.allocator = failing.allocator();
    defer state.childRegistryDeinit();
    try std.testing.expectError(error.OutOfMemory, state.childRegistryInit());
}

test "cross-route error attribution: the process tag decides the registry" {
    // A tagged error reaches the child registry, never socketEvent; an untagged
    // error reaches socketEvent, never the child registry (4.2, 4.3).
    // Mutation: stripping the process tag from child udata must fail this.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.childRegistryInit();
    defer state.childRegistryDeinit();

    const r = try state.childReserve();
    try state.childPublish(r.index, .{ .handle = -1, .pid = 555555 });
    // Tagged error: latches the child's exit failure (childEvent path).
    state.dispatchEvent(.{ .err = true, .udata = procUdata(r.index, r.generation) });
    try std.testing.expect(state.childAt(r.index).?.exit_failed);
    // Untagged error with a socket-style udata: socketEvent (a registry miss
    // here), leaving a fresh child untouched.
    const r2 = try state.childReserve();
    try state.childPublish(r2.index, .{ .handle = -1, .pid = 666666 });
    state.dispatchEvent(.{ .err = true, .udata = slotUdata(0, 1) });
    try std.testing.expect(!state.childAt(r2.index).?.exit_failed);
    try std.testing.expectEqual(@as(?born.ProcessExit, null), state.childAt(r2.index).?.exit);
}

test "mapSpawnError covers every born.process spawn error row" {
    // The coarse map (5.4). std declares no InvalidArgument tag, so it collapses
    // to Unexpected like SetupFailed/ExecFailed (the design table correction).
    if (comptime !process_supported) return error.SkipZigTest;
    const E = std.process.SpawnError;
    try std.testing.expectEqual(@as(E, error.OperationUnsupported), mapSpawnError(error.Unsupported));
    try std.testing.expectEqual(@as(E, error.Unexpected), mapSpawnError(error.InvalidArgument));
    try std.testing.expectEqual(@as(E, error.SystemResources), mapSpawnError(error.SystemResources));
    try std.testing.expectEqual(@as(E, error.FileNotFound), mapSpawnError(error.FileNotFound));
    try std.testing.expectEqual(@as(E, error.AccessDenied), mapSpawnError(error.AccessDenied));
    try std.testing.expectEqual(@as(E, error.InvalidExe), mapSpawnError(error.InvalidExe));
    try std.testing.expectEqual(@as(E, error.Unexpected), mapSpawnError(error.SetupFailed));
    try std.testing.expectEqual(@as(E, error.Unexpected), mapSpawnError(error.ExecFailed));
}

test "synchronous arm confirms the exit watch and a fast exit latches for the wait" {
    // A1: the arm op retires only after the watch is confirmed live (Linux
    // synchronous epoll_ctl; FreeBSD staged EV_ADD NOTE_EXIT confirmed by the
    // zero-timeout flush). The FreeBSD NOTE_EXIT registration delivery is
    // required evidence. A fast-exiting child's exit is latched for the wait.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("exit 5");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);

    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    if (comptime is_freebsd) state.procFlushArms();
    const child = state.childAt(r.index).?;
    try std.testing.expect(child.watch_armed);
    try std.testing.expectEqual(@as(u32, 1), arm.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, null), arm.result.err);

    // Harvest the exit if the arm flush did not already latch it.
    if (child.exit == null and !child.exit_failed) {
        var events: [8]born.Event = undefined;
        const n = try state.port.wait(&events, 2000);
        for (events[0..n]) |ev| state.dispatchEvent(ev);
    }
    try std.testing.expect(child.exit != null);

    // A wait completes immediately from the latched exit and tears down.
    var w: ProcOp = .{ .kind = .wait, .child_index = r.index, .child_gen = r.generation };
    w.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(w.slot_index).?.op = &w;
    state.waitDrive(&w);
    try std.testing.expectEqual(@as(u32, 1), w.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, null), w.result.err);
    try std.testing.expectEqual(@as(?born.ProcessExit, .{ .code = 5 }), w.result.exit);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
}

test "arm watchProcess refusal retires arm_failed and the kill drain cleans up" {
    // R3/A1: an injected watchProcess failure (the descriptor is closed before
    // arming: Linux synchronous epoll_ctl EBADF, FreeBSD staged EV_ERROR at the
    // flush) retires the arm failed; the spawn thunk's cleanup kill op then
    // drives armFailedCleanup. Mutation: returning the child after an arm
    // refusal, or retiring the arm before the flush confirmation, must fail.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);
    // Inject the refusal: close the descriptor so watchProcess fails. On
    // FreeBSD the procdesc close SIGKILLs the running child (init reaps) and
    // the stale descriptor stages EV_ADD, answered EV_ERROR at the flush. On
    // Linux a pidfd close does NOT kill the child, so SIGKILL by pid and reap
    // here (N3) to leak no sleep; epoll_ctl refuses the closed fd synchronously.
    compat.close(bc.handle);
    if (comptime is_linux) {
        std.posix.kill(bc.pid, .KILL) catch {};
        var info: std.os.linux.siginfo_t = undefined;
        while (compat.linuxErrno(compat.waitid(.PID, bc.pid, &info, std.os.linux.W.EXITED)) == .INTR) {}
    }

    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    if (comptime is_freebsd) state.procFlushArms();
    const child = state.childAt(r.index).?;
    try std.testing.expect(child.arm_failed);
    try std.testing.expectEqual(@as(?ProcError, .arm_failed), arm.result.err);
    try std.testing.expectEqual(@as(u32, 1), arm.state.load(.acquire));

    // The descriptor is already closed; null the slot's handle so the
    // cleanup close is a no-op, not a double-close of the same fd (N3).
    child.child.handle = -1;

    // The cleanup kill op finishes without waiting for an exit.
    var k: ProcOp = .{ .kind = .kill, .child_index = r.index, .child_gen = r.generation };
    k.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(k.slot_index).?.op = &k;
    state.killDrive(&k);
    try std.testing.expectEqual(@as(u32, 1), k.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, null), k.result.err);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
}

test "arm flush wait failure marks arm_failed and the kill drain cleans up" {
    // R2: a failed arm-confirming flush (port.wait refusal) must mark the
    // child arm_failed, not just retire the arm op: the spawn thunk's cleanup
    // kill op then drives armFailedCleanup instead of parking pending_kill on
    // an exit that can never arrive (the watch was never registered). The
    // test_flush_fault hook injects the refusal without touching the port.
    // Mutation: retiring .arm_failed without setting child.arm_failed must
    // fail (the kill op would park forever).
    if (comptime !process_supported or !is_freebsd) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);

    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    // Staged, not yet confirmed: the watch is not live, arm_failed is clear.
    try std.testing.expect(!state.childAt(r.index).?.watch_armed);
    try std.testing.expect(!state.childAt(r.index).?.arm_failed);
    try std.testing.expectEqual(&arm, state.childAt(r.index).?.pending_arm.?);

    state.test_flush_fault = true;
    state.procFlushArms();
    const child = state.childAt(r.index).?;
    try std.testing.expect(child.arm_failed);
    try std.testing.expect(!child.watch_armed);
    try std.testing.expectEqual(@as(?*ProcOp, null), child.pending_arm);
    try std.testing.expectEqual(@as(?ProcError, .arm_failed), arm.result.err);
    try std.testing.expectEqual(@as(u32, 1), arm.state.load(.acquire));
    try std.testing.expectEqual(@as(?anyerror, error.Unexpected), state.latchedError());
    try std.testing.expect(!state.test_flush_fault); // hook reset

    // The cleanup kill op finishes without waiting for an exit (armFailedCleanup).
    var k: ProcOp = .{ .kind = .kill, .child_index = r.index, .child_gen = r.generation };
    k.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(k.slot_index).?.op = &k;
    state.killDrive(&k);
    try std.testing.expectEqual(@as(u32, 1), k.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, null), k.result.err);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
    // childCleanup's procdesc close SIGKILLed the running child; init reaps.
    try expectPidGone(bc.pid);
}

test "synthetic EV_ERROR while arming marks arm_failed; flush retires failed" {
    // R2: a tagged EV_ERROR delivered while the arm is pending (the kernel
    // refusing the staged EV_ADD) marks the child arm_failed via childEvent;
    // the flush then retires the arm .arm_failed even though the flush wait
    // itself succeeded, and the cleanup kill op drives armFailedCleanup.
    // Synthetic event injection mirrors the stolen-reap unit's dispatchEvent.
    if (comptime !process_supported or !is_freebsd) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);

    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    try std.testing.expectEqual(&arm, state.childAt(r.index).?.pending_arm.?);

    // Synthetic tagged EV_ERROR for this child while the arm is pending and
    // the watch is not yet live: childEvent marks arm_failed.
    state.dispatchEvent(.{ .err = true, .udata = procUdata(r.index, r.generation) });
    try std.testing.expect(state.childAt(r.index).?.arm_failed);
    try std.testing.expect(!state.childAt(r.index).?.watch_armed);

    // The flush wait succeeds (valid descriptor), but the retire loop sees
    // arm_failed and retires .arm_failed; it must not confirm the watch.
    state.procFlushArms();
    const child = state.childAt(r.index).?;
    try std.testing.expect(child.arm_failed);
    try std.testing.expect(!child.watch_armed);
    try std.testing.expectEqual(@as(?ProcError, .arm_failed), arm.result.err);
    try std.testing.expectEqual(@as(u32, 1), arm.state.load(.acquire));

    // The cleanup kill op finishes without waiting for an exit.
    var k: ProcOp = .{ .kind = .kill, .child_index = r.index, .child_gen = r.generation };
    k.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(k.slot_index).?.op = &k;
    state.killDrive(&k);
    try std.testing.expectEqual(@as(u32, 1), k.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, null), k.result.err);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
    try expectPidGone(bc.pid);
}

test "dead-loop kill reaps a running child via wait6/waitid with no zombie" {
    // S2/B1: childKill after the loop is dead claims the child on the caller
    // thread and reaps it blocking (FreeBSD wait6(P_PID), Linux waitid(P_PIDFD)).
    // The FreeBSD wait6 reap is required evidence. childDeadClaim makes no port
    // call, so port=undefined is safe; the blocking reap leaves no zombie.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);

    var op: ProcOp = .{ .kind = .kill, .child_index = r.index, .child_gen = r.generation };
    op.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(op.slot_index).?.op = &op;
    const claimed = state.childDeadClaim(&op, compat.signalNumber(std.posix.SIG.KILL));
    try std.testing.expect(claimed);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
    // The blocking reap completed: the pid is gone immediately (no zombie).
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(bc.pid, @enumFromInt(0)));
}

test "abandoned wait keeps the child running; the loop reaps it on exit" {
    // R2: canceling a wait abandons the child (pid unpublished, descriptor
    // still watched) rather than killing it; the cancel thunk closes the
    // caller's stdio ends (review R1), not the loop. The loop reaps it when
    // its exit arrives. Mutation: reverting to kill-on-cancel must fail the
    // "still running after the canceled wait" assertion.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);

    // Arm the watch so the exit event arrives after abandon.
    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    if (comptime is_freebsd) state.procFlushArms();
    try std.testing.expect(state.childAt(r.index).?.watch_armed);

    // Park a wait, then cancel it: the drain chains it for abandon.
    var w: ProcOp = .{ .kind = .wait, .child_index = r.index, .child_gen = r.generation };
    w.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(w.slot_index).?.op = &w;
    state.waitDrive(&w);
    try std.testing.expectEqual(&w, state.childAt(r.index).?.pending_wait.?);
    w.cancel_requested.store(true, .release);
    try std.testing.expect(state.procRequestCancel(&w));
    _ = state.procDrainLocked();
    try std.testing.expectEqual(@as(u32, 1), w.state.load(.acquire));
    try std.testing.expect(w.outcome_canceled);

    const child = state.childAt(r.index).?;
    try std.testing.expect(child.abandoned);
    try std.testing.expectEqual(@as(?*ProcOp, null), child.pending_wait);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
    // The child is still running (abandon did not kill it).
    try std.posix.kill(bc.pid, @enumFromInt(0));

    // Trigger the exit and harvest it: the loop reaps the abandoned child.
    bc.kill(compat.signalNumber(std.posix.SIG.TERM)) catch {};
    var events: [8]born.Event = undefined;
    const n = try state.port.wait(&events, 2000);
    for (events[0..n]) |ev| state.dispatchEvent(ev);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
}

test "deinit kills a still-running abandoned child" {
    // R2 teardown: a canceled wait left the child running and abandoned;
    // childRegistryCloseAll (deinit, after the loop joins) SIGKILLs and reaps it.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);
    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    if (comptime is_freebsd) state.procFlushArms();
    var w: ProcOp = .{ .kind = .wait, .child_index = r.index, .child_gen = r.generation };
    w.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(w.slot_index).?.op = &w;
    state.waitDrive(&w);
    w.cancel_requested.store(true, .release);
    _ = state.procRequestCancel(&w);
    _ = state.procDrainLocked();
    try std.testing.expect(state.childAt(r.index).?.abandoned);

    // deinit's close-all kills the still-running abandoned child.
    state.childRegistryCloseAll();
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    // born's FreeBSD close leaves the reap to init (async zombie); Linux reaps
    // on close. Poll until the pid is gone.
    var gone = false;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        std.posix.kill(bc.pid, @enumFromInt(0)) catch |err| {
            if (err == error.ProcessNotFound) {
                gone = true;
                break;
            }
        };
        compat.sleepNs(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(gone);
}

test "a stolen reap latches wait_failed, completing a parked wait with Unexpected" {
    // Failure latch: a tagged error after the arm (stolen reap, port failure)
    // latches exit_failed and completes a parked wait as wait_failed, not a hang.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    // A real child (valid descriptor for the teardown close); the tagged error
    // event simulates a stolen reap rather than a genuine exit.
    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);
    var w: ProcOp = .{ .kind = .wait, .child_index = r.index, .child_gen = r.generation };
    w.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(w.slot_index).?.op = &w;
    state.waitDrive(&w);
    try std.testing.expectEqual(&w, state.childAt(r.index).?.pending_wait.?);

    state.dispatchEvent(.{ .err = true, .udata = procUdata(r.index, r.generation) });
    try std.testing.expectEqual(@as(u32, 1), w.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, .wait_failed), w.result.err);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
}

test "kill drain collects the exit and releases the slot" {
    // The uncancelable kill drain parks until the exit arrives, then collects
    // it and tears down (7). Mutation: reverting to signal-only without exit
    // collection (skip childCleanup in killFinish) must fail this.
    if (comptime !process_supported) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try state.childRegistryInit();
    defer state.childRegistryDeinit();
    defer state.procFreeChunks();

    const bc = try testSpawnSh("sleep 30");
    const r = try state.childReserve();
    try state.childPublish(r.index, bc);
    var arm: ProcOp = .{ .kind = .arm, .child_index = r.index, .child_gen = r.generation };
    arm.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(arm.slot_index).?.op = &arm;
    state.armDrive(&arm);
    if (comptime is_freebsd) state.procFlushArms();

    // Park the kill drain: it waits for the exit, not signal-only.
    var k: ProcOp = .{ .kind = .kill, .child_index = r.index, .child_gen = r.generation };
    k.slot_index = try state.procAllocSlotLocked();
    state.procSlotAt(k.slot_index).?.op = &k;
    state.killDrive(&k);
    try std.testing.expectEqual(&k, state.childAt(r.index).?.pending_kill.?);
    try std.testing.expectEqual(@as(u32, 0), k.state.load(.acquire));

    // Caller SIGTERM through the descriptor; harvest the exit.
    bc.kill(compat.signalNumber(std.posix.SIG.TERM)) catch {};
    var events: [8]born.Event = undefined;
    const n = try state.port.wait(&events, 2000);
    for (events[0..n]) |ev| state.dispatchEvent(ev);
    try std.testing.expectEqual(@as(u32, 1), k.state.load(.acquire));
    try std.testing.expectEqual(@as(?ProcError, null), k.result.err);
    try std.testing.expect(!state.childAt(r.index).?.occupied);
    try std.testing.expect(state.lookupChild(bc.pid) == null);
}

test "public spawn refuses at the registry ceiling with SystemResources, no child" {
    // S1/N2 through the public API: with every registry slot reserved, spawn
    // refuses at reservation BEFORE the fork, so no child is created. The
    // reservations below are slot-only (handle sentinel -1, no descriptor); they
    // are released before deinit so close-all never purges a fake handle.
    if (comptime !process_supported) return error.SkipZigTest;
    const interface = try io(.{
        .allocator = std.testing.allocator,
        .capabilities = .{ .process = .born_evented },
    });
    defer deinit(interface);
    const self = shimFrom(interface.userdata);

    var reserved: u32 = 0;
    defer {
        var i: u32 = 0;
        while (i < reserved) : (i += 1) self.childRelease(i);
    }
    while (true) {
        _ = self.childReserve() catch |err| {
            try std.testing.expectEqual(error.SystemResources, err);
            break;
        };
        reserved += 1;
    }
    try std.testing.expectEqual(@as(u32, @intCast(proc_per_chunk * max_child_chunks)), reserved);

    try std.testing.expectError(error.SystemResources, std.process.spawn(interface, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }));
    // No fork ran: the pid map is empty.
    try std.testing.expectEqual(@as(u32, 0), self.child_registry.map.count());
}

test "public spawn reports OutOfMemory on registry growth refusal, no child" {
    // N2 through the public API: with chunk 0's free list exhausted, the next
    // reservation must grow the registry. ChunkFailAllocator refuses exactly
    // that growth allocation (forwarding the spawn arena's requests), so spawn
    // returns OutOfMemory before any fork; no chunk grows, no child is published.
    if (comptime !process_supported) return error.SkipZigTest;
    const interface = try io(.{
        .allocator = std.testing.allocator,
        .capabilities = .{ .process = .born_evented },
    });
    defer deinit(interface);
    const self = shimFrom(interface.userdata);

    var warm: u32 = 0;
    defer {
        var i: u32 = 0;
        while (i < warm) : (i += 1) self.childRelease(i);
    }
    while (self.child_registry.free_head != null) {
        _ = try self.childReserve();
        warm += 1;
    }
    try std.testing.expectEqual(@as(u32, @intCast(proc_per_chunk)), warm);
    try std.testing.expectEqual(@as(usize, 1), self.child_registry.chunk_count);

    var chunk_fail = ChunkFailAllocator{ .backing = std.testing.allocator };
    self.allocator = chunk_fail.allocator();
    defer self.allocator = std.testing.allocator;

    try std.testing.expectError(error.OutOfMemory, std.process.spawn(interface, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }));
    // The registry growth allocation was attempted and refused (not the arena).
    try std.testing.expect(chunk_fail.chunk_refused);
    try std.testing.expectEqual(@as(usize, 1), self.child_registry.chunk_count);
    try std.testing.expectEqual(@as(u32, 0), self.child_registry.map.count());
}

test "close defers while a consumer holds the socket, then finalizes on drain (#115)" {
    // Deterministic poison for the close-in-flight race: a counting lookup
    // holds `users` on the socket, so closeDrive must NOT close the descriptor
    // or retire the close op yet. New lookups refuse `.closing` (never `.absent`,
    // which would forward to Threaded onto the dying fd). The finalize pass
    // waits for the hold to release, then retires atomically. POSIX unit; the
    // threaded race itself is the net_test close contract plus stress.
    if (is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const fd = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.index = index;
    s.handle = fd;
    s.plain.sock = fd; // sockRetire's deinit closes it
    try state.registerHandle(fd, index);

    // A consumer resolves the handle through the counting lookup: users == 1.
    try std.testing.expectEqual(SockLookup{ .live = index }, state.lookupBorn(fd));
    try std.testing.expectEqual(@as(u32, 1), s.users.load(.acquire));

    var rop: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = &.{} } } };
    rop.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(rop.slot_index).op = &rop;
    s.pending_read = &rop;
    var close_op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
    close_op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(close_op.slot_index).op = &close_op;
    state.closeDrive(&close_op);

    // The parked read retired route_dead; the close is DEFERRED (users > 0):
    // the slot stays occupied/closing and the close op is not yet retired.
    try std.testing.expectEqual(@as(?NetError, .route_dead), rop.result.err);
    try std.testing.expectEqual(@as(u32, 1), rop.state.load(.acquire));
    try std.testing.expect(s.occupied);
    try std.testing.expect(s.closing.load(.acquire));
    try std.testing.expectEqual(@as(?*NetOp, &close_op), s.pending_close);
    try std.testing.expectEqual(@as(u32, 0), close_op.state.load(.acquire));
    try std.testing.expect(state.has_deferred_close.load(.acquire));
    // New lookups refuse `.closing`; the refused counting lookup adds no hold.
    try std.testing.expectEqual(SockLookup.closing, state.sockClassify(fd));
    try std.testing.expectEqual(SockLookup.closing, state.lookupBorn(fd));
    try std.testing.expectEqual(@as(u32, 1), s.users.load(.acquire));

    // The finalize pass must wait while the hold is outstanding.
    state.netCloseDrain();
    try std.testing.expectEqual(@as(u32, 0), close_op.state.load(.acquire));
    try std.testing.expect(s.occupied);
    try std.testing.expect(state.has_deferred_close.load(.acquire));

    // The consumer returns: release the hold, then finalize.
    state.sockUserExit(index);
    try std.testing.expectEqual(@as(u32, 0), s.users.load(.acquire));
    state.netCloseDrain();
    try std.testing.expectEqual(@as(u32, 1), close_op.state.load(.acquire));
    try std.testing.expectEqual(@as(?NetError, null), close_op.result.err);
    try std.testing.expect(!s.occupied);
    try std.testing.expect(!state.has_deferred_close.load(.acquire));
    try std.testing.expectEqual(SockLookup.absent, state.sockClassify(fd));
}

test "a reused socket slot starts with clean teardown state (#115)" {
    // sockFreeLocked must reset closing/users/pending_close: a stale `closing`
    // would make the next closeDrive early-return and strand its parked ops.
    if (is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const fd = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.index = index;
    s.handle = fd;
    s.plain.sock = fd;
    try state.registerHandle(fd, index);
    var close_op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
    close_op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(close_op.slot_index).op = &close_op;
    state.closeDrive(&close_op); // users == 0: immediate retire
    try std.testing.expect(!s.occupied);

    // Reuse the freed slot for a new socket; teardown state must be clean.
    const fd2 = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
    const index2 = try state.sockAllocLocked();
    try std.testing.expectEqual(index, index2);
    const s2 = state.sockAt(index2).?;
    try std.testing.expect(!s2.closing.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), s2.users.load(.acquire));
    try std.testing.expectEqual(@as(?*NetOp, null), s2.pending_close);
    s2.generation +%= 1;
    s2.occupied = true;
    s2.index = index2;
    s2.handle = fd2;
    s2.plain.sock = fd2;
    try state.registerHandle(fd2, index2);
    var rop2: NetOp = .{ .kind = .read, .sock_index = index2, .payload = .{ .read = .{ .data = &.{} } } };
    rop2.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(rop2.slot_index).op = &rop2;
    rop2.cancel_requested.store(true, .release);
    s2.pending_read = &rop2;
    var close2: NetOp = .{ .kind = .close, .sock_index = index2, .payload = .{ .close = {} } };
    close2.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(close2.slot_index).op = &close2;
    state.closeDrive(&close2);
    // The second close drives fully (no stale-closing early return): the
    // canceled parked read stays canceled and the close completes.
    try std.testing.expect(rop2.outcome_canceled);
    try std.testing.expectEqual(@as(u32, 1), rop2.state.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), close2.state.load(.acquire));
    try std.testing.expect(!s2.occupied);
}

test "entry gate refuses consumer thunks once closing and drains to zero (#113)" {
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    // A consumer claims a slot; the count rises.
    try std.testing.expect(state.entryEnter());
    try std.testing.expectEqual(@as(u32, 1), state.entry.load(.acquire) & Shim.entry_count_mask);
    // Teardown sets the closing gate; a new consumer is refused at entry.
    _ = state.entry.fetchOr(Shim.entry_closing, .acq_rel);
    try std.testing.expect(!state.entryEnter());
    // The in-flight consumer returns; the count drains to zero, closing stays.
    state.entryExit();
    try std.testing.expectEqual(@as(u32, 0), state.entry.load(.acquire) & Shim.entry_count_mask);
    try std.testing.expect(state.entry.load(.acquire) & Shim.entry_closing != 0);
    // A refused thunk returns its dead-route error without touching route state.
    try std.testing.expectError(error.Canceled, deadResult(Io.Cancelable!void));
    try std.testing.expectError(error.Unexpected, deadResult(std.process.SpawnError!std.process.Child));
}

test "B1a: error-bearing thunks refuse with a dead error after the gate closes (#117)" {
    // Group (a): every error-union/error-set thunk keeps the dead-route error.
    // Post-gate the refusal returns before any forward, so the count stays zero.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    state.entryCloseAndDrain();
    const ud: ?*anyopaque = @ptrCast(&state);

    try std.testing.expectError(error.Canceled, fwd.sleep(ud, .none));
    try std.testing.expectError(error.Canceled, fwd.checkCancel(ud));
    var word: u32 = 0;
    try std.testing.expectError(error.Canceled, fwd.futexWait(ud, &word, 1, .none));
    try std.testing.expectError(error.Canceled, fwd.groupAwait(ud, undefined, undefined));
    // An error set that declares Unexpected picks it (not a fabricated success).
    try std.testing.expectError(error.Unexpected, fwd.fileLength(ud, undefined));

    try std.testing.expect(state.entry.load(.acquire) & Shim.entry_closing != 0);
    try std.testing.expectEqual(@as(u32, 0), state.entry.load(.acquire) & Shim.entry_count_mask);
}

test "B1b: a release thunk still forwards after the gate closes (#117)" {
    // Group (b): wake/release never refuses. futexWake post-gate must still wake
    // a waiter (refusing it would hang entryCloseAndDrain). Verify the forward
    // runs: a waiter on `word` is woken by a post-gate futexWake.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    const ud: ?*anyopaque = @ptrCast(&state);
    var word: std.atomic.Value(u32) = .init(0);

    const Waiter = struct {
        fn run(tio: Io, w: *std.atomic.Value(u32)) void {
            // Block until the value changes from 0 (uncancelable, like a mutex).
            tio.vtable.futexWaitUncancelable(tio.userdata, &w.raw, 0);
        }
    };
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ state.threaded_io, &word });
    // Close the gate (deinit-style), then release: store the new value and wake.
    state.entryCloseAndDrain();
    word.store(1, .release);
    fwd.futexWake(ud, &word.raw, 1); // post-gate: must forward, not refuse
    t.join(); // returns only if the wake forwarded; a refusal would hang here
    try std.testing.expectEqual(@as(u32, 1), word.load(.acquire));
}

test "B1b: futexWake during deinit drains a counted waiter without hanging (#117)" {
    // The deadlock regression claude named: a COUNTED consumer parked in
    // futexWaitUncancelable whose waker arrives after the gate closes. The drain
    // waits for the counted call; the post-gate futexWake must forward to wake
    // it, or the drain hangs forever. Bounded by a watchdog so a refusal fails
    // the test instead of hanging the suite.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    const ud: ?*anyopaque = @ptrCast(&state);
    const tio = state.threaded_io;
    var word: std.atomic.Value(u32) = .init(0);
    var done: std.atomic.Value(u32) = .init(0);
    var claimed: std.atomic.Value(u32) = .init(0);

    const Counted = struct {
        fn run(s: *Shim, w: *std.atomic.Value(u32), d: *std.atomic.Value(u32), c: *std.atomic.Value(u32)) void {
            // A counted consumer thunk (claims an entry slot, like a real call).
            if (!s.entryEnter()) return;
            defer s.entryExit();
            // Handshake: signal the slot is claimed, then park. The main thread
            // waits on this flag (event-driven, no spin cap) before closing the
            // gate, so the count is provably 1 when the drain begins.
            c.store(1, .release);
            s.threaded_io.vtable.futexWake(s.threaded_io.userdata, &c.raw, 1);
            s.threaded_io.vtable.futexWaitUncancelable(s.threaded_io.userdata, &w.raw, 0);
            d.store(1, .release);
            s.threaded_io.vtable.futexWake(s.threaded_io.userdata, &d.raw, 1);
        }
    };
    const t = try std.Thread.spawn(.{}, Counted.run, .{ &state, &word, &done, &claimed });
    // On ANY failure path below, release and join the waiter before returning:
    // a live thread outliving `state` would dereference freed Threaded memory
    // (the defer above) and crash a later test. Runs before threaded.deinit.
    var joined = false;
    defer {
        if (!joined) {
            word.store(1, .release);
            tio.vtable.futexWake(tio.userdata, &word.raw, 1);
            t.join();
        }
    }
    // Wait until the counted waiter has claimed its slot. Futex re-checks the
    // value under the parking lock, so a wake that lands before this wait is
    // not lost; no arbitrary spin budget (Windows schedules the spawn slower
    // than a capped spin under load, which flaked this test).
    while (claimed.load(.acquire) == 0) {
        tio.vtable.futexWait(tio.userdata, &claimed.raw, 0, .none) catch {};
    }
    // Close the gate: the drain now waits for the counted waiter to return.
    _ = state.entry.fetchOr(Shim.entry_closing, .acq_rel);
    // Outside-thread wake during deinit (post-gate). Must forward (group b).
    word.store(1, .release);
    fwd.futexWake(ud, &word.raw, 1);
    // Watchdog: the waiter signals `done` once it returns. If futexWake were
    // refused, the waiter never wakes and this bounded wait errors -> fail.
    const deadline = Io.Timeout{ .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_s), .clock = .awake } };
    tio.vtable.futexWait(tio.userdata, &done.raw, 0, deadline) catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), done.load(.acquire));
    t.join();
    joined = true;
    // The counted call returned; the drain completes immediately.
    state.entryCloseAndDrain();
    try std.testing.expectEqual(@as(u32, 0), state.entry.load(.acquire) & Shim.entry_count_mask);
}

test "B1b: drain-window unlockStderr releases a counted lockStderr waiter (#117)" {
    // claude 6231: with closing set but Threaded still alive (the drain window),
    // unlockStderr MUST forward. X holds the stderr lock; Y is a counted waiter
    // blocked on t.stderr_mutex. A post-gate no-op never releases Y, so the drain
    // hangs. releaseEnter counts the unlock through the drain window and forwards
    // it; Y acquires and completes. Watchdog-bounded so a no-op fails, not hangs.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    const ud: ?*anyopaque = @ptrCast(&state);
    const tio = state.threaded_io;
    var done: std.atomic.Value(u32) = .init(0);
    var claimed: std.atomic.Value(u32) = .init(0);

    // X (this thread) holds the stderr lock pre-gate.
    _ = fwd.lockStderr(ud, null) catch return error.TestUnexpectedResult;

    const Waiter = struct {
        fn run(s: *Shim, iface: Io, d: *std.atomic.Value(u32), c: *std.atomic.Value(u32)) void {
            // A counted pre-gate lockStderr waiter: claim the slot, signal it,
            // then block on the real stderr mutex (held by X). The manual claim
            // plus raw lock gives the provable claimed-before-gate handshake.
            if (!s.entryEnter()) return;
            defer s.entryExit();
            c.store(1, .release);
            iface.vtable.futexWake(iface.userdata, &c.raw, 1);
            _ = iface.vtable.lockStderr(iface.userdata, null) catch {};
            iface.vtable.unlockStderr(iface.userdata); // Y releases its own lock
            d.store(1, .release);
            iface.vtable.futexWake(iface.userdata, &d.raw, 1);
        }
    };
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ &state, tio, &done, &claimed });
    // On any failure path, free Y and join it before threaded.deinit: a live
    // waiter outliving `state` would dereference freed Threaded memory.
    var joined = false;
    defer {
        if (!joined) {
            // If Y never completed, X still holds the pre-gate lock (the no-op
            // bug): release it raw so Y can finish and be joined.
            if (done.load(.acquire) == 0) tio.vtable.unlockStderr(tio.userdata);
            t.join();
        }
    }
    // Wait until Y has claimed its slot (provably counted before the gate).
    while (claimed.load(.acquire) == 0) {
        tio.vtable.futexWait(tio.userdata, &claimed.raw, 0, .none) catch {};
    }
    // Close the gate: the drain window. Threaded is still alive.
    _ = state.entry.fetchOr(Shim.entry_closing, .acq_rel);
    // X unlocks AFTER the gate. Must forward (counted) to release Y.
    fwd.unlockStderr(ud);
    // Watchdog: Y signals done once it acquires and releases. A no-op unlock
    // leaves Y blocked on the mutex forever, so this bounded wait fails.
    const deadline = Io.Timeout{ .duration = .{ .raw = .fromNanoseconds(2 * std.time.ns_per_s), .clock = .awake } };
    var attempts: u32 = 0;
    while (done.load(.acquire) == 0) {
        if (attempts >= 3) return error.TestUnexpectedResult;
        attempts += 1;
        tio.vtable.futexWait(tio.userdata, &done.raw, 0, deadline) catch {};
    }
    t.join();
    joined = true;
    // Both counted calls returned; the drain completes and sets dead.
    state.entryCloseAndDrain();
    try std.testing.expectEqual(@as(u32, 0), state.entry.load(.acquire) & Shim.entry_count_mask);
    try std.testing.expect(state.entry.load(.acquire) & Shim.entry_dead != 0);
}

test "B1b: drain-window groupCancel returns only after its task finishes (#117)" {
    // claude 6231: in the drain window groupCancel MUST forward and wait for the
    // group's running tasks; a post-gate no-op returns at once, letting the caller
    // free a group still in use. The task parks until released; C calls groupCancel
    // post-gate. While the task is parked groupCancel must NOT return (a no-op
    // would). Once the task is released and signals done, groupCancel returns, so
    // done is provably set before the return. Watchdog-bounded throughout.
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    const ud: ?*anyopaque = @ptrCast(&state);
    const tio = state.threaded_io;
    var go: std.atomic.Value(u32) = .init(0);
    var done: std.atomic.Value(u32) = .init(0);
    var started: std.atomic.Value(u32) = .init(0);
    var cancel_started: std.atomic.Value(u32) = .init(0);
    var cancel_returned: std.atomic.Value(u32) = .init(0);
    const deadline = Io.Timeout{ .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_s), .clock = .awake } };

    const Ctx = struct {
        iface: Io,
        go: *std.atomic.Value(u32),
        done: *std.atomic.Value(u32),
        started: *std.atomic.Value(u32),
    };
    const Task = struct {
        fn run(c: *const Ctx) void {
            c.started.store(1, .release);
            c.iface.vtable.futexWake(c.iface.userdata, &c.started.raw, 1);
            // Park uncancelably until released: groupCancel must wait for this.
            while (c.go.load(.acquire) == 0) {
                c.iface.vtable.futexWaitUncancelable(c.iface.userdata, &c.go.raw, 0);
            }
            c.done.store(1, .release);
            c.iface.vtable.futexWake(c.iface.userdata, &c.done.raw, 1);
        }
    };
    var ctx: Ctx = .{ .iface = tio, .go = &go, .done = &done, .started = &started };
    var group: Io.Group = .init;
    // concurrent (not async) spawns a worker even on a single-core host, so the
    // parked task never runs inline on this thread.
    try group.concurrent(tio, Task.run, .{&ctx});
    // Release the parked task on any exit (runs after the join defer below).
    defer {
        go.store(1, .release);
        tio.vtable.futexWake(tio.userdata, &go.raw, 1);
    }
    // Wait until the task is running (num_running provably >= 1 before the gate).
    var attempts: u32 = 0;
    while (started.load(.acquire) == 0) {
        if (attempts >= 3) return error.TestUnexpectedResult;
        attempts += 1;
        tio.vtable.futexWait(tio.userdata, &started.raw, 0, deadline) catch {};
    }
    // Close the gate: the drain window. Threaded is still alive.
    _ = state.entry.fetchOr(Shim.entry_closing, .acq_rel);

    const Canceler = struct {
        fn run(u: ?*anyopaque, g: *Io.Group, cs: *std.atomic.Value(u32), cr: *std.atomic.Value(u32), iface: Io) void {
            cs.store(1, .release);
            iface.vtable.futexWake(iface.userdata, &cs.raw, 1);
            fwd.groupCancel(u, g, @ptrCast(g));
            cr.store(1, .release);
            iface.vtable.futexWake(iface.userdata, &cr.raw, 1);
        }
    };
    const tc = try std.Thread.spawn(.{}, Canceler.run, .{ ud, &group, &cancel_started, &cancel_returned, tio });
    var joined = false;
    defer {
        if (!joined) {
            go.store(1, .release);
            tio.vtable.futexWake(tio.userdata, &go.raw, 1);
            tc.join();
        }
    }
    while (cancel_started.load(.acquire) == 0) {
        tio.vtable.futexWait(tio.userdata, &cancel_started.raw, 0, .none) catch {};
    }
    // While the task is parked (go == 0), a forwarded groupCancel cannot return.
    // A brief bounded wait must time out with cancel_returned still 0; a no-op
    // returns at once, so cancel_returned is 1 while done is still 0 -> fail.
    const probe = Io.Timeout{ .duration = .{ .raw = .fromNanoseconds(250 * std.time.ns_per_ms), .clock = .awake } };
    tio.vtable.futexWait(tio.userdata, &cancel_returned.raw, 0, probe) catch {};
    if (cancel_returned.load(.acquire) != 0) {
        try std.testing.expectEqual(@as(u32, 1), done.load(.acquire));
    }
    // Release the task; the forwarded groupCancel now waits for it to finish.
    go.store(1, .release);
    tio.vtable.futexWake(tio.userdata, &go.raw, 1);
    attempts = 0;
    while (cancel_returned.load(.acquire) == 0) {
        if (attempts >= 3) return error.TestUnexpectedResult;
        attempts += 1;
        tio.vtable.futexWait(tio.userdata, &cancel_returned.raw, 0, deadline) catch {};
    }
    // groupCancel returned; the task must have finished (signaled done) first.
    try std.testing.expectEqual(@as(u32, 1), done.load(.acquire));
    joined = true;
    tc.join();
    state.entryCloseAndDrain();
    try std.testing.expectEqual(@as(u32, 0), state.entry.load(.acquire) & Shim.entry_count_mask);
    try std.testing.expect(state.entry.load(.acquire) & Shim.entry_dead != 0);
}

test "B2: racing closer and releaser never lose the deferred-close wake (#117)" {
    // Store-buffer regression for the seq_cst ordering: closeDrive stores
    // closing then loads users; sockUserExit subtracts users then loads
    // closing. With acquire/release both sides can read the old value — the
    // close defers while the release fast-paths without waking the loop. This
    // races the real functions and asserts the invariant every iteration: a
    // deferred close implies the releaser took the wake path (counted at the
    // port.wake site). No loop thread runs here, so the test drives the
    // finalize pass itself; a lost wake fails the invariant instead of hanging
    // the suite, and a watchdog bounds every wait regardless.
    if (is_windows) return error.SkipZigTest; // POSIX slot lifecycle, as the #115 poison
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const iterations: u32 = 5000;
    const Race = struct {
        state: *Shim,
        index: u32 = 0,
        op: *NetOp = undefined,
        go: std.atomic.Value(u32) = .init(0),
        bail: std.atomic.Value(u32) = .init(0),
        closer_done: std.atomic.Value(u32) = .init(0),
        releaser_done: std.atomic.Value(u32) = .init(0),

        // Park until go == want; false when the test bails (cleanup path).
        // The bail wake can land before this thread parks (flag + wake, the
        // go value is unchanged), so the park is bounded and re-checks bail
        // instead of trusting the wake alone.
        fn waitGo(r: *@This(), want: u32) bool {
            const tio = r.state.threaded_io;
            const recheck = Io.Timeout{ .duration = .{ .raw = .fromNanoseconds(std.time.ns_per_s), .clock = .awake } };
            while (r.go.load(.acquire) != want) {
                if (r.bail.load(.acquire) != 0) return false;
                tio.vtable.futexWait(tio.userdata, &r.go.raw, r.go.load(.acquire), recheck) catch {};
            }
            return true;
        }
        fn signalDone(tio: Io, w: *std.atomic.Value(u32), n: u32) void {
            w.store(n, .release);
            tio.vtable.futexWake(tio.userdata, &w.raw, 1);
        }
        fn closer(r: *@This()) void {
            var i: u32 = 0;
            while (i < iterations) : (i += 1) {
                if (!waitGo(r, i + 1)) return;
                r.state.closeDrive(r.op);
                signalDone(r.state.threaded_io, &r.closer_done, i + 1);
            }
        }
        fn releaser(r: *@This()) void {
            var i: u32 = 0;
            while (i < iterations) : (i += 1) {
                if (!waitGo(r, i + 1)) return;
                r.state.sockUserExit(r.index);
                signalDone(r.state.threaded_io, &r.releaser_done, i + 1);
            }
        }
    };

    var race: Race = .{ .state = &state };
    const tc = try std.Thread.spawn(.{}, Race.closer, .{&race});
    const tr = try std.Thread.spawn(.{}, Race.releaser, .{&race});
    // On any failure path, release both workers from their go wait and join
    // them before the shim teardown defers run (no thread outlives the state).
    var joined = false;
    defer {
        if (!joined) {
            race.bail.store(1, .release);
            state.threaded_io.vtable.futexWake(state.threaded_io.userdata, &race.go.raw, 2);
            tc.join();
            tr.join();
        }
    }
    const tio = state.threaded_io;
    const watchdog = Io.Timeout{ .duration = .{ .raw = .fromNanoseconds(10 * std.time.ns_per_s), .clock = .awake } };
    // futexWait returns normally on timeout, so bound the attempts: a stuck
    // worker fails the test (3 x 10 s) instead of hanging the suite.
    const waitDone = struct {
        fn f(iface: Io, w: *std.atomic.Value(u32), want: u32, to: Io.Timeout) error{TestUnexpectedResult}!void {
            var attempts: u32 = 0;
            while (w.load(.acquire) != want) {
                if (attempts >= 3) return error.TestUnexpectedResult;
                attempts += 1;
                iface.vtable.futexWait(iface.userdata, &w.raw, w.load(.acquire), to) catch return error.TestUnexpectedResult;
            }
        }
    }.f;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const fd = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
        const index = try state.sockAllocLocked();
        const s = state.sockAt(index).?;
        s.generation +%= 1;
        s.occupied = true;
        s.index = index;
        s.handle = fd;
        s.plain.sock = fd; // sockRetire's POSIX deinit closes this
        try state.registerHandle(fd, index);
        // The releaser holds the only count through the counting lookup.
        try std.testing.expectEqual(SockLookup{ .live = index }, state.lookupBorn(fd));
        try std.testing.expectEqual(@as(u32, 1), s.users.load(.acquire));
        var close_op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
        close_op.slot_index = try state.netAllocSlotLocked();
        state.netSlotAt(close_op.slot_index).op = &close_op;
        race.index = index;
        race.op = &close_op;
        const wakes_before = state.test_exit_wakes.load(.monotonic);
        race.go.store(i + 1, .release);
        tio.vtable.futexWake(tio.userdata, &race.go.raw, 2);
        // Watchdog-bounded waits: a stuck worker fails instead of hanging.
        try waitDone(tio, &race.closer_done, i + 1, watchdog);
        try waitDone(tio, &race.releaser_done, i + 1, watchdog);
        if (close_op.state.load(.acquire) == 0) {
            // Deferred: the seq_cst total order forces the releaser to have
            // observed closing and woken. A lost wake fails here.
            try std.testing.expect(state.test_exit_wakes.load(.monotonic) > wakes_before);
            try std.testing.expect(state.has_deferred_close.load(.acquire));
            state.netCloseDrain(); // the loop's finalize pass, driven by the wake
            try std.testing.expectEqual(@as(u32, 1), close_op.state.load(.acquire));
        }
        try std.testing.expect(!s.occupied); // retired immediately or by the drain
    }
    joined = true;
    tc.join();
    tr.join();
}

test "B1b: release thunks after threaded.deinit touch no freed Threaded memory (#117)" {
    // The drain-window test above covers a wake DURING deinit; this covers
    // releases AFTER threaded.deinit has fully finished. Threaded lives in its
    // own page-allocator allocation: free unmaps it, so any forward that
    // dereferences the dead object faults deterministically (poison semantics;
    // the embedded stack copy would only be scribbled by `t.* = undefined`).
    // The stateless forwards must still work; the thunks whose Threaded
    // implementation touches the object (groupCancel, batchCancel on POSIX,
    // unlockStderr, anonymous fileMemoryMapDestroy) must take their post-dead
    // no-op instead. The shim itself stays live on the stack.
    var state: Shim = undefined;
    testShim(&state);
    defer state.port.deinit(); // the port is not part of the dead-Threaded scenario
    state.threaded.deinit(); // the unused testing-allocator instance
    const t = try std.heap.page_allocator.create(Io.Threaded);
    t.* = Io.Threaded.init(std.heap.page_allocator, .{});
    state.threaded_io = t.io();
    const ud: ?*anyopaque = @ptrCast(&state);

    // Drive teardown to the post-threaded.deinit window (the shim is still
    // mapped; only the Threaded object and its internals are dead).
    _ = state.entry.fetchOr(Shim.entry_closing, .acq_rel);
    state.entryCloseAndDrain();
    state.childRegistryCloseAll();
    t.deinit();
    std.heap.page_allocator.destroy(t);

    // Stateless forwards: address-keyed wake, thread-local crash handler,
    // plain close(2)/CloseHandle releases. None may dereference Threaded.
    var word: std.atomic.Value(u32) = .init(0);
    fwd.futexWake(ud, &word.raw, 1);
    fwd.crashHandler(ud); // Thread.current is null on the test thread: early return
    fwd.fileClose(ud, &.{});
    fwd.dirClose(ud, &.{});
    if (is_017) {
        fwd017.netClose(ud, &.{});
    } else {
        fwd016.netClose(ud, &.{});
    }

    // Post-dead no-ops: must return without touching the dead object, and
    // must leave caller-owned state untouched.
    var group: Io.Group = Io.Group.init;
    var token: u8 = 0;
    fwd.groupCancel(ud, &group, &token);
    try std.testing.expectEqual(@as(?*anyopaque, null), group.token.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), group.state);
    var storage: [1]Io.Operation.Storage = undefined;
    var batch = Io.Batch.init(&storage);
    fwd.batchCancel(ud, &batch); // POSIX no-op; Windows early-returns on empty pending
    try std.testing.expectEqual(@as(?*anyopaque, null), batch.userdata);
    fwd.unlockStderr(ud);

    // Anonymous mapping (section null): the no-op must not free through the
    // dead t.allocator, and must not scribble the caller's MemoryMap.
    const page = std.heap.pageSize();
    const anon = try std.heap.page_allocator.alloc(u8, page);
    var mm_anon: Io.File.MemoryMap = .{ .file = undefined, .offset = 0, .memory = @alignCast(anon), .section = null };
    fwd.fileMemoryMapDestroy(ud, &mm_anon);
    try std.testing.expectEqual(page, mm_anon.memory.len); // still ours: not destroyed
    std.heap.page_allocator.free(anon);
    // File-backed mapping (section non-null): the stateless munmap /
    // INVALID_HANDLE_VALUE early-return path still forwards post-dead.
    const backed = try std.heap.page_allocator.alloc(u8, page);
    const backed_section: ?Io.File.MemoryMap.Section = if (comptime is_windows)
        std.os.windows.INVALID_HANDLE_VALUE
    else
        @as(?void, {});
    var mm_backed: Io.File.MemoryMap = .{ .file = undefined, .offset = 0, .memory = @alignCast(backed), .section = backed_section };
    fwd.fileMemoryMapDestroy(ud, &mm_backed);
    if (is_windows) std.heap.page_allocator.free(backed); // early-return did not unmap

    // The gate is intact (closing + dead) and no counted call leaked in.
    try std.testing.expectEqual(Shim.entry_closing | Shim.entry_dead, state.entry.load(.acquire));
}

test "B1c: infallible value producers take the panic refusal path after deinit (#117)" {
    // Group (c): async/await/cancel/now/random/etc. have no error channel, so a
    // post-gate refusal must panic naming the contract, never return a fabricated
    // value (null future, unwritten result, stale random bytes, zero timestamp).
    // The 0.16 standalone test runner has no --test-filter, so the real @panic
    // abort cannot be asserted in-suite portably; deadRefuse instead records the
    // exact contract message under a test-only hook and the test asserts the
    // refusal path fired. Production aborts via deadPanic (also covered by the
    // stress suite and #108-style external rc=134 checks).
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    state.entryCloseAndDrain();
    const ud: ?*anyopaque = @ptrCast(&state);

    const Hook = struct {
        var captured: ?[]const u8 = null;
        fn record(msg: []const u8) void {
            captured = msg;
        }
    };
    test_dead_panic_hook = &Hook.record;
    defer test_dead_panic_hook = null;

    // Uniform void wrappers so the cases fit one table; args are unused post-gate
    // (the refusal precedes the forward), so undefined placeholders are safe.
    const W = struct {
        fn async_(u: ?*anyopaque) void {
            _ = fwd.async(u, undefined, undefined, undefined, undefined, undefined);
        }
        fn await_(u: ?*anyopaque) void {
            fwd.await(u, undefined, undefined, undefined);
        }
        fn cancel_(u: ?*anyopaque) void {
            fwd.cancel(u, undefined, undefined, undefined);
        }
        fn groupAsync_(u: ?*anyopaque) void {
            fwd.groupAsync(u, undefined, undefined, undefined, undefined);
        }
        fn recancel_(u: ?*anyopaque) void {
            fwd.recancel(u);
        }
        fn swap_(u: ?*anyopaque) void {
            _ = fwd.swapCancelProtection(u, undefined);
        }
        fn now_(u: ?*anyopaque) void {
            _ = fwd.now(u, undefined);
        }
        fn random_(u: ?*anyopaque) void {
            fwd.random(u, undefined);
        }
        fn futexWaitU_(u: ?*anyopaque) void {
            fwd.futexWaitUncancelable(u, undefined, undefined);
        }
    };
    const Case = struct { name: []const u8, call: *const fn (?*anyopaque) void };
    const cases = [_]Case{
        .{ .name = "async", .call = W.async_ },
        .{ .name = "await", .call = W.await_ },
        .{ .name = "cancel", .call = W.cancel_ },
        .{ .name = "groupAsync", .call = W.groupAsync_ },
        .{ .name = "recancel", .call = W.recancel_ },
        .{ .name = "swapCancelProtection", .call = W.swap_ },
        .{ .name = "now", .call = W.now_ },
        .{ .name = "random", .call = W.random_ },
        .{ .name = "futexWaitUncancelable", .call = W.futexWaitU_ },
    };
    for (cases) |c| {
        Hook.captured = null;
        c.call(ud);
        const msg = Hook.captured orelse return error.TestUnexpectedResult;
        const expect = try std.fmt.allocPrint(
            std.testing.allocator,
            "Io.{s} used during or after deinit",
            .{c.name},
        );
        defer std.testing.allocator.free(expect);
        try std.testing.expectEqualStrings(expect, msg);
    }
}

test "blocking thunks on a Born loop thread trip the loop-thread guard" {
    // Item 4 of #140: a blocking call on a Born loop thread stalls every
    // connection on the loop, so blocking shim thunks panic in Debug and
    // ReleaseSafe. The #117-style hook records the message instead of
    // aborting; the marker must be set on the calling thread.
    if (!compat.asserts_active) return error.SkipZigTest; // the guard compiles out in ReleaseFast
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);
    const ud: ?*anyopaque = @ptrCast(&state);

    const Hook = struct {
        var captured: ?[]const u8 = null;
        fn record(msg: []const u8) void {
            captured = msg;
        }
    };
    test_loop_guard_hook = &Hook.record;
    defer test_loop_guard_hook = null;

    // Hold the stderr lock for the unlockStderr case; take it on the
    // unmarked thread because lockStderr is a guarded (blocking) slot.
    _ = fwd.lockStderr(ud, null) catch return error.TestUnexpectedResult;

    born.loop_thread.mark();
    defer born.loop_thread.unmark();

    const W = struct {
        fn sleep_(u: ?*anyopaque) void {
            fwd.sleep(u, .none) catch {};
        }
        fn futexWait_(u: ?*anyopaque) void {
            fwd.futexWait(u, undefined, undefined, .none) catch {};
        }
        fn groupAwait_(u: ?*anyopaque) void {
            fwd.groupAwait(u, undefined, undefined) catch {};
        }
    };
    Hook.captured = null;
    W.sleep_(ud);
    try std.testing.expectEqualStrings("Io.sleep called on a Born loop thread", Hook.captured orelse "uncaptured");

    Hook.captured = null;
    W.futexWait_(ud);
    try std.testing.expectEqualStrings("Io.futexWait called on a Born loop thread", Hook.captured orelse "uncaptured");

    Hook.captured = null;
    W.groupAwait_(ud);
    try std.testing.expectEqualStrings("Io.groupAwait called on a Born loop thread", Hook.captured orelse "uncaptured");

    // An exempt slot on the same marked thread does not trip the guard.
    Hook.captured = null;
    _ = fwd.now(ud, .awake);
    var byte: [1]u8 = .{0};
    _ = fwd.random(ud, &byte);
    try std.testing.expectEqual(@as(?[]const u8, null), Hook.captured);

    // The wake/release class is unguarded by omission, not by the exempt
    // list: a loop thread must be able to wake or release without tripping.
    const release = struct {
        fn futexWake_(u: ?*anyopaque) void {
            var word: u32 = 1;
            fwd.futexWake(u, &word, 1);
        }
        fn unlockStderr_(u: ?*anyopaque) void {
            fwd.unlockStderr(u);
        }
        fn fileClose_(u: ?*anyopaque) void {
            // Close the read end of a fresh pipe: a real descriptor the test owns.
            var fds: [2]std.c.fd_t = undefined;
            const pipe_rc = std.c.pipe(&fds);
            std.debug.assert(pipe_rc == 0);
            const f: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
            const files = [_]Io.File{f};
            fwd.fileClose(u, &files);
            _ = std.c.close(fds[1]);
        }
    };
    Hook.captured = null;
    release.futexWake_(ud);
    try std.testing.expectEqual(@as(?[]const u8, null), Hook.captured);

    Hook.captured = null;
    release.unlockStderr_(ud);
    try std.testing.expectEqual(@as(?[]const u8, null), Hook.captured);

    if (!is_windows) {
        Hook.captured = null;
        release.fileClose_(ud);
        try std.testing.expectEqual(@as(?[]const u8, null), Hook.captured);
    }
}

test "close in flight must not let a resolved handle read a recycled fd (#115 poison)" {
    // Bug reproduction (fails on master eb9b6a4, passes here). A consumer
    // resolves a Born handle, then a close drives. On master lookupBorn is
    // non-counting, so closeDrive closes the descriptor immediately even though
    // the consumer still holds the handle; the fd number is then recycled by a
    // fresh socketpair, and the next read thunk forwards to Threaded onto the
    // recycled fd and reads ITS data (a wrong-socket read). Here the counting
    // lookup holds `users`, closeDrive defers, and the read refuses `.closing`
    // with Unexpected without touching the descriptor. Uses only API common to
    // master and this branch (lookupBorn's result is discarded; it compiles
    // against both the ?u32 and the counting SockLookup signatures).
    if (is_windows) return error.SkipZigTest;
    var state: Shim = undefined;
    testShim(&state);
    defer testShimDeinit(&state);

    try testNetGrow(&state, 1);
    defer state.netFreeChunks();
    try state.registryInit();
    defer state.registryDeinit();

    const fd = try compat.socket(compat.AF.UNIX, compat.SOCK.STREAM, 0);
    defer compat.close(fd);
    const index = try state.sockAllocLocked();
    const s = state.sockAt(index).?;
    s.generation +%= 1;
    s.occupied = true;
    s.index = index;
    s.handle = fd;
    s.plain.sock = fd; // sockRetire's POSIX deinit closes this
    try state.registerHandle(fd, index);

    // A consumer resolves the handle (branch: claims a counting hold; master:
    // plain lookup). The result is intentionally discarded — the hold, where it
    // exists, must keep the descriptor alive across the close.
    _ = state.lookupBorn(fd);

    var close_op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
    close_op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(close_op.slot_index).op = &close_op;
    state.closeDrive(&close_op);

    // Recycle the fd number with a fresh connected pair carrying a marker. On
    // master fd was just closed, so the lowest-free fd (sp[0]) equals fd; here
    // fd is still open (deferred close), so sp[0] is a different number.
    var sp: [2]compat.fd_t = undefined;
    if (std.c.socketpair(compat.AF.UNIX, compat.SOCK.STREAM, 0, &sp) != 0)
        return error.TestUnexpectedResult;
    defer {
        compat.close(sp[0]);
        compat.close(sp[1]);
    }
    _ = try compat.write(sp[1], "RECYCLED");

    // A read arrives on the original handle. It must refuse with Unexpected,
    // never forward onto a closed/recycled descriptor. Master forwards and
    // returns the marker bytes (success), failing this assertion. The read
    // slot is netRead on 0.16 and operate(.net_read) on 0.17.
    var buf: [64]u8 = undefined;
    var data = [_][]u8{&buf};
    const ud: ?*anyopaque = @ptrCast(&state);
    if (is_017) {
        const result = try net017.operate(ud, .{ .net_read = .{ .socket_handle = fd, .data = &data } });
        switch (result) {
            .net_read => |r| try std.testing.expectError(error.Unexpected, r),
            else => return error.TestUnexpectedResult,
        }
    } else {
        try std.testing.expectError(error.Unexpected, net016.netRead(ud, fd, &data));
    }
}
