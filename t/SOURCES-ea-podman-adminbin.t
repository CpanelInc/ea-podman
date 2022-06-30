#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-ea-podman-adminbin.t          Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

## no critic qw(TestingAndDebugging::RequireUseStrict TestingAndDebugging::RequireUseWarnings)
use Test::Spec;    # automatically turns on strict and warnings

use FindBin;

use Test::MockModule;
use Test::MockFile qw< nostrict >;

my %conf = (
    require => "$FindBin::Bin/../SOURCES/ea-podman-adminbin",
    package => 'bin::admin::Cpanel::ea_podman',
);

require $conf{require};

our @system_cmds;

BEGIN {
    use Test::Mock::Cmd 'system' => sub {
        my (@args) = @_;
        my $str = join( ":", @args );
        push( @system_cmds, $str );
        if ( @args > 0 ) {
            print "{}\n" if ( $args[0] eq "/scripts/cpuser_port_authority" );
        }
        return;
    };
}

$| = 1;

describe "ea-podman-adminbin" => sub {
    describe "_actions" => sub {
        it "should LIST GIVE TAKE ENSURE_USER REGISTER DEREGISTER REGISTERED_CONTAINERS" => sub {
            my @ret = bin::admin::Cpanel::ea_podman::_actions();
            is_deeply \@ret, [qw(LIST GIVE TAKE ENSURE_USER REGISTER DEREGISTER REGISTERED_CONTAINERS)];
        };
    };

    describe "LIST" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $mi{mocks} = {};
            @system_cmds = ();

            $mi{mocks}->{list} = Test::MockModule->new('Capture::Tiny');
            $mi{mocks}->{list}->redefine(
                capture_merged => sub {
                    my ($coderef) = @_;
                    $coderef->();
                }
            );

            # Cannot use Test::MockModule for this one
            local *bin::admin::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                my $self = {};
                return bless {}, $class;
            };

            local *bin::admin::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            # $self->{'_arguments'} = $line1_ar;

            $mi{mocks}->{object} = bin::admin::Cpanel::ea_podman->new();

            yield;
        };

        it "should call port authority" => sub {
            $mi{mocks}->{object}->LIST();

            is_deeply( \@system_cmds, ['/scripts/cpuser_port_authority:list:cptest1'] );
        };
    };

    describe "ENSURE_USER" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $mi{mocks} = {};
            @system_cmds = ();

            $mi{mocks}->{list} = Test::MockModule->new('Capture::Tiny');
            $mi{mocks}->{list}->redefine(
                capture_merged => sub {
                    my ($coderef) = @_;
                    $coderef->();
                }
            );

            # Cannot use Test::MockModule for this one
            local *bin::admin::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                my $self = {};
                return bless {}, $class;
            };

            local *bin::admin::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            # $self->{'_arguments'} = $line1_ar;

            $mi{mocks}->{object} = bin::admin::Cpanel::ea_podman->new();

            yield;
        };

        it "should call ensure_user" => sub {
            my $ensure_user = "";

            no warnings qw(redefine once);

            local *ea_podman::subids::ensure_user_root = sub {
                my ($user) = @_;
                $ensure_user = $user;
                return;
            };

            $mi{mocks}->{object}->ENSURE_USER();

            is( $ensure_user, "cptest1" );
        };
    };

    describe "GIVE" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $mi{mocks} = {};
            @system_cmds = ();

            $mi{mocks}->{list} = Test::MockModule->new('Capture::Tiny');
            $mi{mocks}->{list}->redefine(
                capture_merged => sub {
                    my ($coderef) = @_;
                    $coderef->();
                }
            );

            # Cannot use Test::MockModule for this one
            local *bin::admin::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                my $self = {};
                $self->{_arguments} = [];
                return bless {}, $class;
            };

            local *bin::admin::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = bin::admin::Cpanel::ea_podman->new();

            yield;
        };

        it "should call port authority" => sub {
            $mi{mocks}->{object}->GIVE( 1, "container.cptest1.01" );

            is_deeply(
                \@system_cmds,
                [
                    '/scripts/cpuser_port_authority:list:cptest1',
                    '/scripts/cpuser_port_authority:give:cptest1:1:--service=container.cptest1.01'
                ]
            );
        };

        it "should die if no ports are provided" => sub {
            local $@;
            eval { $mi{mocks}->{object}->GIVE(); };

            ok( $@ =~ m/Must provide a number of ports/ );
        };

        it "should die if more than 100 ports are provided" => sub {
            local $@;
            eval { $mi{mocks}->{object}->GIVE( 102, "container.cptest1.01" ); };

            ok( $@ =~ m/ports must be numeric/ );
        };

        it "should die if no container name is provided" => sub {
            local $@;
            eval { $mi{mocks}->{object}->GIVE(1); };

            ok( $@ =~ m/Invalid container name/ );
        };
    };
};

runtests unless caller;

