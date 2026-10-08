#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/cpanel-57396-pkgacct-restore-live.t
#                                                  Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# CPANEL-57396 -- an account backup carries each container's files once, leaves
# nothing behind in the home directory, and the account still comes back with
# its containers, end to end, on a real box.
#
# WHY THIS FILE EXISTS
#
# The PkgAcct::Create pre-hook used to run `ea-podman backup` for the account:
# a full tarball of ~/ea-podman.d into ~/ea-podman-backups/, three kept. The
# homedir archive that follows took ~/ea-podman.d AND every tarball, so each
# account backup held up to four copies of every container's files, and the
# tarballs sat in the user's quota between backups. Now the hook writes only the
# ea_podman_backup_<user>.json manifest, and `ea-podman restore --verify` with no
# tarball rebuilds the containers from it and the restored ~/ea-podman.d.
#
# The unit tests mock pkgacct, restorepkg, podman and the port authority. Only a
# real box can show what lands in a real pkgacct archive, and that a restorepkg'd
# account's containers actually come back up.
#
# WHAT IT PROVES (one subtest per acceptance criterion on the case)
#
#   AC1  A pkgacct archive -- `--backup` (scheduled backups) and plain (cpmove,
#        what a transfer uses) -- holds each container's files exactly once: a
#        random marker file in each container directory appears once, and the
#        archive holds no ea-podman-backups tarball. The manifest is in it.
#   AC2  Three backup runs leave no tarball in the home directory.
#   AC3  Same server: removeacct, restorepkg, `ea-podman restore --verify`, and
#        each container is back under the same name, with the same registry
#        entry, the same start_args, the same ports and the same data, running
#        and serving. A second `restore --verify` leaves them all alone.
#        A TRANSFER to a new server is the same check across two boxes; see
#        TRANSFER below.
#   AC4  Between backups the account carries ~/ea-podman.d plus a manifest of a
#        few KB, and nothing else.
#   AC5  An account with no containers gets no manifest, no tarball, and no
#        lingering user manager from a backup run (the CPANEL-55309 guard).
#   AC6  A tarball an earlier version left in ~/ea-podman-backups is not touched
#        by pkgacct, and `ea-podman backup` still writes one.
#
# ON PORTS (AC3)
#
# The case asks for the same ports. ea-podman does not reclaim them: restore
# asks the port authority for the lowest free ones (docs/backup-restore.md,
# "Ports are reallocated, not reclaimed"). On a clean box that is usually the
# same set, but which container gets which port follows the manifest's order,
# and write_user_manifest() orders by user only, so with two containers the
# per-container check can fail by a swap. That is a real gap against the case,
# not flakiness in this file; the account-wide set is checked separately so a
# failure says which of the two it is.
#
# BEFORE AND AFTER
#
#                                            ea-podman 1.0-33 (bug)   with the fix
#     tarballs in ~/ea-podman-backups after 3       3                      0
#     ea-podman-backups tarballs in the archive    >0                      0
#
# With E2E57396_EXPECT_OLD_EAPODMAN=1 the file asserts the duplication instead and
# stops before the restore, which the old code cannot do without a tarball. A
# passing before run shows the test reproduces the bug.
#
# RUN IT (same server, the default)
#
#     scp t/LiveTests/setup-remote-live.pl t/LiveTests/cpanel-57396-pkgacct-restore-live.t root@VM:/root/
#     # to test a working tree rather than the installed package:
#     rsync -a --delete ./ root@VM:/root/ea-podman/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl --ea-podman=/root/ea-podman --deploy'
#     ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/cpanel-57396-pkgacct-restore-live.t'
#
#     # the before run, on a box with ea-podman 1.0-33 or earlier:
#     ssh root@VM 'EAPODMAN_LIVE=1 E2E57396_EXPECT_OLD_EAPODMAN=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/cpanel-57396-pkgacct-restore-live.t'
#
# TRANSFER (two boxes, both with the fix deployed)
#
# A transfer is pkgacct (plain, not --backup) on the source and restorepkg on the
# destination. The destination usually gives the account a different uid, which
# is what makes it a different test.
#
#     # VM1 -- the source. Leaves the archive and the expected state in the dir.
#     ssh root@VM1 'EAPODMAN_LIVE=1 E2E57396_MODE=transfer-pack E2E57396_TRANSFER_DIR=/root/e2e57396-transfer \
#         /usr/local/cpanel/3rdparty/bin/prove -v /root/cpanel-57396-pkgacct-restore-live.t'
#     scp -r root@VM1:/root/e2e57396-transfer root@VM2:/root/
#     # VM2 -- the destination. The account must not exist there.
#     ssh root@VM2 'EAPODMAN_LIVE=1 E2E57396_MODE=transfer-unpack E2E57396_TRANSFER_DIR=/root/e2e57396-transfer \
#         /usr/local/cpanel/3rdparty/bin/prove -v /root/cpanel-57396-pkgacct-restore-live.t'
#
# A cpmove archive carries ~/.local/share/containers, which remembers the old
# uid. docs/backup-restore.md says a restore under a new uid then stops with
# "RunRoot is pointing to a path ... which is not writable". If the unpack run
# fails that way, that is the documented limitation reproducing, and the case's
# transfer criterion is not met by restore alone.
#
# WHAT THE BOX NEEDS
#
#   * a disposable, LICENSED cPanel VM, cgroup v1 or v2, with ea-podman deployed
#   * internet access to docker.io. A rate-limited pull SKIPS with that reason.
#   * podman, curl, tar
#
# MUST NOT INTERLEAVE WITH ea4-325-upgrade-live.t or cpanel-54868-e2e-live.t:
# they run `remove_containers --all` as root.
#
# DESTRUCTIVE, THROWAWAY VM ONLY. Creates two cPanel accounts, removes and
# restores one of them, and writes pkgacct archives under /root/e2e57396-*. All
# of it is removed at the end unless E2E57396_KEEP=1 (transfer-pack keeps the
# transfer dir; that is its output).
#
# ENVIRONMENT
#
#   EAPODMAN_LIVE=1                  required opt-in (directory convention)
#   E2E57396_MODE                    same-server (default), transfer-pack,
#                                    transfer-unpack
#   E2E57396_TRANSFER_DIR            where transfer-pack writes and
#                                    transfer-unpack reads (default
#                                    /root/e2e57396-transfer)
#   E2E57396_IMAGE                   image to install (default
#                                    docker.io/library/httpd:2.4; it must serve
#                                    HTTP on E2E57396_PORT)
#   E2E57396_PORT                    container port (default 80)
#   E2E57396_EXPECT_OLD_EAPODMAN=1   the box has ea-podman WITHOUT the fix;
#                                    assert the duplication instead
#   E2E57396_KEEP=1                  leave the accounts and archives in place

use strict;
use warnings;

use Test::More;
use Digest::SHA ();
use File::Path  ();
use IPC::Open3  ();
use Symbol      ();

my $WHMAPI     = '/usr/local/cpanel/bin/whmapi1';
my $PKGACCT    = '/scripts/pkgacct';
my $RESTOREPKG = '/scripts/restorepkg';
my $PORT_AUTH  = '/scripts/cpuser_port_authority';
my $EAP_LIB    = '/opt/cpanel/ea-podman/lib/ea_podman/util.pm';
my $REGISTRY   = '/opt/cpanel/ea-podman/registered-containers.json';
my $CLI        = '/usr/local/cpanel/scripts/ea-podman';

my $MODE         = $ENV{E2E57396_MODE}         || 'same-server';
my $TRANSFER_DIR = $ENV{E2E57396_TRANSFER_DIR} || '/root/e2e57396-transfer';
my $IMAGE        = $ENV{E2E57396_IMAGE}        || 'docker.io/library/httpd:2.4';
my $CPORT        = $ENV{E2E57396_PORT}         || 80;
my $EXPECT_OLD   = $ENV{E2E57396_EXPECT_OLD_EAPODMAN} ? 1 : 0;
my $KEEP         = $ENV{E2E57396_KEEP} ? 1 : 0;

my $CBASE     = 'eapod57396';
my $MARKER    = 'e2e57396-marker.bin';
my $BACKUP_RE = qr{ea-podman-backups/backup-[0-9]+\.tar\.gz$};

#=============================================================================
# Guards. Each names what is missing.
#=============================================================================

plan skip_all => 'live test; set EAPODMAN_LIVE=1 to run' unless $ENV{EAPODMAN_LIVE};
plan skip_all => 'must run as root'                      if $> != 0;
plan skip_all => "unknown E2E57396_MODE '$MODE' (same-server, transfer-pack, transfer-unpack)"
  if $MODE !~ /\A(?:same-server|transfer-pack|transfer-unpack)\z/;
plan skip_all => 'E2E57396_EXPECT_OLD_EAPODMAN only applies to same-server mode' if $EXPECT_OLD && $MODE ne 'same-server';

sub in_path {
    my ($bin) = @_;
    for my $dir ( split /:/, ( $ENV{PATH} || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' ) ) {
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

for my $bin (qw(podman curl tar pkill)) {
    plan skip_all => "$bin is not installed" if !in_path($bin);
}
plan skip_all => "whmapi1 not found ($WHMAPI)"  if !-x $WHMAPI;
plan skip_all => "$PKGACCT not found"           if !-x $PKGACCT;
plan skip_all => "$RESTOREPKG not found"        if !-x $RESTOREPKG;
plan skip_all => "$PORT_AUTH not found"         if !-x $PORT_AUTH;
plan skip_all => 'ea-podman is not installed'   if !-e $EAP_LIB;
plan skip_all => "ea-podman CLI not found ($CLI)" if !-x $CLI;

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
require JSON::PP if !$HAVE_CPJSON;

sub decode_json_or_undef {
    my ($text) = @_;
    return undef if !length( $text // '' );
    $text =~ s/\A[^{\[]+//s;
    return undef if !length $text;
    return $HAVE_CPJSON ? eval { Cpanel::JSON::Load($text) } : eval { JSON::PP::decode_json($text) };
}

sub encode_json_pretty {
    my ($data) = @_;
    return $HAVE_CPJSON ? Cpanel::JSON::pretty_canonical_dump($data) : JSON::PP->new->pretty->canonical->encode($data);
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

sub home_of { my ($user) = @_; return ( getpwnam($user) )[7]; }

sub sha_of {
    my ($path) = @_;
    return '' if !-f $path;
    return Digest::SHA->new(256)->addfile($path)->hexdigest;
}

#=============================================================================
# Is the code under test present? A mismatch is a BAIL_OUT, never a skip.
#=============================================================================

my $HAS_FIX  = slurp($EAP_LIB) =~ /^sub write_user_manifest\b/m ? 1 : 0;
my $WANT_FIX = $EXPECT_OLD ? 0 : 1;

if ( $HAS_FIX != $WANT_FIX ) {
    BAIL_OUT( "$EAP_LIB " . ( $HAS_FIX ? 'has' : 'does not have' ) . ' the CPANEL-57396 fix (write_user_manifest) but this run expects ' . ( $WANT_FIX ? 'it' : 'the older code' )
          . '. Refusing to run: the results would describe code you are not looking at. '
          . ( $EXPECT_OLD ? 'Unset E2E57396_EXPECT_OLD_EAPODMAN.' : 'Deploy the fix (setup-remote-live.pl --deploy), or set E2E57396_EXPECT_OLD_EAPODMAN=1 for the before run.' ) );
}

note_both( "mode: $MODE; ea-podman library " . ( $HAS_FIX ? 'HAS' : 'does NOT have' ) . ' the CPANEL-57396 fix' );

if ( $MODE ne 'transfer-unpack' ) {
    my ( $rc, $out, $err ) = run_cmd( 'podman', 'pull', '-q', $IMAGE );
    plan skip_all => "Docker Hub rate limit reached on this host -- `podman login`, use a pull-through cache, or wait:\n$out$err"
      if "$out$err" =~ /toomanyrequests|rate limit/i;
}

#=============================================================================
# Accounts, archives and cleanup
#=============================================================================

my ( $USER, $EMPTY_USER );
my $WORK = "/root/e2e57396-$$";
File::Path::make_path($WORK) if $MODE ne 'transfer-unpack';

my ($CAGEFSCTL) = grep { -x $_ } ( '/usr/sbin/cagefsctl', '/sbin/cagefsctl', '/usr/bin/cagefsctl' );

# The test drives the CLI and podman directly as the account; a jailshell or a
# cage sends the CLI down the restricted path instead, which is not under test.
# Run again after restorepkg, which can put either back.
sub unrestrict_account {
    my ($user) = @_;
    run_cmd( '/usr/sbin/usermod', '-s', '/bin/bash', $user );
    run_cmd( $CAGEFSCTL, '--disable', $user ) if $CAGEFSCTL;
    return;
}

sub make_account {
    my ($name) = @_;
    my $pw = 'Eap0d' . substr( time, -6 ) . '!Xy';
    my ( $j, $rc, $raw ) = whmapi( 'createacct', "username=$name", "domain=$name.cp57396.test", "password=$pw" );
    note_both("createacct $name: $raw") if !whm_ok($j);
    return whm_ok($j);
}

sub remove_account {
    my ($user) = @_;
    return if !defined getpwnam($user);
    run_cmd( 'pkill', '-KILL', '-u', $user );
    sleep 2;
    return whmapi( 'removeacct', "username=$user", 'keepdns=0' );
}

sub registry_for {
    my ($user) = @_;
    my $all = decode_json_or_undef( slurp($REGISTRY) ) || {};
    return { map { $_ => $all->{$_} } grep { ( $all->{$_}{user} // '' ) eq $user } keys %{$all} };
}

# { port => container } for this account's containers. `list root` would show
# only root's.
sub ports_of {
    my ($user) = @_;
    my ( undef, $out ) = run_cmd( $PORT_AUTH, 'list', $user );
    my $hr = decode_json_or_undef($out);
    return {} if ref $hr ne 'HASH';
    return { map { $_ => $hr->{$_}{service} } grep { ( $hr->{$_}{service} // '' ) =~ /\Q$CBASE\E/ } keys %{$hr} };
}

sub ports_by_container {
    my ($user) = @_;
    my $p = ports_of($user);
    my %by;
    push @{ $by{ $p->{$_} } }, $_ for sort { $a <=> $b } keys %{$p};
    return \%by;
}

sub podman_id {
    my ( $user, $c ) = @_;
    my ( $rc, $out ) = as_user( $user, 'podman inspect --format "{{.Id}}" ' . _sh($c) . ' 2>/dev/null' );
    chomp $out;
    return $rc == 0 ? $out : '';
}

sub is_running {
    my ( $user, $c ) = @_;
    my ( undef, $out ) = as_user( $user, q{podman ps --format '{{.Names}}'} );
    return $out =~ /^\Q$c\E$/m ? 1 : 0;
}

# httpd's default page, through the host port. Waits, because a container that
# podman reports running may not be accepting yet.
sub serves {
    my ($port) = @_;
    for ( 1 .. 30 ) {
        my ( $rc, $out ) = run_cmd( 'curl', '-s', '-m', '5', "http://127.0.0.1:$port/" );
        return 1 if $rc == 0 && length $out;
        sleep 2;
    }
    return 0;
}

# What the case calls "configuration": the registry entry and the start_args.
# webapp is a JSON boolean; compare it as 0/1.
sub config_of {
    my ( $user, $c ) = @_;
    my $entry = registry_for($user)->{$c} or return undef;
    my $conf  = decode_json_or_undef( slurp( home_of($user) . "/ea-podman.d/$c/ea-podman.json" ) ) || {};
    return {
        registry => {
            ( map { $_ => $entry->{$_} } grep { exists $entry->{$_} } qw(container_name user pkg image) ),
            webapp => $entry->{webapp} ? 1 : 0,
        },
        start_args => $conf->{start_args},
    };
}

sub snapshot {
    my ($user) = @_;
    my $ports = ports_by_container($user);
    my %c;
    for my $name ( sort keys %{ registry_for($user) } ) {
        $c{$name} = {
            config => config_of( $user, $name ),
            ports  => $ports->{$name} || [],
            marker => sha_of( home_of($user) . "/ea-podman.d/$name/$MARKER" ),
        };
    }
    return { user => $user, uid => ( getpwnam($user) )[2], containers => \%c };
}

# Every member path in a pkgacct archive. Older pkgacct builds nest the home
# directory as homedir.tar; list inside that too.
sub archive_members {
    my ($archive) = @_;
    my ( $rc, $out, $err ) = run_cmd( 'tar', '-tzf', $archive );
    my @members = split /\n/, $out;
    for my $nested ( grep { m{(?:^|/)homedir\.tar$} } @members ) {
        my ( undef, $inner ) = run_cmd( '/bin/sh', '-c', 'tar -xzOf ' . _sh($archive) . ' ' . _sh($nested) . ' | tar -tf -' );
        push @members, map { "$nested!/$_" } split /\n/, $inner;
    }
    note_both("tar -tzf $archive exited $rc: $err") if $rc != 0;
    return \@members;
}

# Run pkgacct into a fresh directory and return the archive it wrote.
my $PKGACCT_RUNS = 0;

sub run_pkgacct {
    my ( $user, @opts ) = @_;
    my $dir = "$WORK/pkgacct-" . ++$PKGACCT_RUNS;
    File::Path::make_path($dir);
    my ( $rc, $out, $err ) = run_cmd( $PKGACCT, @opts, $user, $dir );
    my ($archive) = sort { -M $a <=> -M $b } glob("$dir/*.tar.gz");
    note_both( "pkgacct @opts $user exited $rc and wrote " . ( $archive // 'no archive' ) . ( $rc ? ":\n$out$err" : '' ) );
    return ( $rc, $archive );
}

sub home_tarballs {
    my ($user) = @_;
    return sort glob( home_of($user) . '/ea-podman-backups/backup-*.tar.gz' );
}

sub dump_state {
    my ($why) = @_;
    print "#\n# ===== DIAGNOSTICS ($why) =====\n";
    for my $user ( grep { defined && defined getpwnam($_) } ( $USER, $EMPTY_USER ) ) {
        my $home = home_of($user);
        print "# $user (uid " . ( getpwnam($user) )[2] . ") home $home\n";
        print "#   registry: " . join( ', ', sort keys %{ registry_for($user) } ) . "\n";
        my $p = ports_of($user);
        print "#   ports: " . join( ', ', map { "$_ => $p->{$_}" } sort keys %{$p} ) . "\n";
        my ( undef, $ps ) = as_user( $user, 'podman ps -a --format "{{.Names}} {{.Status}} {{.Ports}}" 2>&1' );
        print map { "#   ps: $_\n" } split /\n/, $ps;
        my ( undef, $ls ) = run_cmd( 'ls', '-la', $home, "$home/ea-podman.d", "$home/ea-podman-backups" );
        print map { "#   $_\n" } split /\n/, $ls;
    }
    print "# ===== END DIAGNOSTICS =====\n";
    return;
}

END {
    my $tb = Test::More->builder;
    dump_state('a test failed') if $tb->current_test && !$tb->is_passing;

    if ($KEEP) {
        print "# E2E57396_KEEP set: accounts and $WORK left in place\n";
    }
    else {
        for my $user ( grep { defined } ( $USER, $EMPTY_USER ) ) {
            next if $MODE eq 'transfer-unpack' && !defined getpwnam($user);
            remove_account($user);
            print "# removed throwaway account '$user'\n";
        }
        File::Path::remove_tree($WORK) if defined $WORK && -d $WORK;
    }
}

#=============================================================================
# Shared steps
#=============================================================================

sub install_containers {
    my ($user) = @_;
    my @names;
    for ( 1 .. 2 ) {
        my ( $rc, $out, $err ) = as_user( $user, _sh($CLI) . " install $CBASE --i-understand-the-risks-do-it-anyway --cpuser-port=$CPORT " . _sh($IMAGE) );
        my ($name) = "$out$err" =~ /Done, installed:\s*(\S+)/;
        ok( $name, "installed container " . ( $name // '(none)' ) ) or note_both("install exited $rc:\n$out$err");
        push @names, $name if $name;
    }
    return @names;
}

# A random file in each container directory. It is what "exactly once" counts,
# and its digest is what "the same data" compares.
sub plant_markers {
    my ( $user, @names ) = @_;
    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    for my $c (@names) {
        my $path = home_of($user) . "/ea-podman.d/$c/$MARKER";
        my ( $rc, undef, $err ) = run_cmd( 'dd', 'if=/dev/urandom', "of=$path", 'bs=64k', 'count=4', 'status=none' );
        chown $uid, $gid, $path;
        ok( -s $path, "planted $MARKER in $c" ) or note_both("dd: $err");
    }
    return;
}

# AC1 for one archive. In old mode it asserts the duplication instead.
sub check_archive_shape {
    my ( $user, $archive, @names ) = @_;
    my $members = archive_members($archive);
    ok( scalar @{$members}, 'the archive lists members' ) or return;

    for my $c (@names) {
        my $n = grep { m{ea-podman\.d/\Q$c\E/\Q$MARKER\E$} } @{$members};
        is( $n, 1, "$c\'s files are in the archive once (counting its marker)" );
    }

    my @tarballs = grep { $_ =~ $BACKUP_RE } @{$members};
    my @manifest = grep { m{(?:^|/)ea_podman_backup_\Q$user\E\.json$} } @{$members};

    if ($EXPECT_OLD) {
        cmp_ok( scalar @tarballs, '>', 0, 'BEFORE RUN: the archive also carries ea-podman-backups tarballs (the duplication)' )
          or note_both( 'archive members under ea-podman-backups: none' );
    }
    else {
        is( scalar @tarballs, 0, 'the archive carries no ea-podman-backups tarball' ) or note_both( "found: @tarballs" );
        is( scalar @manifest, 1, 'the archive carries the manifest once' );
    }
    return;
}

# The restore half of AC3, against what was recorded before the backup.
sub restore_and_compare {
    my ( $user, $expected ) = @_;
    my @names = sort keys %{ $expected->{containers} };
    my $home  = home_of($user);

    unrestrict_account($user);

    is_deeply( [ sort keys %{ registry_for($user) } ], [], 'restorepkg alone registers nothing (there is no restore hook)' );
    ok( -e "$home/ea_podman_backup_$user.json", 'the manifest came back with the account' );
    for my $c (@names) {
        is( sha_of("$home/ea-podman.d/$c/$MARKER"), $expected->{containers}{$c}{marker}, "$c\'s data came back with the account" );
    }

    my ( $rc, $out, $err ) = as_user( $user, _sh($CLI) . ' restore' );
    like( "$out$err", qr/can not be undone/, '`restore` without --verify refuses' );
    is_deeply( [ sort keys %{ registry_for($user) } ], [], 'and registers nothing' );

    ( $rc, $out, $err ) = as_user( $user, _sh($CLI) . ' restore --verify' );
    is( $rc, 0, '`ea-podman restore --verify` with no tarball succeeds' ) or note_both("restore exited $rc:\n$out$err");
    if ( "$out$err" =~ /RunRoot is pointing to a path/ ) {
        note_both( 'restore hit the old-uid podman store: the documented ~/.local/share/containers limitation (docs/backup-restore.md). '
              . "uid before $expected->{uid}, now " . ( getpwnam($user) )[2] );
    }

    my $now = snapshot($user);
    is_deeply( [ sort keys %{ $now->{containers} } ], \@names, 'every container is registered again under the same name' );

    my ( %want_ports, %got_ports );
    for my $c (@names) {
        my ( $want, $got ) = ( $expected->{containers}{$c}, $now->{containers}{$c} || {} );
        is_deeply( $got->{config}, $want->{config}, "$c: same registry entry and start_args" );
        is( $got->{marker}, $want->{marker}, "$c: same data" );
        is_deeply( $got->{ports}, $want->{ports}, "$c: same ports (@{ $want->{ports} })" )
          or note_both( "$c had ports @{ $want->{ports} }, has @{ $got->{ports} || [] }. Restore reallocates rather than reclaims; see ON PORTS in this file's header." );
        $want_ports{$_} = 1 for @{ $want->{ports} };
        $got_ports{$_}  = 1 for @{ $got->{ports} || [] };

        ok( is_running( $user, $c ), "$c is running" );
        my ($port) = @{ $got->{ports} || [] };
        ok( $port && serves($port), "$c serves on its host port " . ( $port // '(none)' ) );
    }
    is_deeply( [ sort keys %got_ports ], [ sort keys %want_ports ], 'the account holds the same set of ports' );

    is( scalar( () = home_tarballs($user) ), 0, 'restoring wrote no tarball' );

    # A second run is what an admin does when unsure whether the first worked.
    my %ids = map { $_ => podman_id( $user, $_ ) } @names;
    my $ports_before = ports_by_container($user);

    ( $rc, $out, $err ) = as_user( $user, _sh($CLI) . ' restore --verify' );
    is( $rc, 0, 'a second `restore --verify` succeeds' ) or note_both("$out$err");
    for my $c (@names) {
        like( "$out$err", qr/\Q$c\E.{0,4} is already registered; leaving it as it is/, "it leaves $c alone" );
        is( podman_id( $user, $c ), $ids{$c}, "$c is the same container instance" );
    }
    like( "$out$err", qr/Nothing to restore/, 'and says there is nothing to restore' );
    is_deeply( ports_by_container($user), $ports_before, 'and takes no further ports' );

    return;
}

#=============================================================================
# transfer-unpack: the destination half of a transfer
#=============================================================================

if ( $MODE eq 'transfer-unpack' ) {
    my $expected = decode_json_or_undef( slurp("$TRANSFER_DIR/expected.json") );
    my ($archive) = glob("$TRANSFER_DIR/*.tar.gz");
    plan skip_all => "no expected.json and archive in $TRANSFER_DIR; run E2E57396_MODE=transfer-pack on the source first"
      if !$expected || !$archive;

    $USER = $expected->{user};
    plan skip_all => "account '$USER' already exists on this box; a transfer needs a destination without it"
      if defined getpwnam($USER);

    subtest "AC3 (transfer): $USER comes back on a new server" => sub {
        my ( $rc, $out, $err ) = run_cmd( $RESTOREPKG, $archive );
        ok( defined getpwnam($USER), "restorepkg created $USER" ) or return note_both("restorepkg exited $rc:\n$out$err");
        note_both( "uid on the source $expected->{uid}, here " . ( getpwnam($USER) )[2] );
        restore_and_compare( $USER, $expected );
    };

    done_testing();
    exit;
}

#=============================================================================
# Setup: an account with two containers, and one with none
#=============================================================================

my $stamp = substr( time, -5 );
$USER = "e57396$stamp";
plan skip_all => "could not create test account '$USER'" if !make_account($USER);
unrestrict_account($USER);

my @NAMES;
subtest "setup: $USER has two running containers with data in them" => sub {
    @NAMES = install_containers($USER);
    is( scalar @NAMES, 2, 'two containers' ) or return;
    for my $c (@NAMES) {
        ok( is_running( $USER, $c ), "$c is running" );
        my ($port) = @{ ports_by_container($USER)->{$c} || [] };
        ok( $port && serves($port), "$c serves on host port " . ( $port // '(none)' ) );
    }
    plant_markers( $USER, @NAMES );
};
BAIL_OUT('setup failed; nothing below would mean anything') if @NAMES != 2;

my $EXPECTED = snapshot($USER);
note_both( "before the backup: " . join( '; ', map { "$_ => ports @{ $EXPECTED->{containers}{$_}{ports} }" } @NAMES ) );

#=============================================================================
# transfer-pack: the source half of a transfer
#=============================================================================

if ( $MODE eq 'transfer-pack' ) {
    subtest 'AC1 (transfer archive): plain pkgacct carries each container once' => sub {
        my ( $rc, $archive ) = run_pkgacct($USER);
        ok( $archive, 'pkgacct wrote an archive' ) or return;
        check_archive_shape( $USER, $archive, @NAMES );

        File::Path::make_path($TRANSFER_DIR);
        unlink glob("$TRANSFER_DIR/*.tar.gz");
        my ($cp_rc) = run_cmd( 'cp', '-p', $archive, $TRANSFER_DIR );
        is( $cp_rc, 0, "copied the archive to $TRANSFER_DIR" );
        spew( "$TRANSFER_DIR/expected.json", encode_json_pretty($EXPECTED) );
        ok( -s "$TRANSFER_DIR/expected.json", 'wrote expected.json' );
    };
    note_both("now copy $TRANSFER_DIR to the destination and run E2E57396_MODE=transfer-unpack there");
    done_testing();
    exit;
}

#=============================================================================
# same-server
#=============================================================================

subtest 'AC5: an account with no containers is skipped by the hook' => sub {
    $EMPTY_USER = "e57396e$stamp";
    ok( make_account($EMPTY_USER), "created $EMPTY_USER" ) or return;

    my ( $rc, $archive ) = run_pkgacct( $EMPTY_USER, '--backup' );
    ok( $archive, 'pkgacct wrote an archive' );

    my $home = home_of($EMPTY_USER);
    ok( !-e "$home/ea_podman_backup_$EMPTY_USER.json", 'no manifest in the home directory' );
    ok( !-e "$home/ea-podman-backups",                 'no ea-podman-backups directory' );
    ok( !-e "/var/lib/systemd/linger/$EMPTY_USER",     'no lingering user manager (CPANEL-55309)' );
    if ($archive) {
        my @hits = grep { /ea_podman_backup_|ea-podman-backups/ } @{ archive_members($archive) };
        is( scalar @hits, 0, 'nothing of ea-podman in the archive' ) or note_both("found: @hits");
    }
};

my $RESTORE_ARCHIVE;
subtest 'AC1, AC2, AC4: three pkgacct --backup runs' => sub {
    for my $run ( 1 .. 3 ) {
        my ( $rc, $archive ) = run_pkgacct( $USER, '--backup' );
        ok( $archive, "run $run: pkgacct wrote an archive" ) or next;
        check_archive_shape( $USER, $archive, @NAMES );
        $RESTORE_ARCHIVE = $archive;
    }

    my @left = home_tarballs($USER);
    if ($EXPECT_OLD) {
        is( scalar @left, 3, 'BEFORE RUN: three tarballs were left in ~/ea-podman-backups' );
        return;
    }

    is( scalar @left, 0, 'no tarball was left in ~/ea-podman-backups' ) or note_both("found: @left");

    my $manifest = home_of($USER) . "/ea_podman_backup_$USER.json";
    ok( -e $manifest, 'the manifest is left in the home directory' );
    cmp_ok( -s $manifest // 0, '<', 64 * 1024, 'and it is small (' . ( -s $manifest // 0 ) . ' bytes)' );

    my $listed = decode_json_or_undef( slurp($manifest) ) || [];
    my %m = map { $_->{container_name} => $_ } @{$listed};
    is_deeply( [ sort keys %m ], [ sort @NAMES ], 'it lists both containers' );
    for my $c (@NAMES) {
        is_deeply( [ sort { $a <=> $b } @{ $m{$c}{curr_ports} || [] } ], $EXPECTED->{containers}{$c}{ports}, "with $c\'s ports" );
    }
};

if ($EXPECT_OLD) {
    note_both('before run: stopping here; the old code cannot restore without a tarball');
    done_testing();
    exit;
}

subtest 'AC1: plain pkgacct (what a transfer uses) carries each container once' => sub {
    my ( $rc, $archive ) = run_pkgacct($USER);
    ok( $archive, 'pkgacct wrote an archive' ) or return;
    check_archive_shape( $USER, $archive, @NAMES );
};

subtest 'AC6: an earlier tarball is left alone, and `ea-podman backup` still makes one' => sub {
    my ( $rc, $out, $err ) = as_user( $USER, _sh($CLI) . ' backup' );
    my ($tarball) = home_tarballs($USER);
    ok( $tarball, '`ea-podman backup` wrote a tarball' ) or return note_both("backup exited $rc:\n$out$err");

    my @before = ( stat $tarball )[ 1, 7, 9 ];
    run_pkgacct( $USER, '--backup' );
    is_deeply( [ home_tarballs($USER) ], [$tarball], 'pkgacct neither added a tarball nor aged this one out' );
    is_deeply( [ ( stat $tarball )[ 1, 7, 9 ] ], \@before, 'and did not touch it' );

    unlink $tarball;    # the restore below uses an archive from before it, but keep the home as it was
};

subtest 'AC3 (same server): removeacct, restorepkg, restore --verify' => sub {
    ok( $RESTORE_ARCHIVE, 'a --backup archive to restore from' ) or return;

    remove_account($USER);
    ok( !defined getpwnam($USER), "removed $USER" ) or return;
    is_deeply( [ sort keys %{ registry_for($USER) } ], [], 'its containers left the registry' );
    is_deeply( ports_of($USER), {}, 'and their ports were released' );

    my ( $rc, $out, $err ) = run_cmd( $RESTOREPKG, $RESTORE_ARCHIVE );
    ok( defined getpwnam($USER), "restorepkg brought $USER back" ) or return note_both("restorepkg exited $rc:\n$out$err");

    restore_and_compare( $USER, $EXPECTED );
};

done_testing();
