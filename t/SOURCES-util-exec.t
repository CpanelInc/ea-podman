#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-exec.t                    Copyright 2026 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# ea_podman::util's `cmd` support (CPANEL-54360) enters a running container's
# namespaces with nsenter (as root, re-mapped to the container's own root) so it
# works even where /proc is hidepid=2 and `podman exec` fails. These unit tests
# cover the pure pieces — the nsenter argv construction and the output cap —
# without needing podman, a container, or root.

#-----------------------------------------------------------------------
# _nsenter_args: correct namespaces + identity, command passed as a list.
#-----------------------------------------------------------------------
{
    my $args = ea_podman::util::_nsenter_args( 12345, ['date'], undef );
    is_deeply(
        $args,
        [ '-t', 12345, '-U', '-m', '-u', '-i', '-n', '-p', '-S', '0', '-G', '0', '--', 'date' ],
        "no --cd: enters userns + all namespaces, drops to container-root, runs argv directly (no shell)"
    );
}

{
    my $args = ea_podman::util::_nsenter_args( 999, [ 'ls', '-la' ], undef );
    is_deeply(
        [ @{$args}[ -2, -1 ] ],
        [ 'ls', '-la' ],
        "multi-arg command is preserved as a list after the -- separator"
    );
}

#-----------------------------------------------------------------------
# --cd wraps in the container's /bin/sh (cd DIR && exec …) without ever
# interpolating the dir or the argv into a shell string.
#-----------------------------------------------------------------------
{
    my $args = ea_podman::util::_nsenter_args( 42, [ 'apk', 'add', 'jq' ], '/tmp' );
    is_deeply(
        $args,
        [
            '-t', 42, '-U', '-m', '-u', '-i', '-n', '-p', '-S', '0', '-G', '0', '--',
            '/bin/sh', '-c', 'cd "$1" || exit 127; shift; exec "$@"', 'ea-podman-cmd', '/tmp', 'apk', 'add', 'jq'
        ],
        "--cd: cd carried as an sh positional arg, argv kept intact (no shell interpolation / injection)"
    );
}

{
    # An empty-string cd must behave exactly like "no cd" (no shell wrap).
    my $args = ea_podman::util::_nsenter_args( 7, ['date'], '' );
    is( scalar( grep { $_ eq '/bin/sh' } @{$args} ), 0, "empty --cd does not wrap in a shell" );
}

#-----------------------------------------------------------------------
# _cap_output: bounded output so a runaway command can't blow up the response.
#-----------------------------------------------------------------------
{
    my ( $txt, $trunc ) = ea_podman::util::_cap_output("hello");
    is( $txt, "hello", "short output passes through unchanged" );
    ok( !$trunc, "short output not flagged truncated" );

    ( $txt, $trunc ) = ea_podman::util::_cap_output(undef);
    is( $txt, "", "undef output becomes empty string" );
    ok( !$trunc, "undef not flagged truncated" );

    my $big = 'x' x ( 262_144 + 10 );
    ( $txt, $trunc ) = ea_podman::util::_cap_output($big);
    is( length($txt), 262_144, "output capped at 256 KiB" );
    ok( $trunc, "over-cap output flagged truncated" );
}

done_testing();
