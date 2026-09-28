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

# A rate limit is a different problem from an unreachable registry, and the
# remedies are nothing alike -- one is "wait or reduce the cadence", the other is
# "fix the network or the image name". Since Increment B every upgrade pulls, so
# this became much easier to hit and much more confusing to diagnose: the forced
# paths keep working from cache while the conditional ones abort.
subtest 'a rate limit is told apart from any other pull failure' => sub {
    no warnings 'redefine';
    local %ea_podman::util::_pulled     = ();
    local %ea_podman::util::_pull_error = ();

    # What podman actually prints, from a live box that hit the limit.
    local *ea_podman::util::_podman_pull_once = sub {
        $ea_podman::util::_pull_error{ $_[0] } =
          'Error: unable to copy from source docker://httpd:2.4: initializing source docker://httpd:2.4: '
          . 'reading manifest 2.4 in docker.io/library/httpd: toomanyrequests: You have reached your '
          . 'unauthenticated pull rate limit. https://www.docker.com/increase-rate-limit';
        return 0;
    };

    is( ea_podman::util::_podman_pull("img-rl"), 0, "the pull fails" );
    is( ea_podman::util::_pull_failure_reason("img-rl"), "rate_limit", "and is recognised as a rate limit" );
};

subtest 'anything else is not guessed at' => sub {
    no warnings 'redefine';
    local %ea_podman::util::_pulled     = ();
    local %ea_podman::util::_pull_error = ();
    local *ea_podman::util::_podman_pull_once = sub {
        $ea_podman::util::_pull_error{ $_[0] } = 'Error: reading manifest nope in docker.io/library/nope: requested access to the resource is denied';
        return 0;
    };

    is( ea_podman::util::_podman_pull("img-404"), 0, "the pull fails" );
    is( ea_podman::util::_pull_failure_reason("img-404"), "unknown", "and is not mislabelled a rate limit" );

    # A reference never attempted has nothing to say about it.
    is( ea_podman::util::_pull_failure_reason("img-never"), "unknown", "nor is one that was never tried" );
};

done_testing();
