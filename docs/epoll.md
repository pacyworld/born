# epoll backend

The epoll backend serves Linux. Like kqueue, it reports readiness and expects
callers to perform non-blocking I/O, but its registration and write-interest
rules differ.

## Registration and waiting

`monitorRead`, `wantWrite`, `cancelWrite`, and `unmonitorRead` apply changes
immediately with `epoll_ctl`. `wait()` calls `epoll_wait`; it does not batch
registrations as kqueue does. A rejected registration is stashed and returned
as `error.RegisterFailed` from the next non-empty `wait()`.

Read interest is persistent and edge-triggered. `EPOLLET` applies to the
entire registration, including `EPOLLOUT`. After connect or a partial write,
attempt the write before waiting. Once write interest is armed, it remains
armed until `cancelWrite`; waiting for another edge without first attempting
the write can deadlock progress.

Call `purgeFd` before closing a registered descriptor so its bookkeeping does
not survive descriptor reuse. Stale events already harvested in the current
batch remain possible and must be tolerated.

## Regular files

Raw epoll refuses regular files with `EPERM`. Born classifies that refusal and
keeps regular files out of the kernel epoll set, reporting them as always
ready through the portable event surface. This matches kqueue behavior for
non-blocking file I/O. Consumers stop registering a regular file at EOF to
avoid repeated immediate readiness.

## Child processes

`born.process.supported` describes target support; Linux `process.spawn` also
probes the running kernel. It uses a raw `clone(CLONE_PIDFD | SIGCHLD)` to
obtain a close-on-exec pidfd, then checks `waitid(P_PIDFD)` with `WNOHANG` and
`WNOWAIT`, which verifies the Linux 5.4 process-watching floor without
consuming an already-available exit status. `CLONE_PIDFD` itself dates from
Linux 5.2. If either required facility is unusable, spawn kills the unwatchable
child by PID, reaps it directly with a blocking `waitid(.PID, ...)`, and returns
`error.Unsupported`. `Child.kill` uses
`pidfd_send_signal`, avoiding PID-reuse races.

`watchProcess` first validates the descriptor with `pidfd_send_signal` signal
0. This rejects even pollable non-pidfds, such as pipes, as
`error.BadHandle`. The first watch creates one close-on-exec inner epoll set
per port and registers that set with the outer port as a level-triggered
internal source. Watched pidfds join the inner set for level-triggered
`EPOLLIN`; re-watching replaces `udata`. `unwatchProcess` removes a watch while
leaving the pidfd open, and `purgeFd` removes it before a close.

When the inner set is ready, `wait()` harvests as many pidfds as the output
buffer permits. Each is collected with
`waitid(P_PIDFD, WEXITED | WNOHANG)`, which both obtains the status and reaps
the child. A successful harvest emits one event with `exited` set and `exit`
containing the code or signal, removes the pidfd from the inner set, and ends
the watch. Ready pidfds that did not fit remain level-triggered and are
reported by a later `wait()`. A failed inner `epoll_wait` is stashed as
`error.SourceFailed` for the next `wait()`.

A Linux pidfd child is otherwise an ordinary child: it sends `SIGCHLD` as
usual, and a generic `waitpid(-1)` or `waitid` elsewhere in the application can
reap it first. If born then gets `ECHILD`, it emits one event with `exited` and
`err` set, `exit` null, and `err_no = ECHILD`. A readable pidfd with no
collectible status, for example when a tracer owns the status, has the same
shape with `err_no = 0`. Both cases end the watch so a permanently readable
pidfd cannot make `wait()` spin. After born reaps a reported exit, or after
an external wait reaps the child, `Child.kill` returns `error.Exited`.

`Child.close` sends `SIGKILL` through the pidfd and attempts a nonblocking
`waitid(P_PIDFD, WEXITED | WNOHANG)` reap. An available status is collected on
the spot, and an already-reaped child just has its pidfd closed. If the killed
child is still exiting, the pidfd is handed to a lazily started, detached
process-global reaper thread. That thread takes ownership of the descriptor,
performs the blocking `waitid`, and closes it. If the thread cannot be spawned
or its queue cannot allocate space, the handoff fails and `Child.close` itself
performs the blocking reap. Thus close normally avoids waiting for a running
child, but it is not unconditionally nonblocking, and the blocking fallback is
not limited to allocation failure.

The detached reaper consumes its queue oldest-first with blocking waits. One
child whose exit stalls therefore delays every later queued pidfd, a known
head-of-line limitation tracked as
[#52](https://pacyworld.dev/pacyworld/born/issues/52). On its first reaper
handoff after a fork, a child process discards inherited pending queue entries
before starting its own reaper: those pidfds name children of the parent,
which the forked child cannot reap.

The caller owns `Child.handle` until `Child.close`, or until a successful
reaper handoff transfers that ownership. `EvPort.deinit` removes and closes
only the inner epoll set and frees its watch map. It neither closes child
pidfds nor kills or finally reaps their processes, and it does not stop the
process-global reaper. Purge a watched pidfd and close the `Child` to finish
caller-owned cleanup.

## Wakeups and companion primitives

An eventfd provides cross-thread wakeups. POSIX wakeups coalesce and produce
`Event.wake`.

A level-triggered timerfd drives the shared deadline heap. A level-triggered
signalfd provides signal events; watched signals must be blocked in every
thread before the port starts watching them. Listener and stream events use
the same drain contracts as kqueue, but epoll does not provide portable
readiness counts, so `Event.avail` is zero.
