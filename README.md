# ea-podman

**Note**: example commands on this page assume that  `/usr/local/cpanel/scripts` or `/opt/cpanel/ea-podman/bin` are in your `PATH` or that you can calling the full path.

For more information on anything here please see [the design doc](DESIGN.md).

----

## Overview

This package brings in `podman` and helpers (primarily the `ea-podman` command) for container based EA4 packages to run safely as the user.

While you can manage arbitrary images with `podman` directly, `ea-podman` can also manage arbitrary containers.

The advantages are:

1. Common tasks have simpler commands
2. If it needs ports they are managed by cPanel’s port authority system ensuring that everyone has unique ports and the firewall is setup to keep those port assignments safe.
3. Consistency in location, naming, and behaviors
4. Automatic service managemant

## Anatomy of an EA4 container-based package

An EA4 container-based package contains everything necessary to setup and manage a containerized service.

As such no additional arguments are needed, simply `ea-podman install <PKG>`.

* You can however pass additional start up args like `-e` and `-v`
   * Some start up args are handled by ea-podman and will error out if used.

## How to use `ea-podman` to manage an arbitrary image like we do an EA4 container based package

**Note**: It recommended that you only use images you trust. For example, from docker hub it is best to only use images from a “Verified Publisher” and/or only “Official Images”. To help encourage that you will see this message on install:
```
🐉🐲🀄️
!!!! Heads up about arbitrary images !!

For security and reliability, when using arbitrary images, we highly recommend the following:

  • only use a trusted registry
  • only use “Official Image” and/or “Verified Publisher” images
  • specifying a version specific tag so that a major or minor change won’t break your containers
```

To use any image you wish you need at least two things:

1. A name you want to call it.
2. An image you want to run.

Beyond that you need to determine:

1. What ports, if any you want, exposed.
2. Additional start up args like `-e` and `-v`
   * Some start up args are handled by ea-podman and will error out if used.

### Example

Let’s say the user `bob` wanted to use the latest official mongo from docker hub. `bob` might have a command like:

`ea-podman install mymongo --cpuser-port=8081 -e "ME_CONFIG_MONGODB_ADMINUSERNAME=root" -e "ME_CONFIG_MONGODB_ADMINPASSWORD=example" docker.io/library/mongo:latest`

Now `bob`:
1. has a directory `~/ea-podman/mymongo.bob.01` for use by the container (useful for `-v`)
2. Can use `mymongo.bob.01` for various `ea-podman` subcommands, e.g.
   * `ea-podman restart mymongo.bob.01` restart the container
   * `ea-podman bash mymongo.bob.01` get a shell inside the container (if it has bash)
   * `ea-podman upgrade mymongo.bob.01` upgrade the image

## How can I use the `ea-podman` CLI?

* get a list of subcommands via `ea-podman`
* get help in a given subcommand: `ea-podman help <SUBCMD>`

## FAQ

### What about networking?

It works the same as using podman directly.

**Details**:

* https://podman.io/getting-started/network
* https://www.redhat.com/sysadmin/container-networking-podman

**TL;DR**:

If you are not `root` you have two options:

1. Use `--pod` to group the containers that need to talk to each other
2. Do communication via your containers’ ports

If you are `root` you can additionally:

1. create a network however you like
   * e.g. `podman network create skynet` for a bridged network named `skynet`
2. pass `--network` to `ea-podman install` of 2 or more images that need it

### Why does an account with containers have systemd lingering enabled?

Rootless containers run under the account’s own `systemd --user` manager. Without
lingering that manager only exists while the user is logged in, so their
containers would stop at logout and never come back after a reboot.
`ea-podman` therefore runs `loginctl enable-linger <user>` (as root) when it sets
an account up for containers.

An account with no containers is never lingered:

* no `ea-podman` command lingers an account that has no containers. Running
  `list`, `status`, `containers`, and so on gets the account its subuid/subgid
  ranges and nothing else. `install` is the exception, since it is about to
  create the first container.
* the backup hook runs for *every* account on the server, so it checks the
  container registry before it does anything at all — an account with nothing
  to back up is left completely alone

Creating a container always establishes the session, whichever code path gets
there, so an account never ends up with containers and no manager to keep them
running.

### Does `ea-podman` ever turn lingering back off?

Only for a linger it turned on itself, and only once that account has no
containers left at all.

An account can be lingering for all sorts of reasons — an administrator enabled
it, or some other software did — and the systemd marker in
`/var/lib/systemd/linger` does not record who asked for it. So whenever
`ea-podman` is the one that enables lingering, it notes that down for itself, as
a marker file per account under `/opt/cpanel/ea-podman/granted-linger`. Removing
the account’s last container (or removing the account) then releases the linger
and drops the note.

Everything else is left strictly alone:

* an account that was *already* lingering when `ea-podman` arrived keeps its
  lingering — that linger belongs to whoever enabled it
* if the account stops lingering and then starts again for some unrelated
  reason, the new linger is not `ea-podman`'s either. The note records *when*
  the grant happened, so a later linger is not released on the strength of it
* an account with containers keeps its lingering, because taking it away would
  stop them at the next logout or reboot
* `root` is never released
* nothing sweeps the server looking for lingering accounts to tidy up

A WebApp deployment gets its lingering from the cPanel WebApp plugin, which
enables it before `ea-podman` is involved. The plugin writes the same note when it
is the one that turns lingering on, so removing the WebApp gives that lingering
back like any other — and a WebApp deployed onto an account that was already
lingering still leaves that lingering alone. On a host whose plugin predates this,
the deployment's lingering is nobody's to release: use
`loginctl disable-linger <user>` if that is not wanted.

### There are files in my home directory that I don’t own/have access to!!!

This happens when podman creates files in the user namespace (e.g. creating storage) using user’s sub ids.

It is prefectly normal and is necessary for rootless containers to work. This is true whether inside the container is root or non-root. Flags like `--userns=keep-id` or `--uidmap` do not address it.

We may be able to rectify this in a future iteration (ZC-9872).
