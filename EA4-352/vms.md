# EA4-352 test VMs

All 9 VMs are up, and root SSH from this server works on every one. They're described in `EA4-352/vms.json`. Every value in it was checked over SSH after a reboot. For example, this loop prints each host's cgroup type:

```
jq -r '.[] | "\(.name) \(.ip)"' EA4-352/vms.json | while read -r n ip; do ssh -n root@$ip 'stat -fc %T /sys/fs/cgroup'; done
```

| Name | IP | OS | cgroup | CageFS | hidepid | podman / runtime |
|---|---|---|---|---|---|---|
| ea4-352-el8-cgv1 | 10.2.66.118 | AlmaLinux 8.10 | v1 | – | – | 4.9.4-rhel / runc 1.2.9 |
| ea4-352-el8-cgv2 | 10.2.64.176 | AlmaLinux 8.10 | v2 | – | – | 4.9.4-rhel / runc 1.2.9 |
| ea4-352-el9 | 10.2.68.59 | AlmaLinux 9.8 | v2 | – | – | 5.8.2 / crun 1.27 |
| ea4-352-el10 | 10.2.68.139 | AlmaLinux 10.2 | v2 | – | – | 5.8.2 / crun 1.30.1 |
| ea4-352-cl8-cgv1 | 10.2.65.44 | CloudLinux 8.10 | v1 | 7.6.52, enabled | 2 | 4.9.4-rhel / runc 1.2.9 |
| ea4-352-cl9 | 10.2.67.236 | CloudLinux 9.8 | v2 | 7.6.52, enabled | invisible (= 2) | 5.8.2 / crun 1.27 |
| ea4-352-cl10 | 10.2.69.209 | CloudLinux 10 | v2 | 7.6.52, enabled | **none** | 5.8.2 / crun 1.30.1 |
| ea4-352-u22 | 10.2.65.58 | Ubuntu 22.04 | v2 | – | – | 3.4.4 / crun 0.17 |
| ea4-352-u24 | 10.2.65.150 | Ubuntu 24.04 | v2 | – | – | 4.9.3 / crun 1.14.1 |

**Where these differ from the prompt:**
- **Size:** all 9 are 3 vCPU / 3 GB, not 4 vCPU / 8 GB. After your other VMs there were only 28 free cores, and 9 × 4 would need 36. The kit's CPU test A assumes 4 CPUs, so it will need adjusting on these hosts.
- **CL9 was switched to cgroup v2.** The `cloudlinux-9` image boots on v1 through its tuned profile, `cloudlinux-default-cgv1`. It was switched to match the PoC's CL9 host with `tuned-adm profile cloudlinux-default-cgv2`, which adds `cgroup_no_v1=all`, and a reboot. CageFS stayed enabled, and podman reports cgroup v2 with the systemd cgroup manager.
- **CL10 has no hidepid on `/proc`.** Its `/etc/os-release` also says AlmaLinux 10.2, because CloudLinux 10 is layered on AlmaLinux here. `vms.json` records it as CloudLinux and explains both in its notes.
- **CL8's update needed a fix.** The image was CL 8.6, and the update failed a GPG check because CloudLinux's 2025 signing key wasn't imported. I imported it from the key file already on the host, and the update to 8.10 then succeeded.

**Changed by the T0.2 probe run (2026-11-06; see PLAN.md, Phase 0 results):**
- The kit is set up for `eapodtest` on all 9 hosts (`/root/eapodman-test-kit`, `/etc/eapodman-test`, three containers on ports 8081–8083), with the probes in `/root/probes`.
- **CL10:** `user.max_user_namespaces = 15000` in `/etc/sysctl.d/99-ea4-352-userns.conf`. The image ships `0` (CLOS-2616), which blocks rootless podman.
- **u24:** `lsm=lockdown,capability,landlock,yama,apparmor,bpf` on the kernel command line (`/etc/default/grub.d/99-ea4-352-bpf-lsm.cfg`), for P0-12.
- **EL10, CL10 and u24:** clang, llvm, bpftool and the libbpf headers are installed. strace is installed everywhere, and rsync on CL9 and CL10.
- **EL8 v1 and v2:** each was switched to the other cgroup version and back (F17). Both are on their original version again.

The OpenStack token is revoked and deleted. The VMs also have a new OpenStack keypair, `ea4-352-root`, which holds this server's public key.
