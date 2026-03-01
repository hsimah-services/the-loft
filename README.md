# space-needle

Home server running media services, download clients, and WordPress in Docker.

## Architecture

### Services

| Service | Image | Ports | Config | Purpose |
|---------|-------|-------|--------|---------|
| Plex | `plexinc/pms-docker` | host network | `/opt/plex/config` | Media server |
| Radarr | `linuxserver/radarr` | 7878 (host) | `/opt/radarr` | Movie management |
| Sonarr | `linuxserver/sonarr` | 8989 (host) | `/opt/sonarr` | TV management |
| Lidarr | `linuxserver/lidarr` | 8686 (host) | `/opt/lidarr` | Music management |
| Jackett | `linuxserver/jackett` | 9117 | `/opt/jackett` | Indexer proxy |
| Transmission | `linuxserver/transmission` | 9091 (via VPN) | `/opt/transmission` | Torrent client |
| Soulseek | `realies/soulseek` | 6080 (via VPN) | `/opt/soulseek` | P2P music |
| Pupyrus | `wordpress` + `mariadb` | 80 | `/opt/pupyrus` | WordPress site |

Transmission and Soulseek route through NordVPN (NordLynx) containers.

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
  /transmission/torrents          Transmission watch directory

/opt
  /plex/config                    Plex configuration
  /radarr                         Radarr configuration
  /sonarr                         Sonarr configuration
  /lidarr                         Lidarr configuration
  /jackett                        Jackett configuration
  /transmission                   Transmission configuration
  /soulseek                       Soulseek configuration
  /config-tracking                Git-tracked config snapshots
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
git clone <repo-url> /home/hsimah/projects/space-needle
cd /home/hsimah/projects/space-needle

# Copy .env.example files and fill in secrets
cp plex/.env.example plex/.env
cp transmission/.env.example transmission/.env
cp soulseek/.env.example soulseek/.env
cp pupyrus/.env.example pupyrus/.env

# Edit each .env file with real values
# Then run setup as root:
sudo bash setup.sh
```

### Updating a service

```bash
cd /home/hsimah/projects/space-needle/<service>
docker compose pull
docker compose up -d
```

## Environment Files

Each service that needs secrets has a `.env.example` template. Copy it to `.env` and fill in real values. The `.env` files are gitignored.

| Service | Required Variables |
|---------|--------------------|
| Plex | `PLEX_CLAIM` (one-time claim token) |
| Transmission | `TRANSMISSION_VPN_TOKEN` (NordVPN token) |
| Soulseek | `SOULSEEK_TOKEN` (NordVPN token) |
| Pupyrus | `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `WORDPRESS_ADMIN_PASSWORD` |

## Config Tracking

A systemd timer runs every 6 hours, rsyncing small config files from `/opt/<service>/` into `/opt/config-tracking/<service>/` and committing changes. Databases, caches, logs, and files over 1MB are excluded.

### Manual trigger

```bash
sudo systemctl start config-tracker.service
```

### Viewing history

```bash
cd /opt/config-tracking
git log --oneline
git diff HEAD~1
```
