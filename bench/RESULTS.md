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
