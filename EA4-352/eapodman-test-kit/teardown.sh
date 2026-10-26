#!/bin/bash
# Run as root. Undoes ./setup.sh: units, slices, containers, runtime mount, /etc/eapodman-test,
# and the generated unit copies in ./systemd. With --purge, also deletes the test storage
# ($HOME/.local/share/ea-podman/storage) and its pulled image.
# Usage: ./teardown.sh <cpuser> [--purge]
set -uo pipefail
U=${1:?usage: $0 <cpuser> [--purge]}
PURGE=${2:-}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"
UID_=$(id -u "$U"); GID_=$(id -g "$U"); HOME_=$(getent passwd "$U" | cut -d: -f6)
for unit in /etc/systemd/system/ea-podman-*."$U".[0-9][0-9].service; do
    [ -e "$unit" ] || continue
    name=$(basename "$unit" .service); name=${name#ea-podman-}
    systemctl disable --now "ea-podman-$name.service"
    systemd-run --quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" --pipe --wait --collect \
        -p WorkingDirectory="$HOME_" \
        --setenv=XDG_RUNTIME_DIR=/run/ea-podman/user/$UID_ \
        --setenv=CONTAINERS_CONF=/etc/eapodman-test/containers.conf \
        --setenv=CONTAINERS_STORAGE_CONF=/etc/eapodman-test/storage.conf \
        --setenv=XDG_CONFIG_HOME=/etc/eapodman-test/empty \
        /usr/bin/podman rm -f "$name" </dev/null
    rm -f "$unit"
done
systemctl stop "ea-podman-runtime@$UID_.service"
mountpoint -q "/run/ea-podman/user/$UID_" && umount "/run/ea-podman/user/$UID_"
rmdir "/run/ea-podman/user/$UID_" 2>/dev/null
rm -f "/etc/systemd/system/eapodman-$UID_.slice" /etc/systemd/system/eapodman.slice /etc/systemd/system/ea-podman-runtime@.service
systemctl daemon-reload
systemctl reset-failed 'ea-podman-*' 'eapodman-*' 2>/dev/null
rm -rf /etc/eapodman-test
# Generated copies setup.sh left in the kit (the shipped files stay).
rm -f "systemd/eapodman-$UID_.slice" systemd/ea-podman-*."$U".[0-9][0-9].service
if [ "$PURGE" = --purge ]; then
    rm -rf "$HOME_/.local/share/ea-podman/storage"
    rmdir "$HOME_/.local/share/ea-podman" 2>/dev/null
    echo "removed, including $HOME_/.local/share/ea-podman/storage"
else
    echo "removed; $HOME_/.local/share/ea-podman/storage kept (use --purge to delete it)"
fi
