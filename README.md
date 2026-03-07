# space-needle

Home server running media services, download clients, and WordPress in Docker.

## Architecture

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
| Pupyrus | `wordpress` + `mariadb` | 80 | `/opt/pupyrus/html`, `/opt/pupyrus/db` | WordPress site |
| Iditarod | `actions/actions-runner` | — | `/opt/iditarod` | Self-hosted GitHub Actions runner |

Transmission and Soulseek route through a shared NordVPN (NordLynx) container (`media-vpn`). Radarr, Sonarr, and Lidarr use host networking. Jackett uses standard port mapping. All six are managed together in `media/docker-compose.yml`.

### Users & Groups

| User | UID | Primary Group | Shell | Additional Groups | Role |
|------|-----|---------------|-------|-------------------|------|
| `littledog` | 1003 | `pack-member` (1003) | `/usr/sbin/nologin` | `docker`, `render`, `video` | Service account for all containers |
| `adminhabl` | auto | `adminhabl` | `/bin/bash` | `sudo`, `docker`, `pack-member` | Admin (passworded, no SSH) |
| `hsimah` | auto | `hsimah` | `/bin/bash` | `pack-member` | SSH user, manages repo |

### Storage Layout

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
```

All `/opt` config dirs are owned `littledog:pack-member` (755).
All `/mammoth` media dirs are owned `littledog:pack-member` (775).

## Security Model

- **SSH**: Only `hsimah` can SSH in (`AllowUsers hsimah` in sshd_config)
- **Admin escalation**: `hsimah` runs `admin` alias (defined in `~/.admin_alias`) which does `su - adminhabl`
- **Sudo**: `adminhabl` has full sudo via `/etc/sudoers.d/adminhabl`
- **Containers**: All run as `littledog` (UID/GID 1003), a nologin service account

## Quick Start

### Fresh setup

```bash
# Clone the repo
git clone <repo-url> /srv/space-needle
cd /srv/space-needle

# Copy .env.example files and fill in secrets
cp plex/.env.example plex/.env
cp media/.env.example media/.env
cp pupyrus/.env.example pupyrus/.env

# Edit each .env file with real values
# Then run setup as root:
sudo bash setup.sh
```

### Deploying changes

Edit compose files on your laptop, push to GitHub, then SSH to the server:

```bash
# Just pull latest config (no restart)
./deploy.sh

# Pull and restart a specific service group
./deploy.sh media     # Transmission, Soulseek, Radarr, Sonarr, Lidarr, Jackett
./deploy.sh plex
./deploy.sh pupyrus
./deploy.sh iditarod
```

The script uses `git pull --ff-only` so it fails cleanly if the local branch has diverged.

A CI workflow validates all `docker-compose.yml` files on every push.

## Environment Files

Each service that needs secrets has a `.env.example` template. Copy it to `.env` and fill in real values. The `.env` files are gitignored.

| Service | Required Variables |
|---------|--------------------|
| Plex | `PLEX_CLAIM` (one-time claim token), `PUID`, `PGID`, `TZ` |
| Media | `NORDVPN_TOKEN` (NordVPN token for shared VPN), `PUID`, `PGID`, `TZ` |
| Pupyrus | `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `WORDPRESS_ADMIN_PASSWORD` |
| Iditarod | `GITHUB_OWNER`, `GITHUB_REPO`, `GITHUB_ACCESS_TOKEN`, `RUNNER_NAME`, `RUNNER_LABELS` |

