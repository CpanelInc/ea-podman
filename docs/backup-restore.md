# Backing up and restoring ea-podman containers

cPanel already backs up an account’s files and databases. An ea-podman container
is **not** recoverable from that backup, because a container isn’t a pile of
files — it’s a root-owned registration, a root-managed port assignment, a
subuid/subgid range, a lingering user systemd session, a generated unit file, and
an image pulled from a registry, plus a per-user podman store that ea-podman
deliberately **excludes** from cPanel backups.

So ea-podman ships its own `backup`/`restore` pair (ZC-9877) and a
`PkgAcct::Create` hook that runs the backup automatically (ZC-11180).

Code references below name a file and a symbol, never a line number — grep for
the symbol. `t/docs-backup-restore.t` enforces that and fails if one of them
stops resolving.

## TL;DR — what you actually have to do

**To be backed up reliably:**

1. **Keep all container state in `-v` mounts under `~/ea-podman.d/<container>/`.**
   This is the only rule you can get wrong permanently. Whatever the container
   writes to a path that is *not* bind-mounted lands in its writable layer in the
   podman store, which is never archived and is **gone** on restore. A `-v` mount
   pointing somewhere else is replayed on restore, but its contents are not in the
   tarball — they come back only if something else backed that path up. A
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

**To restore** — nothing restores containers for you, not even `restorepkg`; a
human must do this:

1. Install every EA4 package the account’s containers use on the destination
   first (`ea-podman avail` lists them). Restore dies on the first container
   whose package is missing, and it does not roll back.
2. As root, once the account itself has been restored:

   ```sh
   ls -t ~bob/ea-podman-backups/       # newest tarball first
   ea-podman containers --all          # confirm bob has no registered containers
   ```

3. As the account, from an unrestricted shell (see Limitations). `--verify` is
   required because the teardown is destructive: it removes the account’s
   existing containers and wipes `~/ea-podman.d` and `~/.config/systemd/user`
   before unpacking.

   ```sh
   ea-podman restore ~/ea-podman-backups/backup-20260803120000.tar.gz --verify
   ea-podman containers                # registry entries are back
   ea-podman list                      # running containers and their NEW ports
   ```

4. Fix up what moved. **Ports are reallocated, not reclaimed** — restore warns
   per container when the numbers differ, and whatever referenced the old ones
   (proxy rules, app configs) needs updating. cPanel’s own firewall rules are
   rebuilt automatically as ports are released and assigned; a third-party
   firewall is not. The registry’s `webapp` flag also comes back `false`.

These commands do not cover root’s own containers, restoring *as* a
jailshell/CageFS account, or restoring under a different username. See
Limitations.

## Why a file and database backup isn’t enough

| State | Where it lives | In a file/DB backup? | Usable if it were? |
|---|---|---|---|
| Container data, config, web app | `~/ea-podman.d/<container>/` | Yes | Yes — the one part that really is just files |
| Registration: owner, pkg, pkg version, image, `webapp` flag | `/opt/cpanel/ea-podman/registered-containers.json`, root-owned (`$known_containers_file`, `SOURCES/util.pm`) | **No** — outside every homedir | n/a |
| TCP port assignments + firewall | cPanel port authority, root-managed | **No** | n/a |
| subuid/subgid range | `/etc/subuid`, `/etc/subgid` (`_ensure_subids()`, `SOURCES/subids.pm`) | **No** | No — assigned per host in allocation order |
| Lingering session (`/run/user/<uid>`, `user@<uid>.service`) | runtime state (`_enable_linger()`, `SOURCES/subids.pm`) | **No** (ephemeral by design) | n/a |
| Unit file `container-<name>.service` | `~/.config/systemd/user/` | **No** — excluded on purpose | No — names a container ID that won’t exist after a rebuild |
| Podman store (layers, container metadata) | `~/.local/share/containers/` | **No** — excluded on purpose | No — see below |
| The image | a remote registry | No | n/a — re-pulled on restore |

Restore `~/ea-podman.d/` alone and the account has the container’s *data* and no
container: nothing registered, no ports, no service, nothing running.

The two homedir exclusions are ea-podman’s own doing:
`_ensure_backup_conf_excludes_files()` (`SOURCES/util.pm`), called at the top of
`_ensure_latest_container()`, adds `.local/share/containers` and
`.config/systemd` to `~/cpbackup-exclude.conf` on **every** install, upgrade, and
restore. As root it writes the same two paths, absolute, into
`/etc/cpbackup-exclude.conf` — which is also the *global* exclude list `pkgacct`
applies to every account. An already-correct file is left untouched and a file it
creates itself is correct; a file that already existed for some other reason gets
mangled (see Limitations).

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

The unit file is excluded for a simpler reason: the `podman generate systemd
--name` in `generate_container_service()` (`SOURCES/util.pm`) bakes in the
container’s identity, so the correct unit after a restore is a newly generated
one.

## How it works: back up the declaration, rebuild the container

### `ea-podman backup`

The `backup` command in `SOURCES/ea-podman.pl` → `perform_user_backup()`
(`SOURCES/util.pm`). Both refuse to run as root.

1. Load the root-owned registry (via the `REGISTERED_CONTAINERS` adminbin), keep
   this user’s entries. With none it prints `There are no containers` and returns
   — no tarball is written at all.
2. Ask the port authority which ports each container holds
   (`_get_current_ports()`) and record them as `curr_ports` — the only place that
   assignment is captured.
3. Write the manifest to `~/ea_podman_backup_<user>.json`.
4. `tar czf ~/ea-podman-backups/backup-<YYYYMMDDHHMMSS>.tar.gz` over the manifest
   plus all of `ea-podman.d` (timestamp is UTC), then **unlink the loose JSON** —
   the manifest only ever persists inside a tarball. The `tar` runs through
   list-form `system()` — no shell, so nothing in the path is interpreted — and a
   non-zero exit dies rather than leaving a partial archive behind (CPANEL-55350).
5. Keep the newest 3 tarballs (`$num_backups_to_retain`); the UTC names sort
   chronologically, so the oldest are the ones dropped.

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

The `restore` command in `SOURCES/ea-podman.pl` → `perform_user_restore()`
(`SOURCES/util.pm`). Both refuse to run as root.

1. **Tear down** — `remove_containers --all` (shelled out to the *installed*
   `/opt/cpanel/ea-podman/bin/ea-podman`, so even a checkout drives the installed
   copy), then `remove_tree` on `~/ea-podman.d` **and**
   `~/.config/systemd/user`. Unconditional; this is why `--verify` exists.
2. **Unpack** into the homedir, then require the manifest and every container
   directory it names, or die. Note the order: this check runs *after* the
   teardown, so a tarball missing either one leaves the account with no
   containers and no `~/ea-podman.d`.
3. **Re-establish the rootless plumbing** — `init_user( creating => 1 )`
   allocates subuid/subgid if missing and runs `loginctl enable-linger`, creating
   `/run/user/<uid>` and starting the user systemd manager. This is exactly the
   state a file backup can’t carry, rebuilt from scratch. The `creating => 1`
   matters: since CPANEL-55309 `init_user()` only lingers an account that has
   registered containers or says it is about to make its first, and step 1 just
   deregistered every one of them, so restore has to say so outright. The
   teardown in step 1 runs with `EA_PODMAN_KEEP_USER_SESSION=1` for the same
   reason — without it, removing the last container would release the linger
   that this step immediately turns back on.
4. **Rebuild each container** — `restore_containers_for_user()` runs the
   install/upgrade code path in `_ensure_latest_container()`, which keys off its
   caller to set `$isrestore`: replay `start_args` from the restored
   `ea-podman.json` (dying if it or its `start_args` is missing, and merging the
   *currently installed* package’s `/opt/cpanel/<pkg>/ea-podman.json` for EA4
   packages), allocate **new** ports (`_get_new_ports()`), skip the package’s
   `local-dir-setup`/`-upgrade` hooks so the restored directory isn’t
   re-scaffolded (the `elsif ($isrestore)` no-op), re-register, `podman create`
   (pulling the image), regenerate the unit, enable, start.
5. **Report port drift** against the manifest’s `curr_ports` (the loop at the end
   of `perform_user_restore()`).

### Automatic backup during pkgacct

A **pre** `PkgAcct::Create` hook, registered in `describe()` → `_do_backup()`
(both in `SOURCES/PodmanHooks.pm`). Pre-stage matters: the tarball must exist
before cPanel archives the homedir.

For a non-root account the hook shells out to
`/scripts/ea-podman rootbackupofuser <user>` (the `rootbackupofuser` command in
`SOURCES/ea-podman.pl`), which drops to the user via `Cpanel::AccessIds`. That
detour is required, for the reason the hook’s own comment gives: the backup needs
adminbin to read root-owned state, and adminbin refuses any caller whose
executable is a Perl interpreter — which is what a module hook running inside
`pkgacct` is. The compiled `/opt/cpanel/ea-podman/bin/ea-podman` passes that
check and is in `allowed_parents` (`SOURCES/ea-podman-adminbin.conf`); the
`/usr/local/cpanel/bin/pkgacct` entry in that same list is a leftover from the
in-process attempt and cannot match (it is a symlink to `pkgacct.pl`, so its
executable is Perl). Because the shell-out starts as root it bypasses the
restricted-shell gate, so jailshell and CageFS accounts do get backed up.

Two cPanel-side notes:

* `pkgacct` applies the exclude files **only** in backup modes (`--backup` /
  `--userbackup`) — see the `$isbackup || $isuserbackup` guard around the
  `EXCLUSION_LIST_FILES` block in cPanel’s own `scripts/pkgacct`, and the
  `$OPTS->{'backup'}`/`{'userbackup'}` block that sets those flags. A plain
  `cpmove-` run doesn’t, so a transfer archive can carry
  `~/.local/share/containers` — bloat that restore ignores, since it rebuilds the
  store from the image.
* There is **no restore-side hook**. Nothing in this package or in cPanel reacts
  to `restorepkg`; a restored account has its `~/ea-podman.d/` and its tarballs
  back on disk and zero containers.

## Limitations and sharp edges

* **Only `~/ea-podman.d/` is captured.** State written anywhere else inside the
  container is gone on restore (see TL;DR #1).
* **The destination must already have the EA4 packages installed.** With
  `/opt/cpanel/<pkg>/ea-podman.json` missing, `_ensure_latest_container()` dies
  telling you to install the package — and `restore_containers_for_user()` loops
  without an `eval`, so the run stops there: earlier containers are up, the rest
  are simply gone, because the teardown already removed them. Install the package
  and re-run the same tarball; restore always starts from a full teardown, so
  re-running is the recovery path.
* **Ports are reallocated, not reclaimed.** The teardown releases the old
  assignments and `_get_new_ports()` takes the lowest free ones
  (`cpuser_port_authority`), so a same-host restore often lands back on the same
  numbers and stays quiet. When it doesn’t, treat the warning as a to-do list.
* **Image tags float**, and for an EA4 package the image comes from the
  *currently installed* package’s `ea-podman.json`, not the manifest — restoring
  onto a host with a newer package lands on the newer image. The manifest’s
  `image`/`pkg_version` are a record of what was, useful for diagnosis.
* **Root’s own containers aren’t covered.** The `backup` and `restore` commands
  both die for `$> == 0`, and the hook’s root branch reaches
  `perform_user_backup()`, which also dies as root. Handle those by hand.
* **Restricted-shell accounts can’t restore themselves.** For jailshell/CageFS
  the CLI routes to the UAPI bridge, whose verbs are
  `install upgrade list start stop restart uninstall status cmd` (`%uapi_verb` in
  `delegate_to_uapi()`) — `backup`/`restore` are absent, so it’s refused.
  The gate keys on the account’s *configured* shell, so `su -s /bin/bash` doesn’t
  evade it, and running as root hits the root check. Backup has a root-side
  driver (`rootbackupofuser`); **restore has no equivalent.** Today that means
  temporarily giving the account an unrestricted shell, or rebuilding by hand:
  unpack the tarball, move the restored `~/ea-podman.d/<container>/` aside, run
  `ea-podman install` (with the restored `ea-podman.json`’s `start_args` for an
  arbitrary image), stop the new container, copy the data into its container
  directory, start it. Install without moving the restored directory aside and
  you get the *next* free name and an empty data dir — a directory (or its
  `.bak`) is one of the things `get_next_available_container_name()` skips on.
* **The `webapp` registry flag never survives a restore.** It’s set at install
  time only (`--webapp-dir`) and otherwise read back from the existing registry
  entry (`register_container_as_root()`) — but restore’s teardown already
  deregistered the container, so there is no entry left to read from and it is
  recorded as `webapp: false`. Same host included. (Upgrade, which doesn’t
  deregister, does preserve it.)
* **Username changes are blocked, and cross-account restore isn’t implemented.**
  Container names embed the user, so `Accounts::Modify` is refused for any
  account with containers (`_pre_username_change()`, `SOURCES/PodmanHooks.pm`)
  and `rename_containers()` is still a stub (ZC-9694). Nothing in `restore`
  rejects `bob`’s tarball when run as `bob2`, but it isn’t a migration: the
  container names still say `bob`, and re-registering them records them as
  `bob2`’s — overwriting `bob`’s own registry entries if that account still has
  them.
* **`tar`'s own diagnostics reach the caller unfiltered.** Both `tar` calls run
  through list-form `system()` and die on a non-zero exit (CPANEL-55350), so a
  truncated archive is no longer mistaken for a good one and paths with spaces or
  shell metacharacters are safe. What they do not do is inspect the archive: a
  `tar` that exits 0 having written something unusable is still caught only by the
  restore's manifest and container-directory checks.
* **The exclude-file writer mangles a pre-existing exclude file.**
  `_ensure_backup_conf_excludes_files()` reads the file *chomped*
  (`lines({ chomp => 1 })`) and `spew()`s the list back with newlines only on the
  lines it appends, so the pre-existing lines are concatenated:
  `public_html/junk` + `tmp` becomes `public_html/junktmp.local/share/containers`.
  The account’s own entries are destroyed on that first pass, and the appended
  line is unrecognizable on the next one, which glues `.config/systemd` into it as
  well — leaving **neither** exclusion in effect. Since the root path writes to
  `/etc/cpbackup-exclude.conf`, that damage is host-wide. Accounts with no
  exclude file (the common case) get a correct one. Not yet fixed.
* **Teardown doesn’t unmount.** Restore’s `remove_tree({ safe => 0 })` has no
  unmount/retry, so a lingering overlay or bind mount can surface `EBUSY`
  mid-restore. See “Related hardening in ea-podman” in `VIRTFS-BUSY.md`.
* **Removed containers leave `<container>.bak` directories** behind
  (`move_container_dir()`), so their data is recoverable by hand — and it also
  rides along in every later tarball, which restore unpacks and ignores.
