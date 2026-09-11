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

my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';

#---------------------------------------------------------------------
# test accounts
#---------------------------------------------------------------------
our $USER;
our $CREATED_USER = 0;
our $ORIG_SHELL;
our $DEAD_USER;          # A3: deleted uncleanly while still registered
our $DEAD_CREATED = 0;

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

    my ( $rc, $out, $secs ) = cli_upgrade( $USER, $container );

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
    my ( $rc, $out ) = cli_upgrade( $USER, $container );
    is( $rc, 0, "the container is repaired for the remaining subtests" ) or diag($out);
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

    my ( $rc, $out ) = cli_upgrade( $USER, $container );

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

    # Repair for what follows.
    patch_start_args( $USER, $container, sub { my ($args) = @_; $args->[-1] = $IMAGE; } );
    cli_upgrade( $USER, $container );
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

    my $before = unit_prop( $USER, $container, 'ActiveEnterTimestamp' );

    my ( $rc, $out ) = run_cmd( $CLI, 'upgrade_containers', '--all' );

    # Surviving must not mean going quiet: a registry entry for a vanished
    # account is a real problem and must not exit 0.
    isnt( $rc, 0, "the sweep exits non-zero" );
    like( $out, qr/skipping .*\Q$DEAD_USER\E/, "it names the account it skipped" );
    like( $out, qr/remove_containers --all/,   "and points at the command that cleans it up" );
    like( $out, qr/did not complete for:.*\Q$DEAD_USER\E/, "and summarises the failure" );

    # The point of the fix: the accounts after the dead one are still processed.
    my $after = unit_prop( $USER, $container, 'ActiveEnterTimestamp' );
    isnt( $after, $before, "the live account sorted after it was still upgraded" );
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

    if ( $DEAD_CREATED && defined $DEAD_USER && defined getpwnam($DEAD_USER) ) {
        run_cmd( $WHMAPI, 'removeacct', "username=$DEAD_USER", 'keepdns=0', '--output=json' );
    }
}
