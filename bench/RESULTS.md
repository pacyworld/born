# kqueue hot-path results

Host: FreeBSD 15.1-RELEASE-p2 amd64 development host, Intel Xeon E5-2620 v4,
20 CPUs, `kern.hz=100`. Zig 0.15.2, ReleaseSafe. Server on CPU 2, clients on
CPUs 4-11 (`bench/README.md`). The host is shared, so throughput and tail
latency carry noise; every cell is the median of 5 repetitions with (min-max)
beside it. Syscalls per request come from DTrace on the server; the loop's own
calls are deterministic.

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
connection.

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

macOS check (second kqueue): MacBook Pro, Apple silicon (Darwin 25.1.0 arm64), Zig
0.15.2 ReleaseSafe, `born-bench wake --seconds 4`, three alternating runs of the
pipe tree and the EVFILT_USER tree. Wake round trips per second: pipe 194865,
198554, 196309; EVFILT_USER 354206, 356599, 351369 (+80%). p50 4 us falls to 2 us
(1 us clock granularity); p99 7 to 6 us. All 98 tests pass there with the
EVFILT_USER wake and the readiness-count tests asserting the kernel's counts.

## (d) Accept filter (accf_data) and (e) event buffer size: not measured, not adopted

Both were implemented and built (accept filter: `ListenOptions.accept_filter`,
`error.AcceptFilterUnavailable`, tests passing with `accf_data` loaded;
buffer: `kbuf` 64 to 256). Measurement then became impossible: sustained
foreign load pushed the host's load average to 30-35 and the single `ip` netisr
thread (`netstat -Q`: queue limit 256, 333977 queue drops) started dropping
loopback packets. Every connection storm stalled for 0.5-4 s on SYN
retransmits, with or without the filter and on every `cpuset` choice, and even
`echo16` fell from about 100000 to 1424 req/s. System settings were not changed.

| Run (storm16 unless noted, host degraded) | req/s | notes |
|---|---|---|
| plain | 6 (2-33500) | p50 1.4 s |
| filter + read after accept | 7 (2-112) | p50 1.9 s |
| read after accept only | 7 (3-11) | p50 1.5 s |

These numbers say nothing about the filter. With no measured improvement,
neither change is in this tree. The accept-filter patch is attached to issue #31
and the benchmark keeps `--read-after-accept`, so both can be measured on a
quiet host: `SERVER_ARGS=--read-after-accept` against the patch's
`--accept-filter`. Expected effect to confirm: with the filter a lone
connection needs one `kevent` wake instead of two. `kbuf` stays 64 (it matters
only when more than 64 events are ready per wait).

## P4 gate calibration (master 36677d7, truss)

The P4 benchmark regression gate (`bench/regress.sh`, `bench/thresholds.txt`,
`.forgejo/workflows/bench.yml`) counts syscalls with `truss -c` instead of
DTrace, so it needs no root on runner01. This run calibrates the thresholds to
that method. Host: FreeBSD 15.1-RELEASE-p2 amd64, 20 CPUs, `kern.hz=100`, Zig
0.15.2 ReleaseSafe, server CPU 2 / clients CPUs 4-11, `SYSCALLS=truss`, 5 reps,
2026-11-12. The quiet-host guard (`bench/quiet.sh`) passed before and after the
run: load1 4.91 then 7.04 (both <= 0.5*20 = 10), ip netisr queue Len 0, QDrops
delta 0 over 3 s.

| Scenario | req/s | p50 us | p99 us | p99.9 us | syscalls/req (truss) |
|---|---|---|---|---|---|
| echo1 | 17530 (15570-18740) | 46.1 (40.8-51.2) | 173.7 (162.4-188.2) | 515.1 (454.9-635.2) | 3.009 (3.009-3.011) |
| echo16 | 86490 (78200-97430) | 138.3 (119.2-163.2) | 327.2 (309.8-359.6) | 2274 (2064-3353) | 2.076 (2.075-2.078) |
| storm16 | 17140 (16280-20790) | 578.9 (525.2-643.2) | 1243 (1099-2598) | 66410 (60210-94500) | 5.143 (5.141-5.152) |
| bulk4 | 522 (495-532) | 7576 (6501-7738) | 12190 (9905-12330) | 24450 (18410-327500) | 5.744 (5.692-5.954) |
| wake | 58420 (56570-61360) | 11.7 (11.6-12.1) | 46.5 (45.4-48.1) | 113.9 (110.5-121) | 4.232 (4.206-4.235) |

truss and DTrace report different totals for the multi-connection scenarios
(echo16 2.076 here vs 2.626 in (a); storm16 5.143 vs 7.305), so the gate's
thresholds are calibrated to these truss medians, not the DTrace baseline.
Syscalls/req is deterministic (spread < 0.01); its bound sits roughly 0.5-0.9
above the median, so a regression of about one syscall per request trips it,
such as losing the readiness counts (echo1 3.009 -> ~4) or the EVFILT_USER wake
(wake 4.232 -> ~8 back on the pipe).
Latency carries the shared host's noise (echo1 p50 46.1 here vs ~30 in the
quieter (a)/(c) runs); its bound is roughly 2x the median, a coarse guard
against gross regressions rather than noise. `bench/regress.sh` reports all
fifteen metrics within bounds on this run. The wake round trip stays near 4
syscalls, confirming (c) is in this tree.

Re-verified on the CI host via workflow dispatch (born run #156, commit
`25f5b35`): runner01 is FreeBSD 15.1-RELEASE-p5 with **6 CPUs**, so the bench
takes the `ncpu < 12` pinning branch (server CPU 0, clients CPUs 0-5). The
quiet guard passed (load1 2.68 <= 0.5*6 = 3.00, ip netisr Len 0, QDrops delta
0) and all fifteen metrics stayed within these same thresholds, so no
recalibration was needed. runner01's faster hardware lowers latency (echo1 p50
17.8 us, wake p50 4.7 us); syscalls/req matches the calibration (echo1 3.005,
echo16 2.068, storm16 5.132, bulk4 5.621, wake 4.845).
