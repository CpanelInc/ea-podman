#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-webapp-proxy-repair.t   Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

require "$FindBin::Bin/../SOURCES/util.pm";

# A restore asks the admin module to re-point the proxies its new ports
# orphaned. These cover what that call can come back with.

my $tmp       = File::Temp->newdir();
my $installed = "$tmp/Repair.pm";
open( my $fh, '>', $installed ) or die "Could not write $installed: $!";
close $fh;

our @calls;
our $answer;
our $failure;
{
    no warnings qw(redefine once);
    *Cpanel::AdminBin::Call::call = sub {
        push @calls, [@_];
        die $failure if defined $failure;
        return $answer;
    };
}

sub repair_proxies {
    my @warnings;
    my $repaired;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $repaired = ea_podman::util::_repair_webapp_proxies();
    }
    return ( $repaired, \@warnings );
}

subtest 'no plugin installed: a silent no-op that asks nothing' => sub {
    local $ea_podman::util::webapp_repair_module = "$tmp/not-installed.pm";
    local @calls                                 = ();

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, [], "nothing repaired" );
    is_deeply( $warnings, [], "nothing said" );
    is_deeply( \@calls,   [], "and the admin module is not called" );
};

subtest 'plugin present: the records the admin module repaired come back' => sub {
    local $ea_podman::util::webapp_repair_module = $installed;
    local @calls                                 = ();
    local $answer                                = [ { name => "blog", container => "blog.bob.01", domain => "blog.tld", was => 10001, now => 10005 } ];

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, $answer,                                                "the records are returned as-is" );
    is_deeply( \@calls,   [ [ 'Cpanel', 'ea_podman', 'REPAIR_WEBAPP_PROXIES' ] ], "through one ea_podman admin call" );
    is_deeply( $warnings, [],                                                     "and nothing said" );
};

subtest 'nothing to repair, or an unexpected answer: nothing comes back' => sub {
    local $ea_podman::util::webapp_repair_module = $installed;

    for my $reply ( [], undef, {} ) {
        local $answer = $reply;
        my ( $repaired, $warnings ) = repair_proxies();
        is_deeply( $repaired, [], "an empty list" );
        is_deeply( $warnings, [], "and nothing said" );
    }
};

subtest 'the admin call fails: reported, and the restore carries on' => sub {
    local $ea_podman::util::webapp_repair_module = $installed;
    local $failure                               = "The repair failed. The server’s error log has the reason.\n";

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, [], "nothing comes back" );
    is( scalar @{$warnings}, 1, "one warning" );
    like( $warnings->[0], qr/^Could not repair the web application proxy wiring: The repair failed\. /, "which passes the reason on" );
};

subtest 'the CLI never reaches the webapp adminbin itself' => sub {

    # It refuses an uncompiled caller, which the CLI is. Only the admin module may.
    for my $file (qw(util.pm ea-podman.pl)) {
        open( my $fh, '<', "$FindBin::Bin/../SOURCES/$file" ) or die "Could not open $file: $!";
        my $src = do { local $/; <$fh> };
        close $fh;

        unlike( $src, qr/AdminBin::Call::call\(\s*'Cpanel',\s*'webapp'/, "$file makes no webapp adminbin call" );
        unlike( $src, qr/repair_current_user/,                           "$file does not use the plugin's adminbin-backed repair" );
    }
};

subtest 'the port-change warning is silenced for what was repaired, kept for what was not' => sub {
    my %drifted = (
        "blog.bob.01"  => { orig => [ 10001, 10002 ], curr => [ 10005, 10006 ] },
        "redis.bob.01" => { orig => [10003],          curr => [10007] },
    );
    my $repaired = [ { name => "blog", container => "blog.bob.01", domain => "blog.tld", was => 10001, now => 10005 } ];

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        ea_podman::util::_warn_of_changed_ports( \%drifted, $repaired );
    }

    is( scalar @warnings, 1, "one container is warned about" );
    like( $warnings[0], qr/The TCP ports for redis\.bob\.01 have changed/,   "the one nothing repaired — its ports really did move under it" );
    like( $warnings[0], qr/originally assigned to the container are: 10003/, "with the old ports" );
    like( $warnings[0], qr/currently assigned to the container are: 10007/,  "and the new ones" );
    unlike( join( '', @warnings ), qr/blog\.bob\.01/, "the repaired application is not called broken right after being fixed" );
};

subtest 'nothing repaired at all still warns about every drifted container' => sub {
    my %drifted = ( "blog.bob.01" => { orig => [10001], curr => [10005] } );

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        ea_podman::util::_warn_of_changed_ports( \%drifted, [] );
        ea_podman::util::_warn_of_changed_ports( \%drifted, undef );
    }

    is( scalar @warnings, 2, "an empty or missing repair list silences nothing" );
};

subtest 'the repair is called once per restore, not once per container' => sub {

    # Structural because the cost is invisible from the return value: a call
    # inside the container loop would mean an Apache reload per application.
    open( my $fh, '<', "$FindBin::Bin/../SOURCES/util.pm" ) or die "Could not open util.pm: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($body) = $src =~ /^sub _warn_if_ports_changed \{(.*?)^\}/ms;
    ok( $body, "found _warn_if_ports_changed()" );
    like( $body, qr/^    my \$repaired = _repair_webapp_proxies\(\);$/m, "the call sits at the sub's own indent, outside the per-container loop" );
};

done_testing();
