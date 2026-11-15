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
//!   encodes (generation, index). The slot table is loop-owned storage; the
//!   port never holds a pointer into caller stack. On fire the loop decodes
//!   the identity, drops the event if the slot is free or the generation does
//!   not match, and only then touches the node. Stale fires are normal (a
//!   cancel's `EV_DELETE` can fail to stage under memory pressure), so this
//!   check is the structural use-after-free guard, not an optimization.
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
//!   nodes; it never scans the armed population. The submitter drains
//!   uncancelably until retirement before returning, so the loop never
//!   touches stack storage after the call unwinds.
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
//! on demand under the queue mutex; a growth refusal is a resource failure,
//! not overload, and maps like a timer-arm refusal below.
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
    /// the loop before the terminal store: `t_arm_ns` at first arm,
    /// `t_fire_ns` at each fire. The submitter's own phase timestamps are
    /// locals, never written here after enqueue (the loop owns the node from
    /// dequeue, so a late submitter write would race the loop's arm).
    t_arm_ns: u64 = 0,
    t_fire_ns: u64 = 0,
};

/// Loop-owned timer slot. The timer id is the slot index; the port's `udata`
/// carries (generation, index) so a stale fire is dropped without touching
/// caller storage. `op`, `generation`, `next_free` and `cancel_next` are
/// protected by the queue mutex; `armed` is loop-thread only.
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
};

/// Initial slot-table capacity, preallocated at construction for the time
/// route so the steady-state sleep path performs no shim allocation. Growth
/// doubles under the queue mutex.
const slots_initial: usize = 64;

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
    /// Loop-owned slot table: timer identity and lifetime. Grows under the
    /// queue mutex; freed at deinit after the loop joins.
    slots: []Slot = &.{},
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

    /// Take a free slot, growing the table if needed. Queue mutex held.
    fn allocSlotLocked(self: *Shim) error{OutOfMemory}!u32 {
        if (self.free_head) |i| {
            self.free_head = self.slots[i].next_free;
            return i;
        }
        const old_len = self.slots.len;
        const new_len = if (old_len == 0) slots_initial else old_len * 2;
        const grown = self.allocator.realloc(self.slots, new_len) catch return error.OutOfMemory;
        self.slots = grown;
        // Thread the new slots onto the free list, last first, so allocation
        // hands out ascending indices.
        var i = new_len;
        while (i > old_len) {
            i -= 1;
            grown[i] = .{ .next_free = self.free_head };
            self.free_head = @intCast(i);
        }
        const head = self.free_head.?;
        self.free_head = grown[head].next_free;
        return head;
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
        const slot = &self.slots[index];
        slot.op = op;
        slot.generation +%= 1;
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
    /// under the same mutex, so the check cannot race). Returns whether the
    /// cancel list went from empty to non-empty.
    fn requestCancel(self: *Shim, op: *SleepOp) bool {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        defer self.queue.mutex.unlock(self.threaded_io);
        const slot = &self.slots[op.slot_index];
        if (slot.op != op) return false;
        const was_empty = self.cancel_head == null;
        slot.cancel_next = self.cancel_head;
        self.cancel_head = op.slot_index;
        return was_empty;
    }

    /// The loop thread: sole driver of the port. Each cycle drains the cancel
    /// list and swaps out the submission queue under the mutex, arms the
    /// swapped nodes, then blocks in `wait` until a timer fires or a wake
    /// arrives. Retires everything on stop or persistent port failure.
    fn loopMain(self: *Shim) void {
        var events: [64]born.Event = undefined;
        var fail_streak: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            const batch = self.drainLocked();
            self.armBatch(batch);
            const n = self.port.wait(&events, null) catch |err| {
                self.latch(err);
                fail_streak += 1;
                if (fail_streak >= wait_fail_limit) break;
                // The next cycle drains the cancel list again, so requests
                // carried by a refused wake are still serviced.
                continue;
            };
            fail_streak = 0;
            for (events[0..n]) |ev| {
                if (ev.timer) self.timerFired(ev.udata);
            }
        }
        self.retireAll();
    }

    /// One critical section: drain the cancel list, then swap out the whole
    /// submission list. Cancel entries for queued (not yet armed) nodes are
    /// left to `armOrRetire`'s `cancel_requested` check; entries for freed
    /// slots are stale and dropped. Links live in the slot table, so walking
    /// them never touches caller storage.
    fn drainLocked(self: *Shim) ?*SleepOp {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        var idx = self.cancel_head;
        self.cancel_head = null;
        while (idx) |i| {
            const slot = &self.slots[i];
            const next = slot.cancel_next;
            slot.cancel_next = null;
            if (slot.op) |op| {
                if (slot.armed) {
                    self.port.cancelTimer(i);
                    slot.armed = false;
                    self.retireLocked(op, i, true);
                    // Cancel drain is the cold path: wake under the mutex.
                    self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &op.state.raw, 1);
                }
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
        // Cancel entries refer to slots retired by the scan below; their
        // links are reset when a slot is next allocated.
        self.cancel_head = null;
        self.queue.mutex.unlock(self.threaded_io);
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.retire(op, true);
            node = next;
        }
        for (self.slots, 0..) |*slot, i| {
            if (slot.op) |op| {
                if (slot.armed) self.port.cancelTimer(@intCast(i));
                self.retire(op, true);
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

    /// Queue mutex held: terminal store plus slot free, no wake. After the
    /// terminal store the submitter may return and reuse its frame: no
    /// field of the node is read or written past this point.
    fn retireLocked(self: *Shim, op: *SleepOp, index: u32, canceled: bool) void {
        op.outcome_canceled = canceled;
        op.state.store(1, .release);
        const slot = &self.slots[index];
        slot.op = null;
        slot.armed = false;
        slot.next_free = self.free_head;
        self.free_head = index;
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
        const slot = &self.slots[index];
        self.port.addTimer(index, slotUdata(index, slot.generation), ceilMs(remaining_ns), .once) catch |err| {
            self.latch(err);
            return self.retire(op, true);
        };
        slot.armed = true;
        if (op.t_arm_ns == 0) op.t_arm_ns = born.nowNs() catch 0;
    }

    /// Handle one timer fire. The identity refers to the loop-owned slot
    /// table: drop the event if the index is out of range, the slot is free,
    /// or the generation does not match, and only then touch the node. While
    /// a slot is occupied only this thread retires it, and allocation writes
    /// are happens-before via the queue dequeue, so the validation reads need
    /// no mutex. Loop-thread only.
    fn timerFired(self: *Shim, udata: ?*anyopaque) void {
        const id = decodeSlotUdata(udata);
        if (id.index >= self.slots.len) return;
        const slot = &self.slots[id.index];
        const op = slot.op orelse return;
        if (slot.generation != id.generation) return;
        // A `.once` timer is retired by the port when it fires.
        slot.armed = false;
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
};

/// Milliseconds for a remaining nanosecond span, rounded up so a sleep never
/// returns early, clamped to the port's u32 ms ceiling. `remaining_ns` > 0.
pub fn ceilMs(remaining_ns: u64) u32 {
    const ms = (remaining_ns +| (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    return @intCast(@min(ms, std.math.maxInt(u32)));
}

/// Builds a `std.Io` over Born's event port. The returned interface owns a
/// heap-allocated composite; release it with `deinit`. The time route
/// (`capabilities.time = .born_evented`) spawns the Scale model loop thread
/// and services `sleep` and monotonic `now` on Born; the caller must not drive
/// the port itself afterwards. Born routes for the other families are still
/// rejected at construction.
pub fn io(port: *born.EvPort, opts: InitOptions) InitError!Io {
    const caps = opts.capabilities;
    if (caps.network == .born_evented or caps.file == .born_evented or caps.process == .born_evented)
        return error.CapabilityUnsupported;
    // The time route needs a loop thread; a single-threaded build cannot host
    // one, so the profile is rejected rather than silently degraded.
    if (caps.time == .born_evented and builtin.single_threaded)
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
    if (caps.time == .born_evented) {
        // Preallocate the slot table so the steady-state sleep path performs
        // no shim allocation; growth beyond capacity is on demand.
        shim.slots = opts.allocator.alloc(Slot, slots_initial) catch return error.OutOfMemory;
        errdefer opts.allocator.free(shim.slots);
        for (shim.slots, 0..) |*slot, i| {
            slot.* = .{ .next_free = if (i + 1 < shim.slots.len) @intCast(i + 1) else null };
        }
        shim.free_head = 0;
        shim.loop = std.Thread.spawn(.{}, Shim.loopMain, .{shim}) catch return error.LoopSpawnFailed;
    }
    return .{
        .userdata = shim,
        .vtable = if (caps.time == .born_evented) &time_vtable else &baseline_vtable,
    };
}

/// Releases the composite created by `io`. As with `Io.Threaded`, every task
/// must have been awaited or canceled first. Stops and joins the time route's
/// loop thread first (retiring any operation still pending as canceled): the
/// loop calls into Threaded until it exits. Then joins the Threaded pool and
/// frees the composite.
pub fn deinit(interface: Io) void {
    const shim = shimFrom(interface.userdata);
    const allocator = shim.allocator;
    if (shim.loop) |loop| {
        shim.stopping.store(true, .release);
        shim.port.wake();
        loop.join();
    }
    shim.threaded.deinit();
    allocator.free(shim.slots);
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
/// sleeps are not counted. The baseline route reports zeros.
pub const TimeStats = struct {
    ops: u64,
    wakes: u64,
    submit_wake_ns: u64,
    queue_arm_ns: u64,
    timer_span_ns: u64,
    futex_return_ns: u64,
};

/// Snapshot of the time route's latency breakdown accumulators.
pub fn timeStats(interface: Io) TimeStats {
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
            _ = self.stats.wakes.fetchAdd(1, .monotonic);
            self.port.wake();
        }
        // Submitter-side phase timestamps are locals: the loop owns the node
        // from dequeue, so writing them into the node after enqueue would
        // race the loop's arm. t0 (captured before submit) is the enqueue
        // timestamp; the loop can only arm after dequeue, so t_arm >= t0.
        const t_wake_done = born.nowNs() catch 0;

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
                        _ = self.stats.wakes.fetchAdd(1, .monotonic);
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
        const t_done = born.nowNs() catch 0;
        if (op.t_fire_ns != 0 and op.t_arm_ns != 0 and t_wake_done != 0 and t_done != 0) {
            _ = self.stats.ops.fetchAdd(1, .monotonic);
            _ = self.stats.submit_wake.fetchAdd(t_wake_done - t0, .monotonic);
            _ = self.stats.queue_arm.fetchAdd(op.t_arm_ns - t0, .monotonic);
            _ = self.stats.timer_span.fetchAdd(op.t_fire_ns - op.t_arm_ns, .monotonic);
            _ = self.stats.futex_return.fetchAdd(t_done - op.t_fire_ns, .monotonic);
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
    // occupant, whose slot was freed, or whose index is out of range must be
    // dropped before any access to the caller's node. The drop paths never
    // reach Threaded, so an otherwise-undefined composite is safe here.
    var state: Shim = undefined;
    var slot: Slot = .{};
    var op: SleepOp = .{};
    state.slots = @as([*]Slot, @ptrCast(&slot))[0..1];

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
    // Out-of-range index.
    state.timerFired(slotUdata(99, 7));
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

test "submit reports only the empty-to-non-empty transition" {
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    state.slots = try std.testing.allocator.alloc(Slot, 2);
    defer std.testing.allocator.free(state.slots);
    state.slots[0] = .{ .next_free = 1 };
    state.slots[1] = .{};
    state.free_head = 0;

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
    try std.testing.expectEqual(@as(u32, 1), state.slots[0].generation);
}

test "cancel request skips a retired slot" {
    var state: Shim = undefined;
    testShim(&state);
    defer state.threaded.deinit();
    state.slots = try std.testing.allocator.alloc(Slot, 1);
    defer std.testing.allocator.free(state.slots);
    state.slots[0] = .{};

    var op: SleepOp = .{};
    op.slot_index = 0;
    state.slots[0].op = &op;
    // Occupied: the request pushes and reports the transition.
    try std.testing.expect(state.requestCancel(&op));
    try std.testing.expectEqual(@as(?u32, 0), state.cancel_head);
    // Drain the list as the loop would.
    state.cancel_head = null;
    state.slots[0].cancel_next = null;
    // Retired (retireLocked frees the slot under the same mutex): the
    // occupancy check must refuse the push, so a reused slot is never
    // canceled on behalf of the previous occupant.
    state.slots[0].op = null;
    try std.testing.expect(!state.requestCancel(&op));
    try std.testing.expectEqual(@as(?u32, null), state.cancel_head);
}
