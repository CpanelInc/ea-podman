#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea_podman/subids.pm                     Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

# Despite the name, this module owns the whole root-side rootless-session
# bootstrap, not just /etc/subuid and /etc/subgid. If you are looking for where
# ea-podman touches systemd as root, it is here.
package ea_podman::subids;

use Path::Tiny 'path';
use Cpanel::OS;
use Digest::SHA ();
use Fcntl       qw(:flock);
use IPC::Open3  ();
use Time::HiRes ();

our $good = "✅";
our $bad  = "❌";

# FOR Testability
our $file_subuid = "/etc/subuid";
our $file_subgid = "/etc/subgid";
our $dir_run     = "/run/user";

# systemd records a lingering user as an empty marker file in here:
# `loginctl enable-linger` creates one, `disable-linger` removes it. Reading
# the marker is cheaper — and far easier to test — than shelling out to
# `loginctl show-user <user> -p Linger`.
our $dir_linger = "/var/lib/systemd/linger";

# Same shape, ea-podman’s own bookkeeping: a marker per account meaning “this
# linger is one we turned on”. $dir_linger says an account lingers, never who
# asked for it. Root owned, and not packaged so an upgrade leaves it be.
our $dir_granted_linger = "/opt/cpanel/ea-podman/granted-linger";

# CageFS 7.6.39+ masks the `user@.service` *template*, so no per-user systemd
# manager can start and rootless podman has nothing to talk to. See
# docs/container-shell-access.md “CageFS 7.6.39+ masks user@.service” for why
# CloudLinux does it and why we cannot just leave it unmasked, and
# ensure_user_manager_carveouts() for what we do about it. (EA4-319, EA4-321)
#
# A mask is the unit name symlinked to /dev/null. Two possible locations,
# because `systemctl mask` writes under /etc and `systemctl mask --runtime`
# writes under /run; which one it is in is what a restore has to preserve.
our $file_mask_etc = "/etc/systemd/system/user\@.service";
our $file_mask_run = "/run/systemd/system/user\@.service";

# Written by ea-podman before EA4-321, which unmasked the template for the
# length of a start. This version never writes it, and only reads it to put the
# mask back on a host that was upgraded while a window was open.
our $file_mask_state = "/opt/cpanel/ea-podman/user-manager-mask.state";

sub ensure_user_root {
    my ( $user, $num_uids, $ensure_session, $may_restart ) = @_;

    $num_uids       = 65537 if !$num_uids;
    $ensure_session = 1     if !defined $ensure_session;

    _ensure_subids( $user, $num_uids );

    # Only an account that has containers — or is about to get its first one —
    # is given a lingering user session. Lingering every account that merely ran
    # a command (or got backed up) was CPANEL-55309; the caller that can see the
    # container registry makes that call, see ea_podman::util::ensure_user().
    #
    # When it does apply it is (idempotently) redone every time, not just on
    # first subid setup: linger may have been torn down since (e.g. a stale
    # state or an explicit `loginctl disable-linger`), which would leave a
    # registered user with no runtime dir. (CPANEL-54037)
    # $may_restart says the account has no containers, so restarting a manager
    # that is up but unusable costs nothing. The caller decides because only it
    # can see the root-owned container registry. See ensure_user_session().
    ensure_user_session( $user, may_restart => $may_restart ) if $ensure_session;

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
# /run/user/<uid> as a tmpfs *and* — on first enable, see ensure_user_session()
# — starts user@<uid>.service (the user systemd manager), persisting both
# across logout/reboot — exactly what rootless
# container persistence requires. Held in a package variable so tests can
# stub the privileged call.
our $linger_enabler = \&_enable_linger;

sub _enable_linger {
    my ($user) = @_;
    system( "loginctl", "enable-linger", $user );
    return $? == 0;
}

# Package variables so tests can stub the privileged calls, same as $linger_enabler.
our $daemon_reloader      = \&_daemon_reload;
our $user_manager_starter = \&_start_user_manager;

sub _daemon_reload {
    system( "systemctl", "daemon-reload" );
    return $? == 0;
}

sub _start_user_manager {
    my ($uid) = @_;
    system( "systemctl", "start", "user\@$uid.service" );
    return $? == 0;
}

# The counterpart to $user_manager_starter, needed for one case only: a manager
# that is running while its runtime directory or bus socket is gone. `systemctl
# start` on a running unit is a no-op, so a restart is the only repair, and a
# restart has to begin with a stop.
#
# Expect this to be slow. Stopping a manager takes its containers down with it,
# and a container whose PID 1 does not exit on SIGTERM is only killed at
# TimeoutStopSec — 90s by default — so budget that per account. It is why only
# the sweep does this and the per-command path reports instead. (EA4-319)
our $user_manager_stopper = \&_stop_user_manager;

sub _stop_user_manager {
    my ($uid) = @_;

    # Allowed while the template is masked: masking refuses new *starts*, not
    # stops, so nothing here needs the account's own unit either. A stop can
    # take TimeoutStopSec (90s) to return.
    system( "systemctl", "stop", "user\@$uid.service" );
    return $? == 0;
}

# Is the account’s manager actually running?
#
# Asked instead of testing for the bus socket, because the socket outlives the
# manager: logind only tears /run/user/<uid> down once the account’s LAST session
# ends, so `systemctl stop user@<uid>.service` on an account that still has a
# login leaves an orphaned /run/user/<uid>/bus behind. A start decision made on
# `-e $bus` then skips the start and reports success while nothing is listening —
# and rootless podman fails with “Failed to connect to user scope bus”. (EA4-319)
our $user_manager_is_active = \&_user_manager_is_active;

sub _user_manager_is_active {
    my ($uid) = @_;
    system( "systemctl", "is-active", "--quiet", "user\@$uid.service" );
    return $? == 0;
}

# Is the account’s manager CONFIRMED stopped? Stricter than `!$user_manager_is_active`,
# and the only thing allowed to authorise taking a unit file away.
#
# `is-active` exits nonzero for every state but `active`, and for a failure to
# ask at all (no bus, systemd busy), so “not active” cannot tell a stopped manager
# from one we failed to query. Deleting the unit from under a live manager and then
# reloading tears it down on systemd 252, so the state has to be read, and only
# `inactive` and `failed` count. `activating`, `deactivating`, `reloading`, an
# empty answer and anything unrecognised all mean leave it alone and ask again
# next time.
our $user_manager_confirmed_stopped = \&_user_manager_confirmed_stopped;

sub _user_manager_confirmed_stopped {
    my ($uid) = @_;

    # List-form pipe: no shell, and stderr is sent to /dev/null so a failed query
    # cannot splash its complaint over the caller's output.
    my $state = eval {
        open( my $err, ">", "/dev/null" ) or die;
        my $pid = IPC::Open3::open3( my $in, my $out, ">&" . fileno($err), "systemctl", "is-active", "user\@$uid.service" );
        close $in;
        my $line = <$out>;
        waitpid( $pid, 0 );
        $line;
    };
    return 0 if !defined $state;

    chomp $state;
    return ( $state eq "inactive" || $state eq "failed" ) ? 1 : 0;
}

# Which of the two locations `user@.service` is masked in, or undef when it is
# not masked.
#
# Read off the filesystem rather than shelled out to
# `systemctl is-enabled user@.service`. Same reasoning as $dir_linger above: it
# is cheaper, it is far easier to test, and `is-enabled` only says “masked”
# without saying where. Per systemd.unit(5) an empty unit file masks too, so it
# counts here; a restore normalises it to the canonical symlink.
sub user_manager_mask_file {
    for my $file ( $file_mask_etc, $file_mask_run ) {
        next if !lstat($file);

        return $file if -l _  && ( readlink($file) // '' ) eq "/dev/null";
        return $file if !-l _ && -z _;
    }

    return;
}

# Put the mask back. Idempotent: a mask already in place is left alone, which is
# what makes it safe to call on a path we never got as far as lifting.
sub _restore_user_manager_mask {
    my ($file) = @_;

    return 0 if !defined $file;
    return 0 if $file ne $file_mask_etc && $file ne $file_mask_run;    # not ours to create

    if ( !lstat($file) ) {

        # /run/systemd/system may not exist yet. mkpath dies rather than
        # returning false, and this sub runs on the error path, so it must not be
        # allowed to throw: the symlink below is the authoritative check and
        # reports the real errno either way.
        eval { path($file)->parent->mkpath; 1 };

        if ( !symlink( "/dev/null", $file ) ) {

            # Failing to put the mask back leaves CloudLinux’s CLOS-4517 fix off
            # on this host, which is a good deal worse than whatever we were
            # doing at the time. Say so loudly, and keep $file_mask_state so the
            # next run through the guard tries again — unlinking it here would
            # strand the host unmasked with nothing left to notice.
            warn "ea-podman: could not put the `user\@.service` mask back at “$file”: $!\n" . "This host is left with the mask lifted. Restore it with `systemctl mask user\@.service` (`--runtime` if it was a runtime mask); ea-podman will also retry on its next run.\n";
            return 0;
        }

        $daemon_reloader->();
    }

    unlink $file_mask_state;

    return 1;
}

sub _read_mask_state {
    return if !-e $file_mask_state;

    chomp( my $file = path($file_mask_state)->slurp );

    # Only ever one of the two paths we mask. Anything else is not ours to
    # unlink or create, and this is the one place the value is trusted.
    return if $file ne $file_mask_etc && $file ne $file_mask_run;

    return $file;
}

# A `user@<uid>.service` of its own for each account that needs a manager, so
# the account's manager does not depend on the `user@.service` template, which a
# CageFS host keeps masked. (EA4-321)
#
# Earlier versions unmasked the template, started the manager, and masked it
# again (EA4-319). That does start the manager, and on systemd 239 and 257 it
# leaves it running. On systemd 252 the remask does not: a reload that changes
# the template's mask state tears down `user-runtime-dir@<uid>.service` for every
# instance that is running, however long it has been up, leaving a manager that
# reports `active` with no /run/user/<uid> and no bus. It is not a race, so
# waiting before the reload does not help. Skipping the reload only defers the
# damage to the next `daemon-reload` anyone on the host runs, which an rpm
# scriptlet or `cagefsctl` will do sooner or later.
#
# So the template is never touched. A unit file named for the instance takes
# precedence over the template, and is not a mask, so it is what lets one
# account's manager start while every other account stays refused: the mask is
# still on the template, and CloudLinux's CLOS-4517 protection is unchanged.
#
# What the probes behind this (EA4-321) found, all of it easy to get wrong:
#
#   * It has to be a real file. A symlink to the vendor unit is resolved as the
#     template it points at, and is refused as masked.
#   * A drop-in directory does not override a mask.
#   * Removing the file while the manager is running, and then reloading, tears
#     the manager down exactly as the remask did. So the file is only ever
#     removed once the manager is confirmed stopped, see
#     remove_user_manager_carveout(), and never from the start path.
#
# It lives under /run, so a reboot clears it, which is right: nothing is running
# then either, and the boot sweep (ensure_user_sessions) writes it again before
# it starts anything. The copy is of the vendor unit as of when it was written,
# so a systemd update that changes the unit is not seen by a running account
# until its manager next restarts.
#
# A host that does not mask the template gets the file too, see
# ensure_user_manager_carveouts(), so the manager survives a mask arriving later.
# Nothing is written for an account that is already up and current.
our $dir_unit_carveout = "/run/systemd/system";
our @files_vendor_unit = ( "/usr/lib/systemd/system/user\@.service", "/lib/systemd/system/user\@.service" );

sub user_manager_carveout_file {
    my ($uid) = @_;

    return "$dir_unit_carveout/user\@$uid.service";
}

sub _vendor_user_unit {
    for my $file (@files_vendor_unit) {
        return $file if -f $file;
    }

    return;
}

# Make sure each of @uids has its own unit file, then reload once for the lot.
# Dies if there is nothing to copy, or a file cannot be written: carrying on
# would only fail later, at the start, with the much less useful “masked”.
sub ensure_user_manager_carveouts {
    my (@uids) = @_;

    my $prepared = _prepare_user_manager_carveouts(@uids);

    @{ $prepared->{refused} } and die $ea_podman::subids::session_error_prefix . join( "", map { _refusal_message( user_manager_carveout_file($_) ) } @{ $prepared->{refused} } );

    return $prepared->{changed};
}

sub _refusal_message {
    my ($file) = @_;

    return "“$file” already exists and was not written by ea-podman (it may be an explicit mask of the account’s user systemd manager), so it was left alone and that manager was not started. Remove it if it should not be there.\n";
}

# The work of ensure_user_manager_carveouts(), except that an account whose
# unit is not ours to replace is reported rather than died on: returns
# { changed => how many were written, refused => [ the uids set aside ] }. The
# sweep uses this directly so one account's administrator-placed mask cannot
# stop every other account's manager from being prepared and started. Still
# dies for what is the same for every account (no vendor unit, a failed write
# or reload).
sub _prepare_user_manager_carveouts {
    my (@uids) = @_;

    _restore_abandoned_unmask_window();

    return { changed => 0, refused => [] } if !@uids;

    # Written whether or not the template is masked right now. CageFS re-applies
    # its mask on every install and upgrade, and on systemd 252 that remask tears
    # down every manager that was started without a unit of its own, so a manager
    # started while the host happened to be unmasked (CloudLinux's
    # `disable-systemd-user-mask` flag) would not survive the mask coming back.
    my $masked = user_manager_mask_file();

    my $vendor = _vendor_user_unit();

    # Nothing to copy is only an error where the copy is what lets the manager
    # start. An unmasked host starts it from the template, exactly as before.
    return { changed => 0, refused => [] } if !$vendor && !$masked;

    $vendor or die $ea_podman::subids::session_error_prefix . "Could not find the vendor user\@.service to copy (looked in @files_vendor_unit), so a user systemd manager cannot be started while the template is masked.\n";

    my $content = path($vendor)->slurp_raw;
    my $digest  = Digest::SHA::sha256_hex($content);

    return _with_carveout_lock(
        sub {

            my $changed = 0;
            my @refused;
            for my $uid (@uids) {
                my $file = user_manager_carveout_file($uid);

                # Left alone when it already matches, so a healthy host pays for no
                # write and, more to the point, no reload.
                next if !-l $file && -f _ && path($file)->slurp_raw eq $content;

                # Only a unit this module wrote is ours to replace, and what is on
                # disk has to still be what was written: a marker alone outlives an
                # administrator swapping the unit for a mask of this one account (a
                # symlink to /dev/null, or an empty file), a restriction that
                # starting the manager would undo. Set aside rather than died on, so
                # one account's mask does not stop the others in the same sweep from
                # getting theirs.
                my $previous;
                if ( lstat($file) ) {
                    $previous = _carveout_written_digest($uid);

                    if ( !defined $previous ) {
                        unlink _carveout_written_file($uid);    # a stale marker vouches for nothing
                        push @refused, $uid;
                        next;
                    }
                }

                eval { path($dir_unit_carveout)->mkpath; 1 } or die $ea_podman::subids::session_error_prefix . "Could not create “$dir_unit_carveout”: $@";

                # Down before the first file lands, and only taken down once the
                # reload has gone through. A reload that fails, or a process that
                # dies between the rename and the reload, leaves the unit on disk
                # and systemd none the wiser; the next run finds the contents
                # matching and would skip the reload for good. The marker is what
                # makes that run reload anyway.
                _touch_state( _reload_pending_file() );

                # Written beside the target and renamed into place, so systemd never reads
                # half a unit. Only ever over a unit of ours (checked above), and rename()
                # swaps the directory entry itself rather than writing through it.
                my $tmp = "$file.ea-podman.$$";
                path($tmp)->spew_raw($content);
                chmod 0644, $tmp;

                # Recorded before the rename so a crash between the two leaves a
                # record for a file that is not there, which is harmless, and never
                # a file of ours that nothing vouches for. The digest of the unit
                # being replaced stays on the record until the rename is done, so a
                # crash in between still leaves whichever of the two is on disk
                # vouched for.
                _write_state( _carveout_written_file($uid), join( "", map { "$_\n" } grep { defined } $previous, $digest ) );
                rename $tmp, $file or do { my $err = $!; unlink $tmp; unlink _carveout_written_file($uid) if !lstat($file); die $ea_podman::subids::session_error_prefix . "Could not install “$file”: $err\n" };
                _write_state( _carveout_written_file($uid), "$digest\n" );

                $changed++;
            }

            # Reloading is what makes systemd see the new files. The template's mask
            # state is not changing, which is the only kind of reload that is harmful.
            if ( $changed || -e _reload_pending_file() ) {
                $daemon_reloader->() or die $ea_podman::subids::session_error_prefix . "`systemctl daemon-reload` failed, so systemd has not picked up the unit files for the user systemd managers. It will be tried again the next time ea-podman prepares a manager.\n";

                unlink _reload_pending_file();
            }

            return { changed => $changed, refused => \@refused };
        }
    );
}

sub ensure_user_manager_carveout {
    my ($uid) = @_;

    return ensure_user_manager_carveouts($uid);
}

# Take the file back once the account no longer has a manager. A no-op while one
# is running: removing the file under a live manager and then reloading is what
# kills it (see above). No reload here either way; systemd drops an inactive
# unit's stale definition on the next one anyone does, and a stopped unit whose
# file is gone simply falls back to the masked template, which is the point.
sub remove_user_manager_carveout {
    my ($uid) = @_;

    return _with_carveout_lock(
        sub {
            my $file = user_manager_carveout_file($uid);

            if ( !lstat($file) ) {
                unlink _carveout_written_file($uid);    # a record of a unit that is gone vouches for nothing
                return 0;
            }

            # Not ours, so not ours to take away either. That includes a unit an
            # administrator put in place of ours, which the record left behind
            # would otherwise still vouch for.
            if ( !defined _carveout_written_digest($uid) ) {
                unlink _carveout_written_file($uid);
                return 0;
            }

            return 0 if !$user_manager_confirmed_stopped->($uid);

            return 0 if !unlink($file);

            unlink _carveout_written_file($uid);
            return 1;
        }
    );
}

# Where ea-podman keeps what it knows about the unit files above. Under /run for
# the same reason the unit files are: a reboot clears the files and these notes
# together, and there is nothing left to know.
#
#   written/<uid>   ea-podman wrote the unit at that uid's name, and what it
#                   wrote (see _carveout_written_digest). This is the whole
#                   record of which units are ours: which are still wanted is
#                   not recorded but asked, of the account's linger and its
#                   manager, by reconcile_carveouts(), so there is no second
#                   note that could disagree with the first.
#   reload-pending  unit files are on disk that systemd has not been told
#                   about, because the reload failed or never ran.
#   lock            one lock for all of it, so a release cannot take a unit
#                   away from an account that is being set up at the same
#                   moment.
our $dir_carveout_state = "/run/ea-podman";

# Package variable so a test can name accounts without needing them in passwd.
our $uid_to_user = sub { scalar getpwuid( $_[0] ) };

# written/<uid> vouches that the unit file at that uid's name is one ea-podman
# wrote: it holds the sha256 of each content we may have left on disk (two while
# a replacement is in flight, see ensure_user_manager_carveouts()).
sub _carveout_written_file {
    my ($uid) = @_;

    return "$dir_carveout_state/written/$uid";
}

# The digest on disk at the unit's name when, and only when, it is still
# something ea-podman wrote: a regular file (never a symlink, so never a
# /dev/null mask) whose content is one the marker vouches for (never an empty
# file). A marker on its own is not enough, it outlives an administrator
# replacing the unit. undef otherwise, which every caller treats as "not ours,
# leave it alone".
sub _carveout_written_digest {
    my ($uid) = @_;

    my $file = user_manager_carveout_file($uid);
    return if !lstat($file) || -l _ || !-f _ || -z _;

    my $recorded = eval { path( _carveout_written_file($uid) )->slurp } // return;
    my %vouched  = map { $_ => 1 } grep { /\A[0-9a-f]{64}\z/ } split /\n/, $recorded;

    my $on_disk = eval { Digest::SHA::sha256_hex( path($file)->slurp_raw ) } // return;

    return $vouched{$on_disk} ? $on_disk : undef;
}

sub _reload_pending_file { return "$dir_carveout_state/reload-pending" }

sub _write_state {
    my ( $file, $content ) = @_;

    eval { path($file)->parent->mkpath; path($file)->spew($content); 1 } or die $ea_podman::subids::session_error_prefix . "Could not record state in “$file”: $@";

    return 1;
}

sub _touch_state {
    my ($file) = @_;

    eval { path($file)->parent->mkpath; path($file)->touch; 1 } or die $ea_podman::subids::session_error_prefix . "Could not record state in “$file”: $@";

    return 1;
}

our $carveout_lock_held = 0;

# Re-entrant, because the callers nest (ensure reaps, reaping removes) and flock
# on a second descriptor of a file this process already holds would wait on
# itself forever.
sub _with_carveout_lock {
    my ($code) = @_;

    return scalar $code->() if $carveout_lock_held;

    eval { path($dir_carveout_state)->mkpath; 1 } or die $ea_podman::subids::session_error_prefix . "Could not create “$dir_carveout_state”: $@";

    open( my $fh, ">>", "$dir_carveout_state/lock" ) or die $ea_podman::subids::session_error_prefix . "Could not open “$dir_carveout_state/lock”: $!\n";
    flock( $fh, LOCK_EX )                            or die $ea_podman::subids::session_error_prefix . "Could not lock “$dir_carveout_state/lock”: $!\n";

    local $carveout_lock_held = 1;

    return scalar $code->();
}

sub _written_uids {
    opendir( my $dh, "$dir_carveout_state/written" ) or return;
    my @uids = grep { /\A[0-9]+\z/ } readdir $dh;
    closedir $dh;

    return @uids;
}

# Take back every unit of ours that nothing wants any more. One rule, asked of
# the live state rather than of a note somebody left: a unit is wanted while
# its account lingers (that is what setup enables, and what a release takes
# away, and a deleted account cannot linger), and is taken back once its manager
# is confirmed stopped, never from under a running one. Anything else is left
# for the next call.
#
# Cheap when there is nothing of ours (one failed opendir), and one stat per
# lingering account otherwise, so it runs from every release and every sweep.
# Never reloads, for the reason given above. Returns how many units it removed.
sub reconcile_carveouts {
    return _reconcile_carveouts( [ _written_uids() ] );
}

sub _reconcile_carveouts {
    my ($uids) = @_;

    return 0 if !@{$uids};

    return _with_carveout_lock(
        sub {
            my $removed = 0;

            for my $uid ( @{$uids} ) {
                my $user = $uid_to_user->($uid);
                next if defined $user && user_has_linger($user);

                # Refuses, and removes nothing, unless the unit is ours and its
                # manager is confirmed stopped; drops a record for a unit that is
                # gone or is no longer what we wrote.
                $removed += remove_user_manager_carveout($uid);
            }

            return $removed;
        }
    );
}

# remove_user_session() finds the unit through getpwnam(), which has nothing to
# say about an account that has been deleted. The unit is still on disk, it is
# still an exception to the cagefs mask, and the uid will be handed to the next
# account that wants it. But every unit ea-podman wrote has a written/<uid>
# record, so the deleted ones are simply those whose uid no longer resolves:
# settle each of them the way a release does, now if its manager is confirmed
# stopped, otherwise left for the next reconcile_carveouts(). The name is the
# account being deleted, kept for the caller; what is done does not depend on
# it, so a deletion that was missed earlier is finished here too. (EA4-321)
sub release_deleted_user_carveout {
    my ($user) = @_;

    my @gone = grep { !defined $uid_to_user->($_) } _written_uids();
    _settle_carveout($_) for @gone;

    return scalar @gone;
}

# A predecessor from before EA4-321 may have been killed in the middle of its
# unmask window, leaving the template unmasked. Put the mask back, once, and
# forget about it. Nothing in this version ever creates that state file, so this
# only ever fires on a host that was upgraded mid-window.
#
# Not before every lingering account has a unit of its own: while the template
# was unmasked, logind started those accounts' managers from it, and the reload
# that puts the mask back is exactly the one that tears such a manager down on
# systemd 252 (see above). So this is the "mask arriving later" case, and is
# handled the same way: units first, one reload for them, then the mask.
our $_restoring_unmask_window = 0;

sub _restore_abandoned_unmask_window {
    return if $_restoring_unmask_window;
    return if !-e $file_mask_state;

    my $file = _read_mask_state();

    if ( !defined $file ) {
        unlink $file_mask_state;    # not ours to act on, and not going to be any use later either
        return;
    }

    {
        local $_restoring_unmask_window = 1;
        my @uids = grep { defined } map { ( getpwnam($_) )[2] } _lingering_users();
        eval { _prepare_user_manager_carveouts(@uids); 1 } or warn "ea-podman: could not give the running user systemd managers a unit of their own before putting the `user\@.service` mask back: $@";
    }

    _restore_user_manager_mask($file);

    return;
}

sub _lingering_users {
    opendir( my $dh, $dir_linger ) or return;
    my @users = grep { _is_valid_linger_user($_) } readdir $dh;
    closedir $dh;

    return @users;
}

# Marks a die as being about THIS account's own user session -- its own uid, its
# own /run/user/<uid> -- and so safe to show the caller verbatim. A subid refusal
# is not: it names /etc/subuid and the account it collided with, which is
# root-side detail a cpuser must not see. The adminbin swallows everything by
# default and uses these two to make the exception, so the one message written to
# tell an operator which command repairs their account actually reaches them.
# (EA4-319)
our $session_error_prefix = "ea-podman user session: ";

sub is_user_session_error {
    my ($err) = @_;
    return ( defined $err && index( $err, $session_error_prefix ) == 0 ) ? 1 : 0;
}

sub strip_user_session_error {
    my ($err) = @_;
    return $err if !is_user_session_error($err);

    substr( $err, 0, length($session_error_prefix) ) = "";
    return $err;
}

# The one statement of what the mask is and where it comes from, so the
# root-side and cpuser-side messages cannot drift apart.
sub masked_user_manager_explanation {
    return "`user\@.service` is masked on this server, which stops any per-user systemd manager from starting. CageFS 7.6.39 and newer mask it deliberately (CloudLinux CLOS-4517) and `cagefsctl --hook-install` re-applies the mask on every cagefs install and upgrade.\n";
}

# Appended to both dies below, because either can be the one that fires.
#
# EA4-319 open question 2 assumed only the bus would be missing, on the grounds
# that user-runtime-dir@.service is not itself masked. Measured on systemd 239,
# that is wrong: user@.service has Requires=user-runtime-dir@%i.service, so
# masking user@ fails the whole job and the runtime dir never gets created
# either — with or without a login session. The runtime-directory die is
# therefore the one a masked host actually hits, which also means the original
# “the runtime directory did not become available” report was accurate rather
# than misleading.
sub _masked_user_manager_hint {
    my ($uid) = @_;

    my $file = user_manager_mask_file() or return "";

    return "\n" . masked_user_manager_explanation() . "The mask is at “$file”. ea-podman leaves it alone and starts the account’s manager from a unit of its own, “" . user_manager_carveout_file($uid) . "”; here that did not take effect.\n" . "Check `systemctl status user\@$uid.service` and `journalctl -u user\@$uid.service` for why the manager itself failed.\n";
}

# The readiness poll below, as package variables so a test can exercise the
# timeout without actually sleeping for it.
our $poll_iterations = 100;
our $poll_sleeper    = sub { Time::HiRes::usleep(100_000) };    # 0.1s × 100 ≈ 10s max

sub ensure_user_session {
    my ( $user, %opts ) = @_;

    # Whether this caller is allowed to restart a manager that is running but
    # unusable (see the die below). Defaults to off: the callers that may are the
    # ones that have checked there are no containers to take down with it.
    my $may_restart = $opts{may_restart} ? 1 : 0;

    my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
    die "Could not look up the uid/gid for “$user”\n" if !defined $uid;

    # Nothing to do when the account already lingers and its manager is up — and
    # running enable-linger anyway is not free. systemd re-touches
    # $dir_linger/<user> every time, and that file’s timestamp is how we tell our
    # own linger from somebody else’s (see grant_covers_current_linger()). Since
    # this runs for every ea-podman command an account with containers makes, a
    # blind re-enable would age our own grant out of covering the linger it
    # granted, and the release on the last container would never happen.
    # (CPANEL-55309)
    #
    # It is also what keeps the unit-writing and reload below off the hot path
    # entirely: a healthy account never reaches it, so on a cagefs host we pay for
    # the bypass once per cold account, not once per command.
    #
    # “Its manager is up” has to be asked of systemd, not inferred from the bus
    # socket: the socket outlives the manager, so an account whose manager was
    # stopped while it still had a login keeps an orphaned
    # /run/user/<uid>/bus and would take this return forever — leaving podman to
    # fail with “Failed to connect to user scope bus” on every command, with
    # nothing here ever trying to repair it. It is one extra `systemctl is-active`
    # per command, ordered last so the three cheap checks short-circuit it, on a
    # path that already forks podman. (EA4-319)
    if ( user_has_linger($user) && -d "$dir_run/$uid" && -e "$dir_run/$uid/bus" && $user_manager_is_active->($uid) ) {

        # A manager that was already running when this version arrived (or that
        # logind started on a host that was not masking the template) has no unit
        # of its own, and a CageFS mask arriving later tears it down on systemd
        # 252. Giving it one does not disturb it (see ensure_user_sessions()), and
        # this is the only place an upgraded host's running managers are reached
        # before that happens: the boot sweep has already run. One lstat once the
        # unit is in place. A failure is reported, not fatal: the manager is healthy
        # and the caller asked for nothing this would make worse. (EA4-321)
        if ( !lstat( user_manager_carveout_file($uid) ) ) {
            eval { ensure_user_manager_carveout($uid); 1 }
              or warn "ea-podman: could not give the running user systemd manager for “$user” a unit of its own: " . strip_user_session_error($@);
        }

        return;
    }

    mkdir $dir_run;    # parent /run/user; harmless when it already exists

    # The unit this writes is taken away by a release that finds the manager
    # stopped, and until the start below the manager is exactly that. So the
    # carveout lock is held from the unit write to a started manager, not just for
    # the write: a release then waits for the start, sees a running manager, and
    # leaves the unit alone. (EA4-321)
    return _with_carveout_lock(
        sub {
            eval { _ensure_user_session_locked( $user, $uid, $may_restart ); 1 } or do {
                my $err = $@;
                _abandon_unstarted_carveout( $user, $uid );
                die $err;
            };

            return;
        }
    );
}

# Setup writes the account's unit before it enables linger and starts the
# manager, and any of those can fail afterwards. A caller that sees the die has
# no reason to release an account that was never set up (the release insists on
# a linger or a grant), so the unit would sit as an exception to the CageFS mask
# until the next call to reconcile_carveouts() from anywhere on the host, or the
# next reboot. Settle it now instead: taken back if the account ended up with
# neither linger nor a manager, left for the reconciler if the manager is not
# confirmed stopped. An account that does linger wants its unit; the next
# attempt carries on from there. Never dies: it runs on an error path and must
# not replace the real error.
sub _abandon_unstarted_carveout {
    my ( $user, $uid ) = @_;

    local $@;
    eval {
        _settle_carveout($uid) if !user_has_linger($user);
        1;
    } or warn "ea-podman: could not take back the unit file for “$user” after a failed setup: $@";

    return;
}

sub _ensure_user_session_locked {
    my ( $user, $uid, $may_restart ) = @_;

    my $rundir = "$dir_run/$uid";
    my $bus    = "$rundir/bus";

    # Two calls, two different jobs, both refused while `user@.service` is
    # masked, so the account gets a unit of its own first (see
    # ensure_user_manager_carveouts):
    #
    #   * enable-linger owns *persistence* — the /var/lib/systemd/linger marker,
    #     so the account’s containers survive logout and reboot.
    #   * the explicit start owns *up right now*, which enable-linger cannot do:
    #     for an account that already lingers, logind will not retry a manager it
    #     believes it already handled. That is exactly the state a cagefs host is
    #     in after a reboot — linger marker present, no runtime dir, no bus —
    #     where enable-linger alone is a no-op.
    #
    # The skip on the start is an “already up” shortcut, not selectivity. It asks
    # systemd whether the manager is running rather than testing for the bus
    # socket: the socket outlives the manager (see $user_manager_is_active), so
    # `-e $bus` would skip the start for an account whose manager is dead and
    # leave it dead. When the start does run, `systemctl start` blocks until the
    # job settles, which is what lets the window close before the poll below
    # rather than around it. (EA4-319)
    my $start_failed;
    ensure_user_manager_carveout($uid);

    {
        # Re-enabling for an account we already hold a grant on moves systemd’s
        # marker ahead of that grant, so the grant has to move with it or it stops
        # covering the very linger it is for. Recorded around the enable, not after
        # the readiness poll below, which can die.
        my $regrant = user_has_granted_linger($user);

        $linger_enabler->($user);

        record_linger_grant($user) if $regrant;

        $start_failed = !$user_manager_starter->($uid) if !$user_manager_is_active->($uid);
    }

    # Waiting for a socket to appear under /run/user/<uid> touches nothing the
    # mask gates, and nothing is held open while it happens.
    #
    # The readiness signal `systemctl --user` and rootless podman actually need is
    # the manager’s dbus socket, not the directory: the directory appears well
    # before the manager is up, so polling only for it races and leaves podman
    # with “Failed to connect to user scope bus”.
    if ( !$start_failed ) {
        for ( 1 .. $poll_iterations ) {
            last if -d $rundir && -e $bus;
            $poll_sleeper->();
        }
    }

    # A manager that is still running with its runtime directory or bus gone is a
    # state this path cannot repair, and must not try to. The start above is
    # skipped for an active manager -- and `systemctl start` on one is a no-op
    # anyway -- so the poll has just waited out its whole ceiling for a socket
    # nothing was ever going to create, and every later command for this account
    # will do the same. Only a restart fixes it.
    #
    # Deliberately not restarted here. ea_podman::util::init_user() reaches this
    # for every verb, including read-only ones, so repairing would mean an
    # `ea-podman list` taking the account's containers down for as long as
    # TimeoutStopSec allows -- a worse outcome than the fault it repairs, and one
    # the caller never asked for. The sweep does restart it (see
    # ensure_user_sessions below), because boot and an explicit admin invocation
    # are the two contexts where that is expected. So: name the condition, and
    # name the command whose job it is.
    #
    # Checked after the poll rather than before it, so a manager that another
    # process started a moment ago still gets its ceiling to finish coming up.
    # (EA4-319)
    if ( ( !-d $rundir || !-e $bus ) && $user_manager_is_active->($uid) ) {

        # Nothing to lose: with no containers under it, restarting the manager
        # costs no downtime, so repair it here rather than making the caller do
        # it. This is the reachable case -- a failed install releases the session
        # it just granted (ea_podman::util::install_container), which can leave
        # the account wedged with zero containers, and the sweep works from the
        # registry so it would never come back to it.
        if ($may_restart) {
            $user_manager_stopper->($uid);

            my $restarted;
            ensure_user_manager_carveout($uid);
            $restarted = $user_manager_starter->($uid);

            if ($restarted) {
                for ( 1 .. $poll_iterations ) {
                    last if -d $rundir && -e $bus;
                    $poll_sleeper->();
                }
            }
        }

        if ( ( !-d $rundir || !-e $bus ) && $user_manager_is_active->($uid) ) {
            my $what = !-d $rundir ? "its runtime directory “$rundir” is gone" : "its session bus “$bus” is gone, so nothing is listening on it";

            die $session_error_prefix
              . "The user systemd manager for “$user” (uid $uid) is running, but $what.\n"
              . "A manager cannot recreate its own runtime directory or socket, so this does not heal on its own: it happens when /run/user/$uid is torn down underneath a manager that is still up.\n"
              . "Repair it as root with `systemctl stop user\@$uid.service` and then re-run this command; the manager is started fresh. This stops the account’s containers, which come back with it.\n"
              . "`ea-podman ensure_user_sessions` does the same for every account the container registry lists — but not for an account with no containers, which is how this state is usually reached.\n";
        }
    }

    if ( !-d $rundir ) {
        die $session_error_prefix . "The directory “$rundir” is missing: neither `loginctl enable-linger $user` nor `systemctl start user\@$uid.service` produced it.\n" . _masked_user_manager_hint($uid);
    }
    if ( !-e $bus ) {
        die $session_error_prefix . "The user session bus “$bus” did not appear after `loginctl enable-linger $user` and `systemctl start user\@$uid.service` (the user systemd manager did not start).\n" . _masked_user_manager_hint($uid);
    }

    return;
}

# The boot-time counterpart to ensure_user_session(): bring up the managers for
# a whole list of accounts in one sweep. Driven by `ea-podman
# ensure_user_sessions`, which the ea-podman-user-managers.service unit runs at
# boot — the trigger EA4-319 was missing, since nothing else writes an account's
# own unit at boot and logind will not start a masked `user@.service` for a
# lingering account on its own.
#
# Deliberately NOT a loop over ensure_user_session(): that would write and
# reload once per account, and would wait out a readiness poll per account, up
# to ~10s each. So the phases are split by hand: every account's own unit is
# written first and reloaded once, every start happens, then the buses are
# polled *together*, one ceiling for the sweep rather than one per account.
#
# Warns and carries on per account rather than dying: one account that cannot
# start its manager must not cost every other account on the box its containers,
# and must not abort the sweep half-way. Returns a hashref of
# user => "ok" (already up), "started", "failed", or "unknown" (no such user).
sub ensure_user_sessions {
    my (@users) = @_;

    # A chance to finish taking back the units of accounts released earlier while
    # a login session still held their manager. Reported, not fatal: it is not
    # this sweep's job.
    eval { reconcile_carveouts(); 1 } or warn "ea-podman: could not finish removing released accounts' user manager units: $@";

    my %result;
    my @pending;
    my @healthy;

    mkdir $dir_run;    # parent /run/user; harmless when it already exists

    for my $user (@users) {
        my $uid = ( getpwnam($user) )[2];

        if ( !defined $uid ) {

            # An account in the registry that no longer exists on the box. Not
            # fatal, and not this sweep’s business to clean up.
            warn "ea-podman: no such user “$user”; skipping\n";
            $result{$user} = "unknown";
            next;
        }

        # After a normal boot on a host that does not mask the template, logind
        # has already started every lingering account’s manager, so every account
        # is healthy and @pending is empty: nothing is started or stopped.
        #
        # Stricter than ensure_user_session()’s early return, which stops at the
        # bus socket: that one is on the hot path of every ea-podman command and
        # cannot afford a `systemctl is-active` per call. This runs once at boot,
        # so it can afford to ask systemd rather than trust a socket that outlives
        # the manager it belongs to (see $user_manager_is_active).
        if ( user_has_linger($user) && -d "$dir_run/$uid" && -e "$dir_run/$uid/bus" && $user_manager_is_active->($uid) ) {
            $result{$user} = "ok";
            push @healthy, $uid;
            next;
        }

        push @pending, { user => $user, uid => $uid };
    }

    # A healthy manager may have been started by logind at boot, on a host that
    # was not masking the template, and so has no unit of its own. The next time
    # the mask arrives (a cagefs install or upgrade, or CloudLinux's
    # `disable-systemd-user-mask` flag being removed) that manager is torn down
    # on systemd 252. Giving a running manager its unit now is what protects it:
    # tested, and it does not disturb the manager. Costs nothing once the unit is
    # in place. A failure here is reported but does not stop the sweep.
    if (@healthy) {
        eval { ensure_user_manager_carveouts(@healthy); 1 } or warn "ea-podman: could not give the running user systemd managers a unit of their own: $@";
    }

    return \%result if !@pending;

    # Stop the unusable managers BEFORE opening the window, not inside it.
    #
    # “Active” is not “usable”: a manager whose /run/user/<uid> was torn down
    # beneath it keeps running with no socket to talk to and cannot recreate one,
    # and `systemctl start` on a running unit is a no-op, so the only repair is a
    # restart. The sweep is where a restart belongs -- it runs at boot and from an
    # explicit admin invocation, both contexts where taking the account's
    # containers down is expected. Every other path reports instead; see
    # ensure_user_session() above.
    #
    # A stop is slow. It takes the account's containers with it, and a container
    # whose PID 1 ignores SIGTERM is only killed at TimeoutStopSec -- 90s each,
    # measured. Masking refuses new *starts*, not stops, so nothing here needs
    # the account's own unit either. (EA4-319)
    for my $acct (@pending) {
        my $uid = $acct->{uid};

        next if !$user_manager_is_active->($uid);
        next if -e "$dir_run/$uid/bus";

        $user_manager_stopper->($uid);
    }

    # Every account's own unit first, and one reload for all of them: /run is
    # empty after a reboot, so none of them has one yet. A failure here is
    # the same for every account, so it is reported once per account and the
    # sweep moves on, as it does for any other reason an account will not start.
    # Held from the first unit written to the last manager started, for the same
    # reason as in ensure_user_session(): a release must not find a manager that
    # is merely not started yet. (EA4-321)
    _with_carveout_lock(
        sub {
            my %refused;
            my $carveouts_ok = eval {
                my $prepared = _prepare_user_manager_carveouts( map { $_->{uid} } @pending );
                $refused{$_} = 1 for @{ $prepared->{refused} };
                1;
            };

            # An account whose unit is not ours to write (an administrator's mask
            # of it) is not started, and says why; the others are unaffected.
            for my $acct ( grep { $refused{ $_->{uid} } } @pending ) {
                warn "ea-podman: could not prepare the user systemd manager for “$acct->{user}”: " . _refusal_message( user_manager_carveout_file( $acct->{uid} ) );
                $acct->{start_failed} = 1;
            }

            if ( !$carveouts_ok ) {
                warn "ea-podman: could not prepare the user systemd managers: $@";
                $_->{start_failed} = 1 for @pending;

                # Some units may have landed before the failure; none of these
                # accounts has a manager to justify them. See ensure_user_session().
                _abandon_unstarted_carveout( $_->{user}, $_->{uid} ) for @pending;
            }

            for my $acct ( $carveouts_ok ? grep { !$refused{ $_->{uid} } } @pending : () ) {
                my ( $user, $uid ) = @{$acct}{qw(user uid)};

                # Contained per account: one that will not start must not cost the rest
                # of the sweep.
                local $@;
                eval {

                    # Same regrant bookkeeping as ensure_user_session(): a
                    # re-enable moves systemd’s linger marker ahead of our grant,
                    # so the grant has to move with it or it stops covering the
                    # very linger it is for. (CPANEL-55309)
                    my $regrant = user_has_granted_linger($user);

                    $linger_enabler->($user);

                    record_linger_grant($user) if $regrant;

                    # Anything still active here is genuinely usable: the
                    # unusable ones were stopped in the pre-pass above, so this
                    # is the same “already up” shortcut as ever.
                    $acct->{start_failed} = !$user_manager_starter->($uid) if !$user_manager_is_active->($uid);

                    1;
                } or do {
                    warn "ea-podman: could not start the user systemd manager for “$user”: $@";
                    $acct->{start_failed} = 1;
                    _abandon_unstarted_carveout( $user, $uid );
                };
            }

            # Shared across accounts: the starts above already
            # blocked until their jobs settled, so this is the tail of a race we have
            # mostly won already. An account whose start outright failed is not waited
            # for at all, same as ensure_user_session().
            my @waiting = grep { !$_->{start_failed} } @pending;

            for ( 1 .. $poll_iterations ) {
                @waiting = grep { !( -d "$dir_run/$_->{uid}" && -e "$dir_run/$_->{uid}/bus" ) } @waiting;
                last if !@waiting;
                $poll_sleeper->();
            }

            return;
        }
    );

    for my $acct (@pending) {
        my ( $user, $uid ) = @{$acct}{qw(user uid)};
        my $rundir = "$dir_run/$uid";

        # The manager, not just the socket: an orphaned bus left behind by a
        # stopped manager would otherwise be reported as a success.
        if ( -d $rundir && -e "$rundir/bus" && $user_manager_is_active->($uid) ) {
            $result{$user} = "started";
            next;
        }

        $result{$user} = "failed";

        # The wrappers report failure by returning false, not by dying, so the
        # per-account eval above never saw it and did not take the unit back.
        # Covers a readiness timeout too. No-op for an account that lingers.
        _abandon_unstarted_carveout( $user, $uid );

        # The same symptoms ensure_user_session() dies on, and the same hint —
        # which names the mask when there is one. A warn, not a die: see above.
        my $why =
            !-d $rundir       ? "the runtime directory “$rundir” was never created"
          : !-e "$rundir/bus" ? "the user session bus “$rundir/bus” never appeared"
          :                     "the session bus “$rundir/bus” exists but `user\@$uid.service` is not running, so nothing is listening on it";

        warn "ea-podman: the user systemd manager for “$user” (uid $uid) did not come up: $why.\n" . _masked_user_manager_hint($uid);
    }

    return \%result;
}

# The counterpart to $linger_enabler: `loginctl disable-linger <user>`, run as
# root, stops the user’s systemd manager and lets logind tear down
# /run/user/<uid> once the account has no session left. Held in a package
# variable so tests can stub the privileged call. (CPANEL-55309)
our $linger_disabler = \&_disable_linger;

sub _disable_linger {
    my ($user) = @_;
    system( "loginctl", "disable-linger", $user );
    return $? == 0;
}

# The marker paths below interpolate an account name and two are unlink()ed as
# root. Anything implausible reads as “no such user”, safe everywhere here.
sub _is_valid_linger_user {
    my ($user) = @_;

    return 0 if !defined $user;
    return $user =~ m{\A[a-z0-9][a-z0-9._-]*\z}i ? 1 : 0;
}

sub user_has_linger {
    my ($user) = @_;

    return 0 if !_is_valid_linger_user($user);
    return -e "$dir_linger/$user" ? 1 : 0;
}

# The grant record (see $dir_granted_linger): idempotent, root only, and “no
# record” is always the safe answer — without one nothing takes an account’s
# linger away. See ea_podman::util::_user_session_is_releasable().
sub user_has_granted_linger {
    my ($user) = @_;

    return 0 if !_is_valid_linger_user($user);
    return -e "$dir_granted_linger/$user" ? 1 : 0;
}

# Always re-touched, never skipped: the mtime has to track the enable-linger
# this call is recording. See grant_covers_current_linger().
sub record_linger_grant {
    my ($user) = @_;

    return 0 if !_is_valid_linger_user($user) || $user eq "root";

    mkdir( $dir_granted_linger, 0700 );    # the parent is packaged; harmless when it already exists
    chmod( 0700, $dir_granted_linger );

    local $@;
    eval { path("$dir_granted_linger/$user")->touch; 1 } or do {
        warn "Could not record the linger grant for “$user”: $@";
        return 0;
    };

    return 1;
}

sub revoke_linger_grant {
    my ($user) = @_;

    return 1 if !user_has_granted_linger($user);
    return unlink("$dir_granted_linger/$user") ? 1 : 0;
}

# A record says we granted *a* linger; this says whether it is the current one.
# We record just after enable-linger, so ours is never the older of the two — a
# newer systemd marker means somebody else enabled this linger after ours went
# away. Unreadable either way ➜ no, same as a missing record. (CPANEL-55309)
sub grant_covers_current_linger {
    my ($user) = @_;

    return 0 if !user_has_granted_linger($user) || !user_has_linger($user);

    my $granted_at      = ( stat("$dir_granted_linger/$user") )[9];
    my $lingering_since = ( stat("$dir_linger/$user") )[9];

    return 0 if !defined $granted_at || !defined $lingering_since;

    return $lingering_since <= $granted_at ? 1 : 0;
}

# The stop is asynchronous, and does not happen at all while a login session
# keeps the manager up. So wait a moment for the ordinary case, and reconcile:
# the unit goes now if the manager is confirmed stopped, and otherwise stays
# for the next reconcile_carveouts() from anywhere on the host, which finds it
# by its written/<uid> record. The release reports success either way, because
# the linger really is gone.
our $settle_iterations = 50;    # × $poll_sleeper (0.1s) ≈ 5s

sub _settle_carveout {
    my ($uid) = @_;

    return if !lstat( user_manager_carveout_file($uid) );

    # Wait for the state the removal insists on, not merely “not active”: a
    # manager that is `deactivating` is not active, but it is not confirmed
    # stopped either, and the removal would refuse it and leave for the next
    # reconcile what a few more polls would have finished.
    for ( 1 .. $settle_iterations ) {
        last if $user_manager_confirmed_stopped->($uid);
        $poll_sleeper->();
    }

    _reconcile_carveouts( [$uid] );

    return;
}

# Undo what ensure_user_session() set up. Idempotent: a no-op (and a “success”)
# when the user is not lingering in the first place. Deciding that a user no
# longer needs a rootless session is the caller’s job — see
# ea_podman::util::release_user_session(). (CPANEL-55309)
sub remove_user_session {
    my ($user) = @_;

    return 1 if !user_has_linger($user);

    $linger_disabler->($user);

    # `loginctl disable-linger` stops the manager, which is the only time the
    # account's own unit (see ensure_user_manager_carveouts) may go. Not before:
    # taking it from under a running manager and reloading kills it. (EA4-321)
    my $uid = ( getpwnam($user) )[2];
    _settle_carveout($uid) if defined $uid;

    # `loginctl disable-linger` can exit non-zero for reasons that leave the
    # linger correctly off (a stopped manager, for instance), so trust the
    # marker over the exit code.
    return user_has_linger($user) ? 0 : 1;
}

# `loginctl disable-linger` has no user to look up once an account has been
# deleted, but logind’s marker file outlives the account — and would silently
# linger any future account that reuses the name. Dropping the marker is
# precisely what disable-linger itself does. (CPANEL-55309)
sub remove_stale_linger_marker {
    my ($user) = @_;

    return 1 if !user_has_linger($user);
    return unlink("$dir_linger/$user") ? 1 : 0;
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
