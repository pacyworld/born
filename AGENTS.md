# Born agent notes

## Toolchain and checks

- Support Zig **0.15.2**, **0.16.0**, and **0.17.1**. The three compilers are
  installed side by side; the gate commands below name the selected one as
  `<toolchain>`. Local command names and install paths are in `AGENTS.local.md`.
- Keep unavoidable toolchain dispatch and native ABI replacements in
  `src/compat.zig`. Core code must not import `std.Io`; use the named `compat`
  module supplied by `build.zig`.
- Run shell/build commands asynchronously. Check the current branch and working
  tree before editing.
- Run `zig fmt` and `zig fmt --check` only with Zig 0.15.2. The 0.17.1
  formatter rewrites `@intFromEnum` and `@enumFromInt` to builtins unavailable
  in 0.15.2. P4 keeps one 0.15.2 formatting gate, not an fmt matrix. If a later
  compiler removes the older builtins, move those calls behind `compat.zig`.
- Native runtime gates for each of the three toolchains:
  - `<toolchain> build test -Doptimize=Debug --summary all`
  - `<toolchain> build test -Doptimize=ReleaseSafe --summary all`
- API documentation gate on each toolchain: `<toolchain> build docs --summary all`,
  producing `zig-out/docs/index.html`. A separate `addObject` step requests
  `-femit-docs` and consumes only `getEmittedDocs()`, so no binary is emitted.
- Semantic cross-target gate on each toolchain: `<toolchain> build check-targets --summary all`.
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

## Runtime evidence

Every backend change needs a run of `born-tests` on its actual OS: epoll on
Linux, IOCP on Windows, EVFILT_USER kqueue on FreeBSD or macOS, and pipe-wake
kqueue or the `__kevent50` ABI on NetBSD. A successful cross-build is not
runtime evidence. CI produces the FreeBSD, Linux and Windows runs on every
push and pull request; manual hosts are the fallback for a backend CI lacks
(`AGENTS.local.md`). Record the OS version, commit, executable sha256 and the
test summary line in the pull request.

### CI (`.forgejo/workflows/ci.yml`)

Per-commit CI runs a toolchain matrix over Zig 0.15.2, 0.16.0, and 0.17.1. The
FreeBSD runner provisions each toolchain from the official ziglang.org FreeBSD
tarball, verified against a pinned SHA-256 and cached under
`~/.cache/born-zig/<version>`; the Linux and Windows runners need no Zig.

| Job | Runner role (`runs-on`) | What it does |
|---|---|---|
| `fmt` | FreeBSD (`FreeBSD`) | The single Zig 0.15.2 `zig fmt --check .` gate plus README/AGENTS version-and-target presence (three versions, seven target names); `build.zig` carries the real target-table row guard. No fmt matrix |
| `build` | FreeBSD (`FreeBSD`) | Matrix `zig: [0.15.2, 0.16.0, 0.17.1]`, `max-parallel: 1`; native Debug and ReleaseSafe tests (kqueue); `check-targets`; API docs; cross-builds both `born-tests` executables in Debug and ReleaseSafe and uploads each with its sha256 |
| `linux-runtime` | Linux (`ubuntu-24.04`) | Matrix `zig × optimize`; runs the Linux executable in a `node:24-bookworm` container on the runner's kernel (epoll) |
| `windows-runtime` | Windows (`windows-2022`) | Matrix `zig × optimize`; runs `born-tests.exe` on the host (IOCP) |

- The runtime jobs need no Zig. Each checks the executable's sha256
  against the build, prints the host kernel or OS version and the commit,
  and ends with a `runtime evidence (...)` line holding the test summary.
- A runtime job fails on a nonzero exit, on a hash mismatch, and when the
  output has no passing summary line (`N passed; M skipped; 0 failed.` or
  `All N tests passed.`). Skips are listed per test in the log; a contract
  test that still skips is not evidence for its primitive.
- The native FreeBSD legs decide pass/fail by `zig build test`'s exit code and
  quote the `Build Summary:` line as evidence (its format differs across
  toolchains). The standalone executables on Linux/Windows print
  `N passed; M skipped; 0 failed.`, which the runtime jobs grep for. Both
  formats were verified under all three toolchains.
- An offline runner leaves its job waiting, so the run and the pull
  request stay pending, never green. Report that instead of merging.
- Artifacts use `https://code.forgejo.org/forgejo/upload-artifact@v4` and
  `download-artifact@v4`. GitHub's `actions/upload-artifact@v4` refuses
  this Forgejo (16.0.5) as GHES; `@v3` works but runs on a retired Node.

To cite CI evidence, link the job: `https://pacyworld.dev/pacyworld/born/actions/runs/<run number>`
(the number shown in the web UI, not the API id), with its summary line.

### Scheduled gates (`.forgejo/workflows/stress.yml`, `bench.yml`)

These run weekly and on `workflow_dispatch`, never on push/PR, so they do not
gate a commit. Both pin Zig 0.15.2 on the FreeBSD runner.

- **Stress (#45 repro shape):** `bench/stress.sh BIN RUNS [HOGS]` runs the suite
  RUNS times (default 500) with HOGS CPU busy-loops beside it, on FreeBSD and
  Linux. HOGS defaults to `ncpu + ncpu/2` (~1.5x the core count, #45's original
  load ratio) derived per host; pass HOGS via dispatch to override. It records
  `vm.loadavg` (`/proc/loadavg` on Linux) at the start, each 50-run progress
  line, and the end. Any failure is a release blocker. It targets the listener
  exhaustion-resume race and `timer_test` under load.
- **Benchmark regression (#31):** `bench.yml` runs `bench/suite.sh` with
  `SYSCALLS=truss` on a quiet FreeBSD runner, then `bench/regress.sh` compares
  the median syscalls/req and p50/p99 latency against `bench/thresholds.txt`.
  `bench/quiet.sh` guards acceptance: 1-min loadavg ≤ 0.5·ncpu, ip netisr queue
  Len 0 and no QDrops advance over 3 s. A busy host fails the guard rather than
  yielding an accepted measurement. Results upload as an artifact; recording
  them in `bench/RESULTS.md` is a per-release step.

### README results table

The README's "Runtime evidence" table records the last run per backend and
primitive: backend, primitive, run, date, commit. Only runs that happened
on that OS go in it. When a primitive's contract tests stop skipping, add
its run in the same pull request. Describe each host by OS, version and role
(for example `kqueue, macOS 26.1 arm64 (manual host)` or `epoll, Linux 6.8
(CI Linux runner, Ubuntu 24.04)`), never by hostname. Cells must not start
with a backtick: `build.zig` counts `| ` followed by a backtick to check the
target table.

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

Maintainers: environment-specific hosts and commands live in AGENTS.local.md (not tracked). Read it if present.