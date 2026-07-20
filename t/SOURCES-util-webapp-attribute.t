#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-webapp-attribute.t      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

use Cpanel::JSON ();

require "$FindBin::Bin/../SOURCES/util.pm";

subtest 'register_container_as_root records webapp as a strict JSON boolean' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    ea_podman::util::register_container_as_root( "my-app.bob.01", "bob", 0, "node:22", 1 );
    ea_podman::util::register_container_as_root( "plain.bob.01",  "bob", 0, "redis:7", 0 );
    ea_podman::util::register_container_as_root( "legacy.bob.01", "bob", 0, "mongo:8" );    # no value given at all

    my $raw = do { local ( @ARGV, $/ ) = ($ea_podman::util::known_containers_file); <> };
    like( $raw, qr/"webapp"\s*:\s*true/,  "a --webapp-dir install’s container is registered with JSON true" );
    like( $raw, qr/"webapp"\s*:\s*false/, "a container without it is registered with JSON false" );

    my $containers = Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file);
    ok( $containers->{"my-app.bob.01"}{webapp},  "webapp given ➜ true" );
    ok( !$containers->{"plain.bob.01"}{webapp},  "webapp not given ➜ false" );
    ok( !$containers->{"legacy.bob.01"}{webapp}, "no argument at all ➜ false" );

    ea_podman::util::register_container_as_root( "truthy.bob.01", "bob", 0, "node:22", "any old junk" );
    $containers = Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file);
    is( Cpanel::JSON::Dump( $containers->{"truthy.bob.01"}{webapp} ), "true", "a non-boolean value is collapsed to a strict boolean, never stored raw" );
};

subtest 'an upgrade preserves the registered webapp value — it cannot be flipped after install' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    ea_podman::util::register_container_as_root( "my-app.bob.01", "bob", 0, "node:22", 1 );
    ea_podman::util::register_container_as_root( "plain.bob.01",  "bob", 0, "redis:7", 0 );

    # An upgrade carries no --webapp-dir; it must not reset true to false …
    ea_podman::util::register_container_as_root( "my-app.bob.01", "bob", 1, "node:23", 0 );

    # … and a caller replaying an "upgrade" registration cannot promote false to true.
    ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 1, "redis:8", 1 );

    my $containers = Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file);
    ok( $containers->{"my-app.bob.01"}{webapp}, "upgrade keeps webapp true" );
    is( $containers->{"my-app.bob.01"}{image}, "node:23", "the upgrade itself still lands" );
    ok( !$containers->{"plain.bob.01"}{webapp}, "upgrade cannot set webapp true on a container installed without --webapp-dir" );
};

subtest 'a duplicate (non-upgrade) registration cannot change webapp' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 0, "redis:7", 0 );

    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 0, "redis:7", 1 );
    }
    like( $warning, qr/already registered/, "the duplicate registration is refused" );

    my $containers = Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file);
    ok( !$containers->{"plain.bob.01"}{webapp}, "webapp is unchanged" );
};

done_testing();
