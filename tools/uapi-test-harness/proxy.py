#!/usr/bin/env python3
"""Local CORS-bypass proxy for the ea-podman UAPI browser test harness.

cpsrvd (cPanel's daemon on :2083) sends no Access-Control-Allow-Origin
headers at all, for any Origin -- confirmed empirically against a live box
(curl preflight + real GET for Origin: null, http://localhost:8000, the
account's own domain, and the server's own hostname all came back with zero
Access-Control-* headers). A browser page therefore cannot call cpsrvd
directly with fetch(); this tiny stdlib-only proxy sits on localhost, adds
permissive CORS headers of its own, and forwards each request server-to-server
(where CORS does not apply) to the real cpsrvd host named in the
X-Proxy-Target request header that index.html sends.

Usage:
    python3 proxy.py                  # listens on 127.0.0.1:8787
    python3 proxy.py --port 9000
    python3 proxy.py --verify-tls     # enforce upstream TLS verification

Only paths under /execute/ are forwarded -- this is a narrow single-purpose
relay for the harness, not a general proxy. It binds to 127.0.0.1 only.
"""
import argparse
import ssl
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ALLOWED_PREFIX = "/execute/"


class Handler(BaseHTTPRequestHandler):
    server_version = "eapodman-harness-proxy/1.0"

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "authorization, x-proxy-target, content-type")
        self.send_header("Access-Control-Max-Age", "600")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        if not self.path.startswith(ALLOWED_PREFIX):
            self.send_response(403)
            self._cors_headers()
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"only /execute/ paths are proxied")
            return

        target = self.headers.get("X-Proxy-Target")
        if not target:
            self.send_response(400)
            self._cors_headers()
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"missing X-Proxy-Target header (host or host:port)")
            return

        if ":" not in target:
            target = f"{target}:2083"

        auth = self.headers.get("Authorization", "")
        upstream_url = f"https://{target}{self.path}"

        ctx = ssl.create_default_context()
        if not self.server.verify_tls:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

        req = urllib.request.Request(upstream_url, headers={"Authorization": auth})
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
                body = resp.read()
                status = resp.status
                content_type = resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            body = e.read()
            status = e.code
            content_type = e.headers.get("Content-Type", "application/json") if e.headers else "application/json"
        except Exception as e:  # noqa: BLE001 - report any upstream failure to the caller
            self.send_response(502)
            self._cors_headers()
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"proxy error reaching {target}: {e}".encode())
            return

        self.send_response(status)
        self._cors_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8787, help="local port to listen on (default 8787)")
    ap.add_argument(
        "--verify-tls",
        action="store_true",
        help="verify the upstream cpsrvd TLS certificate (default: skip, for self-signed dev/test boxes)",
    )
    args = ap.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.verify_tls = args.verify_tls
    print(f"ea-podman UAPI harness proxy listening on http://127.0.0.1:{args.port}")
    print("Forwards /execute/* requests to the cpsrvd host named in the X-Proxy-Target header.")
    if not args.verify_tls:
        print("TLS verification of the upstream is DISABLED (pass --verify-tls to enable).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
