package Install::EAPodman;

#                                      Copyright 2025 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use base qw( Cpanel::Task );

use strict;
use warnings;

our $VERSION = '1.0';

=head1 DESCRIPTION

    Recompile ea-podman binary if needed.

=over 1

=item Type: Sanity

=item Frequency: always

=item EOL: never

=back

=cut

exit __PACKAGE__->runtask() unless caller;

sub new {
    my $proto = shift;
    my $self  = $proto->SUPER::new;

    $self->set_internal_name('ea-podman');

    return $self;
}

sub perform {
    my $self = shift;

    my $compiler     = '/opt/cpanel/ea-podman/bin/compile.sh';
    my $bin_test_cmd = '/opt/cpanel/ea-podman/bin/ea-podman testbin';

    if ( -x $compiler ) {
        `$bin_test_cmd 2>&1`;
        if ( $? != 0 ) {
            system($compiler);

            `$bin_test_cmd 2>&1`;
            if ( $? != 0 ) {
                warn "“$compiler” did not compile a working binary ($bin_test_cmd)\n";
                return 0;
            }
        }

        print "ea-podman binary is ok\n";

    }
    else {
        print "N/A (no $compiler)\n";    # how did we get here if the package installing $compiler installs this .pm …
    }

    return 1;
}

1;
