# the-loft

Fleet configuration for The Loft — a mono-repo managing all hosts (space-needle, viking, fjord) with shared service definitions, per-host configuration, and a unified setup/control-plane.

## Architecture

### Fleet

| Host | Role | Services |
|------|------|----------|
| `space-needle` | Primary server | mushr, pawpcorn, stellarr, pupyrus, howlr (server), pulsr (+ phanpy), pawst, houstn (beszel hub + uptime + homepage), snoot |
| `viking` | Raspberry Pi 3 B+ | howlr (client), snoot |
| `fjord` | Raspberry Pi 3 B+ | howlr (client), snoot |
| `calavera` | Surface Pro 2 (kiosk + turntable) | howlr (client), spinnik, snoot |

Each host has a config file at `hosts/<hostname>/host.conf` that declares its services, storage, directories, and health check URLs. A single `setup.sh` provisions any host by reading its config. Services that need post-deploy configuration have a `services/<name>/setup.sh` script that is automatically sourced after deployment.

### Services

| Service | Image | Ports | Config | Purpose |
|---------|-------|-------|--------|---------|
| Pawpcorn | `plexinc/pms-docker` | host network | `/opt/pawpcorn/config` | Media server (Plex) |
| Stellarr VPN | `bubuntux/nordvpn` | 9091, 5030 | — | Shared NordLynx VPN for Transmission + slskd |
| Transmission | `linuxserver/transmission` | 9091 (via VPN) | `/opt/transmission` | Torrent client |
| slskd | `slskd/slskd` | 5030 (via VPN) | `/opt/slskd` | Soulseek client (API-driven) — indexer + download client for Lidarr via plugin |
| Radarr | `linuxserver/radarr` | — (via Caddy) | `/opt/radarr` | Movie management |
| Sonarr | `linuxserver/sonarr` | — (via Caddy) | `/opt/sonarr` | TV management |
| Lidarr | `linuxserver/lidarr:nightly` | — (via Caddy) | `/opt/lidarr` | Music management (nightly branch for plugin support) |
| Bazarr | `linuxserver/bazarr` | — (via Caddy) | `/opt/bazarr` | Automated subtitle management for Radarr + Sonarr |
| Jackett | `linuxserver/jackett` | — (via Caddy) | `/opt/jackett` | Indexer proxy |
| Mushr (proxy) | `caddy:2-alpine` + Cloudflare DNS module (custom build) | 80, 443 | `Caddyfile`, `Dockerfile.caddy` | Reverse proxy with HTTPS (Let's Encrypt via DNS-01) + LAN HTTP fallback; HTTP/3 disabled (`protocols h1 h2`) to prevent QUIC idle timeout issues; Caddy admin API bound to container loopback only |
| Mushr (tunnel) | `cloudflare/cloudflared` | — (outbound only) | — | Cloudflare Tunnel — exposes Pulsr, hbla.ke, and hsimah.com externally without open ports |
| Mushr (DNS) | `drpsychick/dnsmasq` | 53/udp, 53/tcp | `dnsmasq.conf` | Wildcard DNS — resolves `*.space-needle` and `*.loft.hsimah.com` to LAN IP |
| Pupyrus | `wordpress` + `mariadb` + `redis` | — (via Caddy) | `/opt/pupyrus/html`, `/opt/pupyrus/db` | WordPress site (WPGraphQL + Redis object cache) |
| Howlr (Music Assistant) | `ghcr.io/music-assistant/server` | 1704, 1705, 1780, 8095 (host) | `/opt/howlr` | Music library manager + multi-room audio server with built-in Snapcast, Spotify Connect, and AirPlay receiver |
| Howlr snapclient | `ivdata/snapclient` | host network | `.env` per host | Snapcast client (receives stream, outputs to speakers) |
| Pulsr | `superseriousbusiness/gotosocial` | — (via Caddy) | `/opt/pulsr/data` | Self-hosted fediverse instance (GoToSocial) for status updates, household messaging, and fleet status reporting |
| Pulsr Phanpy | `ghcr.io/yitsushi/phanpy-docker` | — | — | Web client for GoToSocial (served at `pulsr.space-needle/`) |
| Pawst | `nginx:alpine` | — (via Caddy) | `nginx.conf`, `/opt/pawst/{hblake,hsimah}-html` bind mounts | Static blogs — serves `hbla.ke` and `hsimah.com` via Nginx server_name routing (dist deployed by hourly release puller — see [Pull-Based Deploys](#pull-based-deploys)) |
| Spinnik (Icecast) | `libretime/icecast:2.4.4` | 8000 | env vars | Icecast streaming server — serves vinyl audio from the LP5X turntable |
| Spinnik (DarkIce) | Custom build (`debian:bookworm-slim` + darkice) | — | `darkice.cfg` | Captures LP5X USB audio and encodes Ogg Vorbis stream to Icecast |
| Spinnik (UI) | `nginx:alpine` | 8080 | `nginx.conf`, `ui/` | Touch-optimized vinyl controller with audio visualizer; proxies MA API (server-side Bearer auth) and Icecast stream (same-origin for Web Audio API) |
| Houstn — Beszel | `henrygd/beszel` | — (via Caddy) | `/opt/houstn/beszel/data` | Fleet monitoring hub (Beszel) — web dashboard showing host CPU/RAM/disk/network and per-container Docker stats across all fleet hosts |
| Houstn — Uptime | `louislam/uptime-kuma:1` | — (via Caddy) | `/opt/houstn/uptime/data` | Uptime monitor (Uptime Kuma) — HTTP polls all fleet service endpoints and presents a live status dashboard |
| Houstn — Homepage | `ghcr.io/gethomepage/homepage` | — (via Caddy) | `services/houstn/homepage-config/` (bind-mounted from repo) | Homepage dashboard — unified fleet overview with live widgets for Plex streams/library counts, *arr stats, download queue, and container status via Docker socket |
| Snoot | `henrygd/beszel-agent` | 45876 (host) | — | Beszel agent — runs on every host with `network_mode: host` to expose system and Docker metrics to the Houstn/Beszel hub |

Transmission and slskd route through a shared NordVPN (NordLynx) container (`stellarr-vpn`). Radarr, Sonarr, Lidarr, Bazarr, and Jackett run on the shared `loft-proxy` bridge network and are reachable only via Caddy (no host port mappings). Radarr/Sonarr/Lidarr have `host.docker.internal` mapped via `extra_hosts` so they can still reach Transmission and slskd at the VPN container's host-published ports. All eight are managed together in `services/stellarr/docker-compose.yml`. Lidarr uses the `nightly` tag to enable the [Lidarr.Plugin.Slskd](https://github.com/allquiet-hub/Lidarr.Plugin.Slskd) plugin, which adds slskd as both an indexer and download client.

Transmission torrents are automatically cleaned up by a cron job that runs nightly at midnight on space-needle. The `remove-torrents.sh` script (bind-mounted into the container) uses `transmission-remote` to find and remove any torrents that have reached a 200% seed ratio, deleting the download data. This is safe because Radarr/Sonarr/Lidarr hardlink files into `/mammoth/library` — the library copies are independent of the download directory. The cron job is installed to `/etc/cron.d/transmission-cleanup` by `setup.sh`. Docker log rotation (20m/3 files) handles Transmission's logging; no separate log rotation is needed.

Mushr provides a reverse proxy (Caddy) and wildcard DNS (dnsmasq) so all web services are accessible via clean subdomain URLs instead of remembering port numbers. Services are available via two domain systems:
- **`*.loft.hsimah.com`** — HTTPS with real Let's Encrypt certificates (via Cloudflare DNS-01 challenge, no open ports required)
- **`*.space-needle`** — HTTP-only LAN fallback for backward compatibility

A shared `loft-proxy` Docker bridge network connects Caddy to bridge-networked services (pupyrus, pulsr, pulsr-phanpy, pawst, radarr, sonarr, lidarr, bazarr, jackett, beszel, uptime, homepage, cloudflared); host-network services (pawpcorn, howlr, snapweb, transmission/slskd via the VPN container, snoot) are reached via `host.docker.internal`. Pulsr uses path-based routing: the Phanpy web client is the default, while GoToSocial API paths (`/api/*`, `/.well-known/*`, `/settings/*`, etc.) are proxied to GoToSocial directly.

A Cloudflare Tunnel (`mushr-tunnel`) provides external access to Pulsr and Pawst from outside the LAN. The tunnel makes outbound-only connections to Cloudflare's edge — no router ports need to be opened. LAN clients still resolve `pulsr.hsimah.com`, `hbla.ke`, and `hsimah.com` via dnsmasq to the LAN IP, so local traffic bypasses the tunnel entirely. Pulsr uses `pulsr.hsimah.com` (not `*.loft.hsimah.com`) because Cloudflare's free Universal SSL only covers single-level subdomains. Pawst serves two blogs: `hbla.ke` and `hsimah.com`, each with its own domain and Nginx server block.

Howlr uses Docker Compose profiles: `COMPOSE_PROFILES=server` on space-needle runs **Music Assistant** — a unified music control server with a built-in Snapcast server, Spotify Connect plugin, and AirPlay Receiver plugin. `COMPOSE_PROFILES=client` on Pis runs snapclient. The `.env` file controls which profile is active.

Music Assistant provides a web UI (`howlr.loft.hsimah.com`) where you can browse music from multiple sources (Spotify, Apple Music, Tidal, Plex, local files, etc.), pick a room, and play. Rooms are managed as Snapcast player groups. You can also cast directly from the Spotify or AirPlay apps — each room appears as a Spotify Connect / AirPlay target. The built-in Snapcast server handles synchronized multi-room audio distribution to snapclients on viking and fjord.

**Known issues:**
- Spotify Connect and AirPlay Receiver plugins are early-stage with 0.5–5 second startup latency on play/pause/skip. Ongoing playback is real-time with no degradation.
- Spotify Connect: only one target can be active per Spotify account at a time. Family plan members with separate logins can stream to different rooms simultaneously.
- Music Assistant server requires Raspberry Pi 4+ for arm64; Pi 3 B+ hosts (viking, fjord) run snapclient only.

Spinnik (spin + Sputnik) runs on calavera and streams vinyl audio from an Audio-Technica LP5X turntable connected via USB. DarkIce captures the LP5X's ALSA device, encodes to Ogg Vorbis (~256kbps), and sends the stream to a local Icecast server at `http://calavera:8000/vinyl`. Music Assistant on space-needle picks up this URL as a radio station and distributes the audio to all Snapcast clients across the fleet. A udev rule pins the LP5X's USB audio chip (TI PCM2900C, `08bb:29c0`) to a stable ALSA device name `LP5X` so DarkIce can always reference `plughw:LP5X,0` regardless of USB enumeration order. The Spinnik web controller (`http://localhost:8080` on calavera) is a touch-optimized UI served by an nginx container in the spinnik service, local to the kiosk browser. Nginx proxies Music Assistant API calls to space-needle with server-side Bearer token injection (browser never handles auth) and proxies the Icecast stream at `/stream` for same-origin Web Audio API access, enabling a real-time audio visualizer. The UI includes a canvas-based frequency bar visualizer that reacts to the vinyl stream during playback.

### Directory Layout

```
the-loft/
├── hosts/
│   ├── space-needle/
│   │   ├── host.conf                          # Host manifest
│   │   └── profile.jpg                        # Pulsr avatar for fleet account
│   ├── viking/
│   │   ├── host.conf
│   │   └── profile.jpg                        # Pulsr avatar for fleet account
│   ├── fjord/
│   │   ├── host.conf
│   │   └── profile.jpg                        # Pulsr avatar for fleet account
│   └── calavera/
│       └── host.conf                          # Kiosk host (Surface Pro 2)
├── services/
│   ├── pawpcorn/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   ├── stellarr/
│   │   ├── docker-compose.yml
│   │   ├── setup.sh                       # Per-service setup (transmission cron)
│   │   ├── transmission/
│   │   │   └── remove-torrents.sh         # Cron job: removes torrents at 200% ratio
│   │   └── .env.example
│   ├── pupyrus/
│   │   ├── docker-compose.yml
│   │   ├── setup.sh                       # Per-service setup (WordPress install)
│   │   └── .env.example
│   ├── howlr/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   ├── mushr/
│   │   ├── docker-compose.yml
│   │   ├── Dockerfile.caddy
│   │   ├── Caddyfile
│   │   ├── dnsmasq.conf
│   │   └── .env.example
│   ├── pulsr/
│   │   ├── docker-compose.yml
│   │   ├── setup.sh                       # Per-service setup (fleet account provisioning)
│   │   └── .env.example
│   ├── pawst/
│   │   ├── docker-compose.yml
│   │   └── nginx.conf
│   ├── spinnik/
│   │   ├── docker-compose.yml
│   │   ├── Dockerfile.darkice
│   │   ├── darkice.cfg
│   │   ├── nginx.conf                       # Nginx config for UI (MA API + Icecast proxy)
│   │   ├── ui/
│   │   │   └── index.html                   # Vinyl turntable web controller + visualizer
│   │   └── .env.example
│   ├── houstn/
│   │   ├── docker-compose.yml              # Beszel hub + Uptime Kuma + Homepage dashboard
│   │   ├── .env.example
│   │   └── homepage-config/                # Homepage YAML (version-controlled, bind-mounted)
│   │       ├── settings.yaml
│   │       ├── services.yaml
│   │       ├── widgets.yaml
│   │       ├── bookmarks.yaml
│   │       └── docker.yaml
│   └── snoot/
│       ├── docker-compose.yml              # Beszel agent (sniffs each host for the hub)
│       └── .env.example
├── control-plane/
│   ├── common.sh
│   ├── deploy-pull.sh                   # Hourly puller — pulls GitHub Releases into bind-mounted dirs
│   ├── github-app-token.sh              # Generates GitHub App installation tokens (optional auth for deploy-pull)
│   ├── image-collector.sh               # Docker image update checker for fleet status reporting
│   ├── package-collector.sh              # Package update cache for fleet status reporting
│   └── pulsr-collector.sh                # CPU sampler for fleet status reporting
├── plans/
│   ├── howlr.md
│   └── raspberry-pi.md
├── setup.sh
├── loft-ctl
├── pulsr-ctl
├── bashrc.d                               # Shared shell config (prompt, terminal title, aliases)
├── inputrc.d
├── nanorc.d
├── daemon.json
├── .github/workflows/validate.yml
├── .gitignore
├── CLAUDE.md
├── DEBUG.md
└── README.md
```

### Compose Override Pattern

Services are defined once in `services/<name>/docker-compose.yml`. Per-host customization uses Docker Compose's native merge via override files at `hosts/<hostname>/overrides/<service>/docker-compose.override.yml`.

### Users & Groups

Consistent across all hosts:

| User | UID | Primary Group | Shell | Additional Groups | Role |
|------|-----|---------------|-------|-------------------|------|
| `littledog` | 1003 | `pack-member` (1003) | `/usr/sbin/nologin` | `docker` + host-specific | Service account for all containers |
| `adminhabl` | auto | `adminhabl` | `/bin/bash` | `sudo`, `docker`, `pack-member` | Admin (passworded, no SSH) |
| `hsimah` | auto | `hsimah` | `/bin/bash` | `pack-member` | SSH user, manages repo |
| `kiosk` | auto | `kiosk` | `/bin/bash` | `video` | Kiosk display account (kiosk hosts only) |

Host-specific groups (e.g. `render,video` on space-needle) are configured in `host.conf` via `LITTLEDOG_EXTRA_GROUPS`.

### Storage Layout (space-needle only)

```
/mammoth                          XFS volume (/dev/sda1)
  /library
    /movies                       Pawpcorn + Radarr
    /tv                           Pawpcorn + Sonarr
    /music                        Pawpcorn + Lidarr + slskd shared
    /videos                       Pawpcorn
    /stand-up                     Pawpcorn
  /downloads
    /incomplete                   Shared incomplete dir (Transmission + slskd)
    /completed
      /radarr                     Transmission completed — movies
      /sonarr                     Transmission completed — TV
      /lidarr                     Transmission completed — music + slskd downloads
  /pawpcorn/transcode             Plex transcoding workspace

/opt
  /pawpcorn/config                Plex configuration
  /radarr                         Radarr configuration
  /sonarr                         Sonarr configuration
  /lidarr                         Lidarr configuration
  /bazarr                         Bazarr configuration
  /jackett                        Jackett configuration
  /transmission                   Transmission configuration
  /slskd                          slskd configuration + state
  /pupyrus/html                   WordPress files
  /pupyrus/db                     MariaDB data
  /howlr                          Music Assistant data (Snapcast config, plugin state, library DB)
  /pulsr/data                     GoToSocial database + media storage
  /houstn/beszel/data             Beszel hub database + config
  /houstn/uptime/data             Uptime Kuma database + monitor config
  /pawst/hblake-html              hbla.ke static site (deployed by deploy-pull.sh)
  /pawst/hsimah-html              hsimah.com static site (deployed by deploy-pull.sh)
```

Houstn's Homepage container has no `/opt` directory — its config YAML files live in `services/houstn/homepage-config/` and are bind-mounted directly from the repo into the container.

All `/opt` config dirs are owned `littledog:pack-member` (755). All `/mammoth` media dirs are owned `littledog:pack-member` (775). Viking/fjord have no storage mount or `/opt` directories.

## Host Configuration

Each host is defined by `hosts/<hostname>/host.conf`, a bash-sourceable file declaring:

| Variable | Purpose |
|----------|---------|
| `HOST_NAME` | Hostname identifier |
| `SERVICES` | Array of service names to deploy |
| `STORAGE_DEVICE` / `STORAGE_MOUNT` / `STORAGE_FS` | Storage mount config (empty = no mount) |
| `CONFIG_DIRS` | Array of `/opt` config directories to create (755) |
| `MEDIA_DIRS` | Array of media directories to create (775) |
| `LITTLEDOG_EXTRA_GROUPS` | Additional groups for littledog (e.g. `render,video`) |
| `SSH_DISABLE_PASSWORD` | Whether to disable SSH password auth (`true`/`false`) |
| `REPORT_DISKS` | Array of mount points to include in fleet status reports |
| `SERVICE_ENDPOINTS` | Associative array mapping service name → space-separated endpoint labels |
| `SERVICE_ENDPOINTS_WARN` | Associative array mapping service name → space-separated warn-only endpoint labels |
| `HEALTH_URLS` | Associative array of `label:tier` → URL (tiers: `local`, `lan`, `ssl`) |
| `HEALTH_URLS_WARN` | Associative array of `label:tier` → URL (warn-only, e.g. VPN-dependent) |
| `DEPLOY_TARGETS` | Array of `name|owner/repo|target_dir|optional_post_hook` strings for the pull-based deployer (see [Pull-Based Deploys](#pull-based-deploys)) |
| `KIOSK_ENABLED` | Enable kiosk provisioning — `true`/`false` (default: `false`) |
| `KIOSK_URL` | URL to display in the kiosk browser (requires `KIOSK_ENABLED=true`) |
| `KIOSK_SCALE` | Display scale factor, e.g. `1.5` (requires `KIOSK_ENABLED=true`) |

## Log Rotation

Docker log rotation is configured at two levels:

**Global default** (`daemon.json` installed to `/etc/docker/daemon.json`):
- Driver: `json-file`, max-size: `10m`, max-file: `3` (30MB per container)

**Per-service overrides** (in compose files):

| Service | max-size | max-file | Reason |
|---------|----------|----------|--------|
| vpn | 20m | 5 | VPN reconnections and network events |
| transmission | 20m | 3 | Transfer activity logging |
| pawpcorn | 20m | 3 | Media scanning and transcoding |
| db (mariadb) | 10m | 5 | Query logs can spike; longer retention |
| wordpress | 5m | 3 | Relatively quiet |
| redis | 5m | 3 | Low-volume object cache |
| cli | 1m | 2 | Only runs occasionally |
| radarr/sonarr/lidarr | 5m | 3 | Moderate media management logging |
| bazarr | 5m | 3 | Subtitle management logging |
| slskd | 5m | 3 | Moderate logging |
| jackett | 5m | 3 | Moderate logging |
| mushr (caddy) | 5m | 3 | Reverse proxy access logging |
| mushr-dns | 5m | 3 | DNS query logging |
| mushr-tunnel | 5m | 3 | Cloudflare Tunnel connection logging |
| howlr (Music Assistant) | 10m | 3 | Music server + built-in Snapcast + receiver plugins |
| snapclient | 5m | 3 | Audio client logging |
| pulsr | 10m | 3 | Fediverse instance (GoToSocial) |
| pulsr-phanpy | 5m | 3 | Phanpy web client (static files) |
| pawst | 5m | 3 | Static blogs — hbla.ke + hsimah.com (nginx) |
| spinnik-icecast | 5m | 3 | Icecast streaming server |
| spinnik-darkice | 5m | 3 | DarkIce audio encoder |
| spinnik-ui | 5m | 3 | Nginx serving vinyl controller UI |
| beszel | 10m | 3 | Beszel monitoring hub (houstn) |
| uptime | 10m | 3 | Uptime Kuma status monitor (houstn) |
| homepage | 10m | 3 | Homepage fleet dashboard (houstn) |
| snoot | 5m | 3 | Beszel agent (host metrics + Docker stats) |

## Security Model

- **SSH**: Only `hsimah` can SSH in (`AllowUsers hsimah` in sshd_config)
- **SSH passwords**: Disabled on Pis (`SSH_DISABLE_PASSWORD=true`), enabled on space-needle
- **Admin escalation**: `loft-ctl` auto-elevates to `adminhabl` via `su` for docker commands; `adminhabl` alias also available for manual escalation
- **Sudo**: `adminhabl` has full sudo via `/etc/sudoers.d/adminhabl`
- **Containers**: All run as `littledog` (UID/GID 1003), a nologin service account
- **External access**: Pulsr and Pawst (hbla.ke + hsimah.com) are exposed externally via Cloudflare Tunnel (outbound-only, no open ports). All other services remain LAN-only
- **Kiosk lockdown** (calavera): Chromium managed policies restrict URL navigation to the allowlist; Cage compositor prevents app switching or escape; kiosk user has no sudo or docker access

## Debugging

See [DEBUG.md](DEBUG.md) for a comprehensive debugging guide covering container state inspection, log analysis, database debugging, network troubleshooting, Caddy/TLS diagnostics, and common failure patterns with fixes.

## Quick Start

### Fresh host setup

```bash
# Generate an SSH key for GitHub access
sudo ssh-keygen -t ed25519 -C "<hostname>@loft.hsimah.com"
sudo cat /root/.ssh/id_ed25519.pub
# Add the public key as a read-only deploy key at:
# https://github.com/hsimah-services/the-loft/settings/keys

# Clone the repo
sudo git clone git@github.com:hsimah-services/the-loft.git /srv/the-loft
cd /srv/the-loft

# Copy .env.example files and fill in secrets for this host's services
# (check hosts/<hostname>/host.conf for the SERVICES list)
cp services/howlr/.env.example services/howlr/.env
# On space-needle also:
cp services/pawpcorn/.env.example services/pawpcorn/.env
cp services/stellarr/.env.example services/stellarr/.env
cp services/pupyrus/.env.example services/pupyrus/.env
cp services/mushr/.env.example services/mushr/.env
cp services/pulsr/.env.example services/pulsr/.env
cp services/houstn/.env.example services/houstn/.env
# On all hosts (snoot — Beszel agent):
cp services/snoot/.env.example services/snoot/.env
# Note: BESZEL_KEY is empty until the Beszel hub is running — fill it in after first launch (see Fleet Monitoring)

# Edit each .env file with real values
# Then run setup as root:
sudo bash setup.sh
```

### Managing services

Commands that need docker access (`start`, `stop`, `rebuild`, `health`, `update`) auto-elevate to `adminhabl` via `su` when run as another user. You'll be prompted for the admin password.

```bash
# Show usage (dynamically shows this host's services)
loft-ctl

# Start / stop containers
loft-ctl start --all
loft-ctl start pawpcorn stellarr
loft-ctl stop stellarr

# Full rebuild (down + pull images + up — fresh mounts)
loft-ctl rebuild --all
loft-ctl rebuild pawpcorn

# Run health checks (defaults to all services)
loft-ctl health
loft-ctl health pawpcorn stellarr

# Update: git pull + rebuild + health check
loft-ctl update --all
loft-ctl update pawpcorn stellarr

# Update from a specific branch
loft-ctl update --branch feature/ssl --all

# Rebuild without pulling git changes
loft-ctl update --no-pull pawpcorn
```

### Managing Pulsr accounts

`pulsr-ctl` wraps GoToSocial admin commands for managing accounts on the Pulsr instance. Like `loft-ctl`, it auto-elevates to `adminhabl` for docker access.

```bash
# Show usage
pulsr-ctl

# Create a regular account
pulsr-ctl user-add --username alice --email alice@example.com --password 'MyP@ss123'

# Create an admin account
pulsr-ctl user-add --username bob --email bob@example.com --password 'MyP@ss123' --admin

# Get an API token for automated posting
pulsr-ctl user-token --email alice@example.com --password 'MyP@ss123'

# Set a profile picture
pulsr-ctl set-avatar --image hosts/space-needle/profile.jpg

# Post a status update
pulsr-ctl post --message "Server is alive at $(date)"
```

Accounts are automatically confirmed (no email verification on self-hosted instances).

API tokens are obtained via the full OAuth flow (app creation → sign-in → authorize → token exchange) and do not expire unless revoked. Store the token as `GTS_TOKEN` in `services/pulsr/.env`.

After each `rebuild` or `update`, the script verifies:
1. **Container check** — all containers in the compose file are "running" (retries for up to 30s)
2. **Web UI check** — for the targeted service only, checks each endpoint across three tiers:
   - **local** — direct port access (e.g. `http://localhost:7878`)
   - **lan** — dnsmasq subdomain (e.g. `http://radarr.space-needle`)
   - **ssl** — HTTPS with real certificates (e.g. `https://radarr.loft.hsimah.com`)

### Adding a new host

1. Create `hosts/<hostname>/host.conf` with the host's config
2. Optionally create override files in `hosts/<hostname>/overrides/<service>/`
3. Clone the repo on the new host to `/srv/the-loft`
4. Copy and fill in `.env` files for the host's services
5. Run `sudo bash setup.sh`


## Fleet Monitoring

Houstn is the central observability stack on space-needle, bundling three containers (`beszel`, `uptime`, `homepage`) into one compose file at `services/houstn/`. Snoot is the Beszel agent that runs on every host and reports back to the hub.

### Beszel — Host Metrics & Docker Stats

The Beszel hub (`henrygd/beszel`) is a web dashboard showing real-time and historical CPU, RAM, disk, and network metrics per host, plus per-container Docker stats. The agent (`snoot`) runs on every host with `network_mode: host` so it can see both system resources and all Docker containers.

**Setup (one-time after first deploy):**

1. Deploy houstn on space-needle: `loft-ctl start houstn`
2. Open `https://beszel.loft.hsimah.com` and create the admin account
3. Click **Add System** for each host. Beszel will show a `docker run` command — copy the `KEY=` value
4. Set `BESZEL_KEY=<value>` in `services/snoot/.env` on **every host** (same key for all)
5. Start the agents: `loft-ctl start snoot` on each host
6. Back in the Beszel UI, configure each system's connection:
   - `space-needle`: host `host.docker.internal`, port `45876` (the hub container can't reach `localhost`; `host.docker.internal` resolves to the host gateway via the `extra_hosts` entry in the compose)
   - `calavera`: host `calavera`, port `45876`
   - `fjord` / `viking`: use each host's LAN IP, port `45876`

> Add fjord and viking to `services/mushr/dnsmasq.conf` if they have static IPs, so you can use hostnames instead of IPs in the Beszel UI.

### Uptime Kuma — Endpoint Monitoring

Uptime Kuma (`louislam/uptime-kuma:1`) is an HTTP polling monitor with a live status dashboard. Configure monitors via the web UI at `https://uptime.loft.hsimah.com` pointing at the fleet's existing health check URLs (defined in each host's `host.conf`).

**Suggested monitors** (from `hosts/space-needle/host.conf` `HEALTH_URLS`):

| Monitor | URL |
|---------|-----|
| Pawpcorn | `https://pawpcorn.loft.hsimah.com` |
| Radarr | `https://radarr.loft.hsimah.com` |
| Sonarr | `https://sonarr.loft.hsimah.com` |
| Lidarr | `https://lidarr.loft.hsimah.com` |
| Bazarr | `https://bazarr.loft.hsimah.com` |
| Jackett | `https://jackett.loft.hsimah.com` |
| Howlr | `https://howlr.loft.hsimah.com` |
| Pupyrus | `https://pupyrus.loft.hsimah.com` |
| Pawst (hbla.ke) | `https://hbla.ke` |
| Pawst (hsimah.com) | `https://hsimah.com` |

### Homepage — Fleet Dashboard

Homepage (`ghcr.io/gethomepage/homepage`) is a unified fleet overview at `https://homepage.loft.hsimah.com`, with live widgets for Plex streams/library counts, *arr stats, download queue, and container status via the Docker socket.

Configuration lives in `services/houstn/homepage-config/` (bind-mounted from the repo, version-controlled): `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `settings.yaml`, `docker.yaml`. API tokens and other secrets are kept out of the YAML and substituted from `services/houstn/.env` via `HOMEPAGE_VAR_*` placeholders (e.g. `{{HOMEPAGE_VAR_RADARR_API_KEY}}`).

## Fleet Status Reporting

Each fleet host automatically posts system metrics to Pulsr (GoToSocial) every 6 hours. This provides visibility into fleet health through the Fediverse timeline.

### Architecture

- Each host gets its own GoToSocial account (e.g. `space_needle`, `viking`, `fjord`)
- A CPU sampler (`control-plane/pulsr-collector.sh`) runs every minute via cron, appending CPU usage % to `/var/log/loft/cpu.log`
- A package collector (`control-plane/package-collector.sh`) runs every 6 hours via cron, caching security/total update counts and reboot-required status to `/var/log/loft/packages.log`
- An image collector (`control-plane/image-collector.sh`) runs daily via cron, checking running Docker containers for available image updates via `skopeo` and caching results to `/var/log/loft/images.log`
- Every 6 hours, `pulsr-ctl report` reads the CPU log, package cache, and image cache, collects memory/disk/git metrics, and posts a status update
- Reports include hashtags `#LoftServiceUpdate` and `#<HostName>Update` for filtering

### Cron Jobs

| Cron File | Schedule | Purpose |
|-----------|----------|---------|
| `/etc/cron.d/loft-cpu-collector` | Every minute | Sample CPU usage to `/var/log/loft/cpu.log` |
| `/etc/cron.d/loft-image-collector` | Daily at 5:25 AM | Check Docker images for updates to `/var/log/loft/images.log` |
| `/etc/cron.d/loft-package-collector` | Every 6 hours (30 min before report) | Cache package update counts to `/var/log/loft/packages.log` |
| `/etc/cron.d/loft-wifi-watchdog` | Every 5 minutes | Restart dhcpcd if wlan0 loses IPv4 (no-op on hosts without WiFi) |
| `/etc/cron.d/loft-pulsr-report` | Every 6 hours | Post status report to Pulsr |
| `/etc/cron.d/loft-deploy-<name>` | Hourly | Pull-based release deployer — one entry per `DEPLOY_TARGETS` member (see [Pull-Based Deploys](#pull-based-deploys)) |

### Account Provisioning

Fleet accounts are created automatically by `setup.sh` on space-needle (which hosts Pulsr). Each host's profile picture (`hosts/<hostname>/profile.jpg`) is set as the account avatar during setup. Each host's credentials:

| Host | Username | Email |
|------|----------|-------|
| space-needle | `space_needle` | `space-needle@loft.hsimah.com` |
| viking | `viking` | `viking@loft.hsimah.com` |
| fjord | `fjord` | `fjord@loft.hsimah.com` |
| calavera | `calavera` | `calavera@loft.hsimah.com` |

API tokens are stored at `/etc/loft/pulsr.env` on each host (created by `setup.sh`). The `REPORT_DISKS` variable in each host's `host.conf` controls which mount points are included in disk metrics.

### Manual Reporting

```bash
# Post a status report manually
sudo pulsr-ctl report
```

## Raspberry Pi Fleet

Two Raspberry Pi 3 B+ devices (`viking` and `fjord`) in The Loft run Docker with howlr (Snapcast client) and snoot (Beszel agent), using the same unified `setup.sh` and user/group model as space-needle.

### Pi Setup

Pis use the same `setup.sh` as space-needle. The script auto-detects the hostname and sources `hosts/$(hostname)/host.conf`.

```bash
# Clone repo on the Pi
sudo git clone <repo-url> /srv/the-loft
cd /srv/the-loft

# Configure services
sudo cp services/howlr/.env.example services/howlr/.env
sudo cp services/snoot/.env.example services/snoot/.env
# Edit .env files — set COMPOSE_PROFILES=client, SNAPSERVER_HOST, SOUND_DEVICE, HOST_ID for howlr
sudo nano services/howlr/.env

# Run setup
sudo bash setup.sh
```

See `plans/raspberry-pi.md` for the full provisioning guide.

## Calavera — Kiosk Display

A Surface Pro 2 (x86_64, 4GB RAM, Ubuntu) in a dock, used as a touchscreen kiosk displaying the Spinnik vinyl turntable controller — a touch-optimized web UI served locally by nginx (`http://localhost:8080`) for starting/stopping vinyl playback, choosing speaker groups (Upstairs, Downstairs, All), and displaying a real-time audio visualizer. Also connected to an Audio-Technica LP5X turntable via USB — the spinnik service streams vinyl audio to the fleet via Icecast.

### Architecture

```
greetd (auto-login as kiosk user)
  └── cage (Wayland kiosk compositor — single fullscreen app)
       └── chromium --kiosk (URL-restricted via managed policies)

```

- **Cage**: Minimal Wayland compositor (~5MB) that displays exactly one fullscreen app with no window management, panels, or escape vectors
- **Chromium managed policies**: `URLBlocklist` blocks all URLs by default; `URLAllowlist` permits only `*.loft.hsimah.com`, `*.space-needle`, `pulsr.hsimah.com`, `hbla.ke`, `hsimah.com`, `calavera`, and `localhost`
- **Display**: 10.6" 1080p touchscreen at 150% scaling (`--force-device-scale-factor=1.5`)
- **Power**: Suspend, sleep, and hibernate are masked; lid switch is ignored (always-on display)

### Kiosk Host Config Variables

| Variable | Purpose |
|----------|---------|
| `KIOSK_ENABLED` | Enable kiosk provisioning (`true`/`false`) |
| `KIOSK_URL` | URL to display on startup |
| `KIOSK_SCALE` | Display scale factor (e.g. `1.5` for 150%) |

### Adding Services to the Allowlist

To allow the kiosk to navigate to additional URLs, edit `/etc/chromium/policies/managed/kiosk.json` on calavera and add entries to the `URLAllowlist` array. Re-run `setup.sh` to restore the default allowlist.

## Mushr — Reverse Proxy & LAN DNS

Mushr provides subdomain-based access to all web services on space-needle via two domain systems:

### HTTPS — `*.loft.hsimah.com` (recommended)

Real Let's Encrypt certificates via Cloudflare DNS-01 challenge. No open ports or port forwarding required.

| URL | Service |
|-----|---------|
| `https://radarr.loft.hsimah.com` | Radarr |
| `https://sonarr.loft.hsimah.com` | Sonarr |
| `https://lidarr.loft.hsimah.com` | Lidarr |
| `https://bazarr.loft.hsimah.com` | Bazarr (subtitles) |
| `https://jackett.loft.hsimah.com` | Jackett |
| `https://pawpcorn.loft.hsimah.com` | Pawpcorn (Plex) |
| `https://pupyrus.loft.hsimah.com` | WordPress |
| `https://pulsr.hsimah.com` | Phanpy web client (default) / GoToSocial API |
| `https://transmission.loft.hsimah.com` | Transmission |
| `https://soulseek.loft.hsimah.com` | slskd |
| `https://howlr.loft.hsimah.com` | Music Assistant (Howlr) |
| `https://snapweb.loft.hsimah.com` | Snapweb |
| `https://beszel.loft.hsimah.com` | Houstn — Beszel (fleet metrics) |
| `https://uptime.loft.hsimah.com` | Houstn — Uptime Kuma (status monitor) |
| `https://homepage.loft.hsimah.com` | Houstn — Homepage (fleet dashboard) |
| `https://hbla.ke` | Pawst (hbla.ke blog) |
| `https://hsimah.com` | Pawst (hsimah.com blog) |
| `https://loft.hsimah.com` | WordPress (default) |

### HTTP — `*.space-needle` (LAN fallback)

HTTP-only, no TLS. Kept for backward compatibility.

| URL | Service |
|-----|---------|
| `http://radarr.space-needle` | Radarr |
| `http://sonarr.space-needle` | Sonarr |
| `http://lidarr.space-needle` | Lidarr |
| `http://bazarr.space-needle` | Bazarr (subtitles) |
| `http://jackett.space-needle` | Jackett |
| `http://pawpcorn.space-needle` | Pawpcorn (Plex) |
| `http://pupyrus.space-needle` | WordPress |
| `https://pulsr.space-needle` | Pulsr (self-signed TLS via `tls internal`) |
| `http://transmission.space-needle` | Transmission |
| `http://soulseek.space-needle` | slskd |
| `http://howlr.space-needle` | Music Assistant (Howlr) |
| `http://snapweb.space-needle` | Snapweb |
| `http://beszel.space-needle` | Houstn — Beszel (fleet metrics) |
| `http://uptime.space-needle` | Houstn — Uptime Kuma (status monitor) |
| `http://homepage.space-needle` | Houstn — Homepage (fleet dashboard) |
| `http://pawst.space-needle` | Pawst (hbla.ke blog) |
| `http://hsimah.space-needle` | Pawst (hsimah.com blog) |
| `http://space-needle` | WordPress (default) |

Direct port access continues to work for host-networked services (Plex on 32400, Music Assistant on 8095, Transmission on 9091, slskd on 5030, snapweb on 1780). Bridged services (Radarr/Sonarr/Lidarr/Bazarr/Jackett, Pupyrus, Pawst) no longer publish ports on the host — they are only reachable via Caddy at their `*.space-needle` or `*.loft.hsimah.com` URLs.

### DNS Setup

Before deploying, edit `services/mushr/dnsmasq.conf` and replace the `listen-address` and `address` entries with space-needle's actual LAN IP.

To use the subdomain URLs, point LAN clients' DNS at space-needle's IP:
- **Router DHCP** (recommended): Set the primary DNS server to space-needle's LAN IP in your router's DHCP settings. All devices on the network will automatically resolve `*.space-needle`, `*.loft.hsimah.com`, `pulsr.hsimah.com`, `hbla.ke`, and `hsimah.com`.
- **Per-device**: Manually set DNS to space-needle's LAN IP in each device's network settings.

### Cloudflare Setup (one-time)

To enable HTTPS with real certificates:

1. **Add your domains to Cloudflare**: Sign up at [cloudflare.com](https://dash.cloudflare.com), add `hsimah.com` and `hbla.ke`, and update each domain registrar's nameservers to the ones Cloudflare provides. No A records needed — DNS resolution is handled locally by dnsmasq.
2. **Create an API token**: Go to [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens), create a token with permissions **Zone > Zone > Read** and **Zone > DNS > Edit**, scoped to all zones (or all three: `hsimah.com`, `hbla.ke`, and `loft.hsimah.com`).
3. **Set the token in `.env`**: Copy `services/mushr/.env.example` to `.env` and fill in `CLOUDFLARE_API_TOKEN`.
4. **Rebuild mushr**: Caddy will automatically obtain and renew certificates via the DNS-01 challenge.

### Cloudflare Tunnel (external access)

To access Pulsr and Pawst from outside the LAN:

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels → Create
2. Name: `loft-pulsr`, connector: **Cloudflared**
3. Copy the tunnel token
4. Add public hostname: `pulsr.hsimah.com` → HTTPS → `mushr:443`, set **Origin Server Name** to `pulsr.hsimah.com`
5. Add public hostname: `hbla.ke` → HTTPS → `mushr:443`, set **Origin Server Name** to `hbla.ke`
6. Add public hostname: `hsimah.com` → HTTPS → `mushr:443`, set **Origin Server Name** to `hsimah.com`
7. Add `TUNNEL_TOKEN=<token>` to `services/mushr/.env`
8. `loft-ctl rebuild mushr`

Traffic flow: Internet → Cloudflare Edge → `cloudflared` tunnel → `https://mushr:443` → Caddy → target service. LAN clients bypass the tunnel entirely (dnsmasq resolves `pulsr.hsimah.com`, `hbla.ke`, and `hsimah.com` to the LAN IP).

## Pull-Based Deploys

Static-site / file-tree deploys (e.g. pawst's `hbla.ke` and `hsimah.com`) are delivered by an hourly puller on the host instead of being pushed by a self-hosted CI runner. This removes the attack surface of a runner with a docker.sock mount and means CI in the app repos runs on stock GitHub-hosted `ubuntu-latest`.

### How it works

1. The app repo's CI builds the static artifact, packs it as a `.tar.gz`, and attaches it to a tagged GitHub Release.
2. On space-needle, `/etc/cron.d/loft-deploy-<name>` (installed by `setup.sh` from each `DEPLOY_TARGETS` entry) runs `control-plane/deploy-pull.sh` hourly.
3. The puller queries `GET /repos/<owner>/<repo>/releases/latest`, compares the tag against `/var/lib/loft/deploy/<name>.version`, and on a new release downloads the asset and atomically swaps it into the bind-mounted target directory.
4. An optional post-deploy hook runs from the target dir (e.g. wp-cli cache flush).

Hourly is the default schedule. If you push a release and don't want to wait, run the deploy script manually:

```bash
sudo /srv/the-loft/control-plane/deploy-pull.sh pawst-hblake hsimah-services/hbla.ke /opt/pawst/hblake-html
```

### Configuring deploys

Add entries to `DEPLOY_TARGETS` in `hosts/<hostname>/host.conf`, one per line, pipe-delimited:

```bash
DEPLOY_TARGETS=(
  "pawst-hblake|hsimah-services/hbla.ke|/opt/pawst/hblake-html|"
  "pawst-hsimah|hsimah-services/hsimah.com|/opt/pawst/hsimah-html|"
)
```

Format: `name|owner/repo|target_dir|optional_post_hook`. The `name` is used as the state-file key and cron filename suffix. The optional post-deploy hook is a shell snippet run with `cwd = target_dir`. Re-run `sudo bash setup.sh` (or just `sudo bash` the cron-installing section) to materialize the cron entries.

The target dir must exist and should be in `CONFIG_DIRS` so `setup.sh` creates it with `littledog:pack-member` ownership.

### Authenticating private repos

Public repos work out of the box (unauthenticated GitHub API is sufficient for hourly polling of release metadata).

For private repos, install a GitHub App and drop its credentials at `/etc/loft/deploy.env`:

1. Create a GitHub App at `https://github.com/organizations/hsimah-services/settings/apps/new`
   - **Webhook**: Uncheck
   - **Permissions**: Repository > Contents: Read
   - **Install scope**: Only on this account, repos you want to deploy
2. Note the **App ID**, generate a **private key** (downloads `.pem`), and install the app to capture the **Installation ID** (from the URL `/installations/{id}`).
3. On the deploying host:

```bash
sudo mkdir -p /etc/loft
sudo cp loft-deploy-app.pem /etc/loft/loft-deploy-app.pem
sudo chmod 600 /etc/loft/loft-deploy-app.pem
sudo tee /etc/loft/deploy.env >/dev/null <<'EOF'
LOFT_DEPLOY_APP_ID=<app id>
LOFT_DEPLOY_INSTALLATION_ID=<installation id>
LOFT_DEPLOY_KEY_PATH=/etc/loft/loft-deploy-app.pem
EOF
sudo chmod 600 /etc/loft/deploy.env
```

`deploy-pull.sh` auto-detects the env file via `control-plane/github-app-token.sh`. If credentials are absent it falls back to unauthenticated requests, so leaving the env file unset keeps public-repo deploys working.

### Release workflow contract

Each app repo's CI should produce a tarball asset on every release. A minimal `release.yml` for a static-site repo:

```yaml
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci && npm run build
      - name: Package
        run: tar -czf site.tar.gz -C dist .
      - name: Release
        uses: softprops/action-gh-release@v2
        with:
          files: site.tar.gz
```

The tarball can either be flat (files at the root, as above) or have a single top-level wrapper directory; `deploy-pull.sh` handles both.

## Environment Files

Each service that needs secrets has a `.env.example` template. Copy it to `.env` and fill in real values. The `.env` files are gitignored.

| Service | Required Variables |
|---------|--------------------|
| Pawpcorn | `PLEX_CLAIM`, `PUID`, `PGID`, `TZ` |
| Stellarr | `NORDVPN_TOKEN`, `PUID`, `PGID`, `TZ` |
| Pupyrus | `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `GRAPHQL_JWT_AUTH_SECRET_KEY` |
| Howlr (server) | `COMPOSE_PROFILES=server` |
| Howlr (client) | `COMPOSE_PROFILES=client`, `SNAPSERVER_HOST`, `SOUND_DEVICE`, `HOST_ID` |
| Mushr | `LOFT_DOMAIN`, `CLOUDFLARE_API_TOKEN`, `TUNNEL_TOKEN` (edit `dnsmasq.conf` with LAN IP before deploying) |
| Pulsr | `GTS_HOST`, `GTS_PROTOCOL`, `GTS_TOKEN` (for `pulsr-ctl post`), `TZ` |
| Spinnik | `ICECAST_SOURCE_PASSWORD`, `ICECAST_ADMIN_PASSWORD` (source password must match `darkice.cfg`), `MA_HOST`, `MA_API_TOKEN` |
| Houstn | `HOMEPAGE_VAR_*` placeholders for the Homepage dashboard (Plex token, *arr API keys, Transmission/slskd creds, Uptime Kuma slug). Beszel and Uptime Kuma have no required env vars |
| Snoot | `BESZEL_KEY`, `BESZEL_TOKEN` (copy from the Beszel hub UI after first launch — see Fleet Monitoring setup) |

## CI

A GitHub Actions workflow validates on every push:
- Creates shared Docker networks (`loft-proxy`) needed by external network references
- All base `docker-compose.yml` files pass `docker compose config --quiet`
- Howlr compose validated with both `COMPOSE_PROFILES=server` and `COMPOSE_PROFILES=client`
- All compose + override combinations validate
- All shell scripts (`setup.sh`, `loft-ctl`, `pulsr-ctl`, `control-plane/*.sh`, `services/*/setup.sh`) pass `bash -n` syntax check
- All `host.conf` files pass `bash -n` syntax check
