#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/ea4-338-restore-proxy-repair-live.t
#                                                  Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# EA4-338 / CPANEL-55949 -- a user-run `ea-podman restore` re-points the account's
# Web App proxies at the ports its containers now hold, end to end, on a real box.
#
# WHY THIS FILE EXISTS
#
# A tarball restore tears every container down and reallocates its host ports.
# The Apache include for each Web App still names the port from before the
# backup, so the container is healthy and every request 503s. EA4-338 ends the
# restore in the ea_podman admin module's REPAIR_WEBAPP_PROXIES, which runs the
# plugin's root-side Cpanel::WebApps::Repair::repair_user() once for the restore.
#
# FORCING A REAL PORT CHANGE
#
# The port authority hands out the LOWEST free port, and a restore releases the
# account's ports before it asks for new ones, so a plain restore usually gets
# the same ports back and proves nothing. Before anything is deployed this file
# has root hold BLOCKS of decoy ports, so the account's containers land above
# them. Releasing the highest held block just before a restore moves every
# container down into it: a guaranteed change, with no hand-edited include. Each
# phase that needs a change releases one block. A phase that expected a change
# and did not get one BAILs, rather than passing or failing on nothing.
#
# WHAT IT PROVES
#
#   P1  Plugin present: the restore prints "Re-pointed the web application proxy
#       for <domain> to port <N>" for both apps, N is the port podman publishes
#       and the port in BOTH the std and ssl includes, Apache serves each app,
#       the apps are not warned about while the plain container still is, the
#       health sweep cron entry is re-created, and no AutoSSL run is logged.
#   P2  An immediate second restore from a fresh backup: whatever moved (restore
#       allocates in manifest order, which is not stable, so a swap is possible)
#       is re-pointed and nothing that stayed put is reported or warned about.
#   P3  Plugin's Repair.pm absent: no repair output, no error, everything warned
#       about, the includes stay stale -- the restore behaves as it did before.
#   P4  Plugin too old (Repair.pm without repair_user): same as P3.
#   P5  Repair that dies: one "Could not repair the web application proxy
#       wiring" warning, the restore still exits 0, the reason is in cPanel's
#       error_log, and everything is warned about.
#   P6  The real Repair.pm back: a restore re-points the includes P3-P5 left
#       stale and Apache serves both apps again.
#   One Apache reload per restore: P1 (repair) minus P3 (same restore, no
#   repair) is exactly one "resuming normal operations" in Apache's error_log,
#   for two applications.
#
# BEFORE AND AFTER
#
# With E2E338_EXPECT_OLD_EAPODMAN=1 (ea-podman without EA4-338) only P1 runs, and
# it asserts the bug: both apps warned about, includes on the old port, Apache
# 503. A pass there shows the file reproduces the bug.
#
# NOT COVERED
#
#   * The manifest-only restore (`ea-podman restore --verify`, no tarball, after
#     restorepkg) reaches the same _warn_if_ports_changed(), but is not driven
#     here; cpanel-57396-pkgacct-restore-live.t drives that path.
#   * An account without the ea_podman feature: REPAIR_WEBAPP_PROXIES is
#     feature-gated, so its restore warns and leaves the proxies stale. Whether
#     that is the wanted contract is open on PR #39, so this file does not pin it.
#   * AutoSSL is checked only as "no new entry under /var/cpanel/logs/autossl
#     during the restore". A run queued for later than the settle wait would not
#     show up.
#
# RUN IT
#
#     scp t/LiveTests/setup-remote-live.pl t/LiveTests/ea4-338-restore-proxy-repair-live.t root@VM:/root/
#     # to test a working tree rather than the installed package:
#     rsync -a --delete ./ root@VM:/root/ea-podman/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl --ea-podman=/root/ea-podman --deploy'
#     ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/ea4-338-restore-proxy-repair-live.t'
#
#     # the before run, on a box with ea-podman from before EA4-338:
#     ssh root@VM 'EAPODMAN_LIVE=1 E2E338_EXPECT_OLD_EAPODMAN=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/ea4-338-restore-proxy-repair-live.t'
#
# `prove -v` because the first deploy pulls a ~1 GB node image. Expect 15-30
# minutes: two deploys and six restores.
#
# WHAT THE BOX NEEDS
#
#   * a disposable, LICENSED cPanel VM on CGROUP V2 (AlmaLinux 9/10) with the
#     Web App plugin installed, at a build whose Repair.pm has repair_user()
#     (cpanel-plugins #2831). The plugin needs the v2 hierarchy, so this skips on
#     cgroup v1, which includes CloudLinux.
#   * ea-podman from EA4-338 or later, uncompiled (EA4-315 or later).
#   * internet access to docker.io. A rate-limited pull SKIPS with that reason.
#   * zip, curl, podman
#
# MUST NOT INTERLEAVE WITH ea4-325-upgrade-live.t or cpanel-54868-e2e-live.t
# (they run `remove_containers --all` as root), or with anything else that
# allocates ports from the port authority: that would fill the freed blocks.
#
# DESTRUCTIVE, THROWAWAY VM ONLY. Creates a cPanel account, a package and a
# feature list, holds blocks of ports as root, removes the health sweep cron
# entry, and swaps the plugin's /usr/local/cpanel/Cpanel/WebApps/Repair.pm for
# stubs. All of it is put back at the end -- Repair.pm is checksummed on the
# way back -- and the account removed, unless E2E338_KEEP=1 (which still puts
# Repair.pm back and releases the ports). A run killed with SIGKILL leaves
# Repair.pm at Repair.pm.e2e338-saved; the next run refuses to start until it
# is moved back.
#
# ENVIRONMENT
#
#   EAPODMAN_LIVE=1                  required opt-in (directory convention)
#   E2E338_BLOCK                     ports per decoy block; must cover every port
#                                    the account holds (default 4; it uses 3)
#   E2E338_NODE_TAG                  node runtime tag: 20, 22 or 24 (default 22)
#   E2E338_DEPLOY_TIMEOUT            seconds to wait for a deploy (default 900)
#   E2E338_SETTLE                    seconds to wait after a restore for Apache's
#                                    background reload to land (default 20)
#   E2E338_APACHE_WAIT               seconds to retry for a 200 (default 60)
#   E2E338_EXPECT_OLD_EAPODMAN=1     the box has ea-podman WITHOUT EA4-338;
#                                    assert the bug instead
#   E2E338_KEEP=1                    leave the account in place

use strict;
use warnings;

use Test::More;
use Digest::SHA ();
use File::Path  ();
use File::Temp  ();
use IPC::Open3  ();
use Symbol      ();
use Time::HiRes ();

my $WHMAPI     = '/usr/local/cpanel/bin/whmapi1';
my $UAPI       = '/usr/local/cpanel/bin/uapi';
my $CLI        = '/opt/cpanel/ea-podman/bin/ea-podman';
my $EAP_LIB    = '/opt/cpanel/ea-podman/lib/ea_podman/util.pm';
my $ADMIN_PM   = '/usr/local/cpanel/Cpanel/Admin/Modules/Cpanel/ea_podman.pm';
my $PLUGIN_PM  = '/usr/local/cpanel/Cpanel/WebApps/Podman.pm';
my $REPAIR_PM  = '/usr/local/cpanel/Cpanel/WebApps/Repair.pm';
my $REPAIR_BAK = "$REPAIR_PM.e2e338-saved";
my $CRON_FILE  = '/etc/cron.d/webapp_health_sweep';
my $PORT_AUTH  = '/scripts/cpuser_port_authority';
my $CP_ERRLOG  = '/usr/local/cpanel/logs/error_log';
my $AUTOSSL    = '/var/cpanel/logs/autossl';

my $BLOCK       = $ENV{E2E338_BLOCK}          || 4;
my $NODE_TAG    = $ENV{E2E338_NODE_TAG}       || '22';
my $TIMEOUT     = $ENV{E2E338_DEPLOY_TIMEOUT} || 900;
my $SETTLE      = $ENV{E2E338_SETTLE}         || 20;
my $APACHE_WAIT = $ENV{E2E338_APACHE_WAIT}    || 60;
my $EXPECT_OLD  = $ENV{E2E338_EXPECT_OLD_EAPODMAN} ? 1 : 0;

my @SLUGS = qw(r338a r338b);
my $PLAIN = 'r338redis';

# Fully qualified: EL9's registries.conf enforces short names and has no alias
# for redis, so `redis:alpine` dies without a TTY to prompt on.
my $PLAIN_IMAGE = 'docker.io/library/redis:alpine';

#=============================================================================
# Guards. Each names what is missing.
#=============================================================================

plan skip_all => 'live test; set EAPODMAN_LIVE=1 to run' unless $ENV{EAPODMAN_LIVE};
plan skip_all => 'must run as root'                      if $> != 0;

sub in_path {
    my ($bin) = @_;
    for my $dir ( split /:/, ( $ENV{PATH} || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' ) ) {
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

for my $bin (qw(podman zip curl pkill su)) {
    plan skip_all => "$bin is not installed" if !in_path($bin);
}
plan skip_all => "whmapi1 not found ($WHMAPI)"                        if !-x $WHMAPI;
plan skip_all => "uapi not found ($UAPI)"                             if !-x $UAPI;
plan skip_all => "$PORT_AUTH not found"                               if !-x $PORT_AUTH;
plan skip_all => 'ea-podman is not installed'                         if !-e $EAP_LIB || !-x $CLI;
plan skip_all => "the webapp plugin is not installed (no $PLUGIN_PM)" if !-e $PLUGIN_PM;
plan skip_all => 'this box is on cgroup v1; the webapp plugin needs the v2 hierarchy'
  if !-e '/sys/fs/cgroup/cgroup.controllers';

#=============================================================================
# Helpers
#=============================================================================

sub run_cmd {
    my (@cmd) = @_;
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( my $in, my $out, $err, @cmd );
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid( $pid, 0 );
    return ( $? >> 8, $stdout, $stderr );
}

my $WORK = File::Temp::tempdir( 'e2e338-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

# stdout and stderr to separate files: a restore can write more to stderr than a
# pipe holds, which deadlocks run_cmd(), and "Re-pointed" is a print while the
# port warnings are warns.
sub run_capture {
    my (@cmd) = @_;
    my ( $outf, $errf ) = ( "$WORK/out", "$WORK/err" );
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        open STDIN,  '<', '/dev/null' or die;
        open STDOUT, '>', $outf       or die;
        open STDERR, '>', $errf       or die;
        exec(@cmd) or exit 127;
    }
    waitpid( $pid, 0 );
    my $rc = $? >> 8;
    return ( $rc, slurp($outf), slurp($errf) );
}

my $HAVE_CPJSON = eval { require Cpanel::JSON; 1 } ? 1 : 0;

sub decode_json_or_undef {
    my ($text) = @_;
    return undef if !length( $text // '' );
    $text =~ s/\A[^{\[]+//s;
    return undef if !length $text;
    return $HAVE_CPJSON ? eval { Cpanel::JSON::Load($text) } : eval { require JSON::PP; JSON::PP::decode_json($text) };
}

# uapi --user=X must run AS ROOT; it impersonates the account itself.
sub uapi {
    my ( $user, $module, $fn, @args ) = @_;
    my ( $rc, $out, $err ) = run_cmd( $UAPI, "--user=$user", $module, $fn, @args, '--output=json' );
    return ( decode_json_or_undef($out), $rc, $out . $err );
}

sub webapp { my ( $user, $fn, @args ) = @_; return uapi( $user, 'WebApp', $fn, @args ); }

sub uapi_ok { my ($j) = @_; return $j && $j->{result} && $j->{result}{status} ? 1 : 0; }

sub uapi_why {
    my ($j) = @_;
    return 'no JSON returned' if !$j;
    my $e = $j->{result}{errors};
    return join( '; ', @{$e} ) if ref $e eq 'ARRAY' && @{$e};
    return 'no error text';
}

sub whmapi {
    my (@args) = @_;
    my ( $rc, $out, $err ) = run_cmd( $WHMAPI, @args, '--output=json' );
    return ( decode_json_or_undef($out), $rc, $out . $err );
}

sub whm_ok { my ($j) = @_; return $j && $j->{metadata} && $j->{metadata}{result} ? 1 : 0; }

# diag goes to STDERR and vanishes when a run is redirected to a report file.
sub note_both {
    my ($msg) = @_;
    diag($msg);
    print "# $msg\n";
    return;
}

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; return $t // ''; }

sub spew {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $content;
    close $fh;
    return;
}

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub sha_of { my ($p) = @_; return -e $p ? Digest::SHA->new(256)->addfile($p)->hexdigest : ''; }

# As the account, with the rootless session's environment set by hand.
sub as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "
      . "HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_capture( 'su', '-s', '/bin/bash', $user, '-c', "unset QUERY_STRING REQUEST_METHOD; $env $cmd" );
}

sub indent { my ($t) = @_; return join( '', map { "#   $_\n" } split /\n/, $t // '' ); }

#=============================================================================
# Is the code under test present? A mismatch is a BAIL_OUT, never a skip.
#=============================================================================

BAIL_OUT( "$REPAIR_BAK exists: an earlier run was killed before it could put the plugin's Repair.pm back. "
      . "Check it is the real module, then `mv $REPAIR_BAK $REPAIR_PM`." )
  if -e $REPAIR_BAK;

my $HAS_FIX = ( slurp($EAP_LIB) =~ /_repair_webapp_proxies/ && slurp($ADMIN_PM) =~ /REPAIR_WEBAPP_PROXIES/ ) ? 1 : 0;
my $WANT_FIX = $EXPECT_OLD ? 0 : 1;

if ( $HAS_FIX != $WANT_FIX ) {
    BAIL_OUT( "$EAP_LIB / $ADMIN_PM " . ( $HAS_FIX ? 'have' : 'do not have' ) . ' EA4-338 but this run expects ' . ( $WANT_FIX ? 'it' : 'the older code' )
          . '. Refusing to run: the results would describe code you are not looking at. '
          . ( $EXPECT_OLD ? 'Unset E2E338_EXPECT_OLD_EAPODMAN.' : 'Deploy the fix (setup-remote-live.pl --deploy), or set E2E338_EXPECT_OLD_EAPODMAN=1 for the before run.' ) );
}

# Before EA4-315 the CLI was a compiled binary carrying its own util.pm, so the
# library above would not be what runs.
BAIL_OUT("$CLI is a compiled binary: the util.pm checked above is not what it runs. Install an ea-podman from EA4-315 or later.")
  if !-T $CLI;

# A plugin without repair_user() silently turns P1 into P4.
my $REAL_REPAIR_SHA = sha_of($REPAIR_PM);
if ($WANT_FIX) {
    BAIL_OUT("$REPAIR_PM is missing: the webapp plugin on this box cannot repair anything") if !$REAL_REPAIR_SHA;
    BAIL_OUT("$REPAIR_PM has no repair_user(): this plugin predates cpanel-plugins #2831, so every phase would test the fallback")
      if slurp($REPAIR_PM) !~ /^sub repair_user\b/m;
}

my $PLUGIN_BUILD = do {
    my ( $rc, $out ) = run_cmd( 'rpm', '-qf', $PLUGIN_PM );
    ( $rc, $out ) = run_cmd( 'dpkg', '-S', $PLUGIN_PM ) if $rc != 0;
    chomp( $out //= '' );
    $rc == 0 && length $out ? $out : 'unknown (not from a package?)';
};

my $APACHE_LOG = do {
    my $p = eval { require Cpanel::ConfigFiles::Apache; Cpanel::ConfigFiles::Apache->new()->file_error_log() };
    ( grep { length($_) && -f $_ } ( $p // '', '/etc/apache2/logs/error_log', '/usr/local/apache/logs/error_log' ) )[0] // '';
};

note_both( 'ea-podman: ' . ( $HAS_FIX ? 'HAS' : 'does NOT have' ) . ' EA4-338' );
note_both("webapp plugin build: $PLUGIN_BUILD");
note_both( 'Apache error_log: ' . ( $APACHE_LOG || 'not found (the reload count will be skipped)' ) );
note_both( 'expecting ' . ( $WANT_FIX ? 'the proxies re-pointed' : 'the bug: proxies left on the old port (before run)' ) );

#=============================================================================
# State to clean up, and diagnostics on failure
#=============================================================================

my ( $USER, $HOME, $PKG, $FEATURELIST, $SUFFIX );
my @BLOCKS;    # [ [ports...], ... ] lowest first; each still held by root
my $CRON_SAVED = -e $CRON_FILE ? slurp($CRON_FILE) : undef;
my %LAST;      # the last restore's output, for diagnostics

sub port_assignments {
    my ($who) = @_;
    my ( undef, $json ) = run_cmd( $PORT_AUTH, 'list', $who );    # `list root` shows only root's ports
    my $hr = decode_json_or_undef($json);
    return ref $hr eq 'HASH' ? $hr : {};
}

# { service => "p1,p2" } for the account
sub ports_by_service {
    my $hr = port_assignments($USER);
    my %by;
    for my $port ( sort { $a <=> $b } keys %{$hr} ) {
        push @{ $by{ $hr->{$port}{service} // '?' } }, $port;
    }
    return { map { $_ => join( ',', @{ $by{$_} } ) } keys %by };
}

sub describe_ports {
    my $by = ports_by_service();
    return 'none' if !%{$by};
    return join( ', ', map { "$_ => $by->{$_}" } sort keys %{$by} );
}

sub put_repair_back {
    return if !-e $REPAIR_BAK;
    rename( $REPAIR_BAK, $REPAIR_PM ) or return note_both("COULD NOT PUT $REPAIR_PM BACK from $REPAIR_BAK: $!");
    my $sha = sha_of($REPAIR_PM);
    note_both( $sha eq $REAL_REPAIR_SHA ? "put the plugin's $REPAIR_PM back (checksum matches)" : "!!! $REPAIR_PM IS BACK BUT ITS CHECKSUM DIFFERS ($sha vs $REAL_REPAIR_SHA): reinstall the webapp plugin" );
    return;
}

sub release_ports {
    my (@ports) = @_;
    return if !@ports;
    my ( $rc, $out, $err ) = run_cmd( $PORT_AUTH, 'take', 'root', @ports );
    note_both("could not release decoy ports @ports: $out$err") if $rc != 0;
    return $rc == 0;
}

sub dump_state {
    my ($why) = @_;
    print "#\n# ===== DIAGNOSTICS ($why) =====\n";
    print "# ea-podman EA4-338: " . ( $HAS_FIX ? 'yes' : 'no' ) . "   plugin: $PLUGIN_BUILD\n";
    print "# user: " . ( $USER // 'none' ) . "  home: " . ( $HOME // 'none' ) . "\n";
    if ( defined $USER ) {
        print "# reserved ports: " . describe_ports() . "\n";
        print "# decoy blocks still held: " . join( ' | ', map { "@{$_}" } @BLOCKS ) . "\n";
        my ( undef, $ps ) = as_user( $USER, 'podman ps -a --format "{{.Names}} {{.Status}} {{.Ports}}" 2>&1' );
        print "# podman ps -a:\n", indent($ps);
    }
    print "# last restore ($LAST{phase}) exit $LAST{rc}\n# stdout:\n", indent( $LAST{out} ), "# stderr:\n", indent( $LAST{err} ) if %LAST;
    print "# ===== END DIAGNOSTICS =====\n";
    return;
}

END {
    my $exit    = $?;
    my $passing = Test::More->builder->is_passing;
    my $ran     = Test::More->builder->current_test;

    dump_state('a test failed') if $ran && !$passing && ( $USER // '' ) ne '';

    # Always, even with E2E338_KEEP: these are host-wide.
    put_repair_back();
    release_ports( @{$_} ) for @BLOCKS;
    @BLOCKS = ();
    if ( defined $CRON_SAVED && !-e $CRON_FILE ) {
        spew( $CRON_FILE, $CRON_SAVED );
        note_both("put $CRON_FILE back");
    }

    if ( $ENV{E2E338_KEEP} ) {
        print "# E2E338_KEEP set: account '" . ( $USER // '' ) . "' left in place\n" if $USER;
    }
    else {
        if ( defined $USER ) {
            run_cmd( 'pkill', '-KILL', '-u', $USER );
            sleep 2;
            run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
            print "# removed throwaway account '$USER'\n";
        }
        if ( length( $PKG // '' ) ) {
            whmapi( 'killpkg', "pkgname=$PKG" );
            unlink "/var/cpanel/packages/$PKG" if -e "/var/cpanel/packages/$PKG";    # killpkg is broken on some builds
        }
        if ( length( $FEATURELIST // '' ) ) {
            whmapi( 'delete_featurelist', "featurelist=$FEATURELIST" );
            unlink "/var/cpanel/features/$FEATURELIST" if -e "/var/cpanel/features/$FEATURELIST";
        }
    }
    $? = $exit;
}

#=============================================================================
# Decoy ports, held BEFORE the account exists so everything it gets is above
# them. One block per phase that needs a port change.
#=============================================================================

$SUFFIX = substr( time, -5 );

for my $i ( 1 .. ( $WANT_FIX ? 4 : 1 ) ) {
    my ( $rc, $out, $err ) = run_cmd( $PORT_AUTH, 'give', 'root', $BLOCK, "--service=e2e338-decoy-$SUFFIX-$i" );
    my @ports = grep { /^[0-9]+$/ } split /\n/, $out;
    if ( $rc != 0 || @ports != $BLOCK ) {
        release_ports(@ports);
        plan skip_all => "could not hold $BLOCK decoy ports as root: $out$err";
    }
    push @BLOCKS, \@ports;
}
note_both( 'decoy blocks held by root: ' . join( ' | ', map { "@{$_}" } @BLOCKS ) );

# The highest block still held: freeing it moves every container down into it.
sub release_next_block {
    my $block = pop @BLOCKS or BAIL_OUT('no decoy block left to release; this is a bug in the test');
    release_ports( @{$block} ) or BAIL_OUT("could not release decoy ports @{$block}");
    note_both("released decoy block @{$block}");
    return;
}

#=============================================================================
# Account: a package whose feature list enables the webapp feature (and
# subdomains, or every deploy dies creating its subdomain) and ea_podman.
#=============================================================================

{
    $USER        = "r338$SUFFIX";
    $FEATURELIST = "e2e338fl$SUFFIX";
    $PKG         = "e2e338pkg$SUFFIX";

    note_both("Creating throwaway account '$USER' ...");

    my ( $fl, $flrc, $flraw ) = whmapi( 'create_featurelist', "featurelist=$FEATURELIST", 'webapp=1', 'subdomains=1', 'ea_podman=1' );
    if ( !whm_ok($fl) ) {
        my $why = ( $fl && $fl->{metadata}{reason} ) || "exit $flrc: " . substr( $flraw, 0, 300 );
        ( $FEATURELIST, $PKG, $USER ) = ();
        plan skip_all => "could not create the feature list: $why";
    }

    my @pkg = ( 'addpkg', "name=$PKG", "featurelist=$FEATURELIST", 'quota=unlimited' );
    my ( $pk, $pkrc, $pkraw ) = whmapi( @pkg, '_PACKAGE_EXTENSIONS=webapp-limits', 'WEBAPP_MAX_APPS=10' );
    ( $pk, $pkrc, $pkraw ) = whmapi(@pkg) if !whm_ok($pk);
    if ( !whm_ok($pk) ) {
        my $why = ( $pk && $pk->{metadata}{reason} ) || "exit $pkrc: " . substr( $pkraw, 0, 300 );
        undef $USER;
        plan skip_all => "could not create the package: $why";
    }

    # plan= NOT pkg=; hasshell=1 NOT shell=. The others are silently ignored.
    my ( $acct, $acrc, $acraw ) = whmapi(
        'createacct',
        "username=$USER",
        "domain=$USER.e2e338.test",
        'password=R' . $SUFFIX . '!Zx9e2e',
        "plan=$PKG",
        'hasshell=1',
    );
    if ( !whm_ok($acct) ) {
        my $why = ( $acct && $acct->{metadata}{reason} ) || "exit $acrc: " . substr( $acraw, 0, 300 );
        my $u   = $USER;
        undef $USER;
        plan skip_all => "could not create test account '$u': $why";
    }
}

$HOME = ( getpwnam($USER) )[7];
plan skip_all => "could not resolve a homedir for '$USER'" if !length( $HOME // '' ) || !-d $HOME;
note_both("Test user: $USER, home: $HOME");

{
    my ($feat) = webapp( $USER, 'has_feature' );
    plan skip_all => "the webapp feature is not enabled for '$USER' even on a package that grants it: " . uapi_why($feat)
      if !( uapi_ok($feat) && ref $feat->{result}{data} eq 'HASH' && $feat->{result}{data}{has_feature} );
}

#=============================================================================
# Fixtures: two zero-dependency Node apps, and one plain container that is not a
# Web App (its port change is the user's problem and must still be warned about).
#=============================================================================

sub marker { my ($slug) = @_; return uc($slug) . '_OK'; }

sub write_fixture_zip {
    my ($slug) = @_;
    my $dir    = "$HOME/$slug-src";
    my $mark   = marker($slug);
    File::Path::remove_tree($dir);
    File::Path::make_path("$dir/app");

    spew( "$dir/app/package.json", qq({"name":"$slug","version":"1.0.0","private":true,"scripts":{"start":"node server.js"}}\n) );
    spew(
        "$dir/app/server.js", <<"JS"
const http = require('http');
const port = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('$mark\\n');
}).listen(port);
JS
    );

    unlink "$HOME/$slug-src.zip";
    my ( $rc, $out, $err ) = run_cmd( 'bash', '-c', 'cd ' . _sh("$dir/app") . ' && zip -q -r ' . _sh("$HOME/$slug-src.zip") . ' .' );
    die "could not build the fixture zip: $out$err\n" if $rc != 0;

    run_cmd( 'chown', '-R', "$USER:$USER", "$HOME/$slug-src.zip", $dir );
    return "$slug-src.zip";
}

sub app_record {
    my ($slug) = @_;
    my ($json) = webapp( $USER, 'list' );
    return undef if !uapi_ok($json);
    for my $app ( @{ $json->{result}{data} || [] } ) {
        return $app if ( $app->{name} // '' ) eq $slug;
    }
    return undef;
}

# A deploy is queued and returns immediately. Wait for a result.
sub wait_for_result {
    my ($slug) = @_;
    my $deadline = time + $TIMEOUT;

    while ( time < $deadline ) {
        my $app  = app_record($slug);
        my $last = $app && ref $app->{last_deploy} eq 'HASH' ? $app->{last_deploy} : {};
        return ( $app, $last ) if $app && ( $app->{status} // '' ) ne 'deploying' && length( $last->{result} // '' );
        sleep 5;
    }
    return ( app_record($slug), { result => 'timeout' } );
}

sub deploy_log {
    my ($slug) = @_;
    my @files = sort { ( stat($b) )[9] <=> ( stat($a) )[9] } glob("$HOME/.cpanel/logs/*-deploy-$slug.log");
    return @files ? slurp( $files[0] ) : '';
}

sub published_port {
    my ($container) = @_;
    my ( $rc, $out ) = as_user( $USER, 'podman inspect --format ' . _sh('{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}') . ' ' . _sh($container) . ' 2>/dev/null' );
    chomp( $out //= '' );
    return $rc == 0 ? $out : '';
}

# The port each Web App include sends `/` to: { std => N, ssl => N }
sub wired_ports {
    my ($domain) = @_;
    my $base = eval { require Cpanel::ConfigFiles::Apache; Cpanel::ConfigFiles::Apache->new()->dir_conf_userdata() } || '/etc/apache2/conf.d/userdata';
    my %w;
    for my $type (qw(std ssl)) {
        my $conf = slurp("$base/$type/2_4/$USER/$domain/webapp.conf");
        $w{$type} = $conf =~ m{^ProxyPass\s+/\s+http://127\.0\.0\.1:([0-9]+)/}m ? $1 : '';
    }
    return \%w;
}

sub account_ip {
    my ($ip) = slurp("/var/cpanel/users/$USER") =~ /^IP=(\S+)/m;
    return $ip // '127.0.0.1';
}

# Through Apache, to the account's own IP, as a browser would reach it. With
# $want_ok it retries until the APPLICATION answers: Apache's reload is queued
# in the background (BgSafe), so it may land a little after the command returns.
sub via_apache {
    my ( $domain, $mark, $want_ok ) = @_;
    my $ip    = account_ip();
    my $start = Time::HiRes::time();
    my ( $code, $body ) = ( '', '' );
    while (1) {
        my ( undef, $out ) = run_cmd(
            'curl', '-s', '-k', '-L', '--max-time', '15',
            '--resolve', "$domain:80:$ip", '--resolve', "$domain:443:$ip",
            '-w', "\n%{http_code}", "http://$domain/"
        );
        ( $body, $code ) = $out =~ /\A(.*)\n([0-9]{3})\z/s ? ( $1, $2 ) : ( $out, '' );
        last if !$want_ok;
        last if $code eq '200' && $body =~ /\Q$mark\E/;
        last if Time::HiRes::time() - $start >= $APACHE_WAIT;
        sleep 3;
    }
    return ( $code, $body, sprintf( '%.1f', Time::HiRes::time() - $start ) );
}

my %APPS;    # slug => { container, domain }
my $PLAIN_CONTAINER;
my $RATE_LIMITED = 0;

subtest 'setup: two Web Apps and one plain container, serving, above the decoy blocks' => sub {
    for my $slug (@SLUGS) {
        my $archive = write_fixture_zip($slug);

        my ($staged) = webapp( $USER, 'stage', "name=$slug", 'source_type=zip', "source=$archive", 'runtime=nodejs', "runtime_tag=$NODE_TAG" );
        ok( uapi_ok($staged), "WebApp::stage $slug" ) or BAIL_OUT( 'WebApp::stage failed: ' . uapi_why($staged) );

        my ($configured) = webapp( $USER, 'configure', "name=$slug", 'startup_command=npm run start' );
        ok( uapi_ok($configured), "WebApp::configure $slug" ) or BAIL_OUT( 'WebApp::configure failed: ' . uapi_why($configured) );

        my ($deployed) = webapp( $USER, 'deploy', "name=$slug" );
        ok( uapi_ok($deployed), "WebApp::deploy $slug is accepted" ) or BAIL_OUT( 'WebApp::deploy failed: ' . uapi_why($deployed) );

        my ( $app, $last ) = wait_for_result($slug);
        my $log = deploy_log($slug);
        return $RATE_LIMITED = 1 if $log =~ /toomanyrequests|rate limit/i;
        is( $last->{result}, 'success', "$slug deploys" ) or BAIL_OUT( "deploy of $slug did not succeed:\n" . indent($log) );

        $APPS{$slug} = { container => $app->{container_name} // '', domain => $app->{domain} // '' };
        ok( length $APPS{$slug}{container} && length $APPS{$slug}{domain}, "$slug has a container ($APPS{$slug}{container}) and a domain ($APPS{$slug}{domain})" )
          or BAIL_OUT("no container or domain for $slug");

        my ( $code, $body ) = via_apache( $APPS{$slug}{domain}, marker($slug), 1 );
        is( $code, '200', "Apache serves $slug before any restore" ) or BAIL_OUT("$slug is not serving through Apache even before a restore: HTTP $code");
    }

    my ( $j, $rc, $raw ) = uapi( $USER, 'EAPodman', 'install', "name=$PLAIN", "image=$PLAIN_IMAGE", 'cpuser_port=6379', 'accept_arbitrary_image_risk=1' );
    return $RATE_LIMITED = 1 if $raw =~ /toomanyrequests|rate limit/i;

    # BAIL_OUT shows only the first line; podman's reason is on the later ones.
    ok( uapi_ok($j), 'EAPodman::install the plain container' ) or do {
        diag( 'EAPodman install failed: ' . uapi_why($j) );
        BAIL_OUT( 'EAPodman install failed: ' . uapi_why($j) );
    };
    $PLAIN_CONTAINER = $j->{result}{data}{container_name} // '';
    ok( length $PLAIN_CONTAINER, "it is $PLAIN_CONTAINER" ) or BAIL_OUT('no container name for the plain container');

    my $by    = ports_by_service();
    my $total = () = map { split /,/ } values %{$by};
    note_both( 'account ports: ' . describe_ports() );
    cmp_ok( $total, '<=', $BLOCK, "the account's $total ports fit in one decoy block of $BLOCK" ) or BAIL_OUT("raise E2E338_BLOCK to at least $total");

    my $lowest = ( sort { $a <=> $b } map { split /,/ } values %{$by} )[0];
    cmp_ok( $lowest, '>', $BLOCKS[-1][-1], 'every account port is above the highest decoy block' )
      or BAIL_OUT('another process took ports while the decoys were held; the port changes cannot be forced');
};

if ($RATE_LIMITED) {
    note_both('Docker Hub rate-limited this box: an image never arrived, so nothing after this would mean anything');
    done_testing();
    exit 0;
}

#=============================================================================
# A restore, and everything it left behind
#=============================================================================

sub all_containers { return ( ( map { $APPS{$_}{container} } @SLUGS ), $PLAIN_CONTAINER ); }

sub take_backup {
    my ( $rc, $out, $err ) = as_user( $USER, _sh($CLI) . ' backup' );
    my @tarballs = sort glob("$HOME/ea-podman-backups/backup-*.tar.gz");    # UTC names sort chronologically
    BAIL_OUT( "ea-podman backup failed (exit $rc):\n" . indent("$out$err") ) if $rc != 0 || !@tarballs;
    return $tarballs[-1];
}

sub restart_count {
    my ($offset) = @_;
    return undef if !$APACHE_LOG;
    open my $fh, '<', $APACHE_LOG or return undef;
    seek( $fh, $offset, 0 );
    my $n = 0;
    while ( my $line = <$fh> ) { $n++ if $line =~ /resuming normal operations/; }
    return $n;
}

sub autossl_entries { opendir( my $dh, $AUTOSSL ) or return undef; return { map { $_ => 1 } grep { !/^\./ } readdir $dh }; }

sub restore {
    my ($phase) = @_;

    my $tarball = take_backup();
    my %before  = %{ ports_by_service() };

    # The sweep could repair or reload behind our back, and its return is part of P1.
    unlink $CRON_FILE;

    my $apache_off = $APACHE_LOG ? ( -s $APACHE_LOG // 0 ) : 0;
    my $cplog_off  = -s $CP_ERRLOG // 0;
    my $autossl    = autossl_entries();

    my ( $rc, $out, $err ) = as_user( $USER, _sh($CLI) . ' restore ' . _sh($tarball) . ' --verify' );

    # The repair re-creates the sweep's cron entry. It runs every 5 minutes and
    # would re-point the includes the later phases need to stay stale, so it is
    # recorded and taken away again at once.
    my $cron_back = -e $CRON_FILE ? 1 : 0;
    unlink $CRON_FILE;

    # What a visitor sees the moment the command returns. Reported, not asserted:
    # Apache's reload is queued in the background and may land a moment later.
    my $at_return = join( ', ', map { my ($c) = via_apache( $APPS{$_}{domain}, marker($_), 0 ); "$_ HTTP $c" } @SLUGS );

    %LAST = ( phase => $phase, rc => $rc, out => $out, err => $err );
    note_both("$phase: restore exited $rc; as it returned: $at_return");
    print "# stdout:\n", indent($out), "# stderr:\n", indent($err);

    sleep $SETTLE;

    my %after = %{ ports_by_service() };
    my %moved = map { $_ => ( ( $before{$_} // '' ) ne ( $after{$_} // '' ) ? 1 : 0 ) } all_containers();
    note_both( "$phase: " . join( ', ', map { "$_ $before{$_} -> " . ( $after{$_} // 'none' ) } sort keys %before ) );

    my %repointed = $out =~ /^Re-pointed the web application proxy for (\S+) to port ([0-9]+)\.$/mg;
    my %warned    = map { $_ => 1 } $err =~ /^The TCP ports for (\S+) have changed\./mg;

    my $cplog_new = do {
        open my $fh, '<', $CP_ERRLOG;
        my $t = '';
        if ($fh) { seek( $fh, $cplog_off, 0 ); local $/; $t = <$fh> // ''; }
        $t;
    };

    my $autossl_after = autossl_entries();
    my @new_autossl   = ( $autossl && $autossl_after ) ? grep { !$autossl->{$_} } sort keys %{$autossl_after} : ();

    return {
        rc          => $rc,
        out         => $out,
        err         => $err,
        moved       => \%moved,
        after       => \%after,
        repointed   => \%repointed,
        warned      => \%warned,
        cron_back   => $cron_back,
        apache_off  => $apache_off,
        cplog       => $cplog_new,
        new_autossl => \@new_autossl,
        autossl_ok  => defined $autossl ? 1 : 0,
    };
}

sub require_every_container_moved {
    my ( $phase, $r ) = @_;
    my @stayed = grep { !$r->{moved}{$_} } all_containers();
    BAIL_OUT("$phase: setup did not produce a port change for @stayed, so this phase would prove nothing. Was something else allocating ports?")
      if @stayed;
    return;
}

# The proxies were re-pointed: the line names the port podman publishes, both
# includes carry it, and Apache serves the app.
sub assert_repaired {
    my ( $phase, $r, $slug ) = @_;
    my ( $container, $domain ) = @{ $APPS{$slug} }{qw(container domain)};
    my $published = published_port($container);
    my $wired     = wired_ports($domain);

    ok( exists $r->{repointed}{$domain}, "$phase: $slug is reported re-pointed" );
    is( $r->{repointed}{$domain} // '', $published, "$phase: to the port podman publishes ($published)" );
    is( $wired->{std},                  $published, "$phase: the std include names it" );
    is( $wired->{ssl},                  $published, "$phase: the ssl include names it" );
    ok( !$r->{warned}{$container}, "$phase: $slug is not warned about right after being fixed" );

    my ( $code, $body, $secs ) = via_apache( $domain, marker($slug), 1 );
    is( $code, '200', "$phase: Apache serves $slug" ) && like( $body, qr/\Q${\ marker($slug)}\E/, "$phase: and it is $slug" );
    note_both("$phase: $slug served ${secs}s after the settle wait") if $code eq '200';
    return;
}

# The proxies were left alone: warned about, includes on a port nothing
# publishes, Apache 503.
sub assert_stale {
    my ( $phase, $r, $slug ) = @_;
    my ( $container, $domain ) = @{ $APPS{$slug} }{qw(container domain)};
    my $published = published_port($container);
    my $wired     = wired_ports($domain);

    ok( !exists $r->{repointed}{$domain}, "$phase: $slug is not reported re-pointed" );
    ok( $r->{warned}{$container},         "$phase: $slug is warned about, as before EA4-338" );
    isnt( $wired->{std}, $published, "$phase: the std include still names the old port ($wired->{std}, podman publishes $published)" );

    my ($code) = via_apache( $domain, marker($slug), 0 );
    is( $code, '503', "$phase: Apache answers 503 for $slug" );
    return;
}

#=============================================================================
# P1: the plugin's repair, through the admin module
#=============================================================================

my ( $P1, $P3 );

# createacct and the first deploys queue AutoSSL. One landing in P1's window
# would fail its AutoSSL check and add an Apache restart, so wait it out.
my $AUTOSSL_QUIET = do {
    my ( $deadline, $stable_since, $seen ) = ( time + 300, time, '' );
    my $quiet = 0;
    while ( time < $deadline ) {
        my $now     = join( ',', sort keys %{ autossl_entries() // {} } );
        my ($procs) = ( run_cmd( 'pgrep', '-f', 'autossl' ) )[1];
        ( $seen, $stable_since ) = ( $now, time ) if $now ne $seen || length( $procs // '' );
        if ( time - $stable_since >= 30 ) { $quiet = 1; last; }
        sleep 5;
    }
    note_both( $quiet ? 'AutoSSL is quiet' : 'AutoSSL was still busy after 5 minutes; the P1 AutoSSL check will be skipped' );
    $quiet;
};

subtest 'P1: a restore that moves every port re-points both Web Apps' => sub {
    release_next_block();
    $P1 = restore('P1');
    require_every_container_moved( 'P1', $P1 );

    is( $P1->{rc}, 0, 'P1: the restore exits 0' );
    ok( $P1->{warned}{$PLAIN_CONTAINER}, "P1: the plain container ($PLAIN_CONTAINER) is still warned about: its port really did move" );

    if ( !$WANT_FIX ) {
        assert_stale( 'P1 (before run)', $P1, $_ ) for @SLUGS;
        return;
    }

    unlike( $P1->{err}, qr/Could not repair the web application proxy wiring/, 'P1: no repair failure is reported' );
    assert_repaired( 'P1', $P1, $_ ) for @SLUGS;
    is( scalar keys %{ $P1->{repointed} }, scalar @SLUGS, 'P1: only the Web Apps are reported re-pointed' );

    ok( $P1->{cron_back}, "P1: the restore scheduled the health sweep again ($CRON_FILE)" );

  SKIP: {
        skip "$AUTOSSL does not exist on this box",                                         1 if !$P1->{autossl_ok};
        skip 'AutoSSL from the account setup was still running, so a new log means nothing', 1 if !$AUTOSSL_QUIET;
        is_deeply( $P1->{new_autossl}, [], 'P1: no AutoSSL run was logged during the restore' );
    }

    # Counted only now: both apps answering 200 above proves the queued reload landed.
    $P1->{restarts} = restart_count( $P1->{apache_off} );
};

done_testing() if !$WANT_FIX;
exit 0         if !$WANT_FIX;

#=============================================================================
# P2: again at once, from a fresh backup
#=============================================================================

subtest 'P2: a second restore reports only what really moved' => sub {
    my $r = restore('P2');
    is( $r->{rc}, 0, 'P2: the restore exits 0' );
    unlike( $r->{err}, qr/Could not repair the web application proxy wiring/, 'P2: no repair failure is reported' );

    # Allocation follows manifest order, which is not stable, so two containers
    # can swap ports. Hold each one to what actually happened to it.
    for my $slug (@SLUGS) {
        my ( $container, $domain ) = @{ $APPS{$slug} }{qw(container domain)};
        if ( $r->{moved}{$container} ) {
            note_both("P2: $slug moved (a manifest-order swap)");
            assert_repaired( 'P2', $r, $slug );
        }
        else {
            ok( !exists $r->{repointed}{$domain}, "P2: $slug stayed put and is not reported re-pointed" );
            ok( !$r->{warned}{$container},        "P2: nor warned about" );
            my ($code) = via_apache( $domain, marker($slug), 1 );
            is( $code, '200', "P2: Apache still serves $slug" );
        }
    }
    is( !!$r->{warned}{$PLAIN_CONTAINER}, !!$r->{moved}{$PLAIN_CONTAINER}, 'P2: the plain container is warned about only if it moved' );
};

#=============================================================================
# P3-P5: the plugin absent, too old, and broken. Each restore must behave as it
# did before EA4-338, and a broken repair must not fail the restore.
#=============================================================================

sub swap_repair {
    my ($content) = @_;
    rename( $REPAIR_PM, $REPAIR_BAK ) or BAIL_OUT("could not move $REPAIR_PM aside: $!") if !-e $REPAIR_BAK;
    unlink $REPAIR_PM;
    if ( defined $content ) {
        spew( $REPAIR_PM, $content );
        chmod 0644, $REPAIR_PM;
    }
    return;
}

my $STUB_OLD = <<'PM';
package Cpanel::WebApps::Repair;

# e2e338 stub: a plugin from before repair_user()
use strict;
sub repair_current_user { return [] }
1;
PM

my $STUB_BROKEN = <<'PM';
package Cpanel::WebApps::Repair;

# e2e338 stub: a repair that dies
use strict;
sub repair_user         { die "E2E338_STUB_REPAIR_DIED\n" }
sub repair_current_user { return [] }
1;
PM

subtest 'P3: with the plugin\'s Repair.pm absent, the restore behaves as before' => sub {
    swap_repair(undef);
    release_next_block();
    $P3 = restore('P3');
    require_every_container_moved( 'P3', $P3 );

    is( $P3->{rc}, 0, 'P3: the restore exits 0' );
    is( $P3->{out} =~ /Re-pointed/ ? 1 : 0, 0, 'P3: nothing is reported re-pointed' );
    unlike( $P3->{err}, qr/Could not repair/, 'P3: and no repair error appears' );
    ok( $P3->{warned}{$PLAIN_CONTAINER}, 'P3: the plain container is warned about' );
    assert_stale( 'P3', $P3, $_ ) for @SLUGS;
    $P3->{restarts} = restart_count( $P3->{apache_off} );
};

subtest 'P4: with a plugin that predates repair_user(), the restore behaves as before' => sub {
    swap_repair($STUB_OLD);
    release_next_block();
    my $r = restore('P4');
    require_every_container_moved( 'P4', $r );

    is( $r->{rc}, 0, 'P4: the restore exits 0' );
    is( $r->{out} =~ /Re-pointed/ ? 1 : 0, 0, 'P4: nothing is reported re-pointed' );
    unlike( $r->{err}, qr/Could not repair/, 'P4: and no repair error appears' );
    ok( $r->{warned}{$PLAIN_CONTAINER}, 'P4: the plain container is warned about' );
    assert_stale( 'P4', $r, $_ ) for @SLUGS;
};

subtest 'P5: a repair that dies is reported, and the restore still succeeds' => sub {
    swap_repair($STUB_BROKEN);
    release_next_block();
    my $r = restore('P5');
    require_every_container_moved( 'P5', $r );

    is( $r->{rc}, 0, 'P5: the restore still exits 0' );
    my @failures = $r->{err} =~ /^(Could not repair the web application proxy wiring:.*)$/mg;
    is( scalar @failures, 1, 'P5: the failure is reported once' ) or note_both("stderr:\n$r->{err}");
    like( $failures[0] // '', qr/repair failed/, 'P5: as the generic message' );
    unlike( $r->{err}, qr/E2E338_STUB_REPAIR_DIED/, 'P5: the root-side reason is not shown to the account' );
    like( $r->{cplog}, qr/E2E338_STUB_REPAIR_DIED/, "P5: the reason is in $CP_ERRLOG" );
    ok( $r->{warned}{$PLAIN_CONTAINER}, 'P5: the plain container is warned about' );
    assert_stale( 'P5', $r, $_ ) for @SLUGS;
};

#=============================================================================
# P6: the real plugin back. The includes P3-P5 left stale are re-pointed.
#=============================================================================

subtest 'P6: with the real plugin back, a restore re-points the stale includes' => sub {
    put_repair_back();
    is( sha_of($REPAIR_PM), $REAL_REPAIR_SHA, "P6: $REPAIR_PM is the plugin's own again" );

    my $r = restore('P6');
    is( $r->{rc}, 0, 'P6: the restore exits 0' );
    assert_repaired( 'P6', $r, $_ ) for @SLUGS;
    is( !!$r->{warned}{$PLAIN_CONTAINER}, !!$r->{moved}{$PLAIN_CONTAINER}, 'P6: the plain container is warned about only if it moved' );
};

#=============================================================================
# One Apache reload for the whole restore. P1 and P3 are the same restore --
# every port moved -- with and without the repair.
#=============================================================================

SKIP: {
    skip 'no Apache error_log found to count reloads in', 1 if !$APACHE_LOG || !defined $P1->{restarts} || !defined $P3->{restarts};
    note_both("Apache reloads: P1 (repair) $P1->{restarts}, P3 (no repair) $P3->{restarts}");
    is( $P1->{restarts} - $P3->{restarts}, 1, 'the repair adds exactly one Apache reload for both applications' );
}

done_testing();
