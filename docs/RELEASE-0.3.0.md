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
with no source changes. The #23 "consumers build with no source changes"
check is scoped to POSIX until the Windows migration lands; that
migration is tracked in mcp-bridge#35 and follows the repin order below.

## born.io (std.Io compatibility shim) - experimental, opt-in

- `born.io` requires Zig >= 0.16 and is not exported on 0.15.2. The all-Threaded
  baseline (every slot delegated, no loop thread) is the default and the supported
  configuration in 0.3.0.
- `capabilities.time = .born_evented` is opt-in and **experimental** in 0.3.0. It
  currently misses its written benchmark target. #101 (P5.2b) must be closed with
  measured numbers or explicitly accepted before the tag; the route is **not
  recommended for production** until its target is met.
- A Born capability route that is not implemented is rejected at construction
  (`CapabilityUnsupported`), never silently delegated.

## Consumer repin order

1. Cut the v0.3.0 tag.
2. mcp-bridge#35 repins onto the tag.
3. sonya-core moves both pins in one commit.

## Scope gated before the tag

Per the owner go-ahead, v0.3.0 ships the born.io P5 increments and is tagged only
once they are merged and tested: P5.3 (Unix streams), P5.4 (process family) and
P5.5 (proof consumers on all three CI kernels), with #101 (P5.2b time-route
performance) closed with measured numbers or explicitly accepted, tri-kernel
born-io CI green on Zig 0.16.0 and 0.17.1, and the #23 release-checklist audit at
the cut commit. The final shipped surface is recorded against #23.

## Post-0.3.0 (not in this tag)

- #96-#99: process / spawn work (cwd, process groups, macOS and Windows child
  process waits).
- P5.3b: the full server path via additive core listener options (Option A).
