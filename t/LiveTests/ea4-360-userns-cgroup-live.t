#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# EA4-360 — LIVE integration test (NOT a unit test).
#
# WHAT THIS PROVES.
#
#   1. The cgroup v1 heads-up root gets is right for this OS:
#        - nothing on cgroup v2, and nothing on CloudLinux 8 (v2 breaks the
#          user manager there under hidepid=2, EA4-365);
#        - `tuned-adm profile cloudlinux-default-cgv2` on CloudLinux 9/10,
#          never grubby (the tuned profile overrides it);
#        - grubby everywhere else.
#   2. With user.max_user_namespaces=0, a user's podman verbs are refused
#      with the host message and the go.cpanel.net/userns link, through UAPI
#      and the CLI, and WITHOUT a Perl stack trace or exception id.
#   3. The verbs that need no podman still work without user namespaces:
#      list, status, `containers`, stop and uninstall (ports, registry and
#      unit go), and a container that was already running keeps serving.
#   4. With user namespaces restored, a fresh install works again.
#
# It changes a HOST-WIDE sysctl (user.max_user_namespaces) for the duration
# and puts the original value back in END, even on failure or Ctrl-C. Every
# account's new containers are refused while it runs. Use a test VM.
#
# Run ON A LIVE cPanel VM, as root, with podman installed and an ea-podman
# build carrying EA4-360 (PR #45 at e2c78b1 or later):
#
#   scp t/LiveTests/ea4-360-userns-cgroup-live.t root@VM:/root/
#   EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea4-360-userns-cgroup-live.t
#
# Environment variables:
#   EAPODMAN_LIVE=1      REQUIRED opt-in.
#   EAPODMAN_TEST_USER   reuse an existing account (its shell is set to an
#                        unrestricted shell for the test and restored
#                        afterward) instead of creating a throwaway one.
#   EAPODMAN_TEST_IMAGE  image to install (default: redis:alpine).
#   EAPODMAN_TEST_PORT   container port to publish (default: 6379).
#   EAPODMAN_KEEP=1      skip teardown (the sysctl is still restored).
#
# Leaves behind: nothing for a throwaway account (it is removed). For
# EAPODMAN_TEST_USER, the test's containers are removed and the shell restored.
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
my $IMAGE = $ENV{EAPODMAN_TEST_IMAGE} || 'docker.io/library/redis:alpine';
my $PORT  = $ENV{EAPODMAN_TEST_PORT}  || 6379;
my $KEEP  = $ENV{EAPODMAN_KEEP};
my $CBASE = 'eapod360';
my $BASH  = '/bin/bash';

my $UAPI      = '/usr/local/cpanel/bin/uapi';
my $WHMAPI    = '/usr/local/cpanel/bin/whmapi1';
my $EAP_LIB   = '/opt/cpanel/ea-podman/lib/ea_podman';
my $UAPI_MOD  = '/usr/local/cpanel/Cpanel/API/EAPodman.pm';
my $PORTAUTH  = '/usr/local/cpanel/scripts/cpuser_port_authority';
my @CLI_PATHS = ( '/usr/local/cpanel/scripts/ea-podman', '/opt/cpanel/ea-podman/bin/ea-podman' );

my $USERNS_SYSCTL = 'user.max_user_namespaces';

my $CGROUP_ADVICE  = qr/We recommend cgroup v2/;
my $USERNS_REFUSAL = qr/requires user namespaces/;
my $USERNS_URL     = qr{go\.cpanel\.net/userns};

# What the user must not see: a Perl location, the AdminBin call stack, or the
# exception id that get_string_no_id() strips.
my @LEAKS = (
    [ qr/ at \S+ line \d+/,       'no Perl "at FILE line N"' ],
    [ qr/Cpanel::AdminBin::Call/, 'no AdminBin call stack' ],
    [ qr/\(XID [a-z0-9]+\)/i,     'no exception id' ],
);

#---------------------------------------------------------------------
# helpers
#---------------------------------------------------------------------
my $json;

sub run_cmd {
    my (@cmd) = @_;
    my $err   = Symbol::gensym();
    my $pid   = IPC::Open3::open3( my $in, my $out, $err, @cmd );
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
    my $err   = Symbol::gensym();
    my $pid   = IPC::Open3::open3( my $in, my $out, $err, @cmd );
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid( $pid, 0 );
    my $decoded = eval { $json->($stdout) };
    return ( $? >> 8, $decoded, $stdout, $stderr );
}

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

sub uapi_errors {
    my ($res) = @_;
    return join( "\n", @{ $res->{errors} || [] } );
}

sub wait_for {
    my ( $predicate, $timeout ) = @_;
    $timeout //= 10;
    for ( 1 .. $timeout * 10 ) {
        return 1 if $predicate->();
        select( undef, undef, undef, 0.1 );
    }
    return $predicate->();
}

sub read_userns {
    my ( $rc, $out ) = run_cmd( 'sysctl', '-n', $USERNS_SYSCTL );
    return $rc == 0 && $out =~ /^(\d+)/ ? $1 : undef;
}

sub set_userns {
    my ($n)  = @_;
    my ($rc) = run_cmd( 'sysctl', '-w', "$USERNS_SYSCTL=$n" );
    return $rc == 0 && ( read_userns() // -1 ) == $n;
}

# ( ID, major VERSION_ID ) from /etc/os-release, lowercased ID.
sub os_id_major {
    open my $fh, '<', '/etc/os-release' or return ( '', 0 );
    my %kv;
    while ( my $line = <$fh> ) {
        next if $line !~ /^(\w+)=(.*)$/;
        my ( $k, $v ) = ( $1, $2 );
        $v =~ s/^"(.*)"$/$1/;
        $kv{$k} = $v;
    }
    close $fh;
    my ($major) = ( $kv{VERSION_ID} // '' ) =~ /^(\d+)/;
    return ( lc( $kv{ID} // '' ), $major // 0 );
}

# A refusal is the host message with the link, and nothing a user should not see.
sub is_clean_refusal {
    my ( $text, $what ) = @_;
    like( $text, $USERNS_REFUSAL, "$what: says user namespaces are required" );
    like( $text, $USERNS_URL,     "$what: links go.cpanel.net/userns" );
    unlike( $text, $_->[0], "$what: $_->[1]" ) for @LEAKS;
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

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub _assigned_host_port {
    my ( $user, $container ) = @_;
    my ( $rc,   $out )       = run_cmd( $PORTAUTH, 'list', $user );
    return if $rc != 0;
    my $hr = eval { $json->($out) };
    return if !$hr || ref $hr ne 'HASH';
    for my $port ( keys %{$hr} ) {
        my $svc = ref $hr->{$port} eq 'HASH' ? ( $hr->{$port}{service} // '' ) : '';
        return $port if $svc eq $container;
    }
    return;
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

sub _serving {
    my ( $user, $container, $port ) = @_;
    $port //= _assigned_host_port( $user, $container ) or return 0;
    return _redis_ping_over_tcp( '127.0.0.1', $port );
}

sub install_container {
    my ($user) = @_;
    return uapi( $user, 'install', "name=$CBASE", "image=$IMAGE", "cpuser_port=$PORT", 'accept_arbitrary_image_risk=1' );
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

plan skip_all => "podman is not installed"                     if !_in_path('podman');
plan skip_all => "uapi not found ($UAPI)"                      if !-x $UAPI;
plan skip_all => "Cpanel::API::EAPodman not installed"         if !-e $UAPI_MOD;
plan skip_all => "ea-podman library not installed"             if !-e "$EAP_LIB/util.pm";
plan skip_all => "cpuser_port_authority not found ($PORTAUTH)" if !-x $PORTAUTH;

my ($CLI) = grep { -x $_ } @CLI_PATHS;
plan skip_all => "ea-podman CLI not found (@CLI_PATHS)" if !$CLI;

{
    open my $fh, '<', "$EAP_LIB/util.pm" or plan skip_all => "cannot read $EAP_LIB/util.pm";
    local $/;
    my $src = <$fh>;
    close $fh;
    plan skip_all => "installed ea-podman predates EA4-360 e2c78b1 (no CloudLinux cgroup advice / ENSURE_USER message in util.pm); install the PR #45 build first"
      if $src !~ /cloudlinux-default-cgv2/ || $src !~ /get_string_no_id/;
}

our $ORIG_USERNS = read_userns();
plan skip_all => "cannot read $USERNS_SYSCTL"                                      if !defined $ORIG_USERNS;
plan skip_all => "$USERNS_SYSCTL is already 0; set it to the kernel default first" if $ORIG_USERNS == 0;

# Make sure END (which restores the sysctl) runs on Ctrl-C too.
$SIG{INT} = $SIG{TERM} = sub { die "interrupted\n" };

my ( $OS_ID, $OS_MAJOR ) = os_id_major();
my $IS_CL  = $OS_ID eq 'cloudlinux'                 ? 1    : 0;
my $CGROUP = -e '/sys/fs/cgroup/cgroup.controllers' ? 'v2' : 'v1';

#---------------------------------------------------------------------
# test account
#---------------------------------------------------------------------
our $USER;
our $CREATED_USER = 0;
our $ORIG_SHELL;
our @CONTAINERS;    # every container name install returned, for teardown

if ( $ENV{EAPODMAN_TEST_USER} ) {
    $USER = $ENV{EAPODMAN_TEST_USER};
    plan skip_all => "EAPODMAN_TEST_USER '$USER' is not a system user" if !defined getpwnam($USER);
    $ORIG_SHELL = ( getpwnam($USER) )[8];
}
else {
    $USER = 'ea360' . substr( time, -5 );
    my $domain = "$USER.ea4-360.test";
    my $pw     = 'Eap0d' . substr( time, -6 ) . '!Xy';

    diag("Creating throwaway cPanel account '$USER' ($domain) …");
    my ( $rc, $res, $out, $err ) = run_json( $WHMAPI, 'createacct', "username=$USER", "domain=$domain", "password=$pw", '--output=json' );
    if ( !$res || !$res->{metadata} || !$res->{metadata}{result} ) {
        plan skip_all => "could not create test account '$USER' (set EAPODMAN_TEST_USER to reuse one):\nSTDOUT:\n$out\nSTDERR:\n$err";
    }
    $CREATED_USER = 1;
}

$ORIG_SHELL //= ( getpwnam($USER) )[8];
run_cmd( '/usr/sbin/usermod', '-s', $BASH, $USER );

diag("OS=$OS_ID $OS_MAJOR, cgroup=$CGROUP, $USERNS_SYSCTL=$ORIG_USERNS, user=$USER, image=$IMAGE, port=$PORT, cli=$CLI");

# The user-CLI checks run it through `su`, as a normal account would. A caged
# account (CageFS "Enable All" cages new accounts) reaches it through the cage
# bridge instead, so say which this run is.
if ( -x '/usr/sbin/cagefsctl' ) {
    my ( $rc, $out ) = run_cmd( '/usr/sbin/cagefsctl', '--list-enabled' );
    my $caged = grep { $_ eq $USER } split /\s+/, $out;
    diag( "CageFS: $USER is " . ( $caged ? "CAGED (user CLI goes through the cage bridge)" : "not caged" ) );
}

#=====================================================================
# 1. the cgroup heads-up root gets
#=====================================================================
subtest "cgroup advice for root ($OS_ID $OS_MAJOR, cgroup $CGROUP)" => sub {

    # `containers` only reads the registry, but goes through init_user(), which
    # is what gives the advice.
    my ( $rc, $out ) = run_cmd( $CLI, 'containers' );
    is( $rc, 0, "root `ea-podman containers` exits 0" ) or diag($out);

    my $count = () = $out =~ /$CGROUP_ADVICE/g;

    if ( $CGROUP eq 'v2' ) {
        is( $count, 0, "no cgroup advice on cgroup v2" ) or diag($out);
        diag("NOTE: CloudLinux 8 on cgroup v2 gets no warning either; EA4-365 tracks v2 there") if $IS_CL && $OS_MAJOR == 8;
    }
    elsif ( $IS_CL && $OS_MAJOR == 8 ) {
        is( $count, 0, "no cgroup advice on CloudLinux 8 (stays on v1, EA4-365)" ) or diag($out);
    }
    elsif ($IS_CL) {
        is( $count, 1, "cgroup advice given exactly once" ) or diag($out);
        like( $out, qr/tuned-adm profile cloudlinux-default-cgv2/, "CloudLinux $OS_MAJOR: gives the tuned profile" );
        unlike( $out, qr/grubby/, "CloudLinux $OS_MAJOR: not grubby, which the tuned profile overrides" );
    }
    else {
        is( $count, 1, "cgroup advice given exactly once" ) or diag($out);
        like( $out, qr/grubby --update-kernel=ALL --args="systemd\.unified_cgroup_hierarchy=1"/, "gives the grubby kernel arg" );
        unlike( $out, qr/tuned-adm/, "no tuned-adm off CloudLinux" );
    }
};

#=====================================================================
# 2. a running container, made while user namespaces are on
#=====================================================================
my ( $container, $host_port );
{
    my $res = install_container($USER);
    ok( $res->{status}, "baseline: uapi install succeeds with user namespaces on" ) or diag( uapi_errors($res) );
    $container = $res->{data} && $res->{data}{container_name};
    push @CONTAINERS, $container if $container;
}
BAIL_OUT("install did not return a container name; cannot continue") if !$container;

ok( wait_for( sub { _serving( $USER, $container ) }, 30 ), "baseline: $container answers PING on its host port" );
$host_port = _assigned_host_port( $USER, $container );
ok( $host_port, "baseline: port authority assigned a host port ($host_port)" );

#=====================================================================
# 3. user namespaces off
#=====================================================================
ok( set_userns(0), "$USERNS_SYSCTL set to 0" ) or BAIL_OUT("could not set $USERNS_SYSCTL=0");

subtest 'podman verbs are refused, cleanly, for the user' => sub {
    my $res = install_container($USER);
    ok( !$res->{status}, "uapi install is refused" );
    push @CONTAINERS, $res->{data}{container_name} if $res->{status} && $res->{data};
    is_clean_refusal( uapi_errors($res), 'uapi install' );

    $res = uapi( $USER, 'start', "container_name=$container" );
    ok( !$res->{status}, "uapi start is refused" );
    is_clean_refusal( uapi_errors($res), 'uapi start' );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . ' list' );
    isnt( $rc, 0, "user CLI `list` exits non-zero" );
    is_clean_refusal( $out, 'user CLI list' );

    ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . " install $CBASE --cpuser-port=$PORT --i-understand-the-risks-do-it-anyway " . _sh($IMAGE) );
    isnt( $rc, 0, "user CLI `install` exits non-zero" );
    is_clean_refusal( $out, 'user CLI install' );
};

subtest 'podman verbs are refused for root' => sub {
    my ( $rc, $out ) = run_cmd( $CLI, 'list' );
    isnt( $rc, 0, "root CLI `list` exits non-zero" );
    like( $out, $USERNS_REFUSAL, "root CLI list: says user namespaces are required" );
    like( $out, $USERNS_URL,     "root CLI list: links go.cpanel.net/userns" );
};

subtest 'verbs that need no podman still work' => sub {
    my $res = uapi( $USER, 'list' );
    ok( $res->{status},                           "uapi list works" ) or diag( uapi_errors($res) );
    ok( $res->{data} && $res->{data}{$container}, "uapi list still shows $container" );

    $res = uapi( $USER, 'status', "container_name=$container" );
    ok( $res->{status},                        "uapi status works" ) or diag( uapi_errors($res) );
    ok( $res->{data} && $res->{data}{running}, "uapi status: $container is still running" );

    my ( $rc, $out ) = run_as_user( $USER, _sh($CLI) . ' containers' );
    is( $rc, 0, "user CLI `containers` works" ) or diag($out);
    like( $out, qr/\Q$container\E/, "user CLI containers lists $container" );

    ok( _serving( $USER, $container, $host_port ), "$container keeps serving without user namespaces" );

    $res = uapi( $USER, 'stop', "container_name=$container" );
    ok( $res->{status},                                                           "uapi stop works" ) or diag( uapi_errors($res) );
    ok( wait_for( sub { !_redis_ping_over_tcp( '127.0.0.1', $host_port ) }, 30 ), "$container stops serving after stop" );

    $res = uapi( $USER, 'uninstall', "container_name=$container" );
    ok( $res->{status}, "uapi uninstall works" ) or diag( uapi_errors($res) );

    $res = uapi( $USER, 'list' );
    ok( $res->{status} && !( $res->{data} || {} )->{$container}, "uninstall removed $container from the registry" );
    ok( !_assigned_host_port( $USER, $container ),               "uninstall gave back the host port" );

    {
        # Known gap (Kōan #l on PR #45): the user is told it succeeded, though
        # podman's copy of the container and image stay behind. Only error_log
        # gets the "carrying on" warning.
        local $TODO = "uninstall without user namespaces does not tell the user podman's copy was left";
        ok( @{ $res->{warnings} || [] }, "uapi uninstall carries a warning" );
    }
};

#=====================================================================
# 4. user namespaces back on
#=====================================================================
ok( set_userns($ORIG_USERNS), "$USERNS_SYSCTL restored to $ORIG_USERNS" );

# The uninstall above left podman's copy (see the TODO). The registry no longer
# has the name, so the next install may be given it again; clear it so this
# checks recovery, not that gap.
{
    my ( $rc, $out ) = run_as_user( $USER, "podman ps -a --format '{{.Names}}'" );
    my $left = grep { $_ eq $container } split /\n/, $out;
    diag( $left ? "podman still has $container after the uninstall without user namespaces (known gap); removing it" : "podman has no leftover $container" );
    run_as_user( $USER, "podman rm -f " . _sh($container) . " >/dev/null 2>&1" ) if $left;
}

{
    my $res = install_container($USER);
    ok( $res->{status}, "with user namespaces back, uapi install works again" ) or diag( uapi_errors($res) );
    my $again = $res->{data} && $res->{data}{container_name};
    push @CONTAINERS, $again if $again;
    ok( $again && wait_for( sub { _serving( $USER, $again ) }, 30 ), "the new container serves" );
}

done_testing();

#---------------------------------------------------------------------
# teardown
#---------------------------------------------------------------------
END {
    # Always, even with EAPODMAN_KEEP: the whole server depends on it.
    if ( defined $ORIG_USERNS && ( read_userns() // -1 ) != $ORIG_USERNS ) {
        set_userns($ORIG_USERNS) or print STDERR "!!! could not restore $USERNS_SYSCTL=$ORIG_USERNS; restore it by hand\n";
    }

    return if $KEEP;
    return if !$USER;

    for my $c (@CONTAINERS) {
        run_cmd( $UAPI, "--user=$USER", '--output=json', 'EAPodman', 'uninstall', "container_name=$c" );

        # What an uninstall without user namespaces left in podman.
        run_as_user( $USER, "podman rm -f " . _sh($c) . " >/dev/null 2>&1" );
    }

    if ($CREATED_USER) {
        run_cmd( $WHMAPI, 'removeacct', "username=$USER", 'keepdns=0', '--output=json' );
    }
    elsif ( $ORIG_SHELL && $ORIG_SHELL ne $BASH ) {
        run_cmd( '/usr/sbin/usermod', '-s', $ORIG_SHELL, $USER );
    }
}
