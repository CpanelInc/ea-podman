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
- A **non-interactive** "run a command in the container" verb sidesteps all three
  walls; it is implemented as the `cmd` UAPI verb (CPANEL-54360), entering the
  container with `nsenter` as root (necessary because `hidepid=2` hides the
  subuid-owned container process from the cpuser, breaking `podman exec`). An
  interactive shell for a restricted (or non-root, `hidepid`-host) account
  remains unavailable.
