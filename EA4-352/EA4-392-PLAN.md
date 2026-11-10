# EA4-392: PID 1 stops answering the account runner on EL8/9/10

## Context

EA4-392 is a sub-task of EA4-352. On the EL test VMs (el8-cgv1, el8-cgv2, el9, el10), the kit's runner failed with `Failed to start transient service unit: Connection timed out` or `Remote peer disconnected`, and on EL9/EL10 the system bus then stayed broken for every transient unit and logind session until `daemon-reexec`. It has not been seen on CloudLinux or Ubuntu. The runner is `acct_unit` in `eapodman-test-kit/lib.sh`.

**The cause is found (Step 0, el9).** With SELinux enforcing, `systemd-run --pipe` hands its own stdout and stderr to PID 1. When one of them is a file under `/tmp`, `/var/tmp`, `/root` or a home directory, PID 1 drops off the system bus. PLAN.md:448 already said most of this on 2026-11-06, and the product's rule 15 (PLAN.md:1236) and 4.2a (PLAN.md:812) already forbid it: stdin from `/dev/null`, stdout/stderr on pipes the runner creates, never inherited. The kit's `acct_unit` broke that rule. The reload / `set-property` / anchor-start sequence that the ticket suspected has nothing to do with it.

**PLAN.md is not edited while this plan runs.** What affects PLAN.md is collected in Step 6, which makes those edits in one go at the end and then removes this file.

## Step 0: Confirm that PLAN.md:448 is the cause — done (el9, 2026-11-10)

Log: `probes/results/ea4-352-el9/ea4-392-4.log`.

- **It is SELinux.** The same call fails when enforcing, passes after `setenforce 0`, and fails again after `setenforce 1`. The five hosts that never fail have SELinux disabled (`kit-verify.log`).
- **A bare call is enough:** `systemd-run --uid=1000 --gid=1000 --pipe --wait --collect /bin/true </dev/null`. No slice, unit name, kit file or anchor restart is involved.

  | stdout/stderr of `systemd-run` | Result (enforcing) |
  |---|---|
  | `/dev/null`, a pipe | passes |
  | file in `/run` (`var_run_t`) or `/var/log` (`var_log_t`), opened with `>` | passes |
  | file in `/tmp` or `/var/tmp` (`user_tmp_t`), opened with `>` | fails |
  | file in `/tmp`, opened with `>>` | passes |
  | file in `/home/eapodtest` (`user_home_t`), opened with `>` | fails |
  | file in `/root` (`admin_home_t`), opened with `>` or `>>` | fails |
  | only stdout, or only stderr, on such a file | fails |

- **PID 1 leaves the bus.** After a failing call, `busctl --system list` shows `org.freedesktop.systemd1` with no owner, until `daemon-reexec`. That is why logind's session scopes time out.
- **The denial:** `avc: denied { write } for comm="systemd" scontext=init_t tcontext=user_tmp_t tclass=file` in `/var/log/audit/audit.log`, and the same for `user_home_t` and `admin_home_t` (for which `{ append }` is denied too). PID 1 may not write to the file it was handed.
- **Why the ticket says "no AVCs".** `ausearch` reads its stdin instead of the logs when stdin isn't a tty, so over `ssh -n` or from a script it prints `<no matches>`. Use `ausearch --input-logs`, or grep the log. On el8, `setroubleshootd` reported each denial in the journal.
- **Why it looked timing-dependent.** gawk sets `O_APPEND` on its stderr. `plib.sh` runs `awk` when it is sourced, so a probe run as `./p0-10.sh pre >/tmp/file 2>&1` has an append-mode stdout by its first runner call, and passes. `setup.sh` doesn't source `plib.sh`, and a file under `/root` fails either way. A tty, a pipe or `$(…)` always passes, which is why the hand-typed sequence and the first ~20 p0-11 calls worked.

## Step 1 and Step 2: dropped

The host comparison and the instrumented capture (`probes/ea4-392-capture.sh`) aren't needed now.

## Step 3: What is left to settle

- **el8-cgv1 — done** (`probes/results/ea4-352-el8-cgv1/ea4-392-4.log`). It is the same denial, and it passes when permissive. The difference is the bus: with dbus-daemon the call fails with `Connection timed out` after 25 s and PID 1 stays on the bus, so the next call works. With dbus-broker (el9) the call fails at once with `Remote peer disconnected` and PID 1 is gone from the bus.
- **el8-cgv2 and el10:** the bare call wasn't run there. With the fixed kit, `setup.sh` completes on both (Step 6), so it isn't needed.
- **A separate denial, the `conmon.pid` unlink — fixed in the kit.** `avc: denied { unlink } for comm="systemd" name=<name>.conmon.pid scontext=init_t tcontext=container_runtime_tmpfs_t`, once per container stop, since 2026-11-06. At stop, PID 1 removes the unit's `PIDFile=`, and the policy lets `init_t` read that type (F19's fix relies on it) but not unlink it. It never broke anything: the stop succeeds, the stale file stays, the next start overwrites it, and invariant 19 refuses a PID outside the unit. But it is one denial per stop in the audit log (and a `setroubleshootd` report on el8), and it kept the F19 check red. The unit now removes the file itself, as the account, in its first `ExecStopPost=` line: `ExecStopPost=-/usr/bin/rm -f <pidfile>`. It must be first, because a failed `ExecStopPost=` line skips the ones after it, and `podman stop` fails there when conmon was SIGKILLed. Checked on el9: no denial on stop, on restart, or after SIGKILL of conmon.
- **The ticket's item 4 — separate from EA4-392.** `podman_old_storage` on el9 still fails with `configure storage: mkdir /run/user/1000: permission denied` in the re-run, with PID 1 on the bus throughout. It is the "session gone" failure that PLAN.md:257 and :383 already describe: the account has no session, so `/run/user/1000` doesn't exist. Not explained: el10 has the same podman (5.8.2) and falls back to `/tmp/storage-run-1000` instead.
- **`verify.sh`'s F19 check had the same `ausearch` blind spot — fixed** (`--input-logs`). Run without a terminal on stdin, it always saw `<no matches>` and passed "no ea-podman AVC denials". With the fix, `verify.sh` failed that check on the EL hosts with the `conmon.pid` unlink denials above, which was a true result: every earlier `kit-verify.log` PASS for it on an EL host says nothing.
- **Which SELinux modes are in the product's live matrix (F19),** and whether a pipe made by root's caller passes the policy from the domain the product's root code runs in. On el9 it does from an SSH root shell (`unconfined_t`).

## Step 4: Kit fix and product guard

- **Kit — done.** `acct_unit` gives `systemd-run` stdout and stderr on pipes it creates, returns `systemd-run`'s exit status and keeps the two streams apart. Checked on el9 with enforcing on: `./p0-10.sh pre` and `./setup.sh eapodtest` with output redirected to a file under `/root` both complete, and PID 1 stays on the bus.
- **Kit, second fix — done.** The first version waited for EOF on those pipes. On cgroup v1 a child that escapes the unit keeps them open (PLAN.md:447: "The runner must stop reading when `systemd-run` exits"), and `p0-11.sh` on el8-cgv1 hung for 57 minutes in its escape section. `acct_unit` now gives its two readers 2 s after `systemd-run` exits and then kills them. Checked on el9 (exit status, separate streams, 20000 lines through a pipe, `-r`, a 3 s timeout, no leaked fds) and on el8-cgv1, where `p0-11.sh` completes in 25 s and the escape section returns after 8 s.
- **Product:** no new guard. Rule 15 and 4.2a already cover it. Step 6 adds the second reason for that rule and an EA4-372 live test.

## Step 5: `setup.sh` must not take a runner failure for "no such container" — done

- `acct_unit -r` returns the command's own exit 1 as 101, so a 1 only ever means the runner failed (`systemd-run` couldn't start the unit, or `RuntimeMaxSec` expired).
- `setup.sh`: `0` = exists, `101` = create, anything else = "couldn't check", then exit 1.
- Checked on el9: with a `systemd-run` shim that exits 1 first in `PATH`, `setup.sh` prints "couldn't check" and exits 1; without it, all three containers are "already exists; keeping it".
- Not done: `shellcheck` isn't installed on this server. `bash -n` passes.
- The probes that read a runner's rc (`p0-11.sh:112-127`, `p0-1-2.sh:87`) use it only as works/FAILS, so they stay as they are.

## Step 6: Roll out, update PLAN.md, then remove this file (last)

1. **Done:** the fixed kit (`lib.sh`, `setup.sh`, `verify.sh`) is on all 9 VMs. `setup.sh eapodtest`, with its output redirected to a file under `/root`, completed first time on el8-cgv1, el8-cgv2 and el10, with SELinux enforcing and PID 1 still on the bus. Their units now have F25's `--default-mounts-file`.
2. **Done for `verify.sh`:** new `kit-verify.log` on el8-cgv1, el8-cgv2, el9 and el10. The 3 F25 failures are gone. Each then had exactly 1 failed check, "no ea-podman AVC denials", for the `conmon.pid` unlink denial (Step 3). **With the `ExecStopPost=` line (2026-11-10):** `setup.sh` re-run on all 9 VMs, the four EL hosts rebooted, then a container restarted and another stopped and started on each. `verify.sh` has 0 failed checks on all 9, and each `kit-verify.log` is new. **Done for the probes (2026-11-10):** `p0-11.sh`, `p0-10.sh pre`, a reboot and `p0-10.sh post` on el8-cgv1, el8-cgv2, el9 and el10, each with its output redirected to a file under `/root` and SELinux enforcing. Every run returned 0 with PID 1 on the bus. Logs: `p0-11.log`, `p0-10-pre.log` and `p0-10-post-reboot.log` in each host's results directory. After the reboot the canary never ran, the anchor and all three units are active and the ports answer 200. p0-11's last section now has results on all four: `build` works from both runners, and `run --rm` from the plain runner fails on the v2 hosts as F22 says. el8-cgv1's `p0-11.log` is from the second kit fix (Step 4).
3. Make these PLAN.md edits in one commit. Add to the list if Step 3 turns up more, and strike what it rules out:
   - **Line 1335, "Open (EA4-392)":** becomes "Resolved (EA4-392)" and points at line 448. Its claim that the reload / `set-property` / anchor-start sequence is the risk goes.
   - **Line 448:** it isn't only a `/tmp` file. Say "a file under `/tmp`, `/var/tmp`, `/root` or a home directory", that append mode passes for `/tmp` but not for `/root`, the denial (`init_t` `{ write }` on `user_tmp_t`, `user_home_t` or `admin_home_t`), that with dbus-daemon (EL8) only the call fails, and that on EL9/EL10 PID 1 then stays off the system bus for every transient unit and login until `daemon-reexec`.
   - **Rule 15 (line 1236) and 4.2a (line 812):** add the second reason for "never inherited" next to F10's: on an SELinux-enforcing host, an inherited file can take PID 1 off the bus.
   - **Wherever PLAN.md or the probes tell someone to look for AVCs:** `ausearch` needs `--input-logs` when it isn't run from a terminal.
   - **The `conmon.pid` unlink denial** from Step 3: Phase 1's unit shape (line 509) gets `ExecStopPost=-/usr/bin/rm -f {PIDFILE}` as its first `ExecStopPost=` line, the rootful unit included, with the reason. F19 (lines 251-254) gets the denial and this fix, and its "no AVC denials on EL9 or EL10" is corrected: that was `ausearch` reading stdin. Add a live test: on an enforcing EL host, stop, restart and a SIGKILLed conmon log no AVC.
   - **4.2a (line 812):** check that it carries line 447's "the runner must stop reading when `systemd-run` exits". The kit's first fix broke exactly that, so it needs a test: on a v1 host, a child that escapes with the pipes open doesn't delay the runner's return.
   - **The EA4-372 live test:** the runner called with root's stdout and stderr redirected to a file under `/root`, on an enforcing EL host, works and leaves `org.freedesktop.systemd1` owned on the bus.
4. Update `probes/README.md` (line 23) and the EA4-392 section of `poc-rerun-prompt.md`.
5. Post the findings as an EA4-392 comment once the text has been reviewed, and `git rm EA4-352/EA4-392-PLAN.md`.

## Files

- `EA4-352/eapodman-test-kit/lib.sh` (`acct_unit`) and `setup.sh`: changed in Steps 4 and 5
- `EA4-352/probes/results/<vm>/ea4-392-4.log`: el9 and el8-cgv1
- `EA4-352/PLAN.md`, `probes/README.md`, `poc-rerun-prompt.md`, and this file's removal: all in Step 6
- Commits on `EA4-392`, prefixed `EA4-392:`.
