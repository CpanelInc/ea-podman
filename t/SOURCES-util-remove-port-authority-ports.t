#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-remove-port-authority-ports.t   Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

our @system_cmds;
our $take_rv = 0;

BEGIN {
    use Test::Mock::Cmd 'system' => sub {
        push @system_cmds, join( ":", @_ );
        $? = $take_rv;
        return $take_rv;
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";

# CPANEL-57608. remove_port_authority_ports() ignored whether `take` worked, so
# the cleanup of a failed install could not tell it had left its ports behind.
# It must report a real failure, and must not report "no ports to release" as one:
# `take` refuses an empty list.

plan skip_all => "the root path is only taken as root" if $> != 0;

no warnings 'redefine';

subtest 'a container with no ports is not a failure, and take is not asked' => sub {
    @system_cmds = ();
    local $take_rv = 0;
    local *ea_podman::util::_get_current_ports = sub { return () };

    local $@;
    eval { ea_podman::util::remove_port_authority_ports("myapp.root.01") };

    is( $@, "", "no error" );
    is_deeply( \@system_cmds, [], "and take is never called, since it dies on an empty list" );
};

subtest 'the container\'s ports are taken' => sub {
    @system_cmds = ();
    local $take_rv = 0;
    local *ea_podman::util::_get_current_ports = sub { return ( 10000, 10001 ) };

    local $@;
    eval { ea_podman::util::remove_port_authority_ports("myapp.root.01") };

    is( $@, "", "no error" );
    is_deeply( \@system_cmds, ["/scripts/cpuser_port_authority:take:root:10000:10001"], "take is given every port" );
};

subtest 'a take that fails is reported' => sub {
    @system_cmds = ();
    local $take_rv = 256;
    local *ea_podman::util::_get_current_ports = sub { return (10000) };

    local $@;
    eval { ea_podman::util::remove_port_authority_ports("myapp.root.01") };

    like( $@, qr/take. exited unclean \(256\)/, "the failure is raised so the caller can say so" );
};

done_testing();
