#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea_podman/subids.pm                     Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

package ea_podman::subids;

use Path::Tiny 'path';
use Cpanel::OS;
use Time::HiRes ();

our $good = "✅";
our $bad  = "❌";

# FOR Testability
our $file_subuid = "/etc/subuid";
our $file_subgid = "/etc/subgid";
our $dir_run     = "/run/user";

sub ensure_user_root {
    my ( $user, $num_uids ) = @_;

    $num_uids = 65537 if !$num_uids;

    _ensure_subids( $user, $num_uids );

    # Always (idempotently) ensure the user’s rootless session, not just on
    # first subid setup: linger may have been torn down since (e.g. a stale
    # state or an explicit `loginctl disable-linger`), which would leave a
    # registered user with no runtime dir. (CPANEL-54037)
    ensure_user_session($user);

    # Tell podman to ignore uid/gid issues
    _ensure_storage_conf();

    return;
}

# Allocate /etc/subuid + /etc/subgid ranges for the user, unless they already
# have both. New ranges start at 190000 (or just past the highest existing
# allocation, whichever is greater).
sub _ensure_subids {
    my ( $user, $num_uids ) = @_;

    my $subuid = get_subuids();
    my $subgid = get_subgids();

    if ( !( exists $subuid->{$user} && exists $subgid->{$user} ) ) {

        # via the mechanics this means the uids/gids start at 190000
        my $getuid_max = 190000 - $num_uids;
        my $getgid_max = 190000 - $num_uids;

        foreach my $u ( keys %{$subuid} ) {
            my ( $uid, $range ) = split( /:/, $subuid->{$u} );
            $uid += $range;
            $getuid_max = $uid if ( $uid > $getuid_max );
        }

        foreach my $u ( keys %{$subgid} ) {
            my ( $uid, $range ) = split( /:/, $subgid->{$u} );
            $uid += $range;
            $getgid_max = $uid if ( $uid > $getgid_max );
        }

        $getuid_max++;
        $getgid_max++;

        my $num_uids_minus_one = $num_uids - 1;
        if ( !exists $subuid->{$user} ) {
            if ( open my $fh, ">>", $file_subuid ) {
                print $fh "$user:$getuid_max:$num_uids_minus_one\n";
                close $fh;
            }
        }

        if ( !exists $subgid->{$user} ) {
            if ( open my $fh, ">>", $file_subgid ) {
                print $fh "$user:$getgid_max:$num_uids_minus_one\n";
                close $fh;
            }
        }
    }

    if ( !exists $subgid->{$user} ) {
        if ( open my $fh, ">>", $file_subgid ) {
            print $fh "$user:$getgid_max:$num_uids_minus_one\n";
            close $fh;
        }
    }

    return;
}

# Bootstrap the user’s rootless-podman session *as root*. Historically
# ensure_user_root only did `mkdir /run/user/<uid>`, which left rootless
# podman without a running user systemd manager or dbus socket — so
# `podman generate systemd` + `systemctl --user` failed for any user without
# an interactive login (cpsrvd/UAPI, account hooks, `su -`). See CPANEL-54037
# (and UPS-504).
#
# `loginctl enable-linger <user>`, run as root, instead creates
# /run/user/<uid> as a tmpfs *and* starts user@<uid>.service (the user systemd
# manager), persisting both across logout/reboot — exactly what rootless
# container persistence requires. Held in a package variable so tests can
# stub the privileged call.
our $linger_enabler = \&_enable_linger;

sub _enable_linger {
    my ($user) = @_;
    system( "loginctl", "enable-linger", $user );
    return $? == 0;
}

sub ensure_user_session {
    my ($user) = @_;

    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    die "Could not look up the uid/gid for “$user”\n" if !defined $uid;

    mkdir $dir_run;    # parent /run/user; harmless when it already exists

    $linger_enabler->($user);

    # enable-linger is asynchronous: it returns *before* logind has finished
    # creating /run/user/<uid> AND starting user@<uid>.service. The readiness
    # signal that `systemctl --user` + rootless podman actually need is the
    # user manager’s dbus socket at /run/user/<uid>/bus — the directory itself
    # appears well before the manager is up, so polling only for the dir races
    # and leaves podman with “Failed to connect to user scope bus”. Poll for
    # the bus socket.
    my $rundir = "$dir_run/$uid";
    my $bus    = "$rundir/bus";
    for ( 1 .. 100 ) {
        last if -d $rundir && -e $bus;
        Time::HiRes::usleep(100_000);    # 0.1s × 100 ≈ 10s max
    }

    if ( !-d $rundir ) {
        die "The directory “$rundir” is missing and could not be created by `loginctl enable-linger $user`.\n";
    }
    if ( !-e $bus ) {
        die "The user session bus “$bus” did not appear after `loginctl enable-linger $user` (the user systemd manager did not start).\n";
    }

    return;
}

# Bootstrap the user’s rootless-podman session *as root*. Historically
# ensure_user_root only did `mkdir /run/user/<uid>`, which left rootless
# podman without a running user systemd manager or dbus socket — so
# `podman generate systemd` + `systemctl --user` failed for any user without
# an interactive login (cpsrvd/UAPI, account hooks, `su -`). See CPANEL-54037
# (and UPS-504).
#
# `loginctl enable-linger <user>`, run as root, instead creates
# /run/user/<uid> as a tmpfs *and* starts user@<uid>.service (the user systemd
# manager), persisting both across logout/reboot — exactly what rootless
# container persistence requires. Held in a package variable so tests can
# stub the privileged call.
our $linger_enabler = \&_enable_linger;

sub _enable_linger {
    my ($user) = @_;
    system( "loginctl", "enable-linger", $user );
    return $? == 0;
}

sub ensure_user_session {
    my ($user) = @_;

    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    die "Could not look up the uid/gid for “$user”\n" if !defined $uid;

    mkdir $dir_run;    # parent /run/user; harmless when it already exists

    $linger_enabler->($user);

    # enable-linger is asynchronous: it returns *before* logind has finished
    # creating /run/user/<uid> AND starting user@<uid>.service. The readiness
    # signal that `systemctl --user` + rootless podman actually need is the
    # user manager’s dbus socket at /run/user/<uid>/bus — the directory itself
    # appears well before the manager is up, so polling only for the dir races
    # and leaves podman with “Failed to connect to user scope bus”. Poll for
    # the bus socket.
    my $rundir = "$dir_run/$uid";
    my $bus    = "$rundir/bus";
    for ( 1 .. 100 ) {
        last if -d $rundir && -e $bus;
        Time::HiRes::usleep(100_000);    # 0.1s × 100 ≈ 10s max
    }

    if ( !-d $rundir ) {
        die "The directory “$rundir” is missing and could not be created by `loginctl enable-linger $user`.\n";
    }
    if ( !-e $bus ) {
        die "The user session bus “$bus” did not appear after `loginctl enable-linger $user` (the user systemd manager did not start).\n";
    }

    return;
}

sub assert_has_user_namespaces {
    my ($verbose) = @_;

    chomp( my $max_uns = `sysctl --values user.max_user_namespaces 2>/dev/null` );

    if ( !$max_uns ) {
        my $c7_msg = <<'C7';

    • On CentOS 7 running these command enable user namespaces:
        1. grubby --args="namespce.unpriv_enable=1 user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"
        2. echo "user.max_user_namespaces=15076" >> /etc/sysctl.conf
        3. reboot
C7
        chomp($c7_msg);

        # I wish there was a better way …
        my $os = -f '/etc/os-release' ? `source /etc/os-release; echo \$ID\$VERSION_ID` : "??";

        chomp($os);
        $c7_msg = "" if $os ne "centos7";

        die <<"END_NO_UNS";
$bad User Namespaces not available (`sysctl --values user.max_user_namespaces`):
    • Container based packages will not work until they are.
    • To learn more read `man user_namespaces`$c7_msg
END_NO_UNS
    }

    print "$good user.max_user_namespaces = '$max_uns'\n" if $verbose;

    return $max_uns;
}

sub get_subuids {
    return _parse_subid_file($file_subuid);
}

sub get_subgids {
    return _parse_subid_file($file_subgid);
}

###############
#### helpers ##
###############

sub _parse_subid_file {
    my ($file) = @_;

    my $hr = {};

    for my $line ( path($file)->lines( { chomp => 1 } ) ) {
        my ( $user, $ranges ) = split( ":", $line, 2 );
        warn "“$user” is in “$file” more than once!\n" if exists $hr->{$user};
        $hr->{$user} = $ranges;
    }

    return $hr;
}

sub _ensure_storage_conf {

    # This is only necessary on certain OS's.
    # UGMO:
    # Since we can only extend Cpanel::OS for new versions of ULC we can’t use a proper OS agnostic attribute like `if (Cpanel::OS::container_storage_overlay_ignore_chown_errors) { `
    # That being the case we have to violate the point of Cpanel::OS and do an isolated one off here :/
    if ( Cpanel::OS::distro() eq "ubuntu" && Cpanel::OS::major() eq "22" ) {
        my $conf = path('/etc/containers/storage.conf');

        if ( !$conf->exists() ) {
            $conf->spew(
                qq{[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
[storage.options]
    ignore_chown_errors = "true"
}
            );
        }
    }

    return;
}

1;
