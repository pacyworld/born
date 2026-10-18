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

## Runtime evidence

Every epoll or IOCP change needs a run of `born-tests` on Linux or Windows,
and kqueue changes a run on FreeBSD. CI produces all three on every push
and pull request; the manual hosts below are the fallback.

### CI (`.forgejo/workflows/ci.yml`)

| Job | Runner (`runs-on`) | What it does |
|---|---|---|
| `build` | runner01, FreeBSD 15 (`FreeBSD`) | Rejects any Zig but 0.15.2; native Debug and ReleaseSafe tests (kqueue); `check-targets`; cross-builds both `born-tests` executables and uploads them with their sha256 |
| `linux-runtime` | runner03, Ubuntu 24.04 (`ubuntu-24.04`) | Runs the Linux executable in a `node:24-bookworm` container on the runner's kernel (epoll) |
| `windows-runtime` | runner02, Windows Server 2022 (`windows-2022`) | Runs `born-tests.exe` on the host (IOCP) |

- The runtime jobs need no Zig. Each checks the executable's sha256
  against the build, prints the host kernel or OS version and the commit,
  and ends with a `runtime evidence (...)` line holding the test summary.
- A runtime job fails on a nonzero exit, on a hash mismatch, and when the
  output has no passing summary line (`N passed; M skipped; 0 failed.` or
  `All N tests passed.`). Skips are listed per test in the log; a contract
  test that still skips is not evidence for its primitive.
- An offline runner leaves its job waiting, so the run and the pull
  request stay pending, never green. Report that instead of merging.
- Artifacts use `https://code.forgejo.org/forgejo/upload-artifact@v4` and
  `download-artifact@v4`. GitHub's `actions/upload-artifact@v4` refuses
  this Forgejo (16.0.5) as GHES; `@v3` works but runs on a retired Node.
- pacyworld.dev chains to the private Pacy World Root CA. Node trusts it
  on runner01, but not on runner02 (Node ignores the Windows store, which
  does trust it) or in the runner03 container. The workflow carries the
  root PEM and its SHA-256 fingerprint and gives it to Node through
  `NODE_EXTRA_CA_CERTS`.
- runner02 has Node 24, `curl.exe`, `git` and `tar`, and its default
  shell is Windows PowerShell 5.1. Run native executables through
  `cmd /c "... > log 2>&1"` so their stderr does not become PowerShell
  errors. Downloads from public hosts need `curl.exe --ssl-no-revoke` and
  a pinned sha256.

To cite CI evidence, link the job: `https://pacyworld.dev/pacyworld/born/actions/runs/<run number>`
(the number shown in the web UI, not the API id), with its summary line.

### Manual hosts

Use these when a runner is down or a change needs a host CI lacks. Build
on freebsd-dev1 with the `test-bin` commands above, then:

- **Linux:** ubuntu-desktop (Ubuntu 26.04.1 on vSphere, always up):
  ```
  scp zig-out/linux/bin/born-tests ubuntu-desktop:/tmp/born-tests
  ssh ubuntu-desktop 'uname -srm; /tmp/born-tests'
  ```
  The Fedora 44 VM (192.168.0.89) is a second Linux host, available only
  while Daniel's desktop VMs run.
- **Windows:** win11-dev (Windows 11, build 26100; PowerShell login shell):
  ```
  scp zig-out/windows/bin/born-tests.exe win11-dev:born-tests.exe
  ssh win11-dev 'cmd /c "born-tests.exe > born-tests.log 2>&1"; "rc=$LASTEXITCODE"; Get-Content born-tests.log'
  ```
- **macOS (Apple Silicon):** macinotsh-desktop, Zig at
  `/usr/local/bin/zig`; build and run natively there. `x86_64-macos` stays
  compile-only.

Paste the host, OS version, commit, sha256 of the executable and the
summary line into the pull request.

### README results table

The README's "Runtime evidence" table records the last run per backend and
primitive: backend, primitive, run, date, commit. Only runs that happened
on that OS go in it. When a primitive's contract tests stop skipping, add
its run in the same pull request. Cells must not start with a backtick:
`build.zig` counts `| ` followed by a backtick to check the target table.

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
