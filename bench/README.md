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

## Time-route benchmark (P5.2)

`zig build bench-time` (Zig >= 0.16) installs `zig-out/bin/born-time-bench`.
The step is not part of `test`, `test-bin` or `check-targets`. It measures the
born.io time route (`capabilities.time = .born_evented`) against the
all-Threaded baseline:

```
zig build bench-time -Doptimize=ReleaseSafe
sh bench/time.sh zig-out/bin/born-time-bench 3
```

- Sequential phase: `--seq` sleeps (default 200) of `--sleep-ms` (default 1)
  on the calling thread; reports p50/p99/max/mean per-sleep latency.
- Concurrent phase: `--threads` blocking threads (default 64), one sleep in
  flight per thread for `--seconds` (default 5); reports completed sleeps per
  second and p50/p99 per-sleep latency. On the Born route every sleep is a
  cross-thread submission through the shim's loop thread.
- The measurement clock is Born's monotonic clock (`born.nowNs`,
  CLOCK_MONOTONIC / QPC) on both routes, independent of the route under test.
- `bench/time.sh BIN [REPS]` runs the quiet-host guard first (quiet.sh on
  FreeBSD, a loadavg check on Linux) and refuses a busy host; it then runs
  both routes per repetition. Report the spread over repetitions.

### Written target (P5.2)

On the 64-sleeper concurrent phase (the defaults: `--threads 64
--sleep-ms 1 --seconds 5`), the Born route must reach at least 95% of
Threaded's completed sleeps per second, and its p99 per-sleep latency must
be no worse than Threaded's. `--route both` prints the verdict line
(`target ... MET|UNMET`) and, for the Born route, a per-sleep latency
breakdown from `born_io.timeStats` (means over the concurrent phase):

- `submit_wake_us`: submitter side, enqueue plus the conditional wake.
- `queue_arm_us`: enqueue to first arm; includes `submit_wake_us`.
  `loop_handoff_us` is their difference (queue wait, drain, arm).
- `timer_span_us`: armed time including the requested sleep;
  `kernel_slack_us` is the span minus the request (negative when the
  handoff consumed part of the requested sleep).
- `futex_return_us`: completion handoff back to the submitter.

`--instances N` spreads the sleepers round-robin over N port/instance
pairs, the scale model's thread-per-core deployment shape (one loop per
instance); ops/s and p99 aggregate over all sleepers, the breakdown sums
the per-instance accumulators. The default is one instance.

If the target is unmet at an increment, the pull request reports the
numbers and the breakdown and names the increment that meets it; no
open-ended deferral.
