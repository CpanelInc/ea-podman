#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-create-user-container.t   Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# CPANEL-55825: a legal (<=63 byte) app name can still produce a container
# name over 64 bytes once the app-/.<user>.<NN> wrapping is applied, and the
# kernel's sethostname() rejects any hostname over that length. Podman's
# --name has no such limit — only --hostname (the container's internal Linux
# hostname, which nothing in this codebase reads back) does — so
# create_user_container() must never pass --hostname.
subtest 'create_user_container does not pass --hostname to podman' => sub {
    my @podman_calls;
    no warnings 'once';
    local *ea_podman::util::podman = sub {
        push @podman_calls, [@_];
        return 1;
    };

    my $long_name = 'app-' . ( 'a' x 60 ) . '.bob.01';
    ea_podman::util::create_user_container( $long_name, '--foo', 'bar' );

    is( scalar @podman_calls, 1, 'podman() was called once' );
    my @args = @{ $podman_calls[0] };

    ok( !( grep { $_ eq '--hostname' } @args ), 'no --hostname arg is passed' );
    my ($name_idx) = grep { $args[$_] eq '--name' } 0 .. $#args;
    ok( defined $name_idx, '--name arg is present' );
    is( $args[ $name_idx + 1 ], $long_name, '--name is set to the full container name' );
};

done_testing();
