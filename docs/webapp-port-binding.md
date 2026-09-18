# Web app port binding: loopback-only for web apps

## Decision

Container ports published for **web app** containers bind to `127.0.0.1`
only (`-p 127.0.0.1:HOSTPORT:CONTAINERPORT`). All other ea-podman containers
(plain `--cpuser-port` installs: databases, Tomcat-style packages, arbitrary
images, etc.) keep binding all interfaces (`-p HOSTPORT:CONTAINERPORT`), as
they do today.

This decision resolves [EA4-308](https://webpros.atlassian.net/browse/EA4-308)
and applies only to containers registered as a web app (the existing
`$webapp` flag passed to `register_container()`), not to ea-podman as a
whole.

## Rationale

The web app feature's reverse proxy (`Cpanel::WebApps::Proxy::wire_server()`
in `cpanel-plugins`) always routes a web app's domain to
`http://127.0.0.1:$host_port/`. It never uses the container's external
binding. That proxy layer is also where TLS/AutoSSL, ModSecurity, and Apache
access logging are applied to the request.

Binding a web app's port to all interfaces therefore creates a second,
unauthenticated path into the same application: anyone who reaches
`PUBLIC_IP:HOSTPORT` directly hits the app's raw HTTP server, bypassing the
proxy and every protection it provides, with no way for the app itself to
tell the difference. Restricting the port to loopback removes that path
without changing how the feature works, since the proxy never relied on the
external binding in the first place.

Non-web-app containers are different: ea-podman's core use case is exposing
an arbitrary service directly by IP:port (the project's own walkthrough
example is a bare MongoDB container), and existing packages (e.g. the
Tomcat-based EA4 packages) document direct `domain:PORT`/`IP:PORT` access as
their default, unproxied way of reaching the service. Most of what runs
under ea-podman isn't HTTP and has no equivalent transparent-proxy option,
so restricting those to loopback would break real, current functionality
rather than close an unused hole. Binding scope is therefore keyed off
whether a container is a web app, not applied universally.

### What this does not change

Loopback binding is not cross-user isolation on the same host. Any local
user can already open a TCP connection to `127.0.0.1:PORT`, regardless of
which user's container is listening there — this is unchanged before and
after this decision, since the host firewall's port-authority rules govern
outbound source-port ownership, not inbound access. This decision closes
exposure to other hosts on the network; it does not add any protection
against other local users on the same box. If that is a goal, it needs a
separate, dedicated fix (e.g. an inbound UID/owner-matched firewall rule).

## Design

### Where this applies

The single point where a container's `-p` argument is constructed for every
install/upgrade/restore is in `SOURCES/util.pm`, in the block that builds
`@real_start_args` from `@cpuser_ports`:

```perl
my @ports = $portsfunc->( $container_name => scalar(@cpuser_ports) );
for my $idx ( 0 .. $#ports ) {
    my $container_port = $cpuser_ports[$idx] || $ports[$idx];
    push @real_start_args, "-p", "$ports[$idx]:$container_port";
}
```

This becomes conditional on the container's web app status: when the
container is a web app, prefix the host port with `127.0.0.1:`; otherwise
leave it unprefixed as today. The web app flag already exists (used by
`register_container()`) and needs to be available at this point in the
call, ahead of where it's currently determined.

No changes are needed to `/scripts/cpuser_port_authority` or firewall port
assignment — those already work the same regardless of bind address, and
are out of scope for this decision.

### Rollout

`-p` is rebuilt every time a container is created, including on upgrade and
restore (this code path is shared across all three via
`_ensure_latest_container()`). A web app container picks up loopback-only
binding the next time it's recreated — through a normal package
upgrade/reinstall — with no separate migration step required. Containers
already running keep their current binding until then.

### Verification

- Install (or upgrade) a web app container and confirm its published port is
  bound to `127.0.0.1` only (e.g. via `podman port` or `ss -ltn`), and that
  the app's domain still resolves correctly through the proxy.
- Install a non-web-app (`--cpuser-port`) container and confirm it remains
  reachable on the server's public IP, unchanged from current behavior.
