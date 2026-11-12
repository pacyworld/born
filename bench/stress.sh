#!/bin/sh
# Stress gate: the #45 repro shape. Run the born test suite RUNS times with
# HOGS CPU busy-loops beside it to induce scheduler load, and tally failures.
# A single failure is a release blocker (exit nonzero). The workload is
# bounded: HOGS loops, one suite process at a time, all cleaned up on exit.
#
#   bench/stress.sh BIN RUNS [HOGS]
#
# BIN is a built test executable (zig build test-bin). RUNS defaults to 500.
# HOGS defaults to ncpu + ncpu/2 (about 1.5x the core count): #45's original
# repro used load 30-35 on a 20-core host. Pass HOGS to override. The start,
# each 50-run progress line, and the end record vm.loadavg so the run shows
# the load it actually applied.
set -eu

bin=$1
runs=${2:-500}
hogs=${3:-}

ncpu() {
    nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}
loadavg() {
    if [ -r /proc/loadavg ]; then
        cut -d' ' -f1-3 /proc/loadavg
    else
        sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'
    fi
}
if [ -z "$hogs" ]; then
    n=$(ncpu)
    hogs=$((n + n / 2))
fi

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

echo "stress: starting runs=$runs hogs=$hogs loadavg=[$(loadavg)] bin=$bin"
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
        echo "stress: progress $run/$runs runs, $fail failed, loadavg=[$(loadavg)]"
    fi
    run=$((run + 1))
done
echo "stress evidence (${STRESS_LABEL:-$(uname -srm)}): runs=$runs hogs=$hogs failed=$fail loadavg=[$(loadavg)]"
[ "$fail" -eq 0 ]
