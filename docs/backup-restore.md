# Backing up and restoring ea-podman containers

cPanel already backs up an account’s files and databases. An ea-podman container
is **not** recoverable from that backup, because a container isn’t a pile of
files — it’s a root-owned registration, a root-managed port assignment, a
subuid/subgid range, a lingering user systemd session, a generated unit file, and
an image pulled from a registry, plus a per-user podman store that ea-podman
deliberately **excludes** from cPanel backups.

So ea-podman ships its own `backup`/`restore` pair (ZC-9877) and a
`PkgAcct::Create` hook that runs the backup automatically (ZC-11180).

See `DESIGN.md` for internals, `docs/uapi.md` for the UAPI surface, and
`VIRTFS-BUSY.md` for the container-storage mount hazard noted below.

## TL;DR — what you actually have to do

**To be backed up reliably:**

1. **Keep all container state in `-v` mounts under `~/ea-podman.d/<container>/`.**
   This is the only rule you can get wrong permanently. Anything a container
   writes elsewhere lives in the podman store and is **gone** on restore. A
   containerized database is no exception: its datadir must be a mount, and a
   snapshot of a live datadir is crash-consistent, not a dump — dump it yourself
   if you need better.
2. **Pin version-specific image tags** (`:10.0.14`, not `:latest`). Restore
   re-pulls, so a floating tag comes back on a different version.
3. **Let the hook do the rest** — every `pkgacct` run (account backup or
   transfer) backs up containers automatically, including for jailshell/CageFS
   accounts. Nothing to configure.
4. **Run `ea-podman backup` by hand before anything risky**: `ea-podman upgrade`,
   a package upgrade/reinstall, hand-edits to `ea-podman.json` or the mounted
   data dirs, `ea-podman remove_containers`. Only **3** tarballs are kept in
   `~/ea-podman-backups/`, and each automatic pkgacct run consumes a slot — copy
   anything you want to keep longer somewhere else.

**To restore reliably** (nothing restores containers automatically — not even
`restorepkg`; a human must do this):

```sh
# 1. As root, on the destination, after the account has been restored:
ls -t ~bob/ea-podman-backups/       # newest tarball first
ea-podman containers --all          # confirm bob has no registered containers

# 2. As the account — needs an unrestricted shell (see Limitations):
ea-podman restore ~/ea-podman-backups/backup-20260803120000.tar.gz --verify
ea-podman containers                # registry entries are back
ea-podman list                      # running containers and their NEW ports
```

5. **`--verify` is mandatory and the operation is destructive**: it removes the
   account’s existing containers and wipes `~/ea-podman.d` and
   `~/.config/systemd/user` before unpacking.
6. **Expect new ports.** Restore always reallocates and warns per container when
   they differ. Fix whatever referenced the old ones — proxy rules, app configs,
   firewall exceptions.
7. **Restoring root’s own containers, or a jailshell/CageFS account’s, is not
   supported** by these commands. See Limitations.

## Why a file and database backup isn’t enough

| State | Where it lives | In a file/DB backup? | Usable if it were? |
|---|---|---|---|
| Container data, config, web app | `~/ea-podman.d/<container>/` | Yes | Yes — the one part that really is just files |
| Registration: owner, pkg, pkg version, image, `webapp` flag | `/opt/cpanel/ea-podman/registered-containers.json`, root-owned (`SOURCES/util.pm:61`) | **No** — outside every homedir | n/a |
| TCP port assignments + firewall | cPanel port authority, root-managed | **No** | n/a |
| subuid/subgid range | `/etc/subuid`, `/etc/subgid` (`SOURCES/subids.pm:46`) | **No** | No — assigned per host in allocation order |
| Lingering session (`/run/user/<uid>`, `user@<uid>.service`) | runtime state (`SOURCES/subids.pm:105`) | **No** (ephemeral by design) | n/a |
| Unit file `container-<name>.service` | `~/.config/systemd/user/` | **No** — excluded on purpose | No — names a container ID that won’t exist after a rebuild |
| Podman store (layers, container metadata) | `~/.local/share/containers/` | **No** — excluded on purpose | No — see below |
| The image | a remote registry | No | n/a — re-pulled on restore |

Restore `~/ea-podman.d/` alone and the account has the container’s *data* and no
container: nothing registered, no ports, no service, nothing running.

The two homedir exclusions are ea-podman’s own doing:
`_ensure_backup_conf_excludes_files()` (`SOURCES/util.pm:1266`) idempotently adds
`.local/share/containers` and `.config/systemd` to `~/cpbackup-exclude.conf` (or
absolute paths in `/etc/cpbackup-exclude.conf` as root) on **every** install,
upgrade, and restore — so it self-heals if a user edits the file.

The podman store is excluded rather than archived because:

1. **The account can’t read its own store.** Rootless podman writes layers using
   the user’s *subuids* (190000+), so a cpuser-level backup can’t archive them
   faithfully — the same surprise as the “files I don’t own” FAQ in `README.md`.
2. **A perfect copy is still wrong on arrival.** Subuid ranges are per-host and
   first-come; layers owned by another host’s range are meaningless.
3. **It’s large and fully reproducible** from the image reference, which the
   manifest and `ea-podman.json` already record.
4. **It may be mounted while you copy it.** Overlay `merged` mounts are live for
   running containers, and virtfs can replicate them into jailshell jails — the
   `EBUSY` case in `VIRTFS-BUSY.md`.

The unit file is excluded for a simpler reason: `podman generate systemd --name`
(`SOURCES/util.pm:497`) bakes in the container’s identity, so the correct unit
after a restore is a newly generated one.

## How it works: back up the declaration, rebuild the container

### `ea-podman backup`

`SOURCES/ea-podman.pl:724` → `perform_user_backup()` (`SOURCES/util.pm:1328`).
Dies as root.

1. Load the root-owned registry (via the `REGISTERED_CONTAINERS` adminbin), keep
   this user’s entries.
2. Ask the port authority which ports each container holds
   (`_get_current_ports()`, `SOURCES/util.pm:858`) and record them as
   `curr_ports` — the only place that assignment is captured.
3. Write the manifest to `~/ea_podman_backup_<user>.json`.
4. `tar czf ~/ea-podman-backups/backup-<YYYYMMDDHHMMSS>.tar.gz` over the manifest
   plus all of `ea-podman.d` (timestamp is UTC), then **unlink the loose JSON** —
   the manifest only ever persists inside a tarball.
5. Keep the newest 3 tarballs (`$num_backups_to_retain`, `SOURCES/util.pm:1326`).

A manifest entry is a registry record plus ports:

```json
{
   "container_name" : "ea-tomcat100.bob.01",
   "user"           : "bob",
   "pkg"            : "ea-tomcat100",
   "pkg_version"    : "10.0.14-1.cp2211",
   "image"          : "tomcat:10.0.14",
   "webapp"         : false,
   "curr_ports"     : [ 10001, 10002, 10003 ]
}
```

The tarball lands **inside the homedir**, so cPanel’s own homedir archive carries
it for free — which is the whole point of the hook.

### `ea-podman restore <TARBALL> --verify`

`SOURCES/ea-podman.pl:738` → `perform_user_restore()` (`SOURCES/util.pm:1387`).
Dies as root.

1. **Tear down** — `remove_containers --all`, then `remove_tree` on
   `~/ea-podman.d` **and** `~/.config/systemd/user`. Unconditional; this is why
   `--verify` exists.
2. **Unpack** into the homedir, then require the manifest and every container
   directory it names, or die before touching podman.
3. **Re-establish the rootless plumbing** — `init_user()` (`SOURCES/util.pm:17`)
   allocates subuid/subgid if missing and runs `loginctl enable-linger`, creating
   `/run/user/<uid>` and starting the user systemd manager. This is exactly the
   state a file backup can’t carry, rebuilt from scratch.
4. **Rebuild each container** — `restore_containers_for_user()`
   (`SOURCES/util.pm:985`) runs the install/upgrade code path with
   `$isrestore = 1` (`SOURCES/util.pm:528`): replay `start_args` from the restored
   `ea-podman.json` (merging the *currently installed* package’s
   `/opt/cpanel/<pkg>/ea-podman.json` for EA4 packages), allocate **new** ports
   (`_get_new_ports()`, `SOURCES/util.pm:885`), skip the package’s
   `local-dir-setup`/`-upgrade` hooks so the restored directory isn’t
   re-scaffolded (`SOURCES/util.pm:608`), re-register, `podman create` (pulling
   the image), regenerate the unit, enable, start.
5. **Report port drift** against the manifest’s `curr_ports`
   (`SOURCES/util.pm:1455`).

### Automatic backup during pkgacct

A **pre** `PkgAcct::Create` hook (`SOURCES/PodmanHooks.pm:62`) → `_do_backup()`
(`SOURCES/PodmanHooks.pm:143`). Pre-stage matters: the tarball must exist before
cPanel archives the homedir.

For a non-root account the hook shells out to
`/scripts/ea-podman rootbackupofuser <user>` (`SOURCES/ea-podman.pl:788`), which
drops to the user via `Cpanel::AccessIds`. The reason is in the hook’s own
comment: `/scripts/pkgacct` can’t invoke adminbin calls, and the backup needs
adminbin to read root-owned state — which is also why
`/usr/local/cpanel/bin/pkgacct` is in `allowed_parents`
(`SOURCES/ea-podman-adminbin.conf:2`). Because this starts as root it bypasses the
restricted-shell gate, so jailshell and CageFS accounts do get backed up.

Two cPanel-side notes:

* `pkgacct` applies the exclude files **only** in backup modes (`--backup` /
  `--userbackup`; `pkgacct:1648`, `pkgacct:273`). A plain `cpmove-` run doesn’t,
  so a transfer archive can carry `~/.local/share/containers` — bloat that
  restore ignores, since it rebuilds the store from the image.
* There is **no restore-side hook**. Nothing in this package or in cPanel reacts
  to `restorepkg`; a restored account has its `~/ea-podman.d/` and its tarballs
  back on disk and zero containers.

## Limitations and sharp edges

* **Only `~/ea-podman.d/` is captured.** State written anywhere else inside the
  container is gone on restore (see TL;DR #1).
* **Ports always change**; treat the warning as a to-do list.
* **Image tags float**, and for an EA4 package the image comes from the
  *currently installed* package’s `ea-podman.json`, not the manifest — restoring
  onto a host with a newer package lands on the newer image. The manifest’s
  `image`/`pkg_version` are a record of what was, useful for diagnosis.
* **Root’s own containers aren’t covered.** `backup` and `restore` die for
  `$> == 0` (`SOURCES/ea-podman.pl:734`, `:752`), and the hook’s root branch
  reaches `perform_user_backup()`, which also dies as root
  (`SOURCES/util.pm:1331`). Handle those by hand.
* **Restricted-shell accounts can’t restore themselves.** For jailshell/CageFS
  the CLI routes to the UAPI bridge, whose verbs are
  `install upgrade list start stop restart uninstall status cmd`
  (`SOURCES/ea-podman.pl:147`) — `backup`/`restore` are absent, so it’s refused.
  The gate keys on the account’s *configured* shell, so `su -s /bin/bash` doesn’t
  evade it, and running as root hits the root check. Backup has a root-side
  driver (`rootbackupofuser`); **restore has no equivalent.** Today that means
  temporarily giving the account an unrestricted shell, or re-running
  `ea-podman install` and letting the restored `~/ea-podman.d/<container>/`
  supply the data.
* **The `webapp` registry flag doesn’t survive a cross-server restore.** It’s set
  at install time only and, on upgrade/restore, read back from the existing
  registry entry (`SOURCES/util.pm:1076`). Same host: preserved. Fresh host with
  no entry: recorded as `webapp: false`.
* **Username changes are blocked, not migrated.** Container names embed the user,
  so `Accounts::Modify` is refused for any account with containers
  (`SOURCES/PodmanHooks.pm:101`) and `rename_containers()` is still a stub
  (`SOURCES/util.pm:904`, ZC-9694). A backup taken as `bob` can’t be restored as
  `bob2`.
* **Teardown doesn’t unmount.** Restore’s `remove_tree({ safe => 0 })` has no
  unmount/retry, so a lingering overlay or bind mount can surface `EBUSY`
  mid-restore. See “Related hardening in ea-podman” in `VIRTFS-BUSY.md`.

## Related

* `DESIGN.md` — container layout, `ea-podman.json`, package hooks, naming.
* `README.md` — user-facing overview, subuid file-ownership FAQ.
* `docs/uapi.md` — the `EAPodman` UAPI surface used by restricted accounts.
* `docs/container-shell-access.md` — why restricted accounts are gated.
* `VIRTFS-BUSY.md` — container-storage mounts pinned by virtfs jails.
