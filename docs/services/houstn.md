# `houstn`

> Fleet observability bundle — Beszel hub, Uptime Kuma, Homepage, and per-host Glances under one compose with Compose profiles.

## Overview

`houstn` (Houston, mission control) is the central monitoring stack. It bundles four containers into one compose file at [`services/houstn/`](../../services/houstn/) and uses Compose profiles to control which run on each host: `hub` runs the three dashboards on [space-needle](../hosts/space-needle.md), `metrics` runs Glances fleet-wide. The Beszel agent that feeds it lives in its own service, [snoot](snoot.md), so each host runs that with `network_mode: host`.

## Architecture

### Profile layout

| Profile | Containers | Hosts | Purpose |
|---------|-----------|-------|---------|
| `hub` | `beszel`, `uptime`, `homepage` | space-needle only | Web UIs aggregating data from every host |
| `metrics` | `glances` | space-needle + fjord + viking + calavera | Per-host CPU/RAM/disk REST API consumed by Homepage |

space-needle runs `COMPOSE_PROFILES=hub,metrics`; remote hosts run `COMPOSE_PROFILES=metrics`. The agent that the hub talks to is [snoot](snoot.md) on every host.

### Per-component

- **beszel** (`henrygd/beszel`, bridge): Fleet metrics hub. Web UI at `https://beszel.loft.hsimah.com`. Reads CPU/RAM/disk/network + Docker stats from every snoot agent. Persists `/opt/houstn/beszel/data`. `extra_hosts: host.docker.internal:host-gateway` so it can reach the local agent (snoot on space-needle binds to the host network).
- **uptime** (`louislam/uptime-kuma:1`, bridge): HTTP polling status dashboard at `https://uptime.loft.hsimah.com`. Configure monitors via the UI targeting fleet endpoints from [`hosts/space-needle/host.conf`](../../hosts/space-needle/host.conf) `HEALTH_URLS`. Persists `/opt/houstn/uptime/data`.
- **homepage** (`ghcr.io/gethomepage/homepage`, bridge): Unified dashboard at `https://homepage.loft.hsimah.com` with Plex/*arr/Transmission/slskd/Uptime widgets plus per-host Glances widgets. Mounts the Docker socket read-only for container status. Has `extra_hosts` for `host.docker.internal` + bare hostnames `fjord`/`viking`/`calavera` so the Glances widgets can reach each host's API.
- **glances** (`nicolargo/glances:latest-full`, host network + `pid: host`): Per-host metrics API on port 61208 (`GLANCES_OPT=-w` runs the web UI alongside the API). Mounts `/`, the Docker socket, and `/etc/os-release` read-only. Has no UI for the user — it's a metrics source.

### Network topology

The three hub containers join the [`loft-proxy`](mushr.md) bridge so [mushr](mushr.md)'s Caddy can reverse-proxy them. Glances runs on the host network so its REST API is reachable as `host.docker.internal:61208` (for space-needle's own homepage container) or `<bare-hostname>:61208` (for remote hosts, resolved via mushr-dns or `extra_hosts`).

## Configuration

### `.env`

`services/houstn/.env` lives only inside the homepage container's runtime — beszel/uptime/glances have no required env vars (web UI configures beszel and uptime on first launch; glances is config-free). Copy from [`services/houstn/.env.example`](../../services/houstn/.env.example).

| Variable | Hosts | Purpose |
|----------|-------|---------|
| `COMPOSE_PROFILES` | all | `hub,metrics` on space-needle; `metrics` everywhere else |
| `HOMEPAGE_VAR_PLEX_TOKEN` | space-needle | Plex `X-Plex-Token` for the Plex widget |
| `HOMEPAGE_VAR_RADARR_API_KEY` etc. | space-needle | *arr API keys (Settings → General → Security in each app) |
| `HOMEPAGE_VAR_TRANSMISSION_USERNAME` / `_PASSWORD` | space-needle | Blank if no auth set in Transmission |
| `HOMEPAGE_VAR_SLSKD_API_KEY` | space-needle | slskd → Settings → Security → API Keys |
| `HOMEPAGE_VAR_UPTIME_KUMA_SLUG` | space-needle | Public Status Page slug for the Uptime widget |

Homepage substitutes `{{HOMEPAGE_VAR_*}}` placeholders in `homepage-config/*.yaml` at startup, so secrets stay out of the version-controlled YAML.

### Homepage config files (bind-mounted)

`services/houstn/homepage-config/` is bind-mounted as `/app/config` — version-controlled, no `/opt/houstn/homepage` directory. The files:

| File | Purpose |
|------|---------|
| `settings.yaml` | Theme, layout (group → columns), `useEqualHeights` |
| `services.yaml` | Service groups (Media, Downloads, Audio, Monitoring, Infrastructure, Web), each with `widget:` blocks |
| `widgets.yaml` | Top bar — greeting, datetime, four Glances widgets (one per host) |
| `bookmarks.yaml` | Bookmark groups (currently empty) |
| `docker.yaml` | Docker socket reference — `my-docker: socket: /var/run/docker.sock` |

### Per-host overrides

[`hosts/space-needle/overrides/houstn/docker-compose.override.yml`](../../hosts/space-needle/overrides/houstn/docker-compose.override.yml) adds `/mammoth:/mammoth:ro` to the glances container so the media volume shows up alongside `/rootfs` in Homepage's space-needle widget. Without this override glances on space-needle reports only the root disk.

### Beszel hub ↔ agent wiring

The hub reaches each agent by `<host>:45876`. The space-needle entry uses **`host.docker.internal:45876`** (the hub is on the bridge — `localhost` would be its own container). The other hosts use their bare hostname (`fjord`, `viking`, `calavera`), resolved via mushr-dns. The `BESZEL_KEY` value generated by the hub UI is identical on every host — it belongs to the hub, not the agent — and is set in [`services/snoot/.env`](../../services/snoot/.env.example) on each.

Pull beszel/snoot images from Docker Hub (`henrygd/beszel`, `henrygd/beszel-agent`). The ghcr.io mirror returns "denied" for unauthenticated pulls; Docker Hub works without a token.

## Operations

```bash
# Start / stop / rebuild
loft-ctl start houstn
loft-ctl stop houstn
loft-ctl rebuild houstn          # picks up Homepage YAML changes

# Health (all four endpoints: beszel, uptime, homepage, glances)
loft-ctl health houstn
```

### First-time hub setup (space-needle)

1. `loft-ctl start houstn`
2. Open `https://beszel.loft.hsimah.com`, create the admin account
3. **Add System** for space-needle — copy the `KEY=` value from the `docker run` snippet
4. Set `BESZEL_KEY=<value>` in `services/snoot/.env` **on every host** (same key everywhere)
5. `loft-ctl start snoot` on each host
6. Back in Beszel, configure each system's connection: `host.docker.internal:45876` for space-needle, bare hostname (`fjord`/`viking`/`calavera`) at port 45876 for the rest
7. Open `https://uptime.loft.hsimah.com`, create the admin account, add monitors for each fleet URL (the `HEALTH_URLS` in `hosts/space-needle/host.conf` are a good starting set)
8. Open `https://homepage.loft.hsimah.com` — widgets will pull data from Plex/*arr/Transmission/slskd/Uptime as soon as the `HOMEPAGE_VAR_*` keys in `.env` are filled in

### Editing the Homepage dashboard

`services/houstn/homepage-config/*.yaml` is bind-mounted, so Homepage hot-reloads on save when edited in-repo on space-needle. For changes made elsewhere, commit and `loft-ctl update houstn` (or `loft-ctl rebuild houstn` for a clean reload).

### Adding a new fleet-wide agent/exporter

Add it as a new profile inside `services/houstn/docker-compose.yml` rather than a new top-level service. The existing profile split (`hub` / `metrics`) is the template — pick a profile that matches its scope and run it on the hosts that want it via `COMPOSE_PROFILES`.

## Related

- [snoot](snoot.md) — Beszel agent, the other half of the metrics pipeline
- [mushr](mushr.md) — provides `loft-proxy` bridge + Caddy reverse proxy for the three hub UIs
- [space-needle](../hosts/space-needle.md) — only host that runs the `hub` profile
- Root [`README.md`](../../README.md) — `Fleet Monitoring` section (about to slim down)

## Debug & Troubleshooting

### Beszel hub can't reach the local agent

**Symptom:** In the Beszel UI, space-needle shows as offline while fjord/viking/calavera report fine.

**Cause:** The hub is configured with `localhost:45876` or `127.0.0.1:45876` for space-needle. From inside the hub container, those are the container's own loopback — not the host network where snoot listens.

**Fix:** Edit the system in Beszel and set host to `host.docker.internal`, port `45876`. The `extra_hosts: host.docker.internal:host-gateway` entry in `services/houstn/docker-compose.yml` makes that resolve to the host gateway from inside the bridge.

### Beszel agents can't pull image — "denied"

**Symptom:** `loft-ctl start snoot` or `rebuild houstn` fails on image pull with `denied`.

**Cause:** The image was specified as `ghcr.io/henrygd/beszel`. ghcr.io requires authentication for some packages even when public.

**Fix:** Use Docker Hub: `henrygd/beszel` for the hub, `henrygd/beszel-agent` for the agent. Both repos confirm this — the compose files in-repo already point at Docker Hub; if a fork or older config still references ghcr.io, switch it.

### Homepage Glances widgets are empty for remote hosts

**Checks:**

```bash
# Can the homepage container resolve the host?
sudo docker exec homepage getent hosts fjord
# Should return 192.168.86.30 (or whatever extra_hosts declares)

# Is glances actually running there?
curl -s http://fjord:61208/api/4/status | head
```

**Common causes:**
- The remote host doesn't have `COMPOSE_PROFILES=metrics` set, so glances isn't running
- The bare hostname IP changed and `extra_hosts` in `services/houstn/docker-compose.yml` is stale — update the IP and `loft-ctl rebuild houstn`
- The remote host is unreachable on the LAN (separate problem — see that host's page)

### Homepage `host.docker.internal` widget queries fail

**Cause:** `host.docker.internal` resolves to the host gateway via `extra_hosts` in the compose. If that line was removed or Docker is on a host networking config that doesn't allow the gateway alias, widgets targeting `host.docker.internal` go nowhere.

**Fix:** Verify the `extra_hosts:` block is present for the `homepage` and `beszel` services in `services/houstn/docker-compose.yml`, then `loft-ctl rebuild houstn`.

### Glances on space-needle doesn't show `/mammoth` usage

**Cause:** The override that mounts `/mammoth:/mammoth:ro` into glances on space-needle is missing.

**Fix:** Restore [`hosts/space-needle/overrides/houstn/docker-compose.override.yml`](../../hosts/space-needle/overrides/houstn/docker-compose.override.yml) and rebuild. Then ensure `widgets.yaml` lists `/rootfs` and `/mammoth` under the space-needle Glances widget's `disk:` array.

### Homepage `{{HOMEPAGE_VAR_*}}` placeholders showing literally in the UI

**Cause:** The env var is missing or blank in `services/houstn/.env`, so Homepage left the placeholder text in place.

**Fix:** Fill the value in `.env` and `loft-ctl rebuild houstn`. If a widget legitimately has no key (e.g. you haven't set up the Uptime Kuma status page yet), remove the `widget:` block from `services.yaml` until you do.
