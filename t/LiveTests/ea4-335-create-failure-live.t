#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/ea4-335-create-failure-live.t   Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# EA4-335 / CPANEL-55804 -- a container that cannot be created because the
# account is out of disk space says WHY, end to end, on a real box.
#
# WHY THIS FILE EXISTS
#
# A Web App deploy that failed while podman unpacked an image layer into a full
# quota logged only "Could not provision the container (build_failed): Failed
# to create container". podman's own error went to STDERR and was thrown away by
# both halves: ea-podman printed it and died with the bare message, and the
# plugin discarded whatever ea-podman printed. The unit tests prove each half
# with podman mocked out. Only a real box can prove the pair against a real
# podman on a real full filesystem, and the thing worth proving is the seam:
# whether the text survives the trip from podman, through ea-podman, through the
# adminbin-launched deploy, into the log the UI reads.
#
# HOW A FULL DISK IS MADE
#
# The account's rootless container storage is mounted from a small loop-backed
# ext4 image, so the image layers do not fit. That yields "no space left on
# device" (ENOSPC), deterministically, on any VM, with no quota configuration.
# It is NOT the literal "disk quota exceeded" (EDQUOT) of the ticket -- that
# needs a filesystem with quotas enabled, which most dev VMs do not have. Both
# strings go through the same classifier (ea_podman::util::_podman_failure_reason),
# and the exact quota wording is pinned by the unit tests, so this file proves
# the plumbing and the unit tests prove the wording.
#
# WHAT IT PROVES
#
#   A. a Web App deploy on a full disk fails as build_failed (unchanged for
#      callers that only check the category) AND its deploy log contains:
#        - the original "Could not provision the container (build_failed)" line
#        - a plain-words sentence saying the account is out of disk space or
#          quota, EXACTLY ONCE
#        - podman's own error line, EXACTLY ONCE
#      "Exactly once" is the live-only risk: the plugin avoids repeating text
#      ea-podman already reported by comparing the last line it captured, so
#      anything ea-podman prints after podman's error would defeat that and the
#      text would appear twice. The unit tests mocked that away.
#   B. `ea-podman install` from the CLI on the same full disk fails, names the
#      cause, and leaves nothing registered or on disk behind.
#   C. THE NEGATIVE CONTROL. The same application, unmounted and remounted on a
#      large filesystem, deploys successfully and serves. Without it a failure
#      in A could be anything; with it the small filesystem is the only variable.
#      It also proves a failed first install left the staged source intact for a
#      retry.
#   D. AN INTERRUPT DURING `podman create` STILL RUNS THE CLEANUP. A `podman`
#      shim makes create sleep; SIGINT (to the process group, like Ctrl-C),
#      SIGTERM and SIGHUP (to ea-podman alone) are then sent. ea-podman must exit,
#      report the failed create, and leave no container directory, registration
#      or sleeping podman. The unit tests pin the signal dispositions; only a
#      real box shows the install's cleanup actually running afterwards. Runs
#      after C because it needs the big filesystem. (The upgrade rollback is
#      the same code path as the install cleanup once create returns false, and
#      is covered by the unit tests, not here.)
#
# WHICH LOG "THE DEPLOY LOG" IS
#
# The deploy task writes ~/.cpanel/logs/<epoch>-deploy-<name>.log, and that is the
# file the SSE stream tails and the UI shows while a deploy runs. It is NOT what
# WebApp::fetch_logs reads: that returns app.log or the build container's
# build-<deploy_id>.log, which exists only if the build container ran. A first
# deploy that fails while provisioning never gets that far, so fetch_logs has
# nothing for it (CPANEL-55804's ticket assumed otherwise). This file therefore
# reads the task log directly and reports what fetch_logs returned, without
# asserting on it.
#
# WHAT IT DELIBERATELY DOES NOT PROVE
#
#   * The upgrade and rollback path. Live, the failed create and the rollback's
#     create both die with the same out-of-space error, so a test cannot tell
#     the first failure from the second. The unit tests cover it with distinct
#     outputs (t/SOURCES-util-create-failure-output.t).
#   * The UI panel, and the live SSE stream. It reads the file the stream tails;
#     nothing here renders a page or opens the stream.
#   * A real disk quota (EDQUOT). See above.
#
# RUN IT
#
# Neither branch is packaged yet, so test the working trees, not packages. The
# ea-podman CLI is a COMPILED BINARY that embeds util.pm, and the plugin's
# modules are real files on a VM (symlinks only on a dev box), so copying files
# by hand tests the OLD code and the results say nothing about your diff. Use the
# harness; it recompiles the binary and states which copy is under test:
#
#     # from the ea-podman checkout, EA4-335-ea-podman
#     scp t/LiveTests/setup-remote-live.pl t/LiveTests/ea4-335-create-failure-live.t root@VM:/root/
#     rsync -a --delete ./ root@VM:/root/ea-podman/
#     # from the cpanel-plugins checkout, ZC-CPANEL-55804
#     rsync -a --delete ./ root@VM:/root/plugins/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl \
#         --ea-podman=/root/ea-podman --plugin=/root/plugins --deploy'
#     ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/ea4-335-create-failure-live.t'
#
# `prove -v` because a deploy pulls a ~1 GB node image and without -v there is no
# output until it finishes.
#
# WHAT THE BOX NEEDS
#
#   * a disposable, LICENSED cPanel VM on CGROUP V2 (AlmaLinux 9/10), root SSH
#   * internet access to docker.io. An unauthenticated pull that hits Docker
#     Hub's rate limit is detected and SKIPS the rest with that reason rather
#     than failing for a reason that is not ours.
#   * about 4 GB free on the filesystem holding /root (the loop images are
#     sparse and the large one only fills as the node image lands) and free
#     space in /var/tmp, where podman stages image blobs
#   * losetup, mkfs.ext4, mount, umount, zip, podman
#   * SELinux not enforcing (cPanel boxes normally have it off)
#
# CODE UNDER TEST IS CHECKED, NOT ASSUMED
#
# After EAPODMAN_LIVE=1 is set, a missing code marker is a FAILURE (BAIL_OUT),
# never a skip -- a skip reads as green in an automated run and this file's whole
# value is telling you the change is present and working. Markers are asked of
# the thing that runs: the library AND the compiled binary for ea-podman, the
# installed modules for the plugin.
#
# The expectation that ea-podman itself reports the cause is derived from those
# markers, never from the behaviour being tested, so a broken new ea-podman
# cannot pass as an old one. To test the plugin's FALLBACK against an OLDER
# ea-podman (the plugin must keep working when ea-podman has not been updated),
# install an older ea-podman on the VM and set E2E335_EXPECT_OLD_EAPODMAN=1.
#
# MUST NOT INTERLEAVE WITH ea4-325-upgrade-live.t or cpanel-54868-e2e-live.t:
# they run `remove_containers --all` as root and take server-wide state. Run one,
# then `setup-remote-live.pl --check-clean`, then the other.
#
# DESTRUCTIVE, THROWAWAY VM ONLY. Creates a cPanel account, a package and a
# feature list, kills that account's processes, and mounts loop filesystems over
# its container storage. All of it is removed at the end unless E2E335_KEEP=1.
#
# ENVIRONMENT
#
#   EAPODMAN_LIVE=1                required opt-in (directory convention)
#   E2E335_STORE_MB                size of the small filesystem (default 96)
#   E2E335_BIG_MB                  size of the control filesystem (default 3072)
#   E2E335_NODE_TAG                node runtime tag: 20, 22 or 24 (default 22)
#   E2E335_DEPLOY_TIMEOUT          seconds to wait for a deploy (default 900)
#   E2E335_EXPECT_OLD_EAPODMAN=1   the box has an ea-podman WITHOUT this change;
#                                  assert the plugin's fallback instead
#   E2E335_KEEP=1                  leave the account, mounts and files in place
#   E2E335_SKIP_BINARY_CHECK=1     do not grep the compiled binary for the marker
#                                  (use only if you have verified it another way)
#
# ON FAILURE this file prints the full deploy log, the graphroot, df, the mount
# table and which copies were under test, so one run gives you enough to
# diagnose without another trip to the box.

use strict;
use warnings;

use Test::More;
use File::Path ();
use IPC::Open3 ();
use Symbol     ();

my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $UAPI      = '/usr/local/cpanel/bin/uapi';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman/util.pm';
my $EAP_BIN   = '/opt/cpanel/ea-podman/bin/ea-podman';
my $PLUGIN_PM = '/usr/local/cpanel/Cpanel/WebApps/Podman.pm';
my $DEPLOY_PM = '/usr/local/cpanel/Cpanel/WebApps/Deploy.pm';

my $STORE_MB  = $ENV{E2E335_STORE_MB} || 96;
my $BIG_MB    = $ENV{E2E335_BIG_MB}   || 3072;
my $NODE_TAG  = $ENV{E2E335_NODE_TAG} || '22';
my $TIMEOUT   = $ENV{E2E335_DEPLOY_TIMEOUT} || 900;
my $EXPECT_OLD = $ENV{E2E335_EXPECT_OLD_EAPODMAN} ? 1 : 0;

my $SLUG     = 'e2e335';
my $CLI_NAME = 'e335cli';
my $IMAGE    = "docker.io/library/node:$NODE_TAG";

# The sentence both halves use for a full disk, and the two spellings of podman's
# own words for it (ENOSPC and EDQUOT).
my $HINT_RE  = qr/run out of disk space or reached its disk quota/;
my $PODMAN_ERROR_RE = qr/\bError: .*(?:no space left on device|disk quota exceeded)/;

#=============================================================================
# Guards. Each one names what is missing, because "skipped" with no reason
# sends the next person to debug cPanel when the fault was the box.
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

for my $bin (qw(podman zip losetup mkfs.ext4 mount umount df pkill)) {
    plan skip_all => "$bin is not installed" if !in_path($bin);
}
plan skip_all => "whmapi1 not found ($WHMAPI)"                        if !-x $WHMAPI;
plan skip_all => "uapi not found ($UAPI)"                             if !-x $UAPI;
plan skip_all => "ea-podman is not installed"                         if !-e $EAP_LIB || !-e $EAP_BIN;
plan skip_all => "the webapp plugin is not installed (no $PLUGIN_PM)" if !-e $PLUGIN_PM || !-e $DEPLOY_PM;
plan skip_all => 'this box is on cgroup v1; the webapp plugin needs the v2 hierarchy'
  if !-e '/sys/fs/cgroup/cgroup.controllers';

# A loop filesystem the account cannot write to would fail for the wrong reason.
if ( in_path('getenforce') ) {
    my $mode = `getenforce 2>/dev/null`;
    plan skip_all => 'SELinux is enforcing; the loop-mounted storage would be unwritable for the wrong reason'
      if defined $mode && $mode =~ /Enforcing/i;
}

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

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# As the account, with the rootless session's environment set by hand. `su`
# leaves the caller's cwd in place, which the cpuser often cannot enter.
sub as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "
      . "HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "unset QUERY_STRING REQUEST_METHOD; $env $cmd" );
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

sub uapi_ok  { my ($j) = @_; return $j && $j->{result} && $j->{result}{status} ? 1 : 0; }
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

#=============================================================================
# Is the code under test present? A FAILURE if not, never a skip.
#=============================================================================

sub marker_in_file {
    my ( $file, $marker ) = @_;
    return slurp($file) =~ /\Q$marker\E/ ? 1 : 0;
}

# The compiled binary embeds util.pm; ask it, not just the library next to it.
sub marker_in_binary {
    my ($marker) = @_;
    my ( $rc, $out ) = run_cmd( 'grep', '-a', '-c', $marker, $EAP_BIN );
    return ( $rc == 0 && $out =~ /^[1-9]/ ) ? 1 : 0;
}

my %UNDER_TEST;

sub check_marker {
    my ( $what, $has, $want ) = @_;
    $UNDER_TEST{$what} = $has ? 'has the change' : 'does NOT have the change';
    return if $has == $want;
    BAIL_OUT( "$what " . ( $has ? 'has' : 'does not have' ) . " the EA4-335/CPANEL-55804 change but this run expects " . ( $want ? 'it' : 'the older code' )
          . ". Refusing to run: the results would describe code you are not looking at. "
          . "Deploy the working trees with setup-remote-live.pl --deploy (which recompiles the ea-podman binary), "
          . ( $EXPECT_OLD ? 'or unset E2E335_EXPECT_OLD_EAPODMAN.' : 'or set E2E335_EXPECT_OLD_EAPODMAN=1 if you meant the older ea-podman.' ) );
}

my $WANT_NEW_EAP = $EXPECT_OLD ? 0 : 1;

check_marker( "ea-podman library ($EAP_LIB)", marker_in_file( $EAP_LIB, '_podman_create_captured' ), $WANT_NEW_EAP );
check_marker( "ea-podman binary ($EAP_BIN)",  marker_in_binary('_podman_create_captured'),            $WANT_NEW_EAP )
  if !$ENV{E2E335_SKIP_BINARY_CHECK};
check_marker( "ea-podman library ($EAP_LIB) interrupt handling", marker_in_file( $EAP_LIB, 'while podman was creating the container' ), $WANT_NEW_EAP );
check_marker( "ea-podman binary ($EAP_BIN) interrupt handling", marker_in_binary('while podman was creating the container'),            $WANT_NEW_EAP )
  if !$ENV{E2E335_SKIP_BINARY_CHECK};
check_marker( "plugin Podman.pm ($PLUGIN_PM)", marker_in_file( $PLUGIN_PM, '_quietly_explaining' ), 1 );
check_marker( "plugin Deploy.pm ($DEPLOY_PM)", marker_in_file( $DEPLOY_PM, '_log_failure_hint' ),  1 );

note_both( "code under test: $_ -- $UNDER_TEST{$_}" ) for sort keys %UNDER_TEST;
note_both( 'expecting ea-podman ' . ( $WANT_NEW_EAP ? 'WITH' : 'WITHOUT' ) . ' the change' );

#=============================================================================
# State to clean up, and diagnostics on failure
#=============================================================================

my ( $USER, $HOME, $GRAPHROOT, $PKG, $FEATURELIST );
my ( $SMALL_IMG, $BIG_IMG, $MOUNTED );
my $LAST_BUILD_LOG = '';

sub kill_user_processes {
    my ($user) = @_;
    return if !length( $user // '' );

    # Rootless podman keeps its mounts in a pause process's namespace; a mount
    # added under a live one may be invisible to it.
    run_cmd( 'pkill', '-KILL', '-u', $user );
    sleep 2;
    return;
}

sub unmount_graphroot {
    return if !$MOUNTED;
    kill_user_processes($USER);
    my ( $rc ) = run_cmd( 'umount', $GRAPHROOT );
    ( $rc ) = run_cmd( 'umount', '-l', $GRAPHROOT ) if $rc != 0;
    $MOUNTED = 0 if $rc == 0;
    return $rc == 0 ? 1 : 0;
}

sub dump_state {
    my ($why) = @_;
    print "#\n# ===== DIAGNOSTICS ($why) =====\n";
    print "# code under test:\n", map { "#   $_ -- $UNDER_TEST{$_}\n" } sort keys %UNDER_TEST;
    print "# user: " . ( $USER // 'none' ) . "  home: " . ( $HOME // 'none' ) . "  graphroot: " . ( $GRAPHROOT // 'unknown' ) . "\n";
    if ( length( $GRAPHROOT // '' ) ) {
        my ( undef, $df ) = run_cmd( 'df', '-h', $GRAPHROOT );
        print "# df -h $GRAPHROOT:\n", ( map { "#   $_\n" } split /\n/, $df );
    }
    my ( undef, $mounts ) = run_cmd( 'bash', '-c', "grep -E 'loop|e335|e2e' /proc/mounts" );
    print "# mounts:\n", ( map { "#   $_\n" } split /\n/, $mounts );
    my ( undef, $tmpdf ) = run_cmd( 'df', '-h', '/var/tmp' );
    print "# df -h /var/tmp:\n", ( map { "#   $_\n" } split /\n/, $tmpdf );
    print "# last deploy log:\n", ( map { "#   $_\n" } split /\n/, $LAST_BUILD_LOG );
    print "# ===== END DIAGNOSTICS =====\n";
    return;
}

END {
    my $passing = Test::More->builder->is_passing;
    my $ran     = Test::More->builder->current_test;

    dump_state('a test failed') if $ran && !$passing && ( $USER // '' ) ne '';

    if ( $ENV{E2E335_KEEP} ) {
        print "# E2E335_KEEP set: account '" . ( $USER // '' ) . "', mounts and images left in place\n" if $USER;
    }
    elsif ( defined $USER ) {
        unmount_graphroot();
        for my $img ( grep { defined && -e } ( $SMALL_IMG, $BIG_IMG ) ) { unlink $img; }

        kill_user_processes($USER);
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );

        if ( length( $PKG // '' ) ) {
            my ($j) = whmapi( 'killpkg', "pkgname=$PKG" );
            unlink "/var/cpanel/packages/$PKG" if -e "/var/cpanel/packages/$PKG";    # killpkg is broken on some builds
        }
        if ( length( $FEATURELIST // '' ) ) {
            whmapi( 'delete_featurelist', "featurelist=$FEATURELIST" );
            unlink "/var/cpanel/features/$FEATURELIST" if -e "/var/cpanel/features/$FEATURELIST";
        }
        print "# removed throwaway account '$USER', its package and feature list\n";
    }
}

#=============================================================================
# Account: a package whose feature list enables the webapp feature.
#
# `webapp` is an addon feature and is off in the stock default list; a list made
# by create_featurelist writes every unspecified feature as 0, so subdomains
# (plural -- that is the one hasfeature() checks) has to be turned on too or
# every deploy dies creating its subdomain.
#=============================================================================

{
    my $suffix = substr( time, -5 );
    $USER        = "e335$suffix";
    $FEATURELIST = "e2e335fl$suffix";
    $PKG         = "e2e335pkg$suffix";

    note_both("Creating throwaway account '$USER' ...");

    my ( $fl, $flrc, $flraw ) = whmapi( 'create_featurelist', "featurelist=$FEATURELIST", 'webapp=1', 'subdomains=1' );
    if ( !whm_ok($fl) ) {
        my $why = ( $fl && $fl->{metadata}{reason} ) || "exit $flrc: " . substr( $flraw, 0, 300 );
        ( $FEATURELIST, $PKG, $USER ) = ();
        plan skip_all => "could not create the feature list: $why";
    }

    my @pkg = ( 'addpkg', "name=$PKG", "featurelist=$FEATURELIST", 'quota=unlimited' );

    # The resource-limit package extension exists only on newer plugins; try
    # with it, and without if the server does not know it.
    my ( $pk, $pkrc, $pkraw ) = whmapi( @pkg, '_PACKAGE_EXTENSIONS=webapp-limits', 'WEBAPP_MAX_APPS=10' );
    ( $pk, $pkrc, $pkraw ) = whmapi(@pkg) if !whm_ok($pk);
    if ( !whm_ok($pk) ) {
        my $why = ( $pk && $pk->{metadata}{reason} ) || "exit $pkrc: " . substr( $pkraw, 0, 300 );
        plan skip_all => "could not create the package: $why";
    }

    # plan= NOT pkg=; `pkg=` is silently ignored and the account lands on
    # `default`. hasshell=1 NOT shell=; the latter is ignored.
    my ( $acct, $acrc, $acraw ) = whmapi(
        'createacct',
        "username=$USER",
        "domain=$USER.e2e335.test",
        'password=E2e' . $suffix . '!Qx9z',
        "plan=$PKG",
        'hasshell=1',
    );
    if ( !whm_ok($acct) ) {
        my $why = ( $acct && $acct->{metadata}{reason} ) || "exit $acrc: " . substr( $acraw, 0, 300 );
        my $u = $USER;
        undef $USER;    # nothing was created, so END has no account to remove
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
# Fixture: a zero-dependency Node app delivered as a zip, so the image pull is
# the only network this test needs. zip rather than git: the git source type
# needs a reachable https/git@ URL, which makes the test depend on a host nobody
# controls. The archive path must be RELATIVE to the account's home.
#=============================================================================

sub write_fixture_zip {
    my $dir = "$HOME/e2e335-src";
    File::Path::remove_tree($dir);
    File::Path::make_path("$dir/app");

    spew( "$dir/app/package.json", qq({"name":"e2e335","version":"1.0.0","private":true,"scripts":{"start":"node server.js"}}\n) );
    spew(
        "$dir/app/server.js", <<'JS'
const http = require('http');
const port = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('E2E335_OK\n');
}).listen(port);
JS
    );

    unlink "$HOME/e2e335-src.zip";
    my ( $rc, $out, $err ) = run_cmd( 'bash', '-c', 'cd ' . _sh("$dir/app") . ' && zip -q -r ' . _sh("$HOME/e2e335-src.zip") . ' .' );
    die "could not build the fixture zip: $out$err\n" if $rc != 0;

    run_cmd( 'chown', '-R', "$USER:$USER", "$HOME/e2e335-src.zip", $dir );
    return 'e2e335-src.zip';
}

#=============================================================================
# Storage: mount a loop filesystem where the account's rootless podman keeps its
# images.
#=============================================================================

# Where podman really keeps its store for this account. Asked of podman, not
# assumed, because storage.conf can move it -- but the default is used when the
# question cannot be answered (a brand-new account has no user session yet).
sub find_graphroot {
    my ( $rc, $out ) = as_user( $USER, q{podman info --format '{{.Store.GraphRoot}}' 2>/dev/null} );
    my ($path) = grep { m{^/} } reverse split /\n/, ( $out // '' );
    $path = "$HOME/.local/share/containers/storage" if !length( $path // '' );

    die "graphroot '$path' is not under $HOME; refusing to mount over it\n" if index( $path, "$HOME/" ) != 0;
    return $path;
}

sub make_fs {
    my ( $img, $mb ) = @_;
    unlink $img;
    my ($rc, $out, $err) = run_cmd( 'truncate', '-s', "${mb}M", $img );
    die "truncate $img: $out$err\n" if $rc != 0;
    ( $rc, $out, $err ) = run_cmd( 'mkfs.ext4', '-q', '-F', '-m', '0', $img );
    die "mkfs.ext4 $img: $out$err\n" if $rc != 0;
    return;
}

sub mount_graphroot {
    my ($img) = @_;

    kill_user_processes($USER);
    run_cmd( 'su', '-s', '/bin/bash', $USER, '-c', 'mkdir -p ' . _sh($GRAPHROOT) );

    my ( $rc, $out, $err ) = run_cmd( 'mount', '-o', 'loop', $img, $GRAPHROOT );
    die "mount $img on $GRAPHROOT failed: $out$err\n" if $rc != 0;
    $MOUNTED = 1;

    run_cmd( 'chown', "$USER:$USER", $GRAPHROOT );
    run_cmd( 'chmod', '0700', $GRAPHROOT );
    return;
}

# The account's own view of the path, so a mount its processes cannot see is
# caught here rather than showing up as a deploy that mysteriously succeeded.
sub account_sees_loop {
    my ( $rc, $out ) = as_user( $USER, 'df --output=source ' . _sh($GRAPHROOT) . ' 2>&1' );
    return $out =~ m{/dev/loop} ? 1 : 0;
}

#=============================================================================
# Deploy plumbing
#=============================================================================

sub app_record {
    my ($json) = webapp( $USER, 'list' );
    return undef if !uapi_ok($json);
    for my $app ( @{ $json->{result}{data} || [] } ) {
        return $app if ( $app->{name} // '' ) eq $SLUG;
    }
    return undef;
}

# A deploy is queued and returns immediately. Wait for a RESULT, not just for
# the status to leave 'deploying' -- straight after the call the record can still
# show the previous state.
sub wait_for_result {
    my ($previous_id) = @_;
    my $deadline = time + $TIMEOUT;

    while ( time < $deadline ) {
        my $app = app_record();
        my $last = $app && ref $app->{last_deploy} eq 'HASH' ? $app->{last_deploy} : {};
        if ( $app && ( $app->{status} // '' ) ne 'deploying' && length( $last->{result} // '' ) && ( $last->{deploy_id} // '' ) ne ( $previous_id // '' ) ) {
            return ( $app, $last );
        }
        sleep 5;
    }

    my $app = app_record();
    return ( $app, ( $app && ref $app->{last_deploy} eq 'HASH' ) ? { %{ $app->{last_deploy} }, result => 'timeout' } : { result => 'timeout' } );
}

# The deploy task's own log: ~/.cpanel/logs/<epoch>-deploy-<name>.log, the newest
# one. This is what the SSE stream tails. (WebApp::fetch_logs does not read it.)
sub deploy_log_lines {
    my @files = sort { ( stat($b) )[9] <=> ( stat($a) )[9] } glob("$HOME/.cpanel/logs/*-deploy-$SLUG.log");
    return [] if !@files;
    my @lines = split /\n/, slurp( $files[0] );
    return \@lines;
}

# What fetch_logs says for a deploy. Reported, never asserted on: it reads the
# build container's log, which a provisioning failure never produces.
sub fetch_logs_count {
    my ($deploy_id) = @_;
    my ($json) = webapp( $USER, 'fetch_logs', "name=$SLUG", 'log_type=build', 'lines=1000', ( length( $deploy_id // '' ) ? "deploy_id=$deploy_id" : () ) );
    return 'n/a' if !uapi_ok($json);
    my $lines = $json->{result}{data}{lines};
    return ref $lines eq 'ARRAY' ? scalar @$lines : 0;
}

sub count_matching {
    my ( $re, @lines ) = @_;
    return scalar grep { $_ =~ $re } @lines;
}

#=============================================================================
# Stage A -- a Web App deploy on a full disk says why
#=============================================================================

my $ARCHIVE;
my $RATE_LIMITED = 0;
my $LAST_ID;

subtest 'A: a deploy on a full disk fails as build_failed and its log says why' => sub {
    $ARCHIVE = write_fixture_zip();
    $GRAPHROOT = find_graphroot();
    note_both("graphroot: $GRAPHROOT");

    $SMALL_IMG = "/root/e2e335-small-$USER.img";
    $BIG_IMG   = "/root/e2e335-big-$USER.img";
    make_fs( $SMALL_IMG, $STORE_MB );
    mount_graphroot($SMALL_IMG);

    ok( account_sees_loop(), "the account sees its container storage on the ${STORE_MB} MB loop filesystem" )
      or return plan_fatal("the loop mount is not visible to the account; nothing below is meaningful");

    my ($staged) = webapp( $USER, 'stage', "name=$SLUG", 'source_type=zip', "source=$ARCHIVE", 'runtime=nodejs', "runtime_tag=$NODE_TAG" );
    ok( uapi_ok($staged), 'WebApp::stage succeeds' ) or return plan_fatal( 'stage failed: ' . uapi_why($staged) );

    my ($configured) = webapp( $USER, 'configure', "name=$SLUG", 'startup_command=npm run start' );
    ok( uapi_ok($configured), 'WebApp::configure succeeds' ) or note_both( uapi_why($configured) );

    my ($deployed) = webapp( $USER, 'deploy', "name=$SLUG" );
    ok( uapi_ok($deployed), 'WebApp::deploy is accepted' ) or return plan_fatal( 'deploy not accepted: ' . uapi_why($deployed) );

    my ( $app, $last ) = wait_for_result('');
    $LAST_ID = $last->{deploy_id};
    my @lines = @{ deploy_log_lines() };
    $LAST_BUILD_LOG = join( "\n", @lines );
    note_both( 'WebApp::fetch_logs(build) returned ' . fetch_logs_count($LAST_ID) . ' line(s) for this failed deploy (it reads the build container log, not the task log)' );

    if ( $LAST_BUILD_LOG =~ /toomanyrequests|rate limit/i ) {
        $RATE_LIMITED = 1;
        note_both('Docker Hub rate-limited this box; the image never started to unpack, so this proves nothing. Skipping.');
        return plan_fatal_skip('registry rate limit');
    }

    isnt( $last->{result}, 'success', 'the deploy did NOT succeed on a filesystem smaller than the image' )
      or return plan_fatal('the deploy succeeded on the small filesystem: podman is not using the mounted path');
    is( $last->{result}, 'failure', 'it failed rather than timing out' );
    is( $last->{error_category} // '', 'build_failed', 'and the category is still build_failed, for callers that only check it' );

    cmp_ok( scalar @lines, '>', 0, 'the deploy task wrote a log' );
    cmp_ok( count_matching( qr/Could not provision the container \(build_failed\)/, @lines ), '==', 1, 'the original "Could not provision" line is there once' );

    is( count_matching( $HINT_RE, @lines ), 1, 'a plain-words sentence names the account being out of disk space or quota -- exactly once' );

    # THE live-only risk. This line is on the second-or-later line of a
    # multi-line message, so finding it also proves the log keeps the
    # continuation lines.
    is( count_matching( $PODMAN_ERROR_RE, @lines ), 1, "podman's own error line is in the log -- exactly once" )
      or note_both('a count of 2 means the text was appended twice: ea-podman printed something AFTER podman\'s error, defeating the last-line duplicate check');

    my ( undef, $df ) = run_cmd( 'df', '-h', $GRAPHROOT );
    note_both("evidence -- the account's storage after the failed deploy:\n$df");

    return;
};

sub plan_fatal      { my ($why) = @_; note_both("cannot continue: $why"); $RATE_LIMITED = 2; fail($why); return; }
sub plan_fatal_skip { my ($why) = @_; $RATE_LIMITED = 1; pass("skipped: $why"); return; }

#=============================================================================
# Stage B -- `ea-podman install` from the CLI on the same full disk
#=============================================================================

subtest 'B: `ea-podman install` on a full disk names the cause and leaves nothing behind' => sub {
    if ( $RATE_LIMITED || !$MOUNTED ) {
        pass('skipped: stage A did not establish a full disk');
        return;
    }

    my ( $rc, $out ) = as_user(
        $USER,
        "/opt/cpanel/ea-podman/bin/ea-podman install $CLI_NAME --i-understand-the-risks-do-it-anyway --cpuser-port=80 " . _sh($IMAGE) . " 2>&1"
    );
    $LAST_BUILD_LOG .= "\n--- CLI install output ---\n$out";

    if ( $out =~ /toomanyrequests|rate limit/i ) {
        pass('skipped: registry rate limit');
        return;
    }

    isnt( $rc, 0, 'the install fails' );
    like( $out, qr/Failed to create container/, 'and still says "Failed to create container"' );

    # podman's own words are always visible on a terminal (the CLI tees them), so
    # this holds for an old ea-podman too -- it is the deliberate double-print.
    like( $out, $PODMAN_ERROR_RE, "podman's error is shown" );

    if ($WANT_NEW_EAP) {
        like( $out, $HINT_RE,               'ea-podman itself names the disk space or quota as the cause' );
        like( $out, qr/podman reported:/,   'and says what podman reported' );
    }
    else {
        unlike( $out, qr/podman reported:/, 'the older ea-podman adds nothing (this run expects the older code)' );
    }

    my @left = glob("$HOME/ea-podman.d/${CLI_NAME}*");
    is( scalar @left, 0, 'no container directory is left behind' ) or note_both( 'left: ' . join( ', ', @left ) );

    my ( undef, $list ) = as_user( $USER, '/opt/cpanel/ea-podman/bin/ea-podman list 2>&1' );
    unlike( $list, qr/\Q$CLI_NAME\E/, 'and nothing is registered' );

    return;
};

#=============================================================================
# Stage C -- THE NEGATIVE CONTROL. The same application, on a big filesystem.
#=============================================================================

subtest 'C: the same application deploys once the filesystem is big enough' => sub {
    if ( $RATE_LIMITED ) {
        pass('skipped: stage A did not establish a full disk');
        return;
    }

    ok( unmount_graphroot(), 'the small filesystem is unmounted' ) or return;
    make_fs( $BIG_IMG, $BIG_MB );
    mount_graphroot($BIG_IMG);
    ok( account_sees_loop(), "the account sees the ${BIG_MB} MB filesystem" ) or return;

    # The same application, same staged source: it must still be there after a
    # failed first install, which is the point of the install's rollback.
    ok( defined app_record(), 'the application is still registered after the failed deploy' );

    my ($redeployed) = webapp( $USER, 'deploy', "name=$SLUG" );
    ok( uapi_ok($redeployed), 'WebApp::deploy is accepted again' ) or return note_both( uapi_why($redeployed) );

    my ( $app, $last ) = wait_for_result($LAST_ID);
    my @lines = @{ deploy_log_lines() };
    $LAST_BUILD_LOG = join( "\n", @lines );

    if ( $LAST_BUILD_LOG =~ /toomanyrequests|rate limit/i ) {
        pass('skipped: registry rate limit on the control pull');
        return;
    }

    is( $last->{result}, 'success', 'the deploy succeeds -- the small filesystem was the only difference' );
    unlike( $LAST_BUILD_LOG, $HINT_RE, 'and the log carries no out-of-space message' );

    my $port = $app && $app->{container_name} ? _host_port( $app->{container_name} ) : '';
    ok( length $port, 'the container has a published host port' );
    if ( length $port ) {
        my ( $crc, $body ) = run_cmd( 'curl', '-s', '--max-time', '15', "http://127.0.0.1:$port/" );
        like( $body, qr/E2E335_OK/, 'and it serves the application' );
    }

    return;
};

#=============================================================================
# Stage D -- an interrupt during `podman create` still runs the install cleanup
#
# The create is made slow and deterministic with a `podman` shim first in the
# account's PATH: every subcommand goes to the real podman except `create`, which
# announces itself and then sleeps (exec, so a signal reaches the sleeper and not
# a shell that would leave it holding the output pipe). Needs the big filesystem
# from stage C, because the image has to pull for the install to get as far as
# create -- on the full disk it never does.
#
#   INT   goes to the whole process group, as a terminal's Ctrl-C does
#   TERM  goes to ea-podman ALONE, as `kill` does; HUP likewise
#
# For each: ea-podman must exit non-zero, having reported the failed create (which
# proves it survived long enough to run its own error path), and must leave no
# container directory, no registration and no sleeping shim behind.
#=============================================================================

sub _start_interruptible_install {
    my ($shim) = @_;

    my $cmd = "rm -f $HOME/e2e335-create-started $HOME/e2e335-install.pid $HOME/e2e335-install.out; "
      . "PATH=" . _sh($shim) . ":\$PATH setsid bash -c "
      . _sh( "echo \$\$ > $HOME/e2e335-install.pid; exec /opt/cpanel/ea-podman/bin/ea-podman install $CLI_NAME --i-understand-the-risks-do-it-anyway --cpuser-port=80 " . _sh($IMAGE) )
      . " > $HOME/e2e335-install.out 2>&1 < /dev/null &";
    as_user( $USER, $cmd );
    return;
}

sub _wait_for {
    my ( $timeout, $test ) = @_;
    my $deadline = time + $timeout;
    while ( time < $deadline ) {
        return 1 if $test->();
        sleep 1;
    }
    return $test->() ? 1 : 0;
}

subtest 'D: an interrupt during create still runs the install cleanup' => sub {
    if ( $RATE_LIMITED || !$MOUNTED ) {
        pass('skipped: stage A did not establish a working filesystem');
        return;
    }
    if ($EXPECT_OLD) {
        pass('skipped: this run expects the older ea-podman, which has no interrupt handling');
        return;
    }
    if ( !-x '/usr/bin/podman' ) {
        pass('skipped: no /usr/bin/podman for the shim to hand off to');
        return;
    }

    my $shim = "$HOME/e2e335-shim";
    File::Path::make_path($shim);
    spew(
        "$shim/podman", <<'SH'
#!/bin/sh
if [ "$1" = create ]; then
    : > "$HOME/e2e335-create-started"
    exec sleep 300
fi
exec /usr/bin/podman "$@"
SH
    );
    chmod 0755, "$shim/podman";
    run_cmd( 'chown', '-R', "$USER:$USER", $shim );

    for my $case ( [ 'INT', 'the whole process group (a terminal Ctrl-C)' ], [ 'TERM', 'ea-podman alone (kill)' ], [ 'HUP', 'ea-podman alone (hangup)' ] ) {
        my ( $sig, $how ) = @{$case};

        _start_interruptible_install($shim);

        my $started = _wait_for( $TIMEOUT, sub { -e "$HOME/e2e335-create-started" } );
        if ( !$started ) {
            $LAST_BUILD_LOG = slurp("$HOME/e2e335-install.out");
            if ( $LAST_BUILD_LOG =~ /toomanyrequests|rate limit/i ) {
                pass("SIG$sig: skipped, registry rate limit before create was reached");
                next;
            }
            fail("SIG$sig: the install reached `podman create` (through the shim)");
            note_both("install output so far:\n$LAST_BUILD_LOG");
            run_cmd( 'pkill', '-KILL', '-u', $USER, '-x', 'sleep' );
            next;
        }

        chomp( my $pid = slurp("$HOME/e2e335-install.pid") );
        ok( $pid =~ /^\d+$/ && kill( 0, $pid ), "SIG$sig: ea-podman is running, in its own session" ) or next;

        # A negative pid signals the whole process group, which setsid made the pid.
        kill( $sig, $sig eq 'INT' ? -$pid : $pid );
        note_both("sent SIG$sig to $how");

        my $gone = _wait_for( 60, sub { !kill( 0, $pid ) } );
        ok( $gone, "SIG$sig: ea-podman exits instead of hanging on the sleeping podman" );
        kill( 'KILL', -$pid ) if !$gone;

        my $out = slurp("$HOME/e2e335-install.out");
        $LAST_BUILD_LOG = $out;
        like( $out, qr/Failed to create container/, "SIG$sig: it reached its own failed-create path, so cleanup ran" );
        like( $out, qr/interrupted \(SIG$sig\)/,     "SIG$sig: and said what interrupted it" ) if $sig ne 'INT';

        my @left = glob("$HOME/ea-podman.d/${CLI_NAME}*");
        is( scalar @left, 0, "SIG$sig: no container directory is left behind" ) or note_both( 'left: ' . join( ', ', @left ) );

        my ( undef, $list ) = as_user( $USER, '/opt/cpanel/ea-podman/bin/ea-podman list 2>&1' );
        unlike( $list, qr/\Q$CLI_NAME\E/, "SIG$sig: and nothing is registered" );

        my ($prc) = run_cmd( 'pgrep', '-u', $USER, '-x', 'sleep' );
        isnt( $prc, 0, "SIG$sig: and no sleeping podman shim is left running" );
        run_cmd( 'pkill', '-KILL', '-u', $USER, '-x', 'sleep' );
    }

    return;
};

sub _host_port {
    my ($container) = @_;
    my ( $rc, $out ) = as_user( $USER, 'podman inspect --format ' . _sh('{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}') . ' ' . _sh($container) . ' 2>/dev/null' );
    chomp( $out //= '' );
    return $rc == 0 ? $out : '';
}

done_testing();
