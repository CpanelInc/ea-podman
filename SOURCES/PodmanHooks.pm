package PodmanHooks;

# cpanel - /var/cpanel/perl5/lib/PodmanHooks.pm    Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Cpanel::AdminBin::Call ();
use Cpanel::Debug          ();

sub describe {
        {
            'category' => 'System',
            'event'    => 'upcp',
            'stage'    => 'post',
            'hook'     => 'PodmanHooks::_compile_podman',
            'exectype' => 'module',
        }

}

sub _compile_podman {
    my ( $hook, $event ) = @_;

    if (-x '/opt/cpanel/ea-podman/bin/compile.sh') {
        system( '/opt/cpanel/ea-podman/bin/compile.sh' );
    }
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

