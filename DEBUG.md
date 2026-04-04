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
| **stellarr** | `stellarr-vpn`, `transmission`, `slskd`, `radarr`, `sonarr`, `lidarr`, `jackett` |
| **pupyrus** | `pupyrus-db`, `pupyrus-redis`, `pupyrus`, `pupyrus-cli` (cli profile only) |
| **iditarod** | `iditarod` |
| **howlr** | `howlr-snapserver`, `howlr-shairport-sync`, `howlr-librespot`, `howlr-snapclient` |
| **pulsr** | `pulsr`, `pulsr-phanpy` |
| **pawst** | `pawst` |

### Health Check URLs (space-needle)

| Label | URL | Required? |
|-------|-----|-----------|
| pawpcorn | `http://localhost:32400/web` | Yes |
| radarr | `http://localhost:7878` | Yes |
| sonarr | `http://localhost:8989` | Yes |
| lidarr | `http://localhost:8686` | Yes |
| jackett | `http://localhost:9117` | Yes |
| pupyrus | `http://localhost:8081` | Yes |
| mushr | `http://localhost:8880/config/` | Yes |
| snapweb | `http://localhost:1780` | Yes |
| pulsr | `https://pulsr.hsimah.com/api/v1/instance` | Yes |
| pawst | `http://localhost:8085` | Yes |
| transmission | `http://localhost:9091` | Warn only (VPN) |
| slskd | `http://localhost:5030` | Warn only (VPN) |

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
# Cron jobs (CPU collector, image collector, package collector, transmission cleanup, pulsr reports)
sudo grep -i loft /var/log/syslog | tail -20

# CPU metrics (sampled every minute by pulsr-collector.sh)
sudo cat /var/log/loft/cpu.log

# Package update cache (refreshed every 6 hours by package-collector.sh)
sudo cat /var/log/loft/packages.log

# Docker image update cache (refreshed daily by image-collector.sh)
sudo cat /var/log/loft/images.log

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
curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://pulsr.hsimah.com/api/v1/instance # pulsr

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

Expected members of `loft-proxy`: `mushr`, `mushr-tunnel`, `pupyrus`, `pulsr`, `pulsr-phanpy`, `pawst`

### Container-to-container connectivity

```bash
# Test from mushr (Caddy) to pupyrus
sudo docker exec mushr wget -q -O /dev/null http://pupyrus:80 && echo "OK" || echo "FAIL"

# Test from mushr to pulsr
sudo docker exec mushr wget -q -O /dev/null http://pulsr:8080 && echo "OK" || echo "FAIL"

# Test from mushr to pawst
sudo docker exec mushr wget -q -O /dev/null http://pawst:80 && echo "OK" || echo "FAIL"
```

### DNS resolution (mushr-dns / dnsmasq)

```bash
# Test wildcard DNS resolution (from the host)
dig @localhost radarr.space-needle +short
dig @localhost sonarr.loft.hsimah.com +short
dig @localhost pulsr.hsimah.com +short
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
#   1704  — howlr-snapserver (Snapcast stream)
#   1705  — howlr-snapserver (Snapcast control)
#   1780  — howlr-snapserver (Snapweb UI)
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
curl -sk -o /dev/null -w '%{http_code}' https://pulsr.hsimah.com/api/v1/instance
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
sudo docker volume inspect caddy-data
sudo docker volume inspect snapserver-data
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
| Image update available | `loft-ctl rebuild <service>` | Pulls latest images |
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
| **pulsr** | Deletes GoToSocial data (`/opt/pulsr/data`) — all posts, accounts, media |
| **mushr** | Deletes TLS certificates (`caddy-data`) — triggers re-issuance (rate limits apply) |
| **howlr** | Deletes snapserver speaker group config (`snapserver-data` volume) |

`loft-ctl rebuild` uses `docker compose down` (without `-v`) which is safe — it removes containers but preserves volumes and bind mounts.

## 10. Common Problems

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

### Phanpy OAuth cache after GoToSocial rebuild

**Symptom:** After rebuilding pulsr, Phanpy shows login errors or can't connect to GoToSocial.

**Cause:** Phanpy caches the OAuth `client_id` in browser **local storage** (not cookies).

**Fix:** Clear browser local storage for the Phanpy domain, not just cookies. In Chrome: DevTools > Application > Local Storage > delete all entries for the pulsr domain.

### Snapweb crashes on AirPlay stream

**Symptom:** Snapweb browser client loads but audio playback crashes or stutters when playing AirPlay content.

**Cause:** AirPlay 2 uses 48kHz/32-bit format (`sampleformat=48000:32:2`). Snapweb can't handle this format.

**Fix:** Use native snapclient devices (viking, fjord) for AirPlay playback. Spotify Connect works on all clients including snapweb (uses 44100:16:2).

### Howlr no audio after config change (stale FIFOs)

**Symptom:** After changing snapserver or shairport-sync config, audio stops working entirely. No errors in logs.

**Cause:** Named pipes (FIFOs) used for audio transport between containers become stale when only containers are recreated.

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

### iditarod runner offline (token expired)

**Symptom:** GitHub Actions runner shows as offline in the org settings. Container is running but not picking up jobs.

**Cause:** The `GITHUB_ACCESS_TOKEN` in `services/iditarod/.env` has expired.

**Fix:**
1. Generate a new token at GitHub > Settings > Developer settings > Personal access tokens
2. Update `GITHUB_ACCESS_TOKEN` in `services/iditarod/.env`
3. `loft-ctl rebuild iditarod`

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

### pulsr-ctl report silently fails

**Symptom:** `sudo pulsr-ctl report` produces no output at all. No error, no post.

**Cause:** A CPU sample of `0` in `/var/log/loft/cpu.log` triggers a bash arithmetic gotcha. Expressions like `(( 0 ))` return exit code 1, and `set -e` kills the script silently. This was fixed in commit `76c5437` by adding `|| true` to arithmetic lines that can evaluate to zero.

**Fix:** Pull the latest code:
```bash
cd /srv/the-loft && git pull
sudo pulsr-ctl report
```

**Debug tip:** If `pulsr-ctl` ever fails silently, run with `bash -x` to find where it dies:
```bash
sudo bash -x /srv/the-loft/pulsr-ctl report 2>&1 | tail -40
```

### Fleet report shows "Updates: no data"

**Symptom:** `sudo pulsr-ctl report` posts with `Updates: no data` instead of package counts.

**Cause:** The package collector cron hasn't run yet, or `/var/log/loft/packages.log` doesn't exist.

**Fix:**
```bash
# Run the collector manually
sudo /srv/the-loft/control-plane/package-collector.sh

# Verify the cache file
sudo cat /var/log/loft/packages.log

# Check cron is installed
cat /etc/cron.d/loft-package-collector
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

### Pulsr SSL errors after idle (HTTP/3 QUIC timeout)

**Symptom:** After leaving Phanpy idle for a few minutes, API calls fail with SSL/protocol errors in the browser console. The Phanpy UI still loads (from service worker cache), but all GoToSocial API requests (`/api/*`) fail. Recovery requires logging out, clearing browser cache, and waiting 30-60 seconds.

**Cause:** Caddy enables HTTP/3 (QUIC over UDP) by default for all HTTPS listeners. After idle, the QUIC connection's server-side idle timeout expires. When the user returns, the browser tries to reuse the stale QUIC connection, causing SSL errors. The browser eventually falls back to HTTP/2 over TCP, but this takes 30-60 seconds.

**Fix:** HTTP/3 is disabled globally in the Caddyfile via `protocols h1 h2` in the `servers` block. This was already applied — if the issue recurs after a Caddyfile change, verify the setting is still present:

```bash
# Verify protocols setting
sudo docker exec mushr caddy validate --config /etc/caddy/Caddyfile

# Check that HTTP/3 is not advertised
curl -sI https://pulsr.hsimah.com | grep -i alt-svc
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
