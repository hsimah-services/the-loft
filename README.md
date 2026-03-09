# the-loft

Fleet configuration for The Loft — a mono-repo managing all hosts (space-needle, viking, fjord) with shared service definitions, per-host configuration, and a unified setup/control-plane.

## Architecture

### Fleet

| Host | Role | Services |
|------|------|----------|
| `space-needle` | Primary server | plex, media, pupyrus, iditarod, howlr (server) |
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
| Pupyrus | `wordpress` + `mariadb` + `redis` | 80 | `/opt/pupyrus/html`, `/opt/pupyrus/db` | WordPress site (WPGraphQL + Redis object cache) |
| Iditarod | `actions/actions-runner` (custom build) | — | `.env` per host | Self-hosted GitHub Actions runner |
| Howlr snapserver | `ivdata/snapserver` | 1704, 1705, 1780 (host) | `/opt/howlr`, `config/snapserver.conf`, `snapserver-data` volume | Snapcast sync engine + snapweb UI (speaker groups persist via volume) |
| Howlr shairport-sync | `mikebrady/shairport-sync` | host network | `config/shairport-sync.conf` | AirPlay receiver (feeds snapserver) |
| Howlr librespot | `giof71/librespot` | host network | — | Spotify Connect receiver (feeds snapserver) |
| Howlr snapclient | `ivdata/snapclient` | host network | `.env` per host | Snapcast client (receives stream, outputs to speakers) |

Transmission and Soulseek route through a shared NordVPN (NordLynx) container (`media-vpn`). Radarr, Sonarr, and Lidarr use host networking. All six are managed together in `services/media/docker-compose.yml`.

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
│   │   └── .env.example
│   ├── pupyrus/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   ├── iditarod/
│   │   ├── docker-compose.yml
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh
│   │   └── .env.example
│   └── howlr/
│       ├── docker-compose.yml
│       ├── config/
│       │   ├── snapserver.conf
│       │   └── shairport-sync.conf
│       └── .env.example
├── control-plane/
│   ├── common.sh
│   ├── deploy.sh
│   ├── health.sh
│   ├── start.sh
│   ├── stop.sh
│   └── update.sh
├── plans/
│   ├── howlr.md
│   └── raspberry-pi.md
├── setup.sh
├── loft-ctl
├── bashrc
├── nanorc
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
| snapserver | 5m | 3 | Audio distribution logging |
| shairport-sync | 5m | 3 | AirPlay receiver logging |
| librespot | 5m | 3 | Spotify Connect logging |
| snapclient | 5m | 3 | Audio client logging |

## Security Model

- **SSH**: Only `hsimah` can SSH in (`AllowUsers hsimah` in sshd_config)
- **SSH passwords**: Disabled on Pis (`SSH_DISABLE_PASSWORD=true`), enabled on space-needle
- **Admin escalation**: `hsimah` runs `admin` alias which does `su - adminhabl`
- **Sudo**: `adminhabl` has full sudo via `/etc/sudoers.d/adminhabl`
- **Containers**: All run as `littledog` (UID/GID 1003), a nologin service account

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

# Edit each .env file with real values
# Then run setup as root:
sudo bash setup.sh
```

### Managing services

```bash
# Show usage (dynamically shows this host's services)
loft-ctl

# Pull latest config from git
loft-ctl --update

# Deploy (pull images + restart + health check)
loft-ctl --deploy --all
loft-ctl --deploy plex

# Start / stop containers
loft-ctl --start --all
loft-ctl --stop media

# Run health checks without deploying
loft-ctl --health          # all services
loft-ctl --health plex     # single service
```

After each deploy, the script verifies:
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

## Environment Files

Each service that needs secrets has a `.env.example` template. Copy it to `.env` and fill in real values. The `.env` files are gitignored.

| Service | Required Variables |
|---------|--------------------|
| Plex | `PLEX_CLAIM`, `PUID`, `PGID`, `TZ` |
| Media | `NORDVPN_TOKEN`, `PUID`, `PGID`, `TZ` |
| Pupyrus | `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `GRAPHQL_JWT_AUTH_SECRET_KEY` |
| Iditarod | `GITHUB_OWNER`, `GITHUB_REPO`, `GITHUB_ACCESS_TOKEN`, `RUNNER_NAME`, `RUNNER_LABELS`, `DOCKER_GID` |
| Howlr (server) | `COMPOSE_PROFILES=server`, `LIBRESPOT_NAME` |
| Howlr (client) | `COMPOSE_PROFILES=client`, `SNAPSERVER_HOST`, `SOUND_DEVICE`, `HOST_ID` |

## CI

A GitHub Actions workflow validates on every push:
- All base `docker-compose.yml` files pass `docker compose config --quiet`
- Howlr compose validated with both `COMPOSE_PROFILES=server` and `COMPOSE_PROFILES=client`
- All compose + override combinations validate
- All shell scripts pass `bash -n` syntax check
- All `host.conf` files pass `bash -n` syntax check
