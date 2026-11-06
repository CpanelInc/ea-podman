#!/bin/bash
# F15 / T0.4: the 1.x comparison. A container under the account's own user@ manager, with the unit
# 1.x generates (`podman generate systemd --restart-policy on-failure` + %container_unit_directives),
# then SIGKILL its conmon: does it recover, and does it still serve?
set -uo pipefail
cd "$(dirname "$0")"; PROBE=f15-1x; . ./plib.sh
C=f15old
command -v cagefsctl >/dev/null && { result skipped "CloudLinux (user@ masked)"; exit 0; }
cleanup() {
    as_user_old /bin/sh -c "systemctl --user disable --now container-$C.service; rm -f ~/.config/systemd/user/container-$C.service; systemctl --user daemon-reload" >/dev/null 2>&1
    as_user_old /usr/bin/podman rm -f $C >/dev/null 2>&1
    old_session_stop
}
trap cleanup EXIT
old_session_start || { result setup "no user@"; exit 1; }
as_user_old /usr/bin/podman create --name $C -p 127.0.0.1:8097:80 "$IMAGE" >/dev/null 2>&1 || { result setup "create failed"; exit 1; }
as_user_old /bin/sh -c "mkdir -p ~/.config/systemd/user && cd ~/.config/systemd/user && podman generate systemd --restart-policy on-failure --name $C --files >/dev/null \
  && sed -i 's/^\[Service\]/[Service]\nRestartSec=5\nSuccessExitStatus=143/; s/^\[Unit\]/[Unit]\nStartLimitIntervalSec=300\nStartLimitBurst=3/' container-$C.service \
  && systemctl --user daemon-reload && systemctl --user start container-$C.service" >/dev/null 2>&1
u=container-$C.service
show() { as_user_old systemctl --user show -p "$1" --value $u 2>/dev/null; }
m=$(show MainPID); c=$(as_user_old /usr/bin/podman inspect --format '{{.State.Pid}}' $C 2>/dev/null | tail -1)
result before "active=$(show ActiveState) conmon=$m in $(cgline() { grep -E '^0::' /proc/$1/cgroup | cut -d: -f3; }; cgline $m) container in $(grep -E '^0::' /proc/$c/cgroup | cut -d: -f3)"
safe_target "$m" conmon || exit 1
kill -9 "$m"
sleep 30
c2=$(as_user_old /usr/bin/podman inspect --format '{{.State.Status}} pid={{.State.Pid}}' $C 2>/dev/null | tail -1)
result after_conmon_kill "unit=$(show ActiveState)/$(show SubState) NRestarts=$(show NRestarts) container=$c2 original_init_alive=$(kill -0 "$c" 2>/dev/null && echo yes || echo no) http=$(curl -s -m3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8097/)"
