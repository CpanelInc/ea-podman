# Phase 0 probes (EA4-368 T0.2)

Scripts for the Phase 0 probes in `../PLAN.md`. They were run on the VMs in `../vms.json`, and their results are recorded under "Phase 0 results" in PLAN.md. Each one runs as root on a host where `../eapodman-test-kit/setup.sh <cpuser>` has already run. Each sources `plib.sh`, which sources the kit's `lib.sh`, and prints `RESULT <probe>.<key> <value>` lines. `U=<cpuser>` (default `eapodtest`) and `KIT=<kit dir>` (default `/root/eapodman-test-kit`) override the defaults.

| Script | Probe |
|---|---|
| `p0-1-2.sh` | P0-1 (1.x DB with the new env) and P0-2 (1.x containers from cgroupfs units; rootful `rename`). It moves the account's default storage aside and restores it afterwards |
| `p0-3-hidepid.sh` | P0-3: what a stop does under `hidepid` (EA4-366); the kit's `lifecycle.sh` covers the rest |
| `p0-4.sh [basic\|floor\|cpu]` | P0-4, beyond the kit's `loadtest.sh` |
| `p0-5.sh` | P0-5: journald, `podman logs`, events |
| `p0-6.sh run\|post\|clean` | P0-6 (CloudLinux): `PAMName=ea-podman` with `pam_lve` |
| `p0-8.sh` | P0-8: `CONTAINERS_CONF` and `XDG_CONFIG_HOME` with a hostile `~/.config/containers` |
| `p0-9.sh` | P0-9 and the cage parts of P0-7 |
| `p0-10.sh pre\|post` | P0-10: a CLOS-7971 stand-in canary, and the reboot checks (reboot between `pre` and `post`) |
| `p0-11.sh` | P0-11: the bounded `systemd-run` runner |
| `p0-12.sh` | P0-12: loads a **test-only** BPF-LSM program (`p0-12/userns_guard.bpf.c`) and detaches it on exit. Needs clang, bpftool and libbpf headers |
| `p0-13.sh` | P0-13: `podman exec` placement, including 1.x parity |
| `f17-switch.sh flip\|check\|restore` | F17: a real cgroup v1 ↔ v2 switch on EL8 (reboot after `flip` and after `restore`) |

`results/<vm>/` holds the logs from the 2026-11-06 run. The `kit-*.log` files there are the kit's own scripts.

These change the host: `p0-6.sh` writes `/etc/pam.d/ea-podman`, `f17-switch.sh` edits the kernel command line, and `p0-1-2.sh` and `p0-13.sh` start the account's `user@` (on CloudLinux through a `/run/systemd/system` copy). Run them only on test VMs.
