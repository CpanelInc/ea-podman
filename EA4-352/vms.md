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
| ea4-352-cl9 | 10.2.67.236 | CloudLinux 9.8 | **v1** | 7.6.52, enabled | invisible (= 2) | 5.8.2 / crun 1.27 |
| ea4-352-cl10 | 10.2.69.209 | CloudLinux 10 | v2 | 7.6.52, enabled | **none** | 5.8.2 / crun 1.30.1 |
| ea4-352-u22 | 10.2.65.58 | Ubuntu 22.04 | v2 | – | – | 3.4.4 / crun 0.17 |
| ea4-352-u24 | 10.2.65.150 | Ubuntu 24.04 | v2 | – | – | 4.9.3 / crun 1.14.1 |

**Where these differ from the prompt:**
- **Size:** all 9 are 3 vCPU / 3 GB, not 4 vCPU / 8 GB. After your other VMs there were only 28 free cores, and 9 × 4 would need 36. The kit's CPU test A assumes 4 CPUs, so it will need adjusting on these hosts.
- **CL9 is on cgroup v1.** The `cloudlinux-9` image deliberately boots with `systemd.unified_cgroup_hierarchy=0`. Following the prompt, I recorded it rather than changing it. The PoC's CL9 host was on v2; switching this one to v2 is an open decision.
- **CL10 has no hidepid on `/proc`.** Its `/etc/os-release` also says AlmaLinux 10.2, because CloudLinux 10 is layered on AlmaLinux here. `vms.json` records it as CloudLinux and explains both in its notes.
- **CL8's update needed a fix.** The image was CL 8.6, and the update failed a GPG check because CloudLinux's 2025 signing key wasn't imported. I imported it from the key file already on the host, and the update to 8.10 then succeeded.

The OpenStack token is revoked and deleted. The VMs also have a new OpenStack keypair, `ea4-352-root`, which holds this server's public key.
