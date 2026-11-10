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
- **Nothing is logged.** There is no AVC, USER_AVC or SELINUX_ERR record, even with the dontaudit rules off (`semodule -DB`). The ticket's "no AVCs" is right. The denied permission isn't named by any log; the table says it is write (and for `/root`, also append) on those file types.
- **Why it looked timing-dependent.** gawk sets `O_APPEND` on its stderr. `plib.sh` runs `awk` when it is sourced, so a probe run as `./p0-10.sh pre >/tmp/file 2>&1` has an append-mode stdout by its first runner call, and passes. `setup.sh` doesn't source `plib.sh`, and a file under `/root` fails either way. A tty, a pipe or `$(…)` always passes, which is why the hand-typed sequence and the first ~20 p0-11 calls worked.

## Step 1 and Step 2: dropped

The host comparison and the instrumented capture (`probes/ea4-392-capture.sh`) aren't needed now.

## Step 3: What is left to settle

- **el8-cgv1, el8-cgv2 and el10:** run the bare call from Step 0's table (`/dev/null`, a pipe, `>` a `/tmp` file, `>` a `/root` file; enforcing and permissive) on each, and save it as `probes/results/<vm>/ea4-392-4.log`. el8 uses a different bus daemon and fails with `Connection timed out`, so check there whether PID 1 stays on the bus.
- **The ticket's item 4** (`podman_old_storage`'s `mkdir /run/user/1000: permission denied` on el9 in p0-11): re-run `p0-11.sh` on el9 with the fixed kit. If it is still there with a working bus, it is separate from EA4-392.
- **Which SELinux modes are in the product's live matrix (F19),** and whether a pipe made by root's caller passes the policy from the domain the product's root code runs in. On el9 it does from an SSH root shell (`unconfined_t`).

## Step 4: Kit fix and product guard

- **Kit — done.** `acct_unit` gives `systemd-run` stdout and stderr on pipes it creates, returns `systemd-run`'s exit status and keeps the two streams apart. Checked on el9 with enforcing on: `./p0-10.sh pre` and `./setup.sh eapodtest` with output redirected to a file under `/root` both complete, and PID 1 stays on the bus.
- **Product:** no new guard. Rule 15 and 4.2a already cover it. Step 6 adds the second reason for that rule and an EA4-372 live test.

## Step 5: `setup.sh` must not take a runner failure for "no such container" — done

- `acct_unit -r` returns the command's own exit 1 as 101, so a 1 only ever means the runner failed (`systemd-run` couldn't start the unit, or `RuntimeMaxSec` expired).
- `setup.sh`: `0` = exists, `101` = create, anything else = "couldn't check", then exit 1.
- Checked on el9: with a `systemd-run` shim that exits 1 first in `PATH`, `setup.sh` prints "couldn't check" and exits 1; without it, all three containers are "already exists; keeping it".
- Not done: `shellcheck` isn't installed on this server. `bash -n` passes.
- The probes that read a runner's rc (`p0-11.sh:112-127`, `p0-1-2.sh:87`) use it only as works/FAILS, so they stay as they are.

## Step 6: Roll out, update PLAN.md, then remove this file (last)

1. Copy the fixed kit to the other eight VMs. Run `setup.sh eapodtest` on el8-cgv1, el8-cgv2 and el10, which still run units from before F25.
2. Re-run what EA4-392 blocked on the four EL hosts: `p0-10.sh pre`/`post`, the last section of `p0-11.sh`, and `verify.sh` on the three hosts above. Update their logs.
3. Make these PLAN.md edits in one commit. Add to the list if Step 3 turns up more, and strike what it rules out:
   - **Line 1335, "Open (EA4-392)":** becomes "Resolved (EA4-392)" and points at line 448. Its claim that the reload / `set-property` / anchor-start sequence is the risk goes.
   - **Line 448:** it isn't only a `/tmp` file. Say "a file under `/tmp`, `/var/tmp`, `/root` or a home directory", that append mode passes for `/tmp` but not for `/root`, that nothing is audited, and that on EL9/EL10 PID 1 then stays off the system bus for every transient unit and login until `daemon-reexec`.
   - **Rule 15 (line 1236) and 4.2a (line 812):** add the second reason for "never inherited" next to F10's: on an SELinux-enforcing host, an inherited file can take PID 1 off the bus.
   - **The EA4-372 live test:** the runner called with root's stdout and stderr redirected to a file under `/root`, on an enforcing EL host, works and leaves `org.freedesktop.systemd1` owned on the bus.
4. Update `probes/README.md` (line 23) and the EA4-392 section of `poc-rerun-prompt.md`.
5. Post the findings as an EA4-392 comment once the text has been reviewed, and `git rm EA4-352/EA4-392-PLAN.md`.

## Files

- `EA4-352/eapodman-test-kit/lib.sh` (`acct_unit`) and `setup.sh`: changed in Steps 4 and 5
- `EA4-352/probes/results/<vm>/ea4-392-4.log`: el9 done, the other three EL hosts in Step 3
- `EA4-352/PLAN.md`, `probes/README.md`, `poc-rerun-prompt.md`, and this file's removal: all in Step 6
- Commits on `EA4-392`, prefixed `EA4-392:`.
