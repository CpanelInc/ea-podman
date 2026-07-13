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
    check_proc();

    # Order matters (CPANEL-54037): ensure_user() bootstraps the rootless
    # session *as root* (subuid/subgid + `loginctl enable-linger`, which
    # creates /run/user/<uid> and starts the user systemd manager). It must
    # run before ensure_su_login(), which points this (already unprivileged)
    # process’s XDG_RUNTIME_DIR/DBUS at that now-existing runtime dir.
    ensure_user();
    ensure_su_login();
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
use Cwd                    ();

use Path::Tiny 'path';

my $container_name_suffix_regexp      = qr/\.[^.]+\.[0-9][0-9]$/;
my $container_name_sans_suffix_regexp = qr/^[a-z][a-z0-9-]+[a-z0-9]/;
my $known_containers_file             = '/opt/cpanel/ea-podman/registered-containers.json';

# See
#     1. https://docs.docker.com/engine/reference/commandline/tag/#extended-description
#     2. https://regex101.com/r/hP8bK1/1
my $image_name_regexp = qr'^(?:(?=[^:\/]{4,253})(?!-)[a-zA-Z0-9-]{1,63}(?<!-)(?:\.(?!-)[a-zA-Z0-9-]{1,63}(?<!-))*(?::[0-9]{1,5})?/)?((?![._-])(?:[a-z0-9._-]*)(?<![._-])(?:/(?![._-])[a-z0-9._-]*(?<![._-]))*)(?::(?![.-])[a-zA-Z0-9_.-]{1,128})?$';

sub ensure_su_login {    # needed when $user is from root `su - $user` / AccessIds (cpsrvd, hooks) and not SSH
    $ENV{DBUS_SESSION_BUS_ADDRESS} ||= "unix:path=/run/user/$>/bus";    # root can need this

    return if $> == 0;

    delete $ENV{XDG_RUNTIME_DIR} if $ENV{XDG_RUNTIME_DIR} && $ENV{XDG_RUNTIME_DIR} ne "/run/user/$>";
    $ENV{XDG_RUNTIME_DIR} ||= "/run/user/$>";

    # The runtime dir + user systemd manager are bootstrapped *as root* in
    # ea_podman::subids::ensure_user_session() (`loginctl enable-linger`),
    # reached via ensure_user()/the ENSURE_USER adminbin, which init_user()
    # runs before us. We cannot create it here — privileges were already
    # dropped, which is exactly why the previous unprivileged
    # `loginctl enable-linger` attempt could never work. If it is still
    # missing, the privileged bootstrap did not run (or linger was torn down):
    # fail with a clear, actionable error rather than letting podman emit a
    # cryptic “Failed to connect to user scope bus” downstream.
    if ( !-d $ENV{XDG_RUNTIME_DIR} ) {
        my $user = getpwuid($>);
        die "ea-podman: the rootless runtime directory “$ENV{XDG_RUNTIME_DIR}” for “$user” does not exist.\n" . "The privileged setup must run first so `loginctl enable-linger $user` can create it (run `ea-podman subids --ensure` as root, or invoke via the ENSURE_USER adminbin / the cpsrvd path).\n";
    }

    # Run from a working directory the cpuser can actually stat. cpsrvd, the
    # `uapi --user=` CLI, and root `su`/AccessIds callers can leave us with a
    # cwd inherited from root (e.g. /root, mode 0700) that the cpuser cannot
    # enter — which breaks rootless podman and makes File::Path::Tiny::rm()
    # die while restoring cwd during cleanup. (CPANEL-54037: this — not the
    # cage — is what blocked cagefs users; the cpsrvd UAPI context runs
    # OUTSIDE the cage, so no special cage handling is needed.)
    my $home = ( getpwuid($>) )[7];
    chdir($home) if $home && -d $home;

    return;
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

    `podman stop --ignore --time 30 $container_name 2> /dev/null > /dev/null`;

    return;
}

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

    return podman( 'create', "--hostname" => $container_name, "--name" => $container_name, @ulimit, @start_args );
}

# The RLIMIT_NPROC hard cap of the calling user's systemd --user manager (which
# is what actually starts the container). Read from the system manager so it
# works without the user bus. Returns undef when the limit is unlimited/unknown
# (nothing to pin — an unlimited manager applies an unlimited bake just fine).
sub _user_manager_nproc_cap {
    my $uid = $>;

    chomp( my $cap = `systemctl show user\@$uid.service -p LimitNPROC --value 2>/dev/null` );
    chomp( $cap = `systemctl show -p DefaultLimitNPROC --value 2>/dev/null` ) if $cap !~ /^[0-9]+$/;

    return $cap =~ /^[0-9]+$/ ? $cap : undef;
}

sub get_container_service_name {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return "container-$container_name.service";
}

sub get_containers {
    my %containers;

    for my $line (`podman ps --no-trunc --format "{{.Names}} {{.Image}}"`) {
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

sub generate_container_service {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    my $homedir = ( getpwuid($>) )[7];
    File::Path::Tiny::mk( "$homedir/.config/systemd/user", 0750 );
    my $service_name = get_container_service_name($container_name);

    my $container_name_qx = quotemeta($container_name);
    my $service_name_qx   = quotemeta($service_name);

    `podman generate systemd --restart-policy on-failure --name $container_name_qx > ~/.config/systemd/user/$service_name_qx`;
    die "Failed to generate service file\n" if $? != 0;

    sysctl( enable => $service_name ) || die "Failed to enable “$service_name”\n";
    return 1;
}

sub _ensure_latest_container {
    my ( $container_name, @start_args ) = @_;

    warn_if_problematic_cgroup();    # advise (non-fatal) on CloudLinux + cgroup v2

    validate_user_container_name($container_name);

    _ensure_backup_conf_excludes_files();

    my $caller_func = ( caller(1) )[3];
    my $isupgrade   = 0;
    my $isrestore   = 0;
    my $portsfunc;
    if ( $caller_func eq "ea_podman::util::install_container" ) {
        $portsfunc = \&_get_new_ports;
    }
    elsif ( $caller_func eq "ea_podman::util::upgrade_container" ) {
        $portsfunc = \&_get_current_ports;
        $isupgrade = 1;
    }
    elsif ( $caller_func eq "ea_podman::util::restore_containers_for_user" ) {
        $isrestore = 1;
        $portsfunc = \&_get_new_ports;
    }
    else {
        die "_ensure_latest_container() should only be called by install_container() or upgrade_container() (i.e. not $caller_func())\n";
    }

    my $container_root = _get_container_root();
    my $container_dir  = "$container_root/$container_name";

    if ( $isupgrade || $isrestore ) {
        die "“$container_dir” does not exist\n" if !-d $container_dir;
    }

    if ( my $pkg = get_pkg_from_container_name($container_name) ) {
        my $pkg_dir = "/opt/cpanel/$pkg";
        if ( -f "$pkg_dir/ea-podman.json" ) {
            die "Upgrade takes no start args\n" if $isupgrade && @start_args;
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
                else {
                    push @real_start_args, $item;
                }
            }

            push @real_start_args, $docker_name;
        }

        # ensure the user isn’t specifying something they shouldn’t
        validate_start_args( \@real_start_args );

        if ( !$isupgrade && !$isrestore ) {
            File::Path::Tiny::mk( $container_dir, 0750 ) || die "Could not create “$container_dir”: $!\n";
            my $json = Cpanel::JSON::pretty_canonical_dump( { start_args => \@real_start_args, ports => \@cpuser_ports } );
            _file_write_chmod( "$container_dir/ea-podman.json", $json, 0600 );
        }

        my $docker_name = pop @real_start_args;    # so we can put ports before the image

        # then add the ports if any
        my @ports = $portsfunc->( $container_name => scalar(@cpuser_ports) );
        for my $idx ( 0 .. $#ports ) {
            my $container_port = $cpuser_ports[$idx] || $ports[$idx];
            push @real_start_args, "-p", "$ports[$idx]:$container_port";
        }

        @start_args = @real_start_args;
        push @start_args, $docker_name;
    }

    my $image_arg = $start_args[-1];                # so we can persist image name
    my ($image_name) = $image_arg =~ m|([^/]+)$|;

    uninstall_container($container_name) if $isupgrade || $isrestore;                # avoid spurious warnings on install
    register_container( $container_name, $isupgrade || $isrestore, $image_name );    # register before create just in case

    if ( !create_user_container( $container_name, @start_args ) ) {
        if ( !$isupgrade ) {
            deregister_container($container_name);

            # File::Path::Tiny::rm() chdir()s internally and dies if it cannot
            # restore the original cwd (e.g. an inaccessible /root). Move to a
            # safe cwd and don't let cleanup mask the real create failure.
            chdir("/");
            eval { File::Path::Tiny::rm($container_dir) };
        }

        die "Failed to create container\n";
    }

    generate_container_service($container_name);

    my $service_name = get_container_service_name($container_name);
    sysctl( start => $service_name );
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
    _ensure_latest_container( $container_name, @start_args );
    return $container_name;
}

sub upgrade_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    _ensure_latest_container($container_name);
}

sub restore_containers_for_user {
    my (@containers) = @_;

    foreach my $container (@containers) {
        my $container_name = $container->{container_name};

        print "Restoring $container_name\n";

        validate_user_container_name($container_name);
        _ensure_latest_container($container_name);
    }
}

sub move_container_dir {
    my ($container_name) = @_;

    my $container_root = _get_container_root();
    my $container_dir  = "$container_root/$container_name";

    print "Moving “$container_root/$container_name” to “$container_root/$container_name.bak”\n";
    path($container_dir)->move("$container_dir.bak");

    return;
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
    my $containers_hr = {};
    $containers_hr = Cpanel::JSON::LoadFile($known_containers_file) if ( -e $known_containers_file );

    return $containers_hr;
}

sub register_container_as_root {
    my ( $container_name, $user, $isupgrade, $image ) = @_;

    my $containers_hr = load_known_containers_as_root();

    my $pkg = get_pkg_from_container_name($container_name);

    # We want the slurp to error out if a package looking thing is not a container based package
    my $pkg_ver = $pkg ? path("/opt/cpanel/$pkg/pkg-version")->slurp : undef;
    chomp($pkg_ver) if defined $pkg_ver;

    if ( exists $containers_hr->{$container_name} && !$isupgrade ) {
        warn "$container_name is already registered";
        return;
    }
    elsif ( !exists $containers_hr->{$container_name} && $isupgrade ) {
        warn "$container_name is not registered, registering now …\n";
    }

    $containers_hr->{$container_name} = {
        container_name => $container_name,
        user           => $user,
        pkg            => $pkg,
        pkg_version    => $pkg_ver,
        image          => $image,
    };

    Cpanel::JSON::DumpFile( $known_containers_file, $containers_hr ) or die "Cannot open known containers file";

    return;
}

sub deregister_container_as_root {
    my ($container_name) = @_;

    my $containers_hr = load_known_containers_as_root();

    if ( !exists $containers_hr->{$container_name} ) {
        warn "$container_name is not registered";
        return;
    }

    delete $containers_hr->{$container_name} if ( exists $containers_hr->{$container_name} );

    Cpanel::JSON::DumpFile( $known_containers_file, $containers_hr ) or die "Cannot open known containers file";

    return;
}

sub remove_container_by_name {
    my ($container_name) = @_;

    print "Removing $container_name\n";

    ea_podman::util::remove_port_authority_ports($container_name);
    ea_podman::util::uninstall_container($container_name);
    ea_podman::util::deregister_container($container_name);
    ea_podman::util::move_container_dir($container_name);

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

    return;
}

sub upgrade_containers_for_a_user {
    my (@containers) = @_;

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

    foreach my $container (@containers) {
        upgrade_container( $container->{container_name} );
    }

    return;
}

sub register_container {
    my ( $container_name, $isupgrade, $image ) = @_;

    if ( $> == 0 ) {
        local $@;
        eval { register_container_as_root( $container_name, "root", $isupgrade, $image ); };

        die "Unable to register “$container_name”: $@\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'REGISTER', $container_name, $isupgrade, $image );
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

    # The very first command has to be ensure_user which establishes this user
    # in the /etc/subuid and /etc/subgid files, critical to podman
    if ( $> == 0 ) {
        local $@;
        eval { ea_podman::subids::ensure_user_root("root"); };

        die "Unable to ensure the root has subuids and subgids\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'ENSURE_USER' );
    }

    return;
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

sub perform_user_backup {
    my $user = getpwuid($>);

    die "Cannot be run as root\n" if ( $> == 0 );

    my $containers_hr = ea_podman::util::load_known_containers();

    my @containers = values %{$containers_hr};
    @containers = grep { $_->{user} eq $user } @containers;
    @containers = sort { $a->{user} cmp $b->{user} } @containers;

    if ( @containers == 0 ) {
        print "There are no containers\n";
        return 1;
    }

    foreach my $container (@containers) {
        my @curr_ports = ea_podman::util::_get_current_ports( $container->{container_name} );
        $container->{curr_ports} = \@curr_ports;
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

        print `tar czf $tarball_name ea_podman_backup_$user.json ea-podman.d 2> /dev/null` . "\n";
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

sub perform_user_restore {
    my ($backup_tarball) = @_;

    my $homedir = ( getpwuid($>) )[7];
    my $user    = getpwuid($>);

    # Remove any existing containers

    print "\nRemoving existing containers first\n\n";

    die "Cannot be run as root\n" if ( $> == 0 );

    system( '/opt/cpanel/ea-podman/bin/ea-podman', 'remove_containers', '--all' );
    Path::Tiny::path("$homedir/ea-podman.d")->remove_tree( { safe => 0 } );
    Path::Tiny::path("$homedir/.config/systemd/user")->remove_tree( { safe => 0 } );

    # Now explode the tarball in the homedir, this sets up the restore

    print "\nStarting the restore …\n\n";

    {
        # Normally I would use File::chdir, but it seems to cause perlcc to crash

        my $pwd = Cwd::getcwd();
        chdir $homedir;

        print `tar xf $backup_tarball 2> /dev/null` . "\n";

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

    ea_podman::util::init_user();
    ea_podman::util::restore_containers_for_user(@containers);

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

1;

__END__

=encoding utf-8

=head1 CAVEAT EMPTOR!

All consumers of this module must ensure that this function is called prior to calling other functions:

    ea_podman::util::init_user();

Why? If this module doesn’t assume the consumer has init’d it’d need done in pretty much all functions. That would be wasteful and slow things down.

Some exceptions where it is safe to call before C<init_user()> are C<validate_user_container_name()>, C<load_known_containers()>, and C<get_containers()>.
