# eapodman-test-kit

A hand-built version of the layout in `../PLAN.md` for one account. It sets up `eapodman.slice`, the account's `eapodman-<uid>.slice`, the anchor unit and three container units, then tests them. Run every script as root on a cgroup v2 host. `<cpuser>` must have subuid/subgid ranges.

## Run order

```
./setup.sh <cpuser>             # build the layout and start web, api and worker
./verify.sh <cpuser>            # where everything landed and what each cgroup enforces
./loadtest.sh <cpuser>          # CPU and memory limits under load (F12, F13)
./lifecycle.sh <cpuser>         # crash recovery and hostile conmon.pid (P0-3, F15); run last
./teardown.sh <cpuser> --purge  # remove everything, including the test storage
```

`verify.sh` and `lifecycle.sh` exit non-zero if a check fails.

**Run `lifecycle.sh` last, just before teardown.** Its tests 1 and 3 kill conmon. That leaves web and worker failed until they are recreated (F15). `loadtest.sh` needs all three units running, so it can't run after `lifecycle.sh`. Until F15 is fixed, expect `lifecycle.sh` to exit 1 with those 2 checks failed. A recovery failure is marked `(known: F15, see PLAN.md)` only when the unit's journal carries F15's own failed-restart line, `container state improper`. (`Failed with result 'signal'` doesn't count: the test's own kill always produces it.) Otherwise it's marked `NEW` and the journal is printed. With both known, the last line says `2 check(s) failed, all known (F15)`. If a known check starts passing, the script says to update `PLAN.md`.

To run anything again after `lifecycle.sh`, recreate the containers with `./teardown.sh <cpuser>` and then `./setup.sh <cpuser>`.

`setup.sh` copies the units it writes into `systemd/`, for reference. `teardown.sh` removes those copies. Don't commit them.

Run the kit once at a time per account. Two runs against the same account share its containers, slice limits and test unit name.

## Guards

- No script signals a PID it hasn't checked: it must be an integer above 1, with the expected comm, inside the expected cgroup (`safe_target` in `lib.sh`).
- A test whose setup didn't happen fails instead of passing vacuously. For example, the hostile PID must be in `conmon.pid` before conmon is killed, systemd must log its refusal, and the background loads must still be running when measured.
- `loadtest.sh` stops if a container has no `libpod-payload-*` cgroup (`--cgroups=split` not in effect). It skips the floor test where page cache isn't charged to the containers (F13). Its cleanup reads every restored value back.
- `teardown.sh` runs every step, lists the ones that failed, and exits 1 if any did.
- `XDG_CONFIG_HOME` is `/run/ea-podman/xdg/<uid>`: root-owned, holding only a `cni` symlink into the runtime tmpfs (F16). `conf/runtime-mount` rebuilds it on every anchor start.
