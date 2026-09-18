#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/cpanel-54868-e2e-live.t     Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# CPANEL-54868 "Auto maintenance" -- the two halves against each other, through
# the product surface, on one box.
#
# WHY THIS FILE EXISTS
#
# Three live tests already cover this work and every one of them is on ONE side
# of the joint:
#
#   ea-podman   t/LiveTests/ea4-325-upgrade-live.t   the CLI and the EAPodman UAPI
#   plugin      t/Cpanel-WebApps-Cleanup-live.t      Cleanup::sweep as a module
#   plugin      t/Cpanel-WebApps-Podman-redeploy-force-live.t   redeploy_app as a module
#
# The third one does not run at all. `install_app()` reaches ea-podman through
# an adminbin that checks its PARENT PROCESS against a whitelist -- cpanel,
# uapi, xml-api, cpsrvd, queueprocd -- and a standalone .t is not on it and
# cannot be. Its own header says so, and names the way past it:
#
#     "Getting past it means going through an allowed parent, i.e. driving
#      `uapi --user=X WebApp redeploy ...` against a genuinely staged and
#      deployed application. That is a full end-to-end deploy (source intake,
#      adapter, an ASYNC UserTasks deploy to poll) rather than the focused probe
#      this is, and it is a different piece of work."
#
# This is that piece of work. It is also Phase 3 of LIVE-VERIFICATION-PLAN.md,
# which until now said "No automated test covers this, and it is the scenario
# that would reach customers."
#
# WHAT IT PROVES THAT NOTHING ELSE CAN
#
#   1. A Redeploy applies a configuration change that does NOT move the image.
#      That is the whole of CPANEL-56732. It is inert without ea-podman 1.0-28
#      and it is silently broken with 1.0-28 and an older plugin, so it can only
#      be tested with both halves installed and talking to each other.
#   2. The gate really is on: a plain `ea-podman upgrade` on that same container
#      does nothing at all. Both must be true at once, and they pull in opposite
#      directions -- that is the interesting part.
#   3. The administrator-facing cleanup, end to end: the sweep script over a real
#      account, and `ea-podman clean` over the `.bak` a real delete leaves.
#
# WHAT IT CANNOT PROVE, AND DOES NOT PRETEND TO
#
# The ordering HAZARD itself -- that an old plugin against new ea-podman
# silently no-ops -- needs two plugin versions on one box. Set
# CP54868_PROVE_HAZARD=1 and stage G builds that combination deliberately by
# removing `force` from the DEPLOYED Podman.pm, and restores it afterwards. It
# is opt-in because it edits an installed file, and it is the only stage that
# expects a failure.
#
# RUN IT
#
#     scp t/LiveTests/setup-remote-live.pl root@VM:/root/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl \
#         --ea-podman=/root/ea-podman --plugin=/root/plugins --deploy'
#
#     scp t/LiveTests/cpanel-54868-e2e-live.t root@VM:/root/
#     ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl /root/cpanel-54868-e2e-live.t'
#
# The preflight is not optional here. It is what puts the code under test on the
# box and, more to the point, what tells you WHICH copy is under test: the
# ea-podman CLI is a compiled binary that embeds util.pm, and the plugin's
# modules are symlinks into a repo on a dev box but real files from the package
# on a VM. Both failure modes are silent and both make this file pass while
# testing something else.
#
# Self-contained otherwise: core Perl plus what cPanel ships, no repo checkout,
# no CPAN. Single file on purpose -- it gets scp'd to a bare host.
#
# MUST NOT INTERLEAVE WITH ea4-325-upgrade-live.t. That file runs
# `remove_containers --all` AS ROOT, which reaches every account on the box.
# Run one, then `setup-remote-live.pl --check-clean`, then the other.
#
# DESTRUCTIVE, THROWAWAY VM ONLY. Creates a cPanel account, pulls a node image,
# creates and destroys containers, and removes files under that account's home.
# It removes the account again unless CP54868_KEEP=1.
#
# ENVIRONMENT
#
#   EAPODMAN_LIVE=1        required opt-in (directory convention)
#   CP54868_TEST_USER      reuse an existing throwaway account instead of making one
#   CP54868_NODE_TAG       node runtime tag (default 22)
#   CP54868_KEEP=1         leave the account and its containers for inspection
#   CP54868_PROVE_HAZARD=1 also run stage G (edits the deployed Podman.pm)
#   CP54868_DEPLOY_TIMEOUT seconds to wait for an async deploy (default 600)

use strict;
use warnings;

use Test::More;
use File::Path ();
use IPC::Open3 ();
use Symbol     ();

my $WHMAPI      = '/usr/local/cpanel/bin/whmapi1';
my $UAPI        = '/usr/local/cpanel/bin/uapi';
my $EAP_LIB     = '/opt/cpanel/ea-podman/lib/ea_podman/util.pm';
my $EAP_BIN     = '/opt/cpanel/ea-podman/bin/ea-podman';
my $PLUGIN_PM   = '/usr/local/cpanel/Cpanel/WebApps/Podman.pm';
my $SWEEP       = '/usr/local/cpanel/scripts/webapp_cleanup.pl';
my $FEATUREFLAG = '/var/cpanel/feature-flags/webapp';

my $NODE_TAG = $ENV{CP54868_NODE_TAG}       || '22';
my $TIMEOUT  = $ENV{CP54868_DEPLOY_TIMEOUT} || 600;
my $SLUG     = 'e2e54868';

#=============================================================================
# Guards. Each one names what is missing, because "skipped" with no reason
# sends the next person to debug cPanel when the fault was the box.
#=============================================================================

plan skip_all => 'live test; set EAPODMAN_LIVE=1 to run' unless $ENV{EAPODMAN_LIVE};
plan skip_all => 'must run as root'                      if $> != 0;

sub in_path {
    my ($bin) = @_;
    for my $dir ( split /:/, ( $ENV{PATH} || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin' ) ) {
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

plan skip_all => 'podman is not installed'          if !in_path('podman');
plan skip_all => 'zip is not installed'             if !in_path('zip');
plan skip_all => "whmapi1 not found ($WHMAPI)"      if !-x $WHMAPI;
plan skip_all => "uapi not found ($UAPI)"           if !-x $UAPI;
plan skip_all => "ea-podman is not installed"       if !-e $EAP_LIB || !-e $EAP_BIN;
plan skip_all => "the webapp plugin is not installed (no $PLUGIN_PM)" if !-e $PLUGIN_PM;

# cgroup v2. The webapp resource-limit path is inert on a v1 hierarchy and a
# partial pass here would be read as a pass. Fail loudly instead of quietly.
plan skip_all => 'this box is on cgroup v1; these features need the v2 hierarchy'
  if !-e '/sys/fs/cgroup/cgroup.controllers';

# The feature flag gates the WHOLE of Cpanel::API::WebApp. Without it every call
# below answers "Unknown API requested", which reads as a broken plugin.
plan skip_all => "the webapp feature flag is missing ($FEATUREFLAG)" if !-e $FEATUREFLAG;

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

# As the account, with the rootless session's environment set by hand. An ssh
# login does not necessarily create a logind session and `su` leaves the
# caller's cwd in place, which the cpuser often cannot enter -- the same trap
# ea_podman::util::ensure_su_login() works around.
sub as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "
      . "HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";

    # QUERY_STRING/REQUEST_METHOD cleared so an inherited value cannot make a
    # WebApp call refuse a passphrase parameter for reasons nothing explains.
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "unset QUERY_STRING REQUEST_METHOD; $env $cmd" );
}

# Minimal JSON reader. cPanel ships Cpanel::JSON, but this file must survive
# being copied to a box where the plugin is half-installed, so it does not
# depend on anything under /usr/local/cpanel/Cpanel.
my $HAVE_CPJSON = eval { require Cpanel::JSON; 1 } ? 1 : 0;

sub decode_json_or_undef {
    my ($text) = @_;
    return undef if !length( $text // '' );
    $text =~ s/\A[^{\[]+//s;    # advisory banners before the payload
    return undef if !length $text;
    return $HAVE_CPJSON ? eval { Cpanel::JSON::Load($text) } : eval { require JSON::PP; JSON::PP::decode_json($text) };
}

# uapi --user=X must run AS ROOT. Wrapping it in `su -l X` dies with
# "Attempting to setuid as a normal user"; it impersonates the account itself.
sub uapi {
    my ( $user, $module, $fn, @args ) = @_;
    my ( $rc, $out, $err ) = run_cmd( $UAPI, "--user=$user", $module, $fn, @args, '--output=json' );
    my $json = decode_json_or_undef($out);
    return ( $json, $rc, $out . $err );
}

sub webapp {
    my ( $user, $fn, @args ) = @_;
    return uapi( $user, 'WebApp', $fn, @args );
}

sub uapi_ok {
    my ($json) = @_;
    return $json && $json->{result} && $json->{result}{status} ? 1 : 0;
}

sub uapi_why {
    my ($json) = @_;
    return 'no JSON returned' if !$json;
    my $e = $json->{result}{errors};
    return join( '; ', @{$e} ) if ref $e eq 'ARRAY' && @{$e};
    return 'no error text';
}

sub whmapi {
    my (@args) = @_;
    my ( $rc, $out, $err ) = run_cmd( $WHMAPI, @args, '--output=json' );
    return ( decode_json_or_undef($out), $rc, $out . $err );
}

# podman facts about one container, read as the account.
sub inspect_field {
    my ( $user, $container, $fmt ) = @_;
    my ( $rc, $out ) = as_user( $user, "podman inspect --format " . _sh($fmt) . " " . _sh($container) . " 2>/dev/null" );
    chomp( $out //= '' );
    return $rc == 0 ? $out : '';
}

sub container_id      { return inspect_field( @_[ 0, 1 ], '{{.Id}}' ) }
sub container_started { return inspect_field( @_[ 0, 1 ], '{{.State.StartedAt}}' ) }
sub container_running { return inspect_field( @_[ 0, 1 ], '{{.State.Running}}' ) eq 'true' ? 1 : 0 }

# The app record as the product reports it. container_name is surfaced by
# _public_app specifically so a caller can discover it; do not guess the name.
sub app_record {
    my ($user) = @_;
    my ($json) = webapp( $user, 'list' );
    return undef if !uapi_ok($json);
    for my $app ( @{ $json->{result}{data} || [] } ) {
        return $app if ( $app->{name} // '' ) eq $SLUG;
    }
    return undef;
}

# A deploy is queued to UserTasks and returns immediately, so every stage that
# deploys has to wait for the record to settle rather than for the call.
sub wait_for_deploy {
    my ( $user, $what ) = @_;
    my $deadline = time + $TIMEOUT;

    while ( time < $deadline ) {
        my $app = app_record($user);
        if ( $app && ( $app->{status} // '' ) ne 'deploying' ) {
            my $result = ref $app->{last_deploy} eq 'HASH' ? ( $app->{last_deploy}{result} // '' ) : '';
            return ( $app, $result );
        }
        sleep 5;
    }

    return ( app_record($user), 'timeout' );
}

# diag goes to STDERR and vanishes when a run is redirected to a report file.
# Anything needed to diagnose a failure is mirrored to STDOUT as a comment.
sub note_both {
    my ($msg) = @_;
    diag($msg);
    print "# $msg\n";
    return;
}

#=============================================================================
# Am I testing the code I think I am testing?
#
# Both of these are version checks in disguise, and both are asked of the thing
# that actually runs rather than of a package database: an RPM version says
# nothing about whether the compiled binary was rebuilt, or whether a dev box's
# symlinks point at an older tree.
#=============================================================================

my ( $help_rc, $help_out ) = run_cmd( $EAP_BIN, 'help', 'upgrade' );
plan skip_all => "this ea-podman does not know `upgrade --force`; it predates EA4-325 Increment B "
  . "(recompile: bash /opt/cpanel/ea-podman/bin/compile.sh)"
  if $help_out !~ m/--force/;

my ( $clean_rc, $clean_out ) = run_cmd( $EAP_BIN, 'help', 'clean' );
plan skip_all => "this ea-podman has no `clean` verb; it predates EA4-325 Increment C"
  if $clean_rc != 0 || $clean_out !~ m/\.bak/;

my $pm_text = do { local ( @ARGV, $/ ) = ($PLUGIN_PM); <> };
plan skip_all => "the installed Cpanel/WebApps/Podman.pm does not pass `force` on redeploy; "
  . "it predates CPANEL-56732 and the whole point of this file is the pair"
  if $pm_text !~ m/upgrade_container\s*\(\s*\$container_name\s*,\s*force\s*=>\s*1\s*\)/;

plan skip_all => "the cleanup sweep script is not installed ($SWEEP); it predates CPANEL-56733"
  if !-e $SWEEP;

note_both("ea-podman: $EAP_BIN (knows --force and clean)");
note_both("plugin:    $PLUGIN_PM (passes force)");
note_both("sweep:     $SWEEP");

#=============================================================================
# Account
#=============================================================================

my ( $USER, $HOME, $CREATED_USER, $ACCOUNT_ERROR );

if ( $ENV{CP54868_TEST_USER} ) {
    $USER = $ENV{CP54868_TEST_USER};
    plan skip_all => "CP54868_TEST_USER '$USER' is not a system user" if !defined getpwnam($USER);
}
else {
    $USER = 'e2e' . substr( time, -6 );
    note_both("Creating throwaway cPanel account '$USER' ...");

    # plan= NOT pkg=. `pkg=` is silently ignored and the account lands on
    # `default`, which has neither the webapp feature nor shell -- and every
    # later failure then looks like a product bug.
    my ( $json, $rc, $raw ) = whmapi(
        'createacct',
        "username=$USER",
        "domain=$USER.cpanel54868.test",
        'password=E2e' . substr( time, -6 ) . '!Qx',
        'hasshell=1',
    );

    if ( !( $json && $json->{metadata} && $json->{metadata}{result} ) ) {
        $ACCOUNT_ERROR = ( $json && $json->{metadata}{reason} ) || "whmapi1 exit $rc: " . substr( $raw, 0, 300 );
        plan skip_all => "could not create test account '$USER': $ACCOUNT_ERROR (set CP54868_TEST_USER to reuse one)";
    }
    $CREATED_USER = 1;
}

$HOME = ( getpwnam($USER) )[7];
plan skip_all => "could not resolve a homedir for '$USER'" if !length( $HOME // '' ) || !-d $HOME;
note_both("Test user: $USER, home: $HOME");

my $HAZARD_BACKUP;

END {
    # Restore the deployed module FIRST, whatever else happened. Leaving a box
    # with `force` stripped out of Podman.pm is worse than any test failure.
    if ( $HAZARD_BACKUP && -e $HAZARD_BACKUP ) {
        rename( $HAZARD_BACKUP, $PLUGIN_PM ) or warn "COULD NOT RESTORE $PLUGIN_PM from $HAZARD_BACKUP: $!\n";
        print "# restored $PLUGIN_PM\n";
    }

    if ( $CREATED_USER && !$ENV{CP54868_KEEP} ) {
        print "# removing throwaway account $USER\n";
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
    }
    elsif ( $CREATED_USER ) {
        print "# CP54868_KEEP set: account $USER left in place\n";
    }
}

#=============================================================================
# Fixture: a zero-dependency Node app, delivered as a zip.
#
# zip rather than git: the git source type needs a reachable https or git@ URL
# (Source::_validate_git_url), which makes the test depend on a host nobody
# controls. A zip is validated against a path under the account's own home, so
# the whole fixture is local and deterministic.
#
# Zero dependencies so `npm install` has nothing to fetch. The image pull is
# the only network this test wants to need.
#=============================================================================

sub write_fixture_zip {
    my ($marker) = @_;

    my $dir = "$HOME/e2e-src";
    File::Path::remove_tree($dir);
    File::Path::make_path("$dir/app");

    _spew(
        "$dir/app/package.json",
        qq({"name":"e2e54868","version":"1.0.0","private":true,"scripts":{"start":"node server.js"}}\n)
    );

    # Reports the marker it was started with, so "did the new configuration
    # reach the running container" is answerable from outside the container.
    _spew(
        "$dir/app/server.js", <<'JS'
const http = require('http');
const port = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('E2E_MARKER=' + (process.env.E2E_MARKER || 'unset') + '\n');
}).listen(port);
JS
    );

    my ( $rc, $out, $err ) = run_cmd( 'bash', '-c', "cd " . _sh("$dir/app") . " && zip -q -r " . _sh("$HOME/e2e-src.zip") . " . " );
    die "could not build the fixture zip: $out$err\n" if $rc != 0;

    run_cmd( 'chown', '-R', "$USER:$USER", "$HOME/e2e-src.zip", $dir );
    return 'e2e-src.zip';
}

sub _spew {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $content;
    close $fh;
    return;
}

# What the app answers on its published port, from the host side.
sub app_says {
    my ($container) = @_;
    my $port = inspect_field( $USER, $container, '{{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}}{{end}}' );
    return '' if !length $port;
    my ( $rc, $out ) = run_cmd( 'curl', '-s', '--max-time', '10', "http://127.0.0.1:$port/" );
    return $rc == 0 ? ( $out // '' ) : '';
}

#=============================================================================
# Stage A -- a real application, staged and deployed through the product
#=============================================================================

my $CONTAINER;

subtest 'A: an application stages and deploys through the UAPI' => sub {
    my $archive = write_fixture_zip();

    my ( $staged, undef, $raw ) = webapp(
        $USER, 'stage',
        "name=$SLUG",
        'source_type=zip',
        "source=$archive",
        'runtime=nodejs',
        "runtime_tag=$NODE_TAG",
    );
    ok( uapi_ok($staged), 'WebApp::stage succeeds' ) or do {
        note_both( "stage failed: " . uapi_why($staged) . "\nraw: " . substr( $raw, 0, 800 ) );
        plan skip_all => 'nothing downstream can run without a staged application';
    };

    my ($configured) = webapp(
        $USER, 'configure',
        "name=$SLUG",
        'startup_command=npm run start',
        'env={"E2E_MARKER":"one"}',
    );
    ok( uapi_ok($configured), 'WebApp::configure sets the first marker' ) or note_both( uapi_why($configured) );

    my ($deployed) = webapp( $USER, 'deploy', "name=$SLUG" );
    ok( uapi_ok($deployed), 'WebApp::deploy is accepted' ) or note_both( uapi_why($deployed) );

    my ( $app, $result ) = wait_for_deploy( $USER, 'first deploy' );
    is( $result, 'success', 'the deploy finishes successfully' )
      or note_both( "deploy result: $result; status: " . ( $app->{status} // 'undef' ) );

    $CONTAINER = $app && $app->{container_name};
    ok( length( $CONTAINER // '' ), 'the application reports a container name' )
      or plan skip_all => 'without a container name nothing below can assert anything';

    note_both("container: $CONTAINER");
    ok( container_running( $USER, $CONTAINER ), 'the container is running' );
    like( app_says($CONTAINER), qr/E2E_MARKER=one/, 'and it is serving the configuration it was deployed with' );

    return;
};

plan skip_all => 'stage A did not produce a running application' if !length( $CONTAINER // '' );

# Warm the image in the ACCOUNT's own store before anything asserts on a pull.
# Since Increment B every upgrade pulls, and on the conditional path a failed
# pull ABORTS -- so a rate-limited box would fail stage C for a reason that has
# nothing to do with the gate.
my $IMAGE_REF = inspect_field( $USER, $CONTAINER, '{{.ImageName}}' );
my ( $prepull_rc, $prepull_out ) = as_user( $USER, "podman pull " . _sh($IMAGE_REF) . " 2>&1" );
if ( $prepull_rc != 0 ) {
    note_both("pre-pull of $IMAGE_REF failed: " . substr( $prepull_out, 0, 300 ));
    plan skip_all => "cannot pull $IMAGE_REF on this box (rate limit or no registry access); "
      . "stage C asserts on a successful pull and would fail for the wrong reason";
}

#=============================================================================
# Stage B -- THE CONTRACT. CPANEL-56732, and the reason it ships first.
#=============================================================================

subtest 'B: a configuration change that does not move the image reaches the container' => sub {
    my $before_id = container_id( $USER, $CONTAINER );
    ok( length $before_id, 'the container has an id to compare against' );

    my ($configured) = webapp( $USER, 'configure', "name=$SLUG", 'env={"E2E_MARKER":"two"}' );
    ok( uapi_ok($configured), 'the configuration is changed, and nothing about it moves the image' )
      or note_both( uapi_why($configured) );

    my ($redeployed) = webapp( $USER, 'redeploy', "name=$SLUG" );
    ok( uapi_ok($redeployed), 'WebApp::redeploy is accepted' ) or note_both( uapi_why($redeployed) );

    my ( $app, $result ) = wait_for_deploy( $USER, 'redeploy' );
    is( $result, 'success', 'the redeploy finishes successfully' );

    my $after_id = container_id( $USER, $CONTAINER );

    # The two halves of the same claim. Without CPANEL-56732 against an
    # ea-podman 1.0-28 the redeploy reports SUCCESS and changes nothing, so the
    # id assertion is the one that catches it -- the status never would.
    isnt( $after_id, $before_id, 'the container was actually recreated' );
    like( app_says($CONTAINER), qr/E2E_MARKER=two/, 'and the new configuration is what is now running' );

    ok( container_running( $USER, $CONTAINER ), 'the container is up afterwards' );

    return;
};

#=============================================================================
# Stage C -- and yet the gate really is on.
#
# The mirror of stage B, and the reason both belong in one file: they pull in
# opposite directions. A plugin that forced nothing would pass C and fail B; an
# ea-podman that gated nothing would pass B and fail C.
#=============================================================================

subtest 'C: a plain `ea-podman upgrade` on the same container does nothing at all' => sub {
    my $before_id      = container_id( $USER, $CONTAINER );
    my $before_started = container_started( $USER, $CONTAINER );

    my ( $rc, $out ) = as_user( $USER, "/opt/cpanel/ea-podman/bin/ea-podman upgrade " . _sh($CONTAINER) . " 2>&1" );

    is( $rc, 0, 'a no-op upgrade exits 0' ) or note_both( "upgrade output: " . substr( $out, 0, 600 ) );
    like( $out, qr/already up to date/i, 'and says so' );

    is( container_id( $USER, $CONTAINER ),      $before_id,      'the container was NOT recreated' );
    is( container_started( $USER, $CONTAINER ), $before_started, 'and was not even restarted' );
    like( app_says($CONTAINER), qr/E2E_MARKER=two/, 'the application is undisturbed' );

    return;
};

#=============================================================================
# Stage G -- the hazard, deliberately built. Opt-in.
#
# LIVE-VERIFICATION-PLAN.md Phase 3: new ea-podman plus OLD plugin must produce
# a silent no-op. This is the only stage that expects a failure, and the only
# one that edits an installed file. It runs here, while the application from
# stage A is still alive, because rebuilding one costs several minutes.
#=============================================================================

SKIP: {
    skip 'set CP54868_PROVE_HAZARD=1 to build the dangerous combination deliberately', 1
      if !$ENV{CP54868_PROVE_HAZARD};

    subtest 'G: WITHOUT force, the same redeploy silently changes nothing' => sub {
        if ( -l $PLUGIN_PM ) {
            note_both("$PLUGIN_PM is a SYMLINK into a repo; this stage would edit the repo. Skipping.");
            pass('skipped on a development box, where editing the deployed file edits your working tree');
            return;
        }

        $HAZARD_BACKUP = "$PLUGIN_PM.cp54868-e2e-backup";
        my ( $cp_rc ) = run_cmd( 'cp', '-p', $PLUGIN_PM, $HAZARD_BACKUP );
        if ( $cp_rc != 0 ) {
            undef $HAZARD_BACKUP;
            fail('could not back up the deployed Podman.pm, so it must not be edited');
            return;
        }

        my $text = do { local ( @ARGV, $/ ) = ($PLUGIN_PM); <> };
        $text =~ s/upgrade_container\s*\(\s*\$container_name\s*,\s*force\s*=>\s*1\s*\)/upgrade_container(\$container_name)/
          or do { fail('could not find the force call site to remove'); return };
        _spew( $PLUGIN_PM, $text );

        my $before_id = container_id( $USER, $CONTAINER );

        my ($configured) = webapp( $USER, 'configure', "name=$SLUG", 'env={"E2E_MARKER":"three"}' );
        ok( uapi_ok($configured), 'the configuration changes again' );

        my ($redeployed) = webapp( $USER, 'redeploy', "name=$SLUG" );
        my ( undef, $result ) = wait_for_deploy( $USER, 'redeploy without force' );

        # THIS is the customer-visible failure, and why the plugin ships first.
        is( $result, 'success', 'the redeploy still reports SUCCESS' );
        is( container_id( $USER, $CONTAINER ), $before_id, 'but the container was never recreated' );
        like( app_says($CONTAINER), qr/E2E_MARKER=two/, 'and the OLD configuration is still what is running' );

        note_both('HAZARD REPRODUCED: an old plugin against this ea-podman reports success and applies nothing.');

        rename( $HAZARD_BACKUP, $PLUGIN_PM ) or die "could not restore $PLUGIN_PM: $!";
        undef $HAZARD_BACKUP;

        # And the fix really is the fix: same box, same app, force restored.
        webapp( $USER, 'redeploy', "name=$SLUG" );
        my ( undef, $fixed ) = wait_for_deploy( $USER, 'redeploy with force restored' );
        is( $fixed, 'success', 'with force restored the redeploy succeeds' );
        isnt( container_id( $USER, $CONTAINER ), $before_id, 'and this time the container IS recreated' );
        like( app_says($CONTAINER), qr/E2E_MARKER=three/, 'and the configuration finally reaches it' );

        return;
    };
}

#=============================================================================
# Stage D -- a stopped application comes back.
#
# The plugin half of EA4-325 B7 and CPANEL-56732 AC7. The conditional path
# deliberately leaves a stopped container stopped; force still starts it, and
# _start_container's recreate branch has no set_lifecycle of its own, so this is
# the assertion that would catch force quietly ceasing to imply a start.
#=============================================================================

subtest 'D: redeploying a stopped application brings it back up' => sub {
    my ($stopped) = webapp( $USER, 'stop', "name=$SLUG" );
    ok( uapi_ok($stopped), 'the application stops' ) or note_both( uapi_why($stopped) );

    sleep 3;
    ok( !container_running( $USER, $CONTAINER ), 'the container really is down' );

    my ($redeployed) = webapp( $USER, 'redeploy', "name=$SLUG" );
    ok( uapi_ok($redeployed), 'redeploy is accepted against a stopped application' );

    my ( undef, $result ) = wait_for_deploy( $USER, 'redeploy of a stopped app' );

    # Without the start, Deploy.pm finds no published host port and fails the
    # deploy with "the container started but is not listening on a port" -- a
    # false failure with a misleading diagnosis.
    is( $result, 'success', 'and the deploy succeeds rather than failing on a missing host port' );
    ok( container_running( $USER, $CONTAINER ), 'the container is running again' );

    return;
};

#=============================================================================
# Stage E -- the administrator's cleanup sweep, over a real account.
#=============================================================================

subtest 'E: webapp_cleanup.pl reclaims leftovers and leaves the live application alone' => sub {

    # ctime CANNOT be set -- utime moves only atime/mtime, and a chown resets
    # ctime on everything it touches. So on a live box every fixture is
    # necessarily brand new and the only honest way to express "old enough" is
    # to move the threshold to meet it.
    my $ghost = "$HOME/.cpanel/webapp-staging/ghost";
    File::Path::make_path("$ghost/source");
    _spew( "$ghost/source/index.js", "// never deployed\n" );

    my $old_log = "$HOME/.cpanel/logs/1000000000-deploy-$SLUG.log";
    File::Path::make_path("$HOME/.cpanel/logs");
    _spew( $old_log, "an old deploy log\n" );

    run_cmd( 'chown', '-R', "$USER:$USER", "$HOME/.cpanel" );

    my ( $rc, $out ) = run_cmd( $SWEEP, "--user=$USER", '--days=0' );
    is( $rc, 0, 'a listing run exits 0' ) or note_both( substr( $out, 0, 600 ) );
    like( $out, qr/Listing only/,     'and says it is listing only' );
    like( $out, qr/\Qghost\E/,        'the never-deployed staging directory is listed' );
    ok( -d $ghost, 'and is still on disk, because a listing run removes nothing' );

    my ( $run_rc, $run_out ) = run_cmd( $SWEEP, "--user=$USER", '--days=0', '--run' );
    is( $run_rc, 0, 'the removing run exits 0' ) or note_both( substr( $run_out, 0, 600 ) );
    ok( !-d $ghost,    'the orphan is gone' );
    ok( !-e $old_log,  'and so is the superseded deploy log' );

    # The live application's own staging directory is protected by the registry,
    # not by age -- at --days=0 age protects nothing at all.
    my $live_staging = "$HOME/.cpanel/webapp-staging/$SLUG";
    if ( -d $live_staging ) {
        like( $run_out, qr/\Q$SLUG\E/, 'the registered application is reported rather than swept' )
          if $run_out =~ m/\Q$SLUG\E/;
        ok( -d $live_staging, 'the registered application keeps its staging directory' );
    }

    ok( container_running( $USER, $CONTAINER ), 'and the running application is untouched by any of it' );

    return;
};

#=============================================================================
# Stage F -- delete, and then `ea-podman clean` over what delete leaves.
#
# remove_container_by_name() releases the ports, uninstalls the container and
# its unit, deregisters it, and THEN renames the directory to <name>.bak. So all
# four of clean's "is this name free" checks are satisfied and the backup is
# genuinely reclaimable -- which is exactly what makes this the honest test of
# CPANEL-54870 rather than a contrived one.
#=============================================================================

subtest 'F: deleting the application leaves a .bak, and `ea-podman clean` reclaims it' => sub {
    my $bak = "$HOME/ea-podman.d/$CONTAINER.bak";

    # verify=1 is REQUIRED and has no default; without it this is InvalidParameter.
    my ($deleted) = webapp( $USER, 'delete', "name=$SLUG", 'verify=1' );
    ok( uapi_ok($deleted), 'WebApp::delete succeeds' ) or note_both( uapi_why($deleted) );

    ok( -d $bak, "the delete left $CONTAINER.bak behind" )
      or do { note_both("no .bak at $bak; nothing below can assert anything"); return };

    my ( $list_rc, $list_out ) = as_user( $USER, "/opt/cpanel/ea-podman/bin/ea-podman clean --days=0 2>&1" );
    is( $list_rc, 0, 'a listing run exits 0' ) or note_both( substr( $list_out, 0, 600 ) );
    like( $list_out, qr/Listing only/, 'and lists rather than removes' );
    like( $list_out, qr/\Q$CONTAINER\E\.bak/, 'the backup is listed as reclaimable' );

    # C8: the warning is in the DEFAULT listing, while the operator is deciding.
    like( $list_out, qr/only copy/i, 'the listing warns what a .bak can hold before --run is ever passed' );
    ok( -d $bak, 'and the backup is still there' );

    my ( $run_rc, $run_out ) = as_user( $USER, "/opt/cpanel/ea-podman/bin/ea-podman clean --days=0 --run 2>&1" );
    is( $run_rc, 0, 'the removing run exits 0' ) or note_both( substr( $run_out, 0, 600 ) );
    ok( !-d $bak, 'and the backup is gone' );

    return;
};

done_testing();
