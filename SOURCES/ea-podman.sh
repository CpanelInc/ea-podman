is_container_name_running() {
    podman ps --no-trunc --format "{{.Names}}" | grep --quiet ^$1$
}

# short and long .ID (since the regex is not anchored at the end)
is_container_id_running() {
    podman ps --no-trunc --format "{{.ID}}" | grep --quiet ^$1
}

get_user_container_name() {
   # TODO: barf if $1 or $HOME are not set
   echo "$1$HOME" | sed 's|/|_|g'
}
