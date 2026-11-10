# kqueue backend

The kqueue backend serves FreeBSD, macOS, NetBSD, and OpenBSD. It reports
readiness: callers perform non-blocking I/O and use events to decide when to
retry it.

## Registration and waiting

Read interest is persistent and edge-triggered with `EV_CLEAR`. A read handler
must drain until the non-blocking read reports that more data is required.
Write interest is one-shot: attempt the write first, arm it only after the
write would block, and arm it again after a later partial write.

Registrations are staged in the port. The next non-empty `wait()` submits the
staged changelist and collects the event list in one `kevent()` call. An empty
wait does not flush staged work. One-time setup and signal watch changes are
immediate exceptions where delaying them would lose or misdirect signals.

Before closing a descriptor, call `purgeFd` at the end-of-batch reap point.
This removes staged entries for the descriptor so they cannot affect a later
descriptor that reuses the same number. `unmonitorRead` and `cancelWrite` are
for descriptors that remain open.

## Errors and regular files

A kernel-rejected changelist entry arrives as an event with `err` set and the
native errno in `err_no`; readiness bits remain clear. An allocation failure
before submission is stashed and returned as `error.OutOfMemory` from the next
non-empty `wait()`. Registration failures are never discarded.

Regular files are native kqueue readiness sources and remain perpetually
ready. Consumers stop monitoring them at EOF to avoid a busy wait.

## Wakeups and companion primitives

FreeBSD and macOS use an `EVFILT_USER` knote for cross-thread wakeups.
NetBSD and OpenBSD use a non-blocking pipe because they lack `EVFILT_USER`.
POSIX wakeups coalesce, and `Event.wake` identifies the resulting event.

Timers use `EVFILT_TIMER`; signals use `EVFILT_SIGNAL` with the signal
ownership rules in the README. Listeners report pending connection counts in
`Event.avail`, and streams report readable byte counts where the kernel
provides them. These counts are hints that can avoid a trailing `EAGAIN`
call; they do not weaken the drain contract.
