#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/cpanel-57608-quota-redeploy-live.t
#                                                  Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# CPANEL-57608 / CPANEL-57512 -- a Web App whose first deploy failed on a disk
# quota redeploys cleanly once the quota is lifted, end to end, on a real box.
#
# WHY THIS FILE EXISTS
#
# _ensure_latest_container() reserves the host port before `podman create`. When
# a first install failed, the cleanup deregistered the container but never gave
# the port back. The retry got the same .01 name, reserved a second port under
# it, and the Web App proxy was wired to the first one, which nothing listens on:
# the redeploy reported success and the site answered 503.
#
# This is the reproduction from CPANEL-57512, literally: a REAL cPanel disk quota
# (EDQUOT, "disk quota exceeded"), not the full loop filesystem (ENOSPC) that
# ea4-335-create-failure-live.t uses as a stand-in.
#
# WHAT IT PROVES
#
#   A. With the account's quota set just above its usage, a deploy fails AT
#      `podman create` with "disk quota exceeded", and the account holds NO
#      reserved port afterwards. The log check is what makes the port count mean
#      anything: a failure before ea-podman reserved a port would leave none
#      either, on any version.
#   B. With the quota lifted, the same application redeploys, the account holds
#      exactly ONE port, it is the port podman published and the one the proxy is
#      wired to, and Apache serves the application.
#
# BEFORE AND AFTER
#
# The port counts tell the versions apart; the Apache request may not. A plugin
# with CPANEL-57609 wires the proxy to the port podman published, so it serves
# even on a leaky ea-podman. The plugin build is reported for that reason.
#
#                               ea-podman 1.0-32 (bug)   1.0-33 (fix)
#     ports after A                     1                     0
#     ports after B                     2                     1
#
# With E2E57608_EXPECT_OLD_EAPODMAN=1 the file asserts the leak instead, so a run
# against 1.0-32 that passes shows the test reproduces the bug -- rather than a
# red run that might only mean the setup broke.
#
# RUN IT
#
#     scp t/LiveTests/setup-remote-live.pl t/LiveTests/cpanel-57608-quota-redeploy-live.t root@VM:/root/
#     # to test a working tree rather than the installed package:
#     rsync -a --delete ./ root@VM:/root/ea-podman/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl --ea-podman=/root/ea-podman --deploy'
#     ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/cpanel-57608-quota-redeploy-live.t'
#
#     # the before run, on a box with ea-podman 1.0-32:
#     ssh root@VM 'EAPODMAN_LIVE=1 E2E57608_EXPECT_OLD_EAPODMAN=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/cpanel-57608-quota-redeploy-live.t'
#
# `prove -v` because a deploy pulls a ~1 GB node image.
#
# WHAT THE BOX NEEDS
#
#   * a disposable, LICENSED cPanel VM on CGROUP V2 (AlmaLinux 9/10) with the
#     Web App plugin installed. The plugin needs the v2 hierarchy, so this skips
#     on cgroup v1, which includes CloudLinux.
#   * DISK QUOTAS ENABLED on the filesystem holding /home. Run /scripts/fixquotas
#     beforehand, and reboot if it says so (an XFS root always needs one). This
#     file never enables quotas; it reads a limit back and skips if none applies.
#   * internet access to docker.io. A rate-limited pull SKIPS with that reason.
#   * the `quota` tool, zip, curl, podman
#
# MUST NOT INTERLEAVE WITH ea4-325-upgrade-live.t or cpanel-54868-e2e-live.t:
# they run `remove_containers --all` as root.
#
# DESTRUCTIVE, THROWAWAY VM ONLY. Creates a cPanel account, a package and a
# feature list, and sets the account's disk quota. All of it is removed at the
# end (removeacct takes the quota with it) unless E2E57608_KEEP=1.
#
# ENVIRONMENT
#
#   EAPODMAN_LIVE=1                  required opt-in (directory convention)
#   E2E57608_QUOTA_HEADROOM_MB       quota above measured usage (default 64)
#   E2E57608_NODE_TAG                node runtime tag: 20, 22 or 24 (default 22)
#   E2E57608_DEPLOY_TIMEOUT          seconds to wait for a deploy (default 900)
#   E2E57608_APACHE_WAIT             seconds to wait for Apache to serve the app
#                                    after the deploy reports success (default 90)
#   E2E57608_EXPECT_OLD_EAPODMAN=1   the box has ea-podman WITHOUT the fix;
#                                    assert the leak instead
#   E2E57608_KEEP=1                  leave the account and files in place

use strict;
use warnings;

use Test::More;
use File::Path ();
use IPC::Open3 ();
use Symbol     ();

my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $UAPI      = '/usr/local/cpanel/bin/uapi';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman/util.pm';
my $PLUGIN_PM = '/usr/local/cpanel/Cpanel/WebApps/Podman.pm';
my $PORT_AUTH = '/scripts/cpuser_port_authority';

my $HEADROOM_MB = $ENV{E2E57608_QUOTA_HEADROOM_MB} || 64;
my $NODE_TAG    = $ENV{E2E57608_NODE_TAG}          || '22';
my $TIMEOUT     = $ENV{E2E57608_DEPLOY_TIMEOUT}    || 900;
my $APACHE_WAIT = $ENV{E2E57608_APACHE_WAIT}      || 90;
my $EXPECT_OLD  = $ENV{E2E57608_EXPECT_OLD_EAPODMAN} ? 1 : 0;

my $SLUG = 'q57608';

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

for my $bin (qw(podman zip curl quota pkill)) {
    plan skip_all => "$bin is not installed" if !in_path($bin);
}
plan skip_all => "whmapi1 not found ($WHMAPI)"                        if !-x $WHMAPI;
plan skip_all => "uapi not found ($UAPI)"                             if !-x $UAPI;
plan skip_all => "$PORT_AUTH not found"                               if !-x $PORT_AUTH;
plan skip_all => "ea-podman is not installed"                         if !-e $EAP_LIB;
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

# As the account, with the rootless session's environment set by hand.
sub as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "
      . "HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "unset QUERY_STRING REQUEST_METHOD; $env $cmd" );
}

#=============================================================================
# Is the code under test present? A mismatch is a BAIL_OUT, never a skip.
#=============================================================================

my $HAS_FIX = slurp($EAP_LIB) =~ /CPANEL-57608/ ? 1 : 0;
my $WANT_FIX = $EXPECT_OLD ? 0 : 1;

if ( $HAS_FIX != $WANT_FIX ) {
    BAIL_OUT( "$EAP_LIB " . ( $HAS_FIX ? 'has' : 'does not have' ) . ' the CPANEL-57608 fix but this run expects ' . ( $WANT_FIX ? 'it' : 'the older code' )
          . '. Refusing to run: the results would describe code you are not looking at. '
          . ( $EXPECT_OLD ? 'Unset E2E57608_EXPECT_OLD_EAPODMAN.' : 'Deploy the fix (setup-remote-live.pl --deploy), or set E2E57608_EXPECT_OLD_EAPODMAN=1 for the before run.' ) );
}

my $PLUGIN_BUILD = do {
    my ( $rc, $out ) = run_cmd( 'rpm', '-qf', $PLUGIN_PM );
    ( $rc, $out ) = run_cmd( 'dpkg', '-S', $PLUGIN_PM ) if $rc != 0;
    chomp( $out //= '' );
    $rc == 0 && length $out ? $out : 'unknown (not from a package?)';
};

note_both( "ea-podman library: $EAP_LIB " . ( $HAS_FIX ? 'HAS' : 'does NOT have' ) . ' the CPANEL-57608 fix' );
note_both("webapp plugin build: $PLUGIN_BUILD");
note_both( 'expecting ' . ( $WANT_FIX ? 'no leaked port' : 'the leak (before run)' ) );

#=============================================================================
# State to clean up, and diagnostics on failure
#=============================================================================

my ( $USER, $HOME, $PKG, $FEATURELIST );
my $LAST_LOG = '';

sub port_assignments {
    my ( undef, $json ) = run_cmd( $PORT_AUTH, 'list', $USER );    # `list root` shows only root's ports
    my $hr = decode_json_or_undef($json);
    return ref $hr eq 'HASH' ? $hr : {};
}

sub describe_ports {
    my $hr = port_assignments();
    return 'none' if !%{$hr};
    return join( ', ', map { "$_ => " . ( $hr->{$_}{service} // '?' ) } sort keys %{$hr} );
}

# Block usage (KiB) summed over every filesystem `quota` reports for the account,
# and the largest hard block limit among them (0 = no limit anywhere).
sub quota_state {
    my ( $rc, $out, $err ) = run_cmd( 'quota', '-w', '-v', '-u', $USER );
    my ( $used, $limit, $rows ) = ( 0, 0, 0 );
    for my $line ( split /\n/, $out ) {
        my @f = split ' ', $line;
        next if @f < 4 || $f[0] !~ m{^/};
        my ($blocks) = $f[1] =~ /^([0-9]+)/ or next;
        $rows++;
        $used += $blocks;
        $limit = $f[3] if $f[3] =~ /^[0-9]+$/ && $f[3] > $limit;
    }
    return { used_kb => $used, limit_kb => $limit, rows => $rows, raw => $out . $err };
}

sub set_quota_mb {
    my ($mb) = @_;
    my ( $j, $rc, $raw ) = whmapi( 'editquota', "user=$USER", "quota=$mb" );
    note_both("editquota quota=$mb did not report success: $raw") if !whm_ok($j);
    return quota_state();
}

sub dump_state {
    my ($why) = @_;
    print "#\n# ===== DIAGNOSTICS ($why) =====\n";
    print "# ea-podman fix present: " . ( $HAS_FIX ? 'yes' : 'no' ) . "   plugin: $PLUGIN_BUILD\n";
    print "# user: " . ( $USER // 'none' ) . "  home: " . ( $HOME // 'none' ) . "\n";
    if ( defined $USER ) {
        print "# reserved ports: " . describe_ports() . "\n";
        my $q = quota_state();
        print "# quota:\n", ( map { "#   $_\n" } split /\n/, $q->{raw} );
        my ( undef, $ps ) = as_user( $USER, 'podman ps -a --format "{{.Names}} {{.Status}} {{.Ports}}" 2>&1' );
        print "# podman ps -a:\n", ( map { "#   $_\n" } split /\n/, $ps );
    }
    print "# last deploy log:\n", ( map { "#   $_\n" } split /\n/, $LAST_LOG );
    print "# ===== END DIAGNOSTICS =====\n";
    return;
}

END {
    my $passing = Test::More->builder->is_passing;
    my $ran     = Test::More->builder->current_test;

    dump_state('a test failed') if $ran && !$passing && ( $USER // '' ) ne '';

    if ( $ENV{E2E57608_KEEP} ) {
        print "# E2E57608_KEEP set: account '" . ( $USER // '' ) . "' left in place\n" if $USER;
    }
    elsif ( defined $USER ) {
        run_cmd( 'pkill', '-KILL', '-u', $USER );
        sleep 2;
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
        print "# removed throwaway account '$USER'\n";
    }
    if ( !$ENV{E2E57608_KEEP} ) {
        if ( length( $PKG // '' ) ) {
            whmapi( 'killpkg', "pkgname=$PKG" );
            unlink "/var/cpanel/packages/$PKG" if -e "/var/cpanel/packages/$PKG";    # killpkg is broken on some builds
        }
        if ( length( $FEATURELIST // '' ) ) {
            whmapi( 'delete_featurelist', "featurelist=$FEATURELIST" );
            unlink "/var/cpanel/features/$FEATURELIST" if -e "/var/cpanel/features/$FEATURELIST";
        }
    }
}

#=============================================================================
# Account: a package whose feature list enables the webapp feature (and
# subdomains, or every deploy dies creating its subdomain).
#=============================================================================

{
    my $suffix = substr( time, -5 );
    $USER        = "q576$suffix";
    $FEATURELIST = "e2e57608fl$suffix";
    $PKG         = "e2e57608pkg$suffix";

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
        "domain=$USER.e2e57608.test",
        'password=Q' . $suffix . '!Zx9e2e',
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
# Fixture: a zero-dependency Node app as a zip, staged and configured BEFORE the
# quota goes on, so the only thing the quota can stop is the image.
#=============================================================================

sub write_fixture_zip {
    my $dir = "$HOME/q57608-src";
    File::Path::remove_tree($dir);
    File::Path::make_path("$dir/app");

    spew( "$dir/app/package.json", qq({"name":"q57608","version":"1.0.0","private":true,"scripts":{"start":"node server.js"}}\n) );
    spew(
        "$dir/app/server.js", <<'JS'
const http = require('http');
const port = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Q57608_OK\n');
}).listen(port);
JS
    );

    unlink "$HOME/q57608-src.zip";
    my ( $rc, $out, $err ) = run_cmd( 'bash', '-c', 'cd ' . _sh("$dir/app") . ' && zip -q -r ' . _sh("$HOME/q57608-src.zip") . ' .' );
    die "could not build the fixture zip: $out$err\n" if $rc != 0;

    run_cmd( 'chown', '-R', "$USER:$USER", "$HOME/q57608-src.zip", $dir );
    return 'q57608-src.zip';
}

{
    my $archive = write_fixture_zip();

    my ($staged) = webapp( $USER, 'stage', "name=$SLUG", 'source_type=zip', "source=$archive", 'runtime=nodejs', "runtime_tag=$NODE_TAG" );
    plan skip_all => 'WebApp::stage failed: ' . uapi_why($staged) if !uapi_ok($staged);

    my ($configured) = webapp( $USER, 'configure', "name=$SLUG", 'startup_command=npm run start' );
    plan skip_all => 'WebApp::configure failed: ' . uapi_why($configured) if !uapi_ok($configured);
}

#=============================================================================
# The quota: measured usage plus headroom, READ BACK. A box without quotas
# accepts editquota and enforces nothing, which would make A pass for nothing.
#=============================================================================

my $QUOTA_MB;
{
    my $before = quota_state();
    plan skip_all => "`quota` reports no filesystem for '$USER': disk quotas are not enabled here. Run /scripts/fixquotas (and reboot if it says so). quota said: $before->{raw}"
      if !$before->{rows};

    $QUOTA_MB = int( $before->{used_kb} / 1024 ) + 1 + $HEADROOM_MB;
    my $after = set_quota_mb($QUOTA_MB);

    plan skip_all => "set a ${QUOTA_MB} MB quota for '$USER' but `quota` shows no limit: disk quotas are not enforced on the filesystem holding $HOME. Run /scripts/fixquotas (and reboot if it says so). quota said: $after->{raw}"
      if !$after->{limit_kb};

    note_both("quota: '$USER' uses $before->{used_kb} KiB; limit set to ${QUOTA_MB} MB, read back as $after->{limit_kb} KiB");
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

# A deploy is queued and returns immediately. Wait for a RESULT newer than the
# previous one, not just for the status to leave 'deploying'.
sub wait_for_result {
    my ($previous_id) = @_;
    my $deadline = time + $TIMEOUT;

    while ( time < $deadline ) {
        my $app  = app_record();
        my $last = $app && ref $app->{last_deploy} eq 'HASH' ? $app->{last_deploy} : {};
        if ( $app && ( $app->{status} // '' ) ne 'deploying' && length( $last->{result} // '' ) && ( $last->{deploy_id} // '' ) ne ( $previous_id // '' ) ) {
            return ( $app, $last );
        }
        sleep 5;
    }

    my $app = app_record();
    return ( $app, ( $app && ref $app->{last_deploy} eq 'HASH' ) ? { %{ $app->{last_deploy} }, result => 'timeout' } : { result => 'timeout' } );
}

# The deploy task's own log, the newest one: ~/.cpanel/logs/<epoch>-deploy-<name>.log
sub deploy_log {
    my @files = sort { ( stat($b) )[9] <=> ( stat($a) )[9] } glob("$HOME/.cpanel/logs/*-deploy-$SLUG.log");
    return @files ? slurp( $files[0] ) : '';
}

sub host_port {
    my ($container) = @_;
    my ( $rc, $out ) = as_user( $USER, 'podman inspect --format ' . _sh('{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}') . ' ' . _sh($container) . ' 2>/dev/null' );
    chomp( $out //= '' );
    return $rc == 0 ? $out : '';
}

# The port the Web App proxy include sends `/` to.
sub wired_port {
    my ($domain) = @_;
    my $base = eval { require Cpanel::ConfigFiles::Apache; Cpanel::ConfigFiles::Apache->new()->dir_conf_userdata() } || '/etc/apache2/conf.d/userdata';
    my $conf = slurp("$base/std/2_4/$USER/$domain/webapp.conf");
    return $conf =~ m{^ProxyPass\s+/\s+http://127\.0\.0\.1:([0-9]+)/}m ? $1 : '';
}

sub account_ip {
    my ($ip) = slurp("/var/cpanel/users/$USER") =~ /^IP=(\S+)/m;
    return $ip // '127.0.0.1';
}

# Through Apache, to the account's own IP, as a browser would reach it.
#
# Retried until the APPLICATION answers, not until anything answers with 200:
# the deploy reports success before Apache's graceful restart loads the proxy
# include, and in that window the subdomain's vhost serves its empty docroot as a
# 200 directory listing (measured: ~10 s on AlmaLinux 9). A 503 is not retried
# away either way -- once the include is live, a stale port stays a 503.
sub via_apache {
    my ($domain) = @_;
    my $ip = account_ip();
    my ( $code, $body ) = ( '', '' );
    my $deadline = time + $APACHE_WAIT;
    while (1) {
        my ( undef, $out ) = run_cmd(
            'curl', '-s', '-k', '-L', '--max-time', '15',
            '--resolve', "$domain:80:$ip", '--resolve', "$domain:443:$ip",
            '-w', "\n%{http_code}", "http://$domain/"
        );
        ( $body, $code ) = $out =~ /\A(.*)\n([0-9]{3})\z/s ? ( $1, $2 ) : ( $out, '' );
        last if $code eq '200' && $body =~ /Q57608_OK/;
        last if time >= $deadline;
        sleep 5;
    }
    return ( $code, $body );
}

#=============================================================================
# Tests
#=============================================================================

my $RATE_LIMITED = 0;
my $FIRST_ID;

is( describe_ports(), 'none', 'a fresh account holds no reserved port' );

subtest 'A: a deploy over the disk quota fails at create and gives its port back' => sub {
    my ($deployed) = webapp( $USER, 'deploy', "name=$SLUG" );
    ok( uapi_ok($deployed), 'WebApp::deploy is accepted' ) or return note_both( uapi_why($deployed) );

    my ( $app, $last ) = wait_for_result('');
    $FIRST_ID = $last->{deploy_id};
    $LAST_LOG = deploy_log();

    if ( $LAST_LOG =~ /toomanyrequests|rate limit/i ) {
        $RATE_LIMITED = 1;
        pass('skipped: Docker Hub rate-limited this box; the image never arrived, so this proves nothing');
        return;
    }

    isnt( $last->{result}, 'success', "the deploy did NOT succeed under a ${QUOTA_MB} MB quota" );

    # Without these two, "no port afterwards" could mean the deploy died before
    # ea-podman ever reserved one, and would pass on the buggy version too.
    like( $LAST_LOG, qr/Failed to create container/, 'it failed at `podman create`, after ea-podman reserved the port' );
    like( $LAST_LOG, qr/disk quota exceeded/i,       'and podman says why: a real disk quota (EDQUOT), not a full disk' );

    my $ports = port_assignments();
    if ($WANT_FIX) {
        is( scalar keys %{$ports}, 0, 'the failed install left no port reserved' ) or note_both( 'reserved: ' . describe_ports() );
    }
    else {
        cmp_ok( scalar keys %{$ports}, '>=', 1, 'BEFORE RUN: the failed install kept its port (the bug reproduces)' ) or note_both('reserved: none');
    }
    note_both( 'after the failed deploy: ' . describe_ports() );

    return;
};

subtest 'B: with the quota lifted, the same app redeploys on one port and Apache serves it' => sub {
    if ($RATE_LIMITED) {
        pass('skipped: stage A was rate limited');
        return;
    }

    my $q = set_quota_mb(0);
    $q = set_quota_mb('unlimited') if $q->{limit_kb};
    is( $q->{limit_kb}, 0, 'the quota is lifted' ) or return note_both( "quota still shows a limit: $q->{raw}" );

    my ($redeployed) = webapp( $USER, 'deploy', "name=$SLUG" );
    ok( uapi_ok($redeployed), 'WebApp::deploy is accepted again' ) or return note_both( uapi_why($redeployed) );

    my ( $app, $last ) = wait_for_result($FIRST_ID);
    $LAST_LOG = deploy_log();

    if ( $LAST_LOG =~ /toomanyrequests|rate limit/i ) {
        pass('skipped: registry rate limit on the redeploy');
        return;
    }

    is( $last->{result}, 'success', 'the redeploy succeeds' ) or return;

    my $container = $app->{container_name} // '';
    my $domain    = $app->{domain}         // '';
    ok( length $container, "the application has a container ($container)" );
    ok( length $domain,    "and a domain ($domain)" );

    my $ports = port_assignments();
    my @mine  = sort grep { ( $ports->{$_}{service} // '' ) eq $container } keys %{$ports};
    note_both( 'after the redeploy: ' . describe_ports() );

    my $published = length $container ? host_port($container) : '';
    my $wired     = length $domain    ? wired_port($domain)    : '';
    note_both("published by podman: $published   proxy wired to: $wired");

    if ($WANT_FIX) {
        is( scalar keys %{$ports}, 1, 'the account holds exactly one reserved port' );
        is( scalar @mine,          1, 'and it is reserved for this container' );
        is( $published, $mine[0] // '', 'podman published the reserved port' );
        is( $wired,     $mine[0] // '', 'and the proxy is wired to it' );
    }
    else {
        cmp_ok( scalar @mine, '>=', 2, 'BEFORE RUN: the retry reserved a second port under the same name (the bug reproduces)' );
        note_both( 'BEFORE RUN: the proxy is wired to ' . ( $wired eq $published ? 'the published port (a plugin with CPANEL-57609 masks the 503)' : 'a port podman did not publish (the 503)' ) );
    }

    if ( length $domain ) {
        my ( $code, $body ) = via_apache($domain);
        note_both( "through Apache: HTTP $code" . ( $body =~ /Q57608_OK/ ? '' : " body: " . substr( $body, 0, 200 ) ) );
        if ($WANT_FIX) {
            is( $code, '200', 'Apache serves the application (no 503)' );
            like( $body, qr/Q57608_OK/, 'and it is this application' );
        }
    }

    return;
};

done_testing();
