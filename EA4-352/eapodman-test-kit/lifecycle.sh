#!/bin/bash
# Failure handling of the container units ./setup.sh creates. Run as root.
#   1. conmon (the unit's MainPID) is SIGKILLed: Restart= brings the container back.
#   2. the container's own init is SIGKILLed: same.
#   3. the account writes a root process's PID into the real conmon.pid, then conmon dies:
#      systemd must not adopt or kill that process.
#   4. P0-3 / invariant 19, with a unit of the same shape whose ExecStart writes a chosen PID
#      into an account-owned PID file: PID 1 and a root process are refused, and stopping the
#      unit kills neither; a PID inside the unit's cgroup is accepted (control case).
# Run it last, after ./loadtest.sh: tests 1 and 3 leave web and worker down until recreated (F15).
# Exits non-zero if a check fails. Usage: ./lifecycle.sh <cpuser>
set -uo pipefail
U=${1:?usage: $0 <cpuser>}
cd "$(dirname "$0")"
. ./lib.sh
declare -A PORT=( ["web.$U.01"]=8081 ["api.$U.02"]=8082 ["worker.$U.03"]=8083 )
for n in "${!PORT[@]}"; do
    systemctl is-active -q "ea-podman-$n.service" || { echo "ea-podman-$n.service is not running; run ./setup.sh $U" >&2; exit 1; }
done

prop()   { systemctl show -p "$2" --value "ea-podman-$1.service"; }
comm()   { ps -o comm= -p "$1" 2>/dev/null; }
alive()  { kill -0 "$1" 2>/dev/null; }
# Wait for container $1 to be back: active, a new conmon as MainPID, NRestarts past $3, port answering.
# Like check, for a failure PLAN.md already records as F15: still a FAIL, but counted as known
# only when the unit's journal since the cursor carries F15's signature (PLAN.md F15 evidence).
# Any other failure is new, and its journal is printed in full. A pass means F15 no longer reproduces.
F15_SIGNATURE="Failed with result 'signal'|container state improper|[Ss]tart request repeated too quickly|start-limit"
KNOWN=0
f15_check() {    # cursor, unit, description, then the command
    local t=$1 unit=$2 what=$3; shift 3
    if "$@"; then
        echo "  PASS  $what (known F15 no longer reproduces; update PLAN.md)"
    elif journalctl -q --no-pager -o cat --after-cursor "$t" -u "$unit" | grep -qE "$F15_SIGNATURE"; then
        echo "  FAIL  $what (known: F15, see PLAN.md)"
        FAILS=$((FAILS + 1)); KNOWN=$((KNOWN + 1))
    else
        echo "  FAIL  $what (NEW: no F15 signature in the journal)"
        journalctl -q --no-pager -o cat --after-cursor "$t" -u "$unit" | sed 's/^/    journal: /'
        FAILS=$((FAILS + 1))
    fi
}
recovered() {
    local n=$1 old_main=$2 old_nr=$3 i main
    for i in $(seq 60); do
        main=$(prop "$n" MainPID)
        if systemctl is-active -q "ea-podman-$n.service" && [ "$main" != "$old_main" ] && [ "$(comm "$main")" = conmon ] \
            && [ "$(prop "$n" NRestarts)" -gt "$old_nr" ] && curl -fsS -o /dev/null "http://127.0.0.1:${PORT[$n]}/"; then
            echo "  back after ${i}s: MainPID $old_main -> $main, NRestarts $old_nr -> $(prop "$n" NRestarts)"
            return 0
        fi
        sleep 1
    done
    echo "  not back after 60s: $(systemctl is-active "ea-podman-$n.service"), MainPID $main, NRestarts $(prop "$n" NRestarts)"
    return 1
}
cursor()        { journalctl -q -n0 --show-cursor | sed -n 's/^-- cursor: //p'; }
journal_since() { journalctl -q --no-pager -o cat --after-cursor "$1" -u "$2" | grep -iE 'pid|refus|fail|error' | sed 's/^/    journal: /'; }

# A root process for the account to point PID files at. Nothing real is put at risk.
setsid sleep 900 </dev/null >/dev/null 2>&1 &
DECOY=$!
disown "$DECOY"    # so killing it in cleanup prints no "Terminated" job notice
TEST_UNIT=eapodman-test-pidfile-$UID_.service
cleanup() {
    systemctl stop "$TEST_UNIT" 2>/dev/null
    rm -f "/run/systemd/system/$TEST_UNIT" "$ETC/pidfile-writer" "$RUNDIR/test.pid"
    systemctl daemon-reload
    systemctl reset-failed "$TEST_UNIT" 2>/dev/null
    kill "$DECOY" 2>/dev/null
    local n down=()
    for n in "${!PORT[@]}"; do
        systemctl reset-failed "ea-podman-$n.service" 2>/dev/null
        systemctl start "ea-podman-$n.service" 2>/dev/null || down+=("$n")
    done
    if [ ${#down[@]} -gt 0 ]; then
        echo "cleanup: ${down[*]} can't start (F15); next run ./teardown.sh $U, then ./setup.sh $U to test again"
    fi
}
trap cleanup EXIT

echo "== 1. SIGKILL conmon of worker.$U.03"
n=worker.$U.03; main=$(prop "$n" MainPID); nr=$(prop "$n" NRestarts); t=$(cursor)
if safe_target "$main" conmon "/ea-podman-$n.service"; then
    kill -KILL "$main"
    f15_check "$t" "ea-podman-$n.service" "worker comes back through Restart=" recovered "$n" "$main" "$nr"
    journal_since "$t" "ea-podman-$n.service"
else
    check "worker's MainPID is a conmon inside its unit (test 1 not run)" false
fi

echo; echo "== 2. SIGKILL the container's init in api.$U.02"
n=api.$U.02; main=$(prop "$n" MainPID); nr=$(prop "$n" NRestarts); t=$(cursor)
init=$(as_user /usr/bin/podman container inspect --format '{{.State.Pid}}' "$n")
echo "  container init PID $init ($(comm "$init"))"
# The init's comm depends on the image, so check the PID is in the container's payload cgroup instead.
if safe_target "$init" "$(comm "$init")" "/ea-podman-$n.service/libpod-payload-"; then
    kill -KILL "$init"
    check "api comes back through Restart=" recovered "$n" "$main" "$nr"
    journal_since "$t" "ea-podman-$n.service"
else
    check "api's container init is a process in its payload cgroup (test 2 not run)" false
fi

echo; echo "== 3. account writes root PID $DECOY into web.$U.01's conmon.pid, then conmon dies"
n=web.$U.01; main=$(prop "$n" MainPID); nr=$(prop "$n" NRestarts); t=$(cursor)
pidfile=$(prop "$n" PIDFile)
# The test only means something if the hostile PID really is in the file when conmon dies.
if ! safe_target "$main" conmon "/ea-podman-$n.service"; then
    check "web's MainPID is a conmon inside its unit (test 3 not run)" false
elif ! as_user /bin/sh -c 'echo "$1" >"$2"' _ "$DECOY" "$pidfile" || [ "$(cat "$pidfile" 2>/dev/null)" != "$DECOY" ]; then
    check "the account wrote $DECOY into $pidfile (test 3 not run; holds '$(cat "$pidfile" 2>/dev/null)')" false
else
    echo "  conmon.pid now holds $(cat "$pidfile")"
    kill -KILL "$main"
    f15_check "$t" "ea-podman-$n.service" "web comes back through Restart=" recovered "$n" "$main" "$nr"
    check "the root process is still alive" alive "$DECOY"
    check "web's MainPID is not the root process" test "$(prop "$n" MainPID)" != "$DECOY"
    journal_since "$t" "ea-podman-$n.service"
fi

echo; echo "== 4. PID file refusal (P0-3, invariant 19) with a same-shape unit"
# Runs as the account: leaves a child in the unit's cgroup, then writes the chosen PID.
cat >"$ETC/pidfile-writer" <<'EOF'
#!/bin/sh
sleep 300 </dev/null >/dev/null 2>&1 &
t=$1; [ "$t" = self ] && t=$!
echo "$t" >"$2"
EOF
chmod 0755 "$ETC/pidfile-writer"
pid_case() {    # label, target (a PID or "self"), expect accept|refuse
    local label=$1 target=$2 expect=$3 rc main written t
    rm -f "$RUNDIR/test.pid"
    cat >"/run/systemd/system/$TEST_UNIT" <<UNIT
[Service]
Type=forking
User=$U
Group=$(id -gn "$U")
Slice=eapodman-$UID_.slice
PIDFile=$RUNDIR/test.pid
ExecStart=$ETC/pidfile-writer $target $RUNDIR/test.pid
TimeoutStartSec=15
TimeoutStopSec=5
UNIT
    systemctl daemon-reload
    systemctl reset-failed "$TEST_UNIT" 2>/dev/null
    t=$(cursor)
    systemctl start "$TEST_UNIT" 2>/dev/null; rc=$?
    main=$(systemctl show -p MainPID --value "$TEST_UNIT")
    written=$(cat "$RUNDIR/test.pid" 2>/dev/null)
    echo "  $label: start exit $rc, Result=$(systemctl show -p Result --value "$TEST_UNIT"), MainPID $main, PID file $written"
    journal_since "$t" "$TEST_UNIT"
    if [ "$expect" = refuse ]; then
        # Without the hostile PID in the file, or without systemd's own refusal message, a failed
        # start proves nothing (a unit typo or a missing writer also fails it).
        check "$label: the PID file holds $target" test "$written" = "$target"
        check "$label: start is refused" test "$rc" != 0
        check "$label: systemd logged the refusal" bash -c \
            'journalctl -q --no-pager -o cat --after-cursor "$1" -u "$2" | grep -q "Refusing\|refusing"' _ "$t" "$TEST_UNIT"
        check "$label: MainPID is not $target" test "$main" != "$target"
        systemctl stop "$TEST_UNIT" 2>/dev/null
        check "$label: PID 1 is still systemd" test "$(comm 1)" = systemd
        check "$label: root process $DECOY survives the stop" alive "$DECOY"
    else
        check "$label: start succeeds" test "$rc" = 0
        check "$label: the PID file holds a PID" bash -c 'case $1 in ""|0|*[!0-9]*) exit 1;; esac' _ "$written"
        check "$label: MainPID is the PID from the file" test "$main" = "$written"
        systemctl stop "$TEST_UNIT"
        check "$label: stopping the unit kills it" bash -c "! kill -0 $written 2>/dev/null"
    fi
}
pid_case "PID 1" 1 refuse
pid_case "root process" "$DECOY" refuse
pid_case "control, own child" self accept

echo
if [ "$FAILS" = 0 ]; then echo "all checks passed"
elif [ "$FAILS" = "$KNOWN" ]; then echo "$FAILS check(s) failed, all known (F15)"; exit 1
else echo "$FAILS check(s) failed, $KNOWN of them known (F15); the rest are new"; exit 1; fi
