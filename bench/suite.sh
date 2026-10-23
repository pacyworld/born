#!/bin/sh
# Run the standard scenarios (bench/README.md) and keep each raw output.
#
#   bench/suite.sh BIN OUTDIR [REPS]
set -eu

bin=$1
outdir=$2
reps=${3:-5}
here=$(dirname "$0")
mkdir -p "$outdir"

sh "$here/run.sh" "$bin" echo "$reps" --threads 1 >"$outdir/echo1.txt" 2>&1
sh "$here/run.sh" "$bin" echo "$reps" --threads 16 >"$outdir/echo16.txt" 2>&1
sh "$here/run.sh" "$bin" storm "$reps" --threads 16 >"$outdir/storm16.txt" 2>&1
REPLY=4194304 sh "$here/run.sh" "$bin" bulk "$reps" --threads 4 >"$outdir/bulk4.txt" 2>&1
sh "$here/run.sh" "$bin" wake "$reps" >"$outdir/wake.txt" 2>&1
