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

## Wakeups and companion primitives

An eventfd provides cross-thread wakeups. POSIX wakeups coalesce and produce
`Event.wake`.

A level-triggered timerfd drives the shared deadline heap. A level-triggered
signalfd provides signal events; watched signals must be blocked in every
thread before the port starts watching them. Listener and stream events use
the same drain contracts as kqueue, but epoll does not provide portable
readiness counts, so `Event.avail` is zero.
