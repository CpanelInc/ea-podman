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
    # supported verbs through the EAPodman UAPI: cpsrvd executes that request as
    # this cpuser OUTSIDE the cage, so it "just works" the same as the CLI does
    # for an unrestricted user. root and unrestricted-shell users keep the
    # direct path below (and thus the full verb set). See CPANEL-54037.
    if ( $> != 0 && !_has_unrestricted_shell($user) ) {
        return delegate_to_uapi(@args);
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
    # reaches here (restricted shells were routed to delegate_to_uapi above).
    # Stay silent about the cgroup config for them; the UAPI/restricted path
    # never runs through here and keeps the CloudLinux + cgroup v2 advisory.
    $ea_podman::util::EMIT_CGROUP_ADVISORY = 0;

    return App::CmdDispatch->new( get_dispatch_args() )->run(@args);
}

sub _has_unrestricted_shell {
    my ($user) = @_;
    if ( defined &Whostmgr::Accounts::Shell::has_unrestricted_shell ) {
        return Whostmgr::Accounts::Shell::has_unrestricted_shell($user);
    }
    return Cpanel::Shell::has_unrestricted_shell($user);
}

#####################################
#### restricted-shell UAPI bridge ###
#####################################
#
# For a restricted-shell account the CLI cannot drive podman directly, so it
# delegates to the EAPodman UAPI over localhost HTTPS. Auth: a cpuser shell has
# no ambient cpsrvd credential, so the (root) ea-podman adminbin mints a
# short-lived API token for the caller; the CLI makes one authenticated request
# (`Authorization: cpanel user:token`) to /execute/EAPodman/<verb> and then has
# the adminbin revoke the token. See CPANEL-54037 and docs/uapi.md.

sub delegate_to_uapi {
    my (@args) = @_;

    # Built locally (not file-scoped) so they are populated regardless of where
    # `run(@ARGV)` sits relative to a file-scope initializer.
    #
    # Verbs the EAPodman UAPI implements — the only ones that can be delegated.
    my %uapi_verb = map { $_ => 1 } qw(install upgrade list start stop restart uninstall status cmd);

    # CLI aliases (subset of the dispatcher's table) that resolve to a UAPI verb.
    my %uapi_alias = (
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
    $verb = $uapi_alias{$verb} if exists $uapi_alias{$verb};

    my $supported = join( ", ", sort keys %uapi_verb );

    # No verb (or `help`): show what a restricted account can do rather than
    # erroring, so the bare `ea-podman` invocation is still friendly.
    if ( $verb eq '' || $verb eq 'help' ) {
        print "Your account has a restricted shell (jailshell) or CageFS, so ea-podman routes\n" . "these commands through the EAPodman UAPI: $supported.\n" . "Usage: ea-podman <" . join( "|", sort keys %uapi_verb ) . "> [args]\n";
        return 1;
    }

    if ( !$uapi_verb{$verb} ) {
        die "The “$verb” command is not available for accounts with a restricted shell (jailshell) or CageFS.\n" . "Those accounts can use: $supported.\n" . "(These route through the EAPodman UAPI, which works from inside the jail/cage; the remaining ea-podman subcommands require an unrestricted shell.)\n";
    }

    my $params = _cli_args_to_uapi( $verb, @args );
    my $result = _uapi_call( $verb, $params );

    my $status = ref($result) eq 'HASH' ? $result->{status} : undef;
    if ( !$status ) {
        my $errors = ref($result) eq 'HASH'                    ? $result->{errors}        : undef;
        my $msg    = ( ref($errors) eq 'ARRAY' && @{$errors} ) ? join( "\n", @{$errors} ) : "EAPodman $verb failed";
        die "$msg\n";
    }

    _render_uapi_result( $verb, ref($result) eq 'HASH' ? $result->{data} : undef );
    return 1;
}

# Translate the CLI argv for a verb into UAPI key/value params. Mirrors the
# reverse mapping in Cpanel::API::EAPodman (cpuser_port/env/risk-flag + image).
sub _cli_args_to_uapi {
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
    # no interactive gate).
    my ($container_name) = grep { defined && length && $_ ne '--verify' } @args;
    die "$verb requires a container name\n" if !defined $container_name;
    return { container_name => $container_name };
}

# Shared by the direct-CLI `cmd` verb and its UAPI delegation: parses
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

sub _uapi_call {
    my ( $verb, $params ) = @_;

    require Cpanel::AdminBin::Call;

    # A shell login has no ambient cpsrvd credential, so the (root) adminbin
    # mints a short-lived full-access API token for us; we authenticate the one
    # UAPI request with it (`Authorization: cpanel user:token`) and revoke it
    # immediately after, success or not. See CPANEL-54037.
    my $cred = Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'MINT_API_TOKEN' );
    die "Could not obtain an API token to reach the EAPodman UAPI\n"
      if ref($cred) ne 'HASH' || !$cred->{token};

    my $user = scalar getpwuid($>);

    require HTTP::Tiny;
    my $http = HTTP::Tiny->new( verify_SSL => 0, timeout => 120 );    # localhost cert; installs can pull an image

    my $path = "/execute/EAPodman/$verb";
    my $qs   = _uapi_query_string($params);
    my $resp = $http->get(
        "https://127.0.0.1:2083$path" . ( length $qs ? "?$qs" : "" ),
        { headers => { 'Authorization' => "cpanel $user:$cred->{token}" } },
    );

    eval { Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'REVOKE_API_TOKEN', $cred->{name} ); 1 };

    if ( !$resp->{success} ) {
        die "EAPodman UAPI request failed: $resp->{status} $resp->{reason} ($path)\n" . _http_snippet($resp);
    }

    my $decoded = eval { Cpanel::JSON::Load( $resp->{content} ) };
    if ( !$decoded ) {
        die "Could not parse the EAPodman UAPI response (status $resp->{status}, " . "content-type " . ( $resp->{headers}{'content-type'} // '?' ) . "):\n" . _http_snippet($resp);
    }
    return $decoded->{result} // $decoded;
}

# A short, single-line excerpt of a response body, for legible error messages.
sub _http_snippet {
    my ($resp) = @_;
    my $body = $resp->{content} // '';
    $body =~ s/\s+/ /g;
    $body =~ s/^\s+//;
    return length($body) > 300 ? substr( $body, 0, 300 ) . " …\n" : "$body\n";
}

sub _uapi_query_string {
    my ($params) = @_;
    require Cpanel::Encoder::URI;

    # A repeatable arg is just the same name given more than once
    # (key=a&key=b&key=c). Cpanel::Form stores the duplicates and
    # $args->get_multiple() recovers them in order, so there is no need to
    # number them key-1, key-2, … ourselves.
    my @pairs;
    for my $key ( sort keys %{$params} ) {
        my $val = $params->{$key};
        for my $v ( ref($val) eq 'ARRAY' ? @{$val} : $val ) {
            push @pairs, Cpanel::Encoder::URI::uri_encode_str($key) . '=' . Cpanel::Encoder::URI::uri_encode_str($v);
        }
    }
    return join( '&', @pairs );
}

sub _render_uapi_result {
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
            abstract => "Verify binary is stable",
            help     => "If it exits clean the binary is ok. If it exits unclean it should be recompiled with `/opt/cpanel/ea-podman/bin/compile.sh`",
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
                ea_podman::util::init_user();
                my $container_name = ea_podman::util::install_container( $name, @start_args );
                print "Done, installed: $container_name\n";
            },
        },
        upgrade => {
            clue     => "upgrade <CONTAINER_NAME>",
            abstract => "Upgrade a container",
            help     => "Upgrade the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name ) = @_;

                ea_podman::util::init_user();
                ea_podman::util::upgrade_container($container_name);
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
            help     => "Runs CMD (with ARGS) directly inside the container (no shell, no TTY) and prints its stdout/stderr, exiting with its exit code. Does not assume the container has bash. Optional --cd DIR runs the command from that working directory. Works even where /proc is mounted hidepid=2, and is available to restricted-shell (jailshell) and CageFS accounts through the EAPodman UAPI.",
            code     => sub {
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
            clue     => "upgrade_containers [<PKG|NON-PKG-NAME>|--all]",
            abstract => "Upgrade containers",
            help     => qq{Upgrade ea-podman registered containers by EA4 package, an arbitrary non-package name, or all via `--all`.
    - as non-root will only affect only the user
    - as root this will effect all users
            },
            code => sub {
                my ( $app, $pkg ) = @_;

                die "Please provide a package name or the flag `--all`\n" if ( !$pkg );

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
                            ea_podman::util::upgrade_containers_for_a_user( @{ $user_breakdown{$c_user} } );
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
                                    ea_podman::util::upgrade_containers_for_a_user( @{ $user_breakdown{$c_user} } );
                                }
                            );
                        }
                    }
                }
                else {
                    ea_podman::util::init_user();
                    ea_podman::util::upgrade_containers_for_a_user(@containers);
                }
            },
        },
        backup => {
            clue     => "backup",
            abstract => "Backup containers",
            help     => qq{Backup all ea-podman registered containers for a user.

                  Outputs a file ea_podman_backup_<USER>.json
            },
            code => sub {
                my ($app) = @_;

                die "Backup is not allowed for the root user at this time.\n" if ( $> == 0 );
                ea_podman::util::perform_user_backup();
            },
        },
        restore => {
            clue     => "restore <BACKUP_FILE_PATH> [--verify]",
            abstract => "Restore containers that have been backed up.",
            help     => qq{Will restore containers that bave been backed up.

                  NOTE:

                  * Will remove existing containers
                  * Will destroy the ea-podman.d directory
                  * This is a destructive operation, you are required to pass ”--verify”
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
        rootbackupofuser => {
            clue     => "rootbackupofuser - internal use only",
            abstract => "internal use only",
            help     => "internal use only",
            code     => sub {
                my ( $app, $user ) = @_;

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

    if ( $> == 0 ) {
        for my $user ( "root", Cpanel::Config::Users::getcpusers() ) {
            _check_output_user( $user, $subuid_lu, $subgid_lu );
        }
    }
    else {
        my $user = getpwuid($>);
        _check_output_user( $user, $subuid_lu, $subgid_lu );
    }
}

sub _check_output_user {
    my ( $user, $subuid_lu, $subgid_lu ) = @_;

    print( exists $subuid_lu->{$user} ? "$ea_podman::subids::good “$user” has subuids ($subuid_lu->{$user})\n" : "$ea_podman::subids::bad “$user” does not have subuids\n" );
    print( exists $subgid_lu->{$user} ? "$ea_podman::subids::good “$user” has subgids ($subgid_lu->{$user})\n" : "$ea_podman::subids::bad “$user” does not have subgids\n" );
}

1;
