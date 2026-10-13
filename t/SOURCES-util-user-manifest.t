#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-user-manifest.t         Copyright 2026 WebPros International, LLC
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
    # Context-aware, as the real getpwuid is: scalar context yields the NAME.
    *CORE::GLOBAL::getpwuid = sub {
        my ($uid) = @_;
        return "bob" if !wantarray;
        return ( "bob", "x", $uid, $uid, "", "", "", $main::HOMEDIR, "/bin/bash" );
    };

    require Test::Mock::Cmd;

    # Stands in for tar: it still leaves the tarball behind, so retention has
    # something to count.
    Test::Mock::Cmd->import(
        'system' => sub {
            push @system_cmds, [@_];
            if ( $_[0] eq 'tar' && $_[1] eq 'czf' ) {
                open( my $fh, '>', $_[2] ) or die "$_[2]: $!";
                close $fh;
            }
            return 0;
        }
    );
}

require "$FindBin::Bin/../SOURCES/util.pm";

# CPANEL-57396. The pkgacct hook used to tar all of ~/ea-podman.d into
# ~/ea-podman-backups, and the homedir backup then carried that directory twice
# over. The hook now writes only the manifest.

no warnings qw(once redefine);

my $UID_FOR_USER = 65500;    # root cannot be backed up, so act as someone else

sub _world {
    my (%opts) = @_;

    my $tmp = File::Temp->newdir();
    chmod 0777, "$tmp";
    $main::HOMEDIR = "$tmp";
    mkdir "$tmp/ea-podman.d";
    mkdir "$tmp/ea-podman.d/redis.bob.01";
    chmod 0777, "$tmp/ea-podman.d", "$tmp/ea-podman.d/redis.bob.01";

    my @registry = (
        { container_name => "redis.bob.01", user => "bob",   pkg => "ea-redis", webapp => 0 },
        { container_name => "app.bob.02",   user => "bob",   pkg => "",         webapp => 1 },
        { container_name => "redis.alice.01", user => "alice", pkg => "ea-redis", webapp => 0 },
    );
    @registry = () if $opts{empty};

    *ea_podman::util::load_known_containers = sub { return { map { $_->{container_name} => {%$_} } @registry } };
    *ea_podman::util::_get_current_ports = sub { return $_[0] eq "redis.bob.01" ? ( 10001, 10002 ) : (10003) };

    my $n = 0;
    *ea_podman::util::_get_tarball_name = sub { return "$main::HOMEDIR/ea-podman-backups/backup-" . sprintf( "%03d", ++$n ) . ".tar.gz" };

    @system_cmds = ();

    return $tmp;
}

sub _as_user {
    my ($code) = @_;

    # perform_user_backup() chdirs back to where it started, and the new uid
    # cannot read its way back into the checkout
    chdir "/";

    return $code->() if $> != 0;

    local $> = $UID_FOR_USER;
    return $code->();
}

subtest 'write_user_manifest leaves only the manifest in the homedir' => sub {
    my $tmp = _world();

    my $rv = eval { _as_user( sub { ea_podman::util::write_user_manifest() } ); 1 };
    ok( $rv, "it runs" ) or diag($@);

    my $file = "$tmp/ea_podman_backup_bob.json";
    ok( -e $file, "the manifest stays where pkgacct will archive it" );

    my $manifest = Cpanel::JSON::LoadFile($file);
    is_deeply( [ sort map { $_->{container_name} } @{$manifest} ], [ "app.bob.02", "redis.bob.01" ], "only this user's containers" );

    my %by_name = map { $_->{container_name} => $_ } @{$manifest};
    is_deeply( $by_name{"redis.bob.01"}{curr_ports}, [ 10001, 10002 ], "with the ports each one holds now" );
    ok( $by_name{"app.bob.02"}{webapp}, "and the webapp flag restore needs" );

    ok( !-e "$tmp/ea-podman-backups", "no backups directory" );
    is_deeply( \@system_cmds, [], "and nothing was tarred" );
};

subtest 'write_user_manifest with no containers writes nothing' => sub {
    my $tmp = _world( empty => 1 );

    my $out = '';
    {
        open( my $fh, '>', \$out ) or die $!;
        local *STDOUT = $fh;
        is( _as_user( sub { ea_podman::util::write_user_manifest() } ), 1, "it reports there was nothing to do" );
    }

    like( $out, qr/There are no containers/, "and says so" );
    ok( !-e "$tmp/ea_podman_backup_bob.json", "no manifest" );
    ok( !-e "$tmp/ea-podman-backups",          "no backups directory" );
};

subtest 'write_user_manifest refuses to run as root' => sub {
    plan skip_all => "needs to run as root" if $> != 0;

    _world();
    like( do { local $@; eval { ea_podman::util::write_user_manifest() }; $@ }, qr/Cannot be run as root/, "root is refused" );
};

subtest 'perform_user_backup is unchanged: tarball, no loose manifest, newest 3 kept' => sub {
    my $tmp = _world();

    _as_user( sub { ea_podman::util::perform_user_backup() } ) for 1 .. 5;

    my @tarballs = map { s{.*/}{}r } glob("$tmp/ea-podman-backups/backup-*.tar.gz");
    is_deeply( \@tarballs, [ "backup-003.tar.gz", "backup-004.tar.gz", "backup-005.tar.gz" ], "the oldest were dropped" );
    ok( !-e "$tmp/ea_podman_backup_bob.json", "the manifest only lives inside the tarball" );

    my @tars = grep { $_->[1] eq 'czf' } @system_cmds;
    is( scalar @tars, 5, "one tar per run" );
    is_deeply( [ @{ $tars[0] }[ 0, 1, 3, 4 ] ], [ 'tar', 'czf', 'ea_podman_backup_bob.json', 'ea-podman.d' ], "of the manifest and ea-podman.d, list-form" );
};

done_testing();
