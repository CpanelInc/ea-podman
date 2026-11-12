#!/bin/bash
# P0-5: journald routing of User= unit output; where `podman logs` goes; does
# events_logger="journald" work from a system unit with User=, and can the account read it back?
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
C=web.$U.01
unit=ea-podman-$C.service
systemctl is-active -q "$unit" || { echo "$unit not active; run the kit's setup.sh" >&2; exit 1; }

hdr "journald"
st=$(ls -d /var/log/journal 2>/dev/null && echo persistent || echo volatile)
result journal_storage "$st"
info "journald.conf: $(grep -hE '^(Storage|SplitMode)' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
info "account groups: $(id -nG "$U")"

hdr "unit output in the system journal"
systemctl restart "$unit"; sleep 2
n=$(journalctl -u "$unit" --since "-30s" --no-pager -o cat | grep -c .)
result unit_output_in_journal_u "$([ "$n" -gt 0 ] && echo "yes ($n lines)" || echo no)"
fields=$(journalctl -u "$unit" --since "-30s" -o json --no-pager | python3 -c '
import json,sys
seen=set()
for l in sys.stdin:
    j=json.loads(l); seen.add((j.get("_COMM"),j.get("_UID"),j.get("_SYSTEMD_UNIT"),j.get("_SYSTEMD_USER_UNIT")))
print(" ".join("%s/uid=%s/unit=%s/userunit=%s"%s for s in sorted(seen, key=str)))')
info "senders: $fields"

hdr "podman logs (container stdout) as the account, through the runner"
tag="p05-$$-$(date +%s)"
curl -s -o /dev/null "http://127.0.0.1:8081/$tag"
sleep 2
drv=$(as_user /usr/bin/podman inspect --format '{{.HostConfig.LogConfig.Type}}' "$C" 2>&1)
result log_driver "$drv"
lg=$(as_user /usr/bin/podman logs --since 2m "$C" 2>&1); rc=$?
if grep -q "$tag" <<<"$lg"; then result podman_logs_as_account works
else result podman_logs_as_account "FAILS (rc=$rc): $(tail -2 <<<"$lg" | tr '\n' ' ')"; fi
if [ "$drv" = journald ]; then
    j=$(journalctl --since -2m --no-pager -o cat CONTAINER_NAME="$C" | grep -c "$tag")
    result container_stdout_in_system_journal "$([ "$j" -gt 0 ] && echo yes || echo no)"
    jr=$(as_user /usr/bin/journalctl --since -2m --no-pager -o cat CONTAINER_NAME="$C" 2>&1 | grep -c "$tag")
    result account_can_read_its_container_journal "$([ "$jr" -gt 0 ] && echo yes || echo no)"
else
    lp=$(as_user /usr/bin/podman inspect --format '{{.HostConfig.LogConfig.Path}}' "$C" 2>&1)
    info "log path: $lp"
    # Quoted: an unquoted ~ in the replacement is tilde-expanded to root's home.
    result log_file_location "${lp/#"$HOME_"/'~'}"
fi

hdr "podman logs, forcing --log-driver=journald (the 1.x default where podman uses journald)"
probe_create p05.$U.61 --log-driver=journald "$IMAGE" >/dev/null 2>&1 && probe_unit_start p05.$U.61 >/dev/null 2>&1
sleep 3
lg=$(as_user /usr/bin/podman logs p05.$U.61 2>&1); rc=$?
jcount=$(journalctl --since -2m --no-pager -o cat CONTAINER_NAME=p05.$U.61 | grep -c .)
info "root sees $jcount journal lines for p05.$U.61"
if [ $rc = 0 ] && [ -n "$lg" ]; then result podman_logs_journald_driver_as_account works
else result podman_logs_journald_driver_as_account "FAILS (rc=$rc, journal has $jcount lines): $(tail -2 <<<"$lg" | tr '\n' ' ')"; fi
probe_unit_rm p05.$U.61

hdr "podman events (events_logger=journald) as the account"
systemctl restart "$unit"; sleep 2
ev=$(as_user /usr/bin/podman events --since 1m --stream=false --filter container="$C" 2>&1); rc=$?
info "$(head -3 <<<"$ev")"
if grep -qE "container (start|init)" <<<"$ev"; then result podman_events_as_account works
else result podman_events_as_account "FAILS/empty (rc=$rc): $(tail -1 <<<"$ev")"; fi
jev=$(journalctl --since -1m --no-pager -o cat SYSLOG_IDENTIFIER=podman | grep -c "container start")
result events_in_system_journal "$([ "$jev" -gt 0 ] && echo yes || echo no)"
