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

# "Not supported" is a verdict only when both were read: grep -c exits 1 for no match, 2 when it
# couldn't read kallsyms; the LSM list is never empty on a kernel that has securityfs mounted.
hook=$(grep -c ' bpf_lsm_userns_create$' /proc/kallsyms); rc=$?
[ $rc -le 1 ] && [ -n "$hook" ] || { inconclusive userns_create_hook "couldn't read /proc/kallsyms (grep rc=$rc)"; probe_exit; }
lsm=$(cat /sys/kernel/security/lsm 2>&1) && [ -n "$lsm" ] \
    || { inconclusive bpf_in_lsm_list "couldn't read /sys/kernel/security/lsm: ${lsm:-empty}"; probe_exit; }
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
# The program's .bss map (libbpf names it userns_g.bss). bpftool prints each variable as its
# own object ([{"allowed":N},{"denied":M}]), so read them one at a time.
counter() {
    local id; id=$(bpftool map show 2>/dev/null | awk '/\.bss/ && /userns/ {sub(":","",$1); print $1}' | tail -1)
    [ -n "$id" ] && bpftool map dump id "$id" 2>/dev/null | tr -d '\n ' | grep -oE "\"$1\":[0-9]+" | cut -d: -f2
}
counters() { echo "allowed=$(counter allowed) denied=$(counter denied)"; }
a0=$(counter allowed); d0=$(counter denied)
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
# pause.pid is account-writable: read it as the account, and signal it as root only if it is the
# account's process in the account's slice.
if pp=$(acct_pid "$RUNDIR/libpod/tmp/pause.pid") && r=$(safe_target "$pp" --uid "$UID_" --cgroup "/eapodman-$UID_.slice/" 2>&1); then
    kill -9 "$pp"; sleep 1
else
    info "pause.pid is not a process of $U in its slice (${r:-no PID in it}); not killing it"
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
a1=$(counter allowed); d1=$(counter denied)

hdr "must be denied (outside eapodman.slice)"
# The program can only have made the denials that reached it: on CageFS the caged shell has no
# unshare or podman, so those checks fail before any namespace is created ("n/a").
NDENIED=0
denied_result() { local v; v=$(denied "$2" "$3"); [[ $v = denied* ]] && NDENIED=$((NDENIED + 1)); result "$1" "$v"; }
o=$(su - "$U" -s /bin/bash -c 'unshare -U true' </dev/null 2>&1); denied_result ssh_shell_unshare $? "$o"
o=$(su - "$U" -s /bin/bash -c "cd; mkdir -p -m 0700 /tmp/p012-\$(id -u); XDG_RUNTIME_DIR=/tmp/p012-\$(id -u) podman --root /tmp/p012-store-\$(id -u) run --rm $IMAGE true" </dev/null 2>&1); denied_result ssh_shell_raw_podman_run $? "$o"
o=$(systemd-run --quiet --wait --pipe --collect --uid="$UID_" --slice=system.slice unshare -U true </dev/null 2>&1); denied_result cron_like_system_slice_unshare $? "$o"
o=$(systemd-run --quiet --wait --pipe --collect --uid="$UID_" --slice="user-$UID_.slice" unshare -U true </dev/null 2>&1); denied_result user_slice_unshare $? "$o"
o=$(unshare -U true 2>&1); result root_unshare "$(ok $? "$o")"
a2=$(counter allowed); d2=$(counter denied)
info "counters: $(counters)"
# The denials above are the program's only if its denied counter rose by at least the number of
# checks that came back denied (and its allowed counter rose across "must work"); otherwise
# seccomp, max_user_namespaces or CageFS could have produced them.
if [ -z "$a0" ] || [ -z "$d0" ] || [ -z "$a1" ] || [ -z "$d1" ] || [ -z "$a2" ] || [ -z "$d2" ]; then
    inconclusive denials_by_program "couldn't read the program's counters (start a=$a0 d=$d0; mid a=$a1 d=$d1; end a=$a2 d=$d2)"
else
    result allowed_by_program "$([ $((a1 - a0)) -gt 0 ] && echo "yes (+$((a1 - a0)))" || echo "NO (+0)")"
    if [ "$NDENIED" = 0 ]; then
        inconclusive denials_by_program "no check came back denied, so there is nothing to attribute"
    else
        result denials_by_program "$([ $((d2 - d1)) -ge "$NDENIED" ] && echo "yes (+$((d2 - d1)) for $NDENIED denied)" || echo "NO (+$((d2 - d1)) for $NDENIED denied)")"
    fi
fi
rm -rf /tmp/p012-store-"$UID_" /tmp/p012-"$UID_" 2>/dev/null
probe_exit
