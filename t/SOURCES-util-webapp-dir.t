#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-util-webapp-dir.t            Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

require "$FindBin::Bin/../SOURCES/util.pm";

my $FROM = "/home/bob/.cpanel/webapp-staging/my-app";
my $TO   = "/home/bob/ea-podman.d/my-app.bob.01/webapp";

sub _rewritten {
    my (@args) = @_;
    ea_podman::util::_rewrite_webapp_mounts( \@args, $FROM, $TO );
    return \@args;
}

subtest '_rewrite_webapp_mounts rewrites two-arg -v/--volume host paths under the staged dir' => sub {
    is_deeply(
        _rewritten( "-v", "$FROM/source:/app", "-w", "/app", "docker.io/library/node:22" ),
        [ "-v", "$TO/source:/app", "-w", "/app", "docker.io/library/node:22" ],
        "-v subpath follows the move"
    );
    is_deeply(
        _rewritten( "--volume", "$FROM:/app:ro" ),
        [ "--volume", "$TO:/app:ro" ],
        "--volume exact match follows the move, extra options kept"
    );
    is_deeply(
        _rewritten( "-v", "$FROM/source/api:/app" ),
        [ "-v", "$TO/source/api:/app" ],
        "a deeper subpath (appdir) follows the move"
    );
};

subtest '_rewrite_webapp_mounts rewrites inline = forms' => sub {
    is_deeply( _rewritten("-v=$FROM/source:/app"),       ["-v=$TO/source:/app"],       "-v= form" );
    is_deeply( _rewritten("--volume=$FROM/source:/app"), ["--volume=$TO/source:/app"], "--volume= form" );
};

subtest '_rewrite_webapp_mounts leaves everything else alone' => sub {
    is_deeply(
        _rewritten( "-v", "$FROM-other/source:/app" ),
        [ "-v", "$FROM-other/source:/app" ],
        "a sibling path sharing the prefix string is not rewritten (path-boundary anchored)"
    );
    is_deeply(
        _rewritten( "-v", "/somewhere/else:/data" ),
        [ "-v", "/somewhere/else:/data" ],
        "an unrelated mount is not rewritten"
    );
    is_deeply( _rewritten( "-v", "namedvol:/data" ), [ "-v", "namedvol:/data" ], "a named volume is not rewritten" );
    is_deeply( _rewritten( "-v", "/app" ),           [ "-v", "/app" ],           "an anonymous volume (no host part) is not rewritten" );
    is_deeply(
        _rewritten( "-e", "PATH=$FROM/source" ),
        [ "-e", "PATH=$FROM/source" ],
        "non-volume args are never touched"
    );
    is_deeply( _rewritten("-v"), ["-v"], "a trailing -v with no value does not blow up" );
};

subtest '_validate_webapp_dir accepts a real absolute dir and normalizes trailing slashes' => sub {
    my $tmp    = File::Temp->newdir();
    my $staged = "$tmp/webapp-staging/my-app";
    require File::Path;
    File::Path::make_path($staged);

    is( ea_podman::util::_validate_webapp_dir( $staged,     "$tmp/ea-podman.d" ), $staged, "plain path passes through" );
    is( ea_podman::util::_validate_webapp_dir( "$staged//", "$tmp/ea-podman.d" ), $staged, "trailing slashes are stripped" );
};

subtest '_validate_webapp_dir rejects bad values' => sub {
    my $tmp    = File::Temp->newdir();
    my $staged = "$tmp/webapp-staging/my-app";
    require File::Path;
    File::Path::make_path( $staged, "$tmp/ea-podman.d/inside" );

    local $@;
    eval { ea_podman::util::_validate_webapp_dir( undef, "$tmp/ea-podman.d" ) };
    like( $@, qr/--webapp-dir requires the absolute path/, "missing value" );

    eval { ea_podman::util::_validate_webapp_dir( "", "$tmp/ea-podman.d" ) };
    like( $@, qr/--webapp-dir requires the absolute path/, "empty value" );

    eval { ea_podman::util::_validate_webapp_dir( "webapp-staging/my-app", "$tmp/ea-podman.d" ) };
    like( $@, qr/must be an absolute path/, "relative path" );

    eval { ea_podman::util::_validate_webapp_dir( "$tmp/does-not-exist", "$tmp/ea-podman.d" ) };
    like( $@, qr/is not a directory/, "missing dir" );

    eval { ea_podman::util::_validate_webapp_dir( "$tmp/ea-podman.d/inside", "$tmp/ea-podman.d" ) };
    like( $@, qr/cannot be inside/, "a dir inside the container root" );
};

done_testing();
