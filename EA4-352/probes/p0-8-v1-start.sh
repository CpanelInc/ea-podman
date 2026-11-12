#!/bin/bash
# P0-8 follow-up (PR #43 review 4, finding 1): on cgroup v1, why p0-8's unit start can fail
# right after its plain-runner start. A container started from the plain runner lives in the
# runner's transient unit, so it dies when that unit ends; a unit start that follows at once
# can meet the dying first instance. Three sequences, RUNS times each (default 3):
#   unit_only   create, unit start
#   back2back   create, runner start, unit start (p0-8's order)
#   settled     create, runner start, wait 5s, unit start
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
N=p08v1.$U.61
RUNS=${RUNS:-3}
trap 'probe_unit_rm $N' EXIT
state() { as_user /usr/bin/podman inspect --format '{{.State.Status}}' $N 2>&1 | tail -1; }
one() {    # sequence, run number
    probe_unit_rm $N
    probe_create $N -p 127.0.0.1:8091:80 "$IMAGE" >/dev/null || { inconclusive "$1.$2" "create failed"; return; }
    local runner=
    if [ "$1" != unit_only ]; then
        as_user /usr/bin/podman start $N >/dev/null 2>&1; runner="runner_start_rc=$? state_after_runner=$(state) "
        [ "$1" = settled ] && sleep 5
    fi
    probe_unit_start $N >/dev/null 2>&1; local rc=$?
    sleep 2
    result "$1.$2" "${runner}unit_start_rc=$rc unit=$(systemctl is-active "ea-podman-$N.service") state=$(state)"
}
hdr "unit start after each sequence"
for s in unit_only back2back settled; do for i in $(seq "$RUNS"); do one $s $i; done; done

hdr "where a runner-started container's conmon is, and what is left when the runner unit ends"
probe_unit_rm $N; probe_create $N "$IMAGE" >/dev/null || { inconclusive runner_cgroup "create failed"; probe_exit; }
o=$(acct_unit -n hold -- /bin/sh -c '"$@" start "$0" >/dev/null && p=$("$@" inspect --format "{{.State.ConmonPid}}" "$0") &&
    sed -n "s/^[0-9]*:name=systemd:/conmon /p; s/^0::/conmon /p" /proc/$p/cgroup &&
    sed -n "s/^[0-9]*:name=systemd:/runner /p; s/^0::/runner /p" /proc/self/cgroup' $N "${PODMAN[@]}" 2>&1)
c=$(sed -n 's/^conmon //p' <<<"$o"); r=$(sed -n 's/^runner //p' <<<"$o")
if [ -z "$c" ] || [ -z "$r" ]; then inconclusive runner_cgroup "no cgroup read: $(tail -1 <<<"$o")"
else
    info "conmon: $c"; info "runner: $r"
    result conmon_in_runner_unit "$([ "$c" = "$r" ] && echo yes || echo no)"
    sleep 2
    result state_after_runner_unit_ended "$(state)"
fi
probe_exit
