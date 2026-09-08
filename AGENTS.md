# Born agent notes

## Toolchain and checks

- Use Zig **0.15.2**, not 0.16. Verified on freebsd-dev1.morante.com:
  FreeBSD 15.1 amd64, `/usr/local/bin/zig`, `zig version` prints `0.15.2`.
- Run shell/build commands asynchronously; this workstation is FreeBSD,
  not Linux. Check the current branch and working tree before editing.
- Native runtime gates:
  - `zig build test -Doptimize=Debug --summary all`
  - `zig build test -Doptimize=ReleaseSafe --summary all`
- Semantic cross-target gate: `zig build check-targets --summary all`.
  The single `supported_targets` list in `build.zig` contains exactly:
  `x86_64-freebsd`, `x86_64-linux-gnu`, `aarch64-macos`, `x86_64-macos`,
  `x86_64-windows-gnu`, `x86_64-netbsd`, `x86_64-openbsd`.
  The build also rejects missing/extra README target rows.
- The cross-target gate compiles tests rooted at `src/root.zig`, including
  backend, API, and socket tests. Real test calls must exercise function
  bodies: `refAllDecls` or an unused library alone is not sufficient.
- Zig 0.15.2 `Build.Step.Compile` has no `emit_bin` field. An `addTest`
  step with no binary consumer emits `-fno-emit-bin` automatically;
  verified with `zig build check-targets --verbose`. Do not add an install,
  run, or `getEmittedBin` consumer to these seven steps. This gate checks
  semantic compilation, not target linking or runtime behavior.
- Build installable runtime tests without executing them on the build host:
  - `zig build test-bin -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix zig-out/linux --summary all`
  - `zig build test-bin -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix zig-out/windows --summary all`
  - Outputs: `zig-out/linux/bin/born-tests` and
    `zig-out/windows/bin/born-tests.exe`. Run each on its actual target OS;
    a successful cross-build is not runtime evidence.
- `.forgejo/workflows/ci.yml` uses the `FreeBSD` runner on push and pull
  request, rejects any version other than 0.15.2, runs both native gates,
  compiles all seven targets, and builds Linux/Windows runtime executables.

## Invariants

- POSIX modules link libc; Windows modules link `ws2_32` and `kernel32`.
  Born provides plain sockets and event ports, with no TLS dependencies.
- Keep the reactor API non-generic with the platform-native `Handle` and
  shared `Event` layout. Platform selection is compile-time.
- Use kqueue/kevent, epoll, or IOCP, never select/poll or timer-driven I/O.
- kqueue stages registrations and submits them with the next wait in one
  `kevent` call. Purge staged entries before closing a descriptor; drain
  edge-triggered reads fully. FreeBSD `kevent` is 64 bytes (`ext[4]`).
- Windows refusal completions can exceed two seconds; the refusal fixture
  reserves a bound non-listening port and uses one ten-second event wait.
- Windows socket state containing `OVERLAPPED` storage must remain stable
  until cancellation/close completions are drained. Closing a handle does
  not make pending completion storage safe to free.
- Preserve existing comments and scope changes to the requested work.
  Do not claim runtime support on an OS without an actual test run there.
