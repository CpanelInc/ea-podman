#!/bin/bash
# Manual test of the 2.0 layout: eapodman.slice > eapodman-<uid>.slice > anchor + 3 container units.
# Run as root. Usage: ./setup.sh <cpuser> [image]
# Safe to re-run: existing containers are kept, files and units are rewritten. Undo with ./teardown.sh.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: $0 <cpuser> [image]}
# Alpine-based nginx "hello" page: serves on :80 and has sh for podman exec load tests.
IMAGE=${2:-docker.io/nginxdemos/hello:plain-text}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "not a cgroup v2 host" >&2; exit 1; }
UID_=$(id -u "$U"); GID_=$(id -g "$U"); HOME_=$(getent passwd "$U" | cut -d: -f6)
grep -q "^$U:" /etc/subuid && grep -q "^$U:" /etc/subgid || { echo "$U has no subuid/subgid" >&2; exit 1; }
if systemctl is-active -q "user@$UID_.service"; then
    echo "WARNING: user@$UID_.service is running; stop the account's 1.x units first" >&2
fi

for port in 8081 8082 8083; do
    if ss -Hltn "sport = :$port" | grep -q .; then
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

install -d -m 0755 /etc/eapodman-test /etc/eapodman-test/empty
install -m 0644 conf/containers.conf conf/storage.conf /etc/eapodman-test/
install -m 0755 conf/runtime-mount /etc/eapodman-test/

install -m 0644 systemd/eapodman.slice systemd/ea-podman-runtime@.service /etc/systemd/system/
# Account slice. The plan sets these with set_slice_properties (no file); a file is used here
# so the test is self-contained. Floor = max(plugin floor, 256M+512M+64M) = 832M.
cat > /etc/systemd/system/eapodman-$UID_.slice <<SLICE
[Unit]
Description=ea-podman account $U ($UID_)
Before=slices.target

[Slice]
MemoryLow=832M
MemoryMax=2G
TasksMax=33%
SLICE
cp /etc/systemd/system/eapodman-$UID_.slice systemd/
systemctl daemon-reload
systemctl start "ea-podman-runtime@$UID_.service"

ENVS=(
  --setenv=XDG_RUNTIME_DIR=/run/ea-podman/user/$UID_
  --setenv=CONTAINERS_CONF=/etc/eapodman-test/containers.conf
  --setenv=CONTAINERS_STORAGE_CONF=/etc/eapodman-test/storage.conf
  --setenv=XDG_CONFIG_HOME=/etc/eapodman-test/empty
)
seq=0
as_user() {    # the plan's run_as_user_in_slice, by hand
    seq=$((seq + 1))
    systemd-run --quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" \
        --unit="eapodman-run-$UID_-test-$$-$seq" --pipe --wait --collect \
        -p RuntimeMaxSec=600 -p WorkingDirectory="$HOME_" "${ENVS[@]}" "$@" </dev/null
}

for c in "${CONTAINERS[@]}"; do
    IFS='|' read -r name flags memlow cpuweight <<<"$c"
    # shellcheck disable=SC2086
    if as_user /usr/bin/podman container exists "$name"; then
        echo "$name already exists; keeping it"
    else
        as_user /usr/bin/podman create --name "$name" $flags "$IMAGE"
    fi
    pidfile=$(as_user /usr/bin/podman inspect --format '{{.ConmonPidFile}}' "$name")
    unit=/etc/systemd/system/ea-podman-$name.service
    cat > "$unit" <<UNIT
# ea-podman owner=$U uid=$UID_ container=$name
[Unit]
Description=ea-podman container $name
Requires=ea-podman-runtime@$UID_.service
After=ea-podman-runtime@$UID_.service
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=forking
User=$U
Group=$(id -gn "$U")
Slice=eapodman-$UID_.slice
Delegate=cpu io memory pids
# F13: the unit carries the container's floor and weight, or they do nothing.
MemoryLow=$memlow
CPUWeight=$cpuweight
# Plan's {NPROC}. RLIMIT_NPROC counts every process of the uid, so infinity for the test.
LimitNPROC=infinity
Environment=XDG_RUNTIME_DIR=/run/ea-podman/user/$UID_
Environment=CONTAINERS_CONF=/etc/eapodman-test/containers.conf
Environment=CONTAINERS_STORAGE_CONF=/etc/eapodman-test/storage.conf
Environment=XDG_CONFIG_HOME=/etc/eapodman-test/empty
PIDFile=$pidfile
ExecStart=/usr/bin/podman --cgroup-manager=cgroupfs start $name
ExecStop=/usr/bin/podman --cgroup-manager=cgroupfs stop -t 10 $name
Restart=on-failure
RestartSec=5
SuccessExitStatus=143
TimeoutStartSec=90
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
    cp "$unit" systemd/
done

systemctl daemon-reload
for c in "${CONTAINERS[@]}"; do
    name=${c%%|*}
    systemctl enable --now "ea-podman-$name.service"
done
for port in 8081 8082 8083; do
    echo "--- :$port"
    curl -fsS "http://127.0.0.1:$port/" | head -3
done
echo "done; now run ./verify.sh $U"
