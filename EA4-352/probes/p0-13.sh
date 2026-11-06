#!/bin/bash
# P0-13: `podman exec` cgroup placement (F14), read from the host side for a held process.
#  - from the slice runner (as ea-podman's admin path would run it);
#  - from the account's own login shell (as `ea-podman bash` runs it, direct);
#  - from a sub-cgroup of the container unit's delegated subtree, placed there by root (F14's
#    "option 2");
#  - is it inside the LVE (CloudLinux), and is it killed at the runner's RuntimeMaxSec?
#  - 1.x parity (unmasked hosts): the same exec into a user@-managed container.
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
C=web.$U.01
UNITCG=eapodman.slice/eapodman-$UID_.slice/ea-podman-$C.service
TAG=$$
cleanup() {
    pkill -9 -u "$U" -f "sleep 4$TAG" 2>/dev/null; sleep 1
    for d in $CG/$UNITCG/p13exec $CG/*/$UNITCG/p13exec; do [ -d "$d" ] && rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

# Where a held exec'd `sleep 4<TAG><n>` sits, from the host: "<cgroup path>" or "".
where() { local p; p=$(pgrep -f "^sleep 4$TAG$1\$" | head -1); [ -n "$p" ] && grep -E '^0::|name=systemd' "/proc/$p/cgroup" | head -1 | cut -d: -f3; }
classify() {    # cgroup path -> words
    case $1 in
        '') echo "none" ;;
        */libpod-payload-*|*/ea-podman-$C.service/[0-9a-f]*[0-9a-f]) echo "container's cgroup" ;;
        */eapodman-run-*) echo "runner transient" ;;
        */p13exec) echo "unit subtree where root put it (not moved)" ;;
        */session-*.scope) echo "caller's login session scope (not moved)" ;;
        */podman-*.scope/[0-9a-f]*[0-9a-f]) echo "container's cgroup (1.x scope)" ;;
        */libpod-*.scope*) echo "container's cgroup (1.x scope)" ;;
        *) echo "other" ;;
    esac
}
# Run a held exec in the background with the given launcher, then report.
probe_exec() {    # key, n, launcher...
    local key=$1 n=$2; shift 2
    local of=/tmp/p13-$TAG-$n.out
    # Through a pipe: with SELinux, PID 1 may not write a /tmp file handed over by --pipe.
    ( "$@" /usr/bin/podman exec "$C" sleep 4$TAG$n 2>&1; echo "rc=$?" ) | cat >"$of" &
    local bg=$!
    sleep 3
    local cg; cg=$(where "$n")
    if [ -n "$cg" ]; then
        result "${key}" "works; $(classify "$cg") ($cg)"
    else
        wait $bg; result "${key}" "FAILS ($(tail -1 "$of")): $(grep -v 'level=warning\|^rc=' "$of" | tail -1)"
    fi
    pkill -9 -f "sleep 4$TAG$n" 2>/dev/null; wait $bg 2>/dev/null; rm -f "$of"
}
login_shell() {    # argv... as the account from a root-started login session (su -)
    local q; printf -v q '%q ' "$@"
    su - "$U" -s /bin/bash -c "cd; export XDG_RUNTIME_DIR=$RUNDIR CONTAINERS_CONF=$ETC/containers.conf CONTAINERS_STORAGE_CONF=$ETC/storage.conf CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf XDG_CONFIG_HOME=$XDGDIR; exec $q" </dev/null
}
in_unit_subtree() {    # argv... as the account from <unit>/p13exec, placed there by root (F14 option 2)
    local d
    if [ $CGV = 2 ]; then
        d=$CG/$UNITCG/p13exec; mkdir -p "$d"; echo $BASHPID >"$d/cgroup.procs"
    else
        for h in systemd pids memory cpu,cpuacct; do
            d=$CG/$h/$UNITCG/p13exec; mkdir -p "$d"; echo $BASHPID >"$d/cgroup.procs"
        done
    fi
    cd "$HOME_" && exec setpriv --reuid="$UID_" --regid="$GID_" --init-groups env -i PATH=/usr/bin:/bin HOME="$HOME_" \
        XDG_RUNTIME_DIR="$RUNDIR" CONTAINERS_CONF="$ETC/containers.conf" CONTAINERS_STORAGE_CONF="$ETC/storage.conf" \
        CONTAINERS_REGISTRIES_CONF="$ETC/registries.conf" XDG_CONFIG_HOME="$XDGDIR" "$@"
}
runtime=$(sed -n 's/^runtime = "\(.*\)"/\1/p' "$ETC/containers.conf")
result oci_runtime "$runtime $($runtime --version 2>/dev/null | head -1 | awk '{print $NF}')"

hdr "exec from the slice runner"
probe_exec exec_from_runner 1 as_user
hdr "exec from the account's login shell (ea-podman bash)"
probe_exec exec_from_login_shell 2 login_shell
hdr "exec from inside the container unit's delegated subtree (F14 option 2)"
probe_exec exec_from_unit_subtree 3 in_unit_subtree

if command -v lveps >/dev/null; then
    hdr "LVE"
    for n in 1 3; do
        launcher=as_user; [ $n = 3 ] && launcher=in_unit_subtree
        $launcher /usr/bin/podman exec "$C" sleep 4$TAG${n}9 2>&1 | cat >/dev/null &
        sleep 3
        pid=$(pgrep -f "^sleep 4$TAG${n}9\$" | head -1)
        if [ -n "$pid" ]; then
            lv=$(lveps -p 2>/dev/null | awk -v p="$pid" '{for(i=1;i<=NF;i++) if($i==p) print}' | head -1)
            result "exec_in_lve_$launcher" "$([ -n "$lv" ] && echo yes || echo no)"
        else
            result "exec_in_lve_$launcher" "n/a (exec failed)"
        fi
        pkill -9 -f "sleep 4$TAG${n}9"; wait 2>/dev/null
    done
fi

hdr "exec killed at the runner's RuntimeMaxSec"
t0=$(date +%s)
as_user_env 5 "${PINNED[@]}" -- /usr/bin/podman exec "$C" sleep 4${TAG}4 >/dev/null 2>&1; rc=$?
t=$(( $(date +%s) - t0 )); sleep 2
left=$(pgrep -f "sleep 4${TAG}4")
if [ "$rc" = 126 ] || [ "$t" -lt 3 ]; then result exec_killed_at_runtimemaxsec "n/a (exec failed, rc=$rc)"
else result exec_killed_at_runtimemaxsec "$([ -z "$left" ] && echo "yes (rc=$rc after ${t}s)" || echo "NO: still running after ${t}s")"; fi

hdr "1.x parity: exec into a user@-managed container"
if command -v cagefsctl >/dev/null; then
    result parity_1x "skipped (CloudLinux: CageFS masks user@)"
    exit 0
fi
old_session_start || { result parity_1x "could not start user@$UID_"; exit 0; }
o=$(as_user_old /usr/bin/podman run -d --name p13old "$IMAGE" 2>&1); rc=$?
info "run rc=$rc: $(tail -1 <<<"$o")"
cpid=$(as_user_old /usr/bin/podman inspect --format '{{.State.Pid}}' p13old 2>/dev/null)
info "container init: $(grep -E '^0::|name=systemd' /proc/$cpid/cgroup 2>/dev/null | head -1)"
login_shell_old() { local q; printf -v q '%q ' "$@"; su - "$U" -s /bin/bash -c "cd; export XDG_RUNTIME_DIR=$OLDRUN DBUS_SESSION_BUS_ADDRESS=unix:path=$OLDRUN/bus; exec $q" </dev/null; }
C_SAVE=$C; C=p13old
probe_exec parity_1x_exec_from_login_shell 5 login_shell_old
C=$C_SAVE
as_user_old /usr/bin/podman rm -f p13old >/dev/null 2>&1
old_session_stop
