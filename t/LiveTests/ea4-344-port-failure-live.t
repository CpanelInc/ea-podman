#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/ea4-344-port-failure-live.t
#                                                  Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# EA4-344 -- a port the port authority will not give is a fatal, named error,
# end to end, on a real box.
#
# WHY THIS FILE EXISTS
#
# _get_new_ports() used to ignore a failed `cpuser_port_authority give`: as root
# it threw stderr away (2>/dev/null), and as a cPanel user it never looked at the
# exit status the ea_podman admin module's GIVE hands back. The install then
# created the container with no -p mapping, and a Web App deploy reported "The
# container started but is not listening on a port". EA4-344 makes both paths die
# with the port authority's own words.
#
# t/SOURCES-util-get-new-ports.t mocks both boundaries, so it cannot show the two
# contracts the fix rests on:
#
#   * the user path: Cpanel::AdminBin::Call::call() in list context returns
#     GIVE's ( output, exit status ) through the real cpwrapd round trip. If it
#     did not, $rv would be undef and the fix would do nothing for Web Apps.
#   * the root path: a real `give` that runs out of ports exits non-zero.
#
# THE TRIGGER
#
# CPANEL-57865: cpuser_port_authority hands out 10000 .. (ephemeral start - 1),
# floors the ephemeral start at 10001, and drops the range above the ephemeral
# range when that range ends at 65535. With ip_local_port_range = "1024 65535"
# the whole server has exactly one assignable port, 10000. This file widens the
# range, takes that one port as root, and every later `give` then fails with
# "Not enough free ports". The original range is put back at the end, whatever
# happens.
#
# WHAT IT PROVES
#
#   A. Root path: _get_new_ports() as root dies "Could not assign root ports:"
#      followed by the port authority's message, and no port is assigned.
#   B. User path: _get_new_ports() as a cPanel user (through the real admin
#      module) dies "Could not assign user ports: ..." the same way.
#   C. `ea-podman install` as that user (the path a Web App deploy takes, since
#      the plugin calls install_container() in-process as the account) exits
#      non-zero naming the cause, registers nothing, creates no container and
#      reserves no port. Whether it leaves its container directory behind is
#      reported as a TODO: the port step runs after the directory and its
#      ea-podman.json are written, and nothing removes them on this failure.
#   D. Control: with the range restored, the same install succeeds and reserves
#      exactly one port, so A-C failed for the reason this file arranged.
#
# BEFORE AND AFTER
#
# With EA4344_EXPECT_OLD_EAPODMAN=1 the file asserts the old silent behaviour
# instead (no error, no port, and C "succeeds" with a container that publishes
# nothing), so a passing run against ea-podman 1.0-34 shows the test reproduces
# the bug rather than only that the setup broke. Without it, an ea-podman that
# lacks the fix FAILS (never skips).
#
# RUN IT
#
#     scp t/LiveTests/setup-remote-live.pl t/LiveTests/ea4-344-port-failure-live.t root@VM:/root/
#     # to test a working tree rather than the installed package:
#     rsync -a --delete ./ root@VM:/root/ea-podman/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl --ea-podman=/root/ea-podman --deploy'
#     ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/ea4-344-port-failure-live.t'
#
#     # the before run, on a box with ea-podman 1.0-34 and no --deploy:
#     ssh root@VM 'EAPODMAN_LIVE=1 EA4344_EXPECT_OLD_EAPODMAN=1 /usr/local/cpanel/3rdparty/bin/prove -v /root/ea4-344-port-failure-live.t'
#
# WHAT THE BOX NEEDS
#
#   * a disposable, licensed cPanel VM, any supported OS, cgroup v1 or v2. Not
#     with CageFS on for new accounts: the probe lives in /tmp, which a caged
#     account cannot see
#   * podman and ea-podman installed
#   * internet access to docker.io for stage D only (a rate-limited pull skips D)
#
# MUST NOT INTERLEAVE with any other live test: it changes a host-wide sysctl and
# fills the port authority, so anything else allocating ports meanwhile fails.
#
# DESTRUCTIVE, THROWAWAY VM ONLY. Changes net.ipv4.ip_local_port_range for the
# duration of the run, assigns a root port, and creates a cPanel account, a
# package and a feature list. All of it is undone at the end unless EA4344_KEEP=1
# (the sysctl is restored even then).
#
# ENVIRONMENT
#
#   EAPODMAN_LIVE=1                 required opt-in (directory convention)
#   EA4344_IMAGE                    image for C and D (default docker.io/library/nginx:alpine)
#   EA4344_CONTAINER_PORT           port the image listens on (default 80)
#   EA4344_EXPECT_OLD_EAPODMAN=1    the box has ea-podman WITHOUT the fix; assert the old behaviour
#   EA4344_KEEP=1                   leave the account, package, feature list and root port in place

use strict;
use warnings;

use Test::More;
use IPC::Open3 ();
use Symbol     ();

my $PERL      = '/usr/local/cpanel/3rdparty/bin/perl';
my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib';
my $EAP_UTIL  = "$EAP_LIB/ea_podman/util.pm";
my $EAP_BIN   = '/opt/cpanel/ea-podman/bin/ea-podman';
my $PORT_AUTH = '/scripts/cpuser_port_authority';
my $RANGE_KEY = 'net.ipv4.ip_local_port_range';
my $WIDE      = '1024 65535';

my $IMAGE      = $ENV{EA4344_IMAGE}          || 'docker.io/library/nginx:alpine';
my $CPORT      = $ENV{EA4344_CONTAINER_PORT} || 80;
my $EXPECT_OLD = $ENV{EA4344_EXPECT_OLD_EAPODMAN} ? 1 : 0;

my $NO_PORTS_RE = qr/Not enough free ports \(wanted 1\)/;

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

for my $bin (qw(podman sysctl pkill su)) {
    plan skip_all => "$bin is not installed" if !in_path($bin);
}
plan skip_all => "whmapi1 not found ($WHMAPI)" if !-x $WHMAPI;
plan skip_all => "$PORT_AUTH not found"        if !-x $PORT_AUTH;
plan skip_all => 'ea-podman is not installed'  if !-e $EAP_UTIL || !-x $EAP_BIN;

my $HAS_FIX = do {
    open( my $fh, '<', $EAP_UTIL ) or die "Could not read $EAP_UTIL: $!\n";
    local $/;
    my $src = <$fh>;
    $src =~ /Could not assign user ports/ ? 1 : 0;
};

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
    my ( $rc, $out, $err ) = run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "unset QUERY_STRING REQUEST_METHOD; $env $cmd" );
    return ( $rc, $out . $err );
}

my $HAVE_CPJSON = eval { require Cpanel::JSON; 1 } ? 1 : 0;

sub decode_json_or_undef {
    my ($text) = @_;
    return undef if !length( $text // '' );
    $text =~ s/\A[^{\[]+//s;
    return undef if !length $text;
    return $HAVE_CPJSON ? eval { Cpanel::JSON::Load($text) } : eval { require JSON::PP; JSON::PP::decode_json($text) };
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

sub get_range {
    my ( $rc, $out ) = run_cmd( 'sysctl', '-n', $RANGE_KEY );
    return undef if $rc != 0;
    my @f = split ' ', $out;
    return @f == 2 ? "$f[0] $f[1]" : undef;
}

sub set_range {
    my ($range) = @_;
    my ( $rc, $out, $err ) = run_cmd( 'sysctl', '-w', "$RANGE_KEY=$range" );
    note_both("sysctl -w $RANGE_KEY=$range failed: $out$err") if $rc != 0;
    return ( get_range() // '' ) eq $range;
}

# { port => { owner => ..., service => ... } } for one owner
sub pa_list {
    my ($owner) = @_;
    my ( $rc, $out ) = run_cmd( $PORT_AUTH, 'list', $owner );
    return decode_json_or_undef($out) || {};
}

sub pa_give_root {
    my ($service) = @_;
    my ( $rc, $out, $err ) = run_cmd( $PORT_AUTH, 'give', 'root', 1, "--service=$service" );
    my ($port) = $out =~ m/^([0-9]+)$/m;
    return ( $rc, $port, $out . $err );
}

sub describe_ports {
    my ($owner) = @_;
    my $hr = pa_list($owner);
    return '(none)' if !%{$hr};
    return join( ', ', map { "$_=" . ( $hr->{$_}{service} // '?' ) } sort keys %{$hr} );
}

#=============================================================================
# State the END block undoes
#=============================================================================

our ( $USER, $HOME, $PKG, $FEATURELIST, $ORIG_RANGE, $PROBE );
my @ROOT_PORTS;    # every root port this file was given
my $LAST_OUT = '';

sub dump_state {
    my ($why) = @_;
    print "#\n# ===== DIAGNOSTICS ($why) =====\n";
    print "# ea-podman fix present: " . ( $HAS_FIX ? 'yes' : 'no' ) . "   expect old: $EXPECT_OLD\n";
    print "# $RANGE_KEY now: " . ( get_range() // '?' ) . "   original: " . ( $ORIG_RANGE // '?' ) . "\n";
    print "# root ports: " . describe_ports('root') . "\n";
    if ( defined $USER ) {
        print "# user: $USER  home: " . ( $HOME // 'none' ) . "\n";
        print "# user ports: " . describe_ports($USER) . "\n";
        my ( undef, $ps ) = as_user( $USER, 'podman ps -a --format "{{.Names}} {{.Status}} {{.Ports}}" 2>&1' );
        print "# podman ps -a:\n", ( map { "#   $_\n" } split /\n/, $ps );
        my @dirs = defined $HOME ? glob("$HOME/ea-podman.d/*") : ();
        print "# container dirs: " . ( @dirs ? join( ', ', @dirs ) : '(none)' ) . "\n";
    }
    print "# last output:\n", ( map { "#   $_\n" } split /\n/, $LAST_OUT );
    print "# ===== END DIAGNOSTICS =====\n";
    return;
}

END {
    my $passing = Test::More->builder->is_passing;
    my $ran     = Test::More->builder->current_test;

    dump_state('a test failed') if $ran && !$passing;

    # The sysctl is host-wide and outlives the run, so it goes back even with KEEP.
    if ( defined $ORIG_RANGE ) {
        if   ( set_range($ORIG_RANGE) ) { print "# restored $RANGE_KEY to $ORIG_RANGE\n" }
        else                            { print "# WARNING: could not restore $RANGE_KEY to $ORIG_RANGE; do it by hand\n" }
    }
    unlink $PROBE if defined $PROBE && -e $PROBE;

    if ( $ENV{EA4344_KEEP} ) {
        print "# EA4344_KEEP set: account '" . ( $USER // '' ) . "' and root ports (@ROOT_PORTS) left in place\n";
    }
    else {
        my %mine = map { $_ => 1 } @ROOT_PORTS;
        my $root = pa_list('root');
        my @take = grep { $mine{$_} || ( $root->{$_}{service} // '' ) =~ m/^e344/ } keys %{$root};
        run_cmd( $PORT_AUTH, 'take', 'root', @take ) if @take;

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
}

#=============================================================================
# Account: ea_podman is an addon feature, so the package's feature list turns it
# on. hasshell=1 so `su` can run the CLI as the account.
#=============================================================================

{
    my $suffix = substr( time, -5 );
    $USER        = "e344$suffix";
    $FEATURELIST = "ea4344fl$suffix";
    $PKG         = "ea4344pkg$suffix";

    note_both("Creating throwaway account '$USER' ...");

    my ( $fl, $flrc, $flraw ) = whmapi( 'create_featurelist', "featurelist=$FEATURELIST", 'ea_podman=1' );
    if ( !whm_ok($fl) ) {
        my $why = ( $fl && $fl->{metadata}{reason} ) || "exit $flrc: " . substr( $flraw, 0, 300 );
        ( $FEATURELIST, $PKG, $USER ) = ();
        plan skip_all => "could not create the feature list: $why";
    }

    my ( $pk, $pkrc, $pkraw ) = whmapi( 'addpkg', "name=$PKG", "featurelist=$FEATURELIST", 'quota=unlimited' );
    if ( !whm_ok($pk) ) {
        my $why = ( $pk && $pk->{metadata}{reason} ) || "exit $pkrc: " . substr( $pkraw, 0, 300 );
        ( $PKG, $USER ) = ();
        plan skip_all => "could not create the package: $why";
    }

    # plan= NOT pkg=; `pkg=` is silently ignored and the account lands on
    # `default`. hasshell=1 NOT shell=; the latter is ignored.
    my ( $acct, $acrc, $acraw ) = whmapi(
        'createacct',
        "username=$USER",
        "domain=$USER.ea4344.test",
        'password=Ea4344' . $suffix . '!Qx9z',
        "plan=$PKG",
        'hasshell=1',
    );
    if ( !whm_ok($acct) ) {
        my $why = ( $acct && $acct->{metadata}{reason} ) || "exit $acrc: " . substr( $acraw, 0, 300 );
        my $u   = $USER;
        undef $USER;    # nothing was created, so END has no account to remove
        plan skip_all => "could not create test account '$u': $why";
    }
}

$HOME = ( getpwnam($USER) )[7];
plan skip_all => "could not resolve a homedir for '$USER'" if !length( $HOME // '' ) || !-d $HOME;
note_both("Test user: $USER, home: $HOME");

# Calls the exact function under test, so A and B do not depend on a pull, a
# container or a session. World-readable so the account can run it too.
$PROBE = "/tmp/ea4344-probe-$$.pl";
{
    open( my $fh, '>', $PROBE ) or die "Could not write $PROBE: $!\n";
    print {$fh} <<'PROBE';
use strict;
use warnings;
use ea_podman::util ();
my @ports = eval { ea_podman::util::_get_new_ports( $ARGV[0], 1 ) };
my $err   = $@;
print "PORTS=@ports\n";
if ($err) { print "DIED=$err"; exit 3 }
exit 0;
PROBE
    close $fh;
    chmod 0755, $PROBE;
}

#=============================================================================
# Trigger: widen the ephemeral range and take the one port it leaves.
#=============================================================================

$ORIG_RANGE = get_range();
plan skip_all => "could not read $RANGE_KEY" if !defined $ORIG_RANGE;
note_both("original $RANGE_KEY: $ORIG_RANGE");

#=============================================================================
# The fix must be there unless this run says it is not.
#=============================================================================

if ($EXPECT_OLD) {
    ok( !$HAS_FIX, 'EA4344_EXPECT_OLD_EAPODMAN is set and the installed util.pm lacks the EA4-344 change' )
      or BAIL_OUT('EA4344_EXPECT_OLD_EAPODMAN=1 but the fix is installed; unset it');
}
else {
    ok( $HAS_FIX, "the installed util.pm carries the EA4-344 change ($EAP_UTIL)" )
      or BAIL_OUT('ea-podman without EA4-344 is installed; deploy the working tree, or set EA4344_EXPECT_OLD_EAPODMAN=1 for a before run');
}

subtest 'setup: the port authority has no port left to give' => sub {
    ok( set_range($WIDE), "$RANGE_KEY is now $WIDE" ) or BAIL_OUT("could not set $RANGE_KEY");

    # With the wide range at most one port (10000) is assignable; take it.
    my ( $rc, $port, $out );
    for my $n ( 1 .. 3 ) {
        ( $rc, $port, $out ) = pa_give_root("e344fill$n.root");
        last if $rc != 0;
        push @ROOT_PORTS, $port if defined $port;
    }
    $LAST_OUT = $out;
    note_both( 'filled with root port(s): ' . ( @ROOT_PORTS ? "@ROOT_PORTS" : '(none; already taken)' ) );

    isnt( $rc, 0, 'a further `give` fails' ) or BAIL_OUT('the port authority still gives ports with the wide range; CPANEL-57865 may be fixed on this build, so this trigger no longer works');
    like( $out, $NO_PORTS_RE, 'with "Not enough free ports"' );
};

#=============================================================================
# A -- root path
#=============================================================================

subtest 'A: as root, _get_new_ports() dies with the port authority\'s message' => sub {
    my %before = %{ pa_list('root') };
    my ( $rc, $out, $err ) = run_cmd( $PERL, "-I$EAP_LIB", $PROBE, 'e344a.root.01' );
    $LAST_OUT = $out . $err;

    if ($EXPECT_OLD) {
        is( $rc, 0, 'the old code does not die' );
        like( $out, qr/^PORTS=$/m, 'and returns no port' );
    }
    else {
        is( $rc, 3, 'it dies' );
        like( $out, qr/DIED=Could not assign root ports: $NO_PORTS_RE/, 'naming the root path and the cause' );
    }
    is_deeply( [ sort keys %{ pa_list('root') } ], [ sort keys %before ], 'no root port was assigned' );
};

#=============================================================================
# B -- user path, through the real admin module
#=============================================================================

subtest 'B: as the account, _get_new_ports() dies through the admin module' => sub {
    my ( $rc, $out ) = as_user( $USER, "$PERL -I$EAP_LIB $PROBE e344b.$USER.01 2>&1" );
    $LAST_OUT = $out;

    if ($EXPECT_OLD) {
        is( $rc, 0, 'the old code does not die' );
        like( $out, qr/^PORTS=$/m, 'and returns no port' );
    }
    else {
        is( $rc, 3, 'it dies, so GIVE\'s exit status survived the admin call' );
        like( $out, qr/DIED=Could not assign user ports: $NO_PORTS_RE/, 'naming the user path and the cause' );
    }
    is( describe_ports($USER), '(none)', 'the account holds no port' );
};

#=============================================================================
# C -- `ea-podman install` as the account, the path a Web App deploy takes
#=============================================================================

my $C_DIR = "$HOME/ea-podman.d/e344c.$USER.01";

subtest 'C: `ea-podman install` as the account fails, names the cause and keeps nothing' => sub {
    my ( $rc, $out ) = as_user( $USER, "$EAP_BIN install e344c --i-understand-the-risks-do-it-anyway --cpuser-port=$CPORT " . _sh($IMAGE) . ' 2>&1' );
    $LAST_OUT = $out;

    if ($EXPECT_OLD) {
        if ( $out =~ /toomanyrequests|rate limit/i ) {
            pass('skipped: registry rate limit (the old code reaches the pull)');
            return;
        }
        is( $rc, 0, 'the old code "succeeds"' );
        is( describe_ports($USER), '(none)', 'with no port reserved, which is the bug' );
        return;
    }

    isnt( $rc, 0, 'the install fails' );
    like( $out, qr/Could not assign user ports: $NO_PORTS_RE/, 'and says why' );
    unlike( $out, qr/^Done, installed:/m, 'and does not claim success' );

    my ( undef, $reg ) = as_user( $USER, "$EAP_BIN containers 2>&1" );
    unlike( $reg, qr/e344c\./, 'nothing is registered' );

    my ( undef, $ps ) = as_user( $USER, 'podman ps -a --format "{{.Names}}" 2>&1' );
    unlike( $ps, qr/e344c\./, 'no container was created' );

    is( describe_ports($USER), '(none)', 'no port is reserved' );

  TODO: {
        local $TODO = 'EA4-344 dies after the container dir and ea-podman.json are written; nothing removes them on this failure';
        ok( !-e $C_DIR, 'no container directory is left behind' ) or note_both("left behind: $C_DIR");
    }
};

#=============================================================================
# D -- control: the same install with the range restored
#=============================================================================

subtest 'D: control -- with the range restored, the same install succeeds with one port' => sub {
    ok( set_range($ORIG_RANGE), "$RANGE_KEY is back to $ORIG_RANGE" ) or return;

    my ( $rc, $out ) = as_user( $USER, "$EAP_BIN install e344c --i-understand-the-risks-do-it-anyway --cpuser-port=$CPORT " . _sh($IMAGE) . ' 2>&1' );
    $LAST_OUT = $out;

    if ( $out =~ /toomanyrequests|rate limit/i ) {
        pass('skipped: registry rate limit');
        return;
    }

    is( $rc, 0, 'the install succeeds' ) or return;
    my ($name) = $out =~ m/^Done, installed: (\S+)/m;
    ok( defined $name, 'it reports the container' . ( defined $name ? " ($name)" : '' ) ) or return;

    my $ports = pa_list($USER);
    my @mine  = grep { ( $ports->{$_}{service} // '' ) eq $name } keys %{$ports};
    is( scalar @mine, 1, 'exactly one port is reserved for it' ) or note_both( 'user ports: ' . describe_ports($USER) );

    if ( !$EXPECT_OLD ) {
      TODO: {
            local $TODO = 'a directory left by a failed install pushes the retry to the next number';
            is( $name, "e344c.$USER.01", 'the retry reuses the .01 name' );
        }
    }

    my ( $urc, $uout ) = as_user( $USER, "$EAP_BIN uninstall $name --verify 2>&1" );
    is( $urc, 0, 'it uninstalls' ) or note_both($uout);
    unlike( $uout, qr/can not be undone/, 'and was not refused for want of --verify (which still exits 0)' );
    my $after = pa_list($USER);
    is( scalar( grep { ( $after->{$_}{service} // '' ) eq $name } keys %{$after} ), 0, 'and its port is given back' );
};

done_testing();
