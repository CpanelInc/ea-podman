#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-cgroup.t                  Copyright 2026 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# warn_if_not_cgroup_v2() is the EA4-360 recommendation: root is told (once per
# process) that cgroup v2 is what lets limits be enforced, on every OS. Never
# fatal, never for users.

sub _check {
    my ( $is_root, $is_v2 ) = @_;
    no warnings 'redefine';
    local *ea_podman::util::_is_root      = sub { $is_root };
    local *ea_podman::util::_is_cgroup_v2 = sub { $is_v2 };
    use warnings 'redefine';

    local $ea_podman::util::cgroup_v2_warned = 0;
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    my @rets = map { scalar eval { ea_podman::util::warn_if_not_cgroup_v2() } } 1 .. 2;
    return ( $@, \@rets, \@warns );
}

subtest 'root on cgroup v1: warns once with the A8 fix, not fatal' => sub {
    my ( $err, $rets, $warns ) = _check( 1, 0 );
    ok( !$err, "does not die" );
    is_deeply( $rets, [ 0, 0 ], "returns false (v1 detected)" );
    is( scalar(@$warns), 1, "warns only once per process" );
    like( $warns->[0], qr/cgroup v1/,                           "says what it is" );
    like( $warns->[0], qr/recommend cgroup v2/,                 "says what we recommend" );
    like( $warns->[0], qr/systemd\.unified_cgroup_hierarchy=1/, "gives the AlmaLinux 8 fix" );
};

subtest 'silent on cgroup v2, and for users' => sub {
    for my $case ( [ 1, 1, "root, v2" ], [ 0, 0, "user, v1" ], [ 0, 1, "user, v2" ] ) {
        my ( $err, $rets, $warns ) = _check( @{$case}[ 0, 1 ] );
        ok( !$err, "$case->[2]: does not die" );
        is_deeply( $rets, [ 1, 1 ], "$case->[2]: returns true" );
        is( scalar(@$warns), 0, "$case->[2]: no warning" );
    }
};

done_testing();
