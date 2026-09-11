#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-upgrade-sweep.t          Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-325. upgrade_containers_for_a_user() looped with no eval, so the first
# container that died abandoned the rest of that account's.
#
# Fixing that must NOT make the sweep silent, which is the whole point of the
# case: it accumulates and then dies. Thrown rather than returned because the
# root sweep calls this inside Cpanel::AccessIds::do_as_user_with_exception(),
# across a privilege boundary a return value does not survive but an exception
# does.
#
# The CLI half of A3 — the per-account try/catch, the sorted %user_breakdown
# iteration and the `exit 1` — is NOT tested here: SOURCES/ea-podman.pl cannot be
# loaded in a unit test (Cpanel::Config::Users, Cpanel::AccessIds,
# Whostmgr::Accounts::Shell, App::CmdDispatch). That half is covered on a VM.

no warnings 'once';

sub _containers {
    return map { { container_name => $_, user => "bob" } } @_;
}

subtest "one container's failure does not abandon the rest" => sub {
    my @attempted;
    local *ea_podman::util::upgrade_container = sub {
        my ( $name, %opts ) = @_;
        push @attempted, $name;
        die "boom for $name\n" if $name eq "second.bob.02";
        return 1;
    };

    my @c = _containers(qw(first.bob.01 second.bob.02 third.bob.03 fourth.bob.04));

    my $err = do { local $@; eval { ea_podman::util::upgrade_containers_for_a_user( 0, @c ) }; $@ };

    is_deeply(
        \@attempted,
        [qw(first.bob.01 second.bob.02 third.bob.03 fourth.bob.04)],
        "every container was attempted, including the ones after the failure"
    );
    ok( $err, "and it still reported a failure rather than returning quietly" );
};

subtest 'the failures are aggregated into a die that names each one' => sub {
    local *ea_podman::util::upgrade_container = sub {
        my ( $name, %opts ) = @_;
        die "boom\n" if $name =~ m/^(second|fourth)/;
        return 1;
    };

    my @c = _containers(qw(first.bob.01 second.bob.02 third.bob.03 fourth.bob.04));
    my $err = do { local $@; eval { ea_podman::util::upgrade_containers_for_a_user( 0, @c ) }; $@ };

    like( $err, qr/Failed to upgrade 2 of 4 container\(s\)/, "counts both the failures and the total" );
    like( $err, qr/second\.bob\.02/, "names the first failure" );
    like( $err, qr/fourth\.bob\.04/, "names the second" );
    like( $err, qr/for “bob”/,       "and whose containers they are" );
    like( $err, qr/ea-podman upgrade <CONTAINER_NAME>/, "points at the single-container retry" );
};

subtest 'a clean sweep returns true and does not die' => sub {
    my @attempted;
    local *ea_podman::util::upgrade_container = sub { push @attempted, $_[0]; return 1 };

    my @c = _containers(qw(first.bob.01 second.bob.02));
    my $rv = do { local $@; eval { ea_podman::util::upgrade_containers_for_a_user( 0, @c ) } };

    is( $rv, 1, "returns true" );
    is( scalar @attempted, 2, "both attempted" );
};

subtest 'containers belonging to more than one user are still rejected' => sub {
    local *ea_podman::util::upgrade_container = sub { return 1 };

    my @c = ( { container_name => "a.bob.01", user => "bob" }, { container_name => "b.sue.01", user => "sue" } );
    my $err = do { local $@; eval { ea_podman::util::upgrade_containers_for_a_user( 0, @c ) }; $@ };

    like( $err, qr/must be for all the same user/, "the pre-existing guard still fires" );
};

done_testing();
