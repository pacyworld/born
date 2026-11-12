#!/bin/sh
# Stress gate: the #45 repro shape. Run the born test suite RUNS times with
# HOGS CPU busy-loops beside it to induce scheduler load, and tally failures.
# A single failure is a release blocker (exit nonzero). The workload is
# bounded: HOGS loops, one suite process at a time, all cleaned up on exit.
#
#   bench/stress.sh BIN RUNS [HOGS]
#
# BIN is a built test executable (zig build test-bin). RUNS defaults to 500,
# HOGS to 4. #45's original repro used load 30-35 on a 20-core host; raise
# HOGS through the workflow dispatch input to approach that pressure.
set -eu

bin=$1
runs=${2:-500}
hogs=${3:-4}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/born-stress.XXXXXX")
pids=""
i=0
while [ "$i" -lt "$hogs" ]; do
    sh -c 'while :; do :; done' &
    pids="$pids $!"
    i=$((i + 1))
done
cleanup() {
    for p in $pids; do kill "$p" 2>/dev/null || true; done
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

echo "stress: starting runs=$runs hogs=$hogs bin=$bin"
fail=0
run=1
while [ "$run" -le "$runs" ]; do
    if "$bin" >"$tmp/run.log" 2>&1; then
        :
    else
        rc=$?
        fail=$((fail + 1))
        echo "stress: FAIL run $run (rc=$rc)"
        tail -25 "$tmp/run.log"
    fi
    if [ $((run % 50)) -eq 0 ]; then
        echo "stress: progress $run/$runs runs, $fail failed"
    fi
    run=$((run + 1))
done
echo "stress: runs=$runs hogs=$hogs failed=$fail"
[ "$fail" -eq 0 ]