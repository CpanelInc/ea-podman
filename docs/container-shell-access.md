# Shell and command access into ea-podman containers

An account with an **unrestricted shell** (or root) can drop into one of its
containers with `ea-podman bash <container>` — an interactive shell inside the
running container. Accounts with a **jailshell** login shell or a **CloudLinux
CageFS** cage cannot: the command is refused. This document explains *why* that
interactive path cannot easily be offered to restricted accounts, why the reason
differs between jailshell and CageFS, and how a **non-interactive** "run one
command inside the container" capability (the `cmd` verb, CPANEL-54360) is built
where an interactive shell cannot. See `DESIGN.md` for the broader internals and
`docs/uapi.md` for the UAPI surface that restricted accounts already use.

## TL;DR

| Access path | jailshell | CageFS |
|---|---|---|
| `ea-podman bash` from the account's own login | refused by the CLI gate | refused by the CLI gate |
| Run podman **inside** the jail/cage | impossible (`nosuid` breaks rootless podman) | impossible (`nosuid` breaks rootless podman) |
| `su -s /bin/bash <user>` to escape, then `podman exec -it` | works *technically* (out of jail), but the gate keys on the account shell, and it is root-only | **does not escape** — every `su`/login re-enters the cage |
| Non-PAM setuid drop (cPanel `AccessIds`) + TTY, then `podman exec -it` | works, but root-only and bespoke | works, but root-only and bespoke |
| Over the `EAPodman` UAPI | impossible — no TTY on the channel | impossible — no TTY on the channel |
| Non-interactive `podman exec <container> <cmd>` (captured output) | implemented as the `cmd` UAPI verb (CPANEL-54360) | implemented as the `cmd` UAPI verb (CPANEL-54360) |

## Background: how restricted accounts reach ea-podman

For a non-root caller whose configured login shell is restricted, the `ea-podman`
CLI does not run podman locally. It routes a fixed set of verbs through the
`EAPodman` UAPI module, which cpsrvd executes as the cpuser outside the jail/cage
(`SOURCES/ea-podman.pl:65`). The allowlist is (`SOURCES/ea-podman.pl:119`):

```
install upgrade list start stop restart uninstall status
```

`bash` is intentionally **not** on that list. A restricted account that runs
`ea-podman bash <container>` is refused client-side, before any UAPI call or
podman interaction, with a `die` (`SOURCES/ea-podman.pl:146-147`):

```
The “bash” command is not available for accounts with a restricted shell (jailshell) or CageFS.
Those accounts can use: install, list, restart, start, status, stop, uninstall, upgrade.
```

The `bash` verb itself (available only on the direct CLI path, i.e. root and
unrestricted-shell accounts) runs an **interactive** exec
(`SOURCES/ea-podman.pl:426-442`):

```perl
ea_podman::util::podman( exec => "-it", $container_name, "/bin/bash" );
```

The `-it` (allocate a **t**ty, keep std**i**n open) is the crux of why this is
hard to delegate.

## Why interactive `bash` is hard: three independent walls

Any interactive-shell design has to clear all three of the following. Each one is
sufficient on its own to block the naïve approaches.

### Wall 1 — inside the jail/cage, rootless podman cannot start at all

Both a jailshell chroot and a CageFS cage are mounted `nosuid`. That strips the
file capabilities from the `newuidmap`/`newgidmap` helpers, so rootless podman
cannot set up the user namespace it needs, and no podman command (including
`exec`) can run there. This is the same reason the whole feature delegates
container *management* out of the jail/cage in the first place — see the CageFS
note at `t/LiveTests/cagefs-podman-live.t:23-25` and the rootless-session setup
in `SOURCES/util.pm` (`init_user`/`ensure_su_login`).

So "just run `ea-podman bash` from inside the restricted environment" is a
non-starter regardless of any gate: even with the gate removed, it would fail
with a cryptic podman/namespace error instead of the friendly refusal.

### Wall 2 — escaping the restricted environment is different for the two

This is where jailshell and CageFS diverge, and it is the key subtlety.

**jailshell is the login-shell binary.** The jail is established by
`/usr/local/cpanel/bin/jailshell` when it is exec'd as the login shell. Choosing
a *different* shell sidesteps it: `su -s /bin/bash <user> -c '…'` never execs
jailshell, so the process runs on the host filesystem, not in the chroot. This is
exactly the `run_as_user` helper the live test uses to make host-side checks
(`t/LiveTests/jailshell-podman-live.t:121-126`). In that out-of-jail context,
with linger already providing `/run/user/<uid>`, `podman exec -it … /bin/bash`
*does* work.

But two things keep this from being a usable feature:

- The CLI gate keys on the account's **configured** shell
  (`getpwuid($>)` → `_has_unrestricted_shell`, `SOURCES/ea-podman.pl:57,65`), not
  on whether the current process is actually jailed. So even an out-of-jail
  `su -s /bin/bash` invocation is routed to UAPI and refused.
- Only root can `su` to another user without a password, so this is inherently a
  root-mediated path, not something the cpuser can do for itself.

**CageFS is entered per-uid at the PAM/login layer.** There is no shell-selection
seam. The cage is entered for that uid by PAM/login mechanisms regardless of which
shell runs, so `su - <user>` *and* `su -s /bin/bash <user>` both land **inside**
the cage — "a different world," as the test header puts it
(`t/LiveTests/cagefs-podman-live.t:16-31`). The jailshell escape hatch simply
does not transfer: you cannot get outside a CageFS cage by picking a different
shell.

### Wall 3 — UAPI cannot carry an interactive terminal

The supported delegation channel is the `EAPodman` UAPI: a stateless request /
response executed by cpsrvd — a set of parameters in, a single JSON document out
(`docs/uapi.md`). An interactive shell needs a live pseudo-terminal with
bidirectional, streaming stdin/stdout for the whole session. There is no pty and
no streaming channel in UAPI, so `podman exec -it` fundamentally cannot be
expressed over it. This wall stands even when Walls 1 and 2 are satisfied, and it
applies equally to jailshell and CageFS.

## The only "outside" route — and why it is not a feature

There *is* a way to run as the cpuser outside the cage/jail: assume the uid via a
**non-PAM** privilege drop. cPanel's `AccessIds`/`ReducedPrivileges` change the
effective uid/gid directly (setuid), without going through PAM `su`/login — which
is precisely how cpsrvd runs the UAPI outside a CageFS cage. A root-side helper
could do that drop, attach a real TTY, and then run `podman exec -it … /bin/bash`
against the user's container (whose rootless state lives on the host under
`/run/user/<uid>` and the user's home).

Why this is not a shipped capability:

- It requires **root** — only root can change uid without PAM. The restricted
  cpuser cannot initiate it for itself.
- It is a **bespoke** operation with no ea-podman/UAPI wiring today; it would be a
  new root-side entry point outside the normal delegation model.
- It still **cannot** be reached through UAPI (Wall 3), so it does not fit the one
  channel restricted accounts actually have.

In short: interactive container access for a restricted account is only possible
through a root-driven, out-of-band setuid path — not through anything the account
can invoke, and not over UAPI.

## What works: running a command (not a shell)

The walls above are specific to an *interactive* shell. Running **one command**
inside the container and returning its output is a different shape, and it fits
the UAPI channel. This is the `cmd` verb (CPANEL-54360): added to the
`%uapi_verb` allowlist (`SOURCES/ea-podman.pl`) and to `Cpanel::API::EAPodman`
(`SOURCES/Cpanel-API-EAPodman.pm`) alongside the existing verbs. See
`docs/uapi.md`'s "`cmd` arguments" section for the parameter/response shape.

### Why it uses `nsenter`, not `podman exec`

The obvious implementation — `podman exec <container> <cmd…>` (no `-it`) — does
**not** work on a host that mounts `/proc` with `hidepid=2`, which is precisely
the hardening this document's `check_proc()` reference recommends. A rootless
container's main process is owned by one of the user's **subuids** (e.g. because
the image drops privileges to a service user), not by the cpuser's own uid.
Under `hidepid=2` the kernel hides `/proc/<pid>` from anyone but the owning uid,
so when the cpuser runs `podman exec`, the runtime cannot read the container's
init process to confirm it is alive and fails with the misleading
`cannot exec in a stopped container` — even though the container is running and
serving fine. (Note: this is a `hidepid` effect, not a cgroup-version effect;
`CAP_SYS_PTRACE` alone does not lift it — the block is DAC on `/proc/<pid>`.)

For a **cpuser's** container, `cmd` therefore enters the container's namespaces
directly with `nsenter`, run **as root** (which is not subject to `hidepid`):

```
nsenter -t <init-pid> -U -m -u -i -n -p -S 0 -G 0 -- <cmd…>
```

`-U` joins the container's user namespace and `-S 0 -G 0` become uid/gid 0
*within it* — i.e. the container's own root, which maps back to the cpuser on
the host. So the command runs with exactly the identity and privilege
`podman exec` would have given it; no host privilege leaks in. This is literally
the `setns()` step `podman exec` performs internally, just driven by root.

Because only root can reach the subuid-owned, `hidepid`-hidden init process, a
non-root caller (the cpsrvd UAPI path, or an unrestricted-shell CLI user)
delegates to the root ea-podman adminbin action `EXEC_IN_CONTAINER`, which
validates ownership and calls `ea_podman::util::exec_in_container_as_root()`.
This works uniformly for normal, jailshell, and CageFS accounts.

For **root's own** container (the direct root CLI path), none of this is needed:
root is not subject to `hidepid`, and a root-owned container is not
subuid-remapped, so `exec_in_container_as_root()` just uses `podman exec`
directly (`nsenter -U` does not even apply there). The nsenter path is reserved
for reaching *another* user's rootless container.

What the verb accounts for:

- **No interactivity.** One-shot commands only — no prompt, no stdin stream, no
  TTY. `cmd` is the non-interactive equivalent of `bash`.
- **No assumed shell.** The argv is exec'd directly by `nsenter`, so it works
  even in a container with no shell at all. `--cd DIR` is the one exception:
  because `nsenter --wd` is unreliable across the mount-namespace switch, `--cd`
  runs the command through the container's `/bin/sh` as `cd DIR && exec …`
  (exactly the form CPANEL-54360 calls for). Only `--cd` needs a shell.
- **Bounded output.** stdout/stderr are captured and size-limited
  (`ea_podman::util`'s output cap) so a chatty or runaway command cannot blow up
  the JSON response.
- **Ownership validation.** The container name is validated as the caller's
  (`validate_user_container_name` + a registry ownership check in the adminbin),
  and root resolves the init pid itself in the owner's context and verifies the
  pid really belongs to that user before entering it — a caller can never point
  it at an arbitrary process.
- **Argument handling.** The command and its arguments travel as a list (no
  shell interpolation) end to end — CLI argv, the UAPI param encoding, and the
  final `nsenter` argv.
- **Exit semantics.** The container command's exit code is surfaced in
  `data.exit_code`, distinct from the UAPI call's own success/failure.

### CageFS 7.6.39+ masks `user@.service`

Independent of the three walls above, a current CageFS host actively prevents the
per-user systemd manager that ea-podman's whole rootless model rests on.

CageFS 7.6.39 (released 2026-06-16) masks the `user@.service` **template**:

```
/etc/systemd/system/user@.service -> /dev/null
```

Three things about it matter:

- **It is deliberate**, from CloudLinux security report **CLOS-4517**: a caged
  account put a unit in `~/.config/systemd/user/`, had the per-user systemd
  instance start it, and so ran code outside its cage with a view of the real
  filesystem. CloudLinux considered running the per-user manager *inside* the
  cage and rejected it — it would have meant mounting `/run/systemd/system`, the
  notify socket and the system bus into every cage.
- **It is re-applied on every cagefs install and upgrade**, by
  `cagefsctl --hook-install`. Any manual `systemctl unmask` is reverted by the
  next cagefs update, so a persistent unmask is not a fix.
- **It applies to every account on the server**, caged or not — it is the
  template that is masked, not a per-user unit.

With it masked no per-user manager can start, so `/run/user/<uid>/bus` never
appears and rootless podman has nothing to talk to.

It is tempting to reason that `user-runtime-dir@.service` is *not* masked, so
`/run/user/<uid>` should still appear and only the bus should be missing. That
is what EA4-319's open question 2 assumed, and **it is wrong.** `user@.service`
carries `Requires=user-runtime-dir@%i.service`, so masking `user@` fails the
whole job and the runtime directory never gets created either. Measured on
systemd 239, with and without a login session:

| `user@.service` masked | `/run/user/<uid>` | `/run/user/<uid>/bus` |
|---|---|---|
| lingering, no login session | missing | missing |
| after a real login (`pam_systemd`) | missing | missing |

So a masked host loses the directory *and* the bus, which means the original
"the runtime directory did not become available" report was accurate rather than
misleading, and both of ea-podman's readiness errors name the mask.

**What ea-podman does about it.** `ea_podman::subids::ensure_user_manager_carveouts()`
gives each account that needs a manager a unit file of its own, and leaves the
template mask alone:

```
write /run/systemd/system/user@<uid>.service   (a real copy of the vendor unit)
systemctl daemon-reload                        (once; the mask itself is unchanged)
        ├─ loginctl enable-linger <user>       (persistence)
        └─ systemctl start user@<uid>.service  (up now)

then:  poll for /run/user/<uid>/bus
```

A unit file named for the instance takes precedence over the template, and is not
a mask. So one account's manager starts while every other account is still
refused by the template mask, and CLOS-4517's protection is exactly as before.

Those are two different jobs after the unit is in place. `enable-linger` owns
*persistence* — the `/var/lib/systemd/linger` marker, so the account's containers
survive logout and reboot. The explicit `systemctl start` owns *up right now*,
which `enable-linger` cannot do: for an account that already lingers, logind will
not retry a manager it believes it already handled, which is exactly the
post-reboot state on a CageFS host (marker present, `/run/user/<uid>` present,
bus missing).

**Why not lift the mask for the length of the start (EA4-319's first fix, EA4-321).**
That does start the manager, and on systemd 239 and 257 it leaves it running,
because masking a unit does not stop an instance that is already running. On
systemd 252 (CloudLinux 9, AlmaLinux 9) it does not: a `daemon-reload` that
*changes the template's mask state* tears down `user-runtime-dir@<uid>.service`
for every running instance, however long it has been up. The manager still
reports `active` but has no `/run/user/<uid>` and no bus, which looks exactly like
the original masked-host failure. It is not a race: a reload with no mask change
is harmless, and waiting before the remask reload changes nothing. Skipping the
reload only moves the damage to the next `daemon-reload` anyone on the host runs
(an rpm scriptlet, `cagefsctl`, `systemctl enable`), which was measured. It was
reproduced on stock AlmaLinux 9 with no CloudLinux involved.

What EA4-321 found by probing, all of it easy to get wrong:

| Shape | Result on systemd 252 |
|---|---|
| a **real file** copy of the vendor unit at `/run/systemd/system/user@<uid>.service` | works: starts while the template is masked, survives reloads |
| a **symlink** there to the vendor unit | refused as masked; it is resolved as the template it points at |
| a `user@.service.d/` drop-in | refused as masked; a drop-in does not override a mask |
| the real file, **removed while its manager is running**, then a reload | the manager is torn down exactly as the remask did |

Properties worth knowing:

- **It is written whether or not the template is masked right now.** CageFS
  re-applies its mask on every install and upgrade, and CloudLinux's
  `disable-systemd-user-mask` flag leaves a host unmasked only until someone
  removes it. On systemd 252 the mask *arriving* tears down every manager that has
  no unit of its own, exactly as the remask did, so a manager started while the
  host happened to be unmasked needs its unit too. (A host with no vendor unit to
  copy and no mask just starts the manager from the template, as it always did.)
- **The boot sweep also covers managers logind started.** On an unmasked host
  logind starts every lingering account's manager at boot with no ea-podman
  involved. `ensure_user_sessions` gives those running managers their unit as well
  (tested: it does not disturb them, and they survive the mask arriving). The
  per-command `ensure_user_session()` does not, to keep its hot path free.
- **It is on the cold path only.** `ensure_user_session()` returns early whenever
  the account is healthy, so the unit is written once per cold account, not once
  per command. A unit that is already in place and current costs no write and no
  reload.
- **Only the manager *start* needs it.** `systemctl --user` calls
  (`ea_podman::util::sysctl`, `_systemctl_quiet`) talk to the account's
  already-running manager over its own bus, where the template mask is
  irrelevant.
- **It is per account, not host-wide.** Nothing is ever unmasked, so there is no
  window for another account to slip through and no lock to serialise on. The one
  reload happens after the unit is written, with the template's mask unchanged,
  which is the only kind of reload shown to be safe for other accounts' running
  managers.
- **The unit is only removed once the manager is down.** `remove_user_session()`
  (the release when an account's last container goes) runs `loginctl
  disable-linger`, waits a few seconds for the manager to stop, and then calls
  `remove_user_manager_carveout()`, which does nothing while the manager is
  running. There is deliberately no reload on removal. After it the account is
  refused again, like any other.
- **Every unit ea-podman writes is recorded, and only a recorded unit is ever
  replaced or removed.** `/run/ea-podman/written/<uid>` holds the sha256 of what
  was written. A unit at that name is treated as ours only while it is a regular
  file whose content matches the record: an administrator's mask of one account
  (a `/dev/null` symlink or an empty file), or any other unit somebody else put
  there, is refused and left alone, whether it was there first or was put over
  ours later. A refused account is reported and not started; the other accounts
  in the same sweep are unaffected.
- **Which units are still wanted is asked, not recorded.** `reconcile_carveouts()`
  walks the record and takes back every unit whose account no longer lingers
  (released, never finished setting up, or deleted so its uid no longer
  resolves) once its manager is confirmed stopped, never from under a running
  one. There is deliberately no second note saying "this one is owed": the
  record of what we wrote plus the account's live state is the whole truth, so
  nothing can go stale against it. It runs at the start of every
  `release_user_session_as_root()` and of `ensure_user_sessions`, and a release
  or failed setup settles its own account straight away. So a release under a
  login session is finished later, not lost: the manager outlives
  `disable-linger`, the unit stays with it, and the next release or sweep
  anywhere on the host takes it back once the manager is down. Until then a
  login for that account can start a manager the mask would otherwise have
  refused; the window ends at that next release or sweep, or at a reboot.
- **A reload that did not happen is remembered.** The unit is written and then
  `systemctl daemon-reload` makes systemd see it. A failed reload, or a process
  killed between the two, would leave a file that already matches and so never
  triggers another reload. `/run/ea-podman/reload-pending` is created before the
  first unit is written and removed only after a reload succeeds, so the next
  run reloads regardless, and a failed reload is reported as itself instead of
  as the later, misleading "masked".
  `/run/ea-podman/lock` serialises all of this, so a release cannot take a unit
  away from an account that is being set up at the same moment.
- **`/run` is tmpfs.** A reboot clears every unit, which is right, since nothing
  is running either. The boot sweep writes them again before it starts anything,
  see below.
- **A systemd update is not seen until the manager restarts.** The unit is a copy
  of the vendor unit as of when it was written. A package update that changes the
  vendor unit leaves a running account on the old copy until its manager next
  restarts, or until the next cold bootstrap finds the copy differs and rewrites
  it.
- **An older version's abandoned unmask is repaired.** Before EA4-321 a `kill -9`
  mid-window could leave the template unmasked, recorded at
  `/opt/cpanel/ea-podman/user-manager-mask.state`. Nothing writes that file now,
  but a host upgraded while a window was open still has one, and the next run
  puts the mask back and removes the record. If that restore ever fails,
  ea-podman warns loudly and keeps the record so the host is not silently left
  unmasked.

**Reboot.** At boot the mask is already in place, so logind cannot start
`user@<uid>.service` for a lingering account and its containers would not come
back on their own, and `/run` holds no unit for it. Nothing else runs at boot.
Measured on a real masked host: the manager does not return.

The trigger for it is `ea-podman-user-managers.service`, a `oneshot` unit run at
boot that calls the root-only `ea-podman ensure_user_sessions`. That sweeps every
account the container registry says has containers and does for each one what
`ensure_user_session()` does for a single account.

It is not a loop over `ensure_user_session()`, because at boot the scale changes
which shape is affordable: every account's unit is written first with **one**
`daemon-reload` for the lot, every `systemctl start` happens, and then the buses
are polled together, one ceiling for the sweep and not one per account (that poll
is ~10s per account).

It warns and carries on per account, so one account that cannot start its manager
costs only itself and cannot abort the sweep half-way. On a host that is not
masked it starts nothing: logind has already started those managers by the time
it runs, every account takes the "already up" early return, and the only work is
giving them their unit, once.

An account's *next* ea-podman command still repairs it too, exactly as before —
the boot sweep is a second, proactive path to the same repair, not a replacement.

Proving it needs a real reboot, so it is a live test rather than a unit test:
`t/LiveTests/ea4-319-mask-poc.sh --yes pre-reboot-fixed` (stage 6). See EA4-319.

### `bash` on a `hidepid` host

The interactive `bash` verb (direct CLI only — root and unrestricted shells; it
is never delegated) still uses `podman exec -it`. That is fine for **root**,
which is not subject to `hidepid`, so root's interactive shell works on a
`hidepid` host. An **unrestricted-shell cpuser** on a `hidepid` host cannot get
an interactive shell: entering the subuid-owned container needs root, and a live
TTY cannot be handed through the adminbin (the same TTY wall described above) —
so there is nothing to gain by routing `bash` through the adminbin. Such users
are pointed at `cmd`, which runs a (non-interactive) command through exactly
that delegation and therefore does work on a `hidepid` host.

## Summary

- Interactive `ea-podman bash` requires a live TTY. For restricted accounts that
  runs into three independent walls: rootless podman cannot start inside the
  `nosuid` jail/cage; escaping the restricted environment is either gated
  (jailshell) or impossible by shell choice (CageFS); and UAPI has no way to
  carry a terminal.
- jailshell can be escaped by choosing a non-jail shell (`su -s /bin/bash`), but
  CageFS cannot — its cage is entered per-uid at the PAM layer, independent of the
  shell. The only outside-the-cage route is a root-only, non-PAM setuid drop, and
  it still cannot be exposed over UAPI.
- **CageFS 7.6.39+ masks `user@.service`** (CloudLinux CLOS-4517), which stops
  the per-user systemd manager rootless podman needs. ea-podman leaves the
  mask alone and starts each account's manager from a unit file of its own under
  `/run/systemd/system/` (lifting and restoring the mask, EA4-319's first fix,
  tears running managers down on systemd 252; EA4-321). Logind cannot start those managers
  itself at boot while the template is masked, so
  `ea-podman-user-managers.service` runs the same repair then for every account
  the registry says has containers.
- A **non-interactive** "run a command in the container" verb sidesteps all three
  walls; it is implemented as the `cmd` UAPI verb (CPANEL-54360), entering the
  container with `nsenter` as root (necessary because `hidepid=2` hides the
  subuid-owned container process from the cpuser, breaking `podman exec`). An
  interactive shell for a restricted (or non-root, `hidepid`-host) account
  remains unavailable.
