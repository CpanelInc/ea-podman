#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-upgrade-rollback.t       Copyright 2026 WebPros International, LLC
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
    *CORE::GLOBAL::getpwuid = sub {
        my ($uid) = @_;
        return ( "bob", "x", $uid, $uid, "", "", "", $main::HOMEDIR, "/bin/bash" );
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-325. uninstall_container() runs BEFORE the create, so by the time
# `podman create` is attempted the old container and its unit are already gone.
# Two things went wrong from there:
#
#   * the registry was overwritten with the new image and pkg_version before the
#     create, so a failed upgrade left it asserting a container that did not
#     exist at a version never created, and the previous values survived nowhere;
#   * the cleanup branch was gated `if ( !$isupgrade )`, which is true for a
#     RESTORE — so a failed restore deregistered the container and deleted the
#     directory perform_user_restore() had just untarred from the user's backup.

no warnings 'once';

# A scratch world with one arbitrary-image container already "installed".
sub _world {
    my (%opts) = @_;

    my $tmp = File::Temp->newdir();
    $main::HOMEDIR = "$tmp";

    my $name = "myapp.bob.01";
    my $dir  = "$tmp/ea-podman.d/$name";
    mkdir "$tmp/ea-podman.d";
    mkdir $dir;

    open( my $fh, ">", "$dir/ea-podman.json" ) or die $!;
    print {$fh} qq({"start_args":["-e","FOO=bar","docker.io/library/httpd:2.4"],"ports":["80"]});
    close $fh;

    return ( $tmp, $name, $dir );
}

# Everything _ensure_latest_container() touches that needs podman, systemd, the
# adminbin or the registry. Returns a log the subtests assert against.
sub _harness {
    my (%opts) = @_;

    my %log = ( registered => [], deregistered => [], created => [], removed => [], generated => 0, started => 0, uninstalled => 0 );

    no warnings 'redefine';
    *ea_podman::util::warn_if_problematic_cgroup        = sub { 1 };
    *ea_podman::util::ensure_container_session          = sub { 1 };
    *ea_podman::util::_ensure_backup_conf_excludes_files = sub { 1 };
    *ea_podman::util::_arbitrary_image_warning          = sub { 1 };
    *ea_podman::util::_get_container_root               = sub { "$main::HOMEDIR/ea-podman.d" };
    *ea_podman::util::_get_current_ports                = sub { return (10000) };
    *ea_podman::util::_get_new_ports                    = sub { return (10000) };
    *ea_podman::util::validate_start_args               = sub { 1 };
    *ea_podman::util::uninstall_container               = sub { $log{uninstalled}++; 1 };
    *ea_podman::util::remove_user_container             = sub { push @{ $log{removed} }, $_[0]; 1 };
    *ea_podman::util::register_container                = sub { push @{ $log{registered} }, [@_]; 1 };
    *ea_podman::util::deregister_container              = sub { push @{ $log{deregistered} }, $_[0]; 1 };
    *ea_podman::util::generate_container_service        = sub { $log{generated}++; 1 };
    *ea_podman::util::reset_container_unit_failure      = sub { 1 };
    *ea_podman::util::sysctl                            = sub { $log{started}++; 1 };
    *ea_podman::util::_get_container_image_ref          = sub { $opts{prev_image} };

    # Increment B taught the upgrade path to PULL and then compare image IDs, and
    # this harness predates it -- so from B until now every run of this "unit"
    # test shelled out to Docker Hub for real. It passed only because the pull
    # happened to succeed; on a rate-limited or offline host it dies before the
    # first assertion. Mock the three seams B added. The IDs differ on purpose:
    # these subtests are about what happens AFTER the gate says "recreate".
    *ea_podman::util::_podman_pull                     = sub { 1 };
    *ea_podman::util::_get_image_id                    = sub { "sha-new" };
    *ea_podman::util::_get_container_image_id          = sub { exists $opts{prev_image_id} ? $opts{prev_image_id} : "sha-old" };

    my @create_results = @{ $opts{creates} || [1] };
    *ea_podman::util::create_user_container = sub {
        my ( $n, @args ) = @_;
        push @{ $log{created} }, [@args];
        return @create_results ? shift(@create_results) : 0;
    };

    return \%log;
}

subtest 'a successful upgrade registers AFTER the create, not before' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( creates => [1], prev_image => "docker.io/library/httpd:2.3" );

    ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } );

    is( scalar @{ $log->{registered} }, 1, "registered exactly once" );
    is( scalar @{ $log->{created} },    1, "created exactly once" );
    is( $log->{generated}, 1, "the unit was regenerated" );
};

subtest 'an install still registers BEFORE the create' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( creates => [1] );

    # A container with no registry entry is invisible to the removal hooks and
    # leaks its ports, so install keeps register-before-create deliberately.
    ea_podman::util::_ensure_latest_container( "fresh.bob.02", { op => "install" }, "docker.io/library/httpd:2.4" );

    is( scalar @{ $log->{registered} }, 1, "install registered" );
    is( $log->{registered}[0][1], 0, "and not with the isupgrade flag" );
};

subtest 'a failed upgrade never deregisters and never removes the container dir' => sub {
    my ( $tmp, $name, $dir ) = _world();

    # First create fails; the rollback's create also fails.
    my $log = _harness( creates => [ 0, 0 ], prev_image => "docker.io/library/httpd:2.3" );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) }; $@ };

    like( $err, qr/Failed to upgrade/, "it raises" );
    is_deeply( $log->{deregistered}, [], "nothing was deregistered" );
    ok( -d $dir, "the container directory survives" );
    ok( -e "$dir/ea-podman.json", "and so do its persisted start args" );
};

subtest 'a failed upgrade leaves the registry describing the old container' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( creates => [ 0, 0 ], prev_image => "docker.io/library/httpd:2.3" );

    eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) };

    is_deeply( $log->{registered}, [], "the registry was never written, so it still says what it said before" );
};

subtest 'the rollback recreates with the image the container was actually running' => sub {
    my ( $tmp, $name, $dir ) = _world();

    # The upgrade's create fails; the rollback's create succeeds.
    my $log = _harness( creates => [ 0, 1 ], prev_image => "docker.io/library/httpd:2.3", prev_image_id => "sha-old" );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) }; $@ };

    is( scalar @{ $log->{created} }, 2, "it tried again exactly once" );
    is( $log->{created}[0][-1], "docker.io/library/httpd:2.4", "the upgrade used the new image" );
    is( $log->{created}[1][-1], "sha-old", "the rollback pinned back to the previous IMAGE, by ID" );
    is_deeply( $log->{removed}, [$name], "the half-made container was cleared out of the way first" );

    like( $err, qr/is running again/,        "it says service is restored" );
    like( $err, qr/the upgrade did not happen/, "but is explicit that the upgrade did not happen" );
    like( $err, qr/docker\.io\/library\/httpd:2\.3/, "and names the reference, which is what a reader recognises" );
};

# The case that made the ID necessary, and the one no test could see while the
# rollback pinned the reference: the container tracks a tag, the pull moved that
# tag, so the reference the container was created from and the reference the
# upgrade is creating from are the SAME STRING. Pinning it recreates the
# container on the image that just arrived while claiming the opposite.
subtest 'a rollback of a tag-tracking container does not land on the image just pulled' => sub {
    my ( $tmp, $name, $dir ) = _world();

    # prev_image is identical to the configured image, as a moved tag makes it.
    my $log = _harness( creates => [ 0, 1 ], prev_image => "docker.io/library/httpd:2.4", prev_image_id => "sha-old" );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) }; $@ };

    is( $log->{created}[0][-1], "docker.io/library/httpd:2.4", "the upgrade created from the tag" );
    isnt( $log->{created}[1][-1], "docker.io/library/httpd:2.4", "the rollback did NOT create from that same tag" );
    is( $log->{created}[1][-1], "sha-old", "it pinned the image the container had been running" );
    like( $err, qr/the exact image it had been running/, "and the message can say so without qualification" );
};

# No ID but a reference we can still use. Better than nothing -- an operator may
# have edited the persisted image -- but the wording must not promise it is the
# same image, because a moved tag means it is not.
subtest 'a reference with no ID is pinned, but claimed only as a reference' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( creates => [ 0, 1 ], prev_image => "docker.io/library/httpd:2.3", prev_image_id => undef );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) }; $@ };

    is( $log->{created}[1][-1], "docker.io/library/httpd:2.3", "the reference is used when there is no ID" );
    like( $err,   qr/could not report the image ID/,      "and the message says the ID was unavailable" );
    unlike( $err, qr/the exact image it had been running/, "so it never claims to be the same image" );
};

subtest 'an unknown previous image recreates with the args as given, and says so' => sub {
    my ( $tmp, $name, $dir ) = _world();
    my $log = _harness( creates => [ 0, 1 ], prev_image => undef, prev_image_id => undef );

    my $err = do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => "upgrade" } ) }; $@ };

    is( $log->{created}[1][-1], "docker.io/library/httpd:2.4", "nothing to pin back, so the args stand" );
    like( $err, qr/nothing to pin back/, "and the message admits it" );
};

subtest 'the message never claims more recovery than happened' => sub {
    my $status_none    = { created => 0, enabled => 0, started => 0 };
    my $status_created = { created => 1, enabled => 0, started => 0 };
    my $status_enabled = { created => 1, enabled => 1, started => 0 };
    my $status_all     = { created => 1, enabled => 1, started => 1 };

    my @args = ( "myapp.bob.01", "/home/bob/ea-podman.d/myapp.bob.01", "docker.io/library/httpd:2.3", "sha256:0123456789abcdef" );

    like( ea_podman::util::_failed_upgrade_message( @args, $status_none ),    qr/could not be recreated/,       "nothing recovered" );
    like( ea_podman::util::_failed_upgrade_message( @args, $status_created ), qr/could not be enabled/,         "created but not enabled" );
    like( ea_podman::util::_failed_upgrade_message( @args, $status_enabled ), qr/unit did not start/,           "enabled but not started" );
    like( ea_podman::util::_failed_upgrade_message( @args, $status_all ),     qr/is running again/,             "fully recovered" );

    for my $status ( $status_none, $status_created, $status_enabled, $status_all ) {
        my $msg = ea_podman::util::_failed_upgrade_message( @args, $status );
        like( $msg, qr/Nothing was deregistered and nothing was deleted/, "every level promises nothing was destroyed" );
        like( $msg, qr/ea-podman upgrade myapp\.bob\.01/,                 "every level names the retry" );
    }
};

subtest 'a fully recovered rollback still warns the container dir was not rolled back' => sub {
    my $msg = ea_podman::util::_failed_upgrade_message(
        "myapp.bob.01", "/home/bob/ea-podman.d/myapp.bob.01", "docker.io/library/httpd:2.3", "sha256:0123456789abcdef",
        { created => 1, enabled => 1, started => 1 },
    );

    like( $msg, qr/was NOT rolled back/,            "says the directory was not reverted" );
    like( $msg, qr/ea-podman-local-dir-upgrade/,    "and why — the hook has no reverse step" );
};

done_testing();
