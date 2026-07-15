#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# CPANEL-54037 — LIVE integration test (NOT a unit test).
#
# Proves the end-to-end mechanism that lets a cPanel user whose login
# shell is restricted (jailshell) deploy and manage rootless ea-podman
# containers via UAPI, with no interactive login session:
#
#   1. root `loginctl enable-linger` (run inside ENSURE_USER) creates
#      /run/user/<uid> + starts the user systemd manager (persists across
#      logout/reboot), and
#   2. UAPI runs as the cpuser and calls ea_podman::util directly, so it
#      never execs the login shell — the jailshell chroot is bypassed.
#
# This must run ON A LIVE cPanel VM, as root, with:
#   * podman installed,
#   * a build of ea-podman that INCLUDES the CPANEL-54037 changes
#     (ea_podman::subids::ensure_user_session / enable-linger), and
#   * a cPanel build that includes Cpanel::API::EAPodman.
#
# It is intentionally excluded from the normal unit harness (it mutates
# real system state) and only runs when opted in. Copy this file to the test
# VM and run it directly (it does not need the rest of the repo):
#
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl jailshell-podman-live.t
#   EAPODMAN_LIVE=1 EAPODMAN_DRIVER=cli /usr/local/cpanel/3rdparty/bin/perl jailshell-podman-live.t
#
# Configuration (environment variables):
#   EAPODMAN_LIVE=1      REQUIRED opt-in; without it the test skips (so a
#                        stray `prove` run on a build box can't fire it).
#   EAPODMAN_DRIVER      how to issue each verb: "uapi" (default; via
#                        `uapi --user`) or "cli" (the in-jail ea-podman CLI,
#                        which delegates back to the UAPI). Run the file once
#                        per value to cover both entry points with the same
#                        lifecycle assertions.
#   EAPODMAN_TEST_USER   reuse an existing cPanel account instead of
#                        creating a throwaway one (its shell is flipped to
#                        jailshell for the test and restored afterward).
#   EAPODMAN_TEST_IMAGE  container image to install (default: a small,
#                        long-running image — redis:alpine).
#   EAPODMAN_TEST_PORT   container port to publish (default: 6379).
#   EAPODMAN_KEEP=1      skip teardown (leave the account/container for
#                        manual inspection).
#######################################################################

use strict;
use warnings;

use Test::More;

use IPC::Open3      ();
use Symbol          ();
use IO::Socket::INET ();
use IO::Select      ();

#---------------------------------------------------------------------
# config
#---------------------------------------------------------------------
my $JAILSHELL = '/usr/local/cpanel/bin/jailshell';
my $IMAGE     = $ENV{EAPODMAN_TEST_IMAGE} || 'docker.io/library/redis:alpine';
my $PORT      = $ENV{EAPODMAN_TEST_PORT}  || 6379;
my $KEEP      = $ENV{EAPODMAN_KEEP};
my $CBASE     = 'eapod54037';                         # arbitrary container base name (the `name=` arg)
my $DRIVER    = lc( $ENV{EAPODMAN_DRIVER} || 'uapi' );    # how to issue verbs: 'uapi' (uapi --user) or 'cli' (in-jail ea-podman)

my $UAPI       = '/usr/local/cpanel/bin/uapi';
my $WHMAPI     = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB    = '/opt/cpanel/ea-podman/lib/ea_podman';
my $UAPI_MOD   = '/usr/local/cpanel/Cpanel/API/EAPodman.pm';
my @CLI_PATHS  = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

#---------------------------------------------------------------------
# tiny shell helpers (no login shell, so jailshell is never entered)
#---------------------------------------------------------------------

# JSON decoder coderef; populated from the preconditions block below.
# Declared here so run_json (a named sub) can close over it.
my $json;

# Run a command (list form, no shell) and return ($exit, $combined_output).
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

# Like run_cmd, but for commands that emit a JSON document on STDOUT
# (whmapi1/uapi with --output=json). cpsrvd logs unrelated lines (e.g.
# "info [xml-api] Set PHP error_log …") to STDERR, so the JSON must be
# decoded from STDOUT *alone* — concatenating STDERR breaks the parse.
# Returns ($exit, $decoded_or_undef, $stdout, $stderr); the raw streams
# are returned so a genuine failure can still be reported (the reason
# typically lands on STDERR).
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

# Run a command AS $user without their login shell (bypasses jailshell),
# with the rootless podman environment primed. Returns ($exit, $output).
sub run_as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "$env $cmd" );
}

# Run a command through the account's LOGIN shell (enters the jailshell chroot),
# i.e. exactly how the user would invoke it. This is the faithful path for the
# delegated CLI: it proves the CLI can reach the adminbin (cpwrapd) and cpsrvd
# over localhost HTTPS from INSIDE the jail. Returns ($exit, $combined_output).
sub run_in_jail {
    my ( $user, $cmd ) = @_;
    return run_cmd( 'su', '-', $user, '-c', $cmd );
}

# Run EAPodman UAPI verb as $user; returns the decoded result hashref
# (the inner {result} object) or dies on transport/parse failure.
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

# Restart the lingering user manager, tolerating a systemd-249 race where the
# immediate restart of user@<uid>.service fails with status=219/CGROUP: the old
# user-<uid>.slice cgroup is not fully torn down when the new instance tries to
# create its own, and left alone the manager only recovers minutes later. Clear
# the failed state and retry until it is active. A real reboot starts from a
# clean cgroup tree and never hits this, so this only keeps the restart-based
# "reboot" proxy reliable (Ubuntu 22.04 / systemd 249 races; 255 does not).
sub restart_user_manager {
    my ($uid)  = @_;
    my $unit   = "user\@$uid.service";
    my $active = sub { ( run_cmd( 'systemctl', 'is-active', '--quiet', $unit ) )[0] == 0 };
    for my $try ( 1 .. 6 ) {
        run_cmd( 'systemctl', ( $try == 1 ? 'restart' : 'start' ), $unit );
        return 1 if wait_for( $active, 8 );
        run_cmd( 'systemctl', 'reset-failed', $unit );    # drop the 219/CGROUP failure
        sleep 2;                                          # let the old cgroup drain
    }
    return 0;
}

#---------------------------------------------------------------------
# preconditions
#---------------------------------------------------------------------

# Opt-in only. This file lives under t/ but is a destructive LIVE test
# (it creates/removes real accounts, toggles linger, spawns containers).
# The guard keeps `prove`/CI from auto-running it on any build box that
# happens to have podman + a fixed ea-podman installed.
plan skip_all => "live test; set EAPODMAN_LIVE=1 to run" unless $ENV{EAPODMAN_LIVE};

plan skip_all => "must run as root" if $> != 0;

# JSON decoder (prefer cPanel's, fall back to JSON::PP).
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

plan skip_all => "podman is not installed"                 if !_in_path('podman');
plan skip_all => "uapi not found ($UAPI)"                  if !-x $UAPI;
plan skip_all => "Cpanel::API::EAPodman not installed"     if !-e $UAPI_MOD;
plan skip_all => "ea-podman library not installed"         if !-e "$EAP_LIB/subids.pm";
plan skip_all => "EAPODMAN_DRIVER must be 'uapi' or 'cli' (got '$DRIVER')" if $DRIVER ne 'uapi' && $DRIVER ne 'cli';

# (No cgroup-version gate: the serving path is validated on both cgroup v1 and
# v2 — AlmaLinux 8/9/10, Ubuntu 24.04, and CloudLinux 8/9/10. CloudLinux
# defaults to cgroup v1, so gating to v2 would mean never exercising it.)

# Make sure the installed ea-podman actually carries the CPANEL-54037 fix,
# otherwise this test would silently exercise the old (broken) code path.
{
    open my $fh, '<', "$EAP_LIB/subids.pm" or plan skip_all => "cannot read $EAP_LIB/subids.pm";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates CPANEL-54037 (no enable-linger / ensure_user_session in subids.pm); rebuild/install it first"
      if $src !~ /enable[-_ ]?linger/ && $src !~ /ensure_user_session/;
}

my ($CLI) = grep { -x $_ } @CLI_PATHS;

plan skip_all => "EAPODMAN_DRIVER=cli but no ea-podman CLI found (@CLI_PATHS)" if $DRIVER eq 'cli' && !$CLI;

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
    $USER = 'eap' . substr( time, -5 );    # <=8 chars, well under the cPanel username limit
    my $domain = "$USER.cpanel54037.test";
    my $pw     = 'Eap0d' . substr( time, -6 ) . '!Xy';

    diag("Creating throwaway cPanel account '$USER' ($domain) …");
    my ( $rc, $res, $out, $err ) = run_json( $WHMAPI, 'createacct', "username=$USER", "domain=$domain", "password=$pw", '--output=json' );
    if ( !$res || !$res->{metadata} || !$res->{metadata}{result} ) {
        plan skip_all => "could not create test account '$USER' (set EAPODMAN_TEST_USER to reuse one):\nSTDOUT:\n$out\nSTDERR:\n$err";
    }
    $CREATED_USER = 1;
}

# Flip the account to jailshell — the scenario under test.
$ORIG_SHELL //= ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', $JAILSHELL, $USER );
my $uid = ( getpwnam($USER) )[2];

# Guarantee a clean baseline: no linger, no runtime dir.
run_cmd( 'loginctl', 'disable-linger', $USER );
run_cmd( 'systemctl', 'stop', "user\@$uid.service" );
wait_for( sub { !-e "/run/user/$uid" }, 5 );

diag("Test user: $USER (uid=$uid), shell=" . ( ( getpwnam($USER) )[8] ) . ", image=$IMAGE, port=$PORT, driver=$DRIVER");

#=====================================================================
# the tests
#=====================================================================

is( ( getpwnam($USER) )[8], $JAILSHELL, "test account login shell is jailshell" );

ok( !-e "/run/user/$uid", "baseline: no /run/user/$uid before install" );
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    unlike( $out, qr/Linger=yes/, "baseline: linger not enabled before install" );
}

# The jail is real: through the LOGIN shell the user cannot see /etc/subuid.
SKIP: {
    skip "no jailshell binary", 1 if !-x $JAILSHELL;
    my ( $rc, $out ) = run_cmd( 'su', '-', $USER, '-c', 'cat /etc/subuid' );
    isnt( $rc, 0, "login shell (jailshell) cannot read /etc/subuid — the chroot is active" );
}

#---------------------------------------------------------------------
# driver: issue an EAPodman verb either via UAPI (`uapi --user`) or via the
# in-jail ea-podman CLI, normalized to the UAPI envelope { status, data,
# errors } so every lifecycle assertion below is identical for both. Selected
# with EAPODMAN_DRIVER=uapi|cli. (Run the file twice to cover both.)
#---------------------------------------------------------------------
sub op {
    my ( $verb, %args ) = @_;
    return $DRIVER eq 'cli' ? _op_cli( $verb, %args ) : _op_uapi( $verb, %args );
}

sub _op_uapi {
    my ( $verb, %args ) = @_;
    my @kv;
    push @kv, "name=$args{name}"                     if defined $args{name};
    push @kv, "image=$args{image}"                   if defined $args{image};
    push @kv, "cpuser_port=$args{container_port}" if defined $args{container_port};
    push @kv, "accept_arbitrary_image_risk=1"        if $args{accept_arbitrary_image_risk};
    push @kv, "container_name=$args{container_name}" if defined $args{container_name};
    push @kv, "arg=$args{command}"                   if defined $args{command};
    push @kv, "cd=$args{cd}"                         if defined $args{cd};
    return uapi( $USER, $verb, @kv );
}

# Drive the CLI through the account's LOGIN shell (run_in_jail) so it exercises
# the real jail → adminbin → localhost-HTTPS delegation, then map its textual
# output back onto the UAPI envelope.
sub _op_cli {
    my ( $verb, %args ) = @_;

    my $cmd = _sh($CLI) . " $verb";
    if ( $verb eq 'install' ) {
        $cmd .= " " . _sh( $args{name} );
        $cmd .= " --cpuser-port=" . _sh( $args{container_port} ) if defined $args{container_port};
        $cmd .= " --i-understand-the-risks-do-it-anyway"      if $args{accept_arbitrary_image_risk};
        $cmd .= " " . _sh( $args{image} )                     if defined $args{image};
    }
    elsif ( $verb eq 'cmd' ) {
        $cmd .= " " . _sh( $args{container_name} );
        $cmd .= " --cd " . _sh( $args{cd} ) if defined $args{cd};
        $cmd .= " -- " . _sh( $args{command} );
    }
    elsif ( defined $args{container_name} ) {
        $cmd .= " " . _sh( $args{container_name} );
    }

    my ( $exit, $out ) = run_in_jail( $USER, $cmd );

    if ( $verb eq 'install' ) {
        my ($name) = $out =~ /Done,\s*installed:\s*(\S+)/;
        return { status => ( $name ? 1 : 0 ), data => { container_name => $name }, errors => ( $name ? undef : [$out] ) };
    }
    if ( $verb eq 'list' ) {
        # A login shell (su -) may prepend a banner/MOTD; isolate the JSON
        # object (pretty_canonical_dump emits a single top-level {...}).
        my $jsontext = $out;
        $jsontext =~ s/\A[^{]*//s;
        $jsontext =~ s/[^}]*\z//s;
        my $data = eval { $json->($jsontext) };
        return { status => ( $data ? 1 : 0 ), data => ( $data || {} ), errors => ( $data ? undef : [$out] ) };
    }
    if ( $verb eq 'cmd' ) {
        # The CLI `cmd` verb exits with the exec'd command's own exit code and
        # prints its stdout/stderr directly (no JSON envelope) — $exit IS the
        # command's exit status here, unlike start/stop/restart below.
        return { status => 1, data => { stdout => $out, exit_code => $exit }, errors => undef };
    }

    # start / stop / restart / uninstall: success is a clean exit
    return { status => ( $exit == 0 ? 1 : 0 ), data => {}, errors => ( $exit == 0 ? undef : [$out] ) };
}

#--- install via the selected driver --------------------------------
my $container;
{
    my $res = op( 'install', name => $CBASE, image => $IMAGE, container_port => $PORT, accept_arbitrary_image_risk => 1 );
    ok( $res->{status}, "[$DRIVER] EAPodman install succeeded" )
      or diag( "errors: " . join( "; ", @{ $res->{errors} || [] } ) );
    $container = $res->{data} && $res->{data}{container_name};
    like( $container // '', qr/^\Q$CBASE\E\.\Q$USER\E\.[0-9][0-9]$/, "install returned a container name ($container)" );
}

BAIL_OUT("install did not return a container name; cannot continue") if !$container;

#--- the session was bootstrapped as root (the linchpin) -------------
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    like( $out, qr/Linger=yes/, "linger is now enabled for $USER (survives logout/reboot)" );
}
ok( -S "/run/user/$uid/bus", "user dbus socket /run/user/$uid/bus exists" );
{
    my ( $rc, $out ) = run_cmd( 'systemctl', 'is-active', "user\@$uid.service" );
    like( $out, qr/\bactive\b/, "user\@$uid.service (user systemd manager) is active" );
}

#--- the container is actually running (checked as the user) ---------
my $unit = "container-$container.service";
ok( _container_running($USER), "podman shows $container running (no login session)" );
{
    my ( $rc, $out ) = run_as_user( $USER, "systemctl --user is-enabled " . _sh($unit) );
    like( $out, qr/\benabled\b/, "systemd --user unit $unit is enabled" );
}

#--- the service actually answers (functional, not just "Up") --------
# "Running" per podman does not prove redis is serving or that the
# container_port publish is wired through to the host. Prove both with PING:
#   #1 (authoritative) redis answers over the PUBLISHED host port
#      (raw RESP "PING\r\n" -> "+PONG"), which exercises the port mapping —
#      this is what callers actually depend on.
#   #2 redis answers from INSIDE the container (`podman exec` redis-cli ping).
# Both poll for readiness so a module-heavy image that takes a beat to reach
# "Ready to accept connections" does not yield a false negative. The two are
# independent: a broken `podman exec` must not hide a working published port.
SKIP: {
    skip "non-redis image ($IMAGE); skipping redis functional checks", 2 if $IMAGE !~ /redis/i;

    # #1 — published host port (the assigned port may differ from $PORT).
    my ( $ip, $host_port );
    my $serves_port = wait_for(
        sub {
            ( $ip, $host_port ) = _published_host_endpoint($USER);
            return ( $ip && $host_port && _redis_ping_over_tcp( $ip, $host_port ) ) ? 1 : 0;
        },
        30
    );
    ok( $serves_port, "redis answers PING over the published port (" . ( $ip // '?' ) . ":" . ( $host_port // '?' ) . ")" );

    # #2 — in-container `podman exec`. This relies on `podman exec`, which is
    # broken on older podman (4.x) + runc under cgroup v1 / LVE (e.g. CloudLinux
    # 8): it fails with "cannot exec in a stopped container" even while the
    # container runs and serves. So if the published port already answered,
    # treat an exec failure as unsupported-exec (skip), not a serving failure.
    my $serves_exec = wait_for( sub { _redis_ping_in_container($USER) }, 15 );
    skip "podman exec unsupported here (older podman/runc under cgroup v1); container serves over the published port", 1
      if !$serves_exec && $serves_port;
    ok( $serves_exec, "redis answers PING inside the container (redis-cli ping)" );
}

#--- list reflects the container -------------------------------------
{
    my $res = op('list');
    ok( $res->{status} && $res->{data} && exists $res->{data}{$container}, "[$DRIVER] EAPodman list shows $container" );
}

#--- cmd: run commands inside the container (CPANEL-54360, via nsenter) ---
# The delegated path (jailshell → adminbin → nsenter as root) works even on
# this hidepid=2 host where `podman exec` fails. Exercised through whichever
# driver ($DRIVER) this run selected — the UAPI directly, or the in-jail CLI.
{
    my $res = op( 'cmd', container_name => $container, command => 'date' );
    ok( $res->{status}, "[$DRIVER] EAPodman cmd (date) succeeded" )
      or diag( "errors: " . join( "; ", @{ $res->{errors} || [] } ) );
    is( $res->{data}{exit_code}, 0, "[$DRIVER] cmd date exited 0" );
    like( $res->{data}{stdout}, qr/\d{4}/, "[$DRIVER] cmd date produced date-like stdout" );

    # Exit-code fidelity: a non-zero command exit is surfaced, not turned into
    # a delegation failure.
    my $f = op( 'cmd', container_name => $container, command => 'false' );
    is( $f->{data}{exit_code}, 1, "[$DRIVER] cmd (false) surfaces exit_code 1" );

    # --cd runs from the given working directory.
    my $cd = op( 'cmd', container_name => $container, cd => '/etc', command => 'pwd' );
    is( $cd->{data}{exit_code}, 0, "[$DRIVER] cmd --cd=/etc pwd exited 0" );
    like( $cd->{data}{stdout}, qr{/etc}, "[$DRIVER] cmd --cd=/etc ran from /etc" );
}

#--- lifecycle: stop / start / restart -------------------------------
{
    my $res = op( 'stop', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman stop succeeded" );
    ok( wait_for( sub { !_container_running($USER) }, 30 ), "container is stopped after stop" );

    $res = op( 'start', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman start succeeded" );
    ok( wait_for( sub { _container_running($USER) }, 30 ), "container is running after start" );

    $res = op( 'restart', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman restart succeeded" );
    ok( wait_for( sub { _container_running($USER) }, 30 ), "container is running after restart" );
}

#--- persistence proxy: restart the user manager (simulates reboot) --
{
    ok( restart_user_manager($uid), "user manager restarts cleanly (works around the systemd-249 cgroup race)" );
    ok( wait_for( sub { -S "/run/user/$uid/bus" }, 15 ), "user manager came back after restart (linger)" );
    ok( wait_for( sub { _container_running($USER) }, 30 ), "container auto-started under the lingering user manager (survives reboot)" );
}

#--- CLI-specific behavior (the delegation entry point) --------------
# In uapi-driver mode the lifecycle above never touched the CLI, so prove the
# delegated CLI path here too (it must reach the adminbin + cpsrvd over
# localhost HTTPS from INSIDE the jail). In cli-driver mode the lifecycle
# already exercised it. Either way, prove a non-UAPI verb is refused — that is
# CLI-only behavior the lifecycle can't cover.
SKIP: {
    my $ntests = ( $DRIVER ne 'cli' ) ? 2 : 1;
    skip "ea-podman CLI not found", $ntests if !$CLI;

    if ( $DRIVER ne 'cli' ) {
        my ( $lrc, $lout ) = run_in_jail( $USER, _sh($CLI) . " list" );
        like( $lout, qr/\Q$container\E/, "in-jail CLI `list` (delegated to UAPI) shows $container" )
          or diag("list output: $lout");
    }

    # a verb the UAPI does not expose is refused with a clear message
    my ( $arc, $aout ) = run_in_jail( $USER, _sh($CLI) . " avail" );
    like( $aout, qr/not available for accounts with a restricted shell/i, "in-jail CLI refuses a non-UAPI verb for a restricted account" )
      or diag("avail output: $aout");
}

#--- uninstall cleans up ---------------------------------------------
{
    my $res = op( 'uninstall', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman uninstall succeeded" );
    ok( wait_for( sub { !_container_running($USER) }, 30 ), "container is gone after uninstall" );

    my $list = op('list');
    ok( !( $list->{data} && exists $list->{data}{$container} ), "uninstalled container no longer registered" );
}

done_testing();

#---------------------------------------------------------------------
# helpers
#---------------------------------------------------------------------
sub _in_path {
    my ($bin) = @_;
    for my $d ( split /:/, $ENV{PATH} || '' ) {
        return 1 if -x "$d/$bin";
    }
    my ( $rc ) = run_cmd( '/bin/sh', '-c', "command -v " . _sh($bin) );
    return $rc == 0;
}

sub _container_running {
    my ($user) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman ps --no-trunc --format '{{.Names}}'" );
    return 0 if $rc != 0;
    return scalar( grep { $_ eq $container } split /\n/, $out );
}

# #1: does redis answer PING from inside the running container?
sub _redis_ping_in_container {
    my ($user) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman exec " . _sh($container) . " redis-cli ping" );
    return ( $rc == 0 && $out =~ /\bPONG\b/ ) ? 1 : 0;
}

# The host IP:port that $PORT was published to (the port authority assigns
# the host port, so it is not necessarily $PORT). Returns () if not found.
sub _published_host_endpoint {
    my ($user) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman port " . _sh($container) . " " . _sh("$PORT/tcp") );
    return if $rc != 0;
    for my $line ( split /\n/, $out ) {    # e.g. "0.0.0.0:49153" or "[::]:49153"
        next if $line !~ m/(\S+):([0-9]+)\s*$/;
        my ( $ip, $port ) = ( $1, $2 );
        $ip = '127.0.0.1' if $ip eq '0.0.0.0' || $ip eq '::' || $ip eq '[::]';
        return ( $ip, $port );
    }
    return;
}

# #2: speak RESP to the published port — "PING\r\n" should yield "+PONG".
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

sub _sh {    # minimal single-quote shell escaping
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

    # best-effort: remove the container if it is still around
    if ( defined $container ) {
        run_cmd( $UAPI, "--user=$USER", '--output=json', 'EAPodman', 'uninstall', "container_name=$container" );
    }

    my $uid_t = ( getpwnam($USER) )[2];
    run_cmd( 'loginctl', 'disable-linger', $USER ) if defined $uid_t;
    run_cmd( 'systemctl', 'stop', "user\@$uid_t.service" ) if defined $uid_t;

    if ($CREATED_USER) {
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
    }
    elsif ( $ORIG_SHELL && $ORIG_SHELL ne $JAILSHELL ) {
        run_cmd( '/usr/sbin/usermod', '-s', $ORIG_SHELL, $USER );    # restore original shell
    }

    # clear any jailshell virtfs mounts left by the login-shell jail check
    run_cmd('/usr/local/cpanel/scripts/clear_orphaned_virtfs_mounts') if -x '/usr/local/cpanel/scripts/clear_orphaned_virtfs_mounts';
}
