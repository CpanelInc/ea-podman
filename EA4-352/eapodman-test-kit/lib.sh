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

# ---------------------------------------------------------------- running as the account
# The plan's podman_env($uid): sets PODMAN_ENV to the pinned assignments. The only variation a
# caller can ask for is a different containers.conf; the units carry the same values.
# podman_env [containers.conf]
podman_env() {
    PODMAN_ENV=(
        XDG_RUNTIME_DIR=$RUNDIR
        CONTAINERS_CONF=${1:-$ETC/containers.conf}
        CONTAINERS_STORAGE_CONF=$ETC/storage.conf
        CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf
        XDG_CONFIG_HOME=$XDGDIR
    )
}

# Every "run this as the account" goes through acct_unit (a transient unit) or as_acct (no unit).
# Both give the account its own supplementary groups (NSS), as the product's units get them from
# User=: a probe measures what the account can do, never more or less. as_acct takes the groups
# as its first argument so that a caller that needs otherwise says so: init (the account's groups)
# or clear (none).

# The plan's run_as_user_in_slice: a transient unit in the account's slice. Options, then argv:
#   -t SECS        RuntimeMaxSec (default 600)
#   -c CONF        containers.conf for this call only (default: the pinned one)
#   -E             no podman_env: only the -e assignments (if any)
#   -e K=V         an environment assignment (added to podman_env, or with -E the only ones)
#   -p PROP=VAL    an extra unit property (e.g. -p Delegate=yes)
#   -n NAME        the unit name's middle part (default "test"; probes pass "probe")
#   -v             keep systemd-run's own messages (no --quiet)
seq=0
acct_unit() {
    local tmo=600 conf= name=test quiet=--quiet pinned=1 extra=() envs=() props=() OPTIND=1 opt
    while getopts t:c:Ee:p:n:v opt; do
        case $opt in
        t) tmo=$OPTARG ;; c) conf=$OPTARG ;; E) pinned= ;; e) extra+=("$OPTARG") ;;
        p) props+=(-p "$OPTARG") ;; n) name=$OPTARG ;; v) quiet= ;;
        *) echo "acct_unit: bad option" >&2; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ -n "$pinned" ]; then local PODMAN_ENV; podman_env "$conf"; envs=("${PODMAN_ENV[@]}")
    elif [ -n "$conf" ]; then echo "acct_unit: -c needs podman_env (no -E)" >&2; return 2; fi
    envs+=("${extra[@]}")
    seq=$((seq + 1))
    systemd-run $quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" \
        --unit="eapodman-run-$UID_-$name-$$-$seq" --pipe --wait --collect \
        -p RuntimeMaxSec="$tmo" -p WorkingDirectory="$HOME_" "${props[@]}" \
        "${envs[@]/#/--setenv=}" "$@" </dev/null
}
# The common case, with podman_env: as_user [-c containers.conf] <argv...>
as_user() {
    if [ "${1:-}" = -c ]; then acct_unit -c "$2" -- "${@:3}"; else acct_unit -- "$@"; fi
}

# setpriv's prefix for the account: acct_argv <init|clear> sets ACCT_ARGV.
acct_argv() {
    case ${1:-} in
    init)  ACCT_ARGV=(setpriv --reuid="$UID_" --regid="$GID_" --init-groups) ;;
    clear) ACCT_ARGV=(setpriv --reuid="$UID_" --regid="$GID_" --clear-groups) ;;
    *) echo "groups must be init or clear, not '${1:-}'" >&2; return 2 ;;
    esac
}
# A command as the account, without a unit: for root's reads and writes in paths the account
# controls, where a planted symlink must not be followed with root's rights. From /, stdin closed.
# as_acct <init|clear> <argv...>
as_acct() {
    local ACCT_ARGV; acct_argv "$1" || return; shift
    (cd / && exec "${ACCT_ARGV[@]}" "$@" </dev/null)
}
# Root moves itself into cgroup <dir>, then becomes the account and execs argv (the load tests'
# way into a container's cgroup). as_acct_in_cgroup <dir> <init|clear> <argv...>
# acct_cgroup_argv sets ACCT_ARGV to the same prefix, for a caller that backgrounds it and needs
# $! to be the command itself (sh execs into it).
acct_cgroup_argv() {    # dir, init|clear
    acct_argv "$2" || return
    ACCT_ARGV=(sh -c 'echo $$ >"$1/cgroup.procs" && shift && exec "$@"' _ "$1" "${ACCT_ARGV[@]}")
}
as_acct_in_cgroup() {
    local ACCT_ARGV; acct_cgroup_argv "$1" "$2" || return; shift 2
    "${ACCT_ARGV[@]}" "$@"
}

# Root chooses the PID file path from the container name and passes it to `podman create
# --conmon-pidfile`; it never takes it from podman inspect.
conmon_pidfile() { echo "$RUNDIR/$1.conmon.pid"; }

# The container unit, as setup.sh writes it. Callers vary it only through these options, never by
# editing its output: what a probe starts is then the template plus what it asked for.
#   -c CONF   CONTAINERS_CONF for the unit (default: the pinned one)
#   -s LINE   an extra [Service] line (repeatable), e.g. -s PAMName=ea-podman
# Then: name, MemoryLow, CPUWeight, and the SuccessExitStatus value ("" for none; lifecycle.sh
# test 5 compares the two).
# 143 is there because conmon, the main process, exits with the container's status: a PID 1 that
# exits 143 on SIGTERM would otherwise make a deliberate stop "failed" (1.x 0459147, PLAN.md Phase 1).
# 137 stays out: it is also an OOM kill.
container_unit() {
    local conf= extra= opt OPTIND=1 PODMAN_ENV e env_lines=
    while getopts c:s: opt; do
        case $opt in
        c) conf=$OPTARG ;;
        s) extra+="$OPTARG"$'\n' ;;
        *) echo "container_unit: bad option" >&2; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))
    local name=$1 memlow=$2 cpuweight=$3 success_exit= pidfile
    pidfile=$(conmon_pidfile "$name")
    [ -z "${4:-}" ] || success_exit="SuccessExitStatus=$4
"
    podman_env "$conf"
    for e in "${PODMAN_ENV[@]}"; do env_lines+="Environment=$e"$'\n'; done
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
${env_lines}Environment=PODMAN_SYSTEMD_UNIT=%n
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
${extra}
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
