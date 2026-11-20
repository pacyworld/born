#!/bin/sh
# HTTP consumer benchmark driver (P5.5, design section 9): the born network
# route vs the all-Threaded baseline, under the #31 quiet-host guard. See
# born's bench/README.md for the acceptance discipline; results are a
# per-release recording step (bench/RESULTS.md), not a per-push gate.
#
#   consumers/bench/http.sh BIN [REPS] [extra born-http-bench args...]
#
# Each repetition runs both routes in one process. Results are acceptable
# only when the quiet guard passes; a busy host fails the guard instead of
# yielding an accepted measurement.
set -eu

bin=$1
reps=${2:-3}
shift 2 2>/dev/null || shift $#
here=$(dirname "$0")

case $(uname) in
FreeBSD)
    sh "$here/../../bench/quiet.sh"
    ;;
Linux)
    ncpu=$(nproc)
    load1=$(awk '{print $1}' /proc/loadavg)
    maxload=$(awk -v n="$ncpu" 'BEGIN { printf "%.2f", 0.5 * n }')
    echo "quiet: load1=$load1 max=$maxload (ncpu=$ncpu ratio=0.5)"
    awk -v l="$load1" -v m="$maxload" 'BEGIN { exit !(l <= m) }' || {
        echo "quiet: host NOT quiet; do not accept results"
        exit 1
    }
    ;;
*)
    echo "quiet: no guard for $(uname); do not accept results" >&2
    exit 1
    ;;
esac

rep=1
while [ "$rep" -le "$reps" ]; do
    echo "== rep $rep"
    "$bin" --route both "$@"
    rep=$((rep + 1))
done