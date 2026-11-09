#!/bin/bash
# Run as root, after ./setup.sh.
# Show where everything landed and what each cgroup level enforces, then check the unit wiring.
# What is correct depends on the cgroup mode (F17): on v2 each container has its own
# libpod-payload-* cgroup with the per-container limits (split); on v1 split isn't pinned
# (setup.sh), the container runs in its unit's cgroup and those checks are skipped, saying why.
# Exits non-zero if a check fails, including when there was nothing to check.
set -uo pipefail
U=${1:?usage: $0 <cpuser>}
cd "$(dirname "$0")"
. ./lib.sh
[ -e /etc/systemd/system/eapodman.slice ] || { echo "not set up; run ./setup.sh $U first" >&2; exit 1; }
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

A=$CG/eapodman.slice/eapodman-$UID_.slice
if [ "$CGV" = 2 ]; then
    show $CG/eapodman.slice memory.low cpu.weight io.weight pids.max cgroup.subtree_control
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
else
    echo; echo "cgroup v1: per-controller hierarchies"
    show "$CG/memory/eapodman.slice/eapodman-$UID_.slice" memory.limit_in_bytes memory.soft_limit_in_bytes
    show "$CG/pids/eapodman.slice/eapodman-$UID_.slice" pids.max pids.current
    show "$CG/cpu,cpuacct/eapodman.slice" cpu.shares
fi

echo; echo "== account slice"
slice="eapodman-$UID_.slice"
check "$slice is loaded" test "$(systemctl show -p LoadState --value "$slice")" = loaded
check "$slice is active" test "$(systemctl show -p ActiveState --value "$slice")" = active
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
check "podman info answered as the account" test -n "$info"
check "$ETC/containers.conf pins an OCI runtime" test -n "$pinned_rt"
check "OCI runtime is the one pinned in $ETC/containers.conf" test -n "$rt" -a "$rt" = "$pinned_rt"
check "conmon is the one pinned in $ETC/containers.conf" grep -qF "conmon_path = [\"$conmon\"]" $ETC/containers.conf
check "cgroup manager is cgroupfs" test "$mgr" = cgroupfs
check "graphroot is the fresh ea-podman storage" test "$graph" = "$HOME_/.local/share/ea-podman/storage"
check "runroot is in the runtime tmpfs" test "$run" = "$RUNDIR/containers"
# F25: the pinned mounts.conf is root's, and holds the distro's entries (or none).
pinned_mounts() { grep -v '^#' "$MOUNTS_CONF" | grep .; }
distro_mounts() { local f; f=$(distro_mounts_conf) && grep -v '^#' "$f" | grep .; }
check "$MOUNTS_CONF is root-owned, 0644" test "$(stat -c '%u %a' "$MOUNTS_CONF" 2>/dev/null)" = "0 644"
check "$MOUNTS_CONF has the distro's entries ($(distro_mounts_conf || echo none))" \
    test "$(pinned_mounts)" = "$(distro_mounts)"

echo; echo "== container units (cgroup v$CGV)"
# setup.sh creates three; an unmatched glob must not pass as "nothing wrong".
UNITS=()
for unit in /etc/systemd/system/ea-podman-*."$U".[0-9][0-9].service; do
    [ -e "$unit" ] && UNITS+=("$unit")
done
check "setup.sh's three container units exist (found ${#UNITS[@]})" test ${#UNITS[@]} = 3
[ "$CGV" = 2 ] || skip "per-container cgroups and limits: cgroup v1, where split isn't pinned and" \
    "rootless podman can't create them (F12, F17); checking that each container runs in its unit's cgroup instead"
for unit in "${UNITS[@]}"; do
    u=$(basename "$unit")
    name=${u#ea-podman-}; name=${name%.service}
    pidfile=$(systemctl show -p PIDFile --value "$u")
    main=$(systemctl show -p MainPID --value "$u")
    echo "  $u: MainPID $main ($(ps -o comm= -p "$main" 2>/dev/null)), PIDFile $pidfile"
    check "$u PIDFile is derived from the container name" test "$pidfile" = "$(conmon_pidfile "$name")"
    check "$u ExecStart starts that container, with the pinned mounts.conf (F25)" \
        grep -qx "ExecStart=${PODMAN[*]} --cgroup-manager=cgroupfs start $name" "$unit"
    check "$u MainPID is conmon" test "$(ps -o comm= -p "$main" 2>/dev/null)" = conmon
    # v2: <unit>/runtime (cgroups = "split"); v1: the unit's cgroup itself.
    in_unit() { case $(cgroup_of "$1") in "/eapodman.slice/$slice/$u"|"/eapodman.slice/$slice/$u/"*) return 0;; esac; return 1; }
    check "$u MainPID is inside the unit's cgroup" in_unit "$main"
    if [ "$CGV" = 2 ]; then
        # F12: without split there is no container cgroup, and none of the per-container limits apply.
        payload=
        for p in "$A/$u"/libpod-payload-*; do [ -d "$p" ] && payload=$p && break; done
        check "$u has a libpod-payload-* container cgroup (--cgroups=split in effect)" test -n "$payload"
        if [ -n "$payload" ]; then
            for f in memory.max memory.swap.max cpu.max pids.max; do
                check "$u container cgroup has $f" test -e "$payload/$f"
            done
        fi
    else
        init=$(as_user /usr/bin/podman container inspect --format '{{.State.Pid}}' "$name" 2>/dev/null | tail -1)
        check "$u container init ($init) is inside the unit's cgroup" in_unit "$init"
        check "$u has no per-container memory cgroup (v1 rootless: the unit's limits are the container's)" \
            test "$(grep -E '^[0-9]+:memory:' "/proc/$init/cgroup" 2>/dev/null | cut -d: -f3)" = "/eapodman.slice/$slice/$u"
    fi
done

echo; echo "== runtime dir (F16, F19)"
# conf/runtime-mount has the account create these; they must be real dirs, never symlinks.
for e in cni netns; do
    check "$RUNDIR/$e is a real directory, $U's, 0700" \
        test ! -L "$RUNDIR/$e" -a -d "$RUNDIR/$e" -a "$(stat -c '%u %a' "$RUNDIR/$e" 2>/dev/null)" = "$UID_ 700"
done
for unit in "${UNITS[@]}"; do
    check "$(basename "$unit") is active (its container started)" systemctl is-active -q "$(basename "$unit")"
done
# F19: on SELinux hosts pasta needs netns labelled user_tmp_t (runtime-mount's chcon -h), and
# nothing of ea-podman's may be denied since the anchor started.
if command -v selinuxenabled >/dev/null && selinuxenabled; then
    echo "  SELinux: $(getenforce)"
    check "$RUNDIR/netns is labelled user_tmp_t" \
        test "$(stat -c %C "$RUNDIR/netns" 2>/dev/null | cut -d: -f3)" = user_tmp_t
    since=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "ea-podman-runtime@$UID_.service")" +%s 2>/dev/null)
    if [ -z "$since" ] || ! command -v ausearch >/dev/null; then
        check "AVC denials can be searched (ausearch, and the anchor's start time)" false
    else
        avc=$(LC_ALL=C ausearch -m avc,user_avc -i -ts $(LC_ALL=C date -d "@$since" '+%x %H:%M:%S') 2>&1); rc=$?
        # ausearch exits 1 with "<no matches>" when there are none; any other failure is an error.
        if [ $rc = 1 ] && grep -q '<no matches>' <<<"$avc"; then
            ours=
        elif [ $rc = 0 ]; then
            ours=$(grep -E 'pasta|slirp4netns|netavark|aardvark|conmon|podman|crun|runc|catatonit|ea-podman|eapodman' <<<"$avc")
            [ -n "$ours" ] || echo "  (AVC denials since the anchor started, none of them ea-podman's)"
        else
            ours="ausearch failed (rc $rc): $avc"
        fi
        check "no ea-podman AVC denials since the anchor started" test -z "$ours"
        [ -z "$ours" ] || sed 's/^/    /' <<<"$ours" | tail -20
    fi
else
    echo "  SELinux disabled: the netns label and AVC checks (F19) don't apply here"
fi

echo
[ "$FAILS" = 0 ] && echo "all checks passed" || { echo "$FAILS check(s) failed"; exit 1; }
