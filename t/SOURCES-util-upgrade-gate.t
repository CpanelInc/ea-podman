#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-upgrade-gate.t           Copyright 2026 WebPros International, LLC
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

# EA4-325 Increment B. `ea-podman upgrade` used to tear the container down and
# recreate it every single time, and never pulled at all -- `podman create`
# inherits --pull=missing, so an already-cached image was never refreshed. A
# nightly `upgrade_containers --all` therefore restarted every application on the
# server and still fetched nothing.
#
# Safe mode inverts that: pull, compare, and do nothing when nothing moved. The
# pull is not optional -- without it the comparison is between the cache and
# itself, always matches, and the upgrade would no-op forever.

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

sub _harness {
    my (%opts) = @_;
    my %log = ( pulled => [], uninstalled => 0, created => [], registered => [], started => 0 );

    no warnings 'redefine';
    *ea_podman::util::warn_if_problematic_cgroup         = sub { 1 };
    *ea_podman::util::ensure_container_session           = sub { 1 };
    *ea_podman::util::_ensure_backup_conf_excludes_files = sub { 1 };
    *ea_podman::util::_arbitrary_image_warning           = sub { 1 };
    *ea_podman::util::_get_container_root                = sub { "$main::HOMEDIR/ea-podman.d" };
    *ea_podman::util::_get_current_ports                 = sub { return (10000) };
    *ea_podman::util::validate_start_args                = sub { 1 };
    *ea_podman::util::uninstall_container                = sub { $log{uninstalled}++; 1 };
    *ea_podman::util::remove_user_container              = sub { 1 };
    *ea_podman::util::register_container                 = sub { push @{ $log{registered} }, [@_]; 1 };
    *ea_podman::util::deregister_container               = sub { 1 };
    *ea_podman::util::generate_container_service         = sub { 1 };
    *ea_podman::util::reset_container_unit_failure       = sub { 1 };
    *ea_podman::util::sysctl                             = sub { $log{started}++; 1 };
    *ea_podman::util::create_user_container              = sub { push @{ $log{created} }, [@_]; 1 };
    *ea_podman::util::_get_container_image_ref           = sub { "docker.io/library/httpd:2.4" };

    *ea_podman::util::_podman_pull = sub { push @{ $log{pulled} }, $_[0]; return $opts{pull} // 1 };
    *ea_podman::util::_get_image_id           = sub { return $opts{resolved_id} };
    *ea_podman::util::_get_container_image_id = sub { return $opts{container_id} };
    *ea_podman::util::is_user_container_name_running = sub { return $opts{running} // 1 };

    return \%log;
}

subtest 'the image is pulled before anything is decided' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-same", container_id => "sha-same" );

    ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } );

    is_deeply( $log->{pulled}, ["docker.io/library/httpd:2.4"], "the container's image reference was pulled" );
};

subtest 'nothing moved: the container is not touched at all' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-same", container_id => "sha-same" );

    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } );

    is_deeply( $did, { recreated => 0, started => 0 }, "it reports that it did nothing" );

    # The early return has to be before the teardown; anywhere later and the
    # container has already been destroyed by the time we decide not to.
    is( $log->{uninstalled},          0, "nothing was torn down" );
    is( scalar @{ $log->{created} },  0, "nothing was recreated" );
    is( scalar @{ $log->{registered} }, 0, "the registry was not rewritten" );
    is( $log->{started},              0, "and the application was not restarted" );
};

subtest 'the image moved: the container is recreated' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-new", container_id => "sha-old" );

    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } );

    is_deeply( $did, { recreated => 1, started => 1 }, "it reports a recreate" );
    is( $log->{uninstalled},         1, "the old container was torn down" );
    is( scalar @{ $log->{created} }, 1, "and a new one created" );
};

subtest 'force recreates even when nothing moved' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-same", container_id => "sha-same" );

    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "upgrade", force => 1 } );

    is_deeply( $did, { recreated => 1, started => 1 }, "forced through" );
    is( $log->{uninstalled}, 1, "the container was recreated regardless" );

    # Force still pulls: a redeploy picking up base-image patches is the intent.
    is_deeply( $log->{pulled}, ["docker.io/library/httpd:2.4"], "and it still pulled" );
};

# B4. The two paths want opposite answers, and both are deliberate.
subtest 'a failed pull leaves the container untouched, unless forced' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( pull => 0, resolved_id => "sha-same", container_id => "sha-same" );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) }; $@ };

    like( $err, qr/Could not pull/,        "it refuses rather than guessing" );
    like( $err, qr/has NOT been touched/,  "and says the container is unharmed" );
    like( $err, qr/--force/,               "and names the way through" );
    is( $log->{uninstalled}, 0, "nothing was torn down" );
};

subtest 'a failed pull under force falls back to the cached image' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( pull => 0, resolved_id => "sha-same", container_id => "sha-same" );

    # The webapp plugin's Redeploy is the force caller, and a Docker Hub outage
    # or a rate limit must not break it. (CPANEL-56732)
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "upgrade", force => 1 } );

    is_deeply( $did, { recreated => 1, started => 1 }, "the recreate still happened" );
    like( $warnings[0], qr/already cached locally/, "and the fallback was reported, not swallowed" );
};

# B7. A stop cannot be told from a crash, so "was down, stays down" is the only
# rule that never overrides the user.
subtest 'a stopped container is recreated and left stopped' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-new", container_id => "sha-old", running => 0 );

    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } );

    is_deeply( $did, { recreated => 1, started => 0 }, "recreated, but not started" );
    is( $log->{started}, 0, "systemd was not asked to start it" );
};

subtest 'force starts a stopped container, deliberately' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-same", container_id => "sha-same", running => 0 );

    # The plugin's redeploy branch has no start of its own and relies on this.
    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "upgrade", force => 1 } );

    is_deeply( $did, { recreated => 1, started => 1 }, "forced up" );
    is( $log->{started}, 1, "systemd was asked to start it" );
};

subtest 'install and restore are untouched by the gate' => sub {
    my ( $tmp, $name ) = _world();
    my $log = _harness( resolved_id => "sha-same", container_id => "sha-same" );

    my $did = ea_podman::util::_ensure_latest_container( $name, { op => "restore" } );

    is_deeply( $did, { recreated => 1, started => 1 }, "a restore always recreates" );
    is_deeply( $log->{pulled}, [], "and never pulls -- the gate is upgrade-only" );
};

subtest '_upgrade_is_needed: arbitrary images compare local image IDs' => sub {
    no warnings 'redefine';
    local *ea_podman::util::_get_container_image_id = sub { "sha-a" };
    local *ea_podman::util::_get_image_id           = sub { "sha-a" };
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0 ), 0, "identical IDs need nothing" );

    local *ea_podman::util::_get_image_id = sub { "sha-b" };
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0 ), 1, "a different ID needs a recreate" );

    # Guessing "not needed" from missing information is how a container silently
    # stops being updated.
    local *ea_podman::util::_get_image_id = sub { undef };
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0 ), 1, "cannot-tell errs towards acting" );

    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 1 ), 1, "force never asks" );
};

# B8, as decided: an EA4 package owns BOTH the image pin and the start args, so
# an image-only gate would silently skip a package update that changed `startup`
# flags while pinning the same image.
subtest '_upgrade_is_needed: packaged containers gate on the package version too' => sub {
    no warnings 'redefine';
    local *ea_podman::util::_get_container_image_id = sub { "sha-a" };
    local *ea_podman::util::_get_image_id           = sub { "sha-a" };

    local *ea_podman::util::get_pkg_versions = sub { return ( "1.6.45-1", "1.6.45-1" ) };
    is( ea_podman::util::_upgrade_is_needed( "ea-memcached16.bob.01", "img", "ea-memcached16", 0 ), 0, "same version, same image: nothing to do" );

    local *ea_podman::util::get_pkg_versions = sub { return ( "1.6.45-1", "1.6.46-1" ) };
    is( ea_podman::util::_upgrade_is_needed( "ea-memcached16.bob.01", "img", "ea-memcached16", 0 ), 1, "a newer package needs a recreate even though the image is identical" );

    # ...and the image is still consulted, so a re-pushed upstream tag is not missed.
    local *ea_podman::util::get_pkg_versions = sub { return ( "1.6.45-1", "1.6.45-1" ) };
    local *ea_podman::util::_get_image_id    = sub { "sha-b" };
    is( ea_podman::util::_upgrade_is_needed( "ea-memcached16.bob.01", "img", "ea-memcached16", 0 ), 1, "same version but a moved image still needs a recreate" );
};

# EA4-327 binds web app ports to 127.0.0.1, but only at create time, and relied
# on the next upgrade to recreate the web apps that predate it. An unmoved image
# must not stop that from happening.
subtest '_upgrade_is_needed: a web app still published on every interface needs a recreate' => sub {
    no warnings 'redefine';
    local *ea_podman::util::_get_container_image_id = sub { "sha-a" };
    local *ea_podman::util::_get_image_id           = sub { "sha-a" };

    local *ea_podman::util::_container_ports_all_loopback = sub { 0 };
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0, 1 ), 1, "web app, same image, public binding: recreate" );
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0, 0 ), 0, "not a web app, same image, public binding: nothing to do" );

    local *ea_podman::util::_container_ports_all_loopback = sub { 1 };
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0, 1 ), 0, "web app, same image, already loopback: nothing to do" );

    local *ea_podman::util::_container_ports_all_loopback = sub { return };
    is( ea_podman::util::_upgrade_is_needed( "x.bob.01", "img", undef, 0, 1 ), 1, "web app whose binding cannot be read: cannot-tell errs towards acting" );
};

subtest '_container_ports_all_loopback reads podman inspect PortBindings' => sub {
    my $bin = File::Temp->newdir();
    my %cases = (
        'null'                                                                                          => 1,
        '{}'                                                                                            => 1,
        '{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"44444"}]}'                                      => 1,
        '{"8080/tcp":[{"HostIp":"","HostPort":"44444"}]}'                                               => 0,
        '{"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"44444"}]}'                                        => 0,
        '{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"1"}],"443/tcp":[{"HostIp":"","HostPort":"2"}]}' => 0,
        'not json'                                                                                      => undef,
    );

    no warnings 'redefine';
    local *ea_podman::util::validate_user_container_name = sub { 1 };
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    for my $out ( sort keys %cases ) {
        _fake_podman( $bin, "echo '$out'; exit 0" );
        is( ea_podman::util::_container_ports_all_loopback("x.bob.01"), $cases{$out}, "PortBindings $out" );
    }

    _fake_podman( $bin, "exit 125" );
    is( ea_podman::util::_container_ports_all_loopback("x.bob.01"), undef, "a failed inspect is cannot-tell, not loopback" );
};

sub _fake_podman {
    my ( $bin, $body ) = @_;
    open( my $fh, '>', "$bin/podman" ) or die "podman stub: $!";
    print {$fh} "#!/bin/sh\n$body\n";
    close $fh;
    chmod 0755, "$bin/podman";
    return;
}

# The pull memoization is deliberately NOT tested here. _harness() above replaces
# _podman_pull with a non-local glob assignment, so the real sub is gone for the
# rest of this file and any test of it would be testing the stub. It lives in
# t/SOURCES-util-podman-pull.t, which never loads the harness.

done_testing();
