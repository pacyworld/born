# born

An event port for Zig: one small, uniform seam over the platform's native
readiness/completion notification mechanism.

Named for the Born rule — I/O waits in potential until `wait()` collapses it
into a concrete event.

| checked target triple | backend | runtime status |
|---|---|---|
| `x86_64-freebsd` | kqueue | original backend in production since 2026-08 |
| `x86_64-linux-gnu` | epoll + eventfd | original backend in production since 2026-08 |
| `aarch64-macos` | kqueue | **compile-only, not tested on hardware** |
| `x86_64-macos` | kqueue | **compile-only, not tested on hardware** |
| `x86_64-windows-gnu` | IOCP | original backend in production since 2026-08 |
| `x86_64-netbsd` | kqueue | **compile-only, not tested on hardware** |
| `x86_64-openbsd` | kqueue | **compile-only, not tested on hardware** |

These are exactly the `supported_targets` in `build.zig`, checked by CI.
The build rejects missing or extra target rows in this table.
Other Apple/BSD OS tags select kqueue but are not in the checked matrix;
selection alone is not a compilation or runtime guarantee.

## Programming model

The raw event port has a uniform **type surface**, not identical I/O semantics.
Use `born.socket.PlainNb` for the portable plain-TCP companion. TLS, certificate
validation, HTTP and application logging are outside born.

### kqueue and epoll: readiness

`monitorRead` registers persistent edge-triggered socket read interest. Drain
reads until `want_read`; attempt writes before waiting for `want_write`.
kqueue write interest is one-shot and must be rearmed. epoll write interest
remains armed until `cancelWrite`; once read interest adds `EPOLLET`, write
notifications are edge-triggered too. Cancel write interest when no longer needed.

kqueue stages changes and harvests events in **one `kevent()` call**. epoll applies
registrations immediately with `epoll_ctl`; `wait()` then calls `epoll_wait`.
Before closing a descriptor at the end-of-batch reap point, call `purgeFd` to
remove its staged changes/bookkeeping. Never apply stale changes after closing
or recycling a descriptor. `unmonitorRead` and `cancelWrite` are for descriptors
that remain open.

**A failed registration is never silent, on any backend.** Because epoll applies
registrations immediately, a kernel rejection — most notoriously `EPERM` for a
regular file, or `EBADF` for a closed descriptor — is stashed and returned as
`error.RegisterFailed` from the next non-empty `wait()` (an empty `wait` neither
consumes nor reports it). kqueue stages changes: a kernel-rejected change comes
back as an `Event` with `.err` set and the native errno in `.err_no` (and
`.readable`/`.writable` stay clear on such events), while an allocation failure
before the change ever reaches the kernel is stashed and returned as
`error.OutOfMemory` the same way. IOCP reports a failed association identically,
as `error.AssociateFailed` from the next non-empty `wait()`.

One divergence deserves emphasis portably: **epoll refuses regular files with
`EPERM`; kqueue accepts them and reports them perpetually ready.** A program
that registers inherited stdin/stdout without checking will work on FreeBSD and
hang on Linux unless it treats `wait()` errors as fatal. Classify such
descriptors first (`fstat`/`S_ISREG`) and write regular files directly, rather
than registering them.

### IOCP: completion

`monitorRead` associates an overlappable handle with the port; **it does not
submit a read**. New low-level callers can use fallible `associate` directly.
The socket companion associates its own handle at startup; callers must not
associate it again. A failed legacy `monitorRead` is reported by the next
nonempty `wait`, rather than silently dropped.
`wantWrite`, `cancelWrite`, `unmonitorRead` and `purgeFd` do not submit or cancel
Windows operations. `wait()` harvests completions with
`GetQueuedCompletionStatusEx`. Raw `Event.readable` and `Event.writable` remain
false. The owning stream must absorb `overlapped`, `bytes` and any error before
retrying its I/O state machine.

The extracted `born.socket.PlainNb` owns the overlapped connect/receive/send
machinery and receive/send buffers. Construct it **in place**: the stream may
not move while operations are pending. Sends copy a bounded chunk into owned
storage, so Winsock does not borrow the caller's source allocation. Even an
inline-successful Winsock operation queues a completion. On teardown, call
`cancelAndClose`, keep absorbing completions until `pendingOps() == 0`, then
`deinit` and free the stream. Closing the handle alone does not end the lifetime
of its `OVERLAPPED` storage.

Windows anonymous pipes from `std.process.Child` are **not overlappable**.
The TCP companion does not make those pipes IOCP-capable: use explicitly created
overlappable named pipes or a blocking-pipe relay, as mcp-bridge does.

### Common event surface

`born.Handle` is the native descriptor type (`std.posix.fd_t` or
`std.os.windows.HANDLE`). Every backend uses it for descriptor arguments.
`born.Event` has the same fields on every backend: `udata`, `readable`,
`writable`, `eof`, `err`, `err_no: usize`, `wake`,
`overlapped: ?*std.os.windows.OVERLAPPED`, and `bytes: usize`.
Completion fields are null/zero on POSIX. Error numbers are native errno on
kqueue and NTSTATUS on IOCP, not a portable error enumeration.

`wake()` may be called from another thread and produces `Event{ .wake = true }`.
POSIX wakeups coalesce; IOCP queues one completion per post. All other event-port
and socket operations belong to the owning loop thread.

## Raw readiness API (POSIX)

```zig
const born = @import("born");

var ep = try born.EvPort.init(allocator);
defer ep.deinit();

ep.monitorRead(fd, user_data);   // persistent, edge-triggered
ep.wantWrite(fd, user_data);     // kqueue one-shot; epoll until canceled
ep.cancelWrite(fd);
ep.unmonitorRead(fd);
ep.purgeFd(fd);
ep.wake();                       // from any thread

var events: [64]born.Event = undefined;
const n = try ep.wait(&events, timeout_ms);
```

`born.backend_name` reports which backend the build selected, so a program can
say what it is actually running on rather than what it assumes.

## Portable TCP companion

`born.socket` exports `PlainNb`, `NbRead`, `NbWrite`, `IoError` and
`CompletionKind`. It does not depend on OpenSSL, Schannel or mcp-bridge.

1. Initialize a stable `PlainNb{}` and call
   `startConnectInto(allocator, host, port, &ep, user_data)`.
2. Arm `ep.wantWrite(stream.handle(), user_data)` and wait for connect readiness
   or completion. Feed each event to
   `stream.absorbCompletion(event.overlapped, event.bytes, if (event.err) event.err_no else null)`
   before calling `connectDone`. Absorption is a no-op on POSIX.
3. Cancel connect write interest. On POSIX, call `ep.monitorRead` to register
   read interest; on Windows, startup already associated the socket, so do not
   register it again. Call `readNb` and `writeNb` to drive I/O, **including a first
   read before waiting** so Windows can post its receive. Retry after the matching
   event/completion. Drain reads and consume partial writes; arm write interest
   only on `want_write`.
4. `readNb` returns `data`, `want_read`, `want_write` or `eof`.
   `writeNb` returns `done`, `want_read` or `want_write`. Retry the same logical
   send until `done` accounts for its completed bytes; do not advance the write
   queue on `want_write`. Windows owns a copy of the submitted chunk.
5. At end-of-batch teardown, `ep.purgeFd(stream.handle())`, then
   `stream.cancelAndClose()`. Absorb all pending completions before `deinit`.
   `pendingOps` is zero on POSIX.

DNS resolution in `startConnectInto` uses the synchronous system resolver;
only socket connect/read/write are non-blocking. This API does not promise
asynchronous DNS, TLS, or arbitrary child-process I/O.

`src/socket_test.zig` exercises the same loopback lifecycle on all three backend
families and is the executable usage reference.

## Use

The original `v0.1.0` archive contains only the raw event port. Use a revision
containing the socket companion. Fetch the archive with `zig fetch` for its hash;
replace `master` with a full commit ID when pinning a consumer reproducibly.

```zig
// build.zig.zon
.dependencies = .{
    .born = .{ .url = "https://pacyworld.dev/pacyworld/born/archive/master.tar.gz", .hash = "..." },
},
```

```zig
// build.zig
const born = b.dependency("born", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("born", born.module("born"));
```

## Build

```
zig build            # library
zig build test       # backend, public API and socket tests for the selected target
zig build test -Doptimize=ReleaseSafe
zig build check-targets   # semantic compilation of test bodies for all seven triples
zig build test-bin -Dtarget=x86_64-windows-gnu --prefix zig-out/windows
zig build test-bin -Dtarget=x86_64-linux-gnu --prefix zig-out/linux
```

Requires Zig 0.15.2. The module propagates its libc or Winsock/kernel32 linkage.
Forgejo CI checks the exact toolchain version, runs FreeBSD Debug/ReleaseSafe
tests, compiles the seven-target test matrix and links Linux/Windows test
executables. `check-targets` is deliberately compile-only, not evidence that
target libraries link or that tests ran on those operating systems. Run the
`test-bin` output on its matching platform for runtime verification.

## Provenance

Extracted from [mcp-bridge](https://pacyworld.dev/buenapp/mcp-bridge), where
these backends have run in production since August 2026. They carry the scar
tissue to prove it:

- **epoll `EPOLLET` write deadlock.** Edge-triggering applies to the whole
  registration, so `EPOLLOUT` becomes edge-triggered once connect completes.
  The rule that fixes it: attempt writes first, wait only on a real
  `want_write`.
- **kqueue changelist batching.** A single rejected changelist entry makes the
  kernel abandon the rest of the batch — a 128-change batch can be silently
  truncated by one bad fd.
- **epoll swallowed `epoll_ctl` failures.** A rejected registration returned
  success and the event loop then waited forever on interest that was never
  armed — found in practice when a consumer's stdout was redirected to a
  regular file and `epoll_ctl` refused it with `EPERM` (issue #4). Registration
  failures are now surfaced on every backend: as a hard error from the next
  non-empty `wait()` on epoll and IOCP, and as an `err`/`err_no` event on
  kqueue.
- **FreeBSD loopback connect** can return `ECONNREFUSED` *synchronously* under
  load, so a non-blocking connect path must handle both refusal modes.

## Licence

BSD-3-Clause. Copyright (c) 2026, The Daniel Morante Company, Inc.
