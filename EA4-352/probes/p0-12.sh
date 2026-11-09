#!/bin/bash
# P0-12: BPF-LSM namespace boundary (F11). Does the kernel have the userns_create LSM hook and
# bpf in its LSM list? Load a test-only program that denies userns creation to non-root tasks
# outside eapodman.slice, then check that the 2.0 paths still work and the account's own shell
# and cron-like jobs are denied. The program is detached on exit (it is not persistent anyway).
# Product paths (install, upgrade, migration, plugin builds, backup/restore, ea-podman bash) need
# ea-podman 2.0 itself; their stand-ins here are noted per check.
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
PIN=/sys/fs/bpf/eapodman_userns_guard
B=$(mktemp -d /var/tmp/p012-build.XXXXXX) || exit 1
detach() { rm -rf "$PIN"; }
trap 'detach; probe_unit_rm p012.$U.86 >/dev/null 2>&1; rm -rf "$B"' EXIT

hook=$(grep -c ' bpf_lsm_userns_create$' /proc/kallsyms)
lsm=$(cat /sys/kernel/security/lsm)
result userns_create_hook "$([ "$hook" -gt 0 ] && echo yes || echo no)"
result bpf_in_lsm_list "$(grep -qw bpf <<<"${lsm//,/ }" && echo yes || echo "no ($lsm)")"
[ "$hook" -gt 0 ] && grep -qw bpf <<<"${lsm//,/ }" || { result supported no; exit 0; }
command -v clang >/dev/null && command -v bpftool >/dev/null || { result supported "unknown (no clang/bpftool)"; exit 0; }

hdr "build and load"
cp p0-12/userns_guard.bpf.c "$B/"
bpftool btf dump file /sys/kernel/btf/vmlinux format c >"$B/vmlinux.h"
cgid=$(stat -c %i "$CG/eapodman.slice")
info "eapodman.slice cgroup id $cgid"
clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -DALLOWED_CG="${cgid}ULL" -I"$B" -c "$B/userns_guard.bpf.c" -o "$B/userns_guard.bpf.o" 2>&1 | tail -3
detach
o=$(bpftool prog loadall "$B/userns_guard.bpf.o" "$PIN" autoattach 2>&1); rc=$?
result load_and_attach "$([ $rc = 0 ] && echo works || echo "FAILS: $(tail -2 <<<"$o" | tr '\n' ' ')")"
[ $rc = 0 ] || exit 0
counters() {
    local id; id=$(bpftool map show 2>/dev/null | awk '/\.bss/ && /userns/ {sub(":","",$1); print $1}' | tail -1)
    [ -n "$id" ] && bpftool map dump id "$id" 2>/dev/null | tr -d '\n ' | grep -o '"allowed":[0-9]*,"denied":[0-9]*'
}
info "counters: $(counters)"

ok() { [ "$1" = 0 ] && echo works || echo "FAILS: $2"; }
denied() {
    if [ "$1" = 0 ]; then echo "NOT denied"
    elif grep -qiE 'not permitted|permission denied|EPERM' <<<"$2"; then echo "denied ($(grep -m1 -iE 'not permitted|permission denied' <<<"$2" | cut -c1-100))"
    else echo "n/a: failed for another reason ($(tail -1 <<<"$2" | cut -c1-100))"; fi
}

hdr "must work (inside eapodman.slice)"
o=$(as_user /usr/bin/podman unshare /bin/true 2>&1); result runner_podman_unshare "$(ok $? "$o")"
for n in web.$U.01 api.$U.02 worker.$U.03; do systemctl restart "ea-podman-$n.service"; done
sleep 3; o=$(for p in 8081 8082 8083; do curl -s -m3 -o /dev/null -w '%{http_code} ' http://127.0.0.1:$p/; done)
result units_restart "$o"
# pause.pid is account-writable: signal it as root only if it is a real PID owned by the account.
pp=$(cat "$RUNDIR/libpod/tmp/pause.pid" 2>/dev/null)
if [[ "$pp" =~ ^[1-9][0-9]*$ ]] && [ "$pp" -gt 1 ] && [ "$(stat -c %u "/proc/$pp" 2>/dev/null)" = "$UID_" ]; then
    kill -9 "$pp"; sleep 1
else
    info "pause.pid '$pp' is not a process of $U; not killing it"
fi
for n in web.$U.01 api.$U.02 worker.$U.03; do systemctl stop "ea-podman-$n.service"; done
systemctl restart "ea-podman-runtime@$UID_.service"; rc=$?
for n in web.$U.01 api.$U.02 worker.$U.03; do systemctl start "ea-podman-$n.service"; done
sleep 3; o=$(for p in 8081 8082 8083; do curl -s -m3 -o /dev/null -w '%{http_code} ' http://127.0.0.1:$p/; done)
result anchor_restart_after_pause_killed "anchor rc=$rc; ports $o"
o=$(probe_create p012.$U.86 "$IMAGE" 2>&1 && probe_unit_start p012.$U.86 2>&1); result install_standin_create_and_start "$(ok $? "$o")"
probe_unit_rm p012.$U.86 >/dev/null 2>&1
ctx=$HOME_/.p012-build; user_build_ctx "$ctx" 'echo built'
o=$(as_user_deleg /usr/bin/podman build -t localhost/p012:latest "$ctx" 2>&1); result plugin_build_standin "$(ok $? "$(tail -1 <<<"$o")")"
as_user /usr/bin/podman rmi -f localhost/p012:latest >/dev/null 2>&1; user_rm "$ctx"
o=$(as_user_deleg /usr/bin/podman run --rm "$IMAGE" sh -c 'unshare -U true && echo nested-ok' 2>&1); result nested_userns_inside_container "$(tail -1 <<<"$o")"

hdr "must be denied (outside eapodman.slice)"
o=$(su - "$U" -s /bin/bash -c 'unshare -U true' </dev/null 2>&1); result ssh_shell_unshare "$(denied $? "$o")"
o=$(su - "$U" -s /bin/bash -c "cd; mkdir -p -m 0700 /tmp/p012-\$(id -u); XDG_RUNTIME_DIR=/tmp/p012-\$(id -u) podman --root /tmp/p012-store-\$(id -u) run --rm $IMAGE true" </dev/null 2>&1); result ssh_shell_raw_podman_run "$(denied $? "$o")"
o=$(systemd-run --quiet --wait --pipe --collect --uid="$UID_" --slice=system.slice unshare -U true </dev/null 2>&1); result cron_like_system_slice_unshare "$(denied $? "$o")"
o=$(systemd-run --quiet --wait --pipe --collect --uid="$UID_" --slice="user-$UID_.slice" unshare -U true </dev/null 2>&1); result user_slice_unshare "$(denied $? "$o")"
o=$(unshare -U true 2>&1); result root_unshare "$(ok $? "$o")"
info "counters: $(counters)"
rm -rf /tmp/p012-store-"$UID_" /tmp/p012-"$UID_" 2>/dev/null
