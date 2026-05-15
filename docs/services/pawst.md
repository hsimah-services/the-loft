# `pawst`

> Static blogs `hbla.ke` and `hsimah.com` served by one nginx container, with hourly pull-based deploys.

## Overview

`pawst` (paw + post) hosts two static sites on [space-needle](../hosts/space-needle.md): `hbla.ke` (technical blog) and `hsimah.com` (personal blog). One nginx container routes by `server_name` to a different document root per domain. Built sites land in bind-mounted directories via an hourly puller that grabs `.tar.gz` artifacts from each repo's latest GitHub Release.

## Architecture

Single `nginx:alpine` container on the [`loft-proxy`](mushr.md) bridge. No host ports — all traffic comes in through [mushr](mushr.md)'s Caddy (`hbla.ke`, `hsimah.com` on the LAN via dnsmasq; externally via the Cloudflare Tunnel that fronts Caddy).

### nginx server_name routing

[`nginx.conf`](../../services/pawst/nginx.conf) declares two server blocks:

- `server_name hbla.ke hblake.space-needle pawst.space-needle;` → root `/usr/share/nginx/hblake`
- `server_name hsimah.com hsimah.space-needle;` → root `/usr/share/nginx/hsimah`

Both have a SPA-style fallback (`try_files $uri $uri/ /index.html`), long-cache headers for `/assets/*`, and gzip for text/css/js/json/svg.

### Where files come from — pull-based deploys

The container itself is read-only; built sites are bind-mounted from `/opt/pawst/hblake-html` and `/opt/pawst/hsimah-html`. Those directories are populated **on space-needle**, not in CI, by [`control-plane/deploy-pull.sh`](../../control-plane/deploy-pull.sh) which runs hourly via cron. The puller queries `GET /repos/<owner>/<repo>/releases/latest`, compares the tag to its state file, and on a new release downloads and atomically swaps the `.tar.gz` payload. See the scripts page (coming in a separate sub-issue) for the full mechanism.

The two `DEPLOY_TARGETS` entries in [`hosts/space-needle/host.conf`](../../hosts/space-needle/host.conf):

```
"pawst-hblake|hsimah-services/hblake|/opt/pawst/hblake-html|"
"pawst-hsimah|hsimah-services/hsimah|/opt/pawst/hsimah-html|"
```

Each line installs `/etc/cron.d/loft-deploy-<name>` and writes state to `/var/lib/loft/deploy/<name>.version`. The optional trailing field (post-deploy hook) is empty here — nginx serves the new files immediately without reload.

### External access via Cloudflare Tunnel

`hbla.ke` and `hsimah.com` are exposed externally through [mushr's](mushr.md) Cloudflare Tunnel — outbound-only, no router ports. LAN clients still resolve both domains to the LAN IP via mushr-dns and hit Caddy → pawst directly, bypassing the tunnel.

### Static site sources

- `hbla.ke` — repo `hsimah-services/hblake` (Hugo build per the CI workflow there). Reference only; never deep-link the build output.
- `hsimah.com` — repo `hsimah-services/hsimah`.

## Configuration

No `.env` file. The single bound resource is the `nginx.conf` (read-only) and the two HTML dirs (read-only). Everything that varies is upstream:

- The Caddy routes in [`services/mushr/Caddyfile`](../../services/mushr/Caddyfile) (`hbla.ke`, `hsimah.com`, `http://pawst.space-needle`, `http://hsimah.space-needle`)
- The DNS entries in [`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) (`address=/hbla.ke/...`, `address=/hsimah.com/...`)
- The `DEPLOY_TARGETS` array in `hosts/space-needle/host.conf`
- The release artifacts the app repos publish

## Operations

```bash
loft-ctl start pawst
loft-ctl rebuild pawst
loft-ctl health pawst        # checks pawst.space-needle + hsimah.com via Caddy

# Force a deploy without waiting for the hourly cron
sudo /srv/the-loft/control-plane/deploy-pull.sh pawst-hblake hsimah-services/hblake /opt/pawst/hblake-html
sudo /srv/the-loft/control-plane/deploy-pull.sh pawst-hsimah hsimah-services/hsimah /opt/pawst/hsimah-html

# Inspect deploy state
sudo cat /var/lib/loft/deploy/pawst-hblake.version
sudo tail -n 50 /var/log/loft/deploy.log
```

### Adding a new blog / static site

1. Build artifact upstream as `site.tar.gz` (flat or with one wrapper dir; the puller handles both).
2. Publish on a tagged GitHub Release (drafts are skipped).
3. Add a `CONFIG_DIRS` entry (e.g. `/opt/pawst/<name>-html`) and a `DEPLOY_TARGETS` entry in `hosts/space-needle/host.conf`.
4. Bind-mount the new dir into `services/pawst/docker-compose.yml`.
5. Add a new `server { server_name … }` block in `services/pawst/nginx.conf`.
6. Add Caddy routes in `services/mushr/Caddyfile` (and a dnsmasq A record + Cloudflare Tunnel public hostname if it's a new external domain).
7. `sudo bash setup.sh` to materialize the new cron entry + dir + permissions.
8. `loft-ctl rebuild pawst` and `loft-ctl reload mushr`.

## Related

- [mushr](mushr.md) — Caddy routes for the two domains + Cloudflare Tunnel
- [space-needle](../hosts/space-needle.md) — the only host that runs pawst (and the only one with `DEPLOY_TARGETS`)
- Source repos: `hsimah-services/hblake`, `hsimah-services/hsimah`
- Blog: [Pawst — static blogs on the loft](../../../hblake/posts/pawst.md)
- The scripts page (coming up) will document `deploy-pull.sh` in detail

## Debug & Troubleshooting

### A new release isn't showing up

**Checks:**

```bash
# Did the puller see anything?
sudo tail -n 50 /var/log/loft/deploy.log

# What tag does it think is currently deployed?
sudo cat /var/lib/loft/deploy/pawst-hblake.version
sudo cat /var/lib/loft/deploy/pawst-hsimah.version

# Force a run
sudo /srv/the-loft/control-plane/deploy-pull.sh pawst-hblake hsimah-services/hblake /opt/pawst/hblake-html
```

**Common causes:**
- The release has no `.tar.gz` asset attached — the puller only pulls `.tar.gz`.
- The release was published as a **draft** — `releases/latest` skips drafts.
- The repo is private and `/etc/loft/deploy.env` is missing or the GitHub App installation lacks `Contents: Read` on it.

### Stale assets in the browser

**Cause:** The `Cache-Control: public, immutable` header on `/assets/*` is intentional — built artifacts have content-hashed filenames, so the cache is safe. If the site appears stale, the new release wasn't actually deployed (see above) or a custom asset path wasn't hashed by the build.

**Fix:** Force-reload (Ctrl+Shift+R), then verify the deployed `index.html` references the new hashed asset filename with `sudo ls /opt/pawst/hblake-html/assets/`.

### 404 for routes that should exist (SPA fallback not catching)

**Cause:** nginx's `try_files $uri $uri/ /index.html` should catch all client-side routes. If a route 404s, either the request isn't reaching pawst (Caddy / DNS / Host header) or `/index.html` itself isn't in the bound directory.

**Checks:**

```bash
# Is the file there?
sudo ls /opt/pawst/hblake-html/index.html

# Is pawst itself responding?
sudo docker exec mushr wget -q -O - -S 'http://pawst:80/some/path' 2>&1 | head

# What does Caddy think?
curl -sI -H 'Host: hbla.ke' http://localhost
```

### Cloudflare Tunnel returns 502 for the blogs externally

See [mushr's Cloudflare Tunnel debug](mushr.md#cloudflare-tunnel-keeps-disconnecting) — the tunnel itself is the most likely culprit. LAN access via `https://hbla.ke` will still work even when the tunnel is dead, because mushr-dns resolves both domains to the LAN IP.

### `hbla.ke` resolves but `hblake.space-needle` doesn't

**Cause:** The legacy `hblake.space-needle` alias is listed in `server_name` for the pawst-hblake server block but **not** in `dnsmasq.conf`. Only `hbla.ke`, `pawst.space-needle`, and `hsimah.space-needle` have dnsmasq A records.

**Fix:** Use one of the canonical URLs (`hbla.ke`, `pawst.space-needle`, `hsimah.com`, `hsimah.space-needle`), or add `address=/hblake.space-needle/192.168.86.28` to `dnsmasq.conf` and rebuild mushr.
