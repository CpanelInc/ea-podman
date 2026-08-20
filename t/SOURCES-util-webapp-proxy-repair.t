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

# perform_user_restore() asks the webapp plugin to re-point the proxies its new
# ports orphaned. These cover the four states that call can be in.

my $tmp = File::Temp->newdir();
my $seq = 0;

# Each stand-in gets its own path so %INC never short-circuits the require, and
# the subtests run absent-old-present because a defined sub answers can() forever.
sub install_plugin {
    my ($body) = @_;

    my $path = "$tmp/Repair-" . ++$seq . ".pm";
    open( my $fh, '>', $path ) or die "Could not write $path: $!";
    print {$fh} "package Cpanel::WebApps::Repair;\n$body\n1;\n";
    close $fh;

    return $path;
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

subtest 'no plugin installed: a silent no-op' => sub {
    local $ea_podman::util::webapp_repair_module = "$tmp/not-installed.pm";

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, [], "nothing repaired" );
    is_deeply( $warnings, [], "and nothing said — a server without the plugin restores exactly as it did before" );
};

subtest 'plugin too old for the entry point: also a silent no-op' => sub {
    local $ea_podman::util::webapp_repair_module = install_plugin("sub repair_user { die 'root only' }");

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, [], "nothing repaired" );
    is_deeply( $warnings, [], "and nothing said — its own sweep will get to the wiring" );
};

subtest 'plugin present: the records it repaired come back' => sub {
    local $ea_podman::util::webapp_repair_module = install_plugin(
        <<'FAKE'
our $calls = 0;
sub calls { return $calls }
sub repair_current_user {
    $calls++;
    return [ { name => "blog", container => "blog.bob.01", domain => "blog.tld", was => 10001, now => 10005 } ];
}
FAKE
    );

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply(
        $repaired,
        [ { name => "blog", container => "blog.bob.01", domain => "blog.tld", was => 10001, now => 10005 } ],
        "the plugin's repair records are returned as-is"
    );
    is( Cpanel::WebApps::Repair::calls(), 1, "the repair ran once" );
    is_deeply( $warnings, [], "and said nothing" );
};

subtest 'the repair dies: reported, and the restore carries on' => sub {
    local $ea_podman::util::webapp_repair_module = install_plugin("sub repair_current_user { die \"adminbin said no\\n\" }");

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, [], "nothing comes back" );
    is( scalar @{$warnings}, 1, "one warning" );
    like( $warnings->[0], qr/Could not repair the web application proxy wiring: adminbin said no/, "which names the failure" );
};

subtest 'the plugin module will not load: reported, and the restore carries on' => sub {
    local $ea_podman::util::webapp_repair_module = install_plugin("this is not perl(");

    my ( $repaired, $warnings ) = repair_proxies();

    is_deeply( $repaired, [], "nothing comes back" );
    like( join( '', @{$warnings} ), qr/Could not load .+ to repair the web application proxy wiring/, "the load failure is named" );
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
