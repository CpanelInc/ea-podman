# Shared by the kit's scripts. Source it after setting U (the cpuser); run as root.
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
UID_=$(id -u "$U") || exit 1
GID_=$(id -g "$U"); HOME_=$(getent passwd "$U" | cut -d: -f6)
RUNDIR=/run/ea-podman/user/$UID_
# F16: root-owned, holds only the root-owned cni symlink into the runtime tmpfs (conf/runtime-mount).
XDGDIR=/run/ea-podman/xdg/$UID_
ETC=/etc/eapodman-test
CG=/sys/fs/cgroup
# F17: the cgroup mode decides what a correct layout is (split, and the per-container cgroups, are v2 only).
CGV=1; [ "$(stat -fc %T $CG)" = cgroup2fs ] && CGV=2

# T0.6: one nproc source for the unit's LimitNPROC and the create-time --ulimit pin.
NPROC=$(systemctl show -p DefaultLimitNPROC --value)

# The plan's podman_env($uid). The units carry the same values as Environment= lines.
ENVS=(
  --setenv=XDG_RUNTIME_DIR=$RUNDIR
  --setenv=CONTAINERS_CONF=$ETC/containers.conf
  --setenv=CONTAINERS_STORAGE_CONF=$ETC/storage.conf
  --setenv=CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf
  --setenv=XDG_CONFIG_HOME=$XDGDIR
)

# The plan's run_as_user_in_slice, by hand.
seq=0
as_user() {
    seq=$((seq + 1))
    systemd-run --quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" \
        --unit="eapodman-run-$UID_-test-$$-$seq" --pipe --wait --collect \
        -p RuntimeMaxSec=600 -p WorkingDirectory="$HOME_" "${ENVS[@]}" "$@" </dev/null
}

# Root chooses the PID file path from the container name and passes it to `podman create
# --conmon-pidfile`; it never takes it from podman inspect.
conmon_pidfile() { echo "$RUNDIR/$1.conmon.pid"; }

# The container unit, as setup.sh writes it. Args: name, MemoryLow, CPUWeight, and the
# SuccessExitStatus value ("" for none; lifecycle.sh test 5 compares the two).
# 143 is there because conmon, the main process, exits with the container's status: a PID 1 that
# exits 143 on SIGTERM would otherwise make a deliberate stop "failed" (1.x 0459147, PLAN.md Phase 1).
# 137 stays out: it is also an OOM kill.
container_unit() {
    local name=$1 memlow=$2 cpuweight=$3 success_exit= pidfile
    pidfile=$(conmon_pidfile "$name")
    [ -z "${4:-}" ] || success_exit="SuccessExitStatus=$4
"
    cat <<UNIT
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
# Plan's {NPROC} (T0.6): the host's DefaultLimitNPROC, what 1.x's user manager ran with.
LimitNPROC=$NPROC
Environment=XDG_RUNTIME_DIR=$RUNDIR
Environment=CONTAINERS_CONF=$ETC/containers.conf
Environment=CONTAINERS_STORAGE_CONF=$ETC/storage.conf
Environment=CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf
Environment=XDG_CONFIG_HOME=$XDGDIR
Environment=PODMAN_SYSTEMD_UNIT=%n
PIDFile=$pidfile
ExecStart=/usr/bin/podman --cgroup-manager=cgroupfs start $name
ExecStop=/usr/bin/podman --cgroup-manager=cgroupfs stop -t 10 $name
# As in 1.x's generated units. It does not recover a container whose conmon was SIGKILLed:
# podman 4.4 leaves it "running" (without this) or "stopping" (with it), every restart's
# \`podman start\` fails, and only \`podman rm -f\` + recreate gets it back (./lifecycle.sh 1 and 3).
ExecStopPost=/usr/bin/podman --cgroup-manager=cgroupfs stop -t 10 $name
Restart=on-failure
RestartSec=5
${success_exit}TimeoutStartSec=90
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
}

# The cgroup path systemd sees a PID in (v2's 0:: line, v1's name=systemd line).
cgroup_of() { grep -E '^0::|name=systemd' "/proc/$1/cgroup" 2>/dev/null | head -1 | cut -d: -f3; }

# Before signalling a PID that came from systemd or podman: it must be an integer above 1 and
# have the expected comm (`kill 0` would hit our own process group; a stale PID may be reused).
# Optional third argument: a cgroup path fragment the PID must be in.
safe_target() {    # pid, expected comm, [cgroup fragment]
    case $1 in ''|0|1|*[!0-9]*) echo "refusing to signal PID '$1'" >&2; return 1;; esac
    [ -n "$2" ] || { echo "refusing to signal PID $1: no expected comm (has it exited?)" >&2; return 1; }
    [ "$(ps -o comm= -p "$1" 2>/dev/null)" = "$2" ] \
        || { echo "PID $1 is '$(ps -o comm= -p "$1" 2>/dev/null)', not '$2'" >&2; return 1; }
    [ -z "${3:-}" ] || grep -qF "$3" "/proc/$1/cgroup" \
        || { echo "PID $1 is not in a cgroup matching $3" >&2; return 1; }
}

FAILS=0
check() {    # description, then a command that succeeds when the check passes
    local what=$1; shift
    if "$@"; then echo "  PASS  $what"; else echo "  FAIL  $what"; FAILS=$((FAILS + 1)); fi
}
skip() { echo "  SKIP  $*"; }
