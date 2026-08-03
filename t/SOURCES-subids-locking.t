#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-subids-locking.t             Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# An account's /etc/subuid range is what keeps its rootless containers off every
# other account's host uids, so read → compute → append has to happen under one
# exclusive lock. Unlocked, concurrent bootstraps read the same "next" value and
# hand two accounts the same range.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

use Path::Tiny 'path';

require "$FindBin::Bin/../SOURCES/subids.pm";

my $NUM_UIDS = 65537;           # what ensure_user_root() defaults to
my $COUNT    = $NUM_UIDS - 1;

# The reporter's proof of concept: 30 accounts bootstrapping at once produced 7
# colliding start-uids against the unlocked version.
my $CHILDREN = 30;

my @keep_alive;    # File::Temp removes its directory as soon as nothing holds it

subtest 'concurrent allocations never hand out the same range' => sub {
    my ( $subuid, $subgid ) = _mock_files();

    my @users = map { "raceuser$_" } 1 .. $CHILDREN;
    _fork_and_wait( sub { ea_podman::subids::_ensure_subids( "raceuser$_[0]", $NUM_UIDS ) } );

    for my $file ( $subuid, $subgid ) {
        my @ranges = _ranges($file);

        is( scalar @ranges, scalar @users, "every one of the $CHILDREN concurrent allocations is in " . _name($file) );

        my %seen_by_user = map { $_->{user} => 1 } @ranges;
        is_deeply( [ grep { !$seen_by_user{$_} } @users ], [], "no allocation was lost to a concurrent writer in " . _name($file) );

        my @collisions = _collisions(@ranges);
        is_deeply( \@collisions, [], "no two accounts share host IDs in " . _name($file) ) or diag( explain \@collisions );
    }
};

# The same account bootstrapping twice at once is the same race seen from the
# other side: both readers find it absent and both append a line for it.
subtest 'one account racing itself gets exactly one range' => sub {
    my ( $subuid, $subgid ) = _mock_files();

    _fork_and_wait( sub { ea_podman::subids::_ensure_subids( "bob", $NUM_UIDS ) } );

    for my $file ( $subuid, $subgid ) {
        is_deeply( [ map { $_->{user} } _ranges($file) ], ["bob"], "“bob” has a single range in " . _name($file) );
    }
};

# Pins the allocation arithmetic, which was deliberately left alone: the first
# range on an empty host ends just below 190000, and the next starts past it.
subtest 'allocation starts where it always has' => sub {
    my ( $subuid, $subgid ) = _mock_files();

    ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS );
    is_deeply( [ _ranges($subuid) ], [ { user => "alice", start => 124464, count => $COUNT } ], "the first allocation ends just below 190000" );

    ea_podman::subids::_ensure_subids( "bob", $NUM_UIDS );
    is_deeply( [ _ranges($subuid) ], [ { user => "alice", start => 124464, count => $COUNT }, { user => "bob", start => 190001, count => $COUNT } ], "the second starts past the first" );

    is_deeply( [ _ranges($subgid) ], [ _ranges($subuid) ], "subgid tracks subuid" );

    # Already allocated is a no-op, not a second line.
    ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS );
    my @after = _ranges($subuid);
    is( scalar @after, 2, "an account that already has a range is left alone" );
};

subtest 'the files are created when the host has neither yet' => sub {
    my $tmp = File::Temp->newdir();

    no warnings qw/once/;
    local $ea_podman::subids::file_subuid = "$tmp/subuid";
    local $ea_podman::subids::file_subgid = "$tmp/subgid";

    ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS );

    ok( -e "$tmp/subuid", "subuid was created" );
    is_deeply( [ _ranges("$tmp/subuid") ], [ { user => "alice", start => 124464, count => $COUNT } ], "and allocated into" );
};

# The old code wrapped both appends in `if ( open ... )`, so a write it could not
# do looked exactly like one it had done: no range, no error, and podman left to
# fail later on a mapping that was never there.
subtest 'a write that cannot happen is an error, not a silent no-op' => sub {
    my $tmp = File::Temp->newdir();

    no warnings qw/once/;
    local $ea_podman::subids::file_subuid = "$tmp/no-such-dir/subuid";
    local $ea_podman::subids::file_subgid = "$tmp/no-such-dir/subgid";

    my $ok = eval { ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS ); 1 };
    ok( !$ok, "allocating into an unwritable path dies" );
    like( $@, qr/Could not open/, "and says so" );
};

# Fail closed: these states are already on disk on any system an unlocked
# version raced, and running containers on them is the breach itself.
subtest 'an account whose range is already shared is refused' => sub {
    my ( $subuid, $subgid ) = _mock_files("alice:200000:65536\nbob:230000:65536\n");

    for my $user (qw(alice bob)) {
        my $ok = eval { ea_podman::subids::_ensure_subids( $user, $NUM_UIDS ); 1 };
        ok( !$ok, "“$user” is refused while it shares host IDs" );
        like( $@, qr/shares the host IDs/, "and is told what is wrong" );
    }

    # The account that is not part of the overlap is unaffected …
    _mock_files("alice:200000:65536\nbob:230000:65536\ncarol:400000:65536\n");
    ok( eval { ea_podman::subids::_ensure_subids( "carol", $NUM_UIDS ); 1 }, "an account with a range of its own still works" ) or diag($@);

    # … and so is a brand new one, which is allocated past all of them.
    ok( eval { ea_podman::subids::_ensure_subids( "dave", $NUM_UIDS ); 1 }, "and a new account can still be allocated" ) or diag($@);
    is_deeply( [ grep { $_->{user} eq "dave" } _ranges($ea_podman::subids::file_subuid) ], [ { user => "dave", start => 465537, count => $COUNT } ], "past every existing range" );
};

# Half-allocated is a real state: the two files are written separately. Filling
# in the missing half must not hand back a success for an account whose other
# half is already shared.
subtest 'a shared range is refused even when only one file has it' => sub {
    my ( $subuid, $subgid ) = _mock_files();

    path($subuid)->spew("alice:200000:65536\nbob:230000:65536\n");
    path($subgid)->spew("bob:230000:65536\n");

    my $ok = eval { ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS ); 1 };
    ok( !$ok, "“alice” is refused on her shared subuid range despite having no subgid range" );
    like( $@, qr/shares the host IDs/, "and is told what is wrong" );

    is_deeply( [ _ranges($subgid) ], [ { user => "bob", start => 230000, count => 65536 } ], "and no subgid range was handed out to paper over it" );
};

subtest 'an account with two ranges is refused' => sub {
    my ( $subuid, $subgid ) = _mock_files("alice:200000:65536\nalice:400000:65536\n");

    my $ok = eval { ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS ); 1 };
    ok( !$ok, "an ambiguous account is refused" );
    like( $@, qr/more than one range/, "and is told what is wrong" );
};

# A duplicate line's IDs are as taken as any other's. Keeping only the last one
# per account would leave the earlier range out of the highest-end calculation
# and hand its IDs to the next account.
subtest 'every line counts toward the next allocation' => sub {
    my ( $subuid, $subgid ) = _mock_files("alice:200000:65536\nalice:400000:65536\n");

    ea_podman::subids::_ensure_subids( "bob", $NUM_UIDS );
    is_deeply( [ grep { $_->{user} eq "bob" } _ranges($subuid) ], [ { user => "bob", start => 465537, count => $COUNT } ], "the next allocation clears the highest line, not the last one" );
};

subtest 'unparsable lines are skipped rather than treated as collisions' => sub {
    my ( $subuid, $subgid ) = _mock_files("# a comment somebody added\n\nalice:200000:65536\nbroken\nbob:nonsense\n");

    ok( eval { ea_podman::subids::_ensure_subids( "alice", $NUM_UIDS ); 1 }, "a line that cannot be parsed does not take a working account offline" ) or diag($@);
    is_deeply( ea_podman::subids::get_subuid_problems(), {}, "and is not reported as a problem" );
};

# The audit has to agree with what _ensure_subids() enforces per account, or
# `ea-podman subids` gives an account a checkmark it then refuses to act on.
subtest 'unsafe ranges can be audited across the whole file' => sub {
    my ( $subuid, $subgid ) = _mock_files("alice:200000:65536\nbob:230000:65536\ncarol:400000:65536\ndave:400000:65536\n");

    is_deeply(
        ea_podman::subids::get_subuid_problems(),
        {
            alice => "shares host IDs with “bob”",
            bob   => "shares host IDs with “alice”",
            carol => "shares host IDs with “dave”",
            dave  => "shares host IDs with “carol”",
        },
        "every account sharing host IDs is named along with who it shares them with"
    );

    # Not an overlap, but still not a range an account can be said to own — and
    # _ensure_subids() refuses it, so the audit has to flag it too.
    _mock_files("alice:200000:65536\nalice:400000:65536\nbob:600000:65536\n");
    is_deeply( ea_podman::subids::get_subuid_problems(), { alice => "is listed with more than one range" }, "an account with two ranges is flagged even when they do not overlap" );

    _mock_files("alice:200000:65536\nbob:265536:65536\n");
    is_deeply( ea_podman::subids::get_subuid_problems(), {}, "ranges that merely abut do not overlap" );

    # A range that swallows several later ones is still caught: the sweep keeps
    # the range reaching furthest, not just the previous one.
    _mock_files("alice:200000:500000\nbob:250000:65536\ncarol:400000:65536\n");
    is_deeply(
        ea_podman::subids::get_subuid_problems(),
        {
            alice => "shares host IDs with “bob”, “carol”",
            bob   => "shares host IDs with “alice”",
            carol => "shares host IDs with “alice”",
        },
        "a range spanning several others is reported against all of them"
    );

    # Sharing IDs is the more urgent of the two, so it is what gets reported.
    _mock_files("alice:200000:65536\nalice:210000:65536\nbob:220000:65536\n");
    is_deeply( ea_podman::subids::get_subuid_problems(), { alice => "shares host IDs with “bob”", bob => "shares host IDs with “alice”" }, "an account with both problems is reported for the overlap" );
};

done_testing();

sub _mock_files {
    my ($seed) = @_;

    my $tmp = File::Temp->newdir();
    push @keep_alive, $tmp;

    $seed = "" if !defined $seed;
    path("$tmp/subuid")->spew($seed);
    path("$tmp/subgid")->spew($seed);

    no warnings qw/once/;
    $ea_podman::subids::file_subuid = "$tmp/subuid";
    $ea_podman::subids::file_subgid = "$tmp/subgid";

    return ( "$tmp/subuid", "$tmp/subgid" );
}

sub _name {
    my ($file) = @_;
    return path($file)->basename;
}

sub _ranges {
    my ($file) = @_;

    my @ranges;
    for my $line ( path($file)->lines( { chomp => 1 } ) ) {
        my ( $user, $start, $count ) = split( /:/, $line );
        push @ranges, { user => $user, start => $start + 0, count => $count + 0 };
    }

    return sort { $a->{start} <=> $b->{start} } @ranges;
}

# Independent of the module's own overlap check: sort by start and make sure each
# range begins after the previous one ends.
sub _collisions {
    my @ranges = sort { $a->{start} <=> $b->{start} } @_;

    my @collisions;
    for my $i ( 1 .. $#ranges ) {
        my ( $prev, $this ) = @ranges[ $i - 1, $i ];
        next if $this->{start} > $prev->{start} + $prev->{count} - 1;
        push @collisions, "$this->{user} ($this->{start}) overlaps $prev->{user} ($prev->{start}-" . ( $prev->{start} + $prev->{count} - 1 ) . ")";
    }

    return @collisions;
}

sub _fork {
    my ( $kid, $code ) = @_;

    my $pid = fork();
    die "Could not fork: $!" if !defined $pid;
    return $pid              if $pid;

    # Stagger the children a little so they collide inside the read → append
    # window rather than all lining up neatly behind the first one.
    select( undef, undef, undef, ( $kid % 4 ) * 0.01 );

    local $SIG{__WARN__} = sub { };
    eval { $code->($kid); 1 } or do { exit 1 };
    exit 0;
}

sub _fork_and_wait {
    my ($code) = @_;

    my @pids = map { _fork( $_, $code ) } 1 .. $CHILDREN;

    my $failed = 0;
    for my $pid (@pids) {
        waitpid( $pid, 0 );
        $failed++ if $?;
    }

    is( $failed, 0, "all $CHILDREN concurrent allocations finished cleanly" );

    return;
}
