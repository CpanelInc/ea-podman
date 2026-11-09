Re-run the EA4-352 PoC on each VM in `EA4-352/vms.json` and tell me whether we still get the results recorded in `EA4-352/probes/results/<vm>/` (and in PLAN.md's "Phase 0 results").

Commit: **no**

(Change that line to **yes if changed** to commit the logs; see "Committing" below.)

Reboots: **no**

(Change that line to **yes** to also run the probes that need a reboot; see "What to run".)

## Before you start
- Run from this branch's HEAD. If `git status` shows changes under `EA4-352/eapodman-test-kit/` or `EA4-352/probes/`, stop and tell me: logs from uncommitted scripts can't be traced to a commit.
- Read `EA4-352/probes/README.md` and `EA4-352/eapodman-test-kit/README.md`. They give each script's modes, what it changes on the host, the kit's run order, and which failures are known.
- Copy HEAD's kit to `/root/eapodman-test-kit` and the probes to `/root/probes` on every VM, replacing what's there.
- Then run `setup.sh eapodtest` on every VM before anything else. Copying the kit doesn't re-render the units or the pinned files, and el8-cgv1, el8-cgv2 and el10 still run units from before F25 (`verify.sh` fails 3 checks there until `setup.sh` completes). `setup.sh` is safe to re-run over a live setup. On EL hosts it may hit EA4-392; see below.
- The VMs are independent, so you can work on them in parallel. On each VM, run one script at a time: the kit and the probes share the account's containers and slice.

## EA4-392 (EL8, EL9, EL10)
`setup.sh` and `teardown.sh` can fail on the EL hosts with `Failed to start transient service unit: Remote peer disconnected` or `Connection timed out`, and PID 1 can stay off the bus: every later `systemd-run` (so every probe) and every new SSH session's scope times out. It isn't a regression, and this run is EA4-392's chance to catch it in the act:
- On el8-cgv1, el8-cgv2, el9 and el10, run `systemd-analyze log-level debug` before the first `setup.sh`, and `systemd-analyze log-level info` when that VM is done.
- When `setup.sh` or `teardown.sh` fails this way, save the script's output, `journalctl -b -o short-precise _PID=1` and `journalctl -b -o short-precise -u dbus-broker` from the start of that run, to `EA4-352/probes/results/<vm>/ea4-392-<n>.log` (one per occurrence).
- Recover with `systemctl daemon-reexec` and check the bus with `timeout 20 systemd-run --quiet --wait --pipe /bin/true`. If that still fails, reboot the VM. Then run the script again (at most 3 times). Don't add bus checks or sleeps to `setup.sh`: they change its timing, and the scripts must stay HEAD's.
- If `setup.sh` never completes, still run that VM's probes, and mark its cells **EA4-392** in the table.

## What to run
On each VM, run every probe and mode in the probes README that applies to that host. For example, `p0-6.sh` only runs on CloudLinux, `p0-12.sh` needs clang, bpftool and libbpf, and `loadtest.sh` stops on cgroup v1 by design. Then run the kit's `verify.sh` and `loadtest.sh`, and run `lifecycle.sh` last of all. Afterwards run `teardown.sh eapodtest` and `setup.sh eapodtest` so the host is left with the kit set up again (EA4-392 applies to these too), and confirm `verify.sh` passes.

With **Reboots: no**, skip `f17-switch.sh` (it really switches cgroup v1 ↔ v2) and the `p0-10.sh pre`/`post` pair, and run `p0-6.sh run` then `p0-6.sh clean` (its `post` needs a reboot; `run` leaves its container enabled for it). With **yes**, run them as the README describes (`p0-6.sh run`, reboot, `p0-6.sh post`, which cleans up), then confirm each host is back on the cgroup version that `vms.json` records. `f17-switch.sh check` re-runs `setup.sh` on EL8, so EA4-392 applies there too.

If a script fails, record what it printed and continue. Don't edit a script during the run: the logs' hash lines have to name HEAD's files. A probe that couldn't measure something prints `RESULT <probe>.<key> INCONCLUSIVE: <why>` and exits 1; that is a result to report, not a reason to re-run.

## Where the logs go
Write each log to `EA4-352/probes/results/<vm>/` under the name the committed log already has (`p0-4-floor.log`, `t0-8-health.log`, `kit-verify.log`, …), overwriting it. A run that has no committed log gets `<probe>-<mode>.log`.

## Comparing
Compare the `RESULT` lines (the kit's PASS/FAIL lines for `kit-*.log`), not the whole log. Ignore timestamps, PIDs and small numeric drift that doesn't change a verdict.

Not regressions:
- `lifecycle.sh` failing the checks its committed `kit-lifecycle.log` for that host already fails (from before the PR #43 review: 1 check on the v1 hosts, 2 on u22, F15's cleanup note on u24). Compare per host, not against a fixed count.
- `loadtest.sh` stopping on the cgroup v1 hosts.
- `loadtest.sh` splitting CPU test A into A1 and A2: the VMs have 3 vCPUs, and the kit measures in two rounds below 4.
- EA4-392 on the EL hosts (above).
- Known quirks: t0-6's `nproc_2x … runner=/` on Ubuntu (dash's `ulimit` has no `-u`), and the exact crun error text in t0-8's `exec_not_moved`, which varies between runs.
- A **new INCONCLUSIVE** where the old log had a verdict: the probes used to turn a failed command into a verdict, so the old value was never measured. Report it, and say what the old log claimed.
- Changes from the second PR #43 review round, which are the script, not the host. Mark these **changed** and say they're expected:
  - `p0-5.log_file_location` now reads `~/.local/share/ea-podman/storage/…` where the old logs printed `/root/…`. The old value came from a tilde-expansion bug in the probe; the `log path:` line above it always had the account's home.
  - `p0-11.all_reaped_on_timeout` is now `INCONCLUSIVE` unless the runner timed out and its script listed its children. If it's INCONCLUSIVE on a host, that is a real finding (the runner didn't run), not noise.
  - `p0-12` prints real `counters: allowed=N denied=M` lines (they were blank) and has two new results, `allowed_by_program` and `denials_by_program`. Treat these as **first run from current script**. `denials_by_program` must be `yes (+4)` or more wherever `supported` is yes; if it's `NO` or INCONCLUSIVE, the denials came from something other than the BPF program, so say so prominently. That puts PLAN.md's P0-12 verdict in doubt.

No committed log comes from HEAD's exact scripts. The ones re-run on 2026-11-09 carry a hash line naming the scripts that produced them; map it to a commit with the recipe in the probes README (F25 changed `lib.sh` after most of them). The older logs have no hash line and predate the review. Where a result differs, say whether the cause is the script change or the host. Use the hash lines, the probe's git history and PLAN.md to decide.

## What to send back
1. A VM × probe table with one mark per cell: **same**, **changed**, **new INCONCLUSIVE**, **exit ≠ 0**, **skipped (why)**, **EA4-392**, or **first run from current script**.
2. For every changed cell, the old and new `RESULT` lines and your explanation.
3. Every PLAN.md "Phase 0 results" statement that the new results contradict. Don't edit PLAN.md.
4. For EA4-392: on which VMs and at which step it happened, how many retries it took, and where the `ea4-392-*.log` files are. Don't edit EA4-392.

## Committing
- **no:** don't commit. Leave the new logs in the working tree so I can `git diff` them.
- **yes if changed:** commit only the logs whose results changed or that were the first run from current scripts, plus any `ea4-392-*.log`, and `git checkout` the rest. Also update the dates and lists in the probes README's "results" paragraph. The commit message should list what changed per probe and which PLAN.md statements now disagree.
