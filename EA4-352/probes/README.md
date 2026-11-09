# Phase 0 probes (EA4-368 T0.2)

Scripts for the Phase 0 probes in `../PLAN.md`. They were run on the VMs in `../vms.json`, and their results are recorded under "Phase 0 results" in PLAN.md. Each one runs as root on a host where `../eapodman-test-kit/setup.sh <cpuser>` has already run. Each sources `plib.sh`, which sources the kit's `lib.sh`, and prints `RESULT <probe>.<key> <value>` lines. `U=<cpuser>` (default `eapodtest`) and `KIT=<kit dir>` (default `/root/eapodman-test-kit`) override the defaults.

| Script | Probe |
|---|---|
| `p0-1-2.sh` | P0-1 (1.x DB with the new env) and P0-2 (1.x containers from cgroupfs units; rootful `rename`). It moves the account's default storage aside and restores it afterwards |
| `p0-3-hidepid.sh` | P0-3: what a stop does under `hidepid` (EA4-366); the kit's `lifecycle.sh` covers the rest |
| `p0-4.sh [basic\|floor\|cpu]` | P0-4, beyond the kit's `loadtest.sh`. `FLOOR=min p0-4.sh floor` repeats the floor test with `MemoryMin=` (T0.6) |
| `p0-5.sh` | P0-5: journald, `podman logs`, events |
| `p0-6.sh run\|post\|clean` | P0-6 (CloudLinux): `PAMName=ea-podman` with `pam_lve` |
| `p0-8.sh` | P0-8: `CONTAINERS_CONF` and `XDG_CONFIG_HOME` with a hostile `~/.config/containers` |
| `p0-9.sh` | P0-9 and the cage parts of P0-7 |
| `p0-10.sh pre\|post` | P0-10: a CLOS-7971 stand-in canary, and the reboot checks (reboot between `pre` and `post`) |
| `p0-11.sh` | P0-11: the bounded `systemd-run` runner |
| `p0-12.sh` | P0-12: loads a **test-only** BPF-LSM program (`p0-12/userns_guard.bpf.c`) and detaches it on exit. Needs clang, bpftool and libbpf headers |
| `p0-13.sh` | P0-13: `podman exec` placement, including 1.x parity |
| `t0-6.sh basic\|units\|swap` | T0.6:<br>• `basic`: host defaults (nproc, tasks, logind's runtime dir), 1.x parity, runtime-dir use, exit codes without the journal, and a fork storm against the slice's `TasksMax`<br>• `units`: `daemon-reload` cost against the number of units<br>• `swap`: `--memory-swap` with a temporary swap file |
| `t0-8.sh bash\|health\|ptrace` | T0.8 (F20, F24):<br>• `bash`: the account's own process on a pty, moved by root into `<unit>/ea-podman-exec`, runs `podman exec -it`; a unit stop with the session live; a leaf the account froze first<br>• `health`: health checks with no user manager, with `DISABLE_HC_SYSTEMD=true`, and from a root timer whose helper places itself in `<unit>/ea-podman-health`<br>• `ptrace`: can the account attach to its own conmon and container init |
| `f15-1x.sh` | F15 / T0.4: SIGKILL a 1.x container's conmon under the account's own `user@`, with 1.x's generated unit (unmasked hosts) |
| `f17-switch.sh flip\|check\|restore` | F17: a real cgroup v1 ↔ v2 switch on EL8 (reboot after `flip` and after `restore`) |

`results/<vm>/` holds the logs from the 2026-11-06 run, and the `t0-8-*.log` files from 2026-11-09. `p0-8.log`, `p0-3-hidepid.log`, `t0-6-basic.log`, `p0-12.log`, `p0-4-floor.log` and `kit-verify.log` were re-run on all 9 on 2026-11-09 after the PR #43 review fixes, and carry the script hashes described below (the p0-3 part of `p0-3-hidepid+p0-10-pre.log` is superseded by `p0-3-hidepid.log`; that file is kept for p0-10). The `kit-*.log` files are the kit's own scripts.

Each probe's log starts with two lines from `plib.sh`: the host (`os`, `kernel`, `cgroup`, `systemd`, `podman`) and the scripts that produced it, as the first 12 hex digits of each file's sha256 (`probe p0-4.sh=… plib.sh=… lib.sh=…`). The probes run from copies without git, so the hashes name the files rather than a commit. To find the commit, hash each revision of the script:

```
git log --format=%h -- EA4-352/probes/p0-4.sh | while read -r c; do
    echo "$c $(git show "$c:EA4-352/probes/p0-4.sh" | sha256sum | cut -c1-12)"; done
```

A result the probe couldn't measure (a command failed, a file couldn't be read, a PID didn't pass `safe_target`) is printed as `RESULT <probe>.<key> INCONCLUSIVE: <why>`, never as a verdict, and the probe then exits 1. A probe that couldn't put back what it changed (a slice property, the account's own `~/.config/containers` in `p0-8.sh`) says so and exits 1 too.

Logs from before 2026-11-09 have no second line and come from earlier revisions of the scripts; some don't match the scripts at HEAD (for example `results/ea4-352-el9/p0-4-cpu.log` names a variable `p0-4.sh` no longer has).

These change the host: `p0-6.sh` writes `/etc/pam.d/ea-podman`, `f17-switch.sh` edits the kernel command line, `t0-6.sh units` and `t0-6.sh swap` add and then remove dummy units and a swap file, `t0-8.sh` adds and then removes test containers, units and timers, and `p0-1-2.sh`, `p0-13.sh` and `f15-1x.sh` start the account's `user@` (on CloudLinux through a `/run/systemd/system` copy). Run them only on test VMs.
