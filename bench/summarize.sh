#!/bin/sh
# Summarize the raw outputs of bench/suite.sh: one line per scenario with the
# median and min-max of each metric over the plain passes, and the syscalls
# per request of the counted passes.
#
#   bench/summarize.sh OUTDIR
set -eu

for f in "$1"/*.txt; do
    awk -v name="$(basename "$f" .txt)" '
    function med(a, n,   i, j, t) {
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
        return a[int((n + 1) / 2)]
    }
    function kv(line, key,   m) {
        if (match(line, key "=[0-9.]+")) return substr(line, RSTART + length(key) + 1, RLENGTH - length(key) - 1) + 0
        return -1
    }
    /^== rep .* plain/ { plain = 1; next }
    /^== rep .* syscalls/ { plain = 0; next }
    /^(client|wake) mode=/ && plain { n++; rps[n] = kv($0, "rps"); p50[n] = kv($0, "p50_us"); p99[n] = kv($0, "p99_us"); p999[n] = kv($0, "p999_us") }
    /^server waits=/ && plain { w++; wpr[w] = kv($0, "waits") / (kv(last, "requests")) }
    /^(client|wake) mode=/ { last = $0 }
    /^syscalls=/ { s++; spr[s] = kv($0, "per_request") }
    END {
        printf "%-8s reps=%d  rps %s  p50_us %s  p99_us %s  p999_us %s  syscalls/req %s\n", name, n,
            rng(rps, n), rng(p50, n), rng(p99, n), rng(p999, n), rng(spr, s)
    }
    function rng(a, n,   i, lo, hi, m, b) {
        if (n == 0) return "-"
        lo = a[1]; hi = a[1]
        for (i = 1; i <= n; i++) { b[i] = a[i]; if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i] }
        m = med(b, n)
        return sprintf("%.4g (%.4g-%.4g)", m, lo, hi)
    }' "$f"
done
