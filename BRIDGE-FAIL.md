
# Bridge Failure Error

```
⚛︎ # podman run -d --name nginx-hello -p 8080:8080 docker.io/nginxdemos/hello
WARN[0000] Failed to load cached network config: network podman not found in CNI cache, falling back to loading network podman from disk 
WARN[0000] 1 error occurred:
	* plugin type="bridge" failed (delete): cni plugin bridge failed: running [/usr/sbin/iptables -t nat -D POSTROUTING -s 10.88.6.91 -j CNI-33acff44168dd765996a4596 -m comment --comment name: "podman" id: "50155cd765bb655842adb88e28c3f193c89c470e0cc5174966811239d96b3835" --wait]: exit status 2: iptables v1.8.4 (nf_tables): Chain 'CNI-33acff44168dd765996a4596' does not exist
Try `iptables -h' or 'iptables --help' for more information.

 
Error: plugin type="bridge" failed (add): cni plugin bridge failed: failed to list chains: running [/usr/sbin/iptables -t nat -S --wait]: exit status 1: iptables v1.8.4 (nf_tables): table `nat' is incompatible, use 'nft' tool.
```

## Why does this happen?

This box manages its firewall entirely with **nftables** (cPanel's firewall, Host
Access Control, and outbound-SMTP restrictions are all native `nft` tables). The
`/usr/sbin/iptables` binary here is **not** real iptables — it is the
`xtables-nft` compatibility shim (`iptables v1.8.4 (nf_tables)`, i.e.
`/usr/sbin/iptables -> xtables-nft-multi`) that translates iptables commands into
nftables operations.

Podman is pinned to the **legacy `cni` network backend**
(`podman 4.4.1`, `network_backend = "cni"` in
`/usr/share/containers/containers.conf`). The CNI `bridge` plugin sets up
container networking by **shelling out to `/usr/sbin/iptables`** to add masquerade
rules to the `nat` table and forward rules to the `filter` table — i.e. it drives
the nft shim.

The shim then chokes because **other native-`nft` tables register base chains at
the exact same `(hook, priority)` as the iptables built-in chains it expects to
own**:

| Native-nft table | Base chain | hook / priority | Collides with iptables built-in |
|---|---|---|---|
| `ip cpanel_smtp_restrict` | `output_nat`    | `nat` / output / `-100` | `ip nat` **OUTPUT** |
| `ip cpanel_smtp_restrict` | `output_filter` | `filter` / output / `0` | `ip filter` **OUTPUT** |
| `inet filter` (cPanel Host Access Control) | INPUT/FORWARD/OUTPUT | `filter` / `0` | `ip filter` INPUT/FORWARD/OUTPUT |

`xtables-nft` 1.8.4 cannot represent two base chains sharing the same hook and
priority, so it declares the whole table unusable —
`table 'nat' is incompatible, use 'nft' tool` — and refuses to list or modify it.
That single refusal produces **both** symptoms above:

* **On teardown** (`iptables -t nat -D POSTROUTING ...`) it can't see its own chain →
  `Chain 'CNI-...' does not exist`.
* **On setup** (`iptables -t nat -S`) it can't list the table →
  `failed to list chains: ... table 'nat' is incompatible`.

Only `nat` and `filter` break. `raw`, `mangle`, and `security` stay fine because
nothing else hooks their priorities — proof that the trigger is the colliding
base chains, not the table contents themselves.

> Note: this box also had **orphaned `imunify360` chains** (package uninstalled,
> rules never flushed) polluting `nat`/`filter`. They were real and were cleaned
> up, but they were **not** the root blocker — removing them left the tables still
> "incompatible" because of the `cpanel_smtp_restrict` / `inet filter` collisions
> above.

## How to fix it?

### Recommended: switch Podman from CNI to the `netavark` backend

`netavark` (Podman 4.x's modern network backend) programs **nftables directly**
in its own isolated table and **never calls `/usr/sbin/iptables`**, so the shim
incompatibility simply cannot occur. This is the correct long-term fix on an
nftables-managed cPanel host.

```sh
# 1. Install the backend + DNS helper (same repo that provides podman)
dnf install -y netavark aardvark-dns

# 2. Override the pinned backend (do NOT edit the vendored file directly)
mkdir -p /etc/containers/containers.conf.d
cat > /etc/containers/containers.conf.d/90-netavark.conf <<'EOF'
[network]
network_backend = "netavark"
EOF

# 3. The chosen backend is cached and cannot be changed while containers/networks
#    exist. Clear state (removes containers, pods, and networks — not images by
#    default; back up anything you need first):
podman system reset

# 4. Verify and test
podman info --format '{{.Host.NetworkBackend}}'   # -> netavark
podman run -d --name nginx-hello -p 8080:8080 docker.io/nginxdemos/hello
```

After this, Podman's bridge network lives under its own `netavark` nft table,
completely isolated from cPanel's `cpanel_smtp_restrict` / `inet filter` chains,
and container start/stop no longer touches the incompatible `ip nat` / `ip filter`
tables.

### Not recommended: staying on CNI

Keeping the `cni` backend would require the `ip nat` / `ip filter` tables to be
the *only* base chains at those hooks — which means removing cPanel's SMTP-restrict
and Host-Access-Control nft chains. Those are managed cPanel security features
that would be regenerated and whose removal breaks mail/firewall policy, so this
path is not viable.

### Housekeeping (good hygiene, not a fix on its own)

Flush the orphaned `imunify360` chains left behind after the package was
uninstalled (they linger in the live ruleset):

```sh
for spec in "ip nat" "ip filter" "ip6 nat" "ip6 filter"; do
  fam=${spec% *}; tbl=${spec#* }
  chains=$(nft -a list table "$fam" "$tbl" 2>/dev/null | awk '/^\t+chain .*imunify360/{print $2}')
  [ -z "$chains" ] && continue
  for c in $chains; do nft flush chain "$fam" "$tbl" "$c"; done
  nft -a list table "$fam" "$tbl" 2>/dev/null | awk -v fam="$fam" -v tbl="$tbl" '
    /^\t+chain /{chain=$2}
    /imunify360/ && /(jump|goto)/ && /# handle/ {print "delete rule "fam" "tbl" "chain" handle "$NF}
  ' | while read -r args; do nft $args; done
  for c in $chains; do nft delete chain "$fam" "$tbl" "$c"; done
done
```
