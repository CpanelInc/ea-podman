# Shared by the Phase 0 probes (PLAN.md, Phase 0). Run as root on a host where
# ../eapodman-test-kit/setup.sh has already run for $U. Each probe prints
#   RESULT <probe>.<key> <value>
# lines that are collected into PLAN.md, plus whatever context it needs.
U=${U:-eapodtest}
KIT=${KIT:-/root/eapodman-test-kit}
. "$KIT/lib.sh"
PROBE=${PROBE:-$(basename "$0" .sh)}
SDV=$(systemctl --version | awk 'NR==1{print $2}')
PODV=$(podman --version | awk '{print $3}')
OSID=$(. /etc/os-release; echo "$ID-$VERSION_ID")
[ -e /etc/cloudlinux-release ] && OSID="cloudlinux-$(sed 's/[^0-9.]//g' /etc/cloudlinux-release)"

result() { printf 'RESULT %s.%s %s\n' "$PROBE" "$1" "${*:2}"; }
hdr()    { printf '\n### %s\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

# Like lib.sh's as_user, but with the caller's own environment instead of podman_env, and an
# optional RuntimeMaxSec: as_user_env <timeout> <env-assignments...> -- <argv...>
as_user_env() {
    local tmo=$1; shift
    local envs=()
    while [ "$1" != -- ]; do envs+=(--setenv="$1"); shift; done; shift
    seq=$((seq + 1))
    systemd-run --quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" \
        --unit="eapodman-run-$UID_-probe-$$-$seq" --pipe --wait --collect \
        -p RuntimeMaxSec="$tmo" -p WorkingDirectory="$HOME_" "${envs[@]}" "$@" </dev/null
}

# Like lib.sh's as_user, but the transient gets Delegate=yes. With split pinned (v2), podman
# start/run creates sub-cgroups of the caller's cgroup, which a plain runner unit doesn't allow.
as_user_deleg() {
    seq=$((seq + 1))
    systemd-run --quiet --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" \
        --unit="eapodman-run-$UID_-probe-$$-$seq" --pipe --wait --collect -p Delegate=yes \
        -p RuntimeMaxSec=600 -p WorkingDirectory="$HOME_" "${ENVS[@]}" "$@" </dev/null
}

# A build context in the account's home, written by the account itself: root writing (or chowning)
# a path the account controls would follow a planted symlink. user_build_ctx <dir> <RUN command>
user_build_ctx() {
    as_user_env 60 -- /bin/sh -c 'rm -rf "$1" && mkdir "$1" && printf "FROM %s\nRUN %s\n" "$2" "$3" >"$1/Containerfile"' \
        sh "$1" "$IMAGE" "$2"
}
user_rm() { as_user_env 60 -- /bin/rm -rf "$1"; }
# Run a shell snippet as the account, for paths it controls: user_sh '<script>' <args...> ($1...)
user_sh() { local s=$1; shift; as_user_env 60 -- /bin/sh -c "$s" sh "$@"; }
# Run a command as the account (no unit): for reading files it can write, so a planted symlink
# can't make root read, say, /etc/shadow into a log. as_acct <argv...>
as_acct() { setpriv --reuid="$UID_" --regid="$GID_" --init-groups "$@"; }
# A fresh root-owned file at a fixed path in a sticky /tmp or /var/tmp: O_EXCL after the rm, so a
# planted symlink makes it fail instead of being followed. new_tmp <path>
new_tmp() { rm -f "$1" && ( set -C; : >"$1" ); }

# A probe container with its own unit, from the kit's template: probe_create <name> <podman create flags...>
# then probe_unit_start <name>; probe_unit_rm <name> removes both.
probe_create() {
    local name=$1; shift
    as_user /usr/bin/podman create --name "$name" --conmon-pidfile "$(conmon_pidfile "$name")" "$@"
}
probe_unit_start() {
    container_unit "$1" 0 100 143 >"/etc/systemd/system/ea-podman-$1.service"
    systemctl daemon-reload
    systemctl start "ea-podman-$1.service"
}
probe_unit_rm() {
    systemctl stop "ea-podman-$1.service" 2>/dev/null
    rm -f "/etc/systemd/system/ea-podman-$1.service"
    systemctl daemon-reload; systemctl reset-failed "ea-podman-$1.service" 2>/dev/null
    as_user /usr/bin/podman rm -f "$1" >/dev/null 2>&1
}

# 1.x emulation: the account's own systemd --user manager and /run/user/<uid>, as 1.x has
# it (on CloudLinux with CageFS's user@ mask, a root-owned /run/systemd/system copy, as 1.x's
# EA4-321 carveout does). old_session_start / old_session_stop.
OLDRUN=/run/user/$UID_
OLDENV=(XDG_RUNTIME_DIR=$OLDRUN DBUS_SESSION_BUS_ADDRESS=unix:path=$OLDRUN/bus)
old_session_start() {
    if [ "$(systemctl show -p LoadState --value "user@$UID_.service")" = masked ] \
       || [ "$(readlink -f /etc/systemd/system/user@.service 2>/dev/null)" = /dev/null ]; then
        local src
        for src in /usr/lib/systemd/system/user@.service /lib/systemd/system/user@.service; do
            [ -e "$src" ] && break
        done
        install -m 0644 "$src" "/run/systemd/system/user@$UID_.service"
        CARVEOUT=1
        systemctl daemon-reload
    fi
    systemctl start "user-runtime-dir@$UID_.service" "user@$UID_.service"
    systemctl is-active -q "user@$UID_.service"
}
old_session_stop() {
    systemctl stop "user@$UID_.service" "user-runtime-dir@$UID_.service"
    if [ -n "${CARVEOUT:-}" ]; then
        rm -f "/run/systemd/system/user@$UID_.service"
        systemctl daemon-reload
        CARVEOUT=
    fi
}
# Run as the account inside its 1.x session (default storage, systemd cgroup manager).
as_user_old() { as_user_env 600 "${OLDENV[@]}" -- "$@"; }

# Pinned env, plus a different storage.conf (the migration's old-storage.conf).
OLDSTORE_CONF=/etc/eapodman-test/old-storage.conf
write_old_storage_conf() {
    cat >$OLDSTORE_CONF <<'EOF'
[storage]
driver = "overlay"
rootless_storage_path = "$HOME/.local/share/containers/storage"
EOF
    chmod 0644 $OLDSTORE_CONF
}
PINNED_OLD=(XDG_RUNTIME_DIR=$RUNDIR CONTAINERS_CONF=$ETC/containers.conf
    CONTAINERS_STORAGE_CONF=$OLDSTORE_CONF CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf
    XDG_CONFIG_HOME=$XDGDIR)
PINNED=(XDG_RUNTIME_DIR=$RUNDIR CONTAINERS_CONF=$ETC/containers.conf
    CONTAINERS_STORAGE_CONF=$ETC/storage.conf CONTAINERS_REGISTRIES_CONF=$ETC/registries.conf
    XDG_CONFIG_HOME=$XDGDIR)
IMAGE=docker.io/nginxdemos/hello:plain-text

echo "host $(hostname -s) os=$OSID kernel=$(uname -r) cgroup=v$CGV systemd=$SDV podman=$PODV"
