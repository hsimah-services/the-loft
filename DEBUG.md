# Fleet Debugging Guide

Debugging guide for Docker services on The Loft fleet. All commands assume you're SSH'd into the target host. Commands that touch Docker require elevation to `adminhabl` (either manually via the `adminhabl` alias, or automatically via `loft-ctl`).

## 1. Quick Reference

### Top 10 Commands

| # | Command | What it does |
|---|---------|-------------|
| 1 | `loft-ctl health` | Run all health checks (containers + URLs) |
| 2 | `sudo docker ps -a` | List all containers with status |
| 3 | `sudo docker logs <container> --tail 50` | Last 50 lines of a container's logs |
| 4 | `sudo docker logs <container> -f` | Follow logs in real time |
| 5 | `sudo docker inspect <container> --format '{{.State.ExitCode}}'` | Get exit code |
| 6 | `sudo docker inspect <container> --format '{{json .State.Health}}'` | Docker healthcheck details |
| 7 | `sudo docker exec -it <container> sh` | Shell into a running container |
| 8 | `loft-ctl rebuild <service>` | Full teardown + pull + restart |
| 9 | `df -h` | Check disk space |
| 10 | `sudo docker system df` | Docker disk usage (images, containers, volumes) |

### Container Name Reference

| Service | Containers |
|---------|-----------|
| **mushr** | `mushr`, `mushr-tunnel`, `mushr-dns` |
| **pawpcorn** | `pawpcorn` |
| **stellarr** | `stellarr-vpn`, `transmission`, `slskd`, `radarr`, `sonarr`, `lidarr`, `bazarr`, `jackett` |
| **pupyrus** | `pupyrus-db`, `pupyrus-redis`, `pupyrus`, `pupyrus-cli` (cli profile only) |
| **howlr** | `howlr` (Music Assistant, `server` profile), `howlr-snapclient` (`client` profile) |
| **houstn** | `beszel`, `uptime`, `homepage` (`hub` profile), `glances` (`metrics` profile) |
| **snoot** | `snoot` |
| **pawst** | `pawst` |

Music Assistant embeds snapserver, shairport-sync and librespot in the single
`howlr` container — there are no separate `howlr-snapserver` /
`howlr-shairport-sync` / `howlr-librespot` containers.

### Health Check URLs (space-needle)

Authoritative source is `HEALTH_URLS` in `hosts/space-needle/host.conf` — this
table is a summary. Each label is checked across up to three tiers
(`local` / `lan` / `ssl`).

| Label | Representative URL | Required? |
|-------|--------------------|-----------|
| pawpcorn | `http://localhost:32400/web` | Yes |
| radarr | `http://radarr.space-needle` | Yes (via Caddy) |
| sonarr | `http://sonarr.space-needle` | Yes (via Caddy) |
| lidarr | `http://lidarr.space-needle` | Yes (via Caddy) |
| bazarr | `http://bazarr.space-needle` | Yes (via Caddy) |
| jackett | `http://jackett.space-needle` | Yes (via Caddy) |
| pupyrus | `http://pupyrus.space-needle` | Yes (via Caddy) |
| mushr | `http://localhost:8880/config/` | Yes (host-only admin API) |
| howlr | `http://localhost:8095` | Yes — but see caveat below |
| snapweb | `http://localhost:1780` | Yes |
| pawst | `http://pawst.space-needle` | Yes (via Caddy) |
| hsimah | `http://hsimah.space-needle` | Yes (via Caddy) |
| beszel | `http://beszel.space-needle` | Yes (via Caddy) |
| uptime | `http://uptime.space-needle` | Yes (via Caddy) |
| homepage | `http://homepage.space-needle` | Yes (via Caddy) |
| glances | `http://localhost:61208/api/4/status` | Yes (host-only) |
| transmission | `http://localhost:9091` | Warn only (VPN) |
| slskd | `http://localhost:5030` | Warn only (VPN) |

> **These checks only assert a non-`000` HTTP response.** They prove a port is
> answering, not that the service works. Two known false-greens:
>
> - **howlr** — Music Assistant has required authentication since 2.7.0, and its
>   login page returns `200`. `loft-ctl health howlr` passes on a completely
>   unusable MA. Verify by actually playing audio to a group.
> - **transmission / slskd** — these answer on `localhost` whether or not they
>   are inside the VPN namespace. A tunnel that has dropped looks perfectly
>   healthy here *and* in Uptime Kuma and Homepage. Verify the egress IP
>   directly:
>
>   ```bash
>   echo "via VPN: $(sudo docker exec transmission curl -s https://ipinfo.io/ip)"
>   echo "home IP: $(curl -s https://ipinfo.io/ip)"
>   ```
>
>   Those must differ, and the first should geolocate to the configured
>   `CONNECT` country (currently NETHERLANDS).

## 2. Container State

### List all containers

```bash
# Simple list
sudo docker ps -a

# Formatted output — name, status, ports
sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Just names and states (good for scripting)
sudo docker ps -a --format '{{.Names}}\t{{.State}}'
```

### Inspect container details

```bash
# Exit code (0=clean, 1=app error, 137=OOM/SIGKILL, 139=segfault, 143=SIGTERM)
sudo docker inspect <container> --format '{{.State.ExitCode}}'

# Full state (running, paused, restarting, exited, dead)
sudo docker inspect <container> --format '{{.State.Status}}'

# Restart count (high count = crash loop)
sudo docker inspect <container> --format '{{.RestartCount}}'

# When it started / stopped
sudo docker inspect <container> --format 'Started: {{.State.StartedAt}} Finished: {{.State.FinishedAt}}'

# OOM killed?
sudo docker inspect <container> --format '{{.State.OOMKilled}}'
```

### Exit code meanings

| Code | Signal | Meaning |
|------|--------|---------|
| 0 | — | Clean shutdown |
| 1 | — | Application error (check logs) |
| 2 | — | Shell builtin misuse / bad arguments |
| 126 | — | Command not executable (permissions) |
| 127 | — | Command not found (missing binary in image) |
| 137 | SIGKILL (9) | OOM kill or `docker kill` |
| 139 | SIGSEGV (11) | Segmentation fault |
| 143 | SIGTERM (15) | Graceful stop (`docker stop`) |

## 3. Logs

### Basic log commands

```bash
# Last N lines
sudo docker logs <container> --tail 100

# Follow in real time
sudo docker logs <container> -f

# With timestamps
sudo docker logs <container> --tail 50 -t

# Since a specific time
sudo docker logs <container> --since "2025-01-15T10:00:00"
sudo docker logs <container> --since "1h"
sudo docker logs <container> --since "30m"

# Combine: last hour, with timestamps, follow
sudo docker logs <container> --since "1h" -t -f
```

### Where logs live on disk

Docker JSON log files (controlled by `daemon.json` and per-service logging config):

```bash
# Find the log file for a container
sudo docker inspect <container> --format '{{.LogPath}}'

# Read raw JSON log (useful when container won't start)
sudo cat $(sudo docker inspect <container> --format '{{.LogPath}}')
```

### System logs

```bash
# Cron jobs (transmission cleanup, deploy pullers)
sudo grep -i loft /var/log/syslog | tail -20

# Deploy puller logs
sudo cat /var/log/loft/deploy.log

# Docker daemon logs
sudo journalctl -u docker --since "1h"
```

## 4. Health Checks

### Using loft-ctl

```bash
# All services on this host (default)
loft-ctl health

# Specific services
loft-ctl health pawpcorn stellarr
loft-ctl health pupyrus
```

`loft-ctl health` runs two checks per service:
1. **Container check** — all containers in the compose file are in `running` state (polls every 5s, up to 30s timeout)
2. **Web UI check** — HTTP endpoints from `HEALTH_URLS` in `host.conf` respond (5s curl timeout)

### Manual URL checks

```bash
# Quick check — just the HTTP code
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 <url>

# Examples
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8081      # pupyrus
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:32400/web # pawpcorn
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8880/config/ # mushr (Caddy)

# VPN-dependent (may return 000 if VPN is down — that's expected)
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:9091  # transmission
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:5030  # slskd
```

### Docker healthcheck inspection

```bash
# Full health status (includes last N check results)
sudo docker inspect <container> --format '{{json .State.Health}}' | python3 -m json.tool

# Just the overall status (healthy / unhealthy / starting)
sudo docker inspect <container> --format '{{.State.Health.Status}}'

# Containers with Docker-level healthchecks:
#   pupyrus-db    — healthcheck.sh --connect --innodb_initialized
#   pupyrus-redis — redis-cli ping
#   mushr         — wget -q -O /dev/null http://localhost:8880/config/
```

## 5. Database Debugging (MariaDB / Redis)

### MariaDB (pupyrus-db)

```bash
# Connect to MySQL shell
sudo docker exec -it pupyrus-db mariadb -u root -p
# Password: value of MYSQL_ROOT_PASSWORD from services/pupyrus/.env

# Or use the WordPress user
sudo docker exec -it pupyrus-db mariadb -u wordpress -p wordpress
```

Common SQL commands:

```sql
-- Check databases exist
SHOW DATABASES;

-- Check WordPress tables
USE wordpress;
SHOW TABLES;

-- Active connections
SHOW PROCESSLIST;

-- InnoDB status (look for deadlocks, long-running transactions)
SHOW ENGINE INNODB STATUS\G

-- Table sizes
SELECT table_name, ROUND(data_length/1024/1024, 2) AS 'Size (MB)'
FROM information_schema.tables
WHERE table_schema = 'wordpress'
ORDER BY data_length DESC;
```

Check MariaDB healthcheck from outside:

```bash
# The built-in healthcheck script
sudo docker exec pupyrus-db healthcheck.sh --connect --innodb_initialized

# Test connectivity
sudo docker exec pupyrus-db mariadb-admin ping -u root -p
```

### Redis (pupyrus-redis)

```bash
# Ping
sudo docker exec pupyrus-redis redis-cli ping
# Expected: PONG

# Memory usage
sudo docker exec pupyrus-redis redis-cli info memory | grep used_memory_human

# Number of keys
sudo docker exec pupyrus-redis redis-cli dbsize

# List all keys (careful in production — blocking on large datasets)
sudo docker exec pupyrus-redis redis-cli keys '*' | head -20

# Flush cache (safe — WordPress will rebuild it)
sudo docker exec pupyrus-redis redis-cli flushall
```

### WordPress CLI (pupyrus-cli)

The CLI container runs under the `cli` profile. Use `docker compose` directly:

```bash
# Run a wp-cli command (starts the cli container temporarily)
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp core version

# Check WordPress health
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp core verify-checksums

# List plugins
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp plugin list

# Check database connectivity from WordPress
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp db check
```

## 6. Network Debugging

### Docker networks

```bash
# List all networks
sudo docker network ls

# Inspect loft-proxy network (shows connected containers)
sudo docker network inspect loft-proxy --format '{{range .Containers}}{{.Name}} {{end}}'

# Full network details
sudo docker network inspect loft-proxy
```

Expected members of `loft-proxy` (space-needle): `mushr`, `mushr-tunnel`,
`pupyrus`, `pawst`, `beszel`, `uptime`, `homepage`, `radarr`, `sonarr`,
`lidarr`, `bazarr`, `jackett`.

Not on `loft-proxy`: `howlr` and `glances` (both `network_mode: host`),
`pawpcorn` (host), and `transmission` / `slskd` (both
`network_mode: service:vpn`).

### Container-to-container connectivity

```bash
# Test from mushr (Caddy) to pupyrus
sudo docker exec mushr wget -q -O /dev/null http://pupyrus:80 && echo "OK" || echo "FAIL"

# Test from mushr to pawst
sudo docker exec mushr wget -q -O /dev/null http://pawst:80 && echo "OK" || echo "FAIL"
```

### DNS resolution (mushr-dns / dnsmasq)

```bash
# Test wildcard DNS resolution (from the host)
dig @localhost radarr.space-needle +short
dig @localhost sonarr.loft.hsimah.com +short
dig @localhost hbla.ke +short
dig @localhost hsimah.com +short

# All should return the LAN IP configured in dnsmasq.conf

# Check dnsmasq logs
sudo docker logs mushr-dns --tail 20
```

### VPN status (stellarr-vpn)

```bash
# Check if VPN is connected
sudo docker exec stellarr-vpn curl -s https://api.nordvpn.com/vpn/check/full | python3 -m json.tool

# Check VPN container logs for connection issues
sudo docker logs stellarr-vpn --tail 30

# Test connectivity through VPN
sudo docker exec stellarr-vpn curl -s https://ifconfig.me
```

### Port listening

```bash
# What's listening on the host
sudo ss -tlnp

# Key ports to check:
#   53    — mushr-dns (dnsmasq)
#   80    — mushr (Caddy HTTP)
#   443   — mushr (Caddy HTTPS)
#   5030  — slskd (via stellarr-vpn)
#   1704  — howlr (Snapcast stream, embedded in Music Assistant)
#   1705  — howlr (Snapcast control / JSON-RPC)
#   1780  — howlr (Snapweb UI + JSON-RPC over HTTP)
#   8095  — howlr (Music Assistant web UI + API)
#   7878  — radarr
#   8081  — pupyrus (WordPress)
#   8085  — pawst
#   8686  — lidarr
#   8880  — mushr (Caddy admin API)
#   8989  — sonarr
#   9091  — transmission (via stellarr-vpn)
#   9117  — jackett
#   32400 — pawpcorn
```

### Cloudflare Tunnel

```bash
# Tunnel logs
sudo docker logs mushr-tunnel --tail 30

# Tunnel status (should show "Registered" connections)
sudo docker logs mushr-tunnel 2>&1 | grep -i "registered\|error\|failed"

# Test external access
curl -sk -o /dev/null -w '%{http_code}' https://hbla.ke
curl -sk -o /dev/null -w '%{http_code}' https://hsimah.com
```

## 7. Storage / Disk

### Disk space

```bash
# Overall disk usage
df -h

# Key mounts on space-needle:
#   /          — root filesystem
#   /mammoth   — XFS data volume (/dev/sda1)

# Docker-specific disk usage
sudo docker system df
sudo docker system df -v  # verbose — per-image, per-container, per-volume
```

### Find large directories

```bash
# Largest directories under /opt
sudo du -sh /opt/*/  | sort -rh | head -10

# Largest directories under /mammoth
sudo du -sh /mammoth/*/  | sort -rh | head -10
sudo du -sh /mammoth/library/*/  | sort -rh

# Largest directories under /mammoth/downloads
sudo du -sh /mammoth/downloads/*/  | sort -rh
```

### Volume inspection

```bash
# List Docker volumes
sudo docker volume ls

# Inspect a specific volume
# The only named volumes in the fleet are mushr's:
sudo docker volume inspect mushr_caddy-data
sudo docker volume inspect mushr_caddy-config
```

### Permissions check

All `/opt` config dirs and `/mammoth` media dirs should be owned by `littledog:pack-member`:

```bash
# Check ownership
ls -la /opt/
ls -la /mammoth/library/

# Expected:
#   /opt/* dirs     — littledog:pack-member, 755
#   /mammoth/* dirs — littledog:pack-member, 775

# Fix if needed
sudo chown -R littledog:pack-member /opt/<dir>
sudo chmod 755 /opt/<dir>
# or for media:
sudo chmod 775 /mammoth/<dir>
```

### Docker garbage cleanup

```bash
# Remove stopped containers, unused networks, dangling images
sudo docker system prune

# Also remove unused images (not just dangling)
sudo docker system prune -a

# Remove unused volumes (CAREFUL — check what's unused first)
sudo docker volume ls -f dangling=true
sudo docker volume prune
```

## 8. Caddy / Reverse Proxy (mushr)

### Validate Caddyfile

```bash
# Validate syntax (runs inside the container)
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile

# Reload Caddyfile without restarting
sudo docker exec mushr caddy reload --config /etc/caddy/Caddyfile
```

### Admin API

```bash
# Dump running config (JSON)
curl -s http://localhost:8880/config/ | python3 -m json.tool

# Check specific route
curl -s http://localhost:8880/config/apps/http/ | python3 -m json.tool
```

### TLS certificate inspection

```bash
# Check certificate for a domain
echo | openssl s_client -connect localhost:443 -servername radarr.loft.hsimah.com 2>/dev/null | openssl x509 -noout -dates -subject

# Check all domains
for domain in radarr sonarr lidarr jackett pawpcorn pupyrus transmission soulseek snapweb; do
  echo -n "${domain}.loft.hsimah.com: "
  echo | openssl s_client -connect localhost:443 -servername ${domain}.loft.hsimah.com 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "NO CERT"
done
```

### Route testing

```bash
# Test through Caddy (HTTPS)
curl -sk https://localhost -H 'Host: radarr.loft.hsimah.com' -o /dev/null -w '%{http_code}'

# Test through Caddy (HTTP LAN fallback)
curl -s http://localhost -H 'Host: radarr.space-needle' -o /dev/null -w '%{http_code}'
```

### Nuclear option: reset Caddy TLS state

If TLS handshakes are failing and certificates appear corrupt:

```bash
# Stop mushr
loft-ctl stop mushr

# Remove Caddy data volumes (certificates + ACME state)
sudo docker volume rm mushr_caddy-data mushr_caddy-config

# Restart — Caddy will re-obtain certificates via DNS-01
loft-ctl start mushr
```

## 9. Service Lifecycle

### When to use what

| Situation | Command | Notes |
|-----------|---------|-------|
| Service stopped, need to start | `loft-ctl start <service>` | Just runs `docker compose up -d` |
| Service misbehaving, quick restart | `sudo docker restart <container>` | Restarts single container, preserves volumes |
| Config changed in compose file | `loft-ctl rebuild <service>` | `down` + `pull` + `up` — recreates containers |
| Image tag changed in git | `loft-ctl rebuild <service>` | Pulls the **pinned** tag. Images no longer float on `:latest` — see README "Image pinning". |
| Deploy new code from git | `loft-ctl update <service>` | `git pull` + rebuild + health check |
| Audio not working after config change | `loft-ctl rebuild howlr` | Must do full `down`/`up` to get fresh FIFOs |
| Stale bind mount data | `loft-ctl rebuild <service>` | Fresh mount on new container |
| Container won't start at all | Check logs, then rebuild | `sudo docker logs <container> --tail 50` first |

### Volume safety

**NEVER** use `docker compose down -v` on these services (destroys persistent data):

| Service | Why |
|---------|-----|
| **pupyrus** | Deletes MariaDB database (`/opt/pupyrus/db`) — all WordPress content lost |
| **pawpcorn** | Deletes Plex config (`/opt/pawpcorn/config`) — library metadata, watch history, all settings |
| **mushr** | Deletes TLS certificates (`caddy-data`) — triggers re-issuance (rate limits apply) |
| **howlr** | No named volumes — state lives in the `/opt/howlr` bind mount, which `down -v` does not touch. Back up `/opt/howlr` before upgrades regardless; it holds the MA database and provider credentials. |

`loft-ctl rebuild` uses `docker compose down` (without `-v`) which is safe — it removes containers but preserves volumes and bind mounts.

## 10. Common Problems

### pupyrus-db restart-loops with "Bad magic header in tc log"

**Symptom:** `sudo docker ps -a --filter name=pupyrus-db` shows `Restarting (1)`. Logs show:

```
[ERROR] Bad magic header in tc log
[ERROR] Crash recovery failed. Either correct the problem ... or delete tc log and start server with --tc-heuristic-recover={commit|rollback}
[ERROR] Can't init tc log
[ERROR] Aborting
```

**Cause:** MariaDB's two-phase-commit log (`tc.log`) got corrupted because the
container was SIGKILLed mid-write rather than shut down cleanly.

The root cause was found on 2026-07-27: `pupyrus-db` sets
`stop_grace_period: 60s`, but dockerd's own `shutdown-timeout` defaults to **15
seconds** and silently caps it. On every reboot of space-needle MariaDB was
killed 45 seconds early, mid-flush. `daemon.json` now sets
`"shutdown-timeout": 90`, which clears the longest grace period in the fleet.

If this recurs, check the daemon actually has the setting — it is read at
daemon start, so copying `daemon.json` without restarting Docker leaves the old
value live in the running process:

```bash
sudo cat /etc/docker/daemon.json | grep shutdown-timeout
sudo systemctl show docker -p ExecStart | grep -o 'shutdown-timeout=[0-9]*'
```

**Fix:** WordPress doesn't use XA transactions, so `tc.log` carries no in-flight state worth preserving. Delete it and restart:

```bash
sudo docker stop pupyrus-db
sudo rm /opt/pupyrus/db/tc.log
sudo docker start pupyrus-db
sudo docker logs -f pupyrus-db   # watch for "ready for connections"
```

No `--tc-heuristic-recover` flag is needed for this workload.

### VPN-dependent health checks failing

**Symptom:** `loft-ctl health` shows WARNING for transmission/slskd but everything else is OK.

**Cause:** VPN tunnel (`stellarr-vpn`) is disconnected. Transmission and slskd route through it.

**Fix:**
```bash
sudo docker logs stellarr-vpn --tail 20  # Check for connection errors
sudo docker restart stellarr-vpn         # Restart VPN
# Wait 30s for reconnect, then:
loft-ctl health stellarr
```

### mushr-tunnel won't start

**Symptom:** `mushr-tunnel` stays in "waiting" or restarts repeatedly.

**Cause:** `mushr-tunnel` has `depends_on: mushr: condition: service_healthy`. If the Caddy health check fails, the tunnel never starts.

**Fix:**
```bash
# Check if Caddy is healthy
sudo docker inspect mushr --format '{{.State.Health.Status}}'

# If unhealthy, check Caddy logs
sudo docker logs mushr --tail 30

# Often a Caddyfile syntax error — validate it
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile
```

### Caddy TLS handshake failure (stale volumes)

**Symptom:** HTTPS connections fail with "TLS handshake error" or browsers show certificate warnings for `*.loft.hsimah.com`.

**Cause:** Stale or corrupt certificate data in Caddy's data volume.

**Fix:**
```bash
loft-ctl stop mushr
sudo docker volume rm mushr_caddy-data mushr_caddy-config
loft-ctl start mushr
# Caddy will re-obtain certs via Cloudflare DNS-01 (takes ~30s)
```

### Snapweb crashes on AirPlay stream

**Symptom:** Snapweb browser client loads but audio playback crashes or stutters when playing AirPlay content.

**Cause:** AirPlay 2 uses 48kHz/32-bit format (`sampleformat=48000:32:2`). Snapweb can't handle this format.

**Fix:** Use native snapclient devices (viking, calavera) for AirPlay playback. Spotify Connect works on all clients including snapweb (uses 44100:16:2).

### Howlr no audio after config change (stale FIFOs)

**Symptom:** After changing snapserver or shairport-sync config, audio stops working entirely. No errors in logs.

**Cause:** Predates the current topology, when snapserver, shairport-sync and
librespot ran as separate containers passing audio over named pipes (FIFOs).
Music Assistant now embeds all three in the single `howlr` container, so
cross-container FIFOs no longer exist — but a full `down`/`up` is still the
right remedy for audio that has stopped without logging an error, since it
resets snapserver's stream state.

**Fix:**
```bash
# Must do full down/up, not just recreate
loft-ctl rebuild howlr
```

### Permission denied on bind mounts

**Symptom:** Container logs show "permission denied" errors when trying to read/write data.

**Cause:** Bind-mounted directories not owned by `littledog:pack-member` (UID/GID 1003).

**Fix:**
```bash
# Check current ownership
ls -la /opt/<service>/

# Fix ownership
sudo chown -R littledog:pack-member /opt/<service>/

# Fix permissions (755 for config, 775 for media)
sudo chmod -R 755 /opt/<service>/
```

### OOM kill (exit code 137)

**Symptom:** Container exits with code 137, `OOMKilled` is `true`.

**Cause:** Container exceeded its memory limit or host ran out of memory. Common on Raspberry Pis (1GB RAM).

**Fix:**
```bash
# Confirm OOM
sudo docker inspect <container> --format '{{.State.OOMKilled}}'

# Check host memory
free -h

# Check container memory usage
sudo docker stats --no-stream

# If on a Pi, reduce services or add memory limits in compose
```

### deploy-pull.sh isn't pulling a new release

**Symptom:** A new tag/release exists in the source repo but `/opt/<target>` still contains the old build.

**Checks:**
1. Inspect the puller log: `sudo tail -n 50 /var/log/loft/deploy.log`
2. Check the state file: `sudo cat /var/lib/loft/deploy/<name>.version` (should be the previously deployed tag)
3. Force a run: `sudo /srv/the-loft/control-plane/deploy-pull.sh <name> <owner/repo> <target>`
4. If the run errors on auth, confirm `/etc/loft/deploy.env` is present (private repo) or absent (public repo) as intended, and that the App private key is readable.

**Common causes:**
- The release has no `.tar.gz` asset attached — `deploy-pull.sh` only pulls `.tar.gz` files
- The release was published as a draft — `releases/latest` skips drafts
- GitHub App installation doesn't include the repo with `Contents: Read`

### dnsmasq port 53 conflict with systemd-resolved

**Symptom:** `mushr-dns` container fails to start. Logs show "address already in use" on port 53.

**Cause:** `systemd-resolved` is listening on port 53. Common on fresh Ubuntu installs.

**Fix:**
```bash
# Check what's on port 53
sudo ss -tlnp | grep ':53'

# Disable systemd-resolved stub listener
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved

# Restart dnsmasq
sudo docker restart mushr-dns
```

### MariaDB won't start (pupyrus-db)

**Symptom:** `pupyrus-db` exits immediately or enters a restart loop. WordPress and Redis are unaffected.

**Cause:** Usually one of:
- Corrupt transaction coordinator log (unclean shutdown / host reboot)
- Corrupt InnoDB files (crash during write)
- Disk full (`/opt/pupyrus/db` on root filesystem)
- Permission issues on `/opt/pupyrus/db`
- MariaDB major version upgrade with incompatible data format

**Fix:**
```bash
# 1. Check the logs — MariaDB is verbose about startup failures
sudo docker logs pupyrus-db --tail 50

# 2. Check disk space
df -h /opt

# 3. Check permissions
ls -la /opt/pupyrus/db/

# 4. Check exit code
sudo docker inspect pupyrus-db --format '{{.State.ExitCode}}'

# 5. If "Bad magic header in tc log" / "Crash recovery failed":
#    The tc.log is a small transaction coordinator file — safe to delete.
#    MariaDB will recreate it on startup.
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml down
sudo rm /opt/pupyrus/db/tc.log
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml up -d db
sudo docker logs -f pupyrus-db  # wait for "ready for connections"
# Then bring up the rest:
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml up -d

# 6. If InnoDB corruption, try recovery mode:
#    Add to docker-compose environment:
#      MARIADB_AUTO_UPGRADE: "1"
#    Then rebuild:
loft-ctl rebuild pupyrus

# 7. If data format incompatible after major version upgrade:
#    Run mariadb-upgrade inside the container
sudo docker exec pupyrus-db mariadb-upgrade -u root -p
```

### `docker compose pull` fails with "pull access denied" for mushr-caddy

**Symptom:**

```
mushr Warning   pull access denied for mushr-caddy, repository does not exist
                or may require 'docker login': denied
```

**Cause:** Harmless. `mushr-caddy` is built locally from `Dockerfile.caddy`
(Caddy compiled with the `caddy-dns/cloudflare` plugin via xcaddy) and exists in
no registry. A bare `docker compose pull` tries to fetch every service including
that one.

`loft-ctl` already swallows this — `do_rebuild` runs its pull as
`docker compose pull 2>/dev/null || true` — so it only surfaces when pulling by
hand.

**Fix:** Name only the registry-backed services, or skip buildable ones:

```bash
sudo docker compose -f /srv/the-loft/services/mushr/docker-compose.yml pull mushr-tunnel mushr-dns
# or, on compose versions that support it:
sudo docker compose -f /srv/the-loft/services/mushr/docker-compose.yml pull --ignore-buildable
```

To rebuild the Caddy image itself, use `build` — and **always build before
recreating**, so a build failure doesn't leave the fleet with no ingress:

```bash
sudo docker compose -f /srv/the-loft/services/mushr/docker-compose.yml build
sudo docker images mushr-caddy    # confirm the new tag exists before proceeding
loft-ctl update --no-pull mushr
```

### ghcr.io pulls fail with "denied: denied" on public images

**Symptom:** A pull of a known-public image fails on the daemon:

```
Error response from daemon: Head "https://ghcr.io/v2/music-assistant/server/manifests/2.9.9": denied: denied
```

**Cause:** Stale credentials for `ghcr.io` in root's Docker config — often left
over from the GitHub App token flow used by `deploy-pull.sh` for the private
`hsimah-services` repos. Docker sends the expired token instead of fetching an
anonymous one, and ghcr rejects it. The image itself is fine.

**Confirm** the tag really is public before chasing auth (this needs no
credentials, so a 200 here proves the problem is local):

```bash
TOK=$(curl -s "https://ghcr.io/token?scope=repository:music-assistant/server:pull" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  https://ghcr.io/v2/music-assistant/server/manifests/2.9.9
```

**Fix:**

```bash
sudo cat /root/.docker/config.json | python3 -m json.tool   # see what's cached
sudo docker logout ghcr.io
# retry the pull
```

### Caddy SSL errors after idle (HTTP/3 QUIC timeout)

**Symptom:** After leaving an HTTPS service idle for a few minutes, API calls fail with SSL/protocol errors in the browser console. Recovery requires logging out, clearing browser cache, and waiting 30-60 seconds.

**Cause:** Caddy enables HTTP/3 (QUIC over UDP) by default for all HTTPS listeners. After idle, the QUIC connection's server-side idle timeout expires. When the user returns, the browser tries to reuse the stale QUIC connection, causing SSL errors. The browser eventually falls back to HTTP/2 over TCP, but this takes 30-60 seconds.

**Fix:** HTTP/3 is disabled globally in the Caddyfile via `protocols h1 h2` in the `servers` block. This was already applied — if the issue recurs after a Caddyfile change, verify the setting is still present:

```bash
# Verify protocols setting
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile

# Check that HTTP/3 is not advertised
curl -sI https://pupyrus.loft.hsimah.com | grep -i alt-svc
# Should return nothing (no h3 advertisement)

# If the setting was removed, rebuild mushr
loft-ctl rebuild mushr
```

**Why not HTTP/3?** HTTP/3 (QUIC) is designed for lossy, high-latency connections (mobile networks, intercontinental links). On a LAN, HTTP/2 over TCP is equally fast and handles idle connections gracefully via TCP keepalive.

## 11. Triage Flowchart

When something is broken, follow this decision tree:

```
START: Something is broken
│
├─ 1. Run: loft-ctl health
│     → Identifies which service(s) have failures
│
├─ 2. Run: sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}'
│     → Is the container running, exited, or restarting?
│     │
│     ├─ RUNNING but unhealthy
│     │   → Check Docker healthcheck:
│     │     sudo docker inspect <container> --format '{{json .State.Health}}'
│     │   → Check application logs:
│     │     sudo docker logs <container> --tail 50
│     │   → Go to section for that service type (database, network, Caddy)
│     │
│     ├─ EXITED
│     │   → Check exit code:
│     │     sudo docker inspect <container> --format '{{.State.ExitCode}}'
│     │   │
│     │   ├─ Exit 0: Clean shutdown — just restart
│     │   │   sudo docker start <container>
│     │   │
│     │   ├─ Exit 1: App error — check logs
│     │   │   sudo docker logs <container> --tail 50
│     │   │   → Fix config, then: loft-ctl rebuild <service>
│     │   │
│     │   ├─ Exit 137: OOM kill — see "OOM kill" in Common Problems
│     │   │   sudo docker inspect <container> --format '{{.State.OOMKilled}}'
│     │   │
│     │   └─ Exit 127/126: Missing binary or permissions
│     │       → Image may be corrupt: loft-ctl rebuild <service>
│     │
│     └─ RESTARTING (crash loop)
│         → Check logs:
│           sudo docker logs <container> --tail 50
│         → Check restart count:
│           sudo docker inspect <container> --format '{{.RestartCount}}'
│         → If config issue: fix config, then rebuild
│         → If resource issue: check disk (df -h) and memory (free -h)
│
├─ 3. Still stuck? Check infrastructure:
│     │
│     ├─ Disk full?
│     │   df -h
│     │   sudo docker system df
│     │   → See section 7 (Storage / Disk)
│     │
│     ├─ Network issue?
│     │   sudo docker network inspect loft-proxy
│     │   → See section 6 (Network Debugging)
│     │
│     ├─ DNS not resolving?
│     │   dig @localhost radarr.space-needle +short
│     │   → See section 6 (DNS resolution)
│     │
│     └─ Caddy / proxy issue?
│         curl -sk https://localhost -H 'Host: <service>.loft.hsimah.com'
│         → See section 8 (Caddy)
│
└─ 4. Nuclear options (last resort):
      │
      ├─ Rebuild single service:
      │   loft-ctl rebuild <service>
      │
      ├─ Rebuild everything:
      │   loft-ctl rebuild --all
      │
      └─ Full re-provision (preserves data):
          cd /srv/the-loft && sudo bash setup.sh
```

## Worked Example: Debugging pupyrus-db in Error State

This is a real debugging session captured for reference.

**Initial observation:** `loft-ctl health` reports pupyrus as failing. `docker ps -a` shows `pupyrus-db` in an Error state.

### Step 1: Identify the problem

```bash
# Check container status
sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep pupyrus
```

Look for: which containers are running vs exited/error. If `pupyrus-db` is in Error, both `pupyrus` (WordPress) and `pupyrus-cli` will also be down since they depend on it via `service_healthy`.

### Step 2: Get the exit code

```bash
sudo docker inspect pupyrus-db --format '{{.State.ExitCode}}'
sudo docker inspect pupyrus-db --format '{{.State.OOMKilled}}'
```

- Exit code `1` = MariaDB startup error (most common)
- Exit code `137` + OOMKilled `true` = out of memory

### Step 3: Read the logs

```bash
sudo docker logs pupyrus-db --tail 50
```

Common MariaDB error patterns to look for:
- `InnoDB: Corruption` — data file corruption
- `Table 'xxx' is marked as crashed` — table needs repair
- `Disk full` / `No space left on device` — check `df -h /opt`
- `Can't create/write to file` — permissions on `/opt/pupyrus/db`
- `Upgrade Required` — MariaDB version mismatch

### Step 4: Fix based on findings

**If disk full:**
```bash
df -h /opt
# Free space, then restart
sudo docker start pupyrus-db
```

**If permissions:**
```bash
sudo chown -R littledog:pack-member /opt/pupyrus/db
sudo docker start pupyrus-db
```

**If InnoDB corruption or upgrade needed:**
```bash
# Try with auto-upgrade enabled
# Edit services/pupyrus/docker-compose.yml temporarily to add:
#   MARIADB_AUTO_UPGRADE: "1"
# Then:
loft-ctl rebuild pupyrus

# After successful start, run upgrade manually if needed:
sudo docker exec pupyrus-db mariadb-upgrade -u root -p
```

**If unknown — rebuild from scratch:**
```bash
loft-ctl rebuild pupyrus
loft-ctl health pupyrus
```

### Step 5: Verify recovery

```bash
# Check all pupyrus containers are running
sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep pupyrus

# Check MariaDB health
sudo docker inspect pupyrus-db --format '{{.State.Health.Status}}'

# Check WordPress responds
curl -s -o /dev/null -w '%{http_code}' http://localhost:8081

# Full health check
loft-ctl health pupyrus
```
