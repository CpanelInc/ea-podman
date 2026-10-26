#!/bin/bash
# CPU and memory load tests for the 3 containers ./setup.sh creates. Run as root.
#
# Load is NOT generated with `podman exec`: an exec'd process stays in its caller's
# cgroup (it can't be moved into the container's, because the common ancestor
# eapodman-<uid>.slice is root-owned), so it would escape the container's limits.
# Instead root moves each load process into the container's libpod-payload-* cgroup
# and then drops to the account's uid with setpriv. Only the cgroup matters for the
# limits, so the load runs from host binaries, outside the container's namespaces.
#
# Every temporary cgroup change is a direct write that is put back on exit, and the
# three units are restarted at the end, which also kills any load left in them.
# Usage: ./loadtest.sh <cpuser> [cpu|mem|all]
set -uo pipefail
U=${1:?usage: $0 <cpuser> [cpu|mem|all]}
WHAT=${2:-all}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
UID_=$(id -u "$U"); GID_=$(id -g "$U"); HOME_=$(getent passwd "$U" | cut -d: -f6)
A=/sys/fs/cgroup/eapodman.slice/eapodman-$UID_.slice
NAMES=("web.$U.01" "api.$U.02" "worker.$U.03")
SCRATCH=$HOME_/.eapodman-loadtest
[ -d "$A" ] || { echo "not set up; run ./setup.sh $U first" >&2; exit 1; }
for n in "${NAMES[@]}"; do
    systemctl is-active -q "ea-podman-$n.service" || { echo "ea-podman-$n.service is not running" >&2; exit 1; }
done

svc()     { echo "$A/ea-podman-$1.service"; }
payload() { local d; for d in "$(svc "$1")"/libpod-payload-*; do echo "$d"; return; done; }
stat_of() { awk -v k="$2" '$1 == k { print $2 }' "$1"; }
mib()     { echo $(( $1 / 1048576 )); }

# Run a command as the account inside container $1's payload cgroup. Foreground;
# returns the command's exit status (137 when the OOM killer takes it).
ENTER='echo $$ >"$1/cgroup.procs" && shift && exec setpriv --reuid="$UID_" --regid="$GID_" --clear-groups "$@"'
in_container() {
    local p; p=$(payload "$1"); shift
    sh -c "$ENTER" _ "$p" "$@" </dev/null
}
# Same, in the background. sh execs into the command, so the PID in BG is the load itself.
BG=()
in_container_bg() {
    local p; p=$(payload "$1"); shift
    sh -c "$ENTER" _ "$p" "$@" </dev/null >/dev/null 2>&1 &
    BG+=($!)
}
stop_bg() { [ ${#BG[@]} -gt 0 ] && kill "${BG[@]}" 2>/dev/null; wait 2>/dev/null; BG=(); }
export UID_ GID_

# Originals, put back on exit.
ORIG_SLICE_CPU=$(cat "$A/cpu.max"); ORIG_SLICE_MEM=$(cat "$A/memory.max")
declare -A ORIG_W ORIG_L
for n in "${NAMES[@]}"; do ORIG_W[$n]=$(cat "$(svc "$n")/cpu.weight"); ORIG_L[$n]=$(cat "$(svc "$n")/memory.low"); done
cleanup() {
    echo; echo "== cleanup"
    stop_bg
    echo "$ORIG_SLICE_CPU" >"$A/cpu.max"
    echo "$ORIG_SLICE_MEM" >"$A/memory.max"
    for n in "${NAMES[@]}"; do
        echo "${ORIG_W[$n]}" >"$(svc "$n")/cpu.weight"
        echo "${ORIG_L[$n]}" >"$(svc "$n")/memory.low"
    done
    rm -rf "$SCRATCH"
    for n in "${NAMES[@]}"; do systemctl restart "ea-podman-$n.service"; done
    echo "restored slice cpu.max/memory.max and unit cpu.weight/memory.low; removed $SCRATCH; units restarted"
}
trap cleanup EXIT

# ---------------------------------------------------------------- CPU
cpu_usage() { stat_of "$(payload "$1")/cpu.stat" usage_usec; }
cpu_measure() {    # label, then expected CPUs per container
    local label=$1; shift
    local -A t0; local n
    sleep 3
    for n in "${NAMES[@]}"; do t0[$n]=$(cpu_usage "$n"); done
    local s0; s0=$(date +%s%N); sleep 15
    local s1; s1=$(date +%s%N)
    printf '\n%s\n' "$label"
    printf '  %-20s %8s %10s\n' container CPUs expected
    for n in "${NAMES[@]}"; do
        awk -v u="$(( $(cpu_usage "$n") - ${t0[$n]} ))" -v w="$(( (s1 - s0) / 1000 ))" -v n="$n" -v e="$1" \
            'BEGIN { printf "  %-20s %8.2f %10s\n", n, u / w, e }'
        shift
    done
}
cpu_test() {
    echo "== CPU: busy loops in each container's cgroup (web 2, api 3, worker 2; each more than its --cpus)"
    local n k
    declare -A loops=( ["web.$U.01"]=2 ["api.$U.02"]=3 ["worker.$U.03"]=2 )
    for n in "${NAMES[@]}"; do
        for ((k = 0; k < ${loops[$n]}; k++)); do in_container_bg "$n" sh -c 'exec yes >/dev/null'; done
    done
    cpu_measure "A. caps only (cpu.max from --cpus; 4 host CPUs, caps total 3.5)" 1.00 2.00 0.50

    echo "100000 100000" >"$A/cpu.max"
    cpu_measure "B. account slice squeezed to 1 CPU: unit CPUWeight 100/200/50 decides" 0.29 0.57 0.14

    for n in "${NAMES[@]}"; do echo 100 >"$(svc "$n")/cpu.weight"; done
    cpu_measure "C. same, all unit weights 100; container cpu.weight (from --cpu-shares) still $(for n in "${NAMES[@]}"; do printf '%s/' "$(cat "$(payload "$n")/cpu.weight")"; done | sed 's,/$,,')" 0.33 0.33 0.33

    stop_bg
    echo "$ORIG_SLICE_CPU" >"$A/cpu.max"
    for n in "${NAMES[@]}"; do echo "${ORIG_W[$n]}" >"$(svc "$n")/cpu.weight"; done
}

# ---------------------------------------------------------------- memory
mem_cap_test() {
    local n="web.$U.01" p rc before after
    p=$(payload "$n")
    echo; echo "== memory: hard cap on $n (memory.max $(mib "$(cat "$p/memory.max")")M, swap.max $(cat "$p/memory.swap.max"))"
    before=$(stat_of "$p/memory.events" oom_kill)
    in_container "$n" dd if=/dev/zero of=/dev/null bs=400M count=1 2>/dev/null; rc=$?
    printf '  400M allocation: exit %s (expected 0)\n' "$rc"
    in_container "$n" dd if=/dev/zero of=/dev/null bs=600M count=1 2>/dev/null; rc=$?
    after=$(stat_of "$p/memory.events" oom_kill)
    printf '  600M allocation: exit %s (expected 137), oom_kill %s -> %s, swap.current %s\n' "$rc" "$before" "$after" "$(cat "$p/memory.swap.current")"
}
file_mib() { mib "$(stat_of "$(payload "$1")/memory.stat" file)"; }
mem_floor_round() {    # label
    local label=$1 w="web.$U.01" k="worker.$U.03" a="api.$U.02" cur target
    # Re-warm both caches; the pages stay charged to the container that first read them.
    in_container "$w" cat "$SCRATCH/web.bin" >/dev/null
    in_container "$k" cat "$SCRATCH/worker.bin" >/dev/null
    sleep 2
    cur=$(cat "$A/memory.current")
    target=$(( cur - 250 * 1048576 ))
    printf '\n%s\n  before: slice %sM; page cache web %sM (unit low %sM), worker %sM (unit low %sM); api anon %sM\n' "$label" \
        "$(mib "$cur")" "$(file_mib "$w")" "$(mib "$(cat "$(svc "$w")/memory.low")")" \
        "$(file_mib "$k")" "$(mib "$(cat "$(svc "$k")/memory.low")")" \
        "$(mib "$(stat_of "$(payload "$a")/memory.stat" anon)")"
    echo "$target" >"$A/memory.max"
    sleep 3
    printf '  slice memory.max -> %sM (250M below usage)\n' "$(mib "$target")"
    printf '  after:  slice %sM; page cache web %sM, worker %sM; api anon %sM; swap.current web/worker/api %s/%s/%s; slice oom_kill %s\n' \
        "$(mib "$(cat "$A/memory.current")")" "$(file_mib "$w")" "$(file_mib "$k")" \
        "$(mib "$(stat_of "$(payload "$a")/memory.stat" anon)")" \
        "$(cat "$(payload "$w")/memory.swap.current")" "$(cat "$(payload "$k")/memory.swap.current")" \
        "$(cat "$(payload "$a")/memory.swap.current")" "$(stat_of "$A/memory.events" oom_kill)"
    echo "$ORIG_SLICE_MEM" >"$A/memory.max"
}
mem_floor_test() {
    local w="web.$U.01" k="worker.$U.03" a="api.$U.02" i
    echo; echo "== memory: floors under slice pressure (web 400M + worker 200M page cache, api 400M anon)"
    install -d -o "$UID_" -g "$GID_" -m 0700 "$SCRATCH"
    in_container "$w" dd if=/dev/zero of="$SCRATCH/web.bin" bs=1M count=400 conv=fsync 2>/dev/null
    in_container "$k" dd if=/dev/zero of="$SCRATCH/worker.bin" bs=1M count=200 conv=fsync 2>/dev/null
    in_container_bg "$a" python3 -c 'import time; x = b"a" * (400 << 20); time.sleep(600)'
    for i in $(seq 60); do
        [ "$(stat_of "$(payload "$a")/memory.stat" anon)" -gt $(( 380 * 1048576 )) ] && break
        sleep 1
    done
    mem_floor_round "1. unit MemoryLow set (web 256M, worker 64M): reclaim should come from above the floors"
    echo 0 >"$(svc "$w")/memory.low"; echo 0 >"$(svc "$k")/memory.low"
    mem_floor_round "2. control, unit MemoryLow 0 (container memory.low unchanged): reclaim spread across both caches"
    echo "${ORIG_L[$w]}" >"$(svc "$w")/memory.low"; echo "${ORIG_L[$k]}" >"$(svc "$k")/memory.low"
    stop_bg
}

case $WHAT in
    cpu) cpu_test ;;
    mem) mem_cap_test; mem_floor_test ;;
    all) cpu_test; mem_cap_test; mem_floor_test ;;
    *) echo "unknown test: $WHAT" >&2; exit 1 ;;
esac
