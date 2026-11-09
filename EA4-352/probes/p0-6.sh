#!/bin/bash
# P0-6 (CloudLinux): PAMName=ea-podman with a root-owned /etc/pam.d/ea-podman (pam_lve only).
#   p0-6.sh run   a plain PAMName unit, a PAMName container unit and a PAMName systemd-run --uid
#                 transient: where they land (unit cgroup and/or LVE), whether the LVE limit or
#                 the slice limit applies, and whether stop / restart / RuntimeMaxSec reach them.
#                 Leaves the PAMName container unit enabled for `post` after a reboot.
#   p0-6.sh post  after a reboot: is the PAMName container back, tracked, in the LVE?
#   p0-6.sh clean
set -uo pipefail
cd "$(dirname "$0")"; PROBE=p0-6; . ./plib.sh
command -v lveps >/dev/null || { echo "not CloudLinux" >&2; exit 0; }
C=p06pam.$U.85
PAM=/etc/pam.d/ea-podman
in_lve() { lveps -p -n 2>/dev/null | awk -v p="$1" '{for(i=1;i<=NF;i++) if($i==p) f=1} END{print f?"yes":"no"}'; }
cgs() {    # pid -> its cgroup lines, compact
    if [ $CGV = 2 ]; then grep '^0::' "/proc/$1/cgroup" | cut -d: -f3
    else grep -E ':(name=systemd|memory|pids):' "/proc/$1/cgroup" | sed 's/^[0-9]*://' | tr '\n' ' '; fi
}
clean() {
    systemctl stop p06-plain.service "ea-podman-$C.service" 2>/dev/null
    systemctl disable -q "ea-podman-$C.service" 2>/dev/null
    rm -f /etc/systemd/system/p06-plain.service
    probe_unit_rm "$C" >/dev/null 2>&1
    systemctl daemon-reload; systemctl reset-failed 'p06-*' 2>/dev/null
    pkill -9 -u "$U" -f '^sleep 6[0-9]{4}' 2>/dev/null
    rm -f "$PAM"
}
pam_file() {
    cat >"$PAM" <<'EOF'
# ea-podman: LVE entry only (PLAN.md F3/F18). Never systemd-user.
# systemd's PAMName= runs the account stack too; without a line here it falls through to
# /etc/pam.d/other (pam_deny) and every start fails with status 224/PAM.
account    required    pam_permit.so
session    required    pam_lve.so    500    1
EOF
    chmod 0644 "$PAM"
}

case ${1:-run} in
run)
pam_file
info "LVE for $U: $(lvectl list-user 2>/dev/null | awk -v u="$U" '$1==u' | head -1)"

hdr "1. plain unit with PAMName=ea-podman"
cat >/etc/systemd/system/p06-plain.service <<EOF
[Service]
User=$U
PAMName=ea-podman
Slice=eapodman-$UID_.slice
Delegate=yes
ExecStart=/bin/sleep 61111
EOF
systemctl daemon-reload; systemctl start p06-plain.service; sleep 2
m=$(systemctl show -p MainPID --value p06-plain.service)
result plain_cgroups "$(cgs "$m")"
result plain_in_lve "$(in_lve "$m")"
systemctl stop p06-plain.service; sleep 1
result plain_stop_reaches_it "$(kill -0 "$m" 2>/dev/null && echo "NO: pid $m survives" || echo yes)"

hdr "2. memory: does the LVE limit or the slice limit apply? (slice MemoryMax=100M, LVE PMEM default)"
systemctl set-property --runtime "eapodman-$UID_.slice" MemoryMax=100M
systemctl start p06-plain.service; sleep 1
o=$(systemd-run --quiet --wait --pipe --collect --uid="$UID_" -p PAMName=ea-podman --slice="eapodman-$UID_.slice" \
    python3 -c 'b=bytearray(300*1024*1024); import time; time.sleep(1); print("allocated 300M")' </dev/null 2>&1); rc=$?
result alloc_300M_under_slice_100M "rc=$rc $(tail -1 <<<"$o")"
systemctl stop p06-plain.service
systemctl set-property --runtime "eapodman-$UID_.slice" MemoryMax=2G

hdr "3. container unit with PAMName=ea-podman"
probe_create "$C" -p 127.0.0.1:8096:80 --memory=256m "$IMAGE" >/dev/null 2>&1
if probe_unit_start -s PAMName=ea-podman "$C" 2>/dev/null; then
    m=$(systemctl show -p MainPID --value "ea-podman-$C.service")
    c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' "$C" 2>/dev/null | tail -1)
    result pam_container_starts yes
    result pam_conmon "$(cgs "$m") lve=$(in_lve "$m")"
    result pam_container "$(cgs "$c") lve=$(in_lve "$c")"
    result pam_serves "$(curl -s -m3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8096/)"
    systemctl restart "ea-podman-$C.service"; sleep 2
    m2=$(systemctl show -p MainPID --value "ea-podman-$C.service")
    result pam_restart "$(systemctl is-active "ea-podman-$C.service"); MainPID $m -> $m2 ($(ps -o comm= -p "$m2")); old conmon $(kill -0 "$m" 2>/dev/null && echo SURVIVES || echo gone)"
    systemctl stop "ea-podman-$C.service"; sleep 1
    c2=$(pgrep -u "$U" -f nginx | head -1)
    result pam_stop "$(systemctl is-active "ea-podman-$C.service"); Result=$(systemctl show -p Result --value "ea-podman-$C.service"); conmon $(kill -0 "$m2" 2>/dev/null && echo SURVIVES || echo gone)"
    systemctl enable -q "ea-podman-$C.service"; systemctl start "ea-podman-$C.service"
else
    result pam_container_starts "FAILS: $(journalctl -u "ea-podman-$C.service" -n 30 --no-pager -o cat | grep -m1 -i error | cut -c1-200)"
fi

hdr "4. systemd-run --uid transient with PAMName (the runner)"
t0=$(date +%s)
systemd-run --quiet --wait --pipe --collect --uid="$UID_" -p PAMName=ea-podman --slice="eapodman-$UID_.slice" \
    -p RuntimeMaxSec=5 -p KillMode=control-group sh -c 'sleep 62222 & sleep 63333' </dev/null >/dev/null 2>&1; rc=$?
t=$(( $(date +%s) - t0 )); sleep 1
left=$(pgrep -u "$U" -f '^sleep 6(2222|3333)' | tr '\n' ' ')
result runner_pam_runtimemaxsec "rc=$rc after ${t}s; leftovers: ${left:-none}"
p=$(systemd-run --quiet --wait --pipe --collect --uid="$UID_" -p PAMName=ea-podman --slice="eapodman-$UID_.slice" sh -c 'cat /proc/self/cgroup' </dev/null 2>&1 | grep -E '^0::|name=systemd|:memory:' | tr '\n' ' ')
result runner_pam_cgroup "$p"
pkill -9 -u "$U" -f '^sleep 6(2222|3333)' 2>/dev/null
;;
post)
    sleep 15
    u=ea-podman-$C.service
    m=$(systemctl show -p MainPID --value "$u")
    c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' "$C" 2>/dev/null | tail -1)
    result post_reboot_unit "$(systemctl is-active "$u") MainPID=$m($(ps -o comm= -p "$m" 2>/dev/null))"
    result post_reboot_conmon "$(cgs "$m") lve=$(in_lve "$m")"
    result post_reboot_container "$(cgs "$c") lve=$(in_lve "$c")"
    systemctl stop "$u"; sleep 1
    result post_reboot_stop "$(systemctl is-active "$u"); conmon $(kill -0 "$m" 2>/dev/null && echo SURVIVES || echo gone)"
    clean
    ;;
clean) clean ;;
esac
