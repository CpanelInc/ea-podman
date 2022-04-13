#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea_podman/subids.pm                     Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

package ea_podman::subids;

use Path::Tiny 'path';

our $good = "✅";
our $bad  = "❌";

sub ensure_user_root {
    my ( $user, $num_uids ) = @_;

    $num_uids = 65537 if !$num_uids;

    my $subuid = get_subuids();
    my $subgid = get_subgids();

    return if exists $subuid->{$user} && exists $subgid->{$user};

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
        if ( open my $fh, ">>", '/etc/subuid' ) {
            print $fh "$user:$getuid_max:$num_uids_minus_one\n";
            close $fh;
        }
    }

    if ( !exists $subgid->{$user} ) {
        if ( open my $fh, ">>", '/etc/subgid' ) {
            print $fh "$user:$getgid_max:$num_uids_minus_one\n";
            close $fh;
        }
    }

    # best effort
    mkdir "/run/user";
    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    mkdir( "/run/user/$uid", 0700 );
    chown( $uid, $gid, "/run/user/$uid" );
    if ( !-d "/run/user/$uid" ) {
        die "The directory “/run/user/$uid” is missing and could not be created (mode: 0700; owner & group: $user).\n";
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
        my $os = -f "/etc/os-release" ? `source /etc/os-release; echo \$ID\$VERSION_ID` : "??";
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
    return _parse_subid_file("/etc/subuid");
}

sub get_subgids {
    return _parse_subid_file("/etc/subgid");
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

1;