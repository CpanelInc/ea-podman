# EA4-392: PID 1 stops answering the account runner on EL8/9/10

## Context

EA4-392 is a sub-task of EA4-352. On the EL test VMs (el8-cgv1, el8-cgv2, el9, el10), the kit's runner fails with `Failed to start transient service unit: Connection timed out` (el8) or `Remote peer disconnected` (el9/el10). The split isn't clean: el9 also logged `Connection timed out` once its bus was already broken (`ea4-352-el9/ea4-392-1.log`). The runner is `acct_unit` in `eapodman-test-kit/lib.sh:67-86`, which runs `systemd-run --uid --gid --slice=eapodman-<uid>.slice --unit=… --pipe --wait --collect -p RuntimeMaxSec -p WorkingDirectory --setenv=…`. On EL9/EL10 the system bus can then stay broken for every transient unit and logind session until `daemon-reexec`. It has not been seen on CloudLinux or Ubuntu.

The 2026-11-10 comment changes the picture. `setup.sh` isn't needed: it reproduces 3 of 3 on a **fresh boot**, with `p0-10.sh pre`'s first runner call. A plain `systemd-run /bin/true` just before that call works. Neither PID 1 nor dbus-broker logs anything. The same probes worked on these hosts on 2026-11-06.

**PLAN.md already records what is probably the cause.** Line 448, in the P0-11 results from 2026-11-06, says: "**SELinux** (EL): PID 1 may not write to a `/tmp` file passed as stdout through `--pipe`; `systemd-run` fails with `Connection timed out` or `Remote peer disconnected`. Use pipes, as 4.2a already says." Those are EA4-392's two errors and its hosts. The ticket doesn't make the connection, and line 448 doesn't say that PID 1 can stay off the bus afterwards. The logs in `probes/results/` point the same way:

- **SELinux lines up exactly.** `kit-verify.log` says `SELinux: Enforcing` on el8-cgv1, el8-cgv2, el9 and el10, and `SELinux disabled` on cl8-cgv1, cl9, cl10, u22 and u24. Those are the four hosts that fail and the five that never have.
- **Something is denied at the moment of failure.** In `ea4-352-el8-cgv1/ea4-392-2.log` the bus check runs at 01:16:37 and `setroubleshootd` starts at 01:16:40, when `p0-10.sh pre` makes its runner call. `ea4-392-1.log` shows the same start at each failure. That daemon starts when a denial is audited, so the ticket's "no AVCs" needs re-checking.
- **The failing calls run with the script's own stdout/stderr.** These are `p0-10.sh:25` (`user_sh`), `setup.sh:84` (`as_user podman container exists`) and `p0-11.sh:120` (`user_build_ctx`). The ~20 p0-11 calls that worked before them are all inside `$(… 2>&1)` or `>/dev/null`. With `--pipe`, `systemd-run` passes those fds to PID 1 over the bus. This part is an inference, not a finding: a denied fd transfer would explain a request that is dropped with nothing logged by PID 1, and the hand-typed sequence working on a tty.

This matters for 2.0. `run_as_user_in_slice` (PLAN.md F11, line 530) is the product's only as-user path, and `ensure_runtime` and the scriptlets run the same reload / `set-property` / anchor start / runner sequence. If the product can hit this, every account action and every login on the host fails. If the cause is line 448's, that sequence has nothing to do with it, and the product is covered as long as it keeps PLAN.md's rule 15 (line 1236) and 4.2a (line 812): stdin from `/dev/null`, stdout/stderr on pipes the runner creates, never inherited. The kit's `acct_unit` doesn't follow that rule. It redirects only stdin.

Outcome: a root cause, or a minimal reproducer plus a classification (SELinux policy, a systemd/dbus-broker bug, or something the kit does). Then a kit fix, and if the product is exposed, a T1-A guard and an EA4-372 live test. Separately, the `setup.sh` exit-code fix the ticket asks for.

**PLAN.md is not edited while this plan runs.** Each step adds what it finds that affects PLAN.md to the list in Step 6. Step 6 makes those edits in one go at the end, and then removes this file.

## Step 0: Confirm that PLAN.md:448 is the cause (minutes, no instrumentation)

On ea4-352-el9, after a fresh boot:

1. Run `cd /root/probes && ./p0-10.sh pre` once so that it fails. Then read `ausearch -m AVC,USER_AVC,SELINUX_ERR -ts boot` and `journalctl -b -t setroubleshoot`. If they show nothing, run `semodule -DB` (which turns off the dontaudit rules), repeat, and run `semodule -B` afterwards.
2. Reboot, run `setenforce 0`, and run `p0-10.sh pre` again. If it passes, the cause is SELinux policy, and Steps 2–3 shrink to naming the denied permission and the fd or object it applies to.
3. With enforcing back on, run the failing `user_sh` call with stdout/stderr to `/dev/null`, to a pipe (`| cat`), to a file in `/tmp` (line 448's case), and to wherever the 2026-11-10 run sent them, with a bus check between each. This shows whether it is the same denial as line 448's, or a second one.

If this confirms line 448, skip Steps 1 and 2 except for what Step 3's SELinux item still needs, and go on to Step 4. If `setenforce 0` changes nothing, drop this lead and carry on with Steps 1–3 as written.

## Step 1: Narrow it down with cheap host comparisons (no reproduction needed)

From this server over SSH (IPs in `vms.json`), collect the following on all 9 VMs and diff EL against CL and Ubuntu, especially **el9 vs cl9**, which share systemd 252:

- **What changed between 11-06 (worked) and 11-09 (broke).** Run `rpm -qa --last | head -60` and check the dnf history for systemd, dbus-broker, dbus, selinux-policy, polkit, kernel, podman, crun/runc, and passt. A fresh-boot reproduction points at persistent state or a package, not timing.
- **How the scripts were run on 11-06 and on 11-09/10.** Was their stdout a tty, a pipe, or a file? Also `git diff` the kit and the probes between the commits behind those two runs, looking for runner calls that became uncaptured (e.g. `user_sh`).
- `/etc/nsswitch.conf` (passwd/group: `sss`, `systemd`, `altfiles`) and whether sssd or systemd-userdbd is running. PID 1 resolves `--uid` through NSS.
- The bus implementation and versions on every host: dbus-broker or dbus-daemon, `busctl --version`, and `/usr/share/dbus-1/system.conf` limits. Check EL8 as well as Ubuntu: el8's `Connection timed out` against el9/el10's `Remote peer disconnected` may only be dbus-daemon against dbus-broker.
- On-disk ea-podman state that survives a reboot: `/etc/systemd/system.control/eapodman-*`, `/etc/systemd/system/ea-podman-*`, `/run/systemd/transient/` leftovers, `systemctl list-units --all 'eapodman-run-*'`, and `getenforce`.

Write a short findings note. If a package update lines up on exactly the four EL hosts, that becomes the main lead for Step 3.

## Step 2: Instrumented reproduction on ea4-352-el9 (fresh boot + `p0-10.sh pre`)

Script it as `probes/ea4-392-capture.sh`, a new helper in the style of `plib.sh`, so the same capture runs on el8 and el10 too:

1. Reboot. Then run `systemd-analyze log-level debug`, `busctl monitor org.freedesktop.systemd1 >/root/busmon.log &`, and dbus-broker's journal with `-f`.
2. Run the runner variables one at a time, with a `systemd-run --wait --pipe /bin/true` bus check between each:
   1. `--uid=1000 --gid=1000 --pipe --wait /bin/true` (no slice), and the same without `--pipe`
   2. the same + `--slice=eapodman-1000.slice`, run twice in a row
   3. the same + `--unit=`, `-p RuntimeMaxSec=`, `-p WorkingDirectory=/home/eapodtest`
   4. the same + `--quiet --collect`, with `/bin/sh -c true` instead of `/bin/true`
   5. the real failing call (`cd /root/probes; . ./plib.sh; user_sh true`). It has no `--setenv`: `user_sh` is `as_user_env`, which is `acct_unit -E`.
   6. `as_user /bin/true`, which adds `podman_env`'s `--setenv` set, as `setup.sh:84` does

   Run each variant twice: once with the script's own stdout/stderr, and once with `>/dev/null 2>&1`. If the first failing variant still fails after another reboot, it is the trigger.

   Variant 2's second run tells "the first runner in the slice after the anchor starts" from "every runner in the slice". For the same question, check in the journal whether `ea-podman-runtime@1000` (re)started before the p0-11 failure in `ea4-392-{1,3}.log`.
3. While a call hangs (it has a 25 s window), a background watcher grabs `/proc/1/stack`, `/proc/1/wchan`, `systemctl list-jobs`, `busctl status org.freedesktop.systemd1`, `busctl --system list` (to see whether PID 1's connection is still there), and `gdb -p 1 -batch -ex 'thread apply all bt'` if debuginfo is installable.
4. Save everything to `probes/results/ea4-352-el9/ea4-392-4.log`, in the same format as the existing `ea4-392-{1,2,3}.log`.

Then run the same capture on el8-cgv1 (the `Connection timed out` variant) and on cl9 (the control, which must pass).

## Step 3: Classify and decide

- **systemd/dbus-broker bug** (e.g. it follows a package version, or the stack shows PID 1 or broker internals): pin the minimal reproducer with no ea-podman files involved, search the upstream/RHEL trackers, and record the affected versions. The product still needs a guard if its runner call matches the trigger.
- **SELinux policy on EL** (Step 0's `setenforce 0` run passes): name the denied permission, the source and target contexts, and what the kit hands over that the policy refuses. The product question is then different: does 2.0's runner ever pass PID 1 an fd it inherited (rule 15 and 4.2a say never), does a pipe created by root's caller pass the policy whatever domain that caller runs in, and which SELinux modes are in the live matrix (F19)?
- **Something the kit does** (e.g. a slice drop-in, the anchor's mounts, `Delegate=`, or a property): name the exact thing and say whether the product does the same. Check against PLAN.md F8/F9/F11 and `set_slice_properties`.
- Also settle the ticket's item 4. On el9, `podman_old_storage`'s `mkdir /run/user/1000: permission denied` is consistent with logind already being unable to start `user-runtime-dir@` through PID 1, which would make it an early symptom. Confirm or rule this out from the Step 2 logs.

## Step 4: Kit fix, product guard and test

- **Kit (if Step 0 confirms line 448).** `acct_unit` in `lib.sh` gives `systemd-run` stdout and stderr on pipes it creates, as the product's runner will, and still returns `systemd-run`'s exit status and keeps the two streams apart. That fixes `setup.sh:84`, `p0-10.sh:25` and `p0-11.sh:120` in one place. Say why in the lib.sh comment block.
- **Product, if the cause is line 448's:** no new guard. Rule 15 and 4.2a already cover it. Add to Step 6's list: the second reason for that rule, and an EA4-372 live test (the runner called with root's stdout redirected to a file, on an enforcing EL host, must work and must leave the bus working).
- **Product, if the cause is something else that the product sequence can trigger:** a T1-A guard near PLAN.md line 530 (`run_as_user_in_slice`) and in `ensure_runtime`. Depending on the cause, this is a remedy for the cause, a bus check before the runner, or a bounded wait for reload/jobs to settle. A timeout must fail the action with a clear "PID 1 didn't answer" error, never a podman verdict. Add the guard's text and an EA4-372 live test (fresh boot, then the first runner in a new slice, on every EL host) to Step 6's list.

## Step 5: `setup.sh` must not take a runner failure for "no such container" (independent of Steps 1–4)

`setup.sh:84-90` treats exit 1 from `as_user podman container exists` as "absent". But `systemd-run` returns 1 when it can't start the unit, so a runner failure leads to `podman create`. The fix:

- Add a runner-vs-command exit-code split to `lib.sh`. For example, `acct_unit` gets a `-r` option that runs the argv under `/bin/sh -c '"$@"; r=$?; [ $r = 1 ] && exit 101; exit $r'`, keeping the existing `/usr/bin/podman` → `"${PODMAN[@]}"` expansion. A 101 then means "the command said 1", and a 1 means "the runner failed".
- In `setup.sh`: `0` = exists, `101` = create, anything else = "couldn't check (runner or podman)", then exit 1.
- Grep the kit and probes for other places that treat a runner's exit 1 as a command verdict. `p0-11.sh:112-127` and `p0-1-2.sh:87` use rc only as works/FAILS, so they're fine. Leave those as they are unless one of them branches on the value.
- Note the rule in the lib.sh comment block (lines 57-66): "a runner failure is never a podman verdict" (T1.5).

## Step 6: Update PLAN.md, then remove this file (last)

Make these PLAN.md edits in one commit once Steps 0–5 are done. Add to the list as the steps run, and strike what the results rule out:

- **Line 1335, "Open (EA4-392)":** replace with the result. If Step 0 confirms line 448, it becomes "Resolved (EA4-392)" and points at line 448. Its claim that the reload / `set-property` / anchor-start sequence is the risk goes.
- **Line 448:** add the consequence it leaves out (on EL9/EL10, PID 1 can stay off the system bus for every transient unit and login until `daemon-reexec`), and the denied permission and contexts from Step 3.
- **Rule 15 (line 1236) and 4.2a (line 812):** add the second reason for "never inherited" next to F10's: on an SELinux-enforcing host, an inherited fd can take PID 1 off the bus.
- **The EA4-372 live test** from Step 4, wherever PLAN.md lists that ticket's live tests.
- **The T1-A guard near line 530,** only if Step 4 needs one.

Then update `probes/README.md` (line 23) and the EA4-392 section of `poc-rerun-prompt.md`, post the findings as an EA4-392 comment, and `git rm EA4-352/EA4-392-PLAN.md`.

## Files

- `EA4-352/eapodman-test-kit/lib.sh` (`acct_unit`; Steps 4 and 5) and `setup.sh` (Step 5)
- `EA4-352/probes/ea4-392-capture.sh` (new, only if Step 2 runs), and `probes/results/<vm>/ea4-392-<n>.log`
- `EA4-352/PLAN.md`, `probes/README.md` (line 23), the EA4-392 section of `poc-rerun-prompt.md`, and this file's removal: all in Step 6
- Commits on `EA4-392` (the branch this plan is on; an earlier draft said `EA4-352-RC`), prefixed `EA4-392:`. Post the findings as an EA4-392 Jira comment once the text has been reviewed.

## Verification

- Step 5: `bash -n` and `shellcheck` on lib.sh and setup.sh. On a CL host, re-run `setup.sh eapodtest` and confirm "already exists; keeping it". With a forced runner failure, confirm that setup.sh prints "couldn't check" and exits 1 instead of creating. Force it with a `systemd-run` shim that exits 1, in a directory put first in `PATH` for that run. Don't pause dbus-broker for this: it hangs every login on the VM. A `RuntimeMaxSec` expiry also makes `systemd-run` return 1, and the 101 mapping reports that as "couldn't check" too, which is right.
- Steps 0 and 4: with the `acct_unit` fix and SELinux enforcing, `setup.sh eapodtest` with its output redirected to a file completes on all four EL hosts, and the bus check passes afterwards.
- Steps 2–3 (if they run): the capture script fails reproducibly on el9 at an identified variant and passes on cl9.
- Whatever the remedy, run fresh boot + `p0-10.sh pre` 3 of 3 clean on all four EL hosts. Then unblock the EL `p0-10` pre/post and the `p0-11` last section, re-run them, and update their logs and the README.
