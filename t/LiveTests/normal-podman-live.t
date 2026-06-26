#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# CPANEL-54037 — LIVE integration test (NOT a unit test). Sister to
# t/LiveTests/jailshell-podman-live.t and
# t/LiveTests/cagefs-podman-live.t.
#
# WHAT THIS PROVES. A NORMAL cPanel account — one with an unrestricted
# login shell and NOT under CageFS — can deploy and manage rootless
# ea-podman containers. This is the baseline case that jailshell and
# CageFS are restricted variants of: the same UAPI path
# (install/list/start/stop/restart/uninstall, with the privileged
# enable-linger bootstrap done as root) works here too. Unlike a
# restricted account, a normal account may ALSO use the `ea-podman` CLI
# directly — this test asserts that the CLI is not shell-gated for it.
#
# Methodology mirrors the sister tests: UAPI verbs plus cage-independent
# root-side checks (linger, the user systemd manager, and a TCP PING to
# the published port discovered from cpuser_port_authority). Because the
# account is unrestricted, `su`-based checks are also valid here and are
# used for the in-container/CLI assertions.
#
# Run ON A LIVE cPanel VM, as root, with podman installed, an ea-podman
# build carrying the CPANEL-54037 changes, and a cPanel build with
# Cpanel::API::EAPodman:
#
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl normal-podman-live.t
#
# cgroup: this test runs on both cgroup v1 and v2 -- ea-podman's shipped
# Type=forking units bring the container up and serve on either hierarchy.
# (cgroup v2 still gives the user manager proper subtree delegation; cgroup v1
# does not, so resource limits may not apply, but bring-up and serving work.)
#
# Environment variables:
#   EAPODMAN_LIVE=1      REQUIRED opt-in.
#   EAPODMAN_TEST_USER   reuse an existing account (its shell is set to an
#                        unrestricted shell for the test and restored
#                        afterward) instead of creating a throwaway one.
#   EAPODMAN_TEST_IMAGE  image to install (default: redis:alpine).
#   EAPODMAN_TEST_PORT   container port to publish (default: 6379).
#   EAPODMAN_KEEP=1      skip teardown.
#######################################################################

use strict;
use warnings;

use Test::More;

use IPC::Open3       ();
use Symbol           ();
use IO::Socket::INET ();
use IO::Select       ();

#---------------------------------------------------------------------
# config
#---------------------------------------------------------------------
my $IMAGE = $ENV{EAPODMAN_TEST_IMAGE} || 'docker.io/library/redis:alpine';
my $PORT  = $ENV{EAPODMAN_TEST_PORT}  || 6379;
my $KEEP  = $ENV{EAPODMAN_KEEP};
my $CBASE = 'eapod54037';
my $BASH  = '/bin/bash';    # an unrestricted login shell

my $UAPI      = '/usr/local/cpanel/bin/uapi';
my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman';
my $UAPI_MOD  = '/usr/local/cpanel/Cpanel/API/EAPodman.pm';
my $PORTAUTH  = '/usr/local/cpanel/scripts/cpuser_port_authority';
my @CLI_PATHS = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

#---------------------------------------------------------------------
# helpers
#---------------------------------------------------------------------
my $json;

sub run_cmd {
    my (@cmd) = @_;
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( my $in, my $out, $err, @cmd );
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid( $pid, 0 );
    return ( $? >> 8, $stdout . $stderr );
}

# Decode a JSON document from STDOUT alone (cpsrvd logs to STDERR).
sub run_json {
    my (@cmd) = @_;
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( my $in, my $out, $err, @cmd );
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid( $pid, 0 );
    my $decoded = eval { $json->($stdout) };
    return ( $? >> 8, $decoded, $stdout, $stderr );
}

# Run a command AS $user via `su` (no jail, no cage here) with the rootless
# podman environment primed. Returns ($exit, $output).
sub run_as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "$env $cmd" );
}

sub uapi {
    my ( $user, $func, @kv ) = @_;
    my ( $rc, $decoded, $out, $err ) = run_json( $UAPI, "--user=$user", '--output=json', 'EAPodman', $func, @kv );
    die "uapi $func: could not parse JSON (exit $rc):\nSTDOUT:\n$out\nSTDERR:\n$err\n" if !$decoded;
    return $decoded->{result} // $decoded;
}

sub wait_for {
    my ( $predicate, $timeout ) = @_;
    $timeout //= 10;
    for ( 1 .. $timeout * 10 ) {
        return 1 if $predicate->();
        select( undef, undef, undef, 0.1 );
    }
    return $predicate->();
}

#---------------------------------------------------------------------
# preconditions
#---------------------------------------------------------------------
plan skip_all => "live test; set EAPODMAN_LIVE=1 to run" unless $ENV{EAPODMAN_LIVE};
plan skip_all => "must run as root" if $> != 0;

{
    local $@;
    if ( eval { require Cpanel::JSON; 1 } ) {
        $json = sub { return Cpanel::JSON::Load( $_[0] ) };
    }
    elsif ( eval { require JSON::PP; 1 } ) {
        my $jp = JSON::PP->new;
        $json = sub { return $jp->decode( $_[0] ) };
    }
    else {
        plan skip_all => "no JSON module available";
    }
}

plan skip_all => "podman is not installed"                    if !_in_path('podman');
plan skip_all => "uapi not found ($UAPI)"                     if !-x $UAPI;
plan skip_all => "Cpanel::API::EAPodman not installed"        if !-e $UAPI_MOD;
plan skip_all => "ea-podman library not installed"            if !-e "$EAP_LIB/subids.pm";
plan skip_all => "cpuser_port_authority not found ($PORTAUTH)" if !-x $PORTAUTH;

# ea-podman must carry the CPANEL-54037 fix.
{
    open my $fh, '<', "$EAP_LIB/subids.pm" or plan skip_all => "cannot read $EAP_LIB/subids.pm";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates CPANEL-54037 (no enable-linger / ensure_user_session in subids.pm); rebuild/install it first"
      if $src !~ /enable[-_ ]?linger/ && $src !~ /ensure_user_session/;
}

# ea-podman runs on cgroup v1 as well as v2 (the shipped Type=forking units
# bring the container up and serve on either). We no longer skip on cgroup v1;
# the cgroup version is reported in the diag below for context.
my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';

my ($CLI) = grep { -x $_ } @CLI_PATHS;

#---------------------------------------------------------------------
# test account
#---------------------------------------------------------------------
our $USER;
our $CREATED_USER = 0;
our $ORIG_SHELL;

if ( $ENV{EAPODMAN_TEST_USER} ) {
    $USER = $ENV{EAPODMAN_TEST_USER};
    plan skip_all => "EAPODMAN_TEST_USER '$USER' is not a system user" if !defined getpwnam($USER);
    $ORIG_SHELL = ( getpwnam($USER) )[8];
}
else {
    $USER = 'eap' . substr( time, -5 );
    my $domain = "$USER.cpanel54037.test";
    my $pw     = 'Eap0d' . substr( time, -6 ) . '!Xy';

    diag("Creating throwaway cPanel account '$USER' ($domain) …");
    my ( $rc, $res, $out, $err ) = run_json( $WHMAPI, 'createacct', "username=$USER", "domain=$domain", "password=$pw", '--output=json' );
    if ( !$res || !$res->{metadata} || !$res->{metadata}{result} ) {
        plan skip_all => "could not create test account '$USER' (set EAPODMAN_TEST_USER to reuse one):\nSTDOUT:\n$out\nSTDERR:\n$err";
    }
    $CREATED_USER = 1;
}

# Give the account an UNRESTRICTED shell — the scenario under test (a normal,
# non-jailed account). CageFS is not touched.
$ORIG_SHELL //= ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', $BASH, $USER );
my $uid = ( getpwnam($USER) )[2];

# Clean baseline: no linger, no runtime dir.
run_cmd( 'loginctl', 'disable-linger', $USER );
run_cmd( 'systemctl', 'stop', "user\@$uid.service" );
wait_for( sub { !-e "/run/user/$uid" }, 5 );

diag("Test user: $USER (uid=$uid), shell=" . ( ( getpwnam($USER) )[8] ) . ", cgroup=$CGROUP, image=$IMAGE, port=$PORT");

#=====================================================================
# the tests
#=====================================================================

is( ( getpwnam($USER) )[8], $BASH, "test account login shell is unrestricted ($BASH)" );

ok( !-e "/run/user/$uid", "baseline: no /run/user/$uid before install" );
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    unlike( $out, qr/Linger=yes/, "baseline: linger not enabled before install" );
}

# Distinguishing trait: a NORMAL account is NOT shell-gated, so it may run the
# ea-podman CLI directly (unlike jailshell/CageFS accounts).
SKIP: {
    skip "ea-podman CLI not found", 1 if !$CLI;
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " list" );
    unlike( $out, qr/restricted shell/i, "normal user can run the ea-podman CLI directly (not shell-gated)" );
}

#--- install via UAPI ------------------------------------------------
my $container;
{
    my @args = ( "name=$CBASE", "image=$IMAGE", "cpuser_port=$PORT", 'accept_arbitrary_image_risk=1' );
    my $res  = uapi( $USER, 'install', @args );
    ok( $res->{status}, "uapi EAPodman install succeeded" )
      or diag( "errors: " . join( "; ", @{ $res->{errors} || [] } ) );
    $container = $res->{data} && $res->{data}{container_name};
    like( $container // '', qr/^\Q$CBASE\E\.\Q$USER\E\.[0-9][0-9]$/, "install returned a container name ($container)" );
}

BAIL_OUT("install did not return a container name; cannot continue") if !$container;

#--- the session was bootstrapped as root (root-side) ----------------
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    like( $out, qr/Linger=yes/, "linger is now enabled for $USER (survives logout/reboot)" );
}
ok( -S "/run/user/$uid/bus", "user dbus socket /run/user/$uid/bus exists" );
{
    my ( $rc, $out ) = run_cmd( 'systemctl', 'is-active', "user\@$uid.service" );
    like( $out, qr/\bactive\b/, "user\@$uid.service (user systemd manager) is active" );
}

#--- the container is registered -------------------------------------
{
    my $res = uapi( $USER, 'list' );
    ok( $res->{status} && $res->{data} && exists $res->{data}{$container}, "uapi EAPodman list shows $container" );
}

#--- the container actually runs and serves --------------------------
my $unit = "container-$container.service";
ok( _container_running($USER), "podman shows $container running" );
{
    my ( $rc, $out ) = run_as_user( $USER, "systemctl --user is-enabled " . _sh($unit) );
    like( $out, qr/\benabled\b/, "systemd --user unit $unit is enabled" );
}
SKIP: {
    skip "non-redis image ($IMAGE); skipping redis functional check", 1 if $IMAGE !~ /redis/i;
    ok( wait_for( sub { _redis_serving_via_port($USER) }, 45 ),
        "redis answers PING over the published host port (root-side)" )
      or diag( "assigned host port: " . ( _assigned_host_port($USER) // '(none found via cpuser_port_authority)' ) );
}

#--- cmd: run commands inside the container (CPANEL-54360, via nsenter) ---
# Enters the container's namespaces with nsenter (root-side for the cpuser),
# so it works even on this hidepid=2 host where `podman exec` would fail.
{
    my $res = uapi( $USER, 'cmd', "container_name=$container", 'arg=date' );
    ok( $res->{status}, "uapi EAPodman cmd (date) succeeded" )
      or diag( "errors: " . join( "; ", @{ $res->{errors} || [] } ) );
    is( $res->{data}{exit_code}, 0, "cmd date exited 0" );
    like( $res->{data}{stdout}, qr/\d{4}/, "cmd date produced date-like stdout" );

    # Exit-code fidelity: a command that exits non-zero is NOT a UAPI failure —
    # its real code is surfaced in data.exit_code.
    my $f = uapi( $USER, 'cmd', "container_name=$container", 'arg=false' );
    ok( $f->{status}, "uapi cmd (false) is still a successful UAPI call" );
    is( $f->{data}{exit_code}, 1, "cmd (false) surfaces exit_code 1" );

    # --cd runs the command from the given working directory.
    my $cd = uapi( $USER, 'cmd', "container_name=$container", 'cd=/etc', 'arg=pwd' );
    is( $cd->{data}{exit_code}, 0, "cmd --cd=/etc pwd exited 0" );
    like( $cd->{data}{stdout}, qr{^/etc\b}, "cmd --cd=/etc ran from /etc" );

    # Sysadmin task: write a file into the container OS and read it back
    # (a separate invocation, proving the change persisted in the container).
    my $w = uapi( $USER, 'cmd', "container_name=$container", 'arg=touch', 'arg=/eapodman-cmd-marker' );
    is( $w->{data}{exit_code}, 0, "cmd touch created a file in the container" );
    my $r = uapi( $USER, 'cmd', "container_name=$container", 'arg=ls', 'arg=/eapodman-cmd-marker' );
    like( $r->{data}{stdout}, qr{/eapodman-cmd-marker}, "the written file persists and is visible to a later cmd" );
}

# A NORMAL account may ALSO run `cmd` via the direct CLI (not just UAPI). As an
# unrestricted-shell account this routes through the root adminbin, so it works
# on this hidepid host too.
SKIP: {
    skip "ea-podman CLI not found", 1 if !$CLI;
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " cmd " . _sh($container) . " -- date" );
    like( $out, qr/\d{4}/, "direct CLI 'ea-podman cmd ... -- date' produced date-like output" );
}

#--- lifecycle: stop / start / restart -------------------------------
{
    my $res = uapi( $USER, 'stop', "container_name=$container" );
    ok( $res->{status}, "uapi EAPodman stop succeeded" );

    $res = uapi( $USER, 'start', "container_name=$container" );
    ok( $res->{status}, "uapi EAPodman start succeeded" );

    $res = uapi( $USER, 'restart', "container_name=$container" );
    ok( $res->{status}, "uapi EAPodman restart succeeded" );

    SKIP: {
        skip "non-redis image ($IMAGE); skipping serving re-check", 1 if $IMAGE !~ /redis/i;
        ok( wait_for( sub { _redis_serving_via_port($USER) }, 45 ), "redis is serving again over the published port after restart" );
    }
}

#--- persistence proxy: restart the user manager (simulates reboot) --
{
    run_cmd( 'systemctl', 'restart', "user\@$uid.service" );
    ok( wait_for( sub { -S "/run/user/$uid/bus" }, 15 ), "user manager came back after restart (linger)" );

    SKIP: {
        skip "non-redis image ($IMAGE); skipping post-reboot serving check", 1 if $IMAGE !~ /redis/i;
        ok( wait_for( sub { _redis_serving_via_port($USER) }, 60 ), "redis auto-started and serves after the user manager restart (survives reboot)" );
    }
}

#--- uninstall cleans up ---------------------------------------------
{
    my $res = uapi( $USER, 'uninstall', "container_name=$container" );
    ok( $res->{status}, "uapi EAPodman uninstall succeeded" );

    my $list = uapi( $USER, 'list' );
    ok( !( $list->{data} && exists $list->{data}{$container} ), "uninstalled container no longer registered" );
}

done_testing();

#---------------------------------------------------------------------
# helpers (cont.)
#---------------------------------------------------------------------
sub _in_path {
    my ($bin) = @_;
    for my $d ( split /:/, $ENV{PATH} || '' ) {
        return 1 if -x "$d/$bin";
    }
    my ($rc) = run_cmd( '/bin/sh', '-c', "command -v " . _sh($bin) );
    return $rc == 0;
}

sub _container_running {
    my ($user) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman ps --no-trunc --format '{{.Names}}'" );
    return 0 if $rc != 0;
    return scalar( grep { $_ eq $container } split /\n/, $out );
}

# The host port $PORT was published to, discovered ROOT-SIDE from the port
# authority. Returns the port or undef.
sub _assigned_host_port {
    my ($user) = @_;
    my ( $rc, $out ) = run_cmd( $PORTAUTH, 'list', $user );
    return if $rc != 0;
    my $hr = eval { $json->($out) };
    return if !$hr || ref $hr ne 'HASH';
    for my $port ( keys %{$hr} ) {
        my $svc = ref $hr->{$port} eq 'HASH' ? ( $hr->{$port}{service} // '' ) : '';
        return $port if $svc eq $container;
    }
    return;
}

sub _redis_serving_via_port {
    my ($user) = @_;
    my $port = _assigned_host_port($user) or return 0;
    return _redis_ping_over_tcp( '127.0.0.1', $port );
}

sub _redis_ping_over_tcp {
    my ( $ip, $port ) = @_;
    my $sock = IO::Socket::INET->new( PeerHost => $ip, PeerPort => $port, Proto => 'tcp', Timeout => 5 ) or return 0;
    syswrite( $sock, "PING\r\n" );
    my $reply = '';
    my $sel   = IO::Select->new($sock);
    sysread( $sock, $reply, 64 ) if $sel->can_read(5);
    close $sock;
    return $reply =~ /\+PONG/ ? 1 : 0;
}

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

#---------------------------------------------------------------------
# teardown
#---------------------------------------------------------------------
END {
    return if $KEEP;
    return if !$USER;

    if ( defined $container ) {
        run_cmd( $UAPI, "--user=$USER", '--output=json', 'EAPodman', 'uninstall', "container_name=$container" );
    }

    my $uid_t = ( getpwnam($USER) )[2];
    run_cmd( 'loginctl', 'disable-linger', $USER )         if defined $uid_t;
    run_cmd( 'systemctl', 'stop', "user\@$uid_t.service" ) if defined $uid_t;

    if ($CREATED_USER) {
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
    }
    elsif ( $ORIG_SHELL && $ORIG_SHELL ne $BASH ) {
        run_cmd( '/usr/sbin/usermod', '-s', $ORIG_SHELL, $USER );    # restore original shell
    }
}
