#!/bin/sh
# Interleaved A/B comparison of two born-bench binaries over the standard
# scenarios, so drift on the shared host hits both alike.
#
#   bench/ab.sh BIN_A BIN_B OUTDIR [REPS]
#
# Environment: SCENARIOS (default "echo1 echo16 storm16 bulk4 wake") plus the
# variables of bench/run.sh. Raw output lands in OUTDIR/a and OUTDIR/b, one file
# per scenario; summarize each with bench/summarize.sh.
set -eu

bin_a=$1
bin_b=$2
outdir=$3
reps=${4:-5}
scenarios=${SCENARIOS:-"echo1 echo16 storm16 bulk4 wake"}
here=$(dirname "$0")
mkdir -p "$outdir/a" "$outdir/b"

run() { # scenario binary
    case $1 in
    echo1) sh "$here/run.sh" "$2" echo 1 --threads 1 ;;
    echo16) sh "$here/run.sh" "$2" echo 1 --threads 16 ;;
    storm16) sh "$here/run.sh" "$2" storm 1 --threads 16 ;;
    bulk4) REPLY=4194304 sh "$here/run.sh" "$2" bulk 1 --threads 4 ;;
    wake) sh "$here/run.sh" "$2" wake 1 ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
    esac
}

rep=1
while [ "$rep" -le "$reps" ]; do
    for sc in $scenarios; do
        run "$sc" "$bin_a" >>"$outdir/a/$sc.txt" 2>&1
        run "$sc" "$bin_b" >>"$outdir/b/$sc.txt" 2>&1
    done
    rep=$((rep + 1))
done
