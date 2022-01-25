##################################
#### misc podman util fucntions ##
##################################

is_container_name_running() {
    podman ps --no-trunc --format "{{.Names}}" | grep --quiet ^$1$
}

# short and long .ID (since the regex is not anchored at the end)
is_container_id_running() {
    podman ps --no-trunc --format "{{.ID}}" | grep --quiet ^$1
}

##################################################
#### helpers not intended to be run by the user ##
##################################################

_set_su_login() {
   # TODO: barf is !$USER
   loginctl enable-linger $USER
   export XDG_RUNTIME_DIR=/run/user/$(id -u)
}

_remove_user_container() {
    # TODO: barf if $1 is not set
    podman rm --ignore $1
}

_stop_user_container() {
    # TODO: barf if $1 is not set
    podman stop --ignore $1
}

_start_user_container() {
    # TODO: barf if $# is < 4: name -p N:N [optional -p -v -e etc] container
    _set_su_login

    podman run -d --replace=true --rm=true --name "$@"
}

_get_container_service_name() {
   # TODO: barf if !$1
   echo "container-${1}.service"
}

_get_next_available_container_name() {
    # TODO: barf if !$1

    local suffix="01";
    # TODO: find next available suffix from 01-99

    echo $1.$suffix
}

_get_pkg_from_container_name() {
   # TODO: barf if !$1

   # TODO: return if $1 !~ m/^ea-/

   echo $1 | sed 's/\.[0-9][0-9]$//g'
}

_generate_container_service() {
    # TODO: barf if !$1
    _set_su_login

    mkdir -p ~/.config/systemd/user

    local service_name=$(get_container_service_name $1)
    podman generate systemd --restart-policy on-failure -n $1 > ~/.config/systemd/user/$service_name
    systemctl --user enable $service_name
}

_ensure_latest_container() {
    # TODO: barf if !$1
    _set_su_login

    uninstall_container $1

    local pkg=$(_get_pkg_from_container_name $1);
# TODO: sort me out/DESIGN DOC
#    Do needful setup if $pkg && -d /opt/cpanel/$pkg
#    _start_user_container "$@"
#    e.g. podman run -d --hostname rabbitmq-cptest1 --name rabbitmq-cptest1 -p 15672:15672 -p 5672:5672 -e RABBITMQ_DEFAULT_USER=cptest1 -e RABBITMQ_DEFAULT_PASSWORD=cpanel1 docker.io/library/rabbitmq:3-management

    _generate_container_service $1
}

######################
#### service helper ##
######################

# may need to move to cpanel- NS at some point (same w/ ea-podman pkg)
ea-container() {
    # TODO: barf if !$1 or !$2
    _set_su_login

    local service_name=$(get_container_service_name $2)
    systemctl --user $1 $service_name
}

###########################
#### main container CRUD ##
###########################

install_container() {
    # TODO: barf if !$1
    _set_su_login
    local name=$(_get_next_available_container_name $1)
    _ensure_latest_container $name
}

list_container_names() {
   _set_su_login
   podman ps --no-trunc --format "{{.Names}}"
}

container_name_detais() {
    # TODO: barf if !$1
    _set_su_login

   # TODO: dump JSON info about container $1
}

upgrade_container() {
    # TODO: barf if !$1
    _set_su_login

    _ensure_latest_container $1
}

uninstall_container() {
    # TODO: barf if !$1
    _set_su_login

    _stop_user_container $1

    local service_name=$(get_container_service_name $2)
    systemctl --user disable $service_name
    rm -f ~/.config/systemd/user/$service_name
    systemctl --user daemon-reload
    systemctl --user reset-failed

    _remove_user_container $1
}
