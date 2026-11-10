#!/bin/bash
# P0-10: the CLOS-7971 canary, plus the reboot checks for P0-3/P0-4.
#   p0-10.sh pre   plant a user unit in ~/.config/systemd/user (enabled for default.target) that
#                  leaves a marker if it ever runs; record the state; then reboot the host.
#   p0-10.sh post  after the reboot: the canary never ran, no user@<uid>, and the 2.0 layout came
#                  back by itself (anchor tmpfs, XDG dir, units, conmon placement, ports).
# (A stand-in for PLAN.md's test.sh, which isn't in the repo.)
set -uo pipefail
cd "$(dirname "$0")"; PROBE=p0-10; . ./plib.sh
MARK=/var/tmp/clos7971-canary-$UID_
UD=$HOME_/.config/systemd/user
case ${1:-} in
pre)
    # The account writes its own ~/.config; root only builds the text.
    unit=$(cat <<EOF
[Unit]
Description=CLOS-7971 canary (must never run)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "ran as \$(id) at \$(date) caps \$(grep CapEff /proc/self/status) mntns \$(readlink /proc/self/ns/mnt)" >>$MARK'
[Install]
WantedBy=default.target
EOF
)
    user_sh 'mkdir -p "$1/default.target.wants" && printf "%s\n" "$2" >"$1/clos7971-canary.service" &&
        ln -sf ../clos7971-canary.service "$1/default.target.wants/clos7971-canary.service"' "$UD" "$unit" \
        || { result planted "FAILS: the account could not write $UD"; exit 1; }
    rm -f "$MARK"
    result linger "$(ls /var/lib/systemd/linger/ 2>/dev/null | grep -qx "$U" && echo YES || echo no)"
    result planted "$UD/clos7971-canary.service"
    new_tmp /var/tmp/p0-10-reboot-at && date +%s >/var/tmp/p0-10-reboot-at
    ;;
post)
    result booted_after_pre "$([ "$(cut -d. -f1 /proc/uptime)" -lt $(( $(date +%s) - $(cat /var/tmp/p0-10-reboot-at) )) ] && echo yes || echo NO)"
    sleep 20   # let enabled units settle
    result canary_ran "$([ -e "$MARK" ] && echo "YES: $(as_acct init cat "$MARK")" || echo no)"
    result user_manager "$(systemctl is-active "user@$UID_.service")"
    result user_manager_units "$(systemctl list-units --all --no-legend 'user@*' | wc -l)"
    result runtime_carveouts "$(ls /run/systemd/system/user@* 2>/dev/null | wc -l)"
    result anchor "$(systemctl is-active "ea-podman-runtime@$UID_.service")"
    result runtime_tmpfs "$(findmnt -no FSTYPE,OPTIONS "$RUNDIR" | cut -c1-80)"
    result xdg_dir "$(cd "$XDGDIR" 2>/dev/null && find . -mindepth 1 -printf '%p->%l ' || echo missing)"
    for n in web.$U.01 api.$U.02 worker.$U.03; do
        u=ea-podman-$n.service
        m=$(systemctl show -p MainPID --value "$u")
        # From systemd, so it needs --comm; a stopped unit's MainPID is 0.
        if safe_target "$m" --comm conmon; then
            result "unit_${n%%.*}" "$(systemctl is-active "$u") MainPID=$m(conmon) in $(cgroup_of "$m")"
        else
            inconclusive "unit_${n%%.*}" "$(systemctl is-active "$u"), MainPID '$m' is not a conmon process"
        fi
    done
    for p in 8081 8082 8083; do result "port_$p" "$(curl -s -m3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$p/)"; done
    if [ $CGV = 2 ]; then
        result split_after_reboot "$(ls -d "$CG/eapodman.slice/eapodman-$UID_.slice/ea-podman-web.$U.01.service"/libpod-payload-* >/dev/null 2>&1 && echo yes || echo no)"
    fi
    result slice_dropins "$(systemctl show -p MemoryLow -p MemoryMax -p TasksMax --value "eapodman-$UID_.slice" | tr '\n' ' ')"
    user_sh 'rm -f "$1/clos7971-canary.service" "$1/default.target.wants/clos7971-canary.service"' "$UD"
    rm -f "$MARK" /var/tmp/p0-10-reboot-at
    ;;
*) echo "usage: $0 pre|post" >&2; exit 2 ;;
esac
probe_exit
