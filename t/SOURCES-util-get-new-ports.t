#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-get-new-ports.t          Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

# EA4-344. When the port authority could not give a container its ports, the
# failure was thrown away: root's call sent stderr to /dev/null and kept only the
# digit lines, the user's adminbin call ignored GIVE's exit status. The install
# carried on with no ports. A failed assignment must now die with what the port
# authority said, up to its first blank line.

our @readpipe_calls;
our $readpipe_output = "";
our $readpipe_status = 0;

BEGIN {
    *CORE::GLOBAL::readpipe = sub {
        my ($cmd) = @_;
        push @readpipe_calls, $cmd;
        $? = $readpipe_status;
        return wantarray ? split( /^/m, $readpipe_output ) : $readpipe_output;
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";

no warnings 'once';

our @adminbin_calls;
our @adminbin_return;
our $adminbin_die;

{
    no warnings 'redefine';
    *Cpanel::AdminBin::Call::call = sub {
        push @adminbin_calls, [@_];
        die $adminbin_die if defined $adminbin_die;
        return @adminbin_return;
    };
}

sub _get_new_ports {
    my (@args) = @_;
    my @ports;
    local $@;
    my $ok = eval { @ports = ea_podman::util::_get_new_ports(@args); 1 };
    return ( $ok ? undef : $@ ), @ports;
}

# The branch is chosen by $>; drop the euid for the user branch and restore it.
sub _as_user {
    my ($code) = @_;
    return $code->() if $> != 0;
    local $> = 65534;
    return $code->();
}

subtest 'nothing to assign does not ask the port authority' => sub {
    local @readpipe_calls = ();
    @adminbin_calls = ();

    for my $count ( undef, 0, -1 ) {
        my ( $err, @ports ) = _get_new_ports( "myapp.root.01", $count );
        is( $err, undef, "no error for count " . ( $count // "undef" ) );
        is_deeply( \@ports, [], "... and no ports" );
    }
    is_deeply( \@readpipe_calls, [], "the root port authority was not called" );
    is_deeply( \@adminbin_calls, [], "the adminbin was not called" );
};

SKIP: {
    skip "the root branch is taken only when running as root", 4 if $> != 0;

    subtest 'root: a failed assignment dies with the port authority output' => sub {
        local @readpipe_calls  = ();
        local $readpipe_status = 1 << 8;
        local $readpipe_output = "No ports available in range\nTry again later\n\nUsage: cpuser_port_authority ...\n  give <user> <n>\n";

        my ( $err, @ports ) = _get_new_ports( "myapp.root.01", 2 );

        is( $err, "Could not assign root ports: No ports available in range\nTry again later\n", "dies with the output before the first blank line" );
        is_deeply( \@ports, [], "no ports are returned" );
        is_deeply(
            \@readpipe_calls,
            ["/scripts/cpuser_port_authority give root 2 --service=myapp.root.01 2>&1"],
            "stderr is captured, not discarded",
        );
    };

    subtest 'root: digit lines in a failed run are not taken as ports' => sub {
        local $readpipe_status = 1 << 8;
        local $readpipe_output = "10000\nError: could not record assignment\n";

        my ( $err, @ports ) = _get_new_ports( "myapp.root.01", 1 );

        like( $err, qr/\ACould not assign root ports: 10000\nError: could not record assignment\n\z/, "the failure is raised" );
        is_deeply( \@ports, [], "the half-assigned port is not handed back" );
    };

    subtest 'root: a whitespace-only line also ends the message' => sub {
        local $readpipe_status = 1 << 8;
        local $readpipe_output = "Error: port authority locked\n   \t\nstack trace line\n";

        my ( $err, @ports ) = _get_new_ports( "myapp.root.01", 1 );

        is( $err, "Could not assign root ports: Error: port authority locked\n", "stops at the whitespace-only line" );
    };

    subtest 'root: a failure with no output still dies' => sub {
        local $readpipe_status = -1;
        local $readpipe_output = "";

        my ( $err, @ports ) = _get_new_ports( "myapp.root.01", 1 );

        like( $err, qr/\ACould not assign root ports: /, "dies even when the command could not run" );
        is_deeply( \@ports, [], "no ports are returned" );
    };
}

subtest 'user: a failed GIVE dies with its output' => sub {
    @adminbin_calls = ();
    local @adminbin_return = ( "Cannot assign 2 ports: none free\n\nUsage: ...\n", 1 << 8 );
    local $adminbin_die;

    my ( $err, @ports ) = _as_user( sub { _get_new_ports( "myapp.bob.01", 2 ) } );

    is( $err, "Could not assign user ports: Cannot assign 2 ports: none free\n", "dies with the output before the first blank line" );
    is_deeply( \@ports, [], "no ports are returned" );
    is_deeply( \@adminbin_calls, [ [ 'Cpanel', 'ea_podman', 'GIVE', 2, 'myapp.bob.01' ] ], "GIVE was asked for the ports" );
};

subtest 'user: digit lines in a failed GIVE are not taken as ports' => sub {
    local @adminbin_return = ( "10001\nError: could not record assignment\n", 1 << 8 );
    local $adminbin_die;

    my ( $err, @ports ) = _as_user( sub { _get_new_ports( "myapp.bob.01", 1 ) } );

    is( $err, "Could not assign user ports: 10001\nError: could not record assignment\n", "the failure is raised" );
    is_deeply( \@ports, [], "the half-assigned port is not handed back" );
};

subtest 'user: a failed GIVE with no output still dies' => sub {
    local @adminbin_return = ( "", 1 << 8 );
    local $adminbin_die;

    my ( $err, @ports ) = _as_user( sub { _get_new_ports( "myapp.bob.01", 1 ) } );

    like( $err, qr/\ACould not assign user ports: /, "dies with an empty response" );
    is_deeply( \@ports, [], "no ports are returned" );
};

subtest 'user: an adminbin exception is not swallowed' => sub {
    local @adminbin_return = ();
    local $adminbin_die = "The feature “ea_podman” is not enabled\n";

    my ( $err, @ports ) = _as_user( sub { _get_new_ports( "myapp.bob.01", 1 ) } );

    is( $err, "The feature “ea_podman” is not enabled\n", "the adminbin's own error reaches the caller" );
    is_deeply( \@ports, [], "no ports are returned" );
};

SKIP: {
    skip "the root branch is taken only when running as root", 1 if $> != 0;

    subtest 'root: a successful assignment returns bare port numbers' => sub {
        local $readpipe_status = 0;
        local $readpipe_output = "10000\n10001\n";

        my ( $err, @ports ) = _get_new_ports( "myapp.root.01", 2 );

        is( $err, undef, "no error" );
        is_deeply( \@ports, [ 10000, 10001 ], "the ports carry no trailing newline" );
    };
}

subtest 'user: a successful GIVE returns its ports' => sub {
    local @adminbin_return = ( "10000\n10001\n", 0 );
    local $adminbin_die;

    my ( $err, @ports ) = _as_user( sub { _get_new_ports( "myapp.bob.01", 2 ) } );

    is( $err, undef, "no error" );
    is_deeply( \@ports, [ 10000, 10001 ], "the ports are returned" );
};

subtest '_stringify_items_before_first_blank' => sub {
    my $fn = \&ea_podman::util::_stringify_items_before_first_blank;

    is( $fn->( [] ),                     "",               "no lines, empty string" );
    is( $fn->( [ "", "after" ] ),        "",               "a leading blank line yields nothing" );
    is( $fn->( [ "a", "b" ] ),           "a\nb\n",         "unterminated lines get a newline" );
    is( $fn->( [ "a\n", "b\n" ] ),       "a\nb\n",         "terminated lines are not doubled" );
    is( $fn->( [ "a\n", " \n", "c\n" ] ), "a\n",           "stops at a whitespace-only line" );
    is( $fn->( [ "0", "c" ] ),           "0\nc\n",         "a line of '0' is not blank" );
};

done_testing();
