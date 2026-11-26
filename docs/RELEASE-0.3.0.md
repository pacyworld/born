# born v0.3.0 release notes

## Supported surface

- Timers, signals and TCP listeners on kqueue, epoll and IOCP, plus Unix domain
  stream listeners on kqueue and epoll (Windows reports `Unsupported`): the 0.3.0
  workstream, #24. The README runtime-evidence table records a run on each
  backend's own OS for every claimed primitive.
- Windows: `born.windows.SOCKET` and `born.windows.INVALID_SOCKET` exported as the
  type and sentinel of `socket.PlainNb.sock` (#94), alongside `born.windows.OVERLAPPED`.
- Tri-toolchain support: Zig 0.15.2, 0.16.0 and 0.17.1.

## Windows ABI breaking change

0.3.0 stabilizes the Windows ABI in `compat.zig` with born-owned types,
because Zig 0.16.0 and 0.17.1 dropped the Win32 types (`OVERLAPPED`,
`ws2_32.SOCKET`) from `std.os.windows`. v0.2.3 exposed those std types as
the public Windows API, so a consumer whose Windows glue is typed against
`std.os.windows` (for example McpBridge's `win.zig`) no longer coerces
against 0.3.0 and must migrate to `born.windows.SOCKET`,
`born.windows.INVALID_SOCKET` and `born.windows.OVERLAPPED` (#94, #95).
This is a necessary consequence of tri-toolchain Windows support, not a
revertible defect: born cannot alias std types that no longer exist on
0.16/0.17, and aliasing them on 0.15.2 only would make the public Windows
Handle toolchain-dependent.

POSIX consumers are unchanged: McpBridge (FreeBSD host, 88/88 unit tests)
and sonya-core (the -Dzmq daemon, 18/18 build steps) build against the RC
(release-prep PR #103, head 7374af0, as recorded in #23) with no source
changes. The #23 "consumers build with no source changes" check is scoped
to POSIX until the Windows migration lands; that migration is tracked in
mcp-bridge#35 and follows the repin order below.

## Timer unit breaking change

`EvPort.addTimer`'s delay is now `after_ns: u64` (nanoseconds), not
`after_ms: u32` (milliseconds); the uniform ceiling is
`born.timer_after_ns_max` (about 292 years; it fits the platform's signed
timer data field in both nanoseconds and IOCP's 100 ns ticks). A consumer
that passed milliseconds must multiply by `std.time.ns_per_ms`. Every
backend honors any accepted delay up to the ceiling without firing early.
kqueue arms at most its conversion cap per shot (`State.cap_ns`, the
largest delay the kernel converts exactly) and re-arms the remainder
internally until the deadline is due; the chunking is kqueue-specific.
epoll arms one absolute `timerfd_settime` at the heap's earliest deadline
and re-arms as it changes. IOCP arms one relative due time in 100 ns
ticks, rounded up, so a timer never fires early.

Estate consumers audited for the change: none builds against born master
with the nanosecond API today. McpBridge, identityd, sonya-core,
sonya-core-port and sonya-studio pin v0.2.3, which has no timers.
pw-spoa (master and tag v0.7.0) pins born at git commit f3b837c, after
v0.2.3: it drives `born.EvPort` but never calls `addTimer`, so the unit
change does not touch its source, but it still needs a repin. Antibot's
gateway pins born at git commit 1f04266 (also pre-change); its single
`addTimer` call passes a millisecond value (the 1000 ms repeating tick in
`gateway/src/server.zig`), and the port security/antibot-gw 0.4.0
(pacyworld/ports#26) builds on that pin. HSM (vendored snapshot) is a
frozen pre-change copy that calls `addTimer` with millisecond values.
They need the unit change when they repin or re-vendor onto 0.3.0.
xmppd uses its own event loop, not born.

## born.io (std.Io compatibility shim) - experimental, opt-in

- `born.io` requires Zig >= 0.16 and is not exported on 0.15.2. The all-Threaded
  baseline (every slot delegated, no loop thread) is the default and the supported
  configuration in 0.3.0.
- The network client route (`capabilities.network = .born_evented`) and, on
  FreeBSD and Linux, the process route (`capabilities.process = .born_evented`,
  where Linux kernels older than 5.4 fail `spawn` with `error.Unsupported`)
  are opt-in and **experimental** in 0.3.0. The network route runs connect
  and stream I/O on Born (UDP connect, bind and socketpair return declared
  unsupported); listen, accept and name resolution stay on Threaded.
- The time family (`sleep`, `now`, `clockResolution`) always delegates to
  Threaded. A Born time route (`capabilities.time = .born_evented`) was
  implemented and measured, then retired (#101): a blocking sleep routed through
  the loop costs two cross-thread hops and buys nothing over Threaded's in-thread
  sleep. The written benchmark target was withdrawn; the measured findings are
  recorded in `bench/README.md`, and performance work moves to the native API.
- A Born capability route that is not implemented is rejected at construction
  (`CapabilityUnsupported`), never silently delegated.

## Consumer repin order

1. Cut the v0.3.0 tag.
2. mcp-bridge#35 repins onto the tag.
3. sonya-core moves both pins in one commit.
4. pw-spoa repins onto the tag; the port security/pw-spoa follows.
5. Antibot's gateway repins onto the tag; the port security/antibot-gw
   follows.

The order among the post-tag steps is the owner's call.

## Scope gated before the tag

Per the owner go-ahead, v0.3.0 ships the born.io P5 increments and is tagged only
once they are merged and tested: P5.3 (network client family), P5.4 (process family) and
P5.5 (proof consumers on all three CI kernels), with #101 (time-route retirement)
merged, tri-kernel born-io CI green on Zig 0.16.0 and 0.17.1, and the #23
release-checklist audit at the cut commit. The final shipped surface is recorded
against #23.

## Post-0.3.0 (not in this tag)

- #96-#99: process / spawn work (cwd, process groups, macOS and Windows child
  process waits).
- P5.3b: the full server path via additive core listener options (Option A).
