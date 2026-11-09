# Shared by the kit's scripts. Source it after setting U (the cpuser); run as root.
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
UID_=$(id -u "$U") || exit 1
GID_=$(id -g "$U") && [ -n "$GID_" ] || { echo "no group for $U" >&2; exit 1; }
HOME_=$(getent passwd "$U" | cut -d: -f6)
# Everything run as the account uses it as its working directory, and paths are built under it.
case $HOME_ in /?*) ;; *) echo "$U has no usable home directory ('$HOME_')" >&2; exit 1 ;; esac
[ -d "$HOME_" ] || { echo "$U's home $HOME_ is not a directory" >&2; exit 1; }
RUNDIR=/run/ea-podman/user/$UID_
# F16: root-owned, holds only the root-owned cni symlink into the runtime tmpfs (conf/runtime-mount).
XDGDIR=/run/ea-podman/xdg/$UID_
ETC=/etc/eapodman-test
CG=/sys/fs/cgroup
# F17: the cgroup mode decides what a correct layout is (split, and the per-container cgroups, are v2 only).
CGV=1; [ "$(stat -fc %T $CG)" = cgroup2fs ] && CGV=2

# F25: podman applies the first mounts.conf that exists: the account's own
# ~/.config/containers/mounts.conf (found through $HOME, not XDG_CONFIG_HOME), then
# /etc/containers, then /usr/share/containers. containers.conf's default_mounts_file is never read.
# Only podman's global --default-mounts-file decides it, for a unit's start and a build's RUN steps
# alike (podman 3.4, 4.9 and 5.8). So every podman call with the pinned env carries it, and setup.sh
# renders the file, root-owned, from the distro's own (1.x parity: EL's /run/secrets stays).
MOUNTS_CONF=$ETC/mounts.conf
PODMAN=(/usr/bin/podman "--default-mounts-file=$MOUNTS_CONF")
# The distro's mounts.conf podman would use without the account's file, or nothing.
distro_mounts_conf() {
    local f
    for f in /etc/containers/mounts.conf /usr/share/containers/mounts.conf; do
        [ -e "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

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

# The plan's run_as_user_in_slice: a transient unit in the account's slice. With podman_env, an
# argv starting with /usr/bin/podman gets --default-mounts-file (F25). Options, then argv:
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
    [ -n "$pinned" ] && [ "${1:-}" = /usr/bin/podman ] && set -- "${PODMAN[@]}" "${@:2}"
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
ExecStart=${PODMAN[*]} --cgroup-manager=cgroupfs start $name
ExecStop=${PODMAN[*]} --cgroup-manager=cgroupfs stop -t 10 $name
# As in 1.x's generated units. It does not recover a container whose conmon was SIGKILLed:
# podman 4.4 leaves it "running" (without this) or "stopping" (with it), every restart's
# \`podman start\` fails, and only \`podman rm -f\` + recreate gets it back (./lifecycle.sh 1 and 3).
ExecStopPost=${PODMAN[*]} --cgroup-manager=cgroupfs stop -t 10 $name
Restart=on-failure
RestartSec=5
${success_exit}TimeoutStartSec=90
TimeoutStopSec=30
${extra}
[Install]
WantedBy=multi-user.target
UNIT
}

# ---------------------------------------------------------------- PIDs
# The cgroup path systemd sees a PID in (v2's 0:: line, v1's name=systemd line).
cgroup_of() { grep -E '^0::|name=systemd' "/proc/$1/cgroup" 2>/dev/null | head -1 | cut -d: -f3; }

# A PID file the account can write (anything under $RUNDIR or $HOME_) can be a symlink to
# /etc/shadow, or hold any number. Root reads it only as the account, and only digits come back;
# nothing else from it is ever printed. What comes back is still only the account's claim: pass it
# to safe_target with --uid and a cgroup check before acting on it. acct_pid <file>
acct_pid() {
    local v
    v=$(as_acct init head -c 32 -- "$1" 2>/dev/null | tr -d '\n')
    case $v in ''|*[!0-9]*) return 1;; esac
    echo "$v"
}

# Before root signals, moves or reports on a PID: it must be an integer above 1 (`kill 0` hits our
# own process group, `kill -1` everything) and pass every check the caller names, at least one:
#   --comm C       its comm is C (a stale PID may have been reused)
#   --uid N        it runs as uid N
#   --cgroup F     its /proc/<pid>/cgroup contains the fragment F
#   --cgroup-is P  cgroup_of is exactly P (e.g. a scope root itself created)
# A PID from systemd (MainPID) needs --comm; one from acct_pid also needs --uid and a cgroup check.
# Refusals go to stderr; non-zero means "don't touch it". safe_target <pid> <checks...>
safe_target() {
    local pid=$1 n=0 got; shift
    case $pid in ''|0|1|*[!0-9]*) echo "refusing PID '$pid'" >&2; return 1;; esac
    while [ $# -gt 0 ]; do
        [ $# -ge 2 ] || { echo "safe_target: $1 needs a value" >&2; return 2; }
        n=$((n + 1))
        case $1 in
        --comm)
            [ -n "$2" ] || { echo "refusing PID $pid: no expected comm (has it exited?)" >&2; return 1; }
            got=$(ps -o comm= -p "$pid" 2>/dev/null)
            [ "$got" = "$2" ] || { echo "refusing PID $pid: comm '$got', not '$2'" >&2; return 1; } ;;
        --uid)
            got=$(stat -c %u "/proc/$pid" 2>/dev/null)
            [ "$got" = "$2" ] || { echo "refusing PID $pid: uid '$got', not $2" >&2; return 1; } ;;
        --cgroup)
            grep -qF -- "$2" "/proc/$pid/cgroup" 2>/dev/null \
                || { echo "refusing PID $pid: not in a cgroup matching $2" >&2; return 1; } ;;
        --cgroup-is)
            [ -n "$2" ] || { echo "refusing PID $pid: no expected cgroup (is the unit gone?)" >&2; return 1; }
            got=$(cgroup_of "$pid")
            [ "$got" = "$2" ] || { echo "refusing PID $pid: in '$got', not $2" >&2; return 1; } ;;
        *) echo "safe_target: unknown check $1" >&2; return 2 ;;
        esac
        shift 2
    done
    [ $n -gt 0 ] || { echo "refusing PID $pid: no check given" >&2; return 1; }
}

# ---------------------------------------------------------------- temporary changes
# One contract for every value a script changes for a test: the original is saved before the
# first change, put back by restore_changes (or restore_one mid-run), and read back. A value that
# can't be put back is reported, never left silently changed; nothing else is touched.
#   change_cg [-n] <file> <value>        a cgroup file, written directly (-n: don't read it back,
#                                        e.g. memory.max, which the kernel page-aligns)
#   change_prop <unit> <Property> <value>   a systemd runtime property (set-property --runtime)
declare -A ORIG CHANGED_PROP_DROPIN
CHANGED=()    # keys, in change order: "cg:<file>" or "prop:<unit>:<Property>"

# Write a cgroup value and read it back; a write the kernel rejects is reported, not ignored.
set_cg() {    # file, value
    echo "$2" >"$1" 2>/dev/null && [ "$(cat "$1")" = "$2" ] \
        || { echo "  could not set $1 to '$2' (now '$(cat "$1" 2>/dev/null)')" >&2; return 1; }
}
change_cg() {
    local nb=; [ "$1" = -n ] && { nb=1; shift; }
    local f=$1 v=$2 k="cg:$1" o
    if [ -z "${ORIG[$k]+x}" ]; then
        o=$(cat "$f" 2>/dev/null) && [ -n "$o" ] || { echo "  could not read $f; not changing it" >&2; return 1; }
        ORIG[$k]=$o; CHANGED+=("$k")
    fi
    if [ -n "$nb" ]; then echo "$v" >"$f" || { echo "  could not set $f to '$v'" >&2; return 1; }
    else set_cg "$f" "$v"; fi
}
change_prop() {
    local unit=$1 p=$2 v=$3 k="prop:$1:$2" o dropin=/run/systemd/system.control/$1.d/50-$2.conf
    if [ -z "${ORIG[$k]+x}" ]; then
        o=$(systemctl show -p "$p" --value "$unit") && [ -n "$o" ] \
            || { echo "  could not read $unit $p; not changing it" >&2; return 1; }
        ORIG[$k]=$o; CHANGED+=("$k")
        # Our own runtime drop-in is removed on restore; someone else's is put back by value.
        [ -e "$dropin" ] && CHANGED_PROP_DROPIN[$k]=theirs || CHANGED_PROP_DROPIN[$k]=ours
    fi
    systemctl set-property --runtime "$unit" "$p=$v" \
        || { echo "  could not set $unit $p=$v" >&2; return 1; }
}
restore_one() {    # key ("cg:<file>" or "prop:<unit>:<Property>"); reads the value back
    local k=$1 rest unit p dropin
    [ -n "${ORIG[$k]+x}" ] || return 0
    case $k in
    cg:*) set_cg "${k#cg:}" "${ORIG[$k]}" || return 1 ;;
    prop:*)
        rest=${k#prop:}; unit=${rest%:*}; p=${rest##*:}
        dropin=/run/systemd/system.control/$unit.d/50-$p.conf
        if [ "${CHANGED_PROP_DROPIN[$k]}" = ours ] && [ -e "$dropin" ]; then
            rm -f "$dropin" || return 1
            rmdir "${dropin%/*}" 2>/dev/null    # only if that left it empty
            systemctl daemon-reload || return 1
        else
            # An empty value would write `infinity` on systemd 239 (F23): always the saved value.
            systemctl set-property --runtime "$unit" "$p=${ORIG[$k]}" || return 1
        fi
        [ "$(systemctl show -p "$p" --value "$unit")" = "${ORIG[$k]}" ] \
            || { echo "  $unit $p is '$(systemctl show -p "$p" --value "$unit")' after restore, not '${ORIG[$k]}'" >&2; return 1; } ;;
    esac
    unset "ORIG[$k]"
}
restore_cg() { restore_one "cg:$1"; }
restore_prop() { restore_one "prop:$1:$2"; }
# For an EXIT trap: as restore_changes, but a value left changed makes the script exit 1 (a trap's
# own status is otherwise lost).
restore_changes_or_fail() { restore_changes || exit 1; }
# Put back everything still changed, newest first; prints what couldn't be and returns 1 then.
restore_changes() {
    local i k failed=()
    for ((i = ${#CHANGED[@]} - 1; i >= 0; i--)); do
        k=${CHANGED[$i]}
        restore_one "$k" || failed+=("${k#*:}")
    done
    CHANGED=()
    [ ${#failed[@]} = 0 ] || { echo "NOT restored: ${failed[*]}" >&2; return 1; }
}

# ---------------------------------------------------------------- checks
FAILS=0
check() {    # description, then a command that succeeds when the check passes
    local what=$1; shift
    if "$@"; then echo "  PASS  $what"; else echo "  FAIL  $what"; FAILS=$((FAILS + 1)); fi
}
skip() { echo "  SKIP  $*"; }
