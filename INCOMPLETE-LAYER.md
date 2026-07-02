# "Found incomplete layer … deleting it" On Podman Operations

```
WARN[0000] Found incomplete layer "bb2bdb763e2b77f9930789f3b5782bf39b6e32c6ad37cb20e50f7bcb32d7be5e", deleting it
```

Podman found a storage layer that was flagged **incomplete** — i.e. a layer whose
record was created but whose contents were never fully written and committed —
and reclaimed it. The message is a `WARN` emitted at store load time (`[0000]`,
before any real work), and podman then continues normally.

This is **self-healing garbage collection**, not a hard error: the leftover layer
is deleted and the store is left consistent. It matters because it is a
*symptom* — it means a previous image pull/build was **interrupted partway
through**, and it can repeat (or block a container from starting with a
missing-layer error) until the store is reconciled and the image is re-pulled
cleanly.

## Why does this happen?

When containers/storage builds a layer (during `podman pull`, `create`/`run`
that triggers a pull, or `build`) it does so in two steps:

1. Write the layer **record** into the layer store and mark it with the
   `incomplete` flag.
2. Unpack/apply the layer's contents, then **clear** the `incomplete` flag and
   save the record.

If the process dies **between** those two steps, the flag is never cleared and
persists on disk in the layer store metadata. The next time the store is opened
**with a write lock**, `load()` sees the still-set flag, logs
`Found incomplete layer … deleting it`, and removes the orphaned layer. That is
the warning above.

In the ea-podman model images are pulled into the **rootless, per-cPanel-account**
store under `$HOME/.local/share/containers/storage` (see `DESIGN.md`). The pull is
driven by `create_user_container` (`podman create …`) inside
`_ensure_latest_container` — there is no explicit `podman pull` step, so the pull
happens implicitly during create. Anything that kills that process mid-pull
leaves an incomplete layer:

* **The account hit its disk quota mid-pull.** This is the most common cause for
  a rootless per-account store: the layer tarball write is truncated when the
  user's quota is exceeded, so step 2 never finishes. The same install then keeps
  failing (and re-orphaning layers) until quota is freed.
* **The install/upgrade was interrupted** — `ea-podman install`/`upgrade` was
  `Ctrl-C`'d, the SSH session dropped, a timeout/job cancellation fired, or the
  process was `SIGKILL`/`SIGTERM`'d.
* **OOM kill** of the pull process under memory pressure.
* **Power loss or a hard reboot** during a pull.
* **Concurrent podman operations** racing on the same per-user store (e.g. two
  installs at once, or an install overlapping the service starting the
  container).

Confirm the cause on the box (as the affected cPanel user, or `su - <user>`):

```sh
# 1. Which store is it? The rootless per-account store lives here:
echo "$HOME/.local/share/containers/storage"
podman info --format '{{.Store.GraphRoot}}'      # should be under the user's HOME

# 2. Is the account out of quota? (truncated writes -> incomplete layers)
quota -s        # or: repquota -s / cPanel disk-usage for the account
df -h "$HOME"

# 3. Any half-pulled / dangling images left behind?
podman images -a
```

## How to fix it?

### Immediate: let podman reconcile the store, then re-pull

The deletion only happens when podman holds the **write lock**, so read-only
commands (`podman images`, `podman ps`) may keep printing the warning without
actually reclaiming anything. Run a write-lock operation to reconcile, then
re-pull the image cleanly:

```sh
# As the affected user. Reclaim the orphaned layer + any dangling images/state:
podman system prune

# Re-pull the image the container needs (implicitly re-pulled on next create):
podman pull <image>          # or simply re-run the ea-podman install/upgrade
```

If a specific container won't start with a missing/incomplete-layer error, remove
and recreate it via ea-podman so the image is pulled fresh:

```sh
ea-podman upgrade <CONTAINER_NAME>     # re-runs _ensure_latest_container
```

### Root cause: give the pull room and don't interrupt it

Because the store is per-account, the durable fixes are about the account, not
the host:

* **Free up / raise the account's disk quota** before installing. A pull needs
  room for the compressed download *and* the unpacked layers; a nearly-full
  account will truncate mid-pull every time.
* **Don't interrupt `ea-podman install`/`upgrade`.** Let it run to completion;
  run long installs under `screen`/`tmux` or as a background job so a dropped SSH
  session can't kill the pull.
* **Avoid concurrent podman operations** on the same account's store.

Once the layer is reclaimed and the underlying cause (usually quota) is
addressed, the warning stops and the image pulls to completion.

## Related hardening in ea-podman

The image pull is implicit in `create_user_container` (`podman create`) called
from `_ensure_latest_container` (`SOURCES/util.pm`). On failure the current code
deregisters the container and `rm`s the container dir, but it does **not**
reconcile the storage layer that was left incomplete, nor retry the pull:

* `_ensure_latest_container` / `create_user_container` — `SOURCES/util.pm`. A
  failed create leaves the half-pulled layer for the *next* podman invocation to
  garbage-collect (hence the `WARN[0000]` on the following command).

Adding an explicit `podman pull` (so pull failures are distinguished from create
failures) and a reconcile-and-retry on pull failure — plus surfacing a clear
"out of disk quota" message when that is the cause — would make installs robust
against interrupted pulls. Tracked separately from this document.
