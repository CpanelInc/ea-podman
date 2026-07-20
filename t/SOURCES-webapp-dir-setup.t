#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-webapp-dir-setup.t           Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

## no critic qw(TestingAndDebugging::RequireUseStrict TestingAndDebugging::RequireUseWarnings)
use Test::Spec;    # automatically turns on strict and warnings

use FindBin;
use File::Temp;
use File::Path ();

require "$FindBin::Bin/../SOURCES/webapp-dir-setup";

describe "webapp-dir-setup" => sub {
    my ( $tmp, $staged_dir, $container_dir );

    before each => sub {
        $tmp           = File::Temp->newdir();
        $staged_dir    = "$tmp/webapp-staging/my-app";
        $container_dir = "$tmp/ea-podman.d/my-app.bob.01";
        File::Path::make_path( "$staged_dir/source", $container_dir );

        open my $fh, '>', "$staged_dir/source/index.js" or die "Could not write fixture: $!";
        print {$fh} "console.log('hi');\n";
        close $fh;
    };

    it "moves the staged dir to the container dir's webapp/" => sub {
        my $rv = main::run( $staged_dir, $container_dir );

        ok( $rv, "returns true" );
        ok( -f "$container_dir/webapp/source/index.js", "the staged content is now under webapp/" );
    };

    it "leaves nothing behind at the staged location" => sub {
        main::run( $staged_dir, $container_dir );
        ok( !-e $staged_dir, "the staged dir itself became webapp/" );
    };

    it "dies with usage when args are missing" => sub {
        local $@;
        eval { main::run() };
        like( $@, qr/^Usage: webapp-dir-setup/, "no args" );

        eval { main::run($staged_dir) };
        like( $@, qr/^Usage: webapp-dir-setup/, "one arg" );
    };

    it "rejects relative paths" => sub {
        local $@;
        eval { main::run( "webapp-staging/my-app", $container_dir ) };
        like( $@, qr/must be an absolute path/ );
    };

    it "rejects a staged path that is not a directory" => sub {
        local $@;
        eval { main::run( "$tmp/does-not-exist", $container_dir ) };
        like( $@, qr/is not a directory/ );
    };

    it "rejects a container path that is not a directory" => sub {
        local $@;
        eval { main::run( $staged_dir, "$tmp/does-not-exist" ) };
        like( $@, qr/is not a directory/ );
    };

    it "refuses to clobber an existing webapp/ and leaves the staged dir untouched" => sub {
        File::Path::make_path("$container_dir/webapp");

        local $@;
        eval { main::run( $staged_dir, $container_dir ) };
        like( $@, qr/already exists/, "dies on existing webapp\/" );
        ok( -f "$staged_dir/source/index.js", "staged content untouched" );
    };
};

runtests unless caller;
