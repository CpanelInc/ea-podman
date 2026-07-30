#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-registry-locking.t      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# CPANEL-55342: the shared, root-owned container registry is mutated as root on
# behalf of every account, so read → modify → write must happen under one
# exclusive lock or concurrent writers lose entries / tear the file.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

use Cpanel::JSON ();

require "$FindBin::Bin/../SOURCES/util.pm";

plan skip_all => "These tests must run as root (the registry is root-owned)" if $> != 0;

my $CHILDREN           = 12;
my $CONTAINERS_PER_KID = 4;

# Register/deregister from $CHILDREN processes at once, then make sure every
# entry survived. Each child registers its own names so there is no legitimate
# reason for any of them to go missing — anything absent was clobbered by
# another child dumping a hash it read before that child wrote.
subtest 'concurrent registrations do not lose entries' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    my @expected = _fork_and_wait(
        sub {
            my ($kid) = @_;

            for my $n ( 1 .. $CONTAINERS_PER_KID ) {
                ea_podman::util::register_container_as_root( "kid$kid-app$n.bob.01", "bob", 0, "node:22", 0 );
            }

            return map { "kid$kid-app$_.bob.01" } 1 .. $CONTAINERS_PER_KID;
        }
    );

    my $containers = Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file);
    is( scalar keys %{$containers}, scalar @expected, "all " . scalar(@expected) . " concurrently registered containers are in the registry" );

    my @missing = grep { !exists $containers->{$_} } @expected;
    is_deeply( \@missing, [], "no registration was clobbered by a concurrent writer" );
};

subtest 'concurrent deregistrations do not resurrect entries' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    my @names = map { my $kid = $_; map { "kid$kid-app$_.bob.01" } 1 .. $CONTAINERS_PER_KID } 1 .. $CHILDREN;
    ea_podman::util::register_container_as_root( $_, "bob", 0, "node:22", 0 ) for @names;
    is( scalar keys %{ Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file) }, scalar @names, "sanity: everything is registered to start with" );

    # Each child removes only its own containers; a stale-read writer would
    # bring back the ones another child had already removed.
    _fork_and_wait(
        sub {
            my ($kid) = @_;
            ea_podman::util::deregister_container_as_root("kid$kid-app$_.bob.01") for 1 .. $CONTAINERS_PER_KID;
            return;
        }
    );

    is_deeply( Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file), {}, "every concurrent deregistration stuck" );
};

# A torn file is not valid JSON, so a reader racing the writers is the check.
subtest 'a reader never sees a partially written registry' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    ea_podman::util::register_container_as_root( "seed.bob.01", "bob", 0, "node:22", 0 );

    my @writers = map { _fork( $_, sub { my ($kid) = @_; ea_podman::util::register_container_as_root( "kid$kid-app$_.bob.01", "bob", 0, "node:22", 0 ) for 1 .. $CONTAINERS_PER_KID; return } ) } 1 .. $CHILDREN;

    my $reads = 0;
    my @bad;
    while ( waitpid( -1, 1 ) == 0 ) {    # 1 == WNOHANG
        $reads++;
        my $got = eval { ea_podman::util::load_known_containers_as_root() };
        push @bad, ( $@ || 'no data' ) if !$got || !exists $got->{"seed.bob.01"};
    }
    waitpid( $_, 0 ) for @writers;

    ok( $reads > 0, "the reader got at least one read in while the writers ran ($reads reads)" );
    is_deeply( \@bad, [], "every read parsed and still had the seed entry" );
};

subtest 'a no-op or failed mutation still releases the lock' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 0, "redis:7", 0 );

    # Already registered (warns and declines to write) …
    {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 0, "redis:7", 0 );
        ea_podman::util::deregister_container_as_root("never-registered.bob.01");
        is( scalar @warnings, 2, "the already-registered and not-registered cases still warn" );
    }

    # … and a mutation that dies part way through.
    my $died = !eval {
        ea_podman::util::_mutate_known_containers_as_root( sub { die "boom\n" } );
        1;
    };
    ok( $died, "an exception from the mutation propagates" );

    is_deeply( ea_podman::util::load_known_containers_as_root(), Cpanel::JSON::LoadFile($ea_podman::util::known_containers_file), "the registry was left untouched" );

    # If any of the above leaked its lock this would block for
    # $Cpanel::SafeFile::LOCK_WAIT_TIME instead of returning.
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timed out waiting for the registry lock\n" };
        alarm 30;
        ea_podman::util::register_container_as_root( "after.bob.01", "bob", 0, "node:22", 0 );
        alarm 0;
        1;
    };
    ok( $ok, "the registry can still be locked afterward" ) or diag($@);
    ok( exists ea_podman::util::load_known_containers_as_root()->{"after.bob.01"}, "and the next registration went through" );
};

subtest 'the registry stays root-only' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 0, "redis:7", 0 );
    is( sprintf( "%04o", ( stat $ea_podman::util::known_containers_file )[2] & 07777 ), "0600", "a registry created by a mutation is 0600" );

    chmod 0644, $ea_podman::util::known_containers_file;
    ea_podman::util::register_container_as_root( "other.bob.01", "bob", 0, "redis:7", 0 );
    is( sprintf( "%04o", ( stat $ea_podman::util::known_containers_file )[2] & 07777 ), "0600", "a loosened registry is tightened back to 0600 by the next mutation" );
};

subtest 'a truncated registry left by an interrupted unlocked write is recoverable' => sub {
    my $tmp = File::Temp->newdir();
    local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    open my $fh, '>', $ea_podman::util::known_containers_file or die $!;
    close $fh;

    is_deeply( ea_podman::util::load_known_containers_as_root(), {}, "a zero length registry reads as empty instead of dying" );

    ea_podman::util::register_container_as_root( "plain.bob.01", "bob", 0, "redis:7", 0 );
    ok( exists ea_podman::util::load_known_containers_as_root()->{"plain.bob.01"}, "and it can be registered into" );
};

done_testing();

sub _fork {
    my ( $kid, $code ) = @_;

    my $pid = fork();
    die "Could not fork: $!" if !defined $pid;
    return $pid if $pid;

    # Stagger the children a little so they collide inside the read → write
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
    is( $failed, 0, "all $CHILDREN concurrent writers finished cleanly" );

    # What the children were supposed to have done, computed in the parent.
    return map { my $kid = $_; map { "kid$kid-app$_.bob.01" } 1 .. $CONTAINERS_PER_KID } 1 .. $CHILDREN;
}
