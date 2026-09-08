#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-ea-podman-adminbin.t          Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

## no critic qw(TestingAndDebugging::RequireUseStrict TestingAndDebugging::RequireUseWarnings)
use Test::Spec;    # automatically turns on strict and warnings

use FindBin;

use File::Temp;

my %conf = (
    require => "$FindBin::Bin/../SOURCES/subids.pm",
    package => 'bin::admin::Cpanel::ea_podman',
);

require $conf{require};

our $max_usernamespaces = 15000;
our $os                 = "AlmaLinux8";

our @qx_calls;

our $current_qx = sub {
    push @qx_calls, [@_];
    if ( $_[0] =~ m/user\.max_user_namespaces/ ) {
        return $max_usernamespaces;
    }
    elsif ( $_[0] =~ m:source /etc/os-release: ) {
        return $os;
    }
    return "";
};

use Test::Mock::Cmd qx => sub { $current_qx->(@_) };

our $getpwnam_called = 0;

BEGIN {
    # Temp::User::Cpanel, gets a permission denied when creating a user
    # Not sure why, so I have to override this function.
    # This could cause problems, but works for this test right now

    *CORE::GLOBAL::getpwnam = sub {
        my ($user_name) = @_;
        $getpwnam_called++;
        return ( $user_name, "Haha", 11002, 11004, 20, "Hi Mom", "No idea", "/home/$user_name", '/bin/bash' );
    };
}

$| = 1;

describe "subids" => sub {
    share %conf;

    describe "get_subuids" => sub {
        around {
            local $conf{mock_dir}    = File::Temp->newdir();
            local $conf{mock_subuid} = $conf{mock_dir} . "/subuid";
            local $conf{mock_subgid} = $conf{mock_dir} . "/subgid";

            Path::Tiny::path( $conf{mock_subuid} )->spew(
                qq{ubuntu:100000:65536
cptest1:165537:65536
}
            );

            Path::Tiny::path( $conf{mock_subgid} )->spew(
                qq{ubuntu:100000:65536
cptest1:165537:65536
}
            );

            no warnings qw/once/;

            local $ea_podman::subids::file_subuid = $conf{mock_subuid};
            local $ea_podman::subids::file_subgid = $conf{mock_subgid};

            yield;
        };

        it "should properly list" => sub {
            my $hr = ea_podman::subids::get_subuids();

            my $expected_hr = {
                ubuntu  => '100000:65536',
                cptest1 => '165537:65536'
            };

            cmp_deeply( $hr, $expected_hr );
        };
    };

    describe "get_subgids" => sub {
        around {
            local $conf{mock_dir}    = File::Temp->newdir();
            local $conf{mock_subuid} = $conf{mock_dir} . "/subuid";
            local $conf{mock_subgid} = $conf{mock_dir} . "/subgid";

            Path::Tiny::path( $conf{mock_subuid} )->spew(
                qq{ubuntu:100000:65536
cptest1:165537:65536
}
            );

            Path::Tiny::path( $conf{mock_subgid} )->spew(
                qq{ubuntu:100000:65536
cptest1:165537:65536
}
            );

            no warnings qw/once/;

            local $ea_podman::subids::file_subuid = $conf{mock_subuid};
            local $ea_podman::subids::file_subgid = $conf{mock_subgid};

            yield;
        };

        it "should properly list" => sub {
            my $hr = ea_podman::subids::get_subgids();

            my $expected_hr = {
                ubuntu  => '100000:65536',
                cptest1 => '165537:65536'
            };

            cmp_deeply( $hr, $expected_hr );
        };
    };

    describe "assert_has_user_namespaces" => sub {
        it "should work correctly if max_usernamespaces is supported" => sub {
            my $val = ea_podman::subids::assert_has_user_namespaces();
            is( $val, 15000 );
        };

        it "should output horrible things if not supported" => sub {
            local $max_usernamespaces = 0;
            eval { ea_podman::subids::assert_has_user_namespaces(); };

            ok( $@ =~ m/User Namespaces not available/ );
        };

        it "should output more horrible things if on c7" => sub {
            local $max_usernamespaces = 0;
            local $os                 = "centos7";

            eval { ea_podman::subids::assert_has_user_namespaces(); };

            ok( $@ =~ m/CentOS 7 running these command/ );
        };
    };

    describe "ensure_user_root" => sub {
        around {
            local $conf{mock_dir}    = File::Temp->newdir();
            local $conf{mock_subuid} = $conf{mock_dir} . "/subuid";
            local $conf{mock_subgid} = $conf{mock_dir} . "/subgid";

            Path::Tiny::path( $conf{mock_subuid} )->spew(
                qq{ubuntu:100000:65536
cptest1:165537:65536
}
            );

            Path::Tiny::path( $conf{mock_subgid} )->spew(
                qq{ubuntu:100000:65536
cptest1:165537:65536
}
            );

            no warnings qw/once/;

            local $ea_podman::subids::file_subuid = $conf{mock_subuid};
            local $ea_podman::subids::file_subgid = $conf{mock_subgid};

            local $conf{mock_rundir} = $conf{mock_dir} . "/run";
            mkdir $conf{mock_rundir};

            local $ea_podman::subids::dir_run = $conf{mock_rundir};

            # Stub the privileged `loginctl enable-linger` call: simulate it
            # creating the user’s runtime dir (getpwnam mock returns uid 11002)
            # without invoking the real loginctl during the test.
            no warnings qw/once/;
            local $ea_podman::subids::linger_enabler = sub {
                my $d = "$ea_podman::subids::dir_run/11002";
                mkdir $d, 0700;
                Path::Tiny::path("$d/bus")->touch;    # simulate the user-manager dbus socket
                return 1;
            };

            # Stub the other privileged call ensure_user_session() makes, for the
            # same reason: unstubbed it is a real `systemctl is-active` (and then
            # a real `systemctl start`) against the host. A live manager owns the
            # socket the stub above creates.
            local $ea_podman::subids::user_manager_is_active = sub { -e "$ea_podman::subids::dir_run/$_[0]/bus" ? 1 : 0 };

            yield;
        };

        it "should still ensure the session (look up the uid) even when the user already exists in subids" => sub {
            my $user_name = "cptest1";
            local $getpwnam_called = 0;

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537 ); };

            # ensure_user_session() always runs now (CPANEL-54037), so the uid
            # is looked up even when the subids are already present.
            ok( $getpwnam_called >= 1 );
        };

        it "should call getpwnam when user does not exist in subids" => sub {
            my $user_name = "cptest9";
            local $getpwnam_called = 0;

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537 ); };

            ok( $getpwnam_called >= 1 );
        };

        it "should create subdir in /run/user via the linger bootstrap" => sub {
            my $user_name = "cptest9";

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537 ); };

            my $dir = $conf{mock_rundir} . "/11002";
            ok( -d $dir );
        };

        it "should create entry in /etc/subuid" => sub {
            my $user_name = "cptest9";
            my $hr;
            eval {
                ea_podman::subids::ensure_user_root( $user_name, 65537 );
                $hr = ea_podman::subids::get_subuids();
            };

            ok( exists $hr->{$user_name} );
        };

        it "should create entry in /etc/subgid" => sub {
            my $user_name = "cptest9";
            my $hr;
            eval {
                ea_podman::subids::ensure_user_root( $user_name, 65537 );
                $hr = ea_podman::subids::get_subgids();
            };

            ok( exists $hr->{$user_name} );
        };

        # CPANEL-55309: the caller that can see the container registry decides
        # whether this account gets a lingering session at all.
        it "should skip the session when the caller says not to" => sub {
            my $user_name = "cptest9";

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537, 0 ); };

            ok( !-d $conf{mock_rundir} . "/11002", "no runtime dir was bootstrapped" );

            my $hr = ea_podman::subids::get_subuids();
            ok( exists $hr->{$user_name}, "the subids are still allocated — podman needs those regardless" );
        };

        it "should ensure the session when the caller asks for one" => sub {
            my $user_name = "cptest9";

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537, 1 ); };

            ok( -d $conf{mock_rundir} . "/11002" );
        };
    };

    describe "linger" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $conf{mock_dir}    = File::Temp->newdir();
            local $conf{mock_linger} = $conf{mock_dir} . "/linger";
            mkdir $conf{mock_linger};

            no warnings qw/once/;
            local $ea_podman::subids::dir_linger = $conf{mock_linger};

            # Stub the privileged `loginctl disable-linger` call: it removes the
            # marker file, which is all logind does on the state we can see.
            local @mi{qw(disabled)} = ( [] );
            local $ea_podman::subids::linger_disabler = sub {
                my ($user) = @_;
                push @{ $mi{disabled} }, $user;
                unlink "$ea_podman::subids::dir_linger/$user";
                return 1;
            };

            yield;
        };

        it "should see a user that systemd marked as lingering" => sub {
            Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;

            ok( ea_podman::subids::user_has_linger("cptest1") );
            ok( !ea_podman::subids::user_has_linger("cptest2") );
        };

        it "should not consider an undefined or empty user to be lingering" => sub {
            ok( !ea_podman::subids::user_has_linger(undef) );
            ok( !ea_podman::subids::user_has_linger("") );
        };

        it "should disable linger for a lingering user" => sub {
            Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;

            ok( ea_podman::subids::remove_user_session("cptest1") );
            is_deeply( $mi{disabled}, ["cptest1"] );
            ok( !ea_podman::subids::user_has_linger("cptest1") );
        };

        it "should be a no-op for a user that is not lingering" => sub {
            ok( ea_podman::subids::remove_user_session("cptest2") );
            is_deeply( $mi{disabled}, [], "loginctl is not called for a user that is not lingering" );
        };

        it "should report failure when the linger survives the disable" => sub {
            Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;

            no warnings qw/once/;
            local $ea_podman::subids::linger_disabler = sub { return 1; };    # claims success, changes nothing

            ok( !ea_podman::subids::remove_user_session("cptest1"), "the marker is trusted over the exit code" );
        };

        it "should still report success when loginctl exits non-zero but the linger is gone" => sub {
            Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;

            no warnings qw/once/;
            local $ea_podman::subids::linger_disabler = sub {
                unlink "$ea_podman::subids::dir_linger/$_[0]";
                return 0;
            };

            ok( ea_podman::subids::remove_user_session("cptest1") );
        };

        it "should remove a stale marker left behind by a deleted account" => sub {
            Path::Tiny::path("$conf{mock_linger}/goneuser")->touch;

            ok( ea_podman::subids::remove_stale_linger_marker("goneuser") );
            ok( !-e "$conf{mock_linger}/goneuser" );
            is_deeply( $mi{disabled}, [], "loginctl is never asked to look up an account that no longer exists" );
        };

        it "should be happy when there is no stale marker to remove" => sub {
            ok( ea_podman::subids::remove_stale_linger_marker("goneuser") );
        };
    };

    # EA4-319: cagefs 7.6.39+ masks the `user@.service` template, so no per-user
    # systemd manager can start. ea-podman lifts the mask for exactly as long as
    # it takes to start one, then puts it straight back.
    describe "user@.service mask bypass" => sub {
        our %mask;

        around {
            local $conf{mock_dir} = File::Temp->newdir();

            local %mask = ( reloads => 0, ran => 0 );

            mkdir "$conf{mock_dir}/etc";
            mkdir "$conf{mock_dir}/run";

            no warnings qw/once/;

            local $ea_podman::subids::file_mask_etc   = "$conf{mock_dir}/etc/user\@.service";
            local $ea_podman::subids::file_mask_run   = "$conf{mock_dir}/run/user\@.service";
            local $ea_podman::subids::file_mask_lock  = "$conf{mock_dir}/mask.lock";
            local $ea_podman::subids::file_mask_state = "$conf{mock_dir}/mask.state";

            local $ea_podman::subids::daemon_reloader = sub { $mask{reloads}++; return 1 };

            yield;
        };

        it "should be a pure pass-through when the template is not masked" => sub {
            ea_podman::subids::with_user_manager_unmasked( sub { $mask{ran}++; return } );

            is( $mask{ran},     1, "the wrapped code ran" );
            is( $mask{reloads}, 0, "no daemon-reload: an unmasked host sees no extra systemd work at all" );
            ok( !-e $ea_podman::subids::file_mask_state, "no state file is written" );
            ok( !-e $ea_podman::subids::file_mask_lock,  "the lock is not even created" );
        };

        it "should report which location the mask is in" => sub {
            ok( !ea_podman::subids::user_manager_mask_file(), "undef when nothing is masked" );

            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            is( ea_podman::subids::user_manager_mask_file(), $ea_podman::subids::file_mask_etc, "finds a persistent mask" );
        };

        it "should treat a zero-byte unit file as masked too" => sub {
            Path::Tiny::path($ea_podman::subids::file_mask_etc)->touch;

            is( ea_podman::subids::user_manager_mask_file(), $ea_podman::subids::file_mask_etc, "an empty unit file loads as masked per systemd.unit(5), so it counts" );
        };

        it "should ignore a symlink that is not a mask" => sub {
            symlink( "/usr/lib/systemd/system/user\@.service", $ea_podman::subids::file_mask_etc );

            ok( !ea_podman::subids::user_manager_mask_file(), "only /dev/null (or empty) means masked" );
        };

        # Generated rather than copied so every shape of mask is held to the same
        # properties.
        for my $case (
            { what => "a persistent mask", seed => sub { symlink( "/dev/null", $ea_podman::subids::file_mask_etc ) }, where => sub { $ea_podman::subids::file_mask_etc } },
            { what => "a runtime mask",    seed => sub { symlink( "/dev/null", $ea_podman::subids::file_mask_run ) }, where => sub { $ea_podman::subids::file_mask_run } },
            { what => "a zero-byte mask",  seed => sub { Path::Tiny::path($ea_podman::subids::file_mask_etc)->touch }, where => sub { $ea_podman::subids::file_mask_etc } },
        ) {
            it "should lift $case->{what} for the duration and put it back in the same place" => sub {
                $case->{seed}->();

                my $masked_during_code = 1;
                ea_podman::subids::with_user_manager_unmasked(
                    sub {
                        $masked_during_code = ea_podman::subids::user_manager_mask_file() ? 1 : 0;
                        ok( -e $ea_podman::subids::file_mask_state, "an in-progress window is recorded on disk" );
                        return;
                    }
                );

                is( $masked_during_code,                         0,                  "the mask is lifted while the wrapped code runs" );
                is( ea_podman::subids::user_manager_mask_file(), $case->{where}->(), "and is back afterwards, in the same location" );
                ok( !-e $ea_podman::subids::file_mask_state, "and the in-progress record is cleared" );
            };
        }

        it "should relocate nothing: a runtime mask never comes back under /etc" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_run );

            ea_podman::subids::with_user_manager_unmasked( sub { return } );

            ok( !-e $ea_podman::subids::file_mask_etc, "nothing is left behind in the persistent location" );
        };

        it "should normalise a zero-byte mask to the canonical symlink" => sub {
            Path::Tiny::path($ea_podman::subids::file_mask_etc)->touch;

            ea_podman::subids::with_user_manager_unmasked( sub { return } );

            is( readlink($ea_podman::subids::file_mask_etc), "/dev/null", "restored as `systemctl mask` would have written it" );
        };

        # The one test that owns the reload count, so the tests above are free to
        # be about restoration without also pinning systemd bookkeeping.
        it "should reload the manager once to lift the mask and once to put it back" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::with_user_manager_unmasked( sub { return } );

            is( $mask{reloads}, 2, "systemd is told twice, because it caches unit load state" );
        };

        it "should remask when the wrapped code dies, and still propagate the error" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            eval {
                ea_podman::subids::with_user_manager_unmasked( sub { die "boom\n" } );
            };

            is( $@, "boom\n", "the error is not swallowed" );
            ok( ea_podman::subids::user_manager_mask_file(), "the mask is restored on the way out of a die" );
            ok( !-e $ea_podman::subids::file_mask_state,     "and the in-progress record is cleared" );
        };

        it "should put back a mask a killed predecessor left lifted" => sub {

            # What a `kill -9` mid-window leaves: no mask on disk, but a record of
            # the one that was there.
            ea_podman::subids::_write_mask_state($ea_podman::subids::file_mask_etc);
            ok( !ea_podman::subids::user_manager_mask_file(), "precondition: the host is left unmasked" );

            ea_podman::subids::with_user_manager_unmasked( sub { $mask{ran}++; return } );

            is( $mask{ran},                                  1,                                 "the work still gets done" );
            is( $mask{reloads},                              1,                                 "the abandoned mask is adopted, not restored and then lifted again" );
            is( ea_podman::subids::user_manager_mask_file(), $ea_podman::subids::file_mask_etc, "and it is back in place where it was" );
            ok( !-e $ea_podman::subids::file_mask_state, "with the stale record cleared" );
        };

        it "should refuse a state file naming a path we do not manage" => sub {
            Path::Tiny::path($ea_podman::subids::file_mask_state)->spew("$conf{mock_dir}/somewhere-else\n");

            ea_podman::subids::with_user_manager_unmasked( sub { return } );

            ok( !-e "$conf{mock_dir}/somewhere-else", "we never create a unit file outside the two mask paths" );
        };

        it "should record the state file as one line naming the mask" => sub {

            # The format is a contract between two ea-podman runs (the second one
            # repairs the first one's window), so one test pins the actual bytes.
            ea_podman::subids::_write_mask_state($ea_podman::subids::file_mask_run);

            is( Path::Tiny::path($ea_podman::subids::file_mask_state)->slurp, "$ea_podman::subids::file_mask_run\n", "just the masked path" );
            is( ea_podman::subids::_read_mask_state(),                        $ea_podman::subids::file_mask_run,     "and it round-trips" );
        };

        it "should keep the in-progress record and warn loudly when the mask cannot be put back" => sub {

            # Losing the mask leaves CLOS-4517 off on the host. A regular file where
            # the parent directory would go makes the restore fail even for root.
            Path::Tiny::path("$conf{mock_dir}/in-the-way")->touch;
            local $ea_podman::subids::file_mask_etc = "$conf{mock_dir}/in-the-way/user\@.service";
            ea_podman::subids::_write_mask_state($ea_podman::subids::file_mask_etc);

            my @warnings;
            my $rv;
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                $rv = ea_podman::subids::_restore_user_manager_mask($ea_podman::subids::file_mask_etc);
            }

            ok( !$rv, "the restore reports that it failed" );
            like( join( "", @warnings ), qr/could not put the .*mask back/, "and says so out loud" );
            like( join( "", @warnings ), qr/systemctl mask/,                "with the command to fix it by hand" );
            unlike( join( "", @warnings ), qr/No such file or directory/, "reporting the real errno from the symlink, not a leftover from a stat" );
            ok( -e $ea_podman::subids::file_mask_state, "the in-progress record is kept so the next run retries" );
        };

        it "should unmask and remask only once when nested" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::with_user_manager_unmasked(
                sub {
                    ea_podman::subids::with_user_manager_unmasked( sub { $mask{ran}++; return } );
                    ok( !ea_podman::subids::user_manager_mask_file(), "the inner call does not remask under its own caller" );
                    return;
                }
            );

            is( $mask{ran},     1, "the innermost code still ran" );
            is( $mask{reloads}, 2, "exactly one unmask/remask pair for the whole nest" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the mask is back" );
        };
    };

    # The readiness poll and its two dies. Previously uncovered: every other stub
    # in this file either creates the bus socket synchronously or returns before
    # the loop is reached.
    describe "ensure_user_session readiness" => sub {
        our %sess;

        around {
            local $conf{mock_dir} = File::Temp->newdir();

            local %sess = ( started => [], enabled => 0, slept => 0 );

            mkdir "$conf{mock_dir}/run";
            mkdir "$conf{mock_dir}/linger";
            mkdir "$conf{mock_dir}/granted";
            mkdir "$conf{mock_dir}/etc";

            no warnings qw/once/;

            local $ea_podman::subids::dir_run            = "$conf{mock_dir}/run";
            local $ea_podman::subids::dir_linger         = "$conf{mock_dir}/linger";
            local $ea_podman::subids::dir_granted_linger = "$conf{mock_dir}/granted";
            local $ea_podman::subids::file_mask_etc      = "$conf{mock_dir}/etc/user\@.service";
            local $ea_podman::subids::file_mask_run      = "$conf{mock_dir}/etc/never-masked-here";
            local $ea_podman::subids::file_mask_lock     = "$conf{mock_dir}/mask.lock";
            local $ea_podman::subids::file_mask_state    = "$conf{mock_dir}/mask.state";

            local $ea_podman::subids::daemon_reloader      = sub { return 1 };
            local $ea_podman::subids::user_manager_starter = sub { push @{ $sess{started} }, $_[0]; return 1 };
            local $ea_podman::subids::linger_enabler       = sub { $sess{enabled}++;                return 1 };

            # The healthy case these tests model: a live manager is exactly what
            # owns the bus socket. The stale-socket case -- socket without
            # manager -- is its own test below.
            local $ea_podman::subids::user_manager_is_active = sub { -e "$ea_podman::subids::dir_run/$_[0]/bus" ? 1 : 0 };

            # Do not actually sleep out the 10s ceiling to test the timeout.
            local $ea_podman::subids::poll_iterations = 2;
            local $ea_podman::subids::poll_sleeper    = sub { $sess{slept}++; return };

            yield;
        };

        it "should do nothing at all when the account already has a running manager" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11002";
            Path::Tiny::path("$ea_podman::subids::dir_run/11002/bus")->touch;

            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::ensure_user_session("cptest1");

            is( $sess{enabled}, 0, "no enable-linger" );
            is_deeply( $sess{started}, [], "no manager start" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the mask was never touched: the hot path never opens a window" );
        };

        it "should ask systemd for the manager directly, by uid" => sub {

            # The post-reboot state on a cagefs host: linger marker present,
            # runtime dir present (user-runtime-dir@.service is not masked), bus
            # missing. enable-linger alone is a no-op here, so the explicit start
            # is what repairs it.
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11002";

            local $ea_podman::subids::user_manager_starter = sub {
                push @{ $sess{started} }, $_[0];
                Path::Tiny::path("$ea_podman::subids::dir_run/11002/bus")->touch;
                return 1;
            };

            ea_podman::subids::ensure_user_session("cptest1");

            is_deeply( $sess{started}, [11002], "systemctl start user\@<uid>.service is asked for, by uid" );
            is( $sess{enabled}, 1, "and enable-linger still ran, for the persistence half of the job" );
        };

        it "should skip the start when enable-linger already produced a bus" => sub {
            local $ea_podman::subids::linger_enabler = sub {
                $sess{enabled}++;
                my $d = "$ea_podman::subids::dir_run/11002";
                mkdir $d;
                Path::Tiny::path("$d/bus")->touch;
                return 1;
            };

            ea_podman::subids::ensure_user_session("cptest1");

            is( $sess{enabled}, 1, "enable-linger ran" );
            is_deeply( $sess{started}, [], "and was enough on its own, so systemd is not asked again" );
            is( $sess{slept}, 0, "and nothing is polled for, since the bus is already there" );
        };

        # Caught on a live box: `systemctl stop user@<uid>.service` on an account
        # that still has a login leaves /run/user/<uid>/bus behind, because logind
        # only tears the runtime dir down once the LAST session ends. A start
        # decision made on `-e $bus` skips the start and leaves the account with a
        # socket nothing is listening on. (EA4-319)
        it "should still start the manager when the bus socket is stale" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11002";
            Path::Tiny::path("$ea_podman::subids::dir_run/11002/bus")->touch;

            local $ea_podman::subids::user_manager_is_active = sub { $sess{active} ? 1 : 0 };
            local $ea_podman::subids::user_manager_starter   = sub {
                push @{ $sess{started} }, $_[0];
                $sess{active} = 1;
                return 1;
            };

            ea_podman::subids::ensure_user_session("cptest1");

            is_deeply( $sess{started}, [11002], "the orphaned socket does not fool it into skipping the start" );
        };

        # The inverse of the stale socket above, and the case nothing handled.
        # Confirmed live on CloudLinux 8 (root, 2026-09-04): /run/user/<uid> torn
        # down underneath a manager that stays running. The manager keeps the
        # account's containers up but cannot recreate its own socket, the start is
        # skipped because systemd says "active", and the poll then waits out its
        # ceiling for a bus that is never coming -- on this and on every later
        # command, forever. Only a restart repairs it, and a restart is not this
        # path's to perform: init_user() reaches here for read-only verbs too.
        # (EA4-319)
        it "should report, not repair, a running manager whose bus is gone" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11002";

            local $ea_podman::subids::user_manager_is_active = sub { 1 };

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/is running, but its session bus/,  "it names the actual condition" );
            like( $@, qr/systemctl stop user\@11002\.service/, "and the recovery that always works, whether or not the account has containers" );
            like( $@, qr/stops the account/,                 "and warns that the repair is not free" );
            like( $@, qr/but not for an account with no containers/, "and says where ensure_user_sessions does NOT help" );
            unlike( $@, qr/did not appear/, "not the generic bus message, which points at the wrong bug" );

            is_deeply( $sess{started}, [], "nothing is started -- `systemctl start` on a running unit is a no-op" );
            is( $sess{slept}, 2, "and it still polls first, so a manager that is merely slow to come up is not misreported" );

            # Without this the adminbin swallows it into "Unable to ensure the
            # user has subuids and subgids" and the operator never sees the one
            # message written to tell them what to do. (EA4-319)
            ok( ea_podman::subids::is_user_session_error($@), "and it is marked as safe to show the caller" );
            unlike( ea_podman::subids::strip_user_session_error($@), qr/\Qea-podman user session: \E/, "with the marker stripped for display" );
        };

        it "should mark the runtime-directory and bus dies as showable too" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;

            eval { ea_podman::subids::ensure_user_session("cptest1"); };
            ok( ea_podman::subids::is_user_session_error($@), "the runtime-directory die is a session error" );
            like( ea_podman::subids::strip_user_session_error($@), qr/\AThe directory/, "and strips to the bare message" );

            local $ea_podman::subids::linger_enabler = sub { mkdir "$ea_podman::subids::dir_run/11002"; return 1 };

            eval { ea_podman::subids::ensure_user_session("cptest1"); };
            ok( ea_podman::subids::is_user_session_error($@), "the bus die is a session error" );
            like( ea_podman::subids::strip_user_session_error($@), qr/\AThe user session bus/, "and strips to the bare message" );
        };

        it "should not mark an unrelated error as showable" => sub {
            ok( !ea_podman::subids::is_user_session_error("subuid collision with “someone-else”\n"), "a subid refusal is not showable -- it names another account" );
            ok( !ea_podman::subids::is_user_session_error(undef),                                     "and undef is not showable" );
            is( ea_podman::subids::strip_user_session_error("plain\n"), "plain\n", "stripping leaves an unmarked error alone" );
        };

        # The reachable path, found live on a second CL8 box (2026-09-04): an
        # install grants the session, the image pull fails, install_container's
        # error path releases the session it just granted, and the account is left
        # wedged with NO containers -- which the boot sweep works from, so it
        # would never come back to it. With nothing to take down, restarting the
        # manager here costs no downtime, so the caller that can see the registry
        # says so and this repairs in place. (EA4-319)
        it "should repair in place when the account has no containers to lose" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11002";

            my @stopped;
            local $ea_podman::subids::user_manager_stopper = sub { push @stopped, $_[0]; return 1 };

            # Active throughout, exactly as the wedge behaves: stopping and
            # starting is what produces the bus, not the "active" answer.
            local $ea_podman::subids::user_manager_is_active = sub { 1 };
            local $ea_podman::subids::user_manager_starter   = sub {
                push @{ $sess{started} }, $_[0];
                Path::Tiny::path("$ea_podman::subids::dir_run/$_[0]/bus")->touch;
                return 1;
            };

            eval { ea_podman::subids::ensure_user_session( "cptest1", may_restart => 1 ); };

            is( $@, "", "it does not die" );
            is_deeply( \@stopped,          [11002], "the unusable manager is stopped" );
            is_deeply( $sess{started},     [11002], "and started again, which is the only thing that recreates the socket" );
            ok( -e "$ea_podman::subids::dir_run/11002/bus", "and the bus is back" );
        };

        it "should not repair in place by default, so a read-only verb cannot bounce containers" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11002";

            my @stopped;
            local $ea_podman::subids::user_manager_stopper   = sub { push @stopped, $_[0]; return 1 };
            local $ea_podman::subids::user_manager_is_active = sub { 1 };

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            is_deeply( \@stopped, [], "no restart without an explicit may_restart from the caller" );
            like( $@, qr/is running, but/, "it reports instead" );
        };

        it "should report the runtime directory when that is what went missing under a running manager" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;

            local $ea_podman::subids::user_manager_is_active = sub { 1 };

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/is running, but its runtime directory/, "the directory variant of the same fault" );
            like( $@, qr/ensure_user_sessions/,                  "with the same repair instruction" );
        };

        it "should die naming the runtime directory when that is what is missing" => sub {
            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/The directory .* is missing/, "the runtime-dir die fires when there is no runtime dir" );
            is( $sess{slept}, 2, "after polling for it" );
        };

        it "should die naming the bus when only the bus is missing" => sub {
            local $ea_podman::subids::linger_enabler = sub {
                $sess{enabled}++;
                mkdir "$ea_podman::subids::dir_run/11002";
                return 1;
            };

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/The user session bus .* did not appear/, "the bus die fires, not the directory one" );
            like( $@, qr/systemctl start/,                        "and names both commands that were tried, not just enable-linger" );
            unlike( $@, qr/masked/, "and says nothing about masking on a host where nothing is masked" );
        };

        it "should not sleep out the ceiling when the manager start already failed" => sub {
            local $ea_podman::subids::linger_enabler       = sub { mkdir "$ea_podman::subids::dir_run/11002"; return 1 };
            local $ea_podman::subids::user_manager_starter = sub { return 0 };

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/The user session bus .* did not appear/, "it still fails" );
            is( $sess{slept}, 0, "but does not poll for a bus that is not coming" );
        };

        # Measured on systemd 239: masking user@.service takes
        # user-runtime-dir@<uid>.service down with it (user@ Requires= it), so a
        # real masked host produces NO runtime dir at all and this is the die that
        # fires. EA4-319 open question 2 guessed the other one.
        it "should name the mask in the runtime-directory die when the template is masked" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/The directory .* is missing/,       "the runtime-directory die is what a masked host hits" );
            like( $@, qr/\Quser\E\@\Q.service` is masked\E/, "and it says the template is masked" );
            like( $@, qr/CLOS-4517/,                         "and points at where the mask comes from" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the mask is restored even though the session failed" );
        };

        it "should name the mask in the bus die when only the bus is missing" => sub {
            local $ea_podman::subids::linger_enabler = sub {
                mkdir "$ea_podman::subids::dir_run/11002";
                return 1;
            };

            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            eval { ea_podman::subids::ensure_user_session("cptest1"); };

            like( $@, qr/The user session bus .* did not appear/, "still the bus die (EA4-319 open question 2)" );
            like( $@, qr/\Quser\E\@\Q.service` is masked\E/,      "which now says the template is masked" );
            like( $@, qr/CLOS-4517/,                              "and points at where the mask comes from" );
            like( $@, qr/journalctl -u user\@11002\.service/,     "with the per-uid unit to go and read" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the mask is restored even though the session failed" );
        };
    };
    # The boot sweep (EA4-319). What is worth pinning here is not that it starts
    # managers -- ensure_user_session already covers that -- but the two things
    # that are only true because the sweep is hand-split into phases: ONE window
    # for the whole host, and the readiness poll outside it.
    describe "ensure_user_sessions" => sub {
        our %sweep;

        around {
            local $conf{mock_dir} = File::Temp->newdir();

            local %sweep = ( started => [], enabled => [], reloads => 0, slept => 0, in_window => [], stopped_in_window => [] );

            mkdir "$conf{mock_dir}/run";
            mkdir "$conf{mock_dir}/linger";
            mkdir "$conf{mock_dir}/granted";
            mkdir "$conf{mock_dir}/etc";

            no warnings qw/once redefine/;

            # The file-wide getpwnam mock answers 11002 for every name, which
            # cannot express a sweep over several accounts. cptestN => 1100N.
            local *CORE::GLOBAL::getpwnam = sub {
                my ($user_name) = @_;
                return if $user_name !~ m/\Acptest([0-9])\z/;
                return ( $user_name, "x", 11000 + $1, 11004, 20, "", "", "/home/$user_name", "/bin/bash" );
            };

            local $ea_podman::subids::dir_run            = "$conf{mock_dir}/run";
            local $ea_podman::subids::dir_linger         = "$conf{mock_dir}/linger";
            local $ea_podman::subids::dir_granted_linger = "$conf{mock_dir}/granted";
            local $ea_podman::subids::file_mask_etc      = "$conf{mock_dir}/etc/user\@.service";
            local $ea_podman::subids::file_mask_run      = "$conf{mock_dir}/etc/never-masked-here";
            local $ea_podman::subids::file_mask_lock     = "$conf{mock_dir}/mask.lock";
            local $ea_podman::subids::file_mask_state    = "$conf{mock_dir}/mask.state";

            local $ea_podman::subids::daemon_reloader = sub { $sweep{reloads}++;                return 1 };
            local $ea_podman::subids::linger_enabler  = sub { push @{ $sweep{enabled} }, $_[0]; return 1 };

            # As in the readiness block above: healthy means the manager owns the
            # socket. The stale case -- socket without manager -- is its own test.
            local $ea_podman::subids::user_manager_is_active = sub { -e "$ea_podman::subids::dir_run/$_[0]/bus" ? 1 : 0 };

            # Records whether the template was unmasked at the moment of each
            # start, which is how "inside the window" is asserted below.
            local $ea_podman::subids::user_manager_starter = sub {
                my ($uid) = @_;
                push @{ $sweep{started} }, $uid;
                push @{ $sweep{in_window} }, ( ea_podman::subids::user_manager_mask_file() ? 0 : 1 );

                my $d = "$ea_podman::subids::dir_run/$uid";
                mkdir $d;
                Path::Tiny::path("$d/bus")->touch;

                return 1;
            };

            local $ea_podman::subids::poll_iterations = 2;
            local $ea_podman::subids::poll_sleeper    = sub { $sweep{slept}++; return };

            yield;
        };

        # Puts an account in the post-reboot state a masked host produces:
        # lingering, but no runtime dir and no bus.
        my $lingering = sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/$_[0]")->touch;
            return;
        };

        it "should start a manager for every account that needs one" => sub {
            $lingering->("cptest1");
            $lingering->("cptest3");

            my $result = ea_podman::subids::ensure_user_sessions( "cptest1", "cptest3" );

            is_deeply( [ sort { $a <=> $b } @{ $sweep{started} } ], [ 11001, 11003 ],                               "each account's manager is asked for, by its own uid" );
            is_deeply( $result,                                     { cptest1 => "started", cptest3 => "started" }, "and both are reported started" );
        };

        it "should open exactly one unmask window for the whole sweep" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->($_) for qw(cptest1 cptest2 cptest3);

            ea_podman::subids::ensure_user_sessions( "cptest1", "cptest2", "cptest3" );

            is( scalar @{ $sweep{started} }, 3, "all three managers were started" );
            is_deeply( $sweep{in_window}, [ 1, 1, 1 ], "every one of them inside the window" );
            is( $sweep{reloads}, 2, "but only one unmask/remask pair for the sweep, not one per account" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the mask is back afterwards" );
        };

        # The whole reason this is not a loop over ensure_user_session(): nesting
        # would drag each account's ~10s poll inside the host-wide unmask.
        it "should poll for the buses only after the mask is back" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->("cptest1");

            local $ea_podman::subids::user_manager_starter = sub { push @{ $sweep{started} }, $_[0]; return 1 };
            local $ea_podman::subids::poll_sleeper         = sub {
                $sweep{slept}++;
                push @{ $sweep{in_window} }, ( ea_podman::subids::user_manager_mask_file() ? 0 : 1 );
                return;
            };

            {
                local $SIG{__WARN__} = sub { };    # the stub never produces a bus, so the sweep warns
                ea_podman::subids::ensure_user_sessions("cptest1");
            }

            is( $sweep{slept}, 2, "it polled" );
            is_deeply( $sweep{in_window}, [ 0, 0 ], "and the template was masked again the whole time it did" );
        };

        it "should share one poll ceiling across the sweep rather than one per account" => sub {
            $lingering->($_) for qw(cptest1 cptest2 cptest3);

            local $ea_podman::subids::user_manager_starter = sub { push @{ $sweep{started} }, $_[0]; return 1 };

            {
                local $SIG{__WARN__} = sub { };    # as above: no bus, so all three warn
                ea_podman::subids::ensure_user_sessions( "cptest1", "cptest2", "cptest3" );
            }

            is( $sweep{slept}, 2, "the ceiling is the sweep's, not 2 x 3 accounts" );
        };

        it "should skip an account whose manager is already up, without opening a window" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->("cptest1");
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;

            my $result = ea_podman::subids::ensure_user_sessions("cptest1");

            is_deeply( $result,         { cptest1 => "ok" }, "reported as already up" );
            is_deeply( $sweep{started}, [],                  "nothing started" );
            is_deeply( $sweep{enabled}, [],                  "no enable-linger" );
            is( $sweep{reloads}, 0, "and no window opened at all -- the boot no-op on a healthy host" );
        };

        # The repair half of the fault reported by ensure_user_session(): the
        # sweep is the one caller allowed to restart a manager, because boot and
        # an explicit admin invocation are the two contexts where taking the
        # account's containers down is expected. (EA4-319)
        it "should restart a manager that is running with no bus under it" => sub {
            # Masked, so "was the template lifted when this ran" is a real
            # question rather than vacuously true.
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->("cptest1");
            mkdir "$ea_podman::subids::dir_run/11001";

            # Active until something stops it, which is what makes the start below
            # a no-op unless the stop really happened.
            my %active = ( 11001 => 1 );
            my @stopped;

            local $ea_podman::subids::user_manager_is_active = sub { $active{ $_[0] } ? 1 : 0 };
            local $ea_podman::subids::user_manager_stopper   = sub {
                push @stopped, $_[0];
                push @{ $sweep{stopped_in_window} }, ( ea_podman::subids::user_manager_mask_file() ? 0 : 1 );
                $active{ $_[0] } = 0;
                return 1;
            };
            local $ea_podman::subids::user_manager_starter = sub {
                my ($uid) = @_;
                push @{ $sweep{started} }, $uid;
                $active{$uid} = 1;

                my $d = "$ea_podman::subids::dir_run/$uid";
                mkdir $d;
                Path::Tiny::path("$d/bus")->touch;
                return 1;
            };

            my $result = ea_podman::subids::ensure_user_sessions("cptest1");

            is_deeply( \@stopped,       [11001],                 "the useless manager is stopped first" );
            is_deeply( $sweep{started}, [11001],                 "and only then started -- a start alone would be a no-op" );
            is_deeply( $result,         { cptest1 => "started" }, "and the account comes back" );

            # A stop can block for TimeoutStopSec (90s). Inside the window that
            # would hold the host-wide unmask open for minutes. (EA4-319)
            is_deeply( $sweep{stopped_in_window}, [0], "and the stop happened with the template still masked, i.e. outside the window" );
        };

        it "should not stop a manager that was never running" => sub {
            $lingering->("cptest1");

            my @stopped;
            local $ea_podman::subids::user_manager_stopper = sub { push @stopped, $_[0]; return 1 };

            ea_podman::subids::ensure_user_sessions("cptest1");

            is_deeply( \@stopped,       [],      "no stop for a manager that is already down" );
            is_deeply( $sweep{started}, [11001], "just a start" );
        };

        it "should carry on after an account that cannot be started" => sub {
            $lingering->($_) for qw(cptest1 cptest2);

            local $ea_podman::subids::user_manager_starter = sub {
                my ($uid) = @_;
                push @{ $sweep{started} }, $uid;
                return 0 if $uid == 11001;

                my $d = "$ea_podman::subids::dir_run/$uid";
                mkdir $d;
                Path::Tiny::path("$d/bus")->touch;
                return 1;
            };

            my $result;
            my @warnings;
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                $result = ea_podman::subids::ensure_user_sessions( "cptest1", "cptest2" );
            }

            is_deeply( $sweep{started}, [ 11001, 11002 ],                              "the account after the failure was still tried" );
            is_deeply( $result,         { cptest1 => "failed", cptest2 => "started" }, "and only the one that failed is reported failed" );
            like( join( "", @warnings ), qr/cptest1/, "the failure is warned about" );
            is( $sweep{slept}, 0, "and no time is spent polling for a bus that is not coming" );
        };

        it "should not let one account's exception abort the sweep or strand the mask" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->($_) for qw(cptest1 cptest2);

            local $ea_podman::subids::linger_enabler = sub {
                my ($user) = @_;
                die "boom\n" if $user eq "cptest1";
                push @{ $sweep{enabled} }, $user;
                return 1;
            };

            my $result;
            {
                local $SIG{__WARN__} = sub { };
                $result = ea_podman::subids::ensure_user_sessions( "cptest1", "cptest2" );
            }

            is_deeply( $sweep{enabled}, ["cptest2"], "the sweep carried on past the die" );
            is( $result->{cptest1}, "failed",  "the account that threw is reported failed" );
            is( $result->{cptest2}, "started", "and the other one still came up" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the mask is back, not stranded off by the unwind" );
        };

        it "should name the mask when a manager will not start on a masked host" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->("cptest1");

            local $ea_podman::subids::user_manager_starter = sub { return 0 };

            my @warnings;
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                ea_podman::subids::ensure_user_sessions("cptest1");
            }

            my $warned = join( "", @warnings );
            like( $warned, qr/cptest1.*11001/,                    "names the account and its uid" );
            like( $warned, qr/\Quser\E\@\Q.service` is masked\E/, "and says the template is masked" );
            like( $warned, qr/CLOS-4517/,                         "and where the mask comes from" );
        };

        it "should skip an account that no longer exists rather than die" => sub {
            $lingering->("cptest1");

            my $result;
            my @warnings;
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                $result = ea_podman::subids::ensure_user_sessions( "ghostuser", "cptest1" );
            }

            is( $result->{ghostuser}, "unknown", "a registry entry for a deleted account is not fatal" );
            is( $result->{cptest1},   "started", "and does not stop the accounts that do exist" );
            like( join( "", @warnings ), qr/no such user/, "it is warned about" );
        };

        # The sweep's half of the stale-socket bug above. This one also has to be
        # caught in the RESULT: reporting "started" for an account whose manager
        # never came up is worse than the bug, because it hides it.
        it "should not report an account started on the strength of a stale socket" => sub {
            $lingering->("cptest1");
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;

            # The socket is there; nothing is listening on it, and the start fails.
            local $ea_podman::subids::user_manager_is_active = sub { 0 };
            local $ea_podman::subids::user_manager_starter   = sub { push @{ $sweep{started} }, $_[0]; return 0 };

            my $result;
            my @warnings;
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                $result = ea_podman::subids::ensure_user_sessions("cptest1");
            }

            is_deeply( $sweep{started}, [11001], "the stale socket does not skip the start" );
            is( $result->{cptest1}, "failed", "and it is not reported started just because the socket exists" );
            like( join( "", @warnings ), qr/nothing is listening on it/, "the warning says what is actually wrong" );
        };

        it "should not sweep an account whose manager is already running" => sub {
            $lingering->("cptest1");
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;

            local $ea_podman::subids::user_manager_is_active = sub { 1 };

            my $result = ea_podman::subids::ensure_user_sessions("cptest1");

            is_deeply( $result,         { cptest1 => "ok" }, "the healthy early return still holds" );
            is_deeply( $sweep{started}, [],                  "nothing started" );
        };

        it "should do nothing when given no accounts" => sub {
            my $result = ea_podman::subids::ensure_user_sessions();

            is_deeply( $result,         {}, "empty result" );
            is_deeply( $sweep{started}, [], "and nothing touched" );
            is( $sweep{reloads}, 0, "no window" );
        };
    };
};

runtests unless caller;

