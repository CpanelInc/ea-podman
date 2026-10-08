#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-install-failure-ports.t   Copyright 2026 WebPros International, LLC
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

# CPANEL-57608. A first install reserves its host ports before `podman create`.
# When the install then failed, the cleanup deregistered the container and removed
# its directory but left the ports in the port authority. The retry got the same
# name, reserved a second port under it, and the Web App plugin wired its proxy to
# the stale lowest one (503). An install that fails must give its ports back; an
# upgrade or restore that fails must not, because they keep theirs (EA4-325).

no warnings 'once';

sub _world {
    my $tmp = File::Temp->newdir();
    $main::HOMEDIR = "$tmp";

    my $name = "myapp.bob.01";
    my $dir  = "$tmp/ea-podman.d/$name";
    mkdir "$tmp/ea-podman.d";
    mkdir $dir;

    open( my $fh, ">", "$dir/ea-podman.json" ) or die $!;
    print {$fh} qq({"start_args":["docker.io/library/httpd:2.4"],"ports":["80"]});
    close $fh;

    return ( $tmp, $name, $dir );
}

# Everything _ensure_latest_container() touches that needs podman, systemd, the
# adminbin or the registry. The port authority calls and the registry calls are
# recorded, in order, in @{ $log{calls} }.
sub _harness {
    my (%opts) = @_;

    my %log = ( calls => [] );

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
    *ea_podman::util::register_container                 = sub { 1 };
    *ea_podman::util::generate_container_service         = sub { 1 };
    *ea_podman::util::reset_container_unit_failure       = sub { 1 };
    *ea_podman::util::sysctl                             = sub { 1 };
    *ea_podman::util::_get_container_image_ref           = sub { "docker.io/library/httpd:2.3" };
    *ea_podman::util::_podman_pull                       = sub { 1 };
    *ea_podman::util::_get_image_id                      = sub { "sha-new" };
    *ea_podman::util::_get_container_image_id            = sub { "sha-old" };

    *ea_podman::util::remove_port_authority_ports = sub {
        push @{ $log{calls} }, "remove_ports:$_[0]";
        die "port authority is unavailable\n" if $opts{ports_die};
        return;
    };
    *ea_podman::util::deregister_container = sub { push @{ $log{calls} }, "deregister:$_[0]"; return };

    *ea_podman::util::create_user_container = sub {
        $ea_podman::util::_create_output = "Error: forced failure";
        return 0;
    };

    return \%log;
}

sub _fails {
    my ( $name, $op, @extra ) = @_;
    return do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => $op }, @extra ) }; $@ };
}

subtest 'a failed install gives its ports back before it deregisters' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness();

    my $err = _fails( "fresh.bob.02", "install", "docker.io/library/node:22" );

    like( $err, qr/\AFailed to create container\n/, "the original error is unchanged" );
    is_deeply( $log->{calls}, [ "remove_ports:fresh.bob.02", "deregister:fresh.bob.02" ], "ports are released, then the container is deregistered" );
};

subtest 'a web app install that cannot move its source gives its ports back' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness();

    my $staged = "$tmp/staged";
    mkdir $staged;

    no warnings 'redefine';
    local $ea_podman::util::webapp_dir_setup_script = "/bin/false";

    my $err = _fails( "fresh.bob.02", "install", "--webapp-dir=$staged", "docker.io/library/node:22" );

    like( $err, qr/did not exit cleanly/, "the install is aborted for the right reason" );
    is_deeply( $log->{calls}, [ "remove_ports:fresh.bob.02", "deregister:fresh.bob.02" ], "ports are released, then the container is deregistered" );
};

subtest 'a port authority failure does not replace the create failure' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( ports_die => 1 );

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    my $err = _fails( "fresh.bob.02", "install", "docker.io/library/node:22" );

    like( $err, qr/\AFailed to create container\n/, "the user still sees why the install failed" );
    like( join( "", @warned ), qr/port authority is unavailable/, "and the port release failure is reported as a warning" );
    ok( ( grep { $_ eq "deregister:fresh.bob.02" } @{ $log->{calls} } ), "the cleanup carries on" );
};

subtest 'a failed upgrade keeps its ports' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness();

    like( _fails( $name, "upgrade" ), qr/Failed to upgrade/, "it raises" );
    is_deeply( [ grep { /^remove_ports:/ } @{ $log->{calls} } ], [], "no port was released" );
};

subtest 'a failed restore keeps its ports' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness();

    like( _fails( $name, "restore" ), qr/Failed to restore/, "it raises" );
    is_deeply( [ grep { /^remove_ports:/ } @{ $log->{calls} } ], [], "no port was released" );
};

done_testing();
