#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# EA4-321 — LIVE test that ea-podman's per-account user manager survives
# while `user@.service` stays masked (NOT a unit test).
#
# WHAT THIS PROVES. On a host that masks the `user@.service` template
# (CageFS 7.6.39+, CloudLinux CLOS-4517), ea-podman starts an account's
# systemd user manager from a unit file of its own,
# /run/systemd/system/user@<uid>.service, and never touches the mask.
# Before EA4-321 it unmasked the template, started the manager and
# masked it again; on systemd 252 (CloudLinux 9, AlmaLinux 9) that remask
# reload tore down /run/user/<uid> under the running manager. This test
# checks, against the real systemd on the host:
#
#   1. A bootstrapped account has its runtime dir, bus and manager.
#   2. It is STILL up after 3s and after a host-wide `systemctl
#      daemon-reload` (the trigger: anything on the host can do one).
#   3. Bootstrapping a second account does not disturb the first.
#   4. An account that was not bootstrapped is still refused by the
#      template mask, so CLOS-4517's protection is unchanged.
#   5. The template mask is byte for byte what it was, throughout.
#   6. Re-running the bootstrap for a healthy account changes nothing.
#   7. Releasing an account stops its manager and removes its unit, and
#      it is then refused again.
#   8. (EA4321_TOGGLE_MASK=1 only) A manager ea-podman starts on a host
#      that does NOT mask the template has a unit too, and survives the
#      mask arriving later (a cagefs install or upgrade, or CloudLinux's
#      `disable-systemd-user-mask` flag being removed).
#   7a. A mask an administrator puts over a unit ea-podman wrote is not
#      overwritten or removed, and does not stop the rest of a sweep.
#   10. (EA4321_TOGGLE_MASK=1 only) A template mask a pre-EA4-321 run was
#      killed while it had lifted is put back by the next bootstrap, after
#      every lingering account's manager has been given its unit.
#   9. (EA4321_TOGGLE_MASK=1 only) A manager logind started on such a host,
#      with no ea-podman involved, is given its unit by the boot sweep and
#      survives the mask arriving too.
#
# The "after a reboot" case cannot be done from inside a test. It is a
# two-phase operator step, see REBOOT below.
#
# WHERE TO RUN. A disposable cPanel VM, as root. The test creates three
# throwaway system users (ea4321a/b/c) and removes them afterwards. Nothing
# else is created. It needs the ea-podman build under test installed (it
# checks for EA4-321's ensure_user_manager_carveouts) and the template
# masked (CageFS installed and initialised does that; or set
# EA4321_TOGGLE_MASK=1 to let the test mask and unmask it itself).
#
# COPY AND RUN
#
#   scp ea4-321-carveout-live.t root@VM:/root/
#   ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl /root/ea4-321-carveout-live.t'
#
# To test a SOURCES/subids.pm that is not installed yet, copy it to
# <dir>/ea_podman/subids.pm on the VM and add EAPODMAN_LIB=<dir>.
#
# Environment variables:
#   EAPODMAN_LIVE=1        REQUIRED opt-in.
#   EAPODMAN_LIB           directory holding ea_podman/subids.pm to test
#                          (default /opt/cpanel/ea-podman/lib).
#   EA4321_TOGGLE_MASK=1   allow the test to mask the template if it is not
#                          masked, and to unmask it for case 8. Restored
#                          afterwards. Needed on a host without CageFS.
#   EAPODMAN_KEEP=1        skip teardown.
#
# REBOOT (operator step; proves the boot sweep writes the units again,
# since /run is empty after a reboot):
#   1. EA4321_REBOOT=prepare  ... leaves ea4321a/b bootstrapped and lingering.
#   2. reboot the VM.
#   3. EA4321_REBOOT=verify   ... runs the boot sweep the way
#      ea-podman-user-managers.service does, checks both managers come up
#      with units, then removes everything.
#
# LEAVES BEHIND. Nothing on a normal run. With EA4321_REBOOT=prepare, the
# two users, their linger and (if EA4321_TOGGLE_MASK=1 masked it) the
# template mask, until the verify phase runs. After verify on a host without
# CageFS, run `systemctl unmask user@.service` if this test masked it.
#######################################################################

use strict;
use warnings;

use Test::More;

BEGIN {
    plan skip_all => 'set EAPODMAN_LIVE=1 to run this live test on a disposable cPanel VM' if !$ENV{EAPODMAN_LIVE};
}

my $LIB    = $ENV{EAPODMAN_LIB} || '/opt/cpanel/ea-podman/lib';
my $TOGGLE = $ENV{EA4321_TOGGLE_MASK};
my $KEEP   = $ENV{EAPODMAN_KEEP};
my $REBOOT = $ENV{EA4321_REBOOT} || '';
my @USERS  = qw(ea4321a ea4321b ea4321c);

my $MASK_ETC = '/etc/systemd/system/user@.service';
my $UNIT_DIR = '/run/systemd/system';

#---------------------------------------------------------------------
# prerequisites: check them all up front, skip with the reason
#---------------------------------------------------------------------
plan skip_all => 'must run as root'                      if $> != 0;
plan skip_all => 'no systemctl: this needs systemd'      if !_which('systemctl');
plan skip_all => 'no useradd'                            if !_which('useradd');
plan skip_all => "no $LIB/ea_podman/subids.pm to test"   if !-f "$LIB/ea_podman/subids.pm";

unshift @INC, $LIB;
require ea_podman::subids;

plan skip_all => "ea_podman::subids under $LIB has no ensure_user_manager_carveouts: it does not carry EA4-321"
  if !defined &ea_podman::subids::ensure_user_manager_carveouts;

my $masked_at_start = ea_podman::subids::user_manager_mask_file() ? 1 : 0;
plan skip_all => "user\@.service is not masked. Install and initialise CageFS, or set EA4321_TOGGLE_MASK=1 to let this test mask it"
  if !$masked_at_start && !$TOGGLE;

my $systemd_version = ( `systemctl --version` =~ /systemd (\d+)/ )[0] // '?';

#---------------------------------------------------------------------
# reboot phase 2 is its own short run
#---------------------------------------------------------------------
if ( $REBOOT eq 'verify' ) {
    diag("systemd $systemd_version: EA4-321 reboot verify");

    ok( !-e "$UNIT_DIR/user\@" . _uid('ea4321a') . ".service", "after the reboot /run is empty: no unit left for ea4321a" );

    my $result = ea_podman::subids::ensure_user_sessions(qw(ea4321a ea4321b));
    is_deeply( $result, { ea4321a => 'started', ea4321b => 'started' }, "the boot sweep brings both managers up" );

    for my $user (qw(ea4321a ea4321b)) {
        my $uid = _uid($user);
        ok( -f "$UNIT_DIR/user\@$uid.service" && !-l "$UNIT_DIR/user\@$uid.service", "$user: the sweep wrote the unit again, as a real file" );
        ok( -d "/run/user/$uid" && -S "/run/user/$uid/bus", "$user: runtime dir and bus" );
    }

    _sh('systemctl daemon-reload');
    sleep 2;
    ok( -d '/run/user/' . _uid('ea4321a'), "and a host daemon-reload does not take it away" );

    _teardown();
    done_testing();
    exit;
}

#---------------------------------------------------------------------
# setup
#---------------------------------------------------------------------
diag("systemd $systemd_version, template " . ( $masked_at_start ? "masked at $MASK_ETC" : "NOT masked (EA4321_TOGGLE_MASK will mask it)" ));

_teardown();    # anything a previous aborted run left

for my $user (@USERS) {
    _sh("useradd -m $user") == 0 or BAIL_OUT("could not create $user");
}
my %uid = map { $_ => _uid($_) } @USERS;

my $mask_was_ours;
if ( !$masked_at_start ) {
    _sh("systemctl mask user\@.service") == 0 or BAIL_OUT("could not mask user\@.service");
    $mask_was_ours = 1;
}

END {
    return if $KEEP || $REBOOT eq 'prepare';
    _teardown();
    _teardown_mask() if $mask_was_ours;
}

my $mask_file = ea_podman::subids::user_manager_mask_file();
my $mask_before = _describe($mask_file);

sub _up { my $uid = $_[0]; return ( -d "/run/user/$uid" && -S "/run/user/$uid/bus" && _sh("systemctl is-active --quiet user\@$uid.service") == 0 ) ? 1 : 0 }

#---------------------------------------------------------------------
# 1. bootstrap A
#---------------------------------------------------------------------
subtest '1. bootstrapping an account starts its manager' => sub {
    eval { ea_podman::subids::ensure_user_session('ea4321a'); 1 } or fail("ensure_user_session died: $@");

    ok( -d "/run/user/$uid{ea4321a}", 'runtime dir exists' );
    ok( -S "/run/user/$uid{ea4321a}/bus", 'session bus exists' );
    is( _sh("systemctl is-active --quiet user\@$uid{ea4321a}.service"), 0, 'user@<uid>.service is active' );

    my $unit = "$UNIT_DIR/user\@$uid{ea4321a}.service";
    ok( -f $unit && !-l $unit, 'the account has a unit file of its own, and it is a real file' );
    is( _describe( ea_podman::subids::user_manager_mask_file() ), $mask_before, 'the template mask is exactly what it was' );
};

#---------------------------------------------------------------------
# 2. survives the thing that used to kill it
#---------------------------------------------------------------------
subtest '2. the manager survives time and a host daemon-reload' => sub {
    sleep 3;
    ok( _up( $uid{ea4321a} ), 'still up after 3s' );

    _sh('systemctl daemon-reload');
    sleep 2;
    ok( _up( $uid{ea4321a} ), 'still up after a host-wide systemctl daemon-reload' );

    _sh('systemctl daemon-reload');
    _sh('systemctl daemon-reload');
    sleep 2;
    ok( _up( $uid{ea4321a} ), 'and after two more' );
};

#---------------------------------------------------------------------
# 3. a second account does not disturb the first
#---------------------------------------------------------------------
subtest '3. bootstrapping a second account leaves the first alone' => sub {
    my $started = _manager_start_time( $uid{ea4321a} );

    eval { ea_podman::subids::ensure_user_session('ea4321b'); 1 } or fail("ensure_user_session(ea4321b) died: $@");

    ok( _up( $uid{ea4321b} ), 'the second account is up' );
    sleep 2;
    ok( _up( $uid{ea4321a} ), 'the first is still up' );
    is( _manager_start_time( $uid{ea4321a} ), $started, 'and was not restarted in the meantime' );
};

#---------------------------------------------------------------------
# 4. an account nobody bootstrapped is still refused
#---------------------------------------------------------------------
subtest '4. the template mask still refuses an account that was not bootstrapped' => sub {
    ok( !-e "$UNIT_DIR/user\@$uid{ea4321c}.service", 'it has no unit of its own' );

    my $out = `systemctl start user\@$uid{ea4321c}.service 2>&1`;
    isnt( $? >> 8, 0, 'the start fails' );
    like( $out, qr/masked/i, 'because the unit is masked' );
    ok( !-d "/run/user/$uid{ea4321c}", 'and no runtime dir appears for it' );
    is( _describe( ea_podman::subids::user_manager_mask_file() ), $mask_before, 'the mask is still exactly what it was' );
};

#---------------------------------------------------------------------
# 6. a healthy account is left alone
#---------------------------------------------------------------------
subtest '6. re-running the bootstrap for a healthy account changes nothing' => sub {
    my $unit  = "$UNIT_DIR/user\@$uid{ea4321a}.service";
    my $mtime = ( stat $unit )[9];
    my $start = _manager_start_time( $uid{ea4321a} );

    eval { ea_podman::subids::ensure_user_session('ea4321a'); 1 } or fail("ensure_user_session died: $@");

    is( ( stat $unit )[9], $mtime, 'the unit was not rewritten' );
    is( _manager_start_time( $uid{ea4321a} ), $start, 'the manager was not restarted' );
    ok( _up( $uid{ea4321a} ), 'and is up' );
};

#---------------------------------------------------------------------
# 6b. an administrator's mask of one account is not undone
#---------------------------------------------------------------------
subtest '6b. an explicit per-user mask is left alone, and the manager is not started' => sub {
    my $unit = "$UNIT_DIR/user\@$uid{ea4321c}.service";
    ok( symlink( "/dev/null", $unit ), 'the administrator masks this one account' );
    _sh('systemctl daemon-reload');

    my $ok = eval { ea_podman::subids::ensure_user_session('ea4321c'); 1 };
    ok( !$ok, 'bootstrapping it is refused' ) or diag("it returned without dying");
    like( $@, qr/was not written by ea-podman/, 'and says why' );

    ok( -l $unit && readlink($unit) eq '/dev/null', 'the mask is still there' );
    ok( !_up( $uid{ea4321c} ), 'no manager was started' );
    ok( !-d "/run/user/$uid{ea4321c}", 'and no runtime dir appeared' );

    my $swept = eval { ea_podman::subids::ensure_user_manager_carveouts( $uid{ea4321a}, $uid{ea4321c} ) };
    ok( -l $unit && readlink($unit) eq '/dev/null', 'a batch that includes it leaves the mask in place too' );
    ok( _up( $uid{ea4321a} ), 'while the other account in the batch is unaffected' );

    is( ea_podman::subids::remove_user_manager_carveout( $uid{ea4321c} ), 0, 'releasing it does not remove the mask' );
    ok( -l $unit, 'still there' );

    unlink $unit;
    _sh('systemctl daemon-reload');
    ok( !-e $unit, 'cleaned up (the administrator lifting the mask)' );
};

#---------------------------------------------------------------------
# 7. release
#---------------------------------------------------------------------
subtest '7. releasing an account stops its manager and takes its unit back' => sub {
    my $released = ea_podman::subids::remove_user_session('ea4321a');
    ok( $released, 'linger removed' );

    my $down = 0;
    for ( 1 .. 30 ) { if ( _sh("systemctl is-active --quiet user\@$uid{ea4321a}.service") != 0 ) { $down = 1; last } select( undef, undef, undef, 0.5 ) }
    ok( $down, 'the manager is stopped' );

    # No second call to the cleanup helper here: remove_user_session() waits for
    # the manager to stop and takes the unit back itself, and leaves a note for
    # the next release or sweep when it cannot. This asserts the former, and
    # subtest 7b the latter.
    ok( !-e "$UNIT_DIR/user\@$uid{ea4321a}.service", 'its unit is gone' );

    my $out = `systemctl start user\@$uid{ea4321a}.service 2>&1`;
    isnt( $? >> 8, 0, 'and it is refused again, as any other account' );
    like( $out, qr/masked/i, 'because the template is masked' );

    ok( _up( $uid{ea4321b} ), 'the other account is unaffected' );
    is( _describe( ea_podman::subids::user_manager_mask_file() ), $mask_before, 'the mask is still exactly what it was' );
};

#---------------------------------------------------------------------
# 7a. an administrator's mask put over a unit ea-podman wrote
#---------------------------------------------------------------------
subtest '7a. a mask put over a unit ea-podman wrote is neither overwritten, removed, nor starved of the rest of the sweep' => sub {
    my $unit = "$UNIT_DIR/user\@$uid{ea4321c}.service";
    my $wait_down = sub { my $id = shift; for ( 1 .. 30 ) { return 1 if _sh("systemctl is-active --quiet user\@$id.service") != 0; select( undef, undef, undef, 0.5 ) } return 0 };

    eval { ea_podman::subids::ensure_user_session('ea4321c'); 1 } or return fail("could not set the account up: $@");
    ok( -f $unit && !-l $unit, 'precondition: ea-podman wrote a real unit for it' );
    ok( -e "/run/ea-podman/written/$uid{ea4321c}", 'and is holding a marker that says so' );

    # The administrator replaces ea-podman's unit with a mask of this account.
    ok( unlink($unit) && symlink( "/dev/null", $unit ), 'the administrator replaces the unit with a mask' );

    # Releasing the account stops its manager, then asks for the unit back.
    ok( ea_podman::subids::remove_user_session('ea4321c'), 'the account is released' );
    ok( $wait_down->( $uid{ea4321c} ), 'its manager is stopped' );
    ok( -l $unit && readlink($unit) eq '/dev/null', 'the release did not remove the administrator\'s mask, marker or no marker' );

    # A sweep over the masked account and one that needs a manager: the
    # masked one is set aside, the other one still comes up.
    my $warned = '';
    my $result;
    {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        $result = ea_podman::subids::ensure_user_sessions(qw(ea4321c ea4321a));
    }
    is( $result->{ea4321c}, 'failed',  'the masked account is reported failed' );
    is( $result->{ea4321a}, 'started', 'the other account is started regardless' );
    ok( _up( $uid{ea4321a} ), 'and really is up' );
    ok( -l $unit && readlink($unit) eq '/dev/null', 'the mask was not overwritten by the sweep' );
    ok( !_up( $uid{ea4321c} ), 'the masked account has no manager' );
    like( $warned, qr/was not written by ea-podman/, 'and the refusal was reported' );

    # Same again with the mask as an empty file, the other form systemd honours.
    unlink $unit;
    my $fh;
    my $empty_ok = open( $fh, ">", $unit ) && close($fh);
    ok( $empty_ok, 'the administrator replaces it with an empty unit instead' );
    eval { ea_podman::subids::ensure_user_manager_carveouts( $uid{ea4321c} ) };
    like( $@, qr/was not written by ea-podman/, 'that is refused too' );
    ok( -f $unit && -z $unit, 'and left as it was' );

    unlink $unit;
    _sh('systemctl daemon-reload');
    ok( ea_podman::subids::remove_user_session('ea4321a'), 'cleanup: releasing the other account' );
    $wait_down->( $uid{ea4321a} );
};

#---------------------------------------------------------------------
# 7b. a release while a login session holds the manager
#---------------------------------------------------------------------
subtest '7b. a release under a login session is finished by the next call, not lost' => sub {
    my $written = "/run/ea-podman/written/$uid{ea4321a}";
    my $unit    = "$UNIT_DIR/user\@$uid{ea4321a}.service";

    eval { ea_podman::subids::ensure_user_session('ea4321a'); 1 } or return fail("could not set the account up again: $@");
    ok( -e $unit, 'precondition: the account has its unit again' );

    # A login session is what keeps user@<uid> up after linger is taken away.
    # It has to be a real one: `runuser -l` does not create a logind session (the
    # process lands in the manager's own cgroup), so the manager stops within a
    # second of the linger going and there is nothing to hold it. sshd does create
    # one, through pam_systemd, so the session is opened with an ssh to localhost.
    my ( $pid, $why ) = _hold_login_session( 'ea4321a', 40 );
    return plan( skip_all => "could not open a real login session for ea4321a: $why" ) if !$pid;

    my $sessions = _login_sessions( $uid{ea4321a} );
    cmp_ok( scalar @$sessions, '>=', 1, "precondition: logind has a login session for the account (@$sessions)" ) or do { kill 'TERM', $pid; waitpid( $pid, 0 ); return };

    is( ea_podman::subids::_user_manager_confirmed_stopped( $uid{ea4321a} ), 0, 'a running manager is not confirmed stopped' );

    ok( ea_podman::subids::remove_user_session('ea4321a'), 'the release itself succeeds: linger is gone' );
    is( _sh("systemctl is-active --quiet user\@$uid{ea4321a}.service"), 0, 'the session really does hold the manager up after the release' );
    ok( -e $unit,    'the unit is kept under the live manager' );
    ok( -e $written, 'and the record that it is ours, which is what the next reconcile goes by' );

    # What every release and every sweep does first. Nothing is removed while the
    # manager is up, and the unit and record survive being asked.
    is( ea_podman::subids::reconcile_carveouts(), 0, 'a sweep removes nothing while the session holds the manager' );
    ok( -e $unit && -e $written, 'unit and record are both still there' );

    kill 'TERM', $pid;
    waitpid( $pid, 0 );
    my $down = 0;
    for ( 1 .. 30 ) { if ( _sh("systemctl is-active --quiet user\@$uid{ea4321a}.service") != 0 ) { $down = 1; last } select( undef, undef, undef, 0.5 ) }
    ok( $down, 'the manager stops once the login session ends' );

    # A stopped manager can still report `deactivating` for a moment; wait for the
    # state the code insists on before asking it to act.
    for ( 1 .. 30 ) { last if ea_podman::subids::_user_manager_confirmed_stopped( $uid{ea4321a} ); select( undef, undef, undef, 0.5 ) }
    is( ea_podman::subids::_user_manager_confirmed_stopped( $uid{ea4321a} ), 1, 'a stopped manager is confirmed stopped' );

    is( ea_podman::subids::reconcile_carveouts(), 1, 'the next sweep removes the unit' );
    ok( !-e $unit,    'the unit is gone' );
    ok( !-e $written, 'and so is the record' );
};

#---------------------------------------------------------------------
# 8. an unmasked host gets nothing
#---------------------------------------------------------------------
SKIP: {
    skip 'set EA4321_TOGGLE_MASK=1 to test an unmasked host', 3 if !$TOGGLE || $REBOOT eq 'prepare';

    # CageFS re-applies its mask on every install and upgrade, and CloudLinux's
    # `disable-systemd-user-mask` flag leaves a host unmasked until someone takes
    # it away. On systemd 252 the mask arriving tears down every manager that has
    # no unit of its own, which is what CloudLinux hit on their server.
    my $unmask = sub {
        _sh("loginctl disable-linger ea4321b ea4321c");
        _sh("systemctl stop user\@$uid{ea4321b}.service user\@$uid{ea4321c}.service");
        _sh("rm -f $UNIT_DIR/user\@*.service");
        _sh("systemctl unmask user\@.service") if ea_podman::subids::user_manager_mask_file();
        _sh("rm -f $MASK_ETC");
        _sh('systemctl daemon-reload');
        return ea_podman::subids::user_manager_mask_file() ? 0 : 1;
    };
    my $remask = sub { _sh("systemctl mask user\@.service"); sleep 2; return };

    subtest '8. a manager ea-podman starts on an unmasked host survives the mask arriving' => sub {
        ok( $unmask->(), 'precondition: the template is not masked' );

        eval { ea_podman::subids::ensure_user_session('ea4321c'); 1 } or fail("ensure_user_session died: $@");

        ok( _up( $uid{ea4321c} ), 'the account is up' );
        ok( -f "$UNIT_DIR/user\@$uid{ea4321c}.service" && !-l "$UNIT_DIR/user\@$uid{ea4321c}.service", 'and has a unit of its own, written although the host is not masked' );

        $remask->();
        ok( ea_podman::subids::user_manager_mask_file(), 'the template is masked now, as a cagefs install or upgrade would do' );
        ok( _up( $uid{ea4321c} ), 'and the manager is still up' );
    };

    subtest '9. a manager logind started on an unmasked host is protected by the boot sweep' => sub {
        ok( $unmask->(), 'precondition: the template is not masked' );

        # What logind does at boot for a lingering account, with no ea-podman involved.
        _sh("loginctl enable-linger ea4321b");
        my $up = 0;
        for ( 1 .. 20 ) { if ( _up( $uid{ea4321b} ) ) { $up = 1; last } select( undef, undef, undef, 0.5 ) }
        ok( $up, 'logind started the manager' );
        ok( !-e "$UNIT_DIR/user\@$uid{ea4321b}.service", 'and it has no unit of its own' );

        my $result = ea_podman::subids::ensure_user_sessions('ea4321b');
        is_deeply( $result, { ea4321b => 'ok' }, 'the sweep finds it healthy and starts nothing' );
        ok( -f "$UNIT_DIR/user\@$uid{ea4321b}.service", 'but gives it its unit' );
        ok( _up( $uid{ea4321b} ), 'and that did not disturb it' );

        $remask->();
        ok( _up( $uid{ea4321b} ), 'the manager survives the mask arriving' );
    };

    subtest '10. a mask left lifted by a killed pre-EA4-321 run is put back without taking logind-started managers down' => sub {
        ok( $unmask->(), 'precondition: the template is not masked' );

        # As case 9: a manager logind started, with no unit of its own.
        _sh("loginctl enable-linger ea4321b");
        my $up = 0;
        for ( 1 .. 20 ) { if ( _up( $uid{ea4321b} ) ) { $up = 1; last } select( undef, undef, undef, 0.5 ) }
        ok( $up, 'logind started a manager for the lingering account' );
        ok( !-e "$UNIT_DIR/user\@$uid{ea4321b}.service", 'and it has no unit of its own' );

        # What an older version killed inside its unmask window leaves behind.
        no warnings qw(once);
        my $state = $ea_podman::subids::file_mask_state;
        open( my $fh, '>', $state ) or return fail("could not write $state: $!");
        print {$fh} "$MASK_ETC\n";
        close $fh;

        # Any cold bootstrap, for an unrelated account, is what finds it.
        eval { ea_podman::subids::ensure_user_session('ea4321c'); 1 } or fail("ensure_user_session died: $@");

        ok( ea_podman::subids::user_manager_mask_file(), 'the template mask is back' );
        ok( !-e $state, 'and the record of the abandoned window is gone' );
        ok( -f "$UNIT_DIR/user\@$uid{ea4321b}.service", 'the logind-started manager was given its unit first' );
        ok( _up( $uid{ea4321b} ), 'and survived the mask going back' ) or diag( `systemctl status user\@$uid{ea4321b}.service 2>&1 | head -5` );
        ok( _up( $uid{ea4321c} ), 'while the account being set up is up too' );
    };

    # back to how this run found it
    if ($masked_at_start) { _sh("systemctl mask user\@.service") }
    else                  { $mask_was_ours = 1 }
}

#---------------------------------------------------------------------
# reboot phase 1
#---------------------------------------------------------------------
if ( $REBOOT eq 'prepare' ) {
    ea_podman::subids::ensure_user_session('ea4321a');
    ea_podman::subids::ensure_user_session('ea4321b');
    diag("EA4321_REBOOT=prepare done. Reboot the VM, then run with EA4321_REBOOT=verify.");
}

done_testing();
exit;

#---------------------------------------------------------------------
# helpers
#---------------------------------------------------------------------
sub _sh      { system( "sh", "-c", "$_[0] >/dev/null 2>&1" ); return $? >> 8 }
sub _uid     { return scalar( ( getpwnam( $_[0] ) )[2] ) }
sub _which   { for my $d ( split /:/, $ENV{PATH} || '/usr/bin:/bin:/usr/sbin:/sbin' ) { return "$d/$_[0]" if -x "$d/$_[0]" } return }

sub _describe {
    my ($file) = @_;
    return 'none' if !defined $file;
    return "$file -> " . ( readlink($file) // '(regular file)' ) . ( -l $file ? '' : ' size ' . ( -s $file ) );
}

sub _manager_start_time {
    my ($uid) = @_;
    chomp( my $t = `systemctl show -p ActiveEnterTimestampMonotonic --value user\@$uid.service 2>/dev/null` );
    return $t;
}

# Open a real logind login session for $user by ssh-ing to localhost with a
# throwaway key, running `sleep $seconds` in it. Returns the pid of the ssh, or
# ( undef, reason ) when it cannot be done, so the caller can skip with the reason
# instead of failing for an environmental cause.
sub _hold_login_session {
    my ( $user, $seconds ) = @_;

    return ( undef, 'no ssh client' )                      if !_which('ssh') || !_which('ssh-keygen');
    return ( undef, 'sshd is not running' )                if _sh('systemctl is-active --quiet sshd') != 0 && _sh('systemctl is-active --quiet ssh') != 0;

    my $dir = '/root/.ea4321-ssh';
    _sh("rm -rf $dir; mkdir -m 700 $dir") == 0 or return ( undef, "cannot create $dir" );
    _sh("ssh-keygen -q -t ed25519 -N '' -f $dir/key") == 0 or return ( undef, 'ssh-keygen failed' );

    my $home = ( getpwnam($user) )[7];
    _sh("mkdir -p $home/.ssh && cat $dir/key.pub >> $home/.ssh/authorized_keys && chmod 700 $home/.ssh && chmod 600 $home/.ssh/authorized_keys && chown -R $user: $home/.ssh") == 0
      or return ( undef, "cannot install the key for $user" );

    # A quick check that the login works at all, so a refusal is reported as one.
    my $opts = "-i $dir/key -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR";
    my $check = `ssh $opts $user\@localhost true 2>&1`;
    if ( $? != 0 ) {
        $check =~ s/\s+/ /g;
        return ( undef, "ssh to $user\@localhost was refused: $check" );
    }

    my $pid = fork() // return ( undef, "fork: $!" );
    if ( !$pid ) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec( 'sh', '-c', "exec ssh -tt $opts $user\@localhost 'sleep $seconds'" ) or exit 1;
    }

    # -tt gives the remote command a pty, so killing this ssh hangs it up and the
    # session ends with it. Without one the remote sleep outlives the client and
    # the session, and with it the manager, lasts until the sleep is done.
    # Give sshd a moment to get as far as its PAM session.
    for ( 1 .. 20 ) { last if @{ _login_sessions( _uid($user) ) }; select( undef, undef, undef, 0.5 ) }

    return $pid;
}

# logind's login sessions (Class=user) for a uid. The user manager has a session
# of its own on newer systemd (Class=manager), which holds nothing and is skipped.
sub _login_sessions {
    my ($uid) = @_;

    my @found;
    for my $line ( `loginctl list-sessions --no-legend 2>/dev/null` ) {
        my ( $id, $sess_uid ) = split ' ', $line;
        next if !defined $sess_uid || $sess_uid ne $uid;
        chomp( my $class = `loginctl show-session $id -p Class --value 2>/dev/null` );
        push @found, $id if $class eq 'user';
    }

    return \@found;
}

sub _teardown {
    _sh('rm -rf /root/.ea4321-ssh');
    for my $user (@USERS) {
        next if !defined scalar getpwnam($user);
        my $uid = _uid($user);
        _sh("loginctl disable-linger $user");
        _sh("systemctl stop user\@$uid.service");
        unlink "$UNIT_DIR/user\@$uid.service";
        unlink "/run/ea-podman/written/$uid";
        _sh("userdel -r $user");
    }
    return;
}

sub _teardown_mask {
    _sh("systemctl unmask user\@.service");
    _sh("rm -f $MASK_ETC");
    _sh('systemctl daemon-reload');
    return;
}
