#!/bin/bash
# EA4-392: the two SELinux results behind PLAN.md's P0-11 "SELinux" entry and F19's unlink denial.
#   matrix   which stdout/stderr of `systemd-run --pipe` PID 1 may not use, whether PID 1 is still
#            on the system bus afterwards, and the denial. It takes PID 1 off the bus on purpose
#            (dbus-broker hosts) and puts it back with `systemctl daemon-reexec` after each row.
#            It also sets SELinux permissive for three calls, then enforcing again.
#   unlink   PID 1 unlinking a unit's PIDFile= at a restart, a stop and a SIGKILL of conmon: with
#            the kit's unit (its first ExecStopPost= removes the file), and with that line taken
#            out by a drop-in. The second pass must log the denial, or the first proves nothing.
# Both need SELinux enforcing; anywhere else they say so and exit 0.
# Run it with its output on a pipe or a file under /var/log or /run: every runner call in plib.sh
# and lib.sh makes its own pipes, but the point of `matrix` is what happens when a call doesn't.
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
MODE=${1:?usage: $0 matrix|unlink}
PROBE=ea4-392-$MODE

if ! selinux_on || [ "$(getenforce)" != Enforcing ]; then
    result selinux "$(getenforce 2>/dev/null || echo absent): not enforcing, nothing to measure"
    probe_exit
fi
BUS=dbus-daemon; systemctl is-active -q dbus-broker.service && BUS=dbus-broker
info "selinux=Enforcing bus=$BUS policy=$(rpm -q selinux-policy 2>/dev/null) uptime=$(cut -d. -f1 /proc/uptime)s"

# "yes" when PID 1 owns org.freedesktop.systemd1 on the system bus.
pid1_on_bus() {
    [ "$(busctl --system --no-pager list 2>/dev/null | awk '$1 == "org.freedesktop.systemd1" {print $2}')" = 1 ] \
        && echo yes || echo NO
}
# root's systemctl reaches PID 1 over /run/systemd/private, so this works with PID 1 off the bus.
back_on_bus() {
    local i
    systemctl daemon-reexec
    for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(pid1_on_bus)" = yes ] && return 0; sleep 1; done
    return 1
}
# The denials since <epoch>, one summary line per distinct denial:
#   <count> denied { <perms> } comm=<comm> <target type> permissive=<0|1>
denials() {
    sleep 2    # auditd writes its log a moment after the event
    avc_since "$1" || { echo "  could not search: $AVC"; return 1; }
    [ -n "$AVC" ] || return 0
    sed -nE 's/.*denied +\{ ([a-z_ ]+) \}.* comm="?([^ "]+)"?.* tcontext=[^: ]+:[^: ]+:([^: ]+)[^ ]*.* permissive=([01]).*/denied { \1 } comm=\2 \3 permissive=\4/p' <<<"$AVC" \
        | sort | uniq -c | sed 's/^ *//'
}

# ------------------------------------------------------------------------------------------ matrix
matrix() {
    files=()
    TTYCMD=
    cleanup() {
        [ "$(getenforce)" = Enforcing ] || setenforce 1
        [ "$(pid1_on_bus)" = yes ] || back_on_bus || echo "PID 1 IS STILL OFF THE SYSTEM BUS: run systemctl daemon-reexec" >&2
        rm -f "${files[@]}"
    }
    trap cleanup EXIT
    [ "$(pid1_on_bus)" = yes ] || { inconclusive start "PID 1 is not on the system bus before the first call"; probe_exit; }

    # The call PLAN.md gives as the bare reproduction. No slice, reload or set-property.
    CALL=(systemd-run --quiet "--uid=$UID_" "--gid=$GID_" --pipe --wait --collect /bin/true)
    info "call: ${CALL[*]} </dev/null, with stdout and stderr as below"
    # root creates each file (mktemp: O_EXCL), so the label is the directory's default for root.
    newfile() { f=$(mktemp "$1/ea4-392.XXXXXX") && files+=("$f"); }

    FAILED=() PASSED=() OFFBUS=() HELD=
    # row <key> <label> <how> [file]: one call, then where PID 1 is and what was denied.
    #   how: null | pipe | tty | trunc | append | out (stdout the file, stderr a pipe) | err
    row() {
        local key=$1 label=$2 how=$3 file=${4:-} t0 rc msg= ctx=- on den mode o rp pipe held=
        mode=$(getenforce)
        sleep 1; t0=$(date +%s)    # audit times are whole seconds: keep the last row's out
        case $how in
        null)   "${CALL[@]}" </dev/null >/dev/null 2>&1; rc=$?; ctx=$(stat -c %C /dev/null) ;;
        pipe)   msg=$("${CALL[@]}" </dev/null 2>&1); rc=$? ;;
        tty)    # script gives the call a pty as stdout and stderr; its stdin stays /dev/null.
                msg=$(script -qec "${CALL[*]} </dev/null" /dev/null </dev/null 2>&1); rc=$?
                ctx=$(script -qec 'stat -c %C "$(tty)"' /dev/null </dev/null 2>/dev/null | tr -d '\r\n') ;;
        trunc)  "${CALL[@]}" </dev/null >"$file" 2>&1; rc=$? ;;
        append) "${CALL[@]}" </dev/null >>"$file" 2>&1; rc=$? ;;
        out)    msg=$("${CALL[@]}" </dev/null 2>&1 >"$file"); rc=$? ;;
        err)    # stdout is a pipe made here and never waited on for EOF: on EL8 PID 1 keeps the
                # write end it was handed (it got fd 1, then was denied fd 2), so a reader hangs.
                exec {o}> >(exec cat >/dev/null); rp=$!
                pipe=$(readlink "/proc/$$/fd/$o")
                "${CALL[@]}" </dev/null >&"$o" 2>"$file" {o}>&-; rc=$?
                exec {o}>&-
                sleep 1
                if ls -l /proc/1/fd 2>/dev/null | grep -qF -- "$pipe"; then held=yes; else held=no; fi
                kill "$rp" 2>/dev/null ;;
        esac
        if [ -n "$file" ]; then ctx=$(stat -c %C "$file"); msg+=$(head -c 300 "$file" 2>/dev/null); fi
        on=$(pid1_on_bus)
        den=$(denials "$t0" | tr '\n' ';')
        printf '%-10s %-34s %-26s rc=%s pid1_on_bus=%s %s\n' "$mode" "$label" "$(cut -d: -f3 <<<"$ctx")" "$rc" "$on" "$(tr -d '\r' <<<"$msg" | tr '\n' ' ')"
        [ -z "$den" ] || printf '%-10s   denials: %s\n' "" "$den"
        if [ -n "$held" ]; then
            printf '%-10s   PID 1 still holds the stdout pipe after the call: %s\n' "" "$held"
            HELD=$held
        fi
        if [ "$mode" = Enforcing ]; then
            if [ "$rc" = 0 ]; then PASSED+=("$key"); else FAILED+=("$key"); fi
            [ "$on" = yes ] || OFFBUS+=("$key")
        fi
        # A re-exec also makes PID 1 drop a pipe it kept.
        if [ "$on" != yes ] || [ "$held" = yes ]; then
            back_on_bus || { inconclusive "$key" "daemon-reexec did not put PID 1 back on the bus; stopping"; probe_exit; }
        fi
    }

    hdr "destinations (stdout and stderr both, unless the row says otherwise)"
    row null "/dev/null" null
    row pipe "a pipe" pipe
    row tty "a tty (pty from script)" tty
    newfile /tmp && row tmp "> /tmp file" trunc "$f"
    newfile /tmp && row tmp_append ">> /tmp file (append)" append "$f"
    newfile /root && row root "> /root file" trunc "$f"
    newfile /root && row root_append ">> /root file (append)" append "$f"
    newfile /var/tmp && row vartmp "> /var/tmp file" trunc "$f"
    # The account's home is a path it controls; this is a throwaway test account on a test VM.
    newfile "$HOME_" && row home "> $HOME_ file" trunc "$f"
    newfile /run && row run "> /run file" trunc "$f"
    newfile /var/log && row varlog "> /var/log file" trunc "$f"
    newfile /tmp && row tmp_stdout_only "> /tmp file, stdout only" out "$f"
    newfile /tmp && row tmp_stderr_only "> /tmp file, stderr only" err "$f"
    result bus "$BUS"
    result enforcing_pass "${PASSED[*]:-none}"
    result enforcing_fail "${FAILED[*]:-none}"
    result pid1_off_bus_after "${OFFBUS[*]:-none}"
    result pid1_keeps_stdout_pipe_when_stderr_denied "${HELD:-not measured}"

    hdr "the same with SELinux permissive, then enforcing again"
    setenforce 0
    newfile /tmp && row p_tmp "> /tmp file" trunc "$f"
    newfile /root && row p_root "> /root file" trunc "$f"
    setenforce 1
    local before=${#FAILED[@]}
    newfile /tmp && row tmp_again "> /tmp file" trunc "$f"
    result permissive_then_enforcing "$([ ${#FAILED[@]} -gt "$before" ] && echo "fails again once enforcing" || echo "passes once enforcing again")"

    hdr "afterwards"
    result pid1_on_bus_at_end "$(pid1_on_bus)"
    result selinux_at_end "$(getenforce)"
    if [ -d /var/lib/setroubleshoot ] || command -v sealert >/dev/null; then
        sleep 10    # setroubleshootd reports some seconds after the denial
        info "journalctl -t setroubleshoot, since this probe started:"
        journalctl -q --no-pager -o cat -t setroubleshoot --since "@$START" | grep -o 'SELinux is preventing.*' \
            | sed -E 's/ea4-392\.[A-Za-z0-9]+/ea4-392.XXXXXX/' | sort | uniq -c | sed 's/^/    /'
    else
        info "setroubleshoot is not installed"
    fi
}

# ------------------------------------------------------------------------------------------ unlink
unlink_probe() {
    C=ea4392.$U.88
    unit=ea-podman-$C.service; pidfile=$(conmon_pidfile "$C")
    dropin=/run/systemd/system/$unit.d/50-no-rm.conf
    cleanup() {
        rm -f "$dropin"; rmdir "${dropin%/*}" 2>/dev/null
        probe_unit_rm "$C" >/dev/null 2>&1
    }
    trap cleanup EXIT
    prop() { systemctl show -p "$1" --value "$unit"; }
    # "present" when the PID file is still there (lstat only: the account owns the directory).
    pidfile_state() { if [ -e "$pidfile" ] || [ -L "$pidfile" ]; then echo present; else echo gone; fi; }
    # The unlink denials on this container's PID file since <epoch>, as a count.
    unlink_denials() {
        sleep 2
        local n
        avc_since "$1" || { echo "?"; return 1; }
        n=$(grep -F "$C.conmon.pid" <<<"$AVC" | grep -c 'denied  *{ unlink }')    # grep -c exits 1 on 0
        echo "$n"
    }
    # pass <key> <description>: a restart, a stop, and a SIGKILL of conmon, each with its own count.
    pass() {
        local key=$1 what=$2 t0 n main nr i total=0 bad=
        hdr "$what"
        info "ExecStopPost: $(prop ExecStopPost | grep -oE 'argv\[\]=[^;]+' | tr '\n' '|')"
        systemctl reset-failed "$unit" 2>/dev/null
        systemctl start "$unit" || { inconclusive "$key" "the unit did not start"; return; }

        sleep 1; t0=$(date +%s)
        systemctl restart "$unit"; n=$(unlink_denials "$t0") || bad=1
        result "$key.restart" "unlink_denials=$n"; total=$((total + ${n/\?/0}))

        sleep 1; t0=$(date +%s)
        systemctl stop "$unit"; n=$(unlink_denials "$t0") || bad=1
        result "$key.stop" "unlink_denials=$n pidfile_after=$(pidfile_state)"; total=$((total + ${n/\?/0}))

        systemctl reset-failed "$unit" 2>/dev/null
        systemctl start "$unit" || { inconclusive "$key.sigkill_conmon" "the unit did not start again"; return; }
        main=$(prop MainPID); nr=$(prop NRestarts)
        if safe_target "$main" --comm conmon --cgroup "/$unit"; then
            sleep 1; t0=$(date +%s)
            kill -KILL "$main"
            # Until systemd has torn the unit down and tried again (RestartSec=5), or given up.
            for i in $(seq 30); do
                [ "$(prop NRestarts)" -gt "$nr" ] || [ "$(prop ActiveState)" = failed ] && break
                sleep 1
            done
            n=$(unlink_denials "$t0") || bad=1
            result "$key.sigkill_conmon" "unlink_denials=$n (unit now $(prop ActiveState), NRestarts $nr -> $(prop NRestarts))"
            total=$((total + ${n/\?/0}))
        else
            inconclusive "$key.sigkill_conmon" "MainPID $main is not a conmon inside the unit"
        fi
        systemctl stop "$unit" 2>/dev/null
        [ -z "$bad" ] || { inconclusive "$key" "the audit log could not be searched"; return; }
        TOTAL[$key]=$total
    }
    declare -A TOTAL
    START2=$(date +%s)

    probe_create "$C" --memory=64m "$IMAGE" >/dev/null 2>&1 && probe_unit_write "$C" \
        || { inconclusive create "could not create $C or write its unit"; probe_exit; }
    pass with_rm_line "1. the kit's unit: its first ExecStopPost= removes the PID file as the account"

    # F15: a container whose conmon was SIGKILLed may not start again; recreate it for pass 2.
    probe_unit_rm "$C" >/dev/null 2>&1
    probe_create "$C" --memory=64m "$IMAGE" >/dev/null 2>&1 && probe_unit_write "$C" \
        || { inconclusive create2 "could not recreate $C or write its unit"; probe_exit; }
    # The same unit without that line: an empty ExecStopPost= clears the list, then the podman stop.
    install -d -m 0755 "${dropin%/*}"
    printf '[Service]\nExecStopPost=\nExecStopPost=%s --cgroup-manager=cgroupfs stop -t 10 %s\n' "${PODMAN[*]}" "$C" >"$dropin"
    systemctl daemon-reload
    pass without_rm_line "2. the same unit without that line (drop-in): PID 1 unlinks the file itself"

    hdr "verdict"
    if [ -n "${TOTAL[with_rm_line]+x}" ] && [ -n "${TOTAL[without_rm_line]+x}" ]; then
        result denied_without_rm_line "$([ "${TOTAL[without_rm_line]}" -gt 0 ] && echo "yes (${TOTAL[without_rm_line]})" || echo "NO: this host logs no unlink denial at all")"
        result denied_with_rm_line "$([ "${TOTAL[with_rm_line]}" = 0 ] && echo no || echo "YES (${TOTAL[with_rm_line]})")"
    fi
    avc_since "$START2" && info "the denial: $(grep -F "$C.conmon.pid" <<<"$AVC" | grep -m1 -o 'avc: .*')"
    if [ -d /var/lib/setroubleshoot ] || command -v sealert >/dev/null; then
        sleep 10
        info "journalctl -t setroubleshoot, since this probe started:"
        journalctl -q --no-pager -o cat -t setroubleshoot --since "@$START2" | grep -o 'SELinux is preventing.*' \
            | sort | uniq -c | sed 's/^/    /'
        result setroubleshoot_reports_unlink "$(journalctl -q --no-pager -o cat -t setroubleshoot --since "@$START2" | grep -c 'preventing.*unlink')"
    else
        info "setroubleshoot is not installed"
        result setroubleshoot_reports_unlink "n/a (not installed)"
    fi
}

START=$(date +%s)
case $MODE in
matrix) matrix ;;
unlink) unlink_probe ;;
*) echo "usage: $0 matrix|unlink" >&2; exit 2 ;;
esac
probe_exit
