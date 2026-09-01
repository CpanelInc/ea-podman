#!/bin/bash
#
# EA4-319 proof of concept -- podman + systemd only, NO ea-podman code involved.
#
# WHAT THIS PROVES
#   CageFS 7.6.39+ masks the `user@.service` systemd TEMPLATE (CloudLinux
#   CLOS-4517). `cagefsctl --hook-install` does that with literally
#   `systemctl mask user@.service`, so masking it by hand on a plain box
#   produces the IDENTICAL host state -- same /dev/null symlink. You do not
#   need CageFS to reproduce the bug.
#
#   Five things get demonstrated, in order:
#     0. rootless podman under `systemctl --user` works normally
#     1. with the template masked, the runtime DIR appears but the BUS does not
#     2. `loginctl enable-linger` alone cannot repair an already-lingering acct
#     3. unmask -> start the manager -> remask ("the sandwich") repairs it
#     4. the manager and its container SURVIVE the remask   <-- the load-bearing claim
#     5. (optional, needs a reboot) containers do NOT come back on their own
#
# SAFETY
#   Masking user@.service is HOST-WIDE: while masked, no account on this box can
#   get a per-user systemd manager. Run on a throwaway VM.
#   The script records the mask state at startup and restores exactly that on
#   exit -- including via a trap -- so if CageFS put the mask there, it stays.
#
# USAGE
#   ./ea4-319-poc.sh status                 # inspect, change nothing
#   ./ea4-319-poc.sh --yes run [USER]       # stages 0-4
#   ./ea4-319-poc.sh --yes pre-reboot       # arm stage 5, then reboot yourself
#   ./ea4-319-poc.sh post-reboot            # check stage 5 after the reboot
#   ./ea4-319-poc.sh cleanup                # remove the container, restore state

set -uo pipefail

MASK_ETC=/etc/systemd/system/user@.service
MASK_RUN=/run/systemd/system/user@.service
STATEDIR=/var/tmp/ea4-319-poc
IMAGE=docker.io/library/alpine:3
CTR=ea4319poc

U=""; X=""; ASSUME_YES=0
INITIAL_MASK=""          # where the mask was when we started ("" = not masked)
RESTORE_ARMED=0

# ---------------------------------------------------------------- narration --

c()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
hr()  { printf '%s\n' "------------------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }
stage()   { echo; hr; printf '%s\n' "$(c '1;36' "STAGE $1")  $2"; hr; }
why()     { printf '  %s %s\n' "$(c '0;36' 'WHY  ')" "$*"; }
expect()  { printf '  %s %s\n' "$(c '0;33' 'EXPECT')" "$*"; }
verdict() { printf '  %s %s\n' "$(c '1;32' 'PASS  ')" "$*"; }
nope()    { printf '  %s %s\n' "$(c '1;31' 'FAIL  ')" "$*"; }
note()    { printf '  %s %s\n' "$(c '0;35' 'NOTE  ')" "$*"; }

# Show a command, run it, show its output indented.
run() {
    printf '  %s %s\n' "$(c '1;37' '$')" "$*"
    local out rc
    out=$( { eval "$@"; } 2>&1 ); rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/      /'; fi
    return $rc
}

pause() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "  press enter to continue (ctrl-c to stop) " _
}

# ------------------------------------------------------------------ helpers --

# Which location the template is masked in, or "" -- the same predicate
# ea_podman::subids::user_manager_mask_file() uses. systemd.unit(5): a unit is
# masked when its name is a symlink to /dev/null or an empty file.
mask_file() {
    local f
    for f in "$MASK_ETC" "$MASK_RUN"; do
        if [ -L "$f" ]; then
            [ "$(readlink "$f")" = /dev/null ] && { echo "$f"; return; }
        elif [ -e "$f" ] && [ ! -s "$f" ]; then
            echo "$f"; return
        fi
    done
    echo ""
}

# Run a command as the test account over ssh to localhost.
#
# NOT `su`. `su` leaves the caller's cwd in place, which the cpuser frequently
# cannot enter -- the exact trap ea_podman::util::ensure_su_login() works around
# at util.pm:107-115, and which silently broke stage 0 the first time this ran.
# ssh gives a real PAM session, lands in the home directory, and sets
# XDG_RUNTIME_DIR the way a genuine login does, so what we measure is what a user
# actually gets. Key is set up once by ssh_setup().
SSH_KEY=""
as_user() {
    ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -i "$SSH_KEY" "$U@localhost" "$*" 2>&1
}

# Same, but sets XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS explicitly.
#
# Measured on this cPanel box: an ssh login creates NO logind session, so neither
# variable is exported even by a login shell -- `systemctl --user` then fails
# with "Failed to connect to bus". That is not a quirk of this harness; it is the
# same reason ea_podman::util::ensure_su_login() sets both by hand
# (util.pm:100-105) rather than trusting the session. So this is the faithful
# thing to use for the user-side commands.
as_user_env() {
    as_user "XDG_RUNTIME_DIR=/run/user/$X DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$X/bus $*"
}

ssh_setup() {
    local home; home=$(getent passwd "$U" | cut -d: -f6)
    [ -d "$home" ] || { nope "no home directory for $U"; exit 1; }
    SSH_KEY="$STATEDIR/id_poc"
    mkdir -p "$STATEDIR"
    [ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" -C ea4-319-poc
    install -d -m 0700 -o "$U" -g "$(id -gn "$U")" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    grep -qF "$(cat "$SSH_KEY.pub")" "$home/.ssh/authorized_keys" 2>/dev/null \
        || cat "$SSH_KEY.pub" >> "$home/.ssh/authorized_keys"
    chmod 0600 "$home/.ssh/authorized_keys"
    chown "$U:$(id -gn "$U")" "$home/.ssh/authorized_keys"
    if ! as_user true; then
        nope "cannot ssh $U@localhost -- is sshd running and does it allow this account?"
        say  "     (that is a test-harness problem, not an EA4-319 finding)"
        exit 1
    fi
    note "ssh to $U@localhost works; using it instead of su for every user-side command"
}

ssh_teardown() {
    local home ak; home=$(getent passwd "$U" | cut -d: -f6); ak="$home/.ssh/authorized_keys"
    [ -n "$home" ] && [ -f "$ak" ] || return 0

    # NOT chained with && -- grep -v exits 1 when it selects no lines, which is
    # exactly the common case here (our key was the only one), and that would
    # skip the mv and leave the key installed.
    grep -v 'ea4-319-poc' "$ak" > "$ak.tmp" 2>/dev/null
    mv -f "$ak.tmp" "$ak"
    chown "$U:$(id -gn "$U")" "$ak"
    # we created it with touch if it did not exist; do not leave an empty one
    [ -s "$ak" ] || rm -f "$ak"
    return 0
}

show_state() {
    local m; m=$(mask_file)
    say "  mask         : ${m:-(not masked)}   [systemctl says: $(systemctl is-enabled user@.service 2>&1)]"
    [ -n "$U" ] || return 0
    say "  linger       : $(loginctl show-user "$U" -p Linger 2>&1 | tr -d '\n')"
    say "  user manager : $(systemctl is-active "user@$X.service" 2>&1)"
    if [ -S "/run/user/$X/bus" ]; then say "  session bus  : present"
    elif [ -d "/run/user/$X" ]; then say "  session bus  : MISSING  (but /run/user/$X exists)"
    else say "  runtime dir  : missing entirely"; fi
}

restore_mask() {
    [ "$RESTORE_ARMED" = 1 ] || return 0
    local now; now=$(mask_file)
    if [ -n "$INITIAL_MASK" ] && [ -z "$now" ]; then
        echo; note "restoring the mask this box started with: $INITIAL_MASK"
        ln -s /dev/null "$INITIAL_MASK" 2>/dev/null
        systemctl daemon-reload
    elif [ -z "$INITIAL_MASK" ] && [ -n "$now" ]; then
        echo; note "this box was NOT masked when we started; removing our mask"
        systemctl unmask user@.service >/dev/null 2>&1
        systemctl daemon-reload
    fi
}
trap restore_mask EXIT INT TERM

pick_user() {
    U="${1:-}"
    if [ -z "$U" ]; then
        U=$(getent passwd | awk -F: '$3>1000 && $3<65000 && $7 ~ /(bash|sh)$/ {print $1; exit}')
    fi
    [ -n "$U" ] || { nope "no unrestricted-shell test account found; pass one as an argument"; exit 1; }
    X=$(id -u "$U" 2>/dev/null) || { nope "no such user: $U"; exit 1; }
    case "$(getent passwd "$U" | cut -d: -f7)" in
        *jailshell|*noshell|*nologin|*false)
            nope "$U has a restricted shell -- rootless podman cannot run inside it."
            say  "     Pick an account with /bin/bash. (That restriction is the separate"
            say  "     jailshell/CageFS problem, not what this POC is about.)"
            exit 1 ;;
    esac
    mkdir -p "$STATEDIR"; printf '%s\n' "$U" > "$STATEDIR/user"
}

preflight() {
    [ "$(id -u)" = 0 ] || { nope "must run as root"; exit 1; }
    command -v podman >/dev/null || { nope "podman is not installed"; exit 1; }
    INITIAL_MASK=$(mask_file)

    stage "PRE" "Preflight"
    say "  test account : $U (uid $X)"
    say "  podman       : $(podman --version)"
    show_state
    if rpm -q cagefs >/dev/null 2>&1; then
        note "cagefs IS installed here -- the mask you see is theirs, and this"
        note "script will put it back exactly as found."
    else
        note "cagefs is NOT installed. The mask this script applies is byte-identical"
        note "to what \`cagefsctl --hook-install\` applies, so the host state is the same."
    fi
    echo
    if [ "$ASSUME_YES" != 1 ]; then
        say "  $(c '1;31' 'This will mask user@.service host-wide for parts of the run.')"
        read -r -p "  Type YES to continue: " a; [ "$a" = YES ] || exit 1
    fi
    RESTORE_ARMED=1
    ssh_setup
}

# ------------------------------------------------------------------- stages --

stage0() {
    stage 0 "Baseline -- rootless podman under \`systemctl --user\` works"
    why "Establishes that the only thing stages 1-4 change is the mask. The last"
    why "command is the real dependency: container persistence goes through the"
    why "account's own systemd manager, which needs a session bus to talk to."
    pause
    run "systemctl unmask user@.service" >/dev/null 2>&1
    run "loginctl enable-linger $U"
    sleep 3
    expect "the bus exists and user@$X.service is active"
    run "ls -l /run/user/$X/bus"
    run "systemctl is-active user@$X.service"

    podman image exists "$IMAGE" 2>/dev/null || run "podman pull $IMAGE"
    run "as_user_env 'podman rm -f $CTR'" >/dev/null 2>&1
    run "as_user_env 'podman run -d --name $CTR $IMAGE sleep infinity'"
    run "as_user_env 'mkdir -p ~/.config/systemd/user'"
    run "as_user_env 'podman generate systemd --name $CTR > ~/.config/systemd/user/container-$CTR.service'"
    run "as_user_env 'systemctl --user daemon-reload'"
    run "as_user_env 'systemctl --user enable --now container-$CTR.service'"
    expect "active"
    if run "as_user_env 'systemctl --user is-active container-$CTR.service'" | grep -qx '      active'; then
        verdict "the container is managed by the account's own systemd manager"
    else
        nope "baseline did not come up -- everything after this would be meaningless,"
        say  "         because stages 1 and 4 assert against this container. Stopping."
        exit 1
    fi
}

stage1() {
    stage 1 "Mask it -- and see what actually goes missing"
    why "Masking does NOT stop an already-running instance, so the manager has to"
    why "be stopped first to see the failure a cold account hits."
    why ""
    why "EA4-319 open question 2 predicted the runtime DIR would survive (only"
    why "user@.service is masked, user-runtime-dir@.service is not) and that just"
    why "the bus would be missing. That prediction is WRONG: user@.service carries"
    why "Requires=user-runtime-dir@%i.service, so masking user@ fails the whole job"
    why "and the runtime dir never gets created either."
    pause
    run "as_user_env 'systemctl --user stop container-$CTR.service'"
    run "loginctl disable-linger $U"
    run "systemctl stop user@$X.service"
    sleep 2
    run "systemctl mask user@.service"
    run "systemctl daemon-reload"
    run "loginctl enable-linger $U"
    sleep 3

    expect "NEITHER /run/user/$X NOR /run/user/$X/bus exists"
    run "ls -ld /run/user/$X"
    run "ls -l /run/user/$X/bus"
    run "systemctl status user@$X.service --no-pager -l" | head -20
    run "as_user_env 'systemctl --user is-active container-$CTR.service'"
    run "as_user_env 'podman ps'"

    if [ ! -d "/run/user/$X" ] && [ ! -S "/run/user/$X/bus" ]; then
        verdict "BOTH are missing -- this ANSWERS EA4-319 open question 2, and not"
        say  "         the way the ticket guessed. A masked host loses the runtime"
        say  "         directory as well as the bus, so the original customer report"
        say  "         ('the runtime directory did not become available') was ACCURATE,"
        say  "         not misleading. ea-podman must name the mask on both of its"
        say  "         readiness errors, not just the bus one."
    elif [ -d "/run/user/$X" ]; then
        note "the runtime dir survived here -- that contradicts what was measured on"
        note "systemd 239. Capture this output; it is a systemd-version difference"
        note "and it changes which error message a masked host actually shows."
    else
        nope "unexpected state; see the output above"
    fi
}

stage2() {
    stage 2 "Prove \`loginctl enable-linger\` ALONE cannot repair it"
    why "This is the finding that forced an explicit \`systemctl start\`. For an"
    why "account that already lingers, logind will not retry a manager it believes"
    why "it already handled -- which is exactly the post-reboot state on a CageFS"
    why "box: marker present, runtime dir present, bus missing."
    pause
    run "loginctl show-user $U -p Linger"
    run "loginctl enable-linger $U"
    sleep 3
    expect "the bus is STILL missing"
    run "ls -l /run/user/$X/bus"
    if [ ! -S "/run/user/$X/bus" ]; then
        verdict "re-running enable-linger is a no-op here. enable-linger owns"
        say  "         PERSISTENCE; something else has to own 'up right now'."
    else
        nope "the bus appeared -- enable-linger was enough on this systemd version"
    fi
}

stage3() {
    stage 3 "The sandwich -- unmask, start the manager, remask"
    why "The whole EA4-319 approach. The window is only as wide as the start:"
    why "\`systemctl start\` blocks until the job settles, so nothing else has to"
    why "happen while the mask is down."
    pause
    run "systemctl unmask user@.service"
    run "systemctl daemon-reload"
    expect "the start blocks and then the bus exists"
    run "systemctl start user@$X.service"
    run "ls -l /run/user/$X/bus"
    run "systemctl mask user@.service"
    run "systemctl daemon-reload"
    [ -S "/run/user/$X/bus" ] && verdict "manager started and the mask is already back on disk" \
                              || nope "the bus never appeared"
}

stage4() {
    stage 4 "The load-bearing claim -- manager and container SURVIVE the remask"
    why "If this holds, the brief window is enough and CloudLinux's CLOS-4517 fix"
    why "is back in place at rest. If it does not hold, the whole approach is wrong."
    pause
    expect "is-enabled says 'masked' AND is-active says 'active' at the same time"
    run "systemctl is-enabled user@.service"
    run "systemctl is-active user@$X.service"
    run "ls -l /run/user/$X/bus"
    run "as_user_env 'systemctl --user start container-$CTR.service'"
    run "as_user_env 'systemctl --user is-active container-$CTR.service'"
    run "as_user_env 'podman ps'"

    local masked active
    masked=$(systemctl is-enabled user@.service 2>&1)
    active=$(systemctl is-active "user@$X.service" 2>&1)
    if [ "$masked" = masked ] && [ "$active" = active ]; then
        verdict "TEMPLATE MASKED + MANAGER RUNNING simultaneously."
        say  "         Masking refuses new starts; it does not stop a running instance."
        say  "         This is why unmask -> start -> remask works, and why two people"
        say  "         on the ticket got opposite results: whoever had already started"
        say  "         a manager kept working after re-masking."
    else
        nope "mask=$masked manager=$active -- premise NOT proven, stop here"
    fi
}

stage5_arm() {
    stage 5 "Arm the reboot test (EA4-319 open question 1)"
    why "Nothing runs at boot. If logind cannot start user@<uid>.service for a"
    why "lingering account because the template is masked, then already-deployed"
    why "containers do not come back -- which is the question that sets the"
    why "severity on this ticket, and nobody has actually rebooted to check."
    pause
    run "systemctl mask user@.service"; run "systemctl daemon-reload"
    run "loginctl enable-linger $U"
    printf '%s\n' "$INITIAL_MASK" > "$STATEDIR/initial_mask"
    touch "$STATEDIR/armed"
    RESTORE_ARMED=0        # deliberately leave the mask in place across the reboot
    show_state
    echo
    say "  $(c '1;33' 'Now reboot, then run:')  $0 post-reboot"
}

stage5_check() {
    U=$(cat "$STATEDIR/user" 2>/dev/null); X=$(id -u "$U" 2>/dev/null)
    [ -f "$STATEDIR/armed" ] || { nope "not armed -- run 'pre-reboot' first"; exit 1; }
    INITIAL_MASK=$(cat "$STATEDIR/initial_mask" 2>/dev/null)
    stage 5 "After the reboot"
    show_state
    echo
    run "systemctl is-active user@$X.service"
    run "ls -l /run/user/$X/bus"
    run "as_user_env 'podman ps'"
    if [ "$(systemctl is-active "user@$X.service" 2>&1)" != active ]; then
        verdict "CONFIRMED: containers do NOT come back on their own after a reboot"
        say  "         on a masked host. In the real implementation the account's NEXT"
        say  "         ea-podman command repairs this (it runs the sandwich) -- but"
        say  "         nothing repairs it proactively. Document this on EA4-319."
    else
        note "the manager DID come back -- that would contradict the expected gap."
        note "Capture this output on the ticket; it changes the severity."
    fi
    RESTORE_ARMED=1
    rm -f "$STATEDIR/armed"
}

cleanup() {
    [ -z "$U" ] && { U=$(cat "$STATEDIR/user" 2>/dev/null); X=$(id -u "$U" 2>/dev/null); }
    stage "END" "Cleanup"
    [ -z "${INITIAL_MASK}" ] && INITIAL_MASK=$(cat "$STATEDIR/initial_mask" 2>/dev/null)

    # cleanup runs standalone, so the key ssh_setup() made in preflight has to be
    # picked back up or every user-side command below silently no-ops.
    [ -f "$STATEDIR/id_poc" ] && SSH_KEY="$STATEDIR/id_poc"
    run "systemctl unmask user@.service"
    run "systemctl daemon-reload"
    if [ -n "$U" ]; then
        run "as_user_env 'systemctl --user disable --now container-$CTR.service'"
        run "as_user_env 'rm -f ~/.config/systemd/user/container-$CTR.service'"
        run "as_user_env 'podman rm -f $CTR'"
        run "loginctl disable-linger $U"
        run "systemctl stop user@$X.service"
    fi
    ssh_teardown
    rm -rf "$STATEDIR"
    RESTORE_ARMED=1
    restore_mask; RESTORE_ARMED=0
    echo; show_state
}

# -------------------------------------------------------------------- main ---

[ "${1:-}" = "--yes" ] && { ASSUME_YES=1; shift; }
CMD="${1:-status}"; shift 2>/dev/null

case "$CMD" in
    status)      U=$(cat "$STATEDIR/user" 2>/dev/null || true)
                 [ -n "$U" ] && X=$(id -u "$U" 2>/dev/null)
                 stage "--" "Current state"; show_state ;;
    run)         pick_user "${1:-}"; preflight; stage0; stage1; stage2; stage3; stage4
                 echo; note "stage 5 needs a reboot: $0 --yes pre-reboot"
                 note "when done: $0 cleanup" ;;
    pre-reboot)  pick_user "${1:-}"; preflight; stage5_arm ;;
    post-reboot) stage5_check ;;
    cleanup)     cleanup ;;
    *)           sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
