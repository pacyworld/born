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

### Runtime evidence

CI runs the test suite on FreeBSD, Linux and Windows for every push and pull
request (procedure in `AGENTS.md`). This table records the last run on each
OS per primitive, and lists real runs only.

| backend | primitive | last runtime run | date | commit |
|---|---|---|---|---|
| kqueue, FreeBSD 15 (runner01) | event port, wake, plain TCP stream | [run 39, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/39/jobs/0): Debug and ReleaseSafe, 29 passed, 26 skipped, 0 failed | 2026-10-18 | [3ed3785](https://pacyworld.dev/pacyworld/born/commit/3ed378538592c0f8c3a0598c957409dd6becfd57) |
| epoll, Linux 6.8 (runner03, Ubuntu 24.04) | event port, wake, plain TCP stream | [run 39, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/39/jobs/1): ReleaseSafe, 28 passed, 26 skipped, 0 failed | 2026-10-18 | [3ed3785](https://pacyworld.dev/pacyworld/born/commit/3ed378538592c0f8c3a0598c957409dd6becfd57) |
| IOCP, Windows Server 2022 build 20348 (runner02) | event port, wake, plain TCP stream | [run 39, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/39/jobs/2): ReleaseSafe, 21 passed, 27 skipped, 0 failed | 2026-10-18 | [3ed3785](https://pacyworld.dev/pacyworld/born/commit/3ed378538592c0f8c3a0598c957409dd6becfd57) |
| epoll, Linux 6.8 (runner03, Ubuntu 24.04) | signals (signalfd) | [run 51, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/51/jobs/1): ReleaseSafe, 53 passed, 18 skipped, 0 failed | 2026-10-19 | [af7d004](https://pacyworld.dev/pacyworld/born/commit/af7d0046630ed67698570b6b9fd261b6e659c3a7) |
| IOCP, Windows Server 2022 build 20348 (runner02) | timers (thread-pool timer) | [run 75, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/75/jobs/2): ReleaseSafe, 49 passed, 20 skipped, 0 failed | 2026-10-20 | [27c7357](https://pacyworld.dev/pacyworld/born/commit/27c735706b9b3e8f29adcf966ba62b4dfe3b8c4a) |
| epoll, Linux 6.8 (runner03, Ubuntu 24.04) | timers (timerfd plus deadline heap) | [run 61, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/61/jobs/1): ReleaseSafe, 67 passed, 9 skipped, 0 failed | 2026-10-19 | [efa2d93](https://pacyworld.dev/pacyworld/born/commit/efa2d93497abf0ca4d52fe500a6094a9dc1b5888) |
| IOCP, Windows Server 2022 build 20348 (runner02) | signals (console control events) | [run 81, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/81/jobs/2): ReleaseSafe, 36 passed, 25 skipped, 0 failed | 2026-10-20 | [f2229c6](https://pacyworld.dev/pacyworld/born/commit/f2229c68d7e32f718e34f6b5c563461b993b61b9) |
| IOCP, Windows 11 build 26100 (win11-dev, manual) | signals (console control events) | born-tests.exe Debug and ReleaseSafe over OpenSSH: 36 passed, 25 skipped, 0 failed each | 2026-10-20 | [f2229c6](https://pacyworld.dev/pacyworld/born/commit/f2229c68d7e32f718e34f6b5c563461b993b61b9) |
| IOCP, Windows Server 2022 build 20348 (runner02) | TCP listener (AcceptEx) | [run 64, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/64/jobs/2): ReleaseSafe, 38 passed, 26 skipped, 0 failed | 2026-10-20 | [8eca1d3](https://pacyworld.dev/pacyworld/born/commit/8eca1d3e226b14d5120a84192b2aa0779d50884a) |
| kqueue | Unix sockets | none: not implemented yet, their contract tests skip | n/a | n/a |
| epoll | Unix sockets | none: not implemented yet, their contract tests skip | n/a | n/a |
| IOCP | Unix sockets | none: not implemented yet, their contract tests skip | n/a | n/a |

Commit 3ed3785 changes only the CI workflow; its library and tests are
those of master d1017b8. Skips are platform-only tests and the 0.3.0
contract tests that wait for their implementations.

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

**A failed registration is never silent, on any backend.** A rejected
registration — `EBADF` for a dead descriptor, or any other refusal epoll or
kqueue might return — is stashed and returned as `error.RegisterFailed` from
the next non-empty `wait()` on epoll (an empty `wait` neither consumes nor
reports it), matching how IOCP reports a failed association as
`error.AssociateFailed`. kqueue stages changes: a kernel-rejected change comes
back as an `Event` with `.err` set and the native errno in `.err_no` (and
`.readable`/`.writable` stay clear on such events), while an allocation failure
before the change ever reaches the kernel is stashed and returned as
`error.OutOfMemory` the same way epoll stashes its rejections.

**Regular files work identically on every POSIX backend.** I/O on a regular
file never blocks, so "always ready" is the correct answer. kqueue accepts
regular files natively; epoll's raw `epoll_ctl` refuses them with `EPERM`, so
the epoll backend emulates kqueue: a regular file is detected at registration
(`fstat`/`S_ISREG`), kept out of the kernel's epoll set, and reported ready —
readable and/or writable per its interest — by every `wait()`. Consumers must
therefore stop registering a regular file once it reaches EOF, on both
backends, or `wait()` keeps answering instantly (true under kqueue already).

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
retrying its I/O state machine. `post()` — including `wake()` — is callable from
any thread; a failed `PostQueuedCompletionStatus` is never dropped silently: it
is stashed atomically and returned as `error.PostFailed` from the next non-empty
`wait()` (when the failed post was itself a wake, the error arrives with the
next naturally-arriving completion).

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
`overlapped: ?*std.os.windows.OVERLAPPED`, `bytes: usize`, and the 0.3.0
fields `timer: bool`, `signal: ?born.Signal` and `fired: u32` (see
[Planned in 0.3.0](#planned-in-030)), which stay false, null and zero for
every other event.
Completion fields are null/zero on POSIX. Error numbers are native errno on
kqueue and NTSTATUS on IOCP, not a portable error enumeration.

Each `EvPort` operation returns its own error set: `born.InitError` from
`init`, `born.WaitError` from `wait`, `born.TimerError` and
`born.SignalError` from the 0.3.0 calls. `born.Error` is their union. `wait`
reports only loop failures (including stashed registration failures), never
a refused timer or signal.

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

`born.socket` exports `PlainNb`, `NbRead`, `NbWrite`, `CompletionKind` and
one error set per operation: `ConnectError` (`startConnectInto`),
`ConnectDoneError` (`connectDone`), `ReadError` (`readNb`) and `WriteError`
(`writeNb`). Each holds exactly what that call can return, so a consumer can
switch over it with no `else` prong and a later change in born fails the
consumer's build instead of reaching `unreachable`. `IoError` (also
`PlainNb.Error`) is their union, a catch-all that may grow. It does not
depend on OpenSSL, Schannel or mcp-bridge.

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

## Planned in 0.3.0

The 0.3.0 workstream ([#24](https://pacyworld.dev/pacyworld/born/issues/24))
adds four primitives. Their signatures are in place and documented in the
source, but every backend still returns `error.Unsupported` until the
implementation issue for that backend lands. The contract tests
(`src/timer_test.zig`, `src/signal_test.zig`, `src/listener_test.zig`,
`src/unix_test.zig`) skip until then.

- **Timers:** `EvPort.addTimer(id, udata, after_ms, .once or .repeat)` and
  `cancelTimer(id)`, delivered as `Event{ .timer = true, .fired = n }`.
  kqueue ([#12](https://pacyworld.dev/pacyworld/born/issues/12)), epoll
  ([#13](https://pacyworld.dev/pacyworld/born/issues/13)) and IOCP
  ([#14](https://pacyworld.dev/pacyworld/born/issues/14)), with a shared
  deadline heap ([#11](https://pacyworld.dev/pacyworld/born/issues/11)).
- **Signals:** `EvPort.watchSignal(sig, udata)`, `unwatchSignal(sig)` and
  `born.blockSignals(sigs)`, delivered as `Event{ .signal = sig, .fired = n }`
  for `interrupt`, `terminate`, `hangup`, `user1` and `user2`. kqueue
  ([#15](https://pacyworld.dev/pacyworld/born/issues/15)), epoll
  ([#16](https://pacyworld.dev/pacyworld/born/issues/16)) and Windows console
  events ([#17](https://pacyworld.dev/pacyworld/born/issues/17)).
- **TCP listeners:** `born.socket.Listener.openTcp(addr, opts)`, `register`,
  `acceptNb(stream, key)` until `.want_accept`, `localAddress` and `close`,
  with `ListenOptions.reuse_port = .balanced`. POSIX
  ([#18](https://pacyworld.dev/pacyworld/born/issues/18)) and Windows
  AcceptEx ([#19](https://pacyworld.dev/pacyworld/born/issues/19)).
- **Unix domain stream sockets:** `Listener.openUnix(path, opts)` and
  `PlainNb.startConnectUnixInto(path, ...)`. POSIX
  ([#20](https://pacyworld.dev/pacyworld/born/issues/20)) and Windows
  ([#21](https://pacyworld.dev/pacyworld/born/issues/21), may follow 0.3.0).

Rules every implementation follows:

- **Timers are for deadlines, never for driving I/O:** idle timeouts, expiry
  sweeps, periodic aggregation. Born's rule against timer-driven I/O stands.
- **Timer and signal events arrive through `wait()` like any other event.**
  There are no callbacks, and no extra threads on POSIX. On IOCP a thread-pool
  timer or console handler may only `post()`.
- **Stale events:** an event already harvested in the current batch can
  still name a timer or signal that was cancelled or unwatched during that
  batch. Tolerate it, as for a purged descriptor.
- **Timer ids** are caller-chosen and unique per port; re-adding a live id
  replaces it. Cancelling an unknown or expired id is a no-op. A `.once`
  timer with `after_ms = 0` is due at the next `wait()`; a `.repeat` timer
  with `after_ms = 0` is `error.InvalidArgument`.
- **Signals are process-wide.** At most one port watches a given signal; a
  second gets `error.SignalInUse`. On epoll the signal must be blocked in
  every thread (signalfd), so call `born.blockSignals` in `main` before
  spawning threads; `watchSignal` reports `error.SignalNotBlocked` otherwise.
  On kqueue and Windows `blockSignals` is a no-op, so portable programs call
  it unconditionally. Unwatching restores the prior disposition.
- **Windows signals are console control events:** CTRL_C_EVENT is
  `.interrupt`; CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT and CTRL_SHUTDOWN_EVENT
  are `.terminate`. `.hangup`, `.user1` and `.user2` are `error.Unsupported`,
  and so is every signal in a process without a console (a service or GUI
  program). After CTRL_CLOSE_EVENT or CTRL_SHUTDOWN_EVENT the system ends
  the process when the program exits or after its timeout (5 s for a closed
  console window): finish shutdown within that time. Watching `.interrupt`
  clears an inherited CTRL+C ignore flag; unwatching sets it again. Changing
  the process's console (FreeConsole, AllocConsole, AttachConsole) drops
  every watch without an error born could detect, so change consoles before
  watching, or unwatch every signal and watch again. A port must not move
  while it watches a signal.
- **`.balanced` reuse-port** means the kernel spreads connections across
  listeners on one port: `SO_REUSEPORT_LB` on FreeBSD, `SO_REUSEPORT` on
  Linux. Where the platform can only share a port without balancing (macOS,
  NetBSD, OpenBSD) or not at all (Windows), it is `error.Unsupported`.
- **Accept drain:** on POSIX, call `acceptNb` until `.want_accept` on every
  listener event; descriptor exhaustion is `error.ResourceExhausted`, the
  signal to pause the listener with `unmonitorRead`. On Windows, feed listener
  completions to `Listener.absorbCompletion` first, and on teardown absorb
  until `pendingOps() == 0`, as for `PlainNb`.
- **Unix socket paths** that do not fit `sun_path` are `error.NameTooLong`,
  never truncated. `unlink_stale` replaces a socket file that refuses
  connections and never unlinks a live listener (`error.AddressInUse`) or a
  non-socket file (`error.PathNotASocket`). The mode is applied before
  `listen`, so there is no window with wider permissions.
- **Nothing fails silently:** every refusal reaches the caller as an error
  from the call, or from the next `wait()` for deferred registrations.

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
tests, compiles the seven-target test matrix, links the Linux/Windows test
executables and runs them on an Ubuntu 24.04 and a Windows Server 2022 runner.
`check-targets` is deliberately compile-only, not evidence that target
libraries link or that tests ran on those operating systems. Outside CI, run
the `test-bin` output on its matching platform (hosts in `AGENTS.md`).

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
  rejections are now surfaced as hard errors on every backend, and regular
  files specifically are carried as always-ready pseudo registrations so the
  redirected-stdout case works on Linux exactly as under kqueue.
- **FreeBSD loopback connect** can return `ECONNREFUSED` *synchronously* under
  load, so a non-blocking connect path must handle both refusal modes.

## Licence

BSD-3-Clause. Copyright (c) 2026, The Daniel Morante Company, Inc.
