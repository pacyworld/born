# born v0.3.0 release notes

## Supported surface

- Timers, signals, and TCP / Unix listeners on kqueue, epoll and IOCP (the 0.3.0
  workstream, #24). The README runtime-evidence table records a run on each
  backend's own OS for every claimed primitive.
- Windows: `born.windows.SOCKET` and `born.windows.INVALID_SOCKET` exported as the
  type and sentinel of `socket.PlainNb.sock` (#94), alongside `born.windows.OVERLAPPED`.
- Tri-toolchain support: Zig 0.15.2, 0.16.0 and 0.17.1.

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