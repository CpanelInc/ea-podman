#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# LIVE integration test (NOT a unit test). Sister to
# t/LiveTests/normal-podman-live.t, t/LiveTests/jailshell-podman-live.t,
# and t/LiveTests/cagefs-podman-live.t.
#
# WHAT THIS PROVES. A NORMAL cPanel account (unrestricted login shell, not
# under CageFS) can use the `ea-podman` CLI directly — not the UAPI, not an
# arbitrary docker image — to install a real EA4 *container-based package*:
# `ea-memcached16`. This is the `ea-podman install <PKG>` mode documented in
# README.md ("Anatomy of an EA4 container-based package"): unlike the
# arbitrary-image mode, no `--cpuser-port`/image argument is given — the
# package alone (via /opt/cpanel/<PKG>/ea-podman.json) supplies the image,
# ports, and any startup args, and ea-podman's install refuses anything that
# is neither a locally-installed package nor a valid arbitrary name+image.
#
# Because the test account has an unrestricted shell and is not CageFS-caged,
# `ea-podman install ea-memcached16` reaches the direct dispatch path in
# ea-podman.pl (not delegate_to_uapi()) — the same path root uses.
#
# ea-memcached16 is NOT part of this repo. It is a separate, already-built EA4
# container-based package that must be installed on the target VM via the
# system's package manager before this test can run (that's what
# `ea-podman install` itself would tell you if it were missing).
#
# ea-memcached16's ea-podman.json declares an EMPTY `ports` list — it does not
# publish a TCP port at all. Its `-v` startup arg mounts the container's own
# directory at /socket_dir, and its entrypoint runs memcached listening on a
# UNIX socket at /socket_dir/memcached.sock — i.e. on the host,
# <homedir>/ea-podman.d/<container_name>/memcached.sock. So "is it serving"
# here is checked over that unix socket, not a published host port (there
# isn't one; `cpuser_port_authority` is never even called for a package whose
# ports list is empty — see ea_podman::util::_get_new_ports).
#
# Run ON A LIVE cPanel VM, as root, with podman and ea-memcached16 installed,
# and an ea-podman build carrying the CPANEL-54037 changes:
#
#   yum install -y ea-podman ea-memcached16      # or apt-get on a deb host
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea-memcached16-cli-live.t
#
# cgroup: like its sister tests, this runs on both cgroup v1 and v2.
#
# Environment variables:
#   EAPODMAN_LIVE=1      REQUIRED opt-in.
#   EAPODMAN_TEST_USER   reuse an existing account (its shell is set to an
#                        unrestricted shell for the test and restored
#                        afterward) instead of creating a throwaway one.
#   EAPODMAN_TEST_PKG    EA4 container-based package to install (default:
#                        ea-memcached16). Must already be installed locally.
#                        NOTE: the serving check is specific to
#                        ea-memcached16's unix-socket convention (see below);
#                        only override this with another package that serves
#                        the same way.
#   EAPODMAN_KEEP=1      skip teardown.
#######################################################################

use strict;
use warnings;

use Test::More;

use IPC::Open3       ();
use Symbol           ();
use IO::Socket::UNIX ();
use IO::Select       ();
use Socket qw(SOCK_STREAM);

#---------------------------------------------------------------------
# config
#---------------------------------------------------------------------
my $PKG  = $ENV{EAPODMAN_TEST_PKG} || 'ea-memcached16';
my $KEEP = $ENV{EAPODMAN_KEEP};
my $BASH = '/bin/bash';    # an unrestricted login shell

my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman';
my @CLI_PATHS = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

my $PKG_DIR = "/opt/cpanel/$PKG";

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

sub wait_for {
    my ( $predicate, $timeout ) = @_;
    $timeout //= 10;
    for ( 1 .. $timeout * 10 ) {
        return 1 if $predicate->();
        select( undef, undef, undef, 0.1 );
    }
    return $predicate->();
}

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
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

plan skip_all => "podman is not installed"         if !_in_path('podman');
plan skip_all => "ea-podman library not installed" if !-e "$EAP_LIB/subids.pm";

# ea-podman must carry the CPANEL-54037 fix.
{
    open my $fh, '<', "$EAP_LIB/subids.pm" or plan skip_all => "cannot read $EAP_LIB/subids.pm";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates CPANEL-54037 (no enable-linger / ensure_user_session in subids.pm); rebuild/install it first"
      if $src !~ /enable[-_ ]?linger/ && $src !~ /ensure_user_session/;
}

my ($CLI) = grep { -x $_ } @CLI_PATHS;
plan skip_all => "ea-podman CLI not found (checked: @CLI_PATHS)" if !$CLI;

plan skip_all => "“$PKG” is not installed locally ($PKG_DIR/ea-podman.json and pkg-version not found); "
  . "install it via the system package manager first (e.g. `yum install $PKG` / `apt-get install $PKG`), "
  . "or set EAPODMAN_TEST_PKG to an EA4 container-based package that is installed"
  if !-f "$PKG_DIR/ea-podman.json" || !-f "$PKG_DIR/pkg-version";

my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';

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
    $USER = 'eapm' . substr( time, -5 );
    my $domain = "$USER.eapodmanpkg.test";
    my $pw     = 'Eap0d' . substr( time, -6 ) . '!Xy';

    diag("Creating throwaway cPanel account '$USER' ($domain) …");
    my ( $rc, $res, $out, $err ) = run_json( $WHMAPI, 'createacct', "username=$USER", "domain=$domain", "password=$pw", '--output=json' );
    if ( !$res || !$res->{metadata} || !$res->{metadata}{result} ) {
        plan skip_all => "could not create test account '$USER' (set EAPODMAN_TEST_USER to reuse one):\nSTDOUT:\n$out\nSTDERR:\n$err";
    }
    $CREATED_USER = 1;
}

# Give the account an UNRESTRICTED shell and confirm it's not CageFS-caged —
# the scenario under test is a NORMAL account driving the CLI directly.
$ORIG_SHELL //= ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', $BASH, $USER );
my $uid = ( getpwnam($USER) )[2];

# Clean baseline: no linger, no runtime dir.
run_cmd( 'loginctl', 'disable-linger', $USER );
run_cmd( 'systemctl', 'stop', "user\@$uid.service" );
wait_for( sub { !-e "/run/user/$uid" }, 5 );

diag("Test user: $USER (uid=$uid), shell=" . ( ( getpwnam($USER) )[8] ) . ", cgroup=$CGROUP, package=$PKG");

#=====================================================================
# the tests
#=====================================================================

is( ( getpwnam($USER) )[8], $BASH, "test account login shell is unrestricted ($BASH)" );

ok( !-e "/run/user/$uid", "baseline: no /run/user/$uid before install" );
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    unlike( $out, qr/Linger=yes/, "baseline: linger not enabled before install" );
}

#--- the package is discoverable via the CLI's `avail` verb ----------
SKIP: {
    my ( $rc, $decoded, $out, $err ) = run_json( $CLI, 'avail' );
    skip "ea-podman avail did not return usable JSON (needs /etc/cpanel/ea4/ea4-metainfo.json): $err", 1 if !$decoded;
    ok( exists $decoded->{$PKG} && $decoded->{$PKG}{installed_locally}, "ea-podman avail reports “$PKG” as installed locally" );
}

#--- install via the DIRECT CLI (not UAPI) ----------------------------
# `install <PKG>` — an EA4 container-based package needs no image/port args;
# everything comes from $PKG_DIR/ea-podman.json.
my $container;
{
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " install " . _sh($PKG) );
    is( $rc, 0, "ea-podman install $PKG exited 0" ) or diag("output:\n$out");
    ($container) = $out =~ /Done, installed:\s*(\S+)/;
    like( $container // '', qr/^\Q$PKG\E\.\Q$USER\E\.[0-9][0-9]$/, "install returned a container name ($container)" );
}

BAIL_OUT("install did not return a container name; cannot continue") if !$container;

#--- the session was bootstrapped as root (root-side), via init_user() ---
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    like( $out, qr/Linger=yes/, "linger is now enabled for $USER (survives logout/reboot)" );
}
ok( -S "/run/user/$uid/bus", "user dbus socket /run/user/$uid/bus exists" );
{
    my ( $rc, $out ) = run_cmd( 'systemctl', 'is-active', "user\@$uid.service" );
    like( $out, qr/\bactive\b/, "user\@$uid.service (user systemd manager) is active" );
}

#--- the container is registered (via the CLI, not UAPI) --------------
{
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " list" );
    my $decoded = eval { $json->($out) };
    ok( $decoded && exists $decoded->{$container}, "ea-podman list (CLI) shows $container" ) or diag("output:\n$out");
}

#--- the container actually runs and serves ---------------------------
my $unit = "container-$container.service";
ok( _container_running($USER), "podman shows $container running" );
{
    my ( $rc, $out ) = run_as_user( $USER, "systemctl --user is-enabled " . _sh($unit) );
    like( $out, qr/\benabled\b/, "systemd --user unit $unit is enabled" );
}
ok( wait_for( sub { _memcached_serving_via_socket($USER) }, 45 ), "memcached answers `version` over its unix socket (root-side)" )
  or do {
    my $sock_path = _memcached_socket_path($USER);
    diag( "expected socket: $sock_path" . ( -S $sock_path ? " (exists)" : " (missing)" ) );
  };

#--- lifecycle: stop / start / restart, all via the direct CLI --------
{
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " stop " . _sh($container) );
    is( $rc, 0, "ea-podman stop (CLI) exited 0" ) or diag($out);

    ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " start " . _sh($container) );
    is( $rc, 0, "ea-podman start (CLI) exited 0" ) or diag($out);

    ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " restart " . _sh($container) );
    is( $rc, 0, "ea-podman restart (CLI) exited 0" ) or diag($out);

    ok( wait_for( sub { _memcached_serving_via_socket($USER) }, 45 ), "memcached is serving again over its unix socket after restart" );
}

#--- persistence proxy: restart the user manager (simulates reboot) --
{
    run_cmd( 'systemctl', 'restart', "user\@$uid.service" );
    ok( wait_for( sub { -S "/run/user/$uid/bus" }, 15 ), "user manager came back after restart (linger)" );
    ok( wait_for( sub { _memcached_serving_via_socket($USER) }, 60 ), "memcached auto-started and serves after the user manager restart (survives reboot)" );
}

#--- uninstall via the direct CLI cleans up ---------------------------
{
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($container) . " --verify" );
    is( $rc, 0, "ea-podman uninstall --verify (CLI) exited 0" ) or diag($out);

    ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " list" );
    my $decoded = eval { $json->($out) };
    ok( !( $decoded && exists $decoded->{$container} ), "uninstalled container no longer registered" );
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

# ea-memcached16 mounts its own container directory at /socket_dir and runs
# memcached listening on /socket_dir/memcached.sock — i.e., on the host,
# <homedir>/ea-podman.d/<container_name>/memcached.sock. No TCP port is ever
# published (its ea-podman.json declares an empty `ports` list).
sub _memcached_socket_path {
    my ($user) = @_;
    my $homedir = ( getpwnam($user) )[7];
    return "$homedir/ea-podman.d/$container/memcached.sock";
}

sub _memcached_serving_via_socket {
    my ($user) = @_;
    my $path = _memcached_socket_path($user);
    return 0 if !-S $path;
    return _memcached_version_over_unix($path);
}

sub _memcached_version_over_unix {
    my ($path) = @_;
    my $sock = IO::Socket::UNIX->new( Peer => $path, Type => SOCK_STREAM, Timeout => 5 ) or return 0;
    syswrite( $sock, "version\r\n" );
    my $reply = '';
    my $sel   = IO::Select->new($sock);
    sysread( $sock, $reply, 128 ) if $sel->can_read(5);
    close $sock;
    return $reply =~ /^VERSION\b/ ? 1 : 0;
}

#---------------------------------------------------------------------
# teardown
#---------------------------------------------------------------------
END {
    return if $KEEP;
    return if !$USER;

    if ( defined $container ) {
        run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($container) . " --verify" ) if $CLI;
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
