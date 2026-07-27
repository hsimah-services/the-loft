# Fleet Upgrade — July 2026

Sequenced upgrade plan for The Loft. Music Assistant and Plex are the
must-not-break services and are done **one at a time**, each with its own
verify-and-rollback gate, before anything else is touched.

All hosts are remote — every command below is run by hand over SSH on the named
host. Docker commands elevate to `adminhabl` automatically via `loft-ctl`, or
need `sudo` when run directly.

---

## Images are now pinned — the pin commit *is* the upgrade

The fleet previously ran entirely on floating tags. Every image is now pinned to
an explicit version in git (see README → "Image pinning"). **Read this before
deploying anything:**

The pinned versions are the *target* versions — current latest-stable as of
2026-07-26, not what is running today. The pinning commit and the upgrade are
therefore the same action. Deploying it wholesale would upgrade the entire fleet
at once, which is exactly what this plan exists to avoid.

**Deploy the pins per-service, in the phase order below.** The commit can land on
`main` immediately — it changes nothing until `loft-ctl update <service>` runs on
a host.

The upside: rollback is now a git operation.

```bash
git revert <commit>        # or just edit the tag back
loft-ctl update <service>
```

The previous image is still on disk under its own tag, so a rollback needs no
re-download. This replaces the digest-capture dance the old `:latest` setup
required.

Pinned versions:

| Service | Image | Pinned to |
|---|---|---|
| howlr | `ghcr.io/music-assistant/server` | `2.9.9` |
| howlr | `ivdata/snapclient` | digest `sha256:0270a64f…` |
| pawpcorn | `plexinc/pms-docker` | `1.43.3.10828-00f62d37d` |
| stellarr | `ghcr.io/bubuntux/nordvpn` | `v3.12.3` *(archived upstream)* |
| stellarr | `lscr.io/linuxserver/transmission` | `4.1.3-r0-ls355` |
| stellarr | `slskd/slskd` | `0.26.0` |
| stellarr | `lscr.io/linuxserver/radarr` | `6.3.0.10514-ls312` |
| stellarr | `lscr.io/linuxserver/sonarr` | `4.0.19.2979-ls320` |
| stellarr | `lscr.io/linuxserver/lidarr` | **still `nightly`** — see Phase 3 |
| stellarr | `lscr.io/linuxserver/bazarr` | `v1.6.0-ls356` |
| stellarr | `lscr.io/linuxserver/jackett` | `v0.24.2268-ls474` |
| mushr | `caddy` (via `CADDY_VERSION`) | `2.11.4` |
| mushr | `cloudflare/cloudflared` | `2026.7.3` |
| mushr | `drpsychick/dnsmasq` | `2.93` |
| pupyrus | `mariadb` | `12.2.2` *(held on 12.2.x)* |
| pupyrus | `redis` | `7.4.10-alpine` *(held on 7.x)* |
| pupyrus | `wordpress` | `7.0.2-php8.5-apache` |
| pupyrus | `wordpress` (cli) | `cli-2.12.0` |
| pawst | `nginx` | `1.30.4-alpine` |
| houstn | `henrygd/beszel` | `0.18.7` |
| houstn | `louislam/uptime-kuma` | `1.23.17` *(held on 1.x)* |
| houstn | `ghcr.io/gethomepage/homepage` | `v1.13.2` |
| houstn | `nicolargo/glances` | `4.5.5-full` |
| snoot | `henrygd/beszel-agent` | `0.18.7` |

---

## Phase 0 — Recon and rollback anchors (read-only, do this first)

Run on **space-needle**. Nothing here changes state.

```bash
# What is actually running right now
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

# Music Assistant's real version (the tag says nothing)
sudo docker exec howlr python -c "import music_assistant; print(music_assistant.__version__)" 2>/dev/null \
  || curl -s http://localhost:8095/api/info | head -c 400

# Plex's real version
curl -s http://localhost:32400/identity | grep -o 'version="[^"]*"'

# Free space — Plex DB migrations and image pulls both need room
df -h /opt /mammoth /var/lib/docker
```

### Record the outgoing versions

Rollback is `git revert` now, so there is no need to re-tag images defensively.
But the *outgoing* versions still need writing down — they are what tells you
which breaking changes you are crossing (§1.1), and they are not recoverable
once the containers are recreated.

```bash
# Record what the pinned images are replacing
sudo docker image inspect ghcr.io/music-assistant/server:latest --format '{{index .RepoDigests 0}}'
sudo docker image inspect plexinc/pms-docker:latest             --format '{{index .RepoDigests 0}}'
```

Fill these in before proceeding:

- howlr current digest: `___________________`  (version: `______`)
- pawpcorn current digest: `___________________`  (version: `______`)

---

## Phase 1 — Music Assistant (howlr)

**Blast radius:** space-needle (`server` profile), calavera and viking
(`client` profile / snapclient), the calavera touchscreen kiosk, and
`loft-dashboard-power`.

### 1.1 Know which upgrade you are doing

`latest` is currently **2.9.x** (2.9.9 at time of writing; 2.10 is nightly-only).
What breaks depends entirely on the version Phase 0 reported:

| If currently running | You cross | Consequence |
|---|---|---|
| ≥ 2.8.0 | nothing structural | Low risk. Routine pull. |
| 2.7.x | 2.8.0 | Multi-protocol players merged into one player. Player IDs can change. |
| < 2.7.0 | **2.7.0 + 2.8.0** | **Mandatory authentication** *plus* the player merge. High risk — read 1.2. |

### 1.2 The two breaking changes, and what they do to *this* setup

**2.7.0 — mandatory webserver authentication.** Not optional, cannot be
disabled. First startup shows a screen to create an admin account; every direct
client must log in from then on. For this fleet that means:

- **The calavera kiosk will land on a login screen.** `I3_DASHBOARD_URL` points
  Firefox at `https://howlr.loft.hsimah.com/#/home?player=calavera&...`. This
  needs a **one-time manual login at the Surface touchscreen** after the
  upgrade. Good news: the kiosk uses a dedicated persistent profile
  (`/home/rodnik/.local/share/loft-dashboard-firefox`, `hosts/calavera/bootstrap`)
  and writes no clear-on-shutdown prefs, so the session should survive reboots.
  Budget for physically walking to the panel and typing a password once.
- **`loft-dashboard-power` is unaffected** — it reads snapserver's JSON-RPC on
  port 1780, not MA's API, so it never authenticates. This was the right call
  and it pays off here.
- **The health check will go falsely green.** `[howlr:local]="http://localhost:8095"`
  only asserts a non-`000` HTTP code, and a login page returns 200. `loft-ctl health`
  will pass on a completely unusable Music Assistant. Do not trust it as the
  gate for this service — use the manual checklist in 1.5.

**2.8.0 — players supporting multiple protocols are merged into one player.**
Player identities can change. Two things here depend on stable IDs:

- `I3_DASHBOARD_URL` contains `player=calavera`.
- `I3_POWER_GROUPS="syncgroupbkmvcshl,syncgroupzewbtz9n"` — these are MA sync
  group queue IDs, which `loft-dashboard-power` matches against snapserver
  stream names as `Music Assistant - <id>`. **If MA regenerates the sync
  groups, the dashboard screen stops waking on playback.** Verifying and
  possibly re-deriving these IDs is a mandatory post-upgrade step (1.5).

### 1.3 Backup

```bash
sudo systemctl stop docker 2>/dev/null; true   # not required, but quiesces writes
sudo tar czf /mammoth/backups/howlr-$(date +%F).tar.gz -C /opt howlr
ls -lh /mammoth/backups/howlr-*.tar.gz
```

(Create `/mammoth/backups` first if it doesn't exist. `/opt/howlr` is small —
this is fast and cheap, do not skip it.)

### 1.4 Upgrade — server first, then clients

Pull *before* rebuilding to cut the downtime window. `loft-ctl rebuild` takes
the service `down` before it pulls, so an un-primed pull means the music is off
for the whole download.

On **space-needle**:

```bash
# Warm the image while the current one is still serving
sudo docker compose -f /opt/the-loft/services/howlr/docker-compose.yml pull

loft-ctl update howlr
```

Then, **only once the server is verified** (1.5), the snapclients on
**calavera** and **viking**:

```bash
loft-ctl update howlr
```

The snapclient image (`ivdata/snapclient`) is a thin wrapper and low risk, but
there is no reason to move it in the same window as the server.

### 1.5 Verification checklist — do not skip, `loft-ctl health` is not sufficient

- [ ] `sudo docker logs howlr --tail 100` — no repeated tracebacks or restart loops
- [ ] Web UI loads at `https://howlr.loft.hsimah.com` (create the admin account if 2.7+ prompts)
- [ ] Music library is intact — providers still authenticated, tracks browsable
- [ ] **Play audio to the Downstairs group** and confirm sound out of the actual speakers
- [ ] **Play to the All group**
- [ ] `curl -s http://localhost:1780/jsonrpc ...` or the snapweb UI at
      `https://snapweb.loft.hsimah.com` — confirm stream names still read
      `Music Assistant - syncgroupbkmvcshl` and `Music Assistant - syncgroupzewbtz9n`.
      **If the IDs changed, update `I3_POWER_GROUPS` in `hosts/calavera/host.conf`
      and re-run `setup.sh` on calavera.**
- [ ] On calavera: the kiosk shows the now-playing view, not a login screen or
      a blank manual-entry screen
- [ ] On calavera: start playback → the touchscreen wakes
      (`journalctl -u loft-dashboard-power -n 50`)
- [ ] `loft-ctl health howlr` passes (necessary, not sufficient)

### 1.6 Rollback

Set the `howlr` image tag back to the version Phase 0 recorded, commit, then:

```bash
loft-ctl update howlr
```

If MA has already migrated its data store to a newer schema, the image rollback
alone will not be enough — restore `/opt/howlr` from the 1.3 tarball as well:

```bash
sudo docker compose -f .../howlr/docker-compose.yml down
sudo rm -rf /opt/howlr && sudo tar xzf /mammoth/backups/howlr-<date>.tar.gz -C /opt
sudo docker compose -f .../howlr/docker-compose.yml up -d
```

**Stop here.** Do not start Phase 2 until Music Assistant has been playing
music correctly for at least a day.

---

## Phase 2 — Plex (pawpcorn)

Much lower risk than howlr: single container, no auth model change, no
fleet-wide dependencies. The one real hazard is the **library database
migration**, which runs automatically on first start of a newer server and has
no built-in rollback.

`latest` is currently around **1.43.x**.

### 2.1 Backup the database specifically

The full config dir is large (thumbnails, metadata); the database is what
actually matters and is small enough to copy quickly.

```bash
sudo docker stop pawpcorn

sudo tar czf /mammoth/backups/plex-db-$(date +%F).tar.gz \
  -C "/opt/pawpcorn/config/Library/Application Support/Plex Media Server" \
  "Plug-in Support/Databases"

ls -lh /mammoth/backups/plex-db-*.tar.gz
```

Plex also keeps its own nightly `.db-*` backups inside that Databases folder —
confirm a recent one exists as a second line of defence.

### 2.2 Upgrade

```bash
sudo docker compose -f /opt/the-loft/services/pawpcorn/docker-compose.yml pull
loft-ctl update pawpcorn
```

First start after a version jump can sit "starting" for several minutes while
it migrates. **Do not interrupt it** — a half-migrated Plex database is the one
genuinely painful failure mode here. Watch it:

```bash
sudo docker logs pawpcorn -f
```

### 2.3 Verification checklist

- [ ] `https://pawpcorn.loft.hsimah.com` loads and you can sign in
- [ ] All libraries present with correct item counts (Movies, TV, Music, Videos, Stand Up)
- [ ] Play a file — **direct play**
- [ ] Play a file that forces a **transcode**, and confirm hardware transcoding
      still engages (`/dev/dri` passthrough + the `render`/`video` groups from
      `LITTLEDOG_EXTRA_GROUPS`). HW transcode is the most common casualty of a
      Plex container update.
- [ ] Remote access still reports reachable in Settings → Remote Access
- [ ] `loft-ctl health pawpcorn` passes

### 2.4 Rollback

Set the `pawpcorn` image tag back to the version Phase 0 recorded and commit.
Then, because the migration is not reversible, restore the database too:

```bash
sudo docker compose -f .../pawpcorn/docker-compose.yml down
sudo tar xzf /mammoth/backups/plex-db-<date>.tar.gz \
  -C "/opt/pawpcorn/config/Library/Application Support/Plex Media Server"
loft-ctl update pawpcorn
```

---

## Phase 3 — Stellarr (only after 1 and 2 are stable)

Deliberately last. It has the most moving parts and the least urgency.

**The main landmine is `ghcr.io/bubuntux/nordvpn`** — that project is
effectively unmaintained. Before pulling, check whether the image still
publishes and still works with current NordVPN infrastructure; a dead VPN
container is the most likely way this phase breaks.

Mitigating factor worth knowing: only `transmission` and `slskd` sit behind it
(`network_mode: service:vpn`). `radarr`, `sonarr`, `lidarr`, `bazarr` and
`jackett` are bridged and reached via Caddy, so a VPN failure costs you
downloads, not the whole stack. That is also why those two are already
`SERVICE_ENDPOINTS_WARN` entries.

Suggested order within the phase:

1. The bridged *arrs first (`radarr`, `sonarr`, `bazarr`, `jackett`) — safe,
   independent, each does its own config migration on start.
2. `lidarr` — **the one image left unpinned, deliberately.** It tracks
   `nightly`, whose database schema is ahead of stable (`3.1.0.4875-ls36`).
   Pinning to stable would be a downgrade, and Lidarr refuses to open a
   database written by a newer build — it would fail to start. Resolve it by
   pinning to the nightly build *currently running*:

   ```bash
   sudo docker inspect lidarr --format '{{index .Config.Labels "build_version"}}'
   ```

   then write that exact tag into the compose file. Moving to the stable line
   at all means exporting the library and rebuilding the database — a separate
   project, not part of this upgrade.
3. `stellarr-vpn`, then `transmission` + `slskd` together, since the latter two
   share its network namespace and must be recreated with it.

Back up the *arr config dirs (`/opt/{radarr,sonarr,lidarr,bazarr,jackett}`)
before this phase — same pattern as 1.3.

---

## Phase 4 — Everything else

Low risk, batchable once the above is settled.

| Service | Notes |
|---|---|
| `houstn` | beszel `0.18.7` / uptime-kuma `1.23.17` / homepage `v1.13.2` / glances `4.5.5-full`. Upgrade the beszel **hub** before the `snoot` agents. Kuma is held on 1.x on purpose — 2.x is a separate migration. |
| `snoot` | beszel-agent, fleet-wide (all four hosts). Upgrade after the hub. |
| `mushr` | **Upgrade last and carefully** — Caddy + cloudflared + dnsmasq *is* the ingress and LAN DNS for everything. If it breaks, every `*.loft.hsimah.com` and `*.space-needle` URL goes with it, including the calavera kiosk. Have console access, not just SSH-over-hostname. |
| `pupyrus` | WordPress `7.0.2-php8.5-apache` (a PHP 8.5 jump — check plugin compatibility), MariaDB held on `12.2.2`, Redis held on `7.4.10`. Take a DB dump via `pupyrus-cli` before touching it. |
| `pawst` | `nginx:1.30.4-alpine`, static content. Trivial. |

---

## Follow-ups for the repo (not blocking the upgrade)

1. ~~**Pin the critical images.**~~ Done — every image except `lidarr` is now
   pinned in git. See README → "Image pinning" and Phase 3 for lidarr.
2. **Replace two dead upstreams.** `ivdata/snapclient` has published nothing
   since 2023 and has no version tags (pinned by digest); `bubuntux/nordvpn`
   is an archived repo whose final tag is `v3.12.3`. Both work today, neither
   will ever be patched.
3. **`DEBUG.md` is stale.** Its container table lists howlr as
   `howlr-snapserver`, `howlr-shairport-sync`, `howlr-librespot`,
   `howlr-snapclient`. The compose file actually defines `howlr`
   (music-assistant, `server` profile) and `howlr-snapclient` (`client`
   profile). Fix while howlr is fresh in mind.
4. **The howlr health check is too weak.** `http://localhost:8095` returning
   200 does not mean MA works — post-2.7 a login page satisfies it. Consider
   checking an API endpoint that reflects real readiness.
5. `loft-ctl rebuild` takes the service `down` *before* pulling, maximising
   downtime. A `pull`-then-`down`-then-`up` ordering would shrink the outage
   window for large images.
