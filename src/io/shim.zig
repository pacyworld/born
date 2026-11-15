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
//!   node (`SleepOp`), enqueues it on the shim's mutex-protected intrusive
//!   queue, and calls `wake()`, the only cross-thread port call. The loop drains
//!   the queue inside its wait cycle and arms timers on its own thread.
//! - Completion return: the submitter blocks on a cancelable Threaded futex
//!   wait on the node's state word. The loop publishes the terminal state with
//!   a release store and signals the futex. Cancellation composes: Threaded's
//!   cancel interrupts the submitter's futex wait, the submitter requests the
//!   disarm and wakes the loop, and the loop runs `cancelTimer` and retires
//!   the node on that wake. The submitter drains uncancelably until retirement
//!   before returning, so the loop never touches stack storage after the call
//!   unwinds.
//! - Deployment is thread-per-core: one port and one instance per core.
//!
//! ## Time route: per-slot overload and failure mapping
//!
//! The submission queue is bounded by caller-provided operation storage: every
//! blocking call owns exactly one node, so the queue holds at most one node per
//! concurrent caller. There is no shared ring to fill; a queue-full condition
//! cannot occur and no slot returns a queue-full error.
//!
//! | slot | declared error set | queue-full error | other failures |
//! |---|---|---|---|
//! | `sleep` | `error{Canceled}` | none: cannot occur (caller-owned nodes) | cancel request, shim stop, or timer-arm refusal (`born.TimerError`) -> `Canceled`, the set's only member; std.Io's sleep contract admits no resource error, so kernel timer exhaustion is not distinguishable from cancellation |
//! | `now` | infallible | n/a: direct clock read, no submission | clock refusal -> `Timestamp.zero`, matching Threaded |
//! | `clockResolution` | `error{ClockUnavailable, Unexpected}` | n/a: stays Threaded | Threaded's mapping |
//! | `cancel` | `void` | n/a: forwards to Threaded; the Born-side disarm rides the sleeping call's own node | none |
//!
//! `Canceled` from `sleep` therefore always means the operation was interrupted
//! (task cancellation, shim stop, or kernel timer resource exhaustion), never
//! submission-queue overload. Sleeps on a `Clock` other than `.awake` are
//! explicitly delegated to Threaded: Born's timers measure the monotonic timer
//! clock only. On macOS `.awake` reads Born's CLOCK_MONOTONIC rather than
//! Threaded's CLOCK_UPTIME_RAW so `now` and sleep deadlines share one clock.

const std = @import("std");
const builtin = @import("builtin");
const born = @import("born");
const Io = std.Io;
const assert = std.debug.assert;

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

/// Caller-owned operation node for the time route: one per blocking `sleep`
/// call, stack-allocated by the submitter. The submission queue is bounded by
/// these nodes, so it cannot overflow (see the module's overload table).
///
/// Ownership: the submitter owns the node until it is enqueued; the loop
/// thread owns it from dequeue until it publishes the terminal `state`; the
/// submitter owns it again after observing the terminal state. The loop never
/// touches a node after retirement, which is what makes stack storage safe.
pub const SleepOp = struct {
    /// Submission-queue link: submitter writes before enqueue, loop reads
    /// after dequeue.
    next: ?*SleepOp = null,
    /// Armed-list links, loop-thread only.
    live_next: ?*SleepOp = null,
    live_prev: ?*SleepOp = null,
    /// Born monotonic deadline in nanoseconds; loop-thread only after enqueue.
    deadline_ns: u64 = 0,
    /// Timer id assigned by the loop; loop-thread only.
    timer_id: u32 = 0,
    /// True while the timer is armed; loop-thread only.
    armed: bool = false,
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
};

/// Consecutive `wait` failures with no successful wait between them before
/// the loop retires everything and exits. One-shot stashed failures (a refused
/// wake trigger, a transient allocation failure) are retried; a persistently
/// broken port must not spin the loop.
const wait_fail_limit: u32 = 8;

fn shimFrom(userdata: ?*anyopaque) *Shim {
    return @ptrCast(@alignCast(userdata.?));
}

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
    /// mutex critical sections are O(1) (push, or swap out the whole list);
    /// the loop never holds it across `wait`. Locking is uncancelable: a
    /// canceled holder must not strand the list. `dead` is set by the loop on
    /// exit, after which submissions are rejected at the slot.
    queue: struct {
        mutex: Io.Mutex = .init,
        head: ?*SleepOp = null,
        tail: ?*SleepOp = null,
        dead: bool = false,
    } = .{},
    /// Loop-thread-only state: timer id assignment and the armed-op list.
    next_timer_id: u32 = 1,
    id_wrapped: bool = false,
    live: ?*SleepOp = null,
    live_count: usize = 0,

    /// Enqueue a caller-owned node. Returns false only after the loop has
    /// exited (`queue.dead`); the caller then reports `error.Canceled` at the
    /// slot.
    fn submit(self: *Shim, op: *SleepOp) bool {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        defer self.queue.mutex.unlock(self.threaded_io);
        if (self.queue.dead) return false;
        op.next = null;
        if (self.queue.tail) |tail| tail.next = op else self.queue.head = op;
        self.queue.tail = op;
        return true;
    }

    /// The loop thread: sole driver of the port. Drains submissions, blocks
    /// in `wait` until a timer fires or a wake arrives, and retires everything
    /// on stop or persistent port failure.
    fn loopMain(self: *Shim) void {
        var events: [64]born.Event = undefined;
        var fail_streak: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            self.drainSubmissions();
            const n = self.port.wait(&events, null) catch {
                fail_streak += 1;
                if (fail_streak >= wait_fail_limit) break;
                // A refused wake is stashed and reported here; the cancel
                // request it carried still needs its disarm scan.
                self.retireCanceled();
                continue;
            };
            fail_streak = 0;
            var woke = false;
            for (events[0..n]) |ev| {
                if (ev.timer) self.timerFired(@ptrCast(@alignCast(ev.udata.?)));
                if (ev.wake) woke = true;
            }
            // A submitter requests cancellation of an armed operation by
            // setting cancel_requested and then waking the loop; the scan
            // runs on wake events, not on every timer fire.
            if (woke) self.retireCanceled();
        }
        self.retireAll();
    }

    /// Disarm and retire armed operations whose submitter requested
    /// cancellation. Loop-thread only; runs on wake events and stashed wake
    /// failures.
    fn retireCanceled(self: *Shim) void {
        var node = self.live;
        while (node) |op| {
            const next = op.live_next;
            if (op.cancel_requested.load(.acquire)) {
                self.liveRemove(op);
                if (op.armed) self.port.cancelTimer(op.timer_id);
                op.armed = false;
                self.retire(op, true);
            }
            node = next;
        }
    }

    /// Swap the whole submission list out under the mutex, then arm or retire
    /// each node on the loop thread.
    fn drainSubmissions(self: *Shim) void {
        self.queue.mutex.lockUncancelable(self.threaded_io);
        const head = self.queue.head;
        self.queue.head = null;
        self.queue.tail = null;
        self.queue.mutex.unlock(self.threaded_io);
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
        self.queue.mutex.unlock(self.threaded_io);
        var node = head;
        while (node) |op| {
            const next = op.next;
            self.retire(op, true);
            node = next;
        }
        while (self.live) |op| {
            self.live = op.live_next;
            if (op.armed) self.port.cancelTimer(op.timer_id);
            self.retire(op, true);
        }
        self.live_count = 0;
    }

    /// Publish the terminal state and wake the submitter's futex wait.
    fn retire(self: *Shim, op: *SleepOp, canceled: bool) void {
        op.outcome_canceled = canceled;
        op.state.store(1, .release);
        self.threaded_io.vtable.futexWake(self.threaded_io.userdata, &op.state.raw, 1);
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
    /// longer sleeps. An arm refusal retires the operation as canceled:
    /// `error{Canceled}` is the only error `sleep`'s declared set admits
    /// (module overload table).
    fn arm(self: *Shim, op: *SleepOp, remaining_ns: u64) void {
        const id = self.pickTimerId();
        self.port.addTimer(id, op, ceilMs(remaining_ns), .once) catch return self.retire(op, true);
        op.timer_id = id;
        op.armed = true;
        op.live_prev = null;
        op.live_next = self.live;
        if (self.live) |head| head.live_prev = op;
        self.live = op;
        self.live_count += 1;
    }

    fn timerFired(self: *Shim, op: *SleepOp) void {
        // A `.once` timer is retired by the port when it fires.
        op.armed = false;
        self.liveRemove(op);
        if (op.cancel_requested.load(.acquire)) return self.retire(op, true);
        const now_ns = born.nowNs() catch return self.retire(op, false);
        if (now_ns >= op.deadline_ns) return self.retire(op, false);
        self.arm(op, op.deadline_ns - now_ns);
    }

    fn liveRemove(self: *Shim, op: *SleepOp) void {
        if (op.live_prev) |prev| prev.live_next = op.live_next else self.live = op.live_next;
        if (op.live_next) |next| next.live_prev = op.live_prev;
        self.live_count -= 1;
    }

    /// Assign a timer id unique among armed operations. Ids increment; before
    /// the first u32 wrap every issued id is distinct by construction. After
    /// a wrap, skip ids still armed (a re-added live id would replace another
    /// operation's timer). The probe loop is bounded by the armed count: the
    /// u32 space cannot be exhausted by live operations. Loop-thread only.
    pub fn pickTimerId(self: *Shim) u32 {
        const id = self.next_timer_id;
        self.next_timer_id +%= 1;
        if (self.next_timer_id == 0) self.id_wrapped = true;
        if (self.id_wrapped) {
            var candidate = id;
            var probes: usize = 0;
            while (self.isLive(candidate)) : (candidate +%= 1) {
                probes += 1;
                assert(probes <= self.live_count);
            }
            return candidate;
        }
        return id;
    }

    fn isLive(self: *const Shim, id: u32) bool {
        var node = self.live;
        while (node) |op| : (node = op.live_next) {
            if (op.timer_id == id) return true;
        }
        return false;
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
        shim.loop = std.Thread.spawn(.{}, Shim.loopMain, .{shim}) catch return error.OutOfMemory;
    }
    return .{
        .userdata = shim,
        .vtable = if (caps.time == .born_evented) &time_vtable else &baseline_vtable,
    };
}

/// Releases the composite created by `io`. As with `Io.Threaded`, every task
/// must have been awaited or canceled first. Joins the Threaded pool, then
/// stops the time route's loop thread (retiring any operation still pending
/// as canceled) before freeing the composite.
pub fn deinit(interface: Io) void {
    const shim = shimFrom(interface.userdata);
    const allocator = shim.allocator;
    shim.threaded.deinit();
    if (shim.loop) |loop| {
        shim.stopping.store(true, .release);
        shim.port.wake();
        loop.join();
    }
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

/// Born evented implementations of the time family. Every other slot keeps
/// its baseline forwarding thunk; `time_vtable` is a comptime copy of the
/// baseline with only these slots replaced, so the two cannot drift.
const time_route = struct {
    /// Sleep on Born's timers. `.none` returns immediately (Threaded's
    /// semantics); a `Clock` other than `.awake` is explicitly delegated to
    /// Threaded because Born's timers measure the monotonic timer clock only.
    /// The submission node is caller-owned stack storage: the queue cannot
    /// overflow (module overload table). Completion returns through a
    /// cancelable Threaded futex wait; cancellation disarms the Born timer
    /// through the loop and drains until the node is retired.
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
        if (!self.submit(&op)) return error.Canceled;
        self.port.wake();

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
                    self.port.wake();
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
