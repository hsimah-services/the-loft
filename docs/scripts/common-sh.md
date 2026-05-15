# `control-plane/common.sh`

> Sourced library — provides the compose-arg resolution and health-check helpers shared by [`loft-ctl`](loft-ctl.md) and [`setup.sh`](setup.md).

## Overview

[`common.sh`](../../control-plane/common.sh) is the only piece of code that knows how to combine a service's base `docker-compose.yml` with its per-host override file, and the only place that runs URL health checks against the tiered `HEALTH_URLS` data structure. By living in one file and being `source`d by every entry point, the behaviour stays consistent: `loft-ctl rebuild`, `loft-ctl health`, and `setup.sh`'s phase-11 service deployment all interpret `host.conf` the same way.

This is a library, not a CLI. Don't invoke `common.sh` directly — source it from a script that has already loaded `host.conf`.

## Architecture

When sourced, `common.sh`:

1. Resolves `REPO_DIR` from its own `BASH_SOURCE` (so it works regardless of caller's cwd).
2. Sources `hosts/$(hostname)/host.conf` — same precondition as the rest of the control plane. Exits 1 if the host isn't configured.
3. Defines health-check tunables (`HC_TIMEOUT=30`, `HC_INTERVAL=5`) and the tier list (`TIERS=(local lan ssl)`).
4. Defines four helper functions.

### Helpers

| Function | Returns | Purpose |
|----------|---------|---------|
| `compose_args_for <service>` | `-f <base> [-f <override>]` on stdout, exit 0 / 1 | Build the `docker compose` args for a service, merging in the per-host override if present |
| `check_url <url> <tier> [warn_only]` | exit 0 / 1, formatted line on stdout | curl a single URL with a 5s timeout; print `OK`/`FAIL`/`WARNING` row |
| `check_endpoint <label> [warn_only]` | failed count | For one endpoint label, loop over `TIERS` and call `check_url` for each tier with a defined URL |
| `check_containers <compose_args> <service>` | exit 0 / 1 | Poll `docker compose ps` until all containers report `running` (up to `HC_TIMEOUT`s) |
| `check_web_ui <service>` | failed count | For one service, read `SERVICE_ENDPOINTS[<service>]` + `SERVICE_ENDPOINTS_WARN[<service>]` and run all defined endpoint+tier combinations |

`compose_args_for` is the most important: it's what makes per-host overrides work without every caller having to repeat the path logic.

### `compose_args_for` in detail

```bash
# Given a service name:
#   base     = $REPO_DIR/services/<service>/docker-compose.yml
#   override = $REPO_DIR/hosts/$HOST_NAME/overrides/<service>/docker-compose.override.yml
#
# Always emits "-f $base", appends "-f $override" iff the override file exists.
# Returns 1 (and logs ERROR) if no base compose file exists for the service.
compose_args_for stellarr
# → "-f /srv/the-loft/services/stellarr/docker-compose.yml \
#    -f /srv/the-loft/hosts/space-needle/overrides/stellarr/docker-compose.override.yml"
```

Callers feed the result into `docker compose <args> <subcommand>`. Because the output contains spaces, the standard pattern is:

```bash
compose_args=$(compose_args_for "$service") || continue
# shellcheck disable=SC2086 -- intentional word-splitting
docker compose ${compose_args} up -d
```

The shellcheck disable is deliberate — we want word-splitting between `-f` and each path. Quoting `"${compose_args}"` would pass the whole string as one argument to `docker compose`, which would error.

### Health-check tier model

`check_web_ui` reads two associative arrays from `host.conf`:

| Array | Shape | Example |
|-------|-------|---------|
| `SERVICE_ENDPOINTS[<service>]` | space-separated list of labels | `SERVICE_ENDPOINTS[stellarr]="radarr sonarr lidarr jackett bazarr"` |
| `SERVICE_ENDPOINTS_WARN[<service>]` | same, for warn-only labels | `SERVICE_ENDPOINTS_WARN[stellarr]="transmission slskd"` |
| `HEALTH_URLS[<label>:<tier>]` | URL string | `HEALTH_URLS[radarr:ssl]="https://radarr.loft.hsimah.com"` |
| `HEALTH_URLS_WARN[<label>:<tier>]` | URL string | `HEALTH_URLS_WARN[transmission:local]="http://localhost:9091"` |

Tiers iterated in order: `local`, `lan`, `ssl`. Any tier missing a URL is silently skipped (so a service that only has an `ssl` URL doesn't generate "FAIL" rows for `local` and `lan`).

Required vs warn-only:

- **Required** (`SERVICE_ENDPOINTS` + `HEALTH_URLS`): non-200/non-2xx is fine (Caddy + Nginx behind auth often return 401/403 to a curl — that's a successful response from a health-check perspective), but `000` (no response) is a FAIL and counts against the run's exit code.
- **Warn-only** (`SERVICE_ENDPOINTS_WARN` + `HEALTH_URLS_WARN`): `000` is logged as `WARNING (VPN-dependent)` and doesn't fail the run. Used for transmission/slskd which 404 when [stellarr](../services/stellarr.md)'s VPN is down.

`check_url`'s exit code:

| Response | Required | Warn-only |
|----------|----------|-----------|
| `000` (no response) | FAIL — exit 1 | WARNING — exit 0 |
| Any HTTP code | OK — exit 0 | OK — exit 0 |

Note that "responded with any HTTP code" counts as OK, since auth-gated or schema-incomplete endpoints still prove the container is alive and routable.

### `check_containers` polling

```bash
elapsed=0
while (( elapsed < HC_TIMEOUT )); do            # 30s ceiling
  states=$(docker compose <args> ps --format '{{.State}}' | grep -v '^$')
  [[ -z "$states" ]] && { sleep HC_INTERVAL; continue; }   # nothing yet
  all_running=true
  while read -r state; do
    [[ "$state" != "running" ]] && { all_running=false; break; }
  done <<< "$states"
  $all_running && return 0
  sleep HC_INTERVAL                              # 5s between polls
  ((elapsed += HC_INTERVAL))
done
# timeout: print "WARNING: Not all containers running after 30s"
#          dump `docker compose ps`, return 1
```

Six polls over 30s. Adequate for everything in the fleet on a Pi 3 B+; if a service legitimately needs longer to start (e.g. waiting on an upstream), increase `HC_TIMEOUT` per-call by editing the constants (no callable override exists, deliberately — slow boots should be diagnosed, not papered over).

## Configuration

`common.sh` itself has no `.env` and takes no flags. Its inputs are:

| Source | Purpose |
|--------|---------|
| `hosts/$(hostname)/host.conf` | `HOST_NAME`, `SERVICE_ENDPOINTS`, `SERVICE_ENDPOINTS_WARN`, `HEALTH_URLS`, `HEALTH_URLS_WARN` |
| `services/<service>/docker-compose.yml` | Existence is required for `compose_args_for` to succeed |
| `hosts/<host>/overrides/<service>/docker-compose.override.yml` | Existence is optional — appended if present |

### Knobs

| Variable | Default | Purpose |
|----------|---------|---------|
| `HC_TIMEOUT` | `30` (sec) | Max time to wait for all containers in a compose group to be `running` |
| `HC_INTERVAL` | `5` (sec) | Polling interval inside `check_containers` |
| `TIERS` | `(local lan ssl)` | Order and identity of health-check tiers |

These are hardcoded — change them by editing the file. There's no override mechanism on purpose; consistency across callers is the point of the shared library.

## Operations

`common.sh` isn't called directly. Routine use is implicit through `loft-ctl` and `setup.sh`:

```bash
loft-ctl health stellarr        # → check_containers + check_web_ui for stellarr
loft-ctl rebuild --all          # → compose_args_for each entry in SERVICES
sudo bash setup.sh              # → compose_args_for in phase 11 service deploy
```

For ad-hoc debugging (e.g. inspecting which `-f` args a service resolves to), source the library by hand:

```bash
cd /srv/the-loft
source control-plane/common.sh
compose_args_for stellarr
# → -f /srv/the-loft/services/stellarr/docker-compose.yml \
#   -f /srv/the-loft/hosts/space-needle/overrides/stellarr/docker-compose.override.yml
```

(Note: sourcing in an interactive shell prints `host.conf` errors to stderr if the host is unconfigured.)

## Related

- [`loft-ctl`](loft-ctl.md) — primary caller, uses every helper
- [`setup.sh`](setup.md) — sources `common.sh` for `compose_args_for` in the service-deploy phase
- Host pages — define `SERVICE_ENDPOINTS` / `HEALTH_URLS` / overrides: [space-needle](../hosts/space-needle.md), [viking](../hosts/viking.md), [fjord](../hosts/fjord.md), [calavera](../hosts/calavera.md)
- Service pages — every service in the fleet has its compose merged by `compose_args_for`

## Debug & Troubleshooting

### `ERROR: No docker-compose.yml found for '<service>'`

**Cause:** Caller asked for a service that has no `services/<service>/docker-compose.yml`. Usually a typo in `SERVICES`, a deleted service that wasn't removed from `host.conf`, or a missing checkout (e.g. a fresh clone without LFS / submodules).

**Fix:**

```bash
ls services/                 # what actually exists?
# Fix the typo in hosts/$(hostname)/host.conf SERVICES
```

### Per-host override not being applied

**Symptom:** A setting you added to `hosts/<host>/overrides/<service>/docker-compose.override.yml` doesn't appear in `docker compose config`.

**Cause:** The override file name or path is wrong. `compose_args_for` looks for **exactly**:

```
hosts/$HOST_NAME/overrides/<service>/docker-compose.override.yml
```

Any deviation (`.override.yaml` vs `.override.yml`, wrong service directory, typo in hostname) silently means "no override" — the function checks existence only, doesn't warn on near-misses.

**Fix:**

```bash
ls hosts/$(hostname)/overrides/<service>/
# Should contain: docker-compose.override.yml (exact name)

# Manual verification:
source control-plane/common.sh
compose_args_for <service>   # should emit two -f flags
```

### Health checks succeed in `loft-ctl health` but my browser sees the site as broken

**Cause:** `check_url` treats **any HTTP response** as success — it only fails on `000`. So a 502 from Caddy or a 500 from an app still passes the health check.

**Fix:** This is by design (auth-gated endpoints return 401, that's fine). For functional checks, inspect logs of the specific container, or add a more specific URL that returns 200 on success (e.g. an app's `/health` endpoint).

### Containers all report `running` but the URL check fails

**Cause:** Container started but isn't yet listening, or Caddy hasn't reloaded the route, or DNS hasn't propagated (`*.space-needle` and `*.loft.hsimah.com` rely on mushr-dns being up first).

**Fix:**

```bash
loft-ctl rebuild mushr                       # if mushr is the dependency
sudo docker logs <container> --tail 30       # confirm the app's "listening on" line
```

Then retry the health check.

### Health check hangs for the full 30s

**Cause:** One container is genuinely slow to start (cold image pull on a Pi, big WordPress migration on first boot, MariaDB innodb recovery). `check_containers` polls every 5s and tolerates a stragglier; if a service exceeds 30s, you'll get a warning + the `docker compose ps` dump.

**Fix:** Either:

- Wait — the container often comes up shortly after the warning prints, and a follow-up `loft-ctl health <service>` will pass.
- Inspect `docker logs` for the stuck container — sometimes it's an actual failure that needs a fix (e.g. [pupyrus-db tc.log corruption](../services/pupyrus.md#pupyrus-db-restart-loops-with-bad-magic-header-in-tc-log-after-setupsh)).

If a service legitimately needs more than 30s, increase `HC_TIMEOUT` in this file — but treat that as a last resort.

### Sourcing `common.sh` errors with `ERROR: No host config found`

**Cause:** Running on a host whose hostname isn't represented in `hosts/`. Same root cause as in [`setup.sh`](setup.md#no-host-config-found-at-hostshostnamehostconf) and [`loft-ctl`](loft-ctl.md#no-host-config-found-at-hostshostnamehostconf).

**Fix:** Either set the hostname to one of the configured hosts, or add a new `hosts/<this-hostname>/host.conf` describing the host. The library is unwilling to operate on an unconfigured host on purpose — every caller depends on `SERVICES` and friends being set.

### Quoting bug: `docker compose: '-f /path -f /other' is not a docker compose subcommand`

**Cause:** Caller quoted the result of `compose_args_for`: `docker compose "${compose_args}" up -d`. The quotes prevent word-splitting; the whole string is passed as one argument.

**Fix:** Use unquoted expansion in the call (with a shellcheck disable):

```bash
compose_args=$(compose_args_for "$service") || continue
# shellcheck disable=SC2086
docker compose ${compose_args} up -d
```

This is the pattern used by both `loft-ctl` and `setup.sh`.
