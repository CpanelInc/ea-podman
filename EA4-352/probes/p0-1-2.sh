#!/bin/bash
# P0-1: use an existing (1.x) libpod DB with a new XDG_RUNTIME_DIR and the pinned CONTAINERS_*.
#       Error, or silent fallback?
# P0-2: start that 1.x container (created under user@ with the systemd cgroup manager) from a
#       system unit using cgroupfs. Rootful: does `podman rename` of a stopped container keep its
#       ID and named-volume mounts, and does a 1.x rootful container start from a cgroupfs unit?
set -uo pipefail
cd "$(dirname "$0")"; PROBE=p0-1; . ./plib.sh
OLD=p01old.$U.70
ROOTC=p02root
# A pristine 1.x storage: the account's own default storage (and DB) is moved aside and restored.
DS=$HOME_/.local/share/containers
DSBK=$HOME_/.local/share/containers.p01-backup
restore_storage() {
    [ -e "$DSBK" ] || return 0
    as_user_env 120 XDG_RUNTIME_DIR=$RUNDIR -- /usr/bin/podman unshare rm -rf "$DS" 2>/dev/null || rm -rf "$DS"
    mv "$DSBK" "$DS"
}
cleanup() {
    systemctl stop "ea-podman-$OLD.service" 2>/dev/null
    rm -f "/etc/systemd/system/ea-podman-$OLD.service" /etc/systemd/system/ea-podman-$ROOTC*.service
    systemctl daemon-reload; systemctl reset-failed "ea-podman-$OLD.service" "ea-podman-$ROOTC.service" 2>/dev/null
    as_user_env 120 "${PINNED_OLD[@]}" -- /usr/bin/podman rm -f "$OLD" >/dev/null 2>&1
    podman rm -f "$ROOTC" "$ROOTC-renamed" >/dev/null 2>&1; podman volume rm -f p02vol >/dev/null 2>&1
    [ -n "${CARVEOUT:-}" ] && old_session_stop
    rm -f "$OLDSTORE_CONF" "$OLDSTORE_CONF.runroot"
    restore_storage
}
trap cleanup EXIT

p02_start() {    # phase label
    local ph=$1 PROBE=p0-2 o rc j m cpid cur
    hdr "P0-2 ($ph): start the 1.x container from a system unit with cgroupfs"
    cat >"/etc/systemd/system/ea-podman-$OLD.service" <<EOF
[Service]
Type=forking
User=$U
Slice=eapodman-$UID_.slice
Delegate=cpu io memory pids
Environment=XDG_RUNTIME_DIR=$RUNDIR
Environment=CONTAINERS_CONF=$ETC/containers.conf
Environment=CONTAINERS_STORAGE_CONF=$OLDSTORE_CONF
Environment=CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf
Environment=XDG_CONFIG_HOME=$XDGDIR
ExecStart=/usr/bin/podman --cgroup-manager=cgroupfs start $OLD
ExecStop=/usr/bin/podman --cgroup-manager=cgroupfs stop -t 10 $OLD
TimeoutStartSec=90
EOF
    systemctl daemon-reload
    cur=$(journalctl -n0 --show-cursor | sed -n "s/^-- cursor: //p")
    o=$(systemctl start "ea-podman-$OLD.service" 2>&1); rc=$?
    j=$(journalctl -u "ea-podman-$OLD.service" --after-cursor="$cur" --no-pager -o cat | grep -i 'error' | tail -2 | tr '\n' ' ')
    if [ $rc = 0 ]; then
        m=$(systemctl show -p MainPID --value "ea-podman-$OLD.service")
        cpid=$(as_user_env 60 "${PINNED_OLD[@]}" -- /usr/bin/podman inspect --format '{{.State.Pid}}' "$OLD" 2>/dev/null | tail -1)
        result "${ph}_rootless_1x_start_from_cgroupfs_unit" "starts; conmon in $(grep -E '^0::|name=systemd' /proc/$m/cgroup 2>/dev/null | cut -d: -f3), container in $(grep -E '^0::|name=systemd' /proc/$cpid/cgroup 2>/dev/null | cut -d: -f3)"
        curl -fsS -o /dev/null http://127.0.0.1:8095/ && result "${ph}_old_container_serves" yes || result "${ph}_old_container_serves" no
    else
        result "${ph}_rootless_1x_start_from_cgroupfs_unit" "FAILS: $j"
    fi
    systemctl stop "ea-podman-$OLD.service"
    systemctl reset-failed "ea-podman-$OLD.service" 2>/dev/null
}

hdr "create a 1.x container in the account's own session (default storage, systemd manager)"
[ -e "$DS" ] && { [ ! -e "$DSBK" ] || { echo "$DSBK exists; restore it first" >&2; exit 1; }; mv "$DS" "$DSBK"; }
old_session_start || { result setup "could not start user@$UID_"; exit 1; }
o=$(as_user_old /usr/bin/podman run -d --name "$OLD" -p 127.0.0.1:8095:80 "$IMAGE" 2>&1); rc=$?
info "rc=$rc $(tail -1 <<<"$o")"
[ $rc = 0 ] || { result setup "FAILS: no 1.x container: $(tail -1 <<<"$o")"; exit 0; }
info "1.x info: $(as_user_old /usr/bin/podman info --format '{{.Host.CgroupManager}} {{.Store.GraphRoot}} {{.Store.RunRoot}} db={{.Host.DatabaseBackend}}' 2>/dev/null)"
info "recorded: $(as_user_old /usr/bin/podman inspect --format 'cgroupmgr={{.HostConfig.CgroupManager}} cgroups={{.HostConfig.Cgroups}} parent={{.HostConfig.CgroupParent}} conmonpid={{.ConmonPidFile}}' "$OLD" 2>&1)"
as_user_old /usr/bin/podman stop -t 5 "$OLD" >/dev/null 2>&1
# Phase A keeps the 1.x session up: logind removes /run/user/<uid> soon after user@ stops
# (user-runtime-dir@ is StopWhenUnneeded), and the 1.x DB pins its runroot there.
write_old_storage_conf
hdr "A: 1.x session still up (/run/user/$UID_ there), new env"
o=$(as_user_env 120 "${PINNED_OLD[@]}" -- /usr/bin/podman info --format '{{.Store.RunRoot}}' 2>&1)
result A_runroot_used "$(tail -1 <<<"$o")"
o=$(as_user_env 120 "${PINNED_OLD[@]}" -- /usr/bin/podman ps -a --format '{{.Names}}' 2>&1)
result A_old_container_listed "$(grep -q "$OLD" <<<"$o" && echo yes || echo "no: $(tail -1 <<<"$o")")"
p02_start A
systemctl stop "user@$UID_.service" "user-runtime-dir@$UID_.service"
info "session ended: /run/user/$UID_ $( [ -e /run/user/$UID_ ] && echo exists || echo gone)"
hdr "B: /run/user/$UID_ gone too (after the migration's step 12, or a logout)"

hdr "P0-1: old DB, new XDG_RUNTIME_DIR, pinned env (old-storage.conf without runroot)"
o=$(as_user_env 120 "${PINNED_OLD[@]}" -- /usr/bin/podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}' 2>&1); rc=$?
info "rc=$rc $(tr '\n' ' ' <<<"$o")"
rr=$(tail -1 <<<"$o" | awk '{print $2}')
result runroot_used "$rr"
case $rr in
    $RUNDIR/*) result outcome "new runroot used, no error" ;;
    /run/user/*) result outcome "SILENT FALLBACK to the DB's runroot ($rr)" ;;
    /tmp/*) result outcome "SILENT FALLBACK to the DB's runroot ($rr)" ;;
    *) result outcome "other: $(tail -1 <<<"$o")" ;;
esac
grep -qi 'mismatch\|does not match\|overriding\|Overriding' <<<"$o" && result message "$(grep -i 'mismatch\|does not match\|overriding' <<<"$o" | head -1)" || result message none
o=$(as_user_env 120 "${PINNED_OLD[@]}" -- /usr/bin/podman ps -a --format '{{.Names}} {{.Status}}' 2>&1); info "ps -a: $(tr '\n' ' ' <<<"$o")"
result old_container_listed "$(grep -q "$OLD" <<<"$o" && echo yes || echo no)"

hdr "P0-1: old-storage.conf with an explicit runroot in the new runtime dir"
{ cat "$OLDSTORE_CONF"; echo "runroot = \"$RUNDIR/containers-old\""; } >"$OLDSTORE_CONF.runroot"
sed -i 's/^\[storage\]$/[storage]/' "$OLDSTORE_CONF.runroot"
P2=("${PINNED_OLD[@]/CONTAINERS_STORAGE_CONF=*/CONTAINERS_STORAGE_CONF=$OLDSTORE_CONF.runroot}")
o=$(as_user_env 120 "${P2[@]}" -- /usr/bin/podman ps -a --format '{{.Names}}' 2>&1); rc=$?
info "rc=$rc $(tr '\n' ' ' <<<"$o")"
result explicit_runroot "$([ $rc = 0 ] && echo "works (rc=0)" || echo "ERROR: $(grep -i error <<<"$o" | head -1)")"

PROBE=p0-2
p02_start B

hdr "P0-2 rootful: rename keeps ID and named-volume mounts?"
podman volume create p02vol >/dev/null
podman create --name $ROOTC -v p02vol:/data "$IMAGE" >/dev/null 2>&1
id1=$(podman inspect --format '{{.Id}}' $ROOTC); m1=$(podman inspect --format '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' $ROOTC)
podman rename $ROOTC $ROOTC-renamed 2>&1 | tail -1
id2=$(podman inspect --format '{{.Id}}' $ROOTC-renamed 2>/dev/null); m2=$(podman inspect --format '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' $ROOTC-renamed 2>/dev/null)
info "before $id1 [$m1]  after $id2 [$m2]"
result rootful_rename "$([ -n "$id2" ] && [ "$id1" = "$id2" ] && [ "$m1" = "$m2" ] && echo "keeps ID and mounts" || echo "CHANGES: id $id1 -> $id2, mounts [$m1] -> [$m2]")"
podman rename $ROOTC-renamed $ROOTC >/dev/null 2>&1

hdr "P0-2 rootful: a 1.x-style rootful container (systemd manager) started from a cgroupfs unit"
info "recorded: $(podman inspect --format 'cgroupmgr={{.HostConfig.CgroupManager}} parent={{.HostConfig.CgroupParent}}' $ROOTC 2>&1)"
cat >/etc/systemd/system/ea-podman-$ROOTC.service <<EOF
[Service]
Type=forking
Slice=eapodman-0.slice
Delegate=yes
ExecStart=/usr/bin/podman --cgroup-manager=cgroupfs start $ROOTC
ExecStop=/usr/bin/podman --cgroup-manager=cgroupfs stop -t 10 $ROOTC
TimeoutStartSec=90
EOF
systemctl daemon-reload
o=$(systemctl start ea-podman-$ROOTC.service 2>&1); rc=$?
if [ $rc = 0 ]; then
    cpid=$(podman inspect --format '{{.State.Pid}}' $ROOTC)
    result rootful_1x_start_from_cgroupfs_unit "starts; container in $(grep -E '^0::|name=systemd' /proc/$cpid/cgroup | cut -d: -f3)"
else
    result rootful_1x_start_from_cgroupfs_unit "FAILS: $(journalctl -u ea-podman-$ROOTC.service --since -2min --no-pager -o cat | tail -2 | tr '\n' ' ')"
fi
systemctl stop ea-podman-$ROOTC.service
