package Cpanel::API::EAPodman;

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use cPstrict;

=encoding utf-8

=head1 NAME

Cpanel::API::EAPodman - UAPI surface for the C<ea-podman> container engine.

=head1 DESCRIPTION

Lets a cPanel user manage their rootless C<ea-podman> containers through UAPI
(cpsrvd / API tokens) instead of the C<ea-podman> command line.

This is the supported path for users whose login shell is restricted
(C<jailshell>) or virtualized (C<cagefs>): UAPI already runs as the
authenticated cPanel user, so it reaches the C<ea_podman::util> functions
B<directly> — it never execs the user's login shell, so the jail chroot is
never entered, and it bypasses the C<ea-podman> CLI's restricted-shell gate.
The privileged session bootstrap (C<loginctl enable-linger>, subuid/subgid)
happens as root inside C<ea_podman::util::init_user()> via the C<ENSURE_USER>
adminbin. See CPANEL-54037.

=cut

# ea-podman is an optional EA4 package installed under /opt/cpanel/ea-podman.
# Load its util/subids libraries on demand from the installed location. (The
# package also ships the ENSURE_USER adminbin the bootstrap relies on.)
our $LIB_DIR = '/opt/cpanel/ea-podman/lib/ea_podman';

sub _require_ea_podman_or_die {
    state $loaded;
    return 1 if $loaded;

    if ( !-e "$LIB_DIR/util.pm" ) {
        die "The “ea-podman” package is not installed.\n";
    }

    require "$LIB_DIR/util.pm";
    require "$LIB_DIR/subids.pm";
    $loaded = 1;
    return 1;
}

# Prime this (already unprivileged, cpuser) process for rootless podman the
# way the CPANEL-54037 verification showed is required, then run $code.
#
# init_user() does the real work: as root (via the ENSURE_USER adminbin) it
# allocates subuid/subgid and runs `loginctl enable-linger`, which creates
# /run/user/<uid> and starts the user systemd manager; then it points this
# process's XDG_RUNTIME_DIR/DBUS at that runtime dir. We clear any inherited
# DBUS_SESSION_BUS_ADDRESS first so a stale value can't point podman at the
# wrong bus.
#
# ea_podman::util (and init_user's check_proc) print progress/warnings to
# STDOUT/STDERR. Under a synchronous UAPI call that output would be
# interleaved into — and corrupt — the JSON response, so capture it. On
# failure the captured text is appended to the exception so the real error is
# debuggable instead of a bare "Failed to create container".
sub _run_in_user_session ($code) {
    _require_ea_podman_or_die();

    local $ENV{XDG_RUNTIME_DIR} = "/run/user/$>";
    local $ENV{DBUS_SESSION_BUS_ADDRESS};
    delete $ENV{DBUS_SESSION_BUS_ADDRESS};

    # Run from a working directory the cpuser can stat. cpsrvd may hand us a
    # cwd inherited from root (e.g. /root, mode 0700) that the dropped cpuser
    # cannot enter, which breaks rootless podman. (CPANEL-54037: the cpsrvd
    # UAPI context runs OUTSIDE any CageFS cage, so this — plus the privileged
    # enable-linger bootstrap — is all that jailshell/cagefs users need.)
    if ( my $home = ( getpwuid($>) )[7] ) {
        chdir($home);    # best-effort; a failed chdir simply leaves cwd as-is
    }

    require Capture::Tiny;
    my ( @rv, $err );
    my $output = &Capture::Tiny::capture_merged(
        sub {
            local $@;
            eval {
                ea_podman::util::init_user();
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

# NOTE (gating): UAPI requires an authenticated cpsrvd session (or API token)
# for the calling cPanel user, and every operation acts only on that user's
# own containers — the same trust level as the existing ea-podman adminbin. A
# dedicated feature/role ACL for container management is a product decision
# (TI-205) and intentionally not invented here.
my $mutating     = {};
my $non_mutating = { allow_demo => 0 };

our %API = (
    list      => $non_mutating,
    install   => $mutating,
    upgrade   => $mutating,
    uninstall => $mutating,
    start     => $mutating,
    stop      => $mutating,
    restart   => $mutating,
    status    => $non_mutating,
    cmd       => $mutating,
);

=head1 FUNCTIONS

=head2 list

Return the caller's registered C<ea-podman> containers as a hash keyed by
container name. Read-only; does not require the rootless session.

=cut

sub list ( $args, $result ) {
    _require_ea_podman_or_die();

    my $user          = scalar getpwuid($>);
    my $containers_hr = ea_podman::util::load_known_containers();

    my %mine;
    for my $c ( grep { $_->{user} eq $user } values %{$containers_hr} ) {
        $mine{ $c->{container_name} } = $c;
    }

    $result->data( \%mine );
    return 1;
}

=head2 install

Install and start a container for the caller.

ARGUMENTS

=over

=item name (required) - an EA4 container-based package name (e.g. C<ea-podman>
managed) or an arbitrary container name.

=item image - the container image (required for an arbitrary name; omit for an
EA4 package, which supplies its own).

=item cpuser_port - container port(s) to publish; may be given more than once
(C<0> means "same as the assigned host port"). The host-facing port is assigned
by the cPanel port authority.

=item env - C<KEY=VALUE> environment pair(s); may be given more than once.

=item accept_arbitrary_image_risk - boolean; required to install an arbitrary
(non-EA4-package) image, acknowledging the trust/reliability caveats.

=back

Returns the generated container name in C<data.container_name>.

NOTE: this is synchronous, so installing a package whose image must be pulled
can be slow. Driving C<install> asynchronously (a UserTasks worker writing to a
deploy log) is the follow-up for large/remote images; the fast verbs below are
fine synchronous.

=cut

sub install ( $args, $result ) {
    my $name  = $args->get_length_required('name');
    my $image = $args->get('image');

    my @cpuser_ports = grep { length } $args->get_multiple('cpuser_port');
    my @envs         = grep { length } $args->get_multiple('env');

    my @start_args;
    push @start_args, map { "--cpuser-port=$_" } @cpuser_ports;
    push @start_args, map { ( '-e' => $_ ) } @envs;

    if ( $args->get('accept_arbitrary_image_risk') ) {
        push @start_args, '--i-understand-the-risks-do-it-anyway';
    }

    # The image, when given, must be the last start arg.
    push @start_args, $image if length($image);

    my $container_name = _run_in_user_session(
        sub {
            return ea_podman::util::install_container( $name, @start_args );
        }
    );

    $result->data( { container_name => $container_name } );
    return 1;
}

=head2 upgrade

Pull the latest image for the named container and recreate it.
ARGUMENTS: C<container_name> (required).

NOTE: like C<install>, this is synchronous and pulls a new image, so it can be
slow for large/remote images. The same async follow-up (a UserTasks worker
writing to a deploy log) applies.

=cut

sub upgrade ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');

    _run_in_user_session(
        sub {
            ea_podman::util::upgrade_container($container_name);
            return 1;
        }
    );

    return 1;
}

=head2 uninstall

Stop, remove, and deregister the named container (and free its ports).
ARGUMENTS: C<container_name> (required).

=cut

sub uninstall ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');

    _run_in_user_session(
        sub {
            ea_podman::util::validate_user_container_name($container_name);
            ea_podman::util::remove_container_by_name($container_name);
            return 1;
        }
    );

    return 1;
}

=head2 start / stop / restart

Control the container's systemd user service. ARGUMENTS: C<container_name>
(required).

=cut

sub start   ( $args, $result ) { return _lifecycle( $args, 'start' ); }
sub stop    ( $args, $result ) { return _lifecycle( $args, 'stop' ); }
sub restart ( $args, $result ) { return _lifecycle( $args, 'restart' ); }

sub _lifecycle ( $args, $action ) {
    my $container_name = $args->get_length_required('container_name');

    _run_in_user_session(
        sub {
            ea_podman::util::validate_user_container_name($container_name);
            my $service = ea_podman::util::get_container_service_name($container_name);
            return ea_podman::util::sysctl( $action => $service );
        }
    );

    return 1;
}

=head2 status

Report the named container's systemd user-service state. ARGUMENTS:
C<container_name> (required). Returns C<data.running> and C<data.enabled>
booleans.

=cut

sub status ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');

    # is-active/is-enabled communicate purely through their exit code (and,
    # unlike start/restart/enable, sysctl emits no cgroup warnings for them), so
    # we read the boolean result rather than the human-readable status text —
    # more useful to an API consumer than `systemctl status` output.
    my $state = _run_in_user_session(
        sub {
            ea_podman::util::validate_user_container_name($container_name);
            my $service = ea_podman::util::get_container_service_name($container_name);
            return {
                running => ea_podman::util::sysctl( 'is-active'  => $service ),
                enabled => ea_podman::util::sysctl( 'is-enabled' => $service ),
            };
        }
    );

    $result->data($state);
    return 1;
}

=head2 cmd

Run a one-shot, non-interactive command inside the named container and return
its stdout, stderr, and exit code. Does not assume the container has a shell:
the command is exec'd directly by C<podman exec> (no C<-it>, no C<bash -c>
wrapper) — the way an interactive C<ea-podman bash> could never be delegated
over UAPI (no TTY/streaming channel) is documented in
C<docs/container-shell-access.md>; this is the non-interactive verb that doc
sketches.

ARGUMENTS

=over

=item container_name (required) - the container to run the command in.

=item arg (required, repeatable) - the command and its arguments, in order
(e.g. C<arg=date>, or C<arg=ls&arg=-la>).

=item cd - an optional working directory inside the container, passed to
C<podman exec --workdir> (no shell C<cd> is used, so this works even without a
shell in the container).

=back

Returns C<data.stdout>, C<data.stderr>, C<data.exit_code>, and
C<data.stdout_truncated> / C<data.stderr_truncated> (true if the captured
output was cut off at the size cap). A non-zero C<exit_code> is not itself a
UAPI failure — it's just the exec'd command's own exit status.

=cut

sub cmd ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');
    my $cd             = $args->get('cd');

    # Unlike cpuser_port/env (where an empty repeat is meaningless), an empty
    # string can be a legitimate argv element for an arbitrary command, so it
    # is kept — this must match the direct-CLI path's unfiltered @cmd_argv
    # exactly, for the same command to behave identically over either path.
    my @cmd_argv = $args->get_multiple('arg');
    die "cmd requires a command to run (the “arg” parameter)\n" if !@cmd_argv;

    my $state = _run_in_user_session(
        sub {
            return ea_podman::util::exec_in_container( $container_name, \@cmd_argv, cd => $cd );
        }
    );

    $result->data($state);
    return 1;
}

1;
