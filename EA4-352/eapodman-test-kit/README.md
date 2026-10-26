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

**Run `lifecycle.sh` last, just before teardown.** Its tests 1 and 3 kill conmon. That leaves web and worker failed until they are recreated (F15). `loadtest.sh` needs all three units running, so it can't run after `lifecycle.sh`. Until F15 is fixed, expect `lifecycle.sh` to exit 1 with those 2 checks failed. They are marked `(known: F15, see PLAN.md)`, and the last line says `2 check(s) failed, all known (F15)`. Any other failure is new. If a known check starts passing, the script says to update `PLAN.md`.

To run anything again after `lifecycle.sh`, recreate the containers with `./teardown.sh <cpuser>` and then `./setup.sh <cpuser>`.

`setup.sh` copies the units it writes into `systemd/`, for reference. `teardown.sh` removes those copies. Don't commit them.
