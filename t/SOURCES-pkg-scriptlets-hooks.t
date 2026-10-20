#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/SOURCES-pkg-scriptlets-hooks.t        Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# PodmanHooks must stay registered through an RPM upgrade, where the old
# package's %preun runs after the new %post, and be removed on uninstall.

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp;

my $tmp   = File::Temp->newdir();
my $state = "$tmp/hooks";
my $stub  = "$tmp/manage_hooks";

# Models manage_hooks: add skips hooks already registered, as the real one does.
_write( $stub, <<"EOS" );
#!/bin/bash
touch $state
case "\$1" in
    list) cat $state ;;
    add) for h in _pre_username_change _delete_user _do_backup; do
             grep -qx "hook: PodmanHooks::\$h" $state || echo "hook: PodmanHooks::\$h" >> $state
         done ;;
    delete) : > $state ;;
esac
EOS
chmod 0755, $stub;

subtest 'prerm keeps the hooks on upgrade' => sub {
    _set_hooks(3);
    _run_scriptlet( 'pkg.prerm', 1 );
    is _count_hooks(), 3, 'all hooks still registered after an upgrade %preun';
};

subtest 'prerm removes the hooks on uninstall' => sub {
    _set_hooks(3);
    _run_scriptlet( 'pkg.prerm', 0 );
    is _count_hooks(), 0, 'hooks removed by an uninstall %preun';
};

subtest 'posttrans re-registers hooks an unfixed old prerm deleted' => sub {
    _set_hooks(0);
    _run_scriptlet( 'pkg.posttrans', 0 );
    is _count_hooks(), 3, 'all hooks registered';
};

subtest 'posttrans does not duplicate hooks already registered' => sub {
    _set_hooks(3);
    _run_scriptlet( 'pkg.posttrans', 0 );
    is _count_hooks(), 3, 'each hook registered exactly once';
};

subtest 'spec runs pkg.posttrans in %posttrans' => sub {
    my $spec = _slurp("$FindBin::Bin/../SPECS/ea-podman.spec");
    my ($n) = $spec =~ m/^Source(\d+):\s+pkg\.posttrans$/m;
    ok $n, 'pkg.posttrans is a Source';
    like $spec, qr/^%posttrans\s+%include %\{SOURCE$n\}/m, '%posttrans includes it';
};

done_testing;

# Run a scriptlet with its system paths pointed into $tmp.
sub _run_scriptlet {
    my ( $name, $arg ) = @_;
    my $src = _slurp("$FindBin::Bin/../SOURCES/$name");
    $src =~ s{/usr/local/cpanel/bin/manage_hooks}{$stub}g;
    $src =~ s{/opt/cpanel/ea-podman}{$tmp/opt}g;
    $src =~ s{/root/\.ea-podman-tmp}{$tmp/root-tmp}g;
    $src =~ s{/run/systemd/system}{$tmp/no-systemd}g;
    _write( "$tmp/$name", $src );
    system( 'bash', "$tmp/$name", $arg ) == 0 or diag "$name $arg exited $?";
}

sub _set_hooks {
    my ($n) = @_;
    _write( $state, '' );
    system( $stub, 'add' ) if $n;
}

sub _count_hooks { return scalar grep { /^hook: PodmanHooks::/ } split /\n/, `$stub list` }

sub _slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "open $file: $!";
    local $/;
    return <$fh>;
}

sub _write {
    my ( $file, $content ) = @_;
    open my $fh, '>', $file or die "open $file: $!";
    print {$fh} $content;
    close $fh;
}
