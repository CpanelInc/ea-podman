#!/bin/bash
#
# EA4-319 -- verify the boot-time fix (ea-podman-user-managers.service).
#
# WHAT THIS IS
#   The manual verification runbook for the fix, as a script. Its sister
#   ea4-319-mask-poc.sh proves the *mechanism* with no ea-podman code; this one
#   drives ea-podman itself, end to end:
#
#     1 local     repo checks -- tests, syntax, spec, unit file. Changes nothing.
#     2 deploy    install the changed files over the installed ea-podman and
#                 enable the unit, so a box can be tested without an OBS build
#     3 smoke     the verb exists, is root-only, and no-ops on a healthy host
#     4 masked    THE CLAIM: on a masked host the sweep starts the manager and
#                 puts the mask back -- `is-enabled` masked and `is-active`
#                 active at the same time
#     5 unit      run the systemd unit itself and show its journal
#     6 reboot    hand off to ea4-319-mask-poc.sh stage 6, the only test that
#                 proves containers come back at boot
#
# SAFETY
#   Stage 4 masks user@.service HOST-WIDE for a few seconds: while masked, no
#   account on this box can get a new per-user systemd manager. The mask state is
#   recorded at startup and restored on every exit path including a trap, so a
#   CageFS-applied mask is put back as found. Stage 2 overwrites the installed
#   ea-podman, and the register stage may install an EA4 package (it says which,
#   and asks first unless --yes). Throwaway VM only.
#
# USAGE
#   ./ea4-319-verify-boot-fix.sh local              # stage 1 only, safe anywhere
#   ./ea4-319-verify-boot-fix.sh --yes run [USER]   # stages 1-5
#   ./ea4-319-verify-boot-fix.sh --yes deploy       # stage 2 on its own
#   ./ea4-319-verify-boot-fix.sh --yes masked       # stage 4 on its own
#   ./ea4-319-verify-boot-fix.sh register [USER]    # give USER a registered
#                                                   #   container, needed by stage 6
#                                                   #   (installs $EAPODMAN_TEST_PKG,
#                                                   #    default ea-redis62, if absent)
#   ./ea4-319-verify-boot-fix.sh --yes pre-reboot [USER]   # arm stage 6, then reboot
#   ./ea4-319-verify-boot-fix.sh post-reboot        # check stage 6
#   ./ea4-319-verify-boot-fix.sh cleanup            # undo the POC's reboot state
#   ./ea4-319-verify-boot-fix.sh pkg                # check a built RPM instead

set -uo pipefail

MASK_ETC=/etc/systemd/system/user@.service
MASK_RUN=/run/systemd/system/user@.service
EAPODMAN=/opt/cpanel/ea-podman/bin/ea-podman
UNIT=ea-podman-user-managers.service
TEST_PKG="${EAPODMAN_TEST_PKG:-ea-redis62}"
TEST_PKG_DIR="/opt/cpanel/$TEST_PKG"

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
POC="$HERE/ea4-319-mask-poc.sh"

U=""; X=""; ASSUME_YES=0
INITIAL_MASK=""
RESTORE_ARMED=0
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

# Show a command, run it, show its output indented. Returns the command's status.
run() {
    printf '  %s %s\n' "$(c '1;37' '$')" "$*"
    local out rc
    out=$( { eval "$@"; } 2>&1 ); rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/      /'; fi
    return $rc
}

# run(), plus a PASS/FAIL on the exit status.
check() {
    local label="$1"; shift
    if run "$@"; then verdict "$label"; else nope "$label"; fi
}

pause() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "  press enter to continue (ctrl-c to stop) " _
}

# ------------------------------------------------------------------ helpers --

# Which of the two locations the template is masked in, or "" -- the same
# predicate ea_podman::subids::user_manager_mask_file() uses.
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

need_root() {
    [ "$(id -u)" = 0 ] || { nope "must run as root"; exit 1; }
}

need_installed() {
    [ -x "$EAPODMAN" ] || {
        nope "$EAPODMAN is not installed -- run the deploy stage first, or install the package"
        exit 1
    }
}

# A cPanel account, not merely a unix account with a shell.
#
# The ea-podman adminbin refuses anything that is not a cPanel user
# ("<user>" (UID "<n>") is not a valid user for this module), so a plain system
# account can never get a container however good its shell is -- picking one
# only wastes a cycle discovering that. /var/cpanel/users is the same list
# Cpanel::Config::Users::getcpusers() reads.
pick_user() {
    U="${1:-}"

    if [ -z "$U" ]; then
        local candidate
        for candidate in $(ls /var/cpanel/users/ 2>/dev/null); do
            case "$(getent passwd "$candidate" | cut -d: -f7)" in
                */bash | */sh) U="$candidate"; break ;;
            esac
        done
    fi

    if [ -z "$U" ]; then
        nope "no cPanel account with an unrestricted shell found; pass one as an argument"
        say  "         (a plain unix account will not do -- the ea-podman adminbin"
        say  "          only accepts cPanel users)"
        exit 1
    fi

    X=$(id -u "$U" 2>/dev/null) || { nope "no such user: $U"; exit 1; }

    # Passed by hand, so say so here rather than failing later inside the adminbin.
    if [ "$U" != root ] && [ ! -f "/var/cpanel/users/$U" ]; then
        note "$U is not a cPanel account (/var/cpanel/users/$U is missing), so the"
        note "ea-podman adminbin will refuse it. Use a cPanel account, or root."
    fi
}

# Is $U in ea-podman's registry? That is exactly what the boot sweep asks.
#
# No `grep -q`: it closes the pipe as soon as it matches, and under
# `set -o pipefail` the producer's SIGPIPE becomes the pipeline's status -- so a
# match would read as a failure. Same reason every other pipeline here reads all
# of its input.
user_is_registered() {
    $EAPODMAN containers --all 2>/dev/null | grep "\"user\" *: *\"$U\"" > /dev/null
}

# Is the EA4 container package present on this host? Both files, the same pair
# ea-memcached16-cli-live.t checks: pkg-version alone can be left behind, and
# ea-podman.json is what `ea-podman install <PKG>` actually reads.
test_pkg_installed() {
    [ -f "$TEST_PKG_DIR/ea-podman.json" ] && [ -f "$TEST_PKG_DIR/pkg-version" ]
}

# How this host installs one. Same apt-vs-rpm probe pkg.postinst uses.
pkg_install_cmd() {
    if   [ -f /usr/bin/apt ]; then echo "apt-get install -y $TEST_PKG"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf install -y $TEST_PKG"
    else echo "yum install -y $TEST_PKG"
    fi
}

# Does this output mean the cpuser could not run the ea-podman CLI *at all*,
# rather than the CLI having done something wrong?
#
# Perl aborts its @INC search on EACCES instead of skipping the entry, so a
# single unreadable directory early in @INC breaks EVERY module load for
# non-root. Seen on a dev box where /usr/local/cpanel/plugins is a symlink into
# /root (mode 550): `require warnings` fails, so nothing a cpuser runs gets as
# far as its own code. Nothing to do with ea-podman -- reproduce with:
#     su - USER -c '/usr/local/cpanel/3rdparty/bin/perl -e "require warnings"'
cpuser_cli_is_broken() {
    case "$1" in
        *"Can't locate"*|*"Permission denied"*) return 0 ;;
        *) return 1 ;;
    esac
}

report_broken_cpuser_cli() {
    note "$U cannot run ANY perl on this box, so the ea-podman CLI never gets"
    note "as far as its own code. This is a host @INC/permissions problem, not"
    note "an ea-podman one. Confirm with:"
    note "    su - $U -c '/usr/local/cpanel/3rdparty/bin/perl -e \"require warnings\"'"
    note "Fix the unreadable @INC entry (see cpuser_cli_is_broken in this script)"
    note "or run the reboot stage against an account that does not need the"
    note "cpuser CLI -- root, if it already has registered containers."
}

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    say "  $(c '1;31' "$1")"
    read -r -p "  Type YES to continue: " a; [ "$a" = YES ] || exit 1
}

# -------------------------------------------------------------------- stages --

stage_local() {
    stage 1 "Repo checks -- changes nothing on this box"
    why "Everything that can be proven without touching the host: the unit tests"
    why "for the sweep, perl/bash syntax, that the spec still parses with the new"
    why "Source23, and that systemd accepts the unit file."
    pause

    check "the test suite passes"        "cd '$REPO' && prove -l t/ 2>&1 | tail -3"
    check "the perl modules compile"     "cd '$REPO' && perl -c SOURCES/subids.pm && perl -c SOURCES/util.pm && perl -c SOURCES/ea-podman.pl"
    check "the shell files parse"        "cd '$REPO' && bash -n SOURCES/pkg.postinst && bash -n SOURCES/pkg.prerm && bash -n t/LiveTests/ea4-319-mask-poc.sh && bash -n t/LiveTests/ea4-319-verify-boot-fix.sh"
    check "the spec parses"              "cd '$REPO' && rpmspec -P --define \"_sourcedir \$PWD/SOURCES\" SPECS/ea-podman.spec > /dev/null"
    check "the spec ships the unit"      "cd '$REPO' && rpmspec -P --define \"_sourcedir \$PWD/SOURCES\" SPECS/ea-podman.spec 2>/dev/null | grep 'usr/lib/systemd/system/$UNIT' > /dev/null"
    check "systemd accepts the unit"     "[ -z \"\$(systemd-analyze verify '$REPO/SOURCES/$UNIT' 2>&1 | grep -v image-firstboot)\" ]"
}

stage_deploy() {
    stage 2 "Deploy the changed files over the installed ea-podman"
    why "So a box can be tested without waiting on an OBS build. This is NOT a"
    why "test of packaging -- for that, build the RPM and use the 'pkg' stage."
    confirm "This overwrites the installed ea-podman on this box."
    pause

    [ -d /opt/cpanel/ea-podman/lib/ea_podman ] || {
        nope "ea-podman does not look installed here (no /opt/cpanel/ea-podman/lib/ea_podman)"
        exit 1
    }

    run "install -m 0644 '$REPO/SOURCES/subids.pm' /opt/cpanel/ea-podman/lib/ea_podman/subids.pm"
    run "install -m 0644 '$REPO/SOURCES/util.pm' /opt/cpanel/ea-podman/lib/ea_podman/util.pm"
    run "install '$REPO/SOURCES/ea-podman.pl' /opt/cpanel/ea-podman/bin/ea-podman.pl"

    # The CLI is a compiled binary; editing the .pl alone changes nothing.
    check "the CLI recompiles" "/opt/cpanel/ea-podman/bin/compile.sh 2>&1 | tail -5"

    run "install -m 0644 '$REPO/SOURCES/$UNIT' /usr/lib/systemd/system/$UNIT"
    run "systemctl daemon-reload"
    check "the unit enables" "systemctl enable $UNIT"
}

stage_smoke() {
    stage 3 "The verb: it exists, it is root-only, and it no-ops on a healthy host"
    why "Nothing is masked at this point, so every account with containers already"
    why "has a manager -- logind started them at boot. Every account should take the"
    why "'already up' early return and NO unmask window should be opened."
    pause
    need_installed

    check "the verb is registered"  "$EAPODMAN help 2>/dev/null | grep ensure_user_sessions"
    check "the unit is enabled"     "[ \"\$(systemctl is-enabled $UNIT 2>&1)\" = enabled ]"

    expect "every account reports 'ok' -- nothing started, no window"
    check "the sweep runs clean" "$EAPODMAN ensure_user_sessions"

    if [ -n "$U" ]; then
        expect "a non-root caller is refused"

        # Captured rather than piped into grep, for the pipefail reason in
        # user_is_registered() above.
        local refusal
        refusal=$(run "su - $U -c '/usr/local/cpanel/scripts/ea-podman ensure_user_sessions'")
        printf '%s\n' "$refusal"

        case "$refusal" in
            *"can only be run by root"*)
                verdict "$U is refused, as a root-only verb should be" ;;

            *)
                if cpuser_cli_is_broken "$refusal"; then
                    note "the root-only guard was never reached, so this is NOT a verdict on it:"
                    report_broken_cpuser_cli
                else
                    nope "a non-root caller was NOT refused -- check the \$> guard in the verb"
                fi ;;
        esac
    fi
}

stage_masked() {
    stage 4 "THE CLAIM -- the sweep works on a masked host, and puts the mask back"
    why "This is the whole fix in one stage. With the template masked and root's"
    why "manager stopped, the sweep has to: open one window, start the manager,"
    why "remask, and come back with the manager still running. \`is-enabled\` saying"
    why "masked and \`is-active\` saying active AT THE SAME TIME is the proof."
    confirm "This masks user@.service HOST-WIDE for a few seconds."
    pause
    need_installed

    INITIAL_MASK=$(mask_file)
    RESTORE_ARMED=1

    run "systemctl mask user@.service"
    run "systemctl daemon-reload"

    # root is always in the registry when it has containers, and needs no cpuser
    # setup -- so it is what this stage sweeps.
    run "loginctl disable-linger root"
    run "systemctl stop user@0.service"
    sleep 2

    expect "root's manager is stopped"
    run "systemctl is-active user@0.service"
    run "ls -ld /run/user/0"

    # logind only tears /run/user/<uid> down once the account's LAST session ends,
    # and root almost always has one (yours). So the manager stops but its bus
    # socket stays -- which is BETTER than a faithful post-reboot state here: it is
    # the exact stale-socket case that made an earlier version of the sweep report
    # "started" without starting anything. Leave it in place; it is the trap.
    if [ -S /run/user/0/bus ]; then
        note "the bus socket outlived the manager (root still has a session)."
        note "That is deliberate here: it is the stale-socket trap the sweep has"
        note "to see through, so 'started' has to mean the manager is really up."
    fi

    expect "the sweep reports root started"
    run "$EAPODMAN ensure_user_sessions"

    run "systemctl is-enabled user@.service"
    run "systemctl is-active user@0.service"
    run "ls -l /run/user/0/bus"

    local masked active
    masked=$(systemctl is-enabled user@.service 2>&1)
    active=$(systemctl is-active user@0.service 2>&1)

    if [ "$masked" = masked ] && [ "$active" = active ]; then
        verdict "TEMPLATE MASKED + MANAGER RUNNING at the same time."
        say  "         The sweep opened its window, started the manager, and put"
        say  "         CLOS-4517 back. This is the fix working."
    elif [ "$active" = active ]; then
        nope "the manager is up but the template is NOT masked ($masked) -- the sweep"
        say  "         did not restore the mask, which is worse than the bug."
    else
        nope "the manager did not start (mask=$masked manager=$active)"
    fi

    restore_mask
    RESTORE_ARMED=0
    run "systemctl daemon-reload"
}

stage_unit() {
    stage 5 "Run the systemd unit itself"
    why "Everything above called the verb directly. This is what actually runs at"
    why "boot, so its ExecStart, its conditions and its exit status matter too."
    pause

    # `restart`, not `start`: the unit is Type=oneshot + RemainAfterExit=yes, so
    # once anything has run it -- an earlier run of this script, the boot we are
    # standing on -- it sits at `active (exited)` and a `start` job is a no-op
    # that still returns 0. Result would still read `success` from the previous
    # invocation and this stage would pass without running the sweep at all.
    run "systemctl restart $UNIT"
    run "systemctl status $UNIT --no-pager -l" | head -20
    run "journalctl -u $UNIT --no-pager -l" | tail -20

    if [ "$(systemctl show -p Result --value $UNIT 2>&1)" = success ]; then
        verdict "the unit ran and exited clean"
    else
        nope "the unit did not exit clean -- see the journal above"
    fi
}

stage_register() {
    stage "6a" "Give $U a container ea-podman knows about"
    why "The boot sweep works from ea-podman's registry, so an account with no"
    why "REGISTERED container has nothing for it to bring back -- stage 6 would"
    why "pass vacuously. A container made by hand does not count."
    pause
    need_installed

    if user_is_registered; then
        verdict "$U already has a registered container"
        return 0
    fi

    # `ea-podman install <PKG>` installs a CONTAINER for an account from an EA4
    # package that is already on the host. It cannot fetch the package itself, so
    # on a box that has never had one this has to happen first.
    if ! test_pkg_installed; then
        local install_cmd; install_cmd=$(pkg_install_cmd)

        note "$TEST_PKG is not on this host ($TEST_PKG_DIR/ea-podman.json is missing),"
        note "so there is no EA4 container package for $U to install a container from."
        note "Any container-based EA4 package will do; \`ea-podman avail\` lists them"
        note "and EAPODMAN_TEST_PKG picks a different one."
        echo
        confirm "About to install the $TEST_PKG package on this host: $install_cmd"
        check "$TEST_PKG installs" "$install_cmd"

        if ! test_pkg_installed; then
            nope "$TEST_PKG still is not installed -- install it by hand, or set"
            say  "         EAPODMAN_TEST_PKG to an EA4 container package that is present."
            return 1
        fi
    fi

    local out
    out=$(run "su - $U -c '/usr/local/cpanel/scripts/ea-podman install $TEST_PKG'")
    printf '%s\n' "$out"

    if user_is_registered; then
        verdict "$U is now in the registry, so the sweep will act on it"
    elif cpuser_cli_is_broken "$out"; then
        nope "$U could not be given a container, but NOT because of $TEST_PKG:"
        report_broken_cpuser_cli
    else
        nope "$U is still not in the registry -- see the output above"
    fi
}

# The reboot is the only thing that proves containers come back at boot, and the
# POC already owns that harness (arming, mask-across-reboot, the verdict). No
# reason to have two of them.
stage_reboot_arm() {
    [ -x "$POC" ] || { nope "$POC is missing"; exit 1; }
    stage "6b" "Hand off to the POC's stage 6"
    why "ea4-319-mask-poc.sh owns the reboot harness. It checks the unit is enabled"
    why "and that $U is registered, then arms the reboot."
    echo
    RESTORE_ARMED=0     # the POC owns the mask from here; it leaves it up on purpose
    exec "$POC" ${ASSUME_YES:+--yes} pre-reboot-fixed "$U"
}

stage_pkg() {
    stage "PKG" "Check a built package rather than a deployed tree"
    why "Stage 2 bypasses packaging entirely. This is what to run after building"
    why "1.0-28, to prove the unit is in the payload and %post enabled it."
    pause

    check "the unit is in the payload" "rpm -ql ea-podman | grep user-managers"
    check "the unit is enabled"        "[ \"\$(systemctl is-enabled $UNIT 2>&1)\" = enabled ]"
    run   "rpm -q ea-podman"
}

summary() {
    echo
    hr
    if [ "$FAILURES" = 0 ]; then
        printf '%s\n' "$(c '1;32' 'ALL CHECKS PASSED')"
        say "Nothing here proves the reboot, though. That needs stage 6:"
        say "  $0 register [USER]"
        say "  $0 --yes pre-reboot [USER]   # then reboot"
        say "  $0 post-reboot"
    else
        printf '%s\n' "$(c '1;31' "$FAILURES CHECK(S) FAILED")"
        say "Scroll up for the FAIL lines."
    fi
    hr
}

# -------------------------------------------------------------------- main ---

[ "${1:-}" = "--yes" ] && { ASSUME_YES=1; shift; }
CMD="${1:-help}"; shift 2>/dev/null

case "$CMD" in
    local)       stage_local; summary ;;
    deploy)      need_root; stage_deploy; summary ;;
    smoke)       need_root; pick_user "${1:-}"; stage_smoke; summary ;;
    masked)      need_root; stage_masked; summary ;;
    unit)        need_root; stage_unit; summary ;;
    register)    need_root; pick_user "${1:-}"; stage_register; summary ;;
    run)         need_root; pick_user "${1:-}"
                 stage_local; stage_deploy; stage_smoke; stage_masked; stage_unit
                 summary ;;
    pre-reboot)  need_root; pick_user "${1:-}"; stage_register; stage_reboot_arm ;;
    post-reboot) exec "$POC" post-reboot ;;
    cleanup)     exec "$POC" cleanup ;;
    pkg)         need_root; stage_pkg; summary ;;
    *)           sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
