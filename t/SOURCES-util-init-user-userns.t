#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-init-user-userns.t        Copyright 2026 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";
require "$FindBin::Bin/../SOURCES/subids.pm";

# init_user() dies without user namespaces, except for a verb whose own work
# needs no podman (userns_optional), which only warns: the removals, so a server
# that lost them can still be cleaned up (the package's prerm and the
# account-deletion hook are removals), and `containers`. (EA4-360)

plan skip_all => "init_user() only checks user namespaces as root" if $> != 0;

sub _init_user {
    my ( $has_userns, %opts ) = @_;

    my ( @calls, @warns );
    no warnings qw(redefine once);
    local *ea_podman::util::check_proc                    = sub { return };
    local *ea_podman::util::warn_if_not_cgroup_v2         = sub { return 1 };
    local *ea_podman::util::ensure_su_login               = sub { return };
    local *ea_podman::util::ensure_user                   = sub { push @calls, [ ensure_user => @_ ]; return 1 };
    local *ea_podman::subids::assert_has_user_namespaces = sub {
        push @calls, ['assert'];
        die "❌ ea-podman requires user namespaces …\n" if !$has_userns;
        return 15000;
    };
    use warnings qw(redefine once);

    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    my $ok = eval { ea_podman::util::init_user(%opts); 1 };
    return ( $ok ? "" : $@, \@calls, \@warns );
}

subtest 'no user namespaces: dies before anything is set up' => sub {
    my ( $err, $calls ) = _init_user(0);
    like( $err, qr/requires user namespaces/, "dies with the reason" );
    is_deeply( $calls, [ ['assert'] ], "and ensure_user() is never reached" );
};

subtest 'no user namespaces, creating: dies too' => sub {
    my ($err) = _init_user( 0, creating => 1 );
    like( $err, qr/requires user namespaces/ );
};

subtest 'no user namespaces, userns_optional: warns and carries on' => sub {
    my ( $err, $calls, $warns ) = _init_user( 0, userns_optional => 1 );
    is( $err, "", "does not die" );
    is( scalar(@$warns), 1, "warns once" );
    like( $warns->[0], qr/requires user namespaces.*Carrying on/s, "with the reason, and that it goes on" );
    is_deeply( $calls->[-1], [ ensure_user => undef, 1 ], "ensure_user() is reached, and told" );
};

subtest 'user namespaces available: silent either way' => sub {
    for my $optional ( 0, 1 ) {
        my ( $err, $calls, $warns ) = _init_user( 1, userns_optional => $optional );
        is( $err,            "", "userns_optional=$optional: does not die" );
        is( scalar(@$warns), 0,  "userns_optional=$optional: no warning" );
        is( $calls->[-1][0], "ensure_user", "userns_optional=$optional: goes on to ensure_user()" );
    }
};

done_testing();
