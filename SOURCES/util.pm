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

use Path::Tiny 'path';

my $container_name_suffix_regexp      = qr/\.[^.]+\.[0-9][0-9]$/;
my $container_name_sans_suffix_regexp = qr/^[a-z][a-z0-9-]+[a-z0-9]/;
my $known_containers_file             = '/opt/cpanel/ea-podman/registered-containers.json';

# See
#     1. https://docs.docker.com/engine/reference/commandline/tag/#extended-description
#     2. https://regex101.com/r/hP8bK1/1
my $image_name_regexp = qr'^(?:(?=[^:\/]{4,253})(?!-)[a-zA-Z0-9-]{1,63}(?<!-)(?:\.(?!-)[a-zA-Z0-9-]{1,63}(?<!-))*(?::[0-9]{1,5})?/)?((?![._-])(?:[a-z0-9._-]*)(?<![._-])(?:/(?![._-])[a-z0-9._-]*(?<![._-]))*)(?::(?![.-])[a-zA-Z0-9_.-]{1,128})?$';

sub ensure_su_login {    # needed when $user is from root `su - $user` and not SSH
    return if $> == 0;

    delete $ENV{XDG_RUNTIME_DIR} if $ENV{XDG_RUNTIME_DIR} && $ENV{XDG_RUNTIME_DIR} ne "/run/user/$>";

    if ( !$ENV{XDG_RUNTIME_DIR} ) {
        my $user = getpwuid($>);

        # I wish there was a better way …
        if ( -f "/etc/os-release" ) {
            my $os = `source /etc/os-release; echo -n \$ID\$VERSION_ID`;

            if ( $os eq "centos7" ) {
                my $logged_in_user = `logname`;
                chomp($logged_in_user);
                if ( $logged_in_user ne $user ) {
                    die "On CentOS 7 you can only use podman when $user is connected directly via SSH (i.e. `su - $user` is not sufficient)\n";
                }
            }
        }

        # Error messages from loginctl are almost always benign, suppress them
        system("loginctl enable-linger $user 2> /dev/null");
        $ENV{XDG_RUNTIME_DIR} = "/run/user/$>";
    }
}

sub podman {
    ensure_su_login();
    system( podman => @_ );
    return $? == 0 ? 1 : 0;
}

sub sysctl {
    ensure_su_login();
    system( systemctl => "--user", @_ );    # ¿ if $> == 0 do --root => "~/.config/systemd/user" instead of `--user` ?
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

    # It is impossible to suppress the error messages emanating from this call
    # via system, however backticks suppresses them

    `podman stop --ignore --time 30 $container_name 2> /dev/null > /dev/null`;

    return;
}

sub start_user_container {
    my ( $container_name, @start_args ) = @_;
    validate_user_container_name($container_name);

    # start args should already have been validated and ports added
    # So we do not want this here: validate_start_args( \@start_args );

    my $output = podman( 'create', "--hostname" => $container_name, "--name" => $container_name, @start_args );

    return $output;
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
        $containers{$name} = { image => $image, ports => [ _get_current_ports($name) ] };    # empty list == no ports
    }

    return \%containers;
}

sub get_next_available_container_name {    # ¿TODO/YAGNI?: make less racey
    my ($name) = @_;                       # ea-pkg or arbitrary-name
    die "Invalid name\n" if !length($name) || $name !~ m/$container_name_sans_suffix_regexp$/;

    $name .= "." . scalar getpwuid($>) . ".%02d";

    my $max          = 99;
    my $container_hr = load_known_containers();    # running (get_containers()) or not

    # $container_hr does not need non-root entires filtered out when $> == 0 because
    #   1. The $name has the user so root’s call will not get mixed up when $container_hr has a key name foo.bob.99
    #   2. Since the names are generated a non-root user can’t register foo.root.42
    #   3. If they found a way to do ^^^ the worst case senario is root get a different number
    #      * if they used up all 99 options then there would be an error to indicate something is awry

    my $homedir = ( getpwuid($>) )[7];
    my $container_name;
    for my $n ( 1 .. $max ) {
        my $path = sprintf( $name, $n );
        if ( !exists $container_hr->{$path} && !-e "$homedir/$path" && !-e "$homedir/$path.bak" ) {
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

sub _ensure_latest_container {
    my ( $container_name, @start_args ) = @_;

    validate_user_container_name($container_name);

    my $caller_func = ( caller(1) )[3];
    my $isupgrade   = 0;
    my $portsfunc;
    if ( $caller_func eq "ea_podman::util::install_container" ) {
        $portsfunc = \&_get_new_ports;
    }
    elsif ( $caller_func eq "ea_podman::util::upgrade_container" ) {
        $portsfunc = \&_get_current_ports;
        $isupgrade = 1;
    }
    else {
        die "_ensure_latest_container() should only be called by install_container() or upgrade_container() (i.e. not $caller_func())\n";
    }

    my $homedir       = ( getpwuid($>) )[7];
    my $container_dir = "$homedir/$container_name";

    if ($isupgrade) {
        die "“$container_dir” does not exist\n" if !-d $container_dir;
    }

    if ( my $pkg = get_pkg_from_container_name($container_name) ) {
        my $pkg_dir = "/opt/cpanel/$pkg";
        if ( -f "$pkg_dir/ea-podman.json" ) {
            die "Upgrade takes no start args\n" if $isupgrade && @start_args;
            my @given_start_args = @start_args;

            # do needful based on /opt/cpanel/$pkg
            my $pkg_conf = Cpanel::JSON::LoadFile("$pkg_dir/ea-podman.json");
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

            if ($isupgrade) {
                if ( -e "$container_dir/ea-podman.json" ) {
                    my $container_conf = Cpanel::JSON::LoadFile("$container_dir/ea-podman.json");
                    die "`start_args` is missing from $container_dir/ea-podman.json\n" if !exists $container_conf->{start_args};
                    die "`start_args` is not a list\n"                                 if ref( $container_conf->{start_args} ) ne "ARRAY";
                    push @start_args, @{ $container_conf->{start_args} };
                }
            }

            push @start_args, $pkg_conf->{image};

            # ensure ea-podman.json isn’t specifying something it shouldn’t
            validate_start_args( \@start_args );

            if ( !$isupgrade ) {
                mkdir $container_dir || die "Could not create “$container_dir”: $!\n";
            }

            # then add the ports if any
            my @container_ports = $pkg_conf->{ports} && ref $pkg_conf->{ports} eq "ARRAY" ? @{ $pkg_conf->{ports} } : ();
            my @ports           = $portsfunc->( $container_name => scalar(@container_ports) );

            # note the docker image name HAS to be the last argument
            my $docker_name = pop @start_args;

            for my $idx ( 0 .. $#ports ) {
                my $container_port = $container_ports[$idx] || $ports[$idx];
                push @start_args, "-p", "$ports[$idx]:$container_port";
            }
            push @start_args, $docker_name;

            my ( $container_ver, $package_ver ) = get_pkg_versions( $container_name => $pkg );

            if ($isupgrade) {
                if ( -x "$pkg_dir/ea-podman-local-dir-upgrade" ) {
                    system( "$pkg_dir/ea-podman-local-dir-upgrade", $container_dir, $container_ver, $package_ver, @ports );
                    warn "$pkg_dir/ea-podman-local-dir-upgrade did not exit cleanly\n" if $? != 0;
                }
            }
            else {
                if ( -x "$pkg_dir/ea-podman-local-dir-setup" ) {
                    system( "$pkg_dir/ea-podman-local-dir-setup", $container_dir, @ports );
                    warn "$pkg_dir/ea-podman-local-dir-setup did not exit cleanly\n" if $? != 0;
                }

                # has to happen after script so the script can easily bail if the dir is not empty
                if (@given_start_args) {
                    my $json = Cpanel::JSON::pretty_canonical_dump( { start_args => \@given_start_args } );
                    _file_write_chmod( "$container_dir/ea-podman.json", $json, 0600 );
                }
            }

            # Ensure "$container_dir/README.md" is correct
            unlink "$container_dir/README.md";
            symlink( "$pkg_dir/README.md", "$container_dir/README.md" );
            if ( -l "$container_dir/README.md" && !-e _ ) {
                warn "!!!! ATTN DEVELOPER !! - failed to include required README.md for “$pkg” in “$pkg_dir/README.md”\n";
            }
        }
        else {
            die "“$pkg” looks like an EA4 package but it is not a container based EA4 package. Please use the correct package name (or install it if it was uninstalled but its directory left behind) or use a name that does not start w/ `ea-`.\n";
        }
    }
    else {
        my @real_start_args;
        my @cpuser_ports;

        if ($isupgrade) {
            die "Upgrade takes no start args\n"                             if @start_args;
            die "Missing non-EA4-container $container_dir/ea-podman.json\n" if !-e "$container_dir/ea-podman.json";
            my $container_conf = Cpanel::JSON::LoadFile("$container_dir/ea-podman.json");
            die "`start_args` is missing from $container_dir/ea-podman.json\n" if !exists $container_conf->{start_args};
            die "`start_args` is not a list\n"                                 if ref( $container_conf->{start_args} ) ne "ARRAY";

            @cpuser_ports    = @{ $container_conf->{ports} || [] };
            @real_start_args = @{ $container_conf->{start_args} };
        }
        else {    # install
            die "No start args given for install\n" if !@start_args;

            # note the docker image name HAS to be the last argument
            my $docker_name = pop @start_args;
            for my $item (@start_args) {
                if ( $item =~ m/^--cpuser-port(?:=(.+))?/ ) {
                    my $val = $1;

                    if ( !length($val) || $val !~ m/^(?:0|[1-9][0-9]+?)$/ ) {
                        die "--cpuser-port requires a port the container uses (or 0 to be the same as the corresponding host port). e.g. --cpuser-port=8080\n";
                    }
                    push @cpuser_ports, $val;
                }
                else {
                    push @real_start_args, $item;
                }
            }

            push @real_start_args, $docker_name;
        }

        # ensure the user isn’t specifying something they shouldn’t
        validate_start_args( \@real_start_args );

        if ( !$isupgrade ) {
            mkdir $container_dir || die "Could not create “$container_dir”: $!\n";
            my $json = Cpanel::JSON::pretty_canonical_dump( { start_args => \@real_start_args, ports => \@cpuser_ports } );
            _file_write_chmod( "$container_dir/ea-podman.json", $json, 0600 );
        }

        my $docker_name = pop @real_start_args;    # so we can put ports before the image

        # then add the ports if any
        my @ports = $portsfunc->( $container_name => scalar(@cpuser_ports) );
        for my $idx ( 0 .. $#ports ) {
            my $container_port = $cpuser_ports[$idx] || $ports[$idx];
            push @real_start_args, "-p", "$ports[$idx]:$container_port";
        }

        @start_args = @real_start_args;
        push @start_args, $docker_name;
    }

    uninstall_container($container_name) if $isupgrade;    # avoid spurious warnings on install
    register_container( $container_name, $isupgrade );
    start_user_container( $container_name, @start_args );
    generate_container_service($container_name);

    my $service_name = get_container_service_name($container_name);
    sysctl( start => $service_name );
}

sub _file_write_chmod {
    my ( $file, $cont, $mode ) = @_;
    my $path = path($file);

    local $@;
    eval { $path->chmod($mode) };    # try to chmod it first to protect data we are spewing into it
    $path->spew($cont);
    $path->chmod($mode);             # spew() first to ensure it exists
    return 1;
}

sub get_pkg_versions {
    my ( $container_name, $pkg ) = @_;

    my $registered    = load_known_containers();
    my $container_ver = $registered->{$container_name} ? $registered->{$container_name}{pkg_version} : undef;
    chomp($container_ver) if defined $container_ver;

    # we want this to die, it means the pkg left out an important requirement
    my $package_ver = path("/opt/cpanel/$pkg/pkg-version")->slurp;    # dies if can’t open
    chomp($package_ver);
    die "/opt/cpanel/$pkg/pkg-version does not define the version\n" if !length($package_ver);

    # scalar context will do $package_ver
    return ( $container_ver, $package_ver );
}

sub _get_current_ports {
    my ( $container_name, $count ) = @_;

    my @curr_ports;
    my $portassignments_json;
    if ( $> == 0 ) {
        $portassignments_json = `/scripts/cpuser_port_authority list root`;
    }
    else {
        $portassignments_json = Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'LIST' );
    }

    my $portassignments_hr = Cpanel::JSON::Load($portassignments_json);
    for my $port ( sort keys %{$portassignments_hr} ) {
        if ( $portassignments_hr->{$port}{service} eq $container_name ) {
            push @curr_ports, $port;
        }
    }

    if ( length($count) ) {
        my $how_many = @curr_ports;
        warn "“$container_name” needs $count port(s) but only has $how_many assigned\n" if $count != $how_many;
    }

    return @curr_ports;
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
#     `ea-podman bash <CONTAINER_NAME> [CMD]` can be used to get a shell on a running container
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
    ensure_su_login();

    # The very first command has to be ensure_user which establishes this user
    # in the /etc/subuid and /etc/subgid files, critical to podman
    if ( $> == 0 ) {
        local $@;
        eval { ea_podman::subids::ensure_user_root("root"); };

        die "Unable to ensure the root has subuids and subgids\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'ENSURE_USER' );
    }

    _ensure_latest_container( get_next_available_container_name($name), @start_args );
}

sub upgrade_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    ensure_su_login();

    _ensure_latest_container($container_name);
}

sub move_container_dir {
    my ($container_name) = @_;

    my $homedir       = ( getpwuid($>) )[7];
    my $container_dir = "$homedir/$container_name";

    print "Moving “~/$container_name” to “~/$container_name.bak”\n";
    path($container_dir)->move("$container_dir.bak");

    return;
}

sub remove_port_authority_ports {
    my ($container_name) = @_;
    if ( $> == 0 ) {
        my @container_ports = _get_current_ports($container_name);
        system( "/scripts/cpuser_port_authority", take => root => @container_ports );
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'TAKE', $container_name );
    }

    return;
}

sub uninstall_container {
    my ($container_name) = @_;
    validate_user_container_name($container_name);
    ensure_su_login();

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

sub load_known_containers {
    return load_known_containers_as_root() if $> == 0;
    return Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'REGISTERED_CONTAINERS' );
}

sub load_known_containers_as_root {
    my $containers_hr = {};
    $containers_hr = Cpanel::JSON::LoadFile($known_containers_file) if ( -e $known_containers_file );

    return $containers_hr;
}

sub register_container_as_root {
    my ( $container_name, $user, $isupgrade ) = @_;

    my $containers_hr = load_known_containers_as_root();

    my $pkg = get_pkg_from_container_name($container_name);

    # We want the slurp to error out if a package looking thing is not a container based package
    my $pkg_ver = $pkg ? path("/opt/cpanel/$pkg/pkg-version")->slurp : undef;
    chomp($pkg_ver) if defined $pkg_ver;

    if ( exists $containers_hr->{$container_name} && !$isupgrade ) {
        warn "$container_name is already registered";
        return;
    }
    elsif ( !exists $containers_hr->{$container_name} && $isupgrade ) {
        warn "$container_name is not registered, registering now …\n";
    }

    $containers_hr->{$container_name} = {
        container_name => $container_name,
        user           => $user,
        pkg            => $pkg,
        pkg_version    => $pkg_ver,
    };

    Cpanel::JSON::DumpFile( $known_containers_file, $containers_hr ) or die "Cannot open known containers file";

    return;
}

sub deregister_container_as_root {
    my ($container_name) = @_;

    my $containers_hr = load_known_containers_as_root();

    if ( !exists $containers_hr->{$container_name} ) {
        warn "$container_name is not registered";
        return;
    }

    delete $containers_hr->{$container_name} if ( exists $containers_hr->{$container_name} );

    Cpanel::JSON::DumpFile( $known_containers_file, $containers_hr ) or die "Cannot open known containers file";

    return;
}

sub remove_container_by_name {
    my ($container_name) = @_;

    print "Removing $container_name\n";

    ea_podman::util::remove_port_authority_ports($container_name);
    ea_podman::util::uninstall_container($container_name);
    ea_podman::util::deregister_container($container_name);
    ea_podman::util::move_container_dir($container_name);

    return;
}

sub remove_containers_for_a_user {
    my (@containers) = @_;

    # They should be for all the same user
    my $user;
    foreach my $container (@containers) {
        my $c_user = $container->{user};
        if ( !$user ) {
            $user = $c_user;
            next;
        }

        die "remove_users_containers: Containers listed must be for all the same user" if ( $c_user ne $user );
    }

    foreach my $container (@containers) {
        remove_container_by_name( $container->{container_name} );
    }

    return;
}

sub register_container {
    my ( $container_name, $isupgrade ) = @_;

    if ( $> == 0 ) {
        local $@;
        eval { register_container_as_root( $container_name, "root", $isupgrade ); };

        die "Unable to register “$container_name”: $@\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'REGISTER', $container_name, $isupgrade );
    }
}

sub deregister_container {
    my ($container_name) = @_;

    if ( $> == 0 ) {
        local $@;
        eval { deregister_container_as_root($container_name); };

        die "Unable to deregister “$container_name”: $@\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'DEREGISTER', $container_name );
    }
}

sub ensure_user {

    # The very first command has to be ensure_user which establishes this user
    # in the /etc/subuid and /etc/subgid files, critical to podman
    if ( $> == 0 ) {
        local $@;
        eval { ea_podman::subids::ensure_user_root("root"); };

        die "Unable to ensure the root has subuids and subgids\n" if $@;
    }
    else {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'ea_podman', 'ENSURE_USER' );
    }

    return;
}

1;
