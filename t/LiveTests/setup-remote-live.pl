#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/LiveTests/setup-remote-live.pl        Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# Prepare a disposable cPanel VM to run the ea-podman and webapp-plugin live
# tests, and say plainly whether it is ready.
#
#     scp t/LiveTests/setup-remote-live.pl root@VM:/root/
#     ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl'
#
# Self-contained on purpose: no repo checkout, no CPAN, core modules only. It
# runs before anything else is known to work, so it must not need anything.
#
# WHAT THIS IS ACTUALLY FOR
#
# Not installing Perl modules. Every module the live tests use is either Perl
# core or shipped with cPanel -- that is a deliberate constraint on those tests,
# and this script verifies it rather than assuming it. If that ever stops being
# true, the module check below names the missing one instead of letting a test
# die with a bare "Can't locate".
#
# The real hazard is subtler and has bitten this work twice:
#
#   YOU CAN EASILY TEST CODE YOU DID NOT MEAN TO TEST.
#
#   * before EA4-315, ea-podman's CLI is a COMPILED BINARY that EMBEDS util.pm.
#     Copying the library alone changes nothing -- the binary keeps running the
#     old code. compile.sh has to run. From EA4-315 the CLI is the perl script
#     and there is nothing to compile.
#   * the webapp plugin's modules are symlinks into the repo on a development
#     box (`make setup-backend`) but REAL FILES from the package on a VM. Rsync
#     the repo over and the installed modules do not move, so the tests exercise
#     the packaged version while you read the diff of your working tree.
#
# Both failures are silent: the tests pass, and they are telling you about code
# you are not looking at. --deploy exists for that, and the report always states
# which copy is under test.
#
# USAGE
#
#     setup-remote-live.pl [options]
#
#     --ea-podman=PATH   the rsynced ea-podman repo    (default /root/ea-podman)
#     --plugin=PATH      the rsynced plugins repo      (default /usr/local/cpanel/plugins)
#     --deploy           overlay those working trees onto the installed copies,
#                        backing up whatever is replaced, and recompile the
#                        ea-podman CLI if it is a compiled one. WITHOUT THIS the tests exercise the
#                        INSTALLED packages, which is a legitimate thing to want
#                        -- just not the same thing.
#     --image=REF        image to pre-pull (default docker.io/library/httpd:2.4)
#     --no-pull          skip the pre-pull entirely
#     --check-clean      a DIFFERENT mode, for use BETWEEN suites: report any
#                        leftover throwaway accounts or registered containers and
#                        exit. The two live suites are mutually destructive --
#                        ea4-325-upgrade-live.t runs `remove_containers --all` as
#                        ROOT, reaching every account on the box -- so they must
#                        never overlap, and leftovers from an interrupted run
#                        make the NEXT run fail for reasons that look like
#                        defects. Exits 1 when the box is dirty.
#
# Exits 0 when the box is ready, 1 when something fatal is missing. Advisory
# findings never fail the run; they are printed as WARN.
#
# LEAVES BEHIND: a backup directory under /root/ when --deploy replaces files
# (named in the output), and the pulled image. Nothing else.

use strict;
use warnings;

use File::Path     ();
use File::Copy     ();
use File::Basename ();
use Getopt::Long   ();

my $ULC      = '/usr/local/cpanel';
my $PERL     = "$ULC/3rdparty/bin/perl";
my $EAP_ROOT = '/opt/cpanel/ea-podman';

my %opt = (
    'ea-podman' => '/root/ea-podman',
    'plugin'    => "$ULC/plugins",
    'image'     => 'docker.io/library/httpd:2.4',
);
Getopt::Long::GetOptions( \%opt, 'ea-podman=s', 'plugin=s', 'deploy', 'image=s', 'no-pull', 'check-clean' )
  or die "Could not parse options.\n";

my @FATAL;
my @WARN;
my @NOTE;

sub say_hdr { print "\n=== $_[0] ===\n" }
sub ok      { printf "  [ ok ]  %s\n", $_[0] }
sub warn_   { printf "  [WARN]  %s\n", $_[0]; push @WARN,  $_[0] }
sub fatal   { printf "  [FAIL]  %s\n", $_[0]; push @FATAL, $_[0] }
sub note    { printf "          %s\n", $_[0] }

# Run a command and give back (exit, combined output). No shell, so nothing here
# needs quoting.
sub run {
    my (@cmd) = @_;
    my $pid = open( my $fh, '-|' );
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        open( STDERR, '>&', \*STDOUT );
        exec { $cmd[0] } @cmd or exit 127;
    }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return ( $? >> 8, $out );
}

sub first_line {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\n.*//s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub in_path {
    my ($bin) = @_;
    for my $d ( split /:/, ( $ENV{PATH} || '' ) ) {
        return "$d/$bin" if -x "$d/$bin";
    }
    return;
}

#---------------------------------------------------------------------
# 0. the things everything else assumes
#---------------------------------------------------------------------

# --check-clean: is it safe to start the next suite?
#
# Its own mode because it is run BETWEEN suites, not before them. The two live
# suites are mutually destructive -- ea4-325-upgrade-live.t runs
# `remove_containers --all` as ROOT, which reaches every account on the box --
# so they must never overlap, and an interrupted run leaves state that makes the
# NEXT run fail for reasons that look like defects. That has already happened:
# a leftover account from unrelated manual testing failed two subtests that had
# nothing to do with it.
if ( $opt{'check-clean'} ) {
    if ( $> != 0 ) {
        print "This must run as root (it reads /var/cpanel/users).\n";
        exit 1;
    }

    say_hdr('Leftover state');

    my $dirty = 0;

    # Throwaway accounts: eap/cln/aa from the ea-podman suite, wap/wpf from the
    # plugin's. `aa*` is the interesting one -- A3 deletes it with `userdel -f`,
    # which leaves /var/cpanel/users/<name> behind for root's `clean` to
    # enumerate on every later run.
    my @ghosts;
    if ( opendir( my $dh, '/var/cpanel/users' ) ) {
        @ghosts = sort grep { m/\A(?:eap|cln|aa|wap|wpf)\d+\z/ } readdir $dh;
        closedir $dh;
    }
    if (@ghosts) {
        warn_( 'leftover test accounts: ' . join( ', ', @ghosts ) );
        note('Remove with: whmapi1 removeacct username=<name>');
        note('or, for one userdel -f left behind: rm -f /var/cpanel/users/<name>');
        $dirty++;
    }
    else {
        ok('no leftover test accounts');
    }

    my $cli = in_path('ea-podman') || "$EAP_ROOT/bin/ea-podman";
    if ( -x $cli ) {
        my ( $rc, $out ) = run( $cli, 'containers' );

        # Count REGISTRY ENTRIES, not output lines. `ea-podman containers` emits
        # a multi-line hidepid advisory before its JSON on a stock box, and
        # counting lines reported thirteen phantom containers against an empty
        # registry -- sending the reader to clean up nothing.
        my $json = $out // '';
        $json =~ s/\A.*?(?=^\{)//sm;    # drop everything before the first line starting with {
        my $registry = eval { require Cpanel::JSON; Cpanel::JSON::Load($json) };
        my $count = ref $registry eq 'HASH' ? scalar keys %{$registry} : 0;

        if ( $rc == 0 && $count ) {
            warn_( "$count registered container(s) still present" );
            note('A suite that reaches every account will destroy these.');
            note('Clear with: ea-podman remove_containers --all   (SERVER-WIDE)');
            $dirty++;
        }
        else {
            ok('no registered ea-podman containers');
        }
    }

    print "\n";
    print $dirty ? "  DIRTY -- clear the above before the next suite.\n\n" : "  CLEAN -- safe to start the next suite.\n\n";
    exit( $dirty ? 1 : 0 );
}

say_hdr('Basics');

if ( $> != 0 ) {
    print "This must run as root.\n";
    exit 1;
}
ok('running as root');

if ( !-x $PERL ) {
    print "No cPanel perl at $PERL -- is this a cPanel server?\n";
    exit 1;
}
ok("cPanel perl present ($PERL)");

for my $bin ( "$ULC/bin/whmapi1", "$ULC/bin/uapi" ) {
    -x $bin ? ok("$bin") : fatal("missing $bin");
}

{
    my ( $rc, $out ) = run( "$ULC/cpanel", '-V' );
    $rc == 0 ? ok( 'cPanel version: ' . first_line($out) ) : warn_('could not read the cPanel version');
}

# The live tests create throwaway accounts with whmapi1 createacct, which is the
# first thing an invalid licence stops. Checking now turns a confusing mid-run
# failure into one line here.
{
    my ( $rc, $out ) = run( "$ULC/bin/whmapi1", 'version', '--output=json' );
    if ( $rc == 0 && $out =~ m/"result"\s*:\s*"?1/ ) {
        ok('whmapi1 answers, so account creation should work');
    }
    else {
        fatal('whmapi1 is not answering -- the live tests cannot create their throwaway accounts');
        note( first_line($out) ) if length first_line($out);
        note('An expired or missing licence is the usual cause.');
    }
}

#---------------------------------------------------------------------
# 1. perl modules the live tests use
#---------------------------------------------------------------------

say_hdr('Perl modules');

# Every one of these should already be present: the live tests are written to
# core plus what cPanel ships, precisely so a bare VM needs no preparation. This
# checks that contract rather than trusting it.
my @CORE_MODS = qw(
  Data::Dumper File::Path Fcntl IO::Select IO::Socket::INET IO::Socket::UNIX
  IPC::Open3 Socket Symbol Test::More Time::HiRes
);
my @CPANEL_MODS = qw(
  Cpanel::JSON Cpanel::AccessIds Cpanel::PwCache Cpanel::Config::Users
);

# The UNIT suites are a different matter, and this caught me out: they DO need
# CPAN. A cPanel DEVELOPMENT build ships Test::Spec in cpanel-lib, so a dev
# sandbox runs `prove -l t/` green and tells you nothing about a release box,
# where those four test files die at BEGIN. Advisory only -- the live tests do
# not need any of it.
my @UNIT_MODS = qw( Test::Spec Test::Mock::Cmd Test::MockModule Test::MockFile );

my @missing;
for my $mod ( @CORE_MODS, @CPANEL_MODS ) {
    my ( $rc, undef ) = run( $PERL, "-I$ULC", "-M$mod", '-e1' );
    push @missing, $mod if $rc != 0;
}

if (@missing) {
    fatal( 'missing Perl modules: ' . join( ', ', @missing ) );
    note('These are core or cPanel-shipped, so a gap here means a broken');
    note('install rather than something this script should install.');
}
else {
    ok( scalar(@CORE_MODS) + scalar(@CPANEL_MODS) . ' modules present (core + cPanel) -- the live tests need nothing else' );
}

{
    my @unit_missing;
    for my $mod (@UNIT_MODS) {
        my ( $rc, undef ) = run( $PERL, "-I$ULC", '-e', "require $mod" );
        push @unit_missing, $mod if $rc != 0;
    }

    if (@unit_missing) {
        warn_( 'unit-test modules missing: ' . join( ', ', @unit_missing ) );
        note('The LIVE tests are unaffected. `prove -l t/` in the ea-podman repo');
        note('will fail at BEGIN for the files that use them. Install with:');
        note( '  /usr/local/cpanel/3rdparty/perl/542/bin/cpanm --notest ' . join( ' ', @unit_missing ) );
    }
    else {
        ok( scalar(@UNIT_MODS) . ' unit-test modules present (`prove -l t/` will run)' );
    }
}

#---------------------------------------------------------------------
# 2. podman and the kernel side
#---------------------------------------------------------------------

say_hdr('podman');

if ( my $podman = in_path('podman') ) {
    my ( $rc, $out ) = run( $podman, '--version' );
    ok( first_line($out) || 'podman present' );
}
else {
    fatal('podman is not installed -- every container subtest needs it');
    note('dnf install -y podman   (or apt-get install -y podman)');
}

{
    my $v2 = -e '/sys/fs/cgroup/cgroup.controllers' ? 1 : 0;
    ok( 'cgroup ' . ( $v2 ? 'v2' : 'v1' ) );

    # Not a defect, but it changes what the memory-cap paths can do, and on
    # CloudLinux the combination with LVE is known to break systemd --user.
    note('On CloudLinux, cgroup v2 + LVE breaks the rootless user manager.') if $v2;
}

#---------------------------------------------------------------------
# 3. ea-podman
#---------------------------------------------------------------------

say_hdr('ea-podman');

my $EAP_LIB = "$EAP_ROOT/lib/ea_podman/util.pm";
my $EAP_CLI = in_path('ea-podman') || "$EAP_ROOT/bin/ea-podman";

-e $EAP_LIB ? ok("library: $EAP_LIB") : fatal("ea-podman library missing ($EAP_LIB)");
-x $EAP_CLI ? ok("CLI: $EAP_CLI")     : fatal("ea-podman CLI missing ($EAP_CLI)");

my $PORTAUTH = "$ULC/scripts/cpuser_port_authority";
-x $PORTAUTH ? ok('cpuser_port_authority present') : fatal("missing $PORTAUTH");

# Advisory: two subtests skip without it.
if ( -d '/opt/cpanel/ea-memcached16' ) {
    ok('ea-memcached16 installed (packaged-container subtests can run)');
}
else {
    warn_('ea-memcached16 is not installed; the packaged-container subtests will skip');
    note('dnf install -y ea-memcached16   -- optional');
}

#---------------------------------------------------------------------
# 4. the webapp plugin
#---------------------------------------------------------------------

say_hdr('webapp plugin');

my @PLUGIN_MODS = qw(
  Cpanel::WebApps::Podman Cpanel::WebApps::Cleanup
  Cpanel::WebApps::Source Cpanel::WebApps::Registry
);
my @missing_plugin;
for my $mod (@PLUGIN_MODS) {
    my ( $rc, undef ) = run( $PERL, "-I$ULC", "-M$mod", '-e1' );
    push @missing_plugin, $mod if $rc != 0;
}

if (@missing_plugin) {
    warn_( 'plugin modules not loadable: ' . join( ', ', @missing_plugin ) );
    note('The webapp live tests will skip. Fine if you only want the ea-podman ones.');
}
else {
    ok( scalar(@PLUGIN_MODS) . ' plugin modules loadable' );
}

# Which copy is actually under test. This is the question the whole script
# exists to answer, so it is stated outright rather than implied.
{
    my $probe = "$ULC/Cpanel/WebApps/Cleanup.pm";
    if ( -l $probe ) {
        note( 'plugin modules are SYMLINKS -> ' . ( readlink($probe) // '?' ) );
        note('so the repo they point at is what the tests will exercise.');
    }
    elsif ( -e $probe ) {
        note('plugin modules are REAL FILES from the package.');
        note('A working tree elsewhere is NOT under test unless you pass --deploy.');
    }
}

#---------------------------------------------------------------------
# 5. optionally put the working trees under test
#---------------------------------------------------------------------

my $BACKUP = "/root/live-setup-backup-" . time();

sub is_elf {
    my ($path) = @_;
    open( my $fh, '<', $path ) or return 0;
    read( $fh, my $magic, 4 );
    return ( $magic // '' ) eq "\x7fELF" ? 1 : 0;
}

sub backup_and_copy {
    my ( $src, $dst ) = @_;

    if ( -e $dst && !-l $dst ) {
        my $keep = $BACKUP . $dst;
        File::Path::make_path( File::Basename::dirname($keep) );
        File::Copy::copy( $dst, $keep ) or warn_("could not back up $dst: $!");
    }

    File::Path::make_path( File::Basename::dirname($dst) );

    # A symlinked destination means this is a DEVELOPMENT box wired up by
    # `make setup-backend`, where the repo is already what runs. Replacing the
    # link with a copy would both make --deploy pointless and quietly break that
    # wiring -- every later edit to the repo would stop taking effect, with no
    # error to explain why. Leave it alone and say so.
    if ( -l $dst ) {
        my $target = readlink($dst) // '';
        if ( $target eq $src ) {
            ok("already linked to $src; left as a link");
        }
        else {
            warn_("$dst is a symlink to $target, not to $src -- left alone");
            note('Replacing it would break `make setup-backend` linkage.');
        }
        return 0;
    }

    if ( File::Copy::copy( $src, $dst ) ) {
        ok("deployed $dst");
        return 1;
    }
    warn_("could not deploy $dst: $!");
    return 0;
}

if ( $opt{deploy} ) {
    say_hdr('Deploying working trees');
    note("backups under $BACKUP");

    # -- ea-podman ---------------------------------------------------
    my $ea = $opt{'ea-podman'};
    if ( -d $ea ) {

        # SOURCES/lib/ea_podman/util.pm is a symlink to ../../util.pm, so the
        # real file is the one to copy.
        backup_and_copy( "$ea/SOURCES/util.pm",      $EAP_LIB )                     if -e "$ea/SOURCES/util.pm";
        backup_and_copy( "$ea/SOURCES/ea-podman.pl", "$EAP_ROOT/bin/ea-podman.pl" ) if -e "$ea/SOURCES/ea-podman.pl";

        # The UAPI module, which is NOT under /opt/cpanel/ea-podman and so is
        # easy to leave behind. Several subtests drive `uapi EAPodman ...`
        # directly, and the webapp plugin reaches ea-podman through it -- deploy
        # the library without this and the UAPI paths still run packaged code.
        backup_and_copy( "$ea/SOURCES/Cpanel-API-EAPodman.pm", "$ULC/Cpanel/API/EAPodman.pm" )
          if -e "$ea/SOURCES/Cpanel-API-EAPodman.pm";

        # The jailshell/CageFS CLI path lands in the ea_podman admin module
        # (EA4-315), which is also outside /opt/cpanel/ea-podman.
        backup_and_copy( "$ea/SOURCES/Cpanel-Admin-Modules-Cpanel-ea_podman.pm", "$ULC/Cpanel/Admin/Modules/Cpanel/ea_podman.pm" )
          if -e "$ea/SOURCES/Cpanel-Admin-Modules-Cpanel-ea_podman.pm" && -e "$ULC/Cpanel/Admin/Modules/Cpanel/ea_podman.pm";

        # THE STEP EVERYONE FORGETS, and it runs even when the copies above were
        # skipped. Before EA4-315 the CLI is COMPILED and embeds util.pm at
        # compile time, so a util.pm that is already a symlink into the repo
        # still leaves the binary running whatever was embedded when the package
        # was built. Nothing about the file on disk changes that; only
        # recompiling does. From EA4-315 bin/ea-podman is the perl script
        # itself, reading util.pm from lib/, so it is copied like the rest.
        my $cli = "$EAP_ROOT/bin/ea-podman";
        if ( is_elf($cli) ) {
            if ( -x "$EAP_ROOT/bin/compile.sh" ) {
                my ( $rc, $out ) = run("$EAP_ROOT/bin/compile.sh");
                $rc == 0 ? ok('recompiled the ea-podman CLI') : fatal("compile.sh failed (exit $rc)");
                note( first_line($out) ) if $rc != 0;
            }
            else {
                fatal("$cli is compiled but there is no compile.sh at $EAP_ROOT/bin -- the CLI will keep running the packaged code");
            }
        }
        else {
            backup_and_copy( "$ea/SOURCES/ea-podman.pl", $cli ) if -e "$ea/SOURCES/ea-podman.pl";
        }
    }
    else {
        warn_("no ea-podman repo at $ea; skipping (pass --ea-podman=PATH)");
    }

    # -- webapp plugin -----------------------------------------------
    my $pl_root = $opt{plugin} . '/cpanel/webapp/perl/usr/local/cpanel';
    if ( -d $pl_root ) {
        my @files;
        my $walk;
        $walk = sub {
            my ($dir) = @_;
            opendir( my $dh, $dir ) or return;
            for my $e ( sort grep { $_ ne '.' && $_ ne '..' } readdir $dh ) {
                my $p = "$dir/$e";

                # Tests stay in the repo and are run from there; copying a whole
                # t/ tree into cPanel's own t/ is noise nobody asked for.
                next if -d $p && $e eq 't';
                if   ( -d $p ) { $walk->($p) }
                else           { push @files, $p if $p =~ m/\.(pm|pl|yaml|json|conf)\z/ }
            }
            closedir $dh;
        };
        $walk->($pl_root);

        for my $src (@files) {
            my $rel = substr( $src, length($pl_root) );
            backup_and_copy( $src, "$ULC$rel" );
        }
        note( scalar(@files) . ' plugin files considered' );
    }
    else {
        warn_("no plugin tree at $pl_root; skipping (pass --plugin=PATH)");
    }
}
else {
    say_hdr('Deploy');
    note('--deploy not given: the INSTALLED ea-podman and plugin are under test.');
    note('That is a real thing to want. Pass --deploy to test the rsynced working trees.');
}

#---------------------------------------------------------------------
# 6. pre-pull, so a rate limit surfaces here and not mid-suite
#---------------------------------------------------------------------

say_hdr('Test image');

if ( $opt{'no-pull'} ) {
    note('--no-pull given; skipping');
}
elsif ( in_path('podman') ) {
    my ( $rc, $out ) = run( 'podman', 'pull', $opt{image} );
    if ( $rc == 0 ) {
        ok("pulled $opt{image}");
    }
    elsif ( $out =~ m/toomanyrequests|rate limit/i ) {

        # The failure mode this causes is genuinely confusing: forced upgrades
        # keep working from cache while conditional ones abort, so it reads like
        # a bug in the safe-mode gate rather than an environmental limit.
        fatal("the registry is rate limiting this host, so the suite cannot pull $opt{image}");
        note('Docker Hub meters manifest requests per IP for anonymous pulls.');
        note('Wait for the window to clear, or use a locally-present image:');
        note('  EAPODMAN_TEST_IMAGE=<local-ref>  /  WEBAPP_TEST_IMAGE=<local-ref>');
    }
    else {
        fatal("could not pull $opt{image}");
        note( first_line($out) );
    }
}

#---------------------------------------------------------------------
# 7. what to run
#---------------------------------------------------------------------

say_hdr('How to run the live tests');

my $ea_t = $opt{'ea-podman'} . '/t/LiveTests/ea4-325-upgrade-live.t';
if ( -e $ea_t ) {
    print <<"END";

  ea-podman (EA4-325). DESTRUCTIVE and SERVER-WIDE -- it sweeps every account:

    cd $opt{'ea-podman'}
    EAPODMAN_LIVE=1 $PERL t/LiveTests/ea4-325-upgrade-live.t

END
}
else {
    note("no ea-podman live test at $ea_t");
}

my $pl_t = $opt{plugin} . '/cpanel/webapp/perl/usr/local/cpanel/t';
if ( -d $pl_t ) {
    print <<"END";
  webapp plugin (CPANEL-56732 / 56733). Creates throwaway accounts:

    WEBAPP_LIVE=1 $PERL $pl_t/Cpanel-WebApps-Cleanup-live.t
    WEBAPP_LIVE=1 $PERL $pl_t/Cpanel-WebApps-Podman-redeploy-force-live.t

  NOTE: the second one SKIPS. install_app() reaches ea-podman through an
  adminbin that checks its parent process against a whitelist, and a standalone
  .t is not on it. The end-to-end file below is what covers that contract.

END
}
else {
    note("no plugin tests at $pl_t");
}

my $e2e_t = $opt{'ea-podman'} . '/t/LiveTests/cpanel-54868-e2e-live.t';
if ( -e $e2e_t ) {
    print <<"END";
  BOTH HALVES, through the product (CPANEL-54868). This is the only test that
  can prove the ordering contract, because it needs the plugin and ea-podman
  installed and talking to each other. Run it AFTER the ea-podman one above,
  with --check-clean in between -- they are mutually destructive:

    EAPODMAN_LIVE=1 $PERL $e2e_t

  ... and to build the ordering HAZARD deliberately (edits the deployed
  Podman.pm and restores it):

    EAPODMAN_LIVE=1 CP54868_PROVE_HAZARD=1 $PERL $e2e_t

END
}
else {
    note("no end-to-end test at $e2e_t");
}

#---------------------------------------------------------------------
# verdict
#---------------------------------------------------------------------

say_hdr('Verdict');

if (@FATAL) {
    print "  NOT READY -- " . scalar(@FATAL) . " blocking problem(s):\n";
    print "    - $_\n" for @FATAL;
    print "  " . scalar(@WARN) . " advisory warning(s).\n" if @WARN;
    exit 1;
}

print "  READY.\n";
if (@WARN) {
    print "  " . scalar(@WARN) . " advisory warning(s); some subtests will skip:\n";
    print "    - $_\n" for @WARN;
}
print "  Working trees deployed; backups in $BACKUP\n" if $opt{deploy};
print "\n";

exit 0;
