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
use Fcntl       qw(:flock);
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
# have both. A new range starts just past the highest existing allocation; on a
# host with no allocations at all the first one is placed so that it ends just
# below 190000.
#
# Read → compute → append has to happen under one lock, or two accounts
# bootstrapping at once claim the same range and their containers end up on the
# same host uids. One exclusive flock on $file_subuid covers both files: every
# allocation comes through here and always does the two together.
#
# It does not serialize against shadow-utils, which allocates from the same
# space under its own locking; the disjointness checks below cover that.
sub _ensure_subids {
    my ( $user, $num_uids ) = @_;

    # Opened first so the lock is held across everything below, and so a missing
    # file exists by the time it is read.
    open my $subuid_fh, ">>", $file_subuid or die "Could not open “$file_subuid”: $!\n";
    open my $subgid_fh, ">>", $file_subgid or die "Could not open “$file_subgid”: $!\n";

    flock( $subuid_fh, LOCK_EX ) or die "Could not lock “$file_subuid”: $!\n";

    my $subuid_ranges = _read_ranges($file_subuid);
    my $subgid_ranges = _read_ranges($file_subgid);

    my $has_subuid = @{ _user_ranges( $subuid_ranges, $user ) } ? 1 : 0;
    my $has_subgid = @{ _user_ranges( $subgid_ranges, $user ) } ? 1 : 0;

    # Already allocated is not the same as safely allocated: an older unlocked
    # version or a concurrent `useradd` may have put this range on top of
    # another account’s. Each half is checked on its own — a shared subuid range
    # is no better for having the missing subgid range filled in.
    _assert_range_is_exclusive( $user, $subuid_ranges, $file_subuid ) if $has_subuid;
    _assert_range_is_exclusive( $user, $subgid_ranges, $file_subgid ) if $has_subgid;

    return if $has_subuid && $has_subgid;

    # via the mechanics this means the uids/gids end just below 190000
    my $getuid_max = 190000 - $num_uids;
    my $getgid_max = 190000 - $num_uids;

    foreach my $range ( @{$subuid_ranges} ) {
        my $uid = $range->{start} + $range->{count};
        $getuid_max = $uid if ( $uid > $getuid_max );
    }

    foreach my $range ( @{$subgid_ranges} ) {
        my $gid = $range->{start} + $range->{count};
        $getgid_max = $gid if ( $gid > $getgid_max );
    }

    $getuid_max++;
    $getgid_max++;

    my $num_uids_minus_one = $num_uids - 1;

    # Checked, not assumed: highest-end-plus-one is only free if every line was
    # accounted for, and unparsable ones were not (see _read_ranges()).
    if ( !$has_subuid ) {
        _assert_allocation_is_free( $user, $getuid_max, $num_uids_minus_one, $subuid_ranges, $file_subuid );
        print {$subuid_fh} "$user:$getuid_max:$num_uids_minus_one\n" or die "Could not write to “$file_subuid”: $!\n";
    }

    if ( !$has_subgid ) {
        _assert_allocation_is_free( $user, $getgid_max, $num_uids_minus_one, $subgid_ranges, $file_subgid );
        print {$subgid_fh} "$user:$getgid_max:$num_uids_minus_one\n" or die "Could not write to “$file_subgid”: $!\n";
    }

    # A short write only surfaces on flush, and a truncated line here is worth
    # dying over. $subuid_fh closes last because that drops the lock.
    close $subgid_fh or die "Could not write to “$file_subgid”: $!\n";
    close $subuid_fh or die "Could not write to “$file_subuid”: $!\n";

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

# Every account in the file whose range is not exclusively its own, as
# user => why. These are the accounts _ensure_subids() refuses to act for, asked
# of the whole file at once so a box can be audited up front.
sub get_subuid_problems {
    return _find_range_problems($file_subuid);
}

sub get_subgid_problems {
    return _find_range_problems($file_subgid);
}

###############
#### helpers ##
###############

# Every well-formed allocation in $file, in file order, as
# { user => …, start => …, count => … }.
#
# _parse_subid_file() keeps one entry per account, which is all its callers want
# to display; allocation needs every line, since a duplicate’s IDs are just as
# taken as any other’s.
#
# Plain open rather than Path::Tiny: its readers take a shared flock, which
# would block on the exclusive lock _ensure_subids() already holds on this file.
sub _read_ranges {
    my ($file) = @_;

    # A file that does not exist has nothing allocated in it. Anything else has
    # to be fatal: treating an unreadable file as empty would hand out IDs an
    # account already holds.
    open my $fh, "<", $file or do {
        return [] if !-e $file;
        die "Could not read “$file”: $!\n";
    };

    my @ranges;

    while ( my $line = readline $fh ) {
        chomp $line;
        next if $line !~ m/\S/;

        my ( $user,  $ranges ) = split( ":", $line, 2 );
        my ( $start, $count )  = _parse_range($ranges);

        # A line this cannot parse is one it cannot reason about. Skipping it
        # keeps a hand-added comment from taking a working account offline; its
        # IDs going uncounted is why allocations are overlap-checked.
        next if !defined $count;

        push @ranges, { user => $user, start => $start, count => $count };
    }

    return \@ranges;
}

# The “<start>:<count>” half of a subid line, and only when it is one: a
# non-numeric, empty or zero-count range cannot take part in an overlap.
sub _parse_range {
    my ($ranges) = @_;

    return if !defined $ranges;

    my ( $start, $count ) = split( /:/, $ranges );

    return if !defined $start         || !defined $count;
    return if $start !~ m/\A[0-9]+\z/ || $count !~ m/\A[0-9]+\z/;
    return if $count == 0;

    return ( $start, $count );
}

sub _user_ranges {
    my ( $ranges_ar, $user ) = @_;

    return [ grep { $_->{user} eq $user } @{$ranges_ar} ];
}

# The first account holding IDs inside [$start, $start + $count - 1], ignoring
# $skip_user’s own entries.
sub _find_overlap {
    my ( $ranges_ar, $start, $count, $skip_user ) = @_;

    my $end = $start + $count - 1;

    for my $range ( @{$ranges_ar} ) {
        next if defined $skip_user && $range->{user} eq $skip_user;

        my $other_end = $range->{start} + $range->{count} - 1;

        return $range->{user} if $start <= $other_end && $range->{start} <= $end;
    }

    return;
}

# Two accounts sharing host IDs is the breach these ranges exist to prevent, so
# both of these are hard errors. Reallocating automatically is not an option —
# the container files on disk are owned by the old range’s IDs — so it takes an
# administrator, which is what the messages say.
sub _assert_allocation_is_free {
    my ( $user, $start, $count, $ranges_ar, $file ) = @_;

    my $overlaps = _find_overlap( $ranges_ar, $start, $count, $user );
    return if !defined $overlaps;

    my $end = $start + $count - 1;
    die "Refusing to give “$user” the host IDs $start-$end in “$file”: they overlap the IDs “$overlaps” already holds. An administrator needs to sort out “$file” before “$user” can run containers.\n";
}

sub _assert_range_is_exclusive {
    my ( $user, $ranges_ar, $file ) = @_;

    my $mine = _user_ranges( $ranges_ar, $user );

    if ( @{$mine} > 1 ) {
        die "“$user” has more than one range in “$file”, so which host IDs are theirs is ambiguous. An administrator needs to leave them exactly one.\n";
    }

    my ( $start, $count ) = ( $mine->[0]{start}, $mine->[0]{count} );

    my $overlaps = _find_overlap( $ranges_ar, $start, $count, $user );
    return if !defined $overlaps;

    my $end = $start + $count - 1;
    die "“$user” shares the host IDs $start-$end with “$overlaps” in “$file”, so their containers are not isolated from each other’s. An administrator needs to give one of them a range of its own — `ea-podman subids` lists every account this affects.\n";
}

sub _find_range_problems {
    my ($file) = @_;

    my $ranges_ar = _read_ranges($file);

    my %problem;

    # More than one line: which host IDs are actually theirs is ambiguous, so it
    # needs fixing whether or not the lines overlap anything.
    my %lines;
    $lines{ $_->{user} }++ for @{$ranges_ar};
    $problem{$_} = "is listed with more than one range" for grep { $lines{$_} > 1 } keys %lines;

    # Overlaps, by sweeping in start order against the ranges still open at each
    # start. Every partner is named, not just the one reaching furthest: an
    # administrator handed a partial list has no way to tell it is partial, and
    # would have to re-audit after each edit to find the next name.
    #
    # @open is pruned to the ranges that reach the current start, so on a healthy
    # file it holds at most the previous range and the sweep stays linear; it
    # only grows where ranges genuinely pile up, which is the broken case worth
    # spending the comparisons on.
    my %shared_with;
    my @open;
    for my $range ( sort { $a->{start} <=> $b->{start} || $a->{user} cmp $b->{user} } @{$ranges_ar} ) {

        # Ending before this one starts means ending before every later one
        # starts too, so it is done being compared.
        @open = grep { $_->{start} + $_->{count} - 1 >= $range->{start} } @open;

        # Everything left starts at or before this range and reaches into it.
        for my $other (@open) {
            $shared_with{ $range->{user} }{ $other->{user} } = 1;
            $shared_with{ $other->{user} }{ $range->{user} } = 1;
        }

        push @open, $range;
    }

    # Sharing IDs with another account is the more urgent of the two, so it is
    # what gets reported for an account with both problems. Overlapping only
    # itself means two lines, which the ambiguity message above already covers.
    for my $user ( keys %shared_with ) {
        my @others = grep { $_ ne $user } sort keys %{ $shared_with{$user} };
        next if !@others;

        $problem{$user} = "shares host IDs with " . join( ", ", map { "“$_”" } @others );
    }

    return \%problem;
}

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
