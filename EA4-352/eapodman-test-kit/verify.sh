#!/bin/bash
# Run as root, after ./setup.sh.
# Show where everything landed and what each cgroup level enforces, then check the unit wiring.
# Exits non-zero if a check fails.
set -uo pipefail
U=${1:?usage: $0 <cpuser>}
cd "$(dirname "$0")"
. ./lib.sh
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
        [ -d "$sub" ] || continue
        sub=${sub%/}
        show "$sub" memory.max memory.swap.max memory.low cpu.max cpu.weight pids.max cgroup.procs
    done
done

echo; echo "== account slice"
slice="eapodman-$UID_.slice"
check "$slice has no unit file (implicit, as in the plan)" \
    test -z "$(systemctl show -p FragmentPath --value "$slice")"
check "$slice limits are drop-ins under /etc/systemd/system.control" \
    grep -q "/etc/systemd/system.control/$slice.d/" <<<"$(systemctl show -p DropInPaths --value "$slice")"

echo; echo "== pinned podman config, as seen by the account"
info=$(as_user /usr/bin/podman info --format '{{.Host.OCIRuntime.Path}} {{.Host.Conmon.Path}} {{.Host.CgroupManager}} {{.Store.GraphRoot}} {{.Store.RunRoot}}')
read -r rt conmon mgr graph run <<<"$info"
echo "  runtime $rt, conmon $conmon, cgroup manager $mgr"
echo "  graphroot $graph"
echo "  runroot $run"
pinned_rt=$(sed -n 's/^\(crun\|runc\) = \["\(.*\)"\]$/\2/p' $ETC/containers.conf)
check "OCI runtime is the one pinned in $ETC/containers.conf" test "$rt" = "$pinned_rt"
check "conmon is the one pinned in $ETC/containers.conf" grep -qF "conmon_path = [\"$conmon\"]" $ETC/containers.conf
check "cgroup manager is cgroupfs" test "$mgr" = cgroupfs
check "graphroot is the fresh ea-podman storage" test "$graph" = "$HOME_/.local/share/ea-podman/storage"
check "runroot is in the runtime tmpfs" test "$run" = "$RUNDIR/containers"

echo; echo "== container units"
for unit in /etc/systemd/system/ea-podman-*."$U".[0-9][0-9].service; do
    [ -e "$unit" ] || continue
    u=$(basename "$unit")
    name=${u#ea-podman-}; name=${name%.service}
    pidfile=$(systemctl show -p PIDFile --value "$u")
    main=$(systemctl show -p MainPID --value "$u")
    echo "  $u: MainPID $main ($(ps -o comm= -p "$main" 2>/dev/null)), PIDFile $pidfile"
    check "$u PIDFile is derived from the container name" test "$pidfile" = "$(conmon_pidfile "$name")"
    check "$u ExecStart starts that container" grep -qx "ExecStart=/usr/bin/podman --cgroup-manager=cgroupfs start $name" "$unit"
    check "$u MainPID is conmon" test "$(ps -o comm= -p "$main" 2>/dev/null)" = conmon
    check "$u MainPID is inside the unit's cgroup" \
        grep -q "/eapodman.slice/$slice/$u/" "/proc/$main/cgroup"
    # F12: without split there is no container cgroup, and none of the per-container limits apply.
    payload=
    for p in "$A/$u"/libpod-payload-*; do [ -d "$p" ] && payload=$p && break; done
    check "$u has a libpod-payload-* container cgroup (--cgroups=split in effect)" test -n "$payload"
    if [ -n "$payload" ]; then
        for f in memory.max memory.swap.max cpu.max pids.max; do
            check "$u container cgroup has $f" test -e "$payload/$f"
        done
    fi
done

echo
[ "$FAILS" = 0 ] && echo "all checks passed" || { echo "$FAILS check(s) failed"; exit 1; }
