#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - ea_podman/util.pm                       Copyright 2022 cPanel, L.L.C.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

package ea_podman::util;

sub ensure_su_login {
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

    #  We do not want --rm=true --replace=true:
    #     1. these are intended to be long running not one offs
    #     2. systemd management handles them quite nicely

    # TODO: barf if hardcoded run flags are in @start_args
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
        $containers{$name} = $image;
    }

    return \%containers;
}

sub get_next_available_container_name {    # TODO: make less racey
    my ($name) = @_;                       # ea-pkg or arbitrary-name
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

    die "Could not find an available name for “$name” () tried $max times\n";
    return $container_name;
}

sub get_pkg_from_container_name {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    return if $container_name !~ m/^ea-/;

    $container_name =~ s/\.[^.]+\.[0-9][0-9]$//g;
    return $container_name;
}

sub generate_container_service {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    # TODO: not shell out
    system("mkdir -p ~/.config/systemd/user");
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

    uninstall_container($container_name);

    if ( my $pkg = get_pkg_from_container_name($container_name) ) {
        if ( -d "/opt/cpanel/$pkg" ) {

            # TODO:  do needful based on /opt/cpanel/$pkg
        }
    }

    start_user_container( $container_name, @start_args );
    generate_container_service($container_name);
}

sub rename_containers {
    my ( $olduser, $newuser ) = @_;

    # TODO: implement me
}

sub validate_user_container_name {
    my ($container_name) = @_;

    # TODO: implement me
}

###########################
#### main container CRUD ##
###########################

sub install_container {
    my ($name) = @_;
    ensure_latest_container( get_next_available_container_name($name) );
}

sub upgrade_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    ensure_latest_container($container_name);
}

sub uninstall_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);

    stop_user_container($container_name);

    my $service_name = get_container_service_name($container_name);
    sysctl( disable => $service_name );

    # TODO: no ~ rm -f ~/.config/systemd/user/$service_name

    sysctl("daemon-reload");
    sysctl("reset-failed");

    remove_user_container($container_name);
}

1;
