# Backing up and restoring ea-podman containers

A cPanel account's files and databases are backed up by cPanel already. An
ea-podman container is **not** recoverable from that backup — not because the
relevant bytes are missing, but because a container is not a pile of files. It is
a *registration* (root-owned, outside the homedir), a *port assignment* (root-
managed, outside the homedir), a *subuid/subgid range* (`/etc/subuid`), a
*lingering user systemd session*, a *generated unit file*, and an *image pulled
from a registry* — plus a per-user podman store that ea-podman deliberately
**excludes** from cPanel backups.

So `ea-podman` ships its own backup/restore pair (`ea-podman backup`,
`ea-podman restore`, ZC-9877) plus a `PkgAcct::Create` hook (ZC-11180) that runs
the backup automatically whenever cPanel packages the account. This document
explains what is missing from a file-and-database backup, why, how the tool's
backup/restore actually work, and when to use them.

See `DESIGN.md` for the broader internals, `docs/uapi.md` for the UAPI surface,
and `VIRTFS-BUSY.md` for the container-storage mount hazard referenced below.

## TL;DR

* A file+DB backup restores `~/ea-podman.d/` and nothing else that matters. The
  account ends up with the container's *data* on disk and **no container**: not
  registered, no ports, no service, nothing running.
* ea-podman therefore backs up the **declaration**, not the runtime: a JSON
  manifest of the account's registered containers (owner, package, package
  version, image, webapp flag, currently assigned ports) plus the whole
  `~/ea-podman.d/` tree, tarred into `~/ea-podman-backups/`.
* `ea-podman restore` **rebuilds** each container from that declaration — subids
  and linger, registration, fresh port assignments, `podman create` (re-pulling
  the image), a regenerated systemd unit, start.
* Restore is destructive and requires `--verify`. It removes the account's
  existing containers and wipes `~/ea-podman.d` and `~/.config/systemd/user`
  first.
* Ports are **reallocated**, not preserved. Restore warns when they differ from
  what was recorded.
* The automatic hook covers backup only. **Nothing restores containers
  automatically** — after a `restorepkg`/transfer, a human must run
  `ea-podman restore`.

## What a container is made of, and who backs it up

| State | Where it lives | In a normal file/DB backup? | Usable if it were? |
|---|---|---|---|
| Container's own data / config / web app | `~/ea-podman.d/<container>/` (`ea-podman.json`, `-v` targets, `webapp/`) | Yes | Yes — this is the part that genuinely is "just files" |
| Registration: owner, pkg, pkg version, image, `webapp` flag | `/opt/cpanel/ea-podman/registered-containers.json` (root-owned) — `SOURCES/util.pm:61` | **No** — outside every homedir | n/a |
| TCP port assignments + firewall rules | cPanel port authority (`/scripts/cpuser_port_authority`), root-managed | **No** | n/a |
| subuid/subgid range | `/etc/subuid`, `/etc/subgid` — `SOURCES/subids.pm:46` | **No** | Not portable — ranges are per-host and assigned in allocation order |
| Lingering user session (`/run/user/<uid>`, `user@<uid>.service`) | runtime state, created by `loginctl enable-linger` — `SOURCES/subids.pm:105` | **No** (ephemeral by design) | n/a |
| systemd unit `container-<name>.service` | `~/.config/systemd/user/` | **No** — ea-podman excludes it on purpose | No — it names a container ID that will not exist after a rebuild |
| Podman per-user store (image layers, container metadata, volumes) | `~/.local/share/containers/` | **No** — ea-podman excludes it on purpose | No — see below |
| The image itself | A remote registry (`docker.io/...`) | No | n/a — re-pulled on restore |

The two homedir exclusions are written and maintained by ea-podman itself:
`_ensure_backup_conf_excludes_files()` (`SOURCES/util.pm:1266`) idempotently
appends `.local/share/containers` and `.config/systemd` to
`~/cpbackup-exclude.conf` (or absolute paths in `/etc/cpbackup-exclude.conf` when
run as root) on **every** install, upgrade, and restore — it is called from
`_ensure_latest_container()` (`SOURCES/util.pm:515`), so it self-heals if a user
edits the file.

### Why the podman store is excluded rather than backed up

1. **The account cannot read its own store.** Rootless podman writes layers using
   the user's *subuids* (190000+, `SOURCES/subids.pm:46`). Those files are not
   owned by the cpuser, so a cpuser-level backup cannot archive them faithfully —
   this is the same surprise documented in `README.md` ("There are files in my
   home directory that I don't own").
2. **Even a perfect copy is wrong on arrival.** Subuid ranges are allocated
   per-host in first-come order. Restoring layer trees owned by uid 190000-255536
   onto a machine where the account got a different range yields a store whose
   ownership is meaningless.
3. **It is large and fully reproducible.** Every byte is derivable from the image
   reference, which the manifest and `ea-podman.json` already record.
4. **It may be mounted while you back it up.** Overlay `merged` mounts are live
   for running containers, and on a host with jailshell users cPanel's virtfs can
   replicate container-storage mounts into jails — the `EBUSY` failure mode
   described in `VIRTFS-BUSY.md`. Archiving a live overlay tree is at best
   inconsistent.

The generated unit file is excluded for a simpler reason: `podman generate
systemd --name` (`SOURCES/util.pm:497`) bakes in the container's identity, so the
correct unit after a restore is a **newly generated** one, not the old one.

## The model: back up the declaration, rebuild the container

Backup captures what is needed to *re-derive* a container. Restore performs the
same code path as an install/upgrade, flagged as a restore.

### `ea-podman backup`

`SOURCES/ea-podman.pl:724` → `perform_user_backup()` (`SOURCES/util.pm:1328`).
Refuses to run as root (`$> == 0` dies — see "Root's own containers" below).

1. Load the root-owned registry (via the `REGISTERED_CONTAINERS` adminbin) and
   keep only this user's entries. No containers → prints "There are no
   containers" and stops.
2. For each container, ask the port authority which ports it currently holds
   (`_get_current_ports()`, `SOURCES/util.pm:858`) and record them as
   `curr_ports`. This is the only place that assignment is captured.
3. Write the manifest to `~/ea_podman_backup_<user>.json`.
4. `tar czf ~/ea-podman-backups/backup-<YYYYMMDDHHMMSS>.tar.gz
   ea_podman_backup_<user>.json ea-podman.d` (timestamp is UTC), then **unlink
   the loose JSON** — the manifest only ever persists inside a tarball.
5. Prune: keep the newest `$num_backups_to_retain` = **3** tarballs
   (`SOURCES/util.pm:1326`). The condensed timestamp sorts lexically, so
   `reverse sort` is chronological.

A manifest entry is a registry record plus ports:

```json
[
   {
      "container_name" : "ea-tomcat100.bob.01",
      "user"           : "bob",
      "pkg"            : "ea-tomcat100",
      "pkg_version"    : "10.0.14-1.cp2211",
      "image"          : "tomcat:10.0.14",
      "webapp"         : false,
      "curr_ports"     : [ 10001, 10002, 10003 ]
   }
]
```

Because the tarball lands **inside the homedir**, cPanel's own homedir archive
carries it along for free — which is the whole point of the hook below.

### `ea-podman restore <TARBALL> --verify`

`SOURCES/ea-podman.pl:738` → `perform_user_restore()` (`SOURCES/util.pm:1387`).
Also refuses to run as root. `--verify` is mandatory; without it the command
prints a warning and does nothing.

1. **Tear down.** `ea-podman remove_containers --all`, then `remove_tree` on
   `~/ea-podman.d` **and** `~/.config/systemd/user`. This is unconditional and
   irreversible — it is why `--verify` exists.
2. **Unpack** the tarball into the homedir, restoring `ea-podman.d/` and the
   manifest.
3. **Validate.** The manifest must be present, and every container directory it
   names must exist, or the restore dies before touching podman.
4. **Re-establish the account's rootless plumbing.** `init_user()`
   (`SOURCES/util.pm:17`) → `ensure_user()` allocates subuid/subgid if missing
   and runs `loginctl enable-linger` (creating `/run/user/<uid>` and starting the
   user systemd manager), then `ensure_su_login()` points this process at it.
   This is exactly the state a file backup cannot carry, and it is re-created
   here from scratch.
5. **Rebuild each container** — `restore_containers_for_user()`
   (`SOURCES/util.pm:985`) calls `_ensure_latest_container()` per container with
   `$isrestore = 1` (`SOURCES/util.pm:528`). Per container that means:
   * Replay `start_args` from the restored
     `~/ea-podman.d/<container>/ea-podman.json`; for an EA4 container-based
     package, merge in the **currently installed** package's
     `/opt/cpanel/<pkg>/ea-podman.json` (image, `-v`, `-e`, ports).
   * Allocate **new** ports from the port authority (`_get_new_ports()`,
     `SOURCES/util.pm:885`) and build the `-p` flags.
   * Skip the package's `ea-podman-local-dir-setup` / `-upgrade` hooks entirely
     (`SOURCES/util.pm:608`) — the directory contents came from the tarball and
     must not be re-scaffolded.
   * `uninstall_container()`, then re-`register_container()` in the root-owned
     registry, then `podman create` (pulling the image), `podman generate
     systemd`, `systemctl --user enable`, `start`.
6. **Report port drift.** For each container, compare the newly assigned ports
   against the manifest's `curr_ports` and warn per container when they differ
   (`SOURCES/util.pm:1455`), because anything configured against the old ports —
   a proxy rule, a `.htaccess`, an application config, a firewall exception — is
   now pointing at nothing.

## Automatic backup during pkgacct

`PodmanHooks.pm` registers a **pre** `PkgAcct::Create` hook
(`SOURCES/PodmanHooks.pm:62`) → `_do_backup()` (`SOURCES/PodmanHooks.pm:143`).
Pre-stage matters: the tarball has to exist in the homedir *before* cPanel
archives the homedir.

For a non-root account the hook does **not** call the backup directly — it
shells out to `/scripts/ea-podman rootbackupofuser <user>`
(`SOURCES/ea-podman.pl:788`), which drops to the user with
`Cpanel::AccessIds` and runs `perform_user_backup()` there. The comment in the
hook gives the reason: `/scripts/pkgacct` runs under the cPanel binaries and
cannot invoke adminbin calls, and the backup needs adminbin
(`REGISTERED_CONTAINERS`, `LIST`) to read root-owned state. The shell-out is also
why `/usr/local/cpanel/bin/pkgacct` appears in `allowed_parents` in
`SOURCES/ea-podman-adminbin.conf:2`.

This path runs as root before dropping privileges, so it **bypasses the
restricted-shell gate** — jailshell and CageFS accounts get backed up
automatically even though they cannot run `ea-podman backup` themselves.

Two details worth knowing about the cPanel side:

* `/usr/local/cpanel/scripts/pkgacct` applies `~/cpbackup-exclude.conf` and
  `/etc/cpbackup-exclude.conf` **only in backup modes** (`--backup` /
  `--userbackup`; `pkgacct:1648`, and `isbackup` at `pkgacct:273`). A plain
  `cpmove-` package run does not apply them, so a transfer archive can contain
  `~/.local/share/containers` — bloat that restore ignores, since it rebuilds the
  store from the image.
* There is **no restore-side hook**. Nothing in this package or in cPanel
  (`grep` for `ea-podman` under `/usr/local/cpanel` finds only the `EAPodman`
  UAPI module) reacts to `restorepkg`. A restored account has its
  `~/ea-podman.d/` and its `~/ea-podman-backups/*.tar.gz` back on disk, and zero
  containers.

## When to use it

Run `ea-podman backup` (or let the hook run it) **before**:

* Upgrading or reinstalling an EA4 container-based package, or running
  `ea-podman upgrade` — the upgrade replays `start_args` and re-creates the
  container against a new image.
* Any hand-editing of `~/ea-podman.d/<container>/ea-podman.json` or the mounted
  data directories.
* `ea-podman remove_containers`, or any account-level operation that will tear
  containers down.

Run `ea-podman restore <tarball> --verify` **after**:

* A bad upgrade or a broken hand-edit — roll back to the previous declaration on
  the same server (this is what the 3-tarball retention is for).
* An account restore or transfer (`restorepkg` / cpmove). This is the main
  event: the account arrives with `~/ea-podman.d/` and
  `~/ea-podman-backups/` populated and nothing registered or running. Pick the
  newest tarball in `~/ea-podman-backups/` and restore it. Expect new ports.
* A host-level loss of the registry or the podman store.

Do **not** reach for it to recover data that lives *inside* the container but
outside `~/ea-podman.d/` — see the limitations.

### Rough shape of a transfer

```sh
# On the destination, as root, after the account has been restored:
ls -t ~bob/ea-podman-backups/       # newest tarball first
ea-podman containers --all          # registry — bob's containers are absent

# As the account (unrestricted shell required — see limitations):
ea-podman restore ~/ea-podman-backups/backup-20260803120000.tar.gz --verify
ea-podman containers                # registry entries are back
ea-podman list                      # running containers, with their new ports
```

Then reconcile whatever referenced the old ports; the restore output names the
old and new sets per container.

## Limitations and sharp edges

* **Data that only exists inside the container is not backed up.** Only
  `~/ea-podman.d/` is captured. Anything a container writes to a path that is not
  a host bind mount under that directory lives in the podman store and is gone on
  restore. Containers must keep their state in `-v` mounts under
  `<CONTAINERS-HOST-PATH>` (see `DESIGN.md`) to be recoverable at all. A database
  running in a container follows the same rule — its datadir must be a mount, and
  a mount snapshot of a *running* database is a crash-consistent copy, not a dump.
* **Ports change.** Restore always allocates fresh ports. Treat the warning as a
  to-do list.
* **Image tags float.** Restore re-pulls whatever the recorded reference resolves
  to *now*. A container installed against `:latest` can come back on a different
  version — which is precisely why `README.md` and `DESIGN.md` push
  version-specific tags. For an EA4 package the image comes from the *currently
  installed* package's `ea-podman.json`, not from the manifest, so restoring onto
  a host with a newer package lands on the newer image. The manifest's `image` and
  `pkg_version` are a record of what was, useful for diagnosis.
* **Root's own containers are not covered.** `backup` and `restore` both die for
  `$> == 0` ("not allowed for the root user at this time",
  `SOURCES/ea-podman.pl:734` and `:752`), and the pkgacct hook's root branch only
  reaches `perform_user_backup()`, which itself dies as root
  (`SOURCES/util.pm:1331`). Containers root runs for itself must be handled by
  hand.
* **Restricted-shell accounts cannot restore themselves.** For a jailshell or
  CageFS account the CLI routes to the UAPI bridge, whose verb list is
  `install upgrade list start stop restart uninstall status cmd`
  (`SOURCES/ea-podman.pl:147`) — `backup` and `restore` are absent, so the
  command is refused. The gate keys on the account's *configured* shell, so
  `su -s /bin/bash` does not evade it, and running as root hits the "not allowed
  for the root user" check. Backup has a root-side driver
  (`rootbackupofuser`); **restore has no equivalent**. Restoring such an account
  today means temporarily giving it an unrestricted shell, or reinstalling its
  containers with `ea-podman install` and letting the restored
  `~/ea-podman.d/<container>/` supply the data.
* **The `webapp` registry flag does not survive a cross-server restore.** It is
  established at install time only and, on upgrade/restore, is read back from the
  existing registry entry (`SOURCES/util.pm:1076`). On the same host it is
  preserved; on a fresh host with no registry entry a restored web-app container
  is recorded as `webapp: false`.
* **Username changes are blocked, not migrated.** Container names embed the user
  (`<name>.<user>.<NN>`), so `Accounts::Modify` is refused pre-hook for any
  account with containers (`SOURCES/PodmanHooks.pm:101`); `rename_containers()`
  is still a stub (`SOURCES/util.pm:904`, ZC-9694). A backup taken as `bob`
  cannot be restored as `bob2`.
* **Only 3 tarballs are kept**, and each automatic pkgacct run consumes a slot.
  Copy anything you want to keep longer out of `~/ea-podman-backups/`.
* **Teardown does not unmount.** Restore's `remove_tree({ safe => 0 })` on
  `~/ea-podman.d` and `~/.config/systemd/user` has no unmount/retry, so a
  lingering overlay or bind mount can surface `EBUSY` mid-restore. See
  "Related hardening in ea-podman" in `VIRTFS-BUSY.md`.

## Related

* `DESIGN.md` — container layout, `ea-podman.json`, package hooks, naming.
* `README.md` — user-facing overview, subuid file-ownership FAQ.
* `docs/uapi.md` — the `EAPodman` UAPI surface used by restricted accounts.
* `docs/container-shell-access.md` — why restricted accounts are gated, and how
  the shell/`cmd` paths differ.
* `VIRTFS-BUSY.md` — container-storage mounts pinned by virtfs jails.
