package PodmanHooks;

# cpanel - /var/cpanel/perl5/lib/PodmanHooks.pm    Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Cpanel::AdminBin::Call ();
use Cpanel::Debug          ();
use Cpanel::AccessIds      ();

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
    }
    else {                                     # this is for testing
        if ( -d 'SOURCES' ) {
            require './SOURCES/util.pm';
        }
        else {
            require '/root/git/ea-podman/SOURCES/util.pm';
        }
    }
}

sub describe {
    my $hooks = [
        {
            'category' => 'System',
            'event'    => 'upcp',
            'stage'    => 'post',
            'hook'     => 'PodmanHooks::_compile_podman',
            'exectype' => 'module',
        },
        {
            'category' => 'Whostmgr',
            'event'    => 'Accounts::Modify',
            'stage'    => 'pre',
            'hook'     => 'PodmanHooks::_pre_username_change',
            'exectype' => 'module',
        },
        {
            'category' => 'Whostmgr',
            'event'    => 'Accounts::Remove',
            'stage'    => 'pre',
            'hook'     => 'PodmanHooks::_delete_user',
            'exectype' => 'module',
        },
        {
            'category' => 'PkgAcct',
            'event'    => 'Create',
            'stage'    => 'pre',
            'hook'     => 'PodmanHooks::_do_backup',
            'exectype' => 'module',
        },
    ];

    return $hooks;
}

sub _compile_podman {
    my ( $hook, $event ) = @_;

    if ( -x '/opt/cpanel/ea-podman/bin/compile.sh' ) {
        system('/opt/cpanel/ea-podman/bin/compile.sh');
    }

    return;
}

sub _pre_username_change {
    my ( $hook, $event ) = @_;

    # no work if the username is not changed
    return ( 1, "Success" ) if ( $event->{newuser} && $event->{newuser} eq $event->{user} );

    my $user = $event->{user};

    my $containers_hr   = ea_podman::util::load_known_containers();
    my $user_containers = {};
    foreach my $container ( grep { $_->{user} eq $user } values %{$containers_hr} ) {
        $user_containers->{ $container->{container_name} } = $container;
    }

    # no problem if the user does not have containers
    return 1, "Success" if ( keys %{$user_containers} == 0 );

    return 0, qq{

You cannot change the name of this user.
This user's account uses podman containers and these will not function if the name is changed.
For more information, read our documentation: https://go.cpanel.net/containers

};
}

sub _delete_user {
    my ( $hook, $event ) = @_;

    my $user = $event->{user};

    my $containers_hr = ea_podman::util::load_known_containers();

    my $user_containers = {};
    foreach my $container ( grep { $_->{user} eq $user } values %{$containers_hr} ) {
        $user_containers->{ $container->{container_name} } = $container;
    }

    return 1, "Success" if ( keys %{$user_containers} == 0 );

    # now remove the containers

    Cpanel::AccessIds::do_as_user_with_exception(
        $user,
        sub {
            my $homedir = ( getpwuid($>) )[7];
            local $ENV{HOME} = $homedir;
            local $ENV{USER} = $user;

            chdir($homedir);

            ea_podman::util::init_user();
            ea_podman::util::remove_containers_for_a_user( values %{$user_containers} );
        }
    );

    return 1, "Success";
}

sub _do_backup {
    my ( $hook, $event ) = @_;

    my $user = $event->{user};
    if ( $user ne "root" ) {
        Cpanel::AccessIds::do_as_user_with_exception(
            $user,
            sub {
                my $homedir = ( getpwuid($>) )[7];
                local $ENV{HOME} = $homedir;
                local $ENV{USER} = $user;

                chdir($homedir);

                ea_podman::util::init_user();
                ea_podman::util::perform_user_backup();
            }
        );
    }
    else {
        ea_podman::util::init_user();
        ea_podman::util::perform_user_backup();
    }

    return 1, "Success";
}

1;

__END__

=head1 NAME

NginxHooks

=head1 SYNOPSIS

PodmanHooks::_compile_podman();

=head1 DESCRIPTION

PodmanHooks responds to events in the cPanel system and recompiles
the ea-podman executable when upcp finishes running.

PodmanHooks.pm is deployed by the RPM to /var/cpanel/perl5/lib/.

cPanel recognizes that directory as a valid location for hooks modules.

During the installation of the RPM bin/manage_hooks is called to notify
cPanel of this hooks module.

=head1 SUBROUTINES

=head2 _compile_podnam

Recompiles the ea-podman executable (perlcc).

=cut

