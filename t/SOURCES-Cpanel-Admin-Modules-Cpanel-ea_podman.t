#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

## no critic qw(TestingAndDebugging::RequireUseStrict TestingAndDebugging::RequireUseWarnings)
use Test::Spec;    # automatically turns on strict and warnings

use FindBin;

use Test::MockModule;
use Test::MockFile qw< nostrict >;
use File::Temp;

BEGIN {
    # The admin module loads the *installed* ea-podman libraries when there
    # are any, which are not the copies under test. Load the repo copies and mark
    # the installed paths as already loaded so its requires are no-ops.
    require "$FindBin::Bin/../SOURCES/util.pm";
    require "$FindBin::Bin/../SOURCES/subids.pm";
    $INC{"/opt/cpanel/ea-podman/lib/ea_podman/$_.pm"} = __FILE__ for qw(util subids);
}

my %conf = (
    require => "$FindBin::Bin/../SOURCES/Cpanel-Admin-Modules-Cpanel-ea_podman.pm",
    package => 'Cpanel::Admin::Modules::Cpanel::ea_podman',
);

use lib '/usr/local/cpanel';
require $conf{require};

# Cpanel::Admin::Base::cpuser_has_feature() reads the account's cpuser file and
# feature list; the tests decide the answer instead.
our $HAS_FEATURE = 1;
our @FEATURE_CHECKS;
{
    no warnings qw(redefine once);
    *Cpanel::Admin::Modules::Cpanel::ea_podman::cpuser_has_feature = sub {
        my ( $self, $feature ) = @_;
        push @FEATURE_CHECKS, $feature;
        return $HAS_FEATURE;
    };
}

our @system_cmds;
our $list_json = "{}\n";    # what a mocked `cpuser_port_authority list` prints
our $take_rv;               # what a mocked `cpuser_port_authority take` returns (nonzero == it failed)

BEGIN {
    use Test::Mock::Cmd 'system' => sub {
        my (@args) = @_;
        my $str = join( ":", @args );
        push( @system_cmds, $str );
        if ( @args > 0 ) {
            print $list_json if ( $args[0] eq "/scripts/cpuser_port_authority" && ( $args[1] // "" ) eq "list" );
            return $take_rv if ( $args[0] eq "/scripts/cpuser_port_authority" && ( $args[1] // "" ) eq "take" );
        }
        return;
    };
}

$| = 1;

describe "Cpanel::Admin::Modules::Cpanel::ea_podman" => sub {
    describe "_actions" => sub {
        it "should keep every legacy action but the API-token pair, in order, then the lifecycle actions" => sub {
            my @ret = Cpanel::Admin::Modules::Cpanel::ea_podman::_actions();
            is_deeply \@ret, [
                qw(LIST GIVE TAKE ENSURE_USER RELEASE_USER REGISTER DEREGISTER REGISTERED_CONTAINERS EXEC_IN_CONTAINER),
                qw(LIST_CONTAINERS INSTALL UPGRADE UNINSTALL START STOP RESTART STATUS CMD),
            ];
        };

        # With _allowed_parents at '*', MINT_API_TOKEN would hand a full-access
        # API token to any process the account owns. (EA4-314)
        it "should not offer the API-token actions" => sub {
            my %actions = map { $_ => 1 } Cpanel::Admin::Modules::Cpanel::ea_podman::_actions();
            for my $action (qw(MINT_API_TOKEN REVOKE_API_TOKEN)) {
                ok( !$actions{$action},                                       "$action is not an action" );
                ok( !Cpanel::Admin::Modules::Cpanel::ea_podman->can($action), '... and is not defined' );
            }
        };
    };

    describe "LIST" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $mi{mocks} = {};
            @system_cmds = ();

            # Cannot use Test::MockModule for this one
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                my $self = {};
                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            # $self->{'_arguments'} = $line1_ar;

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

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

            # Cannot use Test::MockModule for this one
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                my $self = {};
                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            # $self->{'_arguments'} = $line1_ar;

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

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
            local $ea_podman::subids::dir_linger         = "$tmp/linger";
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
            is( $rv, 1 );
        };

        # The only linger ea-podman ever turns back off, so this is where it is
        # recorded as ours.
        it "should record the grant when this call turns the linger on" => sub {
            my $rv = $with_registry->(
                [],
                sub { $mi{mocks}->{object}->ENSURE_USER(1) }
            );

            is( $ensured->{session}, 1, "the session is established" );
            is( $rv, 1 );
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
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

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

            # Cannot use Test::MockModule for this one
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;

                my $self = {};
                $self->{_arguments} = [];
                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

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

        it "should refuse ports for a container named for another account" => sub {
            local $@;
            eval { $mi{mocks}->{object}->GIVE( 1, "container.cptest2.01" ); };

            ok( $@ =~ m/does not belong to this account/ );
            is_deeply( \@system_cmds, ['/scripts/cpuser_port_authority:list:cptest1'], 'and gives nothing' );
        };
    };

    describe "TAKE" => sub {
        share my %mi;
        around {
            %mi = %conf;

            local $mi{mocks} = {};
            @system_cmds = ();
            local $list_json = qq({"10000":{"owner":"cptest1","service":"container.cptest1.01"},"10001":{"owner":"cptest1","service":"other.cptest1.01"}}\n);
            local $take_rv;

            # Cannot use Test::MockModule for this one
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;
                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

            yield;
        };

        it "should take only the ports assigned to the container" => sub {
            $mi{mocks}->{object}->TAKE("container.cptest1.01");

            is_deeply(
                \@system_cmds,
                [
                    '/scripts/cpuser_port_authority:list:cptest1',
                    '/scripts/cpuser_port_authority:take:cptest1:10000',
                ]
            );
        };

        # `take` dies on an empty list, so asking it to would turn "nothing to release" into a failure
        it "should not call take when the container has no ports" => sub {
            local $list_json = "{}\n";

            local $@;
            eval { $mi{mocks}->{object}->TAKE("container.cptest1.01") };

            is( $@, "" );
            is_deeply( \@system_cmds, ['/scripts/cpuser_port_authority:list:cptest1'] );
        };

        # CPANEL-57608: a failed take used to be indistinguishable from a good one,
        # so a failed install kept its ports and nothing said so
        it "should die when the port authority fails to take the ports" => sub {
            local $take_rv = 256;

            local $@;
            eval { $mi{mocks}->{object}->TAKE("container.cptest1.01") };

            ok( $@ =~ m/cpuser_port_authority take. failed/ );
        };
    };

    describe "DEREGISTER" => sub {
        share my %mi;
        around {
            %mi = %conf;

            # Cannot use Test::MockModule for this one
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;
                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

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

    describe "REGISTER" => sub {
        share my %mi;
        around {
            %mi = %conf;

            # Cannot use Test::MockModule for this one
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::new = sub {
                my ($class) = @_;
                return bless {}, $class;
            };

            local *Cpanel::Admin::Modules::Cpanel::ea_podman::get_caller_username = sub {
                return 'cptest1';
            };

            $mi{mocks}->{object} = Cpanel::Admin::Modules::Cpanel::ea_podman->new();

            yield;
        };

        it "should register a container in the caller’s own namespace" => sub {
            no warnings qw(redefine once);

            my @registered;
            local *ea_podman::util::register_container_as_root = sub {
                push @registered, [@_];
                return 1;
            };

            my $ret = $mi{mocks}->{object}->REGISTER( 'container.cptest1.01', 0, 'redis:7', 0 );

            is( $ret, 1 );
            is_deeply( \@registered, [ [ 'container.cptest1.01', 'cptest1', 0, 'redis:7', 0 ] ] );
        };

        it "should die on another account’s container instead of taking it over" => sub {
            no warnings qw(redefine once);

            my @registered;
            local *ea_podman::util::register_container_as_root = sub {
                push @registered, [@_];
                return 1;
            };

            local $@;
            eval { $mi{mocks}->{object}->REGISTER( 'container.otheruser.01', 1, 'redis:7', 0 ); };

            ok( $@ =~ m/does not belong to this account/ );
            is_deeply( \@registered, [], "the other account’s entry was never touched" );
        };

        it "should die on an unused name in another account’s namespace" => sub {
            no warnings qw(redefine once);

            my @registered;
            local *ea_podman::util::register_container_as_root = sub {
                push @registered, [@_];
                return 1;
            };

            local $@;
            eval { $mi{mocks}->{object}->REGISTER( 'never-registered.otheruser.42', 0, 'redis:7', 0 ); };

            ok( $@ =~ m/does not belong to this account/ );
            is_deeply( \@registered, [], "no squatting in another account’s namespace" );
        };

        it "should not be fooled by a name that merely contains the caller’s name" => sub {
            no warnings qw(redefine once);

            my @registered;
            local *ea_podman::util::register_container_as_root = sub {
                push @registered, [@_];
                return 1;
            };

            local $@;
            eval { $mi{mocks}->{object}->REGISTER( 'cptest1.otheruser.01', 1, 'redis:7', 0 ); };

            ok( $@ =~ m/does not belong to this account/ );
            is_deeply( \@registered, [] );
        };

        it "should die if no container name is provided" => sub {
            local $@;
            eval { $mi{mocks}->{object}->REGISTER(); };

            ok( $@ =~ m/Must provide a container name/ );
        };
    };

    describe "contract" => sub {
        it "should allow a demo account no action" => sub {
            is_deeply [ Cpanel::Admin::Modules::Cpanel::ea_podman->_demo_actions() ], [];
        };

        it "should accept every caller, since the CLI is no longer compiled" => sub {
            is( Cpanel::Admin::Modules::Cpanel::ea_podman->_allowed_parents(), '*' );
        };

        it "should keep the legacy bin's 120s alarm for the legacy actions" => sub {
            is( _obj_for('GIVE')->_alarm(), 120 );
        };

        it "should give image pulls a long alarm" => sub {
            is( _obj_for($_)->_alarm(), 1800, $_ ) for qw(INSTALL UPGRADE);
        };

        it "should give the other lifecycle actions the in-process default" => sub {
            is( _obj_for($_)->_alarm(), 350, $_ ) for qw(START STOP RESTART STATUS UNINSTALL CMD);
        };

        it "should report a failure the user can act on as an AdminError, with its text" => sub {
            local $@;
            eval { _obj_for('GIVE')->GIVE( 1, 'not a container name' ) };
            my $err = $@;
            ok( eval { $err->isa('Cpanel::Exception::AdminError') }, 'AdminError, so cpsrvd passes the text back' );
            like( _msg($err), qr/^Invalid container name$/, 'the same text the legacy bin gave' );
        };
    };

    describe "feature gate" => sub {
        around {
            local $HAS_FEATURE    = 0;
            local @FEATURE_CHECKS = ();
            local @system_cmds    = ();

            local *ea_podman::util::load_known_containers_as_root = sub {
                return { 'container.cptest1.01' => { container_name => 'container.cptest1.01', user => 'cptest1' } };
            };
            local *ea_podman::util::user_has_containers_as_root          = sub { return 1 };
            local *ea_podman::util::release_user_session_as_root         = sub { return 0 };
            local *ea_podman::util::deregister_container_as_root         = sub { return 1 };
            local *ea_podman::util::register_container_as_root           = sub { return 1 };
            local *ea_podman::subids::ensure_user_root                   = sub { return 1 };
            local *ea_podman::subids::user_has_linger                    = sub { return 1 };
            local *Cpanel::Admin::Modules::Cpanel::ea_podman::_as_cpuser = sub { return 'ran as the cpuser' };

            yield;
        };

        my @gated = (
            [ GIVE              => 1, 'container.cptest1.01' ],
            [ REGISTER          => 'container.cptest1.01' ],
            [ ENSURE_USER       => 1 ],
            [ EXEC_IN_CONTAINER => 'container.cptest1.01', '', 'true' ],
            [ INSTALL           => { name           => 'ea-memcached16' } ],
            [ UPGRADE           => { container_name => 'container.cptest1.01' } ],
            [ START             => { container_name => 'container.cptest1.01' } ],
            [ RESTART           => { container_name => 'container.cptest1.01' } ],
            [ CMD               => { container_name => 'container.cptest1.01', arg => ['true'] } ],
        );

        for my $case (@gated) {
            my ( $action, @args ) = @{$case};
            it "should refuse $action without the ea_podman feature, before doing anything" => sub {
                local $@;
                my $ok  = eval { _obj_for($action)->$action(@args); 1 };
                my $err = $@;
                ok( !$ok, "$action died" );
                like( _msg($err), qr/must enable the .*feature/, 'with the feature message' );
                is_deeply( \@FEATURE_CHECKS, ['ea_podman'], 'after checking the ea_podman feature' );
                is_deeply( \@system_cmds,    [],            'and ran nothing' );
            };
        }

        # Cleanup and read-own-state: an account whose feature is turned off
        # must still see and remove what it has.
        my @carve_outs = (
            [ LIST                  => () ],
            [ TAKE                  => 'container.cptest1.01' ],
            [ ENSURE_USER           => 0 ],
            [ RELEASE_USER          => () ],
            [ DEREGISTER            => 'container.cptest1.01' ],
            [ REGISTERED_CONTAINERS => () ],
            [ LIST_CONTAINERS       => () ],
            [ UNINSTALL             => { container_name => 'container.cptest1.01' } ],
            [ STOP                  => { container_name => 'container.cptest1.01' } ],
            [ STATUS                => { container_name => 'container.cptest1.01' } ],
        );

        for my $case (@carve_outs) {
            my ( $action, @args ) = @{$case};
            it "should let $action through without the ea_podman feature" => sub {
                local $@;
                my $ok = eval { _obj_for($action)->$action(@args); 1 };
                ok( $ok, "$action succeeded" ) or diag $@;
                is_deeply( \@FEATURE_CHECKS, [], 'without consulting the feature' );
            };
        }
    };

    describe "lifecycle actions" => sub {
        share my %mi;
        around {
            local $HAS_FEATURE = 1;
            %mi = ( calls => [] );

            local *ea_podman::util::load_known_containers_as_root = sub {
                return {
                    'container.cptest1.01' => { container_name => 'container.cptest1.01', user => 'cptest1' },
                    'container.other.01'   => { container_name => 'container.other.01',   user => 'other' },
                };
            };

            my @verbs = qw(api_install api_upgrade api_uninstall api_lifecycle api_status api_cmd);
            my %orig;
            {
                no strict 'refs';
                no warnings 'redefine';
                for my $verb (@verbs) {
                    $orig{$verb} = \&{"ea_podman::util::$verb"};
                    *{"ea_podman::util::$verb"} = sub { push @{ $mi{calls} }, [ $verb, @_ ]; return $mi{return}{$verb} // 1 };
                }
            }

            $mi{accessids} = Test::MockModule->new('Cpanel::AccessIds');
            $mi{accessids}->redefine(
                do_as_user_with_exception => sub {
                    my ( $user, $code ) = @_;
                    $mi{dropped_to} = $user;
                    return $code->();
                }
            );

            yield;

            {
                no strict 'refs';
                no warnings 'redefine';
                *{"ea_podman::util::$_"} = $orig{$_} for @verbs;
            }
        };

        it "should run INSTALL as the cpuser with the UAPI's parameters" => sub {
            $mi{return}{api_install} = { container_name => 'ea-memcached16.cptest1.01' };
            my $got = _obj_for('INSTALL')->INSTALL( { name => 'ea-memcached16', cpuser_port => [ 0, '' ], env => 'A=1', accept_arbitrary_image_risk => 'yes' } );

            is_deeply( $got, { container_name => 'ea-memcached16.cptest1.01' }, 'returns what the UAPI verb returns' );
            is( $mi{dropped_to}, 'cptest1', 'fully dropped to the calling account' );
            my ( undef, %passed ) = @{ $mi{calls}[0] };
            is_deeply(
                \%passed,
                { name => 'ea-memcached16', image => undef, cpuser_port => [0], env => ['A=1'], accept_arbitrary_image_risk => 1 },
                'with the UAPI parameter names, empty repeats dropped'
            );
        };

        it "should give the child the cpuser's HOME, USER and LOGNAME" => sub {
            my %seen;
            no warnings 'redefine';
            local *ea_podman::util::api_status = sub {
                %seen = map { $_ => $ENV{$_} } qw(HOME USER LOGNAME);
                return {};
            };
            _obj_for('STATUS')->STATUS( { container_name => 'container.cptest1.01' } );
            is_deeply( \%seen, { HOME => '/home/cptest1', USER => 'cptest1', LOGNAME => 'cptest1' } );
        };

        it "should refuse INSTALL arguments that are not a hash" => sub {
            local $@;
            eval { _obj_for('INSTALL')->INSTALL('ea-memcached16') };
            like( _msg($@), qr/must be given as a hash/ );
            is_deeply( $mi{calls}, [], 'without running anything' );
        };

        it "should refuse an INSTALL name that is not a string" => sub {
            local $@;
            eval { _obj_for('INSTALL')->INSTALL( { name => ['x'] } ) };
            like( _msg($@), qr/“name” must be a string/ );
        };

        for my $action (qw(UPGRADE UNINSTALL CMD START STOP RESTART STATUS)) {
            it "should refuse $action on another account's container" => sub {
                local $@;
                eval { _obj_for($action)->$action( { container_name => 'container.other.01', arg => ['true'] } ) };
                like( _msg($@), qr/^No such container for this account$/ );
                is_deeply( $mi{calls}, [], 'without running anything' );
            };

            it "should refuse $action on a malformed name" => sub {
                local $@;
                eval { _obj_for($action)->$action( { container_name => 'x; rm -rf /', arg => ['true'] } ) };
                like( _msg($@), qr/^Invalid container name$/ );
                is_deeply( $mi{calls}, [], 'without running anything' );
            };
        }

        for my $action (qw(UPGRADE UNINSTALL CMD)) {
            it "should refuse $action on an unregistered container named for the account" => sub {
                local $@;
                eval { _obj_for($action)->$action( { container_name => 'ghost.cptest1.02', arg => ['true'] } ) };
                like( _msg($@), qr/^No such container for this account$/ );
            };
        }

        it "should pass UPGRADE's force through to api_upgrade" => sub {
            _obj_for('UPGRADE')->UPGRADE( { container_name => 'container.cptest1.01' } );
            _obj_for('UPGRADE')->UPGRADE( { container_name => 'container.cptest1.01', force => 1 } );
            is_deeply(
                $mi{calls},
                [
                    [ 'api_upgrade', 'container.cptest1.01', force => 0 ],
                    [ 'api_upgrade', 'container.cptest1.01', force => 1 ],
                ]
            );
        };

        it "should map START/STOP/RESTART onto api_lifecycle" => sub {
            _obj_for($_)->$_( { container_name => 'container.cptest1.01' } ) for qw(START STOP RESTART);
            is_deeply( [ map { $_->[2] } @{ $mi{calls} } ], [qw(start stop restart)] );
        };

        it "should keep empty argv elements for CMD and pass cd through" => sub {
            _obj_for('CMD')->CMD( { container_name => 'container.cptest1.01', arg => [ 'printf', '' ], cd => '/data' } );
            is_deeply( $mi{calls}[0], [ 'api_cmd', 'container.cptest1.01', [ 'printf', '' ], '/data' ] );
        };

        it "should refuse CMD without a command" => sub {
            local $@;
            eval { _obj_for('CMD')->CMD( { container_name => 'container.cptest1.01' } ) };
            like( _msg($@), qr/requires a command/ );
        };

        it "should pass what the child throws back to the caller as the same text" => sub {
            no warnings 'redefine';
            local *ea_podman::util::api_upgrade = sub { die "Failed to pull image\npodman said no\n" };
            local $@;
            eval { _obj_for('UPGRADE')->UPGRADE( { container_name => 'container.cptest1.01' } ) };
            my $err = $@;
            ok( eval { $err->isa('Cpanel::Exception::AdminError') }, 'as an AdminError' );
            is( _msg($err), "Failed to pull image\npodman said no" );
        };

        it "should list only the caller's containers, keyed by name, as the UAPI does" => sub {
            is_deeply(
                _obj_for('LIST_CONTAINERS')->LIST_CONTAINERS(),
                { 'container.cptest1.01' => { container_name => 'container.cptest1.01', user => 'cptest1' } },
            );
        };
    };
};

# An object as cpsrvd's Cpanel::Admin::Base::run() builds it for $action,
# called by cptest1.
sub _obj_for {
    my ($action) = @_;
    return bless { function => $action, caller => { _uid => 12345, _username => 'cptest1', _homedir => '/home/cptest1' } }, 'Cpanel::Admin::Modules::Cpanel::ea_podman';
}

# The text an AdminError carries back to the caller.
sub _msg {
    my ($err) = @_;
    my $msg = eval { $err->get('message') };
    return $msg // "$err";
}

runtests unless caller;
