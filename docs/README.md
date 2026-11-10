# Born backend rationale

Born selects one backend at compile time while retaining the platform-native
`Handle` and shared `Event` surface. These chapters explain the contracts that
are specific to each native notification mechanism.

- [kqueue](kqueue.md): staged readiness registration on BSD and macOS
- [epoll](epoll.md): immediate readiness registration on Linux
- [IOCP](iocp.md): overlapped completion processing on Windows

The portable API and examples are in the repository [README](../README.md).
Run `zig build docs` to generate declaration-level API documentation in
`zig-out/docs/index.html`.
