#!/bin/sh
# Threaded sleep baseline benchmark driver: the all-Threaded sleep family
# under the #31 quiet-host guard. The Born time route was retired (#101);
# this records the baseline it was compared against. See bench/README.md.
#
#   bench/time.sh BIN [REPS] [extra born-time-bench args...]
#
# Each repetition runs the baseline in one process. Results are acceptable
# only when the quiet guard passes; a busy host fails the guard instead of
# yielding an accepted measurement.
set -eu

bin=$1
reps=${2:-3}
shift 2 2>/dev/null || shift $#
here=$(dirname "$0")

case $(uname) in
FreeBSD)
    sh "$here/quiet.sh"
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
    "$bin" "$@"
    rep=$((rep + 1))
done