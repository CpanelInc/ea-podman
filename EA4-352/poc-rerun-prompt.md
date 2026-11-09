Re-run the EA4-352 PoC on each VM in `EA4-352/vms.json` and tell me whether we still get the results recorded in `EA4-352/probes/results/<vm>/` (and in PLAN.md's "Phase 0 results").

Commit: **no**

(Change that line to **yes if changed** to commit the logs; see "Committing" below.)

Reboots: **no**

(Change that line to **yes** to also run the probes that need a reboot; see "What to run".)

## Before you start
- Run from this branch's HEAD. If `git status` shows changes under `EA4-352/eapodman-test-kit/` or `EA4-352/probes/`, stop and tell me: logs from uncommitted scripts can't be traced to a commit.
- Read `EA4-352/probes/README.md` and `EA4-352/eapodman-test-kit/README.md`. They give each script's modes, what it changes on the host, the kit's run order, and which failures are known.
- Copy HEAD's kit to `/root/eapodman-test-kit` and the probes to `/root/probes` on every VM, replacing what's there. The kit is already set up for `eapodtest` on all 9. Only run `setup.sh` again after a `teardown.sh`.
- The VMs are independent, so you can work on them in parallel. On each VM, run one script at a time: the kit and the probes share the account's containers and slice.

## What to run
On each VM, run every probe and mode in the probes README that applies to that host. For example, `p0-6.sh` only runs on CloudLinux, `p0-12.sh` needs clang, bpftool and libbpf, and `loadtest.sh` stops on cgroup v1 by design. Then run the kit's `verify.sh` and `loadtest.sh`, and run `lifecycle.sh` last of all. Afterwards run `teardown.sh eapodtest` and `setup.sh eapodtest` so the host is left with the kit set up again.

With **Reboots: no**, skip `f17-switch.sh` (it really switches cgroup v1 ↔ v2) and the `p0-10.sh pre`/`post` pair. With **yes**, run them as the README describes, then confirm each host is back on the cgroup version that `vms.json` records.

If a script fails, record what it printed and continue. Don't edit a script during the run: the logs' hash lines have to name HEAD's files.

## Where the logs go
Write each log to `EA4-352/probes/results/<vm>/` under the name the committed log already has (`p0-4-floor.log`, `t0-8-health.log`, `kit-verify.log`, …), overwriting it. A run that has no committed log gets `<probe>-<mode>.log`.

## Comparing
Compare the `RESULT` lines (the kit's PASS/FAIL lines for `kit-*.log`), not the whole log. Ignore timestamps, PIDs and small numeric drift that doesn't change a verdict.

Not regressions:
- `lifecycle.sh` exiting 1 with `2 check(s) failed, all known (F15)`.
- `loadtest.sh` stopping on the cgroup v1 hosts.
- The VMs have 3 vCPUs, not the 4 the kit's CPU test A assumes. Compare against what the committed log shows for that host.

Only the logs re-run on 2026-11-09 (listed in the probes README) come from current scripts. The older logs have no hash line. Where one of those differs, say whether the cause is the script change or the host. Use the probe's git history and PLAN.md to decide.

## What to send back
1. A VM × probe table with one mark per cell: **same**, **changed**, **new INCONCLUSIVE**, **exit ≠ 0**, **skipped (why)**, or **first run from current script**.
2. For every changed cell, the old and new `RESULT` lines and your explanation.
3. Every PLAN.md "Phase 0 results" statement that the new results contradict. Don't edit PLAN.md.

## Committing
- **no:** don't commit. Leave the new logs in the working tree so I can `git diff` them.
- **yes if changed:** commit only the logs whose results changed or that were the first run from current scripts, and `git checkout` the rest. Also update the dates and lists in the probes README's "results" paragraph. The commit message should list what changed per probe and which PLAN.md statements now disagree.
