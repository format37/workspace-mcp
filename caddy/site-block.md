# Caddy site block

The server owns its whole origin. Its OAuth routes (`/authorize`, `/token`,
`/register`, `/consent`, `/oauth2callback`) and its two `.well-known` documents
are mounted at fixed root paths and cannot be moved under a path prefix, so it
needs a hostname of its own rather than a slot on a shared one.

Replace `workspace.example.com` with your hostname — it must match
`WORKSPACE_EXTERNAL_URL` in `.env` exactly, character for character.

```caddyfile
workspace.example.com {
    # No `tls` line on purpose. Caddy then obtains and renews a Let's Encrypt
    # certificate itself over TLS-ALPN-01 on port 443, so port 80 can stay
    # closed. Requires the DNS A record to be DNS-only (grey cloud on
    # Cloudflare) — a proxied record terminates TLS upstream and ALPN issuance
    # never completes.

    encode gzip

    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options    "nosniff"
        X-Frame-Options           "DENY"

        # DELIBERATE DEVIATION: do NOT use Referrer-Policy "no-referrer" here.
        # It makes Chrome send `Origin: null` on the consent form POST, and the
        # server's origin-validation middleware answers 403 to any Origin it
        # does not recognise. The OAuth flow then dead-ends on a JSON error
        # blob with no way forward.
        Referrer-Policy           "strict-origin-when-cross-origin"
    }

    # Whole-origin proxy. Everything lives in the container: /mcp, /authorize,
    # /token, /register, /consent, /oauth2callback,
    # /.well-known/oauth-authorization-server,
    # /.well-known/oauth-protected-resource/mcp, /health and / .
    #
    # Caddy preserves the Host header by default — leave it that way. The
    # server compares the request's Origin against its Host as a fallback trust
    # rule, so rewriting Host quietly breaks the consent POST.
    #
    # Do not add caching for /.well-known/* . The server already sets
    # `Cache-Control: no-store, must-revalidate` there; a proxy cache in front
    # would serve stale OAuth metadata after a config change.
    reverse_proxy mcp-workspace:8020
}
```

There is no `/oauth2/*` route to forward — older upstream docs mention one, but
it 404s in current releases. Nothing else is needed either: `/` returns the same
health JSON as `/health`, so there is no unmatched-path fall-through to guard
against on this origin.

## Applying it

The Caddyfile is bind-mounted into the container, so it must be edited **in
place**. `vim` is fine; `sed -i` and `>` redirection swap the file's inode and
the container keeps reading the old one — the reload then reports success while
changing nothing.

```bash
vim ~/reverse-proxy/Caddyfile      # append the block above
sudo docker exec reverse-proxy caddy reload --config /etc/caddy/Caddyfile
```

`reload` is hot, with no dropped connections. Certificate issuance takes a few
seconds on first request. Confirm it happened:

```bash
sudo docker exec reverse-proxy \
  ls /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/
```

## Verifying

```bash
# 1. Health, and a valid publicly-trusted certificate.
curl -s https://workspace.example.com/health
# -> {"status":"healthy","service":"workspace-mcp","version":"1.22.2","transport":"streamable-http"}

# 2. Protected-resource metadata. `resource` must equal the connector URL you
#    will type into Claude, exactly.
curl -s https://workspace.example.com/.well-known/oauth-protected-resource/mcp

# 3. Authorization-server metadata. This one lives at the ROOT path — the
#    reverse of the previous. Both spellings existing would be the bug.
curl -s https://workspace.example.com/.well-known/oauth-authorization-server

# 4. The discovery entry point: unauthenticated /mcp must answer 401 AND carry
#    a WWW-Authenticate header naming the metadata URL. A 200 here means the
#    client never starts an OAuth flow.
curl -i -s https://workspace.example.com/mcp | head -20
```

The suffix-less `/.well-known/oauth-protected-resource` returning **404 is
correct** and is asserted by upstream's own tests. Do not "fix" it.

## If the consent page 403s with `Origin not allowed`

Chrome can emit `Origin: null` after a cross-origin redirect chain even without
a `no-referrer` policy, and the middleware has no off switch. It does, however,
trust requests that carry no Origin header at all — that is how ordinary
server-to-server MCP traffic passes. So strip the bad header rather than trying
to allow it:

```caddyfile
    @nullOriginConsent {
        path /consent
        header Origin null
    }
    request_header @nullOriginConsent -Origin
```

Scope it to `/consent` as shown. Stripping Origin globally would also disable
the middleware's same-origin check on every other route.

If instead the 403 mentions a real origin such as `https://claude.ai`, the fix
belongs in the server, not in Caddy: add it to `OAUTH_ALLOWED_ORIGINS`.
