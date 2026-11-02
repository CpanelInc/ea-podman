#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-ensure-user-error.t       Copyright 2026 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

use Cpanel::Exception ();

# A user's ensure_user() gets the ENSURE_USER admin action's refusal (no user
# namespaces, a subid conflict) as the raw exception Cpanel::AdminBin::Call
# rebuilds from it. The user is shown its message,
# not its stack trace. (EA4-360)

plan skip_all => "needs root to run as a user" if $> != 0;

sub _ensure_user_as_user {
    my ($call) = @_;
    no warnings qw(redefine once);
    local *Cpanel::AdminBin::Call::call = $call;
    use warnings qw(redefine once);

    local $> = 65534;
    my $rv;
    my $ok = eval { $rv = ea_podman::util::ensure_user(); 1 };
    return ( $ok ? "" : $@, $rv );
}

subtest 'a refusal is reduced to its message' => sub {
    my ($err) = _ensure_user_as_user( sub { die Cpanel::Exception::create_raw( 'Cpanel::Exception', "❌ ea-podman requires user namespaces\n" ) } );
    is( $err, "❌ ea-podman requires user namespaces\n", "just the message, newline-terminated" );
    unlike( $err, qr/ at \S+ line \d+/, "no stack trace" );
};

subtest 'an empty error still says something' => sub {
    my ($err) = _ensure_user_as_user( sub { die Cpanel::Exception::create_raw( 'Cpanel::Exception', '' ) } );
    like( $err, qr/\AUnable to set up this account for ea-podman\n\z/ );
};

subtest 'success still reports whether there is a session' => sub {
    my ( $err, $rv ) = _ensure_user_as_user( sub { return 1 } );
    is( $err, "", "does not die" );
    is( $rv,  1,  "has a session" );
    ( $err, $rv ) = _ensure_user_as_user( sub { return 0 } );
    is( $rv, 0, "no session" );
};

done_testing();
