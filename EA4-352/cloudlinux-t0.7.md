# ea-podman 2.0 and CloudLinux: four questions (EA4-368 T0.7, EA4-389)

**Context.** ea-podman (cPanel's rootless-podman manager, used by Web Apps) is dropping `systemd --user` in 2.0. That answers CLOS-4517: CageFS masks `user@.service`, and ea-podman 1.x worked around the mask with per-account `user@<uid>` copies. CLOS-7971 shows why that workaround has to go. In 2.0 each container is a root-owned system unit:

- `ea-podman-<name>.service` with `User=<account>` and `Delegate=yes`;
- the unit sits in `eapodman.slice/eapodman-<uid>.slice`;
- nothing starts a user manager, and the account can't add units.

We tested this on CloudLinux 8.10 (cgroup v1), 9.8 (cgroup v2) and 10 (v2), all with CageFS 7.6.52. Caged accounts' containers run from these units, including after a reboot. A CLOS-7971-style unit planted in `~/.config/systemd/user` never ran, and no `user@<uid>` existed after the reboot. The design is in [PLAN.md](https://github.com/webpros-cpanel/ea-podman/blob/EA4-352/EA4-352/PLAN.md), and we can share whichever parts help.

Questions 1–3 don't block 2.0; your answers decide what we document now and what we build later. Question 4 asks about the one assumption the whole 2.0 design rests on, so it matters most to us.

## 1. CloudLinux 10 ships `user.max_user_namespaces=0` (CLOS-2616)

New CL10 installs ship with `user.max_user_namespaces=0`, which turns off rootless podman entirely. ea-podman refuses to set up an account on such a host and links to instructions for raising the value. In our tests, CL10 worked normally with `user.max_user_namespaces=15000`, set in `/etc/sysctl.d/`.

- Is `0` the intended long-term default on CL10? Is it also coming to CL8 or CL9?
- Is there a supported way for an admin to raise it? Will any CloudLinux tool (CageFS, an update, a tuned profile) put it back to `0`?
- Would you consider a narrower control instead of the blanket `0`? Item 2 describes one.

## 2. A BPF-LSM rule as a narrower alternative

In 2.0, every user namespace that ea-podman creates is created from a process inside `eapodman.slice`. So a host BPF-LSM program on the `userns_create` hook can deny unprivileged namespace creation everywhere else: from the account's shell, cron, and CGI and PHP that run as the account. Containers keep working.

We tested a test-only program that denies `userns_create` outside `eapodman.slice` to uid 1000 and above. Root and system accounts below 1000 (for example `nobody`) were allowed everywhere, so we have not tested them:

- **CL10 (kernel 6.12):** the hook exists and `bpf` is in the active LSM list by default. Containers started, restarted and recovered, while `unshare -U` from `user-<uid>.slice` and from a `system.slice` job was denied.
- **CL9 (kernel 5.14):** the kernel has no `userns_create` hook, so this can't work there.
- **Its limits:**
  - It is only sound on cgroup v2. On v1 an account can move its own process into a delegated cgroup.
  - Code inside a container can still create namespaces.
  - The program has to be loaded again at boot.
  - The uid floor is an open choice. Denying every non-root uid would also cover PHP or CGI that runs as a system account, but we have not tested what it breaks.

Our questions:

- Would CloudLinux ship or endorse a policy like this, for example as a CageFS or hardening option? Or do you know of a reason it conflicts with LVE or CageFS?
- Will CL9's kernel get the `userns_create` hook?

## 3. LVE vs. cgroup limits on cgroup v2

Measured by Chris Castillo (Web Apps) on CL10, 9.8 and 8.10, and repeated in our probe run: on cgroup v2, a process that enters the LVE through `PAMName=` with `pam_lve` or through `lve_wrapper` leaves its unit's cgroup and moves to `/lve.slice/lvub/full/lve<uid>`. After that:

- the account slice's `MemoryMax` stops applying to it;
- podman can't create per-container cgroups there, because the LVE cgroup is root-owned and already holds processes;
- after `lve_wrapper`, `systemctl stop` doesn't kill the process.

On v1, a `PAMName=` process is in the LVE for memory, pids and cpu, and systemd still tracks it. But for a caged account, `pam_lve` either cages the session, where podman can't run, or refuses it.

**What 2.0 does:** containers, their runtime anchors and the short-lived as-account helpers stay outside the account's LVE on every CloudLinux version. The account slice (`MemoryMax`, `TasksMax`, CPU weight) and the per-container `--memory`, `--cpus` and `--pids-limit` limits apply instead. WHM shows a warning on CloudLinux that container use doesn't count against the account's LVE limits.

- Does this approach cause any problems for CloudLinux customers or tools (`lvestats`, LVE Manager)?
- Could a future LVE account for a systemd-delegated subtree? For example, `lve<uid>` could charge or limit `eapodman.slice/eapodman-<uid>.slice` without moving processes out of it. That would let a later release have both LVE limits and per-container limits.

## 4. System units that run as a caged account

2.0 rests on one assumption: CageFS keeps allowing a root-owned system unit with `User=<caged account>` and `Delegate=yes` to run that account's podman outside its cage, in the unit's delegated cgroup under `eapodman.slice`. Nothing the account controls starts these units; root writes and starts them, and the account can't add or change one. Today this works on CL8.10, 9.8 and 10 with CageFS 7.6.52, including after a reboot.

We are aware that CLOS-4517 masked `user@.service` because a manager spawned by PID 1 ran account-controlled units outside the cage. 2.0's units are not account-controlled, but we want to be sure they don't fall under the same policy.

- Is CloudLinux planning CageFS or LVE changes that would affect system units running as a caged user outside the cage, or the cgroups systemd delegates to them?
- Is there anything about this layout you would want changed, or a CageFS setting we should check for, before we ship it?

## Contacts

Dan Muey (ea-podman, EA4-352) and Chris Castillo (Web Apps).
