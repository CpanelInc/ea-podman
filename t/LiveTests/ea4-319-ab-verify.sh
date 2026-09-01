#!/bin/bash
#
# EA4-319 A/B verification -- does the shipped change actually fix a masked host?
#
# WHAT THIS IS, AND HOW IT DIFFERS FROM ea4-319-mask-poc.sh
#   The POC proves the *mechanism* with podman/systemctl only and deliberately
#   involves no ea-podman code. This script proves the *implementation*: on a
#   host masked exactly the way `cagefsctl --hook-install` masks it, it runs one
#   identical rootless-podman operation twice --
#
#     A. bootstrapped the way ea-podman did BEFORE EA4-319   -> must FAIL
#     B. bootstrapped by the ea-podman code in this checkout -> must PASS
#
#   Nothing between A and B changes except which ea_podman::subids the bootstrap
#   comes from. The mask stays on for both.
#
#   Both sides come out of THIS CHECKOUT, never out of whatever happens to be
#   installed on the box. A is the last version of SOURCES/subids.pm in this
#   repo's history that predates the fix, recovered with `git show` -- real old
#   code rather than a strawman, and the same old code on every host. Only if
#   there is no usable history (a shallow clone, or the file copied out on its
#   own) does A fall back to an inline reconstruction of what that code did:
#   `loginctl enable-linger` plus a 10s poll for the bus, and nothing else.
#   Either way A is defined by this repo, so the run means the same thing
#   everywhere.
#
#   THE OP ITSELF USES ONLY podman AND systemctl, run as the account: pull-free
#   `podman run -d`, `podman generate systemd`, `systemctl --user enable --now`.
#   That is the thing WebApp deploys need and the thing a masked host breaks.
#
# SAFETY
#   Masking user@.service is HOST-WIDE: while masked, no account on this box can
#   get a NEW per-user systemd manager (already-running ones are unaffected --
#   that is the whole point). Run on a throwaway VM.
#   The mask state present at startup is recorded and restored on every exit
#   path, including via a trap, so a CageFS-owned mask stays exactly as found.
#
# USAGE
#   ./ea4-319-ab-verify.sh status              # inspect, change nothing
#   ./ea4-319-ab-verify.sh --yes run [USER]    # the A/B run
#   ./ea4-319-ab-verify.sh cleanup             # remove the container, restore state

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

MASK_ETC=/etc/systemd/system/user@.service
MASK_RUN=/run/systemd/system/user@.service
STATEDIR=/var/tmp/ea4-319-ab
IMAGE=docker.io/library/alpine:3
CTR=ea4319ab
# The module needs Cpanel::OS and Path::Tiny, so the cPanel perl is a real
# dependency, not a preference. Overridable for a box that puts it elsewhere.
PERL=${EAPODMAN_PERL:-/usr/local/cpanel/3rdparty/bin/perl}
NEW_LIB="$STATEDIR/newlib"
OLD_LIB="$STATEDIR/oldlib"

# ea_podman::subids writes these two, so they are fixed by the code under test.
EAPODMAN_DIR=/opt/cpanel/ea-podman
MASK_STATE="$EAPODMAN_DIR/user-manager-mask.state"
MASK_LOCK="$EAPODMAN_DIR/user-manager-mask.lock"

U=""; X=""; HOME_U=""; ASSUME_YES=0
INITIAL_MASK=""
RESTORE_ARMED=0
A_MODE=""            # "git" or "inline"
A_REV=""
FAILURES=0

# ---------------------------------------------------------------- narration --

c()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
hr()  { printf '%s\n' "------------------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }
stage()   { echo; hr; printf '%s\n' "$(c '1;36' "STAGE $1")  $2"; hr; }
why()     { printf '  %s %s\n' "$(c '0;36' 'WHY  ')" "$*"; }
expect()  { printf '  %s %s\n' "$(c '0;33' 'EXPECT')" "$*"; }
verdict() { printf '  %s %s\n' "$(c '1;32' 'PASS  ')" "$*"; }
nope()    { FAILURES=$((FAILURES+1)); printf '  %s %s\n' "$(c '1;31' 'FAIL  ')" "$*"; }
note()    { printf '  %s %s\n' "$(c '0;35' 'NOTE  ')" "$*"; }

run() {
    printf '  %s %s\n' "$(c '1;37' '$')" "$*"
    local out rc
    out=$( { eval "$@"; } 2>&1 ); rc=$?
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/      /'
    return $rc
}

pause() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "  press enter to continue (ctrl-c to stop) " _
}

# ------------------------------------------------------------------ helpers --

# The same predicate ea_podman::subids::user_manager_mask_file() uses: per
# systemd.unit(5) a unit is masked when its name is a symlink to /dev/null, or
# an empty file.
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

# Run a command as the account.
#
# NOT `su`, and NOT ssh: `runuser -u` execs directly with no login shell and no
# logind session, which is precisely the context ea-podman's privileged callers
# (cpsrvd/UAPI, account hooks, root `su -`) hand it. XDG_RUNTIME_DIR and
# DBUS_SESSION_BUS_ADDRESS are set by hand for the same reason
# ea_podman::util::ensure_su_login() sets them (util.pm:97-116) -- no session
# means nothing else would -- and we start in the home directory because a cwd
# inherited from root is one the cpuser often cannot enter.
as_user() {
    runuser -u "$U" -- env HOME="$HOME_U" \
        XDG_RUNTIME_DIR="/run/user/$X" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$X/bus" \
        bash -c "cd '$HOME_U' && $*" 2>&1
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
    say "  mask state   : $( [ -e "$MASK_STATE" ] && cat "$MASK_STATE" || echo '(no in-progress window recorded)' )"
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
    [ -n "$U" ] || { nope "no test account found; pass one as an argument"; exit 1; }
    X=$(id -u "$U" 2>/dev/null) || { nope "no such user: $U"; exit 1; }
    HOME_U=$(getent passwd "$U" | cut -d: -f6)
    [ -d "$HOME_U" ] || { nope "no home directory for $U"; exit 1; }
    mkdir -p "$STATEDIR"; printf '%s\n' "$U" > "$STATEDIR/user"
}

# The new bootstrap, straight out of this checkout. Each side gets its own @INC
# dir because both declare `package ea_podman::subids` -- they must never be
# loaded into one interpreter, which is also why every bootstrap below is its own
# `perl` process.
stage_new_lib() {
    rm -rf "$NEW_LIB"; mkdir -p "$NEW_LIB/ea_podman"
    cp "$REPO/SOURCES/subids.pm" "$NEW_LIB/ea_podman/subids.pm"
    "$PERL" -I"$NEW_LIB" -e 'require ea_podman::subids; exit 0' 2>&1 || {
        nope "the checkout's SOURCES/subids.pm does not load under $PERL"; exit 1; }
}

# The old bootstrap, also straight out of this checkout: the newest revision of
# SOURCES/subids.pm that does not yet carry with_user_manager_unmasked, i.e. the
# last one that predates the fix.
#
# Deliberately NOT whatever is installed at /opt/cpanel/ea-podman/lib. That box
# may be running anything -- including a build that already has the fix -- so
# using it would make the A side mean something different from host to host, and
# on an up-to-date box it would silently stop being a test of the old behaviour
# at all. History is the same everywhere this repo is.
stage_old_lib() {
    rm -rf "$OLD_LIB"; mkdir -p "$OLD_LIB/ea_podman"
    A_REV=""

    if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
        local rev
        for rev in $(git -C "$REPO" log --format=%H -- SOURCES/subids.pm); do
            git -C "$REPO" show "$rev:SOURCES/subids.pm" 2>/dev/null \
                | grep -q with_user_manager_unmasked || { A_REV=$rev; break; }
        done
    fi

    if [ -n "$A_REV" ]; then
        git -C "$REPO" show "$A_REV:SOURCES/subids.pm" > "$OLD_LIB/ea_podman/subids.pm"
        if "$PERL" -I"$OLD_LIB" -e 'require ea_podman::subids; exit 0' >/dev/null 2>&1; then
            A_MODE=git
            return
        fi
        note "the pre-fix module at $A_REV will not load under $PERL"
    fi

    A_MODE=inline
}

bootstrap_with() {    # $1 = @INC dir
    "$PERL" -I"$1" -e '
        require ea_podman::subids;
        ea_podman::subids::ensure_user_session($ARGV[0]);
        print "ensure_user_session() returned without dying\n";
    ' "$U" 2>&1
}

# Fallback for the no-history case only: the pre-fix ensure_user_session
# transcribed -- enable-linger, poll 10s for the bus, the two dies, and no unmask
# window or explicit manager start, that absence being the whole point.
#
# It leaves out the two parts that cannot change the outcome here: the
# already-healthy early return (this stage runs against a cold account, so it
# never fires) and the linger-grant bookkeeping (a test account we did not grant,
# so there is nothing to re-record). Prefer the git path, which has both.
bootstrap_old_inline() {
    "$PERL" -e '
        use Time::HiRes ();
        my ($user) = @ARGV;
        my $uid = ( getpwnam($user) )[2];
        die "Could not look up the uid/gid for “$user”\n" if !defined $uid;

        mkdir "/run/user";
        system( "loginctl", "enable-linger", $user );

        my ( $rundir, $bus ) = ( "/run/user/$uid", "/run/user/$uid/bus" );
        for ( 1 .. 100 ) {
            last if -d $rundir && -e $bus;
            Time::HiRes::usleep(100_000);
        }

        die "The directory “$rundir” is missing and could not be created by `loginctl enable-linger $user`.\n" if !-d $rundir;
        die "The user session bus “$bus” did not appear after `loginctl enable-linger $user` (the user systemd manager did not start).\n" if !-e $bus;

        print "ensure_user_session() returned without dying\n";
    ' "$U" 2>&1
}

bootstrap_old() {
    if [ "$A_MODE" = git ]; then bootstrap_with "$OLD_LIB"; else bootstrap_old_inline; fi
}

# THE OP. podman + systemctl only, run as the account. Identical in A and B.
#
# Deliberately the same shape ea-podman itself uses, so a pass here means the
# real thing works and not merely something adjacent to it:
# `podman generate systemd --restart-policy on-failure --name` (Type=forking,
# never --new/--sdnotify -- see util.pm:365) into ~/.config/systemd/user, then
# enable (util.pm:634) and start (util.pm:954) through the account's own manager.
do_the_op() {
    as_user "systemctl --user disable --now container-$CTR.service" >/dev/null 2>&1
    as_user "podman rm -f $CTR" >/dev/null 2>&1
    run "as_user 'podman create --name $CTR $IMAGE sleep infinity'"
    run "as_user 'mkdir -p ~/.config/systemd/user'"
    run "as_user 'podman generate systemd --restart-policy on-failure --name $CTR > ~/.config/systemd/user/container-$CTR.service'"
    run "as_user 'systemctl --user daemon-reload'"
    run "as_user 'systemctl --user enable container-$CTR.service'"
    run "as_user 'systemctl --user start container-$CTR.service'"
    run "as_user 'systemctl --user is-active container-$CTR.service'"
    run "as_user 'podman ps --format \"{{.Names}} {{.Status}}\"'"
    [ "$(as_user "systemctl --user is-active container-$CTR.service" | tr -d '\n')" = active ]
}

# ------------------------------------------------------------------- stages --

preflight() {
    [ "$(id -u)" = 0 ] || { nope "must run as root"; exit 1; }
    command -v podman  >/dev/null || { nope "podman is not installed"; exit 1; }
    command -v runuser >/dev/null || { nope "runuser is not available"; exit 1; }
    [ -x "$PERL" ] || { nope "$PERL is missing"; exit 1; }
    INITIAL_MASK=$(mask_file)

    stage "PRE" "Preflight"
    say "  checkout     : $REPO"
    say "  test account : $U (uid $X, home $HOME_U)"
    say "  podman       : $(podman --version)"
    say "  systemd      : $(systemctl --version | head -1)"
    show_state

    stage_new_lib
    say "  B side       : $REPO/SOURCES/subids.pm  (working tree, loads OK)"

    stage_old_lib
    if [ "$A_MODE" = git ]; then
        say "  A side       : SOURCES/subids.pm @ $(git -C "$REPO" log -1 --format='%h %s' "$A_REV")"
        say "                 (last revision before with_user_manager_unmasked, loads OK)"
    else
        say "  A side       : no usable history here -- using an inline transcription"
        say "                 (\`loginctl enable-linger\` + the same 10s bus poll)"
    fi
    note "neither side is read from an installed ea-podman; both come from this checkout,"
    note "so this run means the same thing on any host."

    # ea_podman::subids writes its lock and state file straight into this
    # directory ("parent is packaged, always there"), so B needs it whether or
    # not ea-podman is installed here.
    if [ ! -d "$EAPODMAN_DIR" ]; then
        mkdir -p "$EAPODMAN_DIR" && touch "$STATEDIR/made_eapodman_dir"
        note "created $EAPODMAN_DIR (no ea-podman install here); removed again at cleanup"
    fi

    if rpm -q cagefs >/dev/null 2>&1; then
        note "cagefs IS installed here -- any mask you see is theirs, and this"
        note "script will put it back exactly as found."
    else
        note "cagefs is NOT installed. The mask applied below is what"
        note "\`cagefsctl --hook-install\` applies, verbatim, so the host state is the same."
    fi
    echo
    if [ "$ASSUME_YES" != 1 ]; then
        say "  $(c '1;31' 'This will mask user@.service host-wide for the length of the run.')"
        read -r -p "  Type YES to continue: " a; [ "$a" = YES ] || exit 1
    fi
    RESTORE_ARMED=1
}

setup() {
    stage "SETUP" "Cold, unmasked baseline -- prove the op works before we break anything"
    why "If the op cannot run on a healthy host, A failing later would prove nothing."
    why "This also caches the image in the ACCOUNT'S OWN store, so neither A nor B"
    why "depends on the network."
    pause
    run "systemctl unmask user@.service" >/dev/null 2>&1
    run "systemctl daemon-reload"
    run "loginctl enable-linger $U"
    sleep 3
    run "as_user 'podman pull $IMAGE'" | tail -3
    expect "the op succeeds on an unmasked host"
    if do_the_op; then
        verdict "baseline op works: container is up under the account's own systemd manager"
    else
        nope "the baseline op failed -- fix the environment first; A/B below would be meaningless"
        exit 1
    fi

    stage "COLD" "Tear the account's session back down"
    why "A cold account is what a masked host actually has to bootstrap. Note that"
    why "the LINGER MARKER is left in place on purpose from here on: that is the"
    why "post-reboot cagefs state -- lingering, but no manager -- and it is exactly"
    why "the state \`enable-linger\` alone cannot repair."
    pause
    run "as_user 'systemctl --user disable --now container-$CTR.service'"
    run "as_user 'podman rm -f $CTR'"
    run "loginctl disable-linger $U"
    run "systemctl stop user@$X.service"
    sleep 2
    run "rm -f $MASK_STATE"
    show_state
}

apply_mask() {
    stage "MASK" "Apply the CageFS mask"
    why "\`cagefsctl --hook-install\` runs literally \`systemctl mask user@.service\`"
    why "(CloudLinux CLOS-4517), so this produces a byte-identical host state --"
    why "the template name symlinked to /dev/null. No CageFS needed."
    pause
    run "systemctl mask user@.service"
    run "systemctl daemon-reload"
    run "readlink -f $MASK_ETC"
    run "systemctl is-enabled user@.service"
    # The linger marker back on, as a rebooted cagefs box would have it.
    run "loginctl enable-linger $U"
    sleep 2
    show_state
    if [ -n "$(mask_file)" ]; then
        verdict "the template is masked; every account on this host is now in the EA4-319 state"
    else
        nope "the mask did not take -- stopping"; exit 1
    fi
}

side_a() {
    stage "A" "The op, bootstrapped the way ea-podman did BEFORE EA4-319"
    if [ "$A_MODE" = git ]; then
        why "Running SOURCES/subids.pm as it stood at $(git -C "$REPO" log -1 --format=%h "$A_REV"),"
        why "the last revision before the fix -- recovered from this repo, not from"
        why "anything installed on the box."
    else
        why "No usable history here, so this is that code transcribed inline."
    fi
    why "Either way its ensure_user_session() is \`loginctl enable-linger\` plus a 10s"
    why "poll for the bus, and nothing else -- no unmask window, no explicit start."
    expect "the bootstrap DIES, and then the op cannot get off the ground"
    pause

    printf '  %s %s\n' "$(c '1;37' '$')" "ensure_user_session(\"$U\")   [pre-EA4-319, $A_MODE]"
    bootstrap_old | sed 's/^/      /'
    local rc=${PIPESTATUS[0]}

    if [ "$rc" = 0 ]; then
        nope "the OLD bootstrap SUCCEEDED on a masked host -- that contradicts EA4-319."
        say  "         Capture this: either the mask is not really in place, or this"
        say  "         systemd version does not behave the way the case describes."
    else
        verdict "the old bootstrap died on the masked host, as EA4-319 says it does"
    fi

    say ""
    say "  and now the op itself, with no working session to run in:"
    if do_the_op; then
        nope "the op SUCCEEDED under the old bootstrap -- there is nothing here to fix"
    else
        verdict "THE OP FAILS. This is the customer-visible EA4-319 breakage."
    fi
    run "ls -ld /run/user/$X"
    run "systemctl is-active user@$X.service"
}

side_b() {
    stage "B" "The SAME op, bootstrapped by the ea-podman code in this checkout"
    why "Same masked host, same account, same op. The only thing that changed is"
    why "which revision of ea_podman::subids the bootstrap comes from:"
    why "  with_user_manager_unmasked() lifts the mask, ensure_user_session() starts"
    why "  user@$X.service explicitly (enable-linger alone is a no-op for an account"
    why "  that already lingers -- see A), and the mask goes straight back."
    expect "the bootstrap returns cleanly and the op succeeds"
    pause

    printf '  %s %s\n' "$(c '1;37' '$')" "ensure_user_session(\"$U\")   [working tree]"
    bootstrap_with "$NEW_LIB" | sed 's/^/      /'
    local rc=${PIPESTATUS[0]}

    if [ "$rc" = 0 ]; then
        verdict "the new bootstrap came back clean on the very same masked host"
    else
        nope "the new bootstrap FAILED -- the fix does not work here. Stop and read the error above."
    fi

    run "ls -ld /run/user/$X"
    run "ls -l /run/user/$X/bus"
    run "systemctl is-active user@$X.service"

    say ""
    say "  and now the identical op:"
    if do_the_op; then
        verdict "THE OP WORKS on a masked host. That is the fix, demonstrated end to end."
    else
        nope "the op still fails after the new bootstrap -- the fix is incomplete"
    fi
}

side_c() {
    stage "C" "The mask is back, and the manager survived it"
    why "The load-bearing claim. If the mask were left off, we would have disabled"
    why "CloudLinux's CLOS-4517 fix host-wide instead of working around it. If the"
    why "manager did not survive the remask, the brief window would buy nothing."
    pause
    expect "is-enabled says 'masked' AND is-active says 'active', at the same time"
    run "systemctl is-enabled user@.service"
    run "systemctl is-active user@$X.service"
    run "readlink $MASK_ETC"
    run "ls -l $MASK_STATE"

    local masked active
    masked=$(systemctl is-enabled user@.service 2>&1)
    active=$(systemctl is-active "user@$X.service" 2>&1)

    if [ "$masked" = masked ]; then
        verdict "the mask is back on disk -- CLOS-4517 is in force again at rest"
    else
        nope "the mask was NOT restored (is-enabled=$masked). The host is left exposed."
    fi

    if [ "$active" = active ]; then
        verdict "the manager is still running THROUGH the remask -- masking refuses new"
        say  "         starts, it does not stop a running instance. That is why the window"
        say  "         can be this short, and why two people on the ticket got opposite"
        say  "         results: whoever had already started a manager kept working."
    else
        nope "the manager did not survive the remask (is-active=$active)"
    fi

    if [ -e "$MASK_STATE" ]; then
        nope "$MASK_STATE was left behind -- a completed window must clear it"
    else
        verdict "no in-progress-window state file left behind"
    fi

    if [ -n "$INITIAL_MASK" ] && [ "$(mask_file)" != "$INITIAL_MASK" ]; then
        nope "the mask moved: started at $INITIAL_MASK, now at $(mask_file)"
    fi

    stage "IDEMPOTENCE" "A second bootstrap on a healthy-but-masked account is a no-op"
    why "ensure_user_session() returns early when the account lingers and its bus is"
    why "up, which is what keeps the host-wide window off the hot path: a cagefs box"
    why "pays for the bypass once per cold account, not once per ea-podman command."
    pause
    local t0 t1
    t0=$(date +%s%N)
    bootstrap_with "$NEW_LIB" | sed 's/^/      /'
    t1=$(date +%s%N)
    say "  elapsed: $(( (t1-t0)/1000000 ))ms"
    if [ "$(systemctl is-enabled user@.service 2>&1)" = masked ]; then
        verdict "still masked afterwards -- the second call never opened a window"
    else
        nope "the mask came off on the second call"
    fi
}

summary() {
    stage "RESULT" "Summary"
    show_state
    echo
    if [ "$FAILURES" = 0 ]; then
        say "  $(c '1;32' 'ALL CHECKS PASSED') -- on a host masked exactly as CageFS 7.6.39+ masks it,"
        say "  the pre-EA4-319 bootstrap cannot run the op and the bootstrap in this"
        say "  checkout can, with the mask back in place afterwards."
    else
        say "  $(c '1;31' "$FAILURES CHECK(S) FAILED") -- read the FAIL lines above."
    fi
    echo
    note "cleanup: $0 cleanup"
    return "$FAILURES"
}

cleanup() {
    [ -z "$U" ] && { U=$(cat "$STATEDIR/user" 2>/dev/null); X=$(id -u "$U" 2>/dev/null)
                     HOME_U=$(getent passwd "$U" 2>/dev/null | cut -d: -f6); }
    stage "END" "Cleanup"
    run "systemctl unmask user@.service"
    run "systemctl daemon-reload"
    if [ -n "$U" ]; then
        run "as_user 'systemctl --user disable --now container-$CTR.service'"
        run "as_user 'rm -f ~/.config/systemd/user/container-$CTR.service'"
        run "as_user 'systemctl --user daemon-reload'"
        run "as_user 'podman rm -f $CTR'"
        run "loginctl disable-linger $U"
        run "systemctl stop user@$X.service"
    fi
    run "rm -f $MASK_STATE $MASK_LOCK"
    if [ -e "$STATEDIR/made_eapodman_dir" ]; then
        run "rmdir $EAPODMAN_DIR"
    fi
    rm -rf "$STATEDIR"
    RESTORE_ARMED=1
    restore_mask; RESTORE_ARMED=0
    echo; show_state
}

# -------------------------------------------------------------------- main ---

[ "${1:-}" = "--yes" ] && { ASSUME_YES=1; shift; }
CMD="${1:-status}"; shift 2>/dev/null

case "$CMD" in
    status)  U=$(cat "$STATEDIR/user" 2>/dev/null || true)
             [ -n "$U" ] && { X=$(id -u "$U" 2>/dev/null); HOME_U=$(getent passwd "$U" | cut -d: -f6); }
             stage "--" "Current state"; show_state ;;
    run)     pick_user "${1:-}"; preflight; setup; apply_mask; side_a; side_b; side_c; summary ;;
    cleanup) cleanup ;;
    *)       sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
