#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-get-containers.t         Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-325: split( " ", $line, 2 ) with a limit of 2 lets the second field absorb
# the newline podman ends each line with, so `image` was "…/httpd:2.4\n".
# Harmless in `list` — it just showed up as an escaped \n inside a JSON string —
# and silently fatal to any comparison built on that field, which is exactly what
# CPANEL-54869 is about to build.
#
# get_containers() shells out with a bare backtick, which cannot be glob-mocked,
# which is why it had no real test. Hence the named seam.

no warnings 'once';

subtest 'image names carry no trailing newline' => sub {
    local *ea_podman::util::_podman_ps_names_and_images = sub {
        return ( "myapp.bob.01 docker.io/library/httpd:2.4", "other.bob.02 docker.io/library/node:23" );
    };
    local *ea_podman::util::_get_current_ports = sub { return () };

    my $containers = ea_podman::util::get_containers();

    is( $containers->{"myapp.bob.01"}{image}, "docker.io/library/httpd:2.4", "the full reference survives intact" );
    is( $containers->{"other.bob.02"}{image}, "docker.io/library/node:23",   "and so does the second one" );

    unlike( $containers->{"myapp.bob.01"}{image}, qr/\s\z/, "no trailing whitespace of any kind" );
};

subtest 'the seam chomps, so a caller never sees the newline' => sub {
    # Proves the chomp is in the seam rather than relying on split()'s behaviour:
    # feed it a line that still has one and the field must still come out clean.
    local *ea_podman::util::_podman_ps_names_and_images = sub {
        my @lines = ("myapp.bob.01 docker.io/library/httpd:2.4\n");
        chomp @lines;
        return @lines;
    };
    local *ea_podman::util::_get_current_ports = sub { return () };

    is( ea_podman::util::get_containers()->{"myapp.bob.01"}{image}, "docker.io/library/httpd:2.4", "clean" );
};

subtest 'ports still come through alongside the image' => sub {
    local *ea_podman::util::_podman_ps_names_and_images = sub { return ("myapp.bob.01 docker.io/library/httpd:2.4") };
    local *ea_podman::util::_get_current_ports          = sub { return ( 10000, 10001 ) };

    is_deeply( ea_podman::util::get_containers()->{"myapp.bob.01"}{ports}, [ 10000, 10001 ], "ports are unaffected" );
};

subtest 'an image reference with no registry prefix is kept whole' => sub {
    local *ea_podman::util::_podman_ps_names_and_images = sub { return ("myapp.bob.01 httpd:2.4") };
    local *ea_podman::util::_get_current_ports          = sub { return () };

    is( ea_podman::util::get_containers()->{"myapp.bob.01"}{image}, "httpd:2.4", "short form is untouched" );
};

done_testing();
