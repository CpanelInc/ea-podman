#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-clean-backups.t          Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use File::Temp ();
use FindBin;

our $HOMEDIR;

BEGIN {
    # Context-aware, as the real getpwuid is: scalar context yields the NAME.
    # A list-only stub returns the last element there (the shell), which is the
    # kind of thing that makes a sweep think it belongs to nobody.
    *CORE::GLOBAL::getpwuid = sub {
        my ($uid) = @_;
        return "bob" if !wantarray;
        return ( "bob", "x", $uid, $uid, "", "", "", $main::HOMEDIR, "/bin/bash" );
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";

# Taken before _world() stubs it, so the real one can be asked directly.
my $real_dir_size = \&ea_podman::util::_dir_size;

# EA4-325 Increment C, CPANEL-54870. `ea-podman uninstall` and
# remove_containers move a container's directory aside to <name>.bak and then
# nothing ever reclaims it. A `.bak` holds the container's read-write /app --
# runtime state, .env, and for a zip-sourced application its entire source -- so
# this lists by default and only removes when asked.

no warnings qw(once redefine);    # this file redefines seams constantly, by design

my $DAY = 24 * 60 * 60;

sub _world {
    my $tmp = File::Temp->newdir();
    $main::HOMEDIR = "$tmp";
    mkdir "$tmp/ea-podman.d";

    no warnings 'redefine';
    *ea_podman::util::_get_container_root = sub { "$main::HOMEDIR/ea-podman.d" };
    *ea_podman::util::load_known_containers = sub { return {} };
    *ea_podman::util::_podman_container_exists = sub { return 0 };
    *ea_podman::util::_get_current_ports       = sub { return () };
    *ea_podman::util::_dir_size                = sub { return 4096 };

    return $tmp;
}

# ctime is what this is about, and ctime cannot be set with utime(). Making a
# directory and then renaming it is exactly how a real `.bak` is born, so the
# test builds them the same way and controls age by stubbing the clock instead.
sub _mk_bak {
    my ( $tmp, $name ) = @_;
    my $root = "$tmp/ea-podman.d";
    mkdir "$root/$name";
    rename( "$root/$name", "$root/$name.bak" ) or die "rename: $!";
    return "$root/$name.bak";
}

sub _paths { return [ sort map { $_->{path} } @{ $_[0] } ] }

sub _reason_for {
    my ( $report, $path ) = @_;
    my ($hit) = grep { $_->{path} eq $path } @{ $report->{skipped} };
    return $hit ? $hit->{reason} : undef;
}

subtest 'lists by default and removes only when asked' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );

    # Pretend it aged: the clock moves, not the file.
    local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };

    my $listed = ea_podman::util::clean_backups();
    is( $listed->{ran}, 0, "a bare call does not act" );
    is_deeply( _paths( $listed->{removable} ), [$bak], "and lists the backup" );
    ok( -d $bak, "which is still on disk" );

    my $ran = ea_podman::util::clean_backups( run => 1 );
    is( $ran->{ran}, 1, "run acts" );
    ok( !-d $bak, "and the backup is gone" );
};

subtest 'the listing reports age and size, so an operator can judge' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );

    local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };

    my ($entry) = @{ ea_podman::util::clean_backups()->{removable} };
    is( $entry->{name}, "myapp.bob.01", "the container name is reported" );
    cmp_ok( $entry->{age}, '>', 39 * $DAY, "with its age" );
    is( $entry->{size}, 4096, "and its size" );
};

# EA4-325 C2, and the reason the ticket calls it out: renaming a directory moves
# its ctime and leaves mtime ALONE. A `.bak` made one second ago still carries
# the mtime of its last deploy, so an mtime rule would delete backups made
# moments earlier -- the exact opposite of what this is for.
subtest 'a brand new backup with an ancient mtime is not touched' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );

    # Backdate mtime by a year. ctime stays as of the rename, seconds ago.
    my $old = time() - ( 365 * $DAY );
    utime( $old, $old, $bak );

    my $report = ea_podman::util::clean_backups( run => 1 );

    ok( -d $bak, "the backup survives" );
    is( _reason_for( $report, $bak ), "too_recent", "because its age is taken from ctime, not mtime" );
    is_deeply( $report->{removable}, [], "and nothing was listed as removable" );
};

# EA4-325 C5. get_next_available_container_name() checks only the container
# directory, so freeing a name still claimed elsewhere hands it to the next
# install with stale state attached.
subtest 'a backup whose name is still claimed is kept, and says by what' => sub {
    for my $case (
        [ "registered", sub { *ea_podman::util::load_known_containers    = sub { return { "myapp.bob.01" => {} } } } ],
        [ "container",  sub { *ea_podman::util::_podman_container_exists = sub { return 1 } } ],
        [ "ports",      sub { *ea_podman::util::_get_current_ports       = sub { return (10000) } } ],
      ) {
        my ( $reason, $setup ) = @{$case};

        my $tmp = _world();
        my $bak = _mk_bak( $tmp, "myapp.bob.01" );
        no warnings 'redefine';
        $setup->();
        local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };

        my $report = ea_podman::util::clean_backups( run => 1 );

        ok( -d $bak, "still there when the name is held by: $reason" );
        is( _reason_for( $report, $bak ), $reason, "and reported as $reason" );
    }
};

subtest 'a surviving systemd unit also holds the name' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );
    mkdir "$tmp/.config";
    mkdir "$tmp/.config/systemd";
    mkdir "$tmp/.config/systemd/user";
    open( my $fh, ">", "$tmp/.config/systemd/user/container-myapp.bob.01.service" ) or die $!;
    close $fh;

    local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };

    my $report = ea_podman::util::clean_backups( run => 1 );

    ok( -d $bak, "kept" );
    is( _reason_for( $report, $bak ), "unit", "reported as still having a unit" );
};

# EA4-325 C6. A hand-made directory is excluded by its NAME rather than by a
# guess about its contents.
subtest 'only <name>.<user>.<NN> belonging to this account is considered' => sub {
    my $tmp = _world();

    my $mine     = _mk_bak( $tmp, "myapp.bob.01" );
    my $somebody = _mk_bak( $tmp, "myapp.sue.01" );     # right shape, wrong owner
    my $handmade = _mk_bak( $tmp, "just-a-folder" );    # not a container name

    local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };

    my $report = ea_podman::util::clean_backups( run => 1 );

    ok( !-d $mine,     "this account's backup is removed" );
    ok( -d $somebody,  "another account's name is left alone" );
    ok( -d $handmade,  "and a hand-made directory is never touched" );

    is( _reason_for( $report, $somebody ), "not_a_container_backup", "the foreign name is reported as not ours" );
    is( _reason_for( $report, $handmade ), "not_a_container_backup", "and so is the hand-made one" );
};

subtest 'a directory that is not a .bak is invisible to this' => sub {
    my $tmp = _world();
    mkdir "$tmp/ea-podman.d/myapp.bob.01";    # a LIVE container directory

    local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };

    my $report = ea_podman::util::clean_backups( run => 1 );

    ok( -d "$tmp/ea-podman.d/myapp.bob.01", "the live container directory is untouched" );
    is_deeply( $report->{removable}, [], "and never even considered" );
};

# EA4-325 C7, narrowed. Refusing outright left `clean` unable to do its job:
# removing the last container drops the account's linger, so the accounts WITH
# backups to reclaim are exactly the ones with no session.
subtest 'a session that is down narrows the checks rather than stopping the sweep' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );

    local $ea_podman::util::now = sub { time() + ( 40 * $DAY ) };
    local $ea_podman::util::user_session_reachable = sub { return 0 };

    my $report = ea_podman::util::clean_backups( run => 1 );

    ok( $report->{podman_unverifiable}, "the skipped check is reported" );
    ok( !-d $bak, "and the backup is still reclaimed" );
};

# The narrowing must not become a free-for-all: the three checks that do NOT
# need a session still hold a name.
subtest 'with the session down, the sessionless checks still protect a name' => sub {
    for my $case (
        [ "registered", sub { *ea_podman::util::load_known_containers = sub { return { "myapp.bob.01" => {} } } } ],
        [ "ports",      sub { *ea_podman::util::_get_current_ports    = sub { return (10000) } } ],
      ) {
        my ( $reason, $setup ) = @{$case};

        my $tmp = _world();
        my $bak = _mk_bak( $tmp, "myapp.bob.01" );
        no warnings 'redefine';
        $setup->();
        local $ea_podman::util::now                    = sub { time() + ( 40 * $DAY ) };
        local $ea_podman::util::user_session_reachable = sub { return 0 };

        my $report = ea_podman::util::clean_backups( run => 1 );

        ok( -d $bak, "kept when the name is held by: $reason" );
        is( _reason_for( $report, $bak ), $reason, "and reported as $reason" );
    }
};

# The one thing the narrowing gives up, stated as a test so it is a decision
# rather than an accident: with no session, a container that exists ONLY in
# podman's storage cannot be seen, and its name is treated as free.
subtest 'the gap the narrowing accepts is exactly one check, and only when the session is down' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );

    no warnings 'redefine';
    local *ea_podman::util::_podman_container_exists = sub { return 1 };    # a stopped container in storage
    local $ea_podman::util::now                      = sub { time() + ( 40 * $DAY ) };

    # Session up: podman is asked, and the name is held.
    local $ea_podman::util::user_session_reachable = sub { return 1 };
    ea_podman::util::clean_backups( run => 1 );
    ok( -d $bak, "with a session, podman holds the name" );

    # Session down: podman cannot be asked, so it is reclaimed -- an EA4-320
    # orphan by definition, since nothing else references it.
    local $ea_podman::util::user_session_reachable = sub { return 0 };
    my $report = ea_podman::util::clean_backups( run => 1 );
    ok( !-d $bak, "without one, it is reclaimed" );
    ok( $report->{podman_unverifiable}, "and the report says the check was skipped" );
};

subtest 'the age threshold is an option' => sub {
    my $tmp = _world();
    my $bak = _mk_bak( $tmp, "myapp.bob.01" );

    my $report = ea_podman::util::clean_backups( run => 1 );
    ok( -d $bak, "a fresh backup is kept at the default threshold" );

    ea_podman::util::clean_backups( run => 1, max_age => 0 );
    ok( !-d $bak, "and reachable with a lowered one" );
};

# "Could not look" must never read as "nothing there". A symlink that points at
# itself fails stat() with ELOOP; EACCES is the real-life case, but this suite
# may run as root, and ELOOP takes the same branch.
subtest 'a ~/ea-podman.d that cannot be examined is reported, not treated as empty' => sub {
    my $tmp  = _world();
    my $root = "$tmp/ea-podman.d";
    rmdir $root or die "rmdir: $!";
    symlink( $root, $root ) or die "symlink: $!";

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $report = ea_podman::util::clean_backups( run => 1 );

    is( $report->{unreadable}, $root, "the account is reported as unreadable" );
    is_deeply( $report->{removable}, [], "and nothing is claimed" );
    like( $warnings[0] // '', qr/could not examine/, "and the operator is told" );

    unlink $root;
    my $absent = ea_podman::util::clean_backups();
    ok( !exists $absent->{unreadable}, "while one that simply does not exist is just empty" );
};

subtest 'a .bak that cannot be stat()ed is reported, and never aged as 0 days old' => sub {
    my $tmp = _world();
    my $loop = "$tmp/ea-podman.d/myapp.bob.02.bak";
    symlink( $loop, $loop ) or die "symlink: $!";
    open( my $fh, '>', "$tmp/ea-podman.d/stray.bob.03.bak" ) or die "open: $!";
    close $fh;

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    # --days=0 considers every backup, so an age that fell back to 0 would be
    # removed here. It must be reported instead.
    my $report = ea_podman::util::clean_backups( run => 1, max_age => 0 );

    is( _reason_for( $report, $loop ), 'unreadable', "it is reported as unreadable" );
    is_deeply( $report->{removable}, [], "and not removed" );
    is( _reason_for( $report, "$tmp/ea-podman.d/stray.bob.03.bak" ), undef, "while a stray file is still passed over without a word" );
    is( scalar(@warnings), 1, "one warning, for the one that could not be examined" );
};

subtest 'a size that could not be measured is undef, never 0 bytes' => sub {
    my $tmp = File::Temp->newdir();
    open( my $fh, '>', "$tmp/data" ) or die "open: $!";
    print {$fh} "x" x 5000;
    close $fh;

    my $size = $real_dir_size->("$tmp");
    ok( defined $size && $size >= 5000, "a readable tree is measured" );
    is( $real_dir_size->("$tmp/not-here"), undef, "one du cannot measure is undef, not 0" );
};

subtest 'an account with nothing to clean reports cleanly' => sub {
    my $tmp   = _world();
    my $report = ea_podman::util::clean_backups( run => 1 );
    is_deeply( $report->{removable}, [], "nothing removable" );
    is_deeply( $report->{skipped},   [], "nothing skipped" );
    is( $report->{user}, "bob", "and it says whose account it swept" );
};

done_testing();
