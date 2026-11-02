# Shared by the kit's scripts. Source it after setting U (the cpuser); run as root.
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
UID_=$(id -u "$U") || exit 1
GID_=$(id -g "$U"); HOME_=$(getent passwd "$U" | cut -d: -f6)
RUNDIR=/run/ea-podman/user/$UID_
# F16: root-owned, holds only the root-owned cni symlink into the runtime tmpfs (conf/runtime-mount).
XDGDIR=/run/ea-podman/xdg/$UID_
ETC=/etc/eapodman-test

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
