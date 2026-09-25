#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

#######################################################################
# EA4-315 — LIVE integration test (NOT a unit test).
#
# WHAT THIS PROVES. The ea_podman adminbin became an in-process admin module
# (Cpanel::Admin::Modules::Cpanel::ea_podman), the CLI stopped being compiled,
# and jailshell/CageFS CLI commands moved from a full-access API token onto
# new lifecycle admin actions. The promise is that nothing outside ea-podman
# has to change how it calls in. This checks that promise on a real server:
#
#   1. packaging   - the module is installed; the legacy bin, compile.sh and
#                    the upcp install task are gone; bin/ea-podman is an
#                    rpm/deb-owned perl script, not a compiled binary.
#   2. caller check - with /var/cpanel/skipparentcheck out of the way, an
#                    uncompiled perl process reaches ea_podman while a
#                    default-parents core module (Cpanel/user) refuses it.
#   3. old callers - the legacy call('Cpanel','ea_podman',ACTION,...) triple,
#                    return shapes, and error text (not bare error IDs).
#   4. lifecycle   - from inside a real jail: INSTALL ... UNINSTALL through
#                    the new actions, redis actually serving, ports and the
#                    registry cleaned up, other accounts' containers refused,
#                    and no API token minted (cpwrapd_log).
#   5. feature     - untouched, everything works; with ea_podman=0 in the
#                    account's feature list, installs are refused through the
#                    UAPI, the admin action and the CLI, and uninstall works.
#   6. demo        - a demo account is refused.
#   7. upgrade     - OPTIONAL, with EAPODMAN_UPGRADE_FROM/_TO: old package
#                    with a live container, upgraded in place.
#
# It creates two throwaway cPanel accounts (one jailshell, one normal), pulls
# an image, starts rootless containers, and temporarily moves
# /var/cpanel/skipparentcheck, adds a feature list + package, and sets DEMO on
# an account. All of it is undone in END unless EAPODMAN_KEEP=1.
#
# Run ON A DISPOSABLE cPanel VM, as root, with the new ea-podman installed
# (or pass the two package files for the upgrade section):
#
#   scp t/LiveTests/ea4-315-admin-module-live.t root@VM:/root/
#   ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl /root/ea4-315-admin-module-live.t'
#
#   # with the upgrade section (rpm or deb, both files already on the VM):
#   ssh root@VM 'EAPODMAN_LIVE=1 EAPODMAN_UPGRADE_FROM=/root/ea-podman-1.0-30.rpm \
#       EAPODMAN_UPGRADE_TO=/root/ea-podman-1.0-31.rpm \
#       /usr/local/cpanel/3rdparty/bin/perl /root/ea4-315-admin-module-live.t'
#
# Environment variables:
#   EAPODMAN_LIVE=1          REQUIRED opt-in.
#   EAPODMAN_UPGRADE_FROM    old ea-podman package file (.rpm/.deb) - optional.
#   EAPODMAN_UPGRADE_TO      new ea-podman package file (.rpm/.deb) - optional.
#   EAPODMAN_TEST_IMAGE      image to install (default: redis:alpine).
#   EAPODMAN_TEST_PORT       container port to publish (default: 6379).
#   EAPODMAN_KEEP=1          skip teardown (accounts, containers, settings).
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
my $IMAGE        = $ENV{EAPODMAN_TEST_IMAGE} || 'docker.io/library/redis:alpine';
my $PORT         = $ENV{EAPODMAN_TEST_PORT}  || 6379;
my $KEEP         = $ENV{EAPODMAN_KEEP};
my $UPGRADE_FROM = $ENV{EAPODMAN_UPGRADE_FROM};
my $UPGRADE_TO   = $ENV{EAPODMAN_UPGRADE_TO};
my $CBASE        = 'eapod315';

my $PERL        = '/usr/local/cpanel/3rdparty/bin/perl';
my $UAPI        = '/usr/local/cpanel/bin/uapi';
my $WHMAPI      = '/usr/local/cpanel/bin/whmapi1';
my $JAILSHELL   = '/usr/local/cpanel/bin/jailshell';
my $MODULE      = '/usr/local/cpanel/Cpanel/Admin/Modules/Cpanel/ea_podman.pm';
my $CLI         = '/opt/cpanel/ea-podman/bin/ea-podman';
my $SCRIPTS_CLI = '/usr/local/cpanel/scripts/ea-podman';
my $SKIP_PARENT = '/var/cpanel/skipparentcheck';
my $CPWRAPD_LOG = '/usr/local/cpanel/logs/cpwrapd_log';
my $FEATURELIST = 'eap315_noea_podman';
my $PACKAGE     = 'eap315_noea_podman';
my $LEGACY_LIST = 'eap315_legacy';                                                # a list saved before ea_podman existed
my $LEGACY_PKG  = 'eap315_legacy';

my @GONE = (
    '/usr/local/cpanel/bin/admin/Cpanel/ea_podman',
    '/usr/local/cpanel/bin/admin/Cpanel/ea_podman.conf',
    '/opt/cpanel/ea-podman/bin/compile.sh',
    '/usr/local/cpanel/install/EAPodman.pm',
);

#---------------------------------------------------------------------
# state the END block undoes
#---------------------------------------------------------------------
our ( $JUSER, $NUSER );    # jailshell and normal throwaway accounts
our %CONTAINERS;           # container_name => user, for best-effort cleanup
our $MOVED_SKIP_PARENT;
our %ORIG_PLAN;            # user => package, when this test changed it
our %MADE_FEATURELIST;
our %MADE_PACKAGE;
our %DEMO_SET;             # user => 1 while DEMO=1 is set

my $json;

#---------------------------------------------------------------------
# helpers
#---------------------------------------------------------------------

# Run a command (list form, no shell); returns ($exit, $stdout . $stderr).
sub run_cmd {
    my (@cmd) = @_;
    my ( $exit, $out, $err ) = run_cmd3(@cmd);
    return ( $exit, $out . $err );
}

sub run_cmd3 {
    my (@cmd) = @_;
    my $err   = Symbol::gensym();
    my $pid   = IPC::Open3::open3( my $in, my $out, $err, @cmd );
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid( $pid, 0 );
    return ( $? >> 8, $stdout, $stderr );
}

# whmapi1/uapi with --output=json: decode STDOUT alone (cpsrvd logs to STDERR).
sub run_json {
    my (@cmd) = @_;
    my ( $exit, $out, $err ) = run_cmd3(@cmd);
    my $decoded = eval { $json->($out) };
    return ( $exit, $decoded, $out, $err );
}

sub whmapi {
    my ( $func, @kv ) = @_;
    my ( $rc, $res, $out, $err ) = run_json( $WHMAPI, $func, @kv, '--output=json' );
    my $ok = $res && $res->{metadata} && $res->{metadata}{result};
    return wantarray ? ( $ok, $res, "$out$err" ) : $ok;
}

# EAPodman UAPI verb as $user; returns the {result} object.
sub uapi {
    my ( $user, $func, @kv ) = @_;
    my ( $rc, $decoded, $out, $err ) = run_json( $UAPI, "--user=$user", '--output=json', 'EAPodman', $func, @kv );
    die "uapi $func: could not parse JSON (exit $rc):\nSTDOUT:\n$out\nSTDERR:\n$err\n" if !$decoded;
    return $decoded->{result} // $decoded;
}

sub uapi_errors {
    my ($res) = @_;
    return join( "; ", @{ $res->{errors} || [] } );
}

# As $user, without the login shell, with the rootless podman env primed.
# A non-login su keeps root's environment, so drop what would point the
# account's perl at root's paths (`prove -l` exports PERL5LIB=/root/lib, which
# the account cannot read, and perl dies on that).
sub run_as_user {
    my ( $user, $cmd ) = @_;
    my $uid = ( getpwnam($user) )[2];
    my $env = "unset PERL5LIB PERLLIB PERL5OPT; export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus HOME=\"\$(getent passwd $user | cut -d: -f6)\"; cd \"\$HOME\" 2>/dev/null;";
    return run_cmd( 'su', '-s', '/bin/bash', $user, '-c', "$env $cmd" );
}

# Through the account's LOGIN shell: for a jailshell account, inside the jail.
sub run_login {
    my ( $user, $cmd ) = @_;
    return run_cmd( 'su', '-', $user, '-c', $cmd );
}

# The tiny caller script each test account runs. It is deliberately a plain,
# uncompiled perl script: that is exactly the kind of caller the old
# compiled-parent check refused, and exactly what any outside caller is.
my $CALLER_SRC = <<'EOPERL';
use strict;
use warnings;
use lib '/usr/local/cpanel';
use Cpanel::AdminBin::Call ();
use Cpanel::Exception      ();
use Cpanel::JSON           ();

my ( $ns, $module, $action, $args_json ) = @ARGV;
my @args = @{ Cpanel::JSON::Load( $args_json // '[]' ) };

my $out;
my $data = eval { scalar Cpanel::AdminBin::Call::call( $ns, $module, $action, @args ) };
if ( my $err = $@ ) {
    my $msg = eval { Cpanel::Exception::get_string_no_id($err) } // "$err";
    $out = { ok => 0, class => ( ref($err) || '' ), error => $msg, raw => "$err" };
}
else {
    $out = { ok => 1, data => $data };
}
print "EAP315:" . Cpanel::JSON::Dump($out) . "\n";
EOPERL

sub install_caller_script {
    my ($user) = @_;
    my ( $uid, $gid, $home ) = ( getpwnam($user) )[ 2, 3, 7 ];
    my $path = "$home/.eap315-call.pl";
    open( my $fh, '>', $path ) or die "write $path: $!";
    print {$fh} $CALLER_SRC;
    close $fh;
    chown $uid, $gid, $path;
    chmod 0700, $path;
    return $path;
}

# Call an admin module as $user from an uncompiled perl process.
#   in_jail => 1 goes through the login shell (the real jail for jailshell).
# Returns { ok, data } or { ok => 0, error, class }.
sub admin_call {
    my ( $user, $action, $args, %opts ) = @_;
    my $ns     = $opts{ns}     // 'Cpanel';
    my $module = $opts{module} // 'ea_podman';
    my $home   = ( getpwnam($user) )[7];

    my $cmd = join ' ', map { _sh($_) } $PERL, "$home/.eap315-call.pl", $ns, $module, $action, Cpanel::JSON::Dump( $args || [] );
    my ( $rc, $out ) = $opts{in_jail} ? run_login( $user, $cmd ) : run_as_user( $user, $cmd );

    my ($line) = $out =~ /^EAP315:(.*)$/m;
    my $res = defined $line ? eval { $json->($line) } : undef;
    return $res || { ok => 0, error => "no result from caller script (exit $rc): $out" };
}

sub cpwrapd_log_size { return -s $CPWRAPD_LOG // 0 }

# cpwrapd_log lines written since $offset by $user for module ea_podman.
sub cpwrapd_log_since {
    my ( $offset, $user ) = @_;
    open( my $fh, '<', $CPWRAPD_LOG ) or return ();
    seek( $fh, $offset, 0 );
    my @lines = grep { /\[module\]=\[ea_podman\]/ && /\] \Q$user\E - / } <$fh>;
    close $fh;
    return @lines;
}

sub functions_in {
    return map { /\[function\]=\[([A-Z_]+)\]/ ? $1 : () } @_;
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

sub container_running {
    my ( $user, $container ) = @_;
    my ( $rc,   $out )       = run_as_user( $user, "podman ps --no-trunc --format '{{.Names}}'" );
    return 0 if $rc != 0;
    return scalar grep { $_ eq $container } split /\n/, $out;
}

sub published_host_endpoint {
    my ( $user, $container ) = @_;
    my ( $rc,   $out )       = run_as_user( $user, "podman port " . _sh($container) . " " . _sh("$PORT/tcp") );
    return if $rc != 0;
    for my $line ( split /\n/, $out ) {
        next if $line !~ m/(\S+):([0-9]+)\s*$/;
        my ( $ip, $port ) = ( $1, $2 );
        $ip = '127.0.0.1' if $ip eq '0.0.0.0' || $ip eq '::' || $ip eq '[::]';
        return ( $ip, $port );
    }
    return;
}

sub redis_ping_over_tcp {
    my ( $ip, $port ) = @_;
    my $sock = IO::Socket::INET->new( PeerHost => $ip, PeerPort => $port, Proto => 'tcp', Timeout => 5 ) or return 0;
    syswrite( $sock, "PING\r\n" );
    my $reply = '';
    sysread( $sock, $reply, 64 ) if IO::Select->new($sock)->can_read(5);
    close $sock;
    return $reply =~ /\+PONG/ ? 1 : 0;
}

sub port_authority_services {
    my ($user) = @_;
    my ( $rc, $out ) = run_cmd( '/scripts/cpuser_port_authority', 'list', $user );
    my $hr = eval { $json->($out) } || {};
    return map { $_->{service} // '' } values %{$hr};
}

sub registry_entry {
    my ($container) = @_;
    open( my $fh, '<', '/opt/cpanel/ea-podman/registered-containers.json' ) or return;
    local $/;
    my $all = eval { $json->(<$fh>) } || {};
    return $all->{$container};
}

sub pkg_tool { return -x '/usr/bin/dpkg' && !-x '/usr/bin/rpm' ? 'deb' : 'rpm' }

sub owner_of {
    my ($path) = @_;
    my ( $rc, $out ) = pkg_tool() eq 'deb' ? run_cmd( 'dpkg', '-S', $path ) : run_cmd( 'rpm', '-qf', '--qf', '%{NAME}\n', $path );
    return $rc == 0 ? $out : '';
}

sub is_elf {
    my ($path) = @_;
    open( my $fh, '<', $path ) or return 0;
    read( $fh, my $magic, 4 );
    return ( $magic // '' ) eq "\x7fELF" ? 1 : 0;
}

sub first_line {
    my ($path) = @_;
    open( my $fh, '<', $path ) or return '';
    my $line = <$fh> // '';
    chomp $line;
    return $line;
}

sub create_account {
    my ($prefix) = @_;
    my $user     = $prefix . substr( time, -5 );
    my $domain   = "$user.ea4-315.test";
    my $pw       = 'Eap0d' . substr( time, -6 ) . '!Xy';
    my ( $ok, undef, $out ) = whmapi( 'createacct', "username=$user", "domain=$domain", "password=$pw" );
    return $ok ? $user : ( undef, $out );
}

sub set_demo {
    my ( $user, $on ) = @_;
    my $file = "/var/cpanel/users/$user";
    open( my $fh, '<', $file ) or return 0;
    my @lines = grep { !/^DEMO=/ } <$fh>;
    close $fh;
    push @lines, "DEMO=1\n" if $on;
    open( $fh, '>', $file ) or return 0;
    print {$fh} @lines;
    close $fh;

    # The cached copy is trusted while it is not older than the file; an edit
    # within the same second would go unseen, so drop it.
    unlink "/var/cpanel/users.cache/$user";
    $on ? ( $DEMO_SET{$user} = 1 ) : delete $DEMO_SET{$user};
    return 1;
}

# changepackage applies the package's shell setting; put back the shells the
# scenarios depend on (a normal shell, and jailshell).
sub restore_shells {
    run_cmd( '/usr/sbin/usermod', '-s', '/bin/bash', $NUSER ) if $NUSER;
    run_cmd( '/usr/sbin/usermod', '-s', $JAILSHELL,  $JUSER ) if $JUSER;
    return;
}

sub change_package {
    my ( $user, $pkg ) = @_;
    my $ok = whmapi( 'changepackage', "user=$user", "pkg=$pkg" );
    restore_shells();
    return $ok;
}

sub account_plan {
    my ($user) = @_;
    my ( $ok, $res ) = whmapi( 'accountsummary', "user=$user" );
    return $ok ? $res->{data}{acct}[0]{plan} : undef;
}

# Through the package manager, so dependencies resolve (the old build needs its
# compiler toolchain to run its %post compile). Downgrades when the file is older
# than what is installed.
sub install_package_file {
    my ($file) = @_;
    return run_cmd( 'apt-get', '-y', '--allow-downgrades', 'install', $file ) if pkg_tool() eq 'deb';

    my ( $rc, $out ) = run_cmd( 'dnf', '-y', 'install', $file );
    return ( $rc, $out ) if $rc == 0 && $out !~ /already installed/i;
    my ( $drc, $dout ) = run_cmd( 'dnf', '-y', 'downgrade', $file );
    return $drc == 0 ? ( $drc, $dout ) : ( $rc, "$out\n$dout" );
}

sub _in_path {
    my ($bin) = @_;
    for my $d ( split /:/, $ENV{PATH} || '' ) {
        return 1 if -x "$d/$bin";
    }
    return 0;
}

sub _sh {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

#---------------------------------------------------------------------
# preconditions
#---------------------------------------------------------------------
plan skip_all => "live test; set EAPODMAN_LIVE=1 to run" unless $ENV{EAPODMAN_LIVE};
plan skip_all => "must run as root"                 if $> != 0;
plan skip_all => "not a cPanel server (no $WHMAPI)" if !-x $WHMAPI;

{
    local $@;
    plan skip_all => "Cpanel::JSON unavailable" if !eval { require Cpanel::JSON; 1 };
    $json = sub { return Cpanel::JSON::Load( $_[0] ) };
}

plan skip_all => "podman is not installed"                                   if !_in_path('podman');
plan skip_all => "EAPODMAN_UPGRADE_FROM and EAPODMAN_UPGRADE_TO go together" if ( $UPGRADE_FROM xor $UPGRADE_TO );
if ($UPGRADE_FROM) {
    plan skip_all => "EAPODMAN_UPGRADE_FROM ($UPGRADE_FROM) not found" if !-e $UPGRADE_FROM;
    plan skip_all => "EAPODMAN_UPGRADE_TO ($UPGRADE_TO) not found"     if !-e $UPGRADE_TO;
}
else {
    plan skip_all => "installed ea-podman predates EA4-315 (no $MODULE); install the new build or pass EAPODMAN_UPGRADE_FROM/_TO" if !-e $MODULE;
}

#---------------------------------------------------------------------
# accounts
#---------------------------------------------------------------------
{
    my $err;
    ( $NUSER, $err ) = create_account('eapn');
    plan skip_all => "could not create the normal test account:\n$err" if !$NUSER;
    sleep 1;    # distinct time-based suffix
    ( $JUSER, $err ) = create_account('eapj');
    plan skip_all => "could not create the jailshell test account:\n$err" if !$JUSER;

    run_cmd( '/usr/sbin/usermod', '-s', '/bin/bash', $NUSER );
    run_cmd( '/usr/sbin/usermod', '-s', $JAILSHELL,  $JUSER );
    install_caller_script($_) for $NUSER, $JUSER;
    diag( "accounts: normal=$NUSER jailshell=$JUSER; image=$IMAGE port=$PORT; package tool: " . pkg_tool() );
}

#=====================================================================
# 7 (first, when asked for). upgrade in place from the old package
#=====================================================================
SKIP: {
    skip "EAPODMAN_UPGRADE_FROM/_TO not set", 1 if !$UPGRADE_FROM;

    subtest 'upgrade from the previous package, with a live container' => sub {
        my ( $rc, $out ) = install_package_file($UPGRADE_FROM);
        is( $rc, 0, "installed the old package ($UPGRADE_FROM)" ) or diag $out;

        ok( !-e $MODULE,  'old package: no admin module (sanity: this really is the old build)' );
        ok( is_elf($CLI), 'old package: bin/ea-podman is the compiled binary' );

        my $res = uapi( $NUSER, 'install', "name=$CBASE", "image=$IMAGE", "cpuser_port=$PORT", 'accept_arbitrary_image_risk=1' );
        ok( $res->{status}, 'old package: a container installs' ) or diag uapi_errors($res);
        my $container = $res->{data} && $res->{data}{container_name};
        $CONTAINERS{$container} = $NUSER if $container;
        ok( $container && wait_for( sub { container_running( $NUSER, $container ) }, 60 ), 'old package: it runs' );

        ( $rc, $out ) = install_package_file($UPGRADE_TO);
        is( $rc, 0, "upgraded to the new package ($UPGRADE_TO)" ) or diag $out;

        ok( -e $MODULE,                                        'new package: the admin module is installed' );
        ok( !is_elf($CLI) && first_line($CLI) =~ m{^#!.*perl}, 'new package: bin/ea-podman is now the perl script (the compiled one was replaced)' );
        ok( !-e $_,                                            "new package: $_ is gone" ) for @GONE;

        ok( container_running( $NUSER, $container ), 'the container kept running through the upgrade' );
        is( ( registry_entry($container) || {} )->{user}, $NUSER, 'and is still registered to its account' );

        my ( $hrc, $hooks ) = run_cmd( '/usr/local/cpanel/bin/manage_hooks', 'list' );
        unlike( $hooks, qr/_compile_podman/, 'no upcp compile hook is registered' );
      TODO: {
            local $TODO = 'pre-existing: the old %preun deletes PodmanHooks after the new %post re-adds them (not EA4-315)';
            like( $hooks, qr/PodmanHooks::_delete_user/, 'the account hooks are still registered after the upgrade' );
        }

        my $ens = admin_call( $NUSER, 'ENSURE_USER', [1] );
        ok( $ens->{ok}, 'an account that existed before the upgrade has the ea_podman feature afterwards (a create-type action works)' ) or diag explain $ens;

        # What an EA4 package's prerm, or a user cleaning up, does: the CLI,
        # uncompiled now, reaching the admin module to release ports/registry.
        ( $rc, $out ) = run_as_user( $NUSER, "$CLI remove_containers $CBASE" );
        is( $rc, 0, 'the uncompiled CLI removes the container after the upgrade' ) or diag $out;
        ok( wait_for( sub { !container_running( $NUSER, $container ) }, 30 ), 'it is gone' );
        ok( !registry_entry($container),                                      'and deregistered' );
        delete $CONTAINERS{$container} if $container;
    };
}

#=====================================================================
# 1. packaging
#=====================================================================
subtest 'packaging' => sub {
    ok( -e $MODULE, "admin module installed at $MODULE" );
    my ( $rc, $out ) = run_cmd( $PERL, '-I/usr/local/cpanel', '-c', $MODULE );
    is( $rc, 0, 'it compiles' ) or diag $out;
    like( owner_of($MODULE), qr/ea-podman/, 'owned by the ea-podman package' );

    ok( !-e $_, "$_ is gone" ) for @GONE;

    ok( -x $CLI,       "$CLI is executable" );
    ok( !is_elf($CLI), '... and is not a compiled binary' );
    like( first_line($CLI), qr{^#!/usr/local/cpanel/3rdparty/bin/perl}, '... it is the perl script' );
    like( owner_of($CLI),   qr/ea-podman/,                              '... owned by the package (not left over from a postinst compile)' );
    is( readlink($SCRIPTS_CLI) // '', $CLI, "$SCRIPTS_CLI still points at it" );

    ( $rc, $out ) = run_cmd( $SCRIPTS_CLI, 'testbin' );
    is( $rc, 0, '`ea-podman testbin` still succeeds for anything that calls it' ) or diag $out;

    my ( $drc, $deps ) = pkg_tool() eq 'deb' ? run_cmd( 'dpkg-query', '-W', '-f=${Depends}', 'ea-podman' ) : run_cmd( 'rpm', '-qR', 'ea-podman' );
    unlike( $deps, qr/\b(?:gcc|gcc-toolset-11|libnsl2)\b/, 'no compiler toolchain requirements' );

    my $feature_file = '/usr/local/cpanel/whostmgr/addonfeatures/ea_podman';
    like( first_line($feature_file), qr/^ea_podman:/, 'the ea_podman addon feature is registered' );

    my ( $hrc, $hooks ) = run_cmd( '/usr/local/cpanel/bin/manage_hooks', 'list' );
    unlike( $hooks, qr/_compile_podman/, 'no upcp compile hook' );
};

#=====================================================================
# 2. the caller check is really enforced, and ea_podman still accepts
#=====================================================================
subtest 'uncompiled callers, with the parent check enforced' => sub {

    # cpsrvd reads only this touch file, per request (cpanel.config's
    # skipparentcheck tweak just maintains it), so moving it aside is enough.
    if ( -e $SKIP_PARENT ) {
        ok( rename( $SKIP_PARENT, "$SKIP_PARENT.eap315-saved" ), "moved $SKIP_PARENT aside for the test (restored at the end)" );
        $MOVED_SKIP_PARENT = 1;
    }
    ok( !-e $SKIP_PARENT, 'the parent check is enforced' );

    my $control = admin_call( $NUSER, 'NO_SUCH_FUNCTION', [], module => 'user' );
    ok( !$control->{ok}, 'control: a default-parents core module refuses an uncompiled perl caller' );
    like( $control->{error} // '', qr/[Pp]arent|caller/, '... because of the parent check' ) or diag explain $control;

    my $res = admin_call( $NUSER, 'REGISTERED_CONTAINERS', [] );
    ok( $res->{ok}, 'ea_podman accepts the same uncompiled perl caller' ) or diag explain $res;
    is( ref $res->{data}, 'HASH', '... and returns a hashref' );

    $res = admin_call( $JUSER, 'REGISTERED_CONTAINERS', [], in_jail => 1 );
    ok( $res->{ok}, '... from inside a jail too' ) or diag explain $res;
};

#=====================================================================
# 3. the legacy call shapes and error text
#=====================================================================
subtest 'outside callers see the legacy actions unchanged' => sub {
    my $res = admin_call( $NUSER, 'LIST', [] );
    ok( $res->{ok},                                                                       'LIST' ) or diag explain $res;
    ok( defined $res->{data} && !ref $res->{data} && eval { $json->( $res->{data} ); 1 }, 'LIST returns a JSON string, as before' );

    $res = admin_call( $NUSER, 'ENSURE_USER', [0] );
    ok( $res->{ok}, 'ENSURE_USER(0)' ) or diag explain $res;
    like( $res->{data} // '', qr/^[01]$/, 'ENSURE_USER returns 0/1' );
    ok( !-e "/var/lib/systemd/linger/$NUSER", 'ENSURE_USER(0) does not linger an account with no containers' );

    $res = admin_call( $NUSER, 'RELEASE_USER', [] );
    ok( $res->{ok}, 'RELEASE_USER' ) or diag explain $res;

    $res = admin_call( $NUSER, 'REVOKE_API_TOKEN', ['not_ours'] );
    ok( $res->{ok} && !$res->{data}, 'REVOKE_API_TOKEN ignores a name that is not ours' ) or diag explain $res;

    $res = admin_call( $NUSER, 'GIVE', [ 1, 'not a container name' ] );
    ok( !$res->{ok}, 'GIVE with a bad container name fails' );
    like( $res->{error} // '', qr/Invalid container name/, '... with the same message as before, not a bare error ID' );

    $res = admin_call( $NUSER, 'DEREGISTER', ["$CBASE.$NUSER.99"] );
    like( $res->{error} // '', qr/No such container for this account/, 'DEREGISTER of an unregistered container: the same message as before' );

    $res = admin_call( $NUSER, 'REGISTER', ["$CBASE.$JUSER.01"] );
    like( $res->{error} // '', qr/does not belong to this account/, 'REGISTER of a name for another account: the same message as before' );

    $res = admin_call( $NUSER, 'NO_SUCH_ACTION', [] );
    ok( !$res->{ok}, 'an unknown action is refused' );
};

#=====================================================================
# 4. lifecycle actions from inside a jail
#=====================================================================
my ( $jcontainer, $ncontainer );
subtest 'lifecycle actions, from inside a real jail' => sub {
    my ( $rc, $out ) = run_login( $JUSER, 'cat /etc/subuid' );
    isnt( $rc, 0, 'the jail is real: the login shell cannot read /etc/subuid' );

    # A container for the OTHER account, through the (unchanged) UAPI.
    my $nres = uapi( $NUSER, 'install', "name=$CBASE", "image=$IMAGE", "cpuser_port=$PORT", 'accept_arbitrary_image_risk=1' );
    ok( $nres->{status}, 'the EAPodman UAPI still installs a container (other account)' ) or diag uapi_errors($nres);
    $ncontainer = $nres->{data} && $nres->{data}{container_name};
    $CONTAINERS{$ncontainer} = $NUSER if $ncontainer;

    my $log_at = cpwrapd_log_size();

    my $res = admin_call( $JUSER, 'INSTALL', [ { name => $CBASE, image => $IMAGE, cpuser_port => [$PORT], accept_arbitrary_image_risk => 1 } ], in_jail => 1 );
    ok( $res->{ok}, 'INSTALL' ) or diag explain $res;
    $jcontainer = $res->{ok} && $res->{data}{container_name};
    like( $jcontainer // '', qr/^\Q$CBASE\E\.\Q$JUSER\E\.[0-9][0-9]$/, "returns the container name ($jcontainer)" );
    return if !$jcontainer;
    $CONTAINERS{$jcontainer} = $JUSER;

    ok( wait_for( sub { container_running( $JUSER, $jcontainer ) }, 60 ), 'the container runs' );
    my ( $ip, $hport );
    ok(
        wait_for( sub { ( $ip, $hport ) = published_host_endpoint( $JUSER, $jcontainer ); $ip && redis_ping_over_tcp( $ip, $hport ) }, 45 ),
        "redis answers PING on the published port (" . ( $hport // '?' ) . ")"
    ) if $IMAGE =~ /redis/i;
    is( ( registry_entry($jcontainer) || {} )->{user}, $JUSER, 'registered to the account' );

    $res = admin_call( $JUSER, 'LIST_CONTAINERS', [], in_jail => 1 );
    ok( $res->{ok} && exists $res->{data}{$jcontainer}, 'LIST_CONTAINERS shows it' ) or diag explain $res;
    ok( !exists $res->{data}{ $ncontainer // '' },      "... and not the other account's" );

    $res = admin_call( $JUSER, 'STATUS', [ { container_name => $jcontainer } ], in_jail => 1 );
    ok( $res->{ok} && $res->{data}{running}, 'STATUS: running' ) or diag explain $res;

    $res = admin_call( $JUSER, 'CMD', [ { container_name => $jcontainer, arg => ['date'] } ], in_jail => 1 );
    ok( $res->{ok} && ( $res->{data}{exit_code} // -1 ) == 0 && ( $res->{data}{stdout} // '' ) =~ /\d{4}/, 'CMD date' ) or diag explain $res;

    $res = admin_call( $JUSER, 'CMD', [ { container_name => $jcontainer, arg => ['false'] } ], in_jail => 1 );
    is( $res->{data}{exit_code}, 1, "CMD surfaces the command's own exit code" );

    $res = admin_call( $JUSER, 'STOP', [ { container_name => $jcontainer } ], in_jail => 1 );
    ok( $res->{ok},                                                        'STOP' ) or diag explain $res;
    ok( wait_for( sub { !container_running( $JUSER, $jcontainer ) }, 30 ), '... stopped' );

    $res = admin_call( $JUSER, 'START', [ { container_name => $jcontainer } ], in_jail => 1 );
    ok( $res->{ok},                                                       'START' ) or diag explain $res;
    ok( wait_for( sub { container_running( $JUSER, $jcontainer ) }, 30 ), '... running' );

    $res = admin_call( $JUSER, 'RESTART', [ { container_name => $jcontainer } ], in_jail => 1 );
    ok( $res->{ok},                                                       'RESTART' ) or diag explain $res;
    ok( wait_for( sub { container_running( $JUSER, $jcontainer ) }, 30 ), '... running' );

    $res = admin_call( $JUSER, 'UPGRADE', [ { container_name => $jcontainer } ], in_jail => 1 );
    ok( $res->{ok},                                                       'UPGRADE' ) or diag explain $res;
    ok( wait_for( sub { container_running( $JUSER, $jcontainer ) }, 60 ), '... running' );

    # Another account's container, by its real name.
    if ($ncontainer) {
        for my $action (qw(UNINSTALL CMD STOP STATUS UPGRADE)) {
            $res = admin_call( $JUSER, $action, [ { container_name => $ncontainer, arg => ['true'] } ], in_jail => 1 );
            like( $res->{error} // '', qr/No such container for this account/, "$action on the other account's container is refused" );
        }
        $res = admin_call( $JUSER, 'EXEC_IN_CONTAINER', [ $ncontainer, '', 'true' ], in_jail => 1 );
        like( $res->{error} // '', qr/No such container for this account/, "EXEC_IN_CONTAINER on it is refused" );
        $res = admin_call( $JUSER, 'DEREGISTER', [$ncontainer], in_jail => 1 );
        like( $res->{error} // '', qr/No such container for this account/, "DEREGISTER of it is refused" );
        ok( container_running( $NUSER, $ncontainer ) && registry_entry($ncontainer), '... and it is untouched' );
    }

    # The CLI, in the jail, reaching the same actions.
    ( $rc, $out ) = run_login( $JUSER, "$CLI list" );
    like( $out, qr/\Q$jcontainer\E/, 'the in-jail CLI lists it' ) or diag $out;
    ( $rc, $out ) = run_login( $JUSER, "$CLI status $jcontainer" );
    like( $out, qr/"running"\s*:\s*1/, 'the in-jail CLI shows its status, in the same format as before' ) or diag $out;

    my @functions = functions_in( cpwrapd_log_since( $log_at, $JUSER ) );
    ok( scalar( grep { $_ eq 'INSTALL' } @functions ),         'cpwrapd_log shows the INSTALL action' ) or diag "@functions";
    ok( scalar( grep { $_ eq 'LIST_CONTAINERS' } @functions ), '... and the CLI going through LIST_CONTAINERS' );
    ok( !grep( { $_ eq 'MINT_API_TOKEN' } @functions ),        '... and no API token minted, by either' );

    my ( $trc, $tres ) = run_json( $UAPI, "--user=$JUSER", '--output=json', 'Tokens', 'list' );
    my @tokens = map { $_->{name} // '' } @{ ( $tres && $tres->{result}{data} ) || [] };
    ok( !grep( { /^ea_podman_cli_/ } @tokens ), 'no ea_podman_cli_ token exists for the account' );

    $res = admin_call( $JUSER, 'UNINSTALL', [ { container_name => $jcontainer } ], in_jail => 1 );
    ok( $res->{ok},                                                        'UNINSTALL' ) or diag explain $res;
    ok( wait_for( sub { !container_running( $JUSER, $jcontainer ) }, 30 ), '... the container is gone' );
    ok( !registry_entry($jcontainer),                                      '... deregistered' );
    ok( !grep( { $_ eq $jcontainer } port_authority_services($JUSER) ),    '... and its ports released' );
    ok( wait_for( sub { !-e "/var/lib/systemd/linger/$JUSER" }, 15 ),      '... and the linger ea-podman granted, released with the last container' );
    delete $CONTAINERS{$jcontainer};
};

#=====================================================================
# 5. the ea_podman feature
#=====================================================================
subtest 'the ea_podman feature' => sub {
    plan skip_all => 'needs the other account\'s container from the lifecycle subtest' if !$ncontainer;

    $ORIG_PLAN{$_} = account_plan($_) // 'default' for $NUSER, $JUSER;

    # A feature list an administrator saved before ea_podman existed: it does
    # not mention the feature at all, which must leave it on. Written by hand
    # because create_featurelist (like WHM's Feature Manager) writes every
    # feature it knows about, recording the ones not ticked as =0 -- so a list
    # created now would say ea_podman=0, which is not what an old list says.
    my $legacy_file = "/var/cpanel/features/$LEGACY_LIST";
    ok( open( my $lfh, '>', $legacy_file ), "wrote feature list $LEGACY_LIST, which predates (does not mention) ea_podman" );
    print {$lfh} "webdisk=0\n";
    close $lfh;
    $MADE_FEATURELIST{$LEGACY_LIST} = 1;
    ok( whmapi( 'addpkg', "name=$LEGACY_PKG", "featurelist=$LEGACY_LIST", 'hasshell=1' ), "created package $LEGACY_PKG using it" );
    $MADE_PACKAGE{$LEGACY_PKG} = 1;
    ok( change_package( $NUSER, $LEGACY_PKG ), "moved $NUSER onto it" );
    my $ens = admin_call( $NUSER, 'ENSURE_USER', [1] );
    ok( $ens->{ok}, '... and a create-type action is still allowed' ) or diag explain $ens;

    ok( whmapi( 'create_featurelist', "featurelist=$FEATURELIST", 'ea_podman=0' ), "created feature list $FEATURELIST with ea_podman off" );
    $MADE_FEATURELIST{$FEATURELIST} = 1;
    ok( whmapi( 'addpkg', "name=$PACKAGE", "featurelist=$FEATURELIST", 'hasshell=1' ), "created package $PACKAGE using it" );
    $MADE_PACKAGE{$PACKAGE} = 1;

    for my $user ( $NUSER, $JUSER ) {
        ok( change_package( $user, $PACKAGE ), "moved $user onto it" );
    }

    $ens = admin_call( $NUSER, 'ENSURE_USER', [1] );
    like( $ens->{error} // '', qr/must enable/i, 'ENSURE_USER(1) is refused with the feature message' );
    $ens = admin_call( $NUSER, 'ENSURE_USER', [0] );
    ok( $ens->{ok}, 'ENSURE_USER(0), which every verb runs, still works' ) or diag explain $ens;

    my $cmd = admin_call( $NUSER, 'EXEC_IN_CONTAINER', [ $ncontainer, '', 'true' ] );
    like( $cmd->{error} // '', qr/must enable/i, 'running a command in the container is refused' );

    my $res = uapi( $NUSER, 'install', "name=${CBASE}x", "image=$IMAGE", "cpuser_port=$PORT", 'accept_arbitrary_image_risk=1' );
    ok( !$res->{status}, 'UAPI install is refused' );
    like( uapi_errors($res), qr/must enable/i, '... with the feature message' );

    $res = admin_call( $NUSER, 'INSTALL', [ { name => "${CBASE}x", image => $IMAGE, accept_arbitrary_image_risk => 1 } ] );
    like( $res->{error} // '', qr/must enable/i, 'the INSTALL action is refused with the feature message' );

    my ( $rc, $out ) = run_login( $JUSER, "$CLI install ${CBASE}x --i-understand-the-risks-do-it-anyway $IMAGE" );
    isnt( $rc, 0, 'the in-jail CLI install is refused' );
    like( $out, qr/must enable/i, '... with the feature message' ) or diag $out;

    $res = uapi( $NUSER, 'list' );
    ok( $res->{status} && exists $res->{data}{$ncontainer}, 'listing still works without the feature' );

    $res = uapi( $NUSER, 'uninstall', "container_name=$ncontainer" );
    ok( $res->{status},                                                    'uninstall still works without the feature (the cleanup carve-out)' ) or diag uapi_errors($res);
    ok( wait_for( sub { !container_running( $NUSER, $ncontainer ) }, 30 ), '... the container is gone' );
    ok( !registry_entry($ncontainer),                                      '... deregistered' );
    ok( !grep( { $_ eq $ncontainer } port_authority_services($NUSER) ),    '... ports released' );
    delete $CONTAINERS{$ncontainer};

    for my $user ( $NUSER, $JUSER ) {
        ok( change_package( $user, $ORIG_PLAN{$user} ), "moved $user back to $ORIG_PLAN{$user}" );
        delete $ORIG_PLAN{$user};
    }
};

#=====================================================================
# 6. demo mode
#=====================================================================
subtest 'demo accounts' => sub {
    ok( set_demo( $NUSER, 1 ), "put $NUSER in demo mode" );

    for my $action (qw(REGISTERED_CONTAINERS LIST_CONTAINERS ENSURE_USER)) {
        my $res = admin_call( $NUSER, $action, [] );
        ok( !$res->{ok}, "$action is refused to a demo account" );
        like( ( $res->{class} // '' ) . ' ' . ( $res->{error} // '' ), qr/demo/i, '... as demo mode' ) or diag explain $res;
    }

    ok( set_demo( $NUSER, 0 ), "took $NUSER out of demo mode" );
    my $res = admin_call( $NUSER, 'REGISTERED_CONTAINERS', [] );
    ok( $res->{ok}, 'and it is allowed again' ) or diag explain $res;
};

done_testing();

#---------------------------------------------------------------------
# teardown
#---------------------------------------------------------------------
END {
    my $status = $?;

    if ($KEEP) {
        diag("EAPODMAN_KEEP set: leaving accounts $NUSER/$JUSER, containers, and settings in place") if $NUSER;
        $? = $status;
        return;
    }

    # Always put back what changes the server as a whole.
    rename( "$SKIP_PARENT.eap315-saved", $SKIP_PARENT ) if $MOVED_SKIP_PARENT;
    set_demo( $_, 0 ) for keys %DEMO_SET;
    whmapi( 'changepackage', "user=$_", "pkg=$ORIG_PLAN{$_}" ) for keys %ORIG_PLAN;

    for my $container ( keys %CONTAINERS ) {
        run_cmd( $UAPI, "--user=$CONTAINERS{$container}", '--output=json', 'EAPodman', 'uninstall', "container_name=$container" );
    }

    for my $user ( grep { defined } $NUSER, $JUSER ) {
        run_cmd( 'loginctl', 'disable-linger', $user );
        whmapi( 'removeacct', "user=$user", 'keepdns=0' );
    }

    whmapi( 'killpkg',            "pkgname=$_" )     for keys %MADE_PACKAGE;
    whmapi( 'delete_featurelist', "featurelist=$_" ) for keys %MADE_FEATURELIST;

    $? = $status;
}
