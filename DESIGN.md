# Container based EA4 packages

## Target Audiences

1. Maintenance and security teams
2. Training and technical support
3. Managers and other internal key stakeholders
4. Future project/feature owners/maintainers

## Detailed Summary

Obviously containers offer users (and developers) a lot.

## Overall Intent

Containers can do everything, and as such, users have to do everything (i.e. long commands, or complex dockerfile/gitlab-ci.yml/etc).

We want the containers to be easy to manage for the most common things while still allowing them to do complex things outside of the system.

### Must be secure

We use podman because of the docker compatibility without the problem of a user’s container being able to reach back into the host’s root.

We run the containers as the user meaning they can only damage or hack themselves.

### Usability

Make the most common things consistent and simpler to do.

User can still call `podman` and `systclt` however they wish, we just offer a simpler more consistent interface for the common things.

e.g. `ea-podman restart ea-tomcat100.dantest.42` instead of `systemctl --user restart container-ea-tomcat100.dantest.42.service`
* **Note**: they can still do the full `systemctl` if they really really want to.

### Must be simple to maintain container based packages.

The package should supply only what it needs for the tooling to be able to do what it does.

### Must be able to operate on arbitrary images.

This will allow for an almost limitless amount of services (micro and macro), apps, etc without any maintenance on our part.

## Maintainability

Estimate:

1. how much time and resources will be needed to maintain the feature in the future
    * not much, only bugs and new features that users find they need
2. how frequently maintenance will need to happen
    * When ever upstream is updated, automatable by existing tooling.

## Decisions

### Networking

TBD via ZC-9688

### root/user executing

Typically will be run by users but if root wants to do containers they can use the tool also.

If they want to manage containers for users they can use `su` (hint/help output should indicate that).

### Images we use in EA4 container based packages

* We should use the full URL
  * makes it easier to query for updates since we know right off where it came from
* We should only provide “Official Images” or “Verified Publisher”
* We should use `docker.io`
  * that is a popular and trusted registry
  * makes it easier to query for updates with one API
* non-EA4 packages can use whatever registries and images they wish

### Naming

To remain unique on the system and support multiple instances of the same image we will:

1. Name containers like `<PKG|NONPKG-NAME>.<USER>.<ID>`
2. Name its service file `~/.config/systemd/user/container-<CONTAINER-NAME>.service`

### Ensuring it is up

Since this is intended for more permanent containers as opposied to one-offs in a CI/CD pipeline we need to monitor containers.

We are going with user level systemd:

1. `Ubic` does not work well with containers (init style scripts).
2. `podman` has a mechanism that makes it dead simple to do.

### If it needs files on the host

Each instance will have a directory `~/<CONTAINER_NAME>/`.

This is referred to here as `<CONTAINERS-HOST-PATH>`

### Container Based Packages

#### Should have its info and logic in `/opt/cpanel/<pkg>`.

If given more startup args on the CLI it should error out.

1. ea-podman.json
```
{
    "ports" : [8080, 0, 4200],
    "image" : "docker.io/library/tomcat:10.0.14",
    "startup" : {
        "-e" : ["CATALINA_OPTS=-Xmx100m", "CATALINA_BASE=/usr/local/tomcat"],
        "-v" : [
            "conf:/usr/local/tomcat/conf",
            "logs:/usr/local/tomcat/logs",
            "webapps:/usr/local/tomcat/webapps",
        ]
    },
}
```
   * `-v` the local path is relative to `<CONTAINERS-HOST-PATH>`
      * e.g. `logs:/usr/local/tomcat/logs` will end up being `-v <CONTAINERS-HOST-PATH>/logs:/usr/local/tomcat/logs`
   * Note: ports and other typical start up flags are done for the user. Flags that should not be set here (in long or short form):
      1. `-p`, `--publish`
      2. `-d`, `--detach`
      3. `-h`, `--hostname`
      4. `--name`
      5. `--rm` and `--rmi` — not used because these are intended to be long lived container and systemd handles this nicely
      6. `--replace` — not used for the same reason as `--rm`
      7. `-i, `--interactive` — same as `--rm`, instead use `ea-podman bash`
      8. `-t`, `--tty` — same as `-i`
2. `ea-podman-local-dir-setup <CONTAINERS-HOST-PATH> [PORT [,PORT, PORT, …]]` — a script that will setup any files the container needs as well as configuring the ports (if needed) in the application itself
   * in the `ports` example above this would be something like 10001, 10002, 10003
   * the end result would be -p `10001:8080 -p 10002:10002 10003:4200` (the `0` means use the hosts port for th econtainer too)
3. If `ea-podman-local-dir-setup` needs files it is suggested to keep them in `ea-podman-local-dir-setup.skel` and have your script operate on those.
4. `ea-podman-local-dir-upgrade <CONTAINERS-HOST-PATH> <PKG-VERSION-OF-CONTAINER> <PKG-VERSION-ON-THE-SYSTEM-ATM> [PORT [,PORT, PORT, …]]
   * for the versions, splitting on `[+-]` (limit 2) will get the program version and package release version
5. If `ea-podman-local-dir-upgrade` needs files beyond what setup has it is suggested to keep them in `ea-podman-local-dir-upgrade.skel` and have your script operate on those.

#### Updating

1. The `find-latest-version` should look for the nexest available image from upstream.
2. To fully automate updates: the `ea4-tool-post-update` script just needs to update the version in the `image` field of `ea-podman.json`.

ZC-9686: Perhaps the tooling could contain boiler plate scripts that packages can link to like we do w/ PHPs’ find-latest-version.

### Arbitrary Images

Should have start up options specified in the CLI. Except the ones ea-podman manages.

`--cpuser-port=<CONTAINER-PORT>` can be used to specify ports it needs. They will be assigned host ports as described above.

Those options will be recorded in `<CONTAINERS-HOST-PATH>/ea-podman.json` for later.

## Child Documents

* None
