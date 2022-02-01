#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea_podman/util.pm                       Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

package ea_podman::util;

use Cpanel::JSON           ();
use Cpanel::AdminBin::Call ();
use File::Path::Tiny       ();

my $container_name_suffix_regexp      = qr/\.[^.]+\.[0-9][0-9]$/;
my $container_name_sans_suffix_regexp = qr/^[a-z][a-z0-9-]+[a-z0-9]/;

# See
#     1. https://docs.docker.com/engine/reference/commandline/tag/#extended-description
#     2. https://regex101.com/r/hP8bK1/1
my $image_name_regexp = qr'^(?:(?=[^:\/]{4,253})(?!-)[a-zA-Z0-9-]{1,63}(?<!-)(?:\.(?!-)[a-zA-Z0-9-]{1,63}(?<!-))*(?::[0-9]{1,5})?/)?((?![._-])(?:[a-z0-9._-]*)(?<![._-])(?:/(?![._-])[a-z0-9._-]*(?<![._-]))*)(?::(?![.-])[a-zA-Z0-9_.-]{1,128})?$';

sub ensure_su_login {    # needed when $user is from root `su - $user` and not SSH
    return if $> == 0;

    if ( !$ENV{XDG_RUNTIME_DIR} ) {
        my $user = scalar getpwuid($>);
        system("loginctl enable-linger $user");
        $ENV{XDG_RUNTIME_DIR} = "/run/user/$>";
    }
}

sub podman {
    ensure_su_login();
    system( podman => @_ );
    return $? == 0 ? 1 : 0;
}

sub sysctl {
    system( systemctl => "--user", @_ );
    return $? == 0 ? 1 : 0;
}

sub is_user_container_name_running {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    ensure_su_login();

    $container_name = quotemeta($container_name);
    `podman ps --no-trunc --format "{{.Names}}" | grep --quiet ^$container_name\$`;
    return $? == 0 ? 1 : 0;
}

sub is_user_container_id_running {
    my ($container_id) = @_;    # short and long .ID (since the regex is not anchored at the end)
    ensure_su_login();

    $container_id = quotemeta($container_id);
    `podman ps --no-trunc --format "{{.ID}}" | grep --quiet ^$container_id`;
    return $? == 0 ? 1 : 0;
}

sub remove_user_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return podman( rm => "--ignore", $container_name );
}

sub stop_user_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return podman( stop => "--ignore", $container_name );
}

sub start_user_container {
    my ( $container_name, @start_args ) = @_;
    validate_user_container_name($container_name);
    validate_start_args( \@start_args );

    return podman( run => "-d", "--hostname" => $container_name, "--name" => $container_name, @start_args );
}

sub get_container_service_name {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return "container-$container_name.service";
}

sub get_containers {
    my %containers;

    for my $line (`podman ps --no-trunc --format "{{.Names}} {{.Image}}"`) {
        my ( $name, $image ) = split( " ", $line, 2 );
        $containers{$name} = { image => $image };    # TODO ZC-9691: incorporate ports for $image if any
    }

    return \%containers;
}

sub get_next_available_container_name {    # ¿TODO/YAGNI?: make less racey
    my ($name) = @_;                       # ea-pkg or arbitrary-name
    die "Invalid name\n" if !length($name) || $name !~ m/$container_name_sans_suffix_regexp$/;

    $name .= "." . scalar getpwuid($>) . ".%02d";

    my $max          = 99;
    my $container_hr = get_containers();

    my $container_name;
    for my $n ( 1 .. $max ) {
        my $path = sprintf( $name, $n );
        if ( !exists $container_hr->{$path} ) {
            $container_name = $path;
            last;
        }
    }

    die "Could not find an available name for “$name” () tried $max times\n" if !$container_name;
    return $container_name;
}

sub get_pkg_from_container_name {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return if $container_name !~ m/^ea-/;

    $container_name =~ s/$container_name_suffix_regexp//g;
    return $container_name;
}

sub generate_container_service {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    my $homedir = ( getpwuid($>) )[7];
    File::Path::Tiny::mk("$homedir/.config/systemd/user");
    my $service_name = get_container_service_name($container_name);

    my $container_name_qx = quotemeta($container_name);
    my $service_name_qx   = quotemeta($service_name);

    `podman generate systemd --restart-policy on-failure --name $container_name_qx > ~/.config/systemd/user/$service_name_qx`;
    die "Failed to generate service file\n" if $? != 0;

    sysctl( enable => $service_name ) || die "Failed to enabled “$service_name”\n";
    return 1;
}

sub ensure_latest_container {
    my ( $container_name, @start_args ) = @_;

    validate_user_container_name($container_name);

    if ( my $pkg = get_pkg_from_container_name($container_name) ) {
        my $pkg_dir = "/opt/cpanel/$pkg";

        if ( -f "$pkg_dir/ea-podman.json" ) {
            die "Start args not allowed for container based packages\n" if @start_args;

            # do needful based on /opt/cpanel/$pkg
            my $pkg_conf = Cpanel::JSON::LoadFile("$pkg_dir/ea-podman.json");
            my @ports    = _get_new_ports( $container_name => $pkg_conf->{required_ports} );

            push @start_args, map { ( "-p", "$_:$_" ) } @ports;

            my $homedir       = ( getpwuid($>) )[7];
            my $container_dir = "$homedir/$container_name";
            for my $flag ( keys %{ $pkg_conf->{startup} } ) {
                if ( $flag eq "-v" ) {
                    push @start_args, map { $flag => "$container_dir/$_" } @{ $pkg_conf->{startup}{$flag} };
                }
                else {
                    my @values = @{ $pkg_conf->{startup}{$flag} };
                    if ( !@values ) {
                        push @start_args, $flag;
                    }
                    else {
                        push @start_args, map { $flag => $_ } @values;
                    }
                }
            }
            push @start_args, $pkg_conf->{image};

            validate_start_args( \@start_args );

            system( "$pkg_dir/ea-podman-local-dir-setup", $container_dir, @ports ) if -x "$pkg_dir/ea-podman-local-dir-setup";
        }
    }
    else {
        validate_start_args( \@start_args );
    }

    uninstall_container($container_name);
    start_user_container( $container_name, @start_args );
    generate_container_service($container_name);
}

sub _get_new_ports {
    my ( $container_name, $count ) = @_;

    return if !defined $count || $count < 1;

    my @new_ports;
    if ( $> == 0 ) {
        @new_ports = grep { chomp; m/^[0-9]+$/ ? ($_) : () } `/scripts/cpuser_port_authority give root $count --service=$container_name 2>/dev/null`;
    }
    else {
        my $get_ports_response = Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'GIVE', $count, $container_name );

        @new_ports = grep { m/^[0-9]+$/ ? ($_) : () } split( /\n/, $get_ports_response );
    }

    return @new_ports;

}

sub rename_containers {
    my ( $olduser, $newuser ) = @_;

    # TODO ZC-9694: implement me
}

sub validate_user_container_name {
    my ($container_name) = @_;
    die "Invalid container name\n" if $container_name !~ m/$container_name_sans_suffix_regexp$container_name_suffix_regexp/;
    return 1;
}

# 1 ➜ handled by ea-podman
# 2 ➜ these are intended to be long running not one offs
#     systemd management handles them quite nicely
# 3 ➜ these are intended to be long running not one offs
#     `ea-podman bash bash <CONTAINER_NAME> [CMD]` can be used to get a shell on a running container
my %invalid_start_args = (
    "-p"            => 1,
    "--publish"     => 1,
    "-d"            => 1,
    "--detach"      => 1,
    "-h"            => 1,
    "--hostname"    => 1,
    "--name"        => 1,
    "--rm"          => 2,
    "--rmi"         => 2,
    "--replace"     => 2,
    "-i"            => 3,
    "--interactive" => 3,
    "-t"            => 3,
    "--tty"         => 3,
);

sub validate_start_args {
    my ($start_args) = @_;
    die "No start args given\n"                             if !@{$start_args};
    die "Last start arg does not look like an image name\n" if $start_args->[-1] !~ $image_name_regexp;

    my @invalid;
    for my $flag ( @{$start_args} ) {
        next if substr( $flag, 0, 1 ) ne "-";

        my ( $opt, $val ) = split( "=", $flag, 2 );
        if ( substr( $opt, 0, 2 ) ne "--" ) {
            if ( length($opt) == 2 ) {
                push @invalid, $opt if exists $invalid_start_args{$opt};
            }
            else {
                for my $chr ( split( "", $opt ) ) {
                    next if $chr eq "-";
                    push @invalid, "-$chr" if exists $invalid_start_args{"-$chr"};
                }
            }
        }
        else {
            push @invalid, $opt if exists $invalid_start_args{$opt};
        }
    }

    die "Start args can not include the following: " . join( ",", @invalid ) . "\n" if @invalid;
    return 1;
}

###########################
#### main container CRUD ##
###########################

sub install_container {
    my ( $name, @start_args ) = @_;

    # The very first command has to be ensure_user which establishes this user
    # in the /etc/subuid and /etc/subgid files, critical to podman

    Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'ENSURE_USER' );

    ensure_latest_container( get_next_available_container_name($name), @start_args );
}

sub upgrade_container {    # TODO ZC-9693: ¿start_args?
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    ensure_latest_container($container_name);
}

sub remove_container_dir {
    my ($container_name) = @_;

    my $homedir       = ( getpwuid($>) )[7];
    my $container_dir = "$homedir/$container_name";
    system( 'rm', '-rf', $container_dir );

    return;
}

sub uninstall_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    stop_user_container($container_name);

    my $service_name = get_container_service_name($container_name);
    sysctl( disable => $service_name );

    my $homedir = ( getpwuid($>) )[7];
    unlink "$homedir/.config/systemd/user/$service_name";

    sysctl("daemon-reload");
    sysctl("reset-failed");

    remove_user_container($container_name);

    return;
}

1;
