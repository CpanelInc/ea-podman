#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - t/docs-backup-restore.t                 Copyright 2026 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Test::More;
use FindBin;

# docs/backup-restore.md explains backup/restore by pointing at the code, and a
# pointer is only worth having while it still resolves. Nothing else notices when
# one goes stale, so this test does: every SOURCES file the doc names must exist,
# every symbol it names must still be defined in the file it attributes it to,
# and the couple of values the doc quotes must still match the code.
#
# It also forbids `file:line` references. Line numbers rot silently — an edit
# anywhere above shifts them and the doc goes on looking authoritative while
# pointing at an unrelated line. Name the symbol and let the reader grep.

my $repo = "$FindBin::Bin/..";

sub slurp {
    my ($path) = @_;
    open( my $fh, '<', "$repo/$path" ) or die "Could not open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $md = slurp("docs/backup-restore.md");

my $flat = $md;    # whitespace-insensitive copy, so re-wrapping prose is not a failure
$flat =~ s/\s+/ /g;

#### 1. no line-number references ####

my @line_refs = $md =~ m{(\b[\w./-]+\.(?:pm|pl|conf|md):[0-9]+)}g;
is_deeply( \@line_refs, [], "no file:line references (name the symbol instead — line numbers go stale silently)" )
  or diag explain \@line_refs;

#### 2. every SOURCES path the doc names exists ####

my %sources = map { $_ => 1 } $md =~ m{(SOURCES/[\w.-]+)}g;
ok( scalar( keys %sources ), "the doc references SOURCES files" );
ok( -e "$repo/$_", "$_ exists" ) for sort keys %sources;

#### 3. every symbol the doc names is still defined where it says ####

my %sub_in = (
    '_enable_linger'                     => 'SOURCES/subids.pm',
    '_ensure_subids'                     => 'SOURCES/subids.pm',
    'delegate_to_uapi'                   => 'SOURCES/ea-podman.pl',
    '_do_backup'                         => 'SOURCES/PodmanHooks.pm',
    '_pre_username_change'               => 'SOURCES/PodmanHooks.pm',
    'describe'                           => 'SOURCES/PodmanHooks.pm',
    '_ensure_backup_conf_excludes_files' => 'SOURCES/util.pm',
    '_ensure_latest_container'           => 'SOURCES/util.pm',
    '_get_current_ports'                 => 'SOURCES/util.pm',
    '_get_new_ports'                     => 'SOURCES/util.pm',
    'generate_container_service'         => 'SOURCES/util.pm',
    'get_next_available_container_name'  => 'SOURCES/util.pm',
    'init_user'                          => 'SOURCES/util.pm',
    'move_container_dir'                 => 'SOURCES/util.pm',
    'perform_user_backup'                => 'SOURCES/util.pm',
    'perform_user_restore'               => 'SOURCES/util.pm',
    'register_container_as_root'         => 'SOURCES/util.pm',
    'rename_containers'                  => 'SOURCES/util.pm',
    'restore_containers_for_user'        => 'SOURCES/util.pm',
);

for my $name ( sort keys %sub_in ) {
    my $file = $sub_in{$name};
    like( slurp($file), qr/^\s*sub \Q$name\E\b/m, "$file still defines $name()" );

    # Keeps this table honest in the other direction: a ref dropped from the doc
    # should be dropped from here too.
    like( $flat, qr/\Q$name\E/, "the doc still references $name()" );
}

#### 4. non-sub anchors the doc calls out by name ####

my @anchors = (
    [ 'SOURCES/util.pm',      qr/^our \$known_containers_file\b/m,     '$known_containers_file' ],
    [ 'SOURCES/util.pm',      qr/^our \$num_backups_to_retain\b/m,     '$num_backups_to_retain' ],
    [ 'SOURCES/util.pm',      qr/elsif \(\$isrestore\)/,               'the $isrestore no-op that skips local-dir-setup/-upgrade' ],
    [ 'SOURCES/util.pm',      qr/podman generate systemd/,             'the `podman generate systemd` call' ],
    [ 'SOURCES/util.pm',      qr/remove_tree\( \{ safe => 0 \} \)/,    'the unconditional remove_tree({ safe => 0 })' ],
    [ 'SOURCES/util.pm',      qr/lines\( \{ chomp => 1 \} \)/,         'the chomped read of cpbackup-exclude.conf' ],
    [ 'SOURCES/util.pm',      qr{system\( 'tar', 'czf', \$tarball_name.*\) == 0}, 'the list-form, status-checked tar czf' ],
    [ 'SOURCES/util.pm',      qr{system\( 'tar', 'xf', \$backup_tarball \) == 0}, 'the list-form, status-checked tar xf' ],
    [ 'SOURCES/ea-podman.pl', qr/^\s+backup => \{/m,                   'the backup command' ],
    [ 'SOURCES/ea-podman.pl', qr/^\s+restore => \{/m,                  'the restore command' ],
    [ 'SOURCES/ea-podman.pl', qr/^\s+rootbackupofuser => \{/m,         'the rootbackupofuser command' ],
    [ 'SOURCES/ea-podman.pl', qr/my %uapi_verb = /,                    '%uapi_verb' ],
);

like( slurp( $_->[0] ), $_->[1], "$_->[0] still has $_->[2] (named in the doc)" ) for @anchors;

# The doc's central pkgacct claim is that this fires *pre*-archive as a module hook.
like(
    slurp('SOURCES/PodmanHooks.pm'),
    qr/'category'\s*=>\s*'PkgAcct',\s*'event'\s*=>\s*'Create',\s*'stage'\s*=>\s*'pre',\s*'hook'\s*=>\s*'PodmanHooks::_do_backup'/,
    "the PkgAcct::Create hook is still pre-stage and still calls _do_backup()"
);

#### 5. values the doc quotes must match the code ####

my ($retain) = slurp('SOURCES/util.pm') =~ /our \$num_backups_to_retain\s*=\s*([0-9]+)/;
ok( $retain, "found the retention count in util.pm" );
like( $flat, qr/Keep the newest \Q$retain\E tarballs/, "the doc's retention count is $retain" );

my ($qw) = slurp('SOURCES/ea-podman.pl') =~ /my %uapi_verb = map \{ \$_ => 1 \} qw\(([^)]*)\)/;
ok( $qw, "found the UAPI verb list in ea-podman.pl" );
my $verbs = join( " ", split( " ", $qw ) );
like( $flat, qr/\Q$verbs\E/, "the doc lists the UAPI bridge verbs as: $verbs" );
unlike( $qw, qr/\b(?:backup|restore)\b/, "backup/restore are still absent from the UAPI bridge (the doc's restricted-shell limitation)" );

done_testing();
