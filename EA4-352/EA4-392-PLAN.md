# EA4-392: PID 1 stops answering the account runner on EL8/9/10

## Context

EA4-392 is a sub-task of EA4-352. On the EL test VMs (el8-cgv1, el8-cgv2, el9, el10), the kit's runner fails with `Failed to start transient service unit: Connection timed out` (el8) or `Remote peer disconnected` (el9/el10). The runner is `acct_unit` in `eapodman-test-kit/lib.sh:67-86`, which runs `systemd-run --uid --gid --slice=eapodman-<uid>.slice --unit=… --pipe --wait --collect -p RuntimeMaxSec -p WorkingDirectory --setenv=…`. On EL9/EL10 the system bus can then stay broken for every transient unit and logind session until `daemon-reexec`. It has not been seen on CloudLinux or Ubuntu.

The 2026-11-10 comment changes the picture. `setup.sh` isn't needed: it reproduces 3 of 3 on a **fresh boot**, with `p0-10.sh pre`'s first runner call. A plain `systemd-run /bin/true` just before that call works. Neither PID 1 nor dbus-broker logs anything. The same probes worked on these hosts on 2026-11-06.

This matters for 2.0. `run_as_user_in_slice` (PLAN.md F11, line 530) is the product's only as-user path, and `ensure_runtime` and the scriptlets run the same reload / `set-property` / anchor start / runner sequence. If the product can hit this, every account action and every login on the host fails.

Outcome: a root cause, or a minimal reproducer plus a classification (systemd/dbus-broker bug or something the kit does). Then, if the product is exposed, a T1-A guard and an EA4-372 live test. Separately, the `setup.sh` exit-code fix the ticket asks for.

## Step 1: Narrow it down with cheap host comparisons (no reproduction needed)

From this server over SSH (IPs in `vms.json`), collect the following on all 9 VMs and diff EL against CL and Ubuntu, especially **el9 vs cl9**, which share systemd 252:

- **What changed between 11-06 (worked) and 11-09 (broke).** Run `rpm -qa --last | head -60` and check the dnf history for systemd, dbus-broker, dbus, selinux-policy, polkit, kernel, podman, crun/runc, and passt. A fresh-boot reproduction points at persistent state or a package, not timing.
- `/etc/nsswitch.conf` (passwd/group: `sss`, `systemd`, `altfiles`) and whether sssd or systemd-userdbd is running. PID 1 resolves `--uid` through NSS.
- The bus implementation and versions: dbus-broker vs dbus-daemon (Ubuntu), `busctl --version`, and `/usr/share/dbus-1/system.conf` limits.
- On-disk ea-podman state that survives a reboot: `/etc/systemd/system.control/eapodman-*`, `/etc/systemd/system/ea-podman-*`, `/run/systemd/transient/` leftovers, `systemctl list-units --all 'eapodman-run-*'`, and `getenforce`.

Write a short findings note. If a package update lines up on exactly the four EL hosts, that becomes the main lead for Step 3.

## Step 2: Instrumented reproduction on ea4-352-el9 (fresh boot + `p0-10.sh pre`)

Script it as `probes/ea4-392-capture.sh`, a new helper in the style of `plib.sh`, so the same capture runs on el8 and el10 too:

1. Reboot. Then run `systemd-analyze log-level debug`, `busctl monitor org.freedesktop.systemd1 >/root/busmon.log &`, and dbus-broker's journal with `-f`.
2. Run the runner variables one at a time, with a `systemd-run --wait --pipe /bin/true` bus check between each:
   1. `--uid=1000 --gid=1000 /bin/true` (no slice)
   2. the same + `--slice=eapodman-1000.slice`
   3. the same + `--unit=`, `-p RuntimeMaxSec=`, `-p WorkingDirectory=/home/eapodtest`
   4. the same + the `--setenv` set from `podman_env`
   5. the full `acct_unit` call (`. lib.sh; user_sh true`)

   If the first failing variant still fails after another reboot, it is the trigger.
3. While a call hangs (it has a 25 s window), a background watcher grabs `/proc/1/stack`, `/proc/1/wchan`, `systemctl list-jobs`, `busctl status org.freedesktop.systemd1`, `busctl --system list` (to see whether PID 1's connection is still there), and `gdb -p 1 -batch -ex 'thread apply all bt'` if debuginfo is installable.
4. Save everything to `probes/results/ea4-352-el9/ea4-392-4.log`, in the same format as the existing `ea4-392-{1,2,3}.log`.

Then run the same capture on el8-cgv1 (the `Connection timed out` variant) and on cl9 (the control, which must pass).

## Step 3: Classify and decide

- **systemd/dbus-broker bug** (e.g. it follows a package version, or the stack shows PID 1 or broker internals): pin the minimal reproducer with no ea-podman files involved, search the upstream/RHEL trackers, and record the affected versions. The product still needs a guard if its runner call matches the trigger.
- **Something the kit does** (e.g. a slice drop-in, the anchor's mounts, `Delegate=`, or a property): name the exact thing and say whether the product does the same. Check against PLAN.md F8/F9/F11 and `set_slice_properties`.
- Also settle the ticket's item 4. On el9, `podman_old_storage`'s `mkdir /run/user/1000: permission denied` is consistent with logind already being unable to start `user-runtime-dir@` through PID 1, which would make it an early symptom. Confirm or rule this out from the Step 2 logs.

## Step 4: Product guard and test (only if the product sequence can trigger it)

- Write the T1-A guard into PLAN.md near line 530 (`run_as_user_in_slice`) and `ensure_runtime`. Depending on the cause, this is a remedy for the cause, a bus check before the runner, or a bounded wait for reload/jobs to settle. A timeout must fail the action with a clear "PID 1 didn't answer" error, never a podman verdict.
- Add a live test to EA4-372: fresh boot, then the first runner in a new slice, on every EL host.
- Replace PLAN.md:1335's "Open (EA4-392)" bullet with the result.

## Step 5: `setup.sh` must not take a runner failure for "no such container" (independent of Steps 1–4)

`setup.sh:84-90` treats exit 1 from `as_user podman container exists` as "absent". But `systemd-run` returns 1 when it can't start the unit, so a runner failure leads to `podman create`. The fix:

- Add a runner-vs-command exit-code split to `lib.sh`. For example, `acct_unit` gets a `-r` option that runs the argv under `/bin/sh -c '"$@"; r=$?; [ $r = 1 ] && exit 101; exit $r'`, keeping the existing `/usr/bin/podman` → `"${PODMAN[@]}"` expansion. A 101 then means "the command said 1", and a 1 means "the runner failed".
- In `setup.sh`: `0` = exists, `101` = create, anything else = "couldn't check (runner or podman)", then exit 1.
- Grep the kit and probes for other places that treat a runner's exit 1 as a command verdict. `p0-11.sh:112-127` and `p0-1-2.sh:87` use rc only as works/FAILS, so they're fine. Leave those as they are unless one of them branches on the value.
- Note the rule in the lib.sh comment block (lines 57-66): "a runner failure is never a podman verdict" (T1.5).

## Files

- `EA4-352/eapodman-test-kit/lib.sh` (`acct_unit`) and `setup.sh` (Step 5)
- `EA4-352/probes/ea4-392-capture.sh` (new), and `probes/results/<vm>/ea4-392-<n>.log`
- `EA4-352/PLAN.md` (line 1335, plus the guard near 530 if needed), `probes/README.md` (line 23), and the EA4-392 section of `poc-rerun-prompt.md`
- Commits on `EA4-352-RC`, prefixed `EA4-392:`. Post the findings as an EA4-392 Jira comment once the text has been reviewed.

## Verification

- Step 5: `bash -n` and `shellcheck` on lib.sh and setup.sh. On a CL host, re-run `setup.sh eapodtest` and confirm "already exists; keeping it". With a forced runner failure (e.g. stopping the slice's runner with a bad `--slice` via a temporary override, or with dbus-broker paused), confirm that setup.sh prints "couldn't check" and exits 1 instead of creating.
- Steps 2–3: the capture script fails reproducibly on el9 at an identified variant and passes on cl9. If there's a remedy, run fresh boot + `p0-10.sh pre` 3 of 3 clean on all four EL hosts. Then unblock the EL `p0-10` pre/post and the `p0-11` last section, re-run them, and update their logs and the README.
