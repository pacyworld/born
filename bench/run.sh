#!/bin/sh
# born kqueue hot-path benchmark driver (FreeBSD). See bench/README.md.
#
#   bench/run.sh BIN MODE REPS [client args...]
#
# MODE is echo, storm or bulk (server and client over loopback), or wake (the
# in-process wake round trip). Each repetition runs two passes:
#   plain    server and client under cpuset: latency and throughput;
#   syscalls the same load with the server's syscalls counted by DTrace
#            (SYSCALLS=truss uses `truss -c` instead, which perturbs batching).
# Environment: SRV_CPUS (default 2), CLI_CPUS (default 4-11), SECS (default 5),
# SERVER_ARGS (extra server arguments, e.g. --accept-filter), SYSCALLS.
set -eu

bin=$1
mode=$2
reps=$3
shift 3
client_args=$*

srv_cpus=${SRV_CPUS:-2}
cli_cpus=${CLI_CPUS:-4-11}
secs=${SECS:-5}
server_args=${SERVER_ARGS:-}
syscalls=${SYSCALLS:-dtrace}
# bulk: 16-byte requests answered with 256 KiB by the server (the client's default).
if [ "$mode" = bulk ]; then
    server_args="$server_args --reply ${REPLY:-262144}"
    client_args="$client_args --reply ${REPLY:-262144}"
fi
tmp=$(mktemp -d /tmp/born-bench.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

dtrace_script='syscall:::entry /pid == $target/ { @[probefunc] = count(); }'

# Run "$@" counting its syscalls into $tmp/counts as "name count" lines.
counted() {
    case $syscalls in
    dtrace)
        rm -f "$tmp/dtrace.txt"
        doas dtrace -q -o "$tmp/dtrace.txt" -n "$dtrace_script" -c "$*"
        awk 'NF == 2 { print $1, $2 }' "$tmp/dtrace.txt" | sort -k2,2nr >"$tmp/counts"
        ;;
    truss)
        truss -f -c -o "$tmp/truss.txt" "$@"
        awk '/^ *-+ +-+ +-+$/ { stop = 1 } !stop && NR > 1 { print $1, $3 }' "$tmp/truss.txt" | sort -k2,2nr >"$tmp/counts"
        ;;
    esac
}

# Print the syscall table and the total divided by the request count.
report_counts() {
    # Per-request table: every syscall called at least once per 100 requests.
    awk -v reqs="$1" '{ total += $2 } $2 * 100 >= reqs { printf "  %-14s %9d %8.3f/req\n", $1, $2, $2 / reqs } END { printf "syscalls=%d per_request=%.3f\n", total, total / reqs }' "$tmp/counts"
}

requests_of() {
    sed -n 's/.*requests=\([0-9]*\).*/\1/p' "$1"
}

if [ "$mode" = wake ]; then
    rep=1
    while [ "$rep" -le "$reps" ]; do
        echo "== rep $rep plain"
        cpuset -l "$srv_cpus,$cli_cpus" "$bin" wake --seconds "$secs"
        echo "== rep $rep syscalls"
        counted cpuset -l "$srv_cpus,$cli_cpus" "$bin" wake --seconds "$secs" >"$tmp/wake.out"
        cat "$tmp/wake.out"
        report_counts "$(requests_of "$tmp/wake.out")"
        rep=$((rep + 1))
    done
    exit 0
fi

# One pass: $1 = label, $2 = plain or counted.
pass() {
    label=$1
    fifo=$tmp/ready.$label
    mkfifo "$fifo"
    if [ "$2" = plain ]; then
        # shellcheck disable=SC2086
        cpuset -l "$srv_cpus" "$bin" serve --seconds $((secs + 1)) $server_args >"$fifo" 2>"$tmp/server.$label" &
    else
        # shellcheck disable=SC2086
        counted cpuset -l "$srv_cpus" "$bin" serve --seconds $((secs + 1)) $server_args >"$fifo" 2>"$tmp/server.$label" &
    fi
    srv=$!
    # Blocks until the server has bound and printed its port.
    read -r line <"$fifo"
    port=${line#port=}
    # shellcheck disable=SC2086
    cpuset -l "$cli_cpus" "$bin" client --port "$port" --mode "$mode" --seconds "$secs" $client_args >"$tmp/client.$label" 2>&1 || true
    wait "$srv"
    rm -f "$fifo"
    cat "$tmp/client.$label" "$tmp/server.$label"
}

rep=1
while [ "$rep" -le "$reps" ]; do
    echo "== rep $rep plain"
    pass plain plain
    echo "== rep $rep syscalls"
    pass counted counted
    report_counts "$(requests_of "$tmp/client.counted")"
    rep=$((rep + 1))
done
