#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea_podman/util.pm                       Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

package ea_podman::util;
######################
#### CAVEAT EMPTOR! ##
######################
# See POD for more on this, but TL;DR:
# All consumers of this module must ensure ea_podman::util::init_user()
#    is called prior to calling other functions (there are some exceptions in POD)
sub init_user {
    my (%opts) = @_;    # creating => 1 when about to make a container

    check_proc();

    # Order matters (CPANEL-54037): ensure_user() bootstraps the rootless
    # session *as root* (subuid/subgid + `loginctl enable-linger`, which
    # creates /run/user/<uid> and starts the user systemd manager). It must
    # run before ensure_su_login(), which points this (already unprivileged)
    # process’s XDG_RUNTIME_DIR/DBUS at that now-existing runtime dir.
    #
    # An account only gets that session if it has containers, or is making its
    # first one (`creating`). A user systemd manager exists to keep an
    # account’s containers running; an account without any needs nothing kept
    # running, and lingering every account that ran any ea-podman command was
    # CPANEL-55309. ensure_user() returns whether there is a session, so
    # ensure_su_login() knows whether to insist on the runtime dir.
    #
    # Nothing for a caller to pass about the grant: whether this is the call that
    # turns the linger on is decided root-side, from what is on disk.
    my $has_session = ensure_user( $opts{creating} );
    ensure_su_login($has_session);

    return $has_session;
}

sub check_proc {
    return if $> != 0;

    my $warn = "This could lead to information disclosure.\n";
    $warn .= "One way to mitigate this is for root to set hidepid to 2:\n";
    $warn .= "\t!!!! before running any of these commands be sure to understand their implications !!\n";

    `grep /proc /proc/mounts | grep hidepid=2`;
    if ( $? != 0 ) {
        warn "!!!! pids are currently public (/proc is not mounted hidepid=2) !!\n";
        warn "$warn\t`mount -o remount,rw,nosuid,nodev,noexec,relatime,hidepid=2 /proc`\n\n";
    }

    `grep /proc /etc/fstab | grep hidepid=2`;
    if ( $? != 0 ) {
        warn "!!!! pids will be public on reboot (/proc hidepid is not 2 in fstab) !!\n";
        warn "$warn\t`grep proc /etc/fstab`\n\tEnsure it has an entry like:\n\t\tproc    /proc    proc    defaults,nosuid,nodev,noexec,relatime,hidepid=2\n";
    }
}

use Cpanel::JSON           ();
use Cpanel::AdminBin::Call ();
use Cpanel::Time           ();
use File::Path::Tiny       ();
use Errno                  ();    # for %!, loaded explicitly: the CLI is a compiled binary
use Cwd                    ();
use Time::HiRes            ();

use Path::Tiny 'path';

# We call ea_podman::subids::* and consumers outside this repo require util.pm
# on its own, so load it here rather than rely on them. Sibling path because
# lib/ea_podman is not in @INC; guard because re-requiring under a different
# %INC key would reset subids.pm's package vars.
if ( !defined &ea_podman::subids::user_has_linger ) {
    my $subids_pm = __FILE__;
    $subids_pm =~ s{[^/]+\z}{subids.pm};
    $subids_pm = "./$subids_pm" if $subids_pm !~ m{\A[/.]};    # else require() searches @INC
    require $subids_pm;
}

# The middle segment is the owning user’s name. It used to be `[^.]+`, which
# accepted every shell metacharacter but a dot, so a hand-crafted name could
# reach a shell sink and run as the user outside its cage (CPANEL-55336). User
# names are alphanumeric, so allow only that — no metacharacters in any segment.
my $container_name_suffix_regexp      = qr/\.[a-z0-9]+\.[0-9][0-9]$/;
my $container_name_sans_suffix_regexp = qr/^[a-z][a-z0-9-]+[a-z0-9]/;

# Package variable so tests can point it at a scratch file.
our $known_containers_file = '/opt/cpanel/ea-podman/registered-containers.json';

# See
#     1. https://docs.docker.com/engine/reference/commandline/tag/#extended-description
#     2. https://regex101.com/r/hP8bK1/1
my $image_name_regexp = qr'^(?:(?=[^:\/]{4,253})(?!-)[a-zA-Z0-9-]{1,63}(?<!-)(?:\.(?!-)[a-zA-Z0-9-]{1,63}(?<!-))*(?::[0-9]{1,5})?/)?((?![._-])(?:[a-z0-9._-]*)(?<![._-])(?:/(?![._-])[a-z0-9._-]*(?<![._-]))*)(?::(?![.-])[a-zA-Z0-9_.-]{1,128})?$';

sub ensure_su_login {    # needed when $user is from root `su - $user` / AccessIds (cpsrvd, hooks) and not SSH
    my ($has_session) = @_;

    $ENV{DBUS_SESSION_BUS_ADDRESS} ||= "unix:path=/run/user/$>/bus";    # root can need this

    return if $> == 0;

    delete $ENV{XDG_RUNTIME_DIR} if $ENV{XDG_RUNTIME_DIR} && $ENV{XDG_RUNTIME_DIR} ne "/run/user/$>";
    $ENV{XDG_RUNTIME_DIR} ||= "/run/user/$>";

    # Run from a working directory the cpuser can actually stat. cpsrvd, the
    # `uapi --user=` CLI, and root `su`/AccessIds callers can leave us with a
    # cwd inherited from root (e.g. /root, mode 0700) that the cpuser cannot
    # enter — which breaks rootless podman and makes File::Path::Tiny::rm()
    # die while restoring cwd during cleanup. (CPANEL-54037: this — not the
    # cage — is what blocked cagefs users; the cpsrvd UAPI context runs
    # OUTSIDE the cage, so no special cage handling is needed.)
    my $home = ( getpwuid($>) )[7];
    chdir($home) if $home && -d $home;

    return if -d $ENV{XDG_RUNTIME_DIR};

    # No runtime dir. If this account was never given a session — it has no
    # containers and is not making one — that is expected, not an error: there
    # is nothing for a user systemd manager to keep alive (CPANEL-55309). Leave
    # the environment clean rather than pointing podman and systemctl at a
    # directory that does not exist; whatever we were asked to do either works
    # from the registry alone or has no container to act on, and will say so in
    # its own terms. An account that is simply logged in still has a runtime
    # dir, so this only concerns the no-session, no-login case.
    if ( !$has_session ) {
        delete $ENV{XDG_RUNTIME_DIR};
        delete $ENV{DBUS_SESSION_BUS_ADDRESS};
        return;
    }

    # The runtime dir + user systemd manager are bootstrapped *as root* in
    # ea_podman::subids::ensure_user_session() (`loginctl enable-linger`),
    # reached via ensure_user()/the ENSURE_USER adminbin, which init_user()
    # runs before us. We cannot create it here — privileges were already
    # dropped, which is exactly why the previous unprivileged
    # `loginctl enable-linger` attempt could never work. If it is still
    # missing, the privileged bootstrap did not run (or linger was torn down):
    # fail with a clear, actionable error rather than letting podman emit a
    # cryptic “Failed to connect to user scope bus” downstream.
    #
    # The first line’s wording is load-bearing: ea-podman.pl matches
    # /rootless runtime directory .* does not exist/ on it to fall back to the
    # EAPodman UAPI for a CageFS account (CPANEL-54672). Append to this die, do
    # not reword that sentence.
    my $user = getpwuid($>) // $>;
    die "ea-podman: the rootless runtime directory “$ENV{XDG_RUNTIME_DIR}” for “$user” does not exist.\n" . "The privileged setup must run first so `loginctl enable-linger $user` can create it (run `ea-podman subids --ensure` as root, or invoke via the ENSURE_USER adminbin / the cpsrvd path).\n" . _masked_user_manager_note();
}

# A masked `user@.service` is the other way an account ends up with no runtime
# dir/manager — not something the privileged setup the die above names can be
# blamed for. This note is printed *because* the root-side bypass did not get
# the manager up, so it must not claim that it did. (EA4-319; the bypass is
# ea_podman::subids::ensure_user_manager_carveouts().)
sub _masked_user_manager_note {

    # subids.pm is loaded by the guarded sibling require at the top of this file,
    # but keyed on an older symbol, so a vendored/stale copy can be in %INC
    # without this one. No explanation is better than dying for a footnote.
    return "" if !defined &ea_podman::subids::masked_user_manager_explanation;
    return "" if !ea_podman::subids::user_manager_mask_file();

    return "Note: " . ea_podman::subids::masked_user_manager_explanation();
}

sub podman {
    system( podman => @_ );
    my $rv = $? == 0 ? 1 : 0;
    return $rv;
}

# Cap on captured stdout/stderr from exec_in_container(), so a chatty or
# runaway command in the container can't blow up the UAPI JSON response.
my $EXEC_OUTPUT_CAP = 262_144;    # 256 KiB

# Run a one-shot, non-interactive command inside a container and capture its
# stdout/stderr/exit code — the `ea-podman cmd` / EAPodman `cmd` UAPI verb.
#
# We enter the running container's namespaces with `nsenter`, NOT `podman exec`.
# On a host that mounts /proc with hidepid=2 (a hardening ea-podman itself
# recommends, see check_proc()), a container's init process is owned by one of
# the user's *subuids*, so the cpuser cannot see /proc/<pid> and `podman exec`
# fails with "cannot exec in a stopped container" even though the container is
# running fine. Entering the namespaces as root sidesteps hidepid; `-U -S 0
# -G 0` re-maps the command to the container's own root (which is the cpuser on
# the host), so it runs with exactly the privileges `podman exec` would give it
# and no host privilege leaks in. Because only root can reach a subuid-owned,
# hidepid-hidden process, a non-root caller (the cpsrvd UAPI path, or an
# unrestricted-shell CLI user) delegates to the root ea-podman adminbin
# (EXEC_IN_CONTAINER), which validates ownership and calls
# exec_in_container_as_root(). See docs/container-shell-access.md.
sub exec_in_container {
    my ( $container_name, $cmd_argv, %opts ) = @_;
    validate_user_container_name($container_name);
    die "No command given\n" if !$cmd_argv || !@{$cmd_argv};

    if ( $> == 0 ) {
        return exec_in_container_as_root( $container_name, scalar getpwuid($>), $cmd_argv, $opts{cd} );
    }

    require Cpanel::AdminBin::Call;
    return Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'EXEC_IN_CONTAINER', $container_name, ( $opts{cd} // '' ), @{$cmd_argv} );
}

# Root-side worker for exec_in_container(). MUST run as root. Two cases:
#
#   * $owner is root's OWN container (root CLI path): root is not subject to
#     hidepid and root's containers are not subuid-remapped, so plain
#     `podman exec` works and is the simplest, correct mechanism.
#
#   * $owner is a DIFFERENT (cpuser) container — reached only from the ea-podman
#     adminbin: root cannot drive the cpuser's rootless podman, and hidepid hides
#     the container's init from the cpuser, so we resolve the init pid in the
#     owner's own context, verify it really is the owner's, and enter the
#     namespaces with nsenter (mapped to the container's own root = the cpuser).
sub exec_in_container_as_root {
    my ( $container_name, $owner, $cmd_argv, $cd ) = @_;
    die "exec_in_container_as_root must run as root\n" if $> != 0;
    validate_user_container_name($container_name);
    die "No command given\n" if !$cmd_argv || !@{$cmd_argv};

    if ( $owner eq scalar getpwuid($>) ) {
        my @podman_args = ('exec');
        push @podman_args, '--workdir',     $cd if length( $cd // '' );
        push @podman_args, $container_name, @{$cmd_argv};
        return _run_capture( 'podman', \@podman_args );
    }

    my $pid = resolve_container_init_pid( $container_name, $owner );
    _assert_pid_belongs_to_user( $pid, $owner );
    return _run_capture( 'nsenter', _nsenter_args( $pid, $cmd_argv, $cd ) );
}

# Run $program with @$args, capturing stdout/stderr (size-capped) and the real
# exit code. A non-zero exit code is returned as data, not an exception.
sub _run_capture {
    my ( $program, $args ) = @_;

    require Cpanel::SafeRun::Object;
    local $ENV{PATH} = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    my $run = Cpanel::SafeRun::Object->new( program => $program, args => $args );

    my ( $stdout, $stdout_truncated ) = _cap_output( $run->stdout );
    my ( $stderr, $stderr_truncated ) = _cap_output( $run->stderr );

    return {
        stdout           => $stdout,
        stderr           => $stderr,
        exit_code        => ( $run->CHILD_ERROR() // 0 ) >> 8,
        stdout_truncated => $stdout_truncated,
        stderr_truncated => $stderr_truncated,
    };
}

# Build the nsenter argv: enter the container's mount/uts/ipc/net/pid + user
# namespaces (-U) and become the container's own uid/gid 0 (-S 0 -G 0), which
# maps to the cpuser on the host. With an optional working directory we wrap in
# the container's /bin/sh (`cd DIR && exec …` — exactly the form CPANEL-54360
# calls for), since nsenter's own --wd is unreliable across the mount-ns switch.
# Without --cd the argv is exec'd directly, so NO shell is required (honoring
# "containers may not have bash"). The command is always passed as a list.
sub _nsenter_args {
    my ( $pid, $cmd_argv, $cd ) = @_;

    my @inside =
      length( $cd // '' )
      ? ( '/bin/sh', '-c', 'cd "$1" || exit 127; shift; exec "$@"', 'ea-podman-cmd', $cd, @{$cmd_argv} )
      : @{$cmd_argv};

    return [ '-t', $pid, '-U', '-m', '-u', '-i', '-n', '-p', '-S', '0', '-G', '0', '--', @inside ];
}

# Resolve the container's init process id by asking podman in $owner's OWN
# rootless context. podman reads its own db (not /proc), so hidepid does not
# block it, and podman only ever reports $owner's own containers. When $owner is
# not the current user we fork and drop privileges first, so the pid we act on
# is always derived from $owner's real view — never trusted from a caller.
sub resolve_container_init_pid {
    my ( $container_name, $owner ) = @_;

    my $reader = sub {
        local $ENV{XDG_RUNTIME_DIR} = "/run/user/$>";
        my $home = ( getpwuid($>) )[7];
        chdir($home) if $home && -d $home;
        require Cpanel::SafeRun::Object;
        my $r = Cpanel::SafeRun::Object->new(
            program => 'podman',
            args    => [ 'inspect', '--format', '{{.State.Pid}}', $container_name ],
        );
        my $out = $r->stdout // '';
        $out =~ s/\s+//g;
        return $out;
    };

    my $pid;
    if ( $owner eq scalar getpwuid($>) ) {
        $pid = $reader->();
    }
    else {
        pipe( my $rd, my $wr ) or die "Could not create a pipe: $!\n";
        my $kid = fork();
        die "Could not fork: $!\n" if !defined $kid;
        if ( $kid == 0 ) {
            close $rd;
            require Cpanel::AccessIds;
            eval {
                Cpanel::AccessIds::do_as_user_with_exception( $owner, sub { print {$wr} $reader->(); } );
            };
            close $wr;
            require POSIX;
            POSIX::_exit(0);
        }
        close $wr;
        local $/;
        $pid = <$rd> // '';
        close $rd;
        waitpid( $kid, 0 );
        $pid =~ s/\s+//g;
    }

    die "Could not determine a running process for “$container_name”.\n" if $pid !~ /^[1-9][0-9]*$/;
    return $pid;
}

# Refuse to nsenter into a pid that is not actually $owner's container process.
# Root bypasses hidepid so we CAN stat it; require its real uid to be $owner's
# own uid (container ran as root → maps to the cpuser) or one of $owner's
# subuids (container dropped privileges). Closes a pid-reuse / wrong-target hole.
sub _assert_pid_belongs_to_user {
    my ( $pid, $owner ) = @_;

    my $puid = ( stat("/proc/$pid") )[4];
    die "The container process ($pid) is gone.\n" if !defined $puid;

    my $ouid = ( getpwnam($owner) )[2];
    die "Unknown user “$owner”.\n" if !defined $ouid;
    return 1                       if $puid == $ouid;

    if ( open my $fh, '<', '/etc/subuid' ) {
        while ( my $line = <$fh> ) {
            chomp $line;
            my ( $who, $start, $count ) = split /:/, $line;
            next if !defined $count;
            next if $who ne $owner && $who ne $ouid;
            if ( $puid >= $start && $puid < $start + $count ) {
                close $fh;
                return 1;
            }
        }
        close $fh;
    }

    die "The process $pid is not owned by “$owner”; refusing to enter it.\n";
}

sub _cap_output {
    my ($text) = @_;
    $text = '' if !defined $text;
    return ( $text, 0 ) if length($text) <= $EXEC_OUTPUT_CAP;
    return ( substr( $text, 0, $EXEC_OUTPUT_CAP ), 1 );
}

# ea-podman manages containers through each user's systemd manager, and either
# cgroup hierarchy works for bring-up and serving — the shipped units are plain
# Type=forking (`podman generate systemd --name`, never `--new`/`--sdnotify`),
# so they reach "active" and the container runs on cgroup v1 or v2. We therefore
# never *block* on the cgroup version. The one genuinely problematic combination
# is **CloudLinux + cgroup v2**: the LVE kernel relocates every non-root user's
# processes into its own cgroup (`/lvub/lve<uid>`), and under cgroup v2's single
# unified hierarchy a process can live in only one node, so LVE's placement and
# systemd's per-user `user.slice` are mutually exclusive — `systemd --user` dies
# and the restricted/CageFS path that depends on it fails. On CloudLinux the
# supported configuration is cgroup v1; we advise (warn only, never die) when we
# detect CloudLinux running on v2.
sub _is_cgroup_v2 { return -e '/sys/fs/cgroup/cgroup.controllers' ? 1 : 0; }

# True only on CloudLinux, whose LVE kernel is the source of the v2 conflict.
sub _is_cloudlinux {
    return 1 if -e '/etc/cloudlinux-release';
    for my $f ( '/etc/redhat-release', '/etc/os-release' ) {
        next if !-r $f;
        open my $fh, '<', $f or next;
        local $/;
        my $c = <$fh> // '';
        close $fh;
        return 1 if $c =~ /cloudlinux/i;
    }
    return 0;
}

# Direct CLI (root / unrestricted-shell) sets this to 0 in ea-podman.pl::run()
# to stay silent. The UAPI/restricted path loads this module directly and leaves
# it at 1, so it keeps the advisory (non-fatal).
our $EMIT_CGROUP_ADVISORY = 1;

# Returns true when the host's cgroup configuration is fine for ea-podman (or
# the advisory is suppressed). Returns false after a non-fatal warning on the
# one problematic combination — CloudLinux + cgroup v2 — which breaks the
# per-user systemd manager under LVE.
sub warn_if_problematic_cgroup {
    return 1 unless _is_cloudlinux() && _is_cgroup_v2();
    return 1 unless $EMIT_CGROUP_ADVISORY;                 # direct CLI path: stay silent
    warn "ea-podman: this CloudLinux host is using cgroup v2.\n"
      . "CloudLinux's LVE kernel and cgroup v2 are mutually exclusive with the per-user systemd manager ea-podman relies on, so the user session can fail to start and containers may not come up.\n"
      . "Switch back to cgroup v1 and reboot:  tuned-adm profile cloudlinux-default-cgv1 && reboot\n"
      . "(verify afterward: `stat -fc %T /sys/fs/cgroup` reports tmpfs, not cgroup2fs).\n";
    return 0;
}

sub sysctl {

    # Advise about a problematic cgroup config only for bring-up actions;
    # stop/disable/etc. never warn so an existing container can be torn down
    # quietly on a CloudLinux + cgroup v2 host.
    warn_if_problematic_cgroup() if grep { $_ eq 'start' || $_ eq 'restart' || $_ eq 'enable' } @_;

    system( systemctl => "--user", @_ );    # ¿ if $> == 0 do --root => "~/.config/systemd/user" instead of `--user` ?
    my $rv = $? == 0 ? 1 : 0;
    return $rv;
}

sub is_user_container_name_running {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    $container_name = quotemeta($container_name);
    `podman ps --no-trunc --format "{{.Names}}" | grep --quiet ^$container_name\$`;
    return $? == 0 ? 1 : 0;
}

sub is_user_container_id_running {
    my ($container_id) = @_;    # short and long .ID (since the regex is not anchored at the end)

    $container_id = quotemeta($container_id);
    `podman ps --no-trunc --format "{{.ID}}" | grep --quiet ^$container_id`;
    return $? == 0 ? 1 : 0;
}

sub remove_user_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return podman( rm => "--ignore", $container_name );
}

sub stop_user_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    # It is impossible to suppress the error messages emanating from this call
    # via system, however backticks suppresses them
    # Since this is a shell string, the name must be escaped (CPANEL-55336).

    my $container_name_qx = quotemeta($container_name);
    `podman stop --ignore --time 30 $container_name_qx 2> /dev/null > /dev/null`;

    return;
}

# What the last failed `podman create` said, for the caller to build its error
# from. Undef after a success, so a later failure is never mistaken for it.
# A package variable rather than a return value because create_user_container()
# returns a boolean that two callers test.
our $_create_output;

sub create_user_container {
    my ( $container_name, @start_args ) = @_;
    validate_user_container_name($container_name);

    # start args should already have been validated and ports added
    # So we do not want this here: validate_start_args( \@start_args );

    # Pin the container's nproc ulimit to what the user's systemd manager allows.
    # podman bakes the *creating* process's RLIMIT_NPROC into the container, and
    # when we are invoked through the EAPodman UAPI the creator is cpsrvd, which
    # runs with nproc=unlimited. The container is later started by the user's
    # (lingering) systemd --user manager, whose RLIMIT_NPROC is finite, so crun's
    # setrlimit(RLIMIT_NPROC, unlimited) fails with EPERM and the container never
    # starts. Pinning to the manager's own limit makes the bake always
    # applicable. (Placed before @start_args so an arbitrary-image caller can
    # still override it.) See CPANEL-54037.
    my @ulimit;
    if ( my $cap = _user_manager_nproc_cap() ) {
        @ulimit = ( "--ulimit" => "nproc=$cap:$cap" );
    }

    my ( $ok, $said ) = _podman_create_captured( 'create', "--name" => $container_name, @ulimit, @start_args );
    $_create_output = $ok ? undef : $said;

    return $ok;
}

# The shell-out create_user_container() goes through. Its own sub so a test can
# supply what podman said without podman.
#
# Runs podman in a child whose stdout and stderr are one pipe, and echoes what
# arrives as it arrives, so a person at a terminal still sees an image pull's
# progress live and keeps what podman said for the error message. Deliberately
# not Capture::Tiny::tee: that starts helper subprocesses, which time out inside
# the compiled ea-podman binary ("Timed out waiting for subprocesses to start"),
# and that aborted the install before its cleanup ran. (EA4-335)
#
# Falls back to a plain, uncaptured podman() if the pipe or the fork is refused,
# so this can only ever lose the message, never the create.
sub _podman_create_captured {
    my @args = @_;

    pipe( my $reader, my $writer ) or return ( podman(@args), '' );

    # What system() did for free, and this fork/exec no longer does:
    #   * INT and QUIT are ignored in the parent while the child runs. A Ctrl-C
    #     reaches podman through the terminal's process group; ea-podman must
    #     outlive it to see the create fail and run its cleanup / rollback.
    #   * TERM and HUP (system() never covered these) are forwarded to podman,
    #     which is the only process that could act on them, and ea-podman then
    #     waits for it. Without that, a kill aimed at ea-podman alone would end
    #     it mid-create with the pipe and the child both orphaned.
    # `local`, so every return path restores the caller's handlers.
    my ( $child, @got );
    my $forward = sub {
        push @got, $_[0];
        kill( $_[0], $child ) if $child;
    };
    local @SIG{qw(INT QUIT TERM HUP)} = ( 'IGNORE', 'IGNORE', $forward, $forward );

    my $pid = fork();
    if ( !defined $pid ) {
        close $reader;
        close $writer;
        return ( podman(@args), '' );
    }

    if ( !$pid ) {

        # IGNORE survives exec, so podman would never see a Ctrl-C. Put every
        # disposition back before anything else.
        @SIG{qw(INT QUIT TERM HUP)} = ('DEFAULT') x 4;

        close $reader;
        open( STDOUT, ">&", $writer ) or kill( "KILL", $$ );
        open( STDERR, ">&", $writer ) or kill( "KILL", $$ );
        close $writer;

        # If exec fails, KILL rather than exit so a child never runs the
        # parent's END blocks or destructors.
        exec( "podman", @args ) or kill( "KILL", $$ );
    }

    close $writer;

    # A TERM or HUP that landed between fork() and this line had no pid to go to.
    $child = $pid;
    kill( $_, $pid ) for grep { $_ eq 'TERM' || $_ eq 'HUP' } @got;

    my $said = '';
    while (1) {
        my $n = sysread( $reader, my $chunk, 65536 );
        if ( !defined $n ) {
            next if $! + 0 == 4;    # EINTR
            last;
        }
        last if !$n;

        print STDERR $chunk;
        $said .= $chunk;

        # Only the tail is ever used; do not hold a whole verbose pull.
        $said = substr( $said, -65536 ) if length($said) > 131072;
    }
    close $reader;

    1 while waitpid( $pid, 0 ) == -1 && $! + 0 == 4;    # EINTR

    # If podman finished anyway the create worked and is reported as such; the
    # note is only for the failure the interruption caused.
    my $ok = $? == 0 ? 1 : 0;
    if ( !$ok && @got ) {
        my %seen;
        my $names = join( ", ", map { "SIG$_" } grep { !$seen{$_}++ } @got );
        $said .= "\n" if length($said) && $said !~ /\n\z/;
        $said .= "ea-podman was interrupted ($names) while podman was creating the container.\n";
    }
    return ( $ok, $said );
}

# The RLIMIT_NPROC hard cap of the calling user's systemd --user manager (which
# is what actually starts the container). Asked of the system manager first, so
# it works without the user bus. CloudLinux's D-Bus policy refuses an
# unprivileged uid any systemd1 property read ("Access denied"), so fall back
# to asking the user manager itself, over its private socket under
# XDG_RUNTIME_DIR, for the default it gives its units — the container unit sets
# no LimitNPROC of its own. Without that fallback nothing was pinned there and a
# container created from cpsrvd (nproc=unlimited) never started (EA4-315).
# Returns undef when the limit is unlimited/unknown (nothing to pin — an
# unlimited manager applies an unlimited bake just fine).
sub _user_manager_nproc_cap {
    my $uid = $>;

    for my $query ( [ "show", "user\@$uid.service", "-p", "LimitNPROC", "--value" ], [ "show", "-p", "DefaultLimitNPROC", "--value" ], [ "--user", "show", "-p", "DefaultLimitNPROC", "--value" ] ) {
        my $cap = _systemctl_value( @{$query} );
        return $cap if $cap =~ /^[0-9]+$/;
    }

    return;
}

# Its own sub so tests have a seam that does not need systemd.
sub _systemctl_value {
    my @args = map { quotemeta } @_;
    my $val  = `systemctl @args 2>/dev/null` // '';
    chomp($val);
    return $val;
}

sub get_container_service_name {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return "container-$container_name.service";
}

# Its own named sub so tests have a seam that does not need podman — a bare
# backtick has none, which is why get_containers() had no real test. Chomps here,
# once, rather than letting the newline ride along inside every caller's image
# name: split() with a limit of 2 lets the second field absorb it, so `image` used
# to end in "\n". Harmless in `list`, silently fatal to any comparison built on
# that field. (EA4-325)
sub _podman_ps_names_and_images {
    my @lines = `podman ps --no-trunc --format "{{.Names}} {{.Image}}"`;
    chomp @lines;
    return @lines;
}

sub get_containers {
    my %containers;

    # Rootless podman cannot have anything running for this account without a
    # runtime dir, so there is nothing to ask it about — and asking would only
    # get a “XDG_RUNTIME_DIR not set”-flavoured complaint. An account with no
    # containers is no longer given one (CPANEL-55309).
    return \%containers if $> != 0 && !-d "/run/user/$>";

    for my $line ( _podman_ps_names_and_images() ) {
        my ( $name, $image ) = split( " ", $line, 2 );
        $containers{$name} = { image => $image, ports => [ _get_current_ports($name) ] };    # empty list == no ports
    }

    return \%containers;
}

sub get_next_available_container_name {    # ¿TODO/YAGNI?: make less racey
    my ($name) = @_;                       # ea-pkg or arbitrary-name
    die "Invalid name\n" if !length($name) || $name !~ m/$container_name_sans_suffix_regexp$/;

    $name .= "." . scalar getpwuid($>) . ".%02d";

    my $max          = 99;
    my $container_hr = load_known_containers();    # running (get_containers()) or not

    # $container_hr does not need non-root entires filtered out when $> == 0 because
    #   1. The $name has the user so root’s call will not get mixed up when $container_hr has a key name foo.bob.99
    #   2. Since the names are generated a non-root user can’t register foo.root.42
    #   3. If they found a way to do ^^^ the worst case senario is root get a different number
    #      * if they used up all 99 options then there would be an error to indicate something is awry

    my $container_root = _get_container_root();
    my $container_name;
    for my $n ( 1 .. $max ) {
        my $path = sprintf( $name, $n );
        if ( !exists $container_hr->{$path} && !-e "$container_root/$path" && !-e "$container_root/$path.bak" ) {
            $container_name = $path;
            last;
        }
    }

    die "Could not find an available name for “$name” () tried $max times\n" if !$container_name;
    return $container_name;
}

sub get_pkg_from_container_name {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return if $container_name !~ m/^ea-/;

    $container_name =~ s/$container_name_suffix_regexp//g;
    return $container_name;
}

sub container_name_belongs_to_user {
    my ( $container_name, $user ) = @_;

    return 0 if !defined $container_name || !defined $user;
    return $container_name =~ m/\.\Q$user\E\.[0-9][0-9]$/ ? 1 : 0;
}

# What `podman generate systemd` leaves to systemd's defaults: 5 restarts 100ms
# apart, so a container that crashes on start is failed forever half a second
# in. 137 is left out of SuccessExitStatus — that is also an OOM kill.
our %container_unit_directives = (
    Unit => [
        "StartLimitIntervalSec=300",
        "StartLimitBurst=3",
    ],
    Service => [
        "RestartSec=5",
        "SuccessExitStatus=143",
    ],
);

# Add %container_unit_directives to a generated unit, under the section each
# belongs to. Leaves alone any the generator already wrote, so it is idempotent.
# Pure args-in/string-out so it is unit-testable.
sub _add_container_unit_directives {
    my ($unit) = @_;

    my %present;    # section => { lc directive name => 1 }
    my $section = "";
    for my $line ( split( m/\n/, $unit, -1 ) ) {
        $section                    = $1 if $line =~ m/^\s*\[(\w+)\]\s*$/;
        $present{$section}{ lc $1 } = 1  if $line =~ m/^\s*(\w+)\s*=/;
    }

    my ( @out, %added );
    for my $line ( split( m/\n/, $unit, -1 ) ) {
        push @out, $line;
        next if $line !~ m/^\s*\[(\w+)\]\s*$/;

        my $sec = $1;
        $added{$sec} = 1;
        for my $directive ( @{ $container_unit_directives{$sec} || [] } ) {
            my ($name) = $directive =~ m/^(\w+)=/;
            push @out, $directive if !$present{$sec}{ lc $name };
        }
    }

    # podman writes both sections today; write one it did not rather than
    # silently dropping the directives that belong in it.
    for my $sec ( sort keys %container_unit_directives ) {
        next if $added{$sec};
        push @out, "[$sec]", @{ $container_unit_directives{$sec} }, "";
    }

    return join( "\n", @out );
}

# Does this upgrade have anything to do?
#
# Returns 1 when the container must be recreated, 0 when nothing moved. The
# answer differs by container kind, because what "changed" means differs
# (EA4-325 B2, B8):
#
#   arbitrary image  the image ID the reference now resolves to, against the ID
#                    the container was created from.
#
#   EA4 package      the RPM owns BOTH the image pin and the start args, so the
#                    image alone is the wrong question -- a package update can
#                    change `startup` flags while pinning the same image, and an
#                    image-only gate would silently not apply it. Gate on the
#                    package version, OR the image, so a re-pushed upstream tag
#                    is still picked up. Never on the image alone.
#
# Either kind also needs a recreate when it is a web app still published on
# every interface. EA4-327 binds web app ports to 127.0.0.1 only, but -p is fixed
# when the container is created, so a web app created before EA4-327 keeps its
# public binding until it is recreated. EA4-327 relied on the next upgrade doing
# that recreate. Before this gate, every upgrade did; now one with an unmoved
# image would not. The image is the same, but the container's desired config
# is not.
#
# Cannot-tell is treated as "needed". Guessing "not needed" from missing
# information is how a container silently stops being updated.
sub _upgrade_is_needed {
    my ( $container_name, $image_ref, $pkg, $force, $webapp ) = @_;

    return 1 if $force;    # force never asks

    return 1 if $webapp && !_container_ports_all_loopback($container_name);

    my $image_moved = sub {
        my $current  = _get_container_image_id($container_name);
        my $resolved = defined $image_ref ? _get_image_id($image_ref) : undef;
        return 1 if !defined $current || !defined $resolved;
        return $current ne $resolved ? 1 : 0;
    };

    if ( length( $pkg // '' ) ) {
        my ( $container_ver, $package_ver ) = eval { get_pkg_versions( $container_name => $pkg ) };
        return 1 if $@;                                                          # cannot tell
        return 1 if !defined $container_ver || $container_ver ne $package_ver;
        return $image_moved->();
    }

    return $image_moved->();
}

# Pull an image reference, so "has it changed?" is a question with a real answer.
#
# Without this the comparison below is vacuous: `podman create` inherits
# --pull=missing, so the local image for a tag stays whatever was cached when the
# container was installed, and comparing that to the container's own image always
# matches. Safe mode would then no-op forever and nothing would ever update.
#
# Memoized for the life of the process, which is exactly one `ea-podman` run: an
# `upgrade_containers --all` sweep across many containers on the same image pulls
# it once, not once each (EA4-325 B5). Never dies -- a pull failure is a decision
# for the caller, and the two paths want opposite answers (B4).
our %_pulled;        # image reference => success boolean
our %_pull_error;    # image reference => what podman said, for the failure message

sub _podman_pull {
    my ($image_ref) = @_;

    return $_pulled{$image_ref} if exists $_pulled{$image_ref};

    return $_pulled{$image_ref} = _podman_pull_once($image_ref);
}

# The shell-out _podman_pull memoizes around. Its own sub so the memoization is
# testable: a bare backtick cannot be mocked, so a test that replaced
# _podman_pull itself would be testing its own reimplementation rather than the
# cache -- which is exactly what the first version of that test did.
sub _podman_pull_once {
    my ($image_ref) = @_;

    my $image_qx = quotemeta($image_ref);
    my $out      = `podman pull $image_qx 2>&1`;
    return 1 if $? == 0;

    $_pull_error{$image_ref} = $out // '';
    return 0;
}

# What podman's own words say went wrong, as far as we can tell. One classifier
# for a failed pull and a failed create, because `podman create` pulls the image
# itself when it is not cached and so fails for the same reasons (EA4-335).
#
# A registry rate limit and a full disk are distinguishable and actionable, and
# worth telling apart from a typo'd image or a DNS failure -- the remedies are
# nothing alike. The rate limit also became much easier to hit: since EA4-325
# Increment B every `upgrade` pulls, where none did before.
sub _podman_failure_reason {
    my ($out) = @_;

    $out //= '';
    return "rate_limit" if $out =~ m/toomanyrequests|rate limit/i;
    return "disk_quota" if $out =~ m/disk quota exceeded|no space left on device/i;

    return "unknown";
}

# Why the last pull of this reference failed, as far as we can tell.
sub _pull_failure_reason {
    my ($image_ref) = @_;

    return _podman_failure_reason( $_pull_error{$image_ref} );
}

# The most of podman's output worth putting in an error message.
my $CREATE_OUTPUT_CAP = 2048;

# podman's output made safe to put in an exception: bounded to its tail (the
# error is at the end), and stripped of what would corrupt a log or a terminal.
sub _podman_output_tail {
    my ($out) = @_;

    return '' if !defined $out;

    $out =~ s/\r\n?/\n/g;                          # a progress bar redraws with \r
    $out =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g;          # ANSI escape sequences
    $out =~ tr/\x00-\x08\x0b-\x1f\x7f//d;           # other control characters, keeping \n and \t
    $out =~ s/\s+\z//;

    if ( length($out) > $CREATE_OUTPUT_CAP ) {
        $out = substr( $out, -$CREATE_OUTPUT_CAP );
        $out =~ s/\A[\x80-\xBF]+//;                   # do not start on half a UTF-8 character
    }

    $out =~ s/\A\s+//;
    return $out;
}

# The text a failed create appends to its error: a plain sentence when the cause
# is one the account owner can act on, then what podman said. Empty when podman
# said nothing, so the message is exactly what it was. Argument-pure so it is
# unit-testable. (EA4-335)
sub _create_failure_note {
    my ($out) = @_;

    my $tail = _podman_output_tail($out);
    return '' if !length $tail;

    my $lead = _podman_failure_reason($tail) eq "disk_quota" ? "The account has run out of disk space or reached its disk quota. Free up space, or ask your provider for a larger quota, then try again.\n" : '';

    return $lead . "podman reported:\n$tail\n";
}

# The local image ID a reference currently resolves to, or undef when podman has
# no such image.
#
# The ID, deliberately, not the registry digest (EA4-325 B6). They live in
# different namespaces -- measured on a live box, the same image reports
# Id=17aba4293f3b… and RepoDigest=sha256:570743f3…, so a digest comparison would
# differ forever and recreate on every run.
sub _get_image_id {
    my ($image_ref) = @_;

    my $image_qx = quotemeta($image_ref);
    chomp( my $id = `podman image inspect --format '{{.Id}}' $image_qx 2> /dev/null` );

    return if $? != 0 || !length($id);
    return $id;
}

# The image ID a container was created from -- the other half of the comparison.
# Its own sub so tests have a seam that does not need podman.
sub _get_container_image_id {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    my $container_name_qx = quotemeta($container_name);
    chomp( my $id = `podman inspect --format '{{.Image}}' $container_name_qx 2> /dev/null` );

    return if $? != 0 || !length($id);
    return $id;
}

# Whether every port the container publishes is bound to 127.0.0.1. Returns 1
# when they all are (including when it publishes none), 0 when any is not, and
# undef when podman cannot say. Its own sub so tests have a seam that does not
# need podman. (EA4-327 via EA4-325)
sub _container_ports_all_loopback {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    my $container_name_qx = quotemeta($container_name);
    my $json              = `podman inspect --format '{{json .HostConfig.PortBindings}}' $container_name_qx 2> /dev/null`;
    return if $? != 0 || !length( $json // '' );

    my $bindings = eval { Cpanel::JSON::Load($json) };
    return   if $@;
    return 1 if !$bindings;                # "null": publishes nothing
    return   if ref $bindings ne 'HASH';

    for my $host_list ( values %{$bindings} ) {
        for my $binding ( @{ $host_list || [] } ) {
            return 0 if ( $binding->{HostIp} // '' ) ne '127.0.0.1';
        }
    }

    return 1;
}

# The fully-qualified image a container was created from, e.g.
# "docker.io/library/httpd:2.4". Its own named sub so tests have a seam that does
# not need podman.
#
# `podman inspect`, not `podman ps`: ps omits a stopped container, and upgrading a
# stopped container is legal. This is the only place the previous image is
# knowable — the registry keeps just the basename (see the $image_name computed in
# _ensure_latest_container), which is enough to display and not enough to recreate
# from. Returns undef when podman cannot say, which callers must treat as
# “unknown”, never as an image. (EA4-325)
sub _get_container_image_ref {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    my $container_name_qx = quotemeta($container_name);
    chomp( my $ref = `podman inspect --format '{{.ImageName}}' $container_name_qx 2> /dev/null` );

    return if $? != 0 || !length($ref);
    return $ref;
}

# Its own sub so tests have a seam that does not need podman.
sub _podman_generate_systemd {
    my ($container_name) = @_;

    my $container_name_qx = quotemeta($container_name);
    my $unit              = `podman generate systemd --restart-policy on-failure --name $container_name_qx`;
    die "Failed to generate service file\n" if $? != 0;

    return $unit;
}

sub generate_container_service {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    my $homedir = ( getpwuid($>) )[7];
    File::Path::Tiny::mk( "$homedir/.config/systemd/user", 0750 );
    my $service_name = get_container_service_name($container_name);

    my $unit = _add_container_unit_directives( _podman_generate_systemd($container_name) );
    path("$homedir/.config/systemd/user/$service_name")->spew($unit);

    # The unit changed on disk; without this the manager goes on using the copy
    # it already parsed, so an existing container would keep its old directives.
    sysctl("daemon-reload") || warn "Failed to reload the systemd user manager, “$service_name” may still be running under its previous settings\n";

    sysctl( enable => $service_name ) || die "Failed to enable “$service_name”\n";
    return 1;
}

# Silent sysctl(), since systemctl gripes about an unloaded unit and system()
# cannot suppress that. Its own sub so tests have a seam.
sub _systemctl_quiet {
    my (@args) = @_;

    my $args_qx = join( " ", map { quotemeta } @args );
    `systemctl --user $args_qx 2> /dev/null > /dev/null`;

    return $? == 0 ? 1 : 0;
}

# Clear the `failed` state a stop or a used-up StartLimitBurst leaves behind.
sub reset_container_unit_failure {
    my ($container_name) = @_;
    return _systemctl_quiet( "reset-failed", get_container_service_name($container_name) );
}

# Capturing sibling of _systemctl_quiet(): the value of one unit property.
# _systemctl_quiet() throws stdout away, so it cannot read one. Its own named sub
# so tests have a seam — a bare backtick has none. Returns "" when systemctl
# could not answer at all (unknown unit, no user manager), which callers must
# treat as “we do not know”, never as a state. (EA4-325)
sub _systemctl_show {
    my ( $unit, @properties ) = @_;

    my $unit_qx = quotemeta($unit);
    my $prop_qx = join( " ", map { "-p " . quotemeta($_) } @properties );

    my $out = `systemctl --user show $unit_qx $prop_qx 2> /dev/null`;
    return {} if $? != 0;

    my %value;
    for my $line ( split( m/\n/, $out ) ) {
        $value{$1} = $2 if $line =~ m/^(\w+)=(.*)$/;
    }

    return \%value;
}

# The start-verdict poll, as package variables so a test can exercise the
# timeout and the confirmation without actually sleeping for them.
our $unit_poll_interval_sec = 0.25;
our $unit_poll_sleeper      = sub { Time::HiRes::usleep(250_000) };    # 0.25s

# How long an `active` sighting must persist before it counts. A crash-looping
# unit is genuinely `active` for the moment the container runs on each attempt —
# measured on a live box, a window ≤0.25s wide — so a single sample can land on
# one and report a crash loop as a success. 0.5s is the same value, for the same
# hazard, that Cpanel::WebApps::Podman::is_running() uses as $CONFIRM_DELAY.
# Deliberately short: the assertion is that it started, not that it stays up, and
# every successful upgrade pays this. (EA4-325)
our $unit_active_confirm_sec = 0.5;

# Headroom over the restart budget for the container's own run time per attempt.
our $unit_settle_slack_sec = 10;

# One directive's value out of %container_unit_directives, whichever section it
# is written under. undef when we do not write that directive at all.
sub _container_unit_directive {
    my ($name) = @_;

    for my $section ( sort keys %container_unit_directives ) {
        for my $directive ( @{ $container_unit_directives{$section} } ) {
            return $1 if $directive =~ m/^\s*\Q$name\E\s*=\s*(.*?)\s*$/i;
        }
    }

    return undef;
}

# Enough of a systemd timespan parser for the directives we write ourselves.
# Returns undef on anything it does not recognise, so a malformed directive
# falls back to a default rather than being fatal to an upgrade.
sub _systemd_timespan_to_sec {
    my ($span) = @_;

    return undef if !defined $span;
    $span =~ s/\s+//g;
    return undef if $span !~ m/^([0-9]+(?:\.[0-9]+)?)(us|ms|s|sec|secs|second|seconds|m|min|mins|minute|minutes)?$/i;

    my ( $num, $unit ) = ( $1, lc( $2 // "s" ) );
    my %mult = (
        us => 1 / 1_000_000,
        ms => 1 / 1_000,
        ( map { $_ => 1 } qw(s sec secs second seconds) ),
        ( map { $_ => 60 } qw(m min mins minute minutes) ),
    );

    return $num * $mult{$unit};
}

# How long a just-started container unit may take to reach a terminal state.
# Derived from the directives we write into the unit ourselves
# (%container_unit_directives) plus the generator's `--restart-policy
# on-failure`: systemd waits RestartSec between attempts and gives up after
# StartLimitBurst of them, so no verdict can arrive later than
# RestartSec × StartLimitBurst, plus the container's own run time each attempt.
# Derived rather than a constant so retuning either directive moves the ceiling
# with it.
#
# Only valid because reset_container_unit_failure() runs immediately before the
# start: `reset-failed` clears the rate-limit counter, so the full
# StartLimitBurst budget is actually available. Without that,
# StartLimitIntervalSec=300 could leave far less of it.
#
# Measured against a live box at the default 5 × 3: a crash-looping unit reached
# `failed` 15.8s after a clean start. (EA4-325)
sub container_unit_settle_ceiling_sec {
    my $restart_sec = _systemd_timespan_to_sec( _container_unit_directive("RestartSec") ) // 5;

    my $burst = _container_unit_directive("StartLimitBurst") // 3;
    $burst = 3 if $burst !~ m/^[0-9]+$/ || $burst < 1;

    return ( $restart_sec * $burst ) + $unit_settle_slack_sec;
}

# Poll a just-started container's unit to a terminal verdict. Returns one of:
#
#   active   — up, and still up $unit_active_confirm_sec later
#   failed   — systemd gave up on it
#   crashed  — settled inactive after a non-zero exit
#   stopped  — settled inactive cleanly (a deliberate stop, or an unreachable
#              session: both look like this, which is why the die says so)
#   unknown  — systemctl could not answer at all
#   timeout  — never left activating inside the ceiling
#
# ActiveState alone is not enough. `inactive` covers a clean stop, a container
# that is gone, and a session we cannot see; Result is what separates them.
sub wait_for_container_unit_verdict {
    my ($container_name) = @_;

    my $unit       = get_container_service_name($container_name);
    my $ceiling    = container_unit_settle_ceiling_sec() + $unit_active_confirm_sec;
    my $iterations = int( $ceiling / $unit_poll_interval_sec ) + 1;
    my $confirms   = int( $unit_active_confirm_sec / $unit_poll_interval_sec ) + 1;

    my $active_run = 0;

    for ( 1 .. $iterations ) {
        my $show   = _systemctl_show( $unit, "ActiveState", "Result" );
        my $state  = $show->{ActiveState} // "";
        my $result = $show->{Result}      // "";

        if ( $state eq "active" ) {

            # Provisional, not a verdict — see $unit_active_confirm_sec.
            return "active" if ++$active_run >= $confirms;
        }
        elsif ( $state eq "activating" || $state eq "reloading" || $state eq "deactivating" ) {

            # Includes SubState=auto-restart, the RestartSec backoff between
            # attempts, which is where a failing container spends most of the
            # window before systemd gives up on it.
            $active_run = 0;
        }
        elsif ( $state eq "failed" ) {
            return "failed";
        }
        elsif ( $state eq "inactive" ) {
            return $result eq "success" ? "stopped" : "crashed";
        }
        else {
            return "unknown";    # includes "" — systemctl told us nothing
        }

        $unit_poll_sleeper->();
    }

    return "timeout";
}

# The verdict, as a die. Split from the poll so the poll stays a pure state
# reporter and each half can be tested on its own.
#
# `lead` and `note` let a caller that is not an upgrade say so — the EAPodman
# UAPI's start/restart use the same poll, and telling someone their `start`
# "was upgraded" would be nonsense.
sub verify_container_started {
    my ( $container_name, %opts ) = @_;

    my $verdict = wait_for_container_unit_verdict($container_name);
    return 1 if $verdict eq "active";

    my $unit    = get_container_service_name($container_name);
    my $user    = scalar getpwuid($>);
    my $ceiling = container_unit_settle_ceiling_sec() + $unit_active_confirm_sec;

    my %what = (
        failed  => "its service “$unit” failed",
        crashed => "its service “$unit” started and then exited",
        stopped => "its service “$unit” is not running",
        unknown => "the user systemd manager for “$user” could not be asked about “$unit”",
        timeout => "its service “$unit” was still trying to start ${ceiling}s later and never settled",
    );

    my $hint = "";
    $hint = "That account's systemd user session may not be up. As root, `ea-podman ensure_user_sessions` starts the managers every account with containers needs.\n"
      if $verdict eq "unknown" || $verdict eq "stopped";

    my $lead = $opts{lead} // "“$container_name” was upgraded, but it did not come back up";
    my $note =
      defined $opts{note}
      ? $opts{note}
      : "The upgrade itself completed — the container was recreated from the image its configuration names — so this is the container declining to run, not a half-applied upgrade. The previous container is gone either way.\n";

    die "$lead: $what{$verdict}.\n" . $note . $hint . "Find out why with `systemctl --user status $unit`, `journalctl --user -u $unit`, and the container's own output, `podman logs $container_name` (as root: `su - $user -c '…'`).\n" . "Once the cause is fixed, `ea-podman upgrade $container_name` runs the whole thing again, or `systemctl --user start $unit` just starts it.\n";
}

# Install-time hook for the cpanel-webapp-plugin (--webapp-dir). Package
# variable so tests can point it at the repo copy.
our $webapp_dir_setup_script = "/opt/cpanel/ea-podman/webapp-dir-setup";

sub _ensure_latest_container {
    my ( $container_name, $opts, @start_args ) = @_;

    $opts ||= {};

    warn_if_problematic_cgroup();    # advise (non-fatal) on CloudLinux + cgroup v2

    validate_user_container_name($container_name);

    # Every path that brings a container into existence comes through here
    # (install, restore, upgrade), so this is where the account is guaranteed
    # the lingering session its containers need — whichever caller got us here,
    # in this repo or another, and whether or not it thought to tell
    # init_user() what it was about to do. (CPANEL-55309)
    ensure_container_session();

    _ensure_backup_conf_excludes_files();

    # Which of the three creation paths we are on. The caller says so outright
    # instead of us inferring it from caller(1): a stack frame is not a contract,
    # and the inference silently stopped matching as soon as a call site was
    # wrapped in an eval, which reports “(eval)” rather than the enclosing sub.
    # (CPANEL-55309)
    my $op        = $opts->{op} // "";
    my $isupgrade = 0;
    my $isrestore = 0;
    my $portsfunc;
    if ( $op eq "install" ) {
        $portsfunc = \&_get_new_ports;
    }
    elsif ( $op eq "upgrade" ) {
        $portsfunc = \&_get_current_ports;
        $isupgrade = 1;
    }
    elsif ( $op eq "restore" ) {
        $isrestore = 1;
        $portsfunc = \&_get_new_ports;
    }
    else {
        die "_ensure_latest_container() must be told which operation it is performing — install, upgrade, or restore (not “$op”)\n";
    }

    my $container_root = _get_container_root();
    my $container_dir  = "$container_root/$container_name";

    if ( $isupgrade || $isrestore ) {
        die "“$container_dir” does not exist\n" if !-d $container_dir;
    }

    my ( $webapp_source_dir, $no_start, $webapp );

    if ( my $pkg = get_pkg_from_container_name($container_name) ) {
        my $pkg_dir = "/opt/cpanel/$pkg";
        if ( -f "$pkg_dir/ea-podman.json" ) {
            die "Upgrade takes no start args\n"                                                       if $isupgrade && @start_args;
            die "--webapp-dir and --no-start are only supported when installing an arbitrary image\n" if grep { m/^--(?:webapp-dir|no-start)/ } @start_args;
            my @given_start_args = @start_args;

            # do needful based on /opt/cpanel/$pkg
            my $pkg_conf = Cpanel::JSON::LoadFile("$pkg_dir/ea-podman.json");
            for my $flag ( keys %{ $pkg_conf->{startup} } ) {
                if ( $flag eq "-v" ) {
                    push @start_args, map { $flag => "$container_dir/$_" } @{ $pkg_conf->{startup}{$flag} };
                }
                else {
                    my @values = @{ $pkg_conf->{startup}{$flag} };
                    if ( !@values ) {
                        push @start_args, $flag;
                    }
                    else {
                        push @start_args, map { $flag => $_ } @values;
                    }
                }
            }

            if ( $isupgrade || $isrestore ) {
                if ( -e "$container_dir/ea-podman.json" ) {
                    my $container_conf = Cpanel::JSON::LoadFile("$container_dir/ea-podman.json");
                    die "`start_args` is missing from $container_dir/ea-podman.json\n" if !exists $container_conf->{start_args};
                    die "`start_args` is not a list\n"                                 if ref( $container_conf->{start_args} ) ne "ARRAY";
                    push @start_args, @{ $container_conf->{start_args} };
                }
            }

            push @start_args, $pkg_conf->{image};

            # ensure ea-podman.json isn’t specifying something it shouldn’t
            validate_start_args( \@start_args );

            if ( !$isupgrade && !$isrestore ) {
                File::Path::Tiny::mk( $container_dir, 0750 ) || die "Could not create “$container_dir”: $!\n";
            }

            # then add the ports if any
            my @container_ports = $pkg_conf->{ports} && ref $pkg_conf->{ports} eq "ARRAY" ? @{ $pkg_conf->{ports} } : ();
            my @ports           = $portsfunc->( $container_name => scalar(@container_ports) );

            # note the docker image name HAS to be the last argument
            my $docker_name = pop @start_args;

            for my $idx ( 0 .. $#ports ) {
                my $container_port = $container_ports[$idx] || $ports[$idx];
                push @start_args, "-p", "$ports[$idx]:$container_port";
            }
            push @start_args, $docker_name;

            my ( $container_ver, $package_ver ) = get_pkg_versions( $container_name => $pkg );

            if ($isupgrade) {
                if ( -x "$pkg_dir/ea-podman-local-dir-upgrade" ) {
                    system( "$pkg_dir/ea-podman-local-dir-upgrade", $container_dir, $container_ver, $package_ver, @ports );
                    warn "$pkg_dir/ea-podman-local-dir-upgrade did not exit cleanly\n" if $? != 0;
                }
            }
            elsif ($isrestore) {

                # nothing needed here
            }
            else {
                if ( -x "$pkg_dir/ea-podman-local-dir-setup" ) {
                    system( "$pkg_dir/ea-podman-local-dir-setup", $container_dir, @ports );
                    warn "$pkg_dir/ea-podman-local-dir-setup did not exit cleanly\n" if $? != 0;
                }

                # has to happen after script so the script can easily bail if the dir is not empty
                if (@given_start_args) {
                    my $json = Cpanel::JSON::pretty_canonical_dump( { start_args => \@given_start_args } );
                    _file_write_chmod( "$container_dir/ea-podman.json", $json, 0600 );
                }
            }

            # Ensure "$container_dir/README.md" is correct
            unlink "$container_dir/README.md";
            symlink( "$pkg_dir/README.md", "$container_dir/README.md" );
            if ( -l "$container_dir/README.md" && !-e _ ) {
                warn "!!!! ATTN DEVELOPER !! - failed to include required README.md for “$pkg” in “$pkg_dir/README.md”\n";
            }
        }
        else {
            # Let's see if we can drill down further on why this failed.

            # first and foremost is this an official ea4 podman package?
            my $metainfo     = "/etc/cpanel/ea4/ea4-metainfo.json";
            my $ea4_metainfo = Cpanel::JSON::LoadFile($metainfo);

            my $is_container;

            foreach my $container_pkg ( @{ $ea4_metainfo->{container_based_packages} } ) {
                if ( $pkg eq $container_pkg ) {
                    $is_container = 1;
                    last;
                }
            }

            if ($is_container) {
                die qq{“$pkg” is an EasyApache 4 container based package, “$pkg” is not installed.
In order to spin up an instance of it with ea-podman an admin will need to install “$pkg” via the system’s package manager.
};
            }
            else {
                die qq{“$pkg” is not an EasyApache 4 container-based package.
Check the package name and try again.
To see a list of the available EasyApache 4 container-based packages, run the `/scripts/ea-podman available` command.
};
            }
        }
    }
    else {
        _arbitrary_image_warning( \@start_args ) if !$isupgrade && !$isrestore;

        my @real_start_args;
        my @cpuser_ports;

        if ( $isupgrade || $isrestore ) {
            die "Upgrade/Restore takes no start args\n"                     if @start_args;
            die "Missing non-EA4-container $container_dir/ea-podman.json\n" if !-e "$container_dir/ea-podman.json";
            my $container_conf = Cpanel::JSON::LoadFile("$container_dir/ea-podman.json");
            die "`start_args` is missing from $container_dir/ea-podman.json\n" if !exists $container_conf->{start_args};
            die "`start_args` is not a list\n"                                 if ref( $container_conf->{start_args} ) ne "ARRAY";

            @cpuser_ports    = @{ $container_conf->{ports} || [] };
            @real_start_args = @{ $container_conf->{start_args} };
        }
        else {    # install
            die "No start args given for install\n" if !@start_args;

            # note the docker image name HAS to be the last argument
            my $docker_name = pop @start_args;
            for my $item (@start_args) {
                if ( $item =~ m/^--cpuser-port(?:=(.+))?/ ) {
                    my $val = $1;

                    if ( !length($val) || $val !~ m/^(?:0|[1-9][0-9]+?)$/ ) {
                        die "--cpuser-port requires a port the container uses (or 0 to be the same as the corresponding host port). e.g. --cpuser-port=8080\n";
                    }
                    push @cpuser_ports, $val;
                }
                elsif ( $item =~ m/^--webapp-dir(?:=(.*))?$/ ) {
                    die "--webapp-dir may only be given once\n" if defined $webapp_source_dir;
                    $webapp_source_dir = _validate_webapp_dir( $1, $container_root );
                }
                elsif ( $item eq "--no-start" ) {
                    $no_start = 1;
                }
                else {
                    push @real_start_args, $item;
                }
            }

            push @real_start_args, $docker_name;

            # The staged directory becomes $container_dir/webapp (see the
            # webapp-dir-setup call below), so any mount that points at or
            # into it must follow the move — both for the podman create below
            # and for the persisted start_args that upgrades replay.
            _rewrite_webapp_mounts( \@real_start_args, $webapp_source_dir, "$container_dir/webapp" ) if defined $webapp_source_dir;
        }

        # ensure the user isn’t specifying something they shouldn’t
        validate_start_args( \@real_start_args );

        if ( !$isupgrade && !$isrestore ) {
            File::Path::Tiny::mk( $container_dir, 0750 ) || die "Could not create “$container_dir”: $!\n";
            my $json = Cpanel::JSON::pretty_canonical_dump( { start_args => \@real_start_args, ports => \@cpuser_ports } );
            _file_write_chmod( "$container_dir/ea-podman.json", $json, 0600 );
        }

        my $docker_name = pop @real_start_args;    # so we can put ports before the image

        # Restore has no registry entry to carry `webapp` over (it comes from
        # the backup file instead), but upgrade does, so it's read directly.
        $webapp =
            defined $webapp_source_dir ? 1
          : $isrestore                 ? ( $opts->{webapp} ? 1 : 0 )
          : $isupgrade                 ? _is_registered_webapp($container_name)
          :                              0;

        # then add the ports if any, binding web app ports to loopback only
        # so the reverse proxy (which always talks to 127.0.0.1) remains the
        # only path into the app; see docs/webapp-port-binding.md
        my @ports = $portsfunc->( $container_name => scalar(@cpuser_ports) );
        for my $idx ( 0 .. $#ports ) {
            my $container_port = $cpuser_ports[$idx] || $ports[$idx];
            my $host_port      = $webapp ? "127.0.0.1:$ports[$idx]" : $ports[$idx];
            push @real_start_args, "-p", "$host_port:$container_port";
        }

        @start_args = @real_start_args;
        push @start_args, $docker_name;
    }

    my $image_arg = $start_args[-1];                # so we can persist image name
    my ($image_name) = $image_arg =~ m|([^/]+)$|;

    # EA4-325 B1-B4 and B7. Everything here happens BEFORE anything is torn down,
    # because the whole point is to be able to decide not to.
    my $force = $opts->{force} ? 1 : 0;
    if ($isupgrade) {

        # Pull first, or the comparison is vacuous -- see _podman_pull.
        if ( !_podman_pull($image_arg) ) {

            # B4: the two paths want opposite answers, and deliberately so.
            #
            # Conditional: we cannot tell whether the image moved, so acting
            # would mean tearing a working container down on a guess. Abort with
            # it untouched.
            #
            # Force: the caller asked for a recreate, not for an update. The
            # webapp plugin's Redeploy is the force caller (CPANEL-56732), and a
            # Docker Hub outage or a rate limit must not break Redeploy, so warn
            # and carry on from the cached image.
            my $pull_reason  = _pull_failure_reason($image_arg);
            my $rate_limited = $pull_reason eq "rate_limit";

            # Deliberately vague when we do not know. A bad image name, a DNS
            # failure and an auth refusal all land here, and naming the wrong one
            # is worse than naming none -- the point of this branch is to stop
            # guessing at causes, not to guess differently.
            my $why =
              $rate_limited
              ? "the registry is rate limiting this server"
              : $pull_reason eq "disk_quota" ? "the account has run out of disk space or reached its disk quota"
              :                                "the pull failed";

            # Spelled out because the arithmetic is what an operator needs, and
            # nothing else tells them: the budget is per IP for an
            # unauthenticated server, and every upgrade spends from it.
            my $rate_note =
              $rate_limited
              ? "Docker Hub meters manifest requests, and an unauthenticated server shares one budget per IP address. Since every upgrade now checks the image, a sweep costs one request per distinct image — `upgrade_containers --all` over ten containers on one image costs one, not ten.\n"
              : "";

            die "Could not pull “$image_arg”: $why, so there is no way to tell whether “$container_name” is out of date.\n" . "It has NOT been touched and is still running whatever it was running.\n" . $rate_note . ( $rate_limited ? "Retry once that clears" : "Fix that and retry" ) . ", or force the recreate from the image already cached locally:  ea-podman upgrade --force $container_name\n"
              if !$force;

            warn "Could not pull “$image_arg” ($why); recreating “$container_name” from the image already cached locally.\n";
        }

        # scalar(): get_pkg_from_container_name() does a bare `return` for a
        # non-package name, which flattens to an EMPTY LIST here and would shift
        # $force into the $pkg slot -- silently sending every arbitrary-image
        # container down the packaged branch, where it always reports "needed".
        my $gate_pkg = scalar get_pkg_from_container_name($container_name);

        if ( !_upgrade_is_needed( $container_name, $image_arg, $gate_pkg, $force, $webapp ) ) {
            print "“$container_name” is already up to date; nothing to do.\n";

            # The early return B2 asks for: no teardown, no recreate, no restart,
            # no registry write. A container that is deliberately stopped stays
            # stopped, and one that is running is not bounced.
            return { recreated => 0, started => 0 };
        }

        # B7: the conditional path preserves run state. An upgrade the operator
        # did not explicitly ask to start must not start a container the user
        # stopped -- and we cannot tell a deliberate stop from a crash, so the
        # only rule that never overrides the user is "was down, stays down".
        # Force still starts, as it always has: the plugin's redeploy branch has
        # no start of its own and relies on it.
        $no_start = 1 if !$force && !is_user_container_name_running($container_name);
    }

    # Captured before uninstall_container() tears the container down, because that
    # is the last moment the previous image is knowable — it is what the rollback
    # below pins back. Nothing else needs capturing: the upgrade path never
    # touches the ports (_get_current_ports is read-only) or $container_dir, and
    # the registry entry is left true by deferring the write below. (EA4-325)
    #
    # BOTH the ID and the reference, and they are not interchangeable. The ID is
    # what the rollback pins; the reference is only ever displayed. See
    # _rollback_failed_upgrade() for why pinning the reference is wrong.
    my $prev_image_ref = $isupgrade ? _get_container_image_ref($container_name) : undef;
    my $prev_image_id  = $isupgrade ? _get_container_image_id($container_name)  : undef;

    uninstall_container($container_name) if $isupgrade || $isrestore;    # avoid spurious warnings on install

    # Install and restore register before the create, so a crash in between leaves
    # a registry entry with no container — recoverable, and still visible to the
    # account-removal hooks — rather than a container with no entry, which is
    # invisible and leaks its ports. That is what "just in case" was guarding.
    #
    # An upgrade has the opposite need. Its entry already exists and is true, and
    # overwriting it with the new image and pkg_version *before* the create is
    # exactly what made a failed upgrade unrecoverable: the previous values then
    # survived nowhere. So an upgrade registers only once the new container
    # exists — see below the create. (EA4-325)
    register_container( $container_name, $isrestore, $image_name, $webapp ) if !$isupgrade;

    # Move the staged web application into the container dir (as webapp/).
    # Unlike a package's local-dir-setup hook this one is load-bearing — the
    # container's mounts point at the moved location — so a failure aborts the
    # install instead of warning. The script moves nothing unless it succeeds
    # entirely, so cleanup here never has to restore the staged directory.
    if ( defined $webapp_source_dir ) {
        system( $webapp_dir_setup_script, $webapp_source_dir, $container_dir );
        if ( $? != 0 ) {
            deregister_container($container_name);
            chdir("/");
            eval { File::Path::Tiny::rm($container_dir) };
            die "$webapp_dir_setup_script did not exit cleanly; “$webapp_source_dir” was not moved\n";
        }
    }

    if ( !create_user_container( $container_name, @start_args ) ) {

        # What podman said about THIS create, taken before anything else runs:
        # the upgrade rollback below creates a container again and would replace
        # it with the rollback's own output. (EA4-335)
        my $create_note = _create_failure_note($_create_output);

        # Three operations, three different right answers. This used to be one
        # `if ( !$isupgrade )`, which meant restore took the install cleanup —
        # deregistering and deleting the directory perform_user_restore() had just
        # extracted from the user's backup, their only copy of it. (EA4-325)
        if ($isupgrade) {
            my $rollback = _rollback_failed_upgrade( $container_name, $prev_image_ref, $prev_image_id, \@start_args );
            die _failed_upgrade_message( $container_name, $container_dir, $prev_image_ref, $prev_image_id, $rollback, $create_note );
        }
        elsif ($isrestore) {

            # Never deregister and never remove $container_dir here: it holds the
            # data just extracted from the backup, and perform_user_restore()
            # removed ~/ea-podman.d before the tarball went in, so there is no
            # other copy.
            die _failed_restore_message( $container_name, $container_dir, $create_note );
        }
        else {
            deregister_container($container_name);

            # The moved web application is the user's only copy of their
            # source — put it back where it came from before the container
            # dir is removed.
            if ( defined $webapp_source_dir && -d "$container_dir/webapp" && !-e $webapp_source_dir ) {
                local $@;
                eval { path("$container_dir/webapp")->move($webapp_source_dir) };
                warn "Could not restore “$container_dir/webapp” to “$webapp_source_dir”: $@" if $@;
            }

            # File::Path::Tiny::rm() chdir()s internally and dies if it cannot
            # restore the original cwd (e.g. an inaccessible /root). Move to a
            # safe cwd and don't let cleanup mask the real create failure.
            chdir("/");
            eval { File::Path::Tiny::rm($container_dir) };

            die "Failed to create container\n" . $create_note;
        }
    }

    # Deferred from before the create — see the register_container() above.
    register_container( $container_name, 1, $image_name, $webapp ) if $isupgrade;

    generate_container_service($container_name);

    if ( !$no_start ) {

        # else an upgrade of a container that used up its restarts cannot start it
        # (and see container_unit_settle_ceiling_sec(), whose budget this clears)
        reset_container_unit_failure($container_name);

        # Deliberately not the verdict, and deliberately not fatal here.
        #
        # Not the verdict: `systemctl start` returns success for a container that
        # starts and then dies — measured — so its boolean is necessary but not
        # sufficient. A failed start leaves the unit non-active either way, which
        # is what verify_container_started() reports.
        #
        # Not fatal: this tail is shared by install, upgrade and restore. Only
        # upgrade_container() raises on the outcome (EA4-325); install and restore
        # keep today's behaviour so a multi-container restore is not abandoned
        # partway through.
        sysctl( start => get_container_service_name($container_name) );
    }

    return { recreated => 1, started => $no_start ? 0 : 1 };
}

# A failed `podman create` on upgrade has already cost the container its unit
# file and its podman record — uninstall_container() ran before the create — so
# the failure path has to put those back. "Recreate, do not deregister"
# (EA4-325).
#
# The registry is deliberately not involved: an upgrade's register_container() is
# deferred until after a successful create, so on this path the entry still
# describes the container being recreated and is correct untouched.
#
# The recreate pins the image back to $prev_image_id — the image ID, NOT the
# reference. The reference is the wrong thing to pin, and pinning it was the
# original bug here: _podman_pull() has already run by the time the previous image
# is captured, so for a container tracking a tag — the normal case — that
# reference now resolves to the image the pull just fetched. The rollback would
# recreate the container on the NEW image while the message below told the
# operator it had been put back on the old one, and no test could see it because
# both sides print the same tag string. An ID names one image for as long as it
# exists, and a pull does not remove the image it displaces; it only moves the tag
# off it.
#
# $prev_image_ref is the fallback for when podman cannot report an ID — still
# better than not pinning at all, since an operator may have edited the persisted
# image — and it is what the message displays either way, because an ID means
# nothing to a reader.
#
# That is the whole of what this can
# fix. Every other start arg is rebuilt from the same $container_dir/ea-podman.json
# (and, for a package, /opt/cpanel/$pkg/ea-podman.json) that a retry would read,
# so a failure which is not the image pin recurs here. It also cannot undo
# $pkg_dir/ea-podman-local-dir-upgrade, which ran earlier and has no reverse step.
#
# Reports what it achieved rather than deciding what to say about it, and never
# dies — a rollback that dies is a rollback that reports nothing.
sub _rollback_failed_upgrade {
    my ( $container_name, $prev_image_ref, $prev_image_id, $start_args_ar ) = @_;

    my %status = ( created => 0, enabled => 0, started => 0 );

    my @args = @{$start_args_ar};
    my $pin  = $prev_image_id // $prev_image_ref;
    $args[-1] = $pin if defined $pin;

    # The failed create can leave the name taken; `rm --ignore` is a no-op when it
    # did not.
    remove_user_container($container_name);

    return \%status if !create_user_container( $container_name, @args );
    $status{created} = 1;

    # generate_container_service() dies if `systemctl --user enable` fails, and it
    # needs the container to exist — so it is never reached when the recreate
    # failed.
    local $@;
    $status{enabled} = eval { generate_container_service($container_name); 1 } ? 1 : 0;
    return \%status if !$status{enabled};

    reset_container_unit_failure($container_name);
    $status{started} = sysctl( start => get_container_service_name($container_name) ) ? 1 : 0;

    return \%status;
}

# What the rollback actually pinned, said in a way an operator can act on.
#
# The ID is the honest claim and the reference is the readable one, so when both
# are known both are printed. When only the reference is known the wording has to
# stop short of "the image it had been running": if the tag has moved since, it is
# not. (EA4-325)
sub _pinned_image_description {
    my ( $prev_image_ref, $prev_image_id ) = @_;

    # Enough to identify it in `podman images` without wrapping the line.
    my $short = defined $prev_image_id ? substr( $prev_image_id, 0, 12 ) : undef;

    return "“$prev_image_ref” (image $short — the exact image it had been running)"                                                                                         if defined $short && defined $prev_image_ref;
    return "image $short (the exact image it had been running)"                                                                                                             if defined $short;
    return "“$prev_image_ref” (the image reference it was created from — podman could not report the image ID, so if that tag has moved since, this is not the same image)" if defined $prev_image_ref;

    return "the image its configuration names — podman could not report what the container had been running, so there was nothing to pin back";
}

# Kept argument-pure (names and what the rollback achieved in, string out) so it
# is unit-testable. House style: name the condition, then name the recovery.
sub _failed_upgrade_message {
    my ( $container_name, $container_dir, $prev_image_ref, $prev_image_id, $status, $create_note ) = @_;

    my $pinned = _pinned_image_description( $prev_image_ref, $prev_image_id );

    my $intact = "Nothing was deregistered and nothing was deleted: “$container_name” is still registered at the version it was on, its assigned ports are still held, and “$container_dir” is untouched.\n" . "Re-run once the cause of the create failure is fixed:  ea-podman upgrade $container_name\n";

    my $head = "Failed to upgrade “$container_name”: the new container could not be created.\n" . ( $create_note // '' );

    return $head . "The previous container could not be recreated from $pinned either, so “$container_name” is not running and has no systemd unit.\n" . $intact
      if !$status->{created};

    return $head . "The previous container was recreated from $pinned, but its systemd unit could not be enabled, so it will not start now or at boot.\n" . $intact
      if !$status->{enabled};

    return $head . "The previous container was recreated from $pinned and its unit is enabled, but the unit did not start. Check `systemctl --user status " . get_container_service_name($container_name) . "`.\n" . $intact
      if !$status->{started};

    return $head . "The previous container was recreated from $pinned and is running again, so service is restored — but the upgrade did not happen.\n" . "“$container_dir” was NOT rolled back: a package's ea-podman-local-dir-upgrade hook runs before the container is created and has no reverse step, so any changes it made remain.\n" . $intact;
}

# Kept argument-pure so it is unit-testable.
sub _failed_restore_message {
    my ( $container_name, $container_dir, $create_note ) = @_;

    return
        "Failed to restore “$container_name”: the container could not be created.\n"
      . ( $create_note // '' )
      . "“$container_dir” was left in place. It holds the data just extracted from the backup and is the only copy of it, so a failed restore never removes it. “$container_name” also stays registered, so it remains visible to `ea-podman containers` and to the account-removal hooks.\n"
      . "Ports were assigned to “$container_name” for this restore and are still held. `ea-podman restore` takes a fresh set every run, so retry with `upgrade` rather than re-running the restore, or the old reservations are stranded.\n"
      . "To retry in place:  ea-podman upgrade $container_name   (recreates it from “$container_dir/ea-podman.json” using the ports already assigned)\n"
      . "To give up on it:   ea-podman uninstall $container_name  (releases the ports, deregisters it, and moves “$container_dir” aside to “$container_dir.bak”)\n";
}

# Validate a --webapp-dir value: the absolute path of the staged directory
# webapp-dir-setup will move into the container dir. Returns the normalized
# path. Kept argument-pure (value + container root in, path or die out) so it
# is unit-testable.
sub _validate_webapp_dir {
    my ( $val, $container_root ) = @_;

    die "--webapp-dir requires the absolute path of the staged directory to move into the container directory. e.g. --webapp-dir=/home/user/.cpanel/webapp-staging/my-app\n" if !length( $val // '' );

    $val =~ s{/+$}{};
    die "--webapp-dir must be an absolute path\n"           if $val !~ m{^/};
    die "--webapp-dir “$val” is not a directory\n"          if !-d $val;
    die "--webapp-dir cannot be inside “$container_root”\n" if "$val/" =~ m{^\Q$container_root\E/};

    return $val;
}

# Rewrite -v/--volume host paths that live under $from so the mounts follow
# webapp-dir-setup's move of $from to $to. Only exact path-boundary prefix
# matches are rewritten (/x/app matches /x/app and /x/app/sub, never
# /x/app-other). --mount specs are not handled. Pure args-in/args-out so it is
# unit-testable.
sub _rewrite_webapp_mounts {
    my ( $args, $from, $to ) = @_;

    my $rewrite = sub {
        my ($spec) = @_;
        my ( $host, $rest ) = split( m/:/, $spec, 2 );
        return $spec if !defined $rest;                              # no host part (anonymous volume)
        return $spec if $host ne $from && $host !~ m{^\Q$from\E/};
        substr( $host, 0, length($from) ) = $to;
        return "$host:$rest";
    };

    for my $idx ( 0 .. $#{$args} ) {
        my $item = $args->[$idx];
        if ( $item eq "-v" || $item eq "--volume" ) {
            $args->[ $idx + 1 ] = $rewrite->( $args->[ $idx + 1 ] ) if $idx < $#{$args};
        }
        elsif ( $item =~ m/^(-v=|--volume=)(.*)$/ ) {
            $args->[$idx] = $1 . $rewrite->($2);
        }
    }

    return;
}

sub _file_write_chmod {
    my ( $file, $cont, $mode ) = @_;
    my $path = path($file);

    local $@;
    eval { $path->chmod($mode) };    # try to chmod it first to protect data we are spewing into it
    $path->spew($cont);
    $path->chmod($mode);             # spew() first to ensure it exists
    return 1;
}

sub _is_registered_webapp {
    my ($container_name) = @_;

    my $registered = load_known_containers();
    return $registered->{$container_name} && $registered->{$container_name}{webapp} ? 1 : 0;
}

sub get_pkg_versions {
    my ( $container_name, $pkg ) = @_;

    my $registered    = load_known_containers();
    my $container_ver = $registered->{$container_name} ? $registered->{$container_name}{pkg_version} : undef;
    chomp($container_ver) if defined $container_ver;

    # we want this to die, it means the pkg left out an important requirement
    my $package_ver = path("/opt/cpanel/$pkg/pkg-version")->slurp;    # dies if can’t open
    chomp($package_ver);
    die "/opt/cpanel/$pkg/pkg-version does not define the version\n" if !length($package_ver);

    # scalar context will do $package_ver
    return ( $container_ver, $package_ver );
}

sub _get_current_ports {
    my ( $container_name, $count ) = @_;

    my @curr_ports;
    my $portassignments_json;
    if ( $> == 0 ) {
        $portassignments_json = `/scripts/cpuser_port_authority list root`;
    }
    else {
        $portassignments_json = Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'LIST' );
    }

    my $portassignments_hr = Cpanel::JSON::Load($portassignments_json);
    for my $port ( sort keys %{$portassignments_hr} ) {
        if ( $portassignments_hr->{$port}{service} eq $container_name ) {
            push @curr_ports, $port;
        }
    }

    if ( length($count) ) {
        my $how_many = @curr_ports;
        warn "“$container_name” needs $count port(s) but only has $how_many assigned\n" if $count != $how_many;
    }

    return @curr_ports;
}

sub _get_new_ports {
    my ( $container_name, $count ) = @_;

    return if !defined $count || $count < 1;

    my @new_ports;
    if ( $> == 0 ) {
        @new_ports = grep { chomp; m/^[0-9]+$/ ? ($_) : () } `/scripts/cpuser_port_authority give root $count --service=$container_name 2>/dev/null`;
    }
    else {
        my $get_ports_response = Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'GIVE', $count, $container_name );

        @new_ports = grep { m/^[0-9]+$/ ? ($_) : () } split( /\n/, $get_ports_response );
    }

    return @new_ports;

}

sub rename_containers {
    my ( $olduser, $newuser ) = @_;

    # TODO ZC-9694: implement me
}

sub validate_user_container_name {
    my ($container_name) = @_;
    die "Invalid container name\n" if $container_name !~ m/$container_name_sans_suffix_regexp$container_name_suffix_regexp/;
    return 1;
}

# 1 ➜ handled by ea-podman
# 2 ➜ these are intended to be long running not one offs
#     systemd management handles them quite nicely
# 3 ➜ these are intended to be long running not one offs
#     `ea-podman bash <CONTAINER_NAME> [CMD]` can be used to get a shell on a running container
my %invalid_start_args = (
    "-p"            => 1,
    "--publish"     => 1,
    "-d"            => 1,
    "--detach"      => 1,
    "-h"            => 1,
    "--hostname"    => 1,
    "--name"        => 1,
    "--rm"          => 2,
    "--rmi"         => 2,
    "--replace"     => 2,
    "-i"            => 3,
    "--interactive" => 3,
    "-t"            => 3,
    "--tty"         => 3,
);

sub validate_start_args {
    my ($start_args) = @_;
    die "No start args given\n"                             if !@{$start_args};
    die "Last start arg does not look like an image name\n" if $start_args->[-1] !~ $image_name_regexp;

    my @invalid;
    for my $flag ( @{$start_args} ) {
        next if substr( $flag, 0, 1 ) ne "-";

        my ( $opt, $val ) = split( "=", $flag, 2 );
        if ( substr( $opt, 0, 2 ) ne "--" ) {
            if ( length($opt) == 2 ) {
                push @invalid, $opt if exists $invalid_start_args{$opt};
            }
            else {
                for my $chr ( split( "", $opt ) ) {
                    next if $chr eq "-";
                    push @invalid, "-$chr" if exists $invalid_start_args{"-$chr"};
                }
            }
        }
        else {
            push @invalid, $opt if exists $invalid_start_args{$opt};
        }
    }

    die "Start args can not include the following: " . join( ",", @invalid ) . "\n" if @invalid;
    return 1;
}

###########################
#### main container CRUD ##
###########################

sub install_container {
    my ( $name, @start_args ) = @_;
    my $container_name = get_next_available_container_name($name);

    # The session is granted up front, before there is any container to keep
    # running, so a failed install has to hand it back or it leaves exactly the
    # state this case exists to prevent. Guarded as ever: a registry entry or a
    # container dir still on disk keeps the session. (CPANEL-55309)
    local $@;
    eval { _ensure_latest_container( $container_name, { op => "install" }, @start_args ); 1 } or do {
        my $err = $@ || "unknown error\n";

        local $@;
        eval { release_user_session(); 1 } or warn "Could not release the rootless session after the failed install: $@";

        die $err;
    };

    return $container_name;
}

sub upgrade_container {
    my ( $container_name, %opts ) = @_;
    validate_user_container_name($container_name);

    my $did = _ensure_latest_container( $container_name, { op => "upgrade", force => $opts{force} } );

    # An upgrade that leaves the application down must not exit 0 (EA4-325).
    #
    # Here rather than in _ensure_latest_container()'s start tail because that
    # tail is shared with install and restore: a die there would abandon the rest
    # of a multi-container restore. Every caller this is for comes through this
    # sub — the `upgrade` verb, the upgrade_containers sweep, the EAPodman UAPI,
    # and the webapp plugin's redeploy. No opt-out: the plugin path is the one
    # most users actually hit, so exempting it would leave the lie where it does
    # the most harm.
    #
    # Gated on having actually started something, which matters once the upgrade
    # is conditional: the no-op path touched nothing, and the conditional path
    # deliberately leaves a stopped container stopped (B7). Verifying either
    # would report a container as failed for being in the state we just decided
    # to leave it in — and would make `upgrade_containers --all` exit non-zero
    # for every stopped container on the server.
    verify_container_started($container_name) if $did->{recreated} && $did->{started};

    return 1;
}

sub restore_containers_for_user {
    my (@containers) = @_;

    my @failed;

    foreach my $container (@containers) {
        my $container_name = $container->{container_name};

        print "Restoring $container_name\n";

        validate_user_container_name($container_name);

        # One container that will not come back is no reason to leave the rest
        # unattempted. Before EA4-325 aborting here was defensible — a failed
        # restore had already destroyed the container dir, so there was nothing
        # to come back to. Now the failure is recoverable in place, so aborting
        # would turn one recoverable failure into N unattempted ones.
        #
        # The backup file is the only surviving record that this was a WebApp.
        local $@;
        eval { _ensure_latest_container( $container_name, { op => "restore", webapp => $container->{webapp} ? 1 : 0 } ); 1 } or do {
            warn( $@ || "unknown error\n" );
            push @failed, $container_name;
        };
    }

    if (@failed) {
        die "Could not restore " . scalar(@failed) . " of " . scalar(@containers) . " container(s): " . join( ", ", map { "“$_”" } @failed ) . "\n" . "Each one's error is above, and each is recoverable in place with `ea-podman upgrade <CONTAINER_NAME>`.\n";
    }

    return 1;
}

sub move_container_dir {
    my ($container_name) = @_;

    my $container_root = _get_container_root();
    my $container_dir  = "$container_root/$container_name";

    print "Moving “$container_root/$container_name” to “$container_root/$container_name.bak”\n";
    path($container_dir)->move("$container_dir.bak");

    return;
}

# Matches CPANEL-56733's default for the webapp plugin's own sweep, so an
# operator holds one number rather than two.
our $backup_max_age_default = 30 * 24 * 60 * 60;

# The clock, and whether the account's rootless session is reachable. Package
# variables so a test can age a directory without waiting a month, and can be a
# sessionless account without actually becoming one -- while the ctime read
# itself stays real, which is the part worth testing.
our $now                    = sub { return time() };
our $user_session_reachable = sub { return $> == 0 || -d "/run/user/$>" ? 1 : 0 };

# Does podman know this name at all, running or not? `ps -a`, not `ps`: a
# stopped container still owns its name, and handing that name out again is
# exactly what this guards against. Its own sub so tests have a seam.
sub _podman_container_exists {
    my ($container_name) = @_;

    my $name_qx = quotemeta($container_name);
    `podman ps -a --no-trunc --format "{{.Names}}" 2> /dev/null | grep --quiet ^$name_qx\$`;

    return $? == 0 ? 1 : 0;
}

# Bytes on disk under $path. Its own sub so tests have a seam, and so the
# listing can say how much a `.bak` is actually costing.
sub _dir_size {
    my ($path) = @_;

    my $name_qx = quotemeta($path);
    chomp( my $out = `du -sb $name_qx 2> /dev/null` );
    my ($bytes) = $out =~ m/^([0-9]+)/;

    # undef, never 0, when the size could not be measured. `clean` prints this
    # to an operator deciding whether to delete what may be the only copy of an
    # application's data, and "0 bytes" reads as "nothing to lose". du exits
    # non-zero on a partly unreadable tree while still printing a partial
    # total, so that counts as not measured too.
    return undef if $? != 0 || !defined $bytes;
    return $bytes;
}

# Is this the `.bak` of a container that is genuinely gone, or the wreckage of
# one that still half-exists?
#
# Freeing the name early is the hazard. get_next_available_container_name()
# checks only the container directory -- not podman, not the ports, not the unit
# -- so removing a `.bak` whose name is still claimed elsewhere hands that name
# to the next install with stale state attached to it. Anything still holding on
# is an EA4-320 reconciliation matter, not something `clean` should bulldoze.
# (EA4-325 C5)
sub _backup_name_is_free {
    my ( $container_name, $user, $can_ask_podman ) = @_;

    return "registered" if load_known_containers()->{$container_name};
    return "container"  if $can_ask_podman && _podman_container_exists($container_name);
    return "ports"      if scalar _get_current_ports($container_name);

    my $homedir = ( getpwuid($>) )[7];
    return "unit" if -e "$homedir/.config/systemd/user/" . get_container_service_name($container_name);

    return;
}

# `<name>.<user>.<NN>`, with the owner segment matching whose home this is.
# A hand-made directory is out by construction rather than by a guess about its
# contents. (EA4-325 C6)
sub _backup_belongs_to {
    my ( $container_name, $user ) = @_;

    my @seg = split( m/\./, $container_name );
    return 0 if @seg < 3;
    return 0 if $seg[-1] !~ m/\A[0-9][0-9]\z/;
    return 0 if $seg[-2] ne $user;

    return 1;
}

=head2 clean_backups(%opts)

Report -- or, with C<run>, remove -- the C<< <container>.bak >> directories left
under the current account's container root by C<ea-podman uninstall> and
C<remove_containers>. Returns a hashref:

    {
        user      => the account swept,
        ran       => 0 | 1,
        podman_unverifiable => 1   (session down: podman could not be asked)
        removable => [ { path, name, age, size }, ... ],
        skipped   => [ { path, name, reason }, ... ],
    }

Options: C<run> to act (default is to list only), C<max_age> in seconds
(default C<$backup_max_age_default>, 30 days).

=cut

sub clean_backups {
    my (%opts) = @_;

    my $run     = $opts{run} ? 1 : 0;
    my $max_age = $opts{max_age} // $backup_max_age_default;
    my $user    = scalar getpwuid($>);

    my %result = ( user => $user, ran => $run, removable => [], skipped => [] );

    # A `.bak` exists because a container was REMOVED, and removing the last one
    # correctly drops the account's linger (CPANEL-55309) -- which takes
    # /run/user/<uid> with it. So the accounts with backups to reclaim are
    # precisely the ones with no session, and refusing to look at them outright
    # (as C7 was first written) left `clean` unable to do the one job it has.
    #
    # Narrowed instead of abandoned. Of the four checks that decide whether a
    # name is free, only `podman ps -a` needs a session; the registry, the port
    # authority and the unit file on disk are all answerable without one. And
    # with no session a container cannot be RUNNING -- the only thing that can
    # hide is one sitting stopped in podman's storage, which, having no registry
    # entry, no ports and no unit, is an orphan by definition and EA4-320's to
    # reconcile.
    #
    # Reported rather than silent: the caller says which check was skipped, so an
    # operator is never told a name was free when one of the four was unasked.
    my $can_ask_podman = $user_session_reachable->() ? 1 : 0;
    $result{podman_unverifiable} = 1 if !$can_ask_podman;

    # An account with no ~/ea-podman.d has nothing to clean. One whose
    # ~/ea-podman.d could not be stat()ed or read is NOT that -- it is an
    # account nothing was examined for -- and reporting it as empty is how a
    # sweep says "clean" about something it never looked at.
    my $root    = _get_container_root();
    my @root_st = stat($root);
    if ( !@root_st ) {
        return \%result if $!{ENOENT} || $!{ENOTDIR};
        return _clean_backups_unreadable( \%result, $root, "$!" );
    }
    return \%result if !-d _;

    opendir( my $dh, $root ) or return _clean_backups_unreadable( \%result, $root, "$!" );
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;

    for my $entry (@entries) {
        next if $entry !~ m/\.bak\z/;

        my $path = "$root/$entry";

        # Stat once, here, and age from THIS result below: a second stat could
        # fail on its own, and an age that cannot be read must never become 0 --
        # under --days=0 that hands the backup straight to the remover. A path
        # that vanished, or a stray file, is skipped quietly; one that could not
        # be stat()ed for any other reason is reported, not passed over.
        my @st = stat($path);
        if ( !@st ) {
            next if $!{ENOENT} || $!{ENOTDIR};
            my $err = "$!";
            warn "ea-podman: could not examine “$path”: $err\n";
            push @{ $result{skipped} }, { path => $path, name => $entry, reason => "unreadable" };
            next;
        }
        next if !-d _;

        ( my $name = $entry ) =~ s/\.bak\z//;

        if ( !_backup_belongs_to( $name, $user ) ) {
            push @{ $result{skipped} }, { path => $path, name => $name, reason => "not_a_container_backup" };
            next;
        }

        if ( my $held = _backup_name_is_free( $name, $user, $can_ask_podman ) ) {
            push @{ $result{skipped} }, { path => $path, name => $name, reason => $held };
            next;
        }

        # ctime, NOT mtime (EA4-325 C2). Renaming a directory moves its ctime and
        # leaves mtime alone, so a `.bak` made one second ago still reports the
        # mtime of its last deploy -- an mtime rule would delete backups made
        # moments earlier. ctime IS the moment it became a `.bak`.
        my $age = $now->() - $st[10];

        if ( $age < $max_age ) {
            push @{ $result{skipped} }, { path => $path, name => $name, reason => "too_recent" };
            next;
        }

        my $entry_hr = { path => $path, name => $name, age => $age, size => _dir_size($path) };

        if ($run) {
            local $@;
            if ( !eval { File::Path::Tiny::rm($path); 1 } ) {
                push @{ $result{skipped} }, { path => $path, name => $name, reason => "remove_failed" };
                warn "ea-podman: could not remove “$path”: $@";
                next;
            }
        }

        push @{ $result{removable} }, $entry_hr;
    }

    return \%result;
}

sub _clean_backups_unreadable {
    my ( $result, $root, $err ) = @_;
    warn "ea-podman: could not examine “$root”: $err\n";
    $result->{unreadable} = $root;
    return $result;
}

sub remove_port_authority_ports {
    my ($container_name) = @_;
    if ( $> == 0 ) {
        my @container_ports = _get_current_ports($container_name);
        system( "/scripts/cpuser_port_authority", take => root => @container_ports );
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'TAKE', $container_name );
    }

    return;
}

sub uninstall_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    stop_user_container($container_name);

    my $service_name = get_container_service_name($container_name);
    sysctl( disable => $service_name );

    my $homedir = ( getpwuid($>) )[7];
    unlink "$homedir/.config/systemd/user/$service_name";

    sysctl("daemon-reload");
    sysctl("reset-failed");

    remove_user_container($container_name);

    return;
}

sub load_known_containers {
    return load_known_containers_as_root() if $> == 0;
    return Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'REGISTERED_CONTAINERS' );
}

sub load_known_containers_as_root {

    # No lock is needed to read: every mutation goes through
    # _mutate_known_containers_as_root(), which replaces the file atomically,
    # so a reader either sees the whole previous registry or the whole new one.
    #
    # A missing file means nothing is registered yet. A zero-length one means a
    # pre-CPANEL-55342 unlocked write truncated the file and then died — there
    # is nothing left to lose, so treat it the same as missing (this also
    # matches how the transaction object reads an empty file) rather than
    # dying on “malformed JSON” forever after.
    return {} if !-s $known_containers_file;

    return Cpanel::JSON::LoadFile($known_containers_file);
}

# Take one exclusive lock spanning read → modify → write of the shared,
# root-owned registry (CPANEL-55342).
#
# Every account’s installs and uninstalls mutate this one file as root (the
# REGISTER/DEREGISTER adminbin actions), so the previous plain
# LoadFile → modify → DumpFile let two accounts acting at the same time
# interleave: the second writer dumped a hash built from a stale read, silently
# dropping the first writer’s entry — an unregistered container is skipped by
# the removal hooks and leaks its ports and container — and a dump that died
# part way through left the file torn for everyone.
#
# Cpanel::Transaction::File::JSON takes the lock in its constructor, hands back
# the data read under that lock, and replaces the file atomically on save, so
# each mutation is all-or-nothing and serialized against every other mutation.
#
# $mutate_cr gets the registry hashref to modify in place; it returns true to
# save the result and false to release the lock leaving the file untouched.
sub _mutate_known_containers_as_root {
    my ($mutate_cr) = @_;

    die "The known containers registry can only be modified as root\n" if $> != 0;

    require Cpanel::Transaction::File::JSON;

    # 0600: the registry lists every account’s containers, so only root reads
    # it (unprivileged callers get their own entries via the
    # REGISTERED_CONTAINERS adminbin). Enforce that mode rather than preserving
    # whatever the file happens to have.
    my $trx = Cpanel::Transaction::File::JSON->new(
        path        => $known_containers_file,
        permissions => 0600,
    );

    # A missing or empty file reads back as a reference to undef; start it off
    # as an empty registry. Anything else that is not an object is not a
    # registry we should be silently replacing, so say so instead.
    my $containers_hr = $trx->get_data();
    $containers_hr = {} if ref($containers_hr) eq 'SCALAR' && !defined ${$containers_hr};

    if ( ref($containers_hr) ne 'HASH' ) {
        $trx->close_or_die();
        die "“$known_containers_file” does not contain a JSON object of containers\n";
    }

    my $save = eval { $mutate_cr->($containers_hr) };
    my $err  = $@;

    if ( $err || !$save ) {
        $trx->close_or_die();    # release the lock without writing
        die $err if $err;
        return;
    }

    $trx->set_data($containers_hr);
    $trx->save_and_close_or_die();

    return 1;
}

sub register_container_as_root {
    my ( $container_name, $user, $isupgrade, $image, $webapp ) = @_;

    my $pkg = get_pkg_from_container_name($container_name);

    # We want the slurp to error out if a package looking thing is not a container based package.
    # Done before the registry is locked so a failure here cannot hold the lock.
    my $pkg_ver = $pkg ? path("/opt/cpanel/$pkg/pkg-version")->slurp : undef;
    chomp($pkg_ver) if defined $pkg_ver;

    return _mutate_known_containers_as_root(
        sub {
            my ($containers_hr) = @_;

            my $entry = $containers_hr->{$container_name};
            if ( $entry && ( $entry->{user} // '' ) ne $user ) {
                warn "$container_name does not belong to $user";
                return 0;
            }

            if ( $entry && !$isupgrade ) {
                warn "$container_name is already registered";
                return 0;
            }
            elsif ( !$entry && $isupgrade ) {
                warn "$container_name is not registered, registering now …\n";
            }

            # `webapp` is established at install time only (--webapp-dir given); an
            # upgrade/restore keeps the value already recorded in this root-owned file.
            my $webapp_value = $isupgrade && $entry ? $entry->{webapp} : $webapp;

            $containers_hr->{$container_name} = {
                container_name => $container_name,
                user           => $user,
                pkg            => $pkg,
                pkg_version    => $pkg_ver,
                image          => $image,
                webapp         => $webapp_value ? Cpanel::JSON::true() : Cpanel::JSON::false(),    # strict boolean — never the raw value
            };

            return 1;
        }
    );
}

sub deregister_container_as_root {
    my ( $container_name, $expected_user ) = @_;

    return _mutate_known_containers_as_root(
        sub {
            my ($containers_hr) = @_;

            my $entry = $containers_hr->{$container_name};

            if ( !$entry ) {
                warn "$container_name is not registered";
                return 0;
            }

            # Multi-tenant guard (CPANEL-55337): callers scoped to one account
            # (the DEREGISTER adminbin action) pass their own cpuser here, so a
            # container registered to a different account is left untouched —
            # same outward result as "not registered", so this can't be used to
            # probe for other accounts' container names.
            if ( defined $expected_user && ( $entry->{user} // '' ) ne $expected_user ) {
                warn "$container_name does not belong to $expected_user";
                return 0;
            }

            delete $containers_hr->{$container_name};

            return 1;
        }
    );
}

# Used by pkg.preinst/pkg.prerm to squirrel the registry away, under the same
# lock as every other mutation, before the package manager overwrites it with
# the packaged `{}` default.
sub snapshot_known_containers_as_root {
    my ($dest) = @_;

    _mutate_known_containers_as_root(
        sub {
            my ($containers_hr) = @_;
            Cpanel::JSON::DumpFile( $dest, $containers_hr );
            chmod 0600, $dest;
            return 0;    # nothing to write back to the live registry
        }
    );

    return;
}

# Merge a snapshot taken by snapshot_known_containers_as_root() back into the
# live registry: any container already present now wins, so a registration
# that landed in the live file after the snapshot was taken is preserved
# rather than being overwritten by the older snapshot data. Only entries the
# live registry is missing get restored from the snapshot.
sub restore_known_containers_as_root {
    my ($src) = @_;

    # Only a missing snapshot is benign; a 0-byte one means an interrupted
    # write, and it's our only copy, so fall through and let it die below.
    return if !-e $src;

    my $snapshot_hr = Cpanel::JSON::LoadFile($src);
    die "“$src” does not contain a JSON object of containers\n" if ref($snapshot_hr) ne 'HASH';

    return _mutate_known_containers_as_root(
        sub {
            my ($containers_hr) = @_;

            my $restored = 0;
            for my $container_name ( keys %{$snapshot_hr} ) {
                next if exists $containers_hr->{$container_name};
                $containers_hr->{$container_name} = $snapshot_hr->{$container_name};
                $restored = 1;
            }

            return $restored;
        }
    );
}

sub remove_container_by_name {
    my ($container_name) = @_;

    print "Removing $container_name\n";

    ea_podman::util::remove_port_authority_ports($container_name);
    ea_podman::util::uninstall_container($container_name);
    ea_podman::util::deregister_container($container_name);
    ea_podman::util::move_container_dir($container_name);

    # Hand back a linger we granted for a WebApp once the account’s last
    # container is gone; a no-op otherwise. Has to come after the podman and
    # `systemctl --user` work above, which needs the manager still running, and
    # must never fail an otherwise successful removal.
    local $@;
    eval { ea_podman::util::release_user_session(); };
    warn "Could not release the rootless session: $@" if $@;

    return;
}

sub remove_containers_for_a_user {
    my (@containers) = @_;

    # They should be for all the same user
    my $user;
    foreach my $container (@containers) {
        my $c_user = $container->{user};
        if ( !$user ) {
            $user = $c_user;
            next;
        }

        die "remove_users_containers: Containers listed must be for all the same user" if ( $c_user ne $user );
    }

    foreach my $container (@containers) {
        remove_container_by_name( $container->{container_name} );
    }

    return;
}

sub remove_containers_for_a_deleted_user {
    my (@containers) = @_;

    # They should be for all the same user
    my $user;
    foreach my $container (@containers) {
        my $c_user = $container->{user};
        if ( !$user ) {
            $user = $c_user;
            next;
        }

        die "remove_users_containers: Containers listed must be for all the same user" if ( $c_user ne $user );
    }

    foreach my $container (@containers) {
        deregister_container_as_root( $container->{container_name} );
    }

    _release_deleted_user_session($user);

    return;
}

sub _release_deleted_user_session {
    my ($user) = @_;

    return 0 if !defined $user || $user eq "root";

    # The account's own user-manager unit does not depend on whether we ever
    # granted a linger, only on whether we wrote the unit: enable-linger can fail
    # after it. getpwnam() cannot find the uid of a deleted account, so it is
    # found among the units we wrote by having no account left. (EA4-321)
    ea_podman::subids::release_deleted_user_carveout($user) if !defined getpwnam($user);

    # Only a linger we recorded granting is ours to disable, even for an account
    # that is gone.
    return 0 if !ea_podman::subids::user_has_granted_linger($user);

    # The account may still exist (it is only ever *assumed* gone here, see
    # ZC-10958), in which case this is an ordinary release.
    return release_user_session_as_root($user) if defined getpwnam($user);

    # It really is gone, so `loginctl disable-linger` has no user to look up —
    # but logind’s marker file outlives the account, and would silently linger
    # any future account that reuses the name. Remove it ourselves.
    # No grant_covers_current_linger() check here: a marker for an account that
    # does not exist keeps nothing running, and leaving it is the ZC-10958 bug.
    if ( ea_podman::subids::user_has_linger($user) && !ea_podman::subids::remove_stale_linger_marker($user) ) {
        warn "Could not remove the stale linger marker for the deleted user “$user”: $!\n";
        return 0;
    }

    ea_podman::subids::revoke_linger_grant($user);    # the account is gone, so the grant goes too

    return 1;
}

sub upgrade_containers_for_a_user {
    my ( $force, @containers ) = @_;

    # They should be for all the same user
    my $user;
    foreach my $container (@containers) {
        my $c_user = $container->{user};
        if ( !$user ) {
            $user = $c_user;
            next;
        }

        die "upgrade_users_containers: Containers listed must be for all the same user" if ( $c_user ne $user );
    }

    my @failed;
    foreach my $container (@containers) {
        my $name = $container->{container_name};

        local $@;
        eval { upgrade_container( $name, force => $force ); 1 } or do {
            my $err = $@ || "unknown error\n";
            warn "ea-podman: could not upgrade “$name”: $err";
            push @failed, $name;
        };
    }

    # Thrown, not returned. The root sweep calls this inside
    # Cpanel::AccessIds::do_as_user_with_exception(), across a privilege boundary
    # a return value does not survive but an exception does. The eval above is
    # what stops one bad container abandoning the rest; this is what stops that
    # turning into a silent success — which would re-create the very defect
    # EA4-325 exists to kill. (EA4-325)
    if (@failed) {
        die "Failed to upgrade " . scalar(@failed) . " of " . scalar(@containers) . " container(s) for “$user”: " . join( ", ", @failed ) . "\n" . "Each failure is reported above. Once its cause is fixed, re-run a single one with `ea-podman upgrade <CONTAINER_NAME>`.\n";
    }

    return 1;
}

sub register_container {
    my ( $container_name, $isupgrade, $image, $webapp ) = @_;

    if ( $> == 0 ) {
        local $@;
        eval { register_container_as_root( $container_name, "root", $isupgrade, $image, $webapp ); };

        die "Unable to register “$container_name”: $@\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'REGISTER', $container_name, $isupgrade, $image, $webapp ? 1 : 0 );
    }
}

sub deregister_container {
    my ($container_name) = @_;

    if ( $> == 0 ) {
        local $@;
        eval { deregister_container_as_root($container_name); };

        die "Unable to deregister “$container_name”: $@\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'DEREGISTER', $container_name );
    }
}

sub ensure_user {
    my ($creating) = @_;

    # The very first command has to be ensure_user which establishes this user
    # in the /etc/subuid and /etc/subgid files, critical to podman.
    #
    # The lingering user session is a separate question: only an account with
    # containers, or one making its first (`creating`), gets one. Returns
    # whether it has one.
    if ( $> == 0 ) {
        my $has_containers = user_has_containers_as_root("root");
        my $session        = ( $creating || $has_containers ) ? 1 : 0;

        local $@;

        # No containers ⇒ nothing to take down, so a manager that is up but
        # unusable may be restarted in place. See ensure_user_session().
        eval { ea_podman::subids::ensure_user_root( "root", undef, $session, !$has_containers ); };

        # Root is already looking at root-side state, so it gets the reason
        # itself: a subid refusal names the file and the other account, which is
        # the point of it.
        # Stripped, not tested for: root sees the reason either way, and the
        # marker is only there to tell the adminbin what a cpuser may be shown.
        die "Unable to ensure the root has subuids and subgids: " . ea_podman::subids::strip_user_session_error($@) if $@;

        # No grant for root: /run/user/0 is not ours to take away.
        return $session;
    }

    # The adminbin decides the same thing root-side, from the container
    # registry only it can read, and reports back what it did.
    return Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'ENSURE_USER', $creating ? 1 : 0 ) ? 1 : 0;
}

sub user_has_containers_as_root {
    my ($user) = @_;

    return 0 if !defined $user;

    my $containers_hr = load_known_containers_as_root();
    return ( grep { $_->{user} eq $user } values %{$containers_hr} ) ? 1 : 0;
}

# Every account the registry says has at least one container: the plural of
# user_has_containers_as_root(), off the same source, and the list the boot-time
# sweep works from (see `ea-podman ensure_user_sessions`, EA4-319).
#
# The registry, not $dir_granted_linger: a grant records that ea-podman turned
# *a* linger on, which is not the same question as “does this account have
# containers to bring back”. Sorted so the sweep — and its output — is
# deterministic.
sub users_with_containers_as_root {
    my $containers_hr = load_known_containers_as_root();

    my %seen;
    for my $container ( values %{$containers_hr} ) {
        next if !defined $container->{user} || $container->{user} eq "";
        $seen{ $container->{user} } = 1;
    }

    return sort keys %seen;
}

# Independent of the registry: a live container directory under the account’s
# home means it still has containers even if the root-owned registry says
# otherwise (it was reset by a botched upgrade, say). Removal renames these to
# “<container name>.bak” (see move_container_dir()), so only the others count.
# Belt and braces before taking somebody’s user session away.
sub _user_has_container_dirs {
    my ($user) = @_;

    my $homedir = ( getpwnam($user) )[7];
    return 0 if !defined $homedir;

    my $container_root = "$homedir/ea-podman.d";
    return 0 if !-d $container_root;

    for my $child ( path($container_root)->children ) {
        next if !$child->is_dir;
        next if $child->basename =~ m/\.bak$/;
        return 1;
    }

    return 0;
}

# Could this account have a `.bak` for `clean` to report? Asked as root, before
# dropping privileges, so root `clean` only init_user()s the accounts that can
# appear in its listing: init_user() allocates a subuid/subgid range, and a
# look-only listing must not hand one to every account on the box.
#
# “No” only when that is certain -- no ~/ea-podman.d, or one that reads with no
# `*.bak` in it. Anything this cannot tell is “yes”, so the account is still
# visited and the user-side sweep reports it as not examined, rather than it
# dropping out of the listing. Names only: the sweep itself decides what the
# entries are.
sub user_may_have_backups_as_root {
    my ($user) = @_;

    my $homedir = ( getpwnam($user) )[7];
    return 1 if !defined $homedir;    # visited, so the sweep reports it unreachable

    return _dir_may_hold_backups("$homedir/ea-podman.d");
}

sub _dir_may_hold_backups {
    my ($root) = @_;

    # Absent means what it means in clean_backups(): ENOENT or ENOTDIR only.
    my @st = stat($root);
    if ( !@st ) {
        return 0 if $!{ENOENT} || $!{ENOTDIR};
        return 1;
    }
    return 0 if !-d _;

    opendir( my $dh, $root ) or return 1;
    my $found = grep { m/\.bak\z/ } readdir($dh);
    closedir $dh;

    return $found ? 1 : 0;
}

# Linger — and the user systemd manager it keeps alive — exists for exactly one
# reason here: so the account’s rootless containers survive logout and reboot.
# With no containers left there is nothing to keep running, and on a server with
# hundreds of accounts those idle managers add up (CPANEL-55309).
#
# An argument for giving *ours* back, and none for touching anybody else’s: an
# account may linger because an admin or other software said so, and the systemd
# marker does not say which. Hence:
#
# * no grant record, no release, however little the account seems to need one
# * a record that no longer covers the linger actually in place is not a licence
#   to disable that one — see ea_podman::subids::grant_covers_current_linger()
# * root is never released: /run/user/0 is not ours to take away
# * any remaining container keeps the linger, or it would stop at the next
#   logout/reboot — a live container dir counts even if the registry disagrees
sub _user_session_is_releasable {
    my ($user) = @_;

    return 0 if !defined $user || $user eq "root";
    return 0 if !ea_podman::subids::user_has_granted_linger($user);
    return 0 if !ea_podman::subids::user_has_linger($user);
    return 0 if !ea_podman::subids::grant_covers_current_linger($user);
    return 0 if user_has_containers_as_root($user);
    return 0 if _user_has_container_dirs($user);

    return 1;
}

sub release_user_session_as_root {
    my ($user) = @_;

    # Whichever account this is for, it is a chance to finish taking back the unit
    # file of one released earlier while a login session still held its manager.
    # Nothing else calls back for that account. (EA4-321)
    eval { ea_podman::subids::reconcile_carveouts(); 1 } or warn "Could not finish removing released accounts' user manager units: $@";

    return 0 if !_user_session_is_releasable($user);

    if ( !ea_podman::subids::remove_user_session($user) ) {
        warn "Could not disable linger for “$user”\n";
        return 0;
    }

    # Given back, so no longer ours — or a linger the account later acquires for
    # its own reasons would look like ours to disable.
    ea_podman::subids::revoke_linger_grant($user);

    return 1;
}

# The other half of the bargain: an account that HAS containers must have the
# lingering user session that keeps them running. init_user() deliberately
# withholds it from an account with none (CPANEL-55309), so the moment one is
# actually being created that has to be put right — see
# _ensure_latest_container(), which calls this for every install, restore, and
# upgrade. Idempotent, and free once the session is up (the linger marker is
# world readable, so the check needs no privileges).
sub ensure_container_session {
    my $user = scalar getpwuid($>);

    return 1 if defined $user && ea_podman::subids::user_has_linger($user) && -d "/run/user/$>";

    ensure_user(1);    # 1 ➜ a container is being created, so the session is required
    ensure_su_login(1);

    return 1;
}

sub release_user_session {

    # A restore removes every container and immediately puts them back
    # (perform_user_restore), so the account is not really losing its
    # containers. Tearing the session down in the middle of that would only
    # make the very next step bring it straight back up — with a
    # teardown/start-up race in between. That path sets this.
    return 0 if $ENV{EA_PODMAN_KEEP_USER_SESSION};

    return release_user_session_as_root( scalar getpwuid($>) ) if $> == 0;
    return Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'RELEASE_USER' );
}

sub _get_container_root {
    my $homedir = ( getpwuid($>) )[7];
    return "$homedir/ea-podman.d";
}

sub _arbitrary_image_warning {
    my ($start_args) = @_;

    warn <<"DRAGONS";
🐉🐲🀄️
!!!! Important message about arbitrary images !!

For security and reliability, when using arbitrary images, we highly recommend the following:

  • only use a trusted registry
  • only use “Official Image” and/or “Verified Publisher” images
  • specifying a version specific tag so that a major or minor change won’t break your containers

DRAGONS

    if ( grep m/^--i-understand-the-risks-do-it-anyway$/, @{$start_args} ) {
        my @new_start_args = grep { $_ !~ m/^--i-understand-the-risks-do-it-anyway$/ } @{$start_args};
        @{$start_args} = @new_start_args;
        print "Proceeding per --i-understand-the-risks-do-it-anyway flag …\n";
    }
    else {
        # do not document, do not want to encourage ignoring this via copy and paste
        die "If you really want to continue pass `--i-understand-the-risks-do-it-anyway`\n";
    }

    return 1;
}

sub _ensure_backup_conf_excludes_files {
    my $homedir = ( getpwuid($>) )[7];

    my $fname = "$homedir/cpbackup-exclude.conf";
    $fname = "/etc/cpbackup-exclude.conf" if ( $> == 0 );

    my $local_container_line = '.local/share/containers';
    my $local_systemd_line   = '.config/systemd';

    if ( $> == 0 ) {
        $local_container_line = "$homedir/$local_container_line";
        $local_systemd_line   = "$homedir/$local_systemd_line";
    }

    if ( -e $fname ) {
        my @lines            = Path::Tiny::path($fname)->lines( { chomp => 1 } );
        my $found_containers = 0;
        my $found_systemd    = 0;

        foreach my $line (@lines) {
            $found_containers = 1 if ( $line eq $local_container_line );
            $found_systemd    = 1 if ( $line eq $local_systemd_line );
        }

        push( @lines, $local_container_line . "\n" ) if ( !$found_containers );
        push( @lines, $local_systemd_line . "\n" )   if ( !$found_systemd );

        Path::Tiny::path($fname)->spew(@lines) if ( !$found_systemd || !$found_containers );
    }
    else {
        my @lines;

        push( @lines, $local_container_line . "\n" );
        push( @lines, $local_systemd_line . "\n" );

        Path::Tiny::path($fname)->spew(@lines);
    }

    return;
}

sub get_backup_filename {
    my $homedir = ( getpwuid($>) )[7];
    my $user    = getpwuid($>);

    return "$homedir/ea_podman_backup_$user.json";
}

sub _get_backup_root {
    my $homedir = ( getpwuid($>) )[7];
    return "$homedir/ea-podman-backups";
}

sub _get_tarball_name {
    my $timestamp_str = Cpanel::Time::time2condensedtime();
    my $tarball_name  = _get_backup_root() . "/backup-" . $timestamp_str . ".tar.gz";

    return $tarball_name;
}

our $num_backups_to_retain = 3;

# This user's registry entries, each with the ports it holds now. The manifest
# is the only place those ports are recorded.
sub _user_manifest_entries {
    my $user = getpwuid($>);

    my $containers_hr = ea_podman::util::load_known_containers();

    my @containers = values %{$containers_hr};
    @containers = grep { $_->{user} eq $user } @containers;
    @containers = sort { $a->{user} cmp $b->{user} } @containers;

    foreach my $container (@containers) {
        my @curr_ports = ea_podman::util::_get_current_ports( $container->{container_name} );
        $container->{curr_ports} = \@curr_ports;
    }

    return @containers;
}

# What the pkgacct hook runs. The homedir backup already carries ~/ea-podman.d,
# so the manifest is all it is missing; a tarball of ea-podman.d would put every
# container's files into the account backup a second time.
sub write_user_manifest {
    die "Cannot be run as root\n" if ( $> == 0 );

    my @containers = _user_manifest_entries();

    if ( @containers == 0 ) {
        print "There are no containers\n";
        return 1;
    }

    Path::Tiny::path( ea_podman::util::get_backup_filename() )->spew( Cpanel::JSON::pretty_canonical_dump( \@containers ) );

    return;
}

sub perform_user_backup {
    my $user = getpwuid($>);

    die "Cannot be run as root\n" if ( $> == 0 );

    my @containers = _user_manifest_entries();

    if ( @containers == 0 ) {
        print "There are no containers\n";
        return 1;
    }

    my $homedir = ( getpwuid($>) )[7];

    {
        # Normally I would use File::chdir, but it seems to cause perlcc to crash

        my $pwd = Cwd::getcwd();
        chdir $homedir;

        my $backup_file = ea_podman::util::get_backup_filename();

        Path::Tiny::path($backup_file)->spew( Cpanel::JSON::pretty_canonical_dump( \@containers ) );

        # Now create the backup dir if needed

        my $backups_dir = _get_backup_root();
        if ( !-d $backups_dir ) {
            File::Path::Tiny::mk($backups_dir) || die "Could not create “$backups_dir”: $!\n";
        }

        my $tarball_name = _get_tarball_name();

        system( 'tar', 'czf', $tarball_name, "ea_podman_backup_$user.json", 'ea-podman.d' ) == 0
          or die "Could not create “$tarball_name”\n";
        unlink($backup_file);

        chdir 'ea-podman-backups';
        my @files = reverse sort glob("backup*.tar.gz");
        while ( @files > $num_backups_to_retain ) {
            my $file = pop @files;
            print "Removing older backup $file\n";
            unlink $file;
        }

        chdir $pwd;
    }

    return;
}

# Restore for an account whose files have already come back (restorepkg, a
# transfer): ~/ea-podman.d and the manifest are in the homedir, but the registry
# knows nothing of the containers. Nothing is torn down or unpacked, because the
# directories are exactly what was just restored.
#
# A container the registry already has is left alone. Recreating it would
# allocate it a second set of ports without releasing the first, and the only
# thing that releases them (remove_container_by_name) also moves the directory
# aside to .bak.
sub _restore_from_manifest {
    my ( $homedir, $user ) = @_;

    die "Cannot be run as root\n" if ( $> == 0 );

    my $backup_file = "$homedir/ea_podman_backup_$user.json";
    if ( !-e $backup_file ) {
        die "The container backup file is not present ($backup_file)\n";
    }

    my @containers = @{ Cpanel::JSON::LoadFile($backup_file) };

    # Dies if the registry cannot be read: guessing would recreate containers it
    # may already have.
    my $registered = ea_podman::util::load_known_containers();

    my @to_restore;
    foreach my $container (@containers) {
        if ( exists $registered->{ $container->{container_name} } ) {
            print "“$container->{container_name}” is already registered; leaving it as it is\n";
            next;
        }
        push @to_restore, $container;
    }

    # Every directory must be there before anything is created.
    foreach my $container (@to_restore) {
        my $container_dir = "$homedir/ea-podman.d/$container->{container_name}";

        if ( !-d $container_dir ) {
            die "Container dir ($container_dir) does not exist.\n";
        }
    }

    if ( !@to_restore ) {
        print "Nothing to restore\n";
        return;
    }

    ea_podman::util::init_user( creating => 1 );
    ea_podman::util::restore_containers_for_user(@to_restore);
    _warn_if_ports_changed(@to_restore);

    return;
}

sub perform_user_restore {
    my ($backup_tarball) = @_;

    my $homedir = ( getpwuid($>) )[7];
    my $user    = getpwuid($>);

    return _restore_from_manifest( $homedir, $user ) if !defined $backup_tarball;

    $backup_tarball = Cwd::abs_path( $backup_tarball // '' )                                || die "Please pass in the path to the backup file you want to restore.\n";
    die "The backup file is not a readable file ($backup_tarball)\n" if !-f $backup_tarball || !-r _;

    # Remove any existing containers

    print "\nRemoving existing containers first\n\n";

    die "Cannot be run as root\n" if ( $> == 0 );

    {
        # These containers are coming right back, so keep the user session up
        # rather than have the removals release it and the restore below
        # immediately re-establish it. (CPANEL-55309)
        local $ENV{EA_PODMAN_KEEP_USER_SESSION} = 1;
        system( '/opt/cpanel/ea-podman/bin/ea-podman', 'remove_containers', '--all' );
    }

    Path::Tiny::path("$homedir/ea-podman.d")->remove_tree( { safe => 0 } );
    Path::Tiny::path("$homedir/.config/systemd/user")->remove_tree( { safe => 0 } );

    # Now explode the tarball in the homedir, this sets up the restore

    print "\nStarting the restore …\n\n";

    {
        # Normally I would use File::chdir, but it seems to cause perlcc to crash

        my $pwd = Cwd::getcwd();
        chdir $homedir;

        system( 'tar', 'xf', $backup_tarball ) == 0
          or die "Could not extract “$backup_tarball”\n";

        chdir $pwd;
    }

    my $backup_file = "$homedir/ea_podman_backup_$user.json";
    if ( !-e $backup_file ) {
        die "The container backup file is not present ($backup_file)\n";
    }

    my @containers = @{ Cpanel::JSON::LoadFile($backup_file) };

    # each of the container dirs must exist

    foreach my $container (@containers) {
        my $container_name = $container->{container_name};
        my $container_dir  = "$homedir/ea-podman.d/$container_name";

        if ( !-d $container_dir ) {
            die "Container dir ($container_dir) does not exist.\n";
        }
    }

    # The containers were all removed above and are about to come back, so the
    # registry cannot vouch for this account right now — say outright that a
    # session is needed.
    ea_podman::util::init_user( creating => 1 );
    ea_podman::util::restore_containers_for_user(@containers);
    _warn_if_ports_changed(@containers);

    return;
}

sub _warn_if_ports_changed {
    my (@containers) = @_;

    foreach my $container (@containers) {
        my @new_ports = ea_podman::util::_get_current_ports( $container->{container_name} );
        my %new_ports_lookup;
        @new_ports_lookup{@new_ports} = ();

        my @orig_ports;
        @orig_ports = @{ $container->{curr_ports} } if ( exists $container->{curr_ports} );

        my $ports_are_different = 0;
        foreach my $port (@orig_ports) {
            if ( !exists $new_ports_lookup{$port} ) {
                $ports_are_different = 1;
                last;
            }
        }

        if ($ports_are_different) {
            my $orig_ports = join( ', ', @orig_ports );
            my $new_ports  = join( ', ', @new_ports );

            warn qq{The TCP ports for $container->{container_name} have changed.

Things configured for the old ports may fail until it is corrected to use the current ports.

The ports originally assigned to the container are: $orig_ports

The ports currently assigned to the container are: $new_ports

            };
        }
    }
}

##################################################
#### verbs shared by the UAPI and admin module ##
##################################################
#
# The EAPodman UAPI (Cpanel::API::EAPodman, cpsrvd as the cpuser) and the
# ea_podman admin module's lifecycle actions (root in cpsrvd, forked and fully
# dropped to the cpuser) run the same verb bodies, so a verb behaves the same
# whichever way the call arrives. Each expects to already be running as the
# cpuser. (EA4-315)

# Prime this (already unprivileged, cpuser) process for rootless podman the
# way the CPANEL-54037 verification showed is required, then run $code.
#
# init_user() does the real work: as root (via the ENSURE_USER admin action) it
# allocates subuid/subgid and runs `loginctl enable-linger`, which creates
# /run/user/<uid> and starts the user systemd manager; then it points this
# process's XDG_RUNTIME_DIR/DBUS at that runtime dir. We clear any inherited
# DBUS_SESSION_BUS_ADDRESS first so a stale value can't point podman at the
# wrong bus.
#
# ea_podman::util (and init_user's check_proc) print progress/warnings to
# STDOUT/STDERR. Under a synchronous API call that output would be
# interleaved into — and corrupt — the response, so capture it. On failure the
# captured text is appended to the exception so the real error is debuggable
# instead of a bare "Failed to create container".
sub run_in_user_session {
    my ( $code, %opts ) = @_;

    local $ENV{XDG_RUNTIME_DIR} = "/run/user/$>";
    local $ENV{DBUS_SESSION_BUS_ADDRESS};
    delete $ENV{DBUS_SESSION_BUS_ADDRESS};

    # Run from a working directory the cpuser can stat. cpsrvd may hand us a
    # cwd inherited from root (e.g. /root, mode 0700) that the dropped cpuser
    # cannot enter, which breaks rootless podman. (CPANEL-54037: cpsrvd runs
    # OUTSIDE any CageFS cage, so this — plus the privileged enable-linger
    # bootstrap — is all that jailshell/cagefs users need.)
    if ( my $home = ( getpwuid($>) )[7] ) {
        chdir($home);    # best-effort; a failed chdir simply leaves cwd as-is
    }

    require Capture::Tiny;
    my ( @rv, $err );
    my $output = Capture::Tiny::capture_merged(
        sub {
            local $@;
            eval {
                init_user( creating => $opts{creating} );
                @rv = $code->();
                1;
            } or $err = $@ || "ea-podman: unknown error";
        }
    );

    if ( defined $err ) {
        chomp $err;
        die length($output) ? "$err\n$output" : "$err\n";
    }

    return wantarray ? @rv : $rv[0];
}

# Ownership: act only on a container that is registered to the caller, so a
# well-formed but foreign (or entirely made up) name cannot reach the
# destructive helpers (CPANEL-55336).
sub verify_own_container {
    my ($container_name) = @_;

    my $entry = load_known_containers()->{$container_name};
    die "No such container for this account.\n" if !$entry || ( $entry->{user} // '' ) ne scalar getpwuid($>);
    return 1;
}

sub api_list {
    my $user          = scalar getpwuid($>);
    my $containers_hr = load_known_containers();

    my %mine;
    for my $c ( grep { $_->{user} eq $user } values %{$containers_hr} ) {
        $mine{ $c->{container_name} } = $c;
    }

    return \%mine;
}

# %args are the UAPI parameter names: name, image, cpuser_port (arrayref),
# env (arrayref), accept_arbitrary_image_risk.
sub api_install {
    my (%args) = @_;

    my $name = $args{name};
    die "install requires a package or container name\n" if !length( $name // '' );

    my @start_args;
    push @start_args, map { "--cpuser-port=$_" } grep { length } @{ $args{cpuser_port} || [] };
    push @start_args, map { ( '-e' => $_ ) } grep     { length } @{ $args{env}         || [] };
    push @start_args, '--i-understand-the-risks-do-it-anyway' if $args{accept_arbitrary_image_risk};

    # The image, when given, must be the last start arg.
    push @start_args, $args{image} if length( $args{image} // '' );

    # The one verb that needs a rootless session for an account that may not
    # have a container yet, so it is the one that asks for it. (CPANEL-55309)
    my $container_name = run_in_user_session(
        sub { return install_container( $name, @start_args ) },
        creating => 1,
    );

    return { container_name => $container_name };
}

# %opts: force (see upgrade_container).
sub api_upgrade {
    my ( $container_name, %opts ) = @_;

    run_in_user_session( sub { upgrade_container( $container_name, force => ( $opts{force} ? 1 : 0 ) ); return 1; } );
    return 1;
}

sub api_uninstall {
    my ($container_name) = @_;

    run_in_user_session(
        sub {
            validate_user_container_name($container_name);
            verify_own_container($container_name);
            remove_container_by_name($container_name);
            return 1;
        }
    );

    return 1;
}

# start / stop / restart
sub api_lifecycle {
    my ( $container_name, $action ) = @_;

    die "Invalid action “$action”\n" if !grep { $_ eq $action } qw(start stop restart);

    return run_in_user_session(
        sub {
            validate_user_container_name($container_name);
            my $service = get_container_service_name($container_name);

            # Before a bring-up and after a stop, never after a start — that
            # would hide a real failure from status.
            my $stopping = $action eq 'stop';
            reset_container_unit_failure($container_name) if !$stopping;
            my $rv = sysctl( $action => $service );
            reset_container_unit_failure($container_name) if $stopping;

            # Asymmetric on purpose (EA4-325). $rv used to be returned here and
            # then thrown away by the callers, so every verb reported success
            # whatever systemd did.
            #
            # A bring-up that did not happen is a failure the caller has to know
            # about. A `stop` that returns non-zero is not the same thing: an
            # already-stopped unit, a unit file that is gone, a container that has
            # already been removed all land here, and all of them mean the thing
            # the caller asked for is true. Raising on those would break teardown
            # paths for no gain — the same reasoning as the reset_failed above.
            if ( !$stopping ) {
                die "Failed to $action “$container_name”: systemd refused the job. Check `systemctl --user status $service`.\n" if !$rv;

                # $rv on its own is not enough, and this is the trap the CLI hit
                # too: `systemctl start` reports success for a container that
                # starts and then dies, so a bring-up that leaves the application
                # down still looked like a win. Same poll the upgrade path uses.
                verify_container_started(
                    $container_name,
                    lead => "“$container_name” did not $action",
                    note => "",
                );
            }

            return $rv;
        }
    );
}

# is-active/is-enabled communicate purely through their exit code (and, unlike
# start/restart/enable, sysctl emits no cgroup warnings for them), so read the
# boolean result rather than the human-readable status text.
sub api_status {
    my ($container_name) = @_;

    return run_in_user_session(
        sub {
            validate_user_container_name($container_name);
            my $service = get_container_service_name($container_name);
            return {
                running => sysctl( 'is-active'  => $service ),
                enabled => sysctl( 'is-enabled' => $service ),
            };
        }
    );
}

sub api_cmd {
    my ( $container_name, $cmd_argv, $cd ) = @_;

    die "cmd requires a command to run (the “arg” parameter)\n" if ref($cmd_argv) ne 'ARRAY' || !@{$cmd_argv};

    return run_in_user_session( sub { return exec_in_container( $container_name, $cmd_argv, cd => $cd ) } );
}

1;

__END__

=encoding utf-8

=head1 CAVEAT EMPTOR!

All consumers of this module must ensure that this function is called prior to calling other functions:

    ea_podman::util::init_user();

Why? If this module doesn’t assume the consumer has init’d it’d need done in pretty much all functions. That would be wasteful and slow things down.

Some exceptions where it is safe to call before C<init_user()> are C<validate_user_container_name()>, C<load_known_containers()>, and C<get_containers()>.

=head2 Creating the account’s first container

C<init_user()> gives the account a lingering user systemd manager only when it
already has containers, because that manager exists to keep containers running
and nothing else — an account without any does not get one (CPANEL-55309).

A caller that is about to create a container for an account that may not have
one yet must say so:

    ea_podman::util::init_user( creating => 1 );

That is C<install> (CLI and UAPI) and C<perform_user_restore()>. Every other
verb acts on a container that already exists, so the registry answers for it.
Without C<creating>, an account with no containers gets its subuid/subgid
ranges and no session, and C<init_user()> returns false to say so.

=head2 Giving the linger back

The only linger C<ea-podman> ever disables is one it enabled itself, and only
once the account has no containers left at all. An account can be lingering for
reasons that have nothing to do with containers, and the systemd marker in
F</var/lib/systemd/linger> does not say who asked for it — so C<ea-podman> keeps
its own record instead, a marker file per account under
F</opt/cpanel/ea-podman/granted-linger> (see
C<ea_podman::subids::user_has_granted_linger()>). No record, no release.

Nothing to pass for this: C<ENSURE_USER> checks whether the account is lingering
before it runs C<enable-linger> and records the grant only when that call turned
it on. A record also outlives the linger it was written for, so
C<ea_podman::subids::grant_covers_current_linger()> compares the two markers'
timestamps before anything is disabled. Those timestamps are why
C<ea_podman::subids::ensure_user_session()> leaves an already-established session
alone rather than re-running C<enable-linger>, which would move systemd's marker
past our own record on every command.

A WebApp deployment arrives with the account I<already> lingering — the plugin's
own C<ENSURE_SESSION> runs C<enable-linger> before C<Cpanel::WebApps::Podman>
calls C<init_user()> — so C<ea-podman> never sees that transition. The plugin
writes the same grant record when its call is the one that enabled lingering, and
removing the WebApp then releases it here like any other. See DESIGN.md.
