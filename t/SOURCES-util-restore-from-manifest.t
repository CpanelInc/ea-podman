#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-restore-from-manifest.t Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use File::Temp ();
use FindBin;

our $HOMEDIR;
our @system_cmds;

BEGIN {
    *CORE::GLOBAL::getpwuid = sub {
        my ($uid) = @_;
        return "bob" if !wantarray;
        return ( "bob", "x", $uid, $uid, "", "", "", $main::HOMEDIR, "/bin/bash" );
    };

    require Test::Mock::Cmd;

    # `tar xf` stands in for unpacking a backup: it puts the manifest and the
    # container directory it names into the homedir.
    Test::Mock::Cmd->import(
        'system' => sub {
            push @system_cmds, [@_];
            if ( $_[0] eq 'tar' && $_[1] eq 'xf' ) {
                mkdir "$main::HOMEDIR/ea-podman.d";
                mkdir "$main::HOMEDIR/ea-podman.d/redis.bob.01";
                _write_manifest( [ { container_name => "redis.bob.01", webapp => 0, curr_ports => [10001] } ] );
            }
            return 0;
        }
    );
}

require "$FindBin::Bin/../SOURCES/util.pm";

# CPANEL-57396. pkgacct no longer makes a tarball, so after an account restore
# `ea-podman restore --verify` rebuilds from the manifest and the ea-podman.d
# that came back with the homedir.

no warnings qw(once redefine);

my $UID_FOR_USER = 65500;

sub _write_manifest {
    my ($containers) = @_;
    open( my $fh, '>', "$main::HOMEDIR/ea_podman_backup_bob.json" ) or die $!;
    print {$fh} Cpanel::JSON::pretty_canonical_dump($containers);
    close $fh;
}

# %opts: manifest => [...], dirs => [...], registered => [...], ports => [...]
sub _world {
    my (%opts) = @_;

    my $tmp = File::Temp->newdir();
    chmod 0777, "$tmp";
    $main::HOMEDIR = "$tmp";
    mkdir "$tmp/ea-podman.d";
    chmod 0777, "$tmp/ea-podman.d";
    for my $dir ( @{ $opts{dirs} || [] } ) {
        mkdir "$tmp/ea-podman.d/$dir";
        open( my $fh, '>', "$tmp/ea-podman.d/$dir/precious" ) or die $!;
        print {$fh} "the account's data";
        close $fh;

        # made as root here, but the account owns them in real life
        chmod 0777, "$tmp/ea-podman.d/$dir";
        chmod 0666, "$tmp/ea-podman.d/$dir/precious";
    }
    _write_manifest( $opts{manifest} ) if $opts{manifest};

    my %log = ( init_user => [], restored => [], registry_reads => 0 );

    *ea_podman::util::load_known_containers = sub {
        $log{registry_reads}++;
        die "adminbin unavailable\n" if $opts{registry_dies};
        return { map { $_ => { container_name => $_ } } @{ $opts{registered} || [] } };
    };
    *ea_podman::util::init_user                   = sub { push @{ $log{init_user} }, [@_]; return };
    *ea_podman::util::restore_containers_for_user = sub { push @{ $log{restored} }, [@_]; return 1 };
    *ea_podman::util::_get_current_ports          = sub { return @{ $opts{ports} || [] } };

    @system_cmds = ();

    return ( $tmp, \%log );
}

sub _as_user {
    my ($code) = @_;

    chdir "/";
    return $code->() if $> != 0;

    local $> = $UID_FOR_USER;
    return $code->();
}

sub _restore {
    my (@args) = @_;

    my ( $out, $warned ) = ( '', '' );
    my $ok;
    {
        open( my $fh, '>', \$out ) or die $!;
        local *STDOUT = $fh;
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        $ok = eval { _as_user( sub { ea_podman::util::perform_user_restore(@args) } ); 1 };
    }

    return { ok => $ok, error => $@, out => $out, warned => $warned };
}

sub _names { return [ map { $_->{container_name} } @_ ] }

my $TWO = [
    { container_name => "redis.bob.01", webapp => 0, curr_ports => [10001] },
    { container_name => "app.bob.02",   webapp => 1, curr_ports => [10002] },
];

subtest 'restores from the manifest without tearing anything down or unpacking' => sub {
    my ( $tmp, $log ) = _world( manifest => $TWO, dirs => [ "redis.bob.01", "app.bob.02" ], ports => [10001] );

    my $r = _restore();
    ok( $r->{ok}, "it runs" ) or diag( $r->{error} );

    is_deeply( \@system_cmds, [], "no remove_containers, no tar" );
    ok( -e "$tmp/ea-podman.d/redis.bob.01/precious", "the restored data is untouched" );
    ok( -e "$tmp/ea-podman.d/app.bob.02/precious",   "all of it" );

    is_deeply( $log->{init_user}, [ [ creating => 1 ] ], "a session is set up for containers about to exist" );
    is( scalar @{ $log->{restored} }, 1, "restore_containers_for_user ran once" );
    is_deeply( _names( @{ $log->{restored}[0] } ), [ "redis.bob.01", "app.bob.02" ], "for the manifest's containers" );
    ok( $log->{restored}[0][1]{webapp}, "carrying the webapp flag" );
};

subtest 'a container the registry already has is left alone' => sub {
    my ( $tmp, $log ) = _world( manifest => $TWO, dirs => ["app.bob.02"], registered => ["redis.bob.01"], ports => [10002] );

    my $r = _restore();
    ok( $r->{ok}, "it runs" ) or diag( $r->{error} );

    like( $r->{out}, qr/“redis\.bob\.01” is already registered/, "and says so" );
    is_deeply( _names( @{ $log->{restored}[0] } ), ["app.bob.02"], "only the other one is restored" );
    is( $log->{registry_reads}, 1, "the registry is read once" );
};

subtest 'everything already registered means nothing to do' => sub {
    my ( $tmp, $log ) = _world( manifest => $TWO, registered => [ "redis.bob.01", "app.bob.02" ] );

    my $r = _restore();
    ok( $r->{ok}, "it runs" ) or diag( $r->{error} );

    like( $r->{out}, qr/Nothing to restore/, "it says so" );
    is_deeply( $log->{init_user}, [], "no session is set up" );
    is_deeply( $log->{restored},  [], "and nothing is restored" );
};

subtest 'a problem is found before anything is created' => sub {
    my ( $tmp, $log ) = _world( dirs => ["redis.bob.01"] );
    my $r = _restore();
    like( $r->{error}, qr/container backup file is not present/, "no manifest" );
    is_deeply( [ $log->{init_user}, $log->{restored} ], [ [], [] ], "nothing created" );

    ( $tmp, $log ) = _world( manifest => $TWO, dirs => [ "redis.bob.01", "app.bob.02" ], registry_dies => 1 );
    $r = _restore();
    like( $r->{error}, qr/adminbin unavailable/, "an unreadable registry stops it" );
    is_deeply( [ $log->{init_user}, $log->{restored} ], [ [], [] ], "rather than guessing" );

    ( $tmp, $log ) = _world( manifest => $TWO, dirs => ["redis.bob.01"] );
    $r = _restore();
    like( $r->{error}, qr{Container dir \(\Q$tmp\E/ea-podman\.d/app\.bob\.02\) does not exist}, "a missing container directory" );
    is_deeply( [ $log->{init_user}, $log->{restored} ], [ [], [] ], "stops it before the container that is fine is created" );
    is_deeply( \@system_cmds, [], "and nothing is run" );
};

subtest 'a change of ports is still reported' => sub {
    my ( $tmp, $log ) = _world( manifest => $TWO, dirs => [ "redis.bob.01", "app.bob.02" ], ports => [20001] );

    my $r = _restore();
    like( $r->{warned}, qr/TCP ports for redis\.bob\.01 have changed/, "the old ports are no longer assigned" );
    like( $r->{warned}, qr/originally assigned to the container are: 10001/, "and it names them" );
};

subtest 'root is refused' => sub {
    plan skip_all => "needs to run as root" if $> != 0;

    _world( manifest => $TWO, dirs => ["redis.bob.01"] );
    chdir "/";
    like( do { local $@; eval { ea_podman::util::perform_user_restore() }; $@ }, qr/Cannot be run as root/, "root is refused" );
};

subtest 'restoring from a tarball still tears down, unpacks, then restores everything' => sub {
    my ( $tmp, $log ) = _world( dirs => ["old.bob.09"], registered => ["redis.bob.01"], ports => [10001] );
    open( my $fh, '>', "$tmp/backup.tar.gz" ) or die $!;
    close $fh;

    my $r = _restore("$tmp/backup.tar.gz");
    ok( $r->{ok}, "it runs" ) or diag( $r->{error} );

    is_deeply(
        [ map { join " ", grep { !m{/} } @{$_} } @system_cmds ],
        [ "remove_containers --all", "tar xf" ],
        "existing containers removed, then the tarball unpacked"
    );
    ok( !-e "$tmp/ea-podman.d/old.bob.09", "ea-podman.d was replaced, not merged" );
    is_deeply( _names( @{ $log->{restored}[0] } ), ["redis.bob.01"], "and the tarball's containers restored, registered or not" );
    is( $log->{registry_reads}, 0, "without consulting the registry" );
};

done_testing();
