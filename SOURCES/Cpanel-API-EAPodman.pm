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

# The verb bodies — including the rootless-session priming that used to live
# here as _run_in_user_session() — are shared with the ea_podman admin module's
# lifecycle actions, so both entry points behave the same. See
# ea_podman::util::run_in_user_session(). (EA4-315)

# NOTE (gating): UAPI requires an authenticated cpsrvd session (or API token)
# for the calling cPanel user, and every operation acts only on that user's
# own containers. The verbs that create or run something also need the
# ea_podman feature, matching the ea_podman admin module's actions of the same
# name; the ones that only read or remove the caller's own state do not, so an
# account whose feature is turned off can still see and remove what it has.
# start and restart need the gate here: they reach the admin module only
# through the ungated ENSURE_USER(0). (EA4-315)
my $feature_gated = { needs_feature => 'ea_podman' };
my $mutating      = {};
my $non_mutating  = { allow_demo => 0 };

our %API = (
    list      => $non_mutating,
    install   => $feature_gated,
    upgrade   => $feature_gated,
    uninstall => $mutating,
    start     => $feature_gated,
    stop      => $mutating,
    restart   => $feature_gated,
    status    => $non_mutating,
    cmd       => $feature_gated,
);

=head1 FUNCTIONS

=head2 list

Return the caller's registered C<ea-podman> containers as a hash keyed by
container name. Read-only; does not require the rootless session.

=cut

sub list ( $args, $result ) {
    _require_ea_podman_or_die();

    $result->data( ea_podman::util::api_list() );
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
    my $name = $args->get_length_required('name');

    _require_ea_podman_or_die();

    my $data = ea_podman::util::api_install(
        name                        => $name,
        image                       => scalar $args->get('image'),
        cpuser_port                 => [ $args->get_multiple('cpuser_port') ],
        env                         => [ $args->get_multiple('env') ],
        accept_arbitrary_image_risk => scalar $args->get('accept_arbitrary_image_risk'),
    );

    $result->data($data);
    return 1;
}

=head2 upgrade

Pull the image the named container's configuration names, and recreate the
container only if something actually moved — a newer image for the tag it
tracks, or, for an EasyApache 4 package, a newer version of that package. When
nothing has changed this does nothing at all: the container is not torn down,
recreated, or restarted.

A container that is not running is recreated and left not running, since a
deliberate stop cannot be told from a crash.

ARGUMENTS: C<container_name> (required), C<force> (optional).

C<force> skips the comparison, recreates unconditionally, and starts the
container afterwards. It is what re-applies a configuration change that does not
move the image — which is why C<Cpanel::WebApps::Podman::redeploy_app> passes it
(CPANEL-56732). On C<force> a failed pull warns and falls back to the locally
cached image rather than failing, so a registry outage cannot break a redeploy;
without it a failed pull leaves the container untouched and reports why.

NOTE: like C<install>, this is synchronous and now really does pull, so it can be
slow for large or remote images. The same async follow-up (a UserTasks worker
writing to a deploy log) applies.

=cut

sub upgrade ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');
    my $force          = $args->get('force');

    _require_ea_podman_or_die();
    ea_podman::util::api_upgrade( $container_name, force => $force );

    return 1;
}

=head2 uninstall

Stop, remove, and deregister the named container (and free its ports).
ARGUMENTS: C<container_name> (required).

=cut

sub uninstall ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');

    _require_ea_podman_or_die();
    ea_podman::util::api_uninstall($container_name);

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

    _require_ea_podman_or_die();
    ea_podman::util::api_lifecycle( $container_name, $action );

    return 1;
}

=head2 status

Report the named container's systemd user-service state. ARGUMENTS:
C<container_name> (required). Returns C<data.running> and C<data.enabled>
booleans.

=cut

sub status ( $args, $result ) {
    my $container_name = $args->get_length_required('container_name');

    _require_ea_podman_or_die();
    $result->data( ea_podman::util::api_status($container_name) );

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

    _require_ea_podman_or_die();
    $result->data( ea_podman::util::api_cmd( $container_name, \@cmd_argv, $cd ) );

    return 1;
}

1;
