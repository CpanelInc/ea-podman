# ea-podman UAPI browser test harness

A manual QA tool for exercising every `Cpanel::API::EAPodman` UAPI verb
(`list`, `install`, `upgrade`, `uninstall`, `start`, `stop`, `restart`,
`status`, `cmd`) from a browser, on behalf of a real cPanel account.

## Why the proxy

cpsrvd (port 2083) sends no `Access-Control-*` headers for any `Origin` —
verified empirically (curl preflight + real request against `null`,
`http://localhost:8000`, the account's own domain, and the server's own
hostname all came back with zero CORS headers). A browser therefore cannot
call `https://host:2083/execute/...` directly from a page's `fetch()`, no
matter how the page is hosted or authenticated. `proxy.py` is a small
stdlib-only local relay: the page talks to it on `localhost` (no CORS
applies there), and it forwards the request to the real cpsrvd host
server-to-server (no browser involved, so no CORS applies to that hop
either).

## Usage

1. Get a cPanel API token for the account you want to test as (WHM/cPanel >
   Security > Manage API Tokens, or `uapi --user=<user> Tokens
   create_full_access name=harness`).
2. Run the proxy:
   ```sh
   python3 proxy.py
   ```
   (listens on `http://127.0.0.1:8787` by default; add `--port` to change it,
   `--verify-tls` to enforce upstream TLS verification instead of skipping it —
   skipping is the default since test/dev boxes typically have self-signed
   certs).
3. Open `index.html` in a browser (double-click it, or serve the directory
   with any static file server — either works, since the page only ever
   talks to the local proxy).
4. Fill in the Config panel: proxy base URL (leave as default unless you
   changed `--port`), the cPanel host, the username, and the API token. Click
   Save.
5. Use the per-verb sections to call `EAPodman`. Multi-value fields
   (`cpuser_port` on `install`, `env` on `install`, `arg` on `cmd`) each have
   a `+` button to add more rows; they're sent as repeated query keys,
   matching the wire convention `SOURCES/ea-podman.pl`'s own
   `_uapi_query_string` uses (not the numbered `key-0`/`key-1` legacy form).
6. The Log section at the bottom shows every call made and its raw JSON
   response (the `{status, data, errors}` envelope), newest first.

## Notes

- Config (host/user/token) is stored only in the browser tab's
  `sessionStorage` — cleared when the tab closes, never sent anywhere but the
  local proxy.
- `proxy.py` only forwards paths under `/execute/`; anything else gets a 403.
  It binds to `127.0.0.1` only.
- This is a dev/QA tool, not shipped in the RPM/deb package.
