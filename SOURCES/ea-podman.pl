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

use Term::ReadLine   ();
use App::CmdDispatch ();

run(@ARGV) unless caller;

sub run {
    my @args = @_;
    local $Term::ReadLine::termcap_nowarn = 1;
    return App::CmdDispatch->new( get_dispatch_args() )->run(@args);
}

sub get_dispatch_args {
    my $hint_blurb = "This tool supports the following commands (i.e. $0 {command} …):";
    my %opts       = (
        'default_commands' => 'help',                                                                                                                                                                                               # shell is probably not useful here and potentially confusing
        'help:pre_hint'    => $hint_blurb,
        'help:pre_help'    => "Various EA4 user-container based service/app/etc management\n\n$hint_blurb",
        alias              => { stat => "status", in => "install", up => "upgrade", un => "uninstall", li => "list", re => "restart", st => "start", sp => "stop", sid => "subids", si => "subids", registered => "containers" },
    );

    if ( $> == 0 ) {
        $opts{"help:post_help"} = "To manage containers for a user use `su - USER -c '$0 …'` or similar.";
        $opts{"help:post_hint"} = $opts{"help:post_help"};
    }

    my %cmds = (
        subids => {
            clue     => "subids",
            abstract => "Check and report on sub id config",
            help     => "Checks that use name spaces are enabled or not and if so what sub uids and sub gids are allocated",
            code     => \&subids,
        },

        install => {
            clue     => "install <PKG> [`run` flags]|install <NON-PKG-NAME> [--cpuser-port=<CONTAINER PORT|0> [--cpuser-port=<ANOTHER CONTAINER PORT|0> …]] [`run` flags] <IMAGE>",
            abstract => "Install a container",
            help     => "Has two modes:\n\t<PKG> - An EA4 container based package.\n\t\tNeeds no other arguments or setup as that is all provided by the package. It can take some additional start up arguments.\n\t<NON-PKG-NAME> - manage an arbitrary image as if it where an EA4 container based package.\n\t\tSee https://github.com/CpanelInc/ea-podman/blob/master/README.md for details",
            code     => sub {
                my ( $app, $name, @start_args ) = @_;
                ea_podman::util::install_container( $name, @start_args );
            },
        },
        upgrade => {
            clue     => "upgrade <CONTAINER_NAME>",
            abstract => "Upgrade a container",
            help     => "Upgrade the container named CONTAINER_NAME",
            code     => sub {
                my ( $app, $container_name ) = @_;
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

                ea_podman::util::remove_container_by_name($container_name);
            },
        },
        list => {
            clue     => "list",
            abstract => "Show container information",
            help     => "Dumps the information about user’s running containers in human readable JSON",
            code     => sub {
                my ($app) = @_;
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
                my $service_name = ea_podman::util::get_container_service_name($container_name);

                ea_podman::util::sysctl( status => $service_name );
            }
        },
        bash => {
            clue     => "bash <CONTAINER_NAME> [CMD]",
            abstract => "get into a shell/run commands inside the container",
            help     => "If the container has bash: get a shell inside the container or run the (optional) CMD",
            code     => sub {
                my ( $app, $container_name, $cmd ) = @_;
                ea_podman::util::validate_user_container_name($container_name);
                if ($cmd) {
                    ea_podman::util::podman( exec => "-it", $container_name, "/bin/bash", "-c" => $cmd );
                }
                else {
                    ea_podman::util::podman( exec => "-it", $container_name, "/bin/bash" );
                }
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
                            Cpanel::AccessIds::do_as_user_with_exception(
                                $c_user,
                                sub {
                                    my $homedir = ( getpwuid($>) )[7];
                                    local $ENV{HOME} = $homedir;
                                    local $ENV{USER} = $c_user;

                                    chdir($homedir);

                                    ea_podman::util::ensure_su_login();
                                    ea_podman::util::remove_containers_for_a_user( @{ $user_breakdown{$c_user} } );
                                }
                            );
                        }
                    }
                }
                else {
                    ea_podman::util::remove_containers_for_a_user(@containers);
                }
            },
        },
    );

    return ( \%cmds, \%opts );
}

####################
#### sub commands ##
####################

sub subids {
    my ($app) = @_;

    ea_podman::subids::assert_has_user_namespaces(1);

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
