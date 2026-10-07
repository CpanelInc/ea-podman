#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# EA4-321 — LIVE test of the account unit's lifecycle edges (NOT a unit test).
#
# WHAT THIS PROVES, against the real systemd on the host, with the
# `user@.service` template masked (CageFS 7.6.39+):
#
#   A. A release that arrives while setup has written an account's unit
#      but not yet started its manager waits for the start, and leaves
#      the unit alone. (Setup holds the carveout lock from the unit write
#      to a started manager.)
#   B. A deleted account's unit is found among the units ea-podman wrote by
#      its uid no longer resolving, and is taken back once its manager is
#      confirmed stopped.
#   C. An account that later reuses the uid inherits no unit: systemd
#      still refuses to start its manager as it does for any other
#      account.
#   D. A setup that dies after writing the unit (daemon-reload failing) takes
#      the unit back itself, rather than leaving an exception to the mask
#      that nothing will release.
#   E. A running manager that has no unit of its own (one that predates this
#      version) is given one by an ordinary command, without being restarted.
#   F. A boot sweep whose enable-linger and manager start both report failure by
#      returning false (not by dying) takes the account's unit back.
#
# Not covered here: a deleted account whose manager is still up. userdel -f
# kills the manager, so a real account cannot be held up past its deletion
# without a login session; t/SOURCES-subids-carveout-lifecycle.t covers the
# kept-unit and reconcile path with a stubbed manager.
#
# WHERE TO RUN. A disposable cPanel VM with the template masked, as root.
# Creates throwaway users ea4321r/d/e/f/g/h and removes them afterwards. Needs the
# ea-podman build under test (release_deleted_user_carveout must exist).
#
# COPY AND RUN
#
#   scp ea4-321-lifecycle-live.t root@VM:/root/
#   ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl /root/ea4-321-lifecycle-live.t'
#
# To test a SOURCES/subids.pm that is not installed yet, copy it to
# <dir>/ea_podman/subids.pm on the VM and add EAPODMAN_LIB=<dir>.
#
# Environment variables:
#   EAPODMAN_LIVE=1   REQUIRED opt-in.
#   EAPODMAN_LIB      directory holding ea_podman/subids.pm to test
#                     (default /opt/cpanel/ea-podman/lib).
#   EAPODMAN_KEEP=1   skip teardown.
#
# LEAVES BEHIND. Nothing: users, homes, linger and units are removed.
#######################################################################

use strict;
use warnings;

use Test::More;
use POSIX ();
use Time::HiRes ();

BEGIN {
    plan skip_all => 'set EAPODMAN_LIVE=1 to run this live test on a disposable cPanel VM' if !$ENV{EAPODMAN_LIVE};
}

my $LIB   = $ENV{EAPODMAN_LIB} || '/opt/cpanel/ea-podman/lib';
my $KEEP  = $ENV{EAPODMAN_KEEP};
my @USERS = qw(ea4321r ea4321d ea4321e ea4321f ea4321g ea4321h);

my $UNIT_DIR = '/run/systemd/system';
my $STATE    = '/run/ea-podman';

plan skip_all => 'must run as root'                    if $> != 0;
plan skip_all => 'no systemctl: this needs systemd'    if !_which('systemctl');
plan skip_all => 'no useradd'                          if !_which('useradd');
plan skip_all => "no $LIB/ea_podman/subids.pm to test" if !-f "$LIB/ea_podman/subids.pm";

unshift @INC, $LIB;
require ea_podman::subids;

plan skip_all => "ea_podman::subids under $LIB has no release_deleted_user_carveout: it does not carry this change"
  if !defined &ea_podman::subids::release_deleted_user_carveout;

plan skip_all => "user\@.service is not masked. Install and initialise CageFS first"
  if !ea_podman::subids::user_manager_mask_file();

_teardown();    # anything a previous aborted run left

END { _teardown() if !$KEEP }

for my $user (@USERS) {
    next if $user eq 'ea4321e';    # created later, to take a uid over
    _sh("useradd -m $user") == 0 or BAIL_OUT("could not create $user");
}

sub _unit { return "$UNIT_DIR/user\@$_[0].service" }

sub _active { return _sh("systemctl is-active --quiet user\@$_[0].service") == 0 ? 1 : 0 }

sub _wait_stopped {
    my ($uid) = @_;
    for ( 1 .. 60 ) {
        return 1 if !_active($uid) && ea_podman::subids::_user_manager_confirmed_stopped($uid);
        select( undef, undef, undef, 0.5 );
    }
    return 0;
}

#---------------------------------------------------------------------
# A. a release in the window between the unit write and the start
#---------------------------------------------------------------------
subtest 'A. a release waits for a setup that has not started the manager yet' => sub {
    my $uid  = _uid('ea4321r');
    my $unit = _unit($uid);

    # Widen the window the race lives in: the real start, three seconds late.
    my $delay = 3;
    my $real  = $ea_podman::subids::user_manager_starter;

    no warnings qw(once redefine);
    local $ea_podman::subids::user_manager_starter = sub { sleep $delay; return $real->(@_) };

    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {

        # _exit, not exit: the END block below tears the whole test down.
        eval { ea_podman::subids::ensure_user_session('ea4321r'); 1 } or do { print STDERR "setup died: $@"; POSIX::_exit(1) };
        POSIX::_exit(0);
    }

    my $seen = 0;
    for ( 1 .. 100 ) {
        if ( -f $unit ) { $seen = 1; last }
        select( undef, undef, undef, 0.05 );
    }
    ok( $seen, 'setup has written the unit' ) or do { waitpid( $pid, 0 ); return };
    ok( !_active($uid), 'and the manager is not running yet' );

    my $t0      = Time::HiRes::time();
    my $removed = ea_podman::subids::remove_user_manager_carveout($uid);
    my $waited  = Time::HiRes::time() - $t0;

    waitpid( $pid, 0 );
    is( $? >> 8, 0, 'setup finished cleanly' );

    cmp_ok( $waited, '>=', 1.5, sprintf( 'the release waited for the start (%.1fs)', $waited ) );
    is( $removed, 0, 'and then removed nothing' );
    ok( -f $unit, 'the unit is still there' );
    ok( _active($uid), 'under a running manager' ) or diag( `systemctl status user\@$uid.service 2>&1` );
    ok( -d "/run/user/$uid" && -S "/run/user/$uid/bus", 'with its runtime dir and bus' );

    ea_podman::subids::remove_user_session('ea4321r');
    _wait_stopped($uid);
};

#---------------------------------------------------------------------
# B. a deleted account, manager stopped
#---------------------------------------------------------------------
my $reuse_uid;

subtest "B. a deleted account's unit is found by its uid no longer resolving, and taken back" => sub {
    my $uid  = _uid('ea4321d');
    my $unit = _unit($uid);

    eval { ea_podman::subids::ensure_user_session('ea4321d'); 1 } or return fail("setup died: $@");
    ok( -f $unit && _active($uid), 'precondition: the account has a unit and a running manager' );
    ok( -s "$STATE/written/$uid", 'the unit was recorded as ours when it was written' );

    # Take the manager down and then the account, as a deletion would.
    ea_podman::subids::remove_user_session('ea4321d');    # also takes the unit; put it back for the test
    ok( _wait_stopped($uid), 'the manager is stopped' );
    ea_podman::subids::ensure_user_manager_carveout($uid);
    _sh("userdel -rf ea4321d >/dev/null 2>&1");

    ok( !defined( ( getpwnam('ea4321d') )[2] ), 'the account no longer resolves' );
    ok( -f $unit, 'but its unit is still on disk' );

    ok( ea_podman::subids::release_deleted_user_carveout('ea4321d'), 'the deleted-account release finds it' );

    ok( !-e $unit,                 'the unit is gone' );
    ok( !-e "$STATE/written/$uid", 'and so is the record of it' );

    $reuse_uid = $uid;
};

#---------------------------------------------------------------------
# C. the uid is reused
#---------------------------------------------------------------------
subtest 'C. an account that reuses the uid inherits no exception to the mask' => sub {
    return plan( skip_all => 'subtest B did not leave a uid to reuse' ) if !defined $reuse_uid;

    _sh("useradd -m -u $reuse_uid ea4321e") == 0 or return fail("could not create ea4321e with uid $reuse_uid");

    ok( !-e _unit($reuse_uid), 'no unit exists for the reused uid' );

    my $out = `systemctl start user\@$reuse_uid.service 2>&1`;
    isnt( $? >> 8, 0, 'systemd refuses to start its manager' );
    like( $out, qr/masked/i, 'because the template is masked, as for any account ea-podman did not set up' );
};

#---------------------------------------------------------------------
# D. setup dies after the unit is written
#---------------------------------------------------------------------
subtest 'D. a setup that fails after writing the unit takes it back' => sub {
    my $uid  = _uid('ea4321f');
    my $unit = _unit($uid);

    no warnings qw(once redefine);
    local $ea_podman::subids::daemon_reloader = sub { 0 };
    local $SIG{__WARN__} = sub { };

    ok( !eval { ea_podman::subids::ensure_user_session('ea4321f'); 1 }, 'setup dies when daemon-reload fails' );
    like( $@, qr/daemon-reload/, 'with the reload error' );
    ok( !lstat($unit), 'and the unit it wrote is not left behind' );
    ok( !_active($uid), 'no manager was started' );
    ok( !ea_podman::subids::user_has_linger('ea4321f'), 'and no linger was granted' );
};

#---------------------------------------------------------------------
# E. a running manager with no unit of its own
#---------------------------------------------------------------------
subtest 'E. a running manager without a unit is given one, and not restarted' => sub {
    my $uid  = _uid('ea4321g');
    my $unit = _unit($uid);

    eval { ea_podman::subids::ensure_user_session('ea4321g'); 1 } or return fail("setup died: $@");
    ok( -f $unit && _active($uid), 'precondition: a running manager with its unit' );

    chomp( my $pid = `systemctl show -p MainPID --value user\@$uid.service` );
    ok( $pid, "its manager is pid $pid" );

    # A manager from before this version: running, and no unit on disk. Not
    # reloaded, which is what would tear it down.
    unlink $unit;
    ok( _active($uid), 'still running without the unit, as long as nothing reloads' );

    ok( eval { ea_podman::subids::ensure_user_session('ea4321g'); 1 }, 'an ordinary command succeeds' ) or diag $@;

    ok( -f $unit, 'and the manager has its unit again' );
    ok( _active($uid), 'still running' );
    chomp( my $after = `systemctl show -p MainPID --value user\@$uid.service` );
    is( $after, $pid, 'the same process: it was not restarted' );
    ok( -d "/run/user/$uid" && -S "/run/user/$uid/bus", 'runtime dir and bus intact after the reload' );

    # What the unit is for: a remask-style reload no longer takes it down.
    _sh('systemctl daemon-reload');
    ok( _active($uid), 'and it survives another daemon-reload' );

    ea_podman::subids::remove_user_session('ea4321g');
    _wait_stopped($uid);
};

#---------------------------------------------------------------------
# F. a sweep whose wrappers return false rather than die
#---------------------------------------------------------------------
subtest 'F. a sweep whose linger and start both return false takes the unit back' => sub {
    my $uid  = _uid('ea4321h');
    my $unit = _unit($uid);

    my $wrote_unit;

    no warnings qw(once redefine);
    local $ea_podman::subids::linger_enabler       = sub { return 0 };
    local $ea_podman::subids::user_manager_starter = sub { $wrote_unit = -f $unit ? 1 : 0; return 0 };
    local $SIG{__WARN__} = sub { };

    my $result = eval { ea_podman::subids::ensure_user_sessions('ea4321h') };
    ok( defined $result, 'the sweep returns rather than dies' ) or diag $@;
    is( $result && $result->{ea4321h}, 'failed', 'and reports the account failed' );
    ok( $wrote_unit, 'the unit was in place when the start was attempted' );
    ok( !lstat($unit), 'and is not left behind afterwards' );
    ok( !_active($uid), 'no manager is running' );
    ok( !ea_podman::subids::user_has_linger('ea4321h'), 'and no linger was granted' );
};

done_testing();

#---------------------------------------------------------------------

sub _teardown {
    for my $user (@USERS) {
        my $uid = ( getpwnam($user) )[2];
        _sh("loginctl disable-linger $user >/dev/null 2>&1") if defined $uid;
        if ( defined $uid ) {
            _sh("systemctl stop user\@$uid.service >/dev/null 2>&1");
            unlink _unit($uid);
        }
        _sh("userdel -rf $user >/dev/null 2>&1") if defined $uid;
        unlink "$STATE/written/$uid" if defined $uid;
    }
    _sh('systemctl daemon-reload >/dev/null 2>&1');
    return;
}

sub _uid { return ( getpwnam( $_[0] ) )[2] // die "no such user $_[0]\n" }

sub _sh { return system( "sh", "-c", $_[0] ) >> 8 }

sub _which { my ($c) = @_; for my $d ( split /:/, $ENV{PATH} ) { return "$d/$c" if -x "$d/$c" } return }
