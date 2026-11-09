#!/bin/bash
# P0-8: CONTAINERS_CONF semantics per podman version; is the account's own config ignored?
# With XDG_CONFIG_HOME = the root-owned per-account dir holding only the cni symlink (F16):
# does podman work, and is nothing else under it created or read?
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
UC=$HOME_/.config/containers
BK=$HOME_/.config/containers.p08-backup
# Refuse before any cleanup is armed: a leftover backup belongs to an earlier run, not this one.
# The account owns these paths, so the account moves, writes and removes them, never root.
if [ -e "$BK" ] || [ -L "$BK" ]; then echo "$BK exists; restore it first" >&2; exit 1; fi
if [ -e "$UC" ] || [ -L "$UC" ]; then
    user_sh 'mv "$1" "$2"' "$UC" "$BK" || { echo "could not move $UC aside" >&2; exit 1; }
fi
ST=
cleanup() {    # UC is always this run's hostile config; BK, if any, is what this run moved aside
    user_sh 'rm -rf "$1"; if [ -e "$2" ] || [ -L "$2" ]; then mv "$2" "$1"; fi' "$UC" "$BK"
    [ -n "$ST" ] && rm -rf "$ST"
    probe_unit_rm p08.$U.60
    rm -f /tmp/p08-host-mark
}
trap cleanup EXIT

# Hostile account config: each setting would be visible if podman read it.
# Written by root in a private staging dir, then copied in by the account.
ST=$(mktemp -d) || exit 1; mkdir "$ST/containers.conf.d" "$ST/registries.d"
new_tmp /tmp/p08-host-mark || { result setup "could not create /tmp/p08-host-mark"; exit 1; }
echo hostile >/tmp/p08-host-mark; chmod 0644 /tmp/p08-host-mark
cat >"$ST/containers.conf" <<'EOF'
[containers]
env = ["P08_FROM=user-containers.conf"]
log_driver = "none"
[engine]
cgroup_manager = "systemd"
events_logger = "file"
EOF
cat >"$ST/containers.conf.d/99-p08.conf" <<'EOF'
[containers]
env = ["P08_DROPIN=user-dropin"]
EOF
cat >"$ST/storage.conf" <<EOF
[storage]
driver = "vfs"
graphroot = "$HOME_/p08-hostile-storage"
EOF
cat >"$ST/registries.conf" <<'EOF'
unqualified-search-registries = ["quay.io"]
EOF
# Reject every image: if this were read, a pull or create would fail.
cat >"$ST/policy.json" <<'EOF'
{ "default": [ { "type": "reject" } ] }
EOF
echo "/tmp/p08-host-mark:/run/p08-mark" >"$ST/mounts.conf"
chmod -R a+rX "$ST"
user_sh 'mkdir -p "$1" && cp -R "$2/." "$1/"' "$UC" "$ST" || { result setup "the account could not write $UC"; exit 1; }

hdr "podman info under podman_env, with a hostile ~/.config/containers"
out=$(as_user /usr/bin/podman info --format '{{.Host.CgroupManager}}|{{.Store.GraphDriverName}}|{{.Store.GraphRoot}}|{{.Host.EventLogger}}|{{.Host.NetworkBackend}}' 2>&1)
info "$out"
IFS='|' read -r mgr drv graph evl netbk <<<"$(tail -1 <<<"$out")"
result user_containers_conf_ignored "$([ "$mgr" = cgroupfs ] && [ "$evl" = journald ] && echo yes || echo "NO (mgr=$mgr events=$evl)")"
result user_storage_conf_ignored "$([ "$drv" = overlay ] && [ "$graph" = "$HOME_/.local/share/ea-podman/storage" ] && echo yes || echo "NO ($drv $graph)")"
result network_backend "${netbk:-unknown}"
grep -q 'Failed to decode the keys' <<<"$out" && result pinned_conf_warnings "$(grep -o 'Failed to decode the keys \[[^]]*\]' <<<"$out" | sort -u | tr '\n' ' ')" \
    || result pinned_conf_warnings none

hdr "create + start a container (policy.json, registries.conf, mounts.conf, drop-ins, env)"
before=$(cd "$XDGDIR" && find . -mindepth 1 -printf '%y %p -> %l\n' | sort)
cr=$(probe_create p08.$U.60 -p 127.0.0.1:8090:80 "$IMAGE" 2>&1); rc=$?
info "create rc=$rc: $(tail -1 <<<"$cr")"
result user_policy_json_ignored "$([ $rc = 0 ] && echo yes || echo "NO: $cr")"
st=$(as_user /usr/bin/podman start p08.$U.60 2>&1); src=$?
result start_from_plain_runner "$([ $src = 0 ] && echo works || echo "FAILS: $(tail -1 <<<"$st")")"
st=$(probe_unit_start p08.$U.60 2>&1); src=$?
info "start rc=$src: $(tail -1 <<<"$st")"
result start_with_pinned_xdg_config_home "$([ $src = 0 ] && echo works || echo "FAILS: $(tail -1 <<<"$st")")"
envs=$(as_user /usr/bin/podman exec p08.$U.60 env 2>&1 | grep '^P08_' | tr '\n' ' ')
result user_env_and_dropins_ignored "$([ -z "$envs" ] && echo yes || echo "NO: $envs")"
mnt=$(as_user /usr/bin/podman exec p08.$U.60 cat /run/p08-mark 2>/dev/null)
result user_mounts_conf_ignored "$([ -z "$mnt" ] && echo yes || echo NO)"
ld=$(as_user /usr/bin/podman inspect --format '{{.HostConfig.LogConfig.Type}}' p08.$U.60 2>/dev/null)
result log_driver "$ld (user conf says none)"
[ -e "$HOME_/p08-hostile-storage" ] && result hostile_graphroot_touched YES || result hostile_graphroot_touched no

hdr "what podman created under XDG_CONFIG_HOME ($XDGDIR)"
after=$(cd "$XDGDIR" && find . -mindepth 1 -printf '%y %p -> %l\n' | sort)
info "before: $before"; info "after:  $after"
result xdg_config_home_unchanged "$([ "$before" = "$after" ] && echo yes || echo "NO: $(diff <(echo "$before") <(echo "$after") | grep '^>' | tr '\n' ' ')")"
info "cni dir in the tmpfs: $(cd "$RUNDIR/cni" 2>/dev/null && find . -mindepth 1 | head -10 | tr '\n' ' ')"
result cni_dir_used "$([ -n "$(ls -A "$RUNDIR/cni" 2>/dev/null)" ] && echo "yes ($(cd "$RUNDIR/cni" && find . -mindepth 1 -maxdepth 2 | tr '\n' ' '))" || echo no)"

hdr "what podman opened under the account's ~/.config while it ran (strace, if present)"
if command -v strace >/dev/null; then
    tr_out=$(systemd-run --quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" --pipe --wait --collect \
        -p WorkingDirectory="$HOME_" "${ENVS[@]}" /usr/bin/strace -f -qq -e trace=open,openat,stat,newfstatat,access,statx \
        -o /dev/stderr /usr/bin/podman ps -a </dev/null 2>&1 >/dev/null | grep -o "\"$HOME_/\.config[^\"]*\"" | sort -u | tr '\n' ' ')
    result opens_under_home_config "${tr_out:-none}"
else
    result opens_under_home_config "not checked (no strace)"
fi
