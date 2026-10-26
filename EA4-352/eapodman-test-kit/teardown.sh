#!/bin/bash
# Run as root. Undoes ./setup.sh: units, slice limits, containers, runtime mount, /etc/eapodman-test,
# and the generated unit copies in ./systemd. With --purge, also deletes the test storage
# ($HOME/.local/share/ea-podman/storage) and its pulled image.
# Usage: ./teardown.sh <cpuser> [--purge]
set -uo pipefail
U=${1:?usage: $0 <cpuser> [--purge]}
PURGE=${2:-}
cd "$(dirname "$0")"
. ./lib.sh
for unit in /etc/systemd/system/ea-podman-*."$U".[0-9][0-9].service; do
    [ -e "$unit" ] || continue
    name=$(basename "$unit" .service); name=${name#ea-podman-}
    systemctl disable --now "ea-podman-$name.service"
    as_user /usr/bin/podman rm -f "$name"
    rm -f "$unit"
done
# Left behind only if ./lifecycle.sh was interrupted.
rm -f "/run/systemd/system/eapodman-test-pidfile-$UID_.service"
systemctl stop "ea-podman-runtime@$UID_.service"
mountpoint -q "$RUNDIR" && umount "$RUNDIR"
rmdir "$RUNDIR" 2>/dev/null
# The account slice's limits (the plan's clear_slice_properties), plus the slice file older kits wrote.
rm -rf "/etc/systemd/system.control/eapodman-$UID_.slice.d"
rm -f "/etc/systemd/system/eapodman-$UID_.slice" /etc/systemd/system/eapodman.slice /etc/systemd/system/ea-podman-runtime@.service
systemctl daemon-reload
systemctl reset-failed 'ea-podman-*' 'eapodman-*' 2>/dev/null
rm -rf $ETC
# Generated copies setup.sh left in the kit (the shipped files stay).
rm -f "systemd/eapodman-$UID_.slice" systemd/ea-podman-*."$U".[0-9][0-9].service
if [ "$PURGE" = --purge ]; then
    rm -rf "$HOME_/.local/share/ea-podman/storage"
    rmdir "$HOME_/.local/share/ea-podman" 2>/dev/null
    echo "removed, including $HOME_/.local/share/ea-podman/storage"
else
    echo "removed; $HOME_/.local/share/ea-podman/storage kept (use --purge to delete it)"
fi
