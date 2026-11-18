//! Born `std.Io` compatibility shim: composite state, routing, time route.
//!
//! The shim composes Born's event port with upstream's `Io.Threaded` worker
//! pool behind a single `std.Io`. One `Io.userdata` pointer carries the whole
//! composite (`Shim`); every vtable slot is a thunk that recovers the composite
//! and either services the slot on Born's reactor or re-invokes the saved
//! Threaded vtable with the Threaded's own userdata. This is the explicit
//! per-slot routing seam: increments replace individual thunks with Born
//! evented implementations while the rest keep delegating to Threaded.
//!
//! The all-Threaded baseline (`baseline_vtable`) delegates every slot to
//! Threaded and spawns no loop thread. With `capabilities.time = .born_evented`
//! the interface uses `time_vtable`: `sleep` and the monotonic `now` run on
//! Born's timers and clock through the Scale model machinery below; every
//! other slot still delegates to Threaded.
//!
//! ## Scale model machinery (time route)
//!
//! - Loop ownership: one dedicated loop thread per instance is the sole caller
//!   of `EvPort.wait` and the sole mutator of port state. After `io()` returns,
//!   the caller must not drive the port itself.
//! - Cross-thread submission: a blocking `sleep` stack-allocates one operation
//!   node (`SleepOp`), takes a slot in the loop-owned slot table, enqueues the
//!   node on the shim's mutex-protected intrusive queue, and calls `wake()`
//!   only when the queue went from empty to non-empty. `wake()` is the only
//!   cross-thread port call. The loop swaps the whole queue out under the
//!   mutex and arms timers on its own thread.
//! - Timer identity: the timer id is the slot index and the port's `udata`
//!   encodes (generation, index). The slot table is loop-owned storage in
//!   fixed-size chunks that never move: growth allocates a new chunk and
//!   publishes its pointer with release under the queue mutex, and readers
//!   load it with acquire, so the loop never chases a reallocation. The port
//!   never holds a pointer into caller stack. On fire the loop snapshots
//!   (op, generation) under the queue mutex, drops the event if the slot is
//!   free or the generation does not match, and only then touches the node.
//!   Stale fires are normal (a cancel's `EV_DELETE` can fail to stage under
//!   memory pressure), so this check is the structural use-after-free guard,
//!   not an optimization.
//! - Completion return: the submitter blocks on a cancelable Threaded futex
//!   wait on the node's state word. The loop publishes the terminal state
//!   with a release store and frees the slot under the queue mutex (atomic
//!   with the cancel path's occupancy check), then signals the futex outside
//!   the mutex. The wake is address-keyed and never reads the word, so it is
//!   safe even if the submitter has already returned and reused the frame;
//!   the store precedes the wake, so no wakeup is lost. Cancellation
//!   composes: Threaded's cancel interrupts the submitter's futex wait; the
//!   submitter sets `cancel_requested` and pushes the slot index on a
//!   dedicated cancel list (links live in the slot table, never in caller
//!   storage), waking the loop only on an empty-to-non-empty transition.
//!   The loop drains that list each cycle and disarms only the canceled
//!   nodes; it never scans the armed population. A slot retired by fire
//!   while its cancel entry is still queued is not freed for reuse until
//!   that entry drains, so a reallocation can never truncate the list. The
//!   submitter drains uncancelably until retirement before returning, so
//!   the loop never touches stack storage after the call unwinds.
//! - Failure visibility: `sleep`'s declared set is `error{Canceled}` only, so
//!   route-level refusals (port wait failures, timer-arm refusals, slot-table
//!   growth failures) are latched in the composite and exposed by
//!   `loopError(io)`. After `wait_fail_limit` consecutive wait failures the
//!   loop retires everything and exits; later submits are rejected.
//! - Deployment is thread-per-core: one port and one instance per core.
//!
//! ## Time route: per-slot overload and failure mapping
//!
//! The submission queue is bounded by caller-provided operation storage: every
//! blocking call owns exactly one node, so the queue holds at most one node per
//! concurrent caller. There is no shared ring to fill; a queue-full condition
//! cannot occur and no slot returns a queue-full error. The slot table grows
//! on demand under the queue mutex in non-moving chunks, bounded at
//! `max_chunks * slots_per_chunk` slots per instance; a growth refusal is a
//! resource failure, not overload, and maps like a timer-arm refusal below.
//!
//! | slot | declared error set | queue-full error | other failures |
//! |---|---|---|---|
//! | `sleep` | `error{Canceled}` | none: cannot occur (caller-owned nodes) | cancel request, shim stop, timer-arm refusal (`born.TimerError`), or slot-table growth refusal -> `Canceled`, the set's only member; std.Io's sleep contract admits no resource error, so the cause is latched and readable via `loopError(io)` |
//! | `now` | infallible | n/a: direct clock read, no submission | clock refusal -> `Timestamp.zero`, matching Threaded |
//! | `clockResolution` | `error{ClockUnavailable, Unexpected}` | n/a: stays Threaded | Threaded's mapping; see the clock note below |
//! | `cancel` | `void` | n/a: forwards to Threaded; the Born-side disarm rides the sleeping call's own node | none |
//!
//! `Canceled` from `sleep` therefore always means the operation was interrupted
//! (task cancellation, shim stop, or kernel timer resource exhaustion), never
//! submission-queue overload. Sleeps on a `Clock` other than `.awake` are
//! explicitly delegated to Threaded: Born's timers measure the monotonic timer
//! clock only. On macOS `.awake` reads Born's CLOCK_MONOTONIC rather than
//! Threaded's CLOCK_UPTIME_RAW so `now` and sleep deadlines share one clock.
//! `clockResolution(.awake)` stays on Threaded, so on macOS and Windows it
//! reports the resolution of Threaded's awake clock (CLOCK_UPTIME_RAW and the
//! Windows interrupt-time clock respectively), not of the Born timer clock
//! (CLOCK_MONOTONIC, QPC) that `now(.awake)` reads. Born timers have
//! millisecond granularity: a sleep shorter than 1 ms costs at least 1 ms.
//!
//! ## Latency stats
//!
//! The per-sleep latency breakdown (`timeStats`) is a bench-time instrument
//! behind the `time_stats` build option (`born_io_options` module). It is off
//! by default: the sleep path then performs no shared writes and no extra
//! clock reads, and `timeStats` reports zeros. The test and bench builds
//! enable it; the functional fire timestamp used for re-arm decisions is
//! always recorded.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const compat = @import("compat");
const io_options = @import("born_io_options");
const Io = std.Io;

const is_017 = builtin.zig_version.minor >= 17;
const is_windows = builtin.os.tag == .windows;

/// Comptime gate for the latency-breakdown instrument: when false the sleep
/// path performs no shared writes and no extra clock reads, and `timeStats`
/// reports zeros. Set by the `time_stats` build option.
pub const time_stats_enabled: bool = io_options.time_stats;

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
    /// The time route's loop thread could not be spawned
    /// (`std.Thread.SpawnError`: thread quota, system resources, memory).
    /// Distinct from `OutOfMemory`, which reports composite/pool allocation.
    LoopSpawnFailed,
};

/// Caller-owned operation node for the time route: one per blocking `sleep`
/// call, stack-allocated by the submitter. The submission queue is bounded by
/// these nodes, so it cannot overflow (see the module's overload table).
///
/// Ownership: the submitter owns the node until it is enqueued; the loop
/// thread owns it from dequeue until it publishes the terminal `state`; the
/// submitter owns it again after observing the terminal state. The loop never
/// touches a node after retirement, which is what makes stack storage safe.
/// The port's timer identity refers to the loop-owned slot table, never to
/// this node.
pub const SleepOp = struct {
    /// Submission-queue link: submitter writes before enqueue, loop reads
    /// after dequeue.
    next: ?*SleepOp = null,
    /// Slot-table index assigned at submit under the queue mutex; read by the
    /// loop after dequeue and by the submitter on the cancel path.
    slot_index: u32 = 0,
    /// Born monotonic deadline in nanoseconds; loop-thread only after enqueue.
    deadline_ns: u64 = 0,
    /// Set by the loop before the terminal store: the operation ended without
    /// sleeping out its deadline (cancel request, shim stop, arm refusal).
    outcome_canceled: bool = false,
    /// Futex word: 0 = pending, 1 = terminal. The loop releases, the submitter
    /// acquires; completion and retirement both wake it.
    state: std.atomic.Value(u32) = .init(0),
    /// The submitter sets this (release) when its completion wait observes
    /// cancellation, then waits for retirement. The loop checks it at dequeue
    /// and at timer fire.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Phase timestamps for the latency breakdown (`timeStats`), written by
    /// the loop before the terminal store: `t_arm_ns` at first arm (only
    /// when `time_stats_enabled`), `t_fire_ns` at each fire (always: the
    /// re-arm remainder decision reads it). The submitter's own phase
    /// timestamps are locals, never written here after enqueue (the loop
    /// owns the node from dequeue, so a late submitter write would race the
    /// loop's arm).
    t_arm_ns: u64 = 0,
    t_fire_ns: u64 = 0,
};

/// Loop-owned timer slot. The timer id is the slot index; the port's `udata`
/// carries (generation, index) so a stale fire is dropped without touching
/// caller storage. `op`, `generation`, `next_free`, `cancel_next` and
/// `on_cancel_list` are protected by the queue mutex; `armed` is loop-thread
/// only. Slots live in non-moving chunks, so a slot pointer stays valid
/// across table growth.
pub const Slot = struct {
    /// Occupant: set under the mutex at submit, cleared under the mutex at
    /// retirement. While occupied, only the loop thread retires it.
    op: ?*SleepOp = null,
    /// Bumped under the mutex each time the slot is handed to a new node.
    generation: u32 = 0,
    /// True while the occupant's timer is armed. Loop-thread only.
    armed: bool = false,
    /// Free-list link (queue mutex).
    next_free: ?u32 = null,
    /// Cancel-list link (queue mutex); meaningful only while occupied.
    cancel_next: ?u32 = null,
    /// True while the slot's index is linked on the cancel list (queue
    /// mutex). A slot on the cancel list is never freed for reuse: its
    /// entry must drain first, or a reallocation would reset `cancel_next`
    /// and truncate the list behind it.
    on_cancel_list: bool = false,
};

/// Slots per chunk, the unit of slot-table growth. A chunk is heap-allocated
/// once and never moves or frees until deinit, so the loop can hold slot
/// pointers lock-free while submitters grow the table under the queue mutex.
/// The first chunk is preallocated at construction for the time route so the
/// steady-state sleep path performs no shim allocation.
const slots_per_chunk: usize = 64;

/// Chunk ceiling: at most `max_chunks * slots_per_chunk` (65536) concurrent
/// time-route operations per instance. Growth past the ceiling is a resource
/// refusal latched as `OutOfMemory`, not overload.
const max_chunks: usize = 1024;

/// One non-moving block of the slot table.
const SlotChunk = struct {
    slots: [slots_per_chunk]Slot,
};

/// Encode a slot identity as the port's opaque timer `udata`.
pub fn slotUdata(index: u32, generation: u32) ?*anyopaque {
    comptime {
        if (@bitSizeOf(usize) < 64) @compileError("born.io time route needs a 64-bit usize");
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
// P5.3 generalizes the P5.2 timer engine to network operations without
// touching the timer machinery above. The network engine mirrors it: a
// caller-owned `NetOp` node, a non-moving net-op slot table with a cancel
// list and deferred free, and a sole-driver loop. A separate socket registry
// maps the raw std handle to a stable `SocketState` (the `PlainNb` plus its
// pending ops and a generation for stale-event rejection). The loop thread is
// shared: `loopMain` drives timer fires and socket events in one `wait`.

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
/// stack-allocated by the submitter. Ownership follows `SleepOp`: the submitter
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
    /// Loop sets this before the terminal store for a cancel/stop/close drain.
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
    /// Windows: cancelAndClose issued, draining completions before free.
    closing: bool = false,
    /// Windows: shutdown(.recv/.both) issued. shutdown() does not complete a
    /// pending overlapped WSARecv, so netShutdown cancels it and the loop maps
    /// the abort completion (or a recv posted after shutdown) to EOF.
    shutdown_recv: std.atomic.Value(bool) = .init(false),
};

/// Sockets per registry chunk. `SocketState` embeds a `PlainNb`, which on
/// Windows carries two 16 KiB buffers, so chunks are smaller than the timer
/// table's to bound the preallocated footprint.
const sock_per_chunk: usize = 16;
const max_sock_chunks: usize = 4096;

const SockChunk = struct {
    socks: [sock_per_chunk]SocketState,
};

/// Tag bit distinguishing a connect-deadline timer `udata` from a sleep timer
/// `udata` in the shared `ev.timer` dispatch. The tag is decisive: a net-tagged
/// fire goes only to `connectDeadlineFired` (a stale one is dropped there), and
/// sleep generations are masked to 31 bits so a sleep udata can never carry it.
const net_timer_bit: u64 = 1 << 63;
/// Sleep generations stay below bit 31, which `slotUdata` shifts into bit 63
/// (the network tag). Wrapping at 2^31 reuses keeps the tag space disjoint.
const sleep_generation_mask: u32 = 0x7fff_ffff;
/// Connect-deadline timer ids live in the high half of the u32 id space so they
/// never collide with sleep timer ids (timer slot indices, < 65536).
const net_timer_id_base: u32 = 0x8000_0000;

/// Encode a connect-deadline timer identity (registry index + generation) with
/// the network tag bit set.
fn netTimerUdata(index: u32, generation: u32) ?*anyopaque {
    const base: u64 = @intCast(@intFromPtr(slotUdata(index, generation)));
    return @ptrFromInt(@as(usize, @intCast(base | net_timer_bit)));
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

/// Result of a successful submission: the assigned slot and whether the
/// queue went from empty to non-empty (the only case that needs a wake).
const SubmitResult = struct { index: u32, was_empty: bool };

/// The composite carried by the single `Io.userdata` pointer.
pub const Shim = struct {
    /// Born's event port. With the time route enabled the loop thread is its
    /// sole driver; the baseline leaves it untouched.
    port: *born.EvPort,
    allocator: std.mem.Allocator,
    capabilities: Capabilities,
    threaded: Io.Threaded,
    threaded_io: Io,
    /// The time route's loop thread; null on the all-Threaded baseline.
    loop: ?std.Thread = null,
    /// Set by `deinit`; the loop retires every pending operation and exits.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Submission queue: intrusive FIFO of caller-owned `SleepOp` nodes. The
    /// mutex critical sections are O(1) per node (push, or swap out the whole
    /// list); the loop never holds it across `wait`. Locking is uncancelable:
    /// a canceled holder must not strand the list. `dead` is set by the loop
    /// on exit, after which submissions are rejected at the slot. The same
    /// mutex protects the slot table's occupancy, generation, free list and
    /// cancel list.
    queue: struct {
        mutex: Io.Mutex = .init,
        head: ?*SleepOp = null,
        tail: ?*SleepOp = null,
        dead: bool = false,
    } = .{},
    /// Loop-owned slot table: fixed-size chunks that never move, so the
    /// loop's readers never chase a reallocation. Chunk pointers are
    /// published with release under the queue mutex at growth and loaded
    /// with acquire; `chunk_count` is mutex-protected. Freed at deinit after
    /// the loop joins.
    chunks: [max_chunks]std.atomic.Value(?*SlotChunk) = @splat(.init(null)),
    chunk_count: usize = 0,
    free_head: ?u32 = null,
    /// Cancel requests: slot indices linked through `Slot.cancel_next`,
    /// pushed by submitters under the queue mutex, drained by the loop.
    cancel_head: ?u32 = null,
    /// First route-level failure (wait refusal, timer-arm refusal, slot
    /// growth refusal), as `@intFromError`; 0 = none. First writer wins.
    loop_error: std.atomic.Value(u16) = .init(0),
    /// Latency breakdown accumulators (nanoseconds, monotonic), fed by the
    /// submitter after each completed sleep; read via `timeStats`.
    stats: struct {
        ops: std.atomic.Value(u64) = .init(0),
        wakes: std.atomic.Value(u64) = .init(0),
        submit_wake: std.atomic.Value(u64) = .init(0),
        queue_arm: std.atomic.Value(u64) = .init(0),
        timer_span: std.atomic.Value(u64) = .init(0),
        futex_return: std.atomic.Value(u64) = .init(0),
    } = .{},

    // ------------------------------------------------ network route state ----

    /// Network submission queue: intrusive FIFO of caller-owned `NetOp` nodes,
    /// the same discipline as the timer `queue` (O(1) critical sections, never
    /// held across `wait`, uncancelable, `dead` after the loop exits). Its mutex
    /// also protects the net-op slot table's occupancy, free list and cancel list.
    net_queue: struct {
        mutex: Io.Mutex = .init,
        head: ?*NetOp = null,
        tail: ?*NetOp = null,
        dead: bool = false,
    } = .{},
    /// Loop-owned net-op slot table (non-moving chunks), mirroring `chunks`.
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

    /// Resolve a slot index to its stable storage. The chunk pointer was
    /// published with release at growth; the acquire load pairs with it.
    /// Cross-thread access to the slot's fields still follows the queue
    /// mutex discipline (or loop-only ownership).
    fn slotAt(self: *Shim, index: u32) *Slot {
        const chunk = self.chunks[index / slots_per_chunk].load(.acquire).?;
        return &chunk.slots[index % slots_per_chunk];
    }

    /// Allocate one chunk, thread its slots onto the free list (last first,
    /// so allocation hands out ascending indices) and publish the pointer
    /// with release. Queue mutex held, or construction before the loop
    /// starts. The ceiling is a named resource bound, not overload.
    fn growLocked(self: *Shim) error{OutOfMemory}!void {
        if (self.chunk_count >= max_chunks) return error.OutOfMemory;
        const chunk = self.allocator.create(SlotChunk) catch return error.OutOfMemory;
        // The loop below initializes every slot before publication.
        chunk.* = .{ .slots = undefined };
        const base = self.chunk_count * slots_per_chunk;
        var i: usize = slots_per_chunk;
        while (i > 0) {
            i -= 1;
            chunk.slots[i] = .{ .next_free = self.free_head };
            self.free_head = @intCast(base + i);
        }
        self.chunks[self.chunk_count].store(chunk, .release);
        self.chunk_count += 1;
    }

    /// Take a free slot, growing the table by one chunk if needed. Queue
    /// mutex held.
    fn allocSlotLocked(self: *Shim) error{OutOfMemory}!u32 {
        if (self.free_head == null) try self.growLocked();
        const head = self.free_head.?;
        self.free_head = self.slotAt(head).next_free;
        return head;
    }

    /// Queue mutex held: return a retired slot to the free list. Only called
    /// once the slot is off the cancel list (see `retireLocked`).
    fn freeSlotLocked(self: *Shim, index: u32) void {
        const slot = self.slotAt(index);
        slot.next_free = self.free_head;
        self.free_head = index;
    }

    /// Free every published chunk. Only safe once the loop has joined
    /// (deinit) or before it starts (construction error path, tests).
    fn freeChunks(self: *Shim) void {
        for (&self.chunks) |*c| {
            if (c.load(.monotonic)) |chunk| self.allocator.destroy(chunk);
        }
    }

    /// Enqueue a caller-owned node into a fresh slot. Returns null after the
    /// loop has exited (`queue.dead`) or on a slot-table growth refusal; the
    /// caller then reports `error.Canceled` at the slot.
    fn submit(self: *Shim, op: *SleepOp) ?SubmitResult {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        defer self.queue.mutex.unlock(self.threaded_io);
        if (self.queue.dead) return null;
        const index = self.allocSlotLocked() catch {
            self.latch(error.OutOfMemory);
            return null;
        };
        const slot = self.slotAt(index);
        slot.op = op;
        slot.generation = (slot.generation +% 1) & sleep_generation_mask;
        // Defensive: a free slot is always off the cancel list with a null
        // link (drain clears both before freeing), so this cannot truncate.
        slot.cancel_next = null;
        op.slot_index = index;
        op.next = null;
        const was_empty = self.queue.head == null;
        if (self.queue.tail) |tail| tail.next = op else self.queue.head = op;
        self.queue.tail = op;
        return .{ .index = index, .was_empty = was_empty };
    }

    /// Push the node's slot on the cancel list, unless the loop already
    /// retired it (occupancy is checked under the mutex, and retirement frees
    /// under the same mutex, so the check cannot race) or the slot is already
    /// linked (a double push would corrupt the list). Returns whether the
    /// cancel list went from empty to non-empty.
    fn requestCancel(self: *Shim, op: *SleepOp) bool {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        defer self.queue.mutex.unlock(self.threaded_io);
        const slot = self.slotAt(op.slot_index);
        if (slot.op != op) return false;
        if (slot.on_cancel_list) return false;
        const was_empty = self.cancel_head == null;
        slot.cancel_next = self.cancel_head;
        slot.on_cancel_list = true;
        self.cancel_head = op.slot_index;
        return was_empty;
    }

    /// The loop thread: sole driver of the port for both the time and network
    /// routes. Each cycle drains the timer cancel list and swaps out the timer
    /// submission queue, then the network cancel list and queue; arms the
    /// swapped timer nodes and drives the swapped network ops (try-before-park);
    /// blocks in `wait`; dispatches timer fires and socket events. Retires
    /// everything on stop or persistent port failure.
    fn loopMain(self: *Shim) void {
        var events: [64]born.Event = undefined;
        var fail_streak: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            const batch = self.drainLocked();
            self.armBatch(batch);
            const net_batch = self.netDrainLocked();
            self.netArmBatch(net_batch);
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
                if (ev.timer) {
                    const raw: u64 = @intCast(@intFromPtr(ev.udata.?));
                    if (raw & net_timer_bit != 0) {
                        // The tag is decisive: a connect deadline, live or
                        // stale, never reaches the sleep timer path.
                        _ = self.connectDeadlineFired(ev.udata);
                    } else self.timerFired(ev.udata);
                } else if (ev.wake) {
                    // Cross-thread wakeup only; the queues were drained above.
                } else {
                    self.socketEvent(ev);
                }
            }
        }
        const stopped = self.stopping.load(.acquire);
        self.retireAll();
        self.netRetireAll(stopped);
    }

    /// One critical section: drain the cancel list, then swap out the whole
    /// submission list. Cancel entries for queued (not yet armed) nodes are
    /// left to `armOrRetire`'s `cancel_requested` check; entries for slots
    /// retired by fire free the deferred slot. Links live in the slot table,
    /// so walking them never touches caller storage.
    fn drainLocked(self: *Shim) ?*SleepOp {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        var idx = self.cancel_head;
        self.cancel_head = null;
        while (idx) |i| {
            const slot = self.slotAt(i);
            const next = slot.cancel_next;
            slot.cancel_next = null;
            slot.on_cancel_list = false;
            if (slot.op) |op| {
                if (slot.armed) {
                    self.port.cancelTimer(i);
                    slot.armed = false;
                    self.retireLocked(op, i, true);
                    // Cancel drain is the cold path: wake under the mutex.
                    self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &op.state.raw, 1);
                }
                // Occupied but not armed: the node is in the submission
                // queue swapped out below; armOrRetire retires it via the
                // cancel_requested check.
            } else {
                // Retired by fire while this entry was pending: the slot
                // was deferred, free it now.
                self.freeSlotLocked(i);
            }
            idx = next;
        }
        const head = self.queue.head;
        self.queue.head = null;
        self.queue.tail = null;
        self.queue.mutex.unlock(self.threaded_io);
        return head;
    }

    /// Arm or retire each swapped-out node on the loop thread, outside the
    /// mutex. The slot occupancy was established at submit, so no other
    /// thread can retire these nodes while the loop owns them.
    fn armBatch(self: *Shim, head: ?*SleepOp) void {
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.armOrRetire(op);
            node = next;
        }
    }

    /// Mark the queue dead and retire every queued and armed operation as
    /// canceled. Runs on the loop thread just before it exits; after this,
    /// submissions are rejected under the same mutex, so no node can be
    /// enqueued into a queue nobody drains.
    fn retireAll(self: *Shim) void {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        self.queue.dead = true;
        const head = self.queue.head;
        self.queue.head = null;
        self.queue.tail = null;
        // Drain the cancel list: clear the links and free slots already
        // retired by fire; occupied ones are freed by the scan below.
        var idx = self.cancel_head;
        self.cancel_head = null;
        while (idx) |i| {
            const slot = self.slotAt(i);
            const next = slot.cancel_next;
            slot.cancel_next = null;
            slot.on_cancel_list = false;
            if (slot.op == null) self.freeSlotLocked(i);
            idx = next;
        }
        const chunk_count = self.chunk_count;
        self.queue.mutex.unlock(self.threaded_io);
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.retire(op, true);
            node = next;
        }
        var ci: usize = 0;
        while (ci < chunk_count) : (ci += 1) {
            const chunk = self.chunks[ci].load(.acquire).?;
            for (&chunk.slots, 0..) |*slot, si| {
                if (slot.op) |op| {
                    const index: u32 = @intCast(ci * slots_per_chunk + si);
                    if (slot.armed) self.port.cancelTimer(index);
                    self.retire(op, true);
                }
            }
        }
    }

    /// Publish the terminal state and free the slot under the queue mutex
    /// (retirement must be atomic with the cancel path's occupancy check),
    /// then wake the submitter's futex wait outside the mutex. The wake is
    /// an address-keyed kernel operation that never reads the word, so it
    /// is safe after the submitter observes the terminal state and returns:
    /// the store precedes the wake (no lost wakeup), and a wake that lands
    /// on a reused stack frame is a spurious wake the completion retry loop
    /// already tolerates. Keeping the wake syscall out of the critical
    /// section is what keeps 64 submitters from serializing on it.
    fn retire(self: *Shim, op: *SleepOp, canceled: bool) void {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        self.retireLocked(op, op.slot_index, canceled);
        self.queue.mutex.unlock(self.threaded_io);
        self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &op.state.raw, 1);
    }

    /// Queue mutex held: terminal store plus slot release, no wake. After the
    /// terminal store the submitter may return and reuse its frame: no
    /// field of the node is read or written past this point. A slot still
    /// linked on the cancel list is not freed: its entry must drain first,
    /// or a reallocation would reset `cancel_next` and truncate the list.
    fn retireLocked(self: *Shim, op: *SleepOp, index: u32, canceled: bool) void {
        op.outcome_canceled = canceled;
        op.state.store(1, .release);
        const slot = self.slotAt(index);
        slot.op = null;
        slot.armed = false;
        if (!slot.on_cancel_list) self.freeSlotLocked(index);
    }

    fn armOrRetire(self: *Shim, op: *SleepOp) void {
        if (op.cancel_requested.load(.acquire)) return self.retire(op, true);
        const now_ns = born.nowNs() catch return self.retire(op, false);
        if (now_ns >= op.deadline_ns) return self.retire(op, false);
        self.arm(op, op.deadline_ns - now_ns);
    }

    /// Arm a one-shot timer for the remaining time. Born timers have
    /// millisecond granularity: round up so a sleep never returns early, and
    /// clamp to the u32 ms ceiling; `timerFired` re-arms the remainder for
    /// longer sleeps. An arm refusal retires the operation as canceled and
    /// latches the cause: `error{Canceled}` is the only error `sleep`'s
    /// declared set admits (module overload table). Loop-thread only.
    fn arm(self: *Shim, op: *SleepOp, remaining_ns: u64) void {
        const index = op.slot_index;
        const slot = self.slotAt(index);
        // The slot was allocated under the queue mutex and dequeued under
        // the same mutex, so the submitter's generation write happens-before
        // this read; while occupied, no other thread writes it.
        self.port.addTimer(index, slotUdata(index, slot.generation), ceilMs(remaining_ns), .once) catch |err| {
            self.latch(err);
            return self.retire(op, true);
        };
        slot.armed = true;
        if (time_stats_enabled) {
            if (op.t_arm_ns == 0) op.t_arm_ns = born.nowNs() catch 0;
        }
    }

    /// Handle one timer fire. The identity refers to the loop-owned slot
    /// table: drop the event if the chunk is unpublished, the slot is free,
    /// or the generation does not match, and only then touch the node.
    /// (op, generation) are snapshotted under the queue mutex because a
    /// submitter may be handing a freed slot to a new node concurrently.
    /// After the snapshot occupancy is stable: only this thread retires
    /// occupied slots, and reallocation requires retirement first.
    /// Loop-thread only.
    fn timerFired(self: *Shim, udata: ?*anyopaque) void {
        const id = decodeSlotUdata(udata);
        const chunk_index = id.index / slots_per_chunk;
        if (chunk_index >= max_chunks) return;
        const snap = blk: {
            self.queue.mutex.lockUncancelable(self.threaded_io);
            defer self.queue.mutex.unlock(self.threaded_io);
            const chunk = self.chunks[chunk_index].load(.acquire) orelse break :blk null;
            const slot = &chunk.slots[id.index % slots_per_chunk];
            const op = slot.op orelse break :blk null;
            if (slot.generation != id.generation) break :blk null;
            break :blk .{ .slot = slot, .op = op };
        };
        const s = snap orelse return;
        const slot = s.slot;
        const op = s.op;
        // A `.once` timer is retired by the port when it fires.
        slot.armed = false;
        // Functional timestamp: the re-arm remainder decision below reads
        // it, so it is recorded even when latency stats are off.
        op.t_fire_ns = born.nowNs() catch 0;
        if (op.cancel_requested.load(.acquire)) return self.retire(op, true);
        const now_ns = op.t_fire_ns;
        if (now_ns == 0 or now_ns >= op.deadline_ns) return self.retire(op, false);
        // Re-arm the remainder under the same identity; the slot stays
        // occupied, so the generation is unchanged.
        self.port.addTimer(id.index, udata, ceilMs(op.deadline_ns - now_ns), .once) catch |err| {
            self.latch(err);
            return self.retire(op, true);
        };
        slot.armed = true;
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
        return was_empty;
    }

    /// One critical section: drain the network cancel list, then swap out the
    /// whole submission list. Driven ops on the cancel list are chained for
    /// disarm/retire/wake OUTSIDE the mutex (port calls and futexWake must not
    /// lengthen the submitter-facing lock, the `netRetireOp` shape); entries
    /// for ops still in the swapped queue are left to `netArmOrRetire`'s
    /// `cancel_requested` check.
    fn netDrainLocked(self: *Shim) ?*NetOp {
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

    /// Retire one op at loop exit: canceled for a stop request or an op whose
    /// submitter already requested cancellation, route_dead otherwise. A
    /// failure exit is not the caller's cancellation; the thunks map route_dead
    /// to Unexpected so a consumer sees the dead route instead of a quiet stop.
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
    /// queue mutex, then wake the submitter outside it (the P5.2 retire shape).
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

    /// Submitter-side completion wait for a network op, the same retry shape as
    /// `time_route.sleep`: enqueue, conditional wake, cancelable futex wait,
    /// and on cancellation request the disarm then drain uncancelably until the
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
            const is_born = if (handle) |h| self.lookupBorn(h) != null else false;
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
    /// past the chunk ceiling or the chunk was never published. The ceiling
    /// guard mirrors `timerFired`: a stale event udata must drop before any
    /// table access. Lock-free acquire load; field access follows the registry
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
        state.next_free = self.registry.free_head;
        self.registry.free_head = index;
    }

    fn sockFreeChunks(self: *Shim) void {
        for (&self.registry.chunks) |*c| {
            if (c.load(.monotonic)) |chunk| self.allocator.destroy(chunk);
        }
    }

    /// Release the registry map and socket chunks. Called at deinit after the
    /// loop has closed every remaining socket, and on construction failure.
    fn registryDeinit(self: *Shim) void {
        if (!self.registry.initialized) return;
        self.registry.map.deinit();
        self.sockFreeChunks();
        self.registry.initialized = false;
    }

    /// Submit-time provenance gate: resolve a std handle to its registry index,
    /// or null if it is not Born-owned (forward to Threaded). Registry mutex.
    fn lookupBorn(self: *Shim, handle: born.Handle) ?u32 {
        self.registry.mutex.lockUncancelable(self.threaded_io);
        defer self.registry.mutex.unlock(self.threaded_io);
        if (!self.registry.initialized) return null;
        return self.registry.map.get(handle);
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

    /// Retire a socket on the loop thread: drop the handle mapping BEFORE the
    /// descriptor closes, so a reused fd/SOCKET value opened by another thread
    /// (a Threaded accept or connect in the same process) never resolves to this
    /// dying slot. POSIX purges staged registrations then closes and frees.
    /// Windows cancels/closes and keeps the slot occupied/closing until
    /// socketEvent absorbs every completion (the stable OVERLAPPED storage must
    /// outlive the drain); the generation guard still protects late completions.
    fn sockRetire(self: *Shim, state: *SocketState, index: u32) void {
        self.unregisterHandle(state.handle, index);
        if (is_windows) {
            state.plain.cancelAndClose();
            state.closing = true;
            if (state.plain.pendingOps() == 0) self.sockFree(state, index);
        } else {
            self.port.purgeFd(state.handle);
            state.plain.deinit();
            self.sockFree(state, index);
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
    fn registryCloseAll(self: *Shim) void {
        if (!self.registry.initialized) return;
        const chunk_count = self.registry.chunk_count;
        var ci: usize = 0;
        while (ci < chunk_count) : (ci += 1) {
            const chunk = self.registry.chunks[ci].load(.acquire).?;
            for (&chunk.socks, 0..) |*state, si| {
                if (state.occupied) {
                    const index: u32 = @intCast(ci * sock_per_chunk + si);
                    self.sockRetire(state, index);
                }
            }
        }
        if (is_windows) {
            var events: [64]born.Event = undefined;
            while (self.registryPendingOps() != 0) {
                const n = self.port.wait(&events, null) catch break;
                for (events[0..n]) |ev| {
                    if (ev.timer or ev.wake) continue;
                    self.socketEvent(ev);
                }
            }
        }
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
        state.closing = false;
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
                    state.plain.startConnectAddrInto(addr, self.port, udata) catch |err| break :blk switch (err) {
                        error.ConnectFailed => NetError.connect_refused,
                        error.SocketError => NetError.connect_setup,
                    };
                },
                .unix => |path| {
                    state.plain.startConnectUnixInto(self.allocator, path, self.port, udata) catch |err| break :blk switch (err) {
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
                self.port.addTimer(net_timer_id_base + op.slot_index, netTimerUdata(index, state.generation), ceilMs(c.deadline_ns - now_ns), .once) catch |err| {
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
        if (state.closing) return self.netRetireErr(op, .read_failed);
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
        if (state.closing) return self.netRetireErr(op, .write_failed);
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
                    return;
                },
                .want_read => return self.netRetireErr(op, .write_failed),
            }
        }
    }

    /// Close a Born-owned socket: cancel and drain every pending op, then
    /// retire the socket (unregister before close; Windows keeps the stable
    /// SocketState alive until every completion is absorbed, 4.4).
    fn closeDrive(self: *Shim, op: *NetOp) void {
        const state = self.sockSnapshot(op.sock_index) orelse return self.netRetireOk(op, 0, false);
        if (state.pending_read) |rop| {
            rop.result.err = .canceled;
            self.netRetireOp(rop, true);
        }
        if (state.pending_write) |wop| {
            wop.result.err = .canceled;
            self.netRetireOp(wop, true);
        }
        if (state.pending_connect) |cop| {
            cop.result.err = .canceled;
            self.netRetireOp(cop, true);
        }
        self.sockRetire(state, op.sock_index);
        self.netRetireOk(op, 0, false);
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
            if (s.closing and s.plain.pendingOps() == 0) self.sockFree(s, id.index);
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
};

/// Milliseconds for a remaining nanosecond span, rounded up so a sleep never
/// returns early, clamped to the port's u32 ms ceiling. `remaining_ns` > 0.
pub fn ceilMs(remaining_ns: u64) u32 {
    const ms = (remaining_ns +| (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    return @intCast(@min(ms, std.math.maxInt(u32)));
}

/// Builds a `std.Io` over Born's event port. The returned interface owns a
/// heap-allocated composite; release it with `deinit`. A Born route
/// (`capabilities.time` or `capabilities.network = .born_evented`) spawns the
/// Scale model loop thread and services that family on Born; the caller must
/// not drive the port itself afterwards. The time route services `sleep` and
/// monotonic `now`; the network route services the client path (IP and pathname
/// Unix connect, stream read/write, close, shutdown). Born routes for the file
/// and process families are still rejected at construction.
pub fn io(port: *born.EvPort, opts: InitOptions) InitError!Io {
    const caps = opts.capabilities;
    if (caps.file == .born_evented or caps.process == .born_evented)
        return error.CapabilityUnsupported;
    const time_born = caps.time == .born_evented;
    const net_born = caps.network == .born_evented;
    // The Born routes need a loop thread; a single-threaded build cannot host
    // one, so the profile is rejected rather than silently degraded.
    if ((time_born or net_born) and builtin.single_threaded)
        return error.CapabilityUnsupported;
    const shim = opts.allocator.create(Shim) catch return error.OutOfMemory;
    errdefer opts.allocator.destroy(shim);
    shim.* = .{
        .port = port,
        .allocator = opts.allocator,
        .capabilities = caps,
        .threaded = Io.Threaded.init(opts.allocator, opts.threaded),
        .threaded_io = undefined,
    };
    shim.threaded_io = shim.threaded.io();
    errdefer shim.threaded.deinit();
    if (time_born or net_born) {
        // Preallocate the first chunk of each active route so its steady-state
        // path performs no shim allocation; growth beyond capacity is on demand.
        if (time_born) shim.growLocked() catch return error.OutOfMemory;
        errdefer shim.freeChunks();
        if (net_born) {
            shim.netGrowLocked() catch return error.OutOfMemory;
            shim.registryInit() catch return error.OutOfMemory;
        }
        errdefer shim.netFreeChunks();
        errdefer shim.registryDeinit();
        shim.loop = std.Thread.spawn(.{}, Shim.loopMain, .{shim}) catch return error.LoopSpawnFailed;
    }
    return .{
        .userdata = shim,
        .vtable = if (time_born and net_born)
            &time_network_vtable
        else if (time_born)
            &time_vtable
        else if (net_born)
            &network_vtable
        else
            &baseline_vtable,
    };
}

/// Releases the composite created by `io`. As with `Io.Threaded`, every task
/// must have been awaited or canceled first. Stops and joins the Born route's
/// loop thread first (retiring any operation still pending as canceled and
/// closing any remaining registered socket): the loop calls into Threaded until
/// it exits. Then joins the Threaded pool and frees the composite.
pub fn deinit(interface: Io) void {
    const shim = shimFrom(interface.userdata);
    const allocator = shim.allocator;
    if (shim.loop) |loop| {
        shim.stopping.store(true, .release);
        shim.port.wake();
        loop.join();
    }
    shim.threaded.deinit();
    shim.freeChunks();
    shim.netFreeChunks();
    shim.registryDeinit();
    allocator.destroy(shim);
}

/// The first route-level failure latched by the time route: a port `wait`
/// refusal, a timer-arm refusal (`born.TimerError`), or a slot-table growth
/// refusal. `sleep` surfaces these as `error.Canceled` (its declared set
/// admits no resource error); this accessor exposes the cause so an
/// application can tell a failed or dead time route from ordinary
/// cancellation. Returns null while no failure has occurred. The loop exits
/// after `wait_fail_limit` consecutive wait failures; once it has, every
/// later `sleep` returns `Canceled` immediately. The baseline route never
/// latches and always returns null.
pub fn loopError(interface: Io) ?anyerror {
    return shimFrom(interface.userdata).latchedError();
}

/// Latency breakdown of completed Born-route sleeps, accumulated since
/// construction (monotonic nanosecond sums over `ops` operations). Phases:
/// `submit_wake_ns` is the submitter side (enqueue plus the conditional
/// wake); `queue_arm_ns` spans enqueue to first arm and INCLUDES
/// `submit_wake_ns`, so the loop-side handoff (queue wait, drain, arm) is
/// their difference; `timer_span_ns` is armed time including the requested
/// sleep (kernel slack is the span minus the request); `futex_return_ns` is
/// the completion handoff back to the submitter. `wakes` counts port wake
/// calls, which fire only on empty-to-non-empty queue transitions. Canceled
/// sleeps are not counted. The baseline route reports zeros. With the
/// `time_stats` build option off (the default), no accumulator is ever
/// written and every field reports zero.
pub const TimeStats = struct {
    ops: u64,
    wakes: u64,
    submit_wake_ns: u64,
    queue_arm_ns: u64,
    timer_span_ns: u64,
    futex_return_ns: u64,
};

/// Snapshot of the time route's latency breakdown accumulators. Reports
/// zeros when the `time_stats` build option is off.
pub fn timeStats(interface: Io) TimeStats {
    if (!time_stats_enabled) return .{
        .ops = 0,
        .wakes = 0,
        .submit_wake_ns = 0,
        .queue_arm_ns = 0,
        .timer_span_ns = 0,
        .futex_return_ns = 0,
    };
    const s = &shimFrom(interface.userdata).stats;
    return .{
        .ops = s.ops.load(.monotonic),
        .wakes = s.wakes.load(.monotonic),
        .submit_wake_ns = s.submit_wake.load(.monotonic),
        .queue_arm_ns = s.queue_arm.load(.monotonic),
        .timer_span_ns = s.timer_span.load(.monotonic),
        .futex_return_ns = s.futex_return.load(.monotonic),
    };
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

/// Born evented implementations of the time family. Every other slot keeps
/// its baseline forwarding thunk; `time_vtable` is a comptime copy of the
/// baseline with only these slots replaced, so the two cannot drift.
const time_route = struct {
    /// Sleep on Born's timers. `.none` returns immediately (Threaded's
    /// semantics); a `Clock` other than `.awake` is explicitly delegated to
    /// Threaded because Born's timers measure the monotonic timer clock only.
    /// The submission node is caller-owned stack storage: the queue cannot
    /// overflow (module overload table). The timer identity is a loop-owned
    /// slot, so a stale fire never touches this frame. Completion returns
    /// through a cancelable Threaded futex wait; cancellation pushes the slot
    /// on the loop's cancel list and drains until the node is retired.
    fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const self = shimFrom(userdata);
        const clock: Io.Clock = switch (timeout) {
            .none => return,
            .duration => |d| d.clock,
            .deadline => |d| d.clock,
        };
        if (clock != .awake) return fwd.sleep(userdata, timeout);

        // A refused clock read ends the sleep as elapsed, the same treatment
        // Threaded's sleepPosix gives a clock_nanosleep refusal; callers can
        // probe clockResolution first.
        const now_ns = born.nowNs() catch return;
        const t0 = now_ns;
        const deadline_ns: u64 = switch (timeout) {
            .none => unreachable,
            .duration => |d| blk: {
                if (d.raw.nanoseconds <= 0) return;
                const ns: u64 = @intCast(@min(d.raw.nanoseconds, @as(i96, std.math.maxInt(u64))));
                break :blk now_ns +| ns;
            },
            .deadline => |d| blk: {
                if (d.raw.nanoseconds <= @as(i96, @intCast(now_ns))) return;
                break :blk @intCast(@min(d.raw.nanoseconds, @as(i96, std.math.maxInt(u64))));
            },
        };

        var op: SleepOp = .{ .deadline_ns = deadline_ns };
        const submitted = self.submit(&op) orelse return error.Canceled;
        if (submitted.was_empty) {
            if (time_stats_enabled) _ = self.stats.wakes.fetchAdd(1, .monotonic);
            self.port.wake();
        }
        // Submitter-side phase timestamps are locals: the loop owns the node
        // from dequeue, so writing them into the node after enqueue would
        // race the loop's arm. t0 (captured before submit) is the enqueue
        // timestamp; the loop can only arm after dequeue, so t_arm >= t0.
        const t_wake_done = if (time_stats_enabled) born.nowNs() catch 0 else 0;

        // Completion wait: the same retry shape Threaded's await uses. A
        // spurious wake re-checks the state word; a pending cancel surfaces
        // as error.Canceled from the next futex wait's syscall entry.
        while (true) {
            self.threaded_io.vtable.futexWait(self.threaded_io.userdata, &op.state.raw, 0, .none) catch |err| switch (err) {
                error.Canceled => {
                    // Request the disarm, then drain uncancelably until the
                    // loop retires the node: it must never touch this stack
                    // storage after we return.
                    op.cancel_requested.store(true, .release);
                    if (self.requestCancel(&op)) {
                        if (time_stats_enabled) _ = self.stats.wakes.fetchAdd(1, .monotonic);
                        self.port.wake();
                    }
                    while (op.state.load(.acquire) == 0) {
                        self.threaded_io.vtable.futexWaitUncancelable(self.threaded_io.userdata, &op.state.raw, 0);
                    }
                    return error.Canceled;
                },
            };
            if (op.state.load(.acquire) != 0) break;
        }
        if (op.outcome_canceled) return error.Canceled;
        // Latency breakdown: only completed sleeps with a recorded arm/fire
        // pair contribute. Every delta is non-negative by capture order: t0
        // precedes enqueue, arm follows dequeue, fire follows arm, and the
        // terminal store (observed above) follows the fire timestamp.
        if (time_stats_enabled) {
            const t_done = born.nowNs() catch 0;
            if (op.t_fire_ns != 0 and op.t_arm_ns != 0 and t_wake_done != 0 and t_done != 0) {
                _ = self.stats.ops.fetchAdd(1, .monotonic);
                _ = self.stats.submit_wake.fetchAdd(t_wake_done - t0, .monotonic);
                _ = self.stats.queue_arm.fetchAdd(op.t_arm_ns - t0, .monotonic);
                _ = self.stats.timer_span.fetchAdd(op.t_fire_ns - op.t_arm_ns, .monotonic);
                _ = self.stats.futex_return.fetchAdd(t_done - op.t_fire_ns, .monotonic);
            }
        }
    }

    /// Monotonic `now` reads Born's timer clock so timestamps and sleep
    /// deadlines share one clock. Other Clock tags delegate to Threaded. A
    /// refused clock returns Timestamp.zero, matching Threaded's contract
    /// for an unavailable clock (the slot is infallible).
    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        if (clock == .awake) {
            const ns = born.nowNs() catch return .zero;
            return .{ .nanoseconds = @intCast(ns) };
        }
        return fwd.now(userdata, clock);
    }
};

/// The time-route vtable: the baseline with `sleep` and `now` serviced by
/// Born. Every other slot is byte-identical to the baseline by construction.
pub const time_vtable: Io.VTable = blk: {
    var v = baseline_vtable;
    v.sleep = time_route.sleep;
    v.now = time_route.now;
    break :blk v;
};

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
        if (self.lookupBorn(handle) == null) return fwd.netShutdown(userdata, handle, how);
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
        _ = self.batchPartitionBorn(batch);
        if (batch.submitted.head == .none) return;
        return fwd.batchAwaitAsync(userdata, batch);
    }

    fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        const self = shimFrom(userdata);
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
        const index = self.lookupBorn(src) orelse {
            if (network_stats_enabled) _ = self.net_stats.threaded_read.fetchAdd(1, .monotonic);
            return fwd016.netRead(userdata, src, data);
        };
        var op: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = data } } };
        try self.netWait(&op);
        if (op.result.err) |e| return mapIoError(e);
        return op.result.count; // 0 on EOF; the Reader converts it to EndOfStream
    }

    fn netWrite(userdata: ?*anyopaque, dest: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
        const self = shimFrom(userdata);
        const index = self.lookupBorn(dest) orelse {
            if (network_stats_enabled) _ = self.net_stats.threaded_write.fetchAdd(1, .monotonic);
            return fwd016.netWrite(userdata, dest, header, data, splat);
        };
        var op: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = header, .data = data, .splat = splat } } };
        try self.netWait(&op);
        if (op.result.err) |e| return mapIoError(e);
        return op.result.count;
    }

    /// Message send is excluded by the stream-only profile: a Born-owned handle
    /// completes with the per-message tag result error.Unexpected (section 8).
    fn netSend(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
        const self = shimFrom(userdata);
        if (self.lookupBorn(handle) == null) return fwd016.netSend(userdata, handle, messages, flags);
        return .{ error.Unexpected, 0 };
    }

    fn netClose(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
        const self = shimFrom(userdata);
        for (handles) |h| {
            if (self.lookupBorn(h)) |index| {
                var op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
                self.netCloseWait(&op);
            } else {
                const one: [1]Io.net.Socket.Handle = .{h};
                fwd016.netClose(userdata, &one);
            }
        }
    }

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = shimFrom(userdata);
        switch (operation) {
            .net_receive => |o| {
                if (self.lookupBorn(o.socket_handle) == null) return fwd.operate(userdata, operation);
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
        for (sockets) |s| {
            if (self.lookupBorn(s.handle)) |index| {
                var op: NetOp = .{ .kind = .close, .sock_index = index, .payload = .{ .close = {} } };
                self.netCloseWait(&op);
            } else {
                const one: [1]Io.net.Socket = .{s};
                fwd017.netClose(userdata, &one);
            }
        }
    }

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = shimFrom(userdata);
        switch (operation) {
            .net_read => |o| {
                const index = self.lookupBorn(o.socket_handle) orelse {
                    if (network_stats_enabled) _ = self.net_stats.threaded_read.fetchAdd(1, .monotonic);
                    return fwd.operate(userdata, operation);
                };
                // Control-buffer I/O is excluded by the stream-only profile.
                if (o.control.len != 0) return .{ .net_read = error.Unexpected };
                var op: NetOp = .{ .kind = .read, .sock_index = index, .payload = .{ .read = .{ .data = o.data } } };
                try self.netWait(&op);
                if (op.result.err) |e| return .{ .net_read = mapIoError(e) };
                return .{ .net_read = .{ .data_len = op.result.count } };
            },
            .net_write => |o| {
                const index = self.lookupBorn(o.socket_handle) orelse {
                    if (network_stats_enabled) _ = self.net_stats.threaded_write.fetchAdd(1, .monotonic);
                    return fwd.operate(userdata, operation);
                };
                if (o.control.len != 0) return .{ .net_write = error.Unexpected };
                var op: NetOp = .{ .kind = .write, .sock_index = index, .payload = .{ .write = .{ .header = o.header, .data = o.data, .splat = o.splat } } };
                try self.netWait(&op);
                if (op.result.err) |e| return .{ .net_write = mapIoError(e) };
                return .{ .net_write = op.result.count };
            },
            .net_send => |o| {
                if (self.lookupBorn(o.socket_handle) == null) return fwd.operate(userdata, operation);
                return .{ .net_send = .{ error.Unexpected, 0 } };
            },
            .net_receive => |o| {
                if (self.lookupBorn(o.socket_handle) == null) return fwd.operate(userdata, operation);
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

/// The network-route vtable: the baseline with the client-path slots serviced
/// by Born. Listen/accept, DNS lookup, interface naming and batchCancel keep
/// their baseline forwarding thunks (Threaded hybrids / no Born drain needed).
pub const network_vtable: Io.VTable = blk: {
    var v = baseline_vtable;
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
    break :blk v;
};

/// Both Born routes active: the network vtable plus the time-route sleep/now.
pub const time_network_vtable: Io.VTable = blk: {
    var v = network_vtable;
    v.sleep = time_route.sleep;
    v.now = time_route.now;
    break :blk v;
};

test "slot identity round-trips through udata" {
    const id = decodeSlotUdata(slotUdata(123, 456));
    try std.testing.expectEqual(@as(u32, 123), id.index);
    try std.testing.expectEqual(@as(u32, 456), id.generation);
    const max = decodeSlotUdata(slotUdata(std.math.maxInt(u32), std.math.maxInt(u32)));
    try std.testing.expectEqual(std.math.maxInt(u32), max.index);
    try std.testing.expectEqual(std.math.maxInt(u32), max.generation);
}

test "stale timer fires drop without touching the node" {
    // The use-after-free guard: a fire whose generation predates the current
    // occupant, whose slot was freed, whose chunk was never published, or
    // whose index is past the chunk ceiling must be dropped before any
    // access to the caller's node. timerFired snapshots under the queue
    // mutex, so the composite needs a real Threaded.
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    try testGrow(&state, 1);
    defer state.freeChunks();
    const slot = state.slotAt(0);
    var op: SleepOp = .{};

    slot.op = &op;
    slot.generation = 7;
    slot.armed = true;
    // Stale generation: the slot was freed and re-armed for another node.
    state.timerFired(slotUdata(0, 6));
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    try std.testing.expectEqual(&op, slot.op.?);
    try std.testing.expect(slot.armed);
    // Freed slot: retirement already published the terminal state.
    slot.op = null;
    state.timerFired(slotUdata(0, 7));
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    // Unpublished chunk (index 99 lives in chunk 1).
    state.timerFired(slotUdata(99, 7));
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
    // Index past the chunk ceiling.
    state.timerFired(slotUdata(max_chunks * slots_per_chunk, 7));
    try std.testing.expectEqual(@as(u32, 0), op.state.load(.monotonic));
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
}

/// Publish `count` chunks for queue-mechanism unit tests, mirroring
/// construction-time growth (no loop thread runs).
fn testGrow(state: *Shim, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try state.growLocked();
}

test "submit reports only the empty-to-non-empty transition" {
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    try testGrow(&state, 1);
    defer state.freeChunks();

    var a: SleepOp = .{};
    var b: SleepOp = .{};
    const ra = state.submit(&a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ra.was_empty);
    const rb = state.submit(&b) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!rb.was_empty);
    try std.testing.expectEqual(&a, state.queue.head.?);
    try std.testing.expectEqual(&b, state.queue.tail.?);
    try std.testing.expectEqual(&b, a.next.?);
    try std.testing.expectEqual(@as(?*SleepOp, null), b.next);
    try std.testing.expectEqual(@as(u32, 0), a.slot_index);
    try std.testing.expectEqual(@as(u32, 1), b.slot_index);
    try std.testing.expectEqual(@as(u32, 1), state.slotAt(0).generation);
}

test "cancel request skips a retired slot and refuses a double push" {
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    try testGrow(&state, 1);
    defer state.freeChunks();

    const index = try state.allocSlotLocked();
    var op: SleepOp = .{ .slot_index = index };
    state.slotAt(index).op = &op;
    // Occupied: the request pushes and reports the transition.
    try std.testing.expect(state.requestCancel(&op));
    try std.testing.expectEqual(@as(?u32, index), state.cancel_head);
    // Already linked: a second push must not corrupt the list.
    try std.testing.expect(!state.requestCancel(&op));
    try std.testing.expectEqual(@as(?u32, index), state.cancel_head);
    // Retired by fire while the entry is pending: the slot is not freed
    // until the entry drains, so it cannot be reallocated.
    state.retireLocked(&op, index, true);
    try std.testing.expectEqual(@as(?*SleepOp, null), state.slotAt(index).op);
    try std.testing.expectEqual(@as(?u32, index + 1), state.free_head);
    // The occupancy check refuses a push for the retired occupant.
    try std.testing.expect(!state.requestCancel(&op));
    // Drain frees the deferred slot and clears the list.
    _ = state.drainLocked();
    try std.testing.expectEqual(@as(?u32, index), state.free_head);
    try std.testing.expectEqual(@as(?u32, null), state.cancel_head);
    try std.testing.expect(!state.slotAt(index).on_cancel_list);
}

test "slot table grows in non-moving chunks up to the ceiling" {
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    defer state.freeChunks();
    try testGrow(&state, 1);
    const first = state.slotAt(0);
    // Exhaust the first chunk: the next allocation grows a second chunk.
    var last: u32 = 0;
    var i: usize = 0;
    while (i < slots_per_chunk + 1) : (i += 1) {
        last = try state.allocSlotLocked();
    }
    try std.testing.expectEqual(@as(usize, 2), state.chunk_count);
    try std.testing.expectEqual(@as(u32, @intCast(slots_per_chunk)), last);
    // Growth never moved the first chunk's storage.
    try std.testing.expect(first == state.slotAt(0));
    // Fill to the named ceiling; the next allocation is a resource refusal.
    while (state.chunk_count < max_chunks) try state.growLocked();
    while (state.free_head != null) _ = try state.allocSlotLocked();
    try std.testing.expectError(error.OutOfMemory, state.allocSlotLocked());
}

test "fire-retired slot with a pending cancel entry is not reused" {
    // Review 541 B interleaving: a's timer fires and retires it while a's
    // cancel entry is still queued ahead of c's. A new submit must not take
    // a's slot (that would reset cancel_next and drop c's entry), and the
    // drain must still disarm and retire c. Deterministic: no loop thread,
    // the test drives submit/arm/fire/drain in the exact race order.
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    state.port = &port;
    try testGrow(&state, 1);
    defer state.freeChunks();

    const now = try born.nowNs();
    var a: SleepOp = .{ .deadline_ns = now + 10 * std.time.ns_per_s };
    var b: SleepOp = .{ .deadline_ns = now + 10 * std.time.ns_per_s };
    var c: SleepOp = .{ .deadline_ns = now + 10 * std.time.ns_per_s };
    _ = state.submit(&a) orelse return error.TestUnexpectedResult;
    _ = state.submit(&b) orelse return error.TestUnexpectedResult;
    _ = state.submit(&c) orelse return error.TestUnexpectedResult;
    // Dequeue and arm all three as the loop would.
    state.armBatch(state.drainLocked());
    try std.testing.expectEqual(@as(u32, 0), a.slot_index);
    try std.testing.expectEqual(@as(u32, 1), b.slot_index);
    try std.testing.expectEqual(@as(u32, 2), c.slot_index);

    // Cancel entries queue up: c first, then a, so the list is a -> c.
    try std.testing.expect(state.requestCancel(&c));
    try std.testing.expect(!state.requestCancel(&a));

    // a's timer fires and retires it while its cancel entry is pending.
    // The .once registration is gone once the port delivers the fire.
    port.cancelTimer(a.slot_index);
    a.cancel_requested.store(true, .release);
    state.timerFired(slotUdata(a.slot_index, state.slotAt(a.slot_index).generation));
    try std.testing.expectEqual(@as(u32, 1), a.state.load(.acquire));
    try std.testing.expect(state.slotAt(a.slot_index).op == null);
    try std.testing.expect(state.slotAt(a.slot_index).on_cancel_list);
    // Deferred: the retired slot is not on the free list.
    try std.testing.expectEqual(@as(?u32, 3), state.free_head);

    // A new submit must take a different slot: reusing a's slot here would
    // reset cancel_next and drop c's entry behind it.
    var d: SleepOp = .{};
    const rd = state.submit(&d) orelse return error.TestUnexpectedResult;
    try std.testing.expect(rd.index != a.slot_index);
    try std.testing.expectEqual(@as(?u32, a.slot_index), state.cancel_head);
    try std.testing.expectEqual(@as(?u32, c.slot_index), state.slotAt(a.slot_index).cancel_next);

    // Drain: a's entry frees the deferred slot; c's entry still disarms and
    // retires c (freeing c's slot on top). d is swapped out as the new batch.
    const batch = state.drainLocked();
    try std.testing.expectEqual(@as(?*SleepOp, &d), batch);
    try std.testing.expectEqual(@as(u32, 1), c.state.load(.acquire));
    try std.testing.expect(c.outcome_canceled);
    try std.testing.expectEqual(@as(?u32, c.slot_index), state.free_head);
    try std.testing.expectEqual(@as(?u32, a.slot_index), state.slotAt(c.slot_index).next_free);
    try std.testing.expect(!state.slotAt(a.slot_index).on_cancel_list);

    // Only now are the retired slots reusable: c's slot first, then a's.
    var e: SleepOp = .{};
    const re = state.submit(&e) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(c.slot_index, re.index);
    var f: SleepOp = .{};
    const rf = state.submit(&f) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(a.slot_index, rf.index);

    // Cleanup: retire the never-fired sleepers; a and c are already retired.
    port.cancelTimer(b.slot_index);
    state.retire(&b, true);
    state.retire(&d, true);
    state.retire(&e, true);
    state.retire(&f, true);
}

// ------------------------------------------- network mechanism units (P5.3) ----
//
// These drive the network engine's queue, registry and dispatch mechanics
// directly (private access), with a real Threaded for the uncancelable mutex
// and a real EvPort only where a port call is on the path. No loop thread runs:
// the test steps submit/cancel/retire/drain/fire in the exact race order, the
// P5.2 M-series pattern. The per-slot behavioral contracts (connect, read/write,
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
    defer state.threaded.deinit();
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

test "net cancel request skips a retired slot and refuses a double push" {
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
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
    defer state.threaded.deinit();
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
    defer state.threaded.deinit();
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
    defer state.threaded.deinit();
    try state.registryInit();
    defer state.registryDeinit();

    const h100 = testHandle(100);
    const h101 = testHandle(101);
    // A handle absent from the registry is Threaded-owned (lookup miss).
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(h100));
    const idx0 = try state.sockAllocLocked();
    const s0 = state.sockAt(idx0).?;
    s0.generation +%= 1;
    s0.occupied = true;
    s0.handle = h100;
    s0.index = idx0;
    try state.registerHandle(h100, idx0);
    try std.testing.expectEqual(@as(?u32, idx0), state.lookupBorn(h100));
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
    try std.testing.expectEqual(@as(?u32, idx1), state.lookupBorn(h101));
    try std.testing.expectEqual(@as(u32, 1), s1.generation);

    // Reusing handle 100 for a newer socket overwrites the mapping; unregistering
    // the OLD index must not remove the newer entry (stale-fd guard).
    const idx2 = try state.sockAllocLocked();
    try state.registerHandle(h100, idx2);
    try std.testing.expectEqual(@as(?u32, idx2), state.lookupBorn(h100));
    state.unregisterHandle(h100, idx0); // stale index: no-op
    try std.testing.expectEqual(@as(?u32, idx2), state.lookupBorn(h100));
    state.unregisterHandle(h100, idx2); // current index: removed
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(h100));

    // Free returns the slot to the free list and clears occupancy.
    state.sockFree(s1, idx1);
    try std.testing.expect(!s1.occupied);
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(h101));
    try std.testing.expectEqual(@as(?u32, idx1), state.registry.free_head);
}

test "stale socket events drop without touching the pending op" {
    // The use-after-free guard for a closed-and-reused fd: an event whose
    // generation predates the current occupant, whose slot is unoccupied,
    // whose chunk was never published, or whose index is past the chunk
    // ceiling must drop before any access to the caller's node or socket.
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
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
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    state.port = &port;
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
    try port.addTimer(net_timer_id_base + op.slot_index, netTimerUdata(index, s.generation), 60_000, .once);
    s.deadline_armed = true;

    // The deadline fires: Timeout retire (not canceled), socket closed and
    // unregistered, slot freed, deadline disarmed.
    try std.testing.expect(state.connectDeadlineFired(netTimerUdata(index, s.generation)));
    try std.testing.expectEqual(@as(?NetError, .timeout), op.result.err);
    try std.testing.expectEqual(@as(u32, 1), op.state.load(.acquire));
    try std.testing.expect(!op.outcome_canceled);
    try std.testing.expect(!s.occupied);
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(fd));
    try std.testing.expectEqual(@as(compat.fd_t, -1), s.plain.sock);
    try std.testing.expectEqual(@as(?*NetOp, null), s.pending_connect);
    try std.testing.expect(!s.deadline_armed);

    // A stale deadline fire for the freed slot is dropped by the network path:
    // the tag bit is decisive, so loopMain never forwards it to timerFired.
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
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    state.port = &port;
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
    s.closing = false;
    s.index = index;
    s.pending_connect = null;
    s.pending_read = null;
    s.pending_write = null;
    s.read_armed = false;
    s.write_armed = false;
    s.deadline_armed = false;
    s.plain = .{};
    const udata = slotUdata(index, s.generation);
    try s.plain.startConnectAddrInto(target, &port, udata);
    s.handle = s.plain.handle();
    try state.registerHandle(s.handle, index);
    try std.testing.expectEqual(@as(usize, 1), s.plain.pendingOps());

    var op: NetOp = .{ .kind = .connect, .sock_index = index, .payload = .{ .connect = .{ .target = .{ .ip = target } } } };
    op.slot_index = try state.netAllocSlotLocked();
    state.netSlotAt(op.slot_index).op = &op;
    s.pending_connect = &op;
    try port.addTimer(net_timer_id_base + op.slot_index, netTimerUdata(index, s.generation), 60_000, .once);
    s.deadline_armed = true;

    // The deadline fires while ConnectEx is pending: Timeout retire (not
    // canceled), cancel/close, deadline disarmed, but the slot stays occupied
    // until the completion drains.
    try std.testing.expect(state.connectDeadlineFired(netTimerUdata(index, s.generation)));
    try std.testing.expectEqual(@as(?NetError, .timeout), op.result.err);
    try std.testing.expectEqual(@as(u32, 1), op.state.load(.acquire));
    try std.testing.expect(!op.outcome_canceled);
    try std.testing.expect(s.closing);
    try std.testing.expectEqual(@as(?*NetOp, null), s.pending_connect);
    try std.testing.expect(!s.deadline_armed);
    try std.testing.expect(s.occupied);
    try std.testing.expectEqual(@as(usize, 1), s.plain.pendingOps());
    // Required 1: the handle mapping is dropped BEFORE the drain completes, so
    // a reused SOCKET value opened by another thread never resolves to this
    // dying slot even while it is still occupied/closing.
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(s.handle));

    // Drain the aborted completion through the real event path; the slot is
    // freed only once pendingOps() reaches zero.
    var events: [8]born.Event = undefined;
    var guard: u32 = 0;
    while (s.occupied and guard < 100) : (guard += 1) {
        const n = try port.wait(&events, 100);
        for (events[0..n]) |ev| {
            if (ev.timer or ev.wake) continue;
            state.socketEvent(ev);
        }
    }
    try std.testing.expect(!s.occupied);
    try std.testing.expectEqual(@as(usize, 0), s.plain.pendingOps());
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(s.handle));
}

test "registryCloseAll drains two sockets' completions to their owners (Windows)" {
    // Required 2: the exit drain must route each completion to its OWN socket.
    // Socket B has a completed recv queued (the peer sent a byte) while socket
    // A's recv is still pending. The old per-socket polled drain fed every
    // completion to one socket's absorbCompletion, dropping B's, so B freed with
    // pendingOps != 0 after a 100 s guard. The two-phase drain (cancel all, then
    // dispatch through socketEvent with no timeout) frees both promptly.
    if (!is_windows) return error.SkipZigTest;
    var port = try born.EvPort.init(std.testing.allocator);
    defer port.deinit();
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    state.port = &port;
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
        s.closing = false;
        s.index = index.*;
        s.pending_connect = null;
        s.pending_read = null;
        s.pending_write = null;
        s.read_armed = false;
        s.write_armed = false;
        s.deadline_armed = false;
        try s.plain.startConnectAddrInto(target, &port, slotUdata(index.*, s.generation));
        s.handle = s.plain.handle();
        try state.registerHandle(s.handle, index.*);
        peers[i] = try server.accept(fio);
        // Absorb the connect completion (no loop thread runs), confirm, then
        // post a WSARecv that stays pending until data or cancellation.
        var events: [8]born.Event = undefined;
        var guard: u32 = 0;
        while (!s.plain.connect_done and guard < 100) : (guard += 1) {
            const n = try port.wait(&events, 100);
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
        try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(s.handle));
    }
}

test "net submit refusal and loop-exit retirement distinguish route_dead from canceled" {
    // Required 3: a dead route is not the caller's cancellation. A submit
    // refusal completes the op with route_dead, and a failure exit retires
    // queued ops as route_dead (both map to Unexpected); a stop request or an
    // op whose submitter requested cancellation stays canceled.
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
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

test "concurrent read or write on a parked op is rejected busy, not orphaned" {
    // Minor 8: a second concurrent read/write must not overwrite the parked
    // pending pointer (which would orphan the first op and hang its submitter).
    // It retires busy (mapped to Unexpected); the parked op stays pending.
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
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
    defer state.threaded.deinit();
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
    try std.testing.expect(state.lookupBorn(born_h) != null);
    try std.testing.expectEqual(@as(?u32, null), state.lookupBorn(peer_h));

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
