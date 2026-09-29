#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-create-failure-output.t   Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use File::Temp ();
use FindBin;

our $HOMEDIR;

BEGIN {
    *CORE::GLOBAL::getpwuid = sub {
        my ($uid) = @_;
        return ( "bob", "x", $uid, $uid, "", "", "", $main::HOMEDIR, "/bin/bash" );
    };
}

require "$FindBin::Bin/../SOURCES/util.pm";

# EA4-335. A failed `podman create` used to die with a bare "Failed to create
# container": podman() is a plain system() call, so what podman said went to the
# inherited STDERR and was never seen by anything that runs ea-podman without a
# terminal (the web app plugin, the EAPodman UAPI, the adminbin). The real cause,
# such as a disk quota hit while unpacking an image layer, was only in journalctl.

no warnings 'once';

my $QUOTA = 'Error: unable to copy from source docker://node:22: copying system image from manifest list: '
  . 'writing blob: adding layer with blob "sha256:abc": unpacking failed (error: exit status 1; output: '
  . 'write /usr/lib/x86_64-linux-gnu/libicudata.so.72.1: disk quota exceeded)';

sub _world {
    my $tmp = File::Temp->newdir();
    $main::HOMEDIR = "$tmp";

    my $name = "myapp.bob.01";
    my $dir  = "$tmp/ea-podman.d/$name";
    mkdir "$tmp/ea-podman.d";
    mkdir $dir;

    open( my $fh, ">", "$dir/ea-podman.json" ) or die $!;
    print {$fh} qq({"start_args":["docker.io/library/httpd:2.4"],"ports":["80"]});
    close $fh;

    return ( $tmp, $name, $dir );
}

# Everything _ensure_latest_container() touches that needs podman, systemd, the
# adminbin or the registry. create_user_container is replaced by a sequence of
# [ ok, what-podman-said ] pairs, and records the text the way the real one does.
sub _harness {
    my (%opts) = @_;

    my %log = ( created => [] );

    no warnings 'redefine';
    *ea_podman::util::warn_if_problematic_cgroup         = sub { 1 };
    *ea_podman::util::ensure_container_session           = sub { 1 };
    *ea_podman::util::_ensure_backup_conf_excludes_files = sub { 1 };
    *ea_podman::util::_arbitrary_image_warning           = sub { 1 };
    *ea_podman::util::_get_container_root                = sub { "$main::HOMEDIR/ea-podman.d" };
    *ea_podman::util::_get_current_ports                 = sub { return (10000) };
    *ea_podman::util::_get_new_ports                     = sub { return (10000) };
    *ea_podman::util::validate_start_args                = sub { 1 };
    *ea_podman::util::uninstall_container                = sub { 1 };
    *ea_podman::util::remove_user_container              = sub { 1 };
    *ea_podman::util::register_container                 = sub { 1 };
    *ea_podman::util::deregister_container               = sub { 1 };
    *ea_podman::util::generate_container_service         = sub { 1 };
    *ea_podman::util::reset_container_unit_failure       = sub { 1 };
    *ea_podman::util::sysctl                             = sub { 1 };
    *ea_podman::util::_get_container_image_ref           = sub { "docker.io/library/httpd:2.3" };
    *ea_podman::util::_podman_pull                       = sub { 1 };
    *ea_podman::util::_get_image_id                      = sub { "sha-new" };
    *ea_podman::util::_get_container_image_id            = sub { "sha-old" };

    my @results = @{ $opts{creates} };
    *ea_podman::util::create_user_container = sub {
        my ( $n, @args ) = @_;
        push @{ $log{created} }, [@args];
        my ( $ok, $said ) = @{ shift(@results) // [ 0, undef ] };
        $ea_podman::util::_create_output = $ok ? undef : $said;
        return $ok;
    };

    return \%log;
}

sub _fails {
    my ( $name, $op, @extra ) = @_;
    return do { local $@; eval { ea_podman::util::_ensure_latest_container( $name, { op => $op }, @extra ) }; $@ };
}

# A stand-in `podman` first in PATH, so the real fork, pipe and exec are what is
# tested -- not a mock of the sub under test.
sub _fake_podman {
    my ($body) = @_;
    my $dir = File::Temp->newdir();
    open( my $fh, ">", "$dir/podman" ) or die $!;
    print {$fh} "#!/bin/sh\n$body\n";
    close $fh;
    chmod 0755, "$dir/podman";
    return $dir;
}

# Run $code with STDERR pointed at a file, returning what was echoed to it.
sub _stderr_of {
    my ($code) = @_;
    my $tmp = File::Temp->new();
    open( my $save, ">&", \*STDERR ) or die $!;
    open( STDERR, ">", $tmp->filename ) or die $!;
    my @r = $code->();
    open( STDERR, ">&", $save ) or die $!;
    open( my $in, "<", $tmp->filename ) or die $!;
    local $/;
    return ( scalar(<$in>), @r );
}

subtest 'the capture seam returns what podman said and whether it worked' => sub {
    my $bin = _fake_podman('echo "to stdout"; echo "to stderr" >&2; exit 1');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my ( $echoed, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured( "create", "--name", "x" ) } );

    ok( !$ok, "the failure is reported" );
    like( $said, qr/to stdout/, "stdout is captured" );
    like( $said, qr/to stderr/, "and so is stderr" );
    like( $echoed, qr/to stdout.*to stderr|to stderr.*to stdout/s, "and both are still shown to whoever is watching" );
};

subtest 'the capture seam passes podman its arguments and reports success' => sub {
    my $bin = _fake_podman('echo "args: $*"; exit 0');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my ( undef, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured( "create", "--name", "x y", "img" ) } );

    ok( $ok, "success is reported as true" );
    like( $said, qr/args: create --name x y img/, "the arguments arrive intact" );
};

subtest 'the capture seam never loses the create when podman cannot be run' => sub {
    my $empty = File::Temp->newdir();
    local $ENV{PATH} = "$empty";

    my ( undef, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured( "create", "x" ) } );

    ok( !$ok, "a missing podman is a failure, not a hang or a crash" );
    like( $said, qr/Can't exec "podman"/, "and the reason it could not run is what gets reported" );
};

subtest 'a very chatty podman is not held in memory whole' => sub {
    my $bin = _fake_podman('i=0; while [ $i -lt 4000 ]; do echo "layer $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done; echo "the end" >&2; exit 1');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my ( undef, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured("create") } );

    ok( !$ok, "still a failure" );
    like( $said, qr/the end\s*\z/, "the end of the output is kept" );
    cmp_ok( length $said, '<=', 131072, "and it is bounded" );
};

# EA4-335, review follow-up. system() ignored INT and QUIT in the parent while its
# child ran; the fork/exec that replaced it did not, so Ctrl-C ended ea-podman
# before it could clean up. TERM and HUP are forwarded to podman and waited on.
# A sibling process delivers the signal to this one, mid-create.
sub _signal_me_after {
    my ( $delay, @sigs ) = @_;
    my $me  = $$;
    my $kid = fork() // die $!;
    if ( !$kid ) {
        select( undef, undef, undef, $delay );
        kill( $_, $me ) for @sigs;
        POSIX::_exit(0);    # not exit(): no Test::More END block in the helper
    }
    return $kid;
}

subtest 'Ctrl-C at ea-podman does not end it while podman runs' => sub {
    require POSIX;
    my $bin = _fake_podman('sleep 1; echo finished; exit 0');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $kid = _signal_me_after( 0.3, 'INT', 'QUIT' );
    my ( undef, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured("create") } );
    waitpid( $kid, 0 );

    ok( $ok, "still here, and podman's own outcome is what is reported" );
    like( $said, qr/finished/, "podman was left to finish" );
    unlike( $said, qr/interrupted/, "INT and QUIT are not reported as an interruption of the create" );
};

subtest 'podman gets default INT and QUIT handling, not the parent\'s IGNORE' => sub {
    my $bin = _fake_podman('kill -INT $$; sleep 1; echo survived; exit 0');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my ( undef, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured("create") } );

    ok( !$ok, "podman died of its own SIGINT" );
    unlike( $said, qr/survived/, "so IGNORE did not leak across the exec" );
};

for my $sig (qw(TERM HUP)) {
    subtest "SIG$sig at ea-podman is forwarded to podman and the create fails cleanly" => sub {
        require POSIX;
        my $bin = _fake_podman('echo started; exec sleep 30');
        local $ENV{PATH} = "$bin:$ENV{PATH}";

        my $t0  = time;
        my $kid = _signal_me_after( 0.5, $sig );
        my ( undef, $ok, $said ) = _stderr_of( sub { ea_podman::util::_podman_create_captured("create") } );
        waitpid( $kid, 0 );

        ok( !$ok, "the create is reported as failed, so the caller's cleanup runs" );
        cmp_ok( time - $t0, '<', 20, "and podman was signalled rather than waited out" );
        like( $said, qr/interrupted \(SIG$sig\)/, "and the message says what interrupted it" );
        is( waitpid( -1, POSIX::WNOHANG() ), -1, "no podman child is left behind" );
    };
}

subtest 'the caller\'s signal handlers are put back on every path' => sub {
    my $bin = _fake_podman('exit 0');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $mine = sub { 1 };
    local @SIG{qw(INT QUIT TERM HUP)} = ( $mine, 'DEFAULT', $mine, 'IGNORE' );

    _stderr_of( sub { ea_podman::util::_podman_create_captured("create") } );
    is_deeply( [ @SIG{qw(INT QUIT TERM HUP)} ], [ $mine, 'DEFAULT', $mine, 'IGNORE' ], "after a success" );

    my $empty = File::Temp->newdir();
    {
        local $ENV{PATH} = "$empty";
        _stderr_of( sub { ea_podman::util::_podman_create_captured("create") } );
    }
    is_deeply( [ @SIG{qw(INT QUIT TERM HUP)} ], [ $mine, 'DEFAULT', $mine, 'IGNORE' ], "and after a failure" );
};

subtest 'create_user_container keeps a boolean return and remembers a failure' => sub {
    no warnings 'redefine';
    local $ea_podman::util::_create_output;
    local *ea_podman::util::_podman_create_captured = sub { return ( 0, $QUOTA ) };

    is( ea_podman::util::create_user_container( "myapp.bob.01", "img" ), 0, "still returns false, not the text" );
    is( $ea_podman::util::_create_output, $QUOTA, "the text is kept for the caller" );

    local *ea_podman::util::_podman_create_captured = sub { return ( 1, "pulled some layers\n" ) };
    is( ea_podman::util::create_user_container( "myapp.bob.01", "img" ), 1, "success still returns true" );
    ok( !defined $ea_podman::util::_create_output, "and clears the last failure so a later one is not mistaken for it" );
};

subtest 'podman output is classified once, for pulls and creates alike' => sub {
    is( ea_podman::util::_podman_failure_reason($QUOTA),                                      "disk_quota", "a disk quota" );
    is( ea_podman::util::_podman_failure_reason("Error: ... no space left on device"),         "disk_quota", "a full filesystem" );
    is( ea_podman::util::_podman_failure_reason("Error: ... toomanyrequests: rate limit"),     "rate_limit", "a rate limit is still recognised" );
    is( ea_podman::util::_podman_failure_reason("Error: requested access is denied"),          "unknown",    "anything else is not guessed at" );
    is( ea_podman::util::_podman_failure_reason(undef),                                        "unknown",    "and nothing is unknown" );

    local %ea_podman::util::_pull_error = ( "img" => $QUOTA );
    is( ea_podman::util::_pull_failure_reason("img"), "disk_quota", "a quota hit during the pull is named too" );
};

subtest 'the failure note names a quota and shows podman words' => sub {
    my $note = ea_podman::util::_create_failure_note($QUOTA);

    like( $note, qr/disk space|quota/i,          "says it is disk space or quota" );
    like( $note, qr/larger quota|free up space/i, "and what to do about it" );
    like( $note, qr/libicudata\.so\.72\.1: disk quota exceeded/, "and includes what podman said" );

    my $other = ea_podman::util::_create_failure_note("Error: something else entirely");
    unlike( $other, qr/quota/i, "another cause gets no quota advice" );
    like( $other, qr/something else entirely/, "but still shows podman's text" );

    is( ea_podman::util::_create_failure_note(undef), "", "no output means no note, so the bare message is unchanged" );
    is( ea_podman::util::_create_failure_note("  \n"), "", "and neither does whitespace" );
};

subtest 'the note is bounded and safe to put in a log' => sub {
    my $long = ( "x" x 5000 ) . "\nthe real error\n";
    my $note = ea_podman::util::_create_failure_note($long);
    like( $note, qr/the real error/, "the end of the output is kept" );
    cmp_ok( length $note, '<', 2600, "and the note is bounded" );

    my $noisy = "\e[31mred\e[0m progress 10%\rprogress 90%\x00\x07\nEnd";
    my $clean = ea_podman::util::_create_failure_note($noisy);
    unlike( $clean, qr/[\e\x00\x07\r]/, "escape sequences and control characters are removed" );
    like( $clean, qr/red/, "the text around them survives" );
    like( $clean, qr/End/, "including the last line" );
};

subtest 'a failed install says why' => sub {
    my ( $tmp, $name, $dir ) = _world();
    _harness( creates => [ [ 0, $QUOTA ] ] );

    my $err = _fails( "fresh.bob.02", "install", "docker.io/library/node:22" );

    like( $err, qr/\AFailed to create container\n/, "the original first line is unchanged, for callers that match it" );
    like( $err, qr/quota/i,                         "it names the quota" );
    like( $err, qr/libicudata\.so\.72\.1: disk quota exceeded/, "and carries podman's own words" );
};

subtest 'a failed install with nothing to report keeps the bare message' => sub {
    my ( $tmp, $name, $dir ) = _world();
    _harness( creates => [ [ 0, undef ] ] );

    is( _fails( "fresh.bob.02", "install", "docker.io/library/node:22" ), "Failed to create container\n", "no regression to a blank or altered error" );
};

subtest 'a failed upgrade reports the first failure, not the rollback' => sub {
    my ( $tmp, $name, $dir ) = _world();

    # The rollback runs create_user_container a second time, and it overwrites
    # the remembered text -- so the message has to be built before it runs.
    _harness( creates => [ [ 0, $QUOTA ], [ 0, "Error: the rollback said something else" ] ] );

    my $err = _fails( $name, "upgrade" );

    like( $err, qr/Failed to upgrade/,                     "it raises" );
    like( $err, qr/disk quota exceeded/,                   "the original cause is in it" );
    unlike( $err, qr/rollback said something else/,        "and the rollback's failure is not mistaken for it" );
};

subtest 'a failed restore says why' => sub {
    my ( $tmp, $name, $dir ) = _world();
    _harness( creates => [ [ 0, $QUOTA ] ] );

    my $err = _fails( $name, "restore" );

    like( $err, qr/Failed to restore/,   "it raises" );
    like( $err, qr/disk quota exceeded/, "and carries podman's own words" );
    ok( -d $dir, "the extracted directory is still kept" );
};

subtest 'the message builders stay argument-pure and backward compatible' => sub {
    my $restore = ea_podman::util::_failed_restore_message( "myapp.bob.01", "/home/bob/ea-podman.d/myapp.bob.01" );
    unlike( $restore, qr/podman reported/, "no note, no mention" );

    my $with = ea_podman::util::_failed_restore_message( "myapp.bob.01", "/home/bob/ea-podman.d/myapp.bob.01", "podman reported:\nboom\n" );
    like( $with, qr/podman reported:\nboom/, "a supplied note is included" );

    my $status = { created => 1, enabled => 1, started => 1 };
    my $up     = ea_podman::util::_failed_upgrade_message( "myapp.bob.01", "/d", "img:1", "sha", $status, "podman reported:\nboom\n" );
    like( $up, qr/podman reported:\nboom/, "an upgrade message includes the note too" );
    unlike( ea_podman::util::_failed_upgrade_message( "myapp.bob.01", "/d", "img:1", "sha", $status ), qr/podman reported/, "and omits it when there is none" );
};

subtest 'a forced upgrade tells the operator why a pull failed' => sub {
    my ( $tmp, $name, $dir ) = _world();
    _harness( creates => [ [ 1, undef ] ] );

    no warnings 'redefine';
    local %ea_podman::util::_pull_error = ( "docker.io/library/httpd:2.4" => $QUOTA );
    local *ea_podman::util::_podman_pull = sub { 0 };
    local *ea_podman::util::_upgrade_is_needed = sub { 1 };

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    ea_podman::util::_ensure_latest_container( $name, { op => "upgrade", force => 1 } );

    like( join( "", @warned ), qr/disk space|quota/i, "the warning names the quota rather than only 'the pull failed'" );
};

done_testing();
