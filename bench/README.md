# born kqueue hot-path benchmark

`zig build bench` installs `zig-out/bin/born-bench`. The step is not part of
`test`, `test-bin` or `check-targets`. FreeBSD only (the driver uses `cpuset`
and `truss`); the executable itself builds on any POSIX target.

```
zig build bench -Doptimize=ReleaseSafe --prefix /tmp/bb
sh bench/run.sh /tmp/bb/bin/born-bench echo  5 --threads 1
```

## What runs

`born-bench serve` is one born loop: a TCP listener, accepted `PlainNb`
streams, and a deadline timer that ends the run. It echoes what it reads,
draining reads to `EAGAIN`, attempting every write first and arming write
interest only after a short write. `born-bench client` is a blocking-socket
load generator, one thread per connection, timing every request with
`clock_gettime(CLOCK_MONOTONIC)`.

| Mode | Client behaviour | Exercises |
|---|---|---|
| `echo` | `--threads` persistent connections, 64-byte request and reply | read path, `kevent` batching |
| `storm` | `--threads` threads looping connect, 1 byte, reply, close (reset on close, so no TIME_WAIT) | accept path |
| `bulk` | persistent connections, 16-byte request, 4 MiB reply (`REPLY`) | short writes, write re-arm |
| `wake` | two ports on two threads bounce `wake()`; round trip = two wakes | `wake()` |

## Method

- `bench/run.sh BIN MODE REPS [client args]` pins the server to CPU 2 and the
  clients to CPUs 4-11 (`SRV_CPUS`, `CLI_CPUS`), runs `SECS` seconds (default
  5) per pass and repeats `REPS` times.
- Each repetition has two passes. The **plain** pass reports p50/p99/p99.9
  latency and requests per second. The **truss** pass runs the same load with
  `truss -c -o FILE` on the server only and prints the syscall table plus
  `syscalls / requests`. truss slows the server several times over, so only
  its syscall counts are used, never its latency.
- Syscalls per request is the server's total, including startup and
  teardown, divided by the requests the client completed (a connection
  cycle for `storm`). The fixed cost is a few hundred calls over 10^4 to 10^6
  requests.
- Alternative count without truss: `ktrace -di -f /tmp/k.out ...` then
  `kdump -f /tmp/k.out | awk '/CALL/ {print $4}' | sort | uniq -c`.
- Latency uses `CLOCK_MONOTONIC` directly: on FreeBSD `std.time.Timer` reads
  `CLOCK_MONOTONIC_FAST`, which advances once per tick (10 ms at `kern.hz=100`).
- Report the spread over at least five repetitions, not one number.
- The `server` line carries loop counters: `waits` (`kevent` calls),
  `events`, `accepts`, `reads`, `writes`, `short_writes`.

Scenarios used in `RESULTS.md`:

```
sh bench/run.sh BIN echo  5 --threads 1      # latency of one connection
sh bench/run.sh BIN echo  5 --threads 16     # saturated loop
sh bench/run.sh BIN storm 5 --threads 16     # accept storm
REPLY=4194304 sh bench/run.sh BIN bulk 5 --threads 4  # short writes
sh bench/run.sh BIN wake  5
```

## Threaded sleep baseline benchmark

`zig build bench-time` (Zig >= 0.16) installs `zig-out/bin/born-time-bench`.
The step is not part of `test`, `test-bin` or `check-targets`. It measures the
all-Threaded baseline's sleep family:

```
zig build bench-time -Doptimize=ReleaseSafe
sh bench/time.sh zig-out/bin/born-time-bench 3
```

- Sequential phase: `--seq` sleeps (default 200) of `--sleep-ms` (default 1)
  on the calling thread; reports p50/p99/max/mean per-sleep latency.
- Concurrent phase: `--threads` blocking threads (default 64), one sleep in
  flight per thread for `--seconds` (default 5); reports completed sleeps per
  second and p50/p99 per-sleep latency. Every sleep is serviced by Threaded.
- The measurement clock is Born's monotonic clock (`born.nowNs`,
  CLOCK_MONOTONIC / QPC), independent of the interface under test.
- `bench/time.sh BIN [REPS]` runs the quiet-host guard first (quiet.sh on
  FreeBSD, a loadavg check on Linux) and refuses a busy host; it then runs
  the baseline per repetition. Report the spread over repetitions.
- `--instances N` spreads the sleepers round-robin over N port/instance
  pairs, the thread-per-core deployment shape; ops/s and p99 aggregate over
  all sleepers. The default is one instance.

### Why the Born time route was retired (#101)

The shim once routed `sleep` and monotonic `now` through Born's timers
(`capabilities.time = .born_evented`) against a written target: at 64
sleepers, >= 95% of Threaded's completed sleeps per second with p99 no
worse. Measurement across increments 1-3 showed the target is not reachable
for a blocking sleep, and the route was retired: `sleep`, `now` and
`clockResolution` now always delegate to Threaded. A blocking sleep routed
through the loop costs two cross-thread hops (submitter to loop, loop back
to submitter) and buys nothing over Threaded's in-thread sleep, which is
the best case for this workload. Performance targets move to the native API
(`bench/suite.sh`, `bench/regress.sh`). The shared loop machinery (submission
queues, generation-tagged identity, deferred/batched completion wakes,
connect-deadline timers, failure latch) stays, owned by the network and
process routes.

Measured findings (ReleaseSafe, quiet-host guarded; raw logs in the #101
measurement record):

- FreeBSD 15.1-RELEASE-p2 amd64 (kqueue, development workstation,
  `kern.hz=100`): the single-sleeper kernel slack floor (armed span minus
  request) is roughly flat at ~90-154 us across 1-100 ms, and ~62-90 us
  under the 64-sleeper load. The gap is fixed per-sleep overhead, about
  232 us over a 1 ms request (submit wake ~18 us, queue arm ~35 us, kernel
  slack ~115 us, futex return ~64 us), not a scaling problem. At 64
  sleepers / 1 ms the best ops ratio was ~0.815-0.862 (target unmet); at
  10 ms the fixed overhead amortizes to ops parity (0.985) but p99 stays
  worse. Early re-arms were 0 at every point.
- NetBSD 10.1 GENERIC amd64 (kqueue, 2-vCPU bhyve guest, manual VM host):
  a structural tick floor of `ceil(R/10ms) + 1` ticks (a 1 ms request fires
  at 20 ms, 100 ms at 110 ms). The kernel rounds up and adds one tick, so
  fires are always late relative to the request, never early; early re-arms
  were 0 across the sweep (the early-rearm churn is latent here, not
  active). At 64 sleepers, Born p99 was worse than Threaded in every clean
  repetition.
- A NetBSD clock-read refusal anomaly under guest scheduling pressure
  (load >= ~3.5 on the 2-vCPU VM) is tracked separately as #141; it affects
  core timers and connect deadlines beyond the shim time route.
