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
| `jailshell-podman-live.t` | A cPanel account whose login shell is **jailshell** manages containers — via UAPI, and (with `EAPODMAN_DRIVER=cli`) via the `ea-podman` CLI, which delegates to the UAPI. | A live cPanel VM (cgroup v1 or v2). |
| `cagefs-podman-live.t` | A **CloudLinux CageFS**-enabled account manages containers via UAPI. | CloudLinux (cgroup v1 or v2), with CageFS installed + initialized. |
| `ea-memcached16-cli-live.t` | A **normal** account uses the `ea-podman` CLI directly (`install <PKG>` mode) to install a real EA4 container-based package, `ea-memcached16`. | A live cPanel VM (cgroup v1 or v2), with `ea-memcached16` (or another EA4 container-based package, via `EAPODMAN_TEST_PKG`) already installed locally. |
| `ea-memcached16-cagefs-cli-live.t` | Sister to the above, but the account is **CageFS**-enabled: the CLI is driven through a real CageFS login, exercising the CPANEL-54672 fallback to the UAPI bridge. | CloudLinux (cgroup v1 or v2), with CageFS installed + initialized, and `ea-memcached16` (or another EA4 container-based package, via `EAPODMAN_TEST_PKG`) already installed locally. |

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
