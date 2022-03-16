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
