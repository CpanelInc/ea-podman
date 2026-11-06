#!/bin/bash
# F17 / P0-4: a real cgroup switch. Containers created under one version, host rebooted onto the
# other, pinned containers.conf re-rendered for the new host (as 2.0's anchor helper does), then
# the units started. Run on EL8 (grubby).
#   f17-switch.sh flip     record, then set the kernel arg for the other version (caller reboots)
#   f17-switch.sh check    after the reboot: re-render, start, record where each container runs
#   f17-switch.sh restore  set the kernel arg back (caller reboots), then `check` again
set -uo pipefail
cd "$(dirname "$0")"; PROBE=f17; . ./plib.sh
ARG=systemd.unified_cgroup_hierarchy
case ${1:-} in
flip)
    echo $CGV >/var/tmp/f17-orig-cgv
    if [ $CGV = 2 ]; then grubby --update-kernel=ALL --remove-args="$ARG=1" --args="$ARG=0"
    else grubby --update-kernel=ALL --args="$ARG=1"; fi
    result flipped_from "v$CGV"
    ;;
restore)
    if [ "$(cat /var/tmp/f17-orig-cgv)" = 2 ]; then grubby --update-kernel=ALL --remove-args="$ARG=0" --args="$ARG=1"
    else grubby --update-kernel=ALL --remove-args="$ARG=1 $ARG=0"; fi
    result restored_to "v$(cat /var/tmp/f17-orig-cgv)"
    ;;
check)
    result host "now v$CGV (created on v$(cat /var/tmp/f17-orig-cgv))"
    sleep 15
    for n in web.$U.01 api.$U.02 worker.$U.03; do
        result "boot_${n%%.*}" "$(systemctl is-active "ea-podman-$n.service")"
    done
    # 2.0's anchor helper re-renders the pinned conf for the host's version; the kit's setup.sh does
    # the same and restarts the units (existing containers are kept).
    (cd "$KIT" && ./setup.sh "$U" >/dev/null 2>&1)
    result pinned_split_line "$(grep -c '^cgroups = "split"' "$ETC/containers.conf")"
    for n in web.$U.01 api.$U.02 worker.$U.03; do
        u=ea-podman-$n.service
        st=$(systemctl is-active "$u")
        if [ "$st" = active ]; then
            c=$(as_user /usr/bin/podman inspect --format '{{.State.Pid}}' "$n" 2>/dev/null | tail -1)
            where=$(grep -E '^0::|:memory:' /proc/$c/cgroup | head -1 | cut -d: -f3)
            if [ $CGV = 2 ]; then lim=$(cat "$CG$where/memory.max" 2>/dev/null); else lim=$(cat "$CG/memory$where/memory.limit_in_bytes" 2>/dev/null); fi
            result "${n%%.*}" "active; container in $where; memory limit $lim"
        else
            result "${n%%.*}" "$st: $(journalctl -u "$u" -n 40 --no-pager -o cat | grep -m1 -i 'error' | cut -c1-220)"
        fi
    done
    ;;
*) echo "usage: $0 flip|check|restore" >&2; exit 2 ;;
esac
