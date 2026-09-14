#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# EA4-325 — LIVE integration test (NOT a unit test).
#
# WHAT THIS PROVES. `ea-podman upgrade` tells the truth about what it
# did, and neither it nor `restore` destroys state it cannot put back.
# Four defects, each with a specific, reproducible symptom this test
# reproduces and then asserts is gone:
#
#   A1  A failed start was discarded, so an upgrade that left the
#       application down exited 0. Measured before the fix: exit 0 in
#       2.5s with the container not running.
#
#       One check is not enough, and that is why this test exists rather
#       than a unit test alone. The generated unit carries
#       StartLimitBurst=3 / RestartSec=5, and a crash-looping container
#       is GENUINELY `active` for the moment it runs on each attempt —
#       traced live at t=6.25s with Result=success. A single ActiveState
#       sample landing there reports a crash loop as a success, so the
#       verdict confirms an `active` sighting before believing it. Only a
#       real systemd + podman can demonstrate that.
#
#   A2  uninstall_container() runs BEFORE the create, and the cleanup
#       branch was gated `if ( !$isupgrade )`:
#         * upgrade   — a failed create left the container and its unit
#                       destroyed. Measured: exit 125, both gone.
#         * restore   — $isrestore leaves $isupgrade false, so a failed
#                       restore took the INSTALL cleanup and DELETED the
#                       directory perform_user_restore() had just
#                       untarred from the user's backup. There is no
#                       other copy.
#
#   A3  `upgrade_containers --all` called do_as_user_with_exception bare,
#       so one uncleanly-deleted account aborted the whole sweep. Fixing
#       that must not make it silent, so it must still exit non-zero.
#
#   A4  get_containers() split `podman ps` output without chomping, so
#       the image carried a trailing newline.
#
# Also covers the EAPodman UAPI's _lifecycle, which returned success
# unconditionally: start/restart now report a bring-up that did not
# happen, while stop stays permissive so teardown paths keep working.
#
# INCREMENT B — pull, compare, and do nothing when nothing moved.
#
#   `upgrade` never pulled (podman create inherits --pull=missing) and
#   recreated unconditionally, so a nightly `upgrade_containers --all`
#   restarted every application on the server and still fetched nothing.
#   Now it pulls, compares LOCAL IMAGE IDS (never registry digests -- the
#   two live in different namespaces and would differ forever), and
#   returns before any teardown when nothing changed.
#
#   Only a real podman can prove the no-op: the assertion is that the
#   container's instance ID and StartedAt are UNCHANGED, which no mock
#   can demonstrate.
#
#   Two behaviours here are easy to get subtly wrong and are asserted
#   explicitly:
#     * a failed pull ABORTS the conditional path with the container
#       untouched, but WARNS and falls back to the cached image under
#       --force, so a registry outage cannot break the plugin's Redeploy;
#     * the conditional path recreates a stopped container and LEAVES it
#       stopped, since a deliberate stop cannot be told from a crash.
#
#   An EA4 packaged container is gated on its PACKAGE VERSION as well as
#   its image: the RPM owns both the image pin and the start args, so a
#   package update can change `startup` flags with an identical image.
#
#   And the interaction between the increments: a sweep over a stopped
#   container must exit 0. If A's start verdict were not gated on having
#   actually started something, `--all` would exit non-zero for every
#   stopped container on a server.
#
# NOTE FOR ANYONE EDITING THIS FILE. Since Increment B, a plain `upgrade`
# does NOTHING when the image has not moved -- and editing a container's
# persisted start_args does not move its image. So any step that changes
# start_args and expects the container to follow MUST pass --force. Three
# subtests and one repair step here were written before B and silently
# stopped doing anything; the repair even still returned 0. That is the
# same hazard CPANEL-56732 exists to prevent in the webapp plugin.
#
# VERIFIED ON BOTH PACKAGE FORMATS AND TWO PODMAN MAJORS:
#   AlmaLinux 9.8, podman 5.8.2, ea-podman 1.0-28 RPM  -- 24/24
#   Ubuntu 24.04.4, podman 4.9.3, ea-podman 1.0-28 deb -- 24/24
# The gate reads `podman image inspect --format '{{.Id}}'` against
# `podman inspect --format '{{.Image}}'`, and the rollback reads
# `{{.ImageName}}`; all three behave identically on 4.9 and 5.8, and
# resolve the same image to the same ID.
#
# DESTRUCTIVE, AND SERVER-WIDE. Run this only on a disposable box with no
# ea-podman containers you care about, for two reasons:
#
#   * `upgrade_containers --all` and `clean` are server-wide by design, so
#     ANOTHER account's broken container fails a sweep this file asserts
#     succeeds -- the failure then looks like a bug in the code under test.
#   * the A3 subtest runs `remove_containers --all` AS ROOT to clear a
#     deliberately-deleted account's registry entry. There is no per-account
#     form of that verb, so it removes EVERY account's containers on the box.
#
# Both were learned the hard way: a leftover account from unrelated manual
# testing made two subtests fail for reasons that had nothing to do with them.
#
# Run ON A LIVE cPanel VM, as root, with podman installed and an
# ea-podman build carrying the EA4-325 changes:
#
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea4-325-upgrade-live.t
#
# NOTE ON INSTALLING A BUILD TO TEST. The `ea-podman` CLI is a COMPILED
# binary that EMBEDS util.pm — copying SOURCES/util.pm over
# /opt/cpanel/ea-podman/lib/ea_podman/util.pm does nothing on its own.
# Copy it, then recompile:
#
#   scp SOURCES/util.pm    root@VM:/opt/cpanel/ea-podman/lib/ea_podman/
#   scp SOURCES/ea-podman.pl root@VM:/opt/cpanel/ea-podman/bin/
#   ssh root@VM 'bash /opt/cpanel/ea-podman/bin/compile.sh'
#
# Environment variables:
#   EAPODMAN_LIVE=1      REQUIRED opt-in.
#   EAPODMAN_TEST_USER   reuse an existing account instead of creating a
#                        throwaway one (its shell is set unrestricted for
#                        the test and restored afterward).
#   EAPODMAN_TEST_IMAGE  image to install (default: httpd:2.4).
#   EAPODMAN_TEST_PORT   container port to publish (default: 80).
#   EAPODMAN_TEST_PKG    EA4 container package for the packaged-path
#                        subtests (default: ea-memcached16). Skipped when
#                        it is not installed.
#   Increment C (`ea-podman clean`) is covered too: the ctime-not-mtime
#   rule, the name-still-claimed guard, and that a hand-made directory is
#   never touched.
#
#   EAPODMAN_TEST_ALT_IMAGE  a second, different image used to prove the
#                        gate fires on a real change (default:
#                        httpd:2.4-alpine).
#   EAPODMAN_KEEP=1      skip teardown.
#######################################################################

use strict;
use warnings;

use Test::More;

use IPC::Open3 ();
use Symbol     ();
use Time::HiRes ();

#---------------------------------------------------------------------
# config
#---------------------------------------------------------------------
my $IMAGE = $ENV{EAPODMAN_TEST_IMAGE} || 'docker.io/library/httpd:2.4';
my $PORT  = $ENV{EAPODMAN_TEST_PORT}  || 80;
my $PKG   = $ENV{EAPODMAN_TEST_PKG}   || 'ea-memcached16';
my $KEEP  = $ENV{EAPODMAN_KEEP};
my $CBASE = 'eapod325';
my $BASH  = '/bin/bash';

my $UAPI      = '/usr/local/cpanel/bin/uapi';
my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman';
my $PORTAUTH  = '/usr/local/cpanel/scripts/cpuser_port_authority';
my $REGISTRY  = '/opt/cpanel/ea-podman/registered-containers.json';
my @CLI_PATHS = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

# A container that starts and then exits non-zero: the A1 crash loop.
my $BAD_ENTRYPOINT = '["/bin/sh","-c","exit 7"]';

# An image reference that cannot be pulled: the A2 failed create.
my $BAD_IMAGE = 'docker.io/library/this-image-does-not-exist-ea4325:nope';

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

# Run a command AS $user with the rootless podman environment primed.
# The XDG_RUNTIME_DIR matters: `systemctl --user` under a bare `su -` cannot
# reach the user manager without it and silently reports nothing.
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

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub spew_as {
    my ( $path, $content, $user ) = @_;
    open my $fh, '>', $path or die "Could not write $path: $!";
    print {$fh} $content;
    close $fh;
    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    chown $uid, $gid, $path;
    return 1;
}

sub registry { return $json->( slurp($REGISTRY) // '{}' ) }

sub unit_prop {
    my ( $user, $container, $prop ) = @_;
    my ( $rc, $out ) = run_as_user( $user, "systemctl --user show container-$container.service -p $prop --value" );
    chomp $out;
    return $out;
}

sub running_image {
    my ( $user, $container ) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman inspect --format '{{.ImageName}}' " . _sh($container) );
    chomp $out;
    return $rc == 0 ? $out : '';
}

sub is_running {
    my ( $user, $container ) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman ps --format '{{.Names}}'" );
    return $out =~ m/^\Q$container\E$/m ? 1 : 0;
}

sub ports_held {
    my ( $user, $container ) = @_;
    my ( $rc, $out ) = run_cmd( $PORTAUTH, 'list', $user );
    my $n = 0;
    $n++ while $out =~ m/\Q$container\E/g;
    return $n;
}

sub container_field {
    my ( $user, $container, $format ) = @_;
    my ( $rc, $out ) = run_as_user( $user, "podman inspect --format " . _sh($format) . " " . _sh($container) );
    chomp $out;
    return $rc == 0 ? $out : '';
}

sub slurp_file {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub spew_file {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Could not write $path: $!";
    print {$fh} $content;
    close $fh;
    return 1;
}

sub skip_rest {
    my ( $why, $detail ) = @_;
    diag("SKIP: $why");
    diag($detail) if defined $detail;
    return;
}

sub container_dir {
    my ( $user, $container ) = @_;
    my $home = ( getpwnam($user) )[7];
    return "$home/ea-podman.d/$container";
}

# Rewrite the container's persisted start_args. The arbitrary-image upgrade path
# rebuilds every argument from this file, so it is the seam a test uses to make a
# container unstartable, or to point it at an image that cannot be pulled.
sub patch_start_args {
    my ( $user, $container, $mutate ) = @_;
    my $file = container_dir( $user, $container ) . "/ea-podman.json";
    my $conf = $json->( slurp($file) // die "no $file" );
    $mutate->( $conf->{start_args} );
    spew_as( $file, _encode($conf), $user );
    return 1;
}

sub _encode {
    my ($data) = @_;
    return Cpanel::JSON::pretty_canonical_dump($data) if defined &Cpanel::JSON::pretty_canonical_dump;
    return JSON::PP->new->pretty->canonical->encode($data);
}

sub cli_upgrade {
    my ( $user, $container ) = @_;
    my $t0 = Time::HiRes::time();
    my ( $rc, $out ) = run_as_user( $user, _sh($CLI_PATHS[0]) . " upgrade " . _sh($container) );
    return ( $rc, $out, Time::HiRes::time() - $t0 );
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

sub _in_path {
    my ($bin) = @_;
    for my $dir ( split /:/, ( $ENV{PATH} || '' ) ) { return 1 if -x "$dir/$bin" }
    return 0;
}

plan skip_all => "podman is not installed"                     if !_in_path('podman');
plan skip_all => "uapi not found ($UAPI)"                      if !-x $UAPI;
plan skip_all => "ea-podman library not installed"             if !-e "$EAP_LIB/util.pm";
plan skip_all => "cpuser_port_authority not found ($PORTAUTH)"  if !-x $PORTAUTH;

my ($CLI) = grep { -x $_ } @CLI_PATHS;
plan skip_all => "ea-podman CLI not found" if !$CLI;
$CLI_PATHS[0] = $CLI;

# The installed build must actually carry EA4-325, or every assertion below is
# testing the old behaviour and "failing" for the wrong reason. Checked against
# the compiled binary as well as the library, because the binary embeds its own
# copy of util.pm and is what the CLI actually runs.
{
    my $src = slurp("$EAP_LIB/util.pm") // plan skip_all => "cannot read $EAP_LIB/util.pm";
    plan skip_all => "installed ea-podman predates EA4-325 (no verify_container_started in util.pm); install and RECOMPILE the build under test"
      if $src !~ /verify_container_started/;

    my ( $rc, $out ) = run_cmd( 'grep', '-c', 'did not come back up', $CLI );
    plan skip_all => "the compiled ea-podman binary predates EA4-325 — util.pm was updated but compile.sh was not run"
      if $rc != 0;
}

# Increment B made `upgrade` PULL on every run, so this suite now consumes Docker
# Hub pulls at a rate the pre-B one never did -- roughly one per upgrade, across
# thirty subtests. An anonymous box has ~100 per 6h, and a second full run on the
# same IP will hit it.
#
# Checked up front because the failure is otherwise deeply confusing: the FORCED
# paths keep working (B4: force warns and falls back to the cached image) while
# the CONDITIONAL ones fail (B4: abort, container untouched), so a rate-limited
# box fails a scattered handful of subtests for reasons that look like logic bugs.
{
    my ( $prc, $pout ) = run_cmd( 'podman', 'pull', '-q', $IMAGE );
    plan skip_all => "Docker Hub rate limit reached on this host -- `podman login`, use a pull-through cache, or wait. Running anyway would fail the conditional-path subtests for an environmental reason:\n$pout"
      if $pout =~ m/toomanyrequests|rate limit/i;
}

my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';

#---------------------------------------------------------------------
# test accounts
#---------------------------------------------------------------------
our $USER;
our $CREATED_USER = 0;
our $ORIG_SHELL;
our $DEAD_USER;          # A3: deleted uncleanly while still registered
our $DEAD_CREATED = 0;
our $CLEAN_USER;         # root-side clean: an account with no registered containers
our $CLEAN_CREATED = 0;

sub make_account {
    my ( $name, $domain ) = @_;
    my $pw = 'Eap0d' . substr( time, -6 ) . '!Xy';
    my ( $rc, $res, $out, $err ) = run_json( $WHMAPI, 'createacct', "username=$name", "domain=$domain", "password=$pw", '--output=json' );
    return ( $res && $res->{metadata} && $res->{metadata}{result} ) ? 1 : 0;
}

if ( $ENV{EAPODMAN_TEST_USER} ) {
    $USER = $ENV{EAPODMAN_TEST_USER};
    plan skip_all => "EAPODMAN_TEST_USER '$USER' is not a system user" if !defined getpwnam($USER);
    $ORIG_SHELL = ( getpwnam($USER) )[8];
}
else {
    $USER = 'eap' . substr( time, -5 );
    diag("Creating throwaway cPanel account '$USER' …");
    plan skip_all => "could not create test account '$USER' (set EAPODMAN_TEST_USER to reuse one)"
      if !make_account( $USER, "$USER.ea4325.test" );
    $CREATED_USER = 1;
}

$ORIG_SHELL //= ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', $BASH, $USER );
my $uid = ( getpwnam($USER) )[2];

diag("Test user: $USER (uid=$uid), cgroup=$CGROUP, image=$IMAGE, port=$PORT");

#=====================================================================
# the tests
#=====================================================================

#--- install the container everything else works on ------------------
my $container;
{
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " install $CBASE --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    ($container) = $out =~ m/Done, installed:\s*(\S+)/;
    ok( $container, "installed a container to work on" ) or do {
        diag($out);
        done_testing();
        exit;
    };
    diag("container: $container");
}

my $CDIR = container_dir( $USER, $container );

#---------------------------------------------------------------------
# A4 — the image name carries no trailing newline
#---------------------------------------------------------------------
subtest 'A4: get_containers does not leave a newline on the image' => sub {
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " list" );
    my $listed = eval { $json->($out) } or do { diag($out); return fail("ea-podman list emitted JSON") };

    my $image = $listed->{$container} && $listed->{$container}{image};
    ok( defined $image, "list reports an image for $container" );

    # The bug: split(" ", $line, 2) let the second field absorb podman's newline,
    # so this used to be "docker.io/library/httpd:2.4\n" and showed up as an
    # escaped \n inside the JSON string. Harmless in `list`, fatal to any
    # comparison built on the field.
    unlike( $image // '', qr/\n/,  "the image has no embedded newline" );
    unlike( $image // '', qr/\s\z/, "and no trailing whitespace of any kind" );
};

#---------------------------------------------------------------------
# A1 — a failed start is a failure
#---------------------------------------------------------------------
subtest 'A1: a healthy upgrade still succeeds, and stays quick' => sub {
    my ( $rc, $out, $secs ) = cli_upgrade( $USER, $container );

    is( $rc, 0, "a healthy upgrade exits 0" ) or diag($out);
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and the container is up" );

    # The verdict confirms an `active` sighting before believing it, which costs
    # a successful upgrade one confirm interval and nothing more. The generous
    # bound is deliberate: this asserts we are not waiting out the ~15s restart
    # window on success, not a precise timing.
    cmp_ok( $secs, '<', 10, sprintf( "a healthy upgrade does not wait out the restart window (%.1fs)", $secs ) );
};

subtest 'A1: an upgrade that leaves the container down exits non-zero' => sub {
    patch_start_args(
        $USER, $container,
        sub {
            my ($args) = @_;
            my $image = pop @{$args};
            push @{$args}, '--entrypoint', $BAD_ENTRYPOINT, $image;
        }
    );

    # --force, and this is the whole reason CPANEL-56732 exists. Since Increment
    # B a plain `upgrade` compares images and does nothing when none moved -- and
    # editing start args does not move the image, so the break above would never
    # reach the container. Anything applying a configuration change has to force,
    # which is exactly what the webapp plugin's Redeploy now does.
    my $t0 = Time::HiRes::time();
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    my $secs = Time::HiRes::time() - $t0;

    # THE defect. Before EA4-325 this was exit 0 in ~2.5s with the application
    # down, because sysctl( start => ... )'s return was never looked at.
    isnt( $rc, 0, "the upgrade reports failure" ) or diag($out);
    is( unit_prop( $USER, $container, 'ActiveState' ), 'failed', "and the unit really is failed" );

    # It must not return before the outcome is knowable. systemd retries
    # StartLimitBurst times at RestartSec apart, so a verdict cannot exist
    # earlier than that; anything much faster means we checked once and guessed.
    cmp_ok( $secs, '>', 10, sprintf( "it waited for a terminal verdict rather than checking once (%.1fs)", $secs ) );

    # The message has to be actionable, not just non-zero.
    like( $out, qr/did not come back up/,          "says the container did not come back up" );
    like( $out, qr/not a half-applied upgrade/,    "says the upgrade itself completed" );
    like( $out, qr/systemctl --user status/,       "names systemctl status" );
    like( $out, qr/journalctl --user -u/,          "names journalctl" );
    like( $out, qr/podman logs \Q$container\E/,    "names podman logs" );
    like( $out, qr/ea-podman upgrade \Q$container\E/, "names the retry" );
};

#---------------------------------------------------------------------
# _lifecycle — the same lie, in the UAPI
#---------------------------------------------------------------------
subtest 'UAPI start reports a bring-up that did not happen' => sub {
    # Still broken from the subtest above.
    run_as_user( $USER, "systemctl --user stop container-$container.service; systemctl --user reset-failed container-$container.service" );

    my $res = uapi( $USER, 'start', "container_name=$container" );

    # Checking systemctl's boolean alone would NOT have caught this: `systemctl
    # start` succeeds for a container that starts and then dies, so _lifecycle
    # has to poll to the same verdict the CLI does.
    ok( !$res->{status}, "uapi EAPodman start reports failure" );
    like( join( " ", @{ $res->{errors} || [] } ), qr/did not start/, "and says so" );
};

#--- put it back together for the rest --------------------------------
{
    patch_start_args(
        $USER, $container,
        sub {
            my ($args) = @_;
            @{$args} = grep { $_ ne '--entrypoint' && $_ ne $BAD_ENTRYPOINT } @{$args};
        }
    );

    # --force, or this repair silently does nothing: removing the entrypoint does
    # not move the image, so since Increment B a plain upgrade is a no-op here and
    # returns 0 while leaving the container just as broken. Assert the container is
    # actually up rather than trusting the exit code, which is what hid it.
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    is( $rc, 0, "the container is repaired for the remaining subtests" ) or diag($out);
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and is genuinely running again" );
}

subtest 'UAPI stop stays permissive, so teardown paths keep working' => sub {
    my $first = uapi( $USER, 'stop', "container_name=$container" );
    ok( $first->{status}, "stopping a running container succeeds" );

    # Deliberately asymmetric: an already-stopped unit, a missing unit file and
    # an already-removed container all mean the caller got what they asked for.
    my $again = uapi( $USER, 'stop', "container_name=$container" );
    ok( $again->{status}, "stopping an already-stopped container still succeeds" );

    my $up = uapi( $USER, 'start', "container_name=$container" );
    ok( $up->{status}, "and a healthy start still succeeds" );
};

#---------------------------------------------------------------------
# A2 — a failed create recreates rather than destroys
#---------------------------------------------------------------------
subtest 'A2: a failed upgrade recreates the previous container' => sub {
    my $was_running_image = running_image( $USER, $container );
    my $registry_before   = slurp($REGISTRY);
    my $ports_before      = ports_held( $USER, $container );

    patch_start_args(
        $USER, $container,
        sub { my ($args) = @_; $args->[-1] = $BAD_IMAGE; }
    );

    # --force for a second Increment B reason: on the conditional path an
    # unpullable image now aborts BEFORE anything is torn down (B4), so the
    # failed-CREATE rollback this subtest exists for is unreachable. Force warns
    # about the pull, carries on to the create from cache, and the create is what
    # fails -- which is the state Increment A has to recover from.
    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );

    # Before EA4-325: exit 125 with the container AND its unit destroyed, the
    # registry asserting a container that did not exist, and the ports still
    # held by nothing.
    isnt( $rc, 0, "the upgrade reports failure" );
    ok( is_running( $USER, $container ), "the container is running again" );
    is( running_image( $USER, $container ), $was_running_image, "on the image it was running before" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "with its unit active" );

    ok( -d $CDIR, "the container directory is untouched" );
    is( slurp($REGISTRY), $registry_before, "and the registry is byte-identical — it still describes what is really there" );
    is( ports_held( $USER, $container ), $ports_before, "the ports are still held" );

    like( $out, qr/is running again/,                     "the message says service is restored" );
    like( $out, qr/the upgrade did not happen/,           "but is explicit the upgrade did not happen" );
    like( $out, qr/Nothing was deregistered and nothing was deleted/, "and promises nothing was destroyed" );

    # Repair for what follows -- force, since the image is back to where it was
    # and a conditional upgrade would rightly call that a no-op.
    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE; } );
    run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
};

#---------------------------------------------------------------------
# A2 — the packaged path, where old and new images genuinely differ
#---------------------------------------------------------------------
SKIP: {
    my $pkg_conf = "/opt/cpanel/$PKG/ea-podman.json";
    my $pkg_ver  = "/opt/cpanel/$PKG/pkg-version";
    skip "$PKG is not installed (packaged-container path not covered)", 1 if !-e $pkg_conf;

    subtest "A2: packaged container keeps its recorded version when an upgrade fails" => sub {
        my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " install " . _sh($PKG) );
        my ($pcontainer) = $out =~ m/Done, installed:\s*(\S+)/;
        ok( $pcontainer, "installed a $PKG container" ) or do { diag($out); return };

        my $conf_before = slurp($pkg_conf);
        my $ver_before  = slurp($pkg_ver);
        my $good_image  = running_image( $USER, $pcontainer );
        my $registered  = registry()->{$pcontainer};

        # For a packaged container the image pin comes from the RPM, not from the
        # container's persisted start_args — so this is the only way to make the
        # previous and the new image GENUINELY different, which is the case the
        # recreate exists for. It also gives a non-null pkg_version.
        my $conf = $json->($conf_before);
        $conf->{image} = $BAD_IMAGE;
        spew_as( $pkg_conf, _encode($conf), 'root' );
        spew_as( $pkg_ver, '9.9.9', 'root' );

        my ( $urc, $uout ) = cli_upgrade( $USER, $pcontainer );

        isnt( $urc, 0, "the upgrade reports failure" );
        is( running_image( $USER, $pcontainer ), $good_image, "the container is back on the image the RPM used to pin" );
        is( unit_prop( $USER, $pcontainer, 'ActiveState' ), 'active', "and is up" );

        # The registry write is deferred until after a successful create, so a
        # failed upgrade must not record a version that was never installed.
        is( registry()->{$pcontainer}{pkg_version}, $registered->{pkg_version}, "the recorded pkg_version is unchanged, not 9.9.9" );

        # Put the package back, then prove a real upgrade still lands.
        spew_as( $pkg_conf, $conf_before, 'root' );
        spew_as( $pkg_ver,  $ver_before,  'root' );
        my ( $rrc, $rout ) = cli_upgrade( $USER, $pcontainer );
        is( $rrc, 0, "a genuine upgrade still succeeds afterwards" ) or diag($rout);

        run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($pcontainer) . " --verify" );
    };
}

#---------------------------------------------------------------------
# A2 — the restore path, which used to delete the user's only copy
#---------------------------------------------------------------------
subtest 'A2: a failed restore keeps the directory it just extracted' => sub {
    # A stand-in for whatever the user cannot get back: runtime state, .env, a
    # zip-sourced app's entire source.
    my $sentinel = "$CDIR/EA4325-SENTINEL.txt";
    spew_as( $sentinel, "the user's irreplaceable data\n", $USER );

    # Back up a container that cannot be created, so the restore untars the
    # directory (sentinel included) and then fails.
    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $BAD_IMAGE; } );
    run_as_user( $USER, _sh($CLI) . " backup" );

    # `restore` takes the TARBALL, not the ea_podman_backup_<user>.json manifest
    # — that manifest is tarred and then unlinked, so it no longer exists.
    my $home = ( getpwnam($USER) )[7];
    my ($tarball) = reverse sort glob("$home/ea-podman-backups/backup-*.tar.gz");
    ok( $tarball, "backup wrote a tarball" ) or return;

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " restore " . _sh($tarball) . " --verify" );

    isnt( $rc, 0, "the restore reports failure" );

    # THE defect. perform_user_restore() removes ~/ea-podman.d before untarring,
    # so this directory is the only copy. The cleanup branch was gated
    # `if ( !$isupgrade )` — true for a restore — so it used to be deleted.
    ok( -d $CDIR,     "the container directory survives the failed restore" );
    ok( -e $sentinel, "and so does the data inside it" );
    ok( -e "$CDIR/ea-podman.json", "and its persisted start args" );
    ok( registry()->{$container}, "the container is still registered" );

    like( $out, qr/only copy of it/,                    "the message says why the directory was kept" );
    like( $out, qr/ea-podman upgrade \Q$container\E/,   "and names the in-place retry" );

    # Repair: `upgrade` is the documented in-place retry, and reuses the ports
    # the restore already assigned rather than taking a fresh set.
    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE; } );
    my ( $urc, $uout ) = cli_upgrade( $USER, $container );
    is( $urc, 0, "and `ea-podman upgrade` really does recover it in place" ) or diag($uout);

    unlink $sentinel;
};

#---------------------------------------------------------------------
# Increment B — pull, compare, and do nothing when nothing moved
#---------------------------------------------------------------------

# The assertion that matters most, and the one a mock cannot make: an upgrade
# with nothing to do must not touch the container at all. Before B this tore the
# container down and recreated it every single time -- and never pulled, because
# `podman create` inherits --pull=missing -- so a nightly sweep restarted every
# application on the server and still fetched nothing.
subtest 'B: an upgrade with nothing to do does not touch the container' => sub {
    my $id_before      = container_field( $USER, $container, '{{.Id}}' );
    my $started_before = container_field( $USER, $container, '{{.State.StartedAt}}' );

    my ( $rc, $out, $secs ) = cli_upgrade( $USER, $container );

    is( $rc, 0, "the upgrade succeeds" ) or diag($out);
    like( $out, qr/already up to date/, "and says it had nothing to do" );

    # Identity is the proof. A recreate mints a new container instance, so an
    # unchanged instance ID means no teardown happened at all.
    is( container_field( $USER, $container, '{{.Id}}' ),               $id_before,      "the container instance is the same one" );
    is( container_field( $USER, $container, '{{.State.StartedAt}}' ),  $started_before, "and it was never restarted" );

    return;
};

subtest 'B: --force recreates even when nothing moved' => sub {
    my $id_before = container_field( $USER, $container, '{{.Id}}' );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );

    is( $rc, 0, "the forced upgrade succeeds" ) or diag($out);
    isnt( container_field( $USER, $container, '{{.Id}}' ), $id_before, "and the container really was recreated" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and is running" );

    return;
};

# "The image moved" without controlling a registry: install from one tag, then
# point the container's persisted start args at another. The configured
# reference now resolves to an image ID that is not the one the container was
# created from, which is exactly the real-world condition.
subtest 'B: a container whose configured image now resolves elsewhere is recreated' => sub {
    my $alt = $ENV{EAPODMAN_TEST_ALT_IMAGE} || 'docker.io/library/httpd:2.4-alpine';

    my ( $prc, $pout ) = run_as_user( $USER, "podman pull " . _sh($alt) );
    skip_rest( "could not pull the alternate image $alt", $pout ), return if $prc != 0;

    my $id_before = container_field( $USER, $container, '{{.Id}}' );
    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $alt } );

    my ( $rc, $out ) = cli_upgrade( $USER, $container );

    is( $rc, 0, "the upgrade succeeds" ) or diag($out);
    unlike( $out, qr/already up to date/, "it did not consider this a no-op" );
    isnt( container_field( $USER, $container, '{{.Id}}' ), $id_before, "the container was recreated" );

    # Put it back, and prove the gate is symmetric rather than just always-yes.
    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE } );
    cli_upgrade( $USER, $container );
    my ( $rc2, $out2 ) = cli_upgrade( $USER, $container );
    like( $out2, qr/already up to date/, "and settles back to a no-op once it matches again" );

    return;
};

# B4. The two paths want opposite answers from the same failure.
subtest 'B: a failed pull leaves the container untouched, unless forced' => sub {
    my $id_before = container_field( $USER, $container, '{{.Id}}' );

    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $BAD_IMAGE } );

    my ( $rc, $out ) = cli_upgrade( $USER, $container );

    isnt( $rc, 0, "the upgrade refuses rather than guessing" );
    like( $out, qr/Could not pull/,       "and says why" );
    like( $out, qr/has NOT been touched/, "and that the container is unharmed" );

    # The whole point: a working container is not torn down on a guess.
    is( container_field( $USER, $container, '{{.Id}}' ), $id_before, "the container really was left alone" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and is still running" );

    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE } );
    return;
};

# An image that exists locally but in no registry: the pull fails, the cached
# copy is there, and force must carry on from it. This is the shape of a Docker
# Hub outage or a rate limit, which must never break the plugin's Redeploy.
subtest 'B: force falls back to the cached image when the pull fails' => sub {
    my $local_only = 'localhost/ea4325-cached-only:1';
    run_as_user( $USER, "podman tag " . _sh($IMAGE) . " " . _sh($local_only) );

    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $local_only } );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );

    is( $rc, 0, "the forced upgrade still succeeds" ) or diag($out);
    like( $out, qr/already cached locally/, "and reports the fallback rather than swallowing it" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "the application is up" );

    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE } );
    run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    return;
};

# B7. A deliberate stop cannot be told from a crash, so the conditional path
# must never start something the user stopped.
subtest 'B: a stopped container is recreated but left stopped' => sub {
    my $alt = $ENV{EAPODMAN_TEST_ALT_IMAGE} || 'docker.io/library/httpd:2.4-alpine';

    run_as_user( $USER, "systemctl --user stop container-$container.service" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'inactive', "the container is stopped to begin with" );

    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $alt } );
    my ( $rc, $out ) = cli_upgrade( $USER, $container );

    is( $rc, 0, "the upgrade succeeds" ) or diag($out);
    is( unit_prop( $USER, $container, 'ActiveState' ), 'inactive', "and the container it recreated is still stopped" );

    # Force is the deliberate exception -- the plugin's redeploy branch has no
    # start of its own and relies on it.
    my ( $frc, $fout ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    is( $frc, 0, "a forced upgrade succeeds" ) or diag($fout);
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and brings it back up" );

    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE } );
    run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    return;
};

# The interaction between the two increments, and the one most likely to be
# wrong: Increment A raises when a container did not come back up. If that
# verdict is not gated on having actually started something, a sweep across a
# server with one deliberately stopped container exits non-zero -- inverting the
# trustworthy exit code A exists to provide.
subtest 'B x A: a sweep over a stopped container still exits 0' => sub {
    run_as_user( $USER, "systemctl --user stop container-$container.service" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'inactive', "the container is stopped" );

    my ( $rc, $out ) = run_cmd( $CLI, 'upgrade_containers', '--all' );

    is( $rc, 0, "the sweep exits 0 -- a container it correctly left alone is not a failure" ) or diag($out);
    is( unit_prop( $USER, $container, 'ActiveState' ), 'inactive', "and it stayed stopped" );

    run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    return;
};

# B8, as decided: an EA4 package owns both the image pin and the start args, so
# the package version is the question -- an image-only gate would silently skip
# a package update that changed `startup` flags with the same image.
SKIP: {
    my $pkg_ver = "/opt/cpanel/$PKG/pkg-version";
    skip "$PKG is not installed (packaged gate not covered)", 1 if !-e $pkg_ver;

    subtest "B: a packaged container is gated on its package version" => sub {
        my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install " . _sh($PKG) );
        my ($pc) = $iout =~ m/Done, installed:\s*(\S+)/;
        ok( $pc, "installed a $PKG container" ) or do { diag($iout); return };

        my ( $rc, $out ) = cli_upgrade( $USER, $pc );
        like( $out, qr/already up to date/, "nothing changed, so nothing is done" );

        my $id_before = container_field( $USER, $pc, '{{.Id}}' );

        # Same image, newer package: the case an image-only gate gets wrong.
        my $orig = slurp_file($pkg_ver);
        spew_file( $pkg_ver, "999.999.999" );

        my ( $urc, $uout ) = cli_upgrade( $USER, $pc );
        is( $urc, 0, "the upgrade succeeds" ) or diag($uout);
        unlike( $uout, qr/already up to date/, "a newer package version is not a no-op" );
        isnt( container_field( $USER, $pc, '{{.Id}}' ), $id_before, "the container was recreated for the package change alone" );

        spew_file( $pkg_ver, $orig );
        run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($pc) . " --verify" );
        return;
    };
}

#---------------------------------------------------------------------
# Increment C — `ea-podman clean` for leftover <container>.bak
#---------------------------------------------------------------------

subtest 'C: clean lists a backup, warns about it, and removes it only when asked' => sub {
    # Make a real one the way a real one is made.
    my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install cleanme --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($cn) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $cn, "installed a container to make a backup from" ) or do { diag($iout); return };

    run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($cn) . " --verify" );
    my $bak = container_dir( $USER, $cn ) . ".bak";
    ok( -d $bak, "uninstall left a .bak behind" ) or return;

    # A brand new backup must survive the default threshold.
    my ( $drc, $dout ) = run_as_user( $USER, _sh($CLI) . " clean" );
    is( $drc, 0, "a default clean succeeds" );
    ok( -d $bak, "and a backup made seconds ago is not touched" );

    # C8: the warning belongs in the DEFAULT listing, while the operator is
    # still deciding -- `--run` is the only safeguard there is.
    like( $dout, qr/only copy/, "the default listing warns what a .bak can hold" );
    like( $dout, qr/Listing only/, "and says it is only listing" );

    # In scope now, but still only listed.
    my ( $lrc, $lout ) = run_as_user( $USER, _sh($CLI) . " clean --days=0" );
    like( $lout, qr/\Q$bak\E/, "with a lowered threshold it is listed" );
    like( $lout, qr/could be removed/, "as something that could be removed" );
    ok( -d $bak, "but listing still does not remove it" );

    my ( $rrc, $rout ) = run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );
    is( $rrc, 0, "clean --run succeeds" ) or diag($rout);
    like( $rout, qr/REMOVED/, "and reports the removal" );
    ok( !-d $bak, "the backup is gone" );

    return;
};

# C2, and the reason the ticket calls it out. Renaming a directory moves its
# ctime and leaves mtime alone, so a `.bak` made one second ago still carries
# the mtime of its last deploy -- an mtime rule would delete backups made
# moments earlier, which is the exact opposite of the intent. Only a real
# filesystem can demonstrate the difference.
subtest 'C: a brand new backup with an ancient mtime is still too recent' => sub {
    my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install ctimeprobe --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($cn) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $cn, "installed a container" ) or do { diag($iout); return };

    run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($cn) . " --verify" );
    my $bak = container_dir( $USER, $cn ) . ".bak";
    ok( -d $bak, "with a .bak" ) or return;

    # A year old by mtime. Seconds old by ctime, which is what counts.
    run_cmd( 'touch', '-d', '1 year ago', $bak );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " clean --run" );

    ok( -d $bak, "the backup survives a default clean" );
    unlike( $out, qr/REMOVED/, "and nothing was removed" );

    run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );
    ok( !-d $bak, "it is reachable once the threshold is lowered, so this was the age rule and not an accident" );

    return;
};

# C5. get_next_available_container_name() checks only the container directory --
# not podman, not the ports, not the unit -- so freeing a name still claimed
# elsewhere hands it to the next install with stale state attached.
subtest 'C: a backup whose name is still claimed is kept, and says by what' => sub {
    my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install stillheld --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($cn) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $cn, "installed a LIVE container" ) or do { diag($iout); return };

    # A .bak carrying the same name as something that still exists.
    my $bak = container_dir( $USER, $cn ) . ".bak";
    run_cmd( 'mkdir', '-p', $bak );
    my ( $uid, $gid ) = ( getpwnam($USER) )[ 2, 3 ];
    chown $uid, $gid, $bak;

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );

    ok( -d $bak, "the backup is kept" );
    like( $out, qr/still in use/, "and the reason is reported" );
    like( $out, qr/orphan-reconciliation/, "pointing at EA4-320 rather than bulldozing it" );

    # The live container is untouched by any of this.
    is( unit_prop( $USER, $cn, 'ActiveState' ), 'active', "and its live container is still running" );

    run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($cn) . " --verify" );
    run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );

    return;
};

# C6. A hand-made directory is excluded by its NAME, not by a guess about what
# is inside it.
subtest 'C: a directory that is not a container backup is never touched' => sub {
    my $home     = ( getpwnam($USER) )[7];
    my $handmade = "$home/ea-podman.d/just-my-stuff.bak";
    run_cmd( 'mkdir', '-p', $handmade );
    my ( $uid, $gid ) = ( getpwnam($USER) )[ 2, 3 ];
    chown $uid, $gid, $handmade;

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );

    ok( -d $handmade, "a directory whose name is not <name>.<user>.<NN> is left alone" );

    run_cmd( 'rm', '-rf', $handmade );
    return;
};

#---------------------------------------------------------------------
# Two error paths live coverage had been missing
#---------------------------------------------------------------------

# The verdict poll's `inactive` branch splits on Result, and neither half was
# exercised live. SuccessExitStatus=143 classifies a SIGTERM-style exit as clean,
# so Restart=on-failure does not retry it: the unit settles inactive/success and
# the verdict is `stopped`, not `failed`. This is also the only test that proves
# that directive does anything.
#
# The exit must be IMMEDIATE. Anything that lives longer than the 0.5s
# confirmation window lets the poll see a settled `active` and the subtest passes
# for the wrong reason.
subtest 'the verdict tells a clean stop from a crash' => sub {
    my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install stopprobe --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($c) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $c, "installed a container of its own" ) or do { diag($iout); return };

    patch_start_args(
        $USER, $c,
        sub {
            my ($args) = @_;
            my $image = pop @{$args};
            push @{$args}, '--entrypoint', '["/bin/sh","-c","exit 143"]', $image;
        }
    );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($c) . " --force" );

    isnt( $rc, 0, "the upgrade reports failure" );
    is( unit_prop( $USER, $c, 'ActiveState' ), 'inactive', "the unit settled inactive rather than failed" );
    is( unit_prop( $USER, $c, 'Result' ),      'success',  "and systemd called the exit clean, per SuccessExitStatus=143" );

    # The pair that distinguishes `stopped` from `failed` unambiguously: this
    # wording and the session hint are emitted only for stopped/unknown.
    like( $out, qr/is not running/,        "reported as not running rather than failed" );
    like( $out, qr/ensure_user_sessions/,  "with the session hint the two share" );

    run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($c) . " --verify" );
    run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );
    return;
};

# Live only ever saw the rollback SUCCEED. This is the bottom rung: the
# rollback's own create fails too, so the container is gone and has no unit --
# and the message has to promise, truthfully, that nothing was destroyed.
#
# The lever is a bogus start ARG, not a bogus image: _rollback_failed_upgrade
# replaces only $args[-1], so a bad flag survives into the retry and both creates
# fail. That is exactly what the code comment claims -- "a failure which is not
# the image pin recurs here" -- and nothing asserted it.
subtest 'a rollback that cannot recreate either says so, and still destroys nothing' => sub {
    my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install rbprobe --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($c) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $c, "installed a container of its own" ) or do { diag($iout); return };

    my $cdir              = container_dir( $USER, $c );
    my $registry_before   = slurp($REGISTRY);
    my $ports_before      = ports_held( $USER, $c );

    patch_start_args(
        $USER, $c,
        sub {
            my ($args) = @_;
            my $image = pop @{$args};
            push @{$args}, '--ea4325-not-a-flag', $image;
        }
    );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($c) . " --force" );

    isnt( $rc, 0, "the upgrade reports failure" );
    like( $out, qr/could not be recreated from/,            "the message reaches the bottom rung" );
    like( $out, qr/is not running and has no systemd unit/, "and is honest that the container is gone" );

    # The promise the message makes, asserted rather than taken on trust.
    like( $out, qr/Nothing was deregistered and nothing was deleted/, "it promises nothing was destroyed" );
    is( slurp($REGISTRY), $registry_before, "and the registry really is byte-identical" );
    is( ports_held( $USER, $c ), $ports_before, "the ports are still held" );
    ok( -d $cdir, "and the container directory survives" );

    # `upgrade` is the documented in-place retry, even with no container left.
    patch_start_args( $USER, $c, sub { my ($args) = @_; @{$args} = grep { $_ ne '--ea4325-not-a-flag' } @{$args} } );
    my ( $frc, $fout ) = run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($c) . " --force" );
    is( $frc, 0, "and it recovers in place once the cause is fixed" ) or diag($fout);
    is( unit_prop( $USER, $c, 'ActiveState' ), 'active', "with the container running again" );

    run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($c) . " --verify" );
    run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );
    return;
};

#---------------------------------------------------------------------
# Root-side and UAPI paths that nothing else reaches
#---------------------------------------------------------------------

# THE subtest that catches the bug this file existed to look for.
#
# Root's `clean` used to build its account list from the container registry. But
# a `.bak` exists BECAUSE a container was removed, and removing one deregisters
# it -- so an account that removed all of its containers has no registry entries
# and was never visited. `remove_containers --all` is exactly how a pile of
# backups appears, so the accounts most likely to need cleaning were the ones
# silently skipped.
subtest 'root: clean reaches an account with no registered containers left' => sub {
    $CLEAN_USER = 'cln' . substr( time, -5 );
    if ( !make_account( $CLEAN_USER, "$CLEAN_USER.ea4325.test" ) ) {
        $CLEAN_USER = undef;
        return fail("could not create the second account");
    }
    $CLEAN_CREATED = 1;
    run_cmd( '/usr/sbin/usermod', '-s', $BASH, $CLEAN_USER );

    my ( $irc, $iout ) = run_as_user( $CLEAN_USER, _sh($CLI) . " install lonely --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($cn) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $cn, "the second account has a container" ) or do { diag($iout); return };

    # Remove ALL of its containers: the .bak survives, the registry entry does not.
    run_as_user( $CLEAN_USER, _sh($CLI) . " remove_containers --all" );

    my $home = ( getpwnam($CLEAN_USER) )[7];
    my $bak  = "$home/ea-podman.d/$cn.bak";
    ok( -d $bak, "which left a .bak behind" ) or return;
    ok( !registry()->{$cn}, "and no registry entry at all" );

    # Root sweeps every account, not just the ones the registry still lists.
    my ( $rc, $out ) = run_cmd( $CLI, 'clean', '--run', '--days=0' );

    is( $rc, 0, "root's clean succeeds" ) or diag($out);
    ok( !-d $bak, "and it reached an account the registry no longer knows about" );
    like( $out, qr/\Q$CLEAN_USER\E/, "naming that account in its report" );

    return;
};

# The UAPI's force plumbing had no test of any kind -- not unit, not live.
subtest 'UAPI upgrade accepts force and recreates when nothing moved' => sub {
    my $id_before = container_field( $USER, $container, '{{.Id}}' );

    # No force first: the UAPI inherits safe mode, so this must be a no-op.
    my $plain = uapi( $USER, 'upgrade', "container_name=$container" );
    ok( $plain->{status}, "a plain UAPI upgrade succeeds" );
    is( container_field( $USER, $container, '{{.Id}}' ), $id_before, "and changes nothing, because nothing moved" );

    my $forced = uapi( $USER, 'upgrade', "container_name=$container", 'force=1' );
    ok( $forced->{status}, "a forced UAPI upgrade succeeds" );
    isnt( container_field( $USER, $container, '{{.Id}}' ), $id_before, "and really does recreate the container" );

    return;
};

subtest 'UAPI restart reports a bring-up that did not happen' => sub {
    # _lifecycle backs start, stop and restart; restart shares the raise-on-failure
    # path but was never exercised.
    my $ok = uapi( $USER, 'restart', "container_name=$container" );
    ok( $ok->{status}, "restarting a healthy container succeeds" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and it is up" );

    patch_start_args(
        $USER, $container,
        sub {
            my ($args) = @_;
            my $image = pop @{$args};
            push @{$args}, '--entrypoint', $BAD_ENTRYPOINT, $image;
        }
    );
    run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );

    my $bad = uapi( $USER, 'restart', "container_name=$container" );
    ok( !$bad->{status}, "restarting a container that will not start reports failure" );

    patch_start_args(
        $USER, $container,
        sub {
            my ($args) = @_;
            @{$args} = grep { $_ ne '--entrypoint' && $_ ne $BAD_ENTRYPOINT } @{$args};
        }
    );
    run_as_user( $USER, _sh($CLI) . " upgrade " . _sh($container) . " --force" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and the container is healthy again" );

    return;
};

# B5's --force on the sweep, and the per-user loop surviving one bad container.
subtest 'upgrade_containers --all --force recreates everything, and survives one failure' => sub {
    my ( $irc, $iout ) = run_as_user( $USER, _sh($CLI) . " install second --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($second) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $second, "a second container for the same account" ) or do { diag($iout); return };

    my %before = map { $_ => container_field( $USER, $_, '{{.Id}}' ) } ( $container, $second );

    my ( $rc, $out ) = run_cmd( $CLI, 'upgrade_containers', '--all', '--force' );
    is( $rc, 0, "the forced sweep succeeds" ) or diag($out);

    for my $c ( $container, $second ) {
        isnt( container_field( $USER, $c, '{{.Id}}' ), $before{$c}, "$c was recreated even though no image moved" );
    }

    # One container's failure must not abandon the rest of that account's, and
    # must still surface as a non-zero exit.
    patch_start_args( $USER, $second, sub { my ($args) = @_; $args->[-1] = $BAD_IMAGE } );
    %before = map { $_ => container_field( $USER, $_, '{{.Id}}' ) } ($container);

    my ( $frc, $fout ) = run_cmd( $CLI, 'upgrade_containers', '--all', '--force' );

    isnt( $frc, 0, "a sweep with one broken container exits non-zero" );
    isnt( container_field( $USER, $container, '{{.Id}}' ), $before{$container}, "but the healthy container was still upgraded" );

    run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($second) . " --verify" );
    run_as_user( $USER, _sh($CLI) . " clean --run --days=0" );
    return;
};

#---------------------------------------------------------------------
# A3 — the sweep survives a dead account, and still fails loudly
#---------------------------------------------------------------------
subtest 'A3: upgrade_containers --all survives a deleted account' => sub {
    # Deliberately sorts BEFORE the main account, so that if the sweep aborts on
    # it the main account is demonstrably left unprocessed. A dead account that
    # sorted last would pass even with the bug.
    $DEAD_USER = 'aa' . substr( time, -6 );
    if ( !make_account( $DEAD_USER, "$DEAD_USER.ea4325.test" ) ) {
        $DEAD_USER = undef;
        return skip_all_in_subtest("could not create the second account");
    }
    $DEAD_CREATED = 1;
    run_cmd( '/usr/sbin/usermod', '-s', $BASH, $DEAD_USER );

    my ( $irc, $iout ) = run_as_user( $DEAD_USER, _sh($CLI) . " install $CBASE --i-understand-the-risks-do-it-anyway --cpuser-port=$PORT " . _sh($IMAGE) );
    my ($dead_container) = $iout =~ m/Done, installed:\s*(\S+)/;
    ok( $dead_container, "the second account has a container" ) or do { diag($iout); return };

    # Delete the account WITHOUT going through cPanel, leaving its containers
    # registered — the ZC-10958 shape.
    run_cmd( 'pkill', '-9', '-u', $DEAD_USER );
    sleep 1;
    run_cmd( '/usr/sbin/userdel', '-f', $DEAD_USER );
    ok( !defined getpwnam($DEAD_USER), "the account is gone" );
    ok( registry()->{$dead_container}, "but its container is still registered" );

    my ( $rc, $out ) = run_cmd( $CLI, 'upgrade_containers', '--all' );

    # Surviving must not mean going quiet: a registry entry for a vanished
    # account is a real problem and must not exit 0.
    isnt( $rc, 0, "the sweep exits non-zero" );
    like( $out, qr/skipping .*\Q$DEAD_USER\E/, "it names the account it skipped" );
    like( $out, qr/remove_containers --all/,   "and points at the command that cleans it up" );
    like( $out, qr/did not complete for:.*\Q$DEAD_USER\E/, "and summarises the failure" );

    # The point of the fix: the accounts after the dead one are still processed.
    #
    # Since Increment B, "processed" no longer means "restarted" -- a live
    # account whose images have not moved is correctly a no-op, so a changed
    # ActiveEnterTimestamp would now be evidence of a BUG rather than of the
    # sweep working. The sweep's own report is the proof instead.
    like( $out, qr/\Q$container\E.*already up to date|already up to date/, "the live account sorted after the dead one was still reached" );
    is( unit_prop( $USER, $container, 'ActiveState' ), 'active', "and is still up" );

    # `remove_containers --all` is what the message recommends; prove it works.
    run_cmd( $CLI, 'remove_containers', '--all' );
    ok( !registry()->{$dead_container}, "remove_containers --all clears the dead account's entry" );
    $container = undef;    # that sweep removed ours too
};

sub skip_all_in_subtest {
    my ($why) = @_;
    plan skip_all => $why;
    return;
}

# The startup check cannot catch a limit reached DURING the run, and this suite
# spends pulls freely -- every install and every conditional upgrade is one. When
# that happens the failures are scattered and misleading: the forced paths keep
# passing from cache (B4) while the conditional ones abort (B4), so it reads like
# a logic bug in the gate. Say so plainly instead of leaving it to be rediscovered.
{
    my ( $prc, $pout ) = run_cmd( 'podman', 'pull', '-q', $IMAGE );
    diag( "\n"
          . "!! This host is now rate limited by the registry. Any failures above on the\n"
          . "!! CONDITIONAL paths (a plain `upgrade`, a plain UAPI upgrade, an install) are\n"
          . "!! environmental, not defects: a failed pull deliberately aborts with the\n"
          . "!! container untouched. The forced paths fall back to the cached image and\n"
          . "!! keep passing, which is what makes the pattern confusing.\n"
          . "!! Re-run once the window clears." )
      if $pout =~ m/toomanyrequests|rate limit/i;
}

done_testing();

#---------------------------------------------------------------------
# teardown
#---------------------------------------------------------------------
END {
    return if $KEEP;
    return if !$USER;

    if ( defined $container ) {
        run_as_user( $USER, _sh($CLI) . " uninstall " . _sh($container) . " --verify" );
    }
    run_cmd( $CLI, 'remove_containers', '--all' );

    my $uid_t = ( getpwnam($USER) )[2];
    run_cmd( 'loginctl', 'disable-linger', $USER )         if defined $uid_t;
    run_cmd( 'systemctl', 'stop', "user\@$uid_t.service" ) if defined $uid_t;

    if ($CREATED_USER) {
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
    }
    elsif ( $ORIG_SHELL && $ORIG_SHELL ne $BASH ) {
        run_cmd( '/usr/sbin/usermod', '-s', $ORIG_SHELL, $USER );
    }

    if ( $DEAD_CREATED && defined $DEAD_USER ) {
        if ( defined getpwnam($DEAD_USER) ) {
            run_cmd( $WHMAPI, 'removeacct', "username=$DEAD_USER", 'keepdns=0', '--output=json' );
        }
        else {
            # A3 deletes this account with `userdel -f` on purpose, which leaves
            # /var/cpanel/users/<name> behind -- removeacct cannot clean up an
            # account that is already half gone. Left in place it accumulates one
            # ghost per run, and root's `clean` enumerates that directory
            # (getcpusers), so every later run tries to sweep accounts that no
            # longer exist.
            unlink "/var/cpanel/users/$DEAD_USER";
        }
    }

    if ( $CLEAN_CREATED && defined $CLEAN_USER && defined getpwnam($CLEAN_USER) ) {
        run_cmd( $WHMAPI, 'removeacct', "username=$CLEAN_USER", 'keepdns=0', '--output=json' );
    }
}
