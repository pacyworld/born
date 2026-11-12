# Born design lessons from std.Io

## Scope and source key

This is a source critique of Zig 0.16.0, Zig 0.17.1, and the Born reactor at the cited commit. It does not claim new Dispatch, Kqueue, or Born runtime results.

- `U16`: [Zig 0.16.0 `lib/std`](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std). `U16/...` citations are relative to that directory.
- `U17`: [Zig 0.17.1 `lib/std`](https://codeberg.org/ziglang/zig/src/tag/0.17.1/lib/std). `U17/...` citations are relative to that directory.
- `Born`: [commit `36677d7c61a3451d3beb5dbbd950dc05f36ca28e`](https://pacyworld.dev/pacyworld/born/commit/36677d7c61a3451d3beb5dbbd950dc05f36ca28e). Born citations below are `src/...` paths relative to that commit.

Two source facts should guide the adapter design and shim terminology:

1. `Io.Select` and `Io.Batch` exist in both releases. See `U16/Io.zig:474-504,1360-1425` and `U17/Io.zig:573-640,1489-1555`.
2. Counting top-level declarations in `Io.VTable` gives 109 fields in 0.16.0 and 106 in 0.17.1 (`U16/Io.zig:51-255`, `U17/Io.zig:51-244`). The design problem is the monolithic, mandatory interface regardless of the number. The shim must assert the count and field names for each exact upstream tag.

## What to adopt

### A plain function-pointer table is a useful compatibility boundary

`std.Io` is only `userdata` plus `*const VTable`, and each VTable member is a non-nullable function pointer (`U17/Io.zig:25-26,51-244`). This is a sound interop mechanism: no backend inheritance, generic reactor, or common private base type is required. It also permits one interface to route different operations to different implementations.

The shim should use that mechanism only in `src/io/`. Born core should retain its small, non-generic native `Handle`, shared `Event`, and compile-time backend selection (`src/root.zig:43-59`). The dependency rule is strict:

- `src/io/` imports Born and `std.Io`.
- Born core never imports `std.Io` or `src/io/`.
- CI rejects either core back-edge.
- Shim needs do not justify a scheduler, file API, or std compatibility types in core.

A hybrid VTable needs forwarding thunks. Copying `Io.Threaded` function pointers into a table whose `userdata` points to the shim is invalid. `Io.Threaded.io()` installs its own `*Threaded` as userdata (`U17/Io/Threaded.zig:1854-1857`), and its functions cast userdata back to that type, for example `fileReadPositional` at `U17/Io/Threaded.zig:10307-10311`. Each file or directory thunk must recover the composite shim, then call the saved Threaded VTable slot with `threaded_io.userdata`. Born thunks likewise recover the shim and use its `EvPort`. The shim and both backends must outlive every operation and completion.

Version routing belongs in the adapter. In 0.16, direct network slots include `netSend`, `netRead`, and `netWrite` (`U16/Io.zig:238-255`). In 0.17 those operations are tags under `Operation`, alongside streaming file I/O (`U17/Io.zig:246-257,345-489`). A 0.17 hybrid `operate` thunk must route `file_read_streaming`, `file_write_streaming`, and applicable `device_io_control` operations to Threaded. Only supported `net_read` and `net_write` subsets may route to Born, and only when their vectored, splat, cancellation, result, and error semantics can be preserved. `net_receive` and `net_send` require explicit capability rejection until a new Born message-oriented implementation exists. Nonempty control buffers and every other incompatible `net_read` or `net_write` case likewise require capability rejection or new implementation, never a lossy conversion or silent Threaded fallback. Threaded's own dispatcher shows the complete tag split at `U17/Io/Threaded.zig:2583-2643`.

### Batch and Select offer good ownership and result-routing ideas

Adopt the ideas, not the fiber implementation:

- `Batch` uses caller-provided operation storage and explicit unused, submitted, pending, and completed lists (`U17/Io.zig:578-640`). This bounds queued work and makes storage lifetime visible.
- `Batch.next` returns the caller's operation index and result, while await operations wait for at least one completion rather than requiring the whole batch (`U17/Io.zig:642-697`).
- `Select(U)` routes each task result into a typed union and a bounded queue (`U17/Io.zig:1496-1514,1541-1555`). `awaitMany` copies a minimum number of typed results into caller storage (`U17/Io.zig:1606-1619`).
- Select ownership is explicit: spawned resources belong to the Select, and it must be awaited or canceled before destruction (`U17/Io.zig:1516-1529`).

Born already has the low-level batch shape. Kqueue submits staged changes and harvests an event array in one `kevent` call (`src/evport_kqueue.zig:333-397`); IOCP harvests an array in one `GetQueuedCompletionStatusEx` call (`src/evport_iocp.zig:222-261`). The shim can adapt std operations into this model without adding a second reactor abstraction to core.

Cancellation must preserve completed results. `Batch.cancel` documents that cancellation waits for pending operations, successfully canceled operations disappear, and operations that completed despite the request remain iterable (`U17/Io.zig:699-727`). Select has the same ownership lesson in a higher-level form: `cancel` drains results so resources can be released, while `cancelDiscard` is valid only when results own no resources (`U17/Io.zig:1621-1664`). The shim should use explicit pending, cancel-requested, completed, and drained states. It must not equate "cancel requested" with "storage reusable" or "no result was produced."

### Born's concrete cancellation rules are worth keeping

Born's timer API has direct, testable behavior: caller-chosen live IDs, replacement on re-add, and cancellation of unknown or expired IDs as a no-op (`src/evport_kqueue.zig:283-291`). Its contract tests cover cancellation before expiry, ID reuse, replacement, and cancellation after expiry (`src/timer_test.zig:77-132`). Kqueue also defines the narrow race where a one-shot fired in the kernel but is not yet harvested: its ID remains live, so delete discards the queued firing (`src/timer_kqueue.zig:10-20,176-188`).

IOCP requires a different lifetime rule. `PlainNb.cancelAndClose` requests cancellation and closes the socket, but completions still arrive (`src/socket_windows.zig:347-356`). The object must remain at a stable address until `pendingOps()` reaches zero (`src/socket_windows.zig:358-370`). The real-call test closes, drains, and only then accepts zero pending operations (`src/socket_test.zig:304-323`). Listener teardown follows the same drain rule (`src/listener_windows.zig:410-429`).

The shim should expose these rules through one ownership contract per operation:

1. Submission fixes the operation and completion storage at stable addresses.
2. Cancellation requests interruption and wakes the reactor, but does not free storage.
3. Completion or cancellation completion is harvested.
4. Results are drained or deliberately discarded according to their ownership.
5. Only then may IDs, overlapped storage, buffers, and backend objects be reused or destroyed.

## Dispatch sleep cancellation: the exact wiring defect

The 0.16.0 defect is a wrong callback pointer. The 0.17.1 source contains the one-line correction. This analysis is source-derived; no Darwin runtime reproduction is claimed.

### Cancellation path into the callback

A Dispatch fiber records cancellation with `Fiber.requestCancel`. If the fiber is awaiting a `Cancelable`, it calls `Cancelable.async` (`U16/Io/Dispatch.zig:255-275`). `Cancelable.async` queues the cancelable and its stored function pointer on the cancelable's serial dispatch queue (`U16/Io/Dispatch.zig:766-770`). Consequently, the function named in `SleepWaiter.cancelable.cancel` is the function that must understand `SleepWaiter` layout and cancel its timer.

The 0.16.0 sleep constructor instead stores `&Futex.Waiter.canceled`:

```zig
.cancelable = .{ .queue = queue, .cancel = &Futex.Waiter.canceled },
```

That is `U16/Io/Dispatch.zig:4714-4717`. The correct function is the sibling `SleepWaiter.canceled`.

### Why the wrong handler is type confusion, not just a missed wake

`Futex.Waiter.canceled` converts the context to `Cancelable`, then uses `@fieldParentPtr("cancelable", ...)` as though its owner were a `Futex.Waiter` (`U16/Io/Dispatch.zig:1543-1546`). It next reads `waiter.futex`, calls `waiter.remove()`, and decrements that futex's waiter count (`U16/Io/Dispatch.zig:1547-1549`). `remove` also accesses the futex list and the futex waiter's optional timer (`U16/Io/Dispatch.zig:1566-1569`).

The actual owner is a `SleepWaiter`, whose field after `cancelable` is `timer`, not `futex` (`U16/Io/Dispatch.zig:4662-4666`). The handler therefore reinterprets the sleep timer pointer as a futex pointer and treats subsequent sleep storage as futex list and timer state. This is invalid typed access with potential memory corruption or a crash. The source does not justify reducing the defect to a reliable missed wakeup or a clean `error.Canceled`; the exact runtime symptom depends on layout and timing.

The common `sleeper` and `cancelable` prefix explains why the initial `cancelable.requested(...)` can appear plausible on inspection. It does not make the following futex accesses valid.

### The 0.17.1 wiring and its semantics

In 0.17.1 the constructor names `&SleepWaiter.canceled` (`U17/Io/Dispatch.zig:4723-4726`). That handler:

1. recovers the real `SleepWaiter`;
2. marks cancellation requested through `cancelable.requested`;
3. cancels the dispatch timer (`U17/Io/Dispatch.zig:4693-4698`).

The timer's cancellation handler is `SleepWaiter.wake` (`U17/Io/Dispatch.zig:4727-4730`). `wake` copies the sleeper, invalidates the waiter, and resumes its fiber (`U17/Io/Dispatch.zig:4700-4705`). `Sleeper.wake` performs the queued fiber resume and releases the retained queue (`U17/Io/Dispatch.zig:793-808`). After `ev.yield` returns, `sleep` releases the timer and calls `cancelable.acknowledge`; the requested state produces `error.Canceled` (`U17/Io/Dispatch.zig:4731-4733,784-790`).

Normal timeout uses the same wake mechanism: `timedOut` leaves the cancellation region and cancels the timer (`U17/Io/Dispatch.zig:4685-4691`). The pre-start cancellation case is also wired: `SleepWaiter.start` calls `enter`, and an already requested cancellation cancels the timer before activation (`U17/Io/Dispatch.zig:4677-4683`; `Cancelable.enter` at `U17/Io/Dispatch.zig:728-747`).

The lesson for the shim is to test the whole chain, not only the final error value: callback owner type, state transition, timer cancellation, fiber or task resume, result acknowledgment, and storage release must agree. Required tests are cancellation before registration completes, cancellation during sleep, timeout winning before cancellation, cancellation winning before timeout, and repeated cancellation. Each test must also prove no late resume and no use-after-free. Dispatch is selected for Darwin targets, not FreeBSD (`U17/Io.zig:30-36`), so FreeBSD Kqueue evidence would not exercise this code.

## What to reject

### Do not put a fiber runtime in Born or in the shim

`Io.Evented` is conditional on `Io.fiber.supported` (`U17/Io.zig:30-36`). Kqueue contains fiber context switching, scheduler logic, architecture-specific naked entry points, and a fiber allocation layout with a 4 MiB minimum stack (`U17/Io/Kqueue.zig:76-101,541-575`). Dispatch has its own fiber runtime and a 60 MiB minimum stack in its allocation layout (`U17/Io/Dispatch.zig:99-109,190-207`). These figures describe reserved allocation layouts, not measured resident memory.

The shim is an adapter, not an async runtime. It must not add stack switching, a fiber scheduler, or per-fiber storage to Born. Where consumers require Future, Group, futex, or concurrency primitives, the shim may delegate those primitives to Threaded only after proving cross-backend cancellation and wake behavior. Otherwise it must reject that capability at shim construction. No silent fiber substitute is acceptable.

### Do not reproduce the monolithic mandatory interface in core

Every VTable field is mandatory and non-nullable (`U17/Io.zig:51-244`). Networking, directories, files, memory mapping, processes, randomness, clocks, task scheduling, futexes, and batch operations therefore become one implementation commitment. This breadth encourages empty stubs and couples unrelated release drift.

Born should keep its focused reactor API. The shim alone should carry version-specific VTable construction, operation-tag routing, capability checks, and exact field-count assertions. The correct source-derived assertions for the cited tags are 109 fields for 0.16.0 and 106 for 0.17.1, plus field-name and signature checks. A count alone cannot catch renames or type drift.

### Reject panic stubs and evidence based on lazy analysis

Upstream Kqueue is not a usable reference implementation. Its `io()` initializer still names fields that do not exist in the matching VTable, including `fileWriteStreaming` and `fileReadStreaming` in both releases (`U16/Io/Kqueue.zig:610-664`, `U17/Io/Kqueue.zig:610-662`; compare `U17/Io.zig:176-183`). It also retains direct network operation fields after the 0.17 VTable moved them under `Operation`. Its `now` and `sleep` signatures do not match the current VTable (`U17/Io/Kqueue.zig:987-998` versus `U17/Io.zig:224-226`). Future and group cancellation paths contain `@panic("TODO")`, as do many file, directory, timer, and network operations (`U17/Io/Kqueue.zig:743-809,900-998`).

The test default does not instantiate this backend: `std.testing.io_instance` is `Io.Threaded` in both releases (`U16/testing.zig:34-35`, `U17/testing.zig:23-24`). Lazy analysis can therefore leave the invalid `Kqueue.io()` body unchecked until a real reference forces semantic analysis.

Born's test root states the correct rule: `refAllDecls` supplements real calls, and it imports the API, socket, timer, signal, listener, Unix, and process tests (`src/root.zig:103-116`). `src/api_test.zig:92-109` executes reactor methods with native handles rather than only checking declarations. Cross-compilation remains separate from runtime verification (`src/root.zig:37-38`).

The shim must go further than constructing a VTable:

- Force `io()` and every adapter thunk through semantic analysis on each exact toolchain.
- Execute each claimed operation family on its real kernel backend.
- Run real `std.Io` consumers, including an HTTP client and the selected NATS client.
- Add a mutation check proving that a stale slot or broken registration fails CI.
- Record host OS, commit, toolchain, binary hash, and test summary for each runtime run.

A successful import, `refAllDecls`, cross-build, or Threaded-only consumer run is not evidence for the Born adapter.

### Do not use Threaded as a hidden network fallback

The hybrid recommendation is Born for evented networking, timers, and wake, and `Io.Threaded` for file and directory operations. It is not a license to route network batches through Threaded. Threaded's POSIX batch implementation uses `poll` (`U17/Io/Threaded.zig:2658-2689,2831-2833,2960-2962`), which is outside Born's event-port design and would not exercise Born at all.

Born's regular-file readiness support does not change this split. It supplies native or emulated readiness, not positional I/O, metadata, locks, memory mapping, or directory operations (`src/root.zig:29-30`). Those operations should remain on Threaded through forwarding thunks.

## Shim capability and evidence contract

The shim should publish its route choices and reject unsupported configurations before handing `std.Io` to a consumer.

| Surface | Required route | Unsupported behavior | Required real-call evidence |
|---|---|---|---|
| Born-supported network operations | Born on kqueue, epoll, or IOCP | No Threaded network fallback | Connect, accept, read, write, refusal, close, and cancellation on all three kernels |
| Streaming operations in 0.17 | File/device tags to Threaded; only semantics-preserving supported `net_read`/`net_write` subsets to Born | Reject `net_receive`/`net_send`, incompatible control-buffer cases, and every other unsupported case; never panic or silently fall back | Mixed network and file operations proving each claimed route and rejection |
| Sleep and timers | Shim state plus Born timers and wake | No uncancelable substitute presented as cancelable | Pre-start cancel, active cancel, timeout races, ID reuse, and no late completion |
| File and directory operations | Forwarding thunks to `Io.Threaded` | Fail capability-checked construction when no Threaded route exists | Real files covering streaming, positional I/O, metadata, and close |
| Future, Group, futex, and concurrency | Proven Threaded delegation or no claim | `error.Unsupported` from shim configuration when required support is absent | Cancellation, drain, and cross-thread wake tests |
| Process operations | Only a semantics-preserving adapter | No direct cast between Born process descriptors and `std.process.Child` | Spawn, exit, kill, reap, and target-specific unsupported cases |
| Any unimplemented slot | No silent fallback and no `@panic` | Return only an error declared by that std slot, or reject the configuration with `error.Unsupported` before use | A negative test for every advertised unsupported capability |

Born already uses explicit `Unsupported` errors for unavailable timer, signal, and process capabilities (`src/types.zig:52-92`); IOCP process watch returns it directly (`src/evport_iocp.zig:206-214`). The shim should preserve that clarity at its own boundary. It cannot add `error.Unsupported` to a fixed std VTable signature that does not declare it. Where std uses `error.OperationUnsupported`, translate precisely. Where no suitable error exists, reject the requested capability during shim construction or use a proven Threaded route.

Finally, teardown is part of the API. Cancel and drain Born operations, drain IOCP completions, then join and deinitialize Threaded before releasing the composite shim. This ordering, the no-back-edge rule, per-tag VTable checks, and real-call runtime evidence are the conditions that make the plain function-pointer design useful without importing upstream's runtime and verification problems.
