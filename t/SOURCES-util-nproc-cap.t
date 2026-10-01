#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-nproc-cap.t              Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# query (the systemctl args, joined) => its answer; anything absent answers "".
my %answer;
my @asked;
no warnings 'redefine';
local *ea_podman::util::_systemctl_value = sub {
    my $q = join( " ", @_ );
    push @asked, $q;
    return $answer{$q} // "";
};
use warnings 'redefine';

my $uid     = $>;
my $SYS_ONE = "show user\@$uid.service -p LimitNPROC --value";
my $SYS_DEF = "show -p DefaultLimitNPROC --value";
my $USR_DEF = "--user show -p DefaultLimitNPROC --value";

sub cap_for {
    %answer = @_;
    @asked  = ();
    return ea_podman::util::_user_manager_nproc_cap();
}

is( cap_for( $SYS_ONE => "14536", $SYS_DEF => "999", $USR_DEF => "888" ), 14536, "the system manager's LimitNPROC for user\@UID wins" );
is_deeply( \@asked, [$SYS_ONE], "... and nothing else is asked" );

is( cap_for( $SYS_ONE => "infinity", $SYS_DEF => "4242" ), 4242, "the system default when user\@UID's limit is not a number" );

# CloudLinux: the system bus refuses an unprivileged uid, so both system
# queries come back empty and only the user manager can answer.
is( cap_for( $USR_DEF => "14536" ), 14536, "the user manager's own default when the system bus refuses" );
is_deeply( \@asked, [ $SYS_ONE, $SYS_DEF, $USR_DEF ], "... asked in that order" );

is( cap_for( $USR_DEF => "infinity" ), undef, "unlimited everywhere: nothing to pin" );
is( cap_for(),                         undef, "no answer anywhere: nothing to pin" );

done_testing();
