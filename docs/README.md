# Born backend rationale

Born selects one backend at compile time while retaining the platform-native
`Handle` and shared `Event` surface. These chapters explain the contracts that
are specific to each native notification mechanism.

- [kqueue](kqueue.md): staged readiness registration on BSD and macOS
- [epoll](epoll.md): immediate readiness registration on Linux
- [IOCP](iocp.md): overlapped completion processing on Windows

## std.Io analysis

- [std.Io.VTable gap map](born-vtable-gap.md): all 106 Zig 0.17.1 slots, 0.16.0
  drift, upstream Kqueue status, Born coverage, and compatibility constraints
- [std.Io design lessons](learned-from-ioloop.md): hybrid VTables, Batch/Select,
  Dispatch cancellation, capability rejection, and evidence requirements

The portable API and examples are in the repository [README](../README.md).
Run `zig build docs` to generate declaration-level API documentation in
`zig-out/docs/index.html`.
