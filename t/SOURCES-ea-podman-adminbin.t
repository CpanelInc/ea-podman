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
use File::Temp;

BEGIN {
    # The adminbin loads the *installed* ea-podman libraries when there are
    # any, which are not the copies under test. Load the repo copies and mark
    # the installed paths as already loaded so its requires are no-ops.
    require "$FindBin::Bin/../SOURCES/util.pm";
    require "$FindBin::Bin/../SOURCES/subids.pm";
    $INC{"/opt/cpanel/ea-podman/lib/ea_podman/$_.pm"} = __FILE__ for qw(util subids);
}

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
        it "should LIST GIVE TAKE ENSURE_USER RELEASE_USER REGISTER DEREGISTER REGISTERED_CONTAINERS MINT_API_TOKEN REVOKE_API_TOKEN EXEC_IN_CONTAINER" => sub {
            my @ret = bin::admin::Cpanel::ea_podman::_actions();
            is_deeply \@ret, [qw(LIST GIVE TAKE ENSURE_USER RELEASE_USER REGISTER DEREGISTER REGISTERED_CONTAINERS MINT_API_TOKEN REVOKE_API_TOKEN EXEC_IN_CONTAINER)];
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

        # Only the calling user is ever ensured, and — CPANEL-55309 — the
        # lingering session that comes with it is decided here, root-side, from
        # the registry only root can read.
        my ( $ensured, $granted );
        my $with_registry = sub {
            my ( $containers, $code, %opts ) = @_;

            my $tmp = File::Temp->newdir();

            no warnings qw(redefine once);
            local $ea_podman::util::known_containers_file = "$tmp/registered-containers.json";
            ea_podman::util::register_container_as_root( $_->{name}, $_->{user}, 0, "redis:7", 0 ) for @{$containers};

            # systemd's linger markers, and ea-podman's record of its own grants.
            local $ea_podman::subids::dir_linger        = "$tmp/linger";
            local $ea_podman::subids::dir_granted_linger = "$tmp/granted-linger";
            mkdir $ea_podman::subids::dir_linger;
            mkdir $ea_podman::subids::dir_granted_linger;
            Path::Tiny::path("$ea_podman::subids::dir_linger/cptest1")->touch if $opts{already_lingering};

            $ensured = undef;
            local *ea_podman::subids::ensure_user_root = sub {
                my ( $user, $num_uids, $session ) = @_;
                $ensured = { user => $user, session => $session };

                # The only part of `loginctl enable-linger` the code can see.
                Path::Tiny::path("$ea_podman::subids::dir_linger/$user")->touch if $session;

                return;
            };

            $granted = undef;
            my $rv = $code->();

            # Read the record before the scratch dir goes out of scope.
            $granted = ea_podman::subids::user_has_granted_linger("cptest1");

            return $rv;
        };

        it "should call ensure_user" => sub {
            $with_registry->(
                [ { name => "redis.cptest1.01", user => "cptest1" } ],
                sub { $mi{mocks}->{object}->ENSURE_USER() }
            );

            is( $ensured->{user}, "cptest1" );
        };

        it "should give a session to an account that has containers" => sub {
            my $rv = $with_registry->(
                [ { name => "redis.cptest1.01", user => "cptest1" } ],
                sub { $mi{mocks}->{object}->ENSURE_USER() }
            );

            is( $ensured->{session}, 1, "the session is ensured" );
            is( $rv,                 1, "and the caller is told there is one" );
        };

        it "should NOT give a session to an account with no containers" => sub {
            my $rv = $with_registry->(
                [ { name => "redis.someoneelse.01", user => "someoneelse" } ],
                sub { $mi{mocks}->{object}->ENSURE_USER() }
            );

            is( $ensured->{user},    "cptest1", "the subids are still set up" );
            is( $ensured->{session}, 0,         "but no linger for an account with nothing to keep running" );
            is( $rv,                 0,         "and the caller is told there is no session" );
        };

        it "should give a session to an account installing its first container" => sub {
            my $rv = $with_registry->(
                [],
                sub { $mi{mocks}->{object}->ENSURE_USER(1) }
            );

            is( $ensured->{session}, 1, "an install says so and gets one" );
            is( $rv,                 1 );
        };

        # The only linger ea-podman ever turns back off, so this is where it is
        # recorded as ours.
        it "should record the grant when this call turns the linger on" => sub {
            my $rv = $with_registry->(
                [],
                sub { $mi{mocks}->{object}->ENSURE_USER(1) }
            );

            is( $ensured->{session}, 1, "the session is established" );
            is( $rv,                 1 );
            ok( $granted, "and it is recorded as ea-podman's to give back" );
        };

        it "should NOT record a grant for an account that was already lingering" => sub {
            $with_registry->(
                [],
                sub { $mi{mocks}->{object}->ENSURE_USER(1) },
                already_lingering => 1,
            );

            ok( !$granted, "that linger belongs to whoever enabled it, not to us" );
        };

        it "should NOT record a grant when no session was established at all" => sub {
            my $rv = $with_registry->(
                [],
                sub { $mi{mocks}->{object}->ENSURE_USER(0) }
            );

            is( $rv, 0, "no containers and not creating one ➜ no session" );
            ok( !$granted, "so there is no linger to record" );
        };
    };

    describe "RELEASE_USER" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $mi{mocks} = {};

            # Cannot use Test::MockModule for this one
            local *bin::admin::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                return bless {}, $class;
            };

            local *bin::admin::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = bin::admin::Cpanel::ea_podman->new();

            yield;
        };

        it "should only ever release the calling user" => sub {
            my $released_user = "";

            no warnings qw(redefine once);

            local *ea_podman::util::release_user_session_as_root = sub {
                my ($user) = @_;
                $released_user = $user;
                return 1;
            };

            my $rv = $mi{mocks}->{object}->RELEASE_USER();

            is( $released_user, "cptest1" );
            is( $rv,            1 );
        };

        it "should report when there was nothing to release" => sub {
            no warnings qw(redefine once);

            local *ea_podman::util::release_user_session_as_root = sub { return 0; };

            is( $mi{mocks}->{object}->RELEASE_USER(), 0 );
        };

        it "should die with an admin error when the release blows up" => sub {
            no warnings qw(redefine once);

            local *ea_podman::util::release_user_session_as_root = sub { die "nope\n"; };

            local $@;
            eval { $mi{mocks}->{object}->RELEASE_USER(); };

            ok( $@ =~ m/Unable to release the user session/ );
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

    describe "DEREGISTER" => sub {
        share my %mi;
        around {
            %mi = %conf;

            # Cannot use Test::MockModule for this one
            local *bin::admin::Cpanel::ea_podman::new = sub {
                my ($class) = @_;
                return bless {}, $class;
            };

            local *bin::admin::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = bin::admin::Cpanel::ea_podman->new();

            yield;
        };

        it "should deregister the caller's own container" => sub {
            no warnings qw(redefine once);

            local *ea_podman::util::load_known_containers_as_root = sub {
                return { 'container.cptest1.01' => { user => 'cptest1' } };
            };

            my @deregistered;
            local *ea_podman::util::deregister_container_as_root = sub {
                push @deregistered, [@_];
                return 1;
            };

            my $ret = $mi{mocks}->{object}->DEREGISTER('container.cptest1.01');

            is( $ret, 1 );
            is_deeply( \@deregistered, [ [ 'container.cptest1.01', 'cptest1' ] ] );
        };

        # CPANEL-55337: DEREGISTER resolved the caller but never checked that
        # the named container actually belonged to them, so any account could
        # deregister any other account's (guessably-named) container.
        it "should die on another account's container instead of deregistering it" => sub {
            no warnings qw(redefine once);

            local *ea_podman::util::load_known_containers_as_root = sub {
                return { 'container.otheruser.01' => { user => 'otheruser' } };
            };

            my @deregistered;
            local *ea_podman::util::deregister_container_as_root = sub {
                push @deregistered, [@_];
                return 1;
            };

            local $@;
            eval { $mi{mocks}->{object}->DEREGISTER('container.otheruser.01'); };

            ok( $@ =~ m/No such container for this account/ );
            is_deeply( \@deregistered, [], "the other account's container was never touched" );
        };

        it "should die on an unregistered container name" => sub {
            no warnings qw(redefine once);

            local *ea_podman::util::load_known_containers_as_root = sub {
                return {};
            };

            local $@;
            eval { $mi{mocks}->{object}->DEREGISTER('never-registered.cptest1.01'); };

            ok( $@ =~ m/No such container for this account/ );
        };

        it "should die if no container name is provided" => sub {
            local $@;
            eval { $mi{mocks}->{object}->DEREGISTER(); };

            ok( $@ =~ m/Must provide a container name/ );
        };
    };
};

runtests unless caller;

