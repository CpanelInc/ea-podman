#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# CPANEL-54037 — LIVE integration test for CloudLinux CageFS (NOT a
# unit test). Sister to t/LiveTests/jailshell-podman-live.t.
#
# WHAT THIS PROVES. A CageFS-enabled cPanel user can deploy and manage
# rootless ea-podman containers via UAPI. The key finding behind this
# test (verified live on CloudLinux 9.8):
#
#   CageFS is entered only at the PAM/login layer (SSH / interactive
#   shell). cpsrvd's UAPI execution runs the cpuser context OUTSIDE the
#   cage (host mount namespace), with $USER set correctly. So ea-podman
#   needs NO special cage handling: the privileged session bootstrap
#   (`loginctl enable-linger`, run as root) and the rootless podman work
#   both happen on the host filesystem, exactly as for a normal user.
#
# (Running podman INSIDE the cage is impossible — the cage is mounted
# `nosuid`, which strips newuidmap/newgidmap's file capabilities — but
# the supported UAPI path never does that.)
#
# Because the verification must not depend on the cage, every check here
# is CAGE-INDEPENDENT: UAPI verbs (same context as install) and
# root-side checks (linger, the user systemd manager, and a TCP PING to
# the published port discovered from cpuser_port_authority). It does NOT
# use `su`, which would enter the cage and see a different world.
#
# Run ON A LIVE CloudLinux cPanel VM, as root, with CageFS initialized,
# podman installed, an ea-podman build carrying the CPANEL-54037 changes,
# and a cPanel build with Cpanel::API::EAPodman:
#
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl cagefs-podman-live.t
#
# Runs on both cgroup v1 and v2 (CloudLinux defaults to v1). The serving check
# is the published host port, which is validated on CloudLinux 8/9/10.
#
# Environment variables (same as the jailshell test, except CageFS is
# toggled instead of the login shell):
#   EAPODMAN_LIVE=1      REQUIRED opt-in.
#   EAPODMAN_DRIVER      how to issue each verb: "uapi" (default; via
#                        `uapi --user`, cage-independent) or "cli" (the
#                        account's own login shell running the ea-podman
#                        CLI directly, i.e. a real CageFS login). The
#                        account created for this test has an ordinary
#                        (unrestricted) shell, so in "cli" mode this
#                        exercises CPANEL-54672: a CageFS-caged account
#                        with an unrestricted shell takes the direct CLI
#                        path, can't see its own /run/user/<uid> from
#                        inside the cage, and must transparently fall
#                        back to the UAPI bridge. Run the file once per
#                        value to cover both entry points.
#   EAPODMAN_TEST_USER   reuse an existing account (CageFS is enabled for
#                        it and its prior state restored afterward).
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
my $IMAGE  = $ENV{EAPODMAN_TEST_IMAGE} || 'docker.io/library/redis:alpine';
my $PORT   = $ENV{EAPODMAN_TEST_PORT}  || 6379;
my $KEEP   = $ENV{EAPODMAN_KEEP};
my $CBASE  = 'eapod54037';
my $DRIVER = lc( $ENV{EAPODMAN_DRIVER} || 'uapi' );    # how to issue verbs: 'uapi' (uapi --user) or 'cli' (real login + direct CLI)

my $UAPI      = '/usr/local/cpanel/bin/uapi';
my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman';
my $UAPI_MOD  = '/usr/local/cpanel/Cpanel/API/EAPodman.pm';
my $PORTAUTH  = '/usr/local/cpanel/scripts/cpuser_port_authority';
my @CLI_PATHS = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

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

sub uapi {
    my ( $user, $func, @kv ) = @_;
    my ( $rc, $decoded, $out, $err ) = run_json( $UAPI, "--user=$user", '--output=json', 'EAPodman', $func, @kv );
    die "uapi $func: could not parse JSON (exit $rc):\nSTDOUT:\n$out\nSTDERR:\n$err\n" if !$decoded;
    return $decoded->{result} // $decoded;
}

# Run a command through the account's real LOGIN shell (`su -`), i.e. exactly
# how the user would invoke it. Unlike the jailshell test's `run_in_jail`
# (which proves the jail is bypassed by not going through the shell), CageFS
# is entered at the PAM/login layer regardless of shell — so this is what
# actually puts the process inside the cage. Returns ($exit, $combined_output).
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
plan skip_all => "podman is not installed"                    if !_in_path('podman');
plan skip_all => "uapi not found ($UAPI)"                     if !-x $UAPI;
plan skip_all => "Cpanel::API::EAPodman not installed"        if !-e $UAPI_MOD;
plan skip_all => "ea-podman library not installed"            if !-e "$EAP_LIB/subids.pm";
plan skip_all => "cpuser_port_authority not found ($PORTAUTH)" if !-x $PORTAUTH;
plan skip_all => "EAPODMAN_DRIVER must be 'uapi' or 'cli' (got '$DRIVER')" if $DRIVER ne 'uapi' && $DRIVER ne 'cli';

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
plan skip_all => "EAPODMAN_DRIVER=cli but no ea-podman CLI found (@CLI_PATHS)" if $DRIVER eq 'cli' && !$CLI;

# In 'cli' mode, the installed CLI must carry the CPANEL-54672 CageFS fallback
# (otherwise this test would just reproduce the bug it's meant to guard).
if ( $DRIVER eq 'cli' ) {
    my ($CLI_PL) = grep { -e $_ } ( '/opt/cpanel/ea-podman/bin/ea-podman.pl', "$EAP_LIB/../../bin/ea-podman.pl" );
    plan skip_all => "cannot find installed ea-podman.pl to verify the CPANEL-54672 fallback is present" if !$CLI_PL;
    open my $fh, '<', $CLI_PL or plan skip_all => "cannot read $CLI_PL";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates CPANEL-54672 (no CageFS direct-CLI fallback in ea-podman.pl); rebuild/install it first"
      if $src !~ /rootless runtime directory .* does not exist/;
}

# CageFS must be initialized. `--check-cagefs-initialized` exits non-zero and
# prints "Not initialized" when it isn't (note: "Not initialized" contains
# "initialized", so key off the exit code, not a bare /initialized/ match).
{
    my ( $rc, $out ) = _cagefsctl('--check-cagefs-initialized');
    chomp $out;
    plan skip_all => "CageFS is not initialized on this box (run `cagefsctl --init && cagefsctl --enable-cagefs` first): $out"
      if $rc != 0 || $out =~ /not \s+ initialized/ix;
}

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

my $uid = ( getpwnam($USER) )[2];

# In 'cli' mode a real login (`su -`) is required, which needs the account's
# shell/ACL to actually permit shell access (a throwaway createacct account
# may default to a no-shell ACL). Force an ordinary unrestricted shell so the
# scenario under test — CageFS + unrestricted shell — is deterministic rather
# than incidental; restored afterward for a reused (not created) account.
$ORIG_SHELL = ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', '/bin/bash', $USER );

# Record prior CageFS state (to restore), then enable CageFS for the user —
# the scenario under test. CageFS is orthogonal to the login shell, and this
# isolates the cage as the variable.
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

my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';
diag("Test user: $USER (uid=$uid), CageFS=enabled, cgroup=$CGROUP, image=$IMAGE, port=$PORT, driver=$DRIVER");

# The raw combined output of the most recent _op_cli call — exposed so a test
# can assert on incidental output (e.g. the CageFS fallback warning) without
# every op() caller having to plumb it through.
our $LAST_CLI_OUTPUT;

#---------------------------------------------------------------------
# driver: issue an EAPodman verb either via UAPI (`uapi --user`, cage-
# independent) or via the account's real login running the ea-podman CLI
# directly (`cli` — a genuine CageFS login). Normalized to the UAPI envelope
# { status, data, errors } so every lifecycle assertion below is identical for
# both. Selected with EAPODMAN_DRIVER=uapi|cli.
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
    push @kv, "cpuser_port=$args{container_port}"    if defined $args{container_port};
    push @kv, "accept_arbitrary_image_risk=1"        if $args{accept_arbitrary_image_risk};
    push @kv, "container_name=$args{container_name}" if defined $args{container_name};
    push @kv, "cd=$args{cd}"                         if defined $args{cd};
    if ( defined $args{command} ) {
        push @kv, map { "arg=$_" } ( ref $args{command} eq 'ARRAY' ? @{ $args{command} } : ( $args{command} ) );
    }
    return uapi( $USER, $verb, @kv );
}

# Drive the CLI through the account's real login (run_via_login), so it
# exercises the real cage → (bootstrap succeeds, but the runtime dir is
# invisible) → fallback → adminbin/cpsrvd delegation path, then map its
# textual output back onto the UAPI envelope.
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
        my @cargs = ref $args{command} eq 'ARRAY' ? @{ $args{command} } : ( $args{command} );
        $cmd .= " -- " . join( " ", map { _sh($_) } @cargs );
    }
    elsif ( $verb eq 'uninstall' ) {
        $cmd .= " " . _sh( $args{container_name} ) . " --verify";    # skip the "are you sure" prompt
    }
    elsif ( defined $args{container_name} ) {
        $cmd .= " " . _sh( $args{container_name} );
    }

    my ( $exit, $out ) = run_via_login( $USER, $cmd );
    $LAST_CLI_OUTPUT = $out;

    if ( $verb eq 'install' ) {
        my ($name) = $out =~ /Done,\s*installed:\s*(\S+)/;
        return { status => ( $name ? 1 : 0 ), data => { container_name => $name }, errors => ( $name ? undef : [$out] ) };
    }
    if ( $verb eq 'list' ) {
        # A login shell may prepend a banner/MOTD; isolate the JSON object.
        my $jsontext = $out;
        $jsontext =~ s/\A[^{]*//s;
        $jsontext =~ s/[^}]*\z//s;
        my $data = eval { $json->($jsontext) };
        return { status => ( $data ? 1 : 0 ), data => ( $data || {} ), errors => ( $data ? undef : [$out] ) };
    }
    if ( $verb eq 'cmd' ) {
        # The CLI `cmd` verb exits with the exec'd command's own exit code and
        # prints its stdout/stderr directly (no JSON envelope).
        return { status => 1, data => { stdout => $out, exit_code => $exit }, errors => undef };
    }

    # start / stop / restart / uninstall: success is a clean exit
    return { status => ( $exit == 0 ? 1 : 0 ), data => {}, errors => ( $exit == 0 ? undef : [$out] ) };
}

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

#--- install: via UAPI directly (cage-independent), or via the account's own
#    real login running the CLI (driver=cli — a genuine CageFS login) -------
my $container;
{
    my $res = op( 'install', name => $CBASE, image => $IMAGE, container_port => $PORT, accept_arbitrary_image_risk => 1 );
    ok( $res->{status}, "[$DRIVER] EAPodman install succeeded for a CageFS user" )
      or diag( "errors: " . join( "; ", @{ $res->{errors} || [] } ) );
    $container = $res->{data} && $res->{data}{container_name};
    like( $container // '', qr/^\Q$CBASE\E\.\Q$USER\E\.[0-9][0-9]$/, "install returned a container name ($container)" );

    # The money assertion for CPANEL-54672: a real CageFS login with an
    # unrestricted shell takes the direct CLI path, can't see its own
    # /run/user/<uid> from inside the cage, and must transparently fall back
    # to the UAPI bridge rather than failing outright.
    if ( $DRIVER eq 'cli' ) {
        like(
            $LAST_CLI_OUTPUT // '',
            qr/could not see this account.s rootless runtime directory directly.*retrying through the EAPodman UAPI/s,
            "[cli] direct CLI hit the CageFS symptom and transparently fell back to the UAPI bridge"
        );
    }
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

#--- the container is registered (authoritative: same context as install)
{
    my $res = op('list');
    ok( $res->{status} && $res->{data} && exists $res->{data}{$container}, "[$DRIVER] EAPodman list shows $container" );
}

#--- the service actually serves (cage-independent) ------------------
SKIP: {
    skip "non-redis image ($IMAGE); skipping redis functional check", 1 if $IMAGE !~ /redis/i;
    ok( wait_for( sub { _redis_serving_via_port($USER) }, 45 ),
        "redis answers PING over the published host port (root-side, cage-independent)" )
      or diag( "assigned host port: " . ( _assigned_host_port($USER) // '(none found via cpuser_port_authority)' ) );
}

#--- cmd: run commands inside the container (CPANEL-54360, via nsenter) ---
# The whole reason this ticket exists: a CageFS account has no terminal and the
# container may lack bash. cmd enters the container's namespaces via the root
# adminbin (nsenter), so it works here even though /proc is hidepid=2 and
# `podman exec` would fail.
{
    my $res = op( 'cmd', container_name => $container, command => 'date' );
    ok( $res->{status}, "[$DRIVER] EAPodman cmd (date) succeeded" )
      or diag( "errors: " . join( "; ", @{ $res->{errors} || [] } ) );

    # `podman exec` is broken on older podman (4.x) + runc under cgroup v1 /
    # LVE (e.g. CloudLinux 8): "cannot exec in a stopped container" even while
    # the container runs and serves (same root cause the sister jailshell test
    # already works around for its in-container redis-cli ping check). The
    # `cmd` verb itself round-tripped correctly (status above); treat this as
    # unsupported-exec here, not a cmd-verb failure.
    skip "podman exec unsupported here (older podman/runc under cgroup v1); cmd verb round-tripped correctly", 2
      if ( $res->{data}{stderr} // '' ) =~ /cannot exec in a stopped container/;

    is( $res->{data}{exit_code}, 0, "cmd date exited 0" );
    like( $res->{data}{stdout}, qr/\d{4}/, "cmd date produced date-like stdout" );

    # Exit-code fidelity: non-zero command exit is data, not a failure.
    my $f = op( 'cmd', container_name => $container, command => 'false' );
    ok( $f->{status}, "[$DRIVER] cmd (false) is still a successful call" );
    is( $f->{data}{exit_code}, 1, "cmd (false) surfaces exit_code 1" );

    # --cd runs from the given working directory.
    my $cd = op( 'cmd', container_name => $container, cd => '/etc', command => 'pwd' );
    is( $cd->{data}{exit_code}, 0, "cmd --cd=/etc pwd exited 0" );
    like( $cd->{data}{stdout}, qr{^/etc\b}, "cmd --cd=/etc ran from /etc" );

    # Sysadmin task: write into the container OS and read it back via a later cmd.
    my $w = op( 'cmd', container_name => $container, command => [ 'touch', '/eapodman-cmd-marker' ] );
    is( $w->{data}{exit_code}, 0, "cmd touch created a file in the container" );
    my $r = op( 'cmd', container_name => $container, command => [ 'ls', '/eapodman-cmd-marker' ] );
    like( $r->{data}{stdout}, qr{/eapodman-cmd-marker}, "the written file persists and is visible to a later cmd" );
}

#--- lifecycle: stop / start / restart -------------------------------
{
    my $res = op( 'stop', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman stop succeeded" );

    $res = op( 'start', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman start succeeded" );

    $res = op( 'restart', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman restart succeeded" );

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
    my $res = op( 'uninstall', container_name => $container );
    ok( $res->{status}, "[$DRIVER] EAPodman uninstall succeeded" );

    my $list = op('list');
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

# The host port $PORT was published to, discovered ROOT-SIDE from the port
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
    else {
        run_cmd( $CAGEFSCTL, '--disable', $USER ) if defined $CAGEFS_WAS_ENABLED && !$CAGEFS_WAS_ENABLED && $CAGEFSCTL;
        run_cmd( '/usr/sbin/usermod', '-s', $ORIG_SHELL, $USER ) if $ORIG_SHELL && $ORIG_SHELL ne '/bin/bash';
    }
}
