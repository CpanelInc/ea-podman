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

**Stays:**
- **The admin execution path** (`delegate_to_admin`, `_as_cpuser`). Phase 3b makes it the *only* non-root path and removes the restricted-shell/CageFS detection and the EAPodman UAPI. podman still can't run inside the cage: nosuid breaks newuidmap, and jailshell lacks the binaries. That is why everything except `bash` runs outside the cage via admin, and `bash` stays direct for unrestricted shells only.
- **User namespaces.** Rootless podman still creates a user namespace per container, plus mount, net, pid and other namespaces inside it. It also still needs subuid/subgid allocation (`subids.pm` `_ensure_subids`) and the setuid `newuidmap`/`newgidmap`. **The kernel-CVE exposure is unchanged.** This plan fixes CLOS-4517, not the userns CVEs. 2.0 does make the exposure narrowable: every user namespace ea-podman creates is created inside `eapodman.slice`, so a host BPF-LSM rule on `userns_create` can deny namespace creation everywhere else (F11, invariant 20; EA4-352 comment 1802820).
- **The cgroup v2 advice (EA4-360), CloudLinux 8 carve-out included** (`warn_if_not_cgroup_v2`, `util.pm:404-421`).
  - **What it is:** a root-only "we recommend cgroup v2" warning. It replaced the old "LVE + cgroup v2 kills `systemd --user`" advisory in 1.0-38.
  - **Its wording stays:** `tuned-adm profile cloudlinux-default-cgv2` on CloudLinux 9/10, `grubby` elsewhere.
  - **It stays quiet on CloudLinux 8, and CL8 stays on cgroup v1 in 2.0.** Getting CL8 onto v2 is EA4-365, separate from this plan. Julian's follow-up (EA4-360 comment 1805876) shows system units starting, restarting, serving and enforcing limits on CL8 v2 with `hidepid=2`. That removes the `user@` failure behind the carve-out, but other CL8 v2 issues are still possible, and its remaining checks are EA4-365's: CPU throttling, a reboot, the uninstall order. So 2.0 doesn't recommend v2 on CL8, and CL8 containers get no per-container limits (v1, F12/F17).
- **The user namespace gate (EA4-360).**
  - **What it does:** `init_user` refuses up front when the host doesn't allow unprivileged user namespaces (`subids::assert_has_user_namespaces`, `subids.pm:1394`). The refusal points to https://go.cpanel.net/userns.
  - **Root-only:** CageFS and CloudLinux's `/proc` restrictions can hide what the check reads. So a user's command gets the check root-side, from `ENSURE_USER($creating, $userns_optional)` (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:201`).
  - **Warn-only verbs:** verbs whose own work needs no podman pass `userns_optional`, and only warn (`warn_if_no_user_namespaces`, `subids.pm:1457`). A host that lost user namespaces can still stop and clean up.

  2.0 keeps the same split, now on root-side actions:
  - **refuse:** INSTALL, UPGRADE, START, RESTART, UNIT_INSTALL, and `ensure_runtime` (the anchor runs `podman unshare`);
  - **warn only:** STOP, STATUS/UNIT_SHOW, UNIT_REMOVE, RESET_FAILED, UNINSTALL, `remove_containers`, the account hooks and `containers`;
  - **`migrate_units`:** checks once per run (Phase 4, entry point). Without user namespaces it migrates nothing and marks no account `failed`. On masked hosts it still applies step 12, which is root-only;
  - **CloudLinux 10:** new installs ship with `user.max_user_namespaces=0` (CLOS-2616; Julian, EA4-357 comment 1803523). The gate catches it, and the host docs (Phase 3b) say how to restore the value. To raise with CloudLinux together with F11 (EA4-389): a BPF-LSM rule is a narrow alternative to that blanket `0`.
- **cgroups.** Containers still get their own cgroups:
  - `Delegate=yes` on the system units hands the account's processes a subtree;
  - podman uses `cgroupfs` there instead of asking the user manager over D-Bus, with `cgroups = "split"` pinned on cgroup v2 (F17). Split puts conmon and the container in sub-cgroups of the unit's delegated cgroup;
  - the cgroup manager and the cgroups mode come only from the pinned config. Start args can't override them, and CMD runs no podman (F17, F22, Phase 3b);
  - per-container limits (`--memory`, `--pids-limit`) are enforced on cgroup v2 **only with split**; without it they are silently ignored (Julian, EA4-352 comment 1801665). As today, they don't work for rootless on v1 (F12). Split isn't pinned there, because it stops containers starting (F17).
- **A smaller "session".** The per-user runtime directory now comes from the anchor unit `ea-podman-runtime@<uid>`, and `podman_env()` gives every podman call the same environment. That replaces the whole linger/carveout layer.

## Findings that shape the design

- **F1: we need our own runtime dir.**
  - Without linger, logind owns `/run/user/<uid>`. It overmounts it on login and wipes it on logout.
  - So we use a root-created `/run/ea-podman/user/<uid>`, set up by a per-user anchor unit.
  - Existing libpod DBs record `runroot=/run/user/<uid>`, so existing containers must be recreated in fresh storage.
- **F2: the cgroup manager has to change.** Existing containers may record `CgroupManager=systemd`, which needs the user bus. New containers are created with cgroupfs and `Delegate=yes`. This is a second reason to recreate.
- **F3: LVE limits are lost.** A `User=` unit gets no PAM session, so CloudLinux `pam_lve` limits don't apply.
  - **Observed** in a 2.0 prototype (Julian, EA4-352 comment 1801665) and on all three CloudLinux boxes in the EA4-357 run: CL8, CL9 and CL10 (Julian, EA4-357 comment 1803523). Every conmon and container process sat under `/eapodman.slice`, and `lveps` showed nothing for the account.
  - **Entering the LVE doesn't fix this on cgroup v2** (F18).
  - **Accepted (F18, decided in T0.3):** ea-podman doesn't enter the LVE. Containers stay outside it, and the account slice and the per-container limits apply instead. There is no `PAMName=`, `pam_lve` or `lve_wrapper` anywhere in 2.0.
- **F4: residual (not root, not a regression).** The account owns its libpod DB. From inside the cage it could change a container's OCI runtime or hooks, which would then run as the user outside the cage. Pinning `CONTAINERS_CONF` does not close this. A root-owned graphroot would (follow-up).
- **F5: lifecycle actions don't check registration.** START/STOP/RESTART/STATUS only check the name suffix (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:418,428,437,446`). They must require `registered => 1`.
- **F7: an account's containers need a grouping cgroup.** As separate units in `system.slice`, nothing groups an account's containers. The Web Apps plugin's `MemoryLow` floor on `user-<uid>.slice` would protect nothing, and account totals could never be enforced. Fix: a per-account slice (see Phase 1). Requested on EA4-352 (comment 1800842).
- **F6: restore deletes too much.** `perform_user_restore` deletes all of `~/.config/systemd/user` (`util.pm:3199`), including the user's own units. Stop doing that.
- **F8: the runtime dir loses its size cap.** In 1.x, `/run/user/<uid>` is its own tmpfs, capped by logind (`RuntimeDirectorySize=10%`). A plain directory under `/run` shares the system tmpfs with PID 1, journald, `/run/systemd/transient` and every daemon's PID files, and disk quotas don't apply to tmpfs. Fix: the anchor mounts a capped per-uid tmpfs (Phase 1).
- **F9: moving out of `user-<uid>.slice` drops per-user limits and changes CPU fairness.** In 1.x every account's processes share the one `user.slice` weight and get logind's `TasksMax` (33%) plus any admin drop-ins on `user.slice`, `user-.slice` or `user-<uid>.slice`. Slices directly under the root would each be a sibling of `system.slice` with the same weight, and per-unit `DefaultTasksMax` (15%) has no per-account total. Fix: account slices nest under a packaged `eapodman.slice` (Phase 1).
- **F10: the as-user processes the migration starts must not get root's terminal.** `systemd-run --pipe` gives the transient unit `systemd-run`'s own stdin, stdout and stderr. When an admin runs `migrate_units` in a shell, stdin is root's TTY. The account can open `/proc/<pid>/fd/0` of its own podman process (same uid, not setuid; Yama doesn't restrict this), then read root's input or inject keystrokes with TIOCSTI (allowed on the EL8/EL9 and Ubuntu 22.04 kernels). Fix: 4.2a.
- **F11: a namespace-creation boundary (EA4-352 comment 1802820).** In 1.x and in the earlier plan, ea-podman creates user namespaces from cpsrvd's cgroup (the admin module's `_as_cpuser` child) and from root's as-user helpers. So no cgroup-based rule can tell ea-podman's namespace creation apart from anything else the account runs. Fix: every process root starts as an account runs in `eapodman-<uid>.slice`, through one slice runner (Phase 1). A host BPF-LSM rule on `userns_create` can then allow namespace creation only under `eapodman.slice`. Limits:
  - sound only on cgroup v2. On v1 an account can move its own process into a delegated cgroup (P0-11);
  - code running inside the account's containers can still create namespaces. The rule stops the account's shell, cron and CGI processes, not its container workloads;
  - it bounds where namespaces are created, not whether the account can get code into `eapodman.slice`. An account with a running container always can: its own shell can ptrace its conmon and container processes on all 9, including Ubuntu with `kernel.yama.ptrace_scope=1`, because it owns their user namespace (T0.8);
  - enabled only after `migration/complete`, because 1.x containers run under `user@`;
  - needs a kernel with the `userns_create` LSM hook and `lsm=bpf` (P0-12). EL8's and CL8's 4.18 have `bpf` active but no hook; Ubuntu 22.04's 5.15 has neither (P0-12 re-run, 2026-11-09);
  - **open: the uid floor of a shipped rule.** The test program only denies uid >= 1000. A shipped rule has to choose: deny every non-root uid (untested; a system service that creates a user namespace under its own uid would break), or keep a floor and leave system accounts such as `nobody` unfenced. To raise with CloudLinux (EA4-389).
- **F12: per-container limits need `--cgroups=split`** (EA4-352 comment 1801665). With cgroupfs and `Delegate=yes` alone, podman doesn't place the container in a sub-cgroup of the unit, so `--memory` is not enforced. Fix: pin `cgroups = "split"` on cgroup v2 only (Phase 1, F17), and refuse start args that override it (Phase 3b).
- **F13: relative limits need matching values on the container unit.** `--memory`, `--memory-swap`, `--cpus` and `--pids-limit` are hard caps on the container's own cgroup, so split alone makes them work. `--memory-reservation` and `--cpu-shares` are not:
  - `--memory-reservation` becomes `memory.low`, which only protects up to what every ancestor is protected for. The chain is container → `ea-podman-<name>.service` → `eapodman-<uid>.slice` → `eapodman.slice`. The unit's own `memory.low` belongs to systemd (`MemoryLow=`, default 0), not to the delegated subtree. So on EL8 (4.18, no `memory_recursiveprot`) the reservation does nothing, and on newer kernels (`memory_recursiveprot`) the unit only gets a usage-weighted share of the slice's unclaimed floor, not a guaranteed amount;
  - `--cpu-shares` becomes `cpu.weight`. The conversion follows the OCI runtime version, not podman's: for 1024/2048/512, runc 1.2.9, crun 1.14.1 and crun 0.17 give 39/79/20, and crun 1.27 and 1.30.1 give 100/174/59 (P0-4; first seen by Julian as podman 4 with runc against podman 5 with crun, EA4-357 comment 1803523). A weight only counts against sibling cgroups. Inside the unit, the container's only sibling is conmon's cgroup; between containers, the units compete with systemd's `CPUWeight=` (default 100). So `--cpu-shares` does nothing between containers;
  - `--memory-swap` becomes `memory.swap.max` and needs kernel swap accounting. Without it, podman warns and drops the limit.

  Fix: the container unit carries `MemoryLow=` and `CPUWeight=` taken from the container's reservation and shares (Phase 1), and slice floors include the unit floors. P0-4 checks swap accounting on every target.

  **Memory floors are best effort, by platform** (EA4-357 comments 1802943 and 1803523). `CPUWeight=` behaved as designed on every OS. The unit's `MemoryLow=` is only as good as the kernel's protection:
  - **Newer kernels:** it holds. On Ubuntu 24.04, AlmaLinux 9.8 and AlmaLinux 10.2, web's page cache stayed at about 250M against its 256M floor, and at about 165M without the floor.
  - **EL8:** it is unreliable. One AlmaLinux 8.10 run held 251M, but held 232M without the floor, so the floor barely mattered. Another dropped to 0M with the floor set.
  - **CloudLinux:** it may protect nothing. Page cache isn't charged to the writer's cgroup (CL8, CL9 and CL10, reproduced outside the kit), so there is nothing in the cgroup for a floor to keep.

  The units still carry `MemoryLow=`. The plugin's account floor (Phase 6) and the release notes say where it works.

  **T0.2 (P0-4): MGLRU disables the floors against host-wide pressure.** Under pressure from outside the slices (a file 1.5× RAM streamed from `system.slice`), the floors only held where the kernel's multi-gen LRU is off:
  - **No MGLRU** (EL8 4.18, Ubuntu 22.04 5.15): a 300M page-cache holder under `eapodman-<uid>.slice` (account and `eapodman.slice` floors 832M, its own `MemoryLow=400M`) kept 100%;
  - **MGLRU on** (`/sys/kernel/mm/lru_gen/enabled` = `0x0007` by default on EL9, EL10, CL9, CL10 and Ubuntu 24.04): the same holder kept 2–4%, the same as one with no floor. With `echo n > /sys/kernel/mm/lru_gen/enabled`, EL9 and Ubuntu 24.04 kept 100% again;
  - **Pressure inside the account slice** (the kit's `loadtest.sh`, slice `memory.max` 250M below usage) still respects the unit floors on every non-CloudLinux v2 host, MGLRU or not: web kept 245–252M against its 256M floor.

  So on EL9+, CloudLinux 9/10 and Ubuntu 24.04 as shipped, `MemoryLow=` protects a container against its own account, not against the rest of the host.

  **T0.6: `MemoryMin=` does hold under MGLRU.** The same test with `MemoryMin=400M` on the holder, the account slice and `eapodman.slice` kept 100% on EL9 and Ubuntu 24.04 (MGLRU on) and on EL8 v2. As with `MemoryLow`, a floor on `user-<uid>.slice` still kept nothing.

  **Decision (T0.6): keep `MemoryLow=` for both the unit floors and the account floor, and document the floors by platform.**
  - **Why not `MemoryMin=`.** It is a hard reservation: the kernel never reclaims below it, so floors can't be overcommitted safely. The account slice's floor includes its units' floors, which come from the account's own `--memory-reservation`. With `MemoryMin` an account could pin host memory with an install flag.
  - **Why not change the host.** Turning MGLRU off is a host-wide performance choice, not ea-podman's to make. The docs say what was measured, so an admin who wants host-wide protection can choose it.
  - **Follow-up:** an admin-only "hard floor" in the plugin, which sets `MemoryMin` on the account slice from the admin's value alone, never from unit reservations, if Limits wants one.
- **F14: `podman exec` processes are not in the container's cgroup.** An exec'd process stays in its caller's cgroup. The OCI runtime (runc on EL8, crun elsewhere) can't move it into the container's `libpod-payload-*` cgroup: on cgroup v2 a move needs write access to `cgroup.procs` of the common ancestor, which is the root-owned `eapodman-<uid>.slice`. The rootless runtime ignores the failure. This happens even when the caller is a delegated transient. Since every 2.0 exec goes through the slice runner, an exec'd process runs in the runner's transient unit under `eapodman-<uid>.slice`:
  - it is bound by the account slice (`MemoryMax`, `TasksMax`, CPU weight) and the namespace rule (F11), not by the LVE (F18), but **not** by the container's `--memory`/`--cpus`/`--pids-limit`, and it is not counted in the container's cgroup or `podman stats`;
  - it lives only as long as the runner: `RuntimeMaxSec` and `KillMode=control-group` end it, so `podman exec -d` can't outlive the call.

  **Original decision, replaced by T0.8 (F20): accept and document.** Per-container limits are a resource-planning tool, not a boundary against the account, which can run any process outside them from its own shell. The alternative (root moves the exec'd process into the container unit's delegated subtree) is a follow-up (Open items). 2.0 refuses `exec -d`/`--detach` through ea-podman (Phase 3b) and documents the rest (Phase 7). 1.x very likely behaves the same (an SSH session and `user@<uid>` share only the root-owned `user-<uid>.slice`); P0-13 confirms it.

  **T0.2 (P0-13) overturned part of this, and T0.8 replaced the decision (F20): `ea-podman bash` now lands in the container's cgroup, as in 1.x, and `cmd` keeps running outside the container's limits.** "The rootless runtime ignores the failure" holds for runc only:
  - **crun** (every target except EL8 and CL8: crun 0.17, 1.14.1, 1.27, 1.30.1): `podman exec` from the slice runner, and from the account's own shell (`ea-podman bash`), **fails**: `crun: write to …/libpod-payload-<id>/cgroup.procs: Permission denied: OCI permission denied`, exit 126;
  - **runc on v2** (EL8 v2): it works and stays in the caller's cgroup, as described above;
  - **runc on v1** (EL8 v1, CL8): it works and lands in the container's own cgroup (v1 has no common-ancestor rule);
  - **1.x does not behave the same.** On every unmasked host, an exec from a login session into a `user@`-managed container lands in the container's own cgroup (podman's systemd cgroup manager moves it).

  **Evidence** (AlmaLinux 8.10, cgroup v2, systemd 239, podman 4.4.1, runc 1.1.4; `EA4-352/eapodman-test-kit/loadtest.sh`): `podman exec <web> cat /proc/self/cgroup` shows the runner's `run-u*.service`, with and without `Delegate=yes` on it; a 600M allocation by `podman exec` succeeds in a container with `--memory=512m`, and is OOM-killed (exit 137, `oom_kill` 0 → 1) when the same process is placed in the container's cgroup. The same run confirmed F12/F13: `--cpus` caps exact (1.01/2.01/0.50); `memory.swap.max=0` with no swap used while the host had swap; with equal unit weights, the containers' own `--cpu-shares` (runc weights 39/79/20) made no difference. With the unit's `MemoryLow=`, the page cache held near its floor under slice pressure: web 400M → 251M against a 256M floor, worker 200M → 61M against 64M. But the control without it kept about as much (web 232M, worker 88M; EA4-357 comment 1802943), so on EL8 this run doesn't show the floor protecting (F13).

- **F20: on crun, `podman exec` only works from inside the container unit's delegated subtree** (T0.2, P0-13). A caller that root has placed in a sub-cgroup of `ea-podman-<name>.service` (F14 option 2, Open items) gets its exec'd process into the container's `libpod-payload-*` cgroup on all 9 hosts, crun and runc, v1 and v2. Every other caller fails on crun. This includes the slice runner, a `Delegate=yes` transient (the common ancestor is still the root-owned account slice), and the account's SSH shell. So, as planned, 2.0 breaks `ea-podman bash` and every exec on EL9, EL10, CL9, CL10 and Ubuntu, where 1.x works. `ea-podman cmd` (`exec_in_container`, `nsenter` as root, `util.pm:201`) doesn't use `podman exec` and is unaffected.

  **Decision (T0.8, EA4-368; `probes/t0-8.sh` on all 9): root places the exec caller in the container's unit.**
  - **`ea-podman bash`** stays a direct `podman exec -it` from the account's own process, with one root step first. A new admin action, `EXEC_PLACE` (Phase 2), moves that process on cgroup v2 into a fixed leaf of the container's own unit, `<unit cgroup>/ea-podman-exec`. The CLI then execs `podman exec -it` in the same process, so the account's terminal, signals and window size work as in 1.x. On v1 nothing is moved: exec already lands in the container's cgroup there.
    - **Measured, unmoved:** the exec fails on every crun host (`OCI permission denied`, or `Runtime did not set up terminal` with `-it` on crun 1.30.1). On EL8 v2's runc it runs in the caller's session scope.
    - **Measured, moved:** it works on every v2 host. The exec'd process is in the container's `libpod-payload-*` cgroup, the podman client and the exec session's conmon are in the leaf, and the pty reports the caller's size. On v1 (EL8, CL8) it works unmoved, in the container's cgroup.
    - **As in 1.x:** the exec'd work counts against the container's own limits and `podman stats`. The client and conmon count against the unit and the account slice. `systemctl stop` of the unit ends the session and removes the leaf (all 9). There is no deadline: it is an interactive session, as in 1.x, and it ends with the terminal or the container.
    - **Which process root moves:** only one that is the caller's own and an ancestor of the admin call (`EXEC_PLACE` walks its own `PPid` chain). So it is alive, and it can't be another account's process or a reused PID. Root moves it only into a leaf of the caller's own running container unit, at the `ControlGroup` systemd reports. Any failure refuses; `bash` never falls back to an unplaced exec.
    - **Why the caller's own process, and not one root starts:** root would have to carry the terminal into a process it starts (fd passing or a pty proxy, a new streaming channel into root), and would gain nothing. The moved process only reaches the account's own unit, where its containers already run code it chooses, and where its shell can already ptrace (F11).
    - **Why not `nsenter` for `bash`:** the session would run outside the container's cgroup, seccomp filter and capability set (`-S 0` gives the full set in the user namespace). `cmd` keeps `nsenter` for captured, non-interactive commands, where it is what works under `hidepid`.
    - **A hostile leaf:** the account owns the unit's subtree, so it can create, freeze, limit or remove `ea-podman-exec` first. That only stalls or fails its own session: with the leaf frozen, root's write returned in 6–22 ms on every v2 host, and the exec ran once the account thawed it.
  - **`cmd` (CMD, `EXEC_IN_CONTAINER`) is unchanged.** It never used `podman exec`. In 2.0 its command runs in the admin child's runner transient, bound by the account slice and the runner's deadline, not by the container's limits (F14).
  - **Health checks** are execs too. Their scheduling is F24.
  - **No `exec -d` rule is needed.** `bash` is interactive and `cmd` is `nsenter`, so ea-podman runs no detached exec. Phase 3b's refusal is dropped.

- **F15: a SIGKILLed conmon leaves the container down until it is recreated.** conmon is the unit's main process (`PIDFile=`). With `--cgroups=split` it shares the unit's cgroup with the container, so when conmon dies systemd kills the container too, and no exit status is ever recorded. podman 4.4 then still lists the container as running (or as stopping, after the `ExecStopPost=podman stop` that 1.x units also carry). Every `Restart=` attempt's `podman start` fails ("must be in Created or Stopped state"), the start limit is reached and the unit stays failed. `podman container cleanup` doesn't clear it; only `podman rm -f` and a recreate do. Killing the container's own init instead recovers in about 7 s.
  - **Who can cause it:** the account, which owns conmon, and an OOM kill in the account slice (`MemoryMax`, Phase 6), which can pick conmon. A rootless conmon can't lower its own `oom_score_adj`.
  - **Which podman versions** (Julian, EA4-357 comment 1803523):
    - **Reproduces:** podman 4.4.1 (the AlmaLinux 8.10 host below) and 4.9.3 on Ubuntu 24.04.
    - **Doesn't reproduce:** 4.9.4-rhel (AlmaLinux 8.10, CloudLinux 8) and 5.8.2 (AlmaLinux 9.8 and 10.2, CloudLinux 9 and 10). There the container whose conmon was killed is back in about 7 s.
    - **Ubuntu 22.04 (podman 3.4.4), T0.2:** a different failure. `Restart=` brings the unit back (new conmon, `NRestarts` 1, container `Up`), but the container's published port is gone: `Connection refused`, its rootlessport died with the old conmon. The unit looks healthy and serves nothing.
    - **T0.2 matrix** (kit `lifecycle.sh`, all 9 VMs): recovers on 4.9.4-rhel (EL8 v1 and v2, CL8 v1) and 5.8.2 (EL9, EL10, CL9, CL10); Ubuntu 24.04 (4.9.3) as above.
  - **1.x behaves the same** (T0.4, `probes/f15-1x.sh`). The test used a 1.x container under the account's own `user@`, with 1.x's generated unit (`podman generate systemd --restart-policy on-failure` plus `%container_unit_directives`). There the container has its own `libpod-*.scope` outside the unit. After a conmon SIGKILL:
    - **Ubuntu 24.04:** the unit ends `failed` after 3 restarts, with the container stuck in `stopping`;
    - **Ubuntu 22.04:** the unit is back `active`, the container is `running`, and the port is dead.

    So F15 is a podman bug in those versions, not something 2.0's unit shape introduces.
  - **What is stuck on 4.9.3:** the DB says `stopping` while crun says `stopped` (`podman kill`: `container state improper: stopped`). None of `podman stop -t 0`, `stop --ignore`, `kill`, `container cleanup`, `init` or `ps --sync` clears it.
    - podman's own post-reboot state refresh does clear it (`stopping` → `created`). Stop all of the account's units and its anchor, remove `libpod/tmp/alive` and the stale `pause.pid` in its runtime dir, then start the anchor and the units. The first start can fail once with `crun: container … already exists`, and `Restart=` then brings it up.
    - That refresh is account-wide, so it can't be a per-unit `ExecStartPre`.
    - `podman rm -f` plus a recreate also works, but loses anonymous volumes.
  - **The OOM path is theoretical.** Six account-slice OOMs on Ubuntu 22.04 and 24.04 (slice `MemoryMax` below a 400M allocation in a container) each killed the allocating process, never conmon, and the container kept serving. conmon's footprint is a few MB, so the OOM killer doesn't pick it while a container process is larger. The practical trigger is the account killing its own conmon, which only harms the account.
  - **`OOMScoreAdjust=` on the unit doesn't work as a guard.** With `-1000` the container also inherits `-1000` on podman 4.9 and 5.8 (not on 3.4), which makes it unkillable unless every create passes `--oom-score-adj=0`. The kernel also lets the account lower its own processes back to the inherited value. So it could make its containers immune in a host-wide OOM, which is worse than F15.
  - **Decision (T0.4): accept, document the recovery, and track podman.**
    - **Why not ship-blocking:** it is pre-existing in 1.x, it is caused in practice only by the account itself, and it is limited to Ubuntu's podman 3.4.4 and 4.9.3.
    - **The options, one by one:**
      - **No minimum podman version.** Ubuntu 22.04 and 24.04 ship only these versions, so a minimum would drop Ubuntu.
      - **No `ExecStartPre` cleanup.** No per-container command clears the state without losing data.
      - **No unit-shape change.** 1.x's shape, with the container in its own scope, fails the same way.
      - **No `OOMScoreAdjust=`** (above).
    - **Recovery** (Phase 7 docs, and the status message when a unit hits its start limit on Ubuntu):
      - **Ubuntu 24.04:** `ea-podman upgrade --force <name>`. Without `--force`, `upgrade` skips a container whose image hasn't moved (`_upgrade_is_needed`), which is the usual case here. It still pulls first and falls back to the cached image; anonymous volumes are lost, as with any recreate.
      - **Ubuntu 22.04:** `ea-podman restart <name>` brings the port back.
    - **Revisit:** when Ubuntu ships podman 4.9.4+ or 5.x, or if an account-wide "reset runtime" verb is wanted (the refresh above).
    - **Live test** (T1.20): a hard check on EL and CloudLinux. On Ubuntu 24.04 it is a known TODO matched by `container state improper`; on Ubuntu 22.04, a known TODO matched by "unit active, port refused".
  - **Evidence** (same host; `EA4-352/eapodman-test-kit/lifecycle.sh` tests 1 and 3): `Failed with result 'signal'`, then on each restart `Error: unable to start container …: container state improper` and `Failed with result 'exit-code'`, and finally the start limit.

- **F16: rootless CNI needs a writable `$XDG_CONFIG_HOME/cni`** (Julian, EA4-357 comment 1803523).
  - **The failure:** podman 4.9.4 on AlmaLinux 8 and CloudLinux 8 uses the CNI network backend, the EL8 default, and rootless CNI creates `$XDG_CONFIG_HOME/cni`. With `XDG_CONFIG_HOME` pinned to a root-owned empty dir (Phase 1), the anchor fails: `mkdir /etc/eapodman-test/empty/cni: permission denied`.
  - **Not seen on Dan's A8 run** (podman 4.4.1). Why is unknown; it may use a different network backend.
  - **Don't make the whole dir account-writable.** The account could then add `containers/policy.json`, `registries.d` and other config that podman reads.
  - **Fix (Phase 1):** `XDG_CONFIG_HOME` is a root-owned per-account dir, `/run/ea-podman/xdg/<uid>` (root 0755). It holds only a root-owned symlink, `cni` → `/run/ea-podman/user/<uid>/cni`, which lives in the account's capped runtime tmpfs (F8).
  - **What the account controls:** only its own CNI network config. That is the same class as F4 (it owns its libpod DB) and as netavark's rootless default (`<graphroot>/networks`, in the account's storage), so requiring netavark would not remove it.
  - P0-8 confirms that nothing else under `XDG_CONFIG_HOME` is needed or read.

- **F17: the `split` pin breaks cgroup v1, and a command-line `--cgroups` overrides it** (Chris, EA4-352 comment 1806521; full text on ea-podman PR #43, comment 6528455200).
  - **On cgroup v1** (AlmaLinux 8.10, podman 4.9.4), a system unit with `User=` and `Delegate=yes`:
    - **`--cgroups=split`:** the container is created, then fails to start: `mkdir /sys/fs/cgroup/pids/system.slice/<unit>/runtime: permission denied`.
    - **`--cgroups=enabled` or no flag:** it starts, with podman's "Resource limits are not supported and ignored on cgroups V1 rootless systems" warning, as today.

    EA4-357 ran only on v2. The plugin's Limits design (CPANEL-58034, LIM-ENF-4a) already leaves split off on v1.
  - **On cgroup v2,** under the plan's units (AlmaLinux 10.2, podman 5.8.2, crun, `--cgroup-manager=cgroupfs`):
    - **`--cgroups=split`, or no flag with `cgroups = "split"` pinned:** `--memory` and `--cpus` are enforced.
    - **`--cgroups=enabled`:** the container stays in the unit's cgroup and nothing is enforced, with or without the pin. The flag overrides the pin.
    - In the account's own `user@` session, with the systemd manager, all three forms enforced. That was tested on AlmaLinux 10.2 only.
    - **On CloudLinux 8.10** (runc), `--cgroups=enabled` failed to start. That is unexplained; it may be the exit-143 race of a foreground `podman run` (Dan, EA4-352 comment 1806527 and EA4-358 comment 1806496).
      **T0.2 explains it:** with runc, a container created without split *and with limits* (`--memory`) can't start from the unit on v2: `runc create failed: … rootless needs no limits + no cgrouppath when no permission is granted for cgroups: mkdir /sys/fs/cgroup/eapodman.slice/eapodman-<uid>.slice/<id>: permission denied` (EL8 v2, podman 4.9.4, runc 1.2.9). crun starts the same container and ignores the limits.
  - **Fix:**
    - **v2 only:** the split pin is conditional on the host's cgroup version, and the pinned file follows the host when the version changes (Phase 1).
    - **One source:** the pinned config is the only source of the cgroups mode and the cgroup manager. `validate_start_args` refuses `--cgroups*`, `--cgroup-parent`, `--cgroup-conf` and the global `--cgroup-manager` (Phase 3b; EA4-358 comment 1806496). ea-podman's own creates never pass `--cgroups`. CPANEL-57893 passes `--cgroups=enabled` for capped containers (`SOURCES/util.pm:511` on `CPANEL-57893-full`; not on `CPANEL-57513` or main). 2.0 drops that flag in Phase 1, next to this pin.
    - **The mode is fixed when a container is created** (P0-4 confirms). A container created before a cgroup switch keeps its old mode until it is recreated (`ea-podman upgrade`):
      - after v1 → v2, it runs without limits;
      - after v2 → v1, it won't start.

      The registry records `cgroup_v` at create, and root's cgroup check names those containers.

      **T0.5 decision: name them, don't recreate them.** T0.2 confirmed the mode is fixed at create (podman 3.4.4, 4.9.3, 4.9.4 and 5.8.2, and a real switch on EL8).
      - **Why root doesn't recreate.** The only recreate path is `ea-podman upgrade --force <name>`; plain `upgrade` skips a container whose image hasn't moved (`_upgrade_is_needed`). That pulls first, so the container can come back on a newer image. It also costs downtime and anonymous volumes. A cgroup switch needs a reboot an admin chose to do, so the admin decides when each container pays that, and nothing changes underneath a running service unasked.
      - **What root reports.** A container whose registry `cgroup_v` doesn't match the host is named, with the remedy `ea-podman upgrade --force <name>`, wherever root reports the cgroup version: `warn_if_not_cgroup_v2` and the root-side status. The wording depends on the direction:
        - **created on v1, host now v2** (the direction EA4-360 recommends): a warning that the container runs, but without its resource limits;
        - **created on v2, host now v1:** an error that the container can't start. START's verdict says the same when the unit fails with `mkdir …/runtime: permission denied` and the registry says v2.
      - **What makes it right again.** A recreate (`upgrade --force`, or the migration's step 6) writes the host's current `cgroup_v` into the registry, so the container stops being named.
      - **On v1 → v2 specifically:** per-container limits never applied on v1 rootless (F12), so these containers lose nothing they had. They just don't gain the limits until recreated.

      **T0.2 confirmed all of this** (P0-4):
      - **Fixed at create on podman 3.4.4, 4.9.3, 4.9.4 and 5.8.2.** A split-created container runs split, with its `memory.max`, under a pinned conf without split. A container created without split stays unsplit (`memory.max` = max) under the split conf.
      - **v1:** a container created under split fails to start on EL8 and CL8 (`mkdir /sys/fs/cgroup/blkio/eapodman.slice/runtime: permission denied`).
      - **A real switch on EL8,** with the pinned conf re-rendered for the new version:
        - **v2 → v1:** the split containers fail to start (`mkdir /sys/fs/cgroup/cpu,cpuacct/…/runtime: permission denied`). Back on v2 they start again, with their limits.
        - **v1 → v2:** the v1 containers start and run with no limits. Rootless podman on v1 drops the limits from the spec at create, so runc's "no limits" rule above doesn't trip.

- **F18: on CloudLinux cgroup v2, a process is in its LVE or in the unit's cgroups, not both** (Chris, EA4-358 comment 1806575; tested on CloudLinux 10, 9.8 and 8.10).
  - **What entering the LVE does:** a process that enters through `PAMName=` (with `pam_lve`) or `lve_wrapper` leaves the unit's cgroup. It moves into the LVE's own cgroup under `lvub` (`/lve.slice/lvub/full/lve<uid>` on the later hosts), outside the account slice:
    - **the slice's limit stops applying:** a slice `MemoryMax=100M` didn't limit a 300M allocation, while the LVE's 1024M limit killed an 1100M one;
    - **podman can't create per-container cgroups there.** The LVE cgroup is root-owned (`mkdir …/lve<uid>/runtime: permission denied`). After a `chown`, crun can't write `memory.max`, because no controller can be enabled in a cgroup that holds processes;
    - **`lve_wrapper` loses the process:** its unit's process survived `systemctl stop`, so systemd had lost track of it. A `PAMName=` unit and a plain unit stopped cleanly.
  - **Why it's a conflict:** plain `User=` units with `Delegate=yes` and cgroupfs stay out of the LVE (F3). So on CloudLinux v2, P0-6's gate (every process inside its LVE) and F7/F12/F13 (the account slice and per-container limits) can't both hold.
  - **It answers EA4-358 comment 1805194.** Without a user manager, the 1.x "CloudLinux + cgroup v2 breaks the user manager" problem moves rather than goes away.
  - **Decision (T0.3, EA4-368 comment 1806876, Chris; confirmed by T0.2): limits win.**
    - **The rule:** on CloudLinux, as everywhere else, ea-podman's containers, anchors and runner transients run outside the account's LVE. The account slice (`MemoryMax`, `TasksMax`, CPU weight) and the per-container limits apply, and the LVE doesn't.
    - **The cost:** these processes don't count against the account's LVE limits (F3).
    - **WHM warning:** the Web Apps plugin shows one on CloudLinux saying so (Phase 6). ea-podman's docs and release notes say the same (Phase 7).
    - **Nothing enters the LVE:** no `PAMName=`, `pam_lve` or `lve_wrapper` in any unit or transient, and no `/etc/pam.d/ea-podman`.
    - **Why not the alternatives:**
      - **LVE wins** costs every slice and per-container limit on v2. T0.2 also showed it can't work through `PAMName=` at all: `pam_lve` either cages a caged account's session (no podman inside) or refuses it. And on v2 the runner's deadline stops reaping.
      - **A per-host choice** would carry both designs and both test matrices.
      - **`lve_wrapper`** loses the process on stop.
    - **What stays open, for the CloudLinux follow-up (EA4-389):** CloudLinux's view of this decision, and a CloudLinux-side change that lets an LVE account for a systemd-delegated subtree. That change would let a later release have both, and it is not a 2.0 blocker.
    - **cgroup v1 (CL8):** the same rule. Slice limits apply there; per-container limits don't, as everywhere on v1 (F12, F17).
  - **cgroup v1 may differ.** LVE and systemd use separate hierarchies there, so LVE membership and the unit's placement may coexist. Per-container limits are unenforced on v1 anyway (F12, F17). P0-6 probes it.
  - **T0.2 (P0-6), CL8 v1, CL9 and CL10:**
    - **v1 does differ.** A `PAMName=ea-podman` unit's process is in `/lve.slice/lve<uid>` for `memory`, `pids` and `cpu,cpuacct`, and in its unit for `name=systemd`, so `systemctl stop` reaches it. The LVE owns the limits there: a slice `MemoryMax=100M` didn't stop a 300M allocation. On v2 the process is wholly in `/lve.slice/lvub/full/lve<uid>`, as above.
    - **`PAMName=` can't run podman for a caged account.** `pam_lve.so 500 1` (CloudLinux's own `su`/`sshd` line) puts the session in CageFS, where `/usr/bin/podman` doesn't exist: the container unit fails with `203/EXEC`. With `500 0`, `pam_lve` refuses the caged account's session (`PAM failed: Permission denied`, `224/PAM`). So option 2 ("LVE wins") doesn't work through `PAMName=` as planned.
    - **`/etc/pam.d/ea-podman` needs an `account` line.** systemd runs the account stack too. Without one it falls through to `/etc/pam.d/other` (`pam_deny`) and every start fails with `224/PAM`. The probe used `account required pam_permit.so`.
    - **The runner loses its deadline on v2.** A `systemd-run --uid -p PAMName=ea-podman -p RuntimeMaxSec=5` transient returned on time (rc 1), but its processes kept running in the LVE cgroup. They are outside the unit's cgroup, so `KillMode=control-group` can't reach them. That breaks 4.2a's guarantee. On v1 they were all killed.

- **F19: SELinux blocks pasta in the runtime tmpfs** (T0.2; EL9 and EL10 enforcing, podman 5.8.2 with pasta). Neither EA4-357's hosts nor the CloudLinux VMs (SELinux disabled) hit this.
  - **The failure:** on a plain tmpfs (`tmpfs_t`), the `netns` dir podman creates is labelled `container_runtime_tmpfs_t`. `pasta_t` may not search that, so every container fails to start: `pasta: Couldn't open network namespace /run/ea-podman/user/<uid>/netns/…: Permission denied`. logind's `/run/user/<uid>` is `user_tmp_t`, which `pasta_t` may use.
  - **Labelling the whole mount `user_tmp_t` doesn't work.** pasta then starts, but PID 1 (`init_t`) may not open a `user_tmp_t` `conmon.pid`, and the unit times out (`Can't convert PID files … O_PATH file descriptor to proper file descriptor: Permission denied`).
  - **Fix (in the kit's `conf/runtime-mount`):** keep the mount `tmpfs_t`, so podman's `conmon.pid` files get `container_runtime_tmpfs_t`, which `init_t` may read. The helper has the account create `netns` (0700) and then labels it `user_tmp_t` (`chcon -h`), so pasta may search and watch it. With this, no AVC denials on EL9 or EL10, pasta exits with its container, and it survives a reboot. Phase 1's anchor helper needs the same step. Open items.
- **F21: a 1.x libpod DB pins its runroot to `/run/user/<uid>`** (T0.2, P0-1). podman takes the runroot and tmpdir recorded in the DB over `XDG_RUNTIME_DIR`, and over an explicit `runroot` in `storage.conf`.
  - **While the 1.x session is up,** the pinned old-storage env (new `XDG_RUNTIME_DIR`) silently uses `/run/user/<uid>/containers`, with no warning.
  - **Once the session ends,** every podman call on the old storage fails: `mkdir /run/user/<uid>: permission denied` (`configure storage:` on 5.x). logind removes `/run/user/<uid>` shortly after `user@` stops (`user-runtime-dir@` is `StopWhenUnneeded`).
  - **Seen on** EL8 v1 and v2, EL9, EL10, Ubuntu 22.04 and 24.04. On CL8 the old DB failed even with the session up (`lstat /run/user/<uid>/libpod: permission denied`, cause not investigated). On CL9/CL10 a 1.x systemd-managed container couldn't be created to test (`crun: error creating systemd unit libpod-*.scope: got failed`, the known CloudLinux v2 user-manager breakage).
  - **Consequence for 4.2a/4.3:** every old-storage step (save, export, inspect) must run while the account's `/run/user/<uid>` still exists, before step 12 releases the session. Otherwise root must provide that directory for the step. Open items.
- **F23: `systemctl set-property … TasksMax=N%` is written as N/10 % on systemd 249–257** (T0.6). `set-property TasksMax=33%` writes `TasksMax=3.3%` into the `system.control` drop-in and applies it: about 700 tasks on these VMs instead of about 7,000.
  - **Where:** systemd 249, 252, 255 and 257 (Ubuntu 22.04 and 24.04, EL9, EL10, CL9, CL10). 239 (EL8, CL8) writes 33%.
  - **Only `TasksMax`:** `MemoryMax=10%`, `MemoryLow=5%` and `CPUQuota=150%` are written and applied correctly. A percentage in a unit file is also correct (`eapodman.slice`'s `TasksMax=33%` resolves to about 7,000).
  - **Fix:** ea-podman never passes a `TasksMax` percentage to `set-property`. It resolves percentages itself to `floor(pct × min(threads-max, pid_max) / 100)`, which is systemd's own base: it matched `user-<uid>.slice` on every VM. `set_slice_properties` accepts `TasksMax` only as digits or `infinity`.
  - **Second pitfall, on systemd 239 (EL8, CL8):** clearing with an empty assignment (`set-property … MemoryLow=`) writes `infinity` for every property. For `MemoryLow` that means full protection, not none. 252 resets to 0 correctly. So `clear_slice_properties` never clears through an empty `set-property`. It removes the property's drop-in from `/etc/systemd/system.control/eapodman-<uid>.slice.d/` and reloads, or writes the explicit default (`MemoryLow=0`).
- **F22: with split pinned, `podman start`/`run` needs a delegated cgroup** (T0.2, P0-8/P0-11). On every v2 host, `podman start` and `podman run --rm` from the non-delegated slice runner fail: `mkdir /sys/fs/cgroup/eapodman.slice/eapodman-<uid>.slice/eapodman-run-…/runtime: permission denied`; `supervisor` on podman 3.4. They work from a `Delegate=yes` transient. On v1 the command succeeds, but the container sits in the runner's transient unit and is killed when that unit ends (`probes/p0-8-v1-start.sh`, both v1 hosts). `podman build` with a `RUN` step works from the plain runner everywhere. So any 2.0 path that starts a container outside its unit needs `Delegate=yes` on the runner, or has to go through the unit. **Decision (T0.8): no 2.0 path does, so the runner stays without `Delegate=`.** CMD runs `nsenter`, not podman subcommands, so the earlier "CMD with `run`" was wrong. Health checks are execs (F24), and `verify_container_started` reads UNIT_SHOW. A container is only ever started by its unit, and any later path that needs one started goes through the unit.
- **F24: podman's health checks need the user manager** (T0.8). Rootless podman schedules a container's health check with `systemd-run --user` when the container starts. 2.0 has no user manager, and every Web Apps container carries a health check: the plugin's `health_args`, whose status the plugin reads to decide restarts.
  - **podman 5.8.2** (EL9, EL10, CL9, CL10): the container **doesn't start** (`create healthcheck: unable to get systemd connection to add healthchecks`), and its unit fails;
  - **podman 3.4.4, 4.9.3 and 4.9.4:** it starts and logs that error, and its checks never run;
  - **with `DISABLE_HC_SYSTEMD=true`** (in podman on all 9): it starts everywhere, but its status stays `starting`;
  - **`podman healthcheck run` from the slice runner** reports `unhealthy` (exit 1) on every crun host, because its exec fails (F20). The plugin would restart healthy apps. On runc it works;
  - **run from a leaf of the unit that root placed it in,** it works on all 9.

  **Decision (T0.8): ea-podman schedules the checks itself, from root, and runs each one inside the container's unit.**
  - **`podman_env` sets `DISABLE_HC_SYSTEMD=true`** for every podman call: the units, the runner, and the migration's old-storage env. So podman never looks for a user manager. 1.x's own health timers go away with the 1.x session (4.3 step 12).
  - **Units:** packaged static templates `ea-podman-health@.timer` and `ea-podman-health@.service`, with the container name as the instance. The timer is `BindsTo=`/`After=` the container's unit and wanted by it, so it runs only while the container runs. Its interval is a root-rendered drop-in (`OnUnitActiveSec=`, digits only). The service runs as root, `Type=oneshot`, with `SuccessExitStatus=1` (unhealthy is a result, not a failure) and a fixed `TimeoutStartSec=90`.
  - **Its `ExecStart`** is a root helper, `/opt/cpanel/ea-podman/bin/health-run <name>`. It checks the name and the unit's marker, refuses unless the unit is active, and moves itself into `<unit cgroup>/ea-podman-health` (v2; the same placement as F20). It then drops to the account with `podman_env` and execs `podman healthcheck run <name>`. Nothing runs a check from anywhere else.
  - **What root schedules** comes from the container's own health check, read as the account (`podman inspect`) and treated as untrusted. Root takes only whether there is one, and its interval, clamped to `health_min_interval` (`runtime.conf`, default 30s). The worst an account can do is get its own check run at that minimum. Root syncs it at UNIT_INSTALL and through a new admin action, `HEALTH_SYNC <name>`, which the plugin calls after its live `podman update` (`apply_stabilization`). `reconcile_units` syncs every unit. A sync only runs on those calls, never on a schedule: the only thing that repeats is the timer's `podman healthcheck run`, one per container per interval.
  - **Refused start args:**
    - `--health-on-failure` other than `none`: its actions would run podman stop, kill or restart from the helper, behind the unit's back;
    - the `--health-startup-*` flags: they need podman to swap timers;
    - `--health-timeout` above 60s, so the service's timeout always covers a check.

    The plugin uses `none` and 10s.
  - **Measured, all 9,** with that template:
    - a passing check reads `healthy` and a failing one `unhealthy` (streak 4) after 35s, and the service succeeds both times;
    - a check that outlives `TimeoutStartSec` is still killed, because systemd signals the service's main PID even after it has left the service's cgroup. On v2 the check's own process in the container runs to its end; podman's `--health-timeout` bounds it.
  - **Cost:** one podman run per container with a check, per interval (Web Apps: 60s).

- **F25: podman takes the account's own `mounts.conf`, and never reads `default_mounts_file`** (PR #43 review, 2026-11-09; P0-8 re-run). Rootless podman applies the first `mounts.conf` that exists: the account's `$HOME/.config/containers/mounts.conf` (found through `$HOME`, so the pinned `XDG_CONFIG_HOME` doesn't cover it), then `/etc/containers/mounts.conf`, then `/usr/share/containers/mounts.conf`. `containers.conf`'s `default_mounts_file` is never read. On all 9 (podman 3.4.4, 4.9.3, 4.9.4 and 5.8.2):
  - the account's file reached its containers at the unit's start, and the RUN steps of a `podman build` from the runner (the plugin's builds);
  - podman reads each entry's source as the account and copies it into the container, so the account can put any host file its uid can read into its own containers. On CL8, CL9 and CL10 that included a file in the host's `/tmp`, outside the cage: for CageFS and jailshell accounts it goes around the home-directory check EA4-343 puts on `-v`;
  - the first P0-8 run reported "ignored" because its check used `podman exec`, which fails from the runner on v2 (F20); the probe now reads the container's OCI spec.

  **Decision (A2): every podman call names root's `mounts.conf`.** podman's global `--default-mounts-file=<file>` is the one thing that decides it. With it, only that file applies, for a unit's start and a build alike (podman 3.4, 4.9 and 5.8).
  - **The file:** root renders `/opt/cpanel/ea-podman/etc/mounts.conf` (root:root 0644) from the first of `/etc/containers/mounts.conf` and `/usr/share/containers/mounts.conf`, or empty when there is neither. So a container gets the distro's mounts, as in 1.x (EL and CloudLinux: `/usr/share/rhel/secrets:/run/secrets`; Ubuntu: none), and nothing of the account's. It is re-rendered together with `containers.conf` (the same three callers and marker check).
  - **The flag:** the unit's `ExecStart`, `ExecStop` and `ExecStopPost`, and every podman argv the runner, the admin module and the migration run, carry `--default-mounts-file=` that file, next to `podman_env`.
  - **`default_mounts_file` is dropped** from `containers.conf`: it does nothing, and podman 3.4 warns on it.
  - **Not chosen:** a `HOME` the account can't write (`rootless_storage_path` is `$HOME`-relative, so the container doesn't start, and podman's other `$HOME` uses would need their own probe), and accepting it (leaves the CageFS/jailshell gap open).
  - **Risk:** the flag is hidden (not in `podman --help`), so a podman update could drop it. The hostile-config live test (Tests) is its canary.
  - **Measured with the kit** (`lib.sh`'s `PODMAN`): p0-8 reports the account's file ignored by a unit's start and by a build, and the distro's entries kept, on all 9.

## Phase 0: spikes (gate everything)

Run each probe on these hosts:
- EL8, on cgroup v1 and on v2;
- EL9 and EL10;
- CL8 on cgroup v1 (its default and EA4-360's recommendation; CloudLinux's default `hidepid=2`, EA4-366), CL9 and CL10, each with CageFS 7.6.39+ masked. CL8 on v2 is EA4-365's matrix, not this one;
- Ubuntu 22.04 (podman 3.4) and 24.04.

**PoC coverage so far** (`EA4-352/eapodman-test-kit`, a hand-built version of the Phase 1 layout for one account).
- **The hosts** (Julian, EA4-357 comment 1803523), each on cgroup v2:

  | OS | podman | OCI runtime |
  |---|---|---|
  | Ubuntu 24.04 | 4.9.3 | crun 1.14.1 |
  | AlmaLinux 8.10 | 4.9.4-rhel | runc |
  | CloudLinux 8 + CageFS (`hidepid=2`) | 4.9.4-rhel | runc |
  | CloudLinux 9 + CageFS | 5.8.2 | crun 1.27 |
  | CloudLinux 10 + CageFS | 5.8.2 | crun 1.30.1 |
  | AlmaLinux 9.8 | 5.8.2 | crun 1.27 |
  | AlmaLinux 10.2 | 5.8.2 | crun 1.30.1 |

  Plus Dan's A8: AlmaLinux 8.10, podman 4.4.1, runc 1.1.4 (EA4-357 comment 1802943).
- **Held on every host:**
  - `user@<uid>` stayed inactive;
  - the PID-file refusal passed (P0-3, invariant 19);
  - the hard memory cap held;
  - the unit's `CPUWeight=` decided CPU share within the account.
- **What the runs found:** F3, F15's version split, F16, and the per-platform floor results in F13.
- **Not covered yet:** a reboot, a second account, `PAMName`, cgroup v1 (Chris covered v1 separately: F17), and the CLI, admin and migration code. Those need product code.

**PoC kit follow-ups.** These feed the task that turns the kit into `t/LiveTests`:
- real pass/fail checks in `loadtest.sh`, and in `verify.sh` where it only prints;
- a second account, a reboot test, and on CloudLinux a check that nothing ea-podman starts is in the LVE (F18; EA4-357 comment 1802943);
- CPU test A assumes 4 CPUs (done in T0.2: with fewer CPUs it measures the caps in two rounds);
- `lifecycle.sh` test 2 (kill the container's init) is v2-only; v1 needs its own check (T0.2);
- the anchor helper's SELinux `netns` step (F19; done in the kit's `conf/runtime-mount`), and `setup.sh` on cgroup v1 (done in T0.2);
- CPU test B's tolerance is loose on some hosts;
- the floor test must skip when its before-values are 0, as they are on CloudLinux (F13; EA4-357 comment 1803523).
- done in the kit (PR #43 bot review 6587031689): guarded signals, F15 counted as known only by its journal signature, the hostile-PID write and systemd's refusal asserted, the F16 `XDG_CONFIG_HOME` layout, `SuccessExitStatus=143` kept in the units with lifecycle test 5 for it (third review), the payload-cgroup and load-liveness checks, the floor skip, and checked cleanup and teardown. The live tests keep these rules.

| # | Probe | Decides |
|---|---|---|
| P0-1 | Use an existing DB with a new `XDG_RUNTIME_DIR` and pinned `CONTAINERS_*`. Do we get an error or a silent fallback? | Confirms recreate-in-fresh-storage |
| P0-2 | Start an old container from a system unit using cgroupfs, for a rootless **and** a rootful container. For rootful, also: does `podman rename` of a stopped container keep its CID and named-volume mounts (podman 3.4 and 4+)? | Recreate required? Rootful in-place branch (4.4). Root's containers are always recreated now, because a 1.x container has no `--conmon-pidfile` (Phase 1), so for rootful only the `rename` question remains |
| P0-3 | Unit shape: `Type=forking` + `podman start` + `PIDFile` of conmon.pid (set with `--conmon-pidfile`), vs `start --attach`. Test stop, Restart, killing conmon, reboot. **So far (all 8 PoC hosts, v2):** Restart recovers from a killed container init everywhere, and from a killed conmon except on podman 4.4.1 and Ubuntu's 4.9.3 (F15); `--conmon-pidfile` works for containers created outside the unit; hostile PIDs are refused (invariant 19). Either shape needs `SuccessExitStatus=143`: in the forking shape conmon is the main process and exits with the container's status, so a PID 1 that exits 143 on SIGTERM would turn a deliberate stop into `failed` (EA4-358 comment 1806496). Kit lifecycle test 5 records, per podman version, whether conmon passes 143 on. **`hidepid=2` (EA4-366):** on CL8 a rootless `podman stop` times out (`timed out waiting for file …/exits/<id>`, exit 125) and the unit ends `failed`, in 1.x too; check what that does to STOP's verdict, to `KillMode` reaping and to the UNIT_REMOVE order, on every target with `hidepid=2`. Does conmon land inside the unit's own cgroup? It must, because systemd refuses a PID read through a path the account owns unless that PID is in the unit's cgroup. Also: write `1`, and the PID of a root process, into `conmon.pid`; systemd must refuse both, and `systemctl stop` must kill neither. With `--cgroups=split`, a container *created* outside the unit (by the migration runner or the admin runner) and *started* by the forking unit: do conmon and the container land in sub-cgroups of the unit's cgroup (podman 3.4 and 4+)? | Template |
| P0-4 | `Delegate=yes` + cgroupfs on v1/v2. Where do conmon and the pause process land? Does stopping one unit hurt the account's other containers? Do container cgroups under `eapodman-<uid>.slice` receive delegated controllers on v2? Does `MemoryLow` on the account slice protect under memory pressure when `eapodman.slice` carries the sum of the floors? Is today's floor on `user-<uid>.slice` effective (`user.slice` has no `MemoryLow`)? Under CPU contention, do all container accounts together get no more than one `user.slice`-sized share against `system.slice`? Are the `memory` and `cpu` controllers in `cgroup.subtree_control` of `eapodman.slice`, `eapodman-<uid>.slice` and the unit, and received by the container cgroup? Is `--memory` enforced with split and not without it? Does every target have `memory.swap.max` (swap accounting), and is `--memory-swap` equal to `--memory` enforced as `memory.swap.max=0`? Does `--memory-reservation` protect a container under memory pressure with and without `MemoryLow=` on its unit, on EL8 (no `memory_recursiveprot`) and on EL9+? What `cpu.weight` does each target's OCI runtime (crun or runc) write for `--cpu-shares=1024` (39 or 100, by the OCI runtime's version; see the P0-4 results), and under contention do two containers of one account split CPU by their units' `CPUWeight=` (EA4-357: yes on all 8 hosts)? Is page cache charged to the writer's cgroup on CloudLinux (EA4-357: no on CL8/9/10), and on which kernels does a unit's `MemoryLow=` hold (F13)? **F17:** is the cgroups mode recorded at create (podman 3.4, 4 and 5), so that after a v1 → v2 or v2 → v1 reboot an existing container keeps its old mode? Does a split container fail to start on v1 on every target? The plugin is waiting on these answers (EA4-352 comment 1801665) | Anchor unit; parent slice values; plugin limits; F17 recreate rule |
| P0-5 | Journald routing of `User=` unit output; where `podman logs` goes; whether `events_logger="journald"` works from a system unit with `User=` on every target | Messages/docs; events logger |
| P0-6 | **Decided (T0.3): F18 "limits win"; nothing ea-podman starts enters the LVE. The gate is no longer "every process inside its LVE".** Probe history:  Answered so far on v2: without help, nothing ea-podman starts is in the LVE (F3, CL8/9/10); with `PAMName=` or `lve_wrapper` the process leaves the unit's cgroup for the LVE's, so the slice and per-container limits stop applying, and `lve_wrapper` loses track of the process on `systemctl stop` (F18, CL8.10/9.8/10). Still to probe: the same on **cgroup v1**, where LVE and systemd use separate hierarchies (is a `PAMName=` unit's process in `lve<uid>` *and* in its unit's cgroup, and does `systemctl stop` still reach it?); the `systemd-run --uid` transients (the migration runner and the plugin's builds) with `-p PAMName=ea-podman`; with a `PAMName=` unit on v2, does systemd keep tracking conmon and the container through stop, restart and reboot? T0.2 ran the v1 and transient probes (F18) | F3, F18: the account slice owns account totals on CloudLinux |
| P0-7 | A caged account's container running from a system unit; does the CLI admin fallback still work? | CageFS parity |
| P0-8 | `CONTAINERS_CONF` semantics on podman 3.4 vs 4+; is user config fully ignored? With `XDG_CONFIG_HOME` set to the per-account root-owned dir that holds only the `cni` symlink (F16): do podman 3.4 (CNI), 4.x (CNI and netavark) and 5.x work, and is nothing else under it created or read? | Pinned conf shape; F16 |
| P0-9 | Can a non-root user run `systemctl show` on a system unit on CloudLinux? | STATUS always goes through admin (expected) |
| P0-10 | The CLOS-7971 canary (`test.sh`) after migration and after reboot: it must never run, and no `user@<uid>` may exist | Acceptance |
| P0-11 | The bounded as-user runner (4.2a): `systemd-run --uid --gid --pipe --wait --collect -p RuntimeMaxSec=` running `podman` against old **and** new storage. On a timeout, does systemd reap a SIGSTOPped child, a ptrace-stopped child, and a grandchild that called `setsid`/double-forked? How does `systemd-run --wait` report `Result=timeout` vs a non-zero exit (systemd 239, 249, 252, 255)? On v1, can the account move a runner process into its own delegated cgroup, and does `--wait` still return? | Runner mechanism; timeout detection |
| P0-13 | `podman exec` cgroup placement (F14), on every target (podman 3.4 and 4+, crun and runc versions). From the slice runner: is the exec'd process in the runner's transient (not the container's cgroup), under `eapodman-<uid>.slice`, inside the LVE (P0-6), and killed at `RuntimeMaxSec`? 1.x parity, on an unmasked 1.x account: is a `podman exec` from an SSH session in the session scope rather than the container's cgroup? | F14 docs and release-note wording |
| P0-12 | BPF-LSM namespace boundary (F11), on EL9, CL9, EL10 and Ubuntu 24.04. Does the kernel have the `userns_create` LSM hook, and can `lsm=bpf` be enabled? Load a test-only BPF-LSM program that denies `userns_create` unless the task is under the `eapodman.slice` cgroup. Then all of these must work: install, upgrade, start/stop/restart, reboot, the full migration, plugin builds, backup and restore, `ea-podman bash`, and an anchor restart after the pause process is killed. From the account's SSH shell, cron and a CGI, `unshare -U` and raw `podman run` must be denied | F11 holds; platforms where the rule is supported |

### Phase 0 results (T0.2, 2026-11-06)

**How.** Run on the 9 VMs in `EA4-352/vms.json`:

| VM | OS | cgroup | systemd | podman | OCI runtime | Notes |
|---|---|---|---|---|---|---|
| el8-cgv1, el8-cgv2 | AlmaLinux 8.10 | v1, v2 | 239 | 4.9.4-rhel | runc 1.2.9 | SELinux enforcing |
| el9 | AlmaLinux 9.8 | v2 | 252 | 5.8.2 | crun 1.27 | SELinux enforcing, MGLRU |
| el10 | AlmaLinux 10.2 | v2 | 257 | 5.8.2 | crun 1.30.1 | SELinux enforcing, MGLRU |
| cl8-cgv1 | CloudLinux 8.10 | v1 | 239 | 4.9.4-rhel | runc 1.2.9 | CageFS, `hidepid=2` |
| cl9 | CloudLinux 9.8 | v2 | 252 | 5.8.2 | crun 1.27 | CageFS, `hidepid=invisible`, MGLRU |
| cl10 | CloudLinux 10 | v2 | 257 | 5.8.2 | crun 1.30.1 | CageFS, MGLRU |
| u22 | Ubuntu 22.04 | v2 | 249 | 3.4.4 | crun 0.17 | |
| u24 | Ubuntu 24.04 | v2 | 255 | 4.9.3 | crun 1.14.1 | MGLRU |

- **Setup:** one test account (`eapodtest`) with the kit's layout (`eapodman-test-kit/setup.sh`, now v1-capable) and three containers.
- **Probes:** in `EA4-352/probes/` (`p0-*.sh`, `f17-switch.sh`, sourcing the kit's `lib.sh`). Per-host logs are in `EA4-352/probes/results/<vm>/`.
- **Limits:** none of the VMs has cPanel or ea-podman, so the parts that need product code are marked "not run" below. "1.x" means the account's own `user@` session and default storage, emulated by hand (on CloudLinux through a `/run/systemd/system/user@<uid>.service` copy, as EA4-321 does).
- **CL10:** ships `user.max_user_namespaces=0` (CLOS-2616, confirmed). The probes set it to 15000 in `/etc/sysctl.d/99-ea4-352-userns.conf`.
- **Ubuntu 24.04:** got `lsm=…,bpf` on its kernel command line for P0-12.

**New findings:** F19 (SELinux and pasta), F20 (exec on crun), F21 (the 1.x DB pins its runroot), F22 (split needs a delegated cgroup to start a container). F13, F14, F15, F17 and F18 have T0.2 notes.

- **P0-1: an error, not a silent fallback, once the session is gone** (F21).
  - **Session still up:** the pinned env silently uses the 1.x DB's runroot under `/run/user/<uid>`.
  - **Session gone:** `mkdir /run/user/<uid>: permission denied`, even with an explicit `runroot`.
  - **Verdict:** recreate-in-fresh-storage is confirmed. The migration's old-storage steps must run before the session is released.
- **P0-2: recreate is required on v2.**
  - **Rootless 1.x containers** (recorded `CgroupManager=systemd` on every v2 host) don't start from a cgroupfs system unit, even with the session up. crun 1.14+: `sd-bus call: Interactive authentication required`. crun 0.17: `sd-bus call: Permission denied`. runc on EL8 v2: `unable to apply cgroup configuration`.
  - **On v1** they are cgroupfs, and one started in the unit's cgroup and served (EL8 v1).
  - **Rootful:** `podman rename` of a stopped container keeps its ID and named-volume mounts on 3.4.4, 4.9.3, 4.9.4 and 5.8.2. A 1.x rootful container started from a cgroupfs unit runs, but in `/machine.slice/libpod-<id>.scope`, outside the unit and `eapodman-0.slice`. So recreate, as planned.
- **P0-3: the forking template holds; F15's matrix is extended.** Kit `lifecycle.sh` and `p0-3-hidepid.sh`, all 9:
  - **Hostile PIDs:** `1` and a root PID in `conmon.pid` are refused, systemd logs it, and stop kills neither. Holds on systemd 239, 249, 252, 255 and 257, v1 included (invariant 19).
  - **Exit 143:** conmon passes it on everywhere, so `SuccessExitStatus=143` is needed on all 9.
  - **A killed container init** recovers.
  - **A killed conmon:** see F15 (Ubuntu 22.04 loses the port, Ubuntu 24.04 stays down).
  - **conmon's cgroup:** `<unit>/runtime` on v2 (`<unit>/supervisor` on podman 3.4), and the unit's own cgroup on v1, where the container has a cgroup of its own only in `name=systemd`.
  - **`hidepid=2` (CL8) and `hidepid=invisible` (CL9):** a unit stop ends `Result=success` in at most 1 s, with no `timed out waiting for file …/exits` and nothing left for `KillMode`, and `podman rm` after the stop works. EA4-366's stop timeout doesn't happen in the 2.0 layout.
  - **Reboot, all 9:** the anchor, tmpfs, XDG dir, all three units (conmon as `MainPID` in the unit's cgroup, split payloads on v2), the ports and the slice drop-ins came back by themselves.
  - **Not run:** the `start --attach` shape. (T0.4 then ran F15 under 1.x: same failure, see F15.) The kit's test 2 (kill the container init) is v2-only and didn't run on v1.
- **P0-4: the layout works as designed. Memory floors are kernel-dependent** (F13), and **F17 is confirmed** (see F17).
  - **Placement:** the pause process sits in `ea-podman-runtime@<uid>.service`.
  - **Isolation:** stopping one unit leaves the others and the pause process alone.
  - **Controllers:** `cpu io memory pids` in `cgroup.subtree_control` of `eapodman.slice`, `eapodman-<uid>.slice` and the unit, and received by the container (all v2).
  - **Swap:** no VM has swap configured. `memory.swap.max` exists on every v2 host and is `0` for `--memory-swap` = `--memory` (`memory.memsw.*` exists on v1). Enforcement with real swap was not measured.
  - **Shares conversion** for `--cpu-shares` 1024/2048/512: `cpu.weight` 100/174/59 with crun 1.27 and 1.30.1. It is 39/79/20 with runc 1.2.9, crun 1.14.1 and crun 0.17. So it follows the OCI runtime version, not podman's.
  - **Caps** (kit `loadtest.sh`; CPU test A now runs in two rounds on hosts with fewer than 4 CPUs): `--cpus` exact at 1.00/2.00/0.50 on all 7 v2 hosts. The 512M hard cap held: 400M fine, 600M OOM-killed (137), `swap.current` 0. With the slice capped to 1 CPU, the unit `CPUWeight` decided the split (≈0.29/0.57/0.14).
  - **Equal unit weights:** the split was ≈⅓ each on most hosts, but noisy on EL9 (0.28/0.53/0.19) and Ubuntu 22.04 (0.13/0.73/0.13), not investigated.
  - **CPU between slices:** with 3 busy loops each in `system.slice`, `user-<uid>.slice` and two account slices, the shares were system 33%, user 33%, `eapodman.slice` 33% (16 + 16) on all 9, v1 and CloudLinux included. All container accounts together get one `user.slice`-sized share.
  - **Floors against host-wide pressure:** see F13 (MGLRU). Today's floor on `user-<uid>.slice` doesn't work: with `user.slice` at no floor, a 400M floor kept 4%, the same as none. On CloudLinux, page cache isn't charged to the reader, so there is nothing to protect (F13; 0M on CL8, CL9 and CL10).
- **P0-5: journald works for writing. Reading it back as the account needs a persistent journal.**
  - **Unit output:** a `User=` unit's output (podman, plus conmon on Ubuntu) is in `journalctl -u` everywhere.
  - **Default log driver:** `k8s-file` on EL and CloudLinux, `journald` on Ubuntu. `podman logs` works as the account through the runner on all 9.
  - **EL and CloudLinux** have a volatile journal (no `/var/log/journal`), so there are no per-user journal files. As the account, `podman events` and `podman logs` of a `--log-driver=journald` container return **nothing, with exit 0**, though root sees the entries. Ubuntu (persistent, split per uid) works.
  - **Impact:** ea-podman reads neither.
  - **T0.6 correction:** 1.x does *not* have this gap. Its podman reads the distro's own config: on EL and CloudLinux that is `events_logger = "file"` (and log driver `k8s-file`), so the account reads its events back; on Ubuntu, `journald`. The plan's "journald is the 1.x default" held only on Ubuntu, so pinning `journald` everywhere would regress `podman events` on EL and CloudLinux.
  - **Verdict (T0.6):** pin what each distro's podman uses: `events_logger = "file"` with `events_logfile_max_size = "1m"`, and `log_driver = "k8s-file"`, on EL and CloudLinux; `journald` for both on Ubuntu. The events file lives in the capped runtime tmpfs and rotates (a 1.2 MB file dropped to about 600 KB on the next event, podman 4.9.4 and 5.8.2). With this, `podman events` and `podman logs` work as the account on all 9 VMs.
- **T0.6 measurements** (`probes/t0-6.sh`, `p0-4.sh floor` with `FLOOR=min`, logs in `probes/results/`):
  - **nproc:** `DefaultLimitNPROC` is 10.5k–11.7k on these 3 GB VMs (`threads-max / 2`). The 1.x user manager runs with exactly that on all 9.
  - **The nproc pin:** podman 3.4.4, 4.9.3, 4.9.4 and 5.8.2 all start a container at the unit's `LimitNPROC`, whether or not create pinned `--ulimit nproc`. Created through the runner, nothing bakes a value the unit can't honour (CPANEL-54037 needed cpsrvd's unlimited creator).
  - **Tasks:** systemd's base for `TasksMax=%` is `threads-max` (about 21–23k). `user-<uid>.slice` is 33% (about 7k) on EL9+, CL9+ and Ubuntu, and 80% on EL8/CL8 (RHEL 8's `user-.slice` default). `DefaultTasksMax` is 80% on EL and CloudLinux, 15% on Ubuntu.
  - **Fork storm:** with the unit's `LimitNPROC` at `infinity`, the account slice's `TasksMax` stopped a fork storm exactly at the limit on all 9 (99 of 400 forks).
  - **Runtime dir:** 1.x's `/run/user/<uid>` is `size=10%` of RAM, plus `nr_inodes=size/4096` on systemd ≥ 246 (none on 239). The 2.0 tmpfs held 92–208 KiB and 66–91 inodes with three containers.
  - **Units:** 3,000 extra enabled units added 0.5 s (EL8, systemd 239) to 1 s (EL10, 257) to a `daemon-reload` and 8–13 MiB to PID 1, about 0.2–0.3 ms and 3–4 KiB per unit.
  - **Swap:** accounting exists on all 9 (`memory.swap.max` on v2, `memory.memsw.*` on v1). With a real 1G swap file on EL8 v2, EL9 and Ubuntu 24.04:
    - `--memory=256m --memory-swap=256m` gives `swap.max=0`, and a 400M allocation is OOM-killed with no swap used;
    - `--memory-swap=768m` lets it succeed with about 160 MiB swapped.
  - **Exit codes:** `podman run --rm` and `podman wait` exit codes are right on all 9, so nothing functional depends on the journal.
  - **IO:** every VM disk runs `none` or `mq-deadline`, so `IOWeight=` has no effect there (it needs BFQ or `io.cost`).
- **P0-6:** see F18. On v1, LVE and unit tracking coexist. For caged accounts `PAMName=` can't run podman. The PAM file needs an `account` line. On v2 the runner loses its deadline.
  - **Not run:** a `PAMName` container through restart and reboot (none would start), and `lve_wrapper` on v1.
- **P0-7 (partial):**
  - **Containers:** a caged account's containers run from system units on CL8, CL9 and CL10, including after a reboot.
  - **From inside the cage:** there is no `systemctl` and no `podman`. `/run/ea-podman` and the unit files aren't visible. The account's own conmon is visible only where `/proc` has no `hidepid` (CL10). The ports are reachable.
  - **Not run:** the CLI admin fallback (needs ea-podman 2.0).
- **P0-8: the account's config is ignored except its `mounts.conf` (F25); F16's layout works on every podman version.**
  - **Hostile `~/.config/containers` ignored on all 9** (podman 3.4.4, 4.9.3, 4.9.4 and 5.8.2; CNI and netavark). It held `containers.conf` (cgroup manager, events logger, env, log driver), a `containers.conf.d` drop-in, `storage.conf` (vfs, another graphroot), `registries.conf`, a reject-all `policy.json` and `mounts.conf`. strace shows no opens under `~/.config` while `podman ps` runs. `podman ps` never reads `mounts.conf`, so that trace says nothing about it; the next item covers it.
  - **Except `mounts.conf` (F25, corrected 2026-11-09):** it reaches the container on all 9, even with `default_mounts_file` pinned. This run first said "ignored" because its check used `podman exec`, which fails from the runner on v2 (F20); three hosts' logs had said "NO" all along. With F25's `--default-mounts-file` it is ignored on all 9, by builds too.
  - **Start on v1 (2026-11-10, PR #43 review):** `cl8-cgv1/p0-8.log` shows both starts failing. It is the probe's order, not the layout. p0-8 starts the container from the plain runner first, and on v1 that container is in the runner's transient unit, so it is killed when the unit ends. When that leaves podman's state at `running` (the runner then returns 1), the unit start that follows fails with `conmon exited prematurely`. `probes/p0-8-v1-start.sh` on both v1 hosts: a unit start alone worked 3 of 3; after a runner start it failed 2 of 6 on CL8 and 3 of 6 on EL8, each time after a runner start that returned 1, and a 5 s wait didn't help. The journal of a failing run is in `results/ea4-352-cl8-cgv1/p0-8-rerun.journal`. That host's env, drop-in and `mounts.conf` verdicts stand: they are read from the OCI spec, which the first start wrote. No 2.0 path starts a container from the runner (F22).
  - **`XDG_CONFIG_HOME`:** nothing new appears there. Only `cni/net.d` (and `cni.lock` or the conflist) is written through the symlink: on the CNI hosts, and also on CL9 and Ubuntu 24.04.
  - **podman 3.4.4** doesn't know `default_mounts_file` and warns on every call (`Failed to decode the keys ["containers.default_mounts_file"]`). No podman version reads it (F25), so 2.0 drops it everywhere.
  - **F22** was found here.
- **P0-9: confirmed.** On CL8, CL9 and CL10 the account's `systemctl show` on the system unit gets `Access denied` even outside the cage, and inside it there is no `systemctl`. Other hosts allow it. STATUS goes through admin.
- **P0-10:**
  - **Reboot:** a CLOS-7971 stand-in canary (a unit in `~/.config/systemd/user`, enabled for `default.target`; `test.sh` isn't in the repo) never ran after a reboot on all 9. On its own that shows little: the kit sets no linger, and without linger or a login no host starts `user@<uid>` at boot (the CloudLinux hosts also mask it), so the canary couldn't have run. What it shows is that the 2.0 layout adds no linger and no `user@`. The evidence is the other lines: no `user@<uid>`, no `/run/systemd/system/user@*` and no linger.
  - **Not run:** after a migration. That is where the canary can fail: 1.x leaves linger on, so on a host that doesn't mask `user@` it runs after a reboot if the migration leaves linger behind. On the masked CloudLinux hosts it can't run either way, and the linger and carveout checks are the test.
- **P0-11: the runner mechanism holds.**
  - **Exit reporting:** identical on systemd 239, 249, 252, 255 and 257. Success gives rc 0. An exit 7 gives rc 7 with `Finished with result: exit-code`. A timeout gives **rc 1** with `Finished with result: timeout` and `Main processes terminated with: code=killed, status=15/TERM`. rc 1 alone is ambiguous, so detect the timeout from the `Finished with result:` line, which needs `systemd-run` without `--quiet`, or from the unit's `Result`.
  - **Reaping:** a SIGSTOPped child, a ptrace-stopped child, a `setsid -f` grandchild and a double-forked grandchild were all killed at `RuntimeMaxSec` on all 9.
  - **Escape on v2:** the account can't move a runner process into its delegated container cgroup (`EACCES`, or `EIO` on Ubuntu).
  - **Escape on v1** (EL8, CL8): it can move a child into the unit's `name=systemd` cgroup, which `Delegate` chowns to it, but not into `memory`/`pids`/`cpu`. `--wait` still returns at the deadline. The moved child survives, still in the runner's stale `pids`/`memory` cgroups, until that container unit stops. It also **keeps the `--pipe` stdout open**, so a reader that waits for EOF hangs. The runner must stop reading when `systemd-run` exits.
  - **SELinux** (EL): PID 1 may not write to a `/tmp` file passed as stdout through `--pipe`; `systemd-run` fails with `Connection timed out` or `Remote peer disconnected`. Use pipes, as 4.2a already says.
- **P0-12: supported on EL10, CL10 and Ubuntu 24.04. Not on EL8, CL8, EL9, CL9 or Ubuntu 22.04.**
  - **The hook:** `userns_create` exists on EL10 and CL10 (6.12) and Ubuntu 24.04 (6.8). EL8 and CL8 (4.18), EL9 and CL9 (5.14) and Ubuntu 22.04 (5.15) don't (the last three measured on the 2026-11-09 re-run; this said 22.04 had it, untested).
  - **`bpf` in the LSM list:** active by default on EL and CloudLinux, EL8 and CL8 included. Ubuntu needs `lsm=…,bpf` and a reboot (22.04's default list: `lockdown,capability,landlock,yama,apparmor`).
  - **The test program** (`probes/p0-12/userns_guard.bpf.c`, loaded with `bpftool prog loadall … autoattach`) denies userns creation outside `eapodman.slice` to uid >= 1000 (`MIN_UID`, default 1000; the probe doesn't change it). Root and every system account below 1000 are allowed everywhere, so the results below say nothing about `nobody`, `apache`, `mailnull` or `www-data`, or about a host with `UID_MIN=500`.
  - **Still worked:** the runner's `podman unshare`, unit restarts, an anchor restart after the pause process was killed, create and start, a `podman build` in a delegated runner, and a nested userns inside a container.
  - **Denied** on all three: `unshare -U` from a `system.slice` (cron-like) job and from `user-<uid>.slice`. From the account's login shell, `unshare -U` and raw `podman run` were denied on EL10 and Ubuntu 24.04. CL10's caged shell has neither binary. Root is unaffected.
  - **Not run:** install, upgrade, migration, plugin builds, backup and restore, and `ea-podman bash` (product code). The program doesn't survive a reboot; a shipped policy would need a loader unit.
- **P0-13:** see F14 and F20.
  - **From the runner:** fails on every crun host. On runc it works, outside the container's cgroup on v2 and in it on v1.
  - **From inside the unit's subtree:** works on all 9, in the container's cgroup.
  - **1.x:** an exec lands in the container's cgroup on every unmasked host.
  - **LVE:** an exec'd process is never in the LVE (CloudLinux).
  - **Deadline:** where exec works from the runner, `RuntimeMaxSec` kills it.
- **T0.8 (2026-11-09, `probes/t0-8.sh bash|health|ptrace`, all 9):** `ea-podman bash` with root's placement (F20), health checks (F24), and ptrace (F11). Logs are in `results/<vm>/t0-8-*.log`.

## Phase 1: root-side units module

**New module: `SOURCES/lib/ea_podman/units.pm`.**
- Add it to the spec Source/install/`%files` and to `debify/debian/ea-podman.install`.
- Load it with the guarded sibling-require used for `subids.pm` (`util.pm:92-100`).

**Pinned config, root:root 0644 under `/opt/cpanel/ea-podman/etc/`:**
- `containers.conf`: `cgroup_manager="cgroupfs"`, `cgroups="split"` **on cgroup v2 only** (F12, F17), `events_logger` and `log_driver` as each distro's own podman uses them (T0.6, 1.x parity): `"file"` with `events_logfile_max_size = "1m"` and `log_driver = "k8s-file"` on EL and CloudLinux, `"journald"` for both on Ubuntu. Also explicit `runtime` and `conmon_path`, and `hooks_dir=[]`. No `default_mounts_file`: podman never reads it (F25).
- `mounts.conf` (F25): root's copy of the distro's (`/etc/containers/mounts.conf`, else `/usr/share/containers/mounts.conf`, else empty), re-rendered with `containers.conf`. Every podman command line names it with `--default-mounts-file`, so the account's `~/.config/containers/mounts.conf` is never used. The events file lives in the capped runtime tmpfs (F8).
- **`containers.conf` follows the host's cgroup version (F17).**
  - **How it is rendered:** root renders it from fixed text in code. The `cgroups = "split"` line is present only when `/sys/fs/cgroup/cgroup.controllers` exists, and a marker line records the version it was rendered for.
  - **Atomic rewrite:** a tmp file, fsync, then rename, so a podman reading it mid-change sees the old or the new file, never half of one.
  - **When it is checked:** the package scriptlets, `ensure_runtime`, and the anchor's root helper (below) each re-render it when the marker doesn't match the host. A cgroup switch needs a reboot, and every container unit `Requires=` its anchor, so after a switch the first container start re-renders the file first.
  - **Old containers keep their mode:** the mode is fixed at create, so containers created under the other version keep it until they are recreated (F17). The registry records `cgroup_v` (below), and root's cgroup check names them, with `ea-podman upgrade --force <name>` as the remedy (T0.5; never an automatic recreate).
- `storage.conf`: `rootless_storage_path` = `~/.local/share/ea-podman/storage`.
- `old-storage.conf` and `old-containers.conf`, for the migration only (4.2a): the 1.x graphroot (`~/.local/share/containers/storage`) with the same pinned runtime, conmon and hooks, and the same `--default-mounts-file` (F25). The migration never runs podman under the account's own `containers.conf`.
- A registries reference.
- Every podman invocation gets `CONTAINERS_CONF` / `CONTAINERS_STORAGE_CONF` / `CONTAINERS_REGISTRIES_CONF` pointing at these files, through a new `podman_env($uid)`. That covers the units, the CLI, the admin module and the plugin. Every podman command line also carries `--default-mounts-file` (F25). `podman_env` also clears `CONTAINERS_CONF_OVERRIDE`, sets `DISABLE_HC_SYSTEMD=true` (F24), and sets `XDG_CONFIG_HOME` to the root-owned per-account directory `/run/ea-podman/xdg/<uid>` (root:root 0755).
  - **Nothing account-controlled is read from it.** It holds nothing but a root-owned symlink `cni` → `/run/ea-podman/user/<uid>/cni`, so neither `containers.conf.d` drop-ins nor the account's `policy.json` or `registries.d` are read.
  - **Why the symlink:** rootless CNI (podman 3.4, and EL8's 4.x default) must be able to create `$XDG_CONFIG_HOME/cni`. The symlink lets it, and its writes land in the capped runtime tmpfs (F16, F8).
  - P0-8 confirms this per podman version.

**Anchor unit: `/usr/lib/systemd/system/ea-podman-runtime@.service`.** This is a static template shipped in the package, with the instance being the uid:
- `User=%i`
- `ExecStartPre=+/opt/cpanel/ea-podman/bin/runtime-mount %i`. This is a root-owned helper and the only privileged Exec line in any ea-podman unit. It is allowed because the anchor is fixed packaged text, never rendered. The helper:
  - accepts only a numeric `%i` that `getpwuid` resolves, and is not 0;
  - creates `/run/ea-podman/user/<uid>` (root parents, 0755) unless it exists, refusing a symlink or a non-directory;
  - mounts a tmpfs on it unless one is already mounted there: `size=` and `nr_inodes=` from root-owned `/opt/cpanel/ea-podman/etc/runtime.conf`. The defaults are logind's: `size` = 10% of RAM, resolved to bytes, and `nr_inodes` = size / 4096 (T0.6), `mode=0700`, `uid=`, `gid=`, `nosuid`, `nodev`;
  - creates `/run/ea-podman/xdg/<uid>` (root:root 0755) and its root-owned `cni` symlink into the tmpfs (F16), replacing anything else found there;
  - never creates, chowns or chmods anything inside the tmpfs, which the account owns and can rearrange between any two of the helper's steps. It has the account create `cni` (F16) and `netns` (F19) there (`setpriv` to the uid), and its one root change inside is `chcon -h -t user_tmp_t` on `netns` (F19), which labels that entry itself and never follows a symlink;
  - re-renders the pinned `containers.conf` if its cgroup-version marker doesn't match the host (F17). This is fixed text with no input from the account.

  This replaces `RuntimeDirectory=`. Its pages are charged to the writer's memory cgroup, as `/run/user/<uid>` is in 1.x. `release_runtime` and the account-removal hooks unmount it, then remove the directory and `/run/ea-podman/xdg/<uid>` (F8).
- `Delegate=yes`
- the pinned environment
- `ExecStart`: `podman unshare /bin/true`, so it holds the pause process (per P0-4)
- `Type=oneshot`, `RemainAfterExit=yes`
- explicit `TimeoutStartSec=` and `TimeoutStopSec=`. A oneshot's start timeout defaults to infinity, and its `ExecStart` runs as the account, so without them a root `systemctl start` of the anchor could be held open by the account (4.2a).
- `Slice=eapodman-%i.slice` (see below)
- No `PAMName=` (F18 decided for the limits). The same holds for the container units and the `systemd-run --uid` transients.

**Container unit: `/etc/systemd/system/ea-podman-<name>.service`.**
- Rendered from a **fixed template in code**. The only substituted values are `{NAME}`, `{USER}`, `{GROUP}`, `{UID}`, `{NPROC}`, `{MEMLOW}` and `{CPUWEIGHT}`.
- A marker line records `owner`, `uid` and `container`.
- `Requires=`/`After=` the anchor unit.
- `Type=forking`. `ExecStart`/`ExecStop` are `podman --cgroup-manager=cgroupfs start {NAME}` / `stop -t 10 {NAME}`. As in 1.x's generated units, there is also `ExecStopPost=` (the same `stop`) and `Environment=PODMAN_SYSTEMD_UNIT=%n`.
  - **`SuccessExitStatus=143` stays**, from `%container_unit_directives`. It isn't only about a foreground podman. conmon, the main process, exits with the container's status, so a PID 1 that exits 143 on SIGTERM (a JVM, or catatonit forwarding the signal) would turn a deliberate stop into `failed`. 1.x added it for this same forking shape (`0459147`, CPANEL-55871). 137 stays out because it is also an OOM kill. Kit lifecycle test 5 checks it (EA4-358 comment 1806496).
- **The unit names the container, never its CID.** A recreate (upgrade, migration) then needs no unit rewrite, and the unit reads like 1.x's.
- `PIDFile=/run/ea-podman/user/{UID}/{NAME}.conmon.pid`. Root chooses this path, and the as-user create sets it with `podman create --conmon-pidfile` (`units::conmon_pidfile($uid, $name)`, Phase 3). Root never takes the path from `podman inspect`, which reads the account's libpod DB (F4).
  - The account can still change where conmon writes, through its DB or by recreating the container with raw podman. The unit then finds no PID file and fails to start; that only harms the account. A PID it writes there that is outside the unit's cgroup is refused (invariant 19).
  - Rootful containers use `/run/ea-podman-{NAME}.conmon.pid`, directly under root-owned `/run`.
- `LimitNPROC={NPROC}`: the host's `DefaultLimitNPROC` (`systemctl show -p DefaultLimitNPROC`), or `infinity` if that is what it says (T0.6). 1.x's user manager ran with exactly this on every target. The account-wide bound is the slice's `TasksMax`, not this.
- `Delegate=`, written as the explicit list `cpu io memory pids` (plus `cpuset` where systemd is 244 or newer; EL8's 239 can't delegate it, so `--cpuset-cpus` is not supported there). This is the same as `Delegate=yes` today, but makes it clear what the account receives.
- `MemoryLow={MEMLOW}` and `CPUWeight={CPUWEIGHT}` (F13). Without them, a container's `--memory-reservation` and `--cpu-shares` are written into its cgroup but do nothing.
  - The values come from the validated install args (`--memory-reservation`, `--cpu-shares`), recorded in the registry entry as `memory_low` and `cpu_weight` at `REGISTER`. Root never reads them back from the libpod DB, which the account owns (F4).
  - `{MEMLOW}` is the reservation in bytes; with no reservation it is `0`.
  - `{CPUWEIGHT}` is `shares * 100 / 1024`, rounded and clamped to 1..10000 (systemd's own shares-to-weight mapping); with no `--cpu-shares` it is `100`, systemd's default.
  - No `MemoryMax=` or `CPUQuota=` on the unit. The container's own caps are in its cgroup, and a smaller unit value would silently override them.
- `Slice=eapodman-{UID}.slice`.
- Restart values come from `%container_unit_directives` (`util.pm:704`). Keep it as the single source so that `container_unit_settle_ceiling_sec` (`util.pm:1116`) still works.
- Explicit `TimeoutStartSec=` and `TimeoutStopSec=`, added to `%container_unit_directives`. `ExecStart`/`ExecStop` run as the account, and root runs `systemctl start`/`stop` on these units while holding the account lock (4.2 rule 2, 4.3 step 8). These timeouts are what bound those calls (4.2a).
- `WantedBy=multi-user.target`.
- There are **no** `+`/`!` Exec prefixes, `PermissionsStartOnly`, or root `ExecStartPre`/`Post`.
- **Name namespace.** Container units are always `ea-podman-<name>.service`, where `<name>` matches the container-name regex and so always contains `.<user>.NN`. No ea-podman-internal unit starts with `ea-podman-`: the slice runner's transient units are `eapodman-run-<uid>-<label>-<seq>.service`, the migration's are `eapodman-migrate-<uid>-<step>-<seq>.service` (4.2a), and the slices are `eapodman.slice` / `eapodman-<uid>.slice`. Code that looks for internal units matches a strict regex, never a glob, so an account can't name a container to match one.
- Root's own (rootful) containers get a variant without `User=` or the runtime-dir settings, with `Slice=eapodman-0.slice`, so a namespace rule (F11) needs no exception for ea-podman's own containers.

**Slice runner (F11): `run_as_user_in_slice($user, $label, $timeout, %opts, @argv)`.** This is the 4.2a mechanism, moved into `units.pm` so it outlives `migrate.pm`. It is root-only, and it is **the only way root code runs anything as an account**: the admin module's `_as_cpuser` child, root's as-user helpers, hooks, restore, the migration, and the plugin's builds and `_in_user_session`. A lint test covers `SOURCES/` and the plugin.
- `systemd-run --uid --gid --unit=eapodman-run-<uid>-<label>-<seq> --slice=eapodman-<uid>.slice --pipe --wait --collect`, with `RuntimeMaxSec=<timeout>`, `TimeoutStopSec=10`, `KillMode=control-group`, `WorkingDirectory=<home>` (no `PAMName=`, F18), and `podman_env`.
- stdin is `/dev/null` and stdout/stderr are fresh pipes (F10); output is capped at 1 MB per stream; there is an outer alarm (4.2a).
- `<label>` matches `^[a-z0-9_]+$`. Leftover units are matched by strict regex, never a glob.
- Optional `oom_score_adjust` (whitelisted values, 0 to 1000) for callers such as plugin builds (Phase 6).
- Callbacks into the admin module (`REGISTER`, `UNIT_INSTALL`, `START`) work from inside the transient unit, because the admin socket is reachable from there.

**Placement in a unit's subtree (F20, F24): `place_in_unit($name, $leaf, $pid)`.** Root-only.
- `$leaf` is `ea-podman-exec` or `ea-podman-health`, never caller input. The unit's cgroup is its `ControlGroup` from systemd. The unit must be active, and its marker uid must match.
- **On v2:** `mkdir` the leaf if it is missing, and write the PID to its `cgroup.procs`. An existing leaf can only be a cgroup, because cgroupfs has no symlinks. **On v1:** nothing.
- Any error refuses. Callers never fall back to running unplaced.

**Health checks (F24):** the packaged templates `ea-podman-health@.timer` and `ea-podman-health@.service`, the helper `bin/health-run`, and `health_sync($name)`. `health_sync` is root-only: it reads the health check as the account, then writes or removes the timer's interval drop-in and enables or disables the timer.

**Per-account slice: `eapodman-<uid>.slice`.**
- It groups the account's anchor unit, its container units, and the plugin's build jobs. It gives the account a place for a `MemoryLow` floor, real totals (`MemoryMax`, `CPUQuota`, `TasksMax`) and live changes through `systemctl set-property`. Per-container flags still need a recreate.
- **Naming and nesting.** Dashes in slice names mean nesting, so `eapodman-1002.slice` sits under `eapodman.slice`, which sits directly under the root (F9). The account slices must not sit at the top level: each would be a sibling of `system.slice` with the same CPU and IO weight, and N container accounts would together outweigh every system service N to 1.
- **Parent slice: `/usr/lib/systemd/system/eapodman.slice`**, shipped in the package as fixed text:
  - `CPUWeight=100` and `IOWeight=100`, equal to `user.slice`'s, so all container accounts together compete like one `user.slice` (T0.2/T0.6: 33% each for system, user and `eapodman.slice` on all 9). `IOWeight` only has an effect where the disk's scheduler supports weights;
  - `TasksMax=` from `runtime.conf` (`eapodman_tasks_max`, default 33%) as a host-wide total, written as an absolute count (F23);
  - `MemoryLow=` is kept by root equal to the sum of the account slices' floors. A child's `memory.low` only takes effect up to what its ancestors are protected for, so `set_slice_properties` and `clear_slice_properties` recompute the parent in the same call.
- **Account floor includes unit floors (F13).** The account slice's effective `MemoryLow` is the larger of the plugin's account floor and the sum of the account's container units' `MemoryLow`. `write_unit` and `remove_unit` recompute it, and `eapodman.slice`'s, in the same call as `set_slice_properties`, so a reservation is never larger than what its ancestors protect.
- **Per-account defaults.** Each account slice gets a default `TasksMax` (`account_tasks_max` in `runtime.conf`, default 33%, written as an absolute count, F23), so an account's units share one task total instead of each unit getting `DefaultTasksMax`. That equals `user-<uid>.slice` on EL9+, CloudLinux 9+ and Ubuntu. RHEL 8's `user-.slice` says 80%, but `eapodman.slice`'s 33% caps it anyway (T0.6). If the host has drop-ins on `user-.slice` or `user-<uid>.slice` (`MemoryMax`, `CPUQuota`, `TasksMax`), `ensure_runtime` logs them and the release notes say that they no longer cover containers and must be set on `eapodman-.slice` instead.
- **Implicit, no file.** systemd cannot template slices, and it creates a slice implicitly when a unit references it with `Slice=`. So no per-account slice file is written; the defaults are set by `ensure_runtime` through `set_slice_properties`. On EL8 (systemd 239), `systemctl set-property` on the implicit slice was confirmed to write its drop-ins under `system.control` and apply them (`eapodman-test-kit/verify.sh`). If P0-4 shows a file is needed elsewhere, it is fixed text with the uid from `getpwnam`, written like the unit file.
- **Properties are set only by root,** through `set_slice_properties($user, %props)`:
  - whitelist: `MemoryLow`, `MemoryMax`, `CPUQuota`, `TasksMax`. `TasksMax` must be digits or `infinity`; a `runtime.conf` percentage is resolved by ea-podman first (F23);
  - values must be numeric, unit-suffixed, or `infinity`;
  - the slice name is always derived from `getpwnam`, never from caller input.

  These persist as drop-ins under `/etc/systemd/system.control/eapodman-<uid>.slice.d/`.
- **No delegation on the slice itself.** The services inside it keep `Delegate=`. On v2, systemd enables the needed controllers on the slice. On v1 the limits stay unenforced, as today, and split isn't pinned there (F17).
- **Lifecycle.** `ensure_runtime` brings the slice into use. `release_runtime` and account removal remove its `system.control` drop-ins, so a new account that reuses the uid can't inherit old limits.

**Validation, on every render:**

| Value | Rule |
|---|---|
| name | `validate_user_container_name` (`util.pm:1939`) plus `container_name_belongs_to_user` (`util.pm:694`). It is also a path component of `PIDFile=`, which the name regex keeps free of `/` |
| user | `getpwnam` succeeds, matches a strict regex, and equals the registry user |
| uid/gid | Taken from `getpwnam` only |
| CID | `^[0-9a-f]{64}$`. Units no longer carry a CID; this rule is for the migration state and argv (4.2a) |
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
- **Per-account unit cap.** `write_unit` refuses past `max_units_per_account` (root-owned `runtime.conf`, default 50, T0.6), so an account can't fill `/etc/systemd/system` or PID 1's memory.
  - **The cost it bounds:** each enabled unit costs PID 1 about 3–4 KiB and 0.2–0.3 ms per `daemon-reload` (T0.6).
  - **Migration never refuses:** an account's existing 1.x containers are migrated even past the cap. The cap only refuses new installs, and its message names the setting.

**API, all root-only (each dies unless `$> == 0`):**
- `write_unit`, `remove_unit`
- `unit_ctl($name, start|stop|restart|enable|disable|reset-failed)`
- `unit_show($name, @whitelisted_props)`
- `ensure_runtime($user)` / `release_runtime($user)`, which also own the slice lifecycle
- `set_slice_properties($user, %whitelisted)` / `clear_slice_properties($user)`
- `units_for_user`, `orphan_units` (glob plus marker parse)
- `container_nproc_cap`
- `place_in_unit`, `health_sync`
- Not root-only: `conmon_pidfile($uid, $name)`, a pure path function. The as-user create and root's render both call it, so the two always agree.

Move `_systemctl_quiet` / `_systemctl_show` / `_systemctl_value` (`util.pm:1011,1031,614`) here as plain `systemctl`, keeping them as mockable subs.

**Registry:** add `uid`, `unit` and `cgroup_v` (the host's cgroup version when the container was created, F17) to entries in `register_container_as_root` (`util.pm:2420`), under `_mutate_known_containers_as_root` (`util.pm:2378`). The migration back-fills `uid` and `unit`, and sets `cgroup_v` when it recreates (step 6).

## Phase 2: admin module actions and routing

All in `SOURCES/Cpanel-Admin-Modules-Cpanel-ea_podman.pm`.

**New actions:**
- `UNIT_INSTALL` (gated): the container must be registered to the caller and exist in the caller's storage. Root inspects it as the user and refuses unless its `ConmonPidFile` equals `conmon_pidfile($uid, $name)`. The check only catches a container that wasn't created by ea-podman's path, so its unit can't fail later for a missing PID file. Nothing from the inspect is written into the unit. The inspect runs **before** the account lock is taken, never under it (4.2 rule 1). Under the lock, root re-checks only the registry, then writes the unit.
- `UNIT_REMOVE`: for a registered container, or an orphan whose marker uid is the caller's.
- `UNIT_SHOW`: returns whitelisted properties only.
- `RESET_FAILED`.
- `EXEC_PLACE` (gated), for `ea-podman bash` (F20). The container must be registered to the caller, its unit active, and its marker uid the caller's. The PID must be the caller's own process and an ancestor of the admin process. Then `place_in_unit($name, 'ea-podman-exec', $pid)`.
- `HEALTH_SYNC` (gated): a registered container; `health_sync($name)` (F24).
- **No `SLICE_SET` action.** The admin module's caller is always the account: its identity comes from the socket's peer credentials, so there is no "authorized non-account caller" to let through. Root-side callers (WHM, the Web Apps plugin's adminbin, which already runs as root) call `ea_podman::units::set_slice_properties` directly. An admin action would leave a single authorization bug between the account and its own `MemoryLow` (reserving host memory) or `MemoryMax`.

**START/STOP/RESTART/STATUS:**
- Use `_own_container_arg(..., registered => 1)`, and require the unit's marker uid to match the caller.
- Root runs `unit_ctl` itself, with no `_as_cpuser`.
- START and RESTART run reset-failed, then the verb, then the `wait_for_container_unit_verdict` poll (`util.pm:1137`, moved to root).
- **Locking.** These actions, together with `UNIT_INSTALL`, `UNIT_REMOVE` and `RESET_FAILED`, take the per-account lock only around their own root-side work, with a bounded wait. INSTALL/UPGRADE never hold it across their `_as_cpuser` child, because that child calls these same actions. The rules are in 4.2.

**ENSURE_USER / RELEASE_USER:**
- `ENSURE_USER` keeps subid allocation (`subids::ensure_user_root` minus the session). It calls `ensure_runtime` when the account has containers or is creating one, and returns `{has_runtime, nproc}`.
- **It keeps EA4-360's root-side user namespace check and its `($creating, $userns_optional)` signature** (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:201`). `$userns_optional` only warns, for the verbs that don't need podman ("Stays").
- **The other root-side actions classify the same way.**
  - **Refuse without user namespaces:** START, RESTART and UNIT_INSTALL, because the unit's `ExecStart` runs podman.
  - **Only warn:** STOP, UNIT_SHOW, UNIT_REMOVE and RESET_FAILED.
  - The refusal is the EA4-360 message, passed through as is.
- `RELEASE_USER` stops the anchor unit when the account has no units left.
- **An account that hasn't been migrated yet:** lifecycle actions refuse with "this account's containers have not been migrated to ea-podman 2.0 yet; root can run `ea-podman migrate_units`". They do not migrate the account themselves.

**Routing:**
- Every non-root lifecycle call goes through admin, following the `register_container` pattern (`util.pm:2690`): root calls `ea_podman::units` directly, everyone else uses `Cpanel::AdminBin::Call`.
- Update the POD's AUTHORIZATION and HOSTILE ARGUMENTS sections.

## Phase 3: rewire util.pm and the CLI

- **`sysctl()` (`util.pm:423`) is deleted,** with no compatibility shim. The Web Apps plugin ships in lockstep (Phase 6) and uses the new exports. Internal callers use `api_lifecycle` / `install_container_unit` / `UNIT_SHOW`.
- **Unit install path:**
  - Delete `_podman_generate_systemd` (`util.pm:980`) and `_add_container_unit_directives` (`util.pm:718`). User-produced unit text must never reach root.
  - `generate_container_service` (`util.pm:990`) becomes `install_container_unit($name)`, which goes through admin/root.
- **`_ensure_latest_container` tail (`util.pm:1643-1668`) and rollback (`util.pm:1701-1734`):** call `install_container_unit`, then admin START unless `--no-start`.
- **`uninstall_container` (`util.pm:2320`):** UNIT_REMOVE, then `podman rm` as the user. It no longer writes anything under `~/.config`. Its result says whether podman's copy was removed, and why not. Without user namespaces, the root-side cleanup still succeeds but `podman rm` can't run; today the caller is told only "success" (EA4-367 item 1, which survives this plan).
- **Status and errors:**
  - `verify_container_started` (`util.pm:1186`) uses UNIT_SHOW.
  - Rewrite the messages at `util.pm:1205-1214, 1479, 1766, 3499`: no `systemctl --user`. Point to `ea-podman status`, `podman logs`, and root `journalctl -u ea-podman-<name>`.
- **`api_lifecycle` / `api_status` (`util.pm:3464,3517`):** non-root callers go to admin.
- **Environment:**
  - `ensure_su_login` (`util.pm:118`), `run_in_user_session` (`util.pm:3353`) and `resolve_container_init_pid` (`util.pm:300`) apply `podman_env`. When root calls them, they run through the slice runner (F11), never a direct setuid fork.
  - Keep the "rootless runtime directory … does not exist" wording, because `ea-podman.pl:103` matches on it.
  - `get_containers` (`util.pm:646`) and `util.pm:2103` check the new runtime dir.
- **nproc:** the unit's `LimitNPROC` and the `--ulimit nproc` passed at create (`util.pm:479-491`) come from the same `container_nproc_cap`, which is now the host's `DefaultLimitNPROC` rather than the user manager's (T0.6). The pin stays as a guard: the baked value can never exceed what the unit allows.
- **conmon PID file:** every create (install, upgrade, rollback, `op => 'migrate'`) also passes `--conmon-pidfile` from `conmon_pidfile($uid, $name)`, so the unit's `PIDFile=` (Phase 1) is where conmon writes.
- **`_backup_name_is_free` (`util.pm:2153`)** checks the `/etc` unit path.
  - **The session gap closes.** Its podman check no longer depends on the account having a session.
  - **The other gap stays (EA4-367 item 2).** `_podman_container_exists` (`util.pm:2108`) must report "couldn't check" separately from "no such container", so `clean` keeps a `.bak` when podman can't be asked.
- **CLI (`SOURCES/ea-podman.pl`):**
  - `start/stop/restart/status` (`:441-504`) go through `api_lifecycle` / `api_status` for every caller.
  - Remove the `ensure_user_sessions` verb (`:1042-1084`).
  - Add the root verbs `reconcile_units` and `migrate_units`.
  - **`reconcile_units [--user U] [--dry-run]`** is the repair tool for after a restore, a hand edit, or a failed upgrade tail. Per account, under its account lock: for every registered container on a migrated account, render its unit and rewrite it if it is missing or differs (`write_unit`, so validation and the atomic write apply); remove unit files that carry an ea-podman marker line whose uid and container have no registry entry (the same marker parse as `orphan_units`; files without a marker are never touched), stopping them first; then one coalesced `daemon-reload`. It **leaves enablement and run state alone**: the registry records no desired enable state, and re-enabling would override an operator's `disable` ("Operator actions win", 4.2). For each unit it had to recreate because the file was missing, it prints `systemctl is-enabled`, so the operator can re-enable it. It never starts or stops a container that is in the registry, never touches an account `migrate_units` hasn't finished, and prints each change. `--dry-run` prints without writing.

## Phase 3b: one execution path through the admin module (all non-root verbs except `bash`); remove the EAPodman UAPI

**Why.** The UAPI existed only to get podman out of the CageFS/jailshell view. Since 1.0-32 (EA4-315) the CLI reaches the admin module directly. Once every non-root verb goes through admin, podman runs as the user in exactly one place: the admin module's `_as_cpuser` (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:581-607`).

**CLI (`SOURCES/ea-podman.pl`):**
- For `$> != 0`, every verb except `bash`, `avail`, `testbin` and `help` goes through `delegate_to_admin` (`:156-199`), whatever the shell or cage:
  - `avail` only reads `/opt/cpanel`;
  - `testbin` only prints the perl version.
- `bash` stays direct for unrestricted shells only. Restricted shells keep today's refusal. Before it execs, `bash` calls `ENSURE_USER` and then `EXEC_PLACE` with its own PID through admin (F20), so the anchor and its pause process are up and the process sits in its container's unit. It then execs `podman exec -it` with `podman_env`; a refused `EXEC_PLACE` stops it. `podman exec` then only `setns`-joins existing namespaces and creates none outside the slice (F11). Note this in the help text.
- **Remove:**
  - the `_has_unrestricted_shell` gate (`:58-66`);
  - the CageFS runtime-dir fallback (`:85-110`) and the regex it matches;
  - the "restricted shell" wording in `delegate_to_admin`'s help and errors;
  - `%bridge_verb`/`%bridge_alias` as a *restriction*. They become the general verb-to-action map (`_admin_action_for_verb`, `:281-297`).
- **Audit:** the cPanel Terminal refusal (`:69-82`). Drop it if its only reason was running podman locally.
- **Root** keeps the direct path.

**Admin module coverage.** Existing actions cover install, upgrade, list, start, stop, restart, uninstall, status, cmd and containers (`REGISTERED_CONTAINERS`). New or extended:

| Change | Detail |
|---|---|
| `SUBIDS` (new) | Report, plus `--ensure` via `ENSURE_USER` |
| `BACKUP` / `RESTORE` (new) | The user's own `ea-podman backup`/`restore` |
| `CLEAN` (new) | List, or `--run` |
| `INSTALL` / `UPGRADE` (extended) | Accept the **full CLI argument set** the direct path allowed: arbitrary start args including `-v`/`--mount`, `--cpuser-port`, `--webapp-dir`, `--no-start`. These are safe because they run in the `_as_cpuser` child and are validated by `validate_start_args` (`util.pm:1967`) as the user, exactly as today. The "not expressible through the UAPI" limit in `DESIGN.md` goes away. |

- **Paths resolve in the host view, not the cage's.** The `_as_cpuser` child runs outside CageFS. So for a caged or jailshell account, any path argument names a file in the real filesystem: the real `/tmp`, or files that CageFS hides but the uid can read. Today's admin `INSTALL` takes only name, image, ports and env (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:380-394`), so this is new for those accounts. `-v`/`--mount` are handled by EA4-343 and out of scope here. The other path-taking arguments get the same rule as EA4-343: resolved as the user (`realpath`) and refused unless they are inside the account's home. That covers:
  - start args `--env-file`, `--label-file`, `--authfile`, `--cidfile`, `--pidfile`, `--log-opt path=`, `--seccomp-policy`, `--security-opt seccomp=`;
  - `--webapp-dir`;
  - the BACKUP output path and the RESTORE input path.

  `--network=host` is not a path, so this rule doesn't cover it. It is listed with `-v` as a decision for EA4-343, and the release notes name it.
- **Cgroup start args are refused (F12, F17).**
  - **What is refused:** `validate_start_args` refuses `--cgroups`, `--cgroup-parent`, `--cgroup-conf` and the global `--cgroup-manager`, which podman also accepts after the subcommand. CMD takes no podman flags (it runs `nsenter`, F22), so there is nothing to refuse there.
  - **Why:** the account could otherwise move a container out of its unit's cgroup and escape both the slice limits and the namespace rule (F11). It could also switch per-container limits off: a command-line `--cgroups=enabled` overrides the pinned split and enforces nothing (F17).
  - **ea-podman's own create paths never pass `--cgroups` or `--cgroup-manager`.** CPANEL-57893 passes `--cgroups=enabled` for capped containers (`util.pm:511` on `CPANEL-57893-full`, not on `CPANEL-57513`). 2.0 drops it with the pin, and keeps CPANEL-57513's start-arg denylist in line with this list.
- **`--conmon-pidfile` is refused.** ea-podman sets it itself (Phase 1, Phase 3). A different path would leave the unit with no PID file, so it would never start.
- **CMD runs `nsenter`, not podman (T0.8).** CMD (`api_cmd` → `EXEC_IN_CONTAINER`) runs the account's command in the container's namespaces, mapped to the account (`util.pm:238`). It never runs podman subcommands, so it starts no container (F22), takes no podman flags, and isn't affected by F20. Its command runs in the admin child's runner transient, so it is bound by the account slice and the runner's deadline, not by the container's limits (F14). The help text says so.
- **Health-check start args are refused** as F24 lists: `--health-on-failure` other than `none`, `--health-startup-*`, and `--health-timeout` above 60s.
- Every action: `registered => 1` ownership where a container is named, the feature gate where the UAPI had one (`Cpanel-API-EAPodman.pm:63-77` moves into the actions), and existing timeouts (install/upgrade 1800s).
- `run_in_user_session` (`util.pm:3353`) stays only as the admin child's wrapper. Rename it (e.g. `run_as_cpuser_captured`). It applies `podman_env`, captures output, and `chdir`s to home. Its cpsrvd comments go.
- **`_as_cpuser` runs in the slice (F11).** The admin module's `_as_cpuser` (`Cpanel-Admin-Modules-Cpanel-ea_podman.pm:581-607`) runs its child through `units::run_as_user_in_slice`, with the action's existing timeout (350 s or 1800 s) as `RuntimeMaxSec`, instead of forking under cpsrvd. The 1 MB cap below and the per-account semaphore still apply.
- Output is buffered, not streamed. That's acceptable; note it in the help text for install/upgrade.
- **Root-side limits, because every non-root verb now runs in cpsrvd:**
  - the captured output and the Storable return of `_as_cpuser` are capped at 1 MB per stream, like the migration runner (the rest is drained and discarded, and the reply says it was truncated);
  - a per-account semaphore (`max_concurrent_admin_actions` in `runtime.conf`, default 2; kept by T0.6) limits how many long-running actions (INSTALL, UPGRADE, BACKUP, RESTORE, CLEAN, CMD) one account can hold open at once. Further calls fail at once with "too many ea-podman operations in progress for this account".

**Remove the EAPodman UAPI:**
- **Code and build:**
  - `SOURCES/Cpanel-API-EAPodman.pm`;
  - the nine `SOURCES/EAPodman-*.openapi.yaml` files;
  - `build-tools/gen-openapi.py`, if nothing else uses it;
  - spec Source12-Source2x, install and `%files` entries;
  - debify `ea-podman.install` and `override_dh_auto_install.sh` lines.
- **Docs and tests:**
  - `docs/uapi.md`. Replace it with a short `docs/admin-routing.md` describing the single admin path.
    - **Move its host requirements first** (EA4-360): the cgroup v2 recommendation, user namespaces and https://go.cpanel.net/userns, and CloudLinux 10's `user.max_user_namespaces=0`. Put them in README or `docs/admin-routing.md`.
    - **Update them for 2.0:** CloudLinux 8 stays on v1 (EA4-365); `tuned-adm profile cloudlinux-default-cgv2` on 9/10, `grubby` elsewhere. Add the per-platform limits on memory floors (F13) and the CloudLinux LVE decision (F18);
  - `t/SOURCES-Cpanel-API-EAPodman.t`;
  - UAPI assertions in the live tests (jailshell, cagefs, memcached16-cagefs, ea4-315, ea4-360-userns-cgroup).
  - Keep `DESIGN.md`, README and help-text references in sync.
- **Changelog:** "Remove the EAPodman UAPI module; ea-podman's CLI routes through its admin module for all accounts". This is a breaking change for anyone calling `uapi EAPodman` directly. No consumers exist in the cPanel or cpanel-plugins checkouts.
- **Ships with:** the 2.0 release, so routing changes once.

**Tests:**
- Extend `t/SOURCES-Cpanel-Admin-Modules-Cpanel-ea_podman.t` for the new and extended actions: ownership, feature gate, full install args, `-v` validated as the user.
- Add a CLI routing test: non-root with any shell goes to admin; `bash` stays direct only for unrestricted shells; root stays direct. `bash` calls `EXEC_PLACE` with its own PID before it execs, and stops if that refuses.
- `--cgroups=…`, `--cgroup-parent`, `--cgroup-conf`, `--cgroup-manager` and `--conmon-pidfile` in start args are refused, and so are the F24 health-check flags.
- Errors from admin actions reach the user as the message alone, with no stack trace or exception id. Use `Cpanel::Exception::get_string_no_id`, as `ensure_user` has done since EA4-360 (`util.pm:2718`). Surfacing them in the plugin's API and UI is EA4-364.
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
- **User namespaces (EA4-360).** Every run starts with root's `assert_has_user_namespaces`.
  - **Without them, nothing is migrated.** Every as-user step needs podman. The run marks no account `failed`, changes no state, and prints the EA4-360 message with https://go.cpanel.net/userns. The next trigger tries again.
  - **On masked hosts it still applies step 12 to every account.** That step is root-only and needs no podman. The carveout, not user namespaces, is what keeps the CLOS-7971 exposure open, so it must still be released.

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
  -p WorkingDirectory=<home> \
  [--setenv=... from podman_env or the pinned old-storage env] -- <argv> \
  </dev/null 2>stderr-pipe >stdout-pipe
```

- The argv is built by `migrate.pm` from fixed command words plus values validated by the same rules as Phase 1 (container names, CIDs, volume names). No `-p` value comes from the account or the registry.
- **The account never gets root's terminal (F10).** `--pipe` hands `systemd-run`'s own fds 0–2 to the transient unit. So the runner always starts `systemd-run` with stdin from `/dev/null` and stdout/stderr on pipes it creates, never inherited, even when `migrate_units` runs in an interactive root shell. The plugin's build `systemd-run --pipe` (Phase 6) follows the same rule. The same test that checks `/proc/<pid>/fd` for lock files also checks that fds 0–2 of a runner child are not a TTY and are not any fd that the migration process itself holds.
- **The old-storage env is pinned too.** Steps against 1.x storage use `old-containers.conf` / `old-storage.conf` (Phase 1), never the account's own `~/.config/containers`. Without this, every repair run on a `done` account (step 11) would start the account's own configured runtime and hooks from a PID-1 unit outside the cage.
- **Both envs set `DISABLE_HC_SYSTEMD=true` (F24).** Steps 3, 4, 6 and 11 run podman against containers that may carry a health check. Without it, podman 5.8.2 refuses to start such a container, and every version looks for a user manager to add or remove its timer. 1.x's own health timers, in the account's `user@`, go away with the session at step 12.
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

### 4.3 Per account (`users_with_containers_as_root`, `util.pm:2782`)

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
6. **Recreate, as the user:** `_ensure_latest_container` with a new `op => 'migrate'`. That is the upgrade path with no pull, the image pinned by ID (as in `_rollback_failed_upgrade`, `util.pm:1701`), ports from `_get_current_ports`, the registry untouched, and the `webapp` flag kept. The new containers are **created but not started**. Their named volumes already exist from step 5, so podman doesn't create empty ones or copy image content into them. Anonymous volumes are **not** carried over: podman creates new, empty ones (seeded from the image), the same as on every 1.x upgrade.
7. **Write units, as root.** `write_unit` for each container, **not enabled and not started**. Then `health_sync` for each one (F24), so a container that carries a health check (every Web Apps container does) gets its `ea-podman-health@<name>.timer`. The health check is read from the **new** container, as the account with `podman_env`. The timer is `BindsTo=` the container's unit, so it only runs once step 8 starts the container.
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
    - **CID guard (all accounts, every run, including repair).** Before removing an old copy, check that its old CID is not the `new_cid` in the state and not the CID of the container currently holding the registered name (the container the unit starts, since units name containers, never CIDs). If any match, skip it, log it, and set nothing. Use `podman rm` without `-f`, so a copy someone started is refused, not killed; log it and retry on the next run.
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

- **Root's own containers: an in-place branch, not the same steps.** The pinned `storage.conf` only changes `rootless_storage_path`, so root's old and new storage are the same `/var/lib/containers/storage` (runroot under `/run/containers`). Steps 3, 5, 6 and 11 assume two stores and must not run as written: there is nothing to stage, a volume export/import would copy onto itself, a recreate would collide with the retained old container's name, and step 11 could remove the container the new unit now runs. Root's account gets `in_place: true` and these steps instead:
  1. **Probe** as in step 1, against `user@0` and `/root/.config/systemd/user`. No writer check, quota check or size limit: no volume moves, so sharing with root's own unmanaged containers keeps working.
  2. **Stop** as in step 4. Then, still in this step, **retire the legacy unit before any system unit exists.** 1.x units come from `podman generate systemd --name` (`util.pm:980`), so they address the container by name, in the same storage the new unit uses. If both existed, two managers could control one container, or a later `systemctl --user start` would start the new one. Copy the legacy file into `migration/root-legacy/` (root 0600) for manual rollback, set `legacy_unit_saved`, remove the file and its wants link, and `daemon-reload` root's user manager. (This is root's own home; the "root never writes into home" rule is about account homes.)
  3. **Volumes:** none are copied. Named volumes stay where they are and are reattached by name. Set nothing under `volumes`.
  4. **Always recreate.** A 1.x container was created without `--conmon-pidfile`, so conmon would never write the unit's `PIDFile=` (Phase 1). podman can't change that on an existing container, so there is no "no recreate" branch.
     - `podman rename <name> <name>.ea-podman-1x` (set `old_renamed_to`; the CID and volume mounts are unchanged, per P0-2), then `_ensure_latest_container` with `op => 'migrate'` creates the new container under the original name, created but not started, with the same named volumes. Record `new_cid`. Anonymous volumes behave as on any 1.x upgrade.
  5. **Write the unit and switch** as in steps 7 to 9, with the rootful variant.
  6. **Remove the old copy** only after the new container is verified, by `old_cid`, under the step 11 CID guard. `--prune-old` is refused for root's account: its "old storage" is its live storage.
  7. **Release:** root's linger is never released; `user@0` carveouts are handled as in step 12.
  - **Resume.** A re-run reads reality first: a container named `<name>.ea-podman-1x` with `old_cid` and none named `<name>` means "renamed, not yet recreated"; both present means "recreated", and the new one's CID becomes `new_cid`.
  - **Manual rollback of a `failed` root account** (documented in the recovery doc): `podman rm <new_cid>`, `podman rename <name>.ea-podman-1x <name>`, restore the saved legacy unit, remove the system unit.
- **Unregistered containers, legacy units, or `~/ea-podman.d` dirs.** These are never adopted and never deleted. They are reported as "unmanaged" in `--status`.
- **Raw (non-ea-podman) podman data.** The user's own containers, images and volumes in `~/.local/share/containers` are kept. Only the old copies of the registered ea-podman containers are removed. The release notes say:
  - the user's own `~/.config/systemd/user` units keep running only if *they* linger;
  - on CageFS-masked hosts those units never ran anyway.
- **Anonymous volumes are not migrated.** They come from an image `VOLUME` that the start args don't mount, or from a `-v` with no source. ea-podman treats them as disposable: any recreate replaces them with new, empty ones. A container whose anonymous volume holds data worth keeping is an oversight in how it is mounted, and gets fixed separately, not by the migration. ea-podman 1.x never preserved them either: `podman rm` without `-v` (`util.pm:449`) strands the old one, and the recreated container gets a new, empty one.
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
  - a migrated container that carried a health check in 1.x starts (podman 5.8 refuses it without `DISABLE_HC_SYSTEMD`, F24), has its `ea-podman-health@<name>.timer` after step 7, and reads `healthy` after step 8;
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
- **Root's in-place branch,** for a running and a stopped container:
  - no volume is exported or imported, and the quota and size-limit checks are skipped;
  - the legacy unit is saved and removed before the system unit is written;
  - the new container is created with root's `--conmon-pidfile` path, and the unit starts it;
  - the old container is renamed, the new one keeps the original name and the same named volumes (a marker file written before migration is visible), and the renamed copy is removed only after verification;
  - a die after the rename, after the create, and after the unit write each converges on re-run;
  - `--prune-old` is refused for root;
  - the CID guard: a state file whose `old_cid` equals `new_cid`, or the CID of the container currently holding the name, never leads to a `podman rm`, and a running old copy is refused, not killed.
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
- **Upgrades:** from 1.0-32, 1.0-34, 1.0-37 and 1.0-38 (the last 1.x, with EA4-360's user namespace gate; from the internal archive) to 2.0, on EL9, CL9 with CageFS masked, EL8 (cgroup v1) and Ubuntu 24.04.
- **Fixtures:**
  - one container running, with a marker file in `~/ea-podman.d`;
  - one stopped;
  - one `--no-start` webapp;
  - one jailshell account;
  - root's own containers: one running and one stopped, each with a named volume holding a marker file;
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
- **`remove_containers_for_a_deleted_user`** (`util.pm:2592`) does the same unit removal, using the marker uid, and also unmounts and removes `/run/ea-podman/user/<uid>` and removes `/etc/systemd/system.control/eapodman-<uid>.slice.d/`. The unmount comes first, and the directory is removed only after every process of the uid is gone, so root never walks a tree the account is still changing.
- The hooks' as-user removal and the restore tail run through the slice runner (F11).
- **`_pre_username_change`** (`PodmanHooks.pm:84`) keeps refusing.
- **Restore** (`util.pm:3173`): drop the `remove_tree` of `~/.config/systemd/user` (`:3199`). Units are recreated by the tail.
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
- **Health checks (F24):** `health_args` stay as they are (`none`, a 10s timeout and a 60s interval are all accepted). After `apply_stabilization`'s live `podman update`, the plugin calls `HEALTH_SYNC` so that ea-podman's timer picks the new check up. It never runs `podman healthcheck run` itself: from the runner, that reports `unhealthy` on crun hosts.
- The account `MemoryLow` floor moves from `user-<uid>.slice` to `eapodman-<uid>.slice`. The plugin's root side sets it by calling `ea_podman::units::set_slice_properties` directly; there is no admin action for it (Phase 2). The "takes effect at next recreate" rule and the pending-release bookkeeping no longer apply to account totals.
- **Account limits (agreed with the plugin's DESIGN.md Limits section, EA4-352 comment 1801665):**
  - the plugin sets `MemoryLow` (floor) and `MemoryMax` (hard memory total, enforced live) on `eapodman-<uid>.slice`. The floor is best effort by platform (F13): it holds on newer kernels, is unreliable on EL8, and may protect nothing on CloudLinux, where page cache isn't charged to the writer's cgroup;
  - **no `CPUQuota`.** CPU stays on weights. The whitelist allows `CPUQuota`, but nothing requires it to be set;
  - `TasksMax` defaults come from ea-podman (Phase 1); the plugin doesn't set them;
  - **on CloudLinux,** the plugin sets the account slice's `MemoryLow`/`MemoryMax` as on every other OS (F18: limits win). WHM shows a warning on CloudLinux that Web Apps containers run outside the account's LVE, so the LVE's limits don't cover them and the account slice's do;
  - **on cgroup v1,** split isn't pinned and per-container caps aren't enforced, as today (F17). This matches the Limits design's LIM-ENF-4a.
- **OOM policy.** A `MemoryMax` OOM can kill any process in the account slice, including a container within its own allocation, a container's conmon, and a build. A killed conmon leaves its container down on Ubuntu's podman until it is recreated or restarted (F15). T0.4 accepted that: the OOM killer picked the allocating process, never conmon, in every test. The rest is accepted, with one preference: build transients get `OOMScoreAdjust=500`, so the kernel kills a build before a serving container. The account can raise its own score but not lower it.
- `Session.pm` `ensure` / `ENSURE_SESSION` are replaced by ENSURE_USER. Drop the `user@.service.d` delegate drop-in (`Session.pm:175-198`).
- Builds (`systemd-run --user`, `Podman.pm:1167,1817`) move to the plugin's adminbin, which calls `ea_podman::units::run_as_user_in_slice` (Phase 1) with fixed properties (`RuntimeMaxSec`, `oom_score_adjust => 500`; no `PAMName=`, F18) and validated inputs. It never hand-builds a `systemd-run` line, and callers must never pass `-p`. stdin is `/dev/null`, stdout/stderr are fresh pipes, and captured output is capped.
- `_in_user_session` (`Podman.pm:1930`): when the plugin's root side runs it, it goes through `run_as_user_in_slice`, not a direct setuid fork (F11).

## Phase 7: remove dead code and update docs (in 2.0)

- **Delete:**
  - `subids.pm`: the linger, grant, carveout, mask and session code (about `:37-59`, `:178-1352`). Keep `ensure_user_root` (without the session), `_ensure_subids`, the range helpers, `get_sub*ids`, `_ensure_storage_conf`, and EA4-360's user namespace check: `assert_has_user_namespaces`, `warn_if_no_user_namespaces`, `_sysctl_num`, `_podman_path`, `_apparmor_userns_profile_for` and their package variables (`subids.pm:1359-1522`). The pieces the migration still needs are copied into `migrate.pm`.
  - In `util.pm`:
    - the session half of `ensure_user` and of `init_user`;
    - `release_user_session*`, `_release_deleted_user_session` and `ensure_container_session`;
    - `sysctl()`, `_masked_user_manager_note` and `EA_PODMAN_KEEP_USER_SESSION`;
    - the `/run/user/<uid>` and `DBUS_SESSION_BUS_ADDRESS` handling in `ensure_su_login` and `run_in_user_session`. Only `podman_env()` and its `XDG_RUNTIME_DIR=/run/ea-podman/user/<uid>` remain;
  - **Admin module:** the session, linger and grant parts of `ENSURE_USER`, which keeps only subids, the user namespace check and `ensure_runtime`.
  - **CLI:** the `ensure_user_sessions` verb (`ea-podman.pl:1042-1084`).
  - **`ea-podman-user-managers.service` and its pieces:**
    - spec Source23, install and `%files`;
    - the `%ghost` mask files (spec `:137-141`);
    - the debify lines;
    - scriptlets `pkg.postinst:33-40`, `pkg.prerm:11-18`, `pkg.preinst:9-12`.
  - **Tests that only cover removed code:** carveout-lifecycle, linger, the session parts of `SOURCES-subids.t` (its user namespace tests stay), and the live `ea4-319-*` and `ea4-321-*` tests.
- **Kept on purpose:**
  - the single admin execution path (`delegate_to_admin`, `_as_cpuser`), now used by every non-root caller;
  - subuid/subgid allocation;
  - `XDG_RUNTIME_DIR`, now set through `podman_env`.
- **Docs:**
  - `DESIGN.md`: "Ensuring it is up", "Lingering", and the "users can still run `systemctl`" promise.
  - README FAQ.
  - `docs/container-shell-access.md`.
  - The host requirements moved out of `docs/uapi.md` (Phase 3b).
  - **`t/LiveTests/README.md` and `t/LiveTests/setup-remote-live.pl:319-320`** (EA4-358 comment 1805194):
    - run the CloudLinux live tests on cgroup v2 with the system units: bring-up, stop, restart, and the unit keeping track of its processes;
    - then resolve the note "CloudLinux on cgroup v2 + LVE is not verified yet (EA4-352)" and the "do not switch CloudLinux 8 to v2" warnings to match F18. The CL8 "stay on v1" warning stays until EA4-365. `git grep EA4-352` finds them.
  - `docs/backup-restore.md`, including dropping the `.config/systemd` exclusion (`util.pm:2968-3007`).
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
    - per-container `--memory`/`--memory-swap`/`--cpus`/`--pids-limit` are now enforced on cgroup v2 (`--cgroups=split`); `--memory-swap` needs kernel swap accounting (present on every supported target; where it is missing, INSTALL warns and podman drops the limit, T0.6); `--memory-reservation` and `--cpu-shares` now take effect between containers through the unit's `MemoryLow=`/`CPUWeight=` (F13), and changing them needs a recreate; `--cgroups`, `--cgroup-parent` and `--cgroup-conf` start args are refused;
    - cgroup v2 is recommended on every OS except CloudLinux 8, which stays on v1 until EA4-365 (`tuned-adm profile cloudlinux-default-cgv2` on CloudLinux 9/10, `grubby` elsewhere). On CL8, per-container limits stay unenforced, as in 1.x. Split, and so per-container limits, is pinned only on v2. A container created before a cgroup switch must be recreated (`ea-podman upgrade`): after v1 → v2 to get its limits, after v2 → v1 to start at all (F17). `--cgroup-manager` start args are refused, like `--cgroups*`;
    - memory floors (`--memory-reservation`, the plugin's account floor) are best effort: reliable on newer kernels, not on EL8, and possibly ineffective on CloudLinux (F13);
    - on CloudLinux, how containers relate to the account's LVE, as decided under F18;
    - user namespaces are required, as since 1.0-38 (EA4-360). CloudLinux 10 ships them disabled;
    - `ea-podman bash` sessions run in the container's cgroup, as in 1.x: their work counts against the container's limits and `podman stats`, and stopping the container ends them (F20). `cmd` runs outside the container's limits, bound by the account slice, and ends when the call does (F14);
    - health checks are run by ea-podman's root timer, at the container's own interval but no more often than `health_min_interval`. `--health-on-failure` actions and startup checks aren't supported (F24);
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
7. **Every podman invocation uses the pinned `CONTAINERS_*`, including the migration's runs against old storage.** A hostile `~/.config/containers/containers.conf` (`runtime=~/evil`, `hooks_dir`), `containers.conf.d/` drop-in or `CONTAINERS_CONF_OVERRIDE` never takes effect. Neither does the account's `mounts.conf`, for a container or a build: every podman call names root's with `--default-mounts-file` (F25). Neither does a `policy.json` or `registries.d` the account writes anywhere it can: `XDG_CONFIG_HOME` is root-owned and holds only the `cni` symlink (F16).
8. **Account removal leaves no unit and no runtime dir.** A new account that reuses the uid starts nothing.
9. **`ea-podman.json` `start_args` only reach `podman create` run as the user.** `units.pm` never reads that file.
10. **Slice properties are only ever set by root, from the whitelist, on a slice name derived from `getpwnam`.** No admin action sets them. Test: invalid property names or values and a caller-supplied slice name are refused, and the admin module exposes no action that reaches `set_slice_properties`.
11. **Account removal leaves no `system.control` drop-ins for the uid.** Live test: set a limit, remove the account, and a new account that reuses the uid has the default slice properties.
12. **No account lock is held across a user child or an admin call (the migration's bounded runner, 4.2a, is the one exception), and admin actions never wait on it indefinitely.** An account can't wedge root-side actions by holding a nested call open. Tests: the real nested-call and bounded-wait cases in 4.7.
13. **Migration never destroys data the new setup uses.** It never removes a container whose CID is `new_cid` or that currently holds a registered name (the one its unit starts), never uses `podman rm -f` on an old copy, never exports and imports a volume within one store, and never recreates before a named volume's data is in the destination store (the manual doc included). Tests: the root in-place and CID-guard cases in 4.7, and the manual-doc live run in 4.8.
14. **No account can extend how long the migration holds a lock.** Every as-user step runs in a transient system unit with `RuntimeMaxSec`, under a root-side outer alarm. No lock descriptor reaches an account process. Every root `systemctl` call under an account lock is bounded by explicit unit timeouts. A timeout fails only that account, and the run continues. Tests: the deadline cases in 4.7 and the hostile-stall live test.
15. **No account process ever holds a root terminal or a root-held fd.** Every as-user process root starts (the migration runner, plugin builds) gets stdin from `/dev/null` and stdout/stderr on fresh pipes. Tests: the PTY unit case and the terminal-handoff live test in 4.7.
16. **An account can't exhaust shared host resources through ea-podman more than it could in 1.x.** The runtime dir is a capped tmpfs, not shared `/run`. Account slices sit under `eapodman.slice`, which carries one `user.slice`-sized CPU and IO weight and a `TasksMax` total, and each account slice has a default `TasksMax`. Root-side output buffers are capped, concurrent admin actions per account are limited, PID 1 reloads are coalesced, and units per account are capped. Tests: filling the runtime dir stops at its cap and leaves `/run` untouched; a fork bomb in one account's containers stops at its `TasksMax`; with 10 busy container accounts, a CPU-bound `system.slice` service keeps at least the share it gets against one busy `user.slice`.
17. **No account name or container name can collide with an internal unit.** Internal units use the `eapodman-` prefix, are matched by strict regex, and are never globbed. Test: the `migrate-1003-x` container case in 4.7.
18. **On a masked host, no account keeps ea-podman's 1.x session past the first run that visits it, whatever its migration outcome.** Tests: the session-release cases in 4.7 and the hostile-account live test.
19. **`PIDFile=` can't make PID 1 act on a process outside the unit.** Test (P0-3): a PID outside the unit's cgroup written to `conmon.pid` is refused, and `systemctl stop` kills nothing outside the unit. Passes on EL8 (systemd 239: "New main PID 1 is the manager, refusing" and "… PID file is not owned by root. Refusing"; `eapodman-test-kit/lifecycle.sh` tests 3 and 4).
20. **Every process root starts as an account runs inside `eapodman-<uid>.slice`, and no ea-podman path creates a user namespace outside `eapodman.slice` (F11).** Tests: a lint showing that `run_as_user_in_slice` is the only as-user path in `SOURCES/` and the plugin; unit tests showing that the admin `_as_cpuser` child, hooks, restore and builds go through it; the P0-12 live test, with the BPF-LSM program loaded across the full live suite.
21. **Start args can't move a container out of its unit's cgroup, or change its cgroups mode or cgroup manager (F12, F17).** Tests: the `--cgroups*` and `--cgroup-manager` refusal cases in start args; the pinned `containers.conf` has `cgroups = "split"` on v2 and not on v1, and is re-rendered when its marker doesn't match the host; live, a container's `--memory` shows up as `memory.max` in its cgroup under the unit's cgroup, and is enforced. **Relative limits reach the unit (F13).** Tests: render cases for `{MEMLOW}`/`{CPUWEIGHT}` (defaults, conversion, clamping, refusal of non-numeric values); live, `--memory-swap`, `--cpus`, `--memory-reservation` and `--cpu-shares` show up as `memory.swap.max`, `cpu.max`, `memory.low` and `cpu.weight` in the container cgroup, the unit's `memory.low`/`cpu.weight` match, and each slice's `memory.low` is at least the sum below it.
22. **Root moves a process into a container unit's subtree only for the caller's own running container, only into a fixed leaf, and only either the caller's own process that is an ancestor of the call, or root's own health helper (F20, F24).** Tests: `EXEC_PLACE` refuses another account's container, an unregistered or stopped one, a PID that isn't the caller's, a PID of the caller's that isn't an ancestor of the call, and a non-numeric PID; the leaf path comes from systemd's `ControlGroup`; a placement error refuses and nothing runs unplaced; live (v2), a leaf the account froze only stalls the account's own session.

## Tests

- **Delete:**
  - `t/SOURCES-subids-carveout-lifecycle.t`
  - `t/SOURCES-util-linger.t`
  - the session/mask parts of `t/SOURCES-subids.t` (its EA4-360 user namespace tests stay)
  - `t/LiveTests/ea4-319-*.sh`
  - `t/LiveTests/ea4-321-*.t`
- **Rewrite:**
  - `t/SOURCES-util-container-unit.t`, which becomes `t/SOURCES-units.t`
  - start-verdict, nproc-cap
  - `t/SOURCES-util-cgroup.t`: EA4-360's v2 advice, keeping the CloudLinux 8 carve-out (EA4-365), plus the `cgroup_v` mismatch check (F17)
  - `t/SOURCES-util-init-user-userns.t` and `t/SOURCES-util-ensure-user-error.t` (EA4-360): the 2.0 `init_user`, the admin actions' refuse/warn split ("Stays"), and refusals without a stack trace
  - upgrade-rollback, upgrade-gate
  - the admin-module tests (the UAPI test is deleted in Phase 3b)
  - PodmanHooks-backup, pkg-scriptlets-hooks, the restore tests
- **New unit tests:**
  - `t/SOURCES-units-injection.t`
  - `t/SOURCES-migrate-units.t` (see 4.7)
  - a PodmanHooks removal test
  - the slice runner: lint, injection and label cases (in `t/SOURCES-units.t`), and `_as_cpuser` routing
  - the pinned-config renderer (F17): split only on v2, the marker, the atomic rewrite from each of its three callers, and root's check naming containers whose `cgroup_v` differs from the host's
  - the per-account `XDG_CONFIG_HOME` (F16): root-owned, holding only the `cni` symlink, and replaced if the account has planted anything there
  - the pinned `mounts.conf` (F25): rendered from the distro's (or empty), root-owned, re-rendered with `containers.conf`; every podman argv the units, the runner, the admin module and the migration build carries `--default-mounts-file`, and `containers.conf` has no `default_mounts_file`
- **Live, rework:** cagefs, normal, jailshell, memcached16 (both), ea4-315, ea4-325, ea4-338, cpanel-57396, cpanel-57608, and `ea4-360-userns-cgroup-live.t`.
  - In `ea4-360-userns-cgroup-live.t`, the UAPI cases move to the admin path (Phase 3b).
  - Its "no cgroup advice on CloudLinux 8" case stays until EA4-365.
  - Its uninstall TODO is EA4-367.
- **Live, new:**
  - `system-units-migration-live.t` (see 4.7)
  - `clos7971-canary-live.t`
  - `bpf-lsm-userns-live.t` (P0-12; runs only on kernels with the hook)
  - a hostile-config case (invariant 7): the account's `containers.conf`, drop-ins, `mounts.conf` and `CONTAINERS_CONF_OVERRIDE` take no effect on install, start or a plugin build, while the distro's `mounts.conf` entries do (F25). It is also the canary for `--default-mounts-file`, which podman doesn't document.
  - a `--memory` enforcement case in the normal live test, plus `--memory-swap`, `--cpus`, `--memory-reservation` and `--cpu-shares` cases that check the container cgroup, the unit and both slices (F13).
  - a cgroup v1 case (F17): a container starts without split, and is named by root's check after the host moves to v2 and reboots.
  - CloudLinux on cgroup v2 (EA4-358 comment 1805194): bring-up, stop, restart, and the unit keeping track of conmon and the container, in the configuration F18 settles on.
  - an exec placement case (F20, `exec-placement-live.t`): `ea-podman bash` on a pty lands its exec'd process in the container's `libpod-payload-*` cgroup on v2 and in the container's cgroup on v1, and `systemctl stop` ends the session. An unplaced `podman exec` from the runner still fails on crun; if a podman or crun update makes it work, this case fails, so the design gets revisited.
  - a health-check case (F24): a container with the plugin's `health_args` starts, reads `healthy` within two intervals, a failing check reads `unhealthy`, `HEALTH_SYNC` after a live `podman update --health-cmd` creates the timer, and the timer stops with the container.

## Sequence

1. **Spikes P0-1 … P0-13.** If a spike invalidates an assumption, the design changes before code is written. P0-6 was the CloudLinux ship gate; T0.3 settled F18 for the limits (Chris, EA4-368 comment 1806876), and CloudLinux's review of it runs in parallel (EA4-389).
2. **Implement everything:** Phases 1-7 in ea-podman and Phase 6 in the plugin.
3. **Pre-release testing:**
   - the unit suite, including the injection and migration tests;
   - the full live suite;
   - the migration matrix in 4.7, including reboot, kill and concurrent-run cases.
4. **Delete `EA4-352/` in the PR** (the last commit before merge): once Phase 7's docs carry what admins need from this plan, the manual recovery doc (4.7) is under `docs/`, and the kit and probes are in `t/LiveTests`.
5. **One coordinated release:** ea-podman 2.0 and the matching Web Apps plugin, locked together by `Requires`/`Conflicts`.
6. **Remove 1.x from the mirrors** (RPM and Ubuntu). Keep an internal archive copy for tests.
7. **Release + 6 months at the earliest** (the date is in the release notes and the verb's warning; check adoption telemetry first): a 2.x removes `migrate_units` / `migrate.pm`, `ea-podman-migrate.timer` and `ea-podman-migrate.service` (its scriptlet disables the timer first), and ships the post-removal detector (4.8). This is not a deprecation period; the warning text carries the date.
8. **Follow-up:** a root-owned graphroot (F4).
9. **Follow-up:** once P0-12 passes, ship or document a BPF-LSM namespace policy (with CloudLinux / hardening). It is not part of 2.0; 2.0 only makes it possible (F11). To raise with CloudLinux together with CloudLinux 10's default `user.max_user_namespaces=0` (CLOS-2616) and F18 (EA4-389).

## Open items (resolved by the spikes or a quick call)

- **Resolved (T0.3): the LVE or the limits on CloudLinux (F18).** Limits win. Containers run outside the LVE, the account slice owns account totals (its `MemoryMax` is set by the plugin), and WHM warns about it on CloudLinux (EA4-368 comment 1806876). Still open, with CloudLinux (EA4-389): their view, and an LVE that can account for a systemd-delegated subtree.
- **Resolved (T0.6): `LimitNPROC`.** The host's `DefaultLimitNPROC`, for the unit and the create-time pin alike, because that is what 1.x's user manager ran with on every target. A fixed cap was rejected: it would sit below 1.x on large hosts, and the account-wide bound is the slice's `TasksMax`, which stopped a fork storm on all 9 VMs.
- **Resolved (T0.6): parent slice values.**
  - **`eapodman.slice`:** `CPUWeight=100` and `IOWeight=100` (`user.slice`'s), and `TasksMax` 33% as a host total.
  - **Each account slice:** `TasksMax` 33% by default.
  - **Both** are written as absolute counts (F23); `MemoryLow` is the sum of the floors, as decided.
- **Resolved (T0.6): `runtime.conf` defaults.**
  - `runtime_dir_size` 10% of RAM and `runtime_dir_inodes` = size/4096 (logind's);
  - `max_units_per_account` 50 (migration exempt);
  - `max_concurrent_admin_actions` 2;
  - `eapodman_tasks_max` and `account_tasks_max` 33%.
- **Resolved (T0.2): swap accounting and the runtime's shares conversion.** Swap accounting is present on all 9 targets. `cpu.weight` for `--cpu-shares` follows the OCI runtime version (P0-4).
- **Resolved (T0.4): a killed conmon (F15).** 1.x behaves the same, so the decision is to accept it, document the recovery (`ea-podman upgrade --force` on Ubuntu 24.04, `ea-podman restart` on 22.04) and revisit when Ubuntu's podman moves. See F15.
- **Resolved (T0.6): `--memory-swap` without swap accounting.** INSTALL warns and doesn't refuse. That matches podman, which warns and drops the limit, and cgroup v1 rootless, where every limit is dropped (F12). Root detects it per host: no `memory.swap.max` on v2, no `memory.memsw.*` on v1. It didn't fire on any target: accounting is present on all 9, and enforcement was confirmed with real swap on EL8 v2, EL9 and Ubuntu 24.04.
- **BPF-LSM support matrix:** which platforms can enable the F11 rule (P0-12).
- **CloudLinux 10 ships `user.max_user_namespaces=0`** (CLOS-2616). That blocks 1.x and 2.0 alike. The EA4-360 gate reports it with https://go.cpanel.net/userns. To raise with CloudLinux, together with F11 and F18 (EA4-389).
- **Resolved (T0.5): containers created before a cgroup switch (F17).** The mode is fixed at create. Root names them with the remedy `ea-podman upgrade --force <name>`, and never recreates them on its own. See F17.
- **CPANEL-57893 (`CPANEL-57893-full`; PR #44 and the denylist are on `CPANEL-57513`).** When it reaches main, reconcile its start-arg denylist, and its dropping of recorded cap flags on upgrade and restore, with Phase 3b and with F13's install args (`--memory-reservation` and `--cpu-shares`, recorded as `memory_low` and `cpu_weight`). Also drop its `--cgroups=enabled` (F17).
- **Resolved for 2.0 (T0.2/T0.6): `hidepid=2` and `podman stop` (EA4-366).** In the 2.0 layout the stop doesn't time out (CL8 `hidepid=2`, CL9 `invisible`: `Result=success`, nothing left, `podman rm` works). So STOP's verdict and UNIT_REMOVE's stop-then-remove order need no special case. Whether ea-podman keeps recommending `hidepid=2` stays with EA4-366.
- **Uninstall without user namespaces (EA4-367).** Both of its gaps survive this plan, and Phase 3 covers them: the uninstall result, and "couldn't check" in `_podman_container_exists`.
- **Follow-up:** a root-owned graphroot to close F4.
- **Resolved (T0.8): exec'd processes under the container's limits (F14 option 2).** It is now the design for `ea-podman bash` and health checks (F20, F24), with root moving the caller's own process rather than forking one. `exec -d` isn't offered. The original follow-up: root forks a child that drops to the account and waits on a pipe, writes the child's PID into a sub-cgroup of the container unit (its delegated subtree), then lets it run `podman exec`; the runtime's own move into `libpod-payload-*` then succeeds because the common ancestor is the delegated unit. Gains: Docker-like accounting, `exec -d` lives as long as the container. Costs: root writes into a tree the account controls (it can remove or retype the target, or set `pids.max=0`, a tiny `memory.max` or `cgroup.freeze`; all self-DoS, but paths must be checked and failures must refuse, never fall back); the process leaves the runner's cgroup, so `RuntimeMaxSec`/`KillMode=control-group` no longer bound it and root must enforce the timeout and reaping itself (4.2a); exec'd work competes with the serving container and can get it OOM-killed. Do it only if the plugin needs exec'd work held to a container's budget.
- **Follow-up:** a shipped or documented BPF-LSM namespace policy (F11).

**Raised by T0.2** (Phase 0 results):
- **Resolved (T0.8): `podman exec` on crun (F20).** Root places the caller. `EXEC_PLACE` moves `ea-podman bash`'s own process into `<unit>/ea-podman-exec` on v2, and that process then runs `podman exec -it`. `cmd` stays `nsenter`. F14's decision is replaced, and F22 is settled: no 2.0 path starts a container outside its unit.
- **Resolved (T0.8): health checks (F24).** Found by T0.8: without a user manager, a container with a health check doesn't start on podman 5.8.2, and its checks never run on the other versions. The fix is `DISABLE_HC_SYSTEMD=true` in `podman_env`, plus a root timer per container whose helper runs the check from `<unit>/ea-podman-health`.
- **Resolved (T0.6): memory floors and MGLRU (F13).** Keep `MemoryLow=` for the unit and account floors and document them by platform. `MemoryMin=` holds under MGLRU but is a hard reservation an account could inflate through `--memory-reservation`. An admin-only hard floor in the plugin is a follow-up.
- **Resolved (T0.3): `PAMName=` on CloudLinux (F18).** Not used. These T0.2 results are why, and they go to the CloudLinux follow-up (EA4-389): `pam_lve` cages or refuses a caged account's session; a `PAM` file without an `account` line fails; and on v2 a `PAMName` transient escapes its deadline.
- **Old storage during the migration (F21).** Order the steps so that every old-storage podman call runs before step 12 releases the 1.x session, or have root provide `/run/user/<uid>` for those steps. Also handle a 1.x DB whose runroot is elsewhere (`/tmp/…`, seen where the account first ran podman without a session).
- **Resolved (T0.8): starting containers outside a unit (F22).** No 2.0 path does, so the runner keeps no `Delegate=`.
- **The SELinux `netns` step (F19)** goes into Phase 1's anchor helper, and the SELinux targets go into the live matrix.
- **Resolved (T0.4): Ubuntu 22.04 conmon kill (F15).** Part of F15's decision: `ea-podman restart` restores the port.
- **Superseded by F25: podman 3.4 and `default_mounts_file`.** T0.6 left the key out on podman 3.4 only. No podman version reads it, so 2.0 drops it everywhere and passes `--default-mounts-file` instead.
- **Open (EA4-392): re-running the kit's `setup.sh` can stall PID 1's answers to the runner** (EL8, EL9 and EL10; not seen on CloudLinux or Ubuntu). The first `systemd-run --uid … --slice=eapodman-<uid>.slice` after its reload, `set-property` and anchor start times out, and on EL9/EL10 the bus stays unusable for every transient unit and login session until `systemctl daemon-reexec`. The same steps run one by one don't trigger it. `ensure_runtime` and the package scriptlets run a similar sequence before the runner, so EA4-392 has to say whether the product can hit it before T1-A relies on that sequence.
- **Resolved (T0.6): `events_logger` (P0-5).**
  - **What 1.x used:** EL and CloudLinux's podman used `file` (the vendor `containers.conf`), not journald. Pinning journald would have regressed `podman events` there.
  - **The pin:** `file` with `events_logfile_max_size = "1m"` and `log_driver = "k8s-file"` on EL and CloudLinux; `journald` for both on Ubuntu.
  - **Verified:** events and logs read back as the account on all 9, and the file rotates.
- **runc and unsplit containers with limits (F17).** On EL8 v2, a container created without split and with `--memory` can't start from its unit. 2.0 pins split there, so this only matters for containers created by hand or by 1.x.

## Verification

- `prove -lr t/` passes, including the new injection and migration tests.
- An upgrade from 1.x returns promptly. `ea-podman migrate_units --status` shows every account `done`, and `migration/complete` exists.
- Run the Phase 0 matrix, then the live suite on EL8 (cgroup v1 and v2), CL8 (v1, `hidepid=2`), CL9 and CL10 with CageFS, EL10, and Ubuntu 24.04.
- On a cgroup v1 host, the pinned `containers.conf` has no `cgroups` line and containers start. After a switch to v2 and a reboot, it has `cgroups = "split"`, and root's cgroup check names the containers created on v1.
- `ea-podman install` as an account without user namespaces (`user.max_user_namespaces=0`) is refused with the EA4-360 message and no stack trace. `stop`, `status`, `uninstall` and account removal still work.
- On a migrated CL9 + CageFS host (F18: limits win, so `lveps` shows no ea-podman process for the account):
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
