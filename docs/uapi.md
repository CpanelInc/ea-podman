# Managing ea-podman containers via UAPI

`ea-podman` lets a cPanel account run and manage its own rootless Podman
containers. Accounts with an **unrestricted shell** (and root) use the
command-line tool (`ea-podman`) directly. Accounts with a restricted
(**jailshell**) login shell can run the **same CLI**, too: for the supported
verbs it transparently routes through the **`EAPodman` UAPI module** described
here (which cpsrvd executes outside the jail), so nothing special is required of
the caller. A **CloudLinux CageFS** account with an ordinary (unrestricted)
shell also runs the CLI directly — a real login there really is inside the
cage, and CageFS does not expose `/run/user` into it, so a direct CLI call
that hits that specific symptom (bootstrap already succeeded, but the runtime
directory isn't visible from inside the cage) transparently falls back to the
same UAPI route jailshell uses. The UAPI module is also the direct entry point
for the cPanel UI, API tokens, and other integrations.

This document covers what that UAPI surface is, **who** can use it, and **how**
to call it. See `DESIGN.md` for the internals.

## Why restricted accounts go through UAPI

- Rootless Podman cannot start inside the jailshell chroot or a `nosuid` CageFS
  cage — `newuidmap`/`newgidmap` cannot set up the user namespace there. So a
  jailshell CLI invocation does **not** run podman locally; it hands the
  operation to this UAPI instead.
- UAPI is executed by **cpsrvd as the authenticated cPanel user**, which runs
  **outside** any CageFS cage and never enters the jailshell chroot (it does not
  exec the login shell). So the same code path works for normal, jailshell, and
  CageFS accounts.
- A jailshell (or CageFS-fallback) CLI call reaches that UAPI even though a
  shell login has no ambient web credential: the (root) ea-podman adminbin
  mints a short-lived cPanel API token for the caller, the CLI makes one
  authenticated request over localhost HTTPS (`Authorization: cpanel
  user:token`), and the token is revoked right after.
- The first container operation transparently performs the one-time privileged
  bootstrap (allocate subuid/subgid and run `loginctl enable-linger`, as root
  via the ea-podman adminbin) so the account gets a persistent rootless user
  session (`/run/user/<uid>` + a lingering `user@<uid>.service`).

## Who can run it

- **Any cPanel account**, over an authenticated cpsrvd session or a cPanel API
  token. Normal, jailshell, and CageFS accounts are all supported.
- A call only ever sees and acts on **the calling account's own containers**.
- **root / WHM operators** may invoke it on behalf of an account with
  `uapi --user=<account> EAPodman ...`.

> **Host recommendation — cgroups:** ea-podman manages containers through the
> user's `systemd` manager and runs on either cgroup hierarchy; bring-up and
> serving are verified on both (the shipped units are plain `Type=forking`).
> **The right choice depends on whether the host runs CloudLinux's LVE kernel,
> not on the cgroup version in the abstract:**
>
> - **CloudLinux (LVE): use cgroup v1 — this is the correct, fully-supported
>   configuration, not a fallback.** The LVE kernel relocates every non-root
>   user's processes into its own cgroup, outside systemd's `user.slice`. Under
>   the **cgroup v2** unified hierarchy a process can live in only one node, so
>   LVE's placement and the per-user `systemd --user` manager are mutually
>   exclusive — LVE wins and `systemd --user` dies, which breaks the
>   jailshell/CageFS path that depends on it (`loginctl enable-linger` →
>   `user@<uid>.service` → `/run/user/<uid>/bus`). Stay on cgroup v1. If a box is
>   on cgroup v2, switch it back and reboot:
>
>   ```sh
>   tuned-adm profile cloudlinux-default-cgv1   # (…-latency-performance-cgv1 if that's your base profile)
>   reboot
>   # verify after reboot — should print tmpfs (cgroup v1), not cgroup2fs:
>   stat -fc %T /sys/fs/cgroup
>   ```
>
>   **CloudLinux 10 also ships `user.max_user_namespaces=0`**, which silently
>   breaks rootless Podman's `newuidmap`/`newgidmap` step (install fails during
>   image unpack, e.g. "potentially insufficient UIDs or GIDs"). Check with
>   `sysctl user.max_user_namespaces`; if it's `0`:
>
>   ```sh
>   echo 'user.max_user_namespaces=15000' > /etc/sysctl.d/90-userns.conf && sysctl --system
>   ```
>
> - **Non-LVE hosts (AlmaLinux / RHEL / Ubuntu): cgroup v2 is preferred** — its
>   unified hierarchy gives the user systemd manager proper cgroup-subtree
>   delegation, so resource limits apply cleanly. cgroup v1 still works.
>   AlmaLinux / RHEL 9+ and Ubuntu already default to cgroup v2. **AlmaLinux /
>   RHEL 8** default to cgroup v1; to move to v2, add the kernel arg and reboot:
>
>   ```sh
>   grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
>   reboot
>   # verify after reboot — should print cgroup2fs:
>   stat -fc %T /sys/fs/cgroup
>   ```
>
>   If `stat` still reports `tmpfs` after the reboot, the image is booting from a
>   **static `grub.cfg`** (no BLS), so `grubby` was silently ignored — common on
>   cloud images. Confirm with `grep unified_cgroup_hierarchy /proc/cmdline`
>   (empty = not applied). In that case set the arg in `/etc/default/grub` —
>   append `systemd.unified_cgroup_hierarchy=1` to `GRUB_CMDLINE_LINUX` — then
>   regenerate the config and reboot:
>
>   ```sh
>   grub2-mkconfig -o "$(readlink -f /etc/grub2.cfg)"       # BIOS
>   grub2-mkconfig -o "$(readlink -f /etc/grub2-efi.cfg)"   # UEFI
>   reboot
>   ```

## The verbs

| Function    | Purpose                                              | Arguments |
|-------------|------------------------------------------------------|-----------|
| `list`      | List the caller's registered containers (read-only). | — |
| `install`   | Install and start a container.                        | `name` (required), `image`, `cpuser_port` (repeatable), `env` (repeatable, `KEY=VALUE`), `accept_arbitrary_image_risk` |
| `upgrade`   | Pull the latest image and recreate a container.       | `container_name` (required) |
| `uninstall` | Stop, remove, deregister a container; free its ports. | `container_name` (required) |
| `start`     | Start the container's systemd user service.           | `container_name` (required) |
| `stop`      | Stop the container's systemd user service.            | `container_name` (required) |
| `restart`   | Restart the container's systemd user service.         | `container_name` (required) |
| `status`    | Report a container's service state (read-only).       | `container_name` (required) |
| `cmd`       | Run a one-shot, non-interactive command in a container. | `container_name` (required), `arg` (required, repeatable), `cd` |

### `install` arguments

- **`name`** (required) — an EA4 container-based package name, or an arbitrary
  container name.
- **`image`** — the container image. Required for an arbitrary name; omit for an
  EA4 package (which supplies its own image).
- **`cpuser_port`** — a port *inside the container* to publish; may be given
  more than once. The **host** port is assigned by the cPanel port authority (it
  is not necessarily the same number); the published mapping is
  `<assigned_host_port>:<cpuser_port>`. `0` means "use the assigned host port
  number as the container port too".
- **`env`** — an environment variable as a single `KEY=VALUE` string; may be
  given more than once. Pass it verbatim from the `uapi` CLI, the cPanel
  interface, or LiveAPI. Only in a hand-built URL query string (the raw `curl`
  examples below) must the `=` *inside the value* be percent-encoded as `%3D`,
  so it is not read as the query-string `key=value` separator — e.g. the value
  `TZ=UTC` becomes `env=TZ%3DUTC`. A proper HTTP client encodes this for you.
- **`accept_arbitrary_image_risk`** — boolean; required to install an arbitrary
  (non-EA4-package) image, acknowledging the trust/reliability caveats.

`install` returns the generated container name in `data.container_name`
(e.g. `myapp.bob.01`). It is synchronous, so installing an image that must be
pulled can take a while. `upgrade` pulls a fresh image too and is slow in the
same way.

`status` returns `data.running` and `data.enabled` booleans (the container's
systemd user-service state), rather than the human-readable `systemctl status`
text.

### `cmd` arguments

- **`container_name`** (required) — the container to run the command in.
- **`arg`** (required, repeatable) — the command and its arguments, in order,
  e.g. `arg=date`, or `arg=ls&arg=-la` for `ls -la`. Exec'd directly inside the
  container as a list — no shell (host or container) ever interprets it, so it
  works even in a container without `/bin/bash`. A caller who wants shell
  semantics (pipes, `&&`, redirection) can still get them by naming a shell
  explicitly, e.g. `arg=/bin/sh&arg=-c&arg=cd /tmp && ls`.
- **`cd`** — an optional working directory inside the container. When given, the
  command is run from that directory via the container's `/bin/sh`
  (`cd DIR && exec …`); without `cd`, no shell is used at all.

`cmd` returns `data.stdout`, `data.stderr`, `data.exit_code` (the exec'd
command's own exit status — not the UAPI call's success/failure), and
`data.stdout_truncated` / `data.stderr_truncated` (true if the captured output
was cut off at the output size cap).

## How to call it

### 0. From the `ea-podman` CLI (jailshell accounts)

A jailshell account can simply run the `ea-podman` command for the supported
verbs (`install`, `upgrade`, `list`, `start`, `stop`, `restart`, `uninstall`,
`status`, `cmd`); the CLI
detects the restricted shell and routes the call through this UAPI for them —
no tokens or extra steps. Other CLI subcommands still require an unrestricted
shell. (Unrestricted-shell accounts and root run the CLI directly, as before.)

### 1. From the cPanel interface

Any UI or integration that calls cPanel UAPI as the logged-in user can invoke
the `EAPodman` module functions. This is the normal path for end users,
including jailshell and CageFS accounts.

### 2. With a cPanel API token (HTTPS `execute` endpoint)

Create a token in cPanel (Security ▸ Manage API Tokens), then:

```sh
TOKEN=...                       # the cPanel account's API token
USER=bob                        # the cPanel account name

# install a redis container, publishing container port 6379 and setting the
# env var TZ=UTC (note env's own "=" is encoded as %3D, giving env=TZ%3DUTC)
curl -sk -H "Authorization: cpanel $USER:$TOKEN" \
  "https://HOSTNAME:2083/execute/EAPodman/install?name=myredis&image=docker.io%2Flibrary%2Fredis%3Aalpine&cpuser_port=6379&env=TZ%3DUTC&accept_arbitrary_image_risk=1"

# list the account's containers
curl -sk -H "Authorization: cpanel $USER:$TOKEN" \
  "https://HOSTNAME:2083/execute/EAPodman/list"

# lifecycle / cleanup
curl -sk -H "Authorization: cpanel $USER:$TOKEN" \
  "https://HOSTNAME:2083/execute/EAPodman/restart?container_name=myredis.$USER.01"
curl -sk -H "Authorization: cpanel $USER:$TOKEN" \
  "https://HOSTNAME:2083/execute/EAPodman/uninstall?container_name=myredis.$USER.01"
```

A repeatable argument is just the same name given more than once, e.g.
`cpuser_port=6379&cpuser_port=6380` and — with the `=` in each
`KEY=VALUE` percent-encoded as `%3D`, as noted above —
`env=FOO%3D1&env=BAR%3D2` (i.e. `FOO=1` and `BAR=2`). (The older
`key-1`, `key-2`, … numbered form is also accepted, but the plain repeated
name is simpler.)

### 3. As root, on behalf of an account (`uapi` CLI)

```sh
uapi --user=bob --output=json EAPodman install \
    name=myredis image=docker.io/library/redis:alpine \
    cpuser_port=6379 env=TZ=UTC accept_arbitrary_image_risk=1   # env passed verbatim, no %3D

uapi --user=bob --output=json EAPodman list
uapi --user=bob --output=json EAPodman status  container_name=myredis.bob.01
uapi --user=bob --output=json EAPodman stop    container_name=myredis.bob.01
uapi --user=bob --output=json EAPodman start   container_name=myredis.bob.01
uapi --user=bob --output=json EAPodman upgrade container_name=myredis.bob.01
uapi --user=bob --output=json EAPodman uninstall container_name=myredis.bob.01
uapi --user=bob --output=json EAPodman cmd container_name=myredis.bob.01 arg=date
```

## Response shape

UAPI wraps the result in the standard envelope; the function payload is under
`result.data` with `result.status` (`1` = success) and `result.errors`:

```json
{
  "result": {
    "status": 1,
    "data": { "container_name": "myredis.bob.01" },
    "errors": null
  }
}
```

`list` returns `data` as an object keyed by container name. `status` returns
`data` as `{ "running": 0|1, "enabled": 0|1 }`. `cmd` returns `data` as
`{ "stdout": "...", "stderr": "...", "exit_code": 0, "stdout_truncated": false, "stderr_truncated": false }`.
