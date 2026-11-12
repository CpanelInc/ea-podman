#!/bin/bash
# P0-3 / EA4-366: with hidepid=2 (or invisible) on /proc, what does a stop do to the unit's
# verdict, to KillMode reaping, and to the UNIT_REMOVE order (stop, then podman rm)?
# Runs on every host; the hidepid hosts are the ones that matter, the rest are the control.
set -uo pipefail
cd "$(dirname "$0")"; PROBE=p0-3; . ./plib.sh
hp=$(findmnt -no OPTIONS /proc | grep -o 'hidepid=[^,]*' || echo none)
result hidepid "$hp"
C=p03hp.$U.84
trap 'probe_unit_rm $C >/dev/null 2>&1' EXIT
probe_create "$C" "$IMAGE" >/dev/null 2>&1 && probe_unit_start "$C" >/dev/null 2>&1
u=ea-podman-$C.service
systemctl is-active -q "$u" || { result setup "FAILS: $u not active"; exit 1; }
cgpath=$(systemctl show -p ControlGroup --value "$u")
[ -n "$cgpath" ] || { result setup "FAILS: no ControlGroup for $u"; exit 1; }

hdr "systemctl stop"
cur=$(journalctl -n0 --show-cursor | sed -n 's/^-- cursor: //p')
t0=$(date +%s); systemctl stop "$u"; src=$?; t=$(( $(date +%s) - t0 ))
res=$(systemctl show -p Result --value "$u"); st=$(systemctl show -p ActiveState --value "$u")
j=$(journalctl -u "$u" --after-cursor="$cur" --no-pager -o cat)
result stop "rc=$src after ${t}s; ActiveState=$st Result=$res"
grep -qi 'timed out waiting for file' <<<"$j" && result stop_exit_file_timeout "YES: $(grep -m1 -i 'timed out waiting' <<<"$j" | cut -c1-160)" || result stop_exit_file_timeout no
grep -qiE 'Killing process|SIGKILL|left-over process' <<<"$j" && result killmode_reaped "$(grep -ciE 'Killing process|left-over' <<<"$j") processes killed by systemd" || result killmode_reaped "none needed"
# systemd removes the unit's cgroup once it is empty, so a missing directory means none are left;
# a directory whose cgroup.procs can't be read is not "none".
ucg=$CG$cgpath; [ $CGV = 2 ] || ucg=$CG/systemd$cgpath
if [ ! -d "$ucg" ]; then
    result leftovers_in_unit_cgroup "none (the unit's cgroup is gone)"
elif left=$(cat "$ucg/cgroup.procs" 2>&1); then
    result leftovers_in_unit_cgroup "$([ -z "$left" ] && echo none || echo "$(wc -w <<<"$left") pids")"
else
    inconclusive leftovers_in_unit_cgroup "couldn't read $ucg/cgroup.procs: $left"
fi
state=$(as_user /usr/bin/podman inspect --format '{{.State.Status}}' "$C" 2>&1 | tail -1)
result podman_state_after_stop "$state"

hdr "UNIT_REMOVE order: podman rm after the stop"
o=$(as_user /usr/bin/podman rm "$C" 2>&1); rc=$?
result rm_after_stop "$([ $rc = 0 ] && echo works || echo "FAILS: $(tail -1 <<<"$o")")"
if [ $rc != 0 ]; then
    o=$(as_user /usr/bin/podman rm -f "$C" 2>&1); result rm_force_after_stop "$([ $? = 0 ] && echo works || echo "FAILS: $(tail -1 <<<"$o")")"
fi
probe_exit
