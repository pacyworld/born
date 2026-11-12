#!/bin/sh
# Quiet-host guard for accepting benchmark results (#31). The dev host is
# shared and carries foreign load; latency and throughput are only meaningful
# when the load is moderate and the loopback netisr is not dropping packets.
# Exits 0 when the host is quiet enough to accept results, 1 otherwise.
#
#   bench/quiet.sh [MAX_LOAD_RATIO]
#
# Criteria: 1-min loadavg <= MAX_LOAD_RATIO * ncpu (default 0.5), the ip netisr
# queue Len is 0, and its QDrops counter does not advance over a 3 s sample.
# The degraded state that invalidated #31 (d)/(e) was load 30-35 with hundreds
# of thousands of queue drops; this guard rejects that and accepts a moderately
# loaded host like the one the baseline was measured on.
set -eu

ratio=${1:-0.5}
ncpu=$(sysctl -n hw.ncpu)
load1=$(sysctl -n vm.loadavg | awk '{print $2}')
maxload=$(awk -v r="$ratio" -v n="$ncpu" 'BEGIN { printf "%.2f", r * n }')

iprow() { netstat -Q | awk '$3 == "ip" && NF >= 10 { print $4, $8 }'; }
set -- $(iprow)
len=$1
drops=$2
sleep 3
set -- $(iprow)
len2=$1
drops2=$2
delta=$((drops2 - drops))

echo "quiet: load1=$load1 max=$maxload (ncpu=$ncpu ratio=$ratio) ip_len=$len ip_qdrops_delta=$delta"
ok=1
awk -v l="$load1" -v m="$maxload" 'BEGIN { exit !(l <= m) }' || ok=0
[ "$len" -eq 0 ] || ok=0
[ "$len2" -eq 0 ] || ok=0
[ "$delta" -eq 0 ] || ok=0
if [ "$ok" -eq 1 ]; then
    echo "quiet: host is quiet enough to accept results"
else
    echo "quiet: host NOT quiet; do not accept results"
    exit 1
fi