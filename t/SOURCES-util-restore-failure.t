#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-restore-failure.t        Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use File::Temp ();
use FindBin;

our $HOMEDIR;

BEGIN {
    *CORE::GLOBAL::getpwuid = sub {
        my ($uid) = @_;
        return ( "bob", "x", $uid, $uid, "", "", "", $main::HOMEDIR, "/bin/bash" );
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-325, the data-loss half. The create-failure cleanup was gated
# `if ( !$isupgrade )`. A restore sets $isrestore, NOT $isupgrade, so the guard
# was true and a failed restore ran the install cleanup: deregister_container()
# and File::Path::Tiny::rm($container_dir).
#
# That directory is what perform_user_restore() has just untarred from the user's
# backup — and it removes ~/ea-podman.d before the tarball goes in, so there is no
# other copy. The three sibling guards in the same sub are all
# `!$isupgrade && !$isrestore`; only this one was not.

no warnings 'once';

sub _world {
    my $tmp = File::Temp->newdir();
    $main::HOMEDIR = "$tmp";

    my $name = "myapp.bob.01";
    my $dir  = "$tmp/ea-podman.d/$name";
    mkdir "$tmp/ea-podman.d";
    mkdir $dir;

    # Stand in for the data the restore just extracted.
    open( my $fh, ">", "$dir/ea-podman.json" ) or die $!;
    print {$fh} qq({"start_args":["docker.io/library/httpd:2.4"],"ports":["80"]});
    close $fh;
    open( my $db, ">", "$dir/precious.sqlite" ) or die $!;
    print {$db} "the user's only copy";
    close $db;

    return ( $tmp, $name, $dir );
}

sub _harness {
    my (%opts) = @_;
    my %log = ( registered => [], deregistered => [] );

    no warnings 'redefine';
    *ea_podman::util::warn_if_problematic_cgroup         = sub { 1 };
    *ea_podman::util::ensure_container_session           = sub { 1 };
    *ea_podman::util::_ensure_backup_conf_excludes_files = sub { 1 };
    *ea_podman::util::_arbitrary_image_warning           = sub { 1 };
    *ea_podman::util::_get_container_root                = sub { "$main::HOMEDIR/ea-podman.d" };
    *ea_podman::util::_get_current_ports                 = sub { return (10000) };
    *ea_podman::util::_get_new_ports                     = sub { return (10000) };
    *ea_podman::util::validate_start_args                = sub { 1 };
    *ea_podman::util::uninstall_container                = sub { 1 };
    *ea_podman::util::remove_user_container              = sub { 1 };
    *ea_podman::util::register_container                 = sub { push @{ $log{registered} }, [@_]; 1 };
    *ea_podman::util::deregister_container               = sub { push @{ $log{deregistered} }, $_[0]; 1 };
    *ea_podman::util::generate_container_service         = sub { 1 };
    *ea_podman::util::reset_container_unit_failure       = sub { 1 };
    *ea_podman::util::sysctl                             = sub { 1 };
    *ea_podman::util::create_user_container              = sub { return $opts{create} // 1 };

    return \%log;
}

subtest 'a failed restore leaves the extracted container dir on disk' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( create => 0 );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "restore" } ) }; $@ };

    like( $err, qr/Failed to restore/, "it raises" );
    ok( -d $dir,                    "the container directory survives" );
    ok( -e "$dir/precious.sqlite",  "and so does the data the backup put there" );
};

subtest 'a failed restore does not deregister the container' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( create => 0 );

    eval { ea_podman::util::_ensure_latest_container( $name, { op => "restore" } ) };

    is_deeply( $log->{deregistered}, [], "still registered, so still visible to the removal hooks" );
};

subtest 'a restore still registers before the create' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( create => 1 );

    ea_podman::util::_ensure_latest_container( $name, { op => "restore" } );

    is( scalar @{ $log->{registered} }, 1, "registered once" );
    is( $log->{registered}[0][1], 1, "with the permissive flag, so a pre-existing entry does not warn-and-refuse" );
};

subtest 'the restore message names both ways out' => sub {
    my $msg = ea_podman::util::_failed_restore_message( "myapp.bob.01", "/home/bob/ea-podman.d/myapp.bob.01" );

    like( $msg, qr/only copy of it/,                  "says why the directory was kept" );
    like( $msg, qr/ea-podman upgrade myapp\.bob\.01/, "names the in-place retry" );
    like( $msg, qr/ea-podman uninstall myapp\.bob\.01/, "names the give-up path" );

    # `restore` takes a fresh set of ports every run and nothing releases the old
    # ones, so steering a retry back through `restore` would strand them.
    like( $msg, qr/fresh set every run/, "warns that re-running restore strands ports" );
};

subtest 'one failed container does not abandon the rest of a restore' => sub {
    my @attempted;
    no warnings 'redefine';
    local *ea_podman::util::validate_user_container_name = sub { 1 };
    local *ea_podman::util::_ensure_latest_container     = sub {
        my ($name) = @_;
        push @attempted, $name;
        die "nope for $name\n" if $name eq "second.bob.02";
        return 1;
    };

    my @containers = map { { container_name => $_, webapp => 0 } } qw(first.bob.01 second.bob.02 third.bob.03);

    my $err = do { local $@; eval { ea_podman::util::restore_containers_for_user(@containers) }; $@ };

    is_deeply( \@attempted, [qw(first.bob.01 second.bob.02 third.bob.03)], "every container was attempted" );
    like( $err, qr/Could not restore 1 of 3/,   "it still reports the failure" );
    like( $err, qr/second\.bob\.02/,            "and names the one that failed" );
    like( $err, qr/ea-podman upgrade/,          "and says it is recoverable in place" );
};

subtest 'a clean restore returns without dying' => sub {
    no warnings 'redefine';
    local *ea_podman::util::validate_user_container_name = sub { 1 };
    local *ea_podman::util::_ensure_latest_container     = sub { 1 };

    my @containers = map { { container_name => $_, webapp => 0 } } qw(first.bob.01 second.bob.02);
    is( ea_podman::util::restore_containers_for_user(@containers), 1, "returns true" );
};

done_testing();
