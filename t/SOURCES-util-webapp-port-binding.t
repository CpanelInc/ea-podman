#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-webapp-port-binding.t   Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# EA4-327: a web app container's published port binds to 127.0.0.1 only,
# since the web app reverse proxy always talks to 127.0.0.1 and never relies
# on the container's external binding (see docs/webapp-port-binding.md).
# Non-web-app containers are unaffected. This covers install, restore, and
# — the gap the ADR's rollout story missed — upgrade of an already-registered
# web app container, which must re-derive `webapp` from the registry since
# an upgrade is never told it directly.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;
use Path::Tiny ();
use Cpanel::JSON ();

require "$FindBin::Bin/../SOURCES/util.pm";

plan skip_all => "these tests seed the container registry directly, which requires root" if $> != 0;

# Drives _ensure_latest_container() with every side-effecting dependency
# stubbed out except the registry file (real, on a temp path) and the
# constructed podman args (captured). Returns the args of the 'create' call.
sub _run {
    my (%args) = @_;

    my $tmp             = File::Temp->newdir();
    my $container_root  = "$tmp/containers";
    mkdir $container_root;

    no warnings qw(once redefine);
    local $ea_podman::util::known_containers_file   = "$tmp/registered-containers.json";
    local $ea_podman::util::webapp_dir_setup_script  = "/bin/true";

    local *ea_podman::util::warn_if_problematic_cgroup         = sub { return 1 };
    local *ea_podman::util::ensure_container_session           = sub { return 1 };
    local *ea_podman::util::_ensure_backup_conf_excludes_files = sub { return 1 };
    local *ea_podman::util::_get_container_root                = sub { return $container_root };
    local *ea_podman::util::generate_container_service          = sub { return 1 };
    local *ea_podman::util::reset_container_unit_failure         = sub { return 1 };
    local *ea_podman::util::sysctl                                = sub { return 1 };
    local *ea_podman::util::uninstall_container                   = sub { return 1 };
    local *ea_podman::util::_get_new_ports                        = sub { return ( $args{port} ) };
    local *ea_podman::util::_get_current_ports                    = sub { return ( $args{port} ) };

    my @podman_calls;
    local *ea_podman::util::podman = sub {
        push @podman_calls, [@_];
        return 1;
    };

    if ( $args{pre_register} ) {
        ea_podman::util::register_container_as_root( $args{container_name}, "root", 0, "image:1", $args{pre_register}{webapp} );
    }

    if ( $args{existing_container_conf} ) {
        Path::Tiny::path("$container_root/$args{container_name}")->mkpath;
        my $json = Cpanel::JSON::pretty_canonical_dump( $args{existing_container_conf} );
        Path::Tiny::path("$container_root/$args{container_name}/ea-podman.json")->spew($json);
    }

    local $@;
    local $SIG{__WARN__} = sub { };    # the arbitrary-image dragon warning is expected noise here
    eval {
        ea_podman::util::_ensure_latest_container( $args{container_name}, $args{opts}, @{ $args{start_args} || [] } );
        1;
    } or die "_ensure_latest_container died unexpectedly: $@\n";

    my ($create_call) = grep { $_->[0] eq 'create' } @podman_calls;
    return $create_call;
}

# Extract the value(s) that followed a "-p" flag in a podman create call.
sub _p_args {
    my ($create_call) = @_;
    my @args = @{$create_call};
    return map { $args[ $_ + 1 ] } grep { $args[$_] eq '-p' } 0 .. $#args;
}

subtest 'install with --webapp-dir binds the published port to loopback' => sub {
    my $staged = File::Temp->newdir();

    my $create_call = _run(
        container_name => "myapp.bob.01",
        opts           => { op => "install" },
        start_args     => [ "--webapp-dir=$staged", "--i-understand-the-risks-do-it-anyway", "node:22" ],
        port           => 44444,
    );

    is_deeply( [ _p_args($create_call) ], ["127.0.0.1:44444:44444"], "webapp install publishes on 127.0.0.1 only" );
};

subtest 'install with --cpuser-port (no --webapp-dir) still publishes on all interfaces' => sub {
    my $create_call = _run(
        container_name => "plain.bob.01",
        opts           => { op => "install" },
        start_args     => [ "--cpuser-port=8080", "--i-understand-the-risks-do-it-anyway", "redis:7" ],
        port           => 55555,
    );

    is_deeply( [ _p_args($create_call) ], ["55555:8080"], "a non-webapp install is unchanged" );
};

subtest 'restore with webapp=1 in the backup payload binds to loopback' => sub {
    my $create_call = _run(
        container_name           => "myapp.bob.01",
        opts                     => { op => "restore", webapp => 1 },
        existing_container_conf  => { start_args => ["node:22"], ports => [] },
        port                     => 66666,
    );

    is_deeply( [ _p_args($create_call) ], ["127.0.0.1:66666:66666"], "a restored webapp container is bound to loopback" );
};

subtest 'restore with webapp=0 in the backup payload is unaffected' => sub {
    my $create_call = _run(
        container_name           => "plain.bob.01",
        opts                     => { op => "restore", webapp => 0 },
        existing_container_conf  => { start_args => ["redis:7"], ports => [] },
        port                     => 66667,
    );

    is_deeply( [ _p_args($create_call) ], ["66667:66667"], "a restored non-webapp container is unaffected" );
};

# This is the gap the ADR's rollout story missed: `webapp` is never passed to
# an upgrade, so it has to be read back from the registry instead of assumed
# 0 — otherwise an existing webapp container's port would never actually move
# to loopback-only, no matter how many times it's upgraded.
subtest 'upgrade of an already-registered webapp container re-binds it to loopback' => sub {
    my $create_call = _run(
        container_name           => "myapp.bob.01",
        opts                     => { op => "upgrade" },
        existing_container_conf  => { start_args => ["node:23"], ports => [] },
        pre_register              => { webapp => 1 },
        port                     => 77777,
    );

    is_deeply( [ _p_args($create_call) ], ["127.0.0.1:77777:77777"], "an upgraded webapp container picks up loopback-only binding" );
};

subtest 'upgrade of a container registered without webapp is unaffected' => sub {
    my $create_call = _run(
        container_name           => "plain.bob.01",
        opts                     => { op => "upgrade" },
        existing_container_conf  => { start_args => ["redis:8"], ports => [] },
        pre_register              => { webapp => 0 },
        port                     => 77778,
    );

    is_deeply( [ _p_args($create_call) ], ["77778:77778"], "an upgraded non-webapp container is unaffected" );
};

done_testing();
