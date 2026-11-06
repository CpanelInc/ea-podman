#!/bin/bash
# P0-9: can a non-root account run `systemctl show` on a system unit (CloudLinux, inside CageFS)?
# Also the cage parts of P0-7 that need no cPanel: the caged account's containers run from system
# units (the kit's setup.sh proves that), and what the account sees of them from inside the cage.
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
C=web.$U.01
unit=ea-podman-$C.service
caged=no
command -v cagefsctl >/dev/null && [ "$(cagefsctl --user-status "$U" 2>/dev/null)" = Enabled ] && caged=yes
result account_caged "$caged"
info "shell $(getent passwd "$U" | cut -d: -f7)"

# As the account, through a login (CageFS enters the cage on su -), and through the runner (outside).
in_login()  { su - "$U" -s /bin/bash -c "$1" </dev/null 2>&1; }
in_runner() { as_user /bin/sh -c "$1" 2>&1; }

for how in login runner; do
    run=in_$how
    hdr "as the account, via $how"
    inside=$($run 'test -e /var/.cagefs && echo caged || echo host')
    info "environment: $inside"
    o=$($run "systemctl show -p ActiveState -p MainPID -p User $unit"); rc=$?
    info "$o"
    grep -q '^ActiveState=active' <<<"$o" && result "systemctl_show_$how" "works ($inside)" \
        || result "systemctl_show_$how" "FAILS ($inside, rc=$rc): $(tail -1 <<<"$o")"
    o=$($run "systemctl is-active $unit"); result "systemctl_is_active_$how" "$o"
    o=$($run "systemctl status --no-pager $unit 2>&1 | head -3 | tr '\n' ' '"); info "status: $o"
    o=$($run "ls /run/ea-podman/user/$UID_ >/dev/null 2>&1 && echo yes || echo no"); result "sees_runtime_dir_$how" "$o"
    o=$($run "ls /etc/systemd/system/$unit >/dev/null 2>&1 && echo yes || echo no"); result "sees_unit_file_$how" "$o"
    o=$($run "pgrep -u $U -x conmon >/dev/null && echo yes || echo no"); result "sees_own_conmon_$how" "$o"
    o=$($run "curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8081/ 2>/dev/null || echo none"); result "reaches_container_port_$how" "$o"
    o=$($run "podman ps --format '{{.Names}}' 2>&1 | tail -1")
    result "raw_podman_ps_$how" "$o"
done
