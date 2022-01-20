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

stop_user_container() {
    # TODO: barf if $1 is not set
    podman stop $1
}

start_user_container() {
    # TODO: barf if $# is < 4: name -p N:N [optional -p -v -e etc] container
    podman run -d --rm=true --name "$@"
}

# . /etc/opt/ea-podman/ea-podman.sh
# user_container_init start ea-my-container-with-services-pkg "My Service 1.2" -p hport:cport image
#
# Note: right before the image argument you can add additional run args like -v -e additional -p etc (-d --rm=true an --name are already being done for you)

user_container_init() {
   # TODO: barf if bad args
   cmd=$1
   pkg=$2
   label=$3
   name=$(get_user_container_name $pkg)
   shift 3

   ERROR=0
   case $cmd in
        start)
            if [ is_container_name_running $name ]; then
                echo -e "\e[00;33m$label container is already running (name : $name)\e[00m"
                ERROR=1
            else
                start_user_container $name "$@"
            fi
            ;;
        stop)
            if [ ! is_container_name_running $name ]; then
                echo -e "\e[00;31m$label container is already shutdown\e[00m"
                ERROR=1
            else
                stop_user_container $name
            fi
            ;;
        restart|force-reload|reload)
            if [ is_container_name_running $name ]; then
                stop_user_container $name
            fi

            start_user_container $name "$@"
            ;;
        status|fullstatus)
            if [ ! is_container_name_running $name ]; then
                echo -e "\e[00;31m$label is currently not running.\e[00m"
                ERROR=3
            else
                echo -e "\e[00;32m$label is running!\e[00m"
                ERROR=0
            fi
            ;;
        *)
            echo $"Usage: $0 {start|stop|restart|status|fullstatus}"
            ERROR=2
    esac

    exit $ERROR
}
