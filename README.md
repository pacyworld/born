# born

An event port for Zig: one small, uniform seam over the platform's native
readiness/completion notification mechanism.

Named for the Born rule: I/O waits in potential until `wait()` collapses it
into a concrete event.

| checked target triple | backend | runtime status |
|---|---|---|
| `x86_64-freebsd` | kqueue | original backend in production since 2026-08 |
| `x86_64-linux-gnu` | epoll + eventfd | original backend in production since 2026-08 |
| `aarch64-macos` | kqueue | tested on macOS 26 arm64; see runtime evidence |
| `x86_64-macos` | kqueue | **compile-only, not tested on hardware** |
| `x86_64-windows-gnu` | IOCP | original backend in production since 2026-08 |
| `x86_64-netbsd` | kqueue | **compile-only, not tested on hardware**; nanosecond timers need NetBSD 10.0 or newer |
| `x86_64-openbsd` | kqueue | **compile-only, not tested on hardware**; nanosecond timers need OpenBSD 7.4 or newer |

These are exactly the `supported_targets` in `build.zig`, checked by CI.
The build rejects missing or extra target rows in this table.
Other Apple/BSD OS tags select kqueue but are not in the checked matrix;
selection alone is not a compilation or runtime guarantee.

### Runtime evidence

CI runs the test suite on FreeBSD, Linux and Windows for every push and pull
request (procedure in `AGENTS.md`). This table records the last run on each
OS per primitive, and lists real runs only.

| backend | primitive | last runtime run | date | commit |
|---|---|---|---|---|
| kqueue, FreeBSD 15 (CI FreeBSD runner) | event port, wake, plain TCP stream | [run 39, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/39/jobs/0): Debug and ReleaseSafe, 29 passed, 26 skipped, 0 failed | 2026-10-18 | [3ed3785](https://pacyworld.dev/pacyworld/born/commit/3ed378538592c0f8c3a0598c957409dd6becfd57) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | event port, wake, plain TCP stream | [run 39, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/39/jobs/1): ReleaseSafe, 28 passed, 26 skipped, 0 failed | 2026-10-18 | [3ed3785](https://pacyworld.dev/pacyworld/born/commit/3ed378538592c0f8c3a0598c957409dd6becfd57) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | event port, wake, plain TCP stream | [run 39, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/39/jobs/2): ReleaseSafe, 21 passed, 27 skipped, 0 failed | 2026-10-18 | [3ed3785](https://pacyworld.dev/pacyworld/born/commit/3ed378538592c0f8c3a0598c957409dd6becfd57) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | signals (signalfd) | [run 51, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/51/jobs/1): ReleaseSafe, 53 passed, 18 skipped, 0 failed | 2026-10-19 | [af7d004](https://pacyworld.dev/pacyworld/born/commit/af7d0046630ed67698570b6b9fd261b6e659c3a7) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | timers (thread-pool timer) | [run 664, Windows job (zig 0.15.2, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/13): 99 passed, 36 skipped, 0 failed; ceiling and 60-day acceptance passed; green on all six legs | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | timers (timerfd plus deadline heap) | [run 664, Linux job (zig 0.15.2, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/7): 152 passed, 12 skipped, 0 failed; ceiling and 60-day acceptance passed; green on all six legs | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | signals (console control events) | [run 81, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/81/jobs/2): ReleaseSafe, 36 passed, 25 skipped, 0 failed | 2026-10-20 | [f2229c6](https://pacyworld.dev/pacyworld/born/commit/f2229c68d7e32f718e34f6b5c563461b993b61b9) |
| IOCP, Windows 11 build 26100 (manual host) | signals (console control events) | born-tests.exe Debug and ReleaseSafe over OpenSSH: 36 passed, 25 skipped, 0 failed each | 2026-10-20 | [f2229c6](https://pacyworld.dev/pacyworld/born/commit/f2229c68d7e32f718e34f6b5c563461b993b61b9) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | TCP listener (AcceptEx) | [run 64, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/64/jobs/2): ReleaseSafe, 38 passed, 26 skipped, 0 failed | 2026-10-20 | [8eca1d3](https://pacyworld.dev/pacyworld/born/commit/8eca1d3e226b14d5120a84192b2aa0779d50884a) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | Unix domain stream sockets | [run 70, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/70/jobs/0): Debug and ReleaseSafe, 81 passed, 4 skipped, 0 failed | 2026-10-19 | [86ef7ec](https://pacyworld.dev/pacyworld/born/commit/86ef7ec20f50151e4719254a79d590b7feb7f4ba) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | Unix domain stream sockets | [run 70, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/70/jobs/1): ReleaseSafe, 65 passed, 13 skipped, 0 failed | 2026-10-19 | [86ef7ec](https://pacyworld.dev/pacyworld/born/commit/86ef7ec20f50151e4719254a79d590b7feb7f4ba) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | readiness counts, EVFILT_USER wake | [run 102, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/102/jobs/0): Debug and ReleaseSafe, 91 passed, 6 skipped, 0 failed | 2026-10-22 | [0b1ec8e](https://pacyworld.dev/pacyworld/born/commit/0b1ec8edb100dd8484f002227bc2a5544ec548ef) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | readiness hints without counts (drain contract) | [run 102, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/102/jobs/1): ReleaseSafe, 87 passed, 6 skipped, 0 failed | 2026-10-22 | [0b1ec8e](https://pacyworld.dev/pacyworld/born/commit/0b1ec8edb100dd8484f002227bc2a5544ec548ef) |
| kqueue, NetBSD 10.1 amd64 (manual host) | pipe wake, fallible init | born-tests Debug and ReleaseSafe: 117 passed, 28 skipped, 4 failed each; the four failures pre-date this commit and are tracked in #76 | 2026-11-13 | [8b01256](https://pacyworld.dev/pacyworld/born/commit/8b012561831223f9bad2ff3cd7e03327eebb3ad8) |
| kqueue, NetBSD 10.1 amd64 (manual host) | pipe wake, wake error reporting | born-tests Debug and ReleaseSafe: 132 passed, 30 skipped, 4 failed each; the four failures pre-date this commit and are tracked in #76 | 2026-11-14 | [9b3b7e2](https://pacyworld.dev/pacyworld/born/commit/9b3b7e217a969d852e61178fbccd0d5d1f69774e) |
| epoll, Linux 7.0 (Ubuntu 26.04 VM, manual host) | wake error reporting | born-tests Debug and ReleaseSafe: 147 passed, 11 skipped, 0 failed each | 2026-11-14 | [9b3b7e2](https://pacyworld.dev/pacyworld/born/commit/9b3b7e217a969d852e61178fbccd0d5d1f69774e) |
| kqueue, macOS 26.1 arm64 (manual host) | tri-toolchain compat, event port, readiness counts, EVFILT_USER wake | born-tests ReleaseSafe on Zig 0.15.2, 0.16.0, and 0.17.1: 116 passed, 24 skipped, 0 failed each | 2026-11-11 | [d65e2fe](https://pacyworld.dev/pacyworld/born/commit/d65e2fe0a07e45877b20ea299f8e736978a0dbe9) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | no-op readiness hints | [run 134, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/134/jobs/2): ReleaseSafe, 74 passed, 25 skipped, 0 failed; hint no-op test passed | 2026-11-10 | [1aaf70e](https://pacyworld.dev/pacyworld/born/commit/1aaf70e9d5f61dc8bb4a92aee3f2ca4682057b4c) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | Unix sockets: unsupported contract | [run 134, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/134/jobs/2): ReleaseSafe, 74 passed, 25 skipped, 0 failed; Unsupported test passed, lifecycle tests skip | 2026-11-10 | [1aaf70e](https://pacyworld.dev/pacyworld/born/commit/1aaf70e9d5f61dc8bb4a92aee3f2ca4682057b4c) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | process descriptors (pdfork, EVFILT_PROCDESC) | [run 127, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/127/jobs/0): Debug and ReleaseSafe, 108 passed, 8 skipped, 0 failed | 2026-11-09 | [6f4f6ed](https://pacyworld.dev/pacyworld/born/commit/6f4f6ed776306c37e5beaa4cd238263cb980d1be) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | process descriptors (pidfd, waitid) | [run 127, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/127/jobs/1): ReleaseSafe, 104 passed, 7 skipped, 0 failed | 2026-11-09 | [6f4f6ed](https://pacyworld.dev/pacyworld/born/commit/6f4f6ed776306c37e5beaa4cd238263cb980d1be) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | process descriptors: unsupported contract | [run 134, Windows job](https://pacyworld.dev/pacyworld/born/actions/runs/134/jobs/2): ReleaseSafe, 74 passed, 25 skipped, 0 failed; Unsupported test passed | 2026-11-10 | [1aaf70e](https://pacyworld.dev/pacyworld/born/commit/1aaf70e9d5f61dc8bb4a92aee3f2ca4682057b4c) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | timers (EVFILT_TIMER, per-id deadlines, internal re-arm) | [run 664, FreeBSD job (zig 0.15.2)](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/1): Debug and ReleaseSafe, 161 passed, 18 skipped, 0 failed; ceiling, 60-day, multi-re-arm and production one-shot never-early passed | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| kqueue, macOS 26.1 arm64 (manual host) | timers (NOTE_NSECONDS 0x4, sub-ms, internal re-arm) | born-tests ReleaseSafe on Zig 0.16.0: 145 passed, 34 skipped, 0 failed; ceiling, 60-day, multi-re-arm and production one-shot never-early passed | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| kqueue, NetBSD 10.1 amd64 (manual host) | timers (NOTE_NSECONDS 3, callout tick, internal re-arm) | born-tests ReleaseSafe on Zig 0.16.0: 144 passed, 31 skipped, 4 failed; the four failures pre-date this commit and are tracked in #76; ceiling, 60-day, multi-re-arm and production one-shot never-early passed | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | signals (EVFILT_SIGNAL) | [run 275, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/275/jobs/1): Debug and ReleaseSafe, 151 passed, 18 skipped, 0 failed | 2026-11-15 | [2605345](https://pacyworld.dev/pacyworld/born/commit/26053451f8fa4d1fd70973618db28ca69c7ca16e) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | TCP listener (accept drain, SO_REUSEPORT_LB) | [run 275, FreeBSD job](https://pacyworld.dev/pacyworld/born/actions/runs/275/jobs/1): Debug and ReleaseSafe, 151 passed, 18 skipped, 0 failed | 2026-11-15 | [2605345](https://pacyworld.dev/pacyworld/born/commit/26053451f8fa4d1fd70973618db28ca69c7ca16e) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | TCP listener (accept drain, SO_REUSEPORT) | [run 275, Linux job](https://pacyworld.dev/pacyworld/born/actions/runs/275/jobs/7): ReleaseSafe, 149 passed, 12 skipped, 0 failed | 2026-11-15 | [2605345](https://pacyworld.dev/pacyworld/born/commit/26053451f8fa4d1fd70973618db28ca69c7ca16e) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io time route (sleep, now) | [run 664, FreeBSD job (zig 0.16.0)](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/2) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/3): Debug and ReleaseSafe, 144 passed, 9 skipped, 0 failed each | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io time route (sleep, now) | [run 664, Linux job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/8) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/9): Debug and ReleaseSafe on 0.16.0 and 0.17.1, 141 passed, 12 skipped, 0 failed each | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | born.io time route (sleep, now) | [run 664, Windows job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/14) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/664/jobs/15): Debug and ReleaseSafe, 88 passed, 65 skipped, 0 failed (0.16.0); 85 passed, 68 skipped, 0 failed (0.17.1) | 2026-11-24 | [73e23b1](https://pacyworld.dev/pacyworld/born/commit/73e23b1ea6adf4c5599ef467d21edec6f11b1928) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io time route, batched NWAKE completion wake (FreeBSD only) | [run 682, FreeBSD job (zig 0.16.0)](https://pacyworld.dev/pacyworld/born/actions/runs/682/jobs/2) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/682/jobs/3): Debug and ReleaseSafe, 149 passed, 9 skipped, 0 failed each; real-waiter NWAKE test passed (elapsed-time assertion, proven to fail with the wake withheld) | 2026-11-24 | [9c77377](https://pacyworld.dev/pacyworld/born/commit/9c773779f86119a928f5afad7c9f75544bf50984) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io time route (sleep, now) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0: 34 passed, 0 failed each | 2026-11-15 | [1a008de](https://pacyworld.dev/pacyworld/born/commit/1a008de3a3397e77e5dec2e91b18e7e5b2c3a6cf) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io time route, default config (stats off) | born-io-tests-default Debug and ReleaseSafe on Zig 0.16.0: 34 passed, 0 failed each; the wake-count test asserts the zero contract | 2026-11-15 | [1a008de](https://pacyworld.dev/pacyworld/born/commit/1a008de3a3397e77e5dec2e91b18e7e5b2c3a6cf) |
| kqueue, macOS 26.1 arm64 (manual host) | born.io time route (sleep, now) | born-io-tests ReleaseSafe on Zig 0.16.0: 93 passed, 60 skipped, 0 failed; sub-millisecond sleep contract passed | 2026-11-23 | [07a09fb](https://pacyworld.dev/pacyworld/born/commit/07a09fbef1e6e05b89bfe5cbfbf4706c9e6b010c) |
| kqueue, NetBSD 10.1 amd64 (manual host) | born.io time route (pipe wake) | born-io-tests ReleaseSafe on Zig 0.16.0: 93 passed, 60 skipped, 0 failed; sub-millisecond sleep contract passed | 2026-11-23 | [07a09fb](https://pacyworld.dev/pacyworld/born/commit/07a09fbef1e6e05b89bfe5cbfbf4706c9e6b010c) |
| epoll, Linux 7.0 (Ubuntu 26.04 VM, manual host) | born.io time route (sleep, now) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0: 33 passed, 1 skipped, 0 failed each | 2026-11-15 | [1a008de](https://pacyworld.dev/pacyworld/born/commit/1a008de3a3397e77e5dec2e91b18e7e5b2c3a6cf) |
| epoll, Linux 7.0 (Ubuntu 26.04 VM, manual host) | born.io time route, default config (stats off) | born-io-tests-default ReleaseSafe on Zig 0.16.0: 33 passed, 1 skipped, 0 failed | 2026-11-15 | [1a008de](https://pacyworld.dev/pacyworld/born/commit/1a008de3a3397e77e5dec2e91b18e7e5b2c3a6cf) |
| IOCP, Windows 11 build 26100 (manual host) | born.io time route (sleep, now) | born-io-tests.exe Debug and ReleaseSafe on Zig 0.16.0 over OpenSSH: 33 passed, 1 skipped, 0 failed each | 2026-11-15 | [1a008de](https://pacyworld.dev/pacyworld/born/commit/1a008de3a3397e77e5dec2e91b18e7e5b2c3a6cf) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | examples smoke suite (echo engine) | [run 297, FreeBSD job (zig 0.15.2)](https://pacyworld.dev/pacyworld/born/actions/runs/297/jobs/1): example-smoke Debug and ReleaseSafe, 7/7 tests passed each; green on all three toolchains | 2026-11-16 | [a474347](https://pacyworld.dev/pacyworld/born/commit/a4743479f711f418f59e9f17c5db9c12cc5af2c4) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | examples smoke suite (echo engine) | [run 297, Linux job (zig 0.15.2, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/297/jobs/7): born-example-smoke All 7 tests passed; green on all six legs | 2026-11-16 | [a474347](https://pacyworld.dev/pacyworld/born/commit/a4743479f711f418f59e9f17c5db9c12cc5af2c4) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | examples smoke suite (echo engine) | [run 297, Windows job (zig 0.15.2, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/297/jobs/13): born-example-smoke.exe 5 passed; 2 skipped; 0 failed (SIGTERM and balanced skip on Windows); green on all six legs | 2026-11-16 | [a474347](https://pacyworld.dev/pacyworld/born/commit/a4743479f711f418f59e9f17c5db9c12cc5af2c4) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | examples live drive (echo servers, SIGTERM drain) | born-echo-server and born-echo-per-core ReleaseSafe on Zig 0.15.2: 8 and 24 connections echoed (203105 and 808280 bytes), clean SIGTERM drain exit 0 each | 2026-11-16 | [a474347](https://pacyworld.dev/pacyworld/born/commit/a4743479f711f418f59e9f17c5db9c12cc5af2c4) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io network client route (connect, stream I/O, shutdown) | [run 314, FreeBSD job (zig 0.16.0)](https://pacyworld.dev/pacyworld/born/actions/runs/314/jobs/2) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/314/jobs/3): Debug and ReleaseSafe, born-io-tests 77 passed, 5 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io network client route (connect, stream I/O, shutdown) | [run 314, Linux job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/314/jobs/8): Debug and ReleaseSafe on 0.16.0 and 0.17.1, born-io-tests 76 passed, 6 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | born.io network client route (connect, stream I/O, shutdown) | [run 314, Windows job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/314/jobs/14): Debug and ReleaseSafe on 0.16.0 and 0.17.1, born-io-tests.exe 74 passed, 8 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io network client route (connect, stream I/O, shutdown) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 77 passed, 5 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io network route, default config (stats off) | born-io-tests-default Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 77 passed, 5 skipped, 0 failed each; the echo test asserts the documented zero counter snapshot | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| kqueue, macOS 26.1 arm64 (manual host) | born.io network client route (connect, stream I/O, shutdown) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 77 passed, 5 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| kqueue, NetBSD 10.1 amd64 (manual host) | born.io network client route (pipe wake) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 77 passed, 5 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| epoll, Linux 7.0.0-34-generic x86_64 (manual host) | born.io network client route (connect, stream I/O, shutdown) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 76 passed, 6 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| IOCP, Windows 11 build 26100.6901 (manual host) | born.io network client route (connect, stream I/O, shutdown) | born-io-tests.exe Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1 over OpenSSH: 74 passed, 8 skipped, 0 failed each | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io network route, route_dead vs canceled retirement (mutation proof) | the retirement unit and loop-death integration test pass clean; forcing a failure exit to report canceled fails both (75 passed, 5 skipped, 2 failed); reverted, green again | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| IOCP, Windows 11 build 26100.6901 (manual host) | born.io network route, two-socket exit drain (mutation proof) | the two-socket drain unit passes clean; reverting registryCloseAll to the per-socket polled drain fails its prompt-drain bound (73 passed, 8 skipped, 1 failed); reverted, green again | 2026-11-17 | [068212d](https://pacyworld.dev/pacyworld/born/commit/068212d7e73ee0bb4e8c02bdee15ac8c86f314eb) |
| IOCP, Windows 11 build 26100.6901 (manual host) | born.io network route, connect-deadline drain (mutation proof) | the Windows drain unit passes clean; the unconditional slot-free mutation in connectDeadlineFired fails exactly that unit (67 passed, 6 skipped, 1 failed); reverted, green again | 2026-11-17 | [cfe247d](https://pacyworld.dev/pacyworld/born/commit/cfe247d2d92b3442e1262ba2235d458fcdc718bc) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io process route (spawn, wait, kill, PATH, stdio pipes) | [run 322, FreeBSD job (zig 0.16.0)](https://pacyworld.dev/pacyworld/born/actions/runs/322/jobs/2) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/322/jobs/3): Debug and ReleaseSafe, born-io-tests 125 passed, 6 skipped, 0 failed each | 2026-11-18 | [0c036c8](https://pacyworld.dev/pacyworld/born/commit/0c036c890752924c9c3e1c259d79a0a7d07d6312) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io process route (spawn, wait, kill, PATH, stdio pipes) | [run 322, Linux job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/322/jobs/8): Debug and ReleaseSafe on 0.16.0 and 0.17.1, born-io-tests 122 passed, 9 skipped, 0 failed each; the caller-closed-end fd-reuse regression tests run here | 2026-11-18 | [0c036c8](https://pacyworld.dev/pacyworld/born/commit/0c036c890752924c9c3e1c259d79a0a7d07d6312) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | born.io process route construction rejection, all-Threaded baseline | [run 322, Windows job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/322/jobs/14): Debug and ReleaseSafe on 0.16.0 and 0.17.1, born-io-tests.exe 74 passed, 57 skipped, 0 failed each; the 49 process tests skip | 2026-11-18 | [0c036c8](https://pacyworld.dev/pacyworld/born/commit/0c036c890752924c9c3e1c259d79a0a7d07d6312) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io process route (spawn, wait, kill, PATH, stdio pipes) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 125 passed, 6 skipped, 0 failed each; includes the late-arm NOTE_EXIT flush delivery, dead-loop wait6 reap, arm-flush failure and synthetic EV_ERROR units, and the caller-closed-end fd-reuse regression tests | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io process route, default config (stats off) | born-io-tests-default Debug and ReleaseSafe on Zig 0.16.0: 125 passed, 6 skipped, 0 failed each; the counters test skips and the zero-contract test passes | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| epoll, Linux 7.0.0-34-generic x86_64 (manual host) | born.io process route (spawn, wait, kill, PATH, stdio pipes) | born-io-tests Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1: 122 passed, 9 skipped, 0 failed each; the half-duplex pipe orientation and caller-closed-end fd-reuse regression tests run here, the FreeBSD-only arm-flush units skip | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, macOS 26.1 arm64 (manual host) | born.io process route construction rejection, all-Threaded baseline | born-io-tests ReleaseSafe on Zig 0.16.0 and 0.17.1: 77 passed, 54 skipped, 0 failed each; capabilities.process = .born_evented rejects at construction, the process tests skip, the P5.3 baseline is unchanged | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, NetBSD 10.1 amd64 (manual host) | born.io process route construction rejection, all-Threaded baseline (pipe wake) | born-io-tests ReleaseSafe on Zig 0.16.0: 77 passed, 54 skipped, 0 failed; capabilities.process = .born_evented rejects at construction, the process tests skip, the P5.3 baseline is unchanged | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| IOCP, Windows 11 build 26100.6901 (manual host) | born.io process route construction rejection, all-Threaded baseline | born-io-tests.exe ReleaseSafe on Zig 0.16.0 and 0.17.1 over OpenSSH: 74 passed, 57 skipped, 0 failed each; capabilities.process = .born_evented rejects at construction, the process tests skip, the P5.3 baseline is unchanged | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io process route, process tag attribution (mutation proof) | the tag-attribution units pass clean; stripping proc_udata_bit from procUdata fails the udata round-trip unit (null udata crash), cross-route attribution, arm-refusal, synthetic EV_ERROR and stolen-reap units (120 passed, 6 skipped, 4 failed, 1 crashed); reverted, green again | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io process route, abandon-on-cancel (mutation proof) | the abandon unit and contract tests pass clean; kill-on-cancel (SIGKILL plus blocking reap in abandonWait) fails the abandon unit and both abandon contract tests (122 passed, 6 skipped, 3 failed); reverted, green again | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io process route, synchronous arm confirmation (mutation proof) | the arm-confirmation units pass clean; retiring arms before the flush confirmation fails the arm-refusal and arm-flush failure units and crashes the synthetic EV_ERROR unit (122 passed, 6 skipped, 2 failed, 1 crashed); reverted, green again | 2026-11-18 | [8f57189](https://pacyworld.dev/pacyworld/born/commit/8f5718976e1f9034f1a7d8a5d13b03caeea2e899) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io network route, close is route death (#106) | [run 330, FreeBSD job (zig 0.16.0)](https://pacyworld.dev/pacyworld/born/actions/runs/330/jobs/2) and [zig 0.17.1 job](https://pacyworld.dev/pacyworld/born/actions/runs/330/jobs/3): Debug and ReleaseSafe, born-io-tests 128 passed, 6 skipped, 0 failed each; the close-retirement unit and the Unexpected close contract run here | 2026-11-19 | [cdc2b58](https://pacyworld.dev/pacyworld/born/commit/cdc2b58b383eb4d697b18ea0a349c3aa0f1eea04) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io network route, close is route death (#106) | [run 330, Linux job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/330/jobs/8): Debug and ReleaseSafe on 0.16.0 and 0.17.1, born-io-tests 125 passed, 9 skipped, 0 failed each; the close-retirement unit and the Unexpected close contract run here | 2026-11-19 | [cdc2b58](https://pacyworld.dev/pacyworld/born/commit/cdc2b58b383eb4d697b18ea0a349c3aa0f1eea04) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | born.io network route, close retirement and failed exit drain leak guard (#106) | [run 330, Windows job (zig 0.16.0, ReleaseSafe)](https://pacyworld.dev/pacyworld/born/actions/runs/330/jobs/14): Debug and ReleaseSafe on 0.16.0 and 0.17.1, born-io-tests.exe 76 passed, 58 skipped, 0 failed each; the leak path is tested at the deinit-decision level only (a synthetic drain failure), not by a real GetQueuedCompletionStatusEx failure | 2026-11-19 | [cdc2b58](https://pacyworld.dev/pacyworld/born/commit/cdc2b58b383eb4d697b18ea0a349c3aa0f1eea04) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io network route, nats.zig consumer unit suite | nats-unit Debug and ReleaseSafe on Zig 0.16.0, born and all-Threaded baseline, re-run at the W1 facade fix with NATS_SERVER unset (unit provisions no server): 119 passed, 2 skipped, 0 failed each; born connect=2 with threaded connect=0, baseline counters zero, route proof PASS x4 | 2026-11-19 | [7c1f229](https://pacyworld.dev/pacyworld/born/commit/7c1f2298635785766f5522321cd9b0dff11e1347) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io network route, nats.zig consumer e2e suite (native nats-server v2.15.0) | nats-e2e Debug and ReleaseSafe on Zig 0.16.0, born and all-Threaded baseline, against the pinned v2.15.0 binary (sha256 d3496cfe2199ef65489d63f2f26e946fc3a77c4a1d9baf424ebe761d7d84d48f) spawned by absolute NATS_SERVER path from a directory outside default_PATH (W1 facade fix): 177 passed, 0 skipped, 0 failed each; born legs connect=192 with threaded connect=0 (fixture-side threaded r=5 w=4 only in the two fake-server tests, per-test gate), baseline legs all counters zero with identical results, route proof PASS x4 | 2026-11-19 | [7c1f229](https://pacyworld.dev/pacyworld/born/commit/7c1f2298635785766f5522321cd9b0dff11e1347) |
| kqueue, FreeBSD 15.1-RELEASE-p2 amd64 (manual host) | born.io network route, std.http.Client contract suite | http-contract Debug and ReleaseSafe on Zig 0.16.0 and 0.17.1, born and all-Threaded control, re-run at the W1 facade fix with NATS_SERVER unset (http provisions no server): 8 passed, 0 skipped, 0 failed each; born legs connect=8 with all threaded counters zero, control legs identical results, route proof PASS x8 | 2026-11-19 | [7c1f229](https://pacyworld.dev/pacyworld/born/commit/7c1f2298635785766f5522321cd9b0dff11e1347) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io network route, nats.zig consumer unit suite | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.16.0 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/8) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/12) and all-Threaded baseline [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/10) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/14): 119 passed, 2 skipped, 0 failed each; born connect=2 with threaded connect=0, baseline counters zero, route proof PASS | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io network route, nats.zig consumer e2e suite (native nats-server v2.15.0) | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.16.0 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/8) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/12) and all-Threaded baseline [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/10) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/14), against the pinned v2.15.0 binary spawned by the absolute NATS_SERVER path (W1 facade fix): 177 passed, 0 skipped, 0 failed each; born connect=192 with threaded connect=0 (fixture-side threaded r=5 w=4 only), baseline counters zero with identical results, route proof PASS | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| kqueue, FreeBSD 15 (CI FreeBSD runner) | born.io network route, std.http.Client contract suite | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.16.0 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/8) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/12) and all-Threaded control [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/10) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/14), plus 0.17.1 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/9) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/13) and control [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/11) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/15) (0.17.1 runs http only): 8 passed, 0 skipped, 0 failed each; born connect=8 with all threaded counters zero, control identical results, route proof PASS | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io network route, nats.zig consumer unit suite | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.16.0 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/16) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/20) and all-Threaded baseline [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/18) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/22): 119 passed, 2 skipped, 0 failed each; born connect=2 with threaded connect=0, baseline counters zero, route proof PASS | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io network route, nats.zig consumer e2e suite (native nats-server v2.15.0) | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.16.0 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/16) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/20) and all-Threaded baseline [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/18) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/22), against the pinned v2.15.0 binary (linux-amd64 tarball sha256 verified) spawned by the absolute NATS_SERVER path (W1 facade fix): 177 passed, 0 skipped, 0 failed each; born connect=192 with threaded connect=0 (fixture-side threaded r=5 w=4 only), baseline counters zero with identical results, route proof PASS | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| epoll, Linux 6.8 (CI Linux runner, Ubuntu 24.04) | born.io network route, std.http.Client contract suite | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.16.0 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/16) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/20) and all-Threaded control [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/18) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/22), plus 0.17.1 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/17) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/21) and control [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/19) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/23) (0.17.1 runs http only): 8 passed, 0 skipped, 0 failed each; born connect=8 with all threaded counters zero, control identical results, route proof PASS | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| IOCP, Windows Server 2022 build 20348 (CI Windows runner) | born.io network route, std.http.Client contract suite (0.17.1 only) | [run 364](https://pacyworld.dev/pacyworld/born/actions/runs/364), Zig 0.17.1 born [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/25) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/29) and all-Threaded control [Debug](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/27) / [ReleaseSafe](https://pacyworld.dev/pacyworld/born/actions/runs/364/jobs/31): 8 passed, 0 skipped, 0 failed each; born connect=8 with all threaded counters zero, control identical results, route proof PASS. The Windows 0.16.0 nats rows are pending the runner trust-store fix | 2026-11-19 | [7f93288](https://pacyworld.dev/pacyworld/born/commit/7f932884b80f8382a9dc29e0729c6c1e5d8a1b40) |
| IOCP, Windows 11 build 26100 (manual host) | born.io network route, Zig 0.16.0 threaded Windows AFD terminal-error compensation (#126) | cancel-aware redesign: every AFD ioctl runs through operate/.device_io_control (APC + alertable wait + cancel + drain). born-io-tests Debug and ReleaseSafe 87 passed, 65 skipped, 0 failed each, including the refused-connect, abortive-close read and canceled-pending-connect tests (the cancel target is a reserved non-listening loopback port, so nothing leaves the host; cancel returns Canceled in under 1 s, well inside the ~2 s loopback refusal latency); nats-unit.exe and http-contract.exe Debug and ReleaseSafe on the all-Threaded route: unit 119 passed, 2 skipped, 0 failed and http 10 passed, 0 skipped, 0 failed each, route proof PASS; born-route ReleaseSafe no-regression unit 119/2/0, http 10/0/0, e2e 178/0/0, route proof PASS | 2026-11-23 | [5193170](https://pacyworld.dev/pacyworld/born/commit/5193170e343d885abbc102ead6228019da336eb4) |

Commit 3ed3785 changes only the CI workflow; its library and tests are
those of master d1017b8. Skips identify platform exclusions or primitives
not implemented at the recorded commit. The born.io manual runs were built
from the shim sources of 1a008de; the Linux and Windows runs skip the
kqueue-only loop-death test. The default-config (stats off) runs use
born-io-tests-default, the exported module built without -Dtime-stats. The
commit adding these rows changes only this README; its library, tests and
CI are those of 1a008de.

The consumer rows at 7c1f229 re-run the suites after the W1 facade fix: the
e2e fixture now spawns the pinned nats-server v2.15.0 by the absolute
NATS_SERVER path the runner publishes, from a directory outside the fixture
Threaded io's default_PATH (an unset or non-absolute NATS_SERVER fails
loudly). The earlier 1d3b401 e2e rows used the packaged
/usr/local/bin/nats-server, which sits on that default_PATH. The unit and
http suites provision no server and run with NATS_SERVER unset.

The consumer CI rows record consumers dispatch run 364 at 7f93288: the
FreeBSD and Linux 0.16.0 nats-unit, nats-e2e and http suites (born and
all-Threaded, Debug and ReleaseSafe) and the 0.17.1 http suite, plus the
Windows 0.17.1 http suite. The Windows 0.16.0 nats rows are pending the
runner trust-store fix: the nats-server download fails on the missing
ISRG Root X1 root certificate before any test runs, so those legs carry
no runtime evidence yet. The commit adding these rows changes only this
README; its library, tests and CI are those of 7f93288.

The Windows threaded compensation row records the #126 shim on the
all-Threaded route: every AFD ioctl (SOCKOPT, BIND, CONNECT and the
zero-length SEND probe) runs through the Threaded vtable's operate with
.device_io_control, inheriting std's APC submission, alertable wait,
NtCancelIoFileEx and drain, so a canceled operation returns error.Canceled
promptly. The probe recovers the socket's sticky terminal state behind
error.Unexpected on read/write/send, and the shim's own connect keeps the
CONNECT NTSTATUS observable, so the refused connect and the peer close map
to their declared errors instead of Unexpected. The born-io-tests suite
exercises this on Windows + 0.16 (refused connect, abortive-close read, and
a canceled pending connect to a reserved non-listening loopback port, so
nothing leaves the host; cancel returns Canceled in under 1 s, well inside
the ~2 s loopback refusal latency). The born-route suites on the same host
stay green (unit 119 passed, 2 skipped, 0 failed; http 10 passed, 0 skipped,
0 failed; e2e 178 passed, 0 skipped, 0 failed, ReleaseSafe), confirming no
born-route regression; their binaries are unchanged from 66de6a3, a
test-only delta. The commit adding this row changes only this README;
its library, tests and CI are those of 5193170.

The examples smoke rows record the example integration suite
(examples/smoke.zig) through the shared echo engine; Windows skips the
SIGTERM-drain and balanced-listener tests. The live-drive row records
the two example servers under real clients and SIGTERM on a manual
FreeBSD host. The commit adding these rows changes only this README;
its library, tests and CI are those of a474347.

The born.io network rows record the P5.3 client route: IP and pathname
Unix connect with deadlines, stream read/write, close, shutdown, the
coarse error map, try-before-park, the stale-handle generation guard,
the provenance gate, the per-route counters, unregister-before-close,
the two-phase Windows exit drain, route_dead versus canceled retirement
and persistent read interest. The kqueue POSIX runs skip the four
Windows-only tests and the Unix-on-Windows test; Linux also skips the
kqueue-only time loop-death test; Windows skips the POSIX deadline unit,
both loop-death tests, the four Unix tests and the POSIX handle-reuse
test. The NetBSD born.io suite is separate from born-tests, whose four
pre-existing failures are tracked in #76. The mutation rows record three
revert experiments: route_dead retirement (FreeBSD) and the two-socket
exit drain (Windows) at 068212d, and the connect-deadline drain at
cfe247d; each mutant fails only its targeted tests and the reverted tree
is green again. The CI rows record run 314 at 068212d; the commit adding
these rows changes only this README.

The born.io process rows record the P5.4 process route: spawn, wait and
kill through born.process process descriptors (FreeBSD) and pidfds (Linux)
watched on Born's EvPort, shim-side PATH resolution, the stdio pipe hybrid,
the chunked child registry, abandon-on-cancel, the recycled-pid guard,
cross-route error attribution, synchronous arm confirmation, the late-arm
flush delivery and the dead-loop wait6/waitid reap. The caller's Child
fields solely own the parent pipe ends after spawn returns (the wait/kill
thunks close them on the caller thread, never the loop), and a failed arm
flush latches arm_failed so the cleanup kill never parks. The route is
FreeBSD and Linux only; macOS, NetBSD and Windows reject capabilities.process =
.born_evented at construction (CapabilityUnsupported), and their rows
record the unchanged all-Threaded baseline: the 49 process tests (22
mechanism units, 27 contract tests) skip there, leaving the P5.3 pass
counts (77 on macOS and NetBSD, 74 on Windows). FreeBSD and Linux skip the
zero-contract test when stats are on; the default-config run skips the
counters test and passes the zero-contract test instead. Linux also skips
the kqueue-only time loop-death test and the two FreeBSD-only arm-flush
units. Child piped stdio is an explicit Threaded hybrid: the parent pipe
ends are Threaded-serviced file I/O and are not claimed by the per-route
counters. The mutation rows record three revert experiments at 8f57189:
the process tag strip, kill-on-cancel and the arm retire-before-flush-confirm;
each mutant fails only its targeted tests and the reverted tree is green
again. The CI rows record run 322 at
0c036c8; the commit adding these rows changes only this README.

The born.io hygiene rows record the #106 fixes: a close of the op's socket
kills the route, so closeDrive retires parked read/write/connect as
route_dead (Unexpected at the thunk), honoring cancel_requested, while the
deinit stop path stays canceled; and a failed Windows exit-drain wait
latches the cause and leaks the chunk table instead of freeing OVERLAPPED
storage that completions may still reference. The POSIX close-retirement
unit skips on Windows; the cross-kernel close contract (a parked Born read
retires Unexpected, not Canceled) runs on all three kernels, as do the two
registry deinit-decision units. The leak guard is tested at the
deinit-decision level only: the unit drives registryDrainFailed with a
synthetic wait failure and checks the latch and the kept table; no test
injects a real GetQueuedCompletionStatusEx failure. The CI rows record run
330 at cdc2b58; the commit adding these rows changes only this README, and
its library, tests and CI are those of cdc2b58.

## Programming model

The raw event port has a uniform **type surface**, not identical I/O semantics.
Use `born.socket.PlainNb` for the portable plain-TCP companion. TLS, certificate
validation, HTTP and application logging are outside born. Backend-specific
design rationale is in [docs/](docs/README.md); `zig build docs` generates
declaration-level API documentation. The std.Io analysis includes a
[VTable gap map](docs/born-vtable-gap.md) and
[design lessons](docs/learned-from-ioloop.md).

### kqueue and epoll: readiness

`monitorRead` registers persistent edge-triggered socket read interest. Drain
reads until `want_read`; attempt writes before waiting for `want_write`.
kqueue write interest is one-shot and must be rearmed. epoll write interest
remains armed until `cancelWrite`; once read interest adds `EPOLLET`, write
notifications are edge-triggered too. Cancel write interest when no longer needed.

kqueue stages changes and harvests events in **one `kevent()` call**. epoll applies
registrations immediately with `epoll_ctl`; `wait()` then calls `epoll_wait`.
Before closing a descriptor at the end-of-batch reap point, call `purgeFd` to
remove its staged changes/bookkeeping. Never apply stale changes after closing
or recycling a descriptor. `unmonitorRead` and `cancelWrite` are for descriptors
that remain open.

**Registration failure reporting.** A rejected
registration, including `EBADF` for a dead descriptor or any other refusal
epoll or kqueue might return, is stashed and returned as
`error.RegisterFailed` from the next non-empty `wait()` on epoll (an empty
`wait` neither consumes nor reports it), matching how IOCP reports a failed
association as `error.AssociateFailed`. kqueue stages changes: a
kernel-rejected change comes back as an `Event` with `.err` set and the native
errno in `.err_no` (and
`.readable`/`.writable` stay clear on such events), while an allocation failure
before the change ever reaches the kernel is stashed and returned as
`error.OutOfMemory` the same way epoll stashes its rejections.

On kqueue, each submission is bounded to the available event slots. Every
rejected change has room for its `EV_ERROR` record. `wait()` submits every
staged change before it blocks. Earlier records are returned first, and the
next wait continues with any remaining changes. See
[kqueue backend rationale](docs/kqueue.md) for the complete contract.

**Regular files work identically on every POSIX backend.** I/O on a regular
file never blocks, so "always ready" is the correct answer. kqueue accepts
regular files natively; epoll's raw `epoll_ctl` refuses them with `EPERM`, so
the epoll backend emulates kqueue: the `EPERM` refusal classifies an
unpollable descriptor, which is kept out of the kernel's epoll set and reported
ready by every `wait()`, readable and/or writable per its interest. Consumers
must therefore stop registering a regular file once it reaches EOF, on both
backends, or `wait()` keeps answering instantly (true under kqueue already).

### IOCP: completion

`monitorRead` associates an overlappable handle with the port; **it does not
submit a read**. New low-level callers can use fallible `associate` directly.
The socket companion associates its own handle at startup; callers must not
associate it again. A failed `monitorRead` association is reported by the next
nonempty `wait`, rather than silently dropped.
`wantWrite`, `cancelWrite`, `unmonitorRead` and `purgeFd` do not submit or cancel
Windows operations. `wait()` harvests completions with
`GetQueuedCompletionStatusEx`. Raw `Event.readable` and `Event.writable` remain
false. The owning stream must absorb `overlapped`, `bytes` and any error before
retrying its I/O state machine. `post()` and `wake()` are callable from any
thread; a failed `PostQueuedCompletionStatus` is never dropped silently: it
is stashed atomically and returned as `error.PostFailed` from the next non-empty
`wait()` (when the failed post was itself a wake, the error arrives with the
next naturally-arriving completion).

The extracted `born.socket.PlainNb` owns the overlapped connect/receive/send
machinery and receive/send buffers. Construct it **in place**: the stream may
not move while operations are pending. Sends copy a bounded chunk into owned
storage, so Winsock does not borrow the caller's source allocation. Even an
inline-successful Winsock operation queues a completion. On teardown, call
`cancelAndClose`, keep absorbing completions until `pendingOps() == 0`, then
`deinit` and free the stream. Closing the handle alone does not end the lifetime
of its `OVERLAPPED` storage.

`PlainNb.sock` is the native Winsock socket handle, of type `born.windows.SOCKET`,
with sentinel `born.windows.INVALID_SOCKET`. These are born's own nominal types,
distinct from `std.os.windows.ws2_32.SOCKET`, so they do not interconvert implicitly:
a consumer that stores or returns the socket, or declares its own ws2_32 externs
that take it, names `born.windows.SOCKET` or casts at the boundary. `born.windows`
also exports `OVERLAPPED`, the operation-storage type used by `Event.overlapped`.

Windows anonymous pipes for application-created children, such as those from
`std.process.Child`, are **not overlappable**. The TCP companion does not make
those pipes IOCP-capable: use explicitly created overlappable named pipes or a
blocking-pipe relay, as mcp-bridge does. This is separate from
`born.process.spawn`, which is unsupported on Windows.

### Common event surface

`born.Handle` is the native descriptor type (`std.posix.fd_t` on POSIX,
`*anyopaque` on Windows). Every backend uses it for descriptor arguments.
`born.Event` has the same fields on every backend: `udata`, `readable`,
`writable`, `eof`, `err`, `err_no: usize`, `wake`,
`overlapped: ?*born.windows.OVERLAPPED`, `bytes: usize`, the timer and
signal fields `timer: bool`, `signal: ?born.Signal` and `fired: u32` (see
[primitive contracts](#primitive-contracts)), which stay false, null and zero
for every other event, `avail: usize`, the readiness count (see
[Readiness counts](#readiness-counts)), and `exited: bool` with
`exit: ?born.ProcessExit` for a watched process (see
[Child processes](#child-processes)).
Completion fields are null/zero on POSIX. Error numbers are native errno on
kqueue and NTSTATUS on IOCP, not a portable error enumeration.

Each `EvPort` operation returns its own error set: `born.InitError` from
`init`, `born.WaitError` from `wait`, `born.TimerError` from timer calls,
`born.SignalError` from signal calls, and `born.ProcessError` from
`watchProcess`. `born.Error` is their union. `born.InitError` is the same
on every backend: `SystemResources` when the kernel refuses the port or its
wake source, and `OutOfMemory` when port bookkeeping cannot be allocated.
`wait` reports only loop failures (including stashed registration failures),
never a refused timer, signal, or process watch.

`wake()` may be called from another thread and produces `Event{ .wake = true }`.
POSIX wakeups coalesce; IOCP queues one completion per post. All other event-port
and socket operations belong to the owning loop thread.

How a POSIX port wakes: FreeBSD and macOS use one `EVFILT_USER` knote
(`EV_CLEAR`) that `init` registers with an immediate `kevent()`, as one-time
setup, so a `wake()` from another thread before the first `wait()` is not lost.
`wake()` is a `NOTE_TRIGGER` `kevent()` with no event list. That call is a
cross-thread trigger, not a registration, so the rule that kqueue
registrations are staged into `wait()` does not apply to it. It needs no
descriptors besides the kqueue and no drain `read()`. A trigger the kernel
refuses is reported by the next non-empty `wait()` as `error.WaitFailed`.
NetBSD and OpenBSD have no `EVFILT_USER` and keep the non-blocking pipe, and
epoll uses an eventfd. Measured on FreeBSD (`bench/RESULTS.md`): a wake round
trip between two threads costs 4 syscalls instead of 8 and p50 falls from 14.8
to 11.8 us.

## Raw readiness API (POSIX)

```zig
const born = @import("born");

var ep = try born.EvPort.init(allocator);
defer ep.deinit();

ep.monitorRead(fd, user_data);   // persistent, edge-triggered
ep.wantWrite(fd, user_data);     // kqueue one-shot; epoll until canceled
ep.cancelWrite(fd);
ep.unmonitorRead(fd);
ep.purgeFd(fd);
ep.wake();                       // from any thread

var events: [64]born.Event = undefined;
const n = try ep.wait(&events, timeout_ms);
```

A non-null `timeout_ms` must be nonnegative; `null` waits indefinitely.

`born.backend_name` reports which backend the build selected, so a program can
say what it is actually running on rather than what it assumes.

## Portable TCP companion

`born.socket` exports `PlainNb`, `NbRead`, `NbWrite`, `CompletionKind` and
one error set per operation: `ConnectError` (`startConnectInto`),
`ConnectDoneError` (`connectDone`), `ReadError` (`readNb`) and `WriteError`
(`writeNb`). Each holds exactly what that call can return, so a consumer can
switch over it with no `else` prong and a later change in born fails the
consumer's build instead of reaching `unreachable`. `IoError` (also
`PlainNb.Error`) is their union, including Unix connects and accepted-stream
adoption, and is a catch-all that may grow. It does not depend on OpenSSL,
Schannel or mcp-bridge.

1. Initialize a stable `PlainNb{}` and call
   `startConnectInto(allocator, host, port, &ep, user_data)`.
2. Arm `ep.wantWrite(stream.handle(), user_data)` and wait for connect readiness
   or completion. Feed each event to
   `stream.absorbCompletion(event.overlapped, event.bytes, if (event.err) event.err_no else null)`
   before calling `connectDone`. Absorption is a no-op on POSIX.
3. Cancel connect write interest. On POSIX, call `ep.monitorRead` to register
   read interest; on Windows, startup already associated the socket, so do not
   register it again. Call `readNb` and `writeNb` to drive I/O, **including a first
   read before waiting** so Windows can post its receive. Retry after the matching
   event/completion. Drain reads and consume partial writes; arm write interest
   only on `want_write`.
4. `readNb` returns `data`, `want_read`, `want_write` or `eof`.
   `writeNb` returns `done`, `want_read` or `want_write`. Retry the same logical
   send until `done` accounts for its completed bytes; do not advance the write
   queue on `want_write`. Windows owns a copy of the submitted chunk.
5. At end-of-batch teardown, `ep.purgeFd(stream.handle())`, then
   `stream.cancelAndClose()`. Absorb all pending completions before `deinit`.
   `pendingOps` is zero on POSIX.

DNS resolution in `startConnectInto` uses the synchronous system resolver;
only socket connect/read/write are non-blocking. This API does not promise
asynchronous DNS, TLS, or arbitrary child-process I/O. From an event loop,
resolve names on another thread and connect with
`startConnectAddrInto(address, &ep, user_data)`: the same steps as above,
with no resolver and no allocator, failing only with `ConnectAddrError`
(`ConnectFailed`, `SocketError`).

`src/socket_test.zig` exercises the same loopback lifecycle on all three backend
families and is the executable usage reference.

### Readiness counts

On kqueue a readable event carries the kernel's count in `Event.avail`: bytes
buffered on a stream, connections queued on a listener. It is 0 where the
count is unknown (always on epoll and IOCP, and on any other event).
`PlainNb.hintReadable(event)` and `Listener.hintReadable(event)` record it, and
`readNb` / `acceptNb` then answer `.want_read` / `.want_accept` without the
call that could only return EAGAIN once that many bytes or connections were
taken. The drain-to-EAGAIN contract is unchanged: with no hint the calls drain
exactly as before, and stopping at the count never strands data because
anything arriving after the kernel took the count raises a new edge.

- Call `hintReadable` on every readable event before the first read or
  accept. Each event replaces the previous count; a count outliving a
  partial drain would strand the rest.
- An EOF event is not hinted (`readNb` keeps reading until it returns `.eof`),
  and every error, EAGAIN or `ResourceExhausted` path clears the hint.
- On IOCP, `hintReadable` is a no-op.

Measured on the loopback benchmark (`bench/RESULTS.md`): one syscall less per
echo and about two less per connection in the accept storm.

## Child processes

`born.process.supported` reports compile-time target support on FreeBSD and
Linux. Linux additionally probes the required pidfd and `waitid(P_PIDFD)`
facilities at spawn and returns `error.Unsupported` on kernels older than 5.4.

`born.process.spawn(argv, envp, opts)` starts a program and returns a
`Child{ .handle, .pid }`; `ep.watchProcess(child.handle, udata)` delivers its
exit through `wait()` as `Event{ .exited = true, .exit = .{ .code = n } }` or
`.exit = .{ .signal = n }`. `src/process_test.zig` is the usage reference.

```zig
const argv = [_:null]?[*:0]const u8{ "/usr/local/bin/role", "--worker" };
var child = try born.process.spawn(&argv, envp, .{
    .stdin = .devnull,
    .fds = &.{ listener_fd, control_fd }, // the child's fds 3 and 4
});
try ep.watchProcess(child.handle, &role);
// ... wait() returns Event{ .exited = true, .exit = ..., .udata = &role }
ep.purgeFd(child.handle);
child.close();
```

| backend | descriptor | exit event | reaping |
|---|---|---|---|
| kqueue, FreeBSD | process descriptor from `pdfork(PD_CLOEXEC)` | EVFILT_PROCDESC NOTE_EXIT, staged into the next `wait()` | unless externally reaped, the zombie stays until the last process descriptor closes; born never calls `wait(2)` |
| epoll, Linux 5.4+ | pidfd from `clone(CLONE_PIDFD)` | pidfd readable, harvested through one internal epoll set | the `wait()` that reports the exit reaps it with `waitid(P_PIDFD)` |
| IOCP; kqueue on macOS, NetBSD, OpenBSD | none | spawn and watch return `error.Unsupported` | n/a |

- **Born's successful spawn and setup path takes no allocator and performs no
  user-space heap allocation:** argv and envp are the caller's NUL-terminated
  arrays, and the fixed descriptor plan is ready before the fork. There is no
  PATH search (`opts.path` or argv[0] is the program). Between fork and execve the child
  makes only async-signal-safe calls. FreeBSD libthr also runs the
  application's `pthread_atfork` handlers around `pdfork`; born registers
  none, and application handlers must obey the same child-side rule for a
  multi-threaded caller to be safe.
- **The child starts with a controlled descriptor and signal state:** it gets
  `stdin`, `stdout` and `stderr` as asked (`.inherit`, `.devnull` or a handle)
  and `opts.fds[i]` as fd 3 + i, up to `born.process.max_fds`; every other
  descriptor is closed. It resets signal dispositions to their defaults and
  enters execve with an empty signal mask, whatever the parent blocks or
  ignores, except that FreeBSD accepts `EINVAL` for libthr-reserved signals
  whose dispositions cannot be reset. A parent that blocks signals for epoll's
  signalfd still has children that SIGTERM ends.
- **Errors are never lost:** a close-on-exec pipe carries a setup or execve
  failure back, so `spawn` returns `FileNotFound`, `AccessDenied`,
  `InvalidExe`, `SetupFailed` (for example a mapped handle that is not open),
  `SystemResources` or `ExecFailed`. It calls `Child.close` for the failed
  child, applying the descriptor-close rules below instead of returning a live
  handle. On success it returns once the child has called execve, as
  `posix_spawn` does.
- **The watch ends with the exit event**, which arrives once. A watch added
  after the process exited fires at the next `wait()`. Re-watching replaces
  the udata; `unwatchProcess` ends a watch on a handle that stays open, and
  before closing, `purgeFd(handle)` is enough, as for any descriptor. Stale
  exit events are tolerated as for timers and signals.
- **Descriptor close has platform-specific reaping rules.** FreeBSD retains an
  exited child as a zombie until its last process descriptor closes, even
  after an exit event. Closing the last descriptor of a running child kills it
  with SIGKILL and leaves init to reap it asynchronously. Linux `close` sends
  SIGKILL, makes a nonblocking `waitid` attempt, and reaps on the spot when a
  status is already available. A still-exiting child's pidfd goes to a lazily
  spawned detached reaper thread. If that thread cannot be spawned or its
  queue cannot allocate space, `close` itself falls back to a blocking reap;
  it is therefore not unconditionally nonblocking. The reaper drains
  oldest-first, so one stalled exit delays later entries (#52). Loop code
  should `child.kill(sig)`, wait for the exit event, then `purgeFd` and `close`,
  which keeps reaping on the spot.
- **kill** signals through the descriptor, so it never reaches a recycled
  pid. After born reaps a reported exit, or after an external wait reaps the
  child, Linux answers `error.Exited`; a FreeBSD zombie accepts and ignores
  signals while it remains.
- **wait(2) elsewhere in the program:** a pdfork child sends no SIGCHLD and
  is invisible to a generic wait for children. A Linux pidfd child is an
  ordinary child and sends SIGCHLD as usual: a `waitpid(-1)` elsewhere can reap
  it first, and its exit event then arrives with `exited` and `err` set, `exit`
  null and `err_no` = ECHILD. A readable pidfd whose status belongs to a tracer
  produces the same event shape with `err_no` = 0. Either error event ends the
  watch. A failed harvest of the internal process set is `error.SourceFailed`
  from `wait()`.
- **Ownership stays explicit:** `EvPort.deinit` releases port-owned watch
  sources and bookkeeping but does not close `Child.handle`, kill the child,
  or perform its final reap. The caller purges and closes the child unless a
  successful Linux reaper handoff has already transferred descriptor ownership
  to that reaper.

## Timers, signals, listeners, and Unix sockets

Born's timer, signal, TCP listener, and Unix domain socket primitives share
the event port's `wait()` model. Their contract tests (`src/timer_test.zig`,
`src/signal_test.zig`, `src/listener_test.zig`, and `src/unix_test.zig`)
exercise each implemented backend. Windows Unix domain sockets return
`error.Unsupported` and their contract tests skip on that backend.

### Timers

`EvPort.addTimer(id, udata, after_ns, .once or .repeat)` and `cancelTimer(id)`
deliver `Event{ .timer = true, .fired = n }` through `wait()`. `after_ns` is
nanoseconds; the kernel rounds the deadline up to its own timer resolution,
so a deadline never fires early within that resolution. `after_ns` above
`born.timer_after_ns_max` is `error.InvalidArgument`. Every runtime-tested
backend (FreeBSD, Linux, Windows, macOS, NetBSD) honors any accepted
`after_ns` up to the ceiling (about 292 years) without firing early, proven
by a contract test that arms the ceiling and a 60-day deadline and asserts
no error event and no immediate firing. OpenBSD is source-verified only.

Each kernel converts a delay exactly only up to a per-platform maximum;
beyond it the conversion wraps or saturates and would fire early. Born
tracks every live timer's absolute deadline, arms at most that maximum per
shot, and re-arms the remainder internally until the deadline is due.

Resolution and exact arm caps per platform:

- FreeBSD kqueue: sbintime precision, sub-millisecond. The exact cap is
  about 34 years, half the sbintime seconds range: the kernel adds the
  current uptime to the sbintime deadline, and a value at the ~68-year
  sbintime maximum would overflow that add, wrap into the past and fire at
  once.
- macOS kqueue: mach absolute time, sub-millisecond. The cap derives from
  the mach timebase read at init; at the shipping 24 MHz (arm64) and 1:1
  (Intel) timebases the full ceiling converts exactly.
- NetBSD and OpenBSD kqueue: one callout tick (1/hz, commonly 10 ms at
  hz 100 or 1 ms at hz 1000). A sub-millisecond delay rounds up to a whole
  tick. The cap is just below INT_MAX callout ticks (about 248 days at
  hz 100, 24.8 days at hz 1000), from kern.clockrate read at init; above it
  tvtohz saturates and would fire early. Nanosecond units require NetBSD
  10.0 / OpenBSD 7.4 or newer; older kernels ignore the unit flag and read
  the delay as milliseconds.
- Linux epoll (timerfd): nanosecond deadlines, sub-millisecond. Absolute
  ktime deadlines represent the full ceiling exactly.
- Windows IOCP: 100 ns due-time ticks, fired on the system clock tick. The
  full ceiling fits the signed 100 ns due-time range.

### Signals

`EvPort.watchSignal(sig, udata)`, `unwatchSignal(sig)`, and
`born.blockSignals(sigs)` deliver `Event{ .signal = sig, .fired = n }` for
`interrupt`, `terminate`, `hangup`, `user1`, and `user2`. Windows maps console
control events onto this surface and rejects signals it cannot represent.

### TCP listeners

`born.socket.Listener.openTcp(addr, opts)`, `register`,
`acceptNb(stream, key)`, `localAddress`, and `close` provide non-blocking TCP
accept on POSIX and Windows. `ListenOptions.reuse_port = .balanced` requests
kernel-balanced listener sharing where supported.

### Unix domain stream sockets

POSIX provides `Listener.openUnix(path, opts)` and
`PlainNb.startConnectUnixInto(path, ...)`. Windows returns
`error.Unsupported` for these operations.

### Primitive contracts

- **Timers are for deadlines, never for driving I/O:** idle timeouts, expiry
  sweeps, periodic aggregation. Born's rule against timer-driven I/O stands.
- **Timer and signal events arrive through `wait()` like any other event.**
  There are no callbacks, and no extra threads on POSIX. On IOCP a thread-pool
  timer or console handler may only `post()`.
- **Stale events:** an event already harvested in the current batch can
  still name a timer or signal that was cancelled or unwatched during that
  batch. Tolerate it, as for a purged descriptor.
- **Timer ids** are caller-chosen and unique per port; re-adding a live id
  replaces it. Cancelling an unknown or expired id is a no-op. A `.once`
  timer with `after_ns = 0` is due at the next `wait()`; a `.repeat` timer
  with `after_ns = 0`, or any `after_ns` above `born.timer_after_ns_max`, is
  `error.InvalidArgument`.
- **Signals are process-wide.** At most one port watches a given signal; a
  second gets `error.SignalInUse`. On epoll the signal must be blocked in
  every thread (signalfd), so call `born.blockSignals` in `main` before
  spawning threads; `watchSignal` reports `error.SignalNotBlocked` otherwise.
  On kqueue and Windows `blockSignals` is a no-op, so portable programs call
  it unconditionally. Unwatching restores the prior disposition.
- **Windows signals are console control events:** CTRL_C_EVENT is
  `.interrupt`; CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT and CTRL_SHUTDOWN_EVENT
  are `.terminate`. `.hangup`, `.user1` and `.user2` are `error.Unsupported`,
  and so is every signal in a process without a console (a service or GUI
  program). After CTRL_CLOSE_EVENT or CTRL_SHUTDOWN_EVENT the system ends
  the process when the program exits or after its timeout (5 s for a closed
  console window): finish shutdown within that time. Watching `.interrupt`
  clears an inherited CTRL+C ignore flag; unwatching sets it again. Changing
  the process's console (FreeConsole, AllocConsole, AttachConsole) drops
  every watch without an error born could detect, so change consoles before
  watching, or unwatch every signal and watch again. A port must not move
  while it watches a signal.
- **`.balanced` reuse-port** means the kernel spreads connections across
  listeners on one port: `SO_REUSEPORT_LB` on FreeBSD, `SO_REUSEPORT` on
  Linux. Where the platform can only share a port without balancing (macOS,
  NetBSD, OpenBSD) or not at all (Windows), it is `error.Unsupported`.
- **Accept drain:** on POSIX, call `acceptNb` until `.want_accept` on every
  listener event; descriptor exhaustion is `error.ResourceExhausted`, the
  signal to pause the listener with `unmonitorRead`. On Windows, feed listener
  completions to `Listener.absorbCompletion` first, and on teardown absorb
  until `pendingOps() == 0`, as for `PlainNb`.
- **Unix socket paths** that do not fit `sun_path` are `error.NameTooLong`,
  never truncated. `unlink_stale` replaces a socket file that refuses
  connections and never unlinks a live listener (`error.AddressInUse`) or a
  non-socket file (`error.PathNotASocket`). The mode is applied before
  `listen`, so there is no window with wider permissions. On POSIX the
  stale check is a datagram connect probe, so a live listener with a full
  backlog is never mistaken for a stale file, and `close` removes the path
  only from the process that bound it and only while it is still that file.
- **Nothing fails silently:** every refusal reaches the caller as an error
  from the call, or from the next `wait()` for deferred registrations.

## std.Io compatibility shim (born.io)

On Zig >= 0.16, born also exports `born.io`: a `std.Io` interface composing
Born's event port with upstream's `Io.Threaded` worker pool. Capability
routing is explicit: each family is serviced either by Born's reactor or by
Threaded, and a Born route that is not implemented is rejected at
construction (`CapabilityUnsupported`), never silently delegated.

**Status in v0.3.0: opt-in and experimental.** `born.io` requires Zig >= 0.16
and is not exported on 0.15.2. The Born time route
(`capabilities.time = .born_evented`) is experimental: it currently misses its
written benchmark target, and the remaining work is tracked in #101. It is not
recommended for production until #101 meets that target. The Born network
client route (`capabilities.network = .born_evented`) is likewise opt-in and
experimental. The default remains the all-Threaded baseline, which is the
supported configuration in 0.3.0.

The time family is the first enabled Born route
(`capabilities.time = .born_evented`): `sleep` runs on Born's timers and
monotonic `now` on Born's timer clock; every other slot delegates to
Threaded. One loop thread per instance drives the port. A blocking sleep
submits a caller-owned operation node through an intrusive queue into a
loop-owned slot table; the timer identity is the slot index plus a
generation, so a stale timer fire is dropped without touching caller
storage. The queue wakes the loop only on empty-to-non-empty transitions,
and cancellation rides a dedicated cancel list, so neither path scans the
armed population. Completion returns through a Threaded futex so
cancellation composes with Threaded's cancel machinery. The queue is
bounded by caller storage (one node per blocking call), so queue-full
cannot occur: `sleep`'s only error is `Canceled`, meaning the sleep was
interrupted (task cancellation, shim stop, or kernel timer exhaustion),
never overload. Route-level refusals (port wait failures, timer-arm
refusals, slot-table growth failures) are latched and readable via
`born_io.loopError(io)`. Born timers are millisecond-granular: a sleep
shorter than 1 ms costs at least 1 ms. `clockResolution(.awake)` stays on
Threaded, so on macOS and Windows it reports the resolution of Threaded's
awake clock, not of the Born timer clock that `now(.awake)` reads. The
per-slot failure mapping and the Scale model machinery are documented in
`src/io/shim.zig`.

The network client route (`capabilities.network = .born_evented`) services the
stream client path on Born's reactor: IP and pathname Unix connect (with
connect deadlines), stream reads and writes, close and shutdown. Listen,
accept and DNS resolution stay on Threaded. A handle registry tracks only
Born-owned sockets; a handle it does not know is forwarded to Threaded, so a
Threaded listener and a Born connect compose in one interface. A socket is
unregistered from the registry before its descriptor closes, so an fd or
SOCKET value reused by another thread never resolves to a dying slot. Socket
event identity carries a generation, so an event for a closed-and-reused
handle is dropped without touching caller storage. Read interest is
persistent: armed once when the connect completes and removed only at close,
with a readable event that has no pending read recording the kernel hint, so
a completed parked read does not unmonitor and re-arm on the hot path. A
parked-read echo benchmark on Linux epoll (`bench/net.zig`, `strace -f -c`)
measures the saving: `epoll_ctl` drops from 2.00 to about 0 per request and
total syscalls from 17.76 to 15.62 per request, at a small consistent
latency cost (~30us p50) dominated by the server delay. Every
submitted op attempts its operation once when the loop swaps it in and arms
interest only on a not-ready result, so edge-triggered readiness cannot
strand already-buffered data. A second concurrent read or write on a parked
op is rejected rather than orphaning it.

Born outcomes map coarsely onto the declared std error sets (a failed read or
write becomes `ConnectionResetByPeer`); `Canceled` is reserved for real
cancellation and the deinit stop request. A dead route (a close of the op's
socket, a failure loop exit, or a submit refused after the queue dies)
surfaces as `Unexpected`, never as the caller's cancellation. Out-of-profile
requests are declared errors, never silent fallbacks: bind and
non-stream/non-TCP connect options return `OptionUnsupported`, socket pairs
`OperationUnsupported`, message and control-buffer I/O on a Born-owned handle
complete with their tag result `Unexpected` (a batch with Born members
completes those members per-op and awaits the rest normally), and
`netWriteFile` is a read/copy loop through the Born write path on 0.16 and
declared `Unimplemented` on 0.17.

Connect timeouts stay on the Born route for every clock: a `.duration` is
relative, and a `.deadline` on `.real` or `.boot` is converted to a Born
monotonic deadline using that clock's now; a clock read refusal fails the
connect with `Unexpected` rather than dropping the timeout. On Windows,
connect timeout and close drain pending IOCP completions before the socket
state is freed, and at loop exit every socket is canceled first, then
completions are dispatched to their owning socket until the outstanding op
count reaches zero. `shutdown()` does not complete pending overlapped ops, so
a recv/send shutdown also cancels the in-flight `WSARecv`/`WSASend` and the
loop completes a parked read with EOF. Per-route counters (connect, read
and write completions serviced by Born, and Threaded-forward counts) are
readable via `born_io.networkStats(io)` when the `network_stats` build
option is on (default off; the test and bench builds enable it). The
per-slot contracts and the coarse error map are documented in
`src/io/shim.zig`.

```zig
// build.zig (Zig >= 0.16)
const born = b.dependency("born", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("born", born.module("born"));
exe.root_module.addImport("born.io", born.module("born.io"));
```

```zig
const born = @import("born");
const born_io = @import("born.io");

var port = try born.EvPort.init(allocator);
defer port.deinit();
const io = try born_io.io(&port, .{
    .allocator = allocator,
    .capabilities = .{ .time = .born_evented },
});
defer born_io.deinit(io);
try std.Io.sleep(io, .fromMilliseconds(10), .awake);
```

```zig
// Network client route: DNS stays Threaded, connect and stream I/O run on Born.
const io = try born_io.io(&port, .{
    .allocator = allocator,
    .capabilities = .{ .network = .born_evented },
});
defer born_io.deinit(io);
const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 8080);
var stream = try addr.connect(io, .{ .mode = .stream });
defer stream.close(io);
var wbuf: [64]u8 = undefined;
var writer = stream.writer(io, &wbuf);
try writer.interface.writeAll("ping");
try writer.interface.flush();
```

The all-Threaded baseline (every slot delegated, no loop thread) remains
available and is the default. The shim is isolated: the core never imports
it, and the build enforces that boundary on every toolchain. Removal is
`git rm -r src/io` plus the conditional export lines in `build.zig`.

### Proof consumers

The `consumers/` package proves the born.io network client route against
real upstream consumers: the nats.zig client (unit and e2e suites) and
std.http.Client (a born-owned contract suite). It is a separate package
with its own build graph; born's root build and shipped module set are
unchanged, and nothing in `consumers/` ships downstream. A generated std
facade redirects `std.testing.io` to a fresh born-backed Io per test, so
the vendored consumer tests run on the shim without source changes.

- nats unit + e2e (Zig 0.16.0): the upstream tests tree is vendored
  byte-identical at pin b8ffdd9 and hash-verified against
  `consumers/nats/manifest.sha256` at configure time; the generated tree
  is written from those verified bytes. The only permitted difference is
  tests/utils.zig, a born-owned facade that provisions
  native nats-server v2.15.0 child processes (sha256-pinned per OS in CI)
  in place of docker-compose, on the vendored fixed loopback ports.
- std.http.Client contracts (Zig 0.16.0 and 0.17.1): eight born-owned
  tests over plain HTTP against a plain-Threaded fixture server. This
  suite carries the 0.17.1 consumer proof.
- Gap note: upstream nats.zig tip does not build on 0.17.1, so the nats
  legs are 0.16.0-only; #109 tracks the port. On 0.17.1 the consumer
  proof is the HTTP suite plus the born.io shim suite.

Every suite runs on born.io (`capabilities.network = .born_evented`) and,
as a permanent control leg, on the all-Threaded baseline
(`-Dborn-network=false`) with identical results required. The shared test
runner asserts route proof from the shim's network counters, per test on
a fresh reactor: no consumer connect may be delegated to Threaded
(`threaded_connect == 0` on every born leg) and born connect > 0; e2e and
HTTP also require born read and write > 0. The nats-e2e leg additionally
shows fixture-side threaded read/write: the vendored keepalive
stale-connection and reconnect_limits handshake-failure tests run fake
servers whose listen/accept handles are Threaded-owned under the shim's
client-only profile, so their reads/writes forward by design. Only those
two tests may move threaded read/write; any other test doing so fails
the leg. That is fixture traffic, not consumer traffic.
`TEST_ROUTE_TRACE=1` prints the per-test threaded deltas for attribution
audits.

CI (`.forgejo/workflows/consumers.yml`) builds every leg on each push and
pull request (FreeBSD native plus Linux and Windows cross-builds, with
sha256) and runs the suites on all three kernels weekly and on
workflow_dispatch (the release gate). The HTTP consumer benchmark
(`zig build bench-http`, driver `consumers/bench/http.sh`) is a
per-release recording step under the same quiet-host guard as
`bench/time.sh`, not a gate.

Run locally from `consumers/` with Zig >= 0.16 (the e2e suite needs
nats-server v2.15.0 on PATH):

```
zig build test-unit
zig build test-e2e
zig build test-http
zig build test-unit -Dborn-network=false
```

A project-local `zig-pkg/` directory overrides dependency fetching, so
clean-fetch evidence must run from a clean checkout without it and with
an empty global cache.

## Use

Fetch the archive with `zig fetch` for its hash. Replace `master` with a full
commit ID when pinning a consumer reproducibly.

```zig
// build.zig.zon
.dependencies = .{
    .born = .{ .url = "https://pacyworld.dev/pacyworld/born/archive/master.tar.gz", .hash = "..." },
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
zig build test       # backend, public API and socket tests for the selected target
zig build test -Doptimize=ReleaseSafe
zig build check-targets   # semantic compilation of test bodies for all seven triples
zig build docs            # API documentation in zig-out/docs/index.html
zig build test-bin -Dtarget=x86_64-windows-gnu --prefix zig-out/windows
zig build test-bin -Dtarget=x86_64-linux-gnu --prefix zig-out/linux
zig build test-io-bin -Dtarget=x86_64-linux-gnu --prefix zig-out/linux   # born.io, Zig >= 0.16
zig build examples            # install born-echo-server and born-echo-per-core
zig build example-smoke       # example integration tests on the selected target
zig build example-smoke-bin -Dtarget=x86_64-linux-gnu --prefix zig-out/linux
```

Born supports Zig 0.15.2, 0.16.0, and 0.17.1. `src/compat.zig` owns native ABI
and toolchain-version differences; core code does not depend on `std.Io`.
TCP companions accept `born.socket.Address`, Born's native sockaddr union, on
all three toolchains. Callers using `std.net.Address` must migrate to this type.

The module propagates its libc or Winsock/kernel32 linkage. Forgejo CI
(`.forgejo/workflows/ci.yml`) runs a toolchain matrix over Zig 0.15.2, 0.16.0,
and 0.17.1: each toolchain runs the FreeBSD Debug and ReleaseSafe suites
(kqueue), compiles the seven-target test matrix, generates API documentation,
and cross-builds the Linux and Windows test executables in both optimize modes
(on Zig >= 0.16 the `born.io` test executables too).
The Linux (epoll, Ubuntu 24.04) and Windows (IOCP, Windows Server 2022) runtime
jobs run those executables per toolchain and optimize mode, verifying each
executable's SHA-256 against the build. A single Zig 0.15.2 `zig fmt --check`
gate carries formatting and README/AGENTS consistency; there is deliberately no
fmt matrix, because the 0.17.1 formatter rewrites enum builtins unavailable in
0.15.2. `check-targets` is deliberately compile-only, not evidence that target
libraries link or that tests ran on those operating systems. Outside CI, run
the `test-bin` output on its matching platform (see the runtime-evidence rule
in `AGENTS.md`).

Two scheduled gates run weekly and on dispatch, separate from the per-commit
CI. `stress.yml` runs the suite 500 times under bounded CPU load on FreeBSD and
Linux (the #45 repro shape; a failure is a release blocker). `bench.yml` runs
the kqueue benchmark on a quiet FreeBSD CI runner and fails on a syscall or
latency regression against `bench/thresholds.txt` (#31). macOS Apple Silicon
stays a manual host; the target-coverage list in `AGENTS.md` says which
targets run in CI, on manual hosts, or compile-only.

## Examples

`examples/` holds two reference programs for downstream ports. Both import
only the public `born` module and the shared echo engine (`examples/echo.zig`),
so they compile on all seven supported triples and show the contracts above
in a complete program rather than a fragment.

- **`born-echo-server`** (`examples/echo_server.zig`): a single-threaded TCP
  echo server on one event port. A TCP listener accepts into a fixed table of
  stable stream slots; an idle-timeout sweep timer closes silent connections;
  SIGTERM or Ctrl+C closes the listener and drains established connections
  until they finish or a drain deadline fires. Usage: `born-echo-server [port]`
  (default 7000, binds 127.0.0.1). On Windows the signal watch maps to console
  control events and needs a console.
- **`born-echo-per-core`** (`examples/thread_per_core.zig`): the thread-per-core
  variant. N worker threads each own one event port and one `.balanced`
  listener on the same TCP port; the kernel spreads connections across them
  (`SO_REUSEPORT_LB` on FreeBSD, `SO_REUSEPORT` on Linux). The main thread
  watches SIGTERM/Ctrl+C and shuts workers down with cross-thread `wake()`.
  Usage: `born-echo-per-core [port] [threads]` (default port 7001, one thread
  per CPU, clamped to 1..64). `.balanced` needs kernel load balancing, so this
  program runs on FreeBSD and Linux; elsewhere it reports Unsupported and
  exits cleanly. It still compiles on every target.

The engine demonstrates the rules that matter for a port: accepted streams
live in stable heap slots and a Windows slot is not reused until its close
completions are absorbed; reads drain to EAGAIN (or a posted receive) and a
full echo buffer resumes reading after the pending write drains, so no edge
is stranded; write interest is armed only on `want_write`; listener exhaustion
and a full table pause with `unmonitorRead` and resume by re-registering and
draining at once; timers measure deadlines, never drive I/O.

`zig build example-smoke` runs an integration suite (`examples/smoke.zig`)
through the engine with real sockets on the selected backend: echo round trip,
idle-timeout close, large-payload partial writes and backpressure, cross-thread
wake shutdown, SIGTERM drain (POSIX), and balanced-listener spread
(FreeBSD/Linux). CI runs it on FreeBSD, Linux and Windows alongside the core
suite, so the examples carry runtime evidence, not just cross-compilation.

## Provenance

Born was extracted from [mcp-bridge](https://pacyworld.dev/buenapp/mcp-bridge),
where these backends have run in production since August 2026. The backend
chapters in [docs/](docs/README.md) describe their current registration,
error-surfacing, and object-lifetime contracts.

## Licence

BSD-3-Clause. Copyright (c) 2026, The Daniel Morante Company, Inc.
