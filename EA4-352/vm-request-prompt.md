Please create 9 test VMs for EA4-352 (ea-podman cgroup/systemd work) and send back a JSON description of them.

## Access requirement
Root SSH (port 22) must work from 10.2.68.187 with this public key, on every VM:

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCnvLB2rKh6bWEay+HyngZ1IQw+kOWm0kycpzgk26k9+2QIhjnOE34SkHO6gY+WRH1F+IIUZ05OlTBIgnyftm4/0wBGl8XdwnOL4ii8FFzXdbhGpvyuaamkehsueXS32d7O8cXu1jKa7ejIyV8r2hsgAVcBwC8AUxiv0+u3Y5a+l2V7cw/hvLMwW8XFx5EhVLUY1107Pj+xza1pXpWLXehbfLNyRc6tRnrWKM7mwJ1JboOIhIwGOkOVVEkYZer2mbfGlii5K2JCau/atn7m+uCvbUm6LZeUITJqPJHc/exT7v5VTeAWBcAQtJqMuL2ZNX2Bf+Xeb3gbuRhCdy+pFhdx root@10-2-68-187.cprapid.com

Cloud images block root login by default. Pass cloud-init user-data with `disable_root: false` and the key above in `ssh_authorized_keys` (or put it in /root/.ssh/authorized_keys after boot).

## Size
4 vCPU / 8 GB RAM / 40 GB disk preferred, because the test kit's CPU test assumes 4 CPUs. The minimum is 2 vCPU / 2 GB / 20 GB. Use the same size for all 9.

## The VMs
Use vanilla images with no cPanel installed. On the cPanel Houston OpenStack (network `hou-prod-external`), these images exist:
- AlmaLinux: `auto-sync/almalinux-8.10-…`, `auto-sync/almalinux-9.7-…`, `auto-sync/AlmaLinux-10-GenericCloud-10.2-…`
- CloudLinux: `cloudlinux-8`, `cloudlinux-9`, `cloudlinux-10`, all rebuilt 2026-11-01
- Ubuntu: `auto-sync/ubuntu-jammy-22.04-…`, `auto-sync/ubuntu-noble-24.04-…`

| Name | OS | cgroup | Extra setup |
|---|---|---|---|
| ea4-352-el8-cgv1 | AlmaLinux 8 | v1 (EL8 default) | none |
| ea4-352-el8-cgv2 | AlmaLinux 8 | v2 | `grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"`, then reboot |
| ea4-352-el9 | AlmaLinux 9 | v2 (default) | none |
| ea4-352-el10 | AlmaLinux 10 | v2 (default) | none |
| ea4-352-cl8-cgv1 | CloudLinux 8 | v1 (CL8 default; keep it) | CageFS; keep CloudLinux's default `hidepid=2` on /proc |
| ea4-352-cl9 | CloudLinux 9 | v2 (default) | CageFS |
| ea4-352-cl10 | CloudLinux 10 | v2 (default) | CageFS |
| ea4-352-u22 | Ubuntu 22.04 | v2 (default) | none |
| ea4-352-u24 | Ubuntu 24.04 | v2 (default) | none |

## Per-VM setup (all hosts)
1. Fully update the OS (`dnf -y upgrade` / `apt-get -y full-upgrade`) and reboot.
2. Install podman from the distro's own repositories (`dnf -y install podman` / `apt-get -y install podman`). Don't add third-party repos.
3. **CloudLinux hosts only:**
   - The CloudLinux repos must work (`dnf repolist`). If the image isn't licensed, register it (`clnreg_ks --force`, or with an activation key).
   - Install and enable CageFS: `dnf -y install cagefs && cagefsctl --init && cagefsctl --enable-all`.
   - The CageFS version must be 7.6.39 or newer, the version that masks `user@.service`.
   - Don't change CloudLinux's /proc or cgroup defaults.

## Verify each VM over SSH from 10.2.68.187
Record what you find, not what was intended:
- cgroup: `stat -fc %T /sys/fs/cgroup` (`cgroup2fs` = v2, `tmpfs` = v1)
- /proc options: `findmnt -no OPTIONS /proc` (record the `hidepid=` value, or null if absent)
- OS: `. /etc/os-release; echo "$ID $VERSION_ID"`; kernel: `uname -r`
- `podman --version`, and the OCI runtime: `podman info --format '{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}}'`
- CL only: `rpm -q cagefs` and `cagefsctl --cagefs-status`

If a check doesn't match the table (for example, CL8 isn't on v1 or has no `hidepid=2`), report it instead of forcing it.

## What to send back
A JSON array, one object per VM, exactly in this shape:

```json
[
  {
    "name": "ea4-352-cl8-cgv1",
    "ip": "203.0.113.10",
    "provider": "openstack",
    "server_id": "<provider's server id>",
    "ssh": { "user": "root", "port": 22 },
    "os": { "id": "cloudlinux", "version": "8.10", "family": "cloudlinux", "major": 8 },
    "kernel": "4.18.0-...",
    "cgroup": { "requested": "v1", "actual": "v1" },
    "cagefs": { "enabled": true, "version": "7.6.39-1.el8" },
    "hidepid": "2",
    "podman": "4.9.4-rhel",
    "oci_runtime": "runc 1.1.12",
    "vcpus": 4,
    "ram_mb": 8192,
    "tickets": ["EA4-352", "EA4-360", "EA4-366"],
    "notes": ""
  }
]
```

Field rules:
- `os.family` is one of `el`, `cloudlinux` or `ubuntu`.
- `cagefs` is `{"enabled": false, "version": null}` on non-CL hosts.
- `hidepid` is `null` when /proc has no hidepid option.
- `tickets`: use `["EA4-352"]` for most hosts. CL8 also gets EA4-360 (stay on cgroup v1) and EA4-366 (hidepid=2).
