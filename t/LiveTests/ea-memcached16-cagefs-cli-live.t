#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# LIVE integration test for CloudLinux CageFS (NOT a unit test). Sister to
# t/LiveTests/ea-memcached16-cli-live.t (the "normal account" variant) and
# t/LiveTests/cagefs-podman-live.t.
#
# WHAT THIS PROVES. A CageFS-enabled cPanel account — even one with an
# unrestricted login shell — can still use the `ea-podman` CLI directly to
# install a real EA4 container-based package, `ea-memcached16`. CageFS is
# entered at the PAM/login layer, so a real login running the direct CLI
# cannot see its own /run/user/<uid> (rootless podman's runtime dir) from
# inside the cage. Per CPANEL-54672, ea-podman.pl catches that exact symptom
# and transparently falls back to the same EAPodman UAPI bridge jailshell
# accounts use — so `ea-podman install ea-memcached16` still works from a
# real CageFS login, it just takes one extra hop under the hood.
#
# Everything else here mirrors t/LiveTests/ea-memcached16-cli-live.t: same
# package, same lifecycle, same functional (memcached protocol) check. The
# differences:
#   - the account is CageFS-enabled (CloudLinux only);
#   - the CLI is driven through a REAL login (`su -`), which is what
#     actually enters the cage (see cagefs-podman-live.t); a non-login
#     `su -s` does NOT enter the cage, so that's used (as in the jailshell
#     test) for the "is it actually running" checks, to verify server-side
#     state without depending on the cage at all.
#
# Run ON A LIVE CloudLinux cPanel VM, as root, with CageFS initialized,
# podman and ea-memcached16 installed, and an ea-podman build carrying the
# CPANEL-54037 and CPANEL-54672 changes:
#
#   yum install -y ea-podman ea-memcached16 cagefs
#   cagefsctl --init && cagefsctl --enable-cagefs
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea-memcached16-cagefs-cli-live.t
#
# Environment variables:
#   EAPODMAN_LIVE=1      REQUIRED opt-in.
#   EAPODMAN_TEST_USER   reuse an existing account (CageFS is enabled for it,
#                        and its prior CageFS/shell state restored afterward)
#                        instead of creating a throwaway one.
#   EAPODMAN_TEST_PKG    EA4 container-based package to install (default:
#                        ea-memcached16). Must already be installed locally.
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
my $PKG  = $ENV{EAPODMAN_TEST_PKG} || 'ea-memcached16';
my $KEEP = $ENV{EAPODMAN_KEEP};
my $BASH = '/bin/bash';    # an unrestricted login shell

my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman';
my $PORTAUTH  = '/usr/local/cpanel/scripts/cpuser_port_authority';
my @CLI_PATHS = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

my $PKG_DIR = "/opt/cpanel/$PKG";

my ($CAGEFSCTL) = grep { -x $_ } ( '/usr/sbin/cagefsctl', '/sbin/cagefsctl', '/usr/bin/cagefsctl' );

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

# Run a command AS $user WITHOUT their login shell (bypasses CageFS, which is
# entered only at the PAM/login layer), with the rootless podman environment
# primed. Used for the cage-independent "is it actually running" checks.
# Returns ($exit, $output).
sub run_as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "$env $cmd" );
}

# Run a command through the account's REAL login (`su -`), i.e. exactly how
# the user would invoke it. This is what actually enters the CageFS cage.
# Returns ($exit, $combined_output).
sub run_via_login {
    my ( $user, $cmd ) = @_;
    return run_cmd( 'su', '-', $user, '-c', $cmd );
}

sub _cagefsctl { return run_cmd( $CAGEFSCTL, @_ ); }

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

# CageFS is CloudLinux-only: require the OS first, then the CageFS tooling.
plan skip_all => "not CloudLinux (CageFS is a CloudLinux feature)" if !_is_cloudlinux();
plan skip_all => "CageFS is not installed (cagefsctl not found)"   if !$CAGEFSCTL;
plan skip_all => "podman is not installed"                     if !_in_path('podman');
plan skip_all => "cpuser_port_authority not found ($PORTAUTH)" if !-x $PORTAUTH;
plan skip_all => "ea-podman library not installed"             if !-e "$EAP_LIB/subids.pm";

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

# The installed CLI must carry the CPANEL-54672 CageFS fallback (otherwise
# this test would just reproduce the bug it's meant to guard).
{
    my ($CLI_PL) = grep { -e $_ } ( '/opt/cpanel/ea-podman/bin/ea-podman.pl', "$EAP_LIB/../../bin/ea-podman.pl" );
    plan skip_all => "cannot find installed ea-podman.pl to verify the CPANEL-54672 fallback is present" if !$CLI_PL;
    open my $fh, '<', $CLI_PL or plan skip_all => "cannot read $CLI_PL";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates CPANEL-54672 (no CageFS direct-CLI fallback in ea-podman.pl); rebuild/install it first"
      if $src !~ /rootless runtime directory .* does not exist/;
}

plan skip_all => "“$PKG” is not installed locally ($PKG_DIR/ea-podman.json and pkg-version not found); "
  . "install it via the system package manager first (e.g. `yum install $PKG` / `apt-get install $PKG`), "
  . "or set EAPODMAN_TEST_PKG to an EA4 container-based package that is installed"
  if !-f "$PKG_DIR/ea-podman.json" || !-f "$PKG_DIR/pkg-version";

# CageFS must be initialized. `--check-cagefs-initialized` exits non-zero and
# prints "Not initialized" when it isn't (note: "Not initialized" contains
# "initialized", so key off the exit code, not a bare /initialized/ match).
{
    my ( $rc, $out ) = _cagefsctl('--check-cagefs-initialized');
    chomp $out;
    plan skip_all => "CageFS is not initialized on this box (run `cagefsctl --init && cagefsctl --enable-cagefs` first): $out"
      if $rc != 0 || $out =~ /not \s+ initialized/ix;
}

my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';

#---------------------------------------------------------------------
# test account
#---------------------------------------------------------------------
our $USER;
our $CREATED_USER = 0;
our $CAGEFS_WAS_ENABLED;
our $ORIG_SHELL;

if ( $ENV{EAPODMAN_TEST_USER} ) {
    $USER = $ENV{EAPODMAN_TEST_USER};
    plan skip_all => "EAPODMAN_TEST_USER '$USER' is not a system user" if !defined getpwnam($USER);
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

my $uid = ( getpwnam($USER) )[2];

# A real login (`su -`) is required to genuinely enter the cage, which needs
# the account's shell/ACL to actually permit shell access (a throwaway
# createacct account may default to a no-shell ACL). Force an ordinary
# unrestricted shell so the scenario under test — CageFS + unrestricted shell
# — is deterministic rather than incidental; restored afterward for a reused
# (not created) account.
$ORIG_SHELL = ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', $BASH, $USER );

# Record prior CageFS state (to restore), then enable CageFS for the user —
# the scenario under test.
{
    my ( $src, $sout ) = _cagefsctl( '--user-status', $USER );
    $CAGEFS_WAS_ENABLED = ( $sout =~ /enabled/i && $sout !~ /disabled/i ) ? 1 : 0;
    my ( $erc, $eout ) = _cagefsctl( '--enable', $USER );
    diag("CageFS enable $USER: $eout");
}

# Clean baseline: no linger, no runtime dir.
run_cmd( 'loginctl', 'disable-linger', $USER );
run_cmd( 'systemctl', 'stop', "user\@$uid.service" );
wait_for( sub { !-e "/run/user/$uid" }, 5 );

diag("Test user: $USER (uid=$uid), CageFS=enabled, cgroup=$CGROUP, package=$PKG");

#=====================================================================
# the tests
#=====================================================================

{
    my ( $rc, $out ) = _cagefsctl( '--user-status', $USER );
    like( $out, qr/enabled/i, "CageFS is enabled for $USER" );
}

ok( !-e "/run/user/$uid", "baseline: no /run/user/$uid before install" );
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    unlike( $out, qr/Linger=yes/, "baseline: linger not enabled before install" );
}

#--- the package is discoverable via the CLI's `avail` verb (root, no cage) --
SKIP: {
    my ( $rc, $decoded, $out, $err ) = run_json( $CLI, 'avail' );
    skip "ea-podman avail did not return usable JSON (needs /etc/cpanel/ea4/ea4-metainfo.json): $err", 1 if !$decoded;
    ok( exists $decoded->{$PKG} && $decoded->{$PKG}{installed_locally}, "ea-podman avail reports “$PKG” as installed locally" );
}

#--- install: via a REAL CageFS login running the direct CLI ---------
# `install <PKG>` — an EA4 container-based package needs no image/port args;
# everything comes from $PKG_DIR/ea-podman.json.
my $container;
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " install " . _sh($PKG) );
    ($container) = $out =~ /Done,\s*installed:\s*(\S+)/;
    like( $container // '', qr/^\Q$PKG\E\.\Q$USER\E\.[0-9][0-9]$/, "install (via CageFS login) returned a container name ($container)" )
      or diag("output:\n$out");

    # The money assertion for CPANEL-54672: a real CageFS login with an
    # unrestricted shell takes the direct CLI path, can't see its own
    # /run/user/<uid> from inside the cage, and must transparently fall back
    # to the UAPI bridge rather than failing outright.
    like(
        $out,
        qr/could not see this account.s rootless runtime directory directly.*retrying through the EAPodman UAPI/s,
        "direct CLI hit the CageFS symptom and transparently fell back to the UAPI bridge"
    );
}

BAIL_OUT("install did not return a container name; cannot continue") if !$container;

#--- the session was bootstrapped as root (cage-independent) ---------
{
    my ( $rc, $out ) = run_cmd( 'loginctl', 'show-user', $USER, '-p', 'Linger' );
    like( $out, qr/Linger=yes/, "linger is now enabled for $USER (survives logout/reboot)" );
}
ok( -S "/run/user/$uid/bus", "user dbus socket /run/user/$uid/bus exists" );
{
    my ( $rc, $out ) = run_cmd( 'systemctl', 'is-active', "user\@$uid.service" );
    like( $out, qr/\bactive\b/, "user\@$uid.service (user systemd manager) is active" );
}

#--- the container is registered (via the CLI, through the cage login) ---
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " list" );

    # A real login may prepend a banner/MOTD; isolate the JSON object.
    my $jsontext = $out;
    $jsontext =~ s/\A[^{]*//s;
    $jsontext =~ s/[^}]*\z//s;
    my $decoded = eval { $json->($jsontext) };
    ok( $decoded && exists $decoded->{$container}, "ea-podman list (CLI, via CageFS login) shows $container" ) or diag("output:\n$out");
}

#--- the container actually runs and serves (cage-independent checks) ---
my $unit = "container-$container.service";
ok( _container_running($USER), "podman shows $container running (no login session)" );
{
    my ( $rc, $out ) = run_as_user( $USER, "systemctl --user is-enabled " . _sh($unit) );
    like( $out, qr/\benabled\b/, "systemd --user unit $unit is enabled" );
}
ok( wait_for( sub { _memcached_serving_via_port($USER) }, 45 ), "memcached answers `version` over the published host port (root-side)" )
  or diag( "assigned host port: " . ( _assigned_host_port($USER) // '(none found via cpuser_port_authority)' ) );

#--- lifecycle: stop / start / restart, all via the CageFS login CLI --
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " stop " . _sh($container) );
    is( $rc, 0, "ea-podman stop (CLI, via CageFS login) exited 0" ) or diag($out);

    ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " start " . _sh($container) );
    is( $rc, 0, "ea-podman start (CLI, via CageFS login) exited 0" ) or diag($out);

    ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " restart " . _sh($container) );
    is( $rc, 0, "ea-podman restart (CLI, via CageFS login) exited 0" ) or diag($out);

    ok( wait_for( sub { _memcached_serving_via_port($USER) }, 45 ), "memcached is serving again over the published port after restart" );
}

#--- persistence proxy: restart the user manager (simulates reboot) --
{
    run_cmd( 'systemctl', 'restart', "user\@$uid.service" );
    ok( wait_for( sub { -S "/run/user/$uid/bus" }, 15 ), "user manager came back after restart (linger)" );
    ok( wait_for( sub { _memcached_serving_via_port($USER) }, 60 ), "memcached auto-started and serves after the user manager restart (survives reboot)" );
}

#--- uninstall via the CageFS login CLI cleans up ---------------------
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " uninstall " . _sh($container) . " --verify" );
    is( $rc, 0, "ea-podman uninstall --verify (CLI, via CageFS login) exited 0" ) or diag($out);

    ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " list" );
    my $jsontext = $out;
    $jsontext =~ s/\A[^{]*//s;
    $jsontext =~ s/[^}]*\z//s;
    my $decoded = eval { $json->($jsontext) };
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

# True only on CloudLinux (CageFS is a CloudLinux feature).
sub _is_cloudlinux {
    return 1 if -e '/etc/cloudlinux-release';
    for my $f ( '/etc/redhat-release', '/etc/os-release' ) {
        next if !-r $f;
        open my $fh, '<', $f or next;
        local $/;
        my $c = <$fh> // '';
        close $fh;
        return 1 if $c =~ /cloudlinux/i;
    }
    return 0;
}

sub _container_running {
    my ($user) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman ps --no-trunc --format '{{.Names}}'" );
    return 0 if $rc != 0;
    return scalar( grep { $_ eq $container } split /\n/, $out );
}

# The host port memcached was published to, discovered ROOT-SIDE from the port
# authority (cage-independent). Returns the port or undef.
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

sub _memcached_serving_via_port {
    my ($user) = @_;
    my $port = _assigned_host_port($user) or return 0;
    return _memcached_version_over_tcp( '127.0.0.1', $port );
}

sub _memcached_version_over_tcp {
    my ( $ip, $port ) = @_;
    my $sock = IO::Socket::INET->new( PeerHost => $ip, PeerPort => $port, Proto => 'tcp', Timeout => 5 ) or return 0;
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

    if ( defined $container && $CLI ) {
        run_via_login( $USER, _sh($CLI) . " uninstall " . _sh($container) . " --verify" );
    }

    my $uid_t = ( getpwnam($USER) )[2];
    run_cmd( 'loginctl', 'disable-linger', $USER )         if defined $uid_t;
    run_cmd( 'systemctl', 'stop', "user\@$uid_t.service" ) if defined $uid_t;

    if ($CREATED_USER) {
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
    }
    else {
        run_cmd( $CAGEFSCTL, '--disable', $USER ) if defined $CAGEFS_WAS_ENABLED && !$CAGEFS_WAS_ENABLED && $CAGEFSCTL;
        run_cmd( '/usr/sbin/usermod', '-s', $ORIG_SHELL, $USER ) if $ORIG_SHELL && $ORIG_SHELL ne $BASH;
    }
}
