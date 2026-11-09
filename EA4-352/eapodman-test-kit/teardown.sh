#!/bin/bash
# Run as root. Undoes ./setup.sh: units, slice limits, containers, runtime mount, the XDG_CONFIG_HOME
# dir, /etc/eapodman-test, and the generated unit copies in ./systemd. With --purge, also deletes the
# test storage ($HOME/.local/share/ea-podman/storage), its pulled image, and loadtest's scratch dir.
# Every step runs even if an earlier one fails; the failures are listed and the exit status is 1.
# Usage: ./teardown.sh <cpuser> [--purge]
set -uo pipefail
U=${1:?usage: $0 <cpuser> [--purge]}
PURGE=${2:-}
cd "$(dirname "$0")"
. ./lib.sh
failed=()
try() {    # description, then the command
    local what=$1; shift
    "$@" || failed+=("$what")
}

for unit in /etc/systemd/system/ea-podman-*."$U".[0-9][0-9].service; do
    [ -e "$unit" ] || continue
    name=$(basename "$unit" .service); name=${name#ea-podman-}
    try "disable --now ea-podman-$name.service" systemctl disable --now "ea-podman-$name.service"
    try "podman rm -f $name" as_user /usr/bin/podman rm -f "$name"
    try "remove $unit" rm -f "$unit"
done
# Left running only if ./lifecycle.sh was killed before its cleanup ran (its unit holds a sleep 300).
TEST_UNIT=eapodman-test-pidfile-$UID_.service
if [ -e "/run/systemd/system/$TEST_UNIT" ]; then
    try "stop $TEST_UNIT" systemctl stop "$TEST_UNIT"
    try "remove /run/systemd/system/$TEST_UNIT" rm -f "/run/systemd/system/$TEST_UNIT"
fi
# The purge runs as the account, never as root: a symlink the account planted in any component of
# these home-directory paths would aim a root rm -rf anywhere on the host. `podman system reset`
# deletes the storage from inside the account's user namespace, which the subordinate-ID files
# need (`podman unshare rm` can't: the overlay driver holds storage/overlay mounted in there).
# What it leaves, and loadtest's scratch dir, are the account's own files. It needs the kit's
# runtime dir and config, so it runs before they go, and there is no root fallback: if it
# fails, the failure is listed and the files stay.
# A second --purge finds nothing left (the storage went with the first, $ETC at its end): that is
# done, not a failure. Only storage still there without the config to reset it is a failure.
STORAGE=$HOME_/.local/share/ea-podman/storage
PURGED=
if [ "$PURGE" = --purge ]; then
    # As the account, so a planted symlink is just the account's own path.
    if ! as_acct init test -e "$STORAGE" -o -e "$HOME_/.eapodman-loadtest"; then
        echo "nothing to purge: $STORAGE and $HOME_/.eapodman-loadtest are already gone"
    elif as_acct init test -e "$STORAGE" && [ ! -f "$ETC/containers.conf" ]; then
        failed+=("remove $STORAGE: $ETC is gone, so podman system reset can't run; run ./setup.sh $U, then ./teardown.sh $U --purge")
    elif as_acct init test -e "$STORAGE" && ! systemctl start "ea-podman-runtime@$UID_.service"; then
        failed+=("start ea-podman-runtime@$UID_.service for podman system reset; $STORAGE stays")
    else
        if as_acct init test -e "$STORAGE"; then
            try "podman system reset (as $U)" as_user /usr/bin/podman system reset --force
        fi
        try "remove the test storage and $HOME_/.eapodman-loadtest (as $U)" as_user \
            /bin/sh -c 'rm -rf "$1/.local/share/ea-podman/storage" "$1/.eapodman-loadtest" \
                && { rmdir "$1/.local/share/ea-podman" 2>/dev/null; true; }' _ "$HOME_"
        PURGED=1
    fi
fi
# Not there if setup.sh stopped before installing the template (e.g. on a cgroup v1 host); stopping
# a unit systemd can't find fails, though there is nothing to undo.
if [ "$(systemctl show -p LoadState --value "ea-podman-runtime@$UID_.service")" != not-found ]; then
    try "stop ea-podman-runtime@$UID_.service" systemctl stop "ea-podman-runtime@$UID_.service"
fi
if mountpoint -q "$RUNDIR"; then try "umount $RUNDIR" umount "$RUNDIR"; fi
if [ -d "$RUNDIR" ]; then try "rmdir $RUNDIR" rmdir "$RUNDIR"; fi
try "remove $XDGDIR" rm -rf "$XDGDIR"
# The account slice's limits (the plan's clear_slice_properties), plus the slice file older kits wrote.
try "remove the slice drop-ins" rm -rf "/etc/systemd/system.control/eapodman-$UID_.slice.d"
try "remove the slice and anchor units" rm -f "/etc/systemd/system/eapodman-$UID_.slice" \
    /etc/systemd/system/eapodman.slice /etc/systemd/system/ea-podman-runtime@.service
try "daemon-reload" systemctl daemon-reload
systemctl reset-failed 'ea-podman-*' 'eapodman-*' 2>/dev/null
try "remove $ETC" rm -rf "$ETC"
# Generated copies setup.sh left in the kit (the shipped files stay).
rm -f "systemd/eapodman-$UID_.slice" systemd/ea-podman-*."$U".[0-9][0-9].service

if [ ${#failed[@]} -gt 0 ]; then
    echo "teardown incomplete; these steps failed:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
fi
if [ -n "$PURGED" ]; then
    echo "removed, including $STORAGE"
elif [ "$PURGE" = --purge ]; then
    echo "removed"
else
    echo "removed; $STORAGE kept (use --purge to delete it)"
fi
