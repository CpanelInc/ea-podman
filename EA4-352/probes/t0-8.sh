#!/bin/bash
# T0.8 (F20): how `podman exec` reaches a container on crun hosts, with a root placement step.
#   t0-8.sh bash     the `ea-podman bash` shape: the account's own process, in user-<uid>.slice and
#                    on a pty, is moved by root into <unit>/ea-podman-exec, then runs `podman exec -it`.
#                    Also: a unit stop with a live session, and a leaf the account froze beforehand.
#   t0-8.sh health   podman healthchecks without a user manager, and a root timer whose service
#                    runs `podman healthcheck run` from <unit>/ea-podman-health (healthy, unhealthy,
#                    and a check that outlives the service's timeout)
#   t0-8.sh ptrace   can the account's own processes ptrace its container's conmon and init
#   t0-8.sh hc-helper <container>   the timer's ExecStart (root): place itself, drop, run the check
set -uo pipefail
cd "$(dirname "$0")"; PROBE=t0-8
[ "${1:-}" = hc-helper ] && exec 1>/dev/null    # plib prints a host line; keep the journal clean
. ./plib.sh
TAG=$$
SELF=$(readlink -f "$0")
R= D=    # R: root's private dir (mktemp) holding the pty helper; D=$R/u: the account's files
X=t08x.$U.80 H=t08h.$U.81 F=t08f.$U.82 S=t08s.$U.83 P=t08p.$U.84

cgof() { grep -E '^0::|name=systemd' "/proc/$1/cgroup" 2>/dev/null | head -1 | cut -d: -f3; }
unit_cg() { systemctl show -p ControlGroup --value "ea-podman-$1.service"; }    # from systemd, never from the account
envs() { printf '%s ' "${PINNED[@]}"; }

# A PID from the account (acct_session's pid file) is only a claim. Root accepts it only if the
# kernel puts it in the session scope root itself just created, owned by the account and running
# the pty's sh: any other PID (a host service, another user's process) is refused. The account
# can't move processes into that root-owned scope, so whatever is in it is the account's own.
# scope_pid <pid> <scope unit>
scope_pid() {
    local scg
    case $1 in ''|0|1|*[!0-9]*) echo "refusing PID '$1'"; return 1;; esac
    scg=$(systemctl show -p ControlGroup --value "$2"); [ -n "$scg" ] || { echo "refusing PID $1: $2 is gone"; return 1; }
    [ "$(cgof "$1")" = "$scg" ] || { echo "refusing PID $1: in '$(cgof "$1")', not $2"; return 1; }
    [ "$(stat -c %u "/proc/$1" 2>/dev/null)" = "$UID_" ] || { echo "refusing PID $1: not uid $UID_"; return 1; }
    [ "$(ps -o comm= -p "$1" 2>/dev/null)" = sh ] || { echo "refusing PID $1: comm '$(ps -o comm= -p "$1" 2>/dev/null)', not sh"; return 1; }
}

# Root's placement step: move <pid> into <unit>/<leaf> (v2 only; on v1 exec already lands in the
# container's cgroup, P0-13). With a scope, the PID came from the account and must pass scope_pid,
# before and (for PID reuse in between) after the move. Prints what happened; non-zero means "refuse".
place() {    # pid, container, leaf, [scope unit the PID must be in]
    local cg d r
    if [ -n "${4:-}" ]; then r=$(scope_pid "$1" "$4") || { echo "$r"; return 1; }; fi
    [ $CGV = 2 ] || { echo "v1: not moved"; return 0; }
    cg=$(unit_cg "$2"); [ -n "$cg" ] || { echo "unit not running"; return 1; }
    d=$CG$cg/$3
    mkdir "$d" 2>/dev/null || [ -d "$d" ] || { echo "mkdir $d failed"; return 1; }
    echo "$1" 2>&1 >"$d/cgroup.procs" || { echo "write to $d/cgroup.procs failed"; return 1; }
    if [ -n "${4:-}" ] && { [ "$(stat -c %u "/proc/$1" 2>/dev/null)" != "$UID_" ] \
            || [ "$(ps -o comm= -p "$1" 2>/dev/null)" != sh ]; }; then
        echo "PID $1 changed hands during the move (now uid $(stat -c %u "/proc/$1" 2>/dev/null), comm $(ps -o comm= -p "$1" 2>/dev/null))"
        return 1
    fi
    echo "moved to $cg/$3"
}

# The account's own process on a pty (40x120), in a scope under user-<uid>.slice like an SSH
# login: it writes its PID, waits for root's go, then execs <cmd>. acct_session <n> <cmd>
acct_session() {
    local n=$1 cmd=$2
    rm -f "$D/pid$n" "$D/go$n"
    systemd-run --quiet --scope --slice="user-$UID_.slice" --unit="t08-acct-$TAG-$n" -- \
        setpriv --reuid="$UID_" --regid="$GID_" --init-groups \
        env -i PATH=/usr/bin:/bin HOME="$HOME_" python3 -I "$R/t08pty.py" "$D/out$n" \
        "cd $HOME_; echo \$\$ >$D/pid$n; while [ ! -e $D/go$n ]; do sleep 0.2; done; exec $cmd" </dev/null >/dev/null 2>&1 &
    local i; for i in $(seq 50); do [ -s "$D/pid$n" ] && break; sleep 0.2; done
    acct cat "$D/pid$n" 2>/dev/null
}
exec_cmd() {    # container, n: the `ea-podman bash` exec, holding a `sleep 4<TAG><n>` in the container
    echo "env -i PATH=/usr/bin:/bin HOME=$HOME_ $(envs)/usr/bin/podman exec -it $1 sh -c 'tty; stty size; exec sleep 4$TAG$2'"
}
# D is the account's dir: root reads and writes in it only as the account, so planted symlinks are harmless.
acct() { setpriv --reuid="$UID_" --regid="$GID_" --init-groups "$@"; }
go() { acct touch "$D/go$1"; }
held() { pgrep -f "^sleep 4$TAG$1\$" | head -1; }
out() { acct cat "$D/out$1" 2>/dev/null | tr -d '\r' | grep -v '^$' | grep -v 'level=warning' | tail -4 | paste -sd'|' -; }

setup_d() {
    R=$(mktemp -d /tmp/t08-$TAG.XXXXXX) || exit 1; chmod 0755 "$R"
    D=$R/u; mkdir "$D"; chown "$UID_:$GID_" "$D"    # new, in a dir only root can write
    cat >"$R/t08pty.py" <<'PY'
import fcntl, os, pty, select, struct, sys, termios
of, cmd = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv('/bin/sh', ['/bin/sh', '-c', cmd])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
with open(of, 'ab', buffering=0) as out:
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 1.0)
        except InterruptedError:
            continue
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out.write(data)
        elif os.waitpid(pid, os.WNOHANG)[0]:
            pid = 0
            break
    st = os.waitpid(pid, 0)[1] if pid else 0
    out.write(b'\nrc=%d\n' % (st >> 8))
PY
}

bash_mode() {
    local p cg i t0 t1 r
    cleanup() {
        pkill -9 -f "sleep 4$TAG" 2>/dev/null; pkill -9 -u "$U" -f "$R/t08pty.py" 2>/dev/null; sleep 1
        [ $CGV = 2 ] && [ -n "$(unit_cg $X)" ] && echo 0 >"$CG$(unit_cg $X)/ea-podman-exec/cgroup.freeze" 2>/dev/null
        probe_unit_rm $X >/dev/null 2>&1; [ -n "$R" ] && rm -rf "$R"
    }
    trap cleanup EXIT
    setup_d
    probe_create $X "$IMAGE" >/dev/null 2>&1 && probe_unit_start $X >/dev/null 2>&1 || { result setup "container $X did not start"; return 1; }

    hdr "baseline: the account's own exec -it, not moved (as 2.0 is planned)"
    p=$(acct_session 0 "$(exec_cmd $X 0)"); go 0; sleep 4
    if [ -n "$(held 0)" ]; then result exec_not_moved "works; exec'd process in $(cgof "$(held 0)")"
    else result exec_not_moved "FAILS: $(out 0)"; fi
    pkill -9 -f "sleep 4${TAG}0" 2>/dev/null

    hdr "root moves the account's waiting process into <unit>/ea-podman-exec, then it runs exec -it"
    p=$(acct_session 1 "$(exec_cmd $X 1)")
    result place_1 "$(place "$p" $X ea-podman-exec "t08-acct-$TAG-1.scope")"
    go 1; sleep 4
    if [ -n "$(held 1)" ]; then
        result exec_moved "works; exec'd process in $(cgof "$(held 1)")"
        result exec_moved_client "podman client (moved pid $p) in $(cgof "$p")"
        [ $CGV = 2 ] && result leaf_procs "$(for q in $(cat "$CG$(unit_cg $X)/ea-podman-exec/cgroup.procs"); do ps -o comm= -p $q; done | sort | uniq -c | awk '{print $2"x"$1}' | paste -sd' ' -)"
        result exec_moved_tty "$(out 1)"
    else
        result exec_moved "FAILS: $(out 1)"
    fi

    hdr "unit stop with that session live"
    t0=$(date +%s); systemctl stop "ea-podman-$X.service"; t1=$(date +%s)
    sleep 1
    result stop_with_session "stop took $((t1 - t0))s, unit=$(systemctl show -p ActiveState --value ea-podman-$X.service)/$(systemctl show -p Result --value ea-podman-$X.service), client alive=$(kill -0 "$p" 2>/dev/null && echo yes || echo no), exec'd process alive=$([ -n "$(held 1)" ] && echo yes || echo no), unit cgroup left=$(ls -d $CG/eapodman.slice/eapodman-$UID_.slice/ea-podman-$X.service 2>/dev/null | wc -l)"
    systemctl start "ea-podman-$X.service"
    result restart_after "$(systemctl show -p ActiveState --value ea-podman-$X.service)"

    if [ $CGV = 2 ]; then
        hdr "the account froze <unit>/ea-podman-exec before root's step"
        cg=$(unit_cg $X)
        as_user /bin/sh -c "mkdir $CG$cg/ea-podman-exec && echo 1 >$CG$cg/ea-podman-exec/cgroup.freeze" >/dev/null 2>&1
        result hostile_leaf "account mkdir+freeze: $(cat $CG$cg/ea-podman-exec/cgroup.freeze 2>/dev/null || echo 'not created')"
        p=$(acct_session 2 "$(exec_cmd $X 2)")
        t0=$(date +%s%N); r=$(place "$p" $X ea-podman-exec "t08-acct-$TAG-2.scope"); t1=$(date +%s%N)
        go 2; sleep 4
        result hostile_place "root step: $r in $(( (t1 - t0) / 1000000 )) ms; account's process state=$(awk '/^State/{print $2}' /proc/$p/status 2>/dev/null) frozen=$(awk '/^frozen/{print $2}' $CG$cg/ea-podman-exec/cgroup.events); exec ran=$([ -n "$(held 2)" ] && echo yes || echo no)"
        echo 0 >"$CG$cg/ea-podman-exec/cgroup.freeze"; sleep 3
        result hostile_thaw "after the account thaws it: exec ran=$([ -n "$(held 2)" ] && echo yes || echo no)"
    fi
}

hc_helper() {    # the timer service's ExecStart, as root
    local c=$1 r
    r=$(place $$ "$c" ea-podman-health) || { echo "t0-8 hc-helper: $r" >&2; exit 125; }
    cd "$HOME_" && exec setpriv --reuid="$UID_" --regid="$GID_" --init-groups \
        env -i PATH=/usr/bin:/bin HOME="$HOME_" "${PINNED[@]}" DISABLE_HC_SYSTEMD=true /usr/bin/podman healthcheck run "$c"
}

health() {    # container -> status/failing streak/log entries
    as_user /usr/bin/podman inspect --format '{{json .State}}' "$1" 2>/dev/null | tail -1 | python3 -c '
import json, sys
s = json.load(sys.stdin)
h = s.get("Health") or s.get("Healthcheck") or {}
print("status=%s streak=%s runs=%d" % (h.get("Status") or "(empty)", h.get("FailingStreak"), len(h.get("Log") or [])))'
}

unit_start_hc() {    # the kit's unit plus Environment=DISABLE_HC_SYSTEMD=true (a drop-in), then start
    container_unit "$1" 0 100 143 >"/etc/systemd/system/ea-podman-$1.service"
    mkdir -p "/etc/systemd/system/ea-podman-$1.service.d"
    printf '[Service]\nEnvironment=DISABLE_HC_SYSTEMD=true\n' >"/etc/systemd/system/ea-podman-$1.service.d/t08.conf"
    systemctl daemon-reload
    systemctl start "ea-podman-$1.service"
}

health_mode() {
    local c t0 t1 cid o rc
    local HC=(--health-interval=10s --health-retries=2 --health-timeout=5s)
    cleanup() {
        systemctl stop "t08-health@$H.timer" "t08-health@$F.timer" 2>/dev/null
        systemctl stop "t08-health@$H.service" "t08-health@$F.service" t08-hcslow.service 2>/dev/null
        rm -f /etc/systemd/system/t08-health@.service /etc/systemd/system/t08-health@.timer /etc/systemd/system/t08-hcslow.service
        systemctl daemon-reload; systemctl reset-failed 't08-*' 2>/dev/null
        for c in $P $H $F $S; do probe_unit_rm $c >/dev/null 2>&1; rm -rf "/etc/systemd/system/ea-podman-$c.service.d"; done
        systemctl daemon-reload
    }
    trap cleanup EXIT

    hdr "a container with a healthcheck, from the unit as planned (no user manager)"
    t0=$(date +%s)
    probe_create $P --health-cmd=true "${HC[@]}" "$IMAGE" >/dev/null 2>&1 && probe_unit_start $P >/dev/null 2>&1
    sleep 3
    result planned_unit "unit=$(systemctl show -p ActiveState --value ea-podman-$P.service)/$(systemctl show -p Result --value ea-podman-$P.service) container=$(as_user /usr/bin/podman inspect --format '{{.State.Status}}' $P 2>/dev/null | tail -1)"
    result planned_journal "$(journalctl -u ea-podman-$P.service --since "@$t0" -o cat 2>/dev/null | grep -i -E 'health' | grep -v '^$' | sort -u | tail -2 | cut -c1-240 | paste -sd'|' -)"
    probe_unit_rm $P >/dev/null 2>&1

    hdr "the same with Environment=DISABLE_HC_SYSTEMD=true on the unit"
    t0=$(date +%s)
    probe_create $H --health-cmd=true "${HC[@]}" "$IMAGE" >/dev/null 2>&1 && unit_start_hc $H >/dev/null 2>&1
    probe_create $F --health-cmd=false "${HC[@]}" "$IMAGE" >/dev/null 2>&1 && unit_start_hc $F >/dev/null 2>&1
    probe_create $S --health-cmd='sleep 30' --health-interval=600s --health-timeout=120s "$IMAGE" >/dev/null 2>&1 && unit_start_hc $S >/dev/null 2>&1
    for c in $H $F $S; do [ "$(systemctl show -p ActiveState --value ea-podman-$c.service)" = active ] || { result setup "$c did not start: $(journalctl -u ea-podman-$c.service --since "@$t0" -o cat | grep -i error | tail -1 | cut -c1-200)"; return 1; }; done
    sleep 25
    cid=$(as_user /usr/bin/podman inspect --format '{{.Id}}' $H 2>/dev/null | tail -1)
    result no_scheduler "after 25s with a 10s interval: $H $(health $H); $F $(health $F)"
    result timers "system timers for the container: $(systemctl list-units --all --no-legend --type=timer 2>/dev/null | grep -c "${cid:0:12}")"
    result unit_journal "$(journalctl -u ea-podman-$H.service --since "@$t0" -o cat 2>/dev/null | grep -i -E 'health|timer|systemd-run|bus' | grep -v '^$' | tail -2 | cut -c1-220 | paste -sd'|' -)"

    hdr "podman healthcheck run, by hand"
    o=$(as_user /usr/bin/env DISABLE_HC_SYSTEMD=true /usr/bin/podman healthcheck run $H 2>&1); rc=$?
    result run_from_runner "rc=$rc $(grep -v 'level=warning' <<<"$o" | tail -1 | cut -c1-200)"
    o=$("$SELF" hc-helper $H 2>&1); rc=$?
    result run_from_unit_leaf "rc=$rc $(tail -1 <<<"$o" | cut -c1-200); now $(health $H)"

    hdr "a root timer per container whose service places itself in <unit>/ea-podman-health"
    cat >/etc/systemd/system/t08-health@.service <<EOF
[Unit]
Description=t08 healthcheck for %i
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF hc-helper %i
# podman healthcheck run: 0 healthy, 1 unhealthy
SuccessExitStatus=1
TimeoutStartSec=30
EOF
    cat >/etc/systemd/system/t08-health@.timer <<'EOF'
[Timer]
OnActiveSec=1s
OnUnitActiveSec=10s
AccuracySec=1s
EOF
    cat >/etc/systemd/system/t08-hcslow.service <<EOF
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF hc-helper $S
TimeoutStartSec=5
EOF
    systemctl daemon-reload
    t0=$(date +%s)
    systemctl start "t08-health@$H.timer" "t08-health@$F.timer"
    sleep 35
    for c in $H $F; do
        result "timer_$c" "$(health $c); service Result=$(systemctl show -p Result --value t08-health@$c.service) ExecMainStatus=$(systemctl show -p ExecMainStatus --value t08-health@$c.service)"
    done
    result timer_journal "$(journalctl -u "t08-health@$H.service" -u "t08-health@$F.service" --since "@$t0" -p warning -o cat 2>/dev/null | sort | uniq -c | head -3 | cut -c1-200 | paste -sd'|' -)"

    hdr "a check that outlives the service's TimeoutStartSec=5 (the process left the service's cgroup)"
    t0=$(date +%s); systemctl start t08-hcslow.service 2>/dev/null; t1=$(date +%s)
    sleep 3
    result deadline "start returned after $((t1 - t0))s Result=$(systemctl show -p Result --value t08-hcslow.service); helper podman alive=$(pgrep -f "podman healthcheck run $S" >/dev/null && echo yes || echo no); in-container sleep 30 alive=$(pgrep -f '^sleep 30$' >/dev/null && echo yes || echo no)"
}

ptrace_mode() {
    local W=web.$U.01 m c t pid o rc
    result ptrace_scope "$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo 'no Yama')"
    m=$(systemctl show -p MainPID --value "ea-podman-$W.service")
    c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' $W 2>/dev/null | tail -1)
    for t in "conmon:$m" "container_init:$c"; do
        pid=${t#*:}
        o=$(systemd-run --quiet --scope --slice="user-$UID_.slice" -- setpriv --reuid="$UID_" --regid="$GID_" --init-groups \
            timeout 3 strace -p "$pid" -e trace=none -o /dev/null 2>&1); rc=$?
        result "attach_${t%%:*}" "$([ $rc = 124 ] && echo "attached (pid $pid)" || echo "denied rc=$rc: $(tail -1 <<<"$o")")"
    done
}

case ${1:-bash} in
    bash) bash_mode ;;
    health) health_mode ;;
    ptrace) ptrace_mode ;;
    hc-helper) hc_helper "$2" ;;
esac
