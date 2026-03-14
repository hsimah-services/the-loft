# the-loft

Fleet configuration for The Loft — a mono-repo managing all hosts (space-needle, viking, fjord) with shared service definitions, per-host configuration, and a unified setup/control-plane.

## Architecture

### Fleet

| Host | Role | Services |
|------|------|----------|
| `space-needle` | Primary server | mushr, plex, media, pupyrus, iditarod, howlr (server), pulsr (+ phanpy), hblake |
| `viking` | Raspberry Pi 3 B+ | iditarod, howlr (client) |
| `fjord` | Raspberry Pi 3 B+ | iditarod, howlr (client) |

Each host has a config file at `hosts/<hostname>/host.conf` that declares its services, storage, directories, and health check URLs. A single `setup.sh` provisions any host by reading its config.

### Services

| Service | Image | Ports | Config | Purpose |
|---------|-------|-------|--------|---------|
| Plex | `plexinc/pms-docker` | host network | `/opt/plex/config` | Media server |
| Media VPN | `bubuntux/nordvpn` | 9091, 6080 | — | Shared NordLynx VPN for Transmission + Soulseek |
| Transmission | `linuxserver/transmission` | 9091 (via VPN) | `/opt/transmission` | Torrent client |
| Soulseek | `realies/soulseek` | 6080 (via VPN) | `/opt/soulseek` | P2P music |
| Radarr | `linuxserver/radarr` | 7878 (host) | `/opt/radarr` | Movie management |
| Sonarr | `linuxserver/sonarr` | 8989 (host) | `/opt/sonarr` | TV management |
| Lidarr | `linuxserver/lidarr` | 8686 (host) | `/opt/lidarr` | Music management |
| Jackett | `linuxserver/jackett` | 9117 | `/opt/jackett` | Indexer proxy |
| Mushr (proxy) | `caddy:2-alpine` + Cloudflare DNS module (custom build) | 80, 443, 8880 | `Caddyfile`, `Dockerfile.caddy` | Reverse proxy with HTTPS (Let's Encrypt via DNS-01) + LAN HTTP fallback |
| Mushr (tunnel) | `cloudflare/cloudflared` | — (outbound only) | — | Cloudflare Tunnel — exposes Pulsr and Hblake externally without open ports |
| Mushr (DNS) | `drpsychick/dnsmasq` | 53/udp, 53/tcp | `dnsmasq.conf` | Wildcard DNS — resolves `*.space-needle` and `*.loft.hsimah.com` to LAN IP |
| Pupyrus | `wordpress` + `mariadb` + `redis` | 8081 | `/opt/pupyrus/html`, `/opt/pupyrus/db` | WordPress site (WPGraphQL + Redis object cache) |
| Iditarod | `actions/actions-runner` (custom build) | — | `.env` per host | Self-hosted GitHub Actions runner (org-level, serves all hsimah-services repos) |
| Howlr snapserver | `ivdata/snapserver` | 1704, 1705, 1780 (host) | `/opt/howlr`, `config/snapserver.conf`, `snapserver-data` volume | Snapcast sync engine + snapweb UI (speaker groups persist via volume) |
| Howlr shairport-sync | `mikebrady/shairport-sync` | host network | `config/shairport-sync.conf` | AirPlay receiver (feeds snapserver) |
| Howlr librespot | `giof71/librespot` | host network | — | Spotify Connect receiver (feeds snapserver) |
| Howlr snapclient | `ivdata/snapclient` | host network | `.env` per host | Snapcast client (receives stream, outputs to speakers) |
| Pulsr | `superseriousbusiness/gotosocial` | — (via Caddy) | `/opt/pulsr/data` | Self-hosted fediverse instance (GoToSocial) for status updates and household messaging |
| Pulsr Phanpy | `ghcr.io/yitsushi/phanpy-docker` | — | — | Web client for GoToSocial (served at `pulsr.space-needle/`) |
| Hblake | `nginx:alpine` | 8085 (bridge) | — | Static personal website served at `hbla.ke` |

Transmission and Soulseek route through a shared NordVPN (NordLynx) container (`media-vpn`). Radarr, Sonarr, and Lidarr use host networking. All six are managed together in `services/media/docker-compose.yml`.

Transmission torrents are automatically cleaned up by a cron job that runs nightly at midnight on space-needle. The `remove-torrents.sh` script (bind-mounted into the container) uses `transmission-remote` to find and remove any torrents that have reached a 200% seed ratio, deleting the download data. This is safe because Radarr/Sonarr/Lidarr hardlink files into `/mammoth/library` — the library copies are independent of the download directory. The cron job is installed to `/etc/cron.d/transmission-cleanup` by `setup.sh`. Docker log rotation (20m/3 files) handles Transmission's logging; no separate log rotation is needed.

Mushr provides a reverse proxy (Caddy) and wildcard DNS (dnsmasq) so all web services are accessible via clean subdomain URLs instead of remembering port numbers. Services are available via two domain systems:
- **`*.loft.hsimah.com`** — HTTPS with real Let's Encrypt certificates (via Cloudflare DNS-01 challenge, no open ports required)
- **`*.space-needle`** — HTTP-only LAN fallback for backward compatibility

A shared `loft-proxy` Docker bridge network connects Caddy to bridge-networked services (pupyrus, pulsr, pulsr-phanpy, hblake, cloudflared); host-network services are reached via `host.docker.internal`. Pulsr uses path-based routing: the Phanpy web client is the default, while GoToSocial API paths (`/api/*`, `/.well-known/*`, `/settings/*`, etc.) are proxied to GoToSocial directly.

A Cloudflare Tunnel (`mushr-tunnel`) provides external access to Pulsr and Hblake from outside the LAN. The tunnel makes outbound-only connections to Cloudflare's edge — no router ports need to be opened. LAN clients still resolve `pulsr.hsimah.com` and `hbla.ke` via dnsmasq to the LAN IP, so local traffic bypasses the tunnel entirely. Pulsr uses `pulsr.hsimah.com` (not `*.loft.hsimah.com`) because Cloudflare's free Universal SSL only covers single-level subdomains. Hblake uses its own domain (`hbla.ke`).

Howlr uses Docker Compose profiles: `COMPOSE_PROFILES=server` on space-needle runs snapserver + shairport-sync + librespot; `COMPOSE_PROFILES=client` on Pis runs snapclient. The `.env` file controls which profile is active.

**Known issue:** The AirPlay stream uses AirPlay 2 format (48kHz/32-bit) which crashes the snapweb browser client. Use native snapclient devices (viking, fjord) for AirPlay playback. Spotify Connect works on all clients including snapweb.

### Directory Layout

```
the-loft/
├── hosts/
│   ├── space-needle/
│   │   ├── host.conf                          # Host manifest
│   │   └── overrides/
│   │       └── iditarod/
│   │           └── docker-compose.override.yml # Pupyrus mounts for runner
│   ├── viking/
│   │   └── host.conf
│   └── fjord/
│       └── host.conf
├── services/
│   ├── plex/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   ├── media/
│   │   ├── docker-compose.yml
│   │   ├── transmission/
│   │   │   └── remove-torrents.sh         # Cron job: removes torrents at 200% ratio
│   │   └── .env.example
│   ├── pupyrus/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   ├── iditarod/
│   │   ├── docker-compose.yml
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh
│   │   └── .env.example
│   ├── howlr/
│   │   ├── docker-compose.yml
│   │   ├── config/
│   │   │   ├── snapserver.conf
│   │   │   └── shairport-sync.conf
│   │   └── .env.example
│   ├── mushr/
│   │   ├── docker-compose.yml
│   │   ├── Dockerfile.caddy
│   │   ├── Caddyfile
│   │   ├── dnsmasq.conf
│   │   └── .env.example
│   ├── pulsr/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   └── hblake/
│       ├── docker-compose.yml
│       └── html/
│           └── index.html
├── control-plane/
│   └── common.sh
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
└── README.md
```

### Compose Override Pattern

Services are defined once in `services/<name>/docker-compose.yml`. Per-host customization uses Docker Compose's native merge via override files at `hosts/<hostname>/overrides/<service>/docker-compose.override.yml`.

Example: space-needle's iditarod gets pupyrus volume mounts via override. Viking/fjord get the base compose only (no pupyrus).

### Users & Groups

Consistent across all hosts:

| User | UID | Primary Group | Shell | Additional Groups | Role |
|------|-----|---------------|-------|-------------------|------|
| `littledog` | 1003 | `pack-member` (1003) | `/usr/sbin/nologin` | `docker` + host-specific | Service account for all containers |
| `adminhabl` | auto | `adminhabl` | `/bin/bash` | `sudo`, `docker`, `pack-member` | Admin (passworded, no SSH) |
| `hsimah` | auto | `hsimah` | `/bin/bash` | `pack-member` | SSH user, manages repo |

Host-specific groups (e.g. `render,video` on space-needle) are configured in `host.conf` via `LITTLEDOG_EXTRA_GROUPS`.

### Storage Layout (space-needle only)

```
/mammoth                          XFS volume (/dev/sda1)
  /library
    /movies                       Plex + Radarr
    /tv                           Plex + Sonarr
    /music                        Plex + Lidarr + Soulseek shared
    /videos                       Plex
    /stand-up                     Plex
  /downloads
    /transmission                 Transmission downloads
    /soulseek                     Soulseek downloads
  /plex/transcode                 Plex transcoding workspace

/opt
  /plex/config                    Plex configuration
  /radarr                         Radarr configuration
  /sonarr                         Sonarr configuration
  /lidarr                         Lidarr configuration
  /jackett                        Jackett configuration
  /transmission                   Transmission configuration
  /soulseek                       Soulseek configuration
  /soulseek/logs                  Soulseek chat logs
  /pupyrus/html                   WordPress files
  /pupyrus/db                     MariaDB data
  /iditarod                       GitHub Actions runner workdir
  /howlr                          Howlr persistent data
  /pulsr/data                     GoToSocial database + media storage
```

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
| `HEALTH_URLS` | Associative array of required health check endpoints |
| `HEALTH_URLS_WARN` | Associative array of warn-only health check endpoints |

## Log Rotation

Docker log rotation is configured at two levels:

**Global default** (`daemon.json` installed to `/etc/docker/daemon.json`):
- Driver: `json-file`, max-size: `10m`, max-file: `3` (30MB per container)

**Per-service overrides** (in compose files):

| Service | max-size | max-file | Reason |
|---------|----------|----------|--------|
| vpn | 20m | 5 | VPN reconnections and network events |
| transmission | 20m | 3 | Transfer activity logging |
| plex | 20m | 3 | Media scanning and transcoding |
| db (mariadb) | 10m | 5 | Query logs can spike; longer retention |
| wordpress | 5m | 3 | Relatively quiet |
| redis | 5m | 3 | Low-volume object cache |
| cli | 1m | 2 | Only runs occasionally |
| iditarod | 5m | 3 | CI runner — logs mostly during builds |
| radarr/sonarr/lidarr | 5m | 3 | Moderate media management logging |
| soulseek | 5m | 3 | Moderate logging |
| jackett | 5m | 3 | Moderate logging |
| mushr (caddy) | 5m | 3 | Reverse proxy access logging |
| mushr-dns | 5m | 3 | DNS query logging |
| mushr-tunnel | 5m | 3 | Cloudflare Tunnel connection logging |
| snapserver | 5m | 3 | Audio distribution logging |
| shairport-sync | 5m | 3 | AirPlay receiver logging |
| librespot | 5m | 3 | Spotify Connect logging |
| snapclient | 5m | 3 | Audio client logging |
| pulsr | 10m | 3 | Fediverse instance (GoToSocial) |
| pulsr-phanpy | 5m | 3 | Phanpy web client (static files) |
| hblake | 5m | 3 | Static personal website (nginx) |

## Security Model

- **SSH**: Only `hsimah` can SSH in (`AllowUsers hsimah` in sshd_config)
- **SSH passwords**: Disabled on Pis (`SSH_DISABLE_PASSWORD=true`), enabled on space-needle
- **Admin escalation**: `loft-ctl` auto-elevates to `adminhabl` via `su` for docker commands; `adminhabl` alias also available for manual escalation
- **Sudo**: `adminhabl` has full sudo via `/etc/sudoers.d/adminhabl`
- **Containers**: All run as `littledog` (UID/GID 1003), a nologin service account
- **External access**: Pulsr and Hblake are exposed externally via Cloudflare Tunnel (outbound-only, no open ports). All other services remain LAN-only

## Quick Start

### Fresh host setup

```bash
# Clone the repo
sudo git clone <repo-url> /srv/the-loft
cd /srv/the-loft

# Copy .env.example files and fill in secrets for this host's services
# (check hosts/<hostname>/host.conf for the SERVICES list)
cp services/iditarod/.env.example services/iditarod/.env
cp services/howlr/.env.example services/howlr/.env
# On space-needle also:
cp services/plex/.env.example services/plex/.env
cp services/media/.env.example services/media/.env
cp services/pupyrus/.env.example services/pupyrus/.env
cp services/mushr/.env.example services/mushr/.env
cp services/pulsr/.env.example services/pulsr/.env

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
loft-ctl start plex media
loft-ctl stop media

# Full rebuild (down + pull images + up — fresh mounts)
loft-ctl rebuild --all
loft-ctl rebuild plex

# Run health checks (defaults to all services)
loft-ctl health
loft-ctl health plex media

# Update: git pull + rebuild + health check
loft-ctl update --all
loft-ctl update plex media

# Update from a specific branch
loft-ctl update --branch feature/ssl --all

# Rebuild without pulling git changes
loft-ctl update --no-pull plex
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

# Post a status update
pulsr-ctl post --message "Server is alive at $(date)"
```

Accounts are automatically confirmed (no email verification on self-hosted instances).

API tokens are obtained via the full OAuth flow (app creation → sign-in → authorize → token exchange) and do not expire unless revoked. Store the token as `GTS_TOKEN` in `services/pulsr/.env`.

After each `rebuild` or `update`, the script verifies:
1. **Container check** — all containers in the compose file are "running" (retries for up to 30s)
2. **Web UI check** — HTTP endpoints respond based on the host's `HEALTH_URLS` and `HEALTH_URLS_WARN` config

### Adding a new host

1. Create `hosts/<hostname>/host.conf` with the host's config
2. Optionally create override files in `hosts/<hostname>/overrides/<service>/`
3. Clone the repo on the new host to `/srv/the-loft`
4. Copy and fill in `.env` files for the host's services
5. Run `sudo bash setup.sh`


## Raspberry Pi Fleet

Two Raspberry Pi 3 B+ devices (`viking` and `fjord`) in The Loft run Docker with iditarod (GitHub Actions runner) and howlr (Snapcast client), using the same unified `setup.sh` and user/group model as space-needle.

### Pi Setup

Pis use the same `setup.sh` as space-needle. The script auto-detects the hostname and sources `hosts/$(hostname)/host.conf`.

```bash
# Clone repo on the Pi
sudo git clone <repo-url> /srv/the-loft
cd /srv/the-loft

# Configure services
sudo cp services/iditarod/.env.example services/iditarod/.env
sudo cp services/howlr/.env.example services/howlr/.env
# Edit .env files — set COMPOSE_PROFILES=client, SNAPSERVER_HOST, SOUND_DEVICE, HOST_ID for howlr
sudo nano services/iditarod/.env
sudo nano services/howlr/.env

# Run setup
sudo bash setup.sh
```

See `plans/raspberry-pi.md` for the full provisioning guide.

## Mushr — Reverse Proxy & LAN DNS

Mushr provides subdomain-based access to all web services on space-needle via two domain systems:

### HTTPS — `*.loft.hsimah.com` (recommended)

Real Let's Encrypt certificates via Cloudflare DNS-01 challenge. No open ports or port forwarding required.

| URL | Service |
|-----|---------|
| `https://radarr.loft.hsimah.com` | Radarr |
| `https://sonarr.loft.hsimah.com` | Sonarr |
| `https://lidarr.loft.hsimah.com` | Lidarr |
| `https://jackett.loft.hsimah.com` | Jackett |
| `https://plex.loft.hsimah.com` | Plex |
| `https://pupyrus.loft.hsimah.com` | WordPress |
| `https://pulsr.hsimah.com` | Phanpy web client (default) / GoToSocial API |
| `https://transmission.loft.hsimah.com` | Transmission |
| `https://soulseek.loft.hsimah.com` | Soulseek |
| `https://snapweb.loft.hsimah.com` | Snapweb |
| `https://hbla.ke` | Hblake (static personal site) |
| `https://loft.hsimah.com` | WordPress (default) |

### HTTP — `*.space-needle` (LAN fallback)

HTTP-only, no TLS. Kept for backward compatibility.

| URL | Service |
|-----|---------|
| `http://radarr.space-needle` | Radarr |
| `http://sonarr.space-needle` | Sonarr |
| `http://lidarr.space-needle` | Lidarr |
| `http://jackett.space-needle` | Jackett |
| `http://plex.space-needle` | Plex |
| `http://pupyrus.space-needle` | WordPress |
| `https://pulsr.space-needle` | Pulsr (self-signed TLS via `tls internal`) |
| `http://transmission.space-needle` | Transmission |
| `http://soulseek.space-needle` | Soulseek |
| `http://snapweb.space-needle` | Snapweb |
| `http://hblake.space-needle` | Hblake |
| `http://space-needle` | WordPress (default) |

Direct port access (e.g. `space-needle:7878`) continues to work for all services.

### DNS Setup

Before deploying, edit `services/mushr/dnsmasq.conf` and replace the `listen-address` and `address` entries with space-needle's actual LAN IP.

To use the subdomain URLs, point LAN clients' DNS at space-needle's IP:
- **Router DHCP** (recommended): Set the primary DNS server to space-needle's LAN IP in your router's DHCP settings. All devices on the network will automatically resolve `*.space-needle`, `*.loft.hsimah.com`, `pulsr.hsimah.com`, and `hbla.ke`.
- **Per-device**: Manually set DNS to space-needle's LAN IP in each device's network settings.

### Cloudflare Setup (one-time)

To enable HTTPS with real certificates:

1. **Add your domains to Cloudflare**: Sign up at [cloudflare.com](https://dash.cloudflare.com), add `hsimah.com` and `hbla.ke`, and update each domain registrar's nameservers to the ones Cloudflare provides. No A records needed — DNS resolution is handled locally by dnsmasq.
2. **Create an API token**: Go to [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens), create a token with permissions **Zone > Zone > Read** and **Zone > DNS > Edit**, scoped to all zones (or both `hsimah.com` and `hbla.ke`).
3. **Set the token in `.env`**: Copy `services/mushr/.env.example` to `.env` and fill in `CLOUDFLARE_API_TOKEN`.
4. **Rebuild mushr**: Caddy will automatically obtain and renew certificates via the DNS-01 challenge.

### Cloudflare Tunnel (external access)

To access Pulsr and Hblake from outside the LAN:

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels → Create
2. Name: `loft-pulsr`, connector: **Cloudflared**
3. Copy the tunnel token
4. Add public hostname: `pulsr.hsimah.com` → HTTPS → `mushr:443`, set **Origin Server Name** to `pulsr.hsimah.com`
5. Add public hostname: `hbla.ke` → HTTPS → `mushr:443`, set **Origin Server Name** to `hbla.ke`
6. Add `TUNNEL_TOKEN=<token>` to `services/mushr/.env`
7. `loft-ctl rebuild mushr`

Traffic flow: Internet → Cloudflare Edge → `cloudflared` tunnel → `https://mushr:443` → Caddy → target service. LAN clients bypass the tunnel entirely (dnsmasq resolves domains to the LAN IP).

## Environment Files

Each service that needs secrets has a `.env.example` template. Copy it to `.env` and fill in real values. The `.env` files are gitignored.

| Service | Required Variables |
|---------|--------------------|
| Plex | `PLEX_CLAIM`, `PUID`, `PGID`, `TZ` |
| Media | `NORDVPN_TOKEN`, `PUID`, `PGID`, `TZ` |
| Pupyrus | `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `GRAPHQL_JWT_AUTH_SECRET_KEY` |
| Iditarod | `GITHUB_ORG`, `GITHUB_ACCESS_TOKEN`, `RUNNER_NAME`, `RUNNER_LABELS`, `DOCKER_GID` |
| Howlr (server) | `COMPOSE_PROFILES=server`, `LIBRESPOT_NAME` |
| Howlr (client) | `COMPOSE_PROFILES=client`, `SNAPSERVER_HOST`, `SOUND_DEVICE`, `HOST_ID` |
| Mushr | `LOFT_DOMAIN`, `CLOUDFLARE_API_TOKEN`, `TUNNEL_TOKEN` (edit `dnsmasq.conf` with LAN IP before deploying) |
| Pulsr | `GTS_HOST`, `GTS_PROTOCOL`, `GTS_TOKEN` (for `pulsr-ctl post`), `TZ` |

## CI

A GitHub Actions workflow validates on every push:
- Creates shared Docker networks (`loft-proxy`) needed by external network references
- All base `docker-compose.yml` files pass `docker compose config --quiet`
- Howlr compose validated with both `COMPOSE_PROFILES=server` and `COMPOSE_PROFILES=client`
- All compose + override combinations validate
- All shell scripts pass `bash -n` syntax check
- All `host.conf` files pass `bash -n` syntax check
