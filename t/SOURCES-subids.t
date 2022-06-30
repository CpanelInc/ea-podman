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

            yield;
        };

        it "should not call getpwnam when user exists in subids" => sub {
            my $user_name = "cptest1";
            local $getpwnam_called = 0;

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537 ); };

            is( $getpwnam_called, 0 );
        };

        it "should call getpwnam when user does not exist in subids" => sub {
            my $user_name = "cptest9";
            local $getpwnam_called = 0;

            eval { ea_podman::subids::ensure_user_root( $user_name, 65537 ); };

            is( $getpwnam_called, 1 );
        };

        it "should create subdir in /run/user" => sub {
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
    };
};

runtests unless caller;

