#!/bin/bash
# P0-4: Delegate=yes + cgroupfs on v1/v2, beyond what the kit's loadtest.sh measures.
#  1. where conmon, the container and the pause process land;
#  2. stopping one unit doesn't hurt the account's other containers;
#  3. controllers in cgroup.subtree_control down the chain, and received by the container;
#  4. swap accounting; --memory-swap = --memory -> memory.swap.max;
#  5. cpu.weight the OCI runtime writes for --cpu-shares 1024/2048/512;
#  6. --memory enforced (a memory.max on the container) with split and not without;
#  7. F17: is the cgroups mode fixed at create? Does a split container start on v1?
#  8. memory floors against pressure from outside: eapodman-<uid>.slice (with eapodman.slice
#     carrying the sum) vs a user-<uid>.slice floor (user.slice has none) vs no floor;
#  9. CPU contention: do all container accounts together get one user.slice-sized share
#     against system.slice?
# Usage: p0-4.sh [all|basic|floor|cpu]
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
WHAT=${1:-all}
A=eapodman.slice/eapodman-$UID_.slice
NAMES=(web.$U.01 api.$U.02 worker.$U.03)
for n in "${NAMES[@]}"; do systemctl is-active -q "ea-podman-$n.service" || { echo "ea-podman-$n.service not active" >&2; exit 1; }; done
v1path() { grep -E ":$2:" "/proc/$1/cgroup" 2>/dev/null | cut -d: -f3; }   # pid, controller list (v1)
cleanup() {
    for c in p04split.$U.80 p04nosplit.$U.81 p04v1split.$U.82; do probe_unit_rm "$c" >/dev/null 2>&1; done
    rm -f "$ETC/containers-nosplit.conf" "$ETC/containers-split.conf"
    systemctl stop 'p04-*' 2>/dev/null; systemctl reset-failed 'p04-*' 2>/dev/null
    [ -n "${P4:-}" ] && rm -rf "$P4"
    # Last: only the properties floor() changed, back to their saved values (lib.sh's change_prop),
    # each read back; one that can't be put back makes the probe exit 1.
    restore_changes_or_fail
}
# pause.pid is account-writable: read it as the account, and use it only if it is the account's
# process in the account's slice. A pause process outside the slice is then INCONCLUSIVE, not a cgroup.
pause_pid() {
    local p; p=$(acct_pid "$RUNDIR/libpod/tmp/pause.pid") \
        && safe_target "$p" --uid "$UID_" --cgroup "/eapodman-$UID_.slice/" && echo "$p"
}
trap cleanup EXIT

basic() {
hdr "1. placement"
for n in web.$U.01; do
    u=ea-podman-$n.service
    m=$(systemctl show -p MainPID --value "$u")
    c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' "$n" 2>/dev/null | tail -1)
    # MainPID comes from systemd, so it needs --comm (a stopped unit's is 0).
    safe_target "$m" --comm conmon || m=
    if [ -n "$m" ]; then result conmon_cgroup "$(cgroup_of "$m")"
    else inconclusive conmon_cgroup "$u's MainPID is not a conmon process"; fi
    result container_cgroup "$(cgroup_of "$c")"
    if p=$(pause_pid); then result pause_cgroup "$(cgroup_of "$p")"
    else inconclusive pause_cgroup "pause.pid names no process of uid $UID_ in eapodman-$UID_.slice (gone, outside the slice, or not the pause process)"; fi
    if [ $CGV = 1 ]; then
        for ctl in memory pids cpu,cpuacct; do
            [ -n "$m" ] && result "v1_${ctl/,/_}_conmon" "$(v1path "$m" "$ctl")"
            result "v1_${ctl/,/_}_container" "$(v1path "$c" "$ctl")"
        done
    fi
done

hdr "2. stopping one unit"
systemctl stop "ea-podman-web.$U.01.service"; sleep 2
ok=yes
for n in api.$U.02 worker.$U.03; do systemctl is-active -q "ea-podman-$n.service" || ok="no ($n inactive)"; done
curl -fsS -o /dev/null http://127.0.0.1:8082/ && curl -fsS -o /dev/null http://127.0.0.1:8083/ || ok="no (a port stopped serving)"
pause_pid >/dev/null || ok="no (pause process gone or outside the slice)"
result stop_one_unit_others_unaffected "$ok"
systemctl start "ea-podman-web.$U.01.service"

if [ $CGV = 2 ]; then
    hdr "3. controllers"
    for d in eapodman.slice "$A" "$A/ea-podman-web.$U.01.service"; do
        result "subtree_control_${d##*/}" "$(cat "$CG/$d/cgroup.subtree_control")"
    done
    pl=$(ls -d "$CG/$A/ea-podman-web.$U.01.service"/libpod-payload-* 2>/dev/null | head -1)
    result container_controllers "$(cat "$pl/cgroup.controllers" 2>/dev/null)"

    hdr "4./5. swap accounting and the shares conversion"
    result swap_on_host "$(tail -n +2 /proc/swaps | grep -c .) swap devices"
    for n in "${NAMES[@]}"; do
        pl=$(ls -d "$CG/$A/ea-podman-$n.service"/libpod-payload-* 2>/dev/null | head -1)
        sw=$(cat "$pl/memory.swap.max" 2>/dev/null || echo missing)
        result "${n%%.*}_memory_swap_max" "$sw"
        result "${n%%.*}_cpu_weight" "$(cat "$pl/cpu.weight")"
    done
else
    hdr "4./5. v1: swap accounting and shares"
    result swap_on_host "$(tail -n +2 /proc/swaps | grep -c .) swap devices"
    c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' web.$U.01 2>/dev/null | tail -1)
    result web_cpu_shares_cgroup "$(cat "$CG/cpu,cpuacct$(v1path "$c" cpu,cpuacct)/cpu.shares" 2>/dev/null)"
    result web_memsw_file "$([ -e "$CG/memory$(v1path "$c" memory)/memory.memsw.limit_in_bytes" ] && echo present || echo missing)"
    result web_memory_limit "$(cat "$CG/memory$(v1path "$c" memory)/memory.limit_in_bytes" 2>/dev/null)"
fi

hdr "6./7. split vs no split, and is the mode fixed at create (F17)"
sed '/^cgroups = /d' "$ETC/containers.conf" >"$ETC/containers-nosplit.conf"
{ sed '/^cgroups = /d; s/^\[containers\]$/[containers]\ncgroups = "split"/' "$ETC/containers.conf"; } >"$ETC/containers-split.conf"
chmod 0644 "$ETC"/containers-*split.conf
# create under one conf, start under the other: name|create conf|start conf
for spec in "p04split.$U.80|split|nosplit" "p04nosplit.$U.81|nosplit|split"; do
    IFS='|' read -r c cc sc <<<"$spec"
    probe_create -c "$ETC/containers-$cc.conf" "$c" --memory=64m "$IMAGE" >/dev/null 2>&1 || result "${c%%.*}_create" FAILS
    rec=$(as_user -c "$ETC/containers-$cc.conf" /usr/bin/podman inspect --format '{{.HostConfig.Cgroups}}' "$c" 2>/dev/null | tail -1)
    if probe_unit_start -c "$ETC/containers-$sc.conf" "$c" 2>/dev/null; then
        cp=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' "$c" 2>/dev/null | tail -1)
        where=$(cgroup_of "$cp")
        if [ $CGV = 2 ]; then
            mm=$(cat "$CG$where/memory.max" 2>/dev/null)
            case $where in */libpod-payload-*) mode=split ;; *) mode=no-split ;; esac
            result "${c%%.*}_created_${cc}_started_${sc}" "recorded=$rec ran=$mode memory.max=$mm"
        else
            result "${c%%.*}_created_${cc}_started_${sc}" "recorded=$rec starts; in $where; memory.limit=$(cat "$CG/memory$(v1path "$cp" memory)/memory.limit_in_bytes")"
        fi
    else
        result "${c%%.*}_created_${cc}_started_${sc}" "recorded=$rec FAILS: $(journalctl -u "ea-podman-$c.service" -n 30 --no-pager -o cat | grep -m1 -i error)"
    fi
    probe_unit_rm "$c" >/dev/null 2>&1
done
}

floor() {
# FLOOR=low (default) protects with MemoryLow=; FLOOR=min with MemoryMin= (hard), set on both slices too.
local P=MemoryLow; [ "${FLOOR:-low}" = min ] && P=MemoryMin
hdr "8. memory floors ($P) under pressure from outside the slices"
# Runs whether or not a verdict was reached, so `all` goes on to cpu() with nothing left changed.
floor_end() {
    systemctl stop p04-hold-acct p04-hold-user p04-hold-none 2>/dev/null
    systemctl reset-failed 'p04-hold-*' 2>/dev/null
    restore_changes || exit 1
    rm -rf "$P4"; P4=
}
if [ $P = MemoryMin ]; then
    change_prop eapodman.slice MemoryMin 400M || exit 1
    change_prop "eapodman-$UID_.slice" MemoryMin 400M || exit 1
fi
if command -v cagefsctl >/dev/null; then info "CloudLinux: page cache isn't charged to the reader's cgroup (F13); measuring anyway"; fi
P4=$(mktemp -d /var/tmp/p04.XXXXXX) || exit 1; chmod 0755 "$P4"
# Each holder's file is read once (page cache charged to the reader's cgroup), then it sleeps.
for f in acct user none; do dd if=/dev/urandom of="$P4/$f" bs=1M count=300 status=none; done
chmod 0644 "$P4"/*
big=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 * 3 / 2 ))
dd if=/dev/zero of="$P4/big" bs=1M count=$big status=none
sync; echo 1 >/proc/sys/vm/drop_caches
change_prop "user-$UID_.slice" $P 400M || exit 1
# The three holders, or no verdict: a missing one would compare nothing with something.
hold() {    # name, slice, [extra systemd-run args]
    local h=$1 slice=$2; shift 2
    systemd-run --quiet --unit="p04-hold-$h" --slice="$slice" --uid="$UID_" "$@" \
        sh -c "cat $P4/$h >/dev/null; exec sleep 600"
}
hold acct "eapodman-$UID_.slice" -p $P=400M && hold user "user-$UID_.slice" -p $P=400M && hold none system.slice \
    || { inconclusive floor_verdict "a holder unit didn't start"; floor_end; return; }
sleep 8
file_of() {    # unit -> MiB of page cache charged to its cgroup; fails unless it read a number
    local cg v; cg=$(systemctl show -p ControlGroup --value "$1") && [ -n "$cg" ] || return 1
    if [ $CGV = 2 ]; then v=$(awk '$1=="file"{print int($2/1048576)}' "$CG$cg/memory.stat")
    else v=$(awk '$1=="total_cache"{print int($2/1048576)}' "$CG/memory$cg/memory.stat"); fi
    case $v in ''|*[!0-9]*) return 1;; esac
    echo "$v"
}
declare -A b a
for h in acct user none; do
    b[$h]=$(file_of p04-hold-$h) || { inconclusive floor_verdict "couldn't read p04-hold-$h's page cache before"; floor_end; return; }
done
info "floors ($P): eapodman.slice $(systemctl show -p $P --value eapodman.slice), eapodman-$UID_.slice $(systemctl show -p $P --value eapodman-$UID_.slice), user.slice $(systemctl show -p $P --value user.slice), user-$UID_.slice $(systemctl show -p $P --value user-$UID_.slice)"
# Pressure: stream a file 1.5x RAM, twice, from system.slice.
systemd-run --quiet --wait --unit=p04-pressure --slice=system.slice sh -c "cat $P4/big >/dev/null; cat $P4/big >/dev/null"
for h in acct user none; do
    systemctl is-active -q "p04-hold-$h" && a[$h]=$(file_of p04-hold-$h) \
        || { inconclusive floor_verdict "p04-hold-$h died or its page cache couldn't be read after the pressure"; floor_end; return; }
done
for h in acct user none; do result "pagecache_${h}_MiB" "${b[$h]} -> ${a[$h]}"; done
if [ "${b[acct]}" -lt 100 ]; then result floor_verdict "n/a: page cache not charged to the reader (before=${b[acct]})"
elif [ "${b[user]}" = 0 ] || [ "${b[none]}" = 0 ]; then
    inconclusive floor_verdict "a comparison holder had no page cache before (user=${b[user]} none=${b[none]})"
else
    keep() { echo $(( ${a[$1]} * 100 / ${b[$1]} )); }
    result floor_verdict "kept: account slice $(keep acct)%, user-<uid>.slice $(keep user)%, no floor $(keep none)%"
fi
floor_end
}

cpu() {
hdr "9. CPU: system.slice vs user.slice vs eapodman.slice (two accounts)"
n=$(nproc)
burn="i=0; while [ \$i -lt $n ]; do yes >/dev/null & i=\$((i+1)); done; wait"
B=$((UID_ + 1))
systemd-run --quiet --unit=p04-burn-sys --slice=system.slice sh -c "$burn"
systemd-run --quiet --unit=p04-burn-user --slice="user-$UID_.slice" sh -c "$burn"
systemd-run --quiet --unit=p04-burn-acctA --slice="eapodman-$UID_.slice" sh -c "$burn"
systemd-run --quiet --unit=p04-burn-acctB --slice="eapodman-$B.slice" sh -c "$burn"
sleep 3
usage() {    # slice path -> usec
    if [ $CGV = 2 ]; then awk '$1=="usage_usec"{print $2}' "$CG/$1/cpu.stat"
    else echo $(( $(cat "$CG/cpu,cpuacct/$1/cpuacct.usage") / 1000 )); fi
}
S=(system.slice user.slice eapodman.slice eapodman.slice/eapodman-$UID_.slice eapodman.slice/eapodman-$B.slice)
declare -A u0 u1
for s in "${S[@]}"; do u0[$s]=$(usage "$s"); done
sleep 20
for s in "${S[@]}"; do u1[$s]=$(usage "$s"); done
systemctl stop p04-burn-sys p04-burn-user p04-burn-acctA p04-burn-acctB
tot=$(( (${u1[system.slice]} - ${u0[system.slice]}) + (${u1[user.slice]} - ${u0[user.slice]}) + (${u1[eapodman.slice]} - ${u0[eapodman.slice]}) ))
for s in "${S[@]}"; do
    d=$(( ${u1[$s]} - ${u0[$s]} ))
    result "cpu_share_${s##*/}" "$(( d * 100 / tot ))% ($(awk -v d=$d 'BEGIN{printf "%.2f", d/20e6}') CPUs)"
done
info "weights: system $(systemctl show -p CPUWeight --value system.slice) user $(systemctl show -p CPUWeight --value user.slice) eapodman $(systemctl show -p CPUWeight --value eapodman.slice)"
}

case $WHAT in
    basic) basic ;; floor) floor ;; cpu) cpu ;;
    all) basic; floor; cpu ;;
esac
probe_exit
