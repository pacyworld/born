# kqueue hot-path results

Host: freebsd-dev1, FreeBSD 15.1-RELEASE-p2 amd64, Intel Xeon E5-2620 v4,
20 CPUs, `kern.hz=100`. Zig 0.15.2, ReleaseSafe. Server on CPU 2, clients on
CPUs 4-11 (`bench/README.md`). The host is shared with other sessions, so
throughput and tail latency carry noise; every cell is the median of 5
repetitions with (min-max) beside it. Syscalls per request come from DTrace on
the server; the loop's own calls are deterministic. Raw runs: `bench/raw/<step>/`.

Scenarios: `echo1` one connection, 64-byte echo; `echo16` sixteen connections;
`storm16` sixteen threads of connect, 1 byte, reply, close; `bulk4` four
connections, each request a 16-byte message answered with 4 MiB; `wake` one
round trip of two `wake()` calls between two threads.

## Baseline (master 3b75fa8 plus the benchmark)

| Scenario | req/s | p50 us | p99 us | p99.9 us | syscalls/req |
|---|---|---|---|---|---|
| echo1 | 22680 (19510-32630) | 32.1 (24.8-36.9) | 126.5 (92.5-150.7) | 302.5 (181.3-562) | 4.001 |
| echo16 | 106400 (81740-142700) | 132.4 (99.9-154.2) | 300.7 (240.1-359.8) | 599.8 (440.7-911.3) | 3.578 (3.572-3.602) |
| storm16 | 32980 (27020-35200) | 459 (393.3-484.7) | 894.5 (827.4-983.2) | 1468 (1300-1641) | 9.153 (9.016-9.176) |
| bulk4 | 510 (491-534) | 7302 (6947-7878) | 11780 (10200-12440) | 231100 (20770-350300) | 6.959 (6.857-7.692) |
| wake | 46910 (45610-51750) | 15.9 (14.4-17.7) | 52.6 (48.7-55.8) | 118.1 (108-128) | 8.001 |

Where the syscalls go (per request): an echo is `kevent` 1 + `read` 2 + `sendto`
1 (echo1), the second `read` only returning EAGAIN. A storm connection costs
`kevent` ~2.4, `accept4` ~1.9 (one extra that returns EAGAIN), `read` 3
(data, EAGAIN, the client's reset), `sendto` 1, `close` 1. A wake round trip
costs per wake: `write` 1, `kevent` 1 and `read` 2 (the drain). A bulk request
is ~4.4 `sendto` (64 KiB chunks from a 1 MiB pattern buffer), `read` 2 and
`kevent` ~0.5; about 0.3 of its `sendto` calls per request end in EAGAIN and
arm write interest.

## (a) Readiness counts: `Event.avail` and `hintReadable` (adopted)

The bench server calls `hintReadable(ev)` on each listener and stream event.

| Scenario | req/s | p50 us | p99 us | p99.9 us | syscalls/req (baseline) |
|---|---|---|---|---|---|
| echo1 | 23690 (18940-30340) | 30.5 (28.2-31.2) | 111.8 (98.6-121.5) | 378.5 (262.4-421.6) | 3.001 (4.001) |
| echo16 | 111200 (101200-126600) | 128.5 (111.6-141.1) | 309.5 (237-338.6) | 685.6 (370.3-807.1) | 2.626 (3.578) |
| storm16 | 31810 (28020-37180) | 427.8 (340.6-474.3) | 853.3 (744.1-887.8) | 1823 (1226-23450) | 7.305 (9.153) |
| bulk4 | 496 (481-518) | 7682 (7387-7978) | 11210 (10730-12260) | 18840 (17500-57780) | 6.234 (6.959) |
| wake | 50590 (47140-51190) | 16.2 (14.2-17.1) | 51.4 (50.8-53.7) | 117.2 (112.2-124.3) | 8.001 (8.001) |

Syscalls fall by one per echo (the read that only returned EAGAIN), by one
accept4 per storm connection plus the same read, and by ~0.7 per bulk request.
Latency and throughput stay inside the run-to-run noise (echo1 p50 -5%,
storm16 p50 -7%, both within the baseline's own min-max). Adopted for the
syscall reduction; wake is untouched, as expected.

## (b) EV_DISPATCH + EV_ENABLE write re-arm (rejected)

Interleaved A/B (`bench/ab.sh`, 6 pairs, scenarios echo16, storm16, bulk4) of
`wantWrite` staging `EV_ADD | EV_ONESHOT` (A, the (a) tree) against
`EV_ADD | EV_DISPATCH | EV_ENABLE` (B). Only bulk4 arms write interest (about 0.3
re-arms per request, 6% of its events); echo and storm never do. Server CPU per
request is the process CPU time (`clock_gettime(PROCESS_CPUTIME_ID)`) divided by
requests.

| Scenario | req/s A | req/s B | server cpu us/req A | server cpu us/req B | syscalls/req A | B |
|---|---|---|---|---|---|---|
| bulk4 | 500 (472-532) | 500 (461-526) | 2040 (1938-2211) | 2031 (1969-2118) | 6.013 | 6.031 |
| echo16 | 94240 (86530-124900) | 114300 (98470-139700) | 6.59 (5.50-6.83) | 6.29 (4.85-6.75) | 2.601 | 2.614 |
| storm16 | 32480 (27080-38340) | 26800 (21120-37990) | 15.42 (14.30-18.51) | 16.84 (13.32-18.72) | 7.372 | 7.384 |

The syscall count is identical by construction. bulk4 CPU per request differs by
0.4%, far inside the 5-10% spread, and echo16/storm16 differences go in both
directions with the host's drift. The kernel saves a knote allocation per
re-arm, but at six re-arms per hundred events it does not show. **Rejected, not
adopted:** `wantWrite` stays `EV_ONESHOT`, which also avoids a parked knote per
connection. Raw runs: `bench/raw/b-rejected/`.

## (c) EVFILT_USER for `wake()` (adopted on FreeBSD and macOS)

Interleaved A/B (`bench/ab.sh`, 6 pairs) of the (a) tree (pipe) against EVFILT_USER.
The wake round trip is the only scenario that calls `wake()`; echo1 and echo16 are
guards.

| Scenario | req/s A | req/s B | p50 us A | p50 us B | p99 us A | p99 us B | syscalls/req A | B |
|---|---|---|---|---|---|---|---|---|
| wake (round trip) | 50720 (47720-52810) | 65330 (61930-75500) | 14.8 (14.3-17.7) | 11.8 (10.3-12.9) | 48.1 (45.4-52.5) | 39 (33.2-42.8) | 8.001 | 4 |
| echo1 | 25610 (17770-30170) | 25570 (21350-27790) | 27.8 (27.5-32.7) | 28.8 (27.9-31.2) | 101.1 (96.3-124) | 103.3 (97.8-115.2) | 3.001 | 3.001 |
| echo16 | 94810 (79350-106200) | 96110 (67070-125300) | 133.9 (114.7-163.9) | 129.1 (118-143.2) | 308.8 (303.5-329.4) | 275.9 (249.2-325) | 2.627 | 2.593 |

A wake round trip drops from 8 to 4 syscalls (per wake: `write` + `read` x2 + the
loop's `kevent` become a trigger `kevent` + the loop's `kevent`), p50 -20%, p99
-19%, throughput +29%, with the ranges apart. The echo guards do not move.
Raw runs: `bench/raw/c/`.

macOS check (second kqueue): MacBook Pro, Apple silicon (Darwin 25.1.0 arm64), Zig
0.15.2 ReleaseSafe, `born-bench wake --seconds 4`, three alternating runs of the
pipe tree and the EVFILT_USER tree. Wake round trips per second: pipe 194865,
198554, 196309; EVFILT_USER 354206, 356599, 351369 (+80%). p50 4 us falls to 2 us
(1 us clock granularity); p99 7 to 6 us. All 98 tests pass there with the
EVFILT_USER wake and the readiness-count tests asserting the kernel's counts.

## (d) Accept filter (accf_data) and (e) event buffer size: not measured, not adopted

Both were implemented and built (accept filter: `ListenOptions.accept_filter`,
`error.AcceptFilterUnavailable`, tests passing with `accf_data` loaded on
freebsd-dev1; buffer: `kbuf` 64 to 256), then measurement became impossible:
from about 06:40 on 2026-10-22 freebsd-dev1 was loaded by other work (load
average 30-35: a root `xz` with 21 threads running 19+ hours, builds from other
sessions), and the single `ip` netisr thread (`netstat -Q`: 1 thread, queue
limit 256, 333977 queue drops) started dropping loopback packets. Every connection
storm then stalled for 0.5-4 s on SYN retransmits, with or without the filter and
on every `cpuset` choice, and even `echo16` fell from about 100000 to 1424 req/s.
Changing `net.isr` settings or killing the foreign job is outside this work.

| Run (storm16 unless noted, host degraded) | req/s | notes |
|---|---|---|
| plain | 6 (2-33500) | p50 1.4 s |
| filter + read after accept | 7 (2-112) | p50 1.9 s |
| read after accept only | 7 (3-11) | p50 1.5 s |

These numbers say nothing about the filter. With no measured improvement, neither
change is in this branch. The accept-filter change is kept as a patch against this
branch's parent (`born31-accept-filter.patch` in the session notes folder) and
the benchmark keeps `--read-after-accept`, so both can be measured on a quiet
host: `SERVER_ARGS=--read-after-accept` against the patch's `--accept-filter`.
Expected effect to confirm: with the filter a lone connection needs one `kevent`
wake instead of two. `kbuf` stays 64 (it matters only when more than 64 events are
ready per wait).
