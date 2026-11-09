#!/bin/bash
# T0.6: data for the remaining open values (PLAN.md Open items).
#   t0-6.sh basic   host defaults (nproc, tasks, logind runtime dir), 1.x parity, runtime dir use,
#                   exit codes without journal readback, and the account slice's TasksMax under a
#                   fork storm
#   t0-6.sh units   daemon-reload time and PID 1 memory with N enabled ea-podman-shaped units
#   t0-6.sh swap    --memory-swap enforcement with a real (temporary) swap file
set -uo pipefail
cd "$(dirname "$0")"; PROBE=t0-6; . ./plib.sh
A=eapodman.slice/eapodman-$UID_.slice
WEB=ea-podman-web.$U.01.service
lim() { awk -v k="$2" '$0 ~ "^Max "k {print $(NF-2)"/"$(NF-1)}' "/proc/$1/limits"; }   # soft/hard
# nproc of a PID that passes lib.sh's safe_target checks; any other is "not-measured", never blank.
nproc_of() {    # pid, safe_target checks...
    local pid=$1; shift
    safe_target "$pid" "$@" 2>/dev/null && lim "$pid" processes || echo not-measured
}

basic() {
hdr "host"
result ram_mib "$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
result cpus "$(nproc)"
result pid_max "$(cat /proc/sys/kernel/pid_max)"
result threads_max "$(cat /proc/sys/kernel/threads-max)"
result default_limit_nproc "$(systemctl show -p DefaultLimitNPROC --value) (soft $(systemctl show -p DefaultLimitNPROCSoft --value))"
result default_tasks_max "$(systemctl show -p DefaultTasksMax --value)"
result pid1_nproc "$(lim 1 processes)"
result limits_d_nproc "$(grep -hsE '^[^#]*nproc' /etc/security/limits.conf /etc/security/limits.d/*.conf | tr -s ' \t' ' ' | tr '\n' ';')"
result user_slice_tasks_max "user.slice=$(systemctl show -p TasksMax --value user.slice) user-$UID_.slice=$(systemctl show -p TasksMax --value user-$UID_.slice)"
result user_slice_dropins "$(systemctl show -p DropInPaths --value user-$UID_.slice)"
result logind "$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -E '^[^#]*(RuntimeDirectory|UserTasksMax)' | tr '\n' ';')"
result io_schedulers "$(for d in /sys/block/*/queue/scheduler; do echo -n "${d#/sys/block/}=$(cat $d) "; done | sed 's|/queue/scheduler||g')"
result swap_devices "$(tail -n +2 /proc/swaps | wc -l)"
result swap_accounting "$( [ $CGV = 2 ] && { [ -e $CG/system.slice/memory.swap.max ] && echo 'memory.swap.max present' || echo MISSING; } || { [ -e $CG/memory/memory.memsw.limit_in_bytes ] && echo 'memory.memsw.* present' || echo MISSING; })"

hdr "TasksMax=33% on the account slice, as resolved"
tm=$(systemctl show -p TasksMax --value "eapodman-$UID_.slice")
pm=$( [ $CGV = 2 ] && cat "$CG/$A/pids.max" || cat "$CG/pids/$A/pids.max")
result account_slice_tasks_max "property=$tm pids.max=$pm (base for 33% = $(( tm * 100 / 33 )))"
result eapodman_slice_tasks_max "$(systemctl show -p TasksMax --value eapodman.slice)"

hdr "nproc as 2.0 runs it (kit: unit LimitNPROC=infinity, create through the runner)"
m=$(systemctl show -p MainPID --value $WEB)
c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' web.$U.01 2>/dev/null | tail -1)
p=$(acct_pid "$RUNDIR/libpod/tmp/pause.pid")
result nproc_2x "conmon=$(nproc_of "$m" --comm conmon --cgroup "/$WEB") container_init=$(nproc_of "$c" --uid "$UID_" --cgroup "/$WEB/") pause=$(nproc_of "$p" --uid "$UID_" --cgroup "/eapodman-$UID_.slice/") runner=$(as_user /bin/sh -c 'echo $(ulimit -Su)/$(ulimit -Hu)' 2>/dev/null)"
result container_spec_nproc "$(as_user /usr/bin/podman inspect --format '{{range .HostConfig.Ulimits}}{{if eq .Name "RLIMIT_NPROC"}}{{.Soft}}/{{.Hard}}{{end}}{{end}}' web.$U.01 2>/dev/null | tail -1)"

hdr "1.x parity: the account's own user@ and logind's /run/user/<uid>"
if old_session_start; then
    um=$(systemctl show -p MainPID --value "user@$UID_.service")
    result nproc_1x_user_manager "$(lim $um processes)"
    result runtime_dir_1x "$(findmnt -no OPTIONS /run/user/$UID_ | tr ',' '\n' | grep -E '^(size|nr_inodes|mode)=' | tr '\n' ' ')"
    result user_slice_pids_max_1x "$(cat $CG/user.slice/user-$UID_.slice/pids.max 2>/dev/null || cat $CG/pids/user.slice/user-$UID_.slice/pids.max 2>/dev/null)"
    # events readback in 1.x (journald logger, as the account inside its session)
    as_user_old /usr/bin/podman run --rm --name t06ev "$IMAGE" true >/dev/null 2>&1; rc=$?
    n=$(as_user_old /usr/bin/podman events --since 2m --stream=false --filter container=t06ev 2>/dev/null | grep -c .)
    result events_readback_1x "$([ $rc = 0 ] && echo "$n events" || echo "n/a (1.x run failed rc=$rc)")"
    old_session_stop
else
    result nproc_1x_user_manager "n/a (no user@)"
fi

hdr "2.0 runtime dir use with the kit's 3 containers"
result runtime_dir_2x "$(findmnt -no OPTIONS "$RUNDIR" | tr ',' '\n' | grep -E '^(size|nr_inodes)=' | tr '\n' ' ')used=$(df --output=used -k "$RUNDIR" | tail -1 | tr -d ' ')KiB inodes=$(df --output=iused "$RUNDIR" | tail -1 | tr -d ' ')"

hdr "exit codes without journal readback (2.0 env, delegated runner)"
o=$(as_user_deleg /usr/bin/podman run --rm "$IMAGE" sh -c 'exit 3' 2>&1); rc=$?
result run_rm_exit_code "$rc (want 3)"
as_user_deleg /usr/bin/podman run --name t06w "$IMAGE" sh -c 'exit 4' >/dev/null 2>&1
w=$(as_user /usr/bin/podman wait t06w 2>&1 | tail -1); x=$(as_user /usr/bin/podman inspect --format '{{.State.ExitCode}}' t06w 2>&1 | tail -1)
result wait_and_inspect_exit_code "wait=$w inspect=$x (want 4)"
as_user /usr/bin/podman rm -f t06w >/dev/null 2>&1

hdr "the account slice's TasksMax under a fork storm (LimitNPROC infinity on the unit)"
if [ $CGV = 2 ]; then target=$(ls -d "$CG/$A/$WEB"/libpod-payload-* | head -1); cur=$(cat "$CG/$A/pids.current")
else target="$CG/pids/$A/$WEB"; cur=$(cat "$CG/pids/$A/pids.current"); fi
old=$(systemctl show -p TasksMax --value "eapodman-$UID_.slice")
systemctl set-property --runtime "eapodman-$UID_.slice" TasksMax=$((cur + 100))
got=$(as_acct_in_cgroup "$target" init python3 -c '
import os, signal, time
kids = []
try:
    for i in range(400):
        pid = os.fork()
        if pid == 0:
            os.execv("/bin/sleep", ["sleep", "600"])
        kids.append(pid)
except OSError as e:
    pass
print(len(kids))
for k in kids:
    os.kill(k, signal.SIGKILL)
for k in kids:
    os.waitpid(k, 0)
' 2>&1 | tail -1)
rm -rf "/run/systemd/system.control/eapodman-$UID_.slice.d"; systemctl daemon-reload   # drop the runtime override
result fork_storm "slice had $cur tasks, TasksMax set to $((cur + 100)); forks that succeeded: $got of 400"
}

units() {
hdr "daemon-reload and PID 1 memory vs the number of enabled units"
D=/etc/systemd/system; W=$D/multi-user.target.wants
cleanup_units() { rm -f $D/t06dummy-*.service $W/t06dummy-*.service; systemctl daemon-reload; }
trap cleanup_units EXIT
measure() {
    local t0 t1; t0=$(date +%s%N); systemctl daemon-reload; t1=$(date +%s%N)
    result "reload_${1}_units" "$(( (t1 - t0) / 1000000 )) ms; PID1 RSS $(( $(ps -o rss= -p 1) / 1024 )) MiB; loaded units $(systemctl list-units --all --no-legend | wc -l)"
}
measure 0
n=0
for target in 200 1000 3000; do
    while [ $n -lt $target ]; do
        n=$((n + 1)); f=t06dummy-$n.service
        printf '[Unit]\nDescription=t06 dummy %s\n[Service]\nType=oneshot\nUser=%s\nSlice=eapodman-%s.slice\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' "$n" "$U" "$UID_" >$D/$f
        ln -s ../$f $W/$f
    done
    measure $target
done
}

swap() {
hdr "--memory-swap with a real swap device (temporary 1G swap file)"
SW=$(mktemp /var/tmp/t06.swap.XXXXXX) || exit 1    # not a fixed name: dd would follow a planted symlink
cleanup_swap() { swapoff "$SW" 2>/dev/null; rm -f "$SW"; for c in t06s1.$U.88 t06s2.$U.89; do probe_unit_rm $c >/dev/null 2>&1; done; }
trap cleanup_swap EXIT
dd if=/dev/zero of=$SW bs=1M count=1024 status=none && chmod 600 $SW && mkswap $SW >/dev/null
command -v chcon >/dev/null && selinuxenabled 2>/dev/null && chcon -t swapfile_t $SW
swapon $SW || { result swap "could not enable swap"; exit 0; }
result swap_on "$(tail -n +2 /proc/swaps | awk '{print $1, $3}' | tr '\n' ' ')"
for spec in "t06s1.$U.88|256m|256m" "t06s2.$U.89|256m|768m"; do
    IFS='|' read -r c mem sw <<<"$spec"
    probe_create "$c" --memory=$mem --memory-swap=$sw "$IMAGE" >/dev/null 2>&1 && probe_unit_start "$c" >/dev/null 2>&1
    pl=$(ls -d "$CG/$A/ea-podman-$c.service"/libpod-payload-* 2>/dev/null | head -1)
    [ -n "$pl" ] || { result "$c" "no payload cgroup"; continue; }
    as_acct_in_cgroup "$pl" init python3 -c 'b=bytearray(400*1024*1024); import time; time.sleep(1)' >/dev/null 2>&1; rc=$?
    result "memory_${mem}_swap_${sw}" "swap.max=$(cat $pl/memory.swap.max) alloc400M rc=$rc swap.peak=$(cat $pl/memory.swap.peak 2>/dev/null || echo n/a) oom_kill=$(awk '/oom_kill /{print $2}' $pl/memory.events)"
    probe_unit_rm "$c" >/dev/null 2>&1
done
}

case ${1:-basic} in basic) basic ;; units) units ;; swap) swap ;; esac
