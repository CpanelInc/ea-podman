# Live verification plan — EA4-325 (ea-podman) and CPANEL-56732/56733 (webapp plugin)

How to verify both halves of this work on a disposable cPanel VM, and what to
conclude from each result.

## Why this is a plan and not a driver script

Three reasons, in order of weight.

**1. The two suites are mutually destructive, server-wide.**
`ea4-325-upgrade-live.t` runs `remove_containers --all` **as root** twice — once
inside the A3 subtest (line ~1267, whose own comment reads *"that sweep removed
ours too"*) and again in teardown. There is no per-account form of that verb, so
it removes **every account's containers on the box**. If the plugin's force test
has a container alive at that moment, it is destroyed, and the resulting failure
looks like a plugin bug.

A driver that runs both under one command makes that harder to see, not easier.
The rule is one sentence — *never concurrently, verify clean between* — and it
does not need three hundred lines of orchestration.

**2. The thorough part is not the running.**
It is the negative controls in Phase 1 and the combination in Phase 3. A driver
would either skip those or reduce them to a flag nobody sets. Each `.t` already
guards itself, creates its own accounts and tears them down, so a driver adds
almost nothing mechanically.

**3. A single "ALL GREEN" is the signal that has already misled this case three
times** — the three `clean` defects, the pull-dedupe test that tested its own
reimplementation, and the `.incoming`/`.rollback` scan that never matched
anything the product creates. Every one of those was green before it was
understood.

What *is* worth automating is already automated: `setup-remote-live.pl` does the
preflight, the deploy, the recompile and the pre-pull.

---

## Phase 0 — the box

Do this per platform. Both have been used for this work and they disagree in
ways that matter (podman 5.8 vs 4.9, RPM vs deb):

| Platform | Package | podman |
|---|---|---|
| AlmaLinux 9 | RPM | 5.8.x |
| Ubuntu 24.04 | deb | 4.9.x |

1. Fresh disposable VM, cPanel installed and **licensed** — the live tests
   create accounts with `whmapi1 createacct`, which is the first thing an
   expired licence stops.
2. Install ea-podman and the webapp plugin.
3. `dnf install -y ea-memcached16` (optional; without it two subtests skip).
4. Rsync both repos over.
5. Run the preflight, and **keep its output** — it is the provenance record for
   everything below:

```sh
scp t/LiveTests/setup-remote-live.pl root@VM:/root/
ssh root@VM '/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl \
    --ea-podman=/root/ea-podman --plugin=/root/plugins --deploy' | tee phase0.log
```

`--deploy` is the point: without it you are testing the **installed packages**,
not your working tree. The report states which, every run. Read that line.

**Caveat for Phase 1.** If the report says the plugin modules are SYMLINKS into
a repo, then editing "the deployed file" edits the repo. That is fine, but undo
it in the repo, not by re-deploying.

### Run the unit suites here too

CI does not run ea-podman's — the spec has no `%check` — so the VM is the only
place they run against a real install.

**Unlike the live tests, these need CPAN.** A cPanel *development* build ships
`Test::Spec` in `cpanel-lib`; a release build does not, so four pre-existing
test files die at BEGIN on a fresh VM. The preflight reports this now; install
what it names:

```sh
/usr/local/cpanel/3rdparty/perl/542/bin/cpanm --notest Test::Spec Test::Mock::Cmd
cd /root/ea-podman && /usr/local/cpanel/3rdparty/bin/prove -l t/     # 425 tests
```

The four affected files — `PodmanHooks-backup`, `ea-podman-adminbin`, `subids`,
`webapp-dir-setup` — are all outside EA4-325's surface, so skipping them blocks
nothing if you would rather not add CPAN modules to the box.

They should take about 6 seconds. If they take minutes, something is reaching
the network that should not be — that regression has happened once already.

---

## Phase 1 — negative controls, before any green run counts

A passing test proves nothing until it has been seen to fail. Three headline
claims, three mutations. Do these **first**, while the box is clean.

### 1a. The force contract (CPANEL-56732)

> **THIS TEST CURRENTLY SKIPS — do 1a by hand via Phase 3 instead.** Verified on
> AlmaLinux 9.8: `install_app()` reaches ea-podman through its adminbin, which
> checks its PARENT PROCESS against a whitelist (`cpanel`, `uapi`, `xml-api`,
> `cpsrvd`, `queueprocd`, …). A standalone `.t` is not on it and cannot be, so
> the plugin's Podman module cannot be driven from a test script at all. Getting
> past it needs a full UAPI-driven deploy, which is separate work. Phase 3 is
> the only thing covering this contract today.

> **What this test does not reach, even once unblocked.** It calls
> `Cpanel::WebApps::Podman::redeploy_app` directly. It does **not** go through
> `Cpanel::API::WebApp::redeploy` → UserTasks → `Deploy.pm`, which is the path a
> real Redeploy takes. So it pins the contract at the boundary but says nothing
> about the layers above it. That is exactly the gap Phase 3 fills, and the
> reason Phase 3 is not optional.

In the deployed `Cpanel/WebApps/Podman.pm`, drop `force => 1` from
`redeploy_app`, then:

```sh
WEBAPP_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl \
    .../t/Cpanel-WebApps-Podman-redeploy-force-live.t
```

**Expect:** *"the container was actually recreated"* fails — the ID is
unchanged. Note that the call still **succeeds** and returns a sensible
hashref. That is the whole point: nothing else in the system notices.

Restore the flag. Re-run. Expect green.

### 1b. The intake-leftover scan (CPANEL-56733)

Revert `Cleanup::_sweep_staging` to matching `<name>.incoming|<name>.rollback`
against the entries of `staging_root()`.

**Expect:** *"an interrupted re-stage leaves source.rollback, and the sweep
reclaims it"* fails — the rollback survives.

### 1c. The ctime change

Revert `Cleanup::_age_of` to `(stat)[9]`.

**Expect:** *"a rollback is aged from when it was moved"* fails — a rollback
created seconds ago is swept as forty days old.

> 1b and 1c were already mutation-tested at unit level on a dev box. Repeating
> them live is not redundant: the unit tests run on a mocked filesystem, and
> these two defects are both about what real `stat` data does.

### Before leaving Phase 1

The mutations above ran the plugin tests, which create accounts. Confirm they
tore down, and that every mutation has been reverted, before Phase 2:

```sh
/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl --check-clean
git -C /root/plugins diff --stat        # expect: only your intended changes
```

Phase 2's suite reaches every account on the box, so anything Phase 1 left
behind becomes a Phase 2 failure that looks like a defect.

---

## Phase 2 — the real runs, in this order

**ea-podman first, on a clean box**, because it is the one that reaches every
account.

```sh
cd /root/ea-podman
EAPODMAN_LIVE=1 /usr/local/cpanel/3rdparty/bin/perl \
    t/LiveTests/ea4-325-upgrade-live.t | tee phase2-eapodman.log
```

25 subtests, 30 top-level tests. **30/30 on AlmaLinux 9.8 / podman 5.8.2**,
re-confirmed against `592a361` with the working trees deployed.

The two pieces that had never executed — the end-of-run rate-limit diagnostic
and the A3 ghost-account cleanup in `END` (both from `fb02827`) — have now both
run. The ghost cleanup was verified specifically: no `aa*` entry left in
`/var/cpanel/users` afterwards.

### Verify clean before continuing

Leftover state from an interrupted run has already caused failures that looked
like defects. Between suites:

```sh
/usr/local/cpanel/3rdparty/bin/perl /root/setup-remote-live.pl --check-clean
```

Exits 0 when clean, 1 when not, and names what to remove. This is the one part
of the plan worth having as mechanism rather than prose — it is a pure lookup,
and getting it wrong produces failures that look like defects.

Any `aa*` account left behind is the A3 ghost — `userdel -f` leaves
`/var/cpanel/users/<name>`, which root's `clean` then enumerates on every later
run.

### Then the plugin, cheapest first

```sh
WEBAPP_LIVE=1 ... t/Cpanel-WebApps-Cleanup-live.t   # 12 subtests
```

**12/12 on AlmaLinux 9.8 / podman 5.8.2.**

```sh
WEBAPP_LIVE=1 ... t/Cpanel-WebApps-Podman-redeploy-force-live.t
```

**Expect this one to SKIP**, with the adminbin parent-check message. That is
the current known state, not a regression — see 1a. It costs nothing to run and
will start working the day there is an allowed-parent harness.

Verify clean again afterwards.

---

## Phase 3 — the combination the ordering dependency exists for

**`cpanel-54868-e2e-live.t` now covers this.** It was written for exactly this
phase: its stages B and C are the positive half (the fixed pair), and
`CP54868_PROVE_HAZARD=1` builds the dangerous combination below automatically,
by removing `force` from the deployed `Podman.pm` and putting it back. Run that
first; what follows is the manual procedure it automates, kept because seeing
the no-op with your own eyes is still the thing that justifies the release
order.

EA4-325 Increment B makes safe mode the default, which is why CPANEL-56732 must
ship *before* ea-podman 1.0-29.

Build that dangerous combination deliberately:

1. **New** ea-podman (safe mode default) + **old** plugin (`redeploy_app`
   without `force`).
2. Deploy a web app through the UI or UAPI.
3. Change **only its configuration** — environment or startup command. Nothing
   that moves the image.
4. Redeploy.

**Expect the silent no-op:** success reported, container ID unchanged, old
configuration still live. Confirm the ID with
`podman inspect --format '{{.Id}}'` before and after.

Seeing this failure with your own eyes is the justification for the shipping
order. If it does *not* reproduce, the ordering constraint is wrong and the
release plan should change.

Then upgrade the plugin in place and repeat: the same redeploy must now recreate
the container.

---

## Phase 4 — pacing, so results stay readable

Every `upgrade` pulls now, and this suite spends dozens of manifest requests.
Docker Hub meters them **per IP** for anonymous pulls, so two full passes from
one VM in one window can exhaust the budget.

A rate-limited box fails in a genuinely confusing pattern: **forced paths keep
passing from cache while conditional ones abort**, which reads like a bug in the
safe-mode gate. `setup-remote-live.pl` checks up front, and the suite checks
again at the end — but neither can catch a limit reached mid-run.

For repeat runs, point the tests at an image already on the box:

```sh
EAPODMAN_TEST_IMAGE=<local-ref>  WEBAPP_TEST_IMAGE=<local-ref>
```

---

## Phase 5 — what to record

For each platform, capture and put on the ticket:

- OS, cPanel version, podman version, cgroup v1/v2 (all in `phase0.log`)
- **Which copy was under test** — installed package or deployed working tree
- Pass counts per suite, and every subtest that skipped, with why
- Phase 1 results: which mutation produced which failure
- Phase 3 result: did the silent no-op reproduce

A result without the provenance line is not reportable — most of the confusing
failures in this case came from testing a different build than the one being
read.
