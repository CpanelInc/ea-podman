
# "device or resource busy" On Image / Layer Deletion

```
WARN[0062] Failed to determine parent of image: loading primary layer store data: 1 error occurred:
    * deleting layer "41444f851582a3ad996f3570c4d1def918ac77bf8cd6839113f6725e0998b7f2": unlinkat /var/lib/containers/storage/overlay/41444f851582a3ad996f3570c4d1def918ac77bf8cd6839113f6725e0998b7f2/merged: device or resource busy
, ignoring the error
```

Podman tried to remove an overlay layer's `merged` directory and the kernel
refused with `EBUSY` because that overlay mount is **still referenced by another
mount namespace**. The message is a `WARN` and podman continues ("ignoring the
error"), but the layer is never reclaimed, so it accumulates and repeats.

## Why does this happen?

Two conditions combine on a cPanel box:

1. **Podman is being run as `root`.** The busy layer is in the *rootful* store —
   `/var/lib/containers/storage/overlay/…`, i.e. the `graphroot` from
   `/etc/containers/storage.conf`. ea-podman is designed to run **rootless,
   per cPanel account** (storage under `$HOME/.local/share/containers`,
   `systemctl --user`, subuid/subgid, linger — see `DESIGN.md`), and rootless
   per-user stores do **not** trigger this. Only the shared root store does.

2. **A `jailshell` user exists and cPanel virtfs mirrored `/var` into their
   jail.** Jailed users (`/usr/local/cpanel/bin/jailshell`) get the host system
   tree bind-mounted into `/home/virtfs/<user>/…` so the jail has a working
   userland. That includes `/var/lib/containers`. When root's podman created the
   overlay mounts, **virtfs replicated them (read-only) into the jail**:

   ```
   overlay on /home/virtfs/<user>/var/lib/containers/storage/overlay/<layer>/merged
     type overlay (ro,nosuid,relatime,lowerdir=…,upperdir=…/diff,workdir=…/work,metacopy=on)
   ```

Root's podman can unmount **its own** copy of the overlay, but it has no
knowledge of the virtfs jail, so the **jail's read-only replica stays mounted**.
That replica keeps the underlying `merged` directory busy, so the final
`unlinkat` fails with `EBUSY`.

Confirm the cause on the box (as root):

```sh
# 1. Is the busy layer in the ROOTFUL store? (path in the warning starts with /var/lib)
#    vs. a per-user rootless store under /home/<user>/.local/share/containers

# 2. Which jail replicas are pinning container storage, and for which users:
grep '/home/virtfs' /proc/mounts | grep 'containers/storage'
grep '/home/virtfs' /proc/mounts | grep 'containers/storage' \
  | sed -E 's#.*/home/virtfs/([^/]+)/.*#\1#' | sort -u

# 3. Confirm those users are jailshell:
getent passwd <user>    # -> …:/usr/local/cpanel/bin/jailshell
```

If the mount source is a per-user home path (`…/.local/share/containers/…`)
rather than `/var/lib/containers/…`, this document does **not** apply — that is a
normal rootless store and the busy handle is a live container/volume for that one
user, not a cross-jail replica.

## How to fix it?

### Immediate: drop the jail replicas, then prune

Lazy-unmount (`-l`) detaches the mount even while it is "busy", which is safe for
these read-only replicas. Unmount deepest paths first, then let podman reclaim:

```sh
# Unmount every container-storage replica pinned in the user's jail:
grep '/home/virtfs/<user>' /proc/mounts | grep 'containers/storage' \
  | awk '{print $2}' | sort -r | while read -r m; do umount -l "$m"; done

# Cleaner alternative — tear the whole jail down so all replicas drop at once:
/usr/local/cpanel/scripts/update_users_jail <user>

# Now root's podman can clean up the orphaned layers:
podman system prune
```

### Recommended: keep containers out of the shared root store

The durable fix is to stop populating `/var/lib/containers` on a host with jailed
users. ea-podman's model is rootless-per-account, and those stores are never
cross-pinned. Audit what put images in the root store:

```sh
podman images ; podman ps -a          # as root — should be empty on an ea-podman box
```

Manual `podman` runs as root, or root running its "own" containers, are the usual
source. Prefer the per-user rootless flow ea-podman provides.

### If a rootful store is genuinely required

Then it must not be mirrored into jails. Either:

* **Relocate the rootful `graphroot` outside `/var`** (virtfs mirrors `/var`) by
  overriding it in `/etc/containers/storage.conf` to a path virtfs does not
  bind-mount, **or**
* **Exclude `/var/lib/containers` from virtfs** so jailed users never replicate
  the overlay mounts.

Either way the jail can no longer pin layers, and root's podman reclaims them
normally.

## Related hardening in ea-podman

The teardown paths delete container directories with no unmount/retry, so they
can surface this same `EBUSY` if a mount is still live:

* `uninstall_container` — `SOURCES/util.pm` (`podman rm` + service teardown).
* `perform_user_restore` — `SOURCES/util.pm`, `remove_tree({ safe => 0 })` on
  `$HOME/ea-podman.d` and `$HOME/.config/systemd/user`.

Wrapping these with an unmount-and-retry-on-EBUSY helper would make teardown
robust against a lingering overlay or `-v` bind mount. Tracked separately from
this document.
