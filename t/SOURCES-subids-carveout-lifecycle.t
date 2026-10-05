#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-subids-carveout-lifecycle.t  Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# EA4-321: an account's own user@<uid>.service unit is what lets its manager
# start while the template is masked. Two ways it used to be taken away or left
# behind wrongly:
#
#   * a release that finds the manager stopped removes the unit, and a manager
#     that setup has not started yet is exactly that. Setup holds the carveout
#     lock from the unit write to a started manager so the release waits.
#   * an account deleted outright cannot be looked up, so its unit was never
#     found, and survived to be inherited by whoever got the uid next.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;
use POSIX ();

use Path::Tiny ();

our %uid_for;    # user => uid, for the mocked getpwnam

BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        my ($user) = @_;
        return if !exists $main::uid_for{$user};
        return ( $user, "x", $main::uid_for{$user}, 11004, 20, "", "", "/nonexistent/$user", "/bin/bash" );
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";
require "$FindBin::Bin/../SOURCES/subids.pm";

my @keep_alive;

# A scratch host: a masked template with a vendor unit to copy, and the state
# and unit directories pointed into a temporary directory.
sub _world {
    my $dir = File::Temp->newdir();
    push @keep_alive, $dir;

    for my $sub (qw(etc vendor run linger granted)) {
        mkdir "$dir/$sub";
    }

    my $vendor = "$dir/vendor/user\@.service";
    Path::Tiny::path($vendor)->spew_raw("[Unit]\nDescription=User Manager for UID %i\n");
    symlink( "/dev/null", "$dir/etc/user\@.service" ) or die "could not seed the mask: $!";

    no warnings qw(once);
    $ea_podman::subids::file_mask_etc          = "$dir/etc/user\@.service";
    $ea_podman::subids::file_mask_run          = "$dir/etc/never-masked-here";
    $ea_podman::subids::file_mask_state        = "$dir/mask.state";
    $ea_podman::subids::dir_unit_carveout      = "$dir/units";
    $ea_podman::subids::dir_carveout_state     = "$dir/state";
    $ea_podman::subids::dir_run                = "$dir/run";
    $ea_podman::subids::dir_linger             = "$dir/linger";
    $ea_podman::subids::dir_granted_linger     = "$dir/granted";
    @ea_podman::subids::files_vendor_unit      = ($vendor);
    $ea_podman::subids::daemon_reloader        = sub { 1 };
    $ea_podman::subids::poll_sleeper           = sub { select( undef, undef, undef, 0.02 ) };
    $ea_podman::subids::settle_iterations      = 1;
    $ea_podman::subids::uid_to_user            = sub { my ($uid) = @_; for my $u ( keys %main::uid_for ) { return $u if $main::uid_for{$u} == $uid } return };
    $ea_podman::util::known_containers_file    = "$dir/registered-containers.json";

    %main::uid_for = ();

    return $dir;
}

sub _wait_for {
    my ( $file, $what ) = @_;

    for ( 1 .. 250 ) {
        return 1 if -e $file;
        select( undef, undef, undef, 0.02 );
    }

    fail("timed out waiting for $what");
    return 0;
}

subtest 'a release cannot take the unit from a setup that has not started the manager yet' => sub {
    my $dir = _world();

    my ( $user, $uid ) = ( "racer", 11002 );
    $main::uid_for{$user} = $uid;

    no warnings qw(once);
    $ea_podman::subids::linger_enabler = sub { Path::Tiny::path("$dir/linger/$_[0]")->touch; 1 };

    # Stands in for systemd: the manager exists once the start job has finished.
    $ea_podman::subids::user_manager_is_active         = sub { -e "$dir/active" ? 1 : 0 };
    $ea_podman::subids::user_manager_confirmed_stopped = sub { -e "$dir/active" ? 0 : 1 };

    # Setup parks inside the start, with the unit on disk and no manager yet.
    $ea_podman::subids::user_manager_starter = sub {
        Path::Tiny::path("$dir/paused")->touch;
        _wait_for( "$dir/go", "the test to let the start finish" );
        Path::Tiny::path("$dir/run/$_[0]")->mkpath;
        Path::Tiny::path("$dir/run/$_[0]/bus")->touch;
        Path::Tiny::path("$dir/active")->touch;
        return 1;
    };

    my $unit = ea_podman::subids::user_manager_carveout_file($uid);

    my $setup = fork() // die "fork: $!";
    if ( !$setup ) {
        local $SIG{__WARN__} = sub { };
        eval { ea_podman::subids::ensure_user_session($user); 1 } or POSIX::_exit(1);
        POSIX::_exit(0);
    }

    ok( _wait_for( "$dir/paused", "setup to reach the start" ), "setup got as far as starting the manager" );
    ok( -f $unit, "and its unit is on disk while no manager is running" );

    # The release, arriving in that window.
    my $release = fork() // die "fork: $!";
    if ( !$release ) {
        local $SIG{__WARN__} = sub { };
        my $removed = eval { ea_podman::subids::remove_user_manager_carveout($uid) };
        Path::Tiny::path("$dir/release-result")->spew( defined $removed ? $removed : "died" );
        POSIX::_exit(0);
    }

    select( undef, undef, undef, 0.5 );
    ok( !-e "$dir/release-result", "the release is still waiting on setup" );
    ok( -f $unit, "and has not removed the unit" );

    Path::Tiny::path("$dir/go")->touch;
    waitpid( $setup,   0 );
    is( $?, 0, "setup finished cleanly" );
    waitpid( $release, 0 );

    is( Path::Tiny::path("$dir/release-result")->slurp, "0", "the release then found a running manager and removed nothing" );
    ok( -f $unit, "the unit the running manager depends on is still there" );
};

# A deleted account, set up as it would have been when it existed.
sub _provisioned_then_deleted {
    my (%opt) = @_;

    my $dir = _world();
    my ( $user, $uid ) = ( "gone", 11010 );

    ea_podman::subids::ensure_user_manager_carveouts($uid);

    if ( $opt{granted} ) {
        Path::Tiny::path("$dir/linger/$user")->touch;
        Path::Tiny::path("$dir/granted/$user")->touch;
    }

    ea_podman::util::register_container_as_root( "wordpress.$user.01", $user, 0, "redis:7", 1 );

    # %uid_for has no entry for "gone": getpwnam says the account is deleted.
    return ( $dir, $user, $uid );
}

subtest "a deleted account's unit is removed once its manager is stopped" => sub {
    my ( $dir, $user, $uid ) = _provisioned_then_deleted( granted => 1 );

    no warnings qw(once);
    $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };

    my $unit = ea_podman::subids::user_manager_carveout_file($uid);
    ok( -f $unit, "the unit exists before the account goes" );

    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "wordpress.$user.01", user => $user } );

    ok( !lstat($unit), "the unit is gone although the account cannot be looked up" );
    ok( !-e "$dir/state/written/$uid", "and so is the record of it" );

    # The uid is handed to a new account, which gets no exception it was not given.
    $main::uid_for{newcomer} = $uid;
    ok( !lstat( ea_podman::subids::user_manager_carveout_file( ( getpwnam("newcomer") )[2] ) ), "the account that reuses the uid inherits nothing" );
};

subtest 'a deleted account whose manager is still up is left for the reconciler' => sub {
    my ( $dir, $user, $uid ) = _provisioned_then_deleted( granted => 1 );

    no warnings qw(once);
    my $stopped = 0;
    $ea_podman::subids::user_manager_confirmed_stopped = sub { $stopped };

    my $unit = ea_podman::subids::user_manager_carveout_file($uid);

    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "wordpress.$user.01", user => $user } );

    ok( -f $unit, "a running manager keeps its unit" );
    ok( -e "$dir/state/written/$uid", "and the record that it is ours, which is all a later reconcile needs" );

    is( ea_podman::subids::reconcile_carveouts(), 0, "nothing is taken while the manager runs" );
    ok( -f $unit, "still there" );

    $stopped = 1;
    is( ea_podman::subids::reconcile_carveouts(), 1, "taken back once the manager has stopped" );
    ok( !lstat($unit), "and the unit is gone although nothing can resolve the uid" );
    ok( !-e "$dir/state/written/$uid", "with nothing left owed" );
};

subtest "a deleted account's unit goes even when no linger was ever granted" => sub {
    my ( $dir, $user, $uid ) = _provisioned_then_deleted( granted => 0 );

    no warnings qw(once);
    $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };

    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "wordpress.$user.01", user => $user } );

    ok( !lstat( ea_podman::subids::user_manager_carveout_file($uid) ), "enable-linger failing after the unit was written does not strand it" );
};

subtest "a deleted-account release leaves a lingering account's unit alone" => sub {
    my ( $dir, $user, $uid ) = _provisioned_then_deleted( granted => 1 );

    # The account is not deleted after all: it resolves, and it lingers.
    $main::uid_for{$user} = $uid;

    no warnings qw(once);
    $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };

    is( ea_podman::subids::release_deleted_user_carveout("nobody-recorded"), 0, "no unit of a deleted account, nothing to do" );
    ok( -f ea_podman::subids::user_manager_carveout_file($uid), "and the lingering account's unit is left alone" );
};

# A setup that dies after writing the unit. The caller has no reason to release
# an account it never set up, so the unit has to be taken back by setup itself.
subtest 'a setup that fails after writing the unit does not strand it' => sub {
    my $dir = _world();
    my ( $user, $uid ) = ( "failing", 11020 );
    $main::uid_for{$user} = $uid;

    no warnings qw(once);
    local $SIG{__WARN__} = sub { };
    my $unit = ea_podman::subids::user_manager_carveout_file($uid);

    # daemon-reload fails: the unit is on disk, nothing else happened.
    $ea_podman::subids::daemon_reloader                = sub { 0 };
    $ea_podman::subids::linger_enabler                 = sub { 1 };
    $ea_podman::subids::user_manager_is_active         = sub { 0 };
    $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };

    ok( !eval { ea_podman::subids::ensure_user_session($user); 1 }, "setup dies when the reload fails" );
    like( $@, qr/daemon-reload/, "with the real error, not the cleanup's" );
    ok( !lstat($unit), "and the unit it wrote is taken back, stopped manager and no linger" );

    # Same, with the manager not confirmed stopped: left for the reconciler.
    my $stopped = 0;
    $ea_podman::subids::user_manager_confirmed_stopped = sub { $stopped };
    ok( !eval { ea_podman::subids::ensure_user_session($user); 1 }, "fails again" );
    ok( -f $unit, "a manager that may still be up keeps the unit for now" );
    ok( -e "$dir/state/written/$uid", "with the record that it is ours" );
    $stopped = 1;
    is( ea_podman::subids::reconcile_carveouts(), 1, "and the reconciler takes it once the manager is stopped" );
    ok( !lstat($unit), "unit gone" );

    # An account that lingers wants its unit.
    $ea_podman::subids::daemon_reloader = sub { 1 };
    $ea_podman::subids::linger_enabler  = sub { Path::Tiny::path("$dir/linger/$_[0]")->touch; 1 };
    $ea_podman::subids::user_manager_starter = sub { die "boom\n" };
    ok( !eval { ea_podman::subids::ensure_user_session($user); 1 }, "a failing start dies" );
    ok( -f $unit, "an account that now lingers keeps its unit" );
};

# A manager that was running before this version arrived has no unit of its own.
subtest 'a healthy manager without a unit is given one, and left running' => sub {
    my $dir = _world();
    my ( $user, $uid ) = ( "upgraded", 11030 );
    $main::uid_for{$user} = $uid;

    no warnings qw(once);
    my $reloads = 0;
    $ea_podman::subids::daemon_reloader        = sub { $reloads++; 1 };
    $ea_podman::subids::user_manager_is_active = sub { 1 };
    $ea_podman::subids::linger_enabler         = sub { die "healthy path must not re-enable linger\n" };
    $ea_podman::subids::user_manager_starter   = sub { die "healthy path must not start anything\n" };
    $ea_podman::subids::user_manager_stopper   = sub { die "healthy path must not stop anything\n" };

    Path::Tiny::path("$dir/linger/$user")->touch;
    Path::Tiny::path("$dir/run/$uid")->mkpath;
    Path::Tiny::path("$dir/run/$uid/bus")->touch;

    my $unit = ea_podman::subids::user_manager_carveout_file($uid);
    ok( !lstat($unit), "no unit to begin with" );

    ok( eval { ea_podman::subids::ensure_user_session($user); 1 }, "an ordinary command succeeds" ) or diag $@;
    ok( -f $unit, "and the running manager now has its unit" );
    is( $reloads, 1, "reloaded once to make systemd see it" );
    ok( -e "$dir/state/written/$uid", "and recorded as ours, for a later release" );

    ok( eval { ea_podman::subids::ensure_user_session($user); 1 }, "the next command succeeds" );
    is( $reloads, 1, "and pays for nothing" );

    # A failure to write it must not fail the command: the manager is healthy.
    unlink $unit;
    $ea_podman::subids::daemon_reloader = sub { 0 };
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    ok( eval { ea_podman::subids::ensure_user_session($user); 1 }, "a reload failure does not fail a healthy account's command" );
    is( scalar @warn, 1, "it is reported" );
};

done_testing();
