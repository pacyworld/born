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
  currently misses its written benchmark target; the remaining work is tracked in
  #101 (P5.2b). It is **not recommended for production** until #101 meets that
  target.
- A Born capability route that is not implemented is rejected at construction
  (`CapabilityUnsupported`), never silently delegated.

## Consumer repin order

1. Cut the v0.3.0 tag.
2. mcp-bridge#35 repins onto the tag.
3. sonya-core moves both pins in one commit.

## Post-0.3.0 (not in this tag)

- #101: P5.2b time-route performance to the written target.
- #96-#99: process / spawn work (cwd, process groups, macOS and Windows child
  process waits).
- P5.3 network family (design stage; continues independently of the tag).