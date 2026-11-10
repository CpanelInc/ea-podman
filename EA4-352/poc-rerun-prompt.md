Re-run the EA4-352 PoC on each VM in `EA4-352/vms.json` and tell me whether we still get the results recorded in `EA4-352/probes/results/<vm>/` (and in PLAN.md's "Phase 0 results").

Commit: **no**

(Change that line to **yes if changed** to commit the logs; see "Committing" below.)

Reboots: **no**

(Change that line to **yes** to also run the probes that need a reboot; see "What to run".)

## Before you start
- Run from this branch's HEAD. If `git status` shows changes under `EA4-352/eapodman-test-kit/` or `EA4-352/probes/`, stop and tell me: logs from uncommitted scripts can't be traced to a commit.
- Read `EA4-352/probes/README.md` and `EA4-352/eapodman-test-kit/README.md`. They give each script's modes, what it changes on the host, the kit's run order, and which failures are known.
- Copy HEAD's kit to `/root/eapodman-test-kit` and the probes to `/root/probes` on every VM, replacing what's there.
- Then run `setup.sh eapodtest` on every VM before anything else. Copying the kit doesn't re-render the units or the pinned files. `setup.sh` is safe to re-run over a live setup.
- The VMs are independent, so you can work on them in parallel. On each VM, run one script at a time: the kit and the probes share the account's containers and slice.

## EA4-392 (EL8, EL9, EL10): fixed, so a recurrence is a regression
Until 2026-11-10, `setup.sh`, `teardown.sh` and the probes could fail on the EL hosts with `Failed to start transient service unit: Remote peer disconnected` or `Connection timed out`, and on EL9/EL10 PID 1 then stayed off the bus. The cause was SELinux: the kit's runner passed its own stdout and stderr to `systemd-run --pipe`, and PID 1 may not write to a file under `/tmp`, `/var/tmp`, `/root` or a home directory (PLAN.md, P0-11's SELinux result). The runner now uses its own pipes, so you can redirect a script's output to any file.

If you see either error again:
- Save the script's output, how its stdout and stderr were redirected, and `ausearch --input-logs -m avc,user_avc -ts recent` to `EA4-352/probes/results/<vm>/ea4-392-<n>.log` (one per occurrence). Without `--input-logs`, `ausearch` reads its stdin and prints `<no matches>`.
- Check the bus with `busctl --system list | grep org.freedesktop.systemd1`. If it has no owner, recover with `systemctl daemon-reexec`, or reboot the VM if that fails.
- Run the script once more, mark its cell **EA4-392** in the table, and report it prominently.

## What to run
On each VM, run every probe and mode in the probes README that applies to that host. For example, `p0-6.sh` only runs on CloudLinux, `p0-12.sh` needs clang, bpftool and libbpf, and `loadtest.sh` stops on cgroup v1 by design. Then run the kit's `verify.sh` and `loadtest.sh`, and run `lifecycle.sh` last of all. Afterwards run `teardown.sh eapodtest` and `setup.sh eapodtest` so the host is left with the kit set up again, and confirm `verify.sh` passes.

With **Reboots: no**, skip `f17-switch.sh` (it really switches cgroup v1 ↔ v2) and the `p0-10.sh pre`/`post` pair, and run `p0-6.sh run` then `p0-6.sh clean` (its `post` needs a reboot; `run` leaves its container enabled for it). With **yes**, run them as the README describes (`p0-6.sh run`, reboot, `p0-6.sh post`, which cleans up), then confirm each host is back on the cgroup version that `vms.json` records.

If a script fails, record what it printed and continue. Don't edit a script during the run: the logs' hash lines have to name HEAD's files. A probe that couldn't measure something prints `RESULT <probe>.<key> INCONCLUSIVE: <why>` and exits 1; that is a result to report, not a reason to re-run.

## Where the logs go
Write each log to `EA4-352/probes/results/<vm>/` under the name the committed log already has (`p0-4-floor.log`, `t0-8-health.log`, `kit-verify.log`, …), overwriting it. A run that has no committed log gets `<probe>-<mode>.log`.

## Comparing
Compare the `RESULT` lines (the kit's PASS/FAIL lines for `kit-*.log`), not the whole log. Ignore timestamps, PIDs and small numeric drift that doesn't change a verdict.

Not regressions:
- `lifecycle.sh` failing the checks its committed `kit-lifecycle.log` for that host already fails (from before the PR #43 review: 1 check on the v1 hosts, 2 on u22, F15's cleanup note on u24). Compare per host, not against a fixed count.
- `loadtest.sh` stopping on the cgroup v1 hosts.
- `loadtest.sh` splitting CPU test A into A1 and A2: the VMs have 3 vCPUs, and the kit measures in two rounds below 4.
- Known quirks: t0-6's `nproc_2x … runner=/` on Ubuntu (dash's `ulimit` has no `-u`), and the exact crun error text in t0-8's `exec_not_moved`, which varies between runs.
- A **new INCONCLUSIVE** where the old log had a verdict: the probes used to turn a failed command into a verdict, so the old value was never measured. Report it, and say what the old log claimed.
- Changes from the EA4-392 kit fixes, which are the script, not the host. Mark these **changed** and say they're expected:
  - `p0-11.escape_wait_returned_after_s` on the cgroup v1 hosts is about 8 where older logs have 30: the kit's runner now stops reading its pipes 2 s after `systemd-run` exits.
  - `verify.sh`'s "no ea-podman AVC denials" check now reads the audit log. An older EL `kit-verify.log` that passed it proves nothing.
- Changes from the second PR #43 review round, which are the script, not the host. Mark these **changed** and say they're expected:
  - `p0-5.log_file_location` now reads `~/.local/share/ea-podman/storage/…` where the old logs printed `/root/…`. The old value came from a tilde-expansion bug in the probe; the `log path:` line above it always had the account's home.
  - `p0-11.all_reaped_on_timeout` is now `INCONCLUSIVE` unless the runner timed out and its script listed its children. If it's INCONCLUSIVE on a host, that is a real finding (the runner didn't run), not noise.
  - `p0-12` prints real `counters: allowed=N denied=M` lines (they were blank) and has two new results, `allowed_by_program` and `denials_by_program`. u24, el10 and cl10 already have them from the 2026-11-09 re-run with `ea534f7`'s `p0-12.sh`, so expect **same** there. Wherever the log has a `load_and_attach` line (the probe prints `supported` only when the answer is no or unknown), and `load_and_attach` is yes, `denials_by_program` must be `yes`: the denied counter rose by at least the number of checks that came back `denied` (4, or 2 on CloudLinux, whose caged shell has no `unshare` or `podman`, so those two are `n/a`). If it's `NO` or INCONCLUSIVE, the denials came from something other than the BPF program, so say so prominently. That puts PLAN.md's P0-12 verdict in doubt.

No committed log comes from HEAD's exact scripts. The ones re-run on 2026-11-09 carry a hash line naming the scripts that produced them; map it to a commit with the recipe in the probes README (F25 changed `lib.sh` after most of them). The older logs have no hash line and predate the review. Where a result differs, say whether the cause is the script change or the host. Use the hash lines, the probe's git history and PLAN.md to decide.

## What to send back
1. A VM × probe table with one mark per cell: **same**, **changed**, **new INCONCLUSIVE**, **exit ≠ 0**, **skipped (why)**, **EA4-392**, or **first run from current script**.
2. For every changed cell, the old and new `RESULT` lines and your explanation.
3. Every PLAN.md "Phase 0 results" statement that the new results contradict. Don't edit PLAN.md.
4. If EA4-392's failure came back: on which VMs and at which step, what the script's stdout and stderr were, the denial, and where the `ea4-392-*.log` files are. Don't edit EA4-392.

## Committing
- **no:** don't commit. Leave the new logs in the working tree so I can `git diff` them.
- **yes if changed:** commit only the logs whose results changed or that were the first run from current scripts, plus any `ea4-392-*.log`, and `git checkout` the rest. Also update the dates and lists in the probes README's "results" paragraph. The commit message should list what changed per probe and which PLAN.md statements now disagree.
