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

While eventlist space remains, the kernel copies each rejected change as
`EV_ERROR` and continues processing changes in order. If a rejected change
finds no eventlist slot, `kevent()` returns `-1` with that change's errno and
leaves subsequent changes unprocessed. Earlier changes and copied error
records are not rolled back. `EV_RECEIPT` records consume the same slots.

Born submits at most one change per available event slot, up to 64. Every
rejected change therefore has room for its `EV_ERROR` record. Results are
returned in order, and any remaining changes stay staged for the next wait.
An allocation failure before submission is instead stashed and returned as
`error.OutOfMemory` from the next non-empty `wait()`.

Regular files are native kqueue readiness sources and remain perpetually
ready. Consumers stop monitoring them at EOF to avoid a busy wait.

## Child processes

Process descriptors are available only on FreeBSD. On macOS, NetBSD, OpenBSD,
and other kqueue targets, `born.process.supported` is false, `process.spawn`
and `watchProcess` return `error.Unsupported`, and `unwatchProcess` is a no-op.

FreeBSD `process.spawn` uses `pdfork(PD_CLOEXEC)` and returns a close-on-exec
process descriptor. `Child.kill` signals through that descriptor with `pdkill`,
so it cannot signal a recycled PID. `watchProcess` stages an `EV_ADD` for
`EVFILT_PROCDESC` with `NOTE_EXIT`; the next non-empty `wait()` submits it with
the ordinary changelist. Re-watching replaces the event's `udata`.
`unwatchProcess` drops a staged add or stages a delete for a live knote, while
`purgeFd` forgets the watch before the descriptor is closed.

At exit, the kernel marks the knote `EV_EOF | EV_ONESHOT` and puts the wait
status in its data field. Born translates this into one event with `exited`
set, `exit` containing the exit code or terminating signal, and `eof` clear;
the event ends the watch. Watching an already-exited process fires at the next
`wait()`. A rejected process-watch add instead ends the watch with an error
event: `err` is set, `err_no` contains the native errno, `exited` is false, and
`exit` is null. Both event shapes carry the watch's `udata`.

Born does not reap through kqueue. Unless another caller reaps with
`pdwait`/`wait6`, an exited child remains a zombie until its last process
descriptor is closed, whether or not its exit event was harvested. If the last
descriptor closes while the child is running, the kernel kills it
with `SIGKILL` and leaves init to reap it asynchronously; the close does not
wait for that reap. A `pdfork` child sends no `SIGCHLD` and is invisible to a
generic `wait(2)` for children.

Process adds use the same bounded prefix. Only adds included in the submitted
prefix are marked submitted; adds left for a later wait remain unflushed and
are not treated as live knotes.

`EvPort.deinit` closes the kqueue, which drops its knotes, and frees watch
bookkeeping. It does not close caller-owned `Child.handle` values or perform
the child's final reap; that remains the caller's responsibility.

## Wakeups and companion primitives

FreeBSD and macOS use an `EVFILT_USER` knote for cross-thread wakeups.
NetBSD and OpenBSD use a non-blocking pipe because they lack `EVFILT_USER`.
POSIX wakeups coalesce, and `Event.wake` identifies the resulting event.

Timers use `EVFILT_TIMER`; signals use `EVFILT_SIGNAL` with the signal
ownership rules in the README. Listeners report pending connection counts in
`Event.avail`, and streams report readable byte counts where the kernel
provides them. These counts are hints that can avoid a trailing `EAGAIN`
call; they do not weaken the drain contract.
