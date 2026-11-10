# IOCP backend

The IOCP backend serves Windows. It reports operation completions rather than
readiness, so its socket companions own and drive overlapped operations.

## Association and completion

`associate` attaches an overlappable handle to the completion port. The legacy
`monitorRead` operation also associates a handle; it does not submit a read.
The TCP stream and listener companions associate their own handles during
startup, and callers must not associate them again.

`wait()` harvests completions with `GetQueuedCompletionStatusEx`. Raw
`Event.readable` and `Event.writable` remain false. The owning stream or
listener first absorbs `overlapped`, `bytes`, and any completion error, then
advances its I/O state machine. Even an inline-successful Winsock operation
queues a completion.

A failed association or post is stashed and reported by a later non-empty
`wait()` instead of being discarded.

## Object lifetime

Socket and listener state containing `OVERLAPPED` storage must remain at a
stable address until every pending completion has been absorbed. Construct
streams in place. Sends copy a bounded chunk into owned storage so Winsock
does not borrow the caller's source allocation.

At teardown, cancel and close the handle, continue absorbing completions
until `pendingOps() == 0`, then deinitialize and free the object. Closing a
handle alone does not end the lifetime of its completion storage. Windows
listeners likewise retain accept slots in stable storage until their
completions drain.

## Posts and helper threads

`post()` and `wake()` are callable from any thread. IOCP queues one completion
per post rather than coalescing wakeups. Timer and console helper threads only
post completions; they never mutate loop-owned state. Their stops are
completed before the port closes.

Anonymous pipes created by standard child-process APIs are not overlappable.
Use explicitly created overlappable named pipes or a blocking-pipe relay that
posts completions to the port.
