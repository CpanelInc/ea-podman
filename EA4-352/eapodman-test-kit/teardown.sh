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
if [ "$PURGE" = --purge ]; then
    try "remove the test storage" rm -rf "$HOME_/.local/share/ea-podman/storage"
    rmdir "$HOME_/.local/share/ea-podman" 2>/dev/null
    try "remove $HOME_/.eapodman-loadtest" rm -rf "$HOME_/.eapodman-loadtest"
fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "teardown incomplete; these steps failed:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
fi
if [ "$PURGE" = --purge ]; then
    echo "removed, including $HOME_/.local/share/ea-podman/storage"
else
    echo "removed; $HOME_/.local/share/ea-podman/storage kept (use --purge to delete it)"
fi
