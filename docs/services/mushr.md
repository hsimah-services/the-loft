# `mushr`

> Reverse proxy + Cloudflare Tunnel + LAN DNS — the front door for everything web-facing on space-needle.

## Overview

`mushr` (musher — sled-dog driver) routes every web request in The Loft. Caddy fronts all bridge-networked services on `*.loft.hsimah.com` (HTTPS, real Let's Encrypt certs via Cloudflare DNS-01) and `*.space-needle` (HTTP LAN fallback). `cloudflared` punches an outbound tunnel for external access to the blogs. `dnsmasq` is the LAN's authoritative resolver for those names plus the bare hostnames `fjord`/`viking`/`calavera`.

## Architecture

### Three containers in one compose

| Container | Image | Network | Purpose |
|-----------|-------|---------|---------|
| `mushr` | Custom build of `caddy:2-alpine` with the Cloudflare DNS module | bridge (`loft-proxy`) | Reverse proxy — terminates TLS, routes by Host header |
| `mushr-tunnel` | `cloudflare/cloudflared:latest` | bridge (`loft-proxy`) | Outbound Cloudflare Tunnel → `mushr:443` for external access to hbla.ke + hsimah.com |
| `mushr-dns` | `drpsychick/dnsmasq:latest` | host (binds to space-needle's LAN IP) | LAN DNS — wildcard A records, per-host A records, upstream to Cloudflare |

Caddy is custom-built — [`Dockerfile.caddy`](../../services/mushr/Dockerfile.caddy) runs `xcaddy build --with github.com/caddy-dns/cloudflare` so the binary includes the Cloudflare DNS-01 provider. The image is built locally (`mushr-caddy:latest`).

`mushr-tunnel` has `depends_on: mushr: condition: service_healthy` — the tunnel only starts once Caddy passes its `http://127.0.0.1:8880/config/` healthcheck.

### Two domain systems

Both resolve to space-needle's LAN IP via `mushr-dns`:

- **`*.loft.hsimah.com`** — HTTPS with real Let's Encrypt certs (Cloudflare DNS-01 challenge, no open ports). Recommended day-to-day.
- **`*.space-needle`** — HTTP-only LAN fallback. Useful when Caddy is restarting / cert issuance is mid-flight.

The full route table lives in [`Caddyfile`](../../services/mushr/Caddyfile). Bridge-networked services (radarr/sonarr/lidarr/bazarr/jackett, pupyrus, pawst, beszel, uptime, homepage) are reached by container name on `loft-proxy` (e.g. `reverse_proxy radarr:7878`). Host-network services (pawpcorn, howlr, transmission, slskd, snapweb) are reached via `host.docker.internal:<port>` thanks to the `extra_hosts: host.docker.internal:host-gateway` entry on `mushr`.

### The `loft-proxy` bridge

`loft-proxy` is declared `external: true` in this compose — it's pre-created by `setup.sh` so other services (pupyrus, pawst, stellarr's *arr, houstn's hub containers) can attach to it. Joining the bridge is how a service becomes reverse-proxyable.

### Why HTTP/3 is disabled

The Caddyfile `servers` block forces `protocols h1 h2`. HTTP/3 (QUIC over UDP) caused stale SSL handshakes after browser idle on the LAN — the server-side QUIC idle timeout would expire, the browser would try to reuse the dead connection, and recovery took 30–60s of fallback to HTTP/2. HTTP/3 is designed for lossy, high-latency networks; on a LAN, HTTP/2 over TCP is equally fast and handles idle gracefully via TCP keepalive. The UDP 443 port is still mapped in compose but Caddy doesn't advertise `h3` in `Alt-Svc`.

### Admin API lockdown

The Caddy admin API listens on `127.0.0.1:8880` *inside the container* (`admin 127.0.0.1:8880` in the Caddyfile). It's reachable from the host because the container's loopback maps through the port binding — but only from space-needle itself, not the LAN. Health checks use this endpoint (`http://localhost:8880/config/`).

## Configuration

### `.env`

Copy [`services/mushr/.env.example`](../../services/mushr/.env.example) to `services/mushr/.env`.

| Variable | Purpose |
|----------|---------|
| `LOFT_DOMAIN` | `loft.hsimah.com` — substituted into the Caddyfile as `{$LOFT_DOMAIN}` |
| `CLOUDFLARE_API_TOKEN` | Used by the DNS-01 challenge to write `_acme-challenge` TXT records. Permissions: **Zone > Zone > Read** and **Zone > DNS > Edit** scoped to the loft.hsimah.com / hbla.ke / hsimah.com zones |
| `TUNNEL_TOKEN` | `cloudflared`'s tunnel credential, generated when the tunnel is created in Cloudflare Zero Trust |

### `dnsmasq.conf`

[`services/mushr/dnsmasq.conf`](../../services/mushr/dnsmasq.conf) is bind-mounted into the container. The space-needle LAN IP (`192.168.86.28`) appears in:

- `listen-address=192.168.86.28` — dnsmasq binds only here (not `127.0.0.1`)
- `address=/space-needle/...`, `address=/loft.hsimah.com/...`, `address=/hbla.ke/...`, `address=/hsimah.com/...` — wildcard A records
- `address=/calavera/...`, `address=/fjord/...`, `address=/viking/...` — per-host A records

Update these IPs if space-needle moves, and `loft-ctl rebuild mushr`.

### Volumes

| Volume | Container path | Persists |
|--------|----------------|----------|
| `caddy-data` | `/data` | Let's Encrypt certs + ACME state |
| `caddy-config` | `/config` | Caddy's autosaved JSON config |

These are named Docker volumes — **never** `docker compose down -v mushr` (triggers cert re-issuance, hits rate limits).

### Cloudflare Tunnel public hostnames

Configured in the Cloudflare dashboard (Zero Trust → Networks → Tunnels), not the compose. Two routes:

- `hbla.ke` → HTTPS → `mushr:443`, Origin Server Name `hbla.ke`
- `hsimah.com` → HTTPS → `mushr:443`, Origin Server Name `hsimah.com`

The tunnel runs *inside* the `loft-proxy` network, so `mushr:443` is reachable as the container name. The Origin Server Name override is what lets Caddy's Host-based routing pick the correct site.

### LAN router DHCP

For the wildcard names to work on every device, the router's DHCP DNS server is set to space-needle's LAN IP. Devices then resolve `*.space-needle`, `*.loft.hsimah.com`, the blogs (`hbla.ke`, `hsimah.com`), and the per-host names through mushr-dns. Local traffic to the blogs hits Caddy directly — the tunnel is bypassed.

### Container DNS quirk

Bridge-network containers that need to resolve loft names from inside (e.g. uptime kuma polling `https://pupyrus.loft.hsimah.com`) need `dns: [192.168.86.28]` in their service block. mushr-dns binds to `192.168.86.28` only; the host uses `systemd-resolved` (`127.0.0.53`); Docker's embedded resolver filters loopback entries from the host's resolv.conf when forwarding container queries, then falls back to `8.8.8.8` which doesn't know about loft names. Per-service is preferred over `/etc/docker/daemon.json` `dns:` because the daemon-wide version restarts every container.

Container-to-container queries on `loft-proxy` (`mushr:443`, `pupyrus:80`, etc.) don't need this — Docker's embedded resolver handles container names natively.

## Operations

```bash
loft-ctl start mushr
loft-ctl stop mushr
loft-ctl rebuild mushr           # rebuilds the custom Caddy image too
loft-ctl health mushr            # checks http://localhost:8880/config/

# Validate Caddyfile before rebuilding
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile

# Hot reload Caddyfile (no container restart)
sudo docker exec mushr caddy reload --config /etc/caddy/Caddyfile

# Inspect what Caddy thinks is configured
curl -s http://localhost:8880/config/ | python3 -m json.tool

# Check certs
echo | openssl s_client -connect localhost:443 -servername radarr.loft.hsimah.com 2>/dev/null \
  | openssl x509 -noout -dates -subject

# Tunnel
sudo docker logs mushr-tunnel --tail 30 | grep -i 'registered\|error'
```

### One-time Cloudflare setup

1. Add `hsimah.com` and `hbla.ke` to Cloudflare; update each registrar's nameservers to Cloudflare's. (No A records needed — dnsmasq handles local resolution.)
2. Create an API token at [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) with **Zone:Read** and **DNS:Edit** scoped to all three zones (`loft.hsimah.com`, `hsimah.com`, `hbla.ke`). Drop it into `CLOUDFLARE_API_TOKEN`.
3. Create a tunnel in Cloudflare Zero Trust (connector: Cloudflared). Add the two public hostnames above. Drop the token into `TUNNEL_TOKEN`.
4. `loft-ctl rebuild mushr` — Caddy will issue real certs within ~30s.

### Adding a new service to Caddy

Add a route block in [`Caddyfile`](../../services/mushr/Caddyfile) (HTTPS first, then the matching `http://<name>.space-needle` block), join the service to the `loft-proxy` external network in its compose, then `loft-ctl reload mushr` (or `rebuild` if the service also changed network membership).

## Related

- All bridge-networked services — every page links back here because everything flows through Caddy.
- [space-needle](../hosts/space-needle.md) — the only host running mushr, and the only host that needs the LAN to point DHCP DNS at it.
- Blog: [Reverse proxy + LAN DNS with mushr](../../../hblake/posts/mushr.md)
- Blog: [Docker networking — host vs bridge in the loft](../../../hblake/posts/off-host-network.md)

## Debug & Troubleshooting

### dnsmasq won't bind port 53

**Symptom:** `mushr-dns` exits at startup with `address already in use` on port 53.

**Cause:** `systemd-resolved`'s stub listener is on `127.0.0.53:53` and binds the wildcard 53 on some configurations.

**Fix:**

```bash
sudo ss -tlnp | grep ':53'
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo docker restart mushr-dns
```

### Caddy TLS handshake failures across `*.loft.hsimah.com`

**Symptom:** Browsers warn about cert errors, or curl shows "TLS handshake error".

**Cause:** Stale or corrupt cert data in the `caddy-data` volume.

**Fix:**

```bash
loft-ctl stop mushr
sudo docker volume rm mushr_caddy-data mushr_caddy-config
loft-ctl start mushr
# Caddy re-issues via Cloudflare DNS-01 within ~30s
```

(Beware Let's Encrypt rate limits — don't do this in a loop.)

### `mushr-tunnel` won't start

**Cause:** It has `depends_on: mushr: condition: service_healthy`. If Caddy's healthcheck fails, the tunnel never gets to run.

**Fix:**

```bash
sudo docker inspect mushr --format '{{.State.Health.Status}}'
sudo docker logs mushr --tail 30
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile
```

Most common cause: a typo in the Caddyfile after an edit. Validate before rebuilding.

### Containers can't resolve `*.loft.hsimah.com` while the host can

**Symptom:** From inside a container, `nslookup radarr.loft.hsimah.com` returns NXDOMAIN, but the same query on the host works.

**Cause:** Per the [container DNS quirk](#container-dns-quirk) above. Docker's embedded resolver drops loopback entries from the host's resolv.conf and falls back to public DNS.

**Fix:** Add `dns: [192.168.86.28]` to the affected service in its compose:

```yaml
services:
  uptime:
    dns:
      - 192.168.86.28
```

Then `loft-ctl rebuild` that service.

### Cloudflare Tunnel keeps disconnecting

**Checks:**

```bash
sudo docker logs mushr-tunnel --tail 30 | grep -i 'error\|failed\|disconnect'
# Look for: "Unauthorized: Failed to get tunnel" (token bad) vs
#           "connection reset" / "TLS handshake" (network instability)
```

If the token is bad, regenerate it in Cloudflare Zero Trust and update `TUNNEL_TOKEN` in `.env`. If it's network instability, the tunnel auto-reconnects within a few seconds — sustained drops point at an ISP / Cloudflare edge issue.

### Certs not renewing

Caddy renews 30 days before expiry. If certs are expiring:

```bash
# Check current expiry
echo | openssl s_client -connect localhost:443 -servername radarr.loft.hsimah.com 2>/dev/null \
  | openssl x509 -noout -dates

# Force a fresh issuance via admin API
curl -sX POST 'http://localhost:8880/load' -H 'Content-Type: application/json' \
  -d "$(curl -s http://localhost:8880/config/)"
```

If renewal is failing, check `sudo docker logs mushr --tail 100 | grep -i acme` — usually `CLOUDFLARE_API_TOKEN` has lost the required scopes or was rotated.
