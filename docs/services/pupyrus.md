# `pupyrus`

> WordPress on space-needle — `wordpress` + `mariadb` + `redis`, fronted by Caddy at `pupyrus.loft.hsimah.com`.

## Overview

`pupyrus` (puppy + papyrus, a writing surface) is the WordPress install for the family-facing site. Three core containers run together: `wordpress` (PHP-FPM + Apache), `pupyrus-db` (MariaDB), and `pupyrus-redis` (object cache). A fourth, `pupyrus-cli` (`wordpress:cli`), is gated behind the `cli` profile and used by `services/pupyrus/setup.sh` for one-shot wp-cli commands. Caddy proxies `pupyrus.loft.hsimah.com` (and the LAN HTTP fallback `pupyrus.space-needle` + the apex `loft.hsimah.com`) into the WordPress container.

## Architecture

### Containers

| Container | Image | Network | Purpose |
|-----------|-------|---------|---------|
| `pupyrus` | `wordpress:latest` | `default` + `loft-proxy` | PHP-FPM / Apache — WordPress runtime |
| `pupyrus-db` | `mariadb:12.2` | `default` only | Database — `/var/lib/mysql` on `/opt/pupyrus/db` |
| `pupyrus-redis` | `redis:7-alpine` | `default` only | Object cache — used by the Redis Object Cache plugin |
| `pupyrus-cli` | `wordpress:cli` | `default` only (`cli` profile) | wp-cli for setup + ad-hoc admin |

The `pupyrus` service joins both `default` (so it can reach `db` and `redis` by service name) and `loft-proxy` (so Caddy in [mushr](mushr.md) can reach it as `pupyrus:80`). The db and redis services are deliberately not on `loft-proxy` — there's no reason to expose them outside the compose.

### WPGraphQL + JWT auth

The build is set up to serve a headless GraphQL endpoint alongside the standard WordPress site. The compose injects `WORDPRESS_CONFIG_EXTRA` with:

- `WP_REDIS_HOST=redis` / `WP_REDIS_PORT=6379` / `WP_CACHE=true` — connects WordPress to the Redis Object Cache plugin
- `GRAPHQL_JWT_AUTH_SECRET_KEY=${GRAPHQL_JWT_AUTH_SECRET_KEY}` — read by the [WPGraphQL JWT Authentication](https://github.com/wp-graphql/wp-graphql-jwt-authentication) plugin

The plugins themselves are installed inside `/opt/pupyrus/html/wp-content/plugins/` and activated through wp-admin, not the compose.

### Health gating

- `pupyrus-db` healthcheck: `healthcheck.sh --connect --innodb_initialized`
- `pupyrus-redis` healthcheck: `redis-cli ping`
- `pupyrus` `depends_on` both: `condition: service_healthy` — WordPress won't start until both are up

This is what makes a corrupt `pupyrus-db` cascade into a fully-down WordPress site. See debug below.

## Configuration

### `.env`

Copy [`services/pupyrus/.env.example`](../../services/pupyrus/.env.example).

| Variable | Purpose |
|----------|---------|
| `MYSQL_ROOT_PASSWORD` | MariaDB root — used for manual admin only; WordPress uses the per-app user |
| `MYSQL_DATABASE` | DB name (default `wordpress`) |
| `MYSQL_USER` / `MYSQL_PASSWORD` | WordPress's DB credentials |
| `WORDPRESS_TABLE_PREFIX` | Default `wp_` — change only for multi-site or legacy imports |
| `WORDPRESS_DEBUG` | `0` (default) / `1` to enable `WP_DEBUG` |
| `GRAPHQL_JWT_AUTH_SECRET_KEY` | JWT signing secret for the GraphQL auth plugin — rotate by editing `.env` and rebuilding |
| `WORDPRESS_ADMIN_PASSWORD` / `WORDPRESS_ADMIN_EMAIL` | Used by `services/pupyrus/setup.sh` only — for the first `wp core install` invocation |

### Storage

| Host path | Container path | Service | Purpose |
|-----------|----------------|---------|---------|
| `/opt/pupyrus/html` | `/var/www/html` | `pupyrus`, `pupyrus-cli` | WordPress files — themes, plugins, uploads, wp-config |
| `/opt/pupyrus/db` | `/var/lib/mysql` | `pupyrus-db` | MariaDB data |

Both are bind mounts (not Docker volumes), owned `littledog:pack-member`. **Never** `docker compose down -v pupyrus` — even with bind mounts it's fine, but the `-v` flag also strips any anonymous volumes the WordPress image creates internally.

### Caddy routes

From [`services/mushr/Caddyfile`](../../services/mushr/Caddyfile):

- `pupyrus.loft.hsimah.com` → `pupyrus:80` (HTTPS via Cloudflare DNS-01)
- `http://pupyrus.space-needle` → `pupyrus:80`
- `{$LOFT_DOMAIN}` (the apex `loft.hsimah.com`) → `pupyrus:80` — WordPress is the default site at the apex
- `http://space-needle` → `pupyrus:80`

## Operations

```bash
loft-ctl start pupyrus
loft-ctl rebuild pupyrus              # pulls latest wordpress/mariadb/redis images
loft-ctl health pupyrus               # checks pupyrus.space-needle + pupyrus.loft.hsimah.com

# wp-cli (cli profile)
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp plugin list

sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp cache flush
```

### First-time setup

The repo's `setup.sh` calls `services/pupyrus/setup.sh` after `docker compose up -d`, which checks `wp core is-installed` and runs `wp core install` if not. The admin user is `adminhabl`, password from `WORDPRESS_ADMIN_PASSWORD` in `.env`.

After install, browse to `https://pupyrus.loft.hsimah.com/wp-admin`, install the plugins you need (Redis Object Cache, WPGraphQL, WPGraphQL JWT Authentication), and activate them. **Redis Object Cache → Enable** at Settings → Redis is the step that actually makes the cache active — the env vars only configure WordPress to talk to it.

### Backups

There are no in-repo backup scripts. The data lives under `/opt/pupyrus/{html,db}`. For a manual snapshot:

```bash
loft-ctl stop pupyrus
sudo tar -czf /mammoth/backup/pupyrus-$(date +%F).tar.gz -C /opt pupyrus
loft-ctl start pupyrus
```

## Related

- [mushr](mushr.md) — Caddy routes + Cloudflare DNS-01 cert for `pupyrus.loft.hsimah.com`
- [space-needle](../hosts/space-needle.md) — the only host that runs pupyrus
- Blog: [Pupyrus — WordPress in the loft](../../../hblake/posts/pupyrus.md)

## Debug & Troubleshooting

### `pupyrus-db` restart-loops with "Bad magic header in tc log" — RECURRING

**Symptom:** `sudo docker ps -a --filter name=pupyrus-db` shows `Restarting (1)`. Logs:

```
[ERROR] Bad magic header in tc log
[ERROR] Crash recovery failed. Either correct the problem ... or delete tc log and start server with --tc-heuristic-recover={commit|rollback}
[ERROR] Can't init tc log
[ERROR] Aborting
```

This is the **single most common pupyrus failure** — it surfaces basically every time `setup.sh` recreates `pupyrus-db` mid-startup.

**Cause:** MariaDB's two-phase-commit transaction coordinator log (`tc.log`) got corrupted because the container was hard-killed during InnoDB recovery. WordPress doesn't use XA transactions, so `tc.log` carries no in-flight state worth preserving — deleting it is safe.

**Fix:**

```bash
sudo docker stop pupyrus-db
sudo rm /opt/pupyrus/db/tc.log
sudo docker start pupyrus-db
sudo docker logs -f pupyrus-db   # watch for "ready for connections"
# Then bring up the rest:
sudo docker start pupyrus
```

No `--tc-heuristic-recover` flag needed. After this, the `wordpress` and `pupyrus-redis` containers will come up on their own.

### Redis Object Cache silently not working

**Symptom:** WordPress is slow, the Redis Object Cache plugin says "Connected" but nothing seems cached.

**Checks:**

```bash
# Is Redis getting traffic?
sudo docker exec pupyrus-redis redis-cli dbsize
# Expect non-zero on a site with traffic. 0 means WP isn't writing.

# Memory usage
sudo docker exec pupyrus-redis redis-cli info memory | grep used_memory_human

# Did WordPress pick up WP_CACHE / WP_REDIS_HOST?
sudo docker exec pupyrus wp config get WP_REDIS_HOST --allow-root 2>&1 | tail
```

**Common causes:**
- Plugin installed but **not enabled** at Settings → Redis. The `WP_REDIS_HOST` env vars only describe *where* to connect; the plugin admin UI actually flips the cache on.
- A stale `wp-content/object-cache.php` from an older Redis plugin — delete and re-enable.

### Permission denied writing to `/var/www/html`

**Cause:** `/opt/pupyrus/html` isn't owned by the right UID/GID — usually after `setup.sh` was run as a different user.

**Fix:**

```bash
sudo chown -R 33:33 /opt/pupyrus/html    # www-data inside the wordpress image
# Note: This differs from the loft's standard littledog:pack-member ownership
# because the WordPress image runs as www-data (UID 33). If you reset the
# whole repo with chown -R littledog:pack-member, expect to redo this step.
```

### `pupyrus-db` won't start — InnoDB corruption / version mismatch

If the `tc.log` fix above doesn't get you back up, the logs may show InnoDB corruption or "Upgrade Required":

```bash
sudo docker logs pupyrus-db --tail 100
```

Recovery paths:

```bash
# Major version upgrade — enable auto-upgrade
# Edit services/pupyrus/docker-compose.yml temporarily:
#   environment:
#     MARIADB_AUTO_UPGRADE: "1"
loft-ctl rebuild pupyrus

# Manual upgrade pass
sudo docker exec pupyrus-db mariadb-upgrade -u root -p

# Disk-full?
df -h /opt
```

### WPGraphQL queries return "Invalid signature" or 401

**Cause:** `GRAPHQL_JWT_AUTH_SECRET_KEY` changed between when a token was issued and when it was verified. Rotating the secret invalidates all outstanding JWTs.

**Fix:** Either restore the prior secret in `services/pupyrus/.env` and `loft-ctl rebuild pupyrus`, or re-authenticate any clients to get fresh tokens.

### Caddy can't reach `pupyrus:80`

**Cause:** `pupyrus` isn't on `loft-proxy`. Should be both networks (see compose) — if a recent edit dropped `loft-proxy`, Caddy can't find it by container name.

**Fix:** Verify the `networks:` block on the `wordpress` service includes both `default` and `loft-proxy`, then `loft-ctl rebuild pupyrus`.

### wp-cli commands hang or fail

Use the `cli` profile rather than `docker exec` into the running `pupyrus` container — `wordpress:cli` is a separate image with `wp` on PATH and runs as the right user:

```bash
sudo docker compose -f /srv/the-loft/services/pupyrus/docker-compose.yml \
  --profile cli run --rm cli wp <command>
```

The CLI container has the same bind mount and `depends_on: db: service_healthy` — if it hangs at start, MariaDB is the suspect.
