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

# warn_if_problematic_cgroup() never dies. The one problematic combination is
# CloudLinux + cgroup v2 (LVE breaks the per-user systemd manager); there it
# warns on the UAPI/restricted path ($EMIT_CGROUP_ADVISORY = 1) and stays silent
# on the direct CLI path (0). Every other combination is fine and silent.

sub _check {
    my ( $is_cl, $is_v2, $emit ) = @_;
    no warnings 'redefine';
    local *ea_podman::util::_is_cloudlinux = sub { $is_cl };
    local *ea_podman::util::_is_cgroup_v2  = sub { $is_v2 };
    use warnings 'redefine';

    local $ea_podman::util::EMIT_CGROUP_ADVISORY = $emit;
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    my $ret = eval { ea_podman::util::warn_if_problematic_cgroup() };
    return ( $@, $ret, \@warns );
}

subtest 'CloudLinux + cgroup v2, UAPI/restricted path (EMIT=1): warns, not fatal' => sub {
    my ( $err, $ret, $warns ) = _check( 1, 1, 1 );
    ok( !$err, "does not die (advisory only)" );
    ok( !$ret, "returns false (problematic config detected)" );
    is( scalar(@$warns), 1, "emits exactly one warning" );
    like( $warns->[0], qr/cgroup v2/,        "warning mentions cgroup v2" );
    like( $warns->[0], qr/cgroup v1/,        "warning points to the cgroup v1 fix" );
    like( $warns->[0], qr/cloudlinux-default-cgv1/, "warning gives the switch-back command" );
};

subtest 'CloudLinux + cgroup v2, direct CLI path (EMIT=0): silent, allowed' => sub {
    my ( $err, $ret, $warns ) = _check( 1, 1, 0 );
    ok( !$err, "does not die" );
    ok( $ret,  "returns true (advisory suppressed)" );
    is( scalar(@$warns), 0, "emits no warning" );
};

subtest 'CloudLinux + cgroup v1: supported config, silent regardless of path' => sub {
    for my $emit ( 0, 1 ) {
        my ( $err, $ret, $warns ) = _check( 1, 0, $emit );
        ok( !$err, "EMIT=$emit: does not die" );
        ok( $ret,  "EMIT=$emit: returns true (fine)" );
        is( scalar(@$warns), 0, "EMIT=$emit: no warning" );
    }
};

subtest 'non-CloudLinux: never warns, on either cgroup version' => sub {
    for my $v2 ( 0, 1 ) {
        for my $emit ( 0, 1 ) {
            my ( $err, $ret, $warns ) = _check( 0, $v2, $emit );
            ok( !$err, "v2=$v2 EMIT=$emit: does not die" );
            ok( $ret,  "v2=$v2 EMIT=$emit: returns true (fine)" );
            is( scalar(@$warns), 0, "v2=$v2 EMIT=$emit: no warning" );
        }
    }
};

done_testing();
