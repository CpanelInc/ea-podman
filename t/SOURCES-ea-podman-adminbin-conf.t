#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-ea-podman-adminbin-conf.t     Copyright 2026 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

# The adminbin server enforces a caller (parent) allowlist before crossing the
# privilege boundary. The web-application toolkit deploy worker runs ea_podman
# calls from process_user_tasks (queued as the cpuser by queueprocd), so both
# must be present or deploys fail as build_failed (EA4-288 / CPANEL-54138).

my $conf = "$FindBin::Bin/../SOURCES/ea-podman-adminbin.conf";

open( my $fh, '<', $conf ) or die "Could not open $conf: $!";
my ($allowed_parents) = grep { /^allowed_parents=/ } <$fh>;
close $fh;

ok( defined $allowed_parents, "ea-podman-adminbin.conf has an allowed_parents line" );

chomp $allowed_parents;
$allowed_parents =~ s/^allowed_parents=//;
my %parents = map { $_ => 1 } split( /,/, $allowed_parents );

for my $required (
    '/usr/local/cpanel/bin/process_user_tasks',
    '/usr/local/cpanel/libexec/queueprocd',
) {
    ok( $parents{$required}, "allowed_parents includes $required" );
}

done_testing();
