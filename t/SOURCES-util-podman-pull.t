#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-podman-pull.t            Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-325 B5: an `upgrade_containers --all` sweep across many containers sharing
# one image must pull that image once, not once per container.
#
# This lives in its own file on purpose. t/SOURCES-util-upgrade-gate.t replaces
# _podman_pull with a NON-local glob assignment in its harness, so from the first
# subtest onward the real sub is gone for that whole file -- a memoization test
# there would be asserting against the stub. The first version of this test did
# exactly that: it replaced _podman_pull with its own reimplementation and then
# checked that the reimplementation memoized. Deleting %_pulled from util.pm
# would have left it green.
#
# So: mock the SHELL-OUT (_podman_pull_once), never _podman_pull, and let the
# real cache be the thing under test.

no warnings 'once';

subtest 'each distinct image reaches podman exactly once per run' => sub {
    my @pulled;
    no warnings 'redefine';
    local %ea_podman::util::_pulled           = ();
    local *ea_podman::util::_podman_pull_once = sub { push @pulled, $_[0]; return 1 };

    ea_podman::util::_podman_pull("img-a") for 1 .. 3;
    ea_podman::util::_podman_pull("img-b");
    ea_podman::util::_podman_pull("img-a");

    # Five calls, two shell-outs. This is the assertion that would break if the
    # cache were removed from util.pm -- @pulled would be five entries long.
    is_deeply( \@pulled, [ "img-a", "img-b" ], "two distinct images, two shell-outs" );
};

subtest 'a failed pull is remembered too' => sub {
    my @pulled;
    no warnings 'redefine';
    local %ea_podman::util::_pulled           = ();
    local *ea_podman::util::_podman_pull_once = sub { push @pulled, $_[0]; return 0 };

    # A registry that is down stays down for the run. Retrying it once per
    # container would turn a sweep into a long series of timeouts.
    is( ea_podman::util::_podman_pull("img-c"), 0, "the failure is reported" );
    is( ea_podman::util::_podman_pull("img-c"), 0, "and still is on the second ask" );
    is_deeply( \@pulled, ["img-c"], "without shelling out again" );
};

subtest 'the cache is keyed by image reference' => sub {
    my @pulled;
    no warnings 'redefine';
    local %ea_podman::util::_pulled           = ();
    local *ea_podman::util::_podman_pull_once = sub { push @pulled, $_[0]; return $_[0] eq "good" ? 1 : 0 };

    is( ea_podman::util::_podman_pull("good"), 1, "one reference succeeds" );
    is( ea_podman::util::_podman_pull("bad"),  0, "another fails" );
    is( ea_podman::util::_podman_pull("good"), 1, "and neither answer bleeds into the other" );
    is_deeply( \@pulled, [ "good", "bad" ], "each was asked once" );
};

done_testing();
