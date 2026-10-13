# ea-podman live tests

**These tests run on a real, disposable cPanel machine or VM — never on a
sandbox, build box, workstation, or CI.**

They are **destructive, live integration tests**, not unit tests. Each one
mutates real system state: it creates and removes real cPanel accounts, toggles
`loginctl` lingering and user systemd managers, allocates ports, pulls images,
and spawns/removes rootless Podman containers (and, for the cagefs test,
enables/disables CageFS for an account). Run them only where that is acceptable
and easily thrown away.

Because of that they are:

- **excluded from the normal unit run** — they live in this subdirectory and
  each one `skip_all`s unless `EAPODMAN_LIVE=1` is set, so a stray
  `prove t/` / CI run cannot fire them; and
- **guarded by preconditions** — they skip unless run as root with podman, a
  CPANEL-54037-aware ea-podman build, and `Cpanel::API::EAPodman` installed
  (the cagefs test additionally requires CloudLinux with CageFS installed and
  initialized).

## Do not run these on a sandbox

A sandboxed/containerized or shared environment cannot satisfy what these tests
need (a full cPanel install, real account creation, systemd user sessions,
rootless Podman, and — for cagefs — a CloudLinux kernel with CageFS). At best
they skip; at worst they leave real accounts, containers, or linger/CageFS
state behind. Use a throwaway VM you can discard afterward.

## The tests

ea-podman no longer requires cgroup v2 (the direct CLI runs on cgroup v1; the
UAPI path warns but proceeds). All three live tests run on **both** cgroup v1
and v2 — none has a cgroup-version gate. Their bring-up + serving assertions are
verified on cgroup v1 (AlmaLinux 8 and CloudLinux 8/9/10, which default to v1)
as well as v2 (AlmaLinux 9/10 and Ubuntu 24.04, which default to v2).

| Test | Scenario | Extra requirements |
|------|----------|--------------------|
| `normal-podman-live.t` | A **normal** account (unrestricted shell, not CageFS) manages containers via UAPI, and may also use the `ea-podman` CLI. | A live cPanel VM (cgroup v1 or v2). |
| `jailshell-podman-live.t` | A cPanel account whose login shell is **jailshell** manages containers — via UAPI, and (with `EAPODMAN_DRIVER=cli`) via the `ea-podman` CLI, which delegates to the ea_podman admin module's lifecycle actions (EA4-315). | A live cPanel VM (cgroup v1 or v2). |
| `cagefs-podman-live.t` | A **CloudLinux CageFS**-enabled account manages containers via UAPI. | CloudLinux (cgroup v1 or v2), with CageFS installed + initialized. |
| `ea-memcached16-cli-live.t` | A **normal** account uses the `ea-podman` CLI directly (`install <PKG>` mode) to install a real EA4 container-based package, `ea-memcached16`. | A live cPanel VM (cgroup v1 or v2), with `ea-memcached16` (or another EA4 container-based package, via `EAPODMAN_TEST_PKG`) already installed locally. |
| `ea-memcached16-cagefs-cli-live.t` | Sister to the above, but the account is **CageFS**-enabled: the CLI is driven through a real CageFS login, exercising the CPANEL-54672 fallback to the bridge (the ea_podman admin actions since EA4-315). | CloudLinux (cgroup v1 or v2), with CageFS installed + initialized, and `ea-memcached16` (or another EA4 container-based package, via `EAPODMAN_TEST_PKG`) already installed locally. |
| `ea4-315-admin-module-live.t` | The EA4-315 contract: the adminbin became the `Cpanel::Admin::Modules::Cpanel::ea_podman` admin module and the CLI is no longer compiled, with nothing outside ea-podman changing how it calls in. Checks packaging, that an uncompiled caller gets through with the parent check enforced, the legacy actions' return shapes and error text, the lifecycle actions from inside a real jail (and that no API token is minted), the `ea_podman` feature gate and its cleanup carve-outs, demo refusal, and — with `EAPODMAN_UPGRADE_FROM`/`_TO` — an in-place upgrade from the previous package with a running container. | A live cPanel VM (rpm or deb). Creates two throwaway accounts, and temporarily moves `/var/cpanel/skipparentcheck`, adds a feature list and package, and sets `DEMO` on an account; all undone at the end. |
| `cpanel-57396-pkgacct-restore-live.t` | **An account backup carries each container's files once, and the account still comes back with its containers** (CPANEL-57396). Gives a fresh account two containers with a random marker file in each, then: three `pkgacct --backup` runs and one plain (transfer) `pkgacct` each hold every marker exactly once, the manifest once and no `ea-podman-backups` tarball, and leave no tarball in the home directory; an account with no containers gets no manifest and no linger; a tarball from `ea-podman backup` survives pkgacct untouched; and after `removeacct` + `restorepkg`, `ea-podman restore --verify` with no tarball brings each container back under the same name, registry entry, `start_args`, ports and data, running and serving, and a second run leaves them alone. The per-container port check can fail by a swap: restore reallocates ports in manifest order, which is not stable. `E2E57396_MODE=transfer-pack` / `transfer-unpack` run the transfer across two boxes. With `E2E57396_EXPECT_OLD_EAPODMAN=1` it asserts the duplication instead and stops before the restore. | A live cPanel VM (cgroup v1 or v2), docker.io reachable, `curl`, `tar`. Two VMs for the transfer mode. |
| `ea4-325-upgrade-live.t` | `ea-podman upgrade` reports a container that did not come back up, recreates the previous one when a create fails, and no longer lets a failed `restore` delete the directory it just extracted. Also covers `upgrade_containers --all` surviving a deleted account, and the EAPodman UAPI's `start`/`stop`. | A live cPanel VM (cgroup v1 or v2), with an ea-podman build carrying EA4-325 installed (and **recompiled**, on a build older than EA4-315 — see the test's header). `ea-memcached16` optional — the packaged-container subtest skips without it. |
| `cpanel-54868-e2e-live.t` | **The two halves against each other.** Drives `uapi WebApp stage/deploy/redeploy` as a real account against the installed plugin AND ea-podman: a configuration change that does not move the image reaches the container (CPANEL-56732), while a plain `ea-podman upgrade` on that same container does nothing at all (EA4-325 B2). Then `webapp_cleanup.pl` (CPANEL-56733) and `ea-podman clean` (CPANEL-54870) over what a real delete leaves. | A live cPanel VM on **cgroup v2**, with `zip`, the webapp plugin >= 1.5.0 installed and its feature flag present, and an ea-podman carrying EA4-325 installed (and **recompiled**, on a build older than EA4-315). Needs to pull a `node` image once. |
| `ea4-335-create-failure-live.t` | **A container that cannot be created because the disk is full says why** (EA4-335 / CPANEL-55804). Mounts a small loop filesystem over a fresh account's rootless container storage, then: a Web App deploy fails as `build_failed` and its deploy log, read through `WebApp::fetch_logs`, carries a plain-words out-of-space sentence and podman's own error, each exactly once; `ea-podman install` from the CLI names the cause and leaves nothing behind; as the negative control, the same application deploys and serves once the filesystem is big enough, through Apache as well as on its own port, with exactly one host port reserved for it (CPANEL-57608: a failed first install must not keep its port); and, with a `podman` shim that makes `create` sleep, SIGINT (process group), SIGTERM and SIGHUP (ea-podman alone) sent mid-create still end in the install's failed-create cleanup with nothing left behind. Fails (never skips) if the change is not present in the library, the compiled binary (before EA4-315) or the plugin. Produces ENOSPC, not the literal EDQUOT of the ticket; the quota wording is pinned by the unit tests. | A live cPanel VM on cgroup v2, docker.io reachable, ~4 GB free, `losetup`/`mkfs.ext4`, SELinux not enforcing. Set `E2E335_EXPECT_OLD_EAPODMAN=1` to test the plugin's fallback against an older ea-podman. |
| `cpanel-57608-quota-redeploy-live.t` | **A Web App whose first deploy failed on a disk quota redeploys cleanly once the quota is lifted** (CPANEL-57608 / CPANEL-57512). Sets a fresh account's real cPanel quota just above its usage, then: the deploy fails at `podman create` with "disk quota exceeded" (asserted from the deploy log, so the port check below cannot pass vacuously) and the account holds no reserved port; with the quota lifted, the same application redeploys, the account holds exactly one port, it is the port podman published and the one the proxy is wired to, and Apache serves the app. With `E2E57608_EXPECT_OLD_EAPODMAN=1` it asserts the leak instead (1 port after the failure, 2 after the retry), so a before run against ea-podman 1.0-32 shows the test reproduces the bug. The Apache check alone cannot tell the versions apart on a plugin with CPANEL-57609; the port counts do. | A live cPanel VM on cgroup v2 (skips on v1, so not CloudLinux) with **disk quotas enabled** on the filesystem holding `/home` (`/scripts/fixquotas`, reboot if it says so); the test reads the limit back and skips if none applies. docker.io reachable, `quota`, `curl`, `zip`. |

The CLI-driving tests above also check `cpwrapd_log` for the delegated CLI going
through the lifecycle actions without ever calling `MINT_API_TOKEN` (skipped on
an ea-podman that predates EA4-315).

### Suggested boxes for EA4-315

Each row is one fresh VM:

| Box | Run |
|---|---|
| AlmaLinux 9, cPanel release tier (rpm, cgroup v2) | `ea4-315-admin-module-live.t` with `EAPODMAN_UPGRADE_FROM`/`_TO` set to the previous and new rpm; `normal-podman-live.t`; `jailshell-podman-live.t` with both `EAPODMAN_DRIVER=uapi` and `=cli`; `ea-memcached16-cli-live.t` |
| CloudLinux 8 with CageFS (cgroup v1, hidepid=2) | `ea4-315-admin-module-live.t`, `cagefs-podman-live.t` (both drivers), `ea-memcached16-cagefs-cli-live.t` |
| Ubuntu 24.04 (deb) | `ea4-315-admin-module-live.t` with `EAPODMAN_UPGRADE_FROM`/`_TO` set to the previous and new deb |

### EA4-321: `ea4-321-carveout-live.t`

A single self-contained file, run as root on a disposable cPanel VM whose
`user@.service` template is masked (CageFS installed and initialised, or
`EA4321_TOGGLE_MASK=1` to let it mask the template itself on a host without
CageFS). It creates three throwaway users and removes them. It checks, against
the real systemd, that a bootstrapped account's manager survives 3 seconds and
repeated host-wide `systemctl daemon-reload`s (the thing that killed it on
systemd 252), that bootstrapping a second account does not disturb the first,
that an account nobody bootstrapped is still refused by the mask, that the mask
is unchanged throughout, that releasing an account stops its manager and takes
its unit back (including when a login session holds the manager open at the release, which `runuser -l` provides), and (with the toggle) that a manager started on an unmasked host, by ea-podman or by logind, survives the mask arriving later.

```
scp t/LiveTests/ea4-321-carveout-live.t root@VM:/root/
ssh root@VM 'EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl /root/ea4-321-carveout-live.t'
```

To test a `SOURCES/subids.pm` that is not installed yet, put it at
`<dir>/ea_podman/subids.pm` on the VM and add `EAPODMAN_LIB=<dir>`.

The reboot case is a two-phase operator step: `EA4321_REBOOT=prepare`, reboot
the VM, then `EA4321_REBOOT=verify`. It proves the boot sweep writes the units
again, since `/run` is empty after a reboot. It needs none of the account or
container setup the other tests do, so it is the quickest way to check a new
OS: CL8 (systemd 239) and CL10 (systemd 257) are the ones to run it on to
confirm the fix does not regress them.

### EA4-319 in the two cagefs `.t` files

Both cagefs tests carry the `user@.service` mask checks: the mask is recorded
before install and must be unchanged at the same path afterward, with the
account's manager (started from a unit of its own, EA4-321) still running, no
in-progress state file left behind, and the account still working after
`cagefsctl --hook-install` re-applies the mask.

Their "survives a reboot" step goes through `ea-podman-user-managers.service`
rather than restarting the manager directly. It used to be one
`systemctl restart user@<uid>.service`, which is **not** a reboot proxy on a
masked host: systemd refuses the start half and leaves the running manager
alone, so the socket never disappeared and the checks passed having restarted
nothing (this is the mask-poc's stage-4 finding — masking refuses new starts, it
does not stop a running instance). They now stop the manager for real and bring
it back the way boot does: the sweep unit where the template is masked, plain
`systemctl start` where it is not. They also check the unit is enabled and that
its `ExecStart` runs the sweep verb, and that `ea-podman ensure_user_sessions`
no-ops (reports `ok`, writes nothing) on an account that is already healthy.

That is as close as a `.t` gets. Only a real reboot proves the fix end to end —
`ea4-319-mask-poc.sh` stage 6, below, owns that.

## `ea4-319-mask-poc.sh` — the CageFS `user@.service` mask

Not a `.t` file and not part of the suite: a standalone, self-narrating shell
POC for EA4-319. It uses **only podman, `systemctl` and `loginctl`** — no
ea-podman code — so it validates the underlying mechanism independently of our
implementation.

**It does not need CageFS.** `cagefsctl --hook-install` masks the template with
literally `systemctl mask user@.service`, so masking it by hand on a plain box
produces the identical host state. That is what this script does.

```sh
./ea4-319-mask-poc.sh status                  # inspect, changes nothing
./ea4-319-mask-poc.sh --yes run [USER]        # stages 0-4
./ea4-319-mask-poc.sh --yes pre-reboot        # arm stage 5 (the gap), then reboot
./ea4-319-mask-poc.sh --yes pre-reboot-fixed  # arm stage 6 (the fix), then reboot
./ea4-319-mask-poc.sh post-reboot             # check whichever was armed
./ea4-319-mask-poc.sh cleanup                 # remove the container, restore state
```

Each stage prints why it exists, every command it runs with its output, and a
PASS/FAIL verdict saying what to conclude. What it demonstrates:

0. rootless podman under `systemctl --user` works normally
1. with the template masked, **neither** `/run/user/<uid>` **nor** the bus appears
2. `loginctl enable-linger` alone cannot repair an already-lingering account
3. unmask → start the manager → remask ("the sandwich") repairs it
4. the manager and its container **survive** the remask — the load-bearing claim
5. (needs a reboot) containers do **not** come back on their own — measured and
   confirmed on a masked host
6. (needs a reboot) with `ea-podman-user-managers.service` installed, they **do**

Stage 1 is worth reading carefully. EA4-319 open question 2 predicted the
runtime directory would survive, since `user-runtime-dir@.service` is not itself
masked. Measured on systemd 239, that is wrong: `user@.service` carries
`Requires=user-runtime-dir@%i.service`, so masking `user@` fails the whole job
and the runtime directory is never created either — with or without a login
session. Both of ea-podman's readiness errors therefore name the mask.

**Stage 6 is the odd one out.** Stages 0–5 involve no ea-podman code at all;
stage 6 does, because it is the only test that can prove the fix — the fix is a
systemd unit that runs at boot, so no unit test reaches it. It works from
ea-podman's own container registry, so the account needs a container ea-podman
knows about (`ea-podman install <PKG>`); the hand-made container stage 0 creates
is deliberately not in the registry, and `pre-reboot-fixed` refuses to arm rather
than pass vacuously. It also checks the unit is installed and enabled first.

Safety: masking `user@.service` is **host-wide** — while masked, no account on
the box can get a per-user systemd manager. The script records the mask state at
startup and restores exactly that on exit, including via an `EXIT`/`INT`/`TERM`
trap, so a CageFS-applied mask is put back as found. Throwaway VM only.

The one exception is `pre-reboot` and `pre-reboot-fixed`, which disarm that trap
on purpose: leaving the mask in place across the reboot *is* the test. Until you
run `post-reboot` or `cleanup`, the box boots with no per-user systemd manager
for any account.

It drives the test account over **ssh to localhost** (setting up and removing its
own key), not `su`: `su` leaves the caller's cwd in place, which the cpuser often
cannot enter — the same trap `ea_podman::util::ensure_su_login()` works around at
`util.pm:107-115`. It also sets `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`
explicitly, because an ssh login does not necessarily create a logind session,
which is why `ensure_su_login()` sets them by hand too.

## `ea4-319-verify-boot-fix.sh` — the boot-time fix, end to end

The manual verification runbook for `ea-podman-user-managers.service` as a
script. Where `ea4-319-mask-poc.sh` proves the *mechanism* with no ea-podman
code, this one drives ea-podman itself.

```sh
./ea4-319-verify-boot-fix.sh local              # repo checks only, safe anywhere
./ea4-319-verify-boot-fix.sh --yes run [USER]   # stages 1-5 on this box
./ea4-319-verify-boot-fix.sh register [USER]    # give USER a registered container
./ea4-319-verify-boot-fix.sh --yes pre-reboot [USER]   # arm stage 6, then reboot
./ea4-319-verify-boot-fix.sh post-reboot        # check stage 6
./ea4-319-verify-boot-fix.sh cleanup            # undo the reboot state
./ea4-319-verify-boot-fix.sh pkg                # check a built RPM instead
```

1. **local** — the test suite, perl/bash syntax, that the spec still parses and
   ships the unit, and that systemd accepts the unit file. Changes nothing, so it
   runs anywhere including a dev checkout.
2. **deploy** — installs the changed `subids.pm`/`util.pm`/`ea-podman.pl` over
   the installed ea-podman (including `bin/ea-podman`, which is no longer
   compiled), and enables the unit. Lets a box
   be tested without waiting on an OBS build; it is deliberately *not* a test of
   packaging, which is what the `pkg` stage is for.
3. **smoke** — the verb is registered, is refused to non-root, and no-ops on a
   healthy host.
4. **masked** — the load-bearing one: with the template masked and root's manager
   stopped, the sweep starts it and puts the mask back, so `is-enabled` says
   `masked` and `is-active` says `active` at the same time.
5. **unit** — runs the systemd unit itself and shows its journal, since that is
   what actually fires at boot.
6. **reboot** — hands off to `ea4-319-mask-poc.sh` stage 6, which owns the reboot
   harness. The only test that proves containers come back.

The `register` stage needs an EA4 **container-based package** on the host, since
`ea-podman install <PKG>` installs a container *from* one and cannot fetch the
package itself. It defaults to `ea-redis62`; on a host without it, it names the
package-manager command and offers to run it (`--yes` accepts). `EAPODMAN_TEST_PKG`
picks a different package and `ea-podman avail` lists the candidates — the same
convention `ea-memcached16-cli-live.t` uses.

Stage 4 masks `user@.service` host-wide for a few seconds and restores the state
it found on every exit path, trap included; stage 2 overwrites the installed
ea-podman; `register` may install an EA4 package. Throwaway VM only.

## `ea4-319-ab-verify.sh` — does the fix actually fix it?

Its sister. Where `ea4-319-mask-poc.sh` proves the **mechanism** with no
ea-podman code involved, this one proves the **implementation**: on a host masked
exactly as `cagefsctl --hook-install` masks it, it runs one identical
rootless-podman operation twice and expects opposite results.

```sh
./ea4-319-ab-verify.sh status              # inspect, changes nothing
./ea4-319-ab-verify.sh --yes run [USER]    # the A/B run
./ea4-319-ab-verify.sh cleanup             # remove the container, restore state
```

- **A** bootstraps the account the way ea-podman did *before* EA4-319 and must
  **fail**. It is `SOURCES/subids.pm` at the newest revision in this repo's
  history that carries neither `with_user_manager_unmasked` nor its EA4-321
  replacement `ensure_user_manager_carveouts`, recovered with
  `git show` — real old code rather than a strawman.
- **B** bootstraps it with `SOURCES/subids.pm` from the working tree and must
  **pass**. Nothing else differs — same host, same mask, same account, same op.

Both sides come out of the checkout, never out of whatever ea-podman happens to
be installed on the box: an installed module may be anything, including a build
that already carries the fix, which would make A mean something different from
host to host and on an up-to-date box quietly stop testing the old behaviour at
all. Only when there is no usable history — a shallow clone, or the script copied
out on its own — does A fall back to an inline transcription of that code
(`loginctl enable-linger` plus the same 10s bus poll, and nothing else), and it
says which of the two it used. Both produce the same failure verbatim.

The op is podman and `systemctl` only, in the shape ea-podman itself uses:
`podman create`, `podman generate systemd --restart-policy on-failure --name`
into `~/.config/systemd/user`, then `enable` + `start` through the account's own
manager. It runs the account's commands under `runuser -u` with
`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` set by hand — no login shell, no
logind session — because that is the context ea-podman's privileged callers
(cpsrvd/UAPI, account hooks, root `su -`) actually hand it.

A baseline stage runs the op unmasked first, so an A failure cannot be blamed on
the environment, and it also warms the image in the *account's own* store so
neither side needs the network. After B it checks the things that make the
approach legitimate rather than merely effective: the mask is back at the same
path, no in-progress-window state file is left behind, the manager is still
running *through* the remask, and a second bootstrap on the now-healthy account
opens no window at all.

The one thing it does take from the system is `/usr/local/cpanel/3rdparty/bin/perl`
(override with `EAPODMAN_PERL`), because the module needs `Cpanel::OS` and
`Path::Tiny`. It also creates `/opt/cpanel/ea-podman` if ea-podman is not
installed, since that is where `ea_podman::subids` writes its lock and state
file, and removes it again at cleanup.

Verified on AlmaLinux 8.10, systemd 239, podman 4.4.1, cgroup v1, both A paths:
all checks pass, with A dying on `The directory "/run/user/<uid>" is missing` and
its op hitting `Error: creating events dirs: mkdir /run/user/<uid>: permission
denied` and `Failed to connect to bus`, while B's identical op reaches `active`.

Same safety story as the POC — the mask is host-wide while it is on, and the
startup state is restored on every exit path including the trap. Throwaway VM
only.

## Installing a build to test

From EA4-315 `/opt/cpanel/ea-podman/bin/ea-podman` is the perl script itself and
reads `util.pm` from `lib/`, so a build is installed by copying files:

```sh
scp SOURCES/util.pm                root@VM:/opt/cpanel/ea-podman/lib/ea_podman/
scp SOURCES/ea-podman.pl           root@VM:/opt/cpanel/ea-podman/bin/ea-podman
scp SOURCES/ea-podman.pl           root@VM:/opt/cpanel/ea-podman/bin/ea-podman.pl
scp SOURCES/Cpanel-API-EAPodman.pm root@VM:/usr/local/cpanel/Cpanel/API/EAPodman.pm
scp SOURCES/Cpanel-Admin-Modules-Cpanel-ea_podman.pm \
    root@VM:/usr/local/cpanel/Cpanel/Admin/Modules/Cpanel/ea_podman.pm
```

Before EA4-315 it is a **compiled** binary that embeds its own copy of
`util.pm`. Copying `SOURCES/util.pm` over
`/opt/cpanel/ea-podman/lib/ea_podman/util.pm` therefore changes nothing the CLI
runs — the library copy is what other consumers `require`, not what the binary
uses. Copy, then recompile:

```sh
scp SOURCES/util.pm            root@VM:/opt/cpanel/ea-podman/lib/ea_podman/
scp SOURCES/ea-podman.pl       root@VM:/opt/cpanel/ea-podman/bin/
scp SOURCES/Cpanel-API-EAPodman.pm root@VM:/usr/local/cpanel/Cpanel/API/EAPodman.pm
ssh root@VM 'bash /opt/cpanel/ea-podman/bin/compile.sh'
```

`ea4-325-upgrade-live.t` checks the library, and the binary too when the CLI is
compiled, and skips with a specific message if only the library was updated.

### Or let the setup script do it

`setup-remote-live.pl` does the above — including the recompile when the CLI
is compiled, and the UAPI and admin modules — and checks everything else the
live tests need before you find out the hard way. It is self-contained: no repo
checkout, no CPAN, core modules only.

```sh
scp t/LiveTests/setup-remote-live.pl root@VM:/root/
ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl'
```

Read-only by default — it reports what is present and **which copy of the code
is actually under test**, then prints the exact command for each live test. Add
`--deploy` to put the rsynced working trees under test rather than the installed
packages. It also covers the webapp plugin's live tests (`--plugin=PATH`), whose
modules have the same hazard in reverse: symlinked into the repo on a
development box, real files from the package on a VM.

## Running

As root, on the target VM. Each test is self-contained — copy just the one
`.t` file over (you do not need the rest of the repo) and run it from wherever
you dropped it:

```sh
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl normal-podman-live.t
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl jailshell-podman-live.t
# jailshell, exercising the CLI->UAPI delegation instead of `uapi --user`:
EAPODMAN_LIVE=1 EAPODMAN_DRIVER=cli /usr/local/cpanel/3rdparty/bin/perl jailshell-podman-live.t
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl cagefs-podman-live.t
# install a real EA4 container-based package (ea-memcached16) via the CLI
# (ea-memcached16 must already be installed locally, e.g. `yum install -y ea-memcached16`):
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea-memcached16-cli-live.t
# EA4-325: upgrade/restore truthfulness and the failed-create recreate.
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea4-325-upgrade-live.t
# CPANEL-54868: the plugin and ea-podman against each other, through the product.
# Run the preflight with --deploy first; it is what puts BOTH halves under test.
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl cpanel-54868-e2e-live.t
# ... and the same file building the ordering HAZARD deliberately (edits the
# deployed Podman.pm and restores it):
EAPODMAN_LIVE=1 CP54868_PROVE_HAZARD=1 /usr/local/cpanel/3rdparty/bin/perl cpanel-54868-e2e-live.t
# EA4-335 / CPANEL-55804: a full disk is reported, not swallowed. Run the preflight
# with --deploy first (both halves under test), and read the header for the sizes.
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/prove -v ea4-335-create-failure-live.t
# same, but for a CageFS-enabled account (CloudLinux only):
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl ea-memcached16-cagefs-cli-live.t
```

Useful environment variables (see each test's header for the full list):

- `EAPODMAN_LIVE=1` — **required** opt-in.
- `EAPODMAN_DRIVER` (jailshell test) — `uapi` (default) or `cli`; selects
  whether each verb is issued via `uapi --user` or the in-jail `ea-podman` CLI.
- `EAPODMAN_TEST_USER` — reuse an existing account instead of creating a
  throwaway one (its shell/CageFS state is changed for the test and restored
  afterward).
- `EAPODMAN_TEST_IMAGE` / `EAPODMAN_TEST_PORT` — image / container port
  (defaults: `redis:alpine`, `6379`).
- `EAPODMAN_TEST_PKG` (ea-memcached16 test) — EA4 container-based package to
  install (default: `ea-memcached16`); must already be installed locally.
- `EAPODMAN_KEEP=1` — skip teardown and leave the account/container for manual
  inspection.
- `CP54868_*` (the CPANEL-54868 test) — `CP54868_TEST_USER`, `CP54868_NODE_TAG`
  (default `22`), `CP54868_KEEP=1`, `CP54868_DEPLOY_TIMEOUT` (default 600), and
  `CP54868_PROVE_HAZARD=1`. It uses its own prefix rather than `EAPODMAN_*`
  because it is as much a plugin test as an ea-podman one.

### These are mutually destructive

`ea4-325-upgrade-live.t` runs `remove_containers --all` **as root**, which
reaches every account on the box, and `cpanel-54868-e2e-live.t` has a live
application it expects to still be there. `ea4-335-create-failure-live.t` kills
its own account's processes and mounts over that account's container storage, so
it must not overlap either of them. Never interleave them. Run one, then
`setup-remote-live.pl --check-clean`, then the other.

## CloudLinux setup for the cagefs test

The cagefs test only runs on **CloudLinux** with CageFS installed **and
initialized**; otherwise it skips. It works on the stock **cgroup v1** that
CloudLinux defaults to — do **not** switch CloudLinux to cgroup v2: its LVE
kernel places user processes in `/lvub/lve<uid>`, which under cgroup v2's single
hierarchy collides with systemd's `user.slice` and breaks the per-user systemd
manager the feature relies on. On a fresh CloudLinux VM, as root, set it up in
this order, then run the test:

```sh
# 1. ea-podman (must be a CPANEL-54037-aware build, not the stock EA4 package)
yum install -y ea-podman

# 2. CageFS
yum install -y cagefs

# 3. initialize + enable CageFS (creates /usr/share/cagefs-skeleton)
/usr/sbin/cagefsctl --init
/usr/sbin/cagefsctl --enable-cagefs

# 4. CloudLinux prerequisites for rootless podman:
#    - kernel >= 4.18.0-553 on CL8 (stock images ship 4.18.0-372, on which
#      containers will not run); `yum update` then reboot into the new kernel.
#    - user namespaces enabled (CL10 ships user.max_user_namespaces=0, which
#      silently breaks rootless podman's newuidmap/newgidmap step — install
#      fails during image unpack with something like "potentially insufficient
#      UIDs or GIDs"; `sysctl user.max_user_namespaces` to check):
#      echo 'user.max_user_namespaces=15000' > /etc/sysctl.d/90-userns.conf && sysctl --system

# 5. run the cagefs live test (copy the .t file to the VM first)
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl cagefs-podman-live.t
```

Notes:
- podman is pulled in as an ea-podman dependency; install it explicitly with
  `yum install -y podman` if needed.
- The stock EA4 `ea-podman` predates CPANEL-54037; the test skips on it. Install
  the rebuilt RPM from the `CPANEL-54037` branch.
- The tests run on whatever cgroup hierarchy the host defaults to — no cgroup
  switch is needed. CloudLinux 8/9/10 stay on their default cgroup v1 (do **not**
  switch CloudLinux to v2 — see the warning above); AlmaLinux 8 runs the tests on
  its default cgroup v1; AlmaLinux 9/10 and Ubuntu 24.04 run on cgroup v2.
- **`cagefsctl --init`/`--reinit` may print a one-off mount error** on newer
  kernels (seen on CloudLinux 10 / AlmaLinux 10.2, kernel 6.12), e.g.:
  ```
  mount: /usr/share/cagefs-skeleton/proc/sys/fs/binfmt_misc: open_tree system call failed: Too many levels of symbolic links.
  Error: failed to mount /proc/sys/fs/binfmt_misc
  ```
  This is a transient race between the bind-mount and systemd's
  `proc-sys-fs-binfmt_misc.automount` unit — the modern `mount`'s
  `open_tree()`-based bind-mount path can trip over the automount trigger and
  hit the kernel's path-walk loop limit (ELOOP) mid-race. It is **not an
  ea-podman or CageFS bug**, and it is benign: the bind mount typically still
  lands correctly despite the printed error. Verify with
  `cagefsctl --cagefs-status` (should print `Enabled`) and
  `findmnt /usr/share/cagefs-skeleton/proc/sys/fs/binfmt_misc` (should show
  fstype `binfmt_misc`, not just `autofs`) — if both check out, proceed. If
  CageFS genuinely isn't enabled, just re-run `/usr/sbin/cagefsctl --reinit`;
  it does not reliably reproduce twice in a row.
