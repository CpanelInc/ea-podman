#!/bin/bash
# Manual test of the 2.0 layout: eapodman.slice > eapodman-<uid>.slice > anchor + 3 container units.
# Run as root. Usage: ./setup.sh <cpuser> [image]
# Safe to re-run: existing containers are kept, files and units are rewritten. Undo with ./teardown.sh.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: $0 <cpuser> [image]}
# Alpine-based nginx "hello" page: serves on :80 and has sh for podman exec load tests.
IMAGE=${2:-docker.io/nginxdemos/hello:plain-text}
. ./lib.sh

[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "not a cgroup v2 host" >&2; exit 1; }
grep -q "^$U:" /etc/subuid && grep -q "^$U:" /etc/subgid || { echo "$U has no subuid/subgid" >&2; exit 1; }
if systemctl is-active -q "user@$UID_.service"; then
    echo "WARNING: user@$UID_.service is running; stop the account's 1.x units first" >&2
fi

command -v ss >/dev/null || { echo "ss not found; can't check the test ports are free" >&2; exit 1; }
for port in 8081 8082 8083; do
    listeners=$(ss -Hltn "sport = :$port") || { echo "ss failed probing port $port" >&2; exit 1; }
    if [ -n "$listeners" ]; then
        ss -Hltnp "sport = :$port" | grep -q 'conmon\|rootlessport\|slirp' \
            || { echo "port $port is already in use" >&2; exit 1; }
    fi
done

# name|podman flags|MemoryLow (= reservation)|CPUWeight (= shares*100/1024)
CONTAINERS=(
  "web.$U.01|-p 127.0.0.1:8081:80 --memory=512m --memory-swap=512m --memory-reservation=256m --cpus=1.0 --cpu-shares=1024|256M|100"
  "api.$U.02|-p 127.0.0.1:8082:80 --memory=1g --memory-swap=1g --memory-reservation=512m --cpus=2.0 --cpu-shares=2048|512M|200"
  "worker.$U.03|-p 127.0.0.1:8083:80 --memory=256m --memory-swap=256m --memory-reservation=64m --cpus=0.5 --cpu-shares=512|64M|50"
)

# Pin the runtime and conmon the plan says containers.conf names explicitly: crun if the host has it, else runc.
RUNTIME=crun
command -v crun >/dev/null || RUNTIME=runc
RUNTIME_PATH=$(command -v "$RUNTIME") || { echo "neither crun nor runc found" >&2; exit 1; }
CONMON_PATH=$(command -v conmon) || { echo "conmon not found" >&2; exit 1; }

install -d -m 0755 $ETC
sed -e "s|@RUNTIME@|$RUNTIME|g" -e "s|@RUNTIME_PATH@|$RUNTIME_PATH|g" -e "s|@CONMON_PATH@|$CONMON_PATH|g" \
    conf/containers.conf >$ETC/containers.conf
chmod 0644 $ETC/containers.conf
install -m 0644 conf/storage.conf conf/registries.conf $ETC/
install -m 0644 /dev/null $ETC/mounts.conf
install -m 0755 conf/runtime-mount $ETC/

install -m 0644 systemd/eapodman.slice systemd/ea-podman-runtime@.service /etc/systemd/system/
# Earlier versions of the kit wrote the account slice as a unit file; the plan has none.
rm -f "/etc/systemd/system/eapodman-$UID_.slice" "systemd/eapodman-$UID_.slice"
systemctl daemon-reload
# The account slice is implicit (no file). Its limits are drop-ins under system.control, as the
# plan's set_slice_properties writes them. Floor = max(plugin floor, 256M+512M+64M) = 832M.
systemctl set-property "eapodman-$UID_.slice" MemoryLow=832M MemoryMax=2G TasksMax=33%
systemctl start "ea-podman-runtime@$UID_.service"

for c in "${CONTAINERS[@]}"; do
    IFS='|' read -r name flags memlow cpuweight <<<"$c"
    pidfile=$(conmon_pidfile "$name")
    # podman container exists: 0 = exists, 1 = no such container, anything else = couldn't check.
    rc=0; as_user /usr/bin/podman container exists "$name" || rc=$?
    case $rc in
        0) echo "$name already exists; keeping it" ;;
        # shellcheck disable=SC2086
        1) as_user /usr/bin/podman create --name "$name" --conmon-pidfile "$pidfile" $flags "$IMAGE" >/dev/null ;;
        *) echo "$name: couldn't check whether it exists (exit $rc); see above" >&2; exit 1 ;;
    esac
    # Cross-check only: the inspect value is never written into the unit.
    reported=$(as_user /usr/bin/podman container inspect --format '{{.ConmonPidFile}}' "$name")
    [ "$reported" = "$pidfile" ] || {
        echo "$name: podman writes conmon.pid to $reported, not $pidfile (created by an older kit?); run ./teardown.sh $U first" >&2
        exit 1
    }
    unit=/etc/systemd/system/ea-podman-$name.service
    container_unit "$name" "$memlow" "$cpuweight" 143 >"$unit"
    cp "$unit" systemd/
done

systemctl daemon-reload
for c in "${CONTAINERS[@]}"; do
    name=${c%%|*}
    systemctl enable -q "ea-podman-$name.service"
    # restart, not start, so a re-run picks up rewritten unit files.
    systemctl restart "ea-podman-$name.service"
done
for port in 8081 8082 8083; do
    echo "--- :$port"
    curl -fsS "http://127.0.0.1:$port/" | head -3
done
echo "done; now run ./verify.sh $U, ./loadtest.sh $U, then ./lifecycle.sh $U last (see README.md)"
