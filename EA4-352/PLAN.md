# Replace `systemd --user` with root-owned `User=` system units managed by the admin module

## Context

ea-podman runs each account's rootless containers as `systemd --user` units under that account's `user@<uid>.service` manager.

CloudLinux CageFS 7.6.39+ masks the `user@.service` template server-wide (CLOS-4517). The reason: a manager spawned by PID 1 runs whatever units the account puts in `~/.config/systemd/user`, and it runs them **outside the cage**.

Since 1.0-32 (EA4-321), ea-podman works around the mask:
- it gives each container account a root-owned `/run/systemd/system/user@<uid>.service` copy;
- it adds linger and a boot sweep.

That gives those accounts back exactly what CLOS-4517 removed.
- `test.sh` on this box proved it: a unit the account dropped in `~/.config/systemd/user` ran as uid 1002 with no capabilities, in the host mount namespace.
- CloudLinux has since reported a real compromise (CLOS-7971).
- Masking is spreading.

**Goal.** No per-user manager at all:
- Containers run as root-owned **system** units, from a fixed template, with `User=<cpuser>`.
- Only the root-side admin module creates or controls those units.
- The account can neither define nor edit units.
- Nothing the account controls ever reaches root.
- Rootless podman, userns and subuid/subgid stay as they are.

### Decided
- **Unit name:** `ea-podman-<container>.service`.
- **Account renames:** keep refusing renames for accounts that have containers.
- **Version:** ea-podman **2.0**. The major bump marks the behaviour change: system units, admin-only management, and no EAPodman UAPI.
- **One release.** Spikes and full pre-release testing come first, then a single 2.0 release that migrates everyone. There are no dormant or staged releases and no follow-up cleanup release.
- **Downgrade:** not supported. 1.x is removed from the mirrors (RPM and Ubuntu), so `dnf`/`apt` have nothing to go back to. An internal archive copy is kept only for the migration live tests.
- **Storage:** a fresh ea-podman storage dir. The user's own raw-podman data is left intact (see Phase 4).

## What goes away and what stays

**Goes away in 2.0** (Phase 7). Only the one-time migration code (`ea_podman::migrate`) still understands the 1.x layout:
- **The user-manager session machinery:**
  - linger and the `granted-linger` records;
  - the `user@<uid>` carveouts and the mask/unmask-window handling;
  - the `ea-podman-user-managers` boot sweep;
  - `ensure_user_session(s)`, `release_user_session*` and `ensure_container_session`;
  - `XDG_RUNTIME_DIR=/run/user/<uid>` and `DBUS_SESSION_BUS_ADDRESS`;
  - the plugin's `ENSURE_SESSION` and its `user@.service.d` delegate drop-in.
- **Every `systemctl --user` call.**
- **The LVE + cgroup v2 "kills systemd --user" advisory** (`util.pm:366-411`). There is no user manager left for it to warn about. The LVE question moves to P0-6.

**Stays:**
- **The admin execution path** (`delegate_to_admin`, `_as_cpuser`). Phase 3b makes it the *only* non-root path and removes the restricted-shell/CageFS detection and the EAPodman UAPI. podman still can't run inside the cage: nosuid breaks newuidmap, and jailshell lacks the binaries. That is why everything except `bash` runs outside the cage via admin, and `bash` stays direct for unrestricted shells only.
- **User namespaces.** Rootless podman still creates a user namespace per container, plus mount, net, pid and other namespaces inside it. It also still needs subuid/subgid allocation (`subids.pm` `_ensure_subids`) and the setuid `newuidmap`/`newgidmap`. **The kernel-CVE exposure is unchanged.** This plan fixes CLOS-4517, not the userns CVEs. 2.0 does make the exposure narrowable: every user namespace ea-podman creates is created inside `eapodman.slice`, so a host BPF-LSM rule on `userns_create` can deny namespace creation everywhere else (F11, invariant 20; EA4-352 comment 1802820).
- **cgroups.** Containers still get their own cgroups:
  - `Delegate=yes` on the system units hands the account's processes a subtree;
  - podman uses `cgroupfs` there, with `--cgroups=split` (pinned), instead of asking the user manager over D-Bus. Split puts conmon and the container in sub-cgroups of the unit's delegated cgroup;
  - per-container limits (`--memory`, `--pids-limit`) are enforced on cgroup v2 **only with split**; without it they are silently ignored (Julian, EA4-352 comment 1801665). As today, they don't work for rootless on v1 (F12).
- **A smaller "session".** The per-user runtime directory now comes from the anchor unit `ea-podman-runtime@<uid>`, and `podman_env()` gives every podman call the same environment. That replaces the whole linger/carveout layer.

## Findings that shape the design

- **F1: we need our own runtime dir.**
  - Without linger, logind owns `/run/user/<uid>`. It overmounts it on login and wipes it on logout.
  - So we use a root-created `/run/ea-podman/user/<uid>`, set up by a per-user anchor unit.
  - Existing libpod DBs record `runroot=/run/user/<uid>`, so existing containers must be recreated in fresh storage.
- **F2: the cgroup manager has to change.** Existing containers may record `CgroupManager=systemd`, which needs the user bus. New containers are created with cgroupfs and `Delegate=yes`. This is a second reason to recreate.
- **F3: LVE limits may be lost.** A `User=` unit gets no PAM session, so CloudLinux `pam_lve` limits might not apply. Probe this. If needed, add `PAMName=ea-podman` with a root-owned `/etc/pam.d/ea-podman` (pam_lve/pam_limits only). Do not use `systemd-user`, which would start the user manager again. **Observed:** in a 2.0 prototype the containers were not in an LVE (Julian, EA4-352 comment 1801665). The PAM/LVE-entry step is therefore required; P0-6 now verifies the fix, not the need.
- **F4: residual (not root, not a regression).** The account owns its libpod DB. From inside the cage it could change a container's OCI runtime or hooks, which would then run as the user outside the cage. Pinning `CONTAINERS_CONF` does not close this. A root-owned graphroot would (follow-up).
- **F5: lifecycle actions don't check registration.** START/STOP/RESTART/STATUS only check the name suffix (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:404,414,423,432`). They must require `registered => 1`.
- **F7: an account's containers need a grouping cgroup.** As separate units in `system.slice`, nothing groups an account's containers. The Web Apps plugin's `MemoryLow` floor on `user-<uid>.slice` would protect nothing, and account totals could never be enforced. Fix: a per-account slice (see Phase 1). Requested on EA4-352 (comment 1800842).
- **F6: restore deletes too much.** `perform_user_restore` deletes all of `~/.config/systemd/user` (`util.pm:3185`), including the user's own units. Stop doing that.
- **F8: the runtime dir loses its size cap.** In 1.x, `/run/user/<uid>` is its own tmpfs, capped by logind (`RuntimeDirectorySize=10%`). A plain directory under `/run` shares the system tmpfs with PID 1, journald, `/run/systemd/transient` and every daemon's PID files, and disk quotas don't apply to tmpfs. Fix: the anchor mounts a capped per-uid tmpfs (Phase 1).
- **F9: moving out of `user-<uid>.slice` drops per-user limits and changes CPU fairness.** In 1.x every account's processes share the one `user.slice` weight and get logind's `TasksMax` (33%) plus any admin drop-ins on `user.slice`, `user-.slice` or `user-<uid>.slice`. Slices directly under the root would each be a sibling of `system.slice` with the same weight, and per-unit `DefaultTasksMax` (15%) has no per-account total. Fix: account slices nest under a packaged `eapodman.slice` (Phase 1).
- **F10: the as-user processes the migration starts must not get root's terminal.** `systemd-run --pipe` gives the transient unit `systemd-run`'s own stdin, stdout and stderr. When an admin runs `migrate_units` in a shell, stdin is root's TTY. The account can open `/proc/<pid>/fd/0` of its own podman process (same uid, not setuid; Yama doesn't restrict this), then read root's input or inject keystrokes with TIOCSTI (allowed on the EL8/EL9 and Ubuntu 22.04 kernels). Fix: 4.2a.
- **F11: a namespace-creation boundary (EA4-352 comment 1802820).** In 1.x and in the earlier plan, ea-podman creates user namespaces from cpsrvd's cgroup (the admin module's `_as_cpuser` child) and from root's as-user helpers. So no cgroup-based rule can tell ea-podman's namespace creation apart from anything else the account runs. Fix: every process root starts as an account runs in `eapodman-<uid>.slice`, through one slice runner (Phase 1). A host BPF-LSM rule on `userns_create` can then allow namespace creation only under `eapodman.slice`. Limits:
  - sound only on cgroup v2. On v1 an account can move its own process into a delegated cgroup (P0-11);
  - code running inside the account's containers can still create namespaces. The rule stops the account's shell, cron and CGI processes, not its container workloads;
  - enabled only after `migration/complete`, because 1.x containers run under `user@`;
  - needs a kernel with the `userns_create` LSM hook and `lsm=bpf` (P0-12). EL8's 4.18 has neither.
- **F12: per-container limits need `--cgroups=split`** (EA4-352 comment 1801665). With cgroupfs and `Delegate=yes` alone, podman doesn't place the container in a sub-cgroup of the unit, so `--memory` is not enforced. Fix: pin `cgroups = "split"` (Phase 1), and refuse start args that override it (Phase 3b).
- **F13: relative limits need matching values on the container unit.** `--memory`, `--memory-swap`, `--cpus` and `--pids-limit` are hard caps on the container's own cgroup, so split alone makes them work. `--memory-reservation` and `--cpu-shares` are not:
  - `--memory-reservation` becomes `memory.low`, which only protects up to what every ancestor is protected for. The chain is container → `ea-podman-<name>.service` → `eapodman-<uid>.slice` → `eapodman.slice`. The unit's own `memory.low` belongs to systemd (`MemoryLow=`, default 0), not to the delegated subtree. So on EL8 (4.18, no `memory_recursiveprot`) the reservation does nothing, and on newer kernels (`memory_recursiveprot`) the unit only gets a usage-weighted share of the slice's unclaimed floor, not a guaranteed amount;
  - `--cpu-shares` becomes `cpu.weight` (crun's conversion: about 39 for 1024 on older crun, 100 on newer). A weight only counts against sibling cgroups. Inside the unit, the container's only sibling is conmon's cgroup; between containers, the units compete with systemd's `CPUWeight=` (default 100). So `--cpu-shares` does nothing between containers;
  - `--memory-swap` becomes `memory.swap.max` and needs kernel swap accounting. Without it, podman warns and drops the limit.
  
  Fix: the container unit carries `MemoryLow=` and `CPUWeight=` taken from the container's reservation and shares (Phase 1), and slice floors include the unit floors. P0-4 checks swap accounting on every target.

## Phase 0: spikes (gate everything)

Run each probe on EL8 (cgroup v1), EL9, CL9 with CageFS 7.6.39+ masked, EL10, and Ubuntu 22.04 (podman 3.4) / 24.04.

| # | Probe | Decides |
|---|---|---|
| P0-1 | Use an existing DB with a new `XDG_RUNTIME_DIR` and pinned `CONTAINERS_*`. Do we get an error or a silent fallback? | Confirms recreate-in-fresh-storage |
| P0-2 | Start an old container from a system unit using cgroupfs, for a rootless **and** a rootful container. For rootful, also: does `podman rename` of a stopped container keep its CID and named-volume mounts (podman 3.4 and 4+)? | Recreate required? Rootful in-place branch (4.4) |
| P0-3 | Unit shape: `Type=forking` + `podman start` + `PIDFile` of conmon.pid, vs `start --attach`. Test stop, Restart, killing conmon, reboot. Does conmon land inside the unit's own cgroup? It must, because systemd refuses a PID read through a path the account owns unless that PID is in the unit's cgroup. Also: write `1`, and the PID of a root process, into `conmon.pid`; systemd must refuse both, and `systemctl stop` must kill neither. With `--cgroups=split`, a container *created* outside the unit (by the migration runner or the admin runner) and *started* by the forking unit: do conmon and the container land in sub-cgroups of the unit's cgroup (podman 3.4 and 4+)? | Template |
| P0-4 | `Delegate=yes` + cgroupfs on v1/v2. Where do conmon and the pause process land? Does stopping one unit hurt the account's other containers? Do container cgroups under `eapodman-<uid>.slice` receive delegated controllers on v2? Does `MemoryLow` on the account slice protect under memory pressure when `eapodman.slice` carries the sum of the floors? Is today's floor on `user-<uid>.slice` effective (`user.slice` has no `MemoryLow`)? Under CPU contention, do all container accounts together get no more than one `user.slice`-sized share against `system.slice`? Are the `memory` and `cpu` controllers in `cgroup.subtree_control` of `eapodman.slice`, `eapodman-<uid>.slice` and the unit, and received by the container cgroup? Is `--memory` enforced with split and not without it? Does every target have `memory.swap.max` (swap accounting), and is `--memory-swap` equal to `--memory` enforced as `memory.swap.max=0`? Does `--memory-reservation` protect a container under memory pressure with and without `MemoryLow=` on its unit, on EL8 (no `memory_recursiveprot`) and on EL9+? What `cpu.weight` does each target's crun write for `--cpu-shares=1024`, and under contention do two containers of one account split CPU by their units' `CPUWeight=`? The plugin is waiting on these answers (EA4-352 comment 1801665) | Anchor unit; parent slice values; plugin limits |
| P0-5 | Journald routing of `User=` unit output; where `podman logs` goes; whether `events_logger="journald"` works from a system unit with `User=` on every target | Messages/docs; events logger |
| P0-6 | **Gate, not an open item.** Is the unit's process inside `lve<uid>`, with and without `PAMName=ea-podman`? Same question for the `systemd-run --uid` transients (the migration runner and the plugin's builds), with `-p PAMName=ea-podman`. Do slice totals (`MemoryMax`/`CPUQuota`) double-limit against LVE? Which OOM fires first, and what does each report? Can LVE Manager's limits and the slice's be told apart in the logs? 2.0 does not ship unless every process ea-podman starts as the account is inside its LVE, as under 1.x (a prototype showed they are not without help) | F3; who owns account totals on CloudLinux |
| P0-7 | A caged account's container running from a system unit; does the CLI admin fallback still work? | CageFS parity |
| P0-8 | `CONTAINERS_CONF` semantics on podman 3.4 vs 4+; is user config fully ignored? | Pinned conf shape |
| P0-9 | Can a non-root user run `systemctl show` on a system unit on CloudLinux? | STATUS always goes through admin (expected) |
| P0-10 | The CLOS-7971 canary (`test.sh`) after migration and after reboot: it must never run, and no `user@<uid>` may exist | Acceptance |
| P0-11 | The bounded as-user runner (4.2a): `systemd-run --uid --gid --pipe --wait --collect -p RuntimeMaxSec=` running `podman` against old **and** new storage. On a timeout, does systemd reap a SIGSTOPped child, a ptrace-stopped child, and a grandchild that called `setsid`/double-forked? How does `systemd-run --wait` report `Result=timeout` vs a non-zero exit (systemd 239, 249, 252, 255)? On v1, can the account move a runner process into its own delegated cgroup, and does `--wait` still return? | Runner mechanism; timeout detection |
| P0-12 | BPF-LSM namespace boundary (F11), on EL9, CL9, EL10 and Ubuntu 24.04. Does the kernel have the `userns_create` LSM hook, and can `lsm=bpf` be enabled? Load a test-only BPF-LSM program that denies `userns_create` unless the task is under the `eapodman.slice` cgroup. Then all of these must work: install, upgrade, start/stop/restart, reboot, the full migration, plugin builds, backup and restore, `ea-podman bash`, and an anchor restart after the pause process is killed. From the account's SSH shell, cron and a CGI, `unshare -U` and raw `podman run` must be denied | F11 holds; platforms where the rule is supported |

## Phase 1: root-side units module

**New module: `SOURCES/lib/ea_podman/units.pm`.**
- Add it to the spec Source/install/`%files` and to `debify/debian/ea-podman.install`.
- Load it with the guarded sibling-require used for `subids.pm` (`util.pm:73-81`).

**Pinned config, root:root 0644 under `/opt/cpanel/ea-podman/etc/`:**
- `containers.conf`: `cgroup_manager="cgroupfs"`, `cgroups="split"` (F12), `events_logger="journald"` (the 1.x default; per P0-5), explicit `runtime` and `conmon_path`, `hooks_dir=[]`, and `default_mounts_file` pointed at an empty root-owned file, so the account's `~/.config/containers/mounts.conf` can't add mounts. If P0-5 forces `events_logger="file"`, also set `events_logfile_max_size` wherever the podman version supports it. The events file then lives in the capped runtime tmpfs (F8), so it can't grow past that cap even on podman 3.4, which doesn't rotate it.
- `storage.conf`: `rootless_storage_path` = `~/.local/share/ea-podman/storage`.
- `old-storage.conf` and `old-containers.conf`, for the migration only (4.2a): the 1.x graphroot (`~/.local/share/containers/storage`) with the same pinned runtime, conmon, hooks and mounts settings. The migration never runs podman under the account's own `containers.conf`.
- A registries reference.
- Every podman invocation gets `CONTAINERS_CONF` / `CONTAINERS_STORAGE_CONF` / `CONTAINERS_REGISTRIES_CONF` pointing at these files, through a new `podman_env($uid)`. That covers the units, the CLI, the admin module and the plugin. `podman_env` also clears `CONTAINERS_CONF_OVERRIDE` and sets `XDG_CONFIG_HOME` to a root-owned empty directory, so neither `containers.conf.d` drop-ins nor the account's `policy.json` or `registries.d` are read (P0-8 confirms this per podman version).

**Anchor unit: `/usr/lib/systemd/system/ea-podman-runtime@.service`.** This is a static template shipped in the package, with the instance being the uid:
- `User=%i`
- `ExecStartPre=+/opt/cpanel/ea-podman/bin/runtime-mount %i`. This is a root-owned helper and the only privileged Exec line in any ea-podman unit. It is allowed because the anchor is fixed packaged text, never rendered. The helper:
  - accepts only a numeric `%i` that `getpwuid` resolves, and is not 0;
  - creates `/run/ea-podman/user/<uid>` (root parents, 0755) unless it exists, refusing a symlink or a non-directory;
  - mounts a tmpfs on it unless one is already mounted there: `size=` and `nr_inodes=` from root-owned `/opt/cpanel/ea-podman/etc/runtime.conf` (defaults matching logind's `RuntimeDirectorySize=10%` and `RuntimeDirectoryInodesMax`), `mode=0700`, `uid=`, `gid=`, `nosuid`, `nodev`.
  
  This replaces `RuntimeDirectory=`. Its pages are charged to the writer's memory cgroup, as `/run/user/<uid>` is in 1.x. `release_runtime` and the account-removal hooks unmount it, then remove the directory (F8).
- `Delegate=yes`
- the pinned environment
- `ExecStart`: `podman unshare /bin/true`, so it holds the pause process (per P0-4)
- `Type=oneshot`, `RemainAfterExit=yes`
- explicit `TimeoutStartSec=` and `TimeoutStopSec=`. A oneshot's start timeout defaults to infinity, and its `ExecStart` runs as the account, so without them a root `systemctl start` of the anchor could be held open by the account (4.2a).
- `Slice=eapodman-%i.slice` (see below)
- `PAMName=ea-podman`, if P0-6 requires it (the same applies to the container units and the `systemd-run --uid` transients)

**Container unit: `/etc/systemd/system/ea-podman-<name>.service`.**
- Rendered from a **fixed template in code**. The only substituted values are `{NAME}`, `{USER}`, `{GROUP}`, `{UID}`, `{CID}`, `{NPROC}`, `{MEMLOW}` and `{CPUWEIGHT}`.
- A marker line records `owner`, `uid` and `container`.
- `Requires=`/`After=` the anchor unit.
- `Type=forking`, `ExecStart`/`ExecStop` = `podman --cgroup-manager=cgroupfs start` / `stop`, and `PIDFile=` under the runtime dir.
- `LimitNPROC={NPROC}`.
- `Delegate=`, written as the explicit list `cpu io memory pids` (plus `cpuset` where systemd is 244 or newer; EL8's 239 can't delegate it, so `--cpuset-cpus` is not supported there). This is the same as `Delegate=yes` today, but makes it clear what the account receives.
- `MemoryLow={MEMLOW}` and `CPUWeight={CPUWEIGHT}` (F13). Without them, a container's `--memory-reservation` and `--cpu-shares` are written into its cgroup but do nothing.
  - The values come from the validated install args (`--memory-reservation`, `--cpu-shares`), recorded in the registry entry as `memory_low` and `cpu_weight` at `REGISTER`. Root never reads them back from the libpod DB, which the account owns (F4).
  - `{MEMLOW}` is the reservation in bytes; with no reservation it is `0`.
  - `{CPUWEIGHT}` is `shares * 100 / 1024`, rounded and clamped to 1..10000 (systemd's own shares-to-weight mapping); with no `--cpu-shares` it is `100`, systemd's default.
  - No `MemoryMax=` or `CPUQuota=` on the unit. The container's own caps are in its cgroup, and a smaller unit value would silently override them.
- `Slice=eapodman-{UID}.slice`.
- Restart values come from `%container_unit_directives` (`util.pm:700`). Keep it as the single source so that `container_unit_settle_ceiling_sec` (`util.pm:1112`) still works.
- Explicit `TimeoutStartSec=` and `TimeoutStopSec=`, added to `%container_unit_directives`. `ExecStart`/`ExecStop` run as the account, and root runs `systemctl start`/`stop` on these units while holding the account lock (4.2 rule 2, 4.3 step 8). These timeouts are what bound those calls (4.2a).
- `WantedBy=multi-user.target`.
- There are **no** `+`/`!` Exec prefixes, `PermissionsStartOnly`, or root `ExecStartPre`/`Post`.
- **Name namespace.** Container units are always `ea-podman-<name>.service`, where `<name>` matches the container-name regex and so always contains `.<user>.NN`. No ea-podman-internal unit starts with `ea-podman-`: the slice runner's transient units are `eapodman-run-<uid>-<label>-<seq>.service`, the migration's are `eapodman-migrate-<uid>-<step>-<seq>.service` (4.2a), and the slices are `eapodman.slice` / `eapodman-<uid>.slice`. Code that looks for internal units matches a strict regex, never a glob, so an account can't name a container to match one.
- Root's own (rootful) containers get a variant without `User=` or the runtime-dir settings, with `Slice=eapodman-0.slice`, so a namespace rule (F11) needs no exception for ea-podman's own containers.

**Slice runner (F11): `run_as_user_in_slice($user, $label, $timeout, %opts, @argv)`.** This is the 4.2a mechanism, moved into `units.pm` so it outlives `migrate.pm`. It is root-only, and it is **the only way root code runs anything as an account**: the admin module's `_as_cpuser` child, root's as-user helpers, hooks, restore, the migration, and the plugin's builds and `_in_user_session`. A lint test covers `SOURCES/` and the plugin.
- `systemd-run --uid --gid --unit=eapodman-run-<uid>-<label>-<seq> --slice=eapodman-<uid>.slice --pipe --wait --collect`, with `RuntimeMaxSec=<timeout>`, `TimeoutStopSec=10`, `KillMode=control-group`, `PAMName=ea-podman` per P0-6, `WorkingDirectory=<home>`, and `podman_env`.
- stdin is `/dev/null` and stdout/stderr are fresh pipes (F10); output is capped at 1 MB per stream; there is an outer alarm (4.2a).
- `<label>` matches `^[a-z0-9_]+$`. Leftover units are matched by strict regex, never a glob.
- Optional `oom_score_adjust` (whitelisted values, 0 to 1000) for callers such as plugin builds (Phase 6).
- Callbacks into the admin module (`REGISTER`, `UNIT_INSTALL`, `START`) work from inside the transient unit, because the admin socket is reachable from there.

**Per-account slice: `eapodman-<uid>.slice`.**
- It groups the account's anchor unit, its container units, and the plugin's build jobs. It gives the account a place for a `MemoryLow` floor, real totals (`MemoryMax`, `CPUQuota`, `TasksMax`) and live changes through `systemctl set-property`. Per-container flags still need a recreate.
- **Naming and nesting.** Dashes in slice names mean nesting, so `eapodman-1002.slice` sits under `eapodman.slice`, which sits directly under the root (F9). The account slices must not sit at the top level: each would be a sibling of `system.slice` with the same CPU and IO weight, and N container accounts would together outweigh every system service N to 1.
- **Parent slice: `/usr/lib/systemd/system/eapodman.slice`**, shipped in the package as fixed text:
  - `CPUWeight=` and `IOWeight=` equal to `user.slice`'s, so all container accounts together compete like one `user.slice`;
  - `TasksMax=` from `runtime.conf` (default 33%, logind's `UserTasksMax`) as a host-wide total;
  - `MemoryLow=` is kept by root equal to the sum of the account slices' floors. A child's `memory.low` only takes effect up to what its ancestors are protected for, so `set_slice_properties` and `clear_slice_properties` recompute the parent in the same call.
- **Account floor includes unit floors (F13).** The account slice's effective `MemoryLow` is the larger of the plugin's account floor and the sum of the account's container units' `MemoryLow`. `write_unit` and `remove_unit` recompute it, and `eapodman.slice`'s, in the same call as `set_slice_properties`, so a reservation is never larger than what its ancestors protect.
- **Per-account defaults.** Each account slice gets a default `TasksMax` (from `runtime.conf`, default the same as `user-<uid>.slice` today), so an account's units share one task total instead of 15% each. If the host has drop-ins on `user-.slice` or `user-<uid>.slice` (`MemoryMax`, `CPUQuota`, `TasksMax`), `ensure_runtime` logs them and the release notes say that they no longer cover containers and must be set on `eapodman-.slice` instead.
- **Implicit, no file.** systemd cannot template slices, and it creates a slice implicitly when a unit references it with `Slice=`. So no per-account slice file is written; the defaults are set by `ensure_runtime` through `set_slice_properties`. If P0-4 shows a file is needed, it is fixed text with the uid from `getpwnam`, written like the unit file.
- **Properties are set only by root,** through `set_slice_properties($user, %props)`:
  - whitelist: `MemoryLow`, `MemoryMax`, `CPUQuota`, `TasksMax`;
  - values must be numeric, unit-suffixed, or `infinity`;
  - the slice name is always derived from `getpwnam`, never from caller input.
  
  These persist as drop-ins under `/etc/systemd/system.control/eapodman-<uid>.slice.d/`.
- **No delegation on the slice itself.** The services inside it keep `Delegate=`. On v2, systemd enables the needed controllers on the slice. On v1 the limits stay unenforced, as today.
- **Lifecycle.** `ensure_runtime` brings the slice into use. `release_runtime` and account removal remove its `system.control` drop-ins, so a new account that reuses the uid can't inherit old limits.

**Validation, on every render:**

| Value | Rule |
|---|---|
| name | `validate_user_container_name` (`util.pm:1938`) plus `container_name_belongs_to_user` (`util.pm:690`) |
| user | `getpwnam` succeeds, matches a strict regex, and equals the registry user |
| uid/gid | Taken from `getpwnam` only |
| CID | `^[0-9a-f]{64}$` |
| NPROC | Digits or `infinity` |
| MEMLOW | Digits only (bytes), from the registry entry; `0` when unset |
| CPUWEIGHT | Integer 1..10000, from the registry entry; `100` when unset |

After rendering, check the output against the template skeleton:
- every line without a placeholder is byte-identical to the template;
- there is exactly one `User=` line;
- no substituted value contains a newline, `%`, a quote, a backslash or whitespace.

**Writing the unit:**
- Write a tmp file in `/etc/systemd/system` with `O_EXCL|O_NOFOLLOW`, root:root 0644, fsync, then rename.
- Refuse if the destination is a symlink or not a regular file.
- Then `daemon-reload`, coalesced: a reload already pending (the 1.x `/run/ea-podman/reload-pending` pattern) is not repeated, and reloads are rate-limited host-wide. Accounts can trigger `UNIT_INSTALL`/`UNIT_REMOVE`, and each one reloads PID 1, which in 1.x only the account's own manager did.
- **Per-account unit cap.** `write_unit` refuses past `max_units_per_account` (root-owned `runtime.conf`), so an account can't fill `/etc/systemd/system` or PID 1's memory.

**API, all root-only (each dies unless `$> == 0`):**
- `write_unit`, `remove_unit`
- `unit_ctl($name, start|stop|restart|enable|disable|reset-failed)`
- `unit_show($name, @whitelisted_props)`
- `ensure_runtime($user)` / `release_runtime($user)`, which also own the slice lifecycle
- `set_slice_properties($user, %whitelisted)` / `clear_slice_properties($user)`
- `units_for_user`, `orphan_units` (glob plus marker parse)
- `container_nproc_cap`

Move `_systemctl_quiet` / `_systemctl_show` / `_systemctl_value` (`util.pm:1007,1027,610`) here as plain `systemctl`, keeping them as mockable subs.

**Registry:** add `uid` and `unit` to entries in `register_container_as_root` (`util.pm:2418`), under `_mutate_known_containers_as_root` (`util.pm:2376`). The migration back-fills them.

## Phase 2: admin module actions and routing

All in `SOURCES/Cpanel-Admin-Modules-Cpanel-ea_podman.pm`.

**New actions:**
- `UNIT_INSTALL` (gated): the container must be registered to the caller and exist in the caller's storage. Root reads the CID by inspecting as the user. That inspect runs **before** the account lock is taken, never under it (4.2 rule 1). Under the lock, root re-checks only the registry and the validated CID, then writes the unit.
- `UNIT_REMOVE`: for a registered container, or an orphan whose marker uid is the caller's.
- `UNIT_SHOW`: returns whitelisted properties only.
- `RESET_FAILED`.
- **No `SLICE_SET` action.** The admin module's caller is always the account: its identity comes from the socket's peer credentials, so there is no "authorized non-account caller" to let through. Root-side callers (WHM, the Web Apps plugin's adminbin, which already runs as root) call `ea_podman::units::set_slice_properties` directly. An admin action would leave a single authorization bug between the account and its own `MemoryLow` (reserving host memory) or `MemoryMax`.

**START/STOP/RESTART/STATUS:**
- Use `_own_container_arg(..., registered => 1)`, and require the unit's marker uid to match the caller.
- Root runs `unit_ctl` itself, with no `_as_cpuser`.
- START and RESTART run reset-failed, then the verb, then the `wait_for_container_unit_verdict` poll (`util.pm:1133`, moved to root).
- **Locking.** These actions, together with `UNIT_INSTALL`, `UNIT_REMOVE` and `RESET_FAILED`, take the per-account lock only around their own root-side work, with a bounded wait. INSTALL/UPGRADE never hold it across their `_as_cpuser` child, because that child calls these same actions. The rules are in 4.2.

**ENSURE_USER / RELEASE_USER:**
- `ENSURE_USER` keeps subid allocation (`subids::ensure_user_root` minus the session). It calls `ensure_runtime` when the account has containers or is creating one, and returns `{has_runtime, nproc}`.
- `RELEASE_USER` stops the anchor unit when the account has no units left.
- **An account that hasn't been migrated yet:** lifecycle actions refuse with "this account's containers have not been migrated to ea-podman 2.0 yet; root can run `ea-podman migrate_units`". They do not migrate the account themselves.

**Routing:**
- Every non-root lifecycle call goes through admin, following the `register_container` pattern (`util.pm:2688`): root calls `ea_podman::units` directly, everyone else uses `Cpanel::AdminBin::Call`.
- Update the POD's AUTHORIZATION and HOSTILE ARGUMENTS sections.

## Phase 3: rewire util.pm and the CLI

- **`sysctl()` (`util.pm:413`) is deleted,** with no compatibility shim. The Web Apps plugin ships in lockstep (Phase 6) and uses the new exports. Internal callers use `api_lifecycle` / `install_container_unit` / `UNIT_SHOW`.
- **Unit install path:**
  - Delete `_podman_generate_systemd` (`util.pm:976`) and `_add_container_unit_directives` (`util.pm:714`). User-produced unit text must never reach root.
  - `generate_container_service` (`util.pm:986`) becomes `install_container_unit($name)`, which goes through admin/root.
- **`_ensure_latest_container` tail (`util.pm:1642-1667`) and rollback (`util.pm:1700-1733`):** call `install_container_unit`, then admin START unless `--no-start`.
- **`uninstall_container` (`util.pm:2318`):** UNIT_REMOVE, then `podman rm` as the user. It no longer writes anything under `~/.config`.
- **Status and errors:**
  - `verify_container_started` (`util.pm:1182`) uses UNIT_SHOW.
  - Rewrite the messages at `util.pm:1201-1210, 1477, 1765, 3484`: no `systemctl --user`. Point to `ea-podman status`, `podman logs`, and root `journalctl -u ea-podman-<name>`.
- **`api_lifecycle` / `api_status` (`util.pm:3449,3498`):** non-root callers go to admin.
- **Environment:**
  - `ensure_su_login` (`util.pm:99`), `run_in_user_session` (`util.pm:3339`) and `resolve_container_init_pid` (`util.pm:300`) apply `podman_env`. When root calls them, they run through the slice runner (F11), never a direct setuid fork.
  - Keep the "rootless runtime directory … does not exist" wording, because `ea-podman.pl:108` matches on it.
  - `get_containers` (`util.pm:642`) and `util.pm:2102` check the new runtime dir.
- **nproc:** the unit's `LimitNPROC` and the `--ulimit nproc` passed at create (`util.pm:475-487`) come from the same `container_nproc_cap`.
- **`_backup_name_is_free` (`util.pm:2151`)** checks the `/etc` unit path.
- **CLI (`SOURCES/ea-podman.pl`):**
  - `start/stop/restart/status` (`:447-510`) go through `api_lifecycle` / `api_status` for every caller.
  - Remove the `ensure_user_sessions` verb (`:1047-1089`).
  - Add the root verbs `reconcile_units` and `migrate_units`.

## Phase 3b: one execution path through the admin module (all non-root verbs except `bash`); remove the EAPodman UAPI

**Why.** The UAPI existed only to get podman out of the CageFS/jailshell view. Since 1.0-32 (EA4-315) the CLI reaches the admin module directly. Once every non-root verb goes through admin, podman runs as the user in exactly one place: the admin module's `_as_cpuser` (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:567-593`).

**CLI (`SOURCES/ea-podman.pl`):**
- For `$> != 0`, every verb except `bash`, `avail`, `testbin` and `help` goes through `delegate_to_admin` (`:162-205`), whatever the shell or cage:
  - `avail` only reads `/opt/cpanel`;
  - `testbin` only prints the perl version.
- `bash` stays direct for unrestricted shells only. Restricted shells keep today's refusal. Before it execs, `bash` calls `ENSURE_USER` through admin, so the anchor and its pause process are up. `podman exec` then only `setns`-joins existing namespaces and creates none outside the slice (F11). Note this in the help text.
- **Remove:**
  - the `_has_unrestricted_shell` gate (`:58-66`);
  - the CageFS runtime-dir fallback (`:91-116`) and the regex it matches;
  - the "restricted shell" wording in `delegate_to_admin`'s help and errors;
  - `%bridge_verb`/`%bridge_alias` as a *restriction*. They become the general verb-to-action map (`_admin_action_for_verb`, `:287-303`).
- **Audit:** the cPanel Terminal refusal (`:69-82`). Drop it if its only reason was running podman locally.
- **Root** keeps the direct path.

**Admin module coverage.** Existing actions cover install, upgrade, list, start, stop, restart, uninstall, status, cmd and containers (`REGISTERED_CONTAINERS`). New or extended:

| Change | Detail |
|---|---|
| `SUBIDS` (new) | Report, plus `--ensure` via `ENSURE_USER` |
| `BACKUP` / `RESTORE` (new) | The user's own `ea-podman backup`/`restore` |
| `CLEAN` (new) | List, or `--run` |
| `INSTALL` / `UPGRADE` (extended) | Accept the **full CLI argument set** the direct path allowed: arbitrary start args including `-v`/`--mount`, `--cpuser-port`, `--webapp-dir`, `--no-start`. These are safe because they run in the `_as_cpuser` child and are validated by `validate_start_args` (`util.pm:1966`) as the user, exactly as today. The "not expressible through the UAPI" limit in `DESIGN.md` goes away. |

- **Paths resolve in the host view, not the cage's.** The `_as_cpuser` child runs outside CageFS. So for a caged or jailshell account, any path argument names a file in the real filesystem: the real `/tmp`, or files that CageFS hides but the uid can read. Today's admin `INSTALL` takes only name, image, ports and env (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:366-380`), so this is new for those accounts. `-v`/`--mount` are handled by EA4-343 and out of scope here. The other path-taking arguments get the same rule as EA4-343: resolved as the user (`realpath`) and refused unless they are inside the account's home. That covers:
  - start args `--env-file`, `--label-file`, `--authfile`, `--cidfile`, `--pidfile`, `--conmon-pidfile`, `--log-opt path=`, `--seccomp-policy`, `--security-opt seccomp=`;
  - `--webapp-dir`;
  - the BACKUP output path and the RESTORE input path.
  
  `--network=host` is not a path, so this rule doesn't cover it. It is listed with `-v` as a decision for EA4-343, and the release notes name it.
- **Cgroup start args are refused (F12).** `validate_start_args` refuses `--cgroups`, `--cgroup-parent` and `--cgroup-conf`. Otherwise the account could move a container out of its unit's cgroup and escape both the slice limits and the namespace rule (F11).
- **CMD and code in the slice.** `podman unshare`/`run`/`exec` through CMD run account-chosen code inside the slice. That is the same as what the account's container workloads already do, so it is not new exposure under F11. Still, refuse `unshare` unless it is already a supported verb.
- Every action: `registered => 1` ownership where a container is named, the feature gate where the UAPI had one (`Cpanel-API-EAPodman.pm:63-77` moves into the actions), and existing timeouts (install/upgrade 1800s).
- `run_in_user_session` (`util.pm:3339`) stays only as the admin child's wrapper. Rename it (e.g. `run_as_cpuser_captured`). It applies `podman_env`, captures output, and `chdir`s to home. Its cpsrvd comments go.
- **`_as_cpuser` runs in the slice (F11).** The admin module's `_as_cpuser` (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:567-593`) runs its child through `units::run_as_user_in_slice`, with the action's existing timeout (350 s or 1800 s) as `RuntimeMaxSec`, instead of forking under cpsrvd. The 1 MB cap below and the per-account semaphore still apply.
- Output is buffered, not streamed. That's acceptable; note it in the help text for install/upgrade.
- **Root-side limits, because every non-root verb now runs in cpsrvd:**
  - the captured output and the Storable return of `_as_cpuser` are capped at 1 MB per stream, like the migration runner (the rest is drained and discarded, and the reply says it was truncated);
  - a per-account semaphore (`max_concurrent_admin_actions` in `runtime.conf`, default 2) limits how many long-running actions (INSTALL, UPGRADE, BACKUP, RESTORE, CLEAN, CMD) one account can hold open at once. Further calls fail at once with "too many ea-podman operations in progress for this account".

**Remove the EAPodman UAPI:**
- **Code and build:**
  - `SOURCES/Cpanel-API-EAPodman.pm`;
  - the nine `SOURCES/EAPodman-*.openapi.yaml` files;
  - `build-tools/gen-openapi.py`, if nothing else uses it;
  - spec Source12-Source2x, install and `%files` entries;
  - debify `ea-podman.install` and `override_dh_auto_install.sh` lines.
- **Docs and tests:**
  - `docs/uapi.md`. Replace it with a short `docs/admin-routing.md` describing the single admin path;
  - `t/SOURCES-Cpanel-API-EAPodman.t`;
  - UAPI assertions in the live tests (jailshell, cagefs, memcached16-cagefs, ea4-315).
  - Keep `DESIGN.md`, README and help-text references in sync.
- **Changelog:** "Remove the EAPodman UAPI module; ea-podman's CLI routes through its admin module for all accounts". This is a breaking change for anyone calling `uapi EAPodman` directly. No consumers exist in the cPanel or cpanel-plugins checkouts.
- **Ships with:** the 2.0 release, so routing changes once.

**Tests:**
- Extend `t/SOURCES-Cpanel-Admin-Modules-Cpanel-ea_podman.t` for the new and extended actions: ownership, feature gate, full install args, `-v` validated as the user.
- Add a CLI routing test: non-root with any shell goes to admin; `bash` stays direct only for unrestricted shells; root stays direct.
- `--cgroups=…`, `--cgroup-parent` and `--cgroup-conf` in start args are refused.
- `_as_cpuser` routing: the child runs through `run_as_user_in_slice` (a seam records the call), and a timeout fails the action without hanging cpsrvd.
- Path confinement: each path-taking argument, given `/tmp/x`, `/etc/passwd`, a symlink in home pointing outside it, and `../` escapes, is refused; the same argument under home is accepted.
- Output over the cap is truncated in the reply; a third concurrent long-running action from one account fails at once, and another account's action is unaffected.

## Phase 4: one-time migration from 1.x (in 2.0)

All migration logic lives in `SOURCES/lib/ea_podman/migrate.pm`, the only 2.0 code that knows the 1.x layout. It holds the linger-grant checks, carveout removal and mask restore, copied from today's `subids.pm` (`grant_covers_current_linger`, `remove_user_session`, `remove_user_manager_carveout`, `_restore_abandoned_unmask_window`). A later 2.x release removes it, no earlier than six months after 2.0 (see 4.8).

**Entry point.** One idempotent, root-only verb: `ea-podman migrate_units [--all|--user U] [--auto] [--status] [--wait] [--quiet] [--prune-old] [--stop-unmanaged] [--step-timeout SEC]`.
- It migrates whatever is not done yet and repairs leftovers.
- It prints per-account status.
- It exits non-zero while any account is `failed`.
- `--auto` marks an unattended run (the package and boot triggers). It applies the volume size limit (4.3 step 2).
- `--stop-unmanaged` is only accepted with `--user U`. See 4.3 step 1.
- When everything is done, a run is a quick no-op apart from the leftover sweep.

### 4.1 Triggers

All three run the same verb:

1. **Package install or upgrade** (`pkg.posttrans` on RPM; the end of `pkg.postinst` on Ubuntu, which runs after the registry restore). It starts the verb in the background and never waits or fails:
   ```
   [ -d /run/systemd/system ] && systemd-run --unit=ea-podman-migrate-run --no-block /opt/cpanel/ea-podman/bin/ea-podman migrate_units --all --auto --quiet || true
   ```
   Later 2.x updates trigger it as well, which is a no-op once migration is done.
2. **Boot.** A new timer, `ea-podman-migrate.timer` (`OnBootSec=1min`, `WantedBy=timers.target`), starts a new oneshot, `ea-podman-migrate.service` (`ConditionPathExists=!/opt/cpanel/ea-podman/migration/complete`, `TimeoutStartSec=infinity`, **no `[Install]` section**). The service runs the verb (with `--auto`) once per boot until `complete` exists. After that its condition is false and it is skipped on every later boot.
   - **Why a timer.** `WantedBy=multi-user.target` on the service would make the target wait for it: a target gets an implicit `After=` on every unit it wants (systemd.target(5)), and leaving out `Before=` does not prevent that. With an unbounded oneshot, `multi-user.target` and everything ordered after it would wait for the whole migration. The timer is the only thing a target pulls in. Nothing is ordered after the service, so boot completes while the migration runs.
   - **Only the timer is enabled.** `pkg.posttrans` / `pkg.postinst` run `systemctl enable ea-podman-migrate.timer` (no `--now`: the package trigger in item 1 already covers the current boot). The service is never enabled on its own. A lint test fails if the service gains an `[Install]` section or if anything gets `After=ea-podman-migrate.service`.
   - **Overlap is harmless.** If the timer fires while a package-triggered run is still going, the global flock (4.2) makes the second run exit with "already running".
   - `TimeoutStartSec=infinity` is safe only because each account's share of the run is bounded (4.2a), so no account can keep the run going forever.
3. **Admin.** `ea-podman migrate_units` can be run at any time to finish, retry or repair.

Logging goes to `/var/log/ea-podman/migrate-units.log` and the journal.

### 4.2 Locking, state and guards

- **One run at a time.** A global flock (`migration/run.lock`) serializes runs. A second run either waits (`--wait`) or exits with "already running" and a status summary.
- **Per-account lock.** `ea_podman::units::with_account_lock($user, $code, %opts)` takes `/opt/cpanel/ea-podman/locks/<user>.lock` (root 0700). It lives in `units.pm`, not `migrate.pm`, so it outlives the migration code. The lock is short, held only by root, and never held across a user child, except by the migration, whose user children are bounded (rule 4, 4.2a). These rules keep nested admin calls from deadlocking:
  1. **Never held while waiting on an `_as_cpuser` child or an admin call.** The `_as_cpuser` child of INSTALL/UPGRADE already calls back into admin (`REGISTER`, `GIVE`, `ENSURE_USER`), and in 2.0 it also calls `UNIT_INSTALL` and `START`. If the parent held the lock across that child, the nested action would wait for its own parent. So INSTALL, UPGRADE, UNINSTALL, BACKUP, RESTORE, CLEAN and CMD take no lock themselves. Only the root-side critical sections take it.
  2. **Who takes it, and around what.** `UNIT_INSTALL`, `UNIT_REMOVE`, `START`/`STOP`/`RESTART`, `RESET_FAILED`, root's `set_slice_properties` and root's direct lifecycle calls each take it around their own root-only `units.pm` work: read the migration state, write or remove the unit, run `systemctl`, poll the verdict. ENSURE_USER, REGISTER/DEREGISTER, GIVE/TAKE and the read-only actions don't take it; they keep their existing locks. The `systemctl` calls in that work start or stop units whose `Exec*` lines run as the account. They are bounded by the units' explicit `TimeoutStartSec`/`TimeoutStopSec` (Phase 1) and by the outer deadline in 4.2a, never by the account's cooperation.
  3. **Admin actions never block indefinitely.** They try `LOCK_NB` and retry for up to 30 s, then fail with "this account's containers are being migrated; try again shortly". If we missed a nesting, it then fails fast instead of hanging an install after its old container was torn down.
  4. **The migration holds it for the whole account.** Its own as-user steps make no lock-taking admin calls. Steps 1, 3, 5, 6, 10 and 11 run only podman and file operations. `op => 'migrate'` (step 6) creates without starting, and skips registration, unit install and START. Root does steps 7 and 8 itself, in-process, under the lock it already holds, by calling `units.pm` directly rather than through admin. `op => 'migrate'` asserts this: any lock-taking admin call made from it dies. Holding the lock for the whole account is only acceptable because every as-user step runs under a root-enforced deadline (4.2a), so the hold has a known upper bound that the account cannot extend.
  5. **Hooks** (`_delete_user`, `remove_containers_for_a_deleted_user`) take it only around their root-side `remove_unit` / `release_runtime` steps. They release it before the as-user removal, whose own `UNIT_REMOVE` then finds nothing to do and takes the lock only briefly. Hooks may wait with no time limit, because nothing that holds the lock ever calls a hook, and every holder is bounded:
     - the migration by the account's budget (4.2a);
     - admin actions by the unit timeouts and the outer `systemctl` alarm (rule 2), and also by the action's own cpsrvd alarm (`_alarm`, 350 s or 1800 s). If that alarm kills the process, the kernel releases its flock.
     
     No admin action runs anything as the account while it holds the lock. That includes `UNIT_INSTALL`'s inspect, which runs before the lock is taken, so these bounds hold.
     
     **Removal during a migration.** The migration budget can be hours for an account with large volumes, and account removal should not block for that long. Before waiting, the hook writes `migration/<user>.abort` (root 0600). The migration checks for it before each step, and also on each runner poll, stopping the current transient unit when it appears. It then marks the account `failed` (reason: account is being removed) and releases the lock. The hook's wait is then bounded by one step's outer alarm.
  6. **Order.** `run.lock` is always taken before an account lock, never after. Nothing that holds an account lock takes `run.lock` or another account's lock.
- **Install vs. migration.** INSTALL/UPGRADE don't hold the lock across their child, so they rely on the migration state instead. On an account that isn't `done` they refuse up front, as the lifecycle actions do. An account with no 1.x containers counts as `done`. Until an account is `done`, the migration is the only writer of its units. Once it is `done`, the migration only cleans up (legacy files, old copies, carveouts) and never touches its units or containers, so it can't race an install. If the probe (step 1) finds a container that already has a 2.0 unit marker, it treats that container as migrated.
- **Operator actions win.** Any root lifecycle action on a container of a not-yet-`done` account (`start`/`stop`/`restart`, `enable`/`disable`) sets that container's `run_state_applied` under the per-account lock. From then on the migration never starts, stops, enables or disables it; the captured `was_*` state is history, not desired state. While a migration of that account is running, the action fails after the 30 s wait (rule 3) and can be retried when the run finishes.
- **State.** `/opt/cpanel/ea-podman/migration/` (root 0700) holds:
  - `<user>.json`: `{status: pending|deferred|done|failed, reason, timeouts, failed_step, in_place, volumes: {name: {copied}}, containers: {name: {was_enabled, was_active, old_cid, anon_volumes, image_staged, legacy_stopped, legacy_unit_saved, old_renamed_to, new_cid, new_created, unit_written, run_state_applied, started, legacy_removed, old_copy_removed, error}}}`. The `was_*` fields are written once, on the first visit, so the original state survives a crash after the stop. `in_place` is set for root's account only (4.4); `old_renamed_to` and `legacy_unit_saved` are only used by that branch.
  - Every state change is written to a tmp file, fsynced and renamed before the next step acts on it. `volumes.<name>.copied` and `run_state_applied` in particular are commit points: once set, nothing re-copies that volume or replays that container's `was_*` state.
  - `complete`, written only after the global cleanup.
- **Reality first.** Every step checks the actual state before acting: the unit marker, whether the legacy file exists, `is-enabled`, `is-active`, and `podman inspect`. It never trusts the JSON alone.
- **Registry-restore guard.** The merge-failure branch of `pkg.postinst` (`:16-27`) touches `migration/registry-restore-failed`. While that flag exists, the verb changes nothing and logs the recovery steps. An empty registry must never read as "none of these units are ours".

### 4.2a Deadlines for as-user steps

**Why.** The migration holds `run.lock` and the account lock while it runs processes as the account: steps 1, 3, 4, 5, 6, 10 and 11, and root's in-place steps 1, 2, 4 and 6. The account owns those processes. It can SIGSTOP or ptrace them, keep a podman storage lock held, or leave its own user manager hung so that a `systemctl --user` call never returns (steps 1, 4 and 10). A hung runtime or slow storage has the same effect. Without a deadline, one account could hold `run.lock` forever, so no other account migrates and every retry waits or exits "already running". It could also hold its own account lock forever, so its deletion hook (rule 5) never finishes. This denial of service is new in 2.0: 1.x has no migration lock.

**One runner.** Every as-user command in `migrate.pm` goes through `ea_podman::migrate::run_as_user_bounded($user, $step, $timeout, @argv)`. That is a thin wrapper over `units::run_as_user_in_slice` (Phase 1). It uses the `eapodman-migrate-` unit prefix, the step as the label, and the pinned old-storage env where a step needs it. `migrate.pm` has no other way to run anything as the user: no `do_as_user`, `_as_cpuser`, `system`, backticks or `fork`. A lint test enforces this.

**Mechanism: a transient system unit, killed by cgroup.** The runner runs:

```
systemd-run --uid=<uid> --gid=<gid> --unit=eapodman-migrate-<uid>-<step>-<seq> \
  --slice=eapodman-<uid>.slice --pipe --wait --collect --quiet \
  -p RuntimeMaxSec=<timeout> -p TimeoutStopSec=10 -p KillMode=control-group \
  [-p PAMName=ea-podman, per P0-6] \
  -p WorkingDirectory=<home> \
  [--setenv=... from podman_env or the pinned old-storage env] -- <argv> \
  </dev/null 2>stderr-pipe >stdout-pipe
```

- The argv is built by `migrate.pm` from fixed command words plus values validated by the same rules as Phase 1 (container names, CIDs, volume names). No `-p` value comes from the account or the registry.
- **The account never gets root's terminal (F10).** `--pipe` hands `systemd-run`'s own fds 0–2 to the transient unit. So the runner always starts `systemd-run` with stdin from `/dev/null` and stdout/stderr on pipes it creates, never inherited, even when `migrate_units` runs in an interactive root shell. The plugin's build `systemd-run --pipe` (Phase 6) follows the same rule. The same test that checks `/proc/<pid>/fd` for lock files also checks that fds 0–2 of a runner child are not a TTY and are not any fd that the migration process itself holds.
- **The old-storage env is pinned too.** Steps against 1.x storage use `old-containers.conf` / `old-storage.conf` (Phase 1), never the account's own `~/.config/containers`. Without this, every repair run on a `done` account (step 11) would start the account's own configured runtime and hooks from a PID-1 unit outside the cage.
- **Why not fork, setuid, setsid and alarm:** the account can call `setsid` or double-fork out of a process group, and a ptrace-stopped tree isn't reliably reaped by a process-group kill. systemd kills every process in the unit's cgroup with SIGKILL, stopped or not.
- **No lock descriptor reaches the account.** The unit is spawned by PID 1, so it inherits nothing from the migration process. Both lock files are also opened close-on-exec (Perl's default for descriptors above `$^F`). A test checks `/proc/<pid>/fd` of a runner child for the lock paths.
- **Escape doesn't matter for the deadline.** On cgroup v1 the account may be able to move a process into its own delegated cgroup (P0-11). That process then keeps running as the account, which the account could do anyway, but `systemd-run --wait` returns when the unit stops, so the migration is no longer waiting on it. The deadline guarantees that the migration moves on, not that every account process dies.
- **Captured output is capped** (1 MB per stream; the rest is drained and discarded), so a flood of output can't exhaust root's memory.
- **Outer deadline.** The runner also puts an alarm on `systemd-run` itself, at `timeout + TimeoutStopSec + 30 s`, for a kill that doesn't take (for example a process stuck in uninterruptible I/O). On that alarm it runs `systemctl kill --signal=SIGKILL` on the unit, abandons it, and fails the account. Unit names are unique per call, so an abandoned unit never collides with a later one. A later run refuses to start any step for an account while one of its runner units still exists, matched by the strict regex `^eapodman-migrate-(\d+)-([a-z0-9_]+)-(\d+)\.service$` with the account's uid as the first group, never a glob. Container units are `ea-podman-<name>.service` and always contain dots (Phase 1, name namespace), so no container name can match it. Without that regex, a container named `migrate-1003-x` would fail uid 1003's migration for good. While such a unit exists, the run marks the account `failed` (reason: a previous migration step is still running). The same outer alarm wraps every root-side `systemctl` call that runs under the account lock (steps 7, 8 and 12, and the admin actions in rule 2).

**Deadlines** come from the root-owned `migrate.conf`:

| Step | Deadline |
|---|---|
| Probe, stop, recreate, legacy-file removal, old-copy removal, each `systemctl --user` call | `step_timeout_sec` (default 600) |
| `podman stop -t 30` | `step_timeout_sec + 30` |
| Image `save`/`load` and volume `export`/`import` | `step_timeout_sec + size_mb / copy_min_mb_per_sec` (default 5 MB/s), per image or volume, from the sizes measured in step 2 |

- An admin run can override `step_timeout_sec` with `--step-timeout SEC`. `--step-timeout` is refused with `--auto`, so unattended runs always use the config.
- At the start of each account, the run computes the account's total budget (the sum of its step deadlines) and logs it ("holding <user>'s lock for at most N s"). That number is the longest any hook or admin action for that account can wait.

**On a timeout:**
- The runner reports the timeout separately from a non-zero exit (from the unit's `Result`, per P0-11).
- The account is marked `failed` with reason `timed out after N s in step S (<what>)`. The state gets `timeouts` (a counter) and `failed_step`. The write goes through the usual tmp, fsync and rename before the run moves on.
- The account lock is released and the run continues with the next account. `run.lock` is held only for the bounded sum of the per-account budgets.
- A timeout is handled like a SIGKILL mid-step, and the steps are already ordered to survive that (4.3, and the kill case in 4.7). For example, a killed import leaves a partial new volume, which step 5 removes on the next run, and a killed `podman stop` is caught by step 4's verify.
- **Repeat timeouts.** After 3 consecutive timeouts, `--auto` runs skip the account (reason: `timed out 3 times in step S; run ea-podman migrate_units --user U`), so package updates and boots don't pay its budget every time. An admin run without `--auto` still tries it and resets the counter on success. Like any `failed` account, its 1.x session was already released at the end of its first failed turn (4.3 step 12), and it appears in the 4.8 warning.

### 4.3 Per account (`users_with_containers_as_root`, `util.pm:2768`)

Registry users with no passwd entry go through the deleted-user cleanup instead.

The steps are safe-ordered so a crash at any point leaves something a re-run can finish:
- Everything that can be copied while the old containers run (images) is staged first, to keep the downtime short.
- Only **named** volumes are copied. Anonymous volumes are left in old storage, exactly as a 1.x `ea-podman upgrade` already leaves them (4.4).
- Named volumes are copied only after **every writer** has stopped. A volume copied while its container runs can be an inconsistent snapshot (a database mid-write), and anything written after the export would be silently lost at cutover.
- The old containers, their volumes and the legacy files stay in place until the new ones are verified, so the data is never in only one half-built place.

The account's containers are down from step 4 to step 8. That window is mostly the volume copy time; the release notes say so.

Every "as the user" step below runs through the bounded runner (4.2a). None of them forks or setuids directly.

1. **Probe.**
   - **Manager up:** root sees `user@<uid>` active and `/run/user/<uid>/systemd/private` exists. Read `systemctl --user show container-<name>` and `podman inspect` as the user. Record `was_enabled`, `was_active`, the old CID, and the named-volume mounts.
   - **Named vs anonymous.** A volume mount is *named* only if `podman volume inspect` in old storage reports `Anonymous: false`. Anonymous volumes (from an image `VOLUME` the start args don't mount, or a `-v` with no source) are recorded separately as `anon_volumes: [{name, destination}]` on the container. They are never copied, never counted by the pre-checks, and never written to.
   - **Manager down:** a masked host after a reboot. `was_enabled` comes from an lstat of the `default.target.wants` link, done as the user. `was_active` is false.
   - **Volume writers.** For each named volume a registered container mounts, list every container in old storage that mounts it (`podman ps -a --filter volume=<name>`). If a container that is **not** a registered ea-podman container uses it, mark the account `failed` (reason: shared volume `<name>` is used by unmanaged container `<c>`) and change nothing, apart from the session release in step 12 on masked hosts. By default the migration never stops or copies out from under the user's own containers.
     - No migration order can keep that sharing working: after 2.0 the ea-podman container uses a copy in the new storage, and the user's container keeps the old volume. Someone has to decide.
     - **Admin override:** `migrate_units --user U --stop-unmanaged` stops (never removes) those unmanaged containers as the user, then continues. The output and the log name each stopped container and say that it keeps using the old volume, so its data and the ea-podman container's data diverge from then on. It is never the default, and it is refused with `--all` and `--auto`.
2. **Pre-checks.** Both use the named-volume sizes from `podman system df -v` in old storage; anonymous volumes are not counted.
   - **Quota.** Check headroom for the copied images **and** volumes, **plus** the largest single archive in transit (step 3 and step 5 archives exist one at a time, alongside both the old and new copies). If there isn't enough, mark the account `failed` (reason: quota) and change nothing except the session release in step 12.
   - **Size limit, `--auto` runs on hosts where `user@.service` is not masked.** If the account's named volumes total more than `auto_volume_limit_mb` (root-owned `/opt/cpanel/ea-podman/etc/migrate.conf`, default 2048), mark it `deferred` (reason: `N` MB of volumes; run `ea-podman migrate_units --user U` at a convenient time) and change nothing. The account's containers would be down for the whole copy, and an unattended update must not pick that moment. An admin run without `--auto` ignores the limit; `auto_volume_limit_mb = 0` turns it off.
     - **On masked hosts there is no deferral.** There, an unmigrated account keeps only what ea-podman's carveout gives it, so its 1.x session must be released this run (step 12), and that stops its old containers anyway. Migrating now ends that downtime after the copy; deferring would leave the account down until an admin acts. A hostile account could also use deferral (more than 2 GB of volumes) to keep its per-user manager.
3. **Stage images in fresh storage, as the user, with the old containers still running.** This uses `~/.local/share/ea-podman/storage` through `podman_env`. The old storage is only read, never written.
   - `podman save --output <staging>/<image-id>.tar` the old image by ID, then `podman load --input` that file into the new storage, then remove the file. Set `image_staged`.
   - **Archives never pass through the runner's stdout,** which is capped at 1 MB (4.2a). `<staging>` is `~/.local/share/ea-podman/migrate-staging/`, created by the user with mode 0700 and counted by the quota pre-check. It is never `/tmp`, the runtime dir (a capped tmpfs, F8) or anywhere outside home. A leftover archive from an interrupted run is removed before the step repeats.
4. **Stop the old containers, as the user.** Every registered container in the account, not only the ones that share a volume, so the account switches as a unit.
   - Manager up: `systemctl --user disable --now container-<name>.service`. The old container is stopped, not removed.
   - Then, in either mode, `podman stop --ignore -t 30` against the old storage, and verify with `podman inspect` that it is not running. If any is still running, mark the account `failed` and stop here; nothing has been copied yet.
   - Set `legacy_stopped`.
5. **Copy named volumes, as the user, with every writer stopped.** For each volume without `copied`:
   - If the new volume already exists in new storage, it is a leftover of an interrupted copy (no new container can have used it, because nothing starts before step 8). Remove it.
   - Immediately before the export, re-check that no container mounting the volume is running. If one is, mark the account `failed` and stop.
   - `podman volume create <name>` in new storage. `podman volume import` does not create its destination, so a volume must exist before anything is imported into it.
   - `podman volume export --output <staging>/<name>.tar` from old storage, then `podman volume import <name> <staging>/<name>.tar` into the volume just created, then remove the archive. The archive goes through `<staging>` as in step 3, never through stdout.
   - Check the result of each command (create, export, import). If any fails, mark the account `failed` with the step and the command's error, and leave `copied` unset. The next run then finds the partial volume, removes it (first bullet) and copies again.
   - Set `volumes.<name>.copied` only after the create and the import have both succeeded.
   - A volume with `copied` set is never exported, imported or removed again by any later run.
6. **Recreate, as the user:** `_ensure_latest_container` with a new `op => 'migrate'`. That is the upgrade path with no pull, the image pinned by ID (as in `_rollback_failed_upgrade`, `util.pm:1700`), ports from `_get_current_ports`, the registry untouched, and the `webapp` flag kept. The new containers are **created but not started**. Their named volumes already exist from step 5, so podman doesn't create empty ones or copy image content into them. Anonymous volumes are **not** carried over: podman creates new, empty ones (seeded from the image), the same as on every 1.x upgrade.
7. **Write units, as root.** `write_unit` for each container, **not enabled and not started**.
8. **Switch, as root.** Only for containers whose `run_state_applied` is not set:
   - `enable` if `was_enabled`.
   - Start if `was_active`, or if the manager was down and `was_enabled` (that is what the 1.x boot sweep would have done).
   - Check the verdict. On success, set `started` and `run_state_applied`.
   - `--no-start` webapps come out enabled but inactive, which matches 1.x; set `run_state_applied`.
9. **On a failed start,** mark the account `failed` with the error, and leave the new units enabled and the old files in place. That container stays down until a re-run succeeds; each run retries the start while `run_state_applied` is unset and the account is not `done`. There is no rollback to 1.x, because the 1.x code is gone.
10. **Remove legacy files, as the user only** (root never writes into a home directory). This happens only after every container in the account is verified.
    - Remove `~/.config/systemd/user/container-<registered name>.service` only if it is a regular file (lstat) and its `ExecStart` names that container. Remove its `default.target.wants` symlink.
    - Run `daemon-reload` if the manager is up.
    - Touch nothing else in that directory.
11. **Remove old copies, as the user.** `podman rm` only the old copies of the registered containers, by their recorded old IDs, in old storage. **Never prune** images or volumes there by default.
    - **CID guard (all accounts, every run, including repair).** Before removing an old copy, check that its old CID is not the `new_cid` in the state, not the `{CID}` in any ea-podman unit marker, and not the CID of the container currently holding the registered name. If any match, skip it, log it, and set nothing. Use `podman rm` without `-f`, so a copy someone started is refused, not killed; log it and retry on the next run.
    - Log how much space is reclaimable.
    - Log, and print in the account's `migrate_units` output, each anonymous volume left behind: its container, destination path, old volume name and size. The data stays in old storage and can be copied into the new container by hand.
    - `--prune-old` removes images in old storage that no remaining container references. That clears the doubled disk use.
12. **Release the 1.x session, as root** (`ea_podman::migrate`).
    - Release linger only if ea-podman granted it and the grant still covers the current linger.
    - Remove ea-podman's digest-vouched carveout.
    - If `user@<uid>` is running only because of our carveout, stop it first.
    - Never unmask anything.
    - **When it runs.** Always at the end of a migrated account's turn. On a host where `user@.service` is masked, it also runs at the end of **every** account's turn, whatever the outcome: `failed` at any step (pre-checks included), timed out, or skipped after repeated timeouts. On those hosts the carveout is the only thing giving the account a per-user manager. Without this, an account could keep the CLOS-7971 exposure just by staying `failed`, for example with a raw-podman container that shares a volume name, or by stalling its runner three times.
    - The release stops `user@<uid>`, and with it any old containers still running. On a masked host they would stop at the next reboot anyway, and the state and log say so. It runs as root, in-process, under the outer `systemctl` alarm (4.2a), so a timed-out account still gets it.
    - On unmasked hosts every account can run a per-user manager anyway, so a `failed` account keeps its 1.x setup and its containers keep running until it migrates.
13. **Mark the account `done`.**

**Repair on every run, for `failed` accounts on masked hosts:** step 12 is re-applied, so a session that is somehow back is released again.

**Repair on every run, for `done` accounts:** cleanup only. It removes any remaining legacy files, old copies (under the step 11 CID guard), carveouts and ea-podman-granted lingers. It **never** starts, stops, enables or disables a unit, and never copies a volume. Once an account is `done`, its run state belongs to the admin and the account, and a later package update must not undo a deliberate stop.

### 4.4 Special cases

- **Root's own containers: an in-place branch, not the same steps.** The pinned `storage.conf` only changes `rootless_storage_path`, so root's old and new storage are the same `/var/lib/containers/storage` (runroot under `/run/containers`). Steps 3, 5, 6 and 11 assume two stores and must not run as written: there is nothing to stage, a volume export/import would copy onto itself, a recreate would collide with the retained old container's name, and step 11 could remove the CID the new unit now runs. Root's account gets `in_place: true` and these steps instead:
  1. **Probe** as in step 1, against `user@0` and `/root/.config/systemd/user`. No writer check, quota check or size limit: no volume moves, so sharing with root's own unmanaged containers keeps working.
  2. **Stop** as in step 4. Then, still in this step, **retire the legacy unit before any system unit exists.** 1.x units come from `podman generate systemd --name` (`util.pm:976`), so they address the container by name, in the same storage the new unit uses. If both existed, two managers could control one container, or a later `systemctl --user start` would start the new one. Copy the legacy file into `migration/root-legacy/` (root 0600) for manual rollback, set `legacy_unit_saved`, remove the file and its wants link, and `daemon-reload` root's user manager. (This is root's own home; the "root never writes into home" rule is about account homes.)
  3. **Volumes:** none are copied. Named volumes stay where they are and are reattached by name. Set nothing under `volumes`.
  4. **Recreate only if P0-2 says so.**
     - **No recreate:** `new_cid = old_cid`. The unit is written for the existing container. No old copy exists, so step 11 has nothing to do for it (the CID guard enforces this even if the state is wrong).
     - **Recreate:** `podman rename <name> <name>.ea-podman-1x` (set `old_renamed_to`; the CID and volume mounts are unchanged, per P0-2), then `_ensure_latest_container` with `op => 'migrate'` creates the new container under the original name, created but not started, with the same named volumes. Record `new_cid`. Anonymous volumes behave as on any 1.x upgrade.
  5. **Write the unit and switch** as in steps 7 to 9, with the rootful variant.
  6. **Remove the old copy** only in the recreate case, only after the new container is verified, by `old_cid`, under the step 11 CID guard. `--prune-old` is refused for root's account: its "old storage" is its live storage.
  7. **Release:** root's linger is never released; `user@0` carveouts are handled as in step 12.
  - **Resume.** A re-run reads reality first: a container named `<name>.ea-podman-1x` with `old_cid` and none named `<name>` means "renamed, not yet recreated"; both present means "recreated", and the new one's CID becomes `new_cid`.
  - **Manual rollback of a `failed` root account** (documented in the recovery doc): `podman rm <new_cid>`, `podman rename <name>.ea-podman-1x <name>`, restore the saved legacy unit, remove the system unit.
- **Unregistered containers, legacy units, or `~/ea-podman.d` dirs.** These are never adopted and never deleted. They are reported as "unmanaged" in `--status`.
- **Raw (non-ea-podman) podman data.** The user's own containers, images and volumes in `~/.local/share/containers` are kept. Only the old copies of the registered ea-podman containers are removed. The release notes say:
  - the user's own `~/.config/systemd/user` units keep running only if *they* linger;
  - on CageFS-masked hosts those units never ran anyway.
- **Anonymous volumes are not migrated.** They come from an image `VOLUME` that the start args don't mount, or from a `-v` with no source. ea-podman treats them as disposable: any recreate replaces them with new, empty ones. A container whose anonymous volume holds data worth keeping is an oversight in how it is mounted, and gets fixed separately, not by the migration. ea-podman 1.x never preserved them either: `podman rm` without `-v` (`util.pm:445`) strands the old one, and the recreated container gets a new, empty one.
  - The old volumes stay in old storage (step 11 never prunes volumes), and each one is listed (step 11) so it can be recovered by hand.
  - Known packaged oversight: `ea-redis62` doesn't mount the image's `VOLUME /data`, so its `dump.rdb` lives in an anonymous volume. The fix is a separate packaging change that mounts every path a packaged image declares as `VOLUME` (a named or bind mount, or `--tmpfs` when the data is disposable). It should ship before or with 2.0, so packaged containers have no anonymous volumes holding data.
  - Arbitrary images that need their data kept must mount those paths explicitly; the release notes say so.
- **Reboot mid-migration.** Migrated accounts come up through their system units. Unmigrated accounts stay down until `ea-podman-migrate.service` (started by its timer about a minute after boot) finishes them.
- **What `failed` and `deferred` accounts keep.**
  - **Masked hosts:** nothing. Step 12 releases every account's session at the end of its turn, whatever the outcome, and there is no deferral. So no account keeps ea-podman's linger or carveout, or the CLOS-7971 exposure, past the run that first visits it. A `failed` account's containers are down until it migrates, which is also what a reboot would do, because 2.0 has no boot sweep.
  - **Unmasked hosts:** `failed` and `deferred` accounts keep the 1.x setup, and their containers keep running, until they are migrated. That keeps no exposure the host doesn't already give every account.
  - The warning in 4.8 names each of these accounts with its reason, and the release notes say so.
- **The account restarts an old container mid-migration.** After step 4 the old units are disabled, but an unrestricted-shell account can still `podman start` an old container in old storage. Step 5 re-checks that no writer is running immediately before each export, and fails the account if one is. After the volume is `copied`, writes to the old copy are not carried over; the release notes say the old containers must not be started by hand once migration begins.

### 4.5 Global cleanup

This runs only when every account is `done` and the restore flag is absent.

1. Sweep the remaining ea-podman carveouts, including those of deleted users.
2. If `user-manager-mask.state` exists, put the CageFS mask back (`_restore_abandoned_unmask_window`). Remove the mask lock and state files.
3. Clean `/run/ea-podman/{lock,written,reload-pending}`. Leave `/run/ea-podman/user/` alone.
4. Remove the dangling `multi-user.target.wants/ea-podman-user-managers.service` link if it is still there. 2.0 no longer ships that unit.
5. Run `daemon-reload`, then write `migration/complete`.

### 4.6 Packaging

- **Version:** `ea-podman-2.0-1`.
- **Web Apps plugin in lockstep.** ea-podman gets `Conflicts: cpanel-webapp-plugin < <matching version>`, and the plugin gets `Requires: ea-podman >= 2.0`. Ubuntu gets the debify equivalents. No shims: there is no `sysctl()` or `ensure_user_session` shim and no `record_linger_grant` no-op.
- **What ships and what doesn't:**
  - ships the new `ea-podman-migrate.timer` and `ea-podman-migrate.service`, `units.pm`, `migrate.pm`, the anchor unit, `eapodman.slice`, the `runtime-mount` helper (root:root 0755), `runtime.conf`, and the pinned confs (including the old-storage pair);
  - no longer ships `ea-podman-user-managers.service`;
  - the old package's `%preun` / `prerm` disables that service during the upgrade.
- **Mirrors.** After the release, remove 1.x from the RPM and Ubuntu repos. Check that no EA4 profiles or automation pin `ea-podman-1.*`.
- **Downgrade is unsupported.** That is one line in the release notes; no `prerm` detection.

### 4.7 Migration tests

**Unit test: `t/SOURCES-migrate-units.t`.**

The fixtures use package variables that already exist: a temp HOME, a scratch `$known_containers_file`, carveout, linger and grant dirs, a fake `/etc/systemd/system`, and code-ref seams for systemctl and podman.

Cases:
- **Manager up:** active+enabled; inactive+enabled (a `--no-start` webapp); disabled; failed.
- **Manager down:** enabled; disabled.
- **Other owners:** root's containers; a deleted user; a registry entry whose container is missing.
- **Left alone:** an unregistered legacy unit, a personal unit, the canary unit, and raw-podman data are all untouched.
- **Symlink attacks:** on the unit file, on the wants dir, and on `~/.config/systemd/user` pointing at `/etc`.
- **Linger:** ours and current (released); ours but a newer marker (kept); not ours (kept).
- **Carveout:** ours (removed); an admin's (kept).
- **Mask:** a state file present means the mask is put back.
- **Restore flag:** it blocks everything.
- **Locking:**
  - a second concurrent run waits or exits;
  - **real nested calls, not mocked locks:** an admin dispatcher seam runs nested `Cpanel::AdminBin::Call` requests in-process with real flocks on a temp lock dir. INSTALL and UPGRADE, whose child calls REGISTER, ENSURE_USER, UNIT_INSTALL and START, complete within the test timeout;
  - START, STOP and UNIT_INSTALL on an account whose lock is held fail after the bounded wait with the "being migrated" message, and never hang;
  - a lock-taking admin call made from inside `op => 'migrate'` dies;
  - the hooks release the lock before the as-user removal, and a delete-user hook that runs while a migration holds the lock finishes after the migration does;
  - lock ordering: a seam records acquisition order and shows that no path takes `run.lock` while it holds an account lock.
- **Deadlines (4.2a):**
  - a runner seam whose child never returns, for each as-user step: the account ends `failed` with the timeout reason, `timeouts` and `failed_step` set, and the account lock released; the next account in the same run migrates;
  - a delete-user hook waiting on a timed-out account's lock finishes within that account's logged budget;
  - after a timeout in each step, a re-run converges (same as the die-after-each-step case);
  - three consecutive timeouts make `--auto` skip the account; an admin run still tries it and resets the counter on success;
  - a leftover `eapodman-migrate-<uid>-<step>-<seq>` unit makes a re-run refuse that account and fail it with the "still running" reason;
  - a container unit named `ea-podman-migrate-1003-x.bob.01.service` (another account's container) does **not** block uid 1003's migration;
  - the deadline table, `--step-timeout`, and the refusal of `--step-timeout` with `--auto`;
  - output over the cap is truncated, not buffered;
  - lint: `migrate.pm` runs nothing as the user except through `run_as_user_bounded`;
  - no runner child has a lock file open (`/proc/<pid>/fd`);
  - **no runner child gets root's terminal:** run `migrate_units` under a pseudo-terminal; the runner child's fds 0–2 are `/dev/null` or pipes, never a TTY, and opening `/proc/<child>/fd/0` as the account gives no terminal;
  - an archive never passes through stdout: `save`/`export` write to `<staging>`, and a volume larger than the 1 MB output cap copies intact;
  - steps against old storage run with the pinned old-storage env: a hostile `~/.config/containers/containers.conf` in the account (`runtime=`, `hooks_dir`) never executes during probe, stop, export or old-copy removal, including on repair runs of a `done` account;
  - **removal during a migration:** the abort file makes the run fail that account at the next step boundary (or stop the current runner unit), and the hook finishes within one step's outer alarm.
- **Volumes:**
  - the export never runs while any container mounting the volume is running (the seam records order);
  - a volume shared by two registered containers is copied once, after both stop;
  - a volume shared with an unmanaged container fails the account and touches nothing;
  - the destination volume is created before the import, in fresh storage that holds no volumes;
  - a failed `volume create`, `export` or `import` fails the account with `copied` unset, and the re-run removes the partial volume, creates it again and re-imports;
  - a die between `import` and setting `copied` makes the re-run remove and re-import it; a die after `copied` never re-imports it;
  - an anonymous volume (image `VOLUME` and bare `-v /path`) is not exported, not counted by the quota or size-limit checks, is left untouched in old storage, and is listed in the output and log.
- **Shared volume override:**
  - `--stop-unmanaged` with `--user` stops (never removes) the unmanaged container, migrates the account, and logs the divergence;
  - `--stop-unmanaged` with `--all` or `--auto` is refused.
- **Size limit:**
  - an `--auto` run defers an account over `auto_volume_limit_mb` and changes nothing; an account under it migrates;
  - an admin run without `--auto` migrates the deferred account;
  - `auto_volume_limit_mb = 0` disables the limit;
  - on a masked host an `--auto` run never defers, and migrates an account over the limit;
  - global cleanup and `complete` wait for deferred accounts.
- **Session release on masked hosts:**
  - an account that fails at each point (shared-volume probe, quota, any step, a timeout, the 3-timeout skip) ends the run with no ea-podman linger, no carveout and no `user@<uid>`; the canary unit does not run;
  - on an unmasked host the same failures keep the 1.x session and the old containers running.
- **Run state:**
  - migrate an active container, root stops it, then a package-triggered run: it stays stopped;
  - root stops a container of a `failed` account, then a re-run: it stays stopped, while its siblings still get their start retried;
  - a `done` account whose unit is inactive: a re-run starts nothing.
- **Root's in-place branch,** each for both P0-2 outcomes (no recreate, recreate) and for a running and a stopped container:
  - no volume is exported or imported, and the quota and size-limit checks are skipped;
  - the legacy unit is saved and removed before the system unit is written;
  - no recreate: the unit carries `old_cid`, and no run (including repeated repair runs) removes that container, whether it is running or deliberately stopped;
  - recreate: the old container is renamed, the new one keeps the original name and the same named volumes (a marker file written before migration is visible), and the renamed copy is removed only after verification;
  - a die after the rename, after the create, and after the unit write each converges on re-run;
  - `--prune-old` is refused for root;
  - the CID guard: a state file whose `old_cid` equals the unit's `{CID}` never leads to a `podman rm`, and a running old copy is refused, not killed.
- **Failure and resume:**
  - a failed start leaves the account `failed` with the old files intact, and a re-run succeeds;
  - a die injected after each step, followed by a re-run, converges;
  - a second run after completion makes no changes;
  - global cleanup happens only when every account is done.

**Scriptlet tests.** Extend `t/SOURCES-pkg-scriptlets-hooks.t`:
- posttrans and the apt postinst branch only start the transient unit and always exit 0;
- postinst writes the restore-failed flag;
- `ea-podman-migrate.service` has the `complete` condition and no `[Install]` section;
- `ea-podman-migrate.timer` has `OnBootSec` and `WantedBy=timers.target`, and the scriptlets enable the timer (not the service) without `--now`;
- the spec and debify `ea-podman.install` stay in sync.

**Live test: `t/LiveTests/system-units-migration-live.t`.**
- **Upgrades:** from 1.0-32, 1.0-34 and 1.0-37 (from the internal archive) to 2.0, on EL9, CL9 with CageFS masked, EL8 (cgroup v1) and Ubuntu 24.04.
- **Fixtures:**
  - one container running, with a marker file in `~/ea-podman.d`;
  - one stopped;
  - one `--no-start` webapp;
  - one jailshell account;
  - root's own containers: one running and one stopped, each with a named volume holding a marker file (run once per P0-2 outcome, if both outcomes occur across the matrix);
  - an account with a personal unit, the canary and a raw-podman container;
  - an unregistered legacy unit;
  - an offline account on the masked host.
- **Run:** upgrade with `dnf`/`apt` (it returns promptly), then `migrate_units --wait`. A writer container appends a counter to a file in a named volume (and a database container takes inserts) throughout the migration.
- **Assert:**
  - state, ports and data are preserved; the last counter value and row written before the stop are present in the new volume, and the database passes its own consistency check;
  - units are root:root 0644;
  - the legacy `container-*` files are gone, while the personal unit, the unregistered unit and the raw-podman data remain;
  - only ea-podman's carveouts and lingers are gone, and the mask is intact;
  - `complete` exists and `ea-podman-migrate.service` is condition-skipped.
- **Interruptions:**
  - reboot mid-migration, and the boot timer's run finishes it;
  - **Boot is not held up:** with a migration runner stalled (an account whose volume export is SIGSTOPped), reboot. `multi-user.target` and a test service ordered `After=multi-user.target` become active while `ea-podman-migrate.service` is still `activating`, and `systemctl list-dependencies --after multi-user.target` does not list the migrate service;
  - SIGKILL a run midway, then re-run, and it converges;
  - **Volume copy, real podman, on every OS in the matrix:** an account with a populated named volume migrates into fresh storage that holds no volumes (create, then import). Separately, SIGKILL the runner during `podman volume import`. The account is left `failed` with `copied` unset, the re-run converges, and the new volume's `tar -tv` listing matches the old export's;
  - an admin run concurrent with the background run waits or exits cleanly;
  - during a long volume copy for one account: `ea-podman install` by another account succeeds, and `ea-podman start` by the account being migrated fails fast with the "being migrated" message;
  - account removal during that account's migration completes after the migration and leaves no unit.
  - **Hostile stall:** while account A's volume export runs, A SIGSTOPs (and, separately, ptrace-attaches to) its runner process and starts a `setsid` grandchild that sleeps. A is marked `failed` (timed out) within its logged budget, account B migrates in the same run, removing A finishes within that budget and leaves no unit, and a re-run of A (after the stop is lifted) converges with the volume data intact.
  - **Stalled `ExecStart`:** a container whose `ExecStart` is stopped during root's step 8 start. The start fails at the unit's `TimeoutStartSec`, and the account lock is released.
  - **Hostile account on the masked host:** an account that makes itself fail (a raw-podman container sharing a volume name) ends the run with no `user@<uid>`, and the canary never runs, before and after a reboot.
  - **Terminal handoff:** run `migrate_units --user A` from a real root SSH session; while A's export runs, A opens `/proc/<pid>/fd/0` of every process it owns and tries TIOCSTI. No keystroke reaches root's shell.
- **After:** a reboot brings the containers back and the canary never runs.
- **Operator stop survives updates:** stop a migrated container as root, reinstall the same 2.0 package (which re-triggers `migrate_units`), reboot: it stays stopped.

### 4.8 Removal window for `migrate_units`

**When.** Not before **release date + 6 months**. The date is fixed at release and published as `YYYY-MM-DD` in three places: the release notes, `migrate_units --help`, and the verb's output.
- With weekly releases and automatic updates, nearly every server migrates within days, because the upgrade trigger and the boot trigger run on their own.
- The deadline only matters for two kinds of server:
  - servers that didn't update at all during the window (updates off, EA4 pinned, dormant). With 1.x gone from the mirrors, their next update jumps straight to the current 2.x;
  - accounts that stayed `failed` the whole time.
- Before deleting, check update-adoption telemetry if it exists (how many servers still report ea-podman 1.x). The date means "not before", not "exactly on".
- **Backup restores are not affected.** Restore recreates containers from the `ea-podman.d` tarball or manifest through the normal 2.x install path, so a 1.x backup restores onto 2.x without `migrate_units`.

**Warning, while the tool exists.** Whenever any account is `pending`, `deferred` or `failed`, every run prints:

> `N account(s) are not migrated to ea-podman 2.0 (see --status). On this host their containers <are down until they are migrated | still run under the old per-user systemd manager until they are migrated>. This migration tool will be removed on or after YYYY-MM-DD. After that, their old containers must be removed and recreated by hand (see <doc link>).`

followed by one line per account with its status and reason, for example:

```
  bob: failed (shared volume "data" is used by unmanaged container "mydb";
    resolve it, or run: ea-podman migrate_units --user bob --stop-unmanaged)
  carol: deferred (5120 MB of volumes; run: ea-podman migrate_units --user carol)
```

It is printed by all three triggers, so it reaches the package log, the journal, and admins running the verb by hand. A fully migrated server never sees it.

**After removal: a small detector, not the migrator.**
- It lives in `pkg.postinst`, and in the CLI when run as root. It contains no 1.x logic.
- It fires when there are registered containers, `migration/complete` is missing, and legacy `~/.config/systemd/user/container-*.service` files exist (or `/run/systemd/system/user@*.service` carveouts).
- It prints the same "migrate by hand" message with the doc link. A server that missed the window then gets an actionable message instead of containers that silently don't start.
- **The removal release also drops the "not migrated yet" gate** on INSTALL/UPGRADE and the lifecycle actions (4.2), and ignores leftover `migration/<user>.json` files. Otherwise the manual steps below would be refused.

**Manual recovery doc.** Write it with 2.0, while the details are fresh. The order matters: named-volume data must be in the new storage before anything is recreated, because a named volume that doesn't exist there is created empty and the container starts against it. Per affected account:
1. **Inventory, as the user, against the old storage** (plain `podman`, no ea-podman environment):
   - each container's install arguments from `~/ea-podman.d/<container>/ea-podman.json`, and its CID;
   - each container's named-volume mounts: the mounts from `podman inspect`, keeping those whose `podman volume inspect` reports `Anonymous: false`;
   - for each of those volumes, every container that mounts it (`podman ps -a --filter volume=<name>`). If one is not an ea-podman container, decide first, as `--stop-unmanaged` does: after recovery the two use different copies.
2. **Stop every writer and retire the legacy units, without removing containers.** As the user: `podman stop` every container from step 1 (ea-podman's and any unmanaged sharer), then remove `~/.config/systemd/user/container-*.service` and their `default.target.wants` links, so nothing restarts them. Check with `podman ps` that none of them is running.
3. **Release the 1.x session, as root:**
   - remove `/run/systemd/system/user@<uid>.service`;
   - if `/opt/cpanel/ea-podman/granted-linger/<user>` exists, run `loginctl disable-linger <user>` and remove the record;
   - remove the account's `/var/lib/systemd/linger` entry only if ea-podman granted it.
4. **Transfer each named volume into ea-podman's storage** (exact commands in the doc; they run as the user with ea-podman's pinned `CONTAINERS_*` and `XDG_RUNTIME_DIR`, after `systemctl start ea-podman-runtime@<uid>` as root):
   - `podman volume export <name>` from the old storage to a file only the user can read;
   - in the new storage, fail if the volume already exists and holds data; otherwise `podman volume create <name>` and `podman volume import <name> <file>`;
   - **verify:** export the new volume and compare its `tar -tv` listing (paths and sizes) with the old export. Stop on any difference.
5. **Recreate** each container with `ea-podman install` (or `upgrade`) using the recorded arguments. Its named volumes already exist in the new storage, so it attaches to the transferred data. Ports and registry entries are re-established by the normal 2.x path.
6. **Validate** each application (for a database, its own consistency check and a known recent row). The old containers and volumes are still in old storage, stopped; do not start them, because writes there are not carried over.
7. **Only after validation,** as the user: `podman rm` the old containers by their recorded CIDs (no `-f`). Optionally prune images in the old storage that are no longer used. Leave old volumes until you are sure; anonymous ones are disposable and were never transferred.
- **Root's own containers** follow the in-place branch (4.4) by hand: no volume transfer; stop, save and remove the legacy unit, `podman rename` the old container, install, validate, then remove the renamed copy. The doc includes the rollback (remove the new container, rename the old one back, restore the legacy unit).

**Tests.**
- A unit test for the warning: shown when `pending`, `deferred` or `failed` exist, names each account with its reason, and is absent when everything is `done`.
- A unit test for the detector on a fixture with legacy files and no `complete`.
- The manual doc is exercised once in the live migration environment before 2.0 ships, against a 1.x account that has a populated named-volume database and a counter-writer container, plus root's own container with a named volume. Assert: the last row and counter value written before the stop are present after recovery, the database passes its consistency check, the old containers are removed only after validation, and step 4 refuses a destination volume that already holds data.
- A unit test that the removal release's INSTALL/UPGRADE and lifecycle actions are not refused by a leftover `failed` state file.

## Phase 5: account hooks (2.0)

- **`_delete_user`** (`PodmanHooks.pm:122`): root runs `remove_unit` for every registry entry and orphan marker belonging to the user. Then the existing as-user removal, then another orphan sweep, then `release_runtime`, which removes the slice's `system.control` drop-ins (and the slice file, if one exists), recomputes `eapodman.slice`'s `MemoryLow`, and unmounts and removes the runtime tmpfs. Before waiting on the account lock, it writes the migration abort file (4.2 rule 5).
- **`remove_containers_for_a_deleted_user`** (`util.pm:2590`) does the same unit removal, using the marker uid, and also unmounts and removes `/run/ea-podman/user/<uid>` and removes `/etc/systemd/system.control/eapodman-<uid>.slice.d/`. The unmount comes first, and the directory is removed only after every process of the uid is gone, so root never walks a tree the account is still changing.
- The hooks' as-user removal and the restore tail run through the slice runner (F11).
- **`_pre_username_change`** (`PodmanHooks.pm:84`) keeps refusing.
- **Restore** (`util.pm:3159`): drop the `remove_tree` of `~/.config/systemd/user` (`:3185`). Units are recreated by the tail.
- **Uninstall:** in `pkg.prerm`, `remove_containers --all` deletes every unit, then sweeps orphans: files matching `ea-podman-*.service` that carry an ea-podman marker. Files without a marker are left alone.

## Phase 6: Web Apps plugin (`cpanel-plugins` repo; released together with 2.0, `Requires: ea-podman >= 2.0`)

ea-podman exports these for the plugin:

| Export | Replaces (`WebApps/Podman.pm`) |
|---|---|
| `container_unit_state` (UNIT_SHOW) | `systemctl --user show` (`:1479`) |
| `reset_container_unit_failure` (admin) | `:1399` |
| `podman_env` | used by `_in_user_session` (`:1930`) |
| `container_nproc_cap` | `:1838` |
| `container_cgroup_dir` (root-validated) | `:1631`, `:1976` |

On the plugin side:
- `set_lifecycle` calls `api_lifecycle` (admin) instead of `ea_podman::util::sysctl`.
- The account `MemoryLow` floor moves from `user-<uid>.slice` to `eapodman-<uid>.slice`. The plugin's root side sets it by calling `ea_podman::units::set_slice_properties` directly; there is no admin action for it (Phase 2). The "takes effect at next recreate" rule and the pending-release bookkeeping no longer apply to account totals.
- **Account limits (agreed with the plugin's DESIGN.md Limits section, EA4-352 comment 1801665):**
  - the plugin sets `MemoryLow` (floor) and `MemoryMax` (hard memory total, enforced live) on `eapodman-<uid>.slice`;
  - **no `CPUQuota`.** CPU stays on weights. The whitelist allows `CPUQuota`, but nothing requires it to be set;
  - `TasksMax` defaults come from ea-podman (Phase 1); the plugin doesn't set them;
  - **on CloudLinux,** whether the plugin sets `MemoryMax` at all, or leaves account totals to LVE, is decided after P0-6 measures double-limiting (open item).
- **OOM policy.** A `MemoryMax` OOM can kill any process in the account slice, including a container within its own allocation and a build. That is accepted, with one preference: build transients get `OOMScoreAdjust=500`, so the kernel kills a build before a serving container. The account can raise its own score but not lower it.
- `Session.pm` `ensure` / `ENSURE_SESSION` are replaced by ENSURE_USER. Drop the `user@.service.d` delegate drop-in (`Session.pm:175-198`).
- Builds (`systemd-run --user`, `Podman.pm:1167,1817`) move to the plugin's adminbin, which calls `ea_podman::units::run_as_user_in_slice` (Phase 1) with fixed properties (`RuntimeMaxSec`, `PAMName=ea-podman` per P0-6, `oom_score_adjust => 500`) and validated inputs. It never hand-builds a `systemd-run` line, and callers must never pass `-p`. stdin is `/dev/null`, stdout/stderr are fresh pipes, and captured output is capped.
- `_in_user_session` (`Podman.pm:1930`): when the plugin's root side runs it, it goes through `run_as_user_in_slice`, not a direct setuid fork (F11).

## Phase 7: remove dead code and update docs (in 2.0)

- **Delete:**
  - `subids.pm`: the linger, grant, carveout, mask and session code (about `:34-56`, `:175-1349`). Keep `ensure_user_root` (without the session), `_ensure_subids`, the range helpers, `assert_has_user_namespaces`, `get_sub*ids` and `_ensure_storage_conf`. The pieces the migration still needs are copied into `migrate.pm`.
  - In `util.pm`:
    - the session half of `ensure_user` and of `init_user`;
    - `release_user_session*`, `_release_deleted_user_session` and `ensure_container_session`;
    - `sysctl()`, `_masked_user_manager_note` and `EA_PODMAN_KEEP_USER_SESSION`;
    - the `/run/user/<uid>` and `DBUS_SESSION_BUS_ADDRESS` handling in `ensure_su_login` and `run_in_user_session`. Only `podman_env()` and its `XDG_RUNTIME_DIR=/run/ea-podman/user/<uid>` remain;
    - the LVE + cgroup v2 "kills systemd --user" advisory (`util.pm:366-411` and its callers), unless P0-6 says otherwise.
  - **Admin module:** the session, linger and grant parts of `ENSURE_USER`, which keeps only subids and `ensure_runtime`.
  - **CLI:** the `ensure_user_sessions` verb (`ea-podman.pl:1047-1089`).
  - **`ea-podman-user-managers.service` and its pieces:**
    - spec Source23, install and `%files`;
    - the `%ghost` mask files (spec `:137-141`);
    - the debify lines;
    - scriptlets `pkg.postinst:33-40`, `pkg.prerm:11-18`, `pkg.preinst:9-12`.
  - **Tests that only cover removed code:** carveout-lifecycle, linger, the session parts of `SOURCES-subids.t`, and the live `ea4-319-*` and `ea4-321-*` tests.
- **Kept on purpose:**
  - the single admin execution path (`delegate_to_admin`, `_as_cpuser`), now used by every non-root caller;
  - subuid/subgid allocation;
  - `XDG_RUNTIME_DIR`, now set through `podman_env`.
- **Docs:**
  - `DESIGN.md`: "Ensuring it is up", "Lingering", and the "users can still run `systemctl`" promise.
  - README FAQ.
  - `docs/container-shell-access.md`.
  - `docs/backup-restore.md`, including dropping the `.config/systemd` exclusion (`util.pm:2954-2993`).
  - The 2.0 changelog and release notes:
    - behaviour change;
    - UAPI removal;
    - migration (`migrate_units`), including the downtime while volumes are copied, the size limit for unattended runs, and `--stop-unmanaged`;
    - anonymous volumes are not migrated, the same as on a 1.x upgrade; the migration lists each one left in old storage, and arbitrary images must mount any path whose data must be kept;
    - lifecycle actions on an account that is being migrated fail after a short wait and can be retried;
    - each migration step has a deadline (`migrate.conf`); an account whose step runs past it is marked `failed` with the step named, and `--auto` runs stop retrying it after 3 timeouts;
    - on hosts where CageFS masks `user@.service`, every account's 1.x session is released in the first run, even if its migration fails, so its containers are down until it migrates; there is no unattended deferral there. On other hosts, `failed` or `deferred` accounts keep the old per-user manager and their running containers until they are migrated;
    - containers move from `user-<uid>.slice` to `eapodman.slice` / `eapodman-<uid>.slice`; limits set on `user.slice`, `user-.slice` or `user-<uid>.slice` no longer cover them and must be set on `eapodman-.slice`; all container accounts together get one `user.slice`-sized CPU and IO share;
    - the runtime dir is a capped tmpfs (`runtime.conf`), as `/run/user/<uid>` was;
    - path arguments to ea-podman (other than `-v`/`--mount`, EA4-343) must be inside the account's home;
    - per-account limits on concurrent ea-podman operations and on the number of containers;
    - per-container `--memory`/`--memory-swap`/`--cpus`/`--pids-limit` are now enforced on cgroup v2 (`--cgroups=split`); `--memory-swap` needs kernel swap accounting; `--memory-reservation` and `--cpu-shares` now take effect between containers through the unit's `MemoryLow=`/`CPUWeight=` (F13), and changing them needs a recreate; `--cgroups`, `--cgroup-parent` and `--cgroup-conf` start args are refused;
    - once `migration/complete` exists, every user namespace ea-podman creates comes from `eapodman.slice`, so hosts can deny namespace creation elsewhere with a BPF-LSM rule; list the kernels where that works (P0-12);
    - raw-podman notes;
    - downgrade unsupported.

## Security invariants (each one has a test)

1. **Unit text is only template text plus validated values.** Fuzz `write_unit` with `\n`, `%`, quotes, `\`, spaces, `;`, `+`, unicode and over-long values. Also feed it an inspect result containing `\nUser=root`. Every case must die. The rendered skeleton must equal the template.
2. **Exactly one `User=` line, equal to the registry user.** It is never 0 for non-root owners, and rendered units have no privileged Exec prefixes. The only privileged Exec line anywhere is the static anchor's `ExecStartPre=+…runtime-mount %i`, and it refuses anything but a resolvable non-zero numeric uid.
3. **Units are root:root 0644 in `/etc/systemd/system`.** A symlink planted at the destination makes the write refuse.
4. **Admin only acts on the caller's own registered containers.** It refuses unregistered names, other users' containers, and units whose marker uid doesn't match. Live test: user B gets "No such container" for A's containers on every action.
5. **No user path writes under `/etc`, and root never writes into home.** Migration test with a planted `~/.config/systemd/user` symlink pointing at `/etc`.
6. **After migration, no `user@<uid>` runs for container accounts, and no ea-podman linger or carveout remains.** The canary unit never runs, including after a reboot (P0-10).
7. **Every podman invocation uses the pinned `CONTAINERS_*`, including the migration's runs against old storage.** A hostile `~/.config/containers/containers.conf` (`runtime=~/evil`, `hooks_dir`), `containers.conf.d/` drop-in, `mounts.conf` or `CONTAINERS_CONF_OVERRIDE` never takes effect.
8. **Account removal leaves no unit and no runtime dir.** A new account that reuses the uid starts nothing.
9. **`ea-podman.json` `start_args` only reach `podman create` run as the user.** `units.pm` never reads that file.
10. **Slice properties are only ever set by root, from the whitelist, on a slice name derived from `getpwnam`.** No admin action sets them. Test: invalid property names or values and a caller-supplied slice name are refused, and the admin module exposes no action that reaches `set_slice_properties`.
11. **Account removal leaves no `system.control` drop-ins for the uid.** Live test: set a limit, remove the account, and a new account that reuses the uid has the default slice properties.
12. **No account lock is held across a user child or an admin call (the migration's bounded runner, 4.2a, is the one exception), and admin actions never wait on it indefinitely.** An account can't wedge root-side actions by holding a nested call open. Tests: the real nested-call and bounded-wait cases in 4.7.
13. **Migration never destroys data the new setup uses.** It never removes a container whose CID an ea-podman unit marker or `new_cid` references, never uses `podman rm -f` on an old copy, never exports and imports a volume within one store, and never recreates before a named volume's data is in the destination store (the manual doc included). Tests: the root in-place and CID-guard cases in 4.7, and the manual-doc live run in 4.8.
14. **No account can extend how long the migration holds a lock.** Every as-user step runs in a transient system unit with `RuntimeMaxSec`, under a root-side outer alarm. No lock descriptor reaches an account process. Every root `systemctl` call under an account lock is bounded by explicit unit timeouts. A timeout fails only that account, and the run continues. Tests: the deadline cases in 4.7 and the hostile-stall live test.
15. **No account process ever holds a root terminal or a root-held fd.** Every as-user process root starts (the migration runner, plugin builds) gets stdin from `/dev/null` and stdout/stderr on fresh pipes. Tests: the PTY unit case and the terminal-handoff live test in 4.7.
16. **An account can't exhaust shared host resources through ea-podman more than it could in 1.x.** The runtime dir is a capped tmpfs, not shared `/run`. Account slices sit under `eapodman.slice`, which carries one `user.slice`-sized CPU and IO weight and a `TasksMax` total, and each account slice has a default `TasksMax`. Root-side output buffers are capped, concurrent admin actions per account are limited, PID 1 reloads are coalesced, and units per account are capped. Tests: filling the runtime dir stops at its cap and leaves `/run` untouched; a fork bomb in one account's containers stops at its `TasksMax`; with 10 busy container accounts, a CPU-bound `system.slice` service keeps at least the share it gets against one busy `user.slice`.
17. **No account name or container name can collide with an internal unit.** Internal units use the `eapodman-` prefix, are matched by strict regex, and are never globbed. Test: the `migrate-1003-x` container case in 4.7.
18. **On a masked host, no account keeps ea-podman's 1.x session past the first run that visits it, whatever its migration outcome.** Tests: the session-release cases in 4.7 and the hostile-account live test.
19. **`PIDFile=` can't make PID 1 act on a process outside the unit.** Test (P0-3): a PID outside the unit's cgroup written to `conmon.pid` is refused, and `systemctl stop` kills nothing outside the unit.
20. **Every process root starts as an account runs inside `eapodman-<uid>.slice`, and no ea-podman path creates a user namespace outside `eapodman.slice` (F11).** Tests: a lint showing that `run_as_user_in_slice` is the only as-user path in `SOURCES/` and the plugin; unit tests showing that the admin `_as_cpuser` child, hooks, restore and builds go through it; the P0-12 live test, with the BPF-LSM program loaded across the full live suite.
21. **Start args can't move a container out of its unit's cgroup (F12).** Tests: the `--cgroups*` refusal cases; live, a container's `--memory` shows up as `memory.max` in its cgroup under the unit's cgroup, and is enforced. **Relative limits reach the unit (F13).** Tests: render cases for `{MEMLOW}`/`{CPUWEIGHT}` (defaults, conversion, clamping, refusal of non-numeric values); live, `--memory-swap`, `--cpus`, `--memory-reservation` and `--cpu-shares` show up as `memory.swap.max`, `cpu.max`, `memory.low` and `cpu.weight` in the container cgroup, the unit's `memory.low`/`cpu.weight` match, and each slice's `memory.low` is at least the sum below it.

## Tests

- **Delete:**
  - `t/SOURCES-subids-carveout-lifecycle.t`
  - `t/SOURCES-util-linger.t`
  - the session/mask parts of `t/SOURCES-subids.t`
  - `t/LiveTests/ea4-319-*.sh`
  - `t/LiveTests/ea4-321-*.t`
- **Rewrite:**
  - `t/SOURCES-util-container-unit.t`, which becomes `t/SOURCES-units.t`
  - start-verdict, nproc-cap, cgroup
  - upgrade-rollback, upgrade-gate
  - the admin-module tests (the UAPI test is deleted in Phase 3b)
  - PodmanHooks-backup, pkg-scriptlets-hooks, the restore tests
- **New unit tests:**
  - `t/SOURCES-units-injection.t`
  - `t/SOURCES-migrate-units.t` (see 4.7)
  - a PodmanHooks removal test
  - the slice runner: lint, injection and label cases (in `t/SOURCES-units.t`), and `_as_cpuser` routing
- **Live, rework:** cagefs, normal, jailshell, memcached16 (both), ea4-315, ea4-325, ea4-338, cpanel-57396, cpanel-57608.
- **Live, new:**
  - `system-units-migration-live.t` (see 4.7)
  - `clos7971-canary-live.t`
  - `bpf-lsm-userns-live.t` (P0-12; runs only on kernels with the hook)
  - a `--memory` enforcement case in the normal live test, plus `--memory-swap`, `--cpus`, `--memory-reservation` and `--cpu-shares` cases that check the container cgroup, the unit and both slices (F13).

## Sequence

1. **Spikes P0-1 … P0-12.** P0-6 (LVE) is a ship gate. If one invalidates an assumption, the design changes before code is written.
2. **Implement everything:** Phases 1-7 in ea-podman and Phase 6 in the plugin.
3. **Pre-release testing:**
   - the unit suite, including the injection and migration tests;
   - the full live suite;
   - the migration matrix in 4.7, including reboot, kill and concurrent-run cases.
4. **One coordinated release:** ea-podman 2.0 and the matching Web Apps plugin, locked together by `Requires`/`Conflicts`.
5. **Remove 1.x from the mirrors** (RPM and Ubuntu). Keep an internal archive copy for tests.
6. **Release + 6 months at the earliest** (the date is in the release notes and the verb's warning; check adoption telemetry first): a 2.x removes `migrate_units` / `migrate.pm`, `ea-podman-migrate.timer` and `ea-podman-migrate.service` (its scriptlet disables the timer first), and ships the post-removal detector (4.8). This is not a deprecation period; the warning text carries the date.
7. **Follow-up:** a root-owned graphroot (F4).
8. **Follow-up:** once P0-12 passes, ship or document a BPF-LSM namespace policy (with CloudLinux / hardening). It is not part of 2.0; 2.0 only makes it possible (F11).

## Open items (resolved by the spikes or a quick call)

- **LVE:** do we need `/etc/pam.d/ea-podman` (P0-6)? P0-6 is a release gate: every process ea-podman starts as the account, transients included, must be inside its LVE.
- **`LimitNPROC`:** use the system `DefaultLimitNPROC`, or a fixed cap?
- **Parent slice values:** `eapodman.slice` `CPUWeight`/`IOWeight`/`TasksMax`, and the per-account default `TasksMax` (P0-4). Nesting itself is decided (F9).
- **`runtime.conf` defaults:** tmpfs `size`/`nr_inodes`, `max_units_per_account`, `max_concurrent_admin_actions`.
- **Who owns account totals on CloudLinux:** the slice's `MemoryMax` (set by the plugin), or LVE? This is decided after P0-6 measures double-limiting (Chris, EA4-352 comment 1801665).
- **Swap accounting and crun conversion:** which targets lack `memory.swap.max`, and what `cpu.weight` each target's crun writes for `--cpu-shares` (P0-4). Where swap accounting is missing, does INSTALL refuse `--memory-swap` or only warn?
- **BPF-LSM support matrix:** which platforms can enable the F11 rule (P0-12).
- **Follow-up:** a root-owned graphroot to close F4.
- **Follow-up:** a shipped or documented BPF-LSM namespace policy (F11).

## Verification

- `prove -lr t/` passes, including the new injection and migration tests.
- An upgrade from 1.x returns promptly. `ea-podman migrate_units --status` shows every account `done`, and `migration/complete` exists.
- Run the Phase 0 matrix, then the live suite on EL8, CL9 with CageFS, EL10 and Ubuntu 24.04.
- On a migrated CL9 + CageFS host:
  - `systemctl list-units 'user@*'` shows none for container accounts;
  - `ls /run/systemd/system/user@*` is empty;
  - `ls /etc/systemd/system/ea-podman-*` shows root:root 0644 units;
  - `findmnt /run/ea-podman/user/<uid>` shows a tmpfs with the configured `size` and `nr_inodes` for each container account;
  - `systemd-cgls` shows container accounts under `eapodman.slice`, and nothing ea-podman starts sits directly under the root cgroup or in `user.slice`. That includes the `_as_cpuser` child during an admin INSTALL;
  - a container installed with `--memory` has that value as `memory.max` in its cgroup under `eapodman.slice/eapodman-<uid>.slice/ea-podman-<name>.service/`;
  - a container installed with `--memory=512m --memory-swap=512m --memory-reservation=256m --cpus=1.0 --cpu-shares=1024` has `memory.swap.max` 0, `memory.low` 256M and `cpu.max` `100000 100000` in its cgroup; its unit has `memory.low` 256M and `cpu.weight` 100; and `eapodman-<uid>.slice` and `eapodman.slice` each have `memory.low` of at least 256M;
  - on a P0-12 kernel with the test BPF-LSM program loaded, `unshare -U true` as the account from SSH fails, while `ea-podman` install, start and restart succeed;
  - `ea-podman list`/`status` works as the user from any shell (via the admin module);
  - `./test.sh <user>` reports the canary never ran;
  - after a reboot the containers come back, and the raw-podman container still exists in `~/.local/share/containers`.
