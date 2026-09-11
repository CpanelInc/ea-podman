#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-start-verdict.t          Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-325: `ea-podman upgrade` exited 0 while leaving the application down —
# measured on a live box as a persistent HTTP 503 with exit code 0, because the
# return of sysctl( start => ... ) was never looked at.
#
# A single check is not a verdict. The generated unit carries StartLimitBurst=3
# and RestartSec=5, so a failing container spends the retry window in
# `activating`/`auto-restart`, and — the part that makes this subtle — is
# genuinely `active` for the moment it runs on each attempt. Measured trace of a
# crash loop:
#
#   t=0.00s  activating/auto-restart  Result=exit-code
#   t=3.25s  activating/auto-restart  Result=exit-code  NRestarts=1
#   t=6.25s  active/running           Result=success    NRestarts=2   <-- here
#   t=6.50s  activating/auto-restart  Result=exit-code
#   t=9.50s  failed/failed            Result=exit-code  NRestarts=3

no warnings 'once';

# Drive the poll from a scripted list of states, and never actually sleep.
sub _with_states {
    my ( $states, $code ) = @_;

    my @queue = @{$states};
    my $slept = 0;

    local *ea_podman::util::_systemctl_show = sub {
        my $next = @queue ? shift(@queue) : $states->[-1];    # last state persists
        return $next;
    };
    local $ea_podman::util::unit_poll_sleeper = sub { $slept++ };

    return $code->( \$slept );
}

sub _st { return { ActiveState => $_[0], Result => $_[1] // "success" } }

subtest 'the settle ceiling is derived from %container_unit_directives' => sub {
    is( ea_podman::util::_container_unit_directive("RestartSec"),      "5", "RestartSec is read out of the Service section" );
    is( ea_podman::util::_container_unit_directive("StartLimitBurst"), "3", "StartLimitBurst is read out of the Unit section" );

    # 5 x 3 + 10s slack. Measured on a live box: a crash-looping unit reached
    # `failed` 15.8s after a clean start, so 15s + slack is the right shape.
    is( ea_podman::util::container_unit_settle_ceiling_sec(), 25, "ceiling is RestartSec x StartLimitBurst + slack" );
};

# The test that proves the ceiling is derived and not a constant in disguise.
subtest 'the ceiling follows a retuned unit rather than a hardcoded number' => sub {
    local %ea_podman::util::container_unit_directives = (
        Unit    => ["StartLimitBurst=5"],
        Service => ["RestartSec=2"],
    );
    local $ea_podman::util::unit_settle_slack_sec = 10;

    is( ea_podman::util::container_unit_settle_ceiling_sec(), 20, "2 x 5 + 10" );
};

subtest 'timespans are parsed in the forms systemd writes' => sub {
    is( ea_podman::util::_systemd_timespan_to_sec("5"),     5,   "bare number is seconds" );
    is( ea_podman::util::_systemd_timespan_to_sec("5s"),    5,   "s" );
    is( ea_podman::util::_systemd_timespan_to_sec("500ms"), 0.5, "ms" );
    is( ea_podman::util::_systemd_timespan_to_sec("1min"),  60,  "min" );
    is( ea_podman::util::_systemd_timespan_to_sec("later"), undef, "junk is undef, so the caller can fall back" );
    is( ea_podman::util::_systemd_timespan_to_sec(undef),   undef, "undef in, undef out" );
};

subtest 'a malformed directive falls back instead of breaking the upgrade' => sub {
    local %ea_podman::util::container_unit_directives = (
        Unit    => ["StartLimitBurst=lots"],
        Service => ["RestartSec=whenever"],
    );
    local $ea_podman::util::unit_settle_slack_sec = 10;

    is( ea_podman::util::container_unit_settle_ceiling_sec(), 25, "falls back to the 5 x 3 defaults" );
};

subtest 'an active unit that stays active is a success' => sub {
    _with_states(
        [ _st("active") ],
        sub {
            is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "active", "verdict is active" );
        }
    );
};

# The regression test for the whole design. Without the confirmation window the
# sample at t=6.25s reports a crash loop as a success.
subtest 'a crash loop that flickers active is not mistaken for a success' => sub {
    _with_states(
        [
            _st( "activating", "exit-code" ),
            _st( "activating", "exit-code" ),
            _st( "active",     "success" ),      # the t=6.25s blip
            _st( "activating", "exit-code" ),
            _st( "failed",     "exit-code" ),
        ],
        sub {
            is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "failed", "the flicker does not confirm; the verdict is failed" );
        }
    );
};

subtest 'a unit that is still activating then settles active succeeds' => sub {
    _with_states(
        [ _st( "activating", "exit-code" ), _st("active"), _st("active"), _st("active") ],
        sub {
            is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "active", "confirmed after the wait" );
        }
    );
};

subtest 'failed is terminal and stops the poll immediately' => sub {
    _with_states(
        [ _st( "failed", "exit-code" ) ],
        sub {
            my ($slept) = @_;
            is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "failed", "verdict is failed" );
            is( ${$slept}, 0, "and it did not wait out the ceiling to say so" );
        }
    );
};

# `inactive` covers three different things; Result is what separates them.
subtest 'inactive is split by Result' => sub {
    _with_states( [ _st( "inactive", "exit-code" ) ], sub { is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "crashed", "inactive + exit-code is a crash" ) } );
    _with_states( [ _st( "inactive", "success" ) ],   sub { is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "stopped", "inactive + success is a clean stop" ) } );
};

subtest 'a systemctl that cannot answer is unknown, not a state' => sub {
    _with_states( [ {} ], sub { is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "unknown", "an empty show is unknown" ) } );
};

subtest 'a unit still activating at the ceiling times out' => sub {
    _with_states(
        [ _st( "activating", "exit-code" ) ],
        sub {
            my ($slept) = @_;
            is( ea_podman::util::wait_for_container_unit_verdict("app.bob.01"), "timeout", "verdict is timeout" );
            cmp_ok( ${$slept}, '>', 50, "and it really did poll for the ceiling" );
        }
    );
};

subtest 'verify_container_started raises with a message an operator can act on' => sub {
    local *ea_podman::util::wait_for_container_unit_verdict = sub { return "failed" };

    my $err = do { local $@; eval { ea_podman::util::verify_container_started("app.bob.01") }; $@ };

    like( $err, qr/did not come back up/,                        "says the upgrade did not come back up" );
    like( $err, qr/not a half-applied upgrade/,                  "says the upgrade itself completed" );
    like( $err, qr/systemctl --user status container-app\.bob\.01\.service/, "names systemctl status" );
    like( $err, qr/journalctl --user -u/,                        "names journalctl" );
    like( $err, qr/podman logs app\.bob\.01/,                    "names podman logs" );
    like( $err, qr/ea-podman upgrade app\.bob\.01/,              "names the retry" );
};

subtest 'an unreachable session is named as such' => sub {
    for my $verdict (qw(unknown stopped)) {
        local *ea_podman::util::wait_for_container_unit_verdict = sub { return $verdict };
        my $err = do { local $@; eval { ea_podman::util::verify_container_started("app.bob.01") }; $@ };
        like( $err, qr/ensure_user_sessions/, "$verdict points at ensure_user_sessions" );
    }
};

# The EAPodman UAPI's start/restart reuse this poll, and "was upgraded" would be
# nonsense there.
subtest 'a non-upgrade caller can say what it was actually doing' => sub {
    local *ea_podman::util::wait_for_container_unit_verdict = sub { return "failed" };

    my $err = do {
        local $@;
        eval { ea_podman::util::verify_container_started( "app.bob.01", lead => "“app.bob.01” did not start", note => "" ) };
        $@;
    };

    like( $err, qr/^“app\.bob\.01” did not start:/, "the caller's own lead is used" );
    unlike( $err, qr/was upgraded/,                    "and the upgrade wording is gone" );
    unlike( $err, qr/half-applied/,                    "as is the upgrade-specific note" );
    like( $err, qr/journalctl --user -u/,              "but the diagnostics still follow" );
};

subtest 'verify_container_started is quiet on success' => sub {
    local *ea_podman::util::wait_for_container_unit_verdict = sub { return "active" };
    is( ea_podman::util::verify_container_started("app.bob.01"), 1, "returns true and does not die" );
};

# The whole point: upgrade_container must not report success it has not earned.
subtest 'upgrade_container verifies the container actually came back up' => sub {
    my @verified;
    local *ea_podman::util::_ensure_latest_container = sub { return { recreated => 1, started => 1 } };
    local *ea_podman::util::verify_container_started = sub { push @verified, $_[0]; return 1 };

    is( ea_podman::util::upgrade_container("app.bob.01"), 1, "a good upgrade returns true" );
    is_deeply( \@verified, ["app.bob.01"], "and the verdict was asked about that container" );

    local *ea_podman::util::verify_container_started = sub { die "it did not come back up\n" };
    my $err = do { local $@; eval { ea_podman::util::upgrade_container("app.bob.01") }; $@ };
    is( $err, "it did not come back up\n", "a failed verdict propagates out of upgrade_container" );
};

# Once the upgrade is conditional, verifying unconditionally is wrong in two
# ways, and both would report a container as failed for being in exactly the
# state we just decided to leave it in. On `upgrade_containers --all` that would
# mean a non-zero exit for every stopped container on the server. (EA4-325 B2/B7)
subtest 'a no-op upgrade is not asked whether the container came back up' => sub {
    my $verified = 0;
    local *ea_podman::util::verify_container_started = sub { $verified++; return 1 };

    local *ea_podman::util::_ensure_latest_container = sub { return { recreated => 0, started => 0 } };
    is( ea_podman::util::upgrade_container("app.bob.01"), 1, "the no-op still succeeds" );
    is( $verified, 0, "and nothing was verified, because nothing was touched" );

    # The conditional path recreates a stopped container and leaves it stopped.
    local *ea_podman::util::_ensure_latest_container = sub { return { recreated => 1, started => 0 } };
    is( ea_podman::util::upgrade_container("app.bob.01"), 1, "recreating without starting still succeeds" );
    is( $verified, 0, "and a container deliberately left down is not reported as failed" );
};

# CPANEL-56732 has the webapp plugin's redeploy call this as
# `upgrade_container( $name, force => 1 )`. Two halves to the contract, and only
# one of them can be tested from here:
#
#   * This build must understand that shape and route force through. Tested.
#   * A build PREDATING Increment B must ignore the extra arguments rather than
#     choke, which is what let the plugin ship first. That holds only while this
#     sub takes @_ with no subroutine signature -- add one and the plugin breaks
#     silently on a version pairing nobody tests together. Not testable here (this
#     build reads them), so it is a review contract: do not give this a signature.
subtest 'upgrade_container understands the shape the webapp plugin calls with' => sub {
    my @called;
    local *ea_podman::util::_ensure_latest_container = sub { push @called, $_[1]; return { recreated => 1, started => 1 } };
    local *ea_podman::util::verify_container_started = sub { return 1 };

    is( ea_podman::util::upgrade_container("app.bob.01"), 1, "the plain call works" );
    ok( !$called[0]{force}, "and does not force" );

    is( ea_podman::util::upgrade_container( "app.bob.01", force => 1 ), 1, "the plugin's call works" );
    ok( $called[1]{force}, "and forces" );

    is( $called[0]{op}, "upgrade", "both are upgrades" );
    is( $called[1]{op}, "upgrade", "both are upgrades" );
};

done_testing();
