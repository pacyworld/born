# born

An event port for Zig: one small, uniform seam over the platform's native
readiness/completion notification mechanism.

Named for the Born rule — I/O waits in potential until `wait()` collapses it
into a concrete event.

| platform | backend | status |
|---|---|---|
| FreeBSD | kqueue | production since 2026-08 |
| Linux | epoll + eventfd | production since 2026-08 |
| Windows | IOCP | production since 2026-08 |
| macOS, iOS, tvOS, watchOS, visionOS | kqueue | **compiles, never run on hardware** |
| NetBSD, OpenBSD, DragonFly | kqueue | **compiles, never run on hardware** |

The kqueue backend uses only `std.c` and `std.posix`, with no FreeBSD-specific
syscalls and no `builtin.os.tag` branching — which is why the other kqueue
platforms come along at no cost. "At no cost" means it builds. Nobody has run
it there. Please don't claim otherwise without a test run.

## Contract

Identical across every backend:

- **One syscall per `wait()`** carries staged registrations *and* harvests
  events. Registration is never a separate call.
- **Read interest is persistent and edge-triggered**, so handlers must fully
  drain. **Write interest is one-shot**, re-armed on demand via `wantWrite`.
- **fds are never deleted while closed or recycled.** Defer `close()` to a reap
  point immediately after `wait()` has flushed the staged changelist.
  `unmonitorRead` and `cancelWrite` are for fds that *stay open*.
- **`wake()` posts a loop wakeup from any thread** (pipe / eventfd / IOCP post),
  delivered as a single `Event{ .wake = true }`.

## API

```zig
const born = @import("born");

var ep = try born.EvPort.init(allocator);
defer ep.deinit();

ep.monitorRead(fd, user_data);   // persistent, edge-triggered
ep.wantWrite(fd, user_data);     // one-shot
ep.cancelWrite(fd);
ep.unmonitorRead(fd);
ep.purgeFd(fd);
ep.wake();                       // from any thread

var events: [64]born.Event = undefined;
const n = try ep.wait(&events, timeout_ms);
```

`born.backend_name` reports which backend the build selected, so a program can
say what it is actually running on rather than what it assumes.

## Use

```zig
// build.zig.zon
.dependencies = .{
    .born = .{ .url = "https://pacyworld.dev/pacyworld/born/archive/v0.1.0.tar.gz", .hash = "..." },
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
zig build test       # backend tests for the host platform
zig build check-targets   # compile-only proof for every supported platform
```

Requires Zig 0.15.2.

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
- **FreeBSD loopback connect** can return `ECONNREFUSED` *synchronously* under
  load, so a non-blocking connect path must handle both refusal modes.

## Licence

BSD-3-Clause. Copyright (c) 2026, The Daniel Morante Company, Inc.
