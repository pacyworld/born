#!/bin/sh
# Benchmark regression gate (#31). Compare each scenario's median syscalls/req
# and p50/p99 latency against the explicit policy bounds in bench/thresholds.txt.
# Exits nonzero on any regression or missing metric.
#
#   bench/regress.sh SUMMARY THRESHOLDS
#
# SUMMARY is bench/summarize.sh output (one line per scenario, each metric as
# "median (min-max)"); THRESHOLDS is bench/thresholds.txt. Latency bounds are
# generous upper bounds, not targets. Accept results only from a quiet host
# (bench/quiet.sh); this gate judges the numbers, not the host.
set -eu

summary=$1
thresholds=$2

awk '
NR == FNR {
    if ($0 ~ /^#/ || NF == 0) next
    max[$1, $2] = $3 + 0
    next
}
{
    scenario = $1
    seen[scenario] = 1
    delete med
    for (i = 2; i <= NF; i++) {
        if ($i ~ /^(rps|p50_us|p99_us|p999_us|cpu_us\/req|syscalls\/req)$/)
            med[$i] = $(i + 1) + 0
    }
    for (key in max) {
        split(key, parts, SUBSEP)
        if (parts[1] != scenario) continue
        metric = parts[2]
        if (!(metric in med)) {
            printf "MISSING %s %s\n", scenario, metric
            missing++
            continue
        }
        v = med[metric]; m = max[key]
        if (v > m) {
            printf "REGRESS %s %s median=%.4g max=%.4g\n", scenario, metric, v, m
            fail++
        } else {
            printf "ok      %s %s median=%.4g max=%.4g\n", scenario, metric, v, m
        }
    }
}
END {
    for (key in max) {
        split(key, parts, SUBSEP)
        if (!seen[parts[1]]) {
            printf "MISSING scenario %s (%s)\n", parts[1], parts[2]
            missing++
        }
    }
    if (missing) { printf "regress: %d missing metrics\n", missing; exit 1 }
    if (fail) { printf "regress: %d regressions\n", fail; exit 1 }
    print "regress: all metrics within thresholds"
}
' "$thresholds" "$summary"