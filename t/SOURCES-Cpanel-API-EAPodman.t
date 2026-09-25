#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use strict;
use warnings;

use Test::More;
use FindBin;

use lib '/usr/local/cpanel';
use Cpanel::Args   ();
use Cpanel::Result ();

# The EAPodman UAPI verbs are thin wrappers over ea_podman::util::api_*, which
# the ea_podman admin module's lifecycle actions run too (EA4-315). These pin
# both halves: that each UAPI function still takes the same parameters and
# returns the same data, and that the shared verbs do what the UAPI used to do
# inline. Nothing here needs podman, root, or a cPanel account.

require "$FindBin::Bin/../SOURCES/util.pm";
$INC{"/opt/cpanel/ea-podman/lib/ea_podman/$_.pm"} = __FILE__ for qw(util subids);
require "$FindBin::Bin/../SOURCES/Cpanel-API-EAPodman.pm";

# Its loader checks the installed path; point it at the copies already loaded.
{ no warnings "once"; $Cpanel::API::EAPodman::LIB_DIR = "$FindBin::Bin/../SOURCES"; }
$INC{"$FindBin::Bin/../SOURCES/subids.pm"} //= __FILE__;

my $ME = scalar getpwuid($>);

sub uapi {
    my ( $func, %params ) = @_;

    my $args   = Cpanel::Args->new( \%params );
    my $result = Cpanel::Result->new();
    my $rv     = Cpanel::API::EAPodman->can($func)->( $args, $result );
    return ( $rv, $result->data() );
}

sub with_mocks {
    my ( $mocks, $code ) = @_;
    no strict 'refs';
    no warnings 'redefine';
    my %orig = map { $_ => \&{"ea_podman::util::$_"} } keys %{$mocks};
    *{"ea_podman::util::$_"} = $mocks->{$_} for keys %{$mocks};
    my @rv  = eval { $code->() };
    my $err = $@;
    *{"ea_podman::util::$_"} = $orig{$_} for keys %orig;
    die $err if $err;
    return @rv;
}

#-----------------------------------------------------------------------
# The UAPI wrappers
#-----------------------------------------------------------------------

{
    my @calls;
    my %mock = (
        api_list      => sub { push @calls, [ 'api_list', @_ ];      return { "redis.$ME.01" => { user => $ME } } },
        api_install   => sub { push @calls, [ 'api_install', @_ ];   return { container_name => "ea-memcached16.$ME.01" } },
        api_upgrade   => sub { push @calls, [ 'api_upgrade', @_ ];   return 1 },
        api_uninstall => sub { push @calls, [ 'api_uninstall', @_ ]; return 1 },
        api_lifecycle => sub { push @calls, [ 'api_lifecycle', @_ ]; return 1 },
        api_status    => sub { push @calls, [ 'api_status', @_ ];    return { running => 1, enabled => 0 } },
        api_cmd       => sub { push @calls, [ 'api_cmd', @_ ];       return { stdout => "hi\n", stderr => '', exit_code => 0 } },
    );

    with_mocks(
        \%mock,
        sub {
            my ( $rv, $data ) = uapi('list');
            is( $rv, 1, 'list succeeds' );
            is_deeply( $data, { "redis.$ME.01" => { user => $ME } }, 'list: data is api_list()' );

            @calls = ();
            ( $rv, $data ) = uapi( 'install', name => 'redis', image => 'docker.io/library/redis:alpine', 'cpuser_port-1' => 6379, 'cpuser_port-2' => '', 'env-1' => 'A=1', accept_arbitrary_image_risk => 1 );
            is_deeply( $data, { container_name => "ea-memcached16.$ME.01" }, 'install: data is api_install()' );
            my ( undef, %p ) = @{ $calls[0] };
            is_deeply( \%p, { name => 'redis', image => 'docker.io/library/redis:alpine', cpuser_port => [ 6379, '' ], env => ['A=1'], accept_arbitrary_image_risk => 1 }, 'install: the UAPI parameters, by the same names' );

            for my $func (qw(upgrade uninstall status)) {
                @calls = ();
                ( $rv, $data ) = uapi( $func, container_name => "redis.$ME.01" );
                is( $rv, 1, "$func succeeds" );
                is_deeply( $calls[0], [ "api_$func", "redis.$ME.01" ], "$func: api_$func(container_name)" );
            }
            is_deeply( $data, { running => 1, enabled => 0 }, 'status: data is api_status()' );

            for my $func (qw(start stop restart)) {
                @calls = ();
                ( $rv, $data ) = uapi( $func, container_name => "redis.$ME.01" );
                is( $rv, 1, "$func succeeds" );
                is_deeply( $calls[0], [ 'api_lifecycle', "redis.$ME.01", $func ], "$func: api_lifecycle(container_name, $func)" );
                ok( !defined $data, "$func: no data, as before" );
            }

            @calls = ();
            ( $rv, $data ) = uapi( 'cmd', container_name => "redis.$ME.01", 'arg-1' => 'printf', 'arg-2' => '', cd => '/data' );
            is_deeply( $calls[0], [ 'api_cmd', "redis.$ME.01", [ 'printf', '' ], '/data' ], 'cmd: an empty argv element is kept' );
            is_deeply( $data,     { stdout => "hi\n", stderr => '', exit_code => 0 },       'cmd: data is api_cmd()' );

            @calls = ();
            ok( !eval { uapi( 'cmd', container_name => "redis.$ME.01" ); 1 }, 'cmd without arg dies' );
            like( $@, qr/requires a command/, '... with the same message' );
            is_deeply( \@calls, [], '... before running anything' );

            ok( !eval { uapi('install'); 1 }, 'install without name dies' );
            ok( !eval { uapi('upgrade'); 1 }, 'upgrade without container_name dies' );
        }
    );
}

#-----------------------------------------------------------------------
# The shared verbs
#-----------------------------------------------------------------------

{
    my ( @init, @installed );
    with_mocks(
        {
            init_user => sub { push @init, {@_}; return 1 },
            install_container => sub { push @installed, [@_]; print "noise that must not reach the caller\n"; return "redis.$ME.01" },
        },
        sub {
            my $got = ea_podman::util::api_install( name => 'redis', image => 'img:1', cpuser_port => [ 6379, '' ], env => [ 'A=1', '' ], accept_arbitrary_image_risk => 1 );
            is_deeply( $got,   { container_name => "redis.$ME.01" }, 'api_install returns the container name' );
            is_deeply( \@init, [ { creating => 1 } ],                'api_install asks for a session for a first container' );
            is_deeply(
                $installed[0],
                [ 'redis', '--cpuser-port=6379', '-e', 'A=1', '--i-understand-the-risks-do-it-anyway', 'img:1' ],
                'api_install builds the start args as the UAPI did: empty repeats dropped, image last'
            );
            ok( !eval { ea_podman::util::api_install(); 1 }, 'api_install without a name dies' );
        }
    );
}

{
    my ( $xdg, $dbus, $captured_ok );
    local $ENV{DBUS_SESSION_BUS_ADDRESS} = 'unix:path=/stale';
    with_mocks(
        { init_user => sub { return 1 } },
        sub {
            my $rv = ea_podman::util::run_in_user_session(
                sub {
                    $xdg  = $ENV{XDG_RUNTIME_DIR};
                    $dbus = $ENV{DBUS_SESSION_BUS_ADDRESS};
                    print "progress output\n";
                    return 42;
                }
            );
            is( $rv,                            42,                 'run_in_user_session returns what the code returns' );
            is( $xdg,                           "/run/user/$>",     '... with XDG_RUNTIME_DIR at the caller\'s runtime dir' );
            is( $dbus,                          undef,              '... and no inherited DBUS_SESSION_BUS_ADDRESS' );
            is( $ENV{DBUS_SESSION_BUS_ADDRESS}, 'unix:path=/stale', '... restored afterwards' );

            ok(
                !eval {
                    ea_podman::util::run_in_user_session( sub { print "what podman said\n"; die "it broke\n" } );
                    1;
                },
                'a failure dies'
            );
            like( $@, qr/\Ait broke\nwhat podman said\n\z/, '... with the captured output appended' );
        }
    );
}

{
    my @sysctl;
    with_mocks(
        {
            init_user                    => sub { return 1 },
            sysctl                       => sub { push @sysctl, [@_];             return 1 },
            reset_container_unit_failure => sub { push @sysctl, ['reset-failed']; return 1 },
            get_container_service_name   => sub { return "svc-$_[0]" },
        },
        sub {
            ea_podman::util::api_lifecycle( "redis.$ME.01", 'start' );
            is_deeply( \@sysctl, [ ['reset-failed'], [ start => "svc-redis.$ME.01" ] ], 'start: clear the failed state first' );

            @sysctl = ();
            ea_podman::util::api_lifecycle( "redis.$ME.01", 'stop' );
            is_deeply( \@sysctl, [ [ stop => "svc-redis.$ME.01" ], ['reset-failed'] ], 'stop: clear it after' );

            ok( !eval { ea_podman::util::api_lifecycle( "redis.$ME.01", 'enable' ); 1 }, 'only start, stop and restart' );
            ok( !eval { ea_podman::util::api_lifecycle( 'bad name',     'start' );  1 }, 'a malformed name is refused' );

            @sysctl = ();
            my $state = ea_podman::util::api_status("redis.$ME.01");
            is_deeply( $state, { running => 1, enabled => 1 }, 'status: is-active and is-enabled' );
            is_deeply( [ map { $_->[0] } @sysctl ], [ 'is-active', 'is-enabled' ] );
        }
    );
}

done_testing();
