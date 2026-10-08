package Cpanel::Admin::Modules::Cpanel::ea_podman;

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use cPstrict;

use parent 'Cpanel::Admin::Base';

use Cpanel::Debug     ();
use Cpanel::Exception ();
use Cpanel::JSON      ();

=encoding utf-8

=head1 NAME

Cpanel::Admin::Modules::Cpanel::ea_podman - root-side actions for C<ea-podman>

=head1 SYNOPSIS

    # from any cpuser process, uncompiled perl included
    Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'LIST' );
    Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'INSTALL', { name => 'ea-memcached16' } );

=head1 DESCRIPTION

The C<ea-podman> package's admin module. cpsrvd loads it in-process and runs
each action as root on behalf of the calling cpuser, whose identity comes from
the socket's peer credentials — never from an argument.

It replaces the C<bin/admin/Cpanel/ea_podman> C<Cpanel::AdminBin::Script::Call>
script under the same namespace and module name, with the same action names,
arguments and returns, so nothing that calls in has to change. (EA4-315)

The lifecycle actions (C<INSTALL> … C<CMD>) are how a jailshell or CageFS
account's C<ea-podman> CLI manages its containers: they run as root outside the
jail or cage, fork, drop fully to the cpuser and run the same verb bodies the
C<EAPodman> UAPI runs. See L<ea_podman::util/run_in_user_session>.

=cut

# ea-podman is an optional EA4 package installed under /opt/cpanel/ea-podman;
# load its libraries on demand, at action time rather than compile time, so a
# stray copy of this module never breaks cpsrvd's loading of it.
our $LIB_DIR = '/opt/cpanel/ea-podman/lib/ea_podman';

# The addon feature that gates creating and running containers. It is not in
# any feature list when first installed, which leaves it enabled for every
# account until an administrator disables it.
use constant FEATURE => 'ea_podman';

# Legacy bin's alarm; the in-process default (350s) is for other modules.
use constant _DEFAULT_ALARM => 120;

# Anything that can pull an image.
my %LONG_RUNNING = map { $_ => 1800 } qw(INSTALL UPGRADE);

# Everything else that brings up or reaches into a container.
my %MEDIUM_RUNNING = map { $_ => 350 } qw(START STOP RESTART STATUS UNINSTALL CMD);

use constant _actions => (

    # the legacy bin's actions, unchanged, less MINT_API_TOKEN and
    # REVOKE_API_TOKEN: with any caller allowed, the first would hand a
    # full-access API token to any process the account owns, and nothing calls
    # either any more (EA4-314)
    qw(
      LIST
      GIVE
      TAKE
      ENSURE_USER
      RELEASE_USER
      REGISTER
      DEREGISTER
      REGISTERED_CONTAINERS
      EXEC_IN_CONTAINER
    ),

    # lifecycle actions, one per EAPodman UAPI verb
    qw(
      LIST_CONTAINERS
      INSTALL
      UPGRADE
      UNINSTALL
      START
      STOP
      RESTART
      STATUS
      CMD
    ),
);

# Declared rather than inherited: a demo account may call nothing here, which is
# what the legacy bin did (no _demo_actions) and what the EAPodman UAPI does
# (allow_demo => 0 on every verb). Demo behaviour is unchanged.
use constant _demo_actions => ();

# Every caller, compiled or not. This is required, not a convenience: the
# ea-podman CLI is an uncompiled perl script (no more perlcc, EA4-315), and
# cpsrvd refuses a perl interpreter as a named parent.
#
# Caller-binary identity carries no authorization weight here. Every action:
#   - acts only for the peer-credential uid (get_caller_username()), never a
#     user named in its arguments;
#   - checks that a named container belongs to that account; and
#   - is behind the ea_podman feature, or says why it is exempt: only actions
#     that read or remove the caller's own state are, so an account whose
#     feature is turned off can still see and remove what it has.
# See L</CALLED DIRECTLY WITH HOSTILE ARGUMENTS> for what each action can do
# when any process the account owns calls it with anything at all.
sub _allowed_parents { return '*' }

sub _alarm ($self) {
    my $action = ref $self ? ( $self->get_action() // '' ) : '';
    return $LONG_RUNNING{$action} // $MEDIUM_RUNNING{$action} // _DEFAULT_ALARM;
}

#######################
#### legacy actions ##
#######################

# Not feature-gated (read own state). Ownership: the port authority is keyed by
# account, and only ever asked about the caller.
sub LIST ($self) {
    my $cpuser = $self->_debug_and_user();

    require Capture::Tiny;
    return Capture::Tiny::capture_merged( sub { system( '/scripts/cpuser_port_authority', 'list', $cpuser ) } );
}

sub GIVE ( $self, $num_ports = undef, $container_name = undef ) {
    my $cpuser = $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    my $portassignments_hr      = _load_json_or_die( scalar $self->LIST(), 'port assignments' );
    my $num_ports_already_owned = scalar( keys %{$portassignments_hr} );

    _die_with_message("Must provide a number of ports") if !defined $num_ports;
    _die_with_message("ports must be numeric")          if $num_ports !~ m/^[1-9][0-9]?$/;

    my $total_ports = $num_ports + $num_ports_already_owned;
    _die_with_message("Cannot be assigned more than 100 ports") if $total_ports > 100;

    $container_name //= "";
    _require_ea_podman_or_die();
    _pass_error( sub { ea_podman::util::validate_user_container_name($container_name) } );

    # Ownership: ports are only ever given for a container named for the caller
    # (<base>.<user>.NN), as REGISTER requires of the same name.
    _die_with_message("That container name does not belong to this account")
      if !ea_podman::util::container_name_belongs_to_user( $container_name, $cpuser );

    require Capture::Tiny;
    return Capture::Tiny::capture_merged( sub { system( '/scripts/cpuser_port_authority', 'give', $cpuser, $num_ports, "--service=$container_name" ) } );
}

# Not feature-gated (removes own state): an account without the feature can
# still uninstall without leaking ports. Ownership: the port authority is keyed
# by account; only the caller's own assignments are listed and handed back.
sub TAKE ( $self, $container_name = undef ) {
    my $cpuser = $self->_debug_and_user();

    require Capture::Tiny;
    my $raw_json = Capture::Tiny::capture_merged( sub { system( '/scripts/cpuser_port_authority', 'list', $cpuser ) } );

    my $hr = _load_json_or_die( $raw_json, 'port assignments' );

    my @ports;
    for my $port ( keys %{$hr} ) {
        push( @ports, $port ) if ( $hr->{$port}->{service} eq ( $container_name // '' ) );
    }

    # `take` refuses an empty list, and a container with no ports is not a failure
    return "" if !@ports;

    my ( $out, $rv ) = Capture::Tiny::capture_merged( sub { system( '/scripts/cpuser_port_authority', 'take', $cpuser, @ports ) } );
    chomp( $out //= "" );
    _die_with_message( "`cpuser_port_authority take` failed" . ( length $out ? ": $out" : "" ) ) if $rv;

    return $out;
}

# Feature-gated only when it may create a session ($creating). ENSURE_USER(0)
# is exempt: init_user() calls it on every verb, uninstall included, and it only
# ever grants a session to an account that already has containers. Ownership:
# only ever the caller's own subids and session.
sub ENSURE_USER ( $self, $creating = undef ) {
    my $cpuser = $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE) if $creating;

    _require_ea_podman_or_die();

    # subuid/subgid ranges are for anybody who runs podman at all. A lingering
    # user session is not: it exists to keep an account’s containers running, so
    # only an account that has containers — or says it is about to install its
    # first ($creating) — gets one. The registry that settles it is root-owned,
    # so the decision is made here rather than taken on trust. (CPANEL-55309)
    my $has_containers = ea_podman::util::user_has_containers_as_root($cpuser);
    my $session        = ( $creating || $has_containers ) ? 1 : 0;

    # Only knowable before we do it. An account already lingering records
    # nothing: that linger belongs to whoever enabled it.
    my $granting = ( $session && !ea_podman::subids::user_has_linger($cpuser) ) ? 1 : 0;

    local $@;

    # No containers ⇒ nothing to take down, so a manager that is up but unusable
    # may be restarted in place rather than reported. The reachable case is a
    # failed install, which releases the session it had just granted and can
    # leave the account wedged with no containers at all. See
    # ea_podman::subids::ensure_user_session().
    eval { ea_podman::subids::ensure_user_root( $cpuser, undef, $session, !$has_containers ); };

    if ( my $err = $@ ) {

        # A failure about this account's own user session names nothing but its
        # own uid and its own /run/user/<uid>, and it is the message that tells
        # the operator which command repairs the account -- useless if only root
        # ever reads it in the error log. Pass it through. (EA4-319)
        if ( ea_podman::subids::is_user_session_error($err) ) {
            Cpanel::Debug::log_warn("Could not ensure the user session for “$cpuser”: $err");
            _die_with_message( ea_podman::subids::strip_user_session_error($err) );
        }

        # Everything else gets the generic message: a subid refusal names
        # /etc/subuid and the account it collided with, which is root-side detail.
        # Log it so a refusal still leaves an administrator something to diagnose.
        Cpanel::Debug::log_warn("Could not ensure subids for “$cpuser”: $err");
        _die_with_message("Unable to ensure the user has subuids and subgids");
    }

    ea_podman::subids::record_linger_grant($cpuser) if $granting && ea_podman::subids::user_has_linger($cpuser);

    return $session;
}

# Not feature-gated (removes own state): the mirror image of ENSURE_USER. Only
# ever the caller’s
# own account, only a linger ENSURE_USER recorded granting, and only when the
# root-owned registry agrees there is nothing left to keep running — see
# ea_podman::util::_user_session_is_releasable().
sub RELEASE_USER ($self) {
    my $cpuser = $self->_debug_and_user();

    _require_ea_podman_or_die();

    local $@;
    my $released = eval { ea_podman::util::release_user_session_as_root($cpuser); };

    if ($@) {
        _die_with_message("Unable to release the user session");
    }

    return $released ? 1 : 0;
}

sub REGISTER ( $self, $container_name = undef, $isupgrade = undef, $image = undef, $webapp = undef ) {
    my $cpuser = $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    _die_with_message("Must provide a container name") if !defined $container_name;

    _require_ea_podman_or_die();

    _die_with_message("That container name does not belong to this account")
      if !ea_podman::util::container_name_belongs_to_user( $container_name, $cpuser );

    eval { ea_podman::util::register_container_as_root( $container_name, $cpuser, $isupgrade, $image, $webapp ); };

    _die_with_message("Unable to add to known_containers: $@") if ($@);

    return 1;
}

# Not feature-gated (removes own state): drops the caller's own registry entry
# on uninstall.
sub DEREGISTER ( $self, $container_name = undef ) {
    my $cpuser = $self->_debug_and_user();

    _die_with_message("Must provide a container name") if !defined $container_name;

    _require_ea_podman_or_die();

    # Ownership: only ever the caller's own registered container — mirror
    # EXEC_IN_CONTAINER (CPANEL-55337). Without this, any account could
    # deregister any other account's container by (guessable) name, dropping
    # it from the removal hooks and leaking its ports and container.
    _die_with_message("No such container for this account") if !_registered_to( $container_name, $cpuser );

    eval { ea_podman::util::deregister_container_as_root( $container_name, $cpuser ); };

    _die_with_message("Unable to remove from known_containers: $@") if ($@);

    return 1;
}

# Not feature-gated (read own state): every verb's ownership check reads this,
# uninstall's included. Ownership: filtered to the caller's entries.
sub REGISTERED_CONTAINERS ($self) {
    my $cpuser = $self->_debug_and_user();

    return $self->_own_registered_containers($cpuser);
}

sub EXEC_IN_CONTAINER ( $self, $container_name = undef, $cd = undef, @cmd_argv ) {
    my $cpuser = $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    # Run one non-interactive command inside the caller's container as root
    # (root can enter the subuid-owned, hidepid-hidden container that the cpuser
    # cannot; the command itself is re-mapped to the container's own root = the
    # cpuser, so it gains no host privilege). See ea_podman::util::exec_in_container.
    _die_with_message("Must provide a container name") if !defined $container_name || $container_name eq '';
    _die_with_message("Must provide a command to run") if !@cmd_argv;

    _require_ea_podman_or_die();

    eval { ea_podman::util::validate_user_container_name($container_name); };
    _die_with_message("Invalid container name") if $@;

    # Ownership: only ever the caller's own registered container.
    _die_with_message("No such container for this account") if !_registered_to( $container_name, $cpuser );

    $cd = undef if defined $cd && $cd eq '';
    my $result = eval { ea_podman::util::exec_in_container_as_root( $container_name, $cpuser, \@cmd_argv, $cd ); };
    _die_with_message("Could not run the command in the container: $@") if $@;

    return $result;
}

##########################
#### lifecycle actions ##
##########################
#
# Each takes one hashref of the EAPodman UAPI's parameter names and returns what
# that UAPI verb puts in its result's data. Checks that need root (ownership,
# the feature) happen here; the verb itself runs in a child fully dropped to the
# cpuser, since rootless podman and `systemctl --user` need the real uid to be
# the cpuser's — reduced privileges (euid only) are not enough.

# Not feature-gated (read own state): an account without the feature still
# needs to see what it has, to uninstall it. Ownership: filtered to the caller.
sub LIST_CONTAINERS ( $self, $args = undef ) {
    my $cpuser = $self->_debug_and_user();

    # Same shape as the UAPI's list (keyed by container_name); root reads the
    # registry directly, so there is nothing to drop to.
    my $mine = $self->_own_registered_containers($cpuser);
    return { map { ( $_->{container_name} // '' ) => $_ } values %{$mine} };
}

sub INSTALL ( $self, $args = undef ) {
    $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    $args = _args_hr($args);
    my %install = (
        name                        => _string_arg( $args, 'name', 1 ),
        image                       => _string_arg( $args, 'image' ),
        cpuser_port                 => _list_arg( $args, 'cpuser_port' ),
        env                         => _list_arg( $args, 'env' ),
        accept_arbitrary_image_risk => _string_arg( $args, 'accept_arbitrary_image_risk' ) ? 1 : 0,
    );

    return $self->_as_cpuser( sub { ea_podman::util::api_install(%install) } );
}

sub UPGRADE ( $self, $args = undef ) {
    $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    my $container_name = $self->_own_container_arg( $args, registered => 1 );
    my $force          = _string_arg( $args, 'force' ) ? 1 : 0;
    return $self->_as_cpuser( sub { ea_podman::util::api_upgrade( $container_name, force => $force ) } );
}

# Not feature-gated (removes own state): an account that loses the feature must
# still be able to remove what it has.
sub UNINSTALL ( $self, $args = undef ) {
    $self->_debug_and_user();

    my $container_name = $self->_own_container_arg( $args, registered => 1 );
    return $self->_as_cpuser( sub { ea_podman::util::api_uninstall($container_name) } );
}

sub START ( $self, $args = undef ) {
    $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    my $container_name = $self->_own_container_arg($args);
    $self->_as_cpuser( sub { ea_podman::util::api_lifecycle( $container_name, 'start' ) } );
    return 1;
}

# Not feature-gated (reduces own state): stopping only ever reduces what the
# account runs.
sub STOP ( $self, $args = undef ) {
    $self->_debug_and_user();

    my $container_name = $self->_own_container_arg($args);
    $self->_as_cpuser( sub { ea_podman::util::api_lifecycle( $container_name, 'stop' ) } );
    return 1;
}

sub RESTART ( $self, $args = undef ) {
    $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    my $container_name = $self->_own_container_arg($args);
    $self->_as_cpuser( sub { ea_podman::util::api_lifecycle( $container_name, 'restart' ) } );
    return 1;
}

# Not feature-gated (read own state).
sub STATUS ( $self, $args = undef ) {
    $self->_debug_and_user();

    my $container_name = $self->_own_container_arg($args);
    return $self->_as_cpuser( sub { ea_podman::util::api_status($container_name) } );
}

sub CMD ( $self, $args = undef ) {
    $self->_debug_and_user();
    $self->cpuser_has_feature_or_die(FEATURE);

    my $container_name = $self->_own_container_arg( $args, registered => 1 );
    my $cmd_argv       = _list_arg( _args_hr($args), 'arg', keep_empty => 1 );
    _die_with_message("cmd requires a command to run (the “arg” parameter)") if !@{$cmd_argv};
    my $cd = _string_arg( _args_hr($args), 'cd' );

    return $self->_as_cpuser( sub { ea_podman::util::api_cmd( $container_name, $cmd_argv, $cd ) } );
}

###############
#### helpers ##
###############

sub _debug_and_user ($self) {
    if ($Cpanel::Debug::level) {
        Cpanel::Debug::log_info( ( $self->get_action() // '?' ) . "() called" );
    }

    return $self->get_caller_username();
}

sub _require_ea_podman_or_die {
    return 1 if defined &ea_podman::util::init_user && defined &ea_podman::subids::user_has_linger;

    _die_with_message("The “ea-podman” package is not installed.") if !-e "$LIB_DIR/util.pm";

    require "$LIB_DIR/util.pm";
    require "$LIB_DIR/subids.pm";
    return 1;
}

sub _own_registered_containers ( $self, $cpuser ) {
    _require_ea_podman_or_die();

    my $usr_containers = {};
    my $all_containers = ea_podman::util::load_known_containers_as_root();
    for my $contname ( keys %{$all_containers} ) {
        if ( ( $all_containers->{$contname}{user} // '' ) eq $cpuser ) {
            $usr_containers->{$contname} = $all_containers->{$contname};
        }
    }

    return $usr_containers;
}

sub _registered_to ( $container_name, $cpuser ) {
    my $ent = ea_podman::util::load_known_containers_as_root()->{$container_name};
    return ( $ent && ( $ent->{user} // '' ) eq $cpuser ) ? 1 : 0;
}

# The container_name argument, checked as root: well formed, named for the
# calling account, and (for anything that acts on what the registry records)
# registered to it. The dropped child re-checks what the UAPI verb checks.
sub _own_container_arg ( $self, $args, %opts ) {
    my $cpuser         = $self->get_caller_username();
    my $container_name = _string_arg( _args_hr($args), 'container_name', 1 );

    _require_ea_podman_or_die();

    eval { ea_podman::util::validate_user_container_name($container_name); };
    _die_with_message("Invalid container name") if $@;

    _die_with_message("No such container for this account")
      if !ea_podman::util::container_name_belongs_to_user( $container_name, $cpuser )
      || ( $opts{registered} && !_registered_to( $container_name, $cpuser ) );

    return $container_name;
}

# Run $code as the calling cpuser in a forked child that has fully dropped
# privileges (real and effective uid/gid), with the cpuser's own HOME/USER/LOGNAME
# rather than cpsrvd's filtered request environment.
#
# Whatever the child throws is passed to the caller as-is. That is safe to show
# them: the child runs with only the caller's own privileges, so it can know
# nothing they could not, and it is exactly what the EAPodman UAPI (cpsrvd as
# the cpuser) reports for the same failure.
sub _as_cpuser ( $self, $code ) {
    my $cpuser = $self->get_caller_username();
    my $home   = $self->get_cpuser_homedir();

    _require_ea_podman_or_die();

    require Cpanel::AccessIds;

    local $@;
    my $ret = eval {
        scalar Cpanel::AccessIds::do_as_user_with_exception(
            $cpuser,
            sub {
                local $ENV{HOME}    = $home;
                local $ENV{USER}    = $cpuser;
                local $ENV{LOGNAME} = $cpuser;
                return $code->();
            }
        );
    };

    if ( my $err = $@ ) {
        _die_with_message( _err_to_string($err) );
    }

    return $ret;
}

# Exceptions come back from the child through Storable, which never reblesses,
# so they are strings or plain data structures.
sub _err_to_string ($err) {
    if ( ref $err eq 'HASH' ) {
        for my $key (qw(message _message error)) {
            return "$err->{$key}" if defined $err->{$key} && !ref $err->{$key};
        }
        return eval { Cpanel::JSON::Dump($err) } // "$err";
    }

    return "$err";
}

sub _args_hr ($args) {
    return {}                                              if !defined $args;
    _die_with_message("Arguments must be given as a hash") if ref $args ne 'HASH';
    return $args;
}

sub _string_arg ( $args, $key, $required = 0 ) {
    my $val = $args->{$key};
    _die_with_message("“$key” must be a string")          if ref $val;
    _die_with_message("Missing required argument “$key”") if $required && !length( $val // '' );
    return $val;
}

# A repeatable UAPI parameter: a list of strings (a lone string is a list of
# one). Empty strings are dropped, as the UAPI does for cpuser_port/env, unless
# keep_empty says an empty argv element is meaningful (cmd's arg).
sub _list_arg ( $args, $key, %opts ) {
    my $val  = $args->{$key};
    my @list = !defined $val ? () : ref $val eq 'ARRAY' ? @{$val} : ref $val ? _die_with_message("“$key” must be a list of strings") : ($val);

    _die_with_message("“$key” must be a list of strings") if grep { !defined || ref } @list;

    return $opts{keep_empty} ? \@list : [ grep { length } @list ];
}

sub _load_json_or_die ( $json, $what ) {
    my $hr = eval { Cpanel::JSON::Load($json) };
    _die_with_message("Could not read the $what: $@") if $@;
    return $hr;
}

# Run $code, passing any plain-text failure it throws to the caller verbatim
# rather than reducing it to an error ID. Only for checks whose message is
# meant for the user (e.g. name validation).
sub _pass_error ($code) {
    local $@;
    return 1 if eval { $code->(); 1 };
    my $err = $@;
    chomp $err;
    _die_with_message($err);
}

sub _die_with_message ($msg) {
    chomp $msg;
    die Cpanel::Exception::create( 'AdminError', [ message => $msg ] );
}

1;

__END__

=head1 ACTIONS

=head2 Legacy actions

Carried over from the C<bin/admin/Cpanel/ea_podman> script with the same
arguments and returns, except MINT_API_TOKEN and REVOKE_API_TOKEN, which are
gone (EA4-314): the CLI no longer needs an API token, and with C<_allowed_parents>
at C<*> minting one would hand it to any process the account owns.

=over

=item LIST

JSON string of the ports assigned to the caller.

=item GIVE( $NUM_PORTS, $CONTAINER_NAME )

Assigns $NUM_PORTS ports to the caller for the container. At most 100 in total.

=item TAKE( $CONTAINER_NAME )

Releases every port assigned to the caller for the container.

=item ENSURE_USER( $CREATING )

Ensures the caller has subuids and subgids, and a lingering user session if it
has containers or ($CREATING) is about to install its first. Returns whether
the account has a session.

The ranges are drawn from a space shared by every account, so allocation happens
under an exclusive lock. It also fails closed: an account whose range is not
exclusively its own is refused rather than run with containers that are not
isolated. The caller gets a generic failure; the reason is logged, and
C<ea-podman subids> lists every affected account.

When this call is what turns the linger on, the grant is recorded (see
C<ea_podman::subids::record_linger_grant()>) so L</RELEASE_USER> knows the linger
is ea-podman’s to give back later.

=item RELEASE_USER

Disables the caller’s systemd linger, but only when it is one L</ENSURE_USER>
recorded enabling, only when that record still covers the linger that is there
now, and only when the root-owned registry says the account has no containers
left to keep running. Returns whether it released one.

=item REGISTER( $CONTAINER_NAME, $ISUPGRADE, $IMAGE, $WEBAPP )

Adds the caller's container to ea-podman’s known containers list. $WEBAPP is
stored as a strict JSON boolean C<webapp> attribute and ignored on an update,
where the recorded value is preserved. The read-modify-write is done under an
exclusive lock and saved atomically (CPANEL-55342).

=item DEREGISTER( $CONTAINER_NAME )

Removes the caller's own registered container from the list.

=item REGISTERED_CONTAINERS

Hashref of the caller’s registry entries, keyed by container name.

=item EXEC_IN_CONTAINER( $CONTAINER_NAME, $CD, @ARGV )

Runs one non-interactive command in the caller's registered container, entering
it as root; returns C<stdout>, C<stderr>, C<exit_code> and the truncation flags.

=back

=head2 Lifecycle actions

Each takes one hashref of the C<EAPodman> UAPI verb's parameter names and
returns what that verb puts in its result's C<data>.

=over

=item LIST_CONTAINERS

=item INSTALL( { name, image, cpuser_port => [...], env => [...], accept_arbitrary_image_risk } )

=item UPGRADE( { container_name } )

=item UNINSTALL( { container_name } )

=item START / STOP / RESTART( { container_name } )

=item STATUS( { container_name } )

=item CMD( { container_name, arg => [...], cd } )

=back

=head1 AUTHORIZATION

Every action acts only for the peer-credential caller. Actions that create or
run something require the C<ea_podman> feature: GIVE, REGISTER, ENSURE_USER when
C<$CREATING>, EXEC_IN_CONTAINER, INSTALL, UPGRADE, START, RESTART and CMD.

The rest only read or remove the caller's own state, and are deliberately not
feature-gated so an account whose feature is turned off can still see and remove
what it has without leaking ports, registry entries or a lingering session:
LIST, TAKE, ENSURE_USER(0), RELEASE_USER, DEREGISTER, REGISTERED_CONTAINERS,
LIST_CONTAINERS, UNINSTALL, STOP and STATUS. This is a
considered exception to the "feature gate on every action" rule in
F<docs/security/surfaces/admin-bins.md>, not its shared-state ownership
carve-out: every one of them is still scoped to the caller's own resources.

No action is available to a demo account.

=head1 CALLED DIRECTLY WITH HOSTILE ARGUMENTS

C<_allowed_parents> is C<*>, so any process the account owns can call any action
with any arguments. What that gets it:

=over

=item LIST, REGISTERED_CONTAINERS, LIST_CONTAINERS, STATUS

Its own ports, registry entries and container state. Nothing it could not read
through the UAPI.

=item GIVE

Up to 100 ports in total, which the port authority would hand out through the
UAPI anyway, for a container name that must carry its own account. The name is
validated before it reaches the port authority.

=item TAKE, DEREGISTER, RELEASE_USER

Only its own ports, its own registry entry, and only a linger ea-podman granted
it once no containers are left.

=item ENSURE_USER

C<ENSURE_USER(1)> without ever installing leaves the account lingering with no
containers, the same state a failed install leaves; the next ENSURE_USER(0) or
uninstall releases it. Feature-gated.

=item REGISTER

A registry entry for a name that must carry its own account (C<*.$user.NN>).
The recorded C<image> is only ever pulled and run rootless as that account, and
C<webapp> is stored as a boolean and not updatable. Feature-gated.

=item EXEC_IN_CONTAINER, CMD

A command in its own registered container, re-mapped to the container's root
(the account's own uid). Feature-gated.

=item INSTALL, UPGRADE, UNINSTALL, START, STOP, RESTART

The corresponding UAPI verb, as itself, on containers named for (and, where the
registry matters, registered to) its own account.

=back

=cut
