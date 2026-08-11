#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-linger.t                Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# Linger is enabled so an account’s rootless containers survive logout/reboot, so
# an account with no containers should not have it. Taking one back is narrower:
# the only linger ea-podman disables is one it recorded granting, and only while
# that record still covers the linger actually in place.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;
use Path::Tiny ();

require "$FindBin::Bin/../SOURCES/util.pm";
require "$FindBin::Bin/../SOURCES/subids.pm";

our %homedir_for;    # user => homedir, for the mocked getpwnam

BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        my ($user) = @_;
        return if !exists $main::homedir_for{$user};
        return ( $user, "x", 11002, 11004, 20, "", "", $main::homedir_for{$user}, "/bin/bash" );
    };
}

# A scratch world: the linger dir systemd would own, ea-podman’s record of the
# ones it granted, a container registry, and homedirs. Returns the
# disable-linger call log.
sub _mock_world {
    my (%args) = @_;

    no warnings qw(once);    # the modules under test are required at runtime

    my $tmp = $args{tmp};

    my $linger = "$tmp/linger";
    mkdir $linger;
    Path::Tiny::path("$linger/$_")->touch for @{ $args{lingering} || [] };

    my $granted = "$tmp/granted-linger";
    mkdir $granted;
    Path::Tiny::path("$granted/$_")->touch for @{ $args{granted} || [] };

    $ea_podman::subids::dir_linger          = $linger;
    $ea_podman::subids::dir_granted_linger  = $granted;
    $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";

    for my $container ( @{ $args{containers} || [] } ) {
        ea_podman::util::register_container_as_root( $container->{name}, $container->{user}, 0, "redis:7", $container->{webapp} );
    }

    %main::homedir_for = ();
    for my $user ( @{ $args{users} || [] } ) {
        my $home = "$tmp/home/$user";
        Path::Tiny::path($home)->mkpath;
        $main::homedir_for{$user} = $home;
    }

    for my $dir ( @{ $args{container_dirs} || [] } ) {
        Path::Tiny::path("$main::homedir_for{ $dir->{user} }/ea-podman.d/$dir->{name}")->mkpath;
    }

    my $disabled = [];
    $ea_podman::subids::linger_disabler = sub {
        my ($user) = @_;
        push @{$disabled}, $user;
        unlink "$ea_podman::subids::dir_linger/$user";
        return 1;
    };

    return $disabled;
}

# grant_covers_current_linger() compares mtimes, so fixtures need to order them.
sub _touch_at {
    my ( $path, $when ) = @_;

    Path::Tiny::path($path)->touch;
    utime( $when, $when, $path ) or die "could not set the mtime of $path: $!";

    return;
}

subtest 'user_has_containers_as_root' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, containers => [ { name => "redis.bob.01", user => "bob" } ] );

    ok( ea_podman::util::user_has_containers_as_root("bob"),   "an account with a registered container" );
    ok( !ea_podman::util::user_has_containers_as_root("alice"), "an account with none" );
    ok( !ea_podman::util::user_has_containers_as_root(undef),   "no account at all" );
};

subtest 'the linger grant record' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp );

    ok( !ea_podman::subids::user_has_granted_linger("alice"), "no record to start with" );

    ok( ea_podman::subids::record_linger_grant("alice"),    "the grant is recorded" );
    ok( ea_podman::subids::user_has_granted_linger("alice"), "…and reads back" );
    ok( ea_podman::subids::record_linger_grant("alice"),    "recording it again is fine" );

    ok( ea_podman::subids::revoke_linger_grant("alice"),     "and it can be given up" );
    ok( !ea_podman::subids::user_has_granted_linger("alice"), "…leaving no record" );
    ok( ea_podman::subids::revoke_linger_grant("alice"),     "revoking what is not there is not a failure" );

    ok( !ea_podman::subids::record_linger_grant("root"), "root is never recorded — its linger is not ours to take" );
    ok( !ea_podman::subids::user_has_granted_linger("root") );

    ok( !ea_podman::subids::record_linger_grant(undef),     "nor is no account at all" );
    ok( !ea_podman::subids::user_has_granted_linger(undef), "…which never has a record" );
    ok( !ea_podman::subids::user_has_granted_linger(""),    "nor does the empty string" );
};

subtest 'the grant record is made in a directory only root can read' => sub {
    plan skip_all => "creating the record dir with its real permissions needs root" if $> != 0;

    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp );

    # As it would be on a real server: not there yet.
    my $dir = "$tmp/made-on-demand/granted-linger";
    Path::Tiny::path("$tmp/made-on-demand")->mkpath;
    {
        no warnings qw(once);
        $ea_podman::subids::dir_granted_linger = $dir;
    }

    ok( ea_podman::subids::record_linger_grant("alice"), "the record dir is created on demand" );
    ok( -d $dir, "…and is there" );
    is( sprintf( "%04o", ( stat($dir) )[2] & 07777 ), "0700", "…root only" );
};

# A record outlives the linger it was written for. (CPANEL-55309)
subtest 'a grant record only covers the linger it was written for' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, lingering => ["alice"], granted => ["alice"] );

    ok( ea_podman::subids::grant_covers_current_linger("alice"), "a record written for the linger in place covers it" );

    ok( !ea_podman::subids::grant_covers_current_linger("bob"), "no record, nothing covered" );

    # An admin disables our linger, then re-enables one of their own.
    unlink "$ea_podman::subids::dir_linger/alice";
    ok( !ea_podman::subids::grant_covers_current_linger("alice"), "a record with no linger at all covers nothing" );

    _touch_at( "$ea_podman::subids::dir_linger/alice", time + 60 );
    ok( !ea_podman::subids::grant_covers_current_linger("alice"), "…nor does it cover a linger enabled after it" );

    # The ordinary case: both written together.
    _touch_at( "$ea_podman::subids::dir_linger/alice",         1000 );
    _touch_at( "$ea_podman::subids::dir_granted_linger/alice", 1000 );
    ok( ea_podman::subids::grant_covers_current_linger("alice"), "the same timestamp is ours — enable-linger then record" );
};

# Two of these paths are unlink()ed as root; the guard keeps a `..` out.
subtest 'an implausible account name is never turned into a path' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, lingering => ["alice"], granted => ["alice"] );

    # The escape that would matter: reaching back out of the marker directory.
    my $escape = "../../../../etc/passwd";

    ok( !ea_podman::subids::user_has_linger($escape),         "no linger is ever found for one" );
    ok( !ea_podman::subids::user_has_granted_linger($escape), "nor a grant record" );
    ok( !ea_podman::subids::record_linger_grant($escape),     "nothing is recorded for one" );

    ok( ea_podman::subids::revoke_linger_grant($escape), "revoking is a no-op…" );
    ok( -e "/etc/passwd", "…and unlinked nothing" );

    ok( ea_podman::subids::remove_stale_linger_marker($escape), "so is removing a stale marker…" );
    ok( -e "/etc/passwd", "…which also unlinked nothing" );

    ok( !ea_podman::subids::_is_valid_linger_user(undef), "no account name at all" );
    ok( !ea_podman::subids::_is_valid_linger_user(""),    "nor the empty string" );
    ok( !ea_podman::subids::_is_valid_linger_user("a/b"), "nor one with a path separator" );
    ok( !ea_podman::subids::_is_valid_linger_user(".hid"), "nor one that starts with a dot" );
    ok( ea_podman::subids::_is_valid_linger_user("cptest1"),   "an ordinary cPanel account is fine" );
    ok( ea_podman::subids::_is_valid_linger_user("a.b-c_d99"), "…as are the punctuation cPanel allows" );
};

subtest 'a stale grant record does not release somebody else’s linger' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world( tmp => $tmp, lingering => ["alice"], granted => ["alice"], users => ["alice"] );

    _touch_at( "$ea_podman::subids::dir_linger/alice", time + 60 );    # re-enabled after our grant

    ok( !ea_podman::util::release_user_session_as_root("alice"), "the release is refused" );
    ok( ea_podman::subids::user_has_linger("alice"), "…and the linger is left alone" );
    is_deeply( $disabled, [], "loginctl is never called" );
};

subtest 'ensure_user only bootstraps a session for an account that needs one' => sub {
    plan skip_all => "the root branch of ensure_user() needs root" if $> != 0;

    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, containers => [ { name => "redis.bob.01", user => "bob" } ] );

    my @ensured;

    no warnings qw(redefine once);
    local *ea_podman::subids::ensure_user_root = sub {
        my ( $user, $num_uids, $session ) = @_;
        push @ensured, { user => $user, session => $session };
        return;
    };

    is( ea_podman::util::ensure_user(), 0, "no session for a root that has no containers" );
    is( $ensured[-1]{user},    "root", "the subids are still ensured" );
    is( $ensured[-1]{session}, 0,      "the linger is not" );

    is( ea_podman::util::ensure_user(1), 1, "…unless it is installing its first one" );
    is( $ensured[-1]{session}, 1 );

    is( ea_podman::util::ensure_user( 1, 1 ), 1, "a WebApp deployment gets its session too" );
    ok( !ea_podman::subids::user_has_granted_linger("root"), "but root’s linger is never recorded as ours" );

    ea_podman::util::register_container_as_root( "redis.root.01", "root", 0, "redis:7", 0 );
    is( ea_podman::util::ensure_user(), 1, "an account with containers keeps its session ensured" );
    is( $ensured[-1]{session}, 1 );
};

subtest 'ensure_su_login only insists on a runtime dir when a session was set up' => sub {
    plan skip_all => "switching the effective uid needs root" if $> != 0;

    my $uid = 65500;    # a uid with no /run/user of its own
    plan skip_all => "uid $uid unexpectedly has a runtime dir" if -d "/run/user/$uid";

    local %ENV = %ENV;
    local $>   = $uid;

    delete $ENV{XDG_RUNTIME_DIR};
    delete $ENV{DBUS_SESSION_BUS_ADDRESS};

    my $ok = eval { ea_podman::util::ensure_su_login(0); 1 };
    ok( $ok, "an account that was never given a session is not an error" ) or diag($@);
    ok( !exists $ENV{XDG_RUNTIME_DIR},        "XDG_RUNTIME_DIR is not left pointing at a directory that is not there" );
    ok( !exists $ENV{DBUS_SESSION_BUS_ADDRESS}, "nor is the bus address" );

    is_deeply( ea_podman::util::get_containers(), {}, "and podman is not asked about an account that cannot be running anything" );

    # A session WAS expected: keep the CPANEL-54037 diagnostic, which the CageFS
    # fallback in ea-podman.pl matches on.
    delete $ENV{XDG_RUNTIME_DIR};
    eval { ea_podman::util::ensure_su_login(1); };
    like( $@, qr/rootless runtime directory .* does not exist/, "a missing session that should be there still fails loudly" );
};

subtest 'creating a container always establishes the session, whatever the caller did' => sub {
    plan skip_all => "switching the effective uid needs root" if $> != 0;

    my $uid = 65500;
    plan skip_all => "uid $uid unexpectedly has a runtime dir" if -d "/run/user/$uid";

    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp );

    my @forced;

    no warnings qw(redefine once);
    local *ea_podman::util::ensure_user = sub { push @forced, [@_]; return 1; };
    local *ea_podman::util::ensure_su_login = sub { return; };

    # The cPanel webapp plugin primes its own runtime dir and calls straight
    # into install_container, so it never tells init_user() it is creating
    # anything. The account must still end up lingering.
    local %ENV = %ENV;
    local $>   = $uid;

    ea_podman::util::ensure_container_session();
    is_deeply( \@forced, [ [1] ], "the session is forced for whoever is creating a container" );
};

subtest 'an account that already has its session is not asked again' => sub {
    plan skip_all => "needs root to read a real linger marker" if $> != 0;

    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, lingering => [ scalar getpwuid($>) ] );

    my @forced;
    my $asked_webapp = 0;

    no warnings qw(redefine once);
    local *ea_podman::util::ensure_user = sub { push @forced, [@_]; return 1; };

    # root lingering + /run/user/0 present ➜ nothing to do.
    if ( -d "/run/user/$>" ) {
        ea_podman::util::ensure_container_session( sub { $asked_webapp++; return 1 } );
        is_deeply( \@forced, [], "no privileged round trip when the session is already up" );
        is( $asked_webapp, 0, "and not even a registry lookup to work out whose linger it would be" );
    }
    else {
        plan skip_all => "no /run/user/$> on this host";
    }
};

subtest 'a WebApp linger is given back when there is nothing left to run' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp       => $tmp,
        lingering => ["alice"],
        granted   => ["alice"],
        users     => ["alice"],
    );

    ok( ea_podman::util::release_user_session_as_root("alice"), "the release happens" );
    is_deeply( $disabled, ["alice"], "loginctl disable-linger was called for exactly that account" );
    ok( !ea_podman::subids::user_has_linger("alice"), "and the account no longer lingers" );
    ok( !ea_podman::subids::user_has_granted_linger("alice"), "the grant goes with it, so a future linger is not mistaken for ours" );
};

subtest 'a linger ea-podman did not grant is never touched' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp       => $tmp,
        lingering => [ "alice", "erin" ],
        granted   => ["erin"],                 # erin’s is ours, alice’s is somebody else’s
        users     => [ "alice", "erin" ],
    );

    ok( !ea_podman::util::release_user_session_as_root("alice"), "an account lingering for reasons of its own keeps it" );
    is_deeply( $disabled, [], "loginctl was never called" );
    ok( ea_podman::subids::user_has_linger("alice"), "alice still lingers" );

    ok( ea_podman::util::release_user_session_as_root("erin"), "…while the one we granted is released" );
    is_deeply( $disabled, ["erin"] );
};

subtest 'release_user_session_as_root leaves alone what is not ours to take' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp            => $tmp,
        lingering      => [ "root", "bob", "carol", "dave" ],
        granted        => [ "root", "bob", "carol", "dave", "erin" ],
        users          => [ "bob", "carol", "dave" ],
        containers     => [ { name => "wordpress.bob.01", user => "bob", webapp => 1 } ],
        container_dirs => [ { name => "leftover.carol.01", user => "carol" } ],
    );

    ok( !ea_podman::util::release_user_session_as_root("root"),  "root is never released" );
    ok( !ea_podman::util::release_user_session_as_root("bob"),   "nor is an account that still has a registered container" );
    ok( !ea_podman::util::release_user_session_as_root("carol"), "nor one with a live container dir, whatever the registry says" );
    ok( !ea_podman::util::release_user_session_as_root("erin"),  "nor one that is not lingering in the first place" );
    ok( !ea_podman::util::release_user_session_as_root(undef),   "nor no account at all" );

    is_deeply( $disabled, [], "loginctl was never called" );
    ok( ea_podman::subids::user_has_linger($_), "$_ still lingers" ) for qw(root bob carol);

    # A removed container’s dir is renamed to <name>.bak, which must not count.
    Path::Tiny::path("$main::homedir_for{dave}/ea-podman.d/gone.dave.01.bak")->mkpath;
    ok( ea_podman::util::release_user_session_as_root("dave"), "a .bak dir is a removed container, not a live one" );
};

subtest 'a container the account installed itself keeps the linger too' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp        => $tmp,
        lingering  => ["frank"],
        granted    => ["frank"],
        users      => ["frank"],
        containers => [ { name => "redis.frank.01", user => "frank", webapp => 0 } ],
    );

    # The WebApp that got frank his linger is gone, but the container he installed
    # himself would stop at the next logout/reboot without it.
    ok( !ea_podman::util::release_user_session_as_root("frank"), "the release is declined while anything is still registered" );
    is_deeply( $disabled, [], "loginctl was never called" );
    ok( ea_podman::subids::user_has_linger("frank"), "frank still lingers" );
    ok( ea_podman::subids::user_has_granted_linger("frank"), "and the grant is kept for when he has nothing left" );
};

subtest 'release_user_session_as_root reports a linger that will not go away' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, lingering => ["alice"], granted => ["alice"], users => ["alice"] );

    $ea_podman::subids::linger_disabler = sub { return 1 };    # claims success, changes nothing

    my $warning = '';
    my $rv;
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        $rv = ea_podman::util::release_user_session_as_root("alice");
    }

    ok( !$rv, "the caller is told it did not work" );
    like( $warning, qr/Could not disable linger for/, "and it is reported" );
    like( $warning, qr/alice/,                        "naming the account" );
    ok( ea_podman::subids::user_has_granted_linger("alice"), "the grant is kept, since the linger is still ours" );
};

subtest 'release_user_session does nothing while a restore is in flight' => sub {
    plan skip_all => "the root branch of release_user_session() needs root" if $> != 0;

    my @asked;

    no warnings qw(redefine once);
    local *ea_podman::util::release_user_session_as_root = sub { push @asked, $_[0]; return 1; };

    # perform_user_restore() removes every container and puts them straight
    # back, so the session has to stay up across that.
    {
        local $ENV{EA_PODMAN_KEEP_USER_SESSION} = 1;

        is( ea_podman::util::release_user_session(), 0, "the release is declined" );
        is_deeply( \@asked, [], "it does not even ask" );
    }

    delete local $ENV{EA_PODMAN_KEEP_USER_SESSION};
    ea_podman::util::release_user_session();
    is( scalar @asked, 1, "an ordinary removal still releases" );
};

subtest 'a deleted account does not keep a linger we granted it' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp        => $tmp,
        lingering  => ["gone"],
        granted    => ["gone"],
        containers => [ { name => "wordpress.gone.01", user => "gone", webapp => 1 } ],
    );

    # No homedir entry for "gone" ➜ the mocked getpwnam says the account is gone.
    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "wordpress.gone.01", user => "gone" } );

    ok( !ea_podman::subids::user_has_linger("gone"), "the stale marker is removed" );
    ok( !ea_podman::subids::user_has_granted_linger("gone"), "and so is our record of it" );
    is_deeply( $disabled, [], "loginctl is never asked to look up an account that no longer exists" );
};

subtest 'a deleted account keeps a linger we did not grant it' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp        => $tmp,
        lingering  => ["gone"],
        containers => [ { name => "redis.gone.01", user => "gone" } ],
    );

    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "redis.gone.01", user => "gone" } );

    ok( ea_podman::subids::user_has_linger("gone"), "the marker is left where it is — it was never ours" );
    is_deeply( $disabled, [], "and loginctl was not called either" );
};

# It only deregisters — the container dirs stay — so _user_has_container_dirs()
# refuses. Without them in the fixture this passes for the wrong reason.
subtest 'an account only assumed deleted keeps the linger its container dirs need' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp            => $tmp,
        lingering      => ["stillhere"],
        granted        => ["stillhere"],
        users          => ["stillhere"],
        containers     => [ { name => "wordpress.stillhere.01", user => "stillhere", webapp => 1 } ],
        container_dirs => [ { name => "wordpress.stillhere.01", user => "stillhere" } ],
    );

    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "wordpress.stillhere.01", user => "stillhere" } );

    is_deeply( $disabled, [], "the account still exists and its container dir is still on disk, so nothing is disabled" );
    ok( ea_podman::subids::user_has_linger("stillhere"),         "the linger stays" );
    ok( ea_podman::subids::user_has_granted_linger("stillhere"), "and so does our record, for when the dir does go" );
};

# Same branch once the dir really has gone: the ordinary release applies.
subtest 'an account only assumed deleted is released once nothing is left' => sub {
    my $tmp = File::Temp->newdir();
    my $disabled = _mock_world(
        tmp        => $tmp,
        lingering  => ["stillhere"],
        granted    => ["stillhere"],
        users      => ["stillhere"],
        containers => [ { name => "wordpress.stillhere.01", user => "stillhere", webapp => 1 } ],
    );

    ea_podman::util::remove_containers_for_a_deleted_user( { container_name => "wordpress.stillhere.01", user => "stillhere" } );

    is_deeply( $disabled, ["stillhere"], "the account still exists, so loginctl does the work" );
    ok( !ea_podman::subids::user_has_linger("stillhere"),         "and the linger is gone" );
    ok( !ea_podman::subids::user_has_granted_linger("stillhere"), "along with our record of it" );
};

# The session is granted before _ensure_latest_container() can die with nothing
# registered, leaving an account lingering over nothing. (CPANEL-55309)
subtest 'a failed install hands back the session it was given' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, lingering => ["alice"], granted => ["alice"], users => ["alice"] );

    no warnings qw(redefine once);
    local *ea_podman::util::get_next_available_container_name = sub { return "boom.alice.01" };
    local *ea_podman::util::_ensure_latest_container          = sub { die "could not allocate ports\n" };

    my $released = 0;
    local *ea_podman::util::release_user_session = sub { $released++; return 1 };

    local $@;
    ok( !eval { ea_podman::util::install_container("boom"); 1 }, "the install still fails" );
    is( $@,        "could not allocate ports\n", "…with the original error, not a cleanup one" );
    is( $released, 1,                            "and the session is handed back once" );
};

subtest 'a release that fails does not mask the install error' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp );

    no warnings qw(redefine once);
    local *ea_podman::util::get_next_available_container_name = sub { return "boom.alice.01" };
    local *ea_podman::util::_ensure_latest_container          = sub { die "the real problem\n" };
    local *ea_podman::util::release_user_session              = sub { die "and a second one\n" };

    local $@;
    my $warned = "";
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    ok( !eval { ea_podman::util::install_container("boom"); 1 }, "the install fails" );
    is( $@, "the real problem\n", "…reporting what actually went wrong" );
    like( $warned, qr/Could not release the rootless session/, "the cleanup failure is warned about, not thrown" );
};

# Catches the cleanup being wired up too eagerly.
subtest 'a successful install keeps its session' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp );

    no warnings qw(redefine once);
    local *ea_podman::util::get_next_available_container_name = sub { return "fine.alice.01" };
    local *ea_podman::util::_ensure_latest_container          = sub { return 1 };

    my $released = 0;
    local *ea_podman::util::release_user_session = sub { $released++; return 1 };

    is( ea_podman::util::install_container("fine"), "fine.alice.01", "the container name comes back" );
    is( $released,                                  0,               "and nothing is released" );
};

# The three subtests above stub _ensure_latest_container() outright, which is
# what let the operation dispatch inside it break unnoticed: it used to read
# caller(1), and wrapping install_container()’s call in an eval put an “(eval)”
# frame there instead, so every install died before doing any work. This one
# keeps the real function and stubs only the cheap checks ahead of the dispatch.
# (CPANEL-55309)
subtest 'every creation path gets past the operation dispatch' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp );

    no warnings qw(redefine once);
    local *ea_podman::util::get_next_available_container_name  = sub { return "dispatch.alice.01" };
    local *ea_podman::util::warn_if_problematic_cgroup         = sub { return 1 };
    local *ea_podman::util::validate_user_container_name       = sub { return 1 };
    local *ea_podman::util::ensure_container_session           = sub { return 1 };
    local *ea_podman::util::_ensure_backup_conf_excludes_files = sub { return 1 };
    local *ea_podman::util::release_user_session               = sub { return 1 };

    # _get_container_root() is the first thing past the dispatch, so reaching it
    # is the assertion. Checking the die message instead would pass for free the
    # day the message changes, which is how this went unnoticed the first time.
    my $got_past_dispatch = 0;
    local *ea_podman::util::_get_container_root = sub { $got_past_dispatch++; return "$tmp/never-here" };

    for my $case (
        [ "install", sub { ea_podman::util::install_container("dispatch") } ],
        [ "upgrade", sub { ea_podman::util::upgrade_container("dispatch.alice.01") } ],
        [ "restore", sub { ea_podman::util::restore_containers_for_user( { container_name => "dispatch.alice.01" } ) } ],
    ) {
        my ( $name, $run ) = @{$case};

        $got_past_dispatch = 0;
        local $@;
        eval { $run->(); 1 };    # dies further along on the empty scratch dir, which is fine
        is( $got_past_dispatch, 1, "$name reaches the work, whatever the call stack looks like" );
    }
};

# The release is worth nothing if our own record ages out of covering the linger
# it granted. `loginctl enable-linger` re-touches $dir_linger/<user> even for an
# account that already lingers (systemd 252 touch_file() ➜ futimens(fd, NULL) ➜
# now), and ensure_user_session() runs for every command an account with
# containers makes — so a blind re-enable pushed systemd's marker past our grant
# and the last container never gave the linger back. The stubbed enabler here
# does what systemd does and touches the marker; a stub that does not touch it
# cannot catch this, which is how it went unnoticed. (CPANEL-55309)
subtest 'a redundant enable-linger does not age our grant out of covering it' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, users => ["bob"], lingering => ["bob"], granted => ["bob"] );

    # A session that is already up: lingering, runtime dir, and the user
    # manager's bus, which is all ensure_user_session() exists to establish.
    local $ea_podman::subids::dir_run = "$tmp/run-user";
    Path::Tiny::path("$tmp/run-user/11002")->mkpath;
    Path::Tiny::path("$tmp/run-user/11002/bus")->touch;

    my $marker = "$ea_podman::subids::dir_linger/bob";
    my $grant  = "$ea_podman::subids::dir_granted_linger/bob";

    # Recorded just after the linger it is for, the way ENSURE_USER writes it.
    _touch_at( $marker, time - 100 );
    _touch_at( $grant,  time - 99 );
    ok( ea_podman::subids::grant_covers_current_linger("bob"), "the grant covers the linger to begin with" );

    my $enables = 0;
    no warnings qw(redefine once);
    local $ea_podman::subids::linger_enabler = sub {
        $enables++;
        Path::Tiny::path($marker)->touch;    # systemd moves its marker to now, even when already lingering
        return 1;
    };

    ea_podman::subids::ensure_user_session("bob") for 1 .. 3;

    is( $enables, 0, "enable-linger is not re-run for an account whose session is already up" );
    ok( ea_podman::subids::grant_covers_current_linger("bob"), "so the grant still covers the linger in place" );
    ok( ea_podman::util::_user_session_is_releasable("bob"),   "and the last container can still give the linger back" );
};

subtest 'a linger we do have to re-enable keeps our grant covering it' => sub {
    my $tmp = File::Temp->newdir();
    _mock_world( tmp => $tmp, users => ["bob"], lingering => ["bob"], granted => ["bob"] );

    # Lingering, but with no runtime dir: the stale state CPANEL-54037 is about,
    # where the session really does have to be re-established.
    local $ea_podman::subids::dir_run = "$tmp/run-user";

    my $marker = "$ea_podman::subids::dir_linger/bob";
    my $grant  = "$ea_podman::subids::dir_granted_linger/bob";
    _touch_at( $marker, time - 100 );
    _touch_at( $grant,  time - 99 );

    my $enables = 0;
    no warnings qw(redefine once);
    local $ea_podman::subids::linger_enabler = sub {
        $enables++;
        Path::Tiny::path($marker)->touch;                        # systemd's marker moves to now
        Path::Tiny::path("$tmp/run-user/11002")->mkpath;         # and the session comes up
        Path::Tiny::path("$tmp/run-user/11002/bus")->touch;
        return 1;
    };

    ea_podman::subids::ensure_user_session("bob");

    is( $enables, 1, "the session is re-established when its runtime dir is gone" );
    ok( ea_podman::subids::grant_covers_current_linger("bob"), "and the grant moves with the linger it is still for" );
    ok( ea_podman::util::_user_session_is_releasable("bob"),   "so the release is not lost to the repair" );
};

done_testing();
