#!/bin/bash
# Run as root, after ./setup.sh.
# Show where everything landed and what each cgroup level enforces.
set -uo pipefail
U=${1:?usage: $0 <cpuser>}
UID_=$(id -u "$U")
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -e /etc/systemd/system/eapodman.slice ] || { echo "not set up; run ./setup.sh $U first" >&2; exit 1; }
CG=/sys/fs/cgroup
show() {    # dir, files...
    local d=$1; shift
    printf '\n== %s\n' "${d#$CG/}"
    for f in "$@"; do
        [ -e "$d/$f" ] && printf '  %-24s %s\n' "$f" "$(tr '\n' ' ' <"$d/$f")" || printf '  %-24s (missing)\n' "$f"
    done
}

systemd-cgls --no-pager -u eapodman.slice
echo; echo "user.slice CPUWeight: $(systemctl show -p CPUWeight --value user.slice) (eapodman.slice should match)"
echo "user@$UID_ active: $(systemctl is-active "user@$UID_.service")  (should be inactive)"

show $CG/eapodman.slice memory.low cpu.weight io.weight pids.max cgroup.subtree_control
A=$CG/eapodman.slice/eapodman-$UID_.slice
show "$A" memory.low memory.max pids.max cgroup.subtree_control
for svc in "$A"/ea-podman-*.service; do
    [ -d "$svc" ] || continue
    show "$svc" memory.low cpu.weight cgroup.subtree_control cgroup.procs
    for sub in "$svc"/*/; do
        sub=${sub%/}
        show "$sub" memory.max memory.swap.max memory.low cpu.max cpu.weight pids.max cgroup.procs
    done
done
