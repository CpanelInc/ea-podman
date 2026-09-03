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
#     actually enters the cage (see cagefs-podman-live.t);
#   - unlike the normal-account test, there is no non-login-`su`-based
#     "is it actually running" check. CageFS is a PAM session hook, not a
#     login-shell substitution like jailshell — it applies to ANY `su` into
#     the account, login or not (confirmed live: a non-login `su -s
#     /bin/bash` session here still got a caged view of the filesystem, one
#     lacking `systemctl` entirely). So the "is it actually running" proof
#     here is entirely root-side/cage-independent: linger, the dbus socket,
#     `user@<uid>.service`, and a unix-socket check (see below) — exactly as
#     cagefs-podman-live.t already does with its TCP-port check.
#
# ea-memcached16's ea-podman.json declares an EMPTY `ports` list — it does not
# publish a TCP port at all. Its `-v` startup arg mounts the container's own
# directory at /socket_dir, and its entrypoint runs memcached listening on a
# UNIX socket at /socket_dir/memcached.sock — i.e. on the host,
# <homedir>/ea-podman.d/<container_name>/memcached.sock. So "is it serving"
# here is checked over that unix socket (a plain root-side filesystem path,
# unaffected by the cage either way), not a published host port (there isn't
# one; `cpuser_port_authority` is never even called for a package whose ports
# list is empty — see ea_podman::util::_get_new_ports).
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
use Data::Dumper     ();
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

# run_cmd()/run_via_login() return combined stdout+stderr (needed for diag on
# failure), and a real login may prepend a banner/MOTD besides — either can
# leave non-JSON text before or after the object `ea-podman list` prints on
# stdout (a login banner before it, or a podman stderr warning after it),
# breaking a strict decode. Isolate the outermost {...} object first.
sub _decode_json_loose {
    my ($text) = @_;
    my $jsontext = $text;
    $jsontext =~ s/\A[^{]*//s;
    $jsontext =~ s/[^}]*\z//s;
    return eval { $json->($jsontext) };
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
plan skip_all => "podman is not installed"         if !_in_path('podman');
plan skip_all => "ea-podman library not installed" if !-e "$EAP_LIB/subids.pm";

# ea-podman must carry the CPANEL-54037 fix.
our $HAS_LINGER_FIX;
our $BOOT_UNIT = 'ea-podman-user-managers.service';
our ( $HAS_BOOT_UNIT, $HAS_SWEEP_VERB );
{
    open my $fh, '<', "$EAP_LIB/subids.pm" or plan skip_all => "cannot read $EAP_LIB/subids.pm";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates CPANEL-54037 (no enable-linger / ensure_user_session in subids.pm); rebuild/install it first"
      if $src !~ /enable[-_ ]?linger/ && $src !~ /ensure_user_session/;

    # Withholding the linger from an account with no containers, and giving back
    # one ea-podman granted, came later. Only those assertions are gated on it.
    $HAS_LINGER_FIX = $src =~ /granted_linger/ ? 1 : 0;
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

    # EA4-319: the boot-time sweep that starts the per-user systemd managers
    # logind cannot start while `user@.service` is masked. Newer than the fixes
    # gated above, and its two halves can be missing independently — the verb
    # lives in the CLI, the unit is a packaged systemd file — so each is gated on
    # its own rather than skip_all'd: on a host with no mask the rest of this
    # test does not care either way.
    $HAS_SWEEP_VERB = $src =~ /ensure_user_sessions/ ? 1 : 0;

    my ($rc) = run_cmd( 'systemctl', 'cat', $BOOT_UNIT );
    $HAS_BOOT_UNIT = $rc == 0 ? 1 : 0;
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

# EA4-319: cagefs 7.6.39+ masks the user@.service template (CloudLinux
# CLOS-4517), so no per-user systemd manager can start. Recorded before install
# so the after-check can prove the mask went back *identically* — a bypass that
# quietly relocated or dropped it would be a regression in CloudLinux's security
# fix, not a fix for ours.
my $MASK_BEFORE = _user_manager_mask_file();
diag( "user\@.service mask before install: " . ( $MASK_BEFORE // "(not masked)" ) );

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

# CPANEL-55309: merely running a verb must not linger an account that has no
# containers. Doing so for every account a backup touched is what put hundreds
# of idle user systemd managers on a server.
SKIP: {
    skip "installed ea-podman predates CPANEL-55309", 1 if !$HAS_LINGER_FIX;
    run_via_login( $USER, _sh($CLI) . " list" );
    ok( !-e "/var/lib/systemd/linger/$USER", "an account with no containers is not lingered by running a verb" );
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

# EA4-319: the manager above had to be started through a masked template, so the
# mask was lifted to do it. The remask-survival check is the property the whole
# approach rests on: masking does not stop an already-running instance.
{
    my $after = _user_manager_mask_file();

    if ($MASK_BEFORE) {
        is( $after, $MASK_BEFORE, "the user\@.service mask is back in the same location after the deploy (no /etc <-> /run relocation)" );

        my ( $rc, $out ) = run_cmd( 'systemctl', 'is-active', "user\@$uid.service" );
        like( $out, qr/\bactive\b/, "and the manager started inside the window survives the remask" );
    }
    else {
        is( $after, undef, "nothing was masked before the deploy, and nothing is masked after it" );
    }

    ok( !-e "/opt/cpanel/ea-podman/user-manager-mask.state", "no in-progress unmask record is left behind" );
}

# EA4-319: the window above repairs an account mid-command, which is no help at
# boot — nothing runs ea-podman then, so on a masked host a rebooted account
# keeps no manager until somebody happens to. The sweep is what closes that, and
# this is it being deployed at all. It is exercised for real further down, once
# there is a manager to lose.
SKIP: {
    skip "installed ea-podman predates EA4-319 (no $BOOT_UNIT)", 2 if !$HAS_BOOT_UNIT;

    my ( $rc, $out ) = run_cmd( 'systemctl', 'is-enabled', $BOOT_UNIT );
    like( $out, qr/\benabled\b/, "$BOOT_UNIT is enabled, so it runs at boot" ) or diag($out);

    # What it runs, not just that it is wired up: a unit whose ExecStart names a
    # verb the installed CLI does not have would fail every boot, quietly.
    ( $rc, $out ) = run_cmd( 'systemctl', 'cat', $BOOT_UNIT );
    like( $out, qr/^ExecStart=.*\bensure_user_sessions\b/m, "…and its ExecStart runs the sweep verb" ) or diag($out);
}

# The verb by hand, against an account whose manager is already up. It has to
# find the account (which it can only do from the container registry), cost
# nothing, and — the part that matters on a CageFS host — not open a mask window
# it does not need. Reporting `ok` rather than `started` is that last one: the
# window is only ever opened for accounts it reports as `started`/`failed`.
#
# It sweeps every account in the registry, not just this one, so on a box with
# other containerised accounts whose managers are down it will start those too.
# That is the verb doing its job, and this is a throwaway VM either way.
SKIP: {
    skip "installed ea-podman predates EA4-319 (no ensure_user_sessions verb)", 3 if !$HAS_SWEEP_VERB;

    my ( $rc, $out ) = run_cmd( $CLI, 'ensure_user_sessions' );
    is( $rc, 0, "`ea-podman ensure_user_sessions` exits 0 on a healthy host" ) or diag($out);
    like( $out, qr/^\Q$USER\E:\s+ok\b/m, "…reports $USER as already ok, so it opened no window for it" ) or diag($out);
    ok( !-e "/opt/cpanel/ea-podman/user-manager-mask.state", "…and left no in-progress unmask record behind" );
}

# EA4-319: `cagefsctl --hook-install` re-applies the mask on every cagefs install
# and upgrade, so what we did must not fight with that.
SKIP: {
    skip "no user\@.service mask on this host", 2 if !$MASK_BEFORE;

    _cagefsctl('--hook-install');

    ok( _user_manager_mask_file(), "the mask is in place after `cagefsctl --hook-install` re-applies it" );

    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " list" );
    is( $rc, 0, "an already-bootstrapped account still works after a cagefs hook re-install" ) or diag($out);
}

#--- the container is registered (via the CLI, through the cage login) ---
# NOTE: unlike the normal-account sister test, this does NOT also check
# `podman ps`/`systemctl --user is-enabled` through a non-login `su -s`.
# CageFS is a PAM session hook (see cagefsctl/pam_cagefs), not a login-shell
# substitution like jailshell — it applies to ANY `su` into the account,
# login or not (confirmed live: a non-login `su -s /bin/bash` session here
# got a cage view of the filesystem that lacks `systemctl` entirely). So
# there is no `su`-based way to observe this account "from outside the
# cage"; only root-side/cage-independent checks (below) and the CLI's own
# JSON output are trustworthy here. This mirrors cagefs-podman-live.t, which
# for the same reason never runs a `podman ps`/`systemctl --user` check.
my $list_data;
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " list" );
    my $decoded = _decode_json_loose($out);
    ok( $decoded && exists $decoded->{$container}, "ea-podman list (CLI, via CageFS login) shows $container" ) or diag("output:\n$out");
    $list_data = $decoded;
}

#--- the container actually serves (cage-independent: root-side socket path only) ---
ok( wait_for( sub { _memcached_serving_via_socket($USER) }, 45 ), "memcached answers `version` over its unix socket (root-side)" )
  or do {
    my $sock_path = _memcached_socket_path($USER);
    diag(
        "expected socket: $sock_path" . ( -S $sock_path ? " (exists)" : " (missing)" ) . "\n"
          . "`ea-podman list` entry for $container: "
          . ( $list_data && $list_data->{$container} ? Data::Dumper::Dumper( $list_data->{$container} ) : '(unavailable)' )
    );
  };

#--- lifecycle: stop / start / restart, all via the CageFS login CLI --
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " stop " . _sh($container) );
    is( $rc, 0, "ea-podman stop (CLI, via CageFS login) exited 0" ) or diag($out);

    ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " start " . _sh($container) );
    is( $rc, 0, "ea-podman start (CLI, via CageFS login) exited 0" ) or diag($out);

    ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " restart " . _sh($container) );
    is( $rc, 0, "ea-podman restart (CLI, via CageFS login) exited 0" ) or diag($out);

    ok( wait_for( sub { _memcached_serving_via_socket($USER) }, 45 ), "memcached is serving again over its unix socket after restart" );
}

#--- persistence proxy: bring the manager back the way boot does -----
#
# EA4-319: this used to be a single `systemctl restart user@<uid>.service`. By
# now the template is masked again — `cagefsctl --hook-install` above put it
# back — and systemd refuses the start half of that restart while leaving the
# running manager alone, since masking refuses new starts but does not stop a
# running instance (ea4-319-mask-poc.sh stage 4). The bus socket therefore never
# went away and the checks below passed having restarted nothing at all.
#
# So take the manager down for real first, then bring it back through whatever
# is actually supposed to do that at boot: the sweep where the template is
# masked and logind cannot, logind's own path where it can.
{
    my $masked_now = _user_manager_mask_file();

    # `systemctl is-active`, not the bus socket: /run/user/<uid>/bus outlives the
    # manager that was listening on it, which is why the sweep itself asks
    # systemd rather than trusting the socket (subids.pm, $user_manager_is_active).
    my $manager_active = sub { return ( run_cmd( 'systemctl', 'is-active', "user\@$uid.service" ) )[1] =~ /\bactive\b/ ? 1 : 0 };

    # Stop, not restart: a stop job is allowed on a masked unit, a start job is
    # not, which is the whole reason the old `restart` here was a no-op.
    run_cmd( 'systemctl', 'stop', "user\@$uid.service" );
    ok( wait_for( sub { !$manager_active->() }, 15 ), "the user manager can be stopped (the state a reboot leaves behind on a masked host)" )
      or diag( "still up: " . ( run_cmd( 'systemctl', 'is-active', "user\@$uid.service" ) )[1] );

    my $came_back = 0;

    if ($masked_now) {
      SKIP: {
            skip "installed ea-podman predates EA4-319 (no $BOOT_UNIT); nothing brings this account back at boot", 4 if !$HAS_BOOT_UNIT;

            # Starting the unit, not calling the verb: the unit is what fires at
            # boot, so a unit that cannot run its own ExecStart is the whole bug.
            my ( $rc, $out ) = run_cmd( 'systemctl', 'start', $BOOT_UNIT );
            is( $rc, 0, "the boot-time sweep runs clean with the template masked" ) or diag($out);

            $came_back = wait_for( sub { $manager_active->() && -S "/run/user/$uid/bus" }, 30 );
            ok( $came_back, "…and the account's user manager is back, which on a masked host nothing else would have done" )
              or diag( ( run_cmd( 'systemctl', 'status', $BOOT_UNIT, '--no-pager', '-l' ) )[1] );

            # This sweep really did open a window (unlike the no-op one above),
            # so this is the one place the boot path's own remask is observable.
            is( _user_manager_mask_file(), $masked_now, "…with the mask back in the same location it was in" );
            ok( !-e "/opt/cpanel/ea-podman/user-manager-mask.state", "…and no in-progress unmask record left behind" );
        }
    }
    else {
        my ( $rc, $out ) = run_cmd( 'systemctl', 'start', "user\@$uid.service" );
        is( $rc, 0, "the user manager starts again (nothing masked on this host)" ) or diag($out);

        $came_back = wait_for( sub { $manager_active->() && -S "/run/user/$uid/bus" }, 30 );
        ok( $came_back, "user manager came back (linger)" );
    }

    SKIP: {
        skip "the user manager never came back; nothing to serve", 1 if !$came_back;
        ok( wait_for( sub { _memcached_serving_via_socket($USER) }, 60 ), "memcached auto-started and serves once the manager is back (survives reboot)" );
    }
}

#--- uninstall via the CageFS login CLI cleans up ---------------------
{
    my ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " uninstall " . _sh($container) . " --verify" );
    is( $rc, 0, "ea-podman uninstall --verify (CLI, via CageFS login) exited 0" ) or diag($out);

    # That was the account's last container, so there is nothing left for a user
    # systemd manager to keep alive, and this linger is one ea-podman granted.
    # Checked before anything else runs as the user and bootstraps it again.
    SKIP: {
        skip "installed ea-podman predates CPANEL-55309", 2 if !$HAS_LINGER_FIX;
        ok( wait_for( sub { !-e "/var/lib/systemd/linger/$USER" }, 15 ), "the linger ea-podman granted is released with the last container" );
        ok( !-e "/opt/cpanel/ea-podman/granted-linger/$USER", "…and the grant record goes with it" );
    }

    ( $rc, $out ) = run_via_login( $USER, _sh($CLI) . " list" );
    my $decoded = _decode_json_loose($out);
    ok( !( $decoded && exists $decoded->{$container} ), "uninstalled container no longer registered" );
}

done_testing();

#---------------------------------------------------------------------
# helpers (cont.)
#---------------------------------------------------------------------
# Which location `user@.service` is masked in, or undef. Deliberately an
# independent oracle: re-derived from the filesystem rather than calling
# ea_podman::subids::user_manager_mask_file(), so it cannot agree with the code
# under test tautologically — and so this test does not have to load a module
# out of the *installed* package. Per systemd.unit(5) a unit is masked when its
# name is symlinked to /dev/null or is an empty file. (EA4-319)
sub _user_manager_mask_file {
    for my $file ( "/etc/systemd/system/user\@.service", "/run/systemd/system/user\@.service" ) {
        next if !lstat($file);

        return $file if -l _  && ( readlink($file) // '' ) eq "/dev/null";
        return $file if !-l _ && -z _;
    }

    return;
}

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

# ea-memcached16 mounts its own container directory at /socket_dir and runs
# memcached listening on /socket_dir/memcached.sock — i.e., on the host,
# <homedir>/ea-podman.d/<container_name>/memcached.sock. No TCP port is ever
# published (its ea-podman.json declares an empty `ports` list). This is a
# plain root-side filesystem path — cage-independent either way, since it's
# read directly by this (root) process, not via `su`.
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
