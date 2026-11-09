# eapodman-test-kit

A hand-built version of the layout in `../PLAN.md` for one account. It sets up `eapodman.slice`, the account's `eapodman-<uid>.slice`, the anchor unit and three container units, then tests them. Run every script as root. On cgroup v1, `setup.sh` leaves `cgroups = "split"` out of the pinned config (F17). `verify.sh` then skips the per-container cgroup checks, says why, and checks the v1 layout instead (each container runs in its unit's cgroup); `loadtest.sh` needs the per-container cgroups and stops there. `<cpuser>` must have subuid/subgid ranges.

## Run order

```
./setup.sh <cpuser>             # build the layout and start web, api and worker
./verify.sh <cpuser>            # where everything landed and what each cgroup enforces
./loadtest.sh <cpuser>          # CPU and memory limits under load (F12, F13)
./lifecycle.sh <cpuser>         # crash recovery, hostile conmon.pid, exit 143 on stop (P0-3, F15); run last
./teardown.sh <cpuser> --purge  # remove everything, including the test storage
```

`verify.sh` and `lifecycle.sh` exit non-zero if a check fails. `verify.sh` also fails if it finds fewer than the three container units, rather than passing with nothing checked.

**Run `lifecycle.sh` last, just before teardown.** Its tests 1 and 3 kill conmon. That leaves web and worker failed until they are recreated (F15). `loadtest.sh` needs all three units running, so it can't run after `lifecycle.sh`. Until F15 is fixed, expect `lifecycle.sh` to exit 1 with those 2 checks failed. A recovery failure is marked `(known: F15, see PLAN.md)` only when the unit's journal carries F15's own failed-restart line, `container state improper`. (`Failed with result 'signal'` doesn't count: the test's own kill always produces it.) Otherwise it's marked `NEW` and the journal is printed. With both known, the last line says `2 check(s) failed, all known (F15)`. If a known check starts passing, the script says to update `PLAN.md`.

Test 5 creates a temporary container, `term.<cpuser>.04`, whose PID 1 exits 143 on SIGTERM, and removes it on exit. It checks that a stop ends `Result=success` with the units' `SuccessExitStatus=143`. It also runs the same stop without the directive and prints the result as `INFO`: `failed` there means conmon passed the container's 143 on, which is why the directive stays.

To run anything again after `lifecycle.sh`, recreate the containers with `./teardown.sh <cpuser>` and then `./setup.sh <cpuser>`.

`setup.sh` copies the units it writes into `systemd/`, for reference. `teardown.sh` removes those copies. Don't commit them.

Run the kit once at a time per account. Two runs against the same account share its containers, slice limits and test unit name.

## Guards

- No script signals a PID it hasn't checked: it must be an integer above 1, with the expected comm, inside the expected cgroup (`safe_target` in `lib.sh`).
- A test whose setup didn't happen fails instead of passing vacuously. For example, the hostile PID must be in `conmon.pid` before conmon is killed, systemd must log its refusal, and the background loads must still be running when measured.
- `loadtest.sh` stops if a container has no `libpod-payload-*` cgroup (`--cgroups=split` not in effect). It skips the floor test where page cache isn't charged to the containers (F13). Its cleanup reads every restored value back.
- `teardown.sh` runs every step, lists the ones that failed, and exits 1 if any did.
- Root never creates, chowns or deletes paths in the account's home, where a planted symlink (on the path itself or any parent) would redirect it. `loadtest.sh` makes and removes its scratch dir as the account. `teardown.sh --purge` deletes the storage as the account (`podman system reset`, then `rm` of what's left), before the runtime dir and config go; if that fails it reports it and leaves the files.
- The T0.6 values: each unit's `LimitNPROC` and the create-time `--ulimit nproc` both come from the host's `DefaultLimitNPROC`. The account slice's `TasksMax` is an absolute 33% of `min(threads-max, pid_max)`, because systemd 249-257 writes `set-property TasksMax=33%` as 3.3%. The runtime tmpfs gets logind's `size=10%` and `nr_inodes=size/4096`. `events_logger` and `log_driver` are what the distro's own podman uses: `file` (rotating at 1 MiB) and `k8s-file` on EL and CloudLinux, `journald` on Ubuntu.
- `XDG_CONFIG_HOME` is `/run/ea-podman/xdg/<uid>`: root-owned, holding only a `cni` symlink into the runtime tmpfs (F16). `conf/runtime-mount` rebuilds it on every anchor start.
