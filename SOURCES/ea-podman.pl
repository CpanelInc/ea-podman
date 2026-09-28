#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea-podman                               Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

package scripts::ea_podman;

BEGIN {
    # I cannot get this to work using FindBin in 4 different environments, this works in all
    # 4 enviroments.
    #
    # The environments:
    #
    # Testing,  in the ea-podman repo dir
    # Script,   in /opt/cpanel/ea-podman/bin/ea-podman
    # Script,   in /usr/local/cpanel/scripts/ea-podman
    # AdminBin, in /usr/cpanel/local/bin/admin/Cpanel

    if ( -e '/opt/cpanel/ea-podman/lib' ) {    # it has been installed on the machine
        require '/opt/cpanel/ea-podman/lib/ea_podman/util.pm';
        require '/opt/cpanel/ea-podman/lib/ea_podman/subids.pm';
    }
    else {                                     # this is for testing
        if ( -d 'SOURCES' ) {
            require './SOURCES/util.pm';
            require './SOURCES/subids.pm';
        }
        else {
            require '/root/git/ea-podman/SOURCES/util.pm';
            require '/root/git/ea-podman/SOURCES/subids.pm';
        }
    }
}

use Cpanel::Config::Users ();
use Cpanel::JSON          ();
use Cpanel::AccessIds     ();

use Whostmgr::Accounts::Shell ();
use Cpanel::Shell             ();

use Term::ReadLine   ();
use App::CmdDispatch ();

use Try::Tiny;

run(@ARGV) unless caller;

sub run {
    my @args = @_;
    local $Term::ReadLine::termcap_nowarn = 1;

    my $user = getpwuid($>);

    # A restricted-shell (jailshell) account cannot run rootless podman from
    # inside the jail chroot. Rather than refuse, transparently route the
    # supported verbs through the ea_podman admin module's lifecycle actions:
    # cpsrvd runs them OUTSIDE the cage and drops to this cpuser, so it "just
    # works" the same as the CLI does for an unrestricted user. root and
    # unrestricted-shell users keep the direct path below (and thus the full
    # verb set). See CPANEL-54037 and EA4-315.
    if ( $> != 0 && !_has_unrestricted_shell($user) ) {
        return delegate_to_admin(@args);
    }

    if ( $ENV{'OPENSSL_NO_DEFAULT_ZLIB'} && $ENV{'OPENSSL_NO_DEFAULT_ZLIB'} == 1 ) {

        # This is a special case where they are trying to run ea-podman from
        # inside cPanel Terminal.
        #
        # We cannot allow it, they instead should ssh $USER@localhost and
        # perform the operations.

        print "You cannot run the /scripts/ea-podman script directly from the cPanel and WHM terminal.\n";
        print "  To use this script, you must first log in via ssh with the following command:\n";
        print "  ssh $user\@localhost\n\n";

        exit 1;
    }

    # We are on the direct CLI path: only root or an unrestricted-shell user
    # reaches here (restricted shells were routed to delegate_to_admin above).
    # Stay silent about the cgroup config for them; the UAPI/restricted path
    # never runs through here and keeps the CloudLinux + cgroup v2 advisory.
    $ea_podman::util::EMIT_CGROUP_ADVISORY = 0;

    # An account can also be unreachable directly for a reason the shell check
    # above can't see: CageFS. A CageFS-caged account can have an unrestricted
    # shell (so it isn't routed to delegate_to_admin above), but a real login
    # still runs inside the cage's own mount namespace, which does not expose
    # /run/user. The root-privileged bootstrap (ensure_user(), just above
    # ensure_su_login() in init_user()) still succeeds — it runs via the
    # ENSURE_USER adminbin, outside the cage — so the account ends up fully
    # bootstrapped on the host while this process still can't see the result.
    # ensure_su_login() (util.pm) surfaces that as a specific, distinctive die.
    # Rather than inventing cage-detection, catch that exact symptom and fall
    # back to the same admin actions jailshell already uses (cpsrvd also runs
    # outside the cage, so it can see what we just bootstrapped). See CPANEL-54672.
    if ( $> != 0 ) {
        my $ok = eval {
            App::CmdDispatch->new( get_dispatch_args() )->run(@args);
            1;
        };
        if ( !$ok ) {
            my $err = $@;
            if ( $err =~ /rootless runtime directory .* does not exist/ ) {
                warn "ea-podman: could not see this account's rootless runtime directory directly " . "(typical of a CageFS-enabled account) - retrying through the ea-podman admin actions...\n";
                return delegate_to_admin(@args);
            }
            die $err;
        }
        return;
    }

    return App::CmdDispatch->new( get_dispatch_args() )->run(@args);
}

sub _age_str {
    my ($secs) = @_;
    my $days = int( $secs / 86400 );
    return $days >= 1 ? "$days day" . ( $days == 1 ? "" : "s" ) : "less than a day";
}

sub _size_str {
    my ($bytes) = @_;
    return "size unknown" if !defined $bytes;
    return sprintf( "%.1f GiB", $bytes / ( 1024**3 ) ) if $bytes >= 1024**3;
    return sprintf( "%.1f MiB", $bytes / ( 1024**2 ) ) if $bytes >= 1024**2;
    return sprintf( "%.1f KiB", $bytes / 1024 )        if $bytes >= 1024;
    return "$bytes bytes";
}

sub _has_unrestricted_shell {
    my ($user) = @_;
    if ( defined &Whostmgr::Accounts::Shell::has_unrestricted_shell ) {
        return Whostmgr::Accounts::Shell::has_unrestricted_shell($user);
    }
    return Cpanel::Shell::has_unrestricted_shell($user);
}

######################################
#### restricted-shell admin bridge ###
######################################
#
# For a restricted-shell or caged account the CLI cannot drive podman directly,
# so it asks the ea_podman admin module to: each supported verb has a lifecycle
# action that runs as root outside the jail/cage, drops fully to this cpuser
# and runs the same verb body the EAPodman UAPI runs. One call, no credential
# to mint. See EA4-315 (previously a full-access API token and a localhost
# UAPI request, CPANEL-54037).

sub delegate_to_admin {
    my (@args) = @_;

    # Built locally (not file-scoped) so they are populated regardless of where
    # `run(@ARGV)` sits relative to a file-scope initializer.
    #
    # Verbs with a lifecycle admin action — the only ones that can be delegated.
    my %bridge_verb = map { $_ => 1 } qw(install upgrade list start stop restart uninstall status cmd);

    # CLI aliases (subset of the dispatcher's table) that resolve to a bridged verb.
    my %bridge_alias = (
        in      => 'install',
        up      => 'upgrade',
        li      => 'list',
        running => 'list',
        st      => 'start',
        sp      => 'stop',
        re      => 'restart',
        un      => 'uninstall',
        stat    => 'status',
    );

    my $verb = shift(@args) // '';
    $verb = $bridge_alias{$verb} if exists $bridge_alias{$verb};

    my $supported = join( ", ", sort keys %bridge_verb );

    # No verb (or `help`): show what a restricted account can do rather than
    # erroring, so the bare `ea-podman` invocation is still friendly.
    if ( $verb eq '' || $verb eq 'help' ) {
        print "Your account has a restricted shell (jailshell) or CageFS, so ea-podman routes\n" . "these commands through its privileged helper: $supported.\n" . "Usage: ea-podman <" . join( "|", sort keys %bridge_verb ) . "> [args]\n";
        return 1;
    }

    if ( !$bridge_verb{$verb} ) {
        die "The “$verb” command is not available for accounts with a restricted shell (jailshell) or CageFS.\n" . "Those accounts can use: $supported.\n" . "(These route through ea-podman's privileged helper, which works from inside the jail/cage; the remaining ea-podman subcommands require an unrestricted shell.)\n";
    }

    my $params = _cli_args_to_params( $verb, @args );
    my $data   = _admin_call( $verb, $params );

    _render_result( $verb, $data );
    return 1;
}

# Translate the CLI argv for a verb into the EAPodman UAPI's key/value params,
# which the lifecycle admin actions take too. Mirrors the reverse mapping in
# ea_podman::util::api_install (cpuser_port/env/risk-flag + image).
sub _cli_args_to_params {
    my ( $verb, @args ) = @_;

    return {} if $verb eq 'list';

    if ( $verb eq 'install' ) {
        my %p;
        my ( @ports, @envs, @positional );
        for ( my $i = 0; $i < @args; $i++ ) {
            my $a = $args[$i];
            if ( $a =~ /^--cpuser-port=(.+)$/ ) {
                push @ports, $1;
            }
            elsif ( $a =~ /^(?:-e|--env)=(.+)$/ ) {
                push @envs, $1;
            }
            elsif ( ( $a eq '-e' || $a eq '--env' ) && defined $args[ $i + 1 ] ) {
                push @envs, $args[ ++$i ];
            }
            elsif ( $a eq '--i-understand-the-risks-do-it-anyway' ) {
                $p{accept_arbitrary_image_risk} = 1;
            }
            else {
                push @positional, $a;
            }
        }
        die "install requires a package or container name\n" if !@positional;
        $p{name}        = shift @positional;
        $p{image}       = pop @positional if @positional;    # non-package form: trailing IMAGE
        $p{cpuser_port} = \@ports         if @ports;
        $p{env}         = \@envs          if @envs;
        return \%p;
    }

    if ( $verb eq 'cmd' ) {
        my ( $container_name, $cd, @cmd_argv ) = _parse_cmd_args(@args);
        my %p = ( container_name => $container_name, arg => \@cmd_argv );
        $p{cd} = $cd if length( $cd // '' );
        return \%p;
    }

    # upgrade / start / stop / restart / uninstall / status: a single
    # container_name positional (ignore the CLI's --verify; UAPI uninstall has
    # no interactive gate). upgrade's --force is the one flag that carries over.
    my $force            = $verb eq 'upgrade' && grep { defined && $_ eq '--force' } @args;
    my ($container_name) = grep { defined && length && $_ ne '--verify' && $_ ne '--force' } @args;
    die "$verb requires a container name\n" if !defined $container_name;
    return { container_name => $container_name, ( $force ? ( force => 1 ) : () ) };
}

# Shared by the direct-CLI `cmd` verb and its admin-action delegation: parses
# `<CONTAINER_NAME> [--cd DIR] -- <CMD> [ARGS...]`. The `--` is mandatory so
# ea-podman's own flags can never be confused with the exec'd command's own
# argv (which may legitimately contain "--cd" or "--" tokens of its own).
sub _parse_cmd_args {
    my (@args) = @_;

    my $container_name = shift @args;
    die "cmd requires a container name\n" if !length( $container_name // '' );

    my $cd;
    if ( @args && $args[0] eq '--cd' ) {
        shift @args;
        $cd = shift @args;
        die "--cd requires a directory\n" if !length( $cd // '' );
    }

    die "cmd requires a “--” before the command, e.g. cmd <CONTAINER_NAME> [--cd DIR] -- <CMD> [ARGS...]\n"
      if !@args || $args[0] ne '--';
    shift @args;

    die "cmd requires a command to run after “--”\n" if !@args;

    return ( $container_name, $cd, @args );
}

# The admin action behind each bridged verb.
sub _admin_action_for_verb {
    my ($verb) = @_;

    my %action = (
        install   => 'INSTALL',
        upgrade   => 'UPGRADE',
        list      => 'LIST_CONTAINERS',
        start     => 'START',
        stop      => 'STOP',
        restart   => 'RESTART',
        uninstall => 'UNINSTALL',
        status    => 'STATUS',
        cmd       => 'CMD',
    );

    return $action{$verb} // die "No ea-podman admin action for “$verb”\n";
}

sub _admin_call {
    my ( $verb, $params ) = @_;

    require Cpanel::AdminBin::Call;
    require Cpanel::Exception;

    my $data;
    local $@;
    my $ok = eval { $data = Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', _admin_action_for_verb($verb), $params ); 1 };
    if ( !$ok ) {
        my $msg = Cpanel::Exception::get_string_no_id($@);
        $msg = "EAPodman $verb failed" if !length( $msg // '' );
        chomp $msg;
        die "$msg\n";
    }

    return $data;
}

sub _render_result {
    my ( $verb, $data ) = @_;

    if ( $verb eq 'install' ) {
        my $name = ref($data) eq 'HASH' ? $data->{container_name} : undef;
        print "Done, installed: " . ( $name // '?' ) . "\n";
    }
    elsif ( $verb eq 'list' || $verb eq 'status' ) {
        print Cpanel::JSON::pretty_canonical_dump( $data || {} );
    }
    elsif ( $verb eq 'cmd' ) {
        my $exit_code = ref($data) eq 'HASH' ? $data->{exit_code} // 0 : 0;
        print STDOUT ref($data) eq 'HASH' ? $data->{stdout} // '' : '';
        print STDERR ref($data) eq 'HASH' ? $data->{stderr} // '' : '';
        exit($exit_code);
    }
    else {    # upgrade / start / stop / restart / uninstall
        print "Done: $verb\n";
    }
    return;
}

sub get_dispatch_args {
    my $hint_blurb = "This tool supports the following commands (i.e. $0 {command} …):";
    my %opts       = (
        'default_commands' => 'help',                                                                                                                                                                                                                                                       # shell is probably not useful here and potentially confusing
        'help:pre_hint'    => $hint_blurb,
        'help:pre_help'    => "Various EA4 user-container based service/app/etc management\n\n$hint_blurb",
        alias              => { stat => "status", in => "install", up => "upgrade", un => "uninstall", li => "list", re => "restart", st => "start", sp => "stop", sid => "subids", si => "subids", registered => "containers", running => "list", available => "avail", av => "avail" },
    );

    if ( $> == 0 ) {
        $opts{"help:post_help"} = "To manage containers for a user use `su - USER -c '$0 …'` or similar.";
        $opts{"help:post_hint"} = $opts{"help:post_help"};
    }

    my %cmds = (
        testbin => {
            clue     => "testbin",
            abstract => "Verify ea-podman runs",
            help     => "If it exits clean ea-podman is ok. It is no longer compiled, so there is nothing to rebuild; kept so existing callers keep working.",
            code     => sub {
                printf "$0 is running under perl v%vd\n", $^V;
            },
        },
        subids => {
            clue     => "subids [--ensure]",
            abstract => "Check and report on sub id config",
            help     => "Checks that use name spaces are enabled or not and if so what sub uids and sub gids are allocated\nOptional --ensure flag, makes sure the subids are setup for this user.",
            code     => sub {
                my ( $app, @other_args ) = @_;
                ea_podman::util::init_user();
                subids( $app, @other_args );
            },
        },

        install => {
            clue     => "install <PKG> [`run` flags]|install <NON-PKG-NAME> [--cpuser-port=<CONTAINER PORT|0> [--cpuser-port=<ANOTHER CONTAINER PORT|0> …]] [`run` flags] <IMAGE>",
            abstract => "Install a container",
            help     => "Has two modes:\n\t<PKG> - An EA4 container based package.\n\t\tNeeds no other arguments or setup as that is all provided by the package. It can take some additional start up arguments.\n\t<NON-PKG-NAME> - manage an arbitrary image as if it where an EA4 container based package.\n\t\tSee https://github.com/CpanelInc/ea-podman/blob/master/README.md for details",
            code     => sub {
                my ( $app, $name, @start_args ) = @_;

                # The one verb that legitimately needs a rootless session for an
                # account with no containers yet.
                ea_podman::util::init_user( creating => 1 );
                my $container_name = ea_podman::util::install_container( $name, @start_args );
                print "Done, installed: $container_name\n";
            },
        },
        upgrade => {
            clue     => "upgrade <CONTAINER_NAME> [--force]",
            abstract => "Upgrade a container",
            help     => qq{Upgrade the container named CONTAINER_NAME.

Pulls the image the container's configuration names, and recreates the container only if something actually moved — a newer image for the tag it tracks, or, for an EasyApache 4 package, a newer version of the package. When nothing has changed this does nothing at all: the container is not torn down, recreated, or restarted.

A container that is not running is recreated and LEFT not running, because a stop cannot be told from a crash and starting it would override a deliberate stop.

--force skips the comparison and recreates unconditionally, and starts the container afterwards. Use it to re-apply a configuration change that does not move the image, or to rebuild from the locally cached image when the registry cannot be reached.

If the pull fails, this reports the failure and leaves the container untouched rather than guessing; --force falls back to the cached image instead.},
            code     => sub {
                my ( $app, @args ) = @_;

                my ( $container_name, $force );
                for my $arg (@args) {
                    if    ( $arg eq '--force' ) { $force = 1 }
                    elsif ( !defined $container_name ) { $container_name = $arg }
                    else                        { die "Unknown argument “$arg”\n" }
                }

                die "Please provide the name of the container to upgrade.\n" if !defined $container_name;

                ea_podman::util::init_user();
                ea_podman::util::upgrade_container( $container_name, force => $force );
            },
        },
        uninstall => {
            clue     => "uninstall <CONTAINER_NAME>",
            abstract => "Uninstall a container",
            help     => "Uninstall the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name, $verify ) = @_;
                if ( !length($verify) || $verify ne "--verify" ) {
                    print "This operation can not be undone! Please pass `--verify` to verify you really want to do this.\n";
                    return;
                }

                ea_podman::util::init_user();
                ea_podman::util::remove_container_by_name($container_name);
            },
        },
        list => {
            clue     => "list",
            abstract => "Show container information",
            help     => "Dumps the information about user’s running containers in human readable JSON",
            code     => sub {
                my ($app) = @_;
                ea_podman::util::init_user();
                print Cpanel::JSON::pretty_canonical_dump( ea_podman::util::get_containers() );
            },
        },
        start => {
            clue     => "start <CONTAINER_NAME>",
            abstract => "Start a container",
            help     => "Start the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name ) = @_;
                ea_podman::util::validate_user_container_name($container_name);

                ea_podman::util::init_user();

                my $service_name = ea_podman::util::get_container_service_name($container_name);

                # else a container that used up its restarts cannot start for five minutes
                ea_podman::util::reset_container_unit_failure($container_name);
                ea_podman::util::sysctl( start => $service_name );
            }
        },
        stop => {
            clue     => "stop <CONTAINER_NAME>",
            abstract => "Stop a container",
            help     => "Stop the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name ) = @_;
                ea_podman::util::validate_user_container_name($container_name);

                ea_podman::util::init_user();

                my $service_name = ea_podman::util::get_container_service_name($container_name);
                ea_podman::util::sysctl( stop => $service_name );

                # a PID 1 that ignores SIGTERM is SIGKILLed and exits 137, recorded as a failure
                ea_podman::util::reset_container_unit_failure($container_name);
            }
        },
        restart => {
            clue     => "restart <CONTAINER_NAME>",
            abstract => "Restart a container",
            help     => "Restart the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name ) = @_;
                ea_podman::util::validate_user_container_name($container_name);

                ea_podman::util::init_user();

                my $service_name = ea_podman::util::get_container_service_name($container_name);

                ea_podman::util::reset_container_unit_failure($container_name);
                ea_podman::util::sysctl( restart => $service_name );
            }
        },
        status => {
            clue     => "status <CONTAINER_NAME>",
            abstract => "Get status of a container",
            help     => "Get status of the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name ) = @_;
                ea_podman::util::validate_user_container_name($container_name);

                ea_podman::util::init_user();

                my $service_name = ea_podman::util::get_container_service_name($container_name);
                ea_podman::util::sysctl( status => $service_name );
            }
        },
        bash => {
            clue     => "bash <CONTAINER_NAME> [CMD]",
            abstract => "get into a shell/run commands inside the container",
            help     => "If the container has bash: get an interactive shell inside the container, or run the (optional) CMD. Interactive access needs a TTY, so it is only for root and unrestricted-shell accounts. For a non-interactive command that also works for jailshell/CageFS accounts and on hidepid=2 hosts, use `cmd`.",
            code     => sub {
                my ( $app, $container_name, $cmd ) = @_;
                ea_podman::util::validate_user_container_name($container_name);

                ea_podman::util::init_user();

                if ($cmd) {
                    ea_podman::util::podman( exec => "-it", $container_name, "/bin/bash", "-c" => $cmd );
                }
                else {
                    ea_podman::util::podman( exec => "-it", $container_name, "/bin/bash" );
                }
            },
        },
        cmd => {
            clue     => "cmd <CONTAINER_NAME> [--cd DIR] -- <CMD> [ARGS...]",
            abstract => "run a one-shot, non-interactive command inside the container",
            help     =>
              "Runs CMD (with ARGS) directly inside the container (no shell, no TTY) and prints its stdout/stderr, exiting with its exit code. Does not assume the container has bash. Optional --cd DIR runs the command from that working directory. Works even where /proc is mounted hidepid=2, and is available to restricted-shell (jailshell) and CageFS accounts through ea-podman's privileged helper (and the EAPodman UAPI).",
            code => sub {
                my ( $app, @args ) = @_;
                my ( $container_name, $cd, @cmd_argv ) = _parse_cmd_args(@args);

                ea_podman::util::validate_user_container_name($container_name);
                ea_podman::util::init_user();

                my $state = ea_podman::util::exec_in_container( $container_name, \@cmd_argv, cd => $cd );

                print STDOUT $state->{stdout} // '';
                print STDERR $state->{stderr} // '';
                exit( $state->{exit_code} // 0 );
            },
        },
        containers => {
            clue     => "containers [--all]",
            abstract => "List containers",
            help     => "List your ea-podman registered containers. root can additionally pass --all to list everyone’s ea-podman registered containers.",
            code     => sub {
                my ( $app, $all ) = @_;

                die "Unknown argument “$all”\n" if defined $all && $all ne '--all';

                my $user = getpwuid($>);

                ea_podman::util::init_user();

                my $containers_hr = ea_podman::util::load_known_containers();

                my %user_containers;
                foreach my $container ( grep { $_->{user} eq $user } values %{$containers_hr} ) {
                    $user_containers{ $container->{container_name} } = $container;
                }

                if ( $> == 0 ) {
                    if ($all) {
                        print Cpanel::JSON::pretty_canonical_dump($containers_hr);
                    }
                    else {
                        print Cpanel::JSON::pretty_canonical_dump( \%user_containers );
                    }
                }
                else {
                    if ($all) {
                        die "Only root can specifically --all\n";
                    }
                    else {
                        print Cpanel::JSON::pretty_canonical_dump( \%user_containers );
                    }
                }
            },
        },
        remove_containers => {
            clue     => "remove_containers [<PKG|NON-PKG-NAME>|--all]",
            abstract => "Remove containers",
            help     => qq{Remove ea-podman registered containers by EA4 package, an arbitrary non-package name, or all via `--all`.
    - as non-root will only affect only the user
    - as root this will effect all users

This is intended to make it easier for a user to purge their ea-podman based containers and to facilitate cleanup when uninstalling packages that the containers need to run.
            },
            code => sub {
                my ( $app, $pkg ) = @_;

                die "Please provide a package name or the flag `--all`\n" if ( !$pkg );

                ea_podman::util::init_user();

                # TODO ZC-9746: have them verify they want to do this destructive thing

                my $user          = getpwuid($>);
                my $containers_hr = ea_podman::util::load_known_containers();

                my @containers = values %{$containers_hr};
                @containers = grep { $_->{user} eq $user } @containers if ( $user ne "root" );

                if ( $pkg ne '--all' ) {
                    @containers = grep {
                        ( defined $_->{pkg} && $_->{pkg} eq $pkg )                                              # <PKG> form …
                          ||                                                                                    # … OR …
                          ( !defined $_->{pkg} && $_->{container_name} =~ m/^\Q$pkg\E\.$user\.[0-9][0-9]$/ )    # … <NON-PKG-NAME> form
                    } @containers;
                }

                @containers = sort { $a->{user} cmp $b->{user} } @containers;

                if ( @containers == 0 ) {
                    print "There are no containers\n";
                    exit 0;
                }

                if ( $user eq "root" ) {
                    my %user_breakdown;

                    foreach my $container (@containers) {
                        my $c_user = $container->{user};
                        push( @{ $user_breakdown{$c_user} }, $container );
                    }

                    foreach my $c_user ( keys %user_breakdown ) {
                        if ( $c_user eq "root" ) {
                            ea_podman::util::remove_containers_for_a_user( @{ $user_breakdown{$c_user} } );
                        }
                        else {
                            try {
                                Cpanel::AccessIds::do_as_user_with_exception(
                                    $c_user,
                                    sub {
                                        my $homedir = ( getpwuid($>) )[7];
                                        local $ENV{HOME} = $homedir;
                                        local $ENV{USER} = $c_user;

                                        chdir($homedir);
                                        ea_podman::util::init_user();
                                        ea_podman::util::remove_containers_for_a_user( @{ $user_breakdown{$c_user} } );
                                    }
                                );
                            }
                            catch {
                                my $err = $_;

                                # Handles cases where users are not removed cleanly (with the use of a cPanel script/API), therefore it tries to manage containers as the deleted user
                                # which causes unistall of containerized packages to fail (see ZC-10958)
                                if ( $err->isa("Cpanel::Exception::UserNotFound") ) {
                                    ea_podman::util::remove_containers_for_a_deleted_user( @{ $user_breakdown{$c_user} } );

                                    return;
                                }

                                # Rethrow any other exception type
                                die $err;
                            };
                        }
                    }
                }
                else {
                    ea_podman::util::init_user();
                    ea_podman::util::remove_containers_for_a_user(@containers);
                }
            },
        },
        upgrade_containers => {
            clue     => "upgrade_containers [<PKG|NON-PKG-NAME>|--all] [--force]",
            abstract => "Upgrade containers",
            help     => qq{Upgrade ea-podman registered containers by EA4 package, an arbitrary non-package name, or all via `--all`.
    - as non-root will only affect only the user
    - as root this will effect all users

One account's or one container's failure no longer stops the sweep: the rest are still attempted, each failure is reported as it happens, and the command exits non-zero if anything failed.

Each container is only recreated if something actually moved; see `ea-podman help upgrade`. --force recreates every one of them unconditionally, which on a large server means restarting every application it touches.
            },
            code => sub {
                my ( $app, @args ) = @_;

                my ( $pkg, $force );
                for my $arg (@args) {
                    if    ( $arg eq '--force' )  { $force = 1 }
                    elsif ( !defined $pkg )      { $pkg   = $arg }
                    else                         { die "Unknown argument “$arg”\n" }
                }

                die "Please provide a package name or the flag `--all`\n" if ( !$pkg );

                # Before the registry read, as remove_containers does. Without it
                # the root branch below reaches upgrade_containers_for_a_user()
                # having never run check_proc()/ensure_user()/ensure_su_login().
                ea_podman::util::init_user();

                my $user          = getpwuid($>);
                my $containers_hr = ea_podman::util::load_known_containers();

                my @containers = values %{$containers_hr};
                @containers = grep { $_->{user} eq $user } @containers if ( $user ne "root" );

                if ( $pkg ne '--all' ) {
                    @containers = grep {
                        ( defined $_->{pkg} && $_->{pkg} eq $pkg )                                              # <PKG> form …
                          ||                                                                                    # … OR …
                          ( !defined $_->{pkg} && $_->{container_name} =~ m/^\Q$pkg\E\.$user\.[0-9][0-9]$/ )    # … <NON-PKG-NAME> form
                    } @containers;
                }

                @containers = sort { $a->{user} cmp $b->{user} } @containers;

                if ( @containers == 0 ) {
                    print "There are no containers\n";
                    exit 0;
                }

                my @failed;

                if ( $user eq "root" ) {
                    my %user_breakdown;

                    foreach my $container (@containers) {
                        my $c_user = $container->{user};
                        push( @{ $user_breakdown{$c_user} }, $container );
                    }

                    # `sort` matters. @containers is sorted above, but building
                    # %user_breakdown throws that order away and bare `keys` is
                    # randomised per process — so which accounts a mid-sweep
                    # failure skipped used to vary run to run, making the failure
                    # list unreproducible. (EA4-325)
                    foreach my $c_user ( sort keys %user_breakdown ) {
                        my @c_containers = @{ $user_breakdown{$c_user} };

                        try {
                            if ( $c_user eq "root" ) {
                                ea_podman::util::upgrade_containers_for_a_user( $force, @c_containers );
                            }
                            else {
                                Cpanel::AccessIds::do_as_user_with_exception(
                                    $c_user,
                                    sub {
                                        my $homedir = ( getpwuid($>) )[7];
                                        local $ENV{HOME} = $homedir;
                                        local $ENV{USER} = $c_user;

                                        chdir($homedir);

                                        ea_podman::util::init_user();
                                        ea_podman::util::upgrade_containers_for_a_user( $force, @c_containers );
                                    }
                                );
                            }
                        }
                        catch {
                            my $err = $_;

                            # ref() first: unlike remove_containers, what arrives
                            # here can be a plain string — the aggregate die from
                            # upgrade_containers_for_a_user() — and ->isa on a
                            # string is a trap waiting to be sprung.
                            if ( ref($err) && eval { $err->isa("Cpanel::Exception::UserNotFound") } ) {

                                # No deleted-user fallback of the kind
                                # remove_containers has (ZC-10958): there is
                                # nothing to upgrade for an account that is gone,
                                # and an upgrade sweep must never deregister
                                # anything — that is remove's job, and doing it
                                # here would make `upgrade` silently destructive.
                                # Skipped, but counted: a registry entry for a
                                # vanished account is a real problem and must not
                                # exit 0.
                                warn "ea-podman: skipping “$c_user”: the account no longer exists, so its registered containers ("
                                  . join( ", ", map { $_->{container_name} } @c_containers )
                                  . ") cannot be upgraded.\n"
                                  . "They are still registered. Clean them up as root with `ea-podman remove_containers --all`, which handles containers whose account was deleted uncleanly.\n";
                            }
                            else {
                                warn "ea-podman: upgrading containers for “$c_user” failed: $err";
                            }

                            push @failed, $c_user;
                        };
                    }
                }
                else {
                    try { ea_podman::util::upgrade_containers_for_a_user( $force, @containers ) }
                    catch { warn "ea-podman: $_"; push @failed, $user };
                }

                # Survive a bad account or a bad container, but never silently.
                # Accumulating without this exit would re-create the defect the
                # rest of EA4-325 exists to kill. Shape follows
                # ensure_user_sessions below.
                if (@failed) {
                    warn "ea-podman: upgrade_containers did not complete for: " . join( ", ", sort @failed ) . "\n";
                    exit 1;
                }

                return 1;
            },
        },
        clean => {
            clue     => "clean [--run] [--days=N]",
            abstract => "List (or remove) leftover <CONTAINER_NAME>.bak directories",
            help     => qq{List the `<CONTAINER_NAME>.bak` directories left behind under ~/ea-podman.d/ when a container is uninstalled or removed.

Lists only, with each one's age and size, unless you pass `--run`. `--run` removes them.

    - as non-root this covers only your own account
    - as root it covers every account with a `.bak` under ~/ea-podman.d/, whether or not the container registry still lists it

A `.bak` is only removed when its container name is otherwise COMPLETELY gone: no registry entry, nothing in `podman ps -a`, no port still assigned to it, and no systemd unit. Anything still holding the name is reported and left alone -- freeing the name early would hand it to the next install with stale state attached.

Age is measured from when the directory BECAME a `.bak`, not from when its contents were last written, so a backup made moments ago is never mistaken for an old one. Default is 30 days; `--days=N` uses a different threshold, and `--days=0` considers every one of them.

WHAT A `.bak` HOLDS. It is made when an application is deleted, and it contains that container's read-write /app directory -- runtime state such as SQLite files, uploads and generated content, its `.env`, and for a zip-sourced application the entire source. Nothing reads a `.bak`, but nothing else keeps a copy either. Read the listing before you pass `--run`.},
            code     => sub {
                my ( $app, @args ) = @_;

                my $run  = 0;
                my $days = undef;
                for my $arg (@args) {
                    if    ( $arg eq '--run' )              { $run  = 1 }
                    elsif ( $arg =~ m/^--days=([0-9]+)$/ ) { $days = $1 }
                    else                                   { die "Unknown argument “$arg”\n" }
                }

                my %age = defined $days ? ( max_age => $days * 24 * 60 * 60 ) : ();

                my $user = getpwuid($>);

                # Warned in the DEFAULT listing, not only under --run (EA4-325
                # C8). `--run` is the only safeguard, so the warning has to be in
                # front of the operator while they are still deciding.
                print "Note: a “.bak” can hold the only copy of an application's runtime state, its .env, and a zip-sourced application's entire source.\n";
                print "Considering backups older than " . ( defined $days ? "$days day" . ( $days == 1 ? "" : "s" ) : "30 days" ) . ".\n";
                print $run ? "Removing.\n\n" : "Listing only. Pass `--run` to remove.\n\n";

                my @reports;
                if ( $user eq "root" ) {

                    # init_user() allocates a subuid/subgid range, so a
                    # look-only listing must not run it for an account -- root
                    # included -- that has no `.bak` to report. See
                    # user_may_have_backups_as_root().
                    if ( ea_podman::util::user_may_have_backups_as_root("root") ) {
                        ea_podman::util::init_user();
                        push @reports, ea_podman::util::clean_backups( run => $run, %age );
                    }

                    # Every cPanel account, NOT the ones the container registry
                    # knows about.
                    #
                    # A `.bak` exists precisely BECAUSE a container was removed,
                    # and removing one deregisters it. So an account that removed
                    # all of its containers has no registry entries at all -- and
                    # `remove_containers --all` is exactly how a pile of backups
                    # appears. Driving this from the registry would skip the
                    # accounts most likely to have something to clean, and skip
                    # them silently.
                    #
                    # ensure_user_sessions() does use the registry list, and is
                    # right to: only an account WITH containers needs a systemd
                    # manager. This wants the opposite set. Same shape as the
                    # `check` verb below. Sorted so a failure list is
                    # reproducible.
                    #
                    # Every account is CONSIDERED, but only the ones that may
                    # have a `.bak` are visited, checked as root before
                    # privileges are dropped. Visiting means init_user(), and
                    # doing that to every account allocated subids for accounts
                    # that never used ea-podman, on a plain listing. Skipping
                    # them also spares a fork per account on a large server.
                    for my $c_user ( sort( Cpanel::Config::Users::getcpusers() ) ) {
                        next if !ea_podman::util::user_may_have_backups_as_root($c_user);

                        try {
                            # RETURNED, not pushed. do_as_user_with_exception runs
                            # the closure in a forked child (Cpanel::ForkSync), so
                            # anything pushed to a lexical in there dies with the
                            # child and root reports nothing for the account it
                            # just swept. ForkSync serialises the return value
                            # back, so that is the way across.
                            my $report = Cpanel::AccessIds::do_as_user_with_exception(
                                $c_user,
                                sub {
                                    my $homedir = ( getpwuid($>) )[7];
                                    local $ENV{HOME} = $homedir;
                                    local $ENV{USER} = $c_user;

                                    chdir($homedir);
                                    ea_podman::util::init_user();
                                    return ea_podman::util::clean_backups( run => $run, %age );
                                }
                            );

                            # clean_backups() returns a hash on every path, so this
                            # is the serialisation back across the fork failing
                            # quietly. Say so, rather than dropping the account
                            # from the listing as if it had had nothing to clean.
                            if ( ref $report eq 'HASH' ) {
                                push @reports, $report;
                            }
                            else {
                                warn "ea-podman: no report came back for “$c_user”\n";
                                push @reports, { user => $c_user, unreachable => 1, removable => [], skipped => [] };
                            }
                        }
                        catch {
                            my $err = $_;
                            warn "ea-podman: could not clean up for “$c_user”: $err";
                            push @reports, { user => $c_user, unreachable => 1, removable => [], skipped => [] };
                        };
                    }
                }
                else {
                    ea_podman::util::init_user();
                    push @reports, ea_podman::util::clean_backups( run => $run, %age );
                }

                my $total         = 0;
                my $bytes         = 0;
                my $bytes_unknown = 0;
                for my $r (@reports) {
                    if ( $r->{unreachable} ) {
                        print "$r->{user}: UNKNOWN — the account could not be reached, so nothing was examined.\n";
                        next;
                    }
                    if ( $r->{unreadable} ) {
                        print "$r->{user}: UNKNOWN — “$r->{unreadable}” could not be read, so nothing was examined.\n";
                        next;
                    }
                    if ( $r->{podman_unverifiable} ) {
                        print "$r->{user}: note — this account's rootless session is not up, so podman could not be asked. A container that exists only in podman's storage, with no registry entry, no ports and no unit, would not be seen here; that is an orphan for `ea-podman orphan` to reconcile.\n";
                    }

                    for my $b ( @{ $r->{removable} } ) {
                        printf( "%s: %s  (%s old, %s)%s\n", $r->{user}, $b->{path}, _age_str( $b->{age} ), _size_str( $b->{size} ), $run ? " — REMOVED" : "" );
                        $total++;
                        if   ( defined $b->{size} ) { $bytes += $b->{size} }
                        else                        { $bytes_unknown++ }
                    }
                    for my $sk ( @{ $r->{skipped} } ) {
                        next if $sk->{reason} eq 'too_recent' || $sk->{reason} eq 'not_a_container_backup';
                        if ( $sk->{reason} eq 'remove_failed' ) {
                            print "$r->{user}: $sk->{path} — could not be removed; see the warning above.\n";
                        }
                        elsif ( $sk->{reason} eq 'unreadable' ) {
                            print "$r->{user}: $sk->{path} — could not be examined, so it was left alone.\n";
                        }
                        else {
                            print "$r->{user}: $sk->{path} — kept, the name is still in use ($sk->{reason}); that is an orphan-reconciliation matter, not a cleanup one.\n";
                        }
                    }
                }

                if ( !$total ) {
                    print "Nothing to clean up.\n";
                }
                else {
                    my $size = $bytes_unknown ? "at least " . _size_str($bytes) . " ($bytes_unknown of unknown size)" : _size_str($bytes);
                    printf( "\n%d backup director%s%s, %s.\n", $total, ( $total == 1 ? "y" : "ies" ), ( $run ? " removed" : " could be removed" ), $size );
                }

                return 1;
            },
        },
        backup => {
            clue     => "backup",
            abstract => "Backup containers",
            help     => qq{Backup all ea-podman registered containers for a user. Cannot be run as root.

Writes ~/ea-podman-backups/backup-<YYYYMMDDHHMMSS>.tar.gz, holding each container's directory plus a manifest of its registry entry. That tarball is the path to hand to `ea-podman restore` — list them newest first with `ls -t ~/ea-podman-backups/`.

Only the newest 3 are kept; older ones are removed on each run. pkgacct takes a backup too, so an automatic run can age out one you meant to keep — copy it elsewhere if it matters.

The ~/ea_podman_backup_<USER>.json manifest is written, tarred, and then removed, so it does not survive the run and is not what `restore` wants.
            },
            code => sub {
                my ($app) = @_;

                die "Backup is not allowed for the root user at this time.\n" if ( $> == 0 );
                ea_podman::util::perform_user_backup();
            },
        },
        restore => {
            clue     => "restore <BACKUP_TARBALL> [--verify]",
            abstract => "Restore containers that have been backed up.",
            help     => qq{Will restore containers that have been backed up. Cannot be run as root.

BACKUP_TARBALL is a tarball written by `ea-podman backup`, e.g. ~/ea-podman-backups/backup-20260803120000.tar.gz — not the ea_podman_backup_<USER>.json manifest, which only ever exists inside that tarball.

NOTE:

    * Will remove existing containers
    * Will destroy the ea-podman.d directory
    * This is a destructive operation, you are required to pass ”--verify”
    * Restored containers get a NEW set of ports, so anything pointing at the old ones needs updating
            },
            code => sub {
                my ( $app, $backup_file, $verify ) = @_;

                die "Restore is not allowed for the root user at this time.\n" if ( $> == 0 );

                die "Please pass in the path to the backup file you want to restore.\n" if ( !$backup_file );
                die "Backup file cannot be read\n"                                      if ( !-r $backup_file );

                if ( !length($verify) || $verify ne "--verify" ) {
                    print "This operation can not be undone! Please pass `--verify` to verify you really want to do this.\n";
                    return;
                }

                ea_podman::util::perform_user_restore($backup_file);
            },
        },
        avail => {
            clue     => "avail",
            abstract => "list available EA4 container based packages",
            help     => "lists available EA4 container based packages and, for each one, shows if its installed locally or not and has a URL to its documentation",
            code     => sub {
                my ($app) = @_;

                my $e4m = Cpanel::JSON::LoadFile("/etc/cpanel/ea4/ea4-metainfo.json");
                if ( !exists $e4m->{container_based_packages} ) {
                    die "Container based packages list not found (need to upgrade ea-cpanel-tools?)\n";
                }

                my %avail;
                for my $pkg ( @{ $e4m->{container_based_packages} } ) {
                    $avail{$pkg}{installed_locally} = -e "/opt/cpanel/$pkg/pkg-version" ? 1 : 0;
                    $avail{$pkg}{url}               = "https://github.com/CpanelInc/$pkg/blob/master/SOURCES/README.md";
                }

                print Cpanel::JSON::pretty_canonical_dump( \%avail );

                return 1;
            },
        },
        ensure_user_sessions => {
            clue     => "ensure_user_sessions [--quiet]",
            abstract => "Bring up the per-user systemd managers every account with containers needs",
            help     =>
              "root only. For each account the container registry says has containers, makes sure it lingers and that its user systemd manager is running — lifting a masked `user\@.service` for as long as that takes, exactly as any other ea-podman command does.\n\nRun at boot by ea-podman-user-managers.service. Nothing else starts these managers at boot on a host where `user\@.service` is masked (CageFS 7.6.39+ / CloudLinux CLOS-4517), so without it an account's containers stay down until its next ea-podman command. Safe and near-free to run by hand at any time: an account whose manager is already up is skipped without opening a window.\n\nReports what it did per account and exits non-zero if any account's manager could not be started.\n\n--quiet prints only failures, for unattended runs.",
            code => sub {
                my ( $app, @other_args ) = @_;

                die "ensure_user_sessions can only be run by root\n" if $> != 0;

                my $quiet = 0;
                for my $arg (@other_args) {
                    if ( $arg eq "--quiet" ) { $quiet = 1 }
                    else                     { die "Unknown argument “$arg”\n" }
                }

                my @users = ea_podman::util::users_with_containers_as_root();

                if ( !@users ) {
                    print "No accounts have ea-podman containers, so there are no user systemd managers to start.\n" if !$quiet;
                    return 1;
                }

                my $result = ea_podman::subids::ensure_user_sessions(@users);

                # The per-account warnings have already gone to STDERR from
                # ensure_user_sessions(); this is the summary.
                my @failed = sort grep { $result->{$_} eq "failed" } keys %{$result};

                if ( !$quiet ) {
                    for my $user ( sort keys %{$result} ) {
                        print "$user: $result->{$user}\n";
                    }
                }

                if (@failed) {
                    warn "ea-podman: could not start the user systemd manager for: " . join( ", ", @failed ) . "\n";
                    exit 1;
                }

                return 1;
            },
        },
        rootbackupofuser => {
            clue     => "rootbackupofuser - internal use only",
            abstract => "internal use only",
            help     => "internal use only",
            code     => sub {
                my ( $app, $user ) = @_;

                die "rootbackupofuser can only be run by root\n" if $> != 0;

                # The same guard as the PkgAcct hook that calls us, since this
                # is a reachable entry point in its own right: do not stand up a
                # rootless session (subids + linger) for an account that has no
                # containers to back up. (CPANEL-55309)
                return 1 if !ea_podman::util::user_has_containers_as_root($user);

                require Cpanel::AccessIds;

                Cpanel::AccessIds::do_as_user_with_exception(
                    $user,
                    sub {
                        my $homedir = ( getpwuid($<) )[7];
                        local $ENV{HOME} = $homedir;
                        local $ENV{USER} = $user;

                        chdir($homedir);

                        ea_podman::util::init_user();
                        ea_podman::util::perform_user_backup();
                    }
                );

                return 1;
            },
        },
    );

    return ( \%cmds, \%opts );
}

####################
#### sub commands ##
####################

sub subids {
    my ( $app, @other ) = @_;

    ea_podman::subids::assert_has_user_namespaces(1);

    if ( @other == 1 && $other[0] eq "--ensure" ) {
        ea_podman::util::ensure_user();    # do not need init_user because we don’t care aboue the su login stuff here
    }
    else {
        die "Too many arguments"                    if @other > 1;
        die "--ensure is the only allowed argument" if @other && $other[0] ne "--ensure";
    }

    my $subuid_lu = ea_podman::subids::get_subuids();
    my $subgid_lu = ea_podman::subids::get_subgids();

    # Having a range and having one nobody else has are different things, and
    # only the second is isolation. Worked out once for the whole file.
    my $subuid_problems = ea_podman::subids::get_subuid_problems();
    my $subgid_problems = ea_podman::subids::get_subgid_problems();

    if ( $> == 0 ) {
        for my $user ( "root", Cpanel::Config::Users::getcpusers() ) {
            _check_output_user( $user, $subuid_lu, $subgid_lu, $subuid_problems, $subgid_problems );
        }
    }
    else {
        my $user = getpwuid($>);
        _check_output_user( $user, $subuid_lu, $subgid_lu, $subuid_problems, $subgid_problems );
    }
}

sub _check_output_user {
    my ( $user, $subuid_lu, $subgid_lu, $subuid_problems, $subgid_problems ) = @_;

    _output_user_range( $user, "subuids", $subuid_lu, $subuid_problems );
    _output_user_range( $user, "subgids", $subgid_lu, $subgid_problems );
}

sub _output_user_range {
    my ( $user, $label, $lu, $problems ) = @_;

    if ( !exists $lu->{$user} ) {
        print "$ea_podman::subids::bad “$user” does not have $label\n";
        return;
    }

    # ea-podman refuses to run this account’s containers while its range is not
    # exclusively its own, so that does not get a checkmark here either.
    if ( my $problem = $problems->{$user} ) {
        print "$ea_podman::subids::bad “$user” has $label ($lu->{$user}) but $problem\n";
        return;
    }

    print "$ea_podman::subids::good “$user” has $label ($lu->{$user})\n";
}

1;
