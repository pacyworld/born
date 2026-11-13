# born

An event port for Zig: one small, uniform seam over the platform's native
readiness/completion notification mechanism.

Named for the Born rule: I/O waits in potential until `wait()` collapses it
into a concrete event.

| checked target triple | backend | runtime status |
|---|---|---|
| `x86_64-freebsd` | kqueue | original backend in production since 2026-08 |
| `x86_64-linux-gnu` | epoll + eventfd | original backend in production since 2026-08 |
| `aarch64-macos` | kqueue | tested on macOS 26 arm64; see runtime evidence |
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
| kqueue, FreeBSD 15 (runner01) | Unix domain stream sockets | [run 70, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/70/jobs/0): Debug and ReleaseSafe, 81 passed, 4 skipped, 0 failed | 2026-10-19 | [86ef7ec](https://pacyworld.dev/pacyworld/born/commit/86ef7ec20f50151e4719254a79d590b7feb7f4ba) |
| epoll, Linux 6.8 (runner03, Ubuntu 24.04) | Unix domain stream sockets | [run 70, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/70/jobs/1): ReleaseSafe, 65 passed, 13 skipped, 0 failed | 2026-10-19 | [86ef7ec](https://pacyworld.dev/pacyworld/born/commit/86ef7ec20f50151e4719254a79d590b7feb7f4ba) |
| kqueue, FreeBSD 15 (runner01) | readiness counts, EVFILT_USER wake | [run 102, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/102/jobs/0): Debug and ReleaseSafe, 91 passed, 6 skipped, 0 failed | 2026-10-22 | [0b1ec8e](https://pacyworld.dev/pacyworld/born/commit/0b1ec8edb100dd8484f002227bc2a5544ec548ef) |
| epoll, Linux 6.8 (runner03, Ubuntu 24.04) | readiness hints without counts (drain contract) | [run 102, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/102/jobs/1): ReleaseSafe, 87 passed, 6 skipped, 0 failed | 2026-10-22 | [0b1ec8e](https://pacyworld.dev/pacyworld/born/commit/0b1ec8edb100dd8484f002227bc2a5544ec548ef) |
| kqueue, macOS 26.1 arm64 (macinotsh-desktop, manual) | tri-toolchain compat, event port, readiness counts, EVFILT_USER wake | born-tests ReleaseSafe on Zig 0.15.2, 0.16.0, and 0.17.1: 116 passed, 24 skipped, 0 failed each | 2026-11-11 | [d65e2fe](https://pacyworld.dev/pacyworld/born/commit/d65e2fe0a07e45877b20ea299f8e736978a0dbe9) |
| IOCP, Windows Server 2022 build 20348 (runner02) | no-op readiness hints | [run 134, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/134/jobs/2): ReleaseSafe, 74 passed, 25 skipped, 0 failed; hint no-op test passed | 2026-11-10 | [1aaf70e](https://pacyworld.dev/pacyworld/born/commit/1aaf70e9d5f61dc8bb4a92aee3f2ca4682057b4c) |
| IOCP, Windows Server 2022 build 20348 (runner02) | Unix sockets: unsupported contract | [run 134, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/134/jobs/2): ReleaseSafe, 74 passed, 25 skipped, 0 failed; Unsupported test passed, lifecycle tests skip | 2026-11-10 | [1aaf70e](https://pacyworld.dev/pacyworld/born/commit/1aaf70e9d5f61dc8bb4a92aee3f2ca4682057b4c) |
| kqueue, FreeBSD 15 (runner01) | process descriptors (pdfork, EVFILT_PROCDESC) | [run 127, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/127/jobs/0): Debug and ReleaseSafe, 108 passed, 8 skipped, 0 failed | 2026-11-09 | [6f4f6ed](https://pacyworld.dev/pacyworld/born/commit/6f4f6ed776306c37e5beaa4cd238263cb980d1be) |
| epoll, Linux 6.8 (runner03, Ubuntu 24.04) | process descriptors (pidfd, waitid) | [run 127, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/127/jobs/1): ReleaseSafe, 104 passed, 7 skipped, 0 failed | 2026-11-09 | [6f4f6ed](https://pacyworld.dev/pacyworld/born/commit/6f4f6ed776306c37e5beaa4cd238263cb980d1be) |
| IOCP, Windows Server 2022 build 20348 (runner02) | process descriptors: unsupported contract | [run 134, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/134/jobs/2): ReleaseSafe, 74 passed, 25 skipped, 0 failed; Unsupported test passed | 2026-11-10 | [1aaf70e](https://pacyworld.dev/pacyworld/born/commit/1aaf70e9d5f61dc8bb4a92aee3f2ca4682057b4c) |

Commit 3ed3785 changes only the CI workflow; its library and tests are
those of master d1017b8. Skips identify platform exclusions or primitives
not implemented at the recorded commit.

## Programming model

The raw event port has a uniform **type surface**, not identical I/O semantics.
Use `born.socket.PlainNb` for the portable plain-TCP companion. TLS, certificate
validation, HTTP and application logging are outside born. Backend-specific
design rationale is in [docs/](docs/README.md); `zig build docs` generates
declaration-level API documentation. The std.Io analysis includes a
[VTable gap map](docs/born-vtable-gap.md) and
[design lessons](docs/learned-from-ioloop.md).

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

**Registration failure reporting.** A rejected
registration, including `EBADF` for a dead descriptor or any other refusal
epoll or kqueue might return, is stashed and returned as
`error.RegisterFailed` from the next non-empty `wait()` on epoll (an empty
`wait` neither consumes nor reports it), matching how IOCP reports a failed
association as `error.AssociateFailed`. kqueue stages changes: a
kernel-rejected change comes back as an `Event` with `.err` set and the native
errno in `.err_no` (and
`.readable`/`.writable` stay clear on such events), while an allocation failure
before the change ever reaches the kernel is stashed and returned as
`error.OutOfMemory` the same way epoll stashes its rejections.

On kqueue, each submission is bounded to the available event slots. Every
rejected change has room for its `EV_ERROR` record. `wait()` submits every
staged change before it blocks. Earlier records are returned first, and the
next wait continues with any remaining changes. See
[kqueue backend rationale](docs/kqueue.md) for the complete contract.

**Regular files work identically on every POSIX backend.** I/O on a regular
file never blocks, so "always ready" is the correct answer. kqueue accepts
regular files natively; epoll's raw `epoll_ctl` refuses them with `EPERM`, so
the epoll backend emulates kqueue: the `EPERM` refusal classifies an
unpollable descriptor, which is kept out of the kernel's epoll set and reported
ready by every `wait()`, readable and/or writable per its interest. Consumers
must therefore stop registering a regular file once it reaches EOF, on both
backends, or `wait()` keeps answering instantly (true under kqueue already).

### IOCP: completion

`monitorRead` associates an overlappable handle with the port; **it does not
submit a read**. New low-level callers can use fallible `associate` directly.
The socket companion associates its own handle at startup; callers must not
associate it again. A failed `monitorRead` association is reported by the next
nonempty `wait`, rather than silently dropped.
`wantWrite`, `cancelWrite`, `unmonitorRead` and `purgeFd` do not submit or cancel
Windows operations. `wait()` harvests completions with
`GetQueuedCompletionStatusEx`. Raw `Event.readable` and `Event.writable` remain
false. The owning stream must absorb `overlapped`, `bytes` and any error before
retrying its I/O state machine. `post()` and `wake()` are callable from any
thread; a failed `PostQueuedCompletionStatus` is never dropped silently: it
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

Windows anonymous pipes for application-created children, such as those from
`std.process.Child`, are **not overlappable**. The TCP companion does not make
those pipes IOCP-capable: use explicitly created overlappable named pipes or a
blocking-pipe relay, as mcp-bridge does. This is separate from
`born.process.spawn`, which is unsupported on Windows.

### Common event surface

`born.Handle` is the native descriptor type (`std.posix.fd_t` or
`std.os.windows.HANDLE`). Every backend uses it for descriptor arguments.
`born.Event` has the same fields on every backend: `udata`, `readable`,
`writable`, `eof`, `err`, `err_no: usize`, `wake`,
`overlapped: ?*std.os.windows.OVERLAPPED`, `bytes: usize`, the timer and
signal fields `timer: bool`, `signal: ?born.Signal` and `fired: u32` (see
[primitive contracts](#primitive-contracts)), which stay false, null and zero
for every other event, `avail: usize`, the readiness count (see
[Readiness counts](#readiness-counts)), and `exited: bool` with
`exit: ?born.ProcessExit` for a watched process (see
[Child processes](#child-processes)).
Completion fields are null/zero on POSIX. Error numbers are native errno on
kqueue and NTSTATUS on IOCP, not a portable error enumeration.

Each `EvPort` operation returns its own error set: `born.InitError` from
`init`, `born.WaitError` from `wait`, `born.TimerError` from timer calls,
`born.SignalError` from signal calls, and `born.ProcessError` from
`watchProcess`. `born.Error` is their union. `wait` reports only loop
failures (including stashed registration failures), never a refused timer,
signal, or process watch.

`wake()` may be called from another thread and produces `Event{ .wake = true }`.
POSIX wakeups coalesce; IOCP queues one completion per post. All other event-port
and socket operations belong to the owning loop thread.

How a POSIX port wakes: FreeBSD and macOS use one `EVFILT_USER` knote
(`EV_CLEAR`) that `init` registers with an immediate `kevent()`, as one-time
setup, so a `wake()` from another thread before the first `wait()` is not lost.
`wake()` is a `NOTE_TRIGGER` `kevent()` with no event list. That call is a
cross-thread trigger, not a registration, so the rule that kqueue
registrations are staged into `wait()` does not apply to it. It needs no
descriptors besides the kqueue and no drain `read()`. A trigger the kernel
refuses is reported by the next non-empty `wait()` as `error.WaitFailed`.
NetBSD and OpenBSD have no `EVFILT_USER` and keep the non-blocking pipe, and
epoll uses an eventfd. Measured on FreeBSD (`bench/RESULTS.md`): a wake round
trip between two threads costs 4 syscalls instead of 8 and p50 falls from 14.8
to 11.8 us.

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

A non-null `timeout_ms` must be nonnegative; `null` waits indefinitely.

`born.backend_name` reports which backend the build selected, so a program can
say what it is actually running on rather than what it assumes.

## Portable TCP companion

`born.socket` exports `PlainNb`, `NbRead`, `NbWrite`, `CompletionKind` and
one error set per operation: `ConnectError` (`startConnectInto`),
`ConnectDoneError` (`connectDone`), `ReadError` (`readNb`) and `WriteError`
(`writeNb`). Each holds exactly what that call can return, so a consumer can
switch over it with no `else` prong and a later change in born fails the
consumer's build instead of reaching `unreachable`. `IoError` (also
`PlainNb.Error`) is their union, including Unix connects and accepted-stream
adoption, and is a catch-all that may grow. It does not depend on OpenSSL,
Schannel or mcp-bridge.

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
asynchronous DNS, TLS, or arbitrary child-process I/O. From an event loop,
resolve names on another thread and connect with
`startConnectAddrInto(address, &ep, user_data)`: the same steps as above,
with no resolver and no allocator, failing only with `ConnectAddrError`
(`ConnectFailed`, `SocketError`).

`src/socket_test.zig` exercises the same loopback lifecycle on all three backend
families and is the executable usage reference.

### Readiness counts

On kqueue a readable event carries the kernel's count in `Event.avail`: bytes
buffered on a stream, connections queued on a listener. It is 0 where the
count is unknown (always on epoll and IOCP, and on any other event).
`PlainNb.hintReadable(event)` and `Listener.hintReadable(event)` record it, and
`readNb` / `acceptNb` then answer `.want_read` / `.want_accept` without the
call that could only return EAGAIN once that many bytes or connections were
taken. The drain-to-EAGAIN contract is unchanged: with no hint the calls drain
exactly as before, and stopping at the count never strands data because
anything arriving after the kernel took the count raises a new edge.

- Call `hintReadable` on every readable event before the first read or
  accept. Each event replaces the previous count; a count outliving a
  partial drain would strand the rest.
- An EOF event is not hinted (`readNb` keeps reading until it returns `.eof`),
  and every error, EAGAIN or `ResourceExhausted` path clears the hint.
- On IOCP, `hintReadable` is a no-op.

Measured on the loopback benchmark (`bench/RESULTS.md`): one syscall less per
echo and about two less per connection in the accept storm.

## Child processes

`born.process.supported` reports compile-time target support on FreeBSD and
Linux. Linux additionally probes the required pidfd and `waitid(P_PIDFD)`
facilities at spawn and returns `error.Unsupported` on kernels older than 5.4.

`born.process.spawn(argv, envp, opts)` starts a program and returns a
`Child{ .handle, .pid }`; `ep.watchProcess(child.handle, udata)` delivers its
exit through `wait()` as `Event{ .exited = true, .exit = .{ .code = n } }` or
`.exit = .{ .signal = n }`. `src/process_test.zig` is the usage reference.

```zig
const argv = [_:null]?[*:0]const u8{ "/usr/local/bin/role", "--worker" };
var child = try born.process.spawn(&argv, envp, .{
    .stdin = .devnull,
    .fds = &.{ listener_fd, control_fd }, // the child's fds 3 and 4
});
try ep.watchProcess(child.handle, &role);
// ... wait() returns Event{ .exited = true, .exit = ..., .udata = &role }
ep.purgeFd(child.handle);
child.close();
```

| backend | descriptor | exit event | reaping |
|---|---|---|---|
| kqueue, FreeBSD | process descriptor from `pdfork(PD_CLOEXEC)` | EVFILT_PROCDESC NOTE_EXIT, staged into the next `wait()` | unless externally reaped, the zombie stays until the last process descriptor closes; born never calls `wait(2)` |
| epoll, Linux 5.4+ | pidfd from `clone(CLONE_PIDFD)` | pidfd readable, harvested through one internal epoll set | the `wait()` that reports the exit reaps it with `waitid(P_PIDFD)` |
| IOCP; kqueue on macOS, NetBSD, OpenBSD | none | spawn and watch return `error.Unsupported` | n/a |

- **Born's successful spawn and setup path takes no allocator and performs no
  user-space heap allocation:** argv and envp are the caller's NUL-terminated
  arrays, and the fixed descriptor plan is ready before the fork. There is no
  PATH search (`opts.path` or argv[0] is the program). Between fork and execve the child
  makes only async-signal-safe calls. FreeBSD libthr also runs the
  application's `pthread_atfork` handlers around `pdfork`; born registers
  none, and application handlers must obey the same child-side rule for a
  multi-threaded caller to be safe.
- **The child starts with a controlled descriptor and signal state:** it gets
  `stdin`, `stdout` and `stderr` as asked (`.inherit`, `.devnull` or a handle)
  and `opts.fds[i]` as fd 3 + i, up to `born.process.max_fds`; every other
  descriptor is closed. It resets signal dispositions to their defaults and
  enters execve with an empty signal mask, whatever the parent blocks or
  ignores, except that FreeBSD accepts `EINVAL` for libthr-reserved signals
  whose dispositions cannot be reset. A parent that blocks signals for epoll's
  signalfd still has children that SIGTERM ends.
- **Errors are never lost:** a close-on-exec pipe carries a setup or execve
  failure back, so `spawn` returns `FileNotFound`, `AccessDenied`,
  `InvalidExe`, `SetupFailed` (for example a mapped handle that is not open),
  `SystemResources` or `ExecFailed`. It calls `Child.close` for the failed
  child, applying the descriptor-close rules below instead of returning a live
  handle. On success it returns once the child has called execve, as
  `posix_spawn` does.
- **The watch ends with the exit event**, which arrives once. A watch added
  after the process exited fires at the next `wait()`. Re-watching replaces
  the udata; `unwatchProcess` ends a watch on a handle that stays open, and
  before closing, `purgeFd(handle)` is enough, as for any descriptor. Stale
  exit events are tolerated as for timers and signals.
- **Descriptor close has platform-specific reaping rules.** FreeBSD retains an
  exited child as a zombie until its last process descriptor closes, even
  after an exit event. Closing the last descriptor of a running child kills it
  with SIGKILL and leaves init to reap it asynchronously. Linux `close` sends
  SIGKILL, makes a nonblocking `waitid` attempt, and reaps on the spot when a
  status is already available. A still-exiting child's pidfd goes to a lazily
  spawned detached reaper thread. If that thread cannot be spawned or its
  queue cannot allocate space, `close` itself falls back to a blocking reap;
  it is therefore not unconditionally nonblocking. The reaper drains
  oldest-first, so one stalled exit delays later entries (#52). Loop code
  should `child.kill(sig)`, wait for the exit event, then `purgeFd` and `close`,
  which keeps reaping on the spot.
- **kill** signals through the descriptor, so it never reaches a recycled
  pid. After born reaps a reported exit, or after an external wait reaps the
  child, Linux answers `error.Exited`; a FreeBSD zombie accepts and ignores
  signals while it remains.
- **wait(2) elsewhere in the program:** a pdfork child sends no SIGCHLD and
  is invisible to a generic wait for children. A Linux pidfd child is an
  ordinary child and sends SIGCHLD as usual: a `waitpid(-1)` elsewhere can reap
  it first, and its exit event then arrives with `exited` and `err` set, `exit`
  null and `err_no` = ECHILD. A readable pidfd whose status belongs to a tracer
  produces the same event shape with `err_no` = 0. Either error event ends the
  watch. A failed harvest of the internal process set is `error.SourceFailed`
  from `wait()`.
- **Ownership stays explicit:** `EvPort.deinit` releases port-owned watch
  sources and bookkeeping but does not close `Child.handle`, kill the child,
  or perform its final reap. The caller purges and closes the child unless a
  successful Linux reaper handoff has already transferred descriptor ownership
  to that reaper.

## Timers, signals, listeners, and Unix sockets

Born's timer, signal, TCP listener, and Unix domain socket primitives share
the event port's `wait()` model. Their contract tests (`src/timer_test.zig`,
`src/signal_test.zig`, `src/listener_test.zig`, and `src/unix_test.zig`)
exercise each implemented backend. Windows Unix domain sockets return
`error.Unsupported` and their contract tests skip on that backend.

### Timers

`EvPort.addTimer(id, udata, after_ms, .once or .repeat)` and `cancelTimer(id)`
deliver `Event{ .timer = true, .fired = n }` through `wait()`.

### Signals

`EvPort.watchSignal(sig, udata)`, `unwatchSignal(sig)`, and
`born.blockSignals(sigs)` deliver `Event{ .signal = sig, .fired = n }` for
`interrupt`, `terminate`, `hangup`, `user1`, and `user2`. Windows maps console
control events onto this surface and rejects signals it cannot represent.

### TCP listeners

`born.socket.Listener.openTcp(addr, opts)`, `register`,
`acceptNb(stream, key)`, `localAddress`, and `close` provide non-blocking TCP
accept on POSIX and Windows. `ListenOptions.reuse_port = .balanced` requests
kernel-balanced listener sharing where supported.

### Unix domain stream sockets

POSIX provides `Listener.openUnix(path, opts)` and
`PlainNb.startConnectUnixInto(path, ...)`. Windows returns
`error.Unsupported` for these operations.

### Primitive contracts

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
  `listen`, so there is no window with wider permissions. On POSIX the
  stale check is a datagram connect probe, so a live listener with a full
  backlog is never mistaken for a stale file, and `close` removes the path
  only from the process that bound it and only while it is still that file.
- **Nothing fails silently:** every refusal reaches the caller as an error
  from the call, or from the next `wait()` for deferred registrations.

## Use

Fetch the archive with `zig fetch` for its hash. Replace `master` with a full
commit ID when pinning a consumer reproducibly.

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
zig build docs            # API documentation in zig-out/docs/index.html
zig build test-bin -Dtarget=x86_64-windows-gnu --prefix zig-out/windows
zig build test-bin -Dtarget=x86_64-linux-gnu --prefix zig-out/linux
```

Born supports Zig 0.15.2, 0.16.0, and 0.17.1. `src/compat.zig` owns native ABI
and toolchain-version differences; core code does not depend on `std.Io`.
TCP companions accept `born.socket.Address`, Born's native sockaddr union, on
all three toolchains. Callers using `std.net.Address` must migrate to this type.

The module propagates its libc or Winsock/kernel32 linkage. Forgejo CI
(`.forgejo/workflows/ci.yml`) runs a toolchain matrix over Zig 0.15.2, 0.16.0,
and 0.17.1: each toolchain runs the FreeBSD Debug and ReleaseSafe suites
(kqueue), compiles the seven-target test matrix, generates API documentation,
and cross-builds the Linux and Windows test executables in both optimize modes.
The Linux (epoll, Ubuntu 24.04) and Windows (IOCP, Windows Server 2022) runtime
jobs run those executables per toolchain and optimize mode, verifying each
executable's SHA-256 against the build. A single Zig 0.15.2 `zig fmt --check`
gate carries formatting and README/AGENTS consistency; there is deliberately no
fmt matrix, because the 0.17.1 formatter rewrites enum builtins unavailable in
0.15.2. `check-targets` is deliberately compile-only, not evidence that target
libraries link or that tests ran on those operating systems. Outside CI, run
the `test-bin` output on its matching platform (hosts in `AGENTS.md`).

Two scheduled gates run weekly and on dispatch, separate from the per-commit
CI. `stress.yml` runs the suite 500 times under bounded CPU load on FreeBSD and
Linux (the #45 repro shape; a failure is a release blocker). `bench.yml` runs
the kqueue benchmark on a quiet runner01 and fails on a syscall or latency
regression against `bench/thresholds.txt` (#31). macOS Apple Silicon stays a
manual harness (`AGENTS.md`).

## Provenance

Born was extracted from [mcp-bridge](https://pacyworld.dev/buenapp/mcp-bridge),
where these backends have run in production since August 2026. The backend
chapters in [docs/](docs/README.md) describe their current registration,
error-surfacing, and object-lifetime contracts.

## Licence

BSD-3-Clause. Copyright (c) 2026, The Daniel Morante Company, Inc.
