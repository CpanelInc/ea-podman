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
    # systemd manager can start. EA4-321: ea-podman gives each account that needs
    # a manager a unit of its own instead of lifting the mask, because on systemd
    # 252 remasking the template reload tears down every running manager.
    describe "user@.service mask bypass" => sub {
        our %mask;

        around {
            local $conf{mock_dir} = File::Temp->newdir();

            local %mask = ( reloads => 0 );

            mkdir "$conf{mock_dir}/etc";
            mkdir "$conf{mock_dir}/run";
            mkdir "$conf{mock_dir}/vendor";

            Path::Tiny::path("$conf{mock_dir}/vendor/user\@.service")->spew_raw("[Unit]\nDescription=User Manager for UID %i\n");

            no warnings qw/once/;

            local $ea_podman::subids::file_mask_etc   = "$conf{mock_dir}/etc/user\@.service";
            local $ea_podman::subids::file_mask_run   = "$conf{mock_dir}/run/user\@.service";
            local $ea_podman::subids::file_mask_state = "$conf{mock_dir}/mask.state";
            local $ea_podman::subids::dir_unit_carveout = "$conf{mock_dir}/units";
            local $ea_podman::subids::dir_carveout_state = "$conf{mock_dir}/state";
            local @ea_podman::subids::files_vendor_unit = ( "$conf{mock_dir}/vendor/user\@.service" );

            local $ea_podman::subids::daemon_reloader = sub { $mask{reloads}++; return 1 };

            yield;
        };

        my $carveout = sub { ea_podman::subids::user_manager_carveout_file( $_[0] ) };

        # CageFS re-applies its mask on every install and upgrade, and on systemd
        # 252 that tears down every manager that has no unit of its own. A manager
        # started while the host is unmasked has to have one already.
        it "should give the account its unit even when the template is not masked" => sub {
            is( ea_podman::subids::ensure_user_manager_carveouts(1001), 1, "one unit written" );

            ok( !-l $carveout->(1001) && -f _, "a real file" );
            ok( !ea_podman::subids::user_manager_mask_file(), "and the host is still not masked: nothing else changed" );
        };

        it "should quietly write nothing on an unmasked host with no vendor unit to copy" => sub {
            local @ea_podman::subids::files_vendor_unit = ("$conf{mock_dir}/vendor/nope");

            is( ea_podman::subids::ensure_user_manager_carveouts(1001), 0, "nothing done" );
            ok( !-e $carveout->(1001), "no unit file" );
            is( $mask{reloads}, 0, "and no reload: such a host starts the manager from the template, as it always did" );
        };

        it "should write nothing for an empty list" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            is( ea_podman::subids::ensure_user_manager_carveouts(), 0, "nothing to do" );
            is( $mask{reloads}, 0, "and no reload" );
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

        for my $case (
            { what => "a persistent mask", seed => sub { symlink( "/dev/null", $ea_podman::subids::file_mask_etc ) }, where => sub { $ea_podman::subids::file_mask_etc } },
            { what => "a runtime mask",    seed => sub { symlink( "/dev/null", $ea_podman::subids::file_mask_run ) }, where => sub { $ea_podman::subids::file_mask_run } },
            { what => "a zero-byte mask",  seed => sub { Path::Tiny::path($ea_podman::subids::file_mask_etc)->touch }, where => sub { $ea_podman::subids::file_mask_etc } },
        ) {
            it "should give the account a unit of its own and leave $case->{what} exactly as it was" => sub {
                $case->{seed}->();
                my $before = -l $case->{where}->() ? readlink( $case->{where}->() ) : "file";

                is( ea_podman::subids::ensure_user_manager_carveouts(1001), 1, "one unit written" );

                ok( !-l $carveout->(1001) && -f _, "as a real file, not a symlink: a symlink to the vendor unit is resolved as the masked template" );
                is( ea_podman::subids::user_manager_mask_file(), $case->{where}->(), "the mask is still in the same place" );
                is( ( -l $case->{where}->() ? readlink( $case->{where}->() ) : "file" ), $before, "and is byte for byte what it was" );
            };
        }

        it "should copy the vendor unit" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::ensure_user_manager_carveouts(1001);

            is( Path::Tiny::path( $carveout->(1001) )->slurp_raw, Path::Tiny::path("$conf{mock_dir}/vendor/user\@.service")->slurp_raw, "same bytes as the vendor unit" );
            is( sprintf( "%04o", ( stat $carveout->(1001) )[2] & 07777 ), "0644", "and world readable, as unit files are" );
        };

        it "should name the file for the uid, so every other account stays refused" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::ensure_user_manager_carveouts(1001);

            ok( -e $carveout->(1001),  "the account asked for has one" );
            ok( !-e $carveout->(1002), "no other account does, so the template mask still applies to it" );
        };

        it "should reload once for any number of accounts, and never touch the mask's state" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            is( ea_podman::subids::ensure_user_manager_carveouts( 1001, 1002, 1003 ), 3, "three units written" );

            is( $mask{reloads}, 1, "one daemon-reload for the lot, so systemd sees the new files" );
            ok( ea_podman::subids::user_manager_mask_file(), "the template stays masked throughout: changing it is what kills running managers" );
        };

        it "should do nothing, and not reload, when the unit is already in place" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::ensure_user_manager_carveouts(1001);
            $mask{reloads} = 0;

            is( ea_podman::subids::ensure_user_manager_carveouts(1001), 0, "nothing to write" );
            is( $mask{reloads}, 0, "and so nothing to reload" );
        };

        it "should replace a stale copy" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            ea_podman::subids::ensure_user_manager_carveouts(1001);

            Path::Tiny::path("$conf{mock_dir}/vendor/user\@.service")->spew_raw("[Unit]\nDescription=newer\n");

            is( ea_podman::subids::ensure_user_manager_carveouts(1001), 1, "rewritten" );
            like( Path::Tiny::path( $carveout->(1001) )->slurp_raw, qr/newer/, "with the current vendor unit" );
        };

        it "should refuse to replace an explicit per-user mask, and leave it intact" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            mkdir $ea_podman::subids::dir_unit_carveout;
            symlink( "/dev/null", $carveout->(1001) );

            eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };

            like( $@, qr/was not written by ea-podman/, "says why" );
            ok( ea_podman::subids::is_user_session_error($@), "and is shown to the account like the other session errors" );
            ok( -l $carveout->(1001) && readlink( $carveout->(1001) ) eq "/dev/null", "the mask is still there" );
            is( $mask{reloads}, 0, "with nothing reloaded" );
        };

        it "should refuse to replace a unit someone else put there" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            mkdir $ea_podman::subids::dir_unit_carveout;
            Path::Tiny::path( $carveout->(1001) )->spew_raw("[Unit]\nDescription=custom\n");

            eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };

            like( $@, qr/was not written by ea-podman/, "refused" );
            like( Path::Tiny::path( $carveout->(1001) )->slurp_raw, qr/custom/, "and untouched" );
        };

        it "should still write the other accounts' units when one is refused" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            mkdir $ea_podman::subids::dir_unit_carveout;
            symlink( "/dev/null", $carveout->(1001) );

            eval { ea_podman::subids::ensure_user_manager_carveouts( 1001, 1002 ) };

            like( $@, qr/was not written by ea-podman/, "the refusal is still reported" );
            ok( -f $carveout->(1002), "but the other account has its unit" );
            ok( -l $carveout->(1001), "and the mask is intact" );
        };

        # The marker ea-podman keeps for a unit it wrote outlives an administrator
        # replacing that unit afterwards, so it cannot be what says the unit is ours.
        for my $case ( [ "a mask symlink", sub { unlink $_[0]; symlink( "/dev/null", $_[0] ) } ], [ "an empty file", sub { unlink $_[0]; Path::Tiny::path( $_[0] )->spew_raw("") } ], [ "an emptied file, in place", sub { truncate $_[0], 0 } ], [ "a different unit", sub { unlink $_[0]; Path::Tiny::path( $_[0] )->spew_raw("[Unit]\nDescription=custom\n") } ], ) {
            my ( $what, $replace ) = @{$case};

            it "should not overwrite $what an administrator put over a unit it wrote" => sub {
                symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
                ea_podman::subids::ensure_user_manager_carveouts(1001);
                $replace->( $carveout->(1001) );
                my $before = -l $carveout->(1001) ? readlink $carveout->(1001) : Path::Tiny::path( $carveout->(1001) )->slurp_raw;
                $mask{reloads} = 0;

                eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };

                like( $@, qr/was not written by ea-podman/, "refused" );
                my $after = -l $carveout->(1001) ? readlink $carveout->(1001) : Path::Tiny::path( $carveout->(1001) )->slurp_raw;
                is( $after, $before, "and left as the administrator made it" );
                is( $mask{reloads}, 0, "with nothing reloaded" );
            };

            it "should not remove $what an administrator put over a unit it wrote" => sub {
                symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
                ea_podman::subids::ensure_user_manager_carveouts(1001);
                $replace->( $carveout->(1001) );
                local $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };

                is( ea_podman::subids::remove_user_manager_carveout(1001), 0, "nothing removed" );
                ok( lstat( $carveout->(1001) ), "the administrator's file is still there" );
            };
        }

        it "should not remove a unit it did not write" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            mkdir $ea_podman::subids::dir_unit_carveout;
            symlink( "/dev/null", $carveout->(1001) );
            local $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };

            is( ea_podman::subids::remove_user_manager_carveout(1001), 0, "nothing removed" );
            ok( -l $carveout->(1001), "the mask survives" );
        };

        it "should leave no temporary file behind" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            ea_podman::subids::ensure_user_manager_carveouts( 1001, 1002 );

            opendir my $dh, $ea_podman::subids::dir_unit_carveout or die $!;
            is_deeply( [ sort grep { !/^\./ } readdir $dh ], [ "user\@1001.service", "user\@1002.service" ], "only the two units" );
        };

        it "should die, saying why, when there is no vendor unit to copy" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            local @ea_podman::subids::files_vendor_unit = ("$conf{mock_dir}/vendor/nope");

            eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };

            like( $@, qr/Could not find the vendor user\@\.service/, "names the problem" );
            ok( ea_podman::subids::is_user_session_error($@), "and is shown to the account verbatim like the other session errors" );
        };

        describe "removing the unit" => sub {
            around {
                no warnings qw/once/;
                local $ea_podman::subids::user_manager_is_active = sub { $conf{active} };
                local $ea_podman::subids::user_manager_confirmed_stopped = sub { $conf{active} ? 0 : 1 };

                yield;
            };

            it "should remove it once the manager is down" => sub {
                symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
                ea_podman::subids::ensure_user_manager_carveouts(1001);
                local $conf{active} = 0;

                is( ea_podman::subids::remove_user_manager_carveout(1001), 1, "removed" );
                ok( !-e $carveout->(1001), "and gone" );
                ok( ea_podman::subids::user_manager_mask_file(), "the mask is untouched" );
            };

            it "should leave it alone while the manager is running" => sub {
                symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
                ea_podman::subids::ensure_user_manager_carveouts(1001);
                local $conf{active} = 1;

                is( ea_podman::subids::remove_user_manager_carveout(1001), 0, "not removed" );
                ok( -e $carveout->(1001), "still there: taking it from under a live manager and reloading kills it" );
            };

            it "should not mind there being nothing to remove" => sub {
                local $conf{active} = 0;

                is( ea_podman::subids::remove_user_manager_carveout(1001), 0, "reports nothing done" );
            };

            it "should not reload" => sub {
                symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
                ea_podman::subids::ensure_user_manager_carveouts(1001);
                $mask{reloads} = 0;
                local $conf{active} = 0;

                ea_podman::subids::remove_user_manager_carveout(1001);

                is( $mask{reloads}, 0, "a reload is a chance to hurt another account's manager, and there is nothing to gain" );
            };
        };

        # The two ways a unit file and systemd's idea of it can part company
        # without anyone noticing. (EA4-321)
        describe "what is still owed to systemd" => sub {
            my $written = sub { "$ea_podman::subids::dir_carveout_state/written/$_[0]" };

            around {
                no warnings qw/once redefine/;
                local $conf{active}       = 0;
                local $conf{mock_linger} = "$conf{mock_dir}/linger";
                mkdir $conf{mock_linger};
                local $ea_podman::subids::dir_linger             = $conf{mock_linger};
                local $ea_podman::subids::user_manager_is_active = sub { $conf{active} };
                local $ea_podman::subids::user_manager_confirmed_stopped = sub { $conf{active} ? 0 : 1 };
                local $ea_podman::subids::poll_iterations        = 1;
                local $ea_podman::subids::settle_iterations      = 2;
                local $ea_podman::subids::poll_sleeper           = sub { return };
                local $ea_podman::subids::uid_to_user = sub { return $_[0] == 1001 ? "cptest1" : undef };

                symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

                yield;
            };

            describe "a failed reload" => sub {
                it "should die, saying so, and not report the unit as installed" => sub {
                    local $ea_podman::subids::daemon_reloader = sub { return 0 };

                    eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };

                    like( $@, qr/daemon-reload` failed/, "names the problem" );
                    ok( ea_podman::subids::is_user_session_error($@), "and is shown to the account like the other session errors" );
                };

                it "should reload on the next run even though the file already matches" => sub {
                    {
                        local $ea_podman::subids::daemon_reloader = sub { return 0 };
                        eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };
                    }
                    $mask{reloads} = 0;

                    is( ea_podman::subids::ensure_user_manager_carveouts(1001), 0, "nothing to write this time" );
                    is( $mask{reloads}, 1, "but systemd has still not been told, so it is" );

                    is( ea_podman::subids::ensure_user_manager_carveouts(1001), 0, "nothing to write" );
                    is( $mask{reloads}, 1, "and once it has been told, it is not told again" );
                };

                it "should reload on the next run after a process that died between the rename and the reload" => sub {
                    {
                        local $ea_podman::subids::daemon_reloader = sub { die "killed\n" };
                        eval { ea_podman::subids::ensure_user_manager_carveouts(1001) };
                    }
                    ok( -e $carveout->(1001), "precondition: the unit is on disk" );
                    $mask{reloads} = 0;

                    ea_podman::subids::ensure_user_manager_carveouts(1001);

                    is( $mask{reloads}, 1, "reloaded" );
                };
            };

            describe "a release while the manager is still up" => sub {
                my $release = sub {
                    Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;
                    no warnings qw/once redefine/;
                    local *CORE::GLOBAL::getpwnam = sub { return $_[0] eq "cptest1" ? ( "cptest1", "x", 1001, 1001 ) : () };
                    local $ea_podman::subids::linger_disabler = sub { unlink "$ea_podman::subids::dir_linger/$_[0]"; return 1 };
                    return ea_podman::subids::remove_user_session("cptest1");
                };

                it "should remove the unit straight away when the manager stops in time" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts(1001);
                    my $polls = 0;
                    local $conf{active} = 1;
                    local $ea_podman::subids::poll_sleeper = sub { $conf{active} = 0 if ++$polls == 1 };

                    ok( $release->(), "released" );
                    ok( !-e $carveout->(1001), "the unit is gone" );
                    ok( !-e $written->(1001),  "and so is the record of it" );
                };

                it "should keep the unit, and the record of it, while a login session holds the manager" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts(1001);
                    local $conf{active} = 1;

                    ok( $release->(), "the release itself succeeds: the linger is gone" );
                    ok( -e $carveout->(1001), "the unit is kept under the live manager" );
                    ok( -e $written->(1001),  "and the record that it is ours, which is what a later reconcile goes by" );
                };

                it "should take the unit back once the manager has stopped, with nothing but the ordinary calls" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts(1001);
                    {
                        local $conf{active} = 1;
                        $release->();
                    }
                    $mask{reloads} = 0;

                    {
                        local $conf{active} = 1;
                        is( ea_podman::subids::reconcile_carveouts(), 0, "nothing while the manager is still up" );
                        ok( -e $carveout->(1001), "still there" );
                    }

                    local $conf{active} = 0;
                    is( ea_podman::subids::reconcile_carveouts(), 1, "removed once it is down" );
                    ok( !-e $carveout->(1001), "the unit is gone" );
                    ok( !-e $written->(1001),  "and so is the record" );
                    is( $mask{reloads}, 0, "without a reload" );
                };

                it "should keep the unit when the account has lingered again" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts(1001);
                    {
                        local $conf{active} = 1;
                        $release->();
                    }
                    Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;

                    is( ea_podman::subids::reconcile_carveouts(), 0, "nothing removed" );
                    ok( -e $carveout->(1001), "the unit is wanted again" );
                };

                it "should keep the unit, without a rewrite, when the account is set up again" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts(1001);
                    {
                        local $conf{active} = 1;
                        $release->();
                    }
                    $mask{reloads} = 0;

                    is( ea_podman::subids::ensure_user_manager_carveouts(1001), 0, "the unit it already has is kept as is" );
                    ok( -e $carveout->(1001), "and stays" );
                    is( $mask{reloads}, 0, "with no reload, since nothing changed" );
                };

                it "should take back a unit whose account is gone, or has no linger, whichever way it got there" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts( 1001, 1002 );    # 1002 resolves to no account at all
                    local $conf{active} = 0;

                    is( ea_podman::subids::reconcile_carveouts(), 2, "both taken back: neither has an account that lingers" );
                    ok( !-e $carveout->(1001) && !-e $carveout->(1002), "the units are gone" );
                    ok( !-e $written->(1001) && !-e $written->(1002),   "and the records" );
                };

                it "should drop a record for a unit that is no longer there" => sub {
                    ea_podman::subids::ensure_user_manager_carveouts(1001);
                    unlink $carveout->(1001);

                    is( ea_podman::subids::reconcile_carveouts(), 0, "nothing to remove" );
                    ok( !-e $written->(1001), "the record vouched for nothing, and is gone" );
                };

                describe "a reconcile that was waiting for the lock" => sub {
                    it "should not take a unit whose account was set up again while it waited" => sub {
                        ea_podman::subids::ensure_user_manager_carveouts(1001);
                        {
                            local $conf{active} = 1;
                            $release->();
                        }
                        ok( -e $written->(1001), "precondition: the unit is ours and its account has no linger" );

                        # What happens while the reconcile waits for the lock: a setup
                        # enables the account's linger again. Read under the lock, that
                        # is what it must see.
                        no warnings qw/once redefine/;
                        my $orig = \&ea_podman::subids::_with_carveout_lock;
                        local *ea_podman::subids::_with_carveout_lock = sub {
                            Path::Tiny::path("$conf{mock_linger}/cptest1")->touch;
                            local *ea_podman::subids::_with_carveout_lock = $orig;
                            return $orig->(@_);
                        };
                        local $conf{active} = 0;

                        is( ea_podman::subids::reconcile_carveouts(), 0, "nothing removed" );
                        ok( -e $carveout->(1001), "the unit that setup just wanted again is still there" );
                    };
                };

                describe "a manager that cannot be confirmed stopped" => sub {
                    my $stopped_for = sub {
                        my ($script) = @_;
                        my $bin = "$conf{mock_dir}/fakebin";
                        mkdir $bin;
                        Path::Tiny::path("$bin/systemctl")->spew("#!/bin/sh\n$script\n");
                        chmod 0755, "$bin/systemctl";
                        local $ENV{PATH} = "$bin:$ENV{PATH}";
                        return ea_podman::subids::_user_manager_confirmed_stopped(1001);
                    };

                    it "should count only inactive and failed as stopped" => sub {
                        is( $stopped_for->('echo inactive; exit 3'),     1, "inactive" );
                        is( $stopped_for->('echo failed; exit 3'),       1, "failed" );
                        is( $stopped_for->('echo active; exit 0'),       0, "active" );
                        is( $stopped_for->('echo activating; exit 3'),   0, "activating" );
                        is( $stopped_for->('echo deactivating; exit 3'), 0, "deactivating" );
                        is( $stopped_for->('echo reloading; exit 0'),    0, "reloading" );
                        is( $stopped_for->('echo unknown; exit 4'),      0, "unknown" );
                        is( $stopped_for->('exit 1'),                    0, "a query that failed and said nothing" );
                        is( $stopped_for->('echo "Failed to connect to bus" >&2; exit 1'), 0, "a bus error" );
                    };

                    it "should keep the unit and its record when the query fails" => sub {
                        ea_podman::subids::ensure_user_manager_carveouts(1001);
                        {
                            local $conf{active} = 1;
                            $release->();
                        }
                        no warnings qw/once redefine/;
                        local $ea_podman::subids::user_manager_confirmed_stopped = sub { 0 };

                        is( ea_podman::subids::reconcile_carveouts(),              0, "nothing removed" );
                        is( ea_podman::subids::remove_user_manager_carveout(1001), 0, "and a direct removal refuses too" );
                        ok( -e $carveout->(1001), "the unit is kept" );
                        ok( -e $written->(1001),  "and so is the record, so it is tried again" );

                        local $ea_podman::subids::user_manager_confirmed_stopped = sub { 1 };
                        is( ea_podman::subids::reconcile_carveouts(), 1, "removed once the manager is confirmed stopped" );
                    };
                };
            };

            it "should have nothing to do when nothing is owed" => sub {
                is( ea_podman::subids::reconcile_carveouts(), 0, "no state directory at all" );
            };
        };

        # Before EA4-321 a window was opened and a kill -9 could leave the
        # template unmasked. Nothing writes that record now; a host upgraded
        # mid-window is the one place it is still read.
        describe "an unmask window left open by an older version" => sub {
            it "should give every lingering account its unit, and reload, before the mask goes back" => sub {
                Path::Tiny::path($ea_podman::subids::file_mask_state)->spew("$ea_podman::subids::file_mask_etc\n");
                ok( !ea_podman::subids::user_manager_mask_file(), "precondition: the host is left unmasked" );

                # Two accounts logind started from the unmasked template. Neither is
                # the one being set up now.
                local $ea_podman::subids::dir_linger = "$conf{mock_dir}/linger";
                mkdir $ea_podman::subids::dir_linger;
                Path::Tiny::path("$ea_podman::subids::dir_linger/$_")->touch for qw(cptest2 cptest3);
                no warnings qw/once redefine/;
                local *CORE::GLOBAL::getpwnam = sub { return $_[0] =~ /\Acptest([0-9])\z/ ? ( $_[0], "x", 1000 + $1, 1000 + $1 ) : () };

                # What each reload sees: which units are on disk, and whether the mask is.
                my @seen;
                local $ea_podman::subids::daemon_reloader = sub {
                    push @seen, { units => [ grep { -f $carveout->($_) } 1001 .. 1003 ], masked => ea_podman::subids::user_manager_mask_file() ? 1 : 0 };
                    return 1;
                };

                ea_podman::subids::ensure_user_manager_carveouts(1001);

                is_deeply( $seen[0], { units => [ 1002, 1003 ], masked => 0 }, "the first reload is for the lingering accounts' units, with the template still unmasked" );
                is( $seen[1]{masked}, 1, "the mask goes back, and is reloaded, only after that" );
                is( ea_podman::subids::user_manager_mask_file(), $ea_podman::subids::file_mask_etc, "and is back where it was" );
                ok( -e $carveout->(1001), "the account being set up gets its unit too" );
                ok( !-e $ea_podman::subids::file_mask_state, "with the stale record cleared" );
            };

            it "should put the mask back" => sub {
                Path::Tiny::path($ea_podman::subids::file_mask_state)->spew("$ea_podman::subids::file_mask_etc\n");
                ok( !ea_podman::subids::user_manager_mask_file(), "precondition: the host is left unmasked" );

                ea_podman::subids::ensure_user_manager_carveouts(1001);

                is( ea_podman::subids::user_manager_mask_file(), $ea_podman::subids::file_mask_etc, "back in place where it was" );
                ok( !-e $ea_podman::subids::file_mask_state, "with the stale record cleared" );
                ok( -e $carveout->(1001), "and the account still gets its unit, now that the host is masked again" );
            };

            it "should refuse a state file naming a path we do not manage" => sub {
                Path::Tiny::path($ea_podman::subids::file_mask_state)->spew("$conf{mock_dir}/somewhere-else\n");

                ea_podman::subids::ensure_user_manager_carveouts(1001);

                ok( !-e "$conf{mock_dir}/somewhere-else", "we never create a unit file outside the two mask paths" );
                ok( !-e $ea_podman::subids::file_mask_state, "and the useless record is dropped" );
            };

            it "should read the state file as one line naming the mask" => sub {
                Path::Tiny::path($ea_podman::subids::file_mask_state)->spew("$ea_podman::subids::file_mask_run\n");

                is( ea_podman::subids::_read_mask_state(), $ea_podman::subids::file_mask_run, "just the masked path" );
            };

            it "should keep the record and warn loudly when the mask cannot be put back" => sub {

                # Losing the mask leaves CLOS-4517 off on the host. A regular file where
                # the parent directory would go makes the restore fail even for root.
                Path::Tiny::path("$conf{mock_dir}/in-the-way")->touch;
                local $ea_podman::subids::file_mask_etc = "$conf{mock_dir}/in-the-way/user\@.service";
                Path::Tiny::path($ea_podman::subids::file_mask_state)->spew("$ea_podman::subids::file_mask_etc\n");

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
                ok( -e $ea_podman::subids::file_mask_state, "the record is kept so the next run retries" );
            };
        };
    };

    describe "user@.service mask bypass, in use" => sub {
        our %use;

        around {
            local $conf{mock_dir} = File::Temp->newdir();

            local %use = ( order => [], reloads => 0 );

            mkdir "$conf{mock_dir}/$_" for qw(run linger granted etc vendor);
            Path::Tiny::path("$conf{mock_dir}/vendor/user\@.service")->spew_raw("[Unit]\nDescription=x\n");
            symlink( "/dev/null", "$conf{mock_dir}/etc/user\@.service" );

            no warnings qw/once redefine/;

            local *CORE::GLOBAL::getpwnam = sub {
                return if $_[0] !~ m/\Acptest([0-9])\z/;
                return ( $_[0], "x", 11000 + $1, 11004, 20, "", "", "/home/$_[0]", "/bin/bash" );
            };

            local $ea_podman::subids::dir_run            = "$conf{mock_dir}/run";
            local $ea_podman::subids::dir_linger         = "$conf{mock_dir}/linger";
            local $ea_podman::subids::dir_granted_linger = "$conf{mock_dir}/granted";
            local $ea_podman::subids::file_mask_etc      = "$conf{mock_dir}/etc/user\@.service";
            local $ea_podman::subids::file_mask_run      = "$conf{mock_dir}/etc/never-masked-here";
            local $ea_podman::subids::file_mask_state    = "$conf{mock_dir}/mask.state";
            local $ea_podman::subids::dir_unit_carveout  = "$conf{mock_dir}/units";
            local $ea_podman::subids::dir_carveout_state = "$conf{mock_dir}/state";
            local @ea_podman::subids::files_vendor_unit  = ( "$conf{mock_dir}/vendor/user\@.service" );
            local $ea_podman::subids::poll_iterations    = 1;
            local $ea_podman::subids::poll_sleeper       = sub { return };

            local $ea_podman::subids::daemon_reloader = sub { $use{reloads}++; push @{ $use{order} }, "reload"; return 1 };
            local $ea_podman::subids::linger_enabler  = sub { push @{ $use{order} }, "linger"; return 1 };
            local $ea_podman::subids::user_manager_is_active = sub { $use{active} ? 1 : 0 };
            local $ea_podman::subids::user_manager_confirmed_stopped = sub { $use{active} ? 0 : 1 };
            local $ea_podman::subids::user_manager_starter   = sub {
                my ($uid) = @_;
                push @{ $use{order} }, "start";
                $use{unit_at_start} = -e ea_podman::subids::user_manager_carveout_file($uid) ? 1 : 0;
                mkdir "$ea_podman::subids::dir_run/$uid";
                Path::Tiny::path("$ea_podman::subids::dir_run/$uid/bus")->touch;
                return 1;
            };

            yield;
        };

        it "should have the account's own unit in place, and loaded, before linger is enabled and before the start" => sub {
            ea_podman::subids::ensure_user_session("cptest1");

            is_deeply( $use{order}, [qw(reload linger start)], "unit written and reloaded first, then linger, then the start" );
            is( $use{unit_at_start}, 1, "the unit is on disk when the manager is started" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the template is still masked afterwards" );
        };

        it "should not touch the unit, or reload, for an account that is already healthy and has its unit" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;
            local $use{active} = 1;

            ea_podman::subids::ensure_user_manager_carveout(11001);
            $use{reloads} = 0;
            my $before = Path::Tiny::path( ea_podman::subids::user_manager_carveout_file(11001) )->slurp_raw;

            ea_podman::subids::ensure_user_session("cptest1");

            is( $use{reloads}, 0, "the hot path does no systemd work at all" );
            is( Path::Tiny::path( ea_podman::subids::user_manager_carveout_file(11001) )->slurp_raw, $before, "and writes nothing" );
        };

        it "should give an already-healthy manager that predates its unit one, without starting or stopping it" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;
            local $use{active} = 1;

            ea_podman::subids::ensure_user_session("cptest1");

            is( $use{reloads}, 1, "reloaded once so systemd sees the unit" );
            ok( -f ea_podman::subids::user_manager_carveout_file(11001), "and the running manager now has its unit" );
            is_deeply( $use{order}, [qw(reload)], "nothing was enabled, started or stopped" );
        };

        it "should give the repair path its unit too, since its restart is also a start" => sub {
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            mkdir "$ea_podman::subids::dir_run/11001";    # runtime dir but no bus: the torn-down state
            local $use{active} = 1;
            my @stopped;
            local $ea_podman::subids::user_manager_stopper = sub { push @stopped, $_[0]; $use{active} = 0; return 1 };

            ea_podman::subids::ensure_user_session( "cptest1", may_restart => 1 );

            is_deeply( \@stopped, [11001], "stopped" );
            is( $use{unit_at_start}, 1, "and the unit was in place for the start that followed" );
        };

        it "should take the unit back when the account's linger is removed and its manager is down" => sub {
            ea_podman::subids::ensure_user_manager_carveout(11001);
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            local $ea_podman::subids::linger_disabler = sub { unlink "$ea_podman::subids::dir_linger/$_[0]"; return 1 };
            local $use{active} = 0;

            ok( ea_podman::subids::remove_user_session("cptest1"), "released" );
            ok( !-e ea_podman::subids::user_manager_carveout_file(11001), "and its unit went with it" );
        };

        it "should keep the unit when the manager is somehow still running after the release" => sub {
            ea_podman::subids::ensure_user_manager_carveout(11001);
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch;
            local $ea_podman::subids::linger_disabler = sub { unlink "$ea_podman::subids::dir_linger/$_[0]"; return 1 };
            local $use{active} = 1;

            ea_podman::subids::remove_user_session("cptest1");

            ok( -e ea_podman::subids::user_manager_carveout_file(11001), "it is never taken from under a running manager" );
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
            mkdir "$conf{mock_dir}/vendor";
            Path::Tiny::path("$conf{mock_dir}/vendor/user\@.service")->spew_raw("[Unit]\nDescription=User Manager for UID %i\n");

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
            local $ea_podman::subids::file_mask_state    = "$conf{mock_dir}/mask.state";
            local $ea_podman::subids::dir_unit_carveout  = "$conf{mock_dir}/units";
            local @ea_podman::subids::files_vendor_unit  = ( "$conf{mock_dir}/vendor/user\@.service" );

            local $ea_podman::subids::daemon_reloader = sub { $sweep{reloads}++;                return 1 };
            local $ea_podman::subids::linger_enabler  = sub { push @{ $sweep{enabled} }, $_[0]; return 1 };
            local $ea_podman::subids::uid_to_user     = sub { $_[0] =~ /\A1100([0-9])\z/ ? "cptest$1" : undef };

            # As in the readiness block above: healthy means the manager owns the
            # socket. The stale case -- socket without manager -- is its own test.
            local $ea_podman::subids::user_manager_is_active = sub { -e "$ea_podman::subids::dir_run/$_[0]/bus" ? 1 : 0 };

            # Records whether the account had a unit of its own at the moment of
            # its start, which is how "a unit first" is asserted below.
            local $ea_podman::subids::user_manager_starter = sub {
                my ($uid) = @_;
                push @{ $sweep{started} }, $uid;
                push @{ $sweep{in_window} }, ( -e ea_podman::subids::user_manager_carveout_file($uid) ? 1 : 0 );

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

        it "should give every account its own unit first, with one reload for the whole sweep" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->($_) for qw(cptest1 cptest2 cptest3);

            ea_podman::subids::ensure_user_sessions( "cptest1", "cptest2", "cptest3" );

            is( scalar @{ $sweep{started} }, 3, "all three managers were started" );
            is_deeply( $sweep{in_window}, [ 1, 1, 1 ], "every one of them had its unit before its start" );
            is( $sweep{reloads}, 1, "with one daemon-reload for the sweep, not one per account" );
            ok( ea_podman::subids::user_manager_mask_file(), "and the template was never unmasked" );
        };

        # The whole reason this is not a loop over ensure_user_session(): nesting
        # would drag each account's ~10s poll inside the host-wide unmask.
        it "should poll for the buses with the template still masked" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->("cptest1");

            local $ea_podman::subids::user_manager_starter = sub { push @{ $sweep{started} }, $_[0]; return 1 };
            local $ea_podman::subids::poll_sleeper         = sub {
                $sweep{slept}++;
                push @{ $sweep{in_window} }, ( ea_podman::subids::user_manager_mask_file() ? 1 : 0 );
                return;
            };

            {
                local $SIG{__WARN__} = sub { };    # the stub never produces a bus, so the sweep warns
                ea_podman::subids::ensure_user_sessions("cptest1");
            }

            is( $sweep{slept}, 2, "it polled" );
            is_deeply( $sweep{in_window}, [ 1, 1 ], "and the template was masked the whole time it did" );
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

        it "should start nothing for an account whose manager is already up, but give it its unit" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );

            $lingering->("cptest1");
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;

            my $result = ea_podman::subids::ensure_user_sessions("cptest1");

            is_deeply( $result,         { cptest1 => "ok" }, "reported as already up" );
            is_deeply( $sweep{started}, [],                  "nothing started" );
            is_deeply( $sweep{enabled}, [],                  "no enable-linger" );
            ok( -e ea_podman::subids::user_manager_carveout_file(11001), "a manager logind started has no unit of its own, and needs one before a mask arrives" );
            is( $sweep{reloads}, 1, "one reload to load it" );

            $sweep{reloads} = 0;
            ea_podman::subids::ensure_user_sessions("cptest1");
            is( $sweep{reloads}, 0, "and a second sweep has nothing to do: the boot no-op on a healthy host" );
        };

        it "should not let a failure to write a unit stop the sweep" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            $lingering->("cptest1");
            mkdir "$ea_podman::subids::dir_run/11001";
            Path::Tiny::path("$ea_podman::subids::dir_run/11001/bus")->touch;
            local @ea_podman::subids::files_vendor_unit = ("$conf{mock_dir}/vendor/nope");

            my @warnings;
            my $result;
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                $result = ea_podman::subids::ensure_user_sessions("cptest1");
            }

            is_deeply( $result, { cptest1 => "ok" }, "the healthy account is still reported" );
            like( join( "", @warnings ), qr/could not give the running user systemd managers a unit/, "and the failure is said out loud" );
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

            is_deeply( $sweep{stopped_in_window}, [0], "and the stop happened with the template still masked" );
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

        it "should still start the other accounts when one has an explicit mask of its own" => sub {
            symlink( "/dev/null", $ea_podman::subids::file_mask_etc );
            mkdir $ea_podman::subids::dir_unit_carveout;
            my $masked = ea_podman::subids::user_manager_carveout_file(11001);
            symlink( "/dev/null", $masked );

            $lingering->($_) for qw(cptest1 cptest2);

            my ( $result, @warnings );
            {
                local $SIG{__WARN__} = sub { push @warnings, $_[0] };
                $result = ea_podman::subids::ensure_user_sessions( "cptest1", "cptest2" );
            }

            is_deeply( $sweep{started}, [11002], "only the unmasked account is started" );
            is( $result->{cptest1}, "failed",  "the masked account is reported failed" );
            is( $result->{cptest2}, "started", "and the other one still came up" );
            ok( -l $masked && readlink($masked) eq "/dev/null", "the administrator's mask is untouched" );
            like( join( "", @warnings ), qr/cptest1.*was not written by ea-podman/s, "and the refusal names the account" );
        };

        it "should take back the unit of an account whose enable-linger and start both return false" => sub {
            my $unit = ea_podman::subids::user_manager_carveout_file(11001);

            local $ea_podman::subids::linger_enabler       = sub { return 0 };
            local $ea_podman::subids::user_manager_starter = sub { return 0 };

            my $result;
            {
                local $SIG{__WARN__} = sub { };
                $result = ea_podman::subids::ensure_user_sessions("cptest1");
            }

            is( $result->{cptest1}, "failed", "the account is reported failed" );
            ok( !lstat($unit), "and the unit written for it is taken back, not left as an exception to the mask" );
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

