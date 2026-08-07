#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-PodmanHooks-backup.t         Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# CPANEL-55309: pkgacct runs for every account, so this hook does too. It must
# not bootstrap a rootless session (subuid/subgid + `loginctl enable-linger`,
# which starts a user systemd manager that then never goes away) for an account
# that has no containers to back up in the first place.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

our @system_cmds;

BEGIN {
    # PodmanHooks.pm loads the *installed* util.pm when there is one, which on a
    # machine with ea-podman installed is not the copy under test. Load the repo
    # copy and mark the installed path as already loaded so its require is a
    # no-op.
    require "$FindBin::Bin/../SOURCES/util.pm";
    require "$FindBin::Bin/../SOURCES/subids.pm";
    $INC{$_} = __FILE__ for (
        '/opt/cpanel/ea-podman/lib/ea_podman/util.pm',
        './SOURCES/util.pm',
        '/root/git/ea-podman/SOURCES/util.pm',
        "$FindBin::Bin/../SOURCES/util.pm",
        '/opt/cpanel/ea-podman/lib/ea_podman/subids.pm',
        './SOURCES/subids.pm',
        '/root/git/ea-podman/SOURCES/subids.pm',
        "$FindBin::Bin/../SOURCES/subids.pm",
    );

    require Test::Mock::Cmd;
    Test::Mock::Cmd->import( 'system' => sub { push @system_cmds, [@_]; return 0; } );
}

require "$FindBin::Bin/../SOURCES/PodmanHooks.pm";

our @init_user_calls;
our @backup_calls;

{
    no warnings qw(redefine once);
    *ea_podman::util::init_user          = sub { push @init_user_calls, [@_]; return; };
    *ea_podman::util::perform_user_backup = sub { push @backup_calls,   [@_]; return; };
}

sub _registry {
    my (@containers) = @_;

    my $tmp = File::Temp->newdir();
    $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    for my $container (@containers) {
        ea_podman::util::register_container_as_root( $container->{name}, $container->{user}, 0, "redis:7", 0 );
    }

    @system_cmds     = ();
    @init_user_calls = ();
    @backup_calls    = ();

    return $tmp;    # keep it alive for the caller’s scope
}

subtest 'an account with no containers is left completely alone' => sub {
    my $tmp = _registry( { name => "redis.bob.01", user => "bob" } );

    my @rv = PodmanHooks::_do_backup( {}, { user => "alice" } );

    is_deeply( \@rv, [ 1, "Success" ], "the hook still succeeds" );
    is_deeply( \@system_cmds, [], "no rootbackupofuser run — so no linger, no subid allocation" );
    is_deeply( \@init_user_calls, [], "and init_user() is never reached" );
};

subtest 'an account with a container is still backed up' => sub {
    my $tmp = _registry( { name => "redis.bob.01", user => "bob" } );

    my @rv = PodmanHooks::_do_backup( {}, { user => "bob" } );

    is_deeply( \@rv, [ 1, "Success" ] );
    is_deeply( \@system_cmds, [ [ "/scripts/ea-podman", "rootbackupofuser", "bob" ] ], "the backup runs as it always did" );
};

subtest 'root with no containers is left alone too' => sub {
    my $tmp = _registry( { name => "redis.bob.01", user => "bob" } );

    my @rv = PodmanHooks::_do_backup( {}, { user => "root" } );

    is_deeply( \@rv, [ 1, "Success" ] );
    is_deeply( \@init_user_calls, [], "no session bootstrap" );
    is_deeply( \@backup_calls,    [], "and nothing to back up" );
};

subtest 'root with containers is backed up in process' => sub {
    my $tmp = _registry( { name => "redis.root.01", user => "root" } );

    my @rv = PodmanHooks::_do_backup( {}, { user => "root" } );

    is_deeply( \@rv, [ 1, "Success" ] );
    is( scalar @init_user_calls, 1, "root’s own session is set up" );
    is( scalar @backup_calls,    1, "and the backup runs" );
    is_deeply( \@system_cmds, [], "root does not need the adminbin detour" );
};

subtest 'an empty registry means nobody is bootstrapped' => sub {
    my $tmp = _registry();

    PodmanHooks::_do_backup( {}, { user => $_ } ) for qw(alice bob root);

    is_deeply( \@system_cmds,     [], "no account is shelled out for" );
    is_deeply( \@init_user_calls, [], "no account is lingered" );
};

# An install that dies before registering leaves a grant no removal comes back
# for. These hooks are where such an account is last seen. (CPANEL-55309)
subtest 'deleting a container-less account still gives back a linger we granted' => sub {
    my $tmp = _registry( { name => "redis.bob.01", user => "bob" } );

    my @released;
    no warnings qw(redefine once);
    local *ea_podman::util::release_user_session_as_root = sub { push @released, $_[0]; return 1; };

    my @rv = PodmanHooks::_delete_user( {}, { user => "alice" } );

    is_deeply( \@rv,       [ 1, "Success" ], "the hook still succeeds" );
    is_deeply( \@released, ["alice"],        "and the orphaned grant is handed back" );
};

subtest 'renaming a container-less account gives back a linger we granted' => sub {
    my $tmp = _registry( { name => "redis.bob.01", user => "bob" } );

    my @released;
    no warnings qw(redefine once);
    local *ea_podman::util::release_user_session_as_root = sub { push @released, $_[0]; return 1; };

    my @rv = PodmanHooks::_pre_username_change( {}, { user => "alice", newuser => "alice2" } );

    is_deeply( \@rv,       [ 1, "Success" ], "the rename is still allowed" );
    is_deeply( \@released, ["alice"],        "and it is given back under the name that still exists" );
};

subtest 'renaming an account that has containers is still refused' => sub {
    my $tmp = _registry( { name => "redis.bob.01", user => "bob" } );

    my @released;
    no warnings qw(redefine once);
    local *ea_podman::util::release_user_session_as_root = sub { push @released, $_[0]; return 1; };

    my ($ok) = PodmanHooks::_pre_username_change( {}, { user => "bob", newuser => "bob2" } );

    is( $ok, 0, "the rename is refused" );
    is_deeply( \@released, [], "and nothing is released for an account that keeps its containers" );
};

subtest 'a rename that is not really a rename is still a no-op' => sub {
    my $tmp = _registry();

    my @released;
    no warnings qw(redefine once);
    local *ea_podman::util::release_user_session_as_root = sub { push @released, $_[0]; return 1; };

    my @rv = PodmanHooks::_pre_username_change( {}, { user => "alice", newuser => "alice" } );

    is_deeply( \@rv,       [ 1, "Success" ] );
    is_deeply( \@released, [], "the account is not going anywhere, so its session is not touched" );
};

done_testing();
