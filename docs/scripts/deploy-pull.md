# `control-plane/deploy-pull.sh`

> Hourly puller — fetches the latest GitHub Release for a repo and atomically swaps its `.tar.gz` into a bind-mounted target directory.

## Overview

[`deploy-pull.sh`](../../control-plane/deploy-pull.sh) replaces the "self-hosted GitHub Actions runner with `docker.sock` mounted" pattern for static-site deploys. Each app repo's CI runs on stock `ubuntu-latest`, builds an artifact, and attaches it as a `.tar.gz` to a tagged Release. On space-needle, cron runs `deploy-pull.sh` every hour per `DEPLOY_TARGETS` entry; new releases are downloaded and swapped into place. No CI runner on the host, no docker socket exposure, no inbound webhook.

The primary consumer is [pawst](../services/pawst.md) — both `hbla.ke` and `hsimah.com` are pulled this way from their respective `hsimah-services/*` repos.

## Architecture

### Flow per invocation

```
cron → deploy-pull.sh <name> <repo> <target_dir> [post_hook]
         │
         ├── (best-effort) github-app-token.sh → bearer token
         │
         ├── GET /repos/<repo>/releases/latest
         │     └── extract .tag_name + .assets[].url where name endswith ".tar.gz"
         │
         ├── compare tag to /var/lib/loft/deploy/<name>.version
         │     └── same? → log "Already at <tag>" → exit 0
         │
         ├── curl asset → /tmp/<tarball>
         │
         ├── extract to <target_dir>/../.<basename>.deploy.<rand>/  (sibling on same fs)
         │     └── unwrap single top-level dir if present
         │     └── chown littledog:pack-member, chmod u=rwX,go=rX
         │
         ├── ATOMIC SWAP:
         │     mv <target_dir>            → <parent>/.<basename>.old.<epoch>
         │     mv <staging>                → <target_dir>
         │     rm -rf <old>
         │
         ├── echo <tag> > /var/lib/loft/deploy/<name>.version
         │
         └── (optional) post_hook executed with cwd = <target_dir>
```

### Arguments

| # | Name | Required | Example |
|---|------|----------|---------|
| 1 | `name` | yes | `pawst-hblake` |
| 2 | `repo` | yes | `hsimah-services/hblake` |
| 3 | `target_dir` | yes | `/opt/pawst/hblake-html` |
| 4 | `post_hook` | no | `wp cache flush` (or empty string) |

`name` is the unique identifier — it's the state-file key and the cron filename suffix. `repo` is `owner/repo`. `target_dir` is the bind-mounted directory the service reads from. `post_hook` runs `bash -c "<hook>"` from inside the new target directory; the hook is allowed to fail (non-zero exits log a warning, don't break the deploy).

### State files

| Path | Purpose |
|------|---------|
| `/var/lib/loft/deploy/<name>.version` | Last successfully deployed tag (one line, e.g. `v1.4.2`) |
| `/var/log/loft/deploy.log` | All cron-invoked output (stdout + stderr), prefixed with `[deploy:<name>]` |
| `<parent>/.<basename>.deploy.XXXXXX/` | Transient staging directory during swap |
| `<parent>/.<basename>.old.<epoch>/` | Transient previous-deploy backup (removed after successful swap) |

The `.deploy.XXXXXX` and `.old.<epoch>` paths live as siblings of the target so the `mv` is on the same filesystem — `mv` between filesystems is a copy, not atomic. Both are deleted at the end of a happy path. After a crash mid-swap, the script will leave one behind; safe to remove manually.

### Auth

`deploy-pull.sh` calls [`github-app-token.sh`](github-app-token.md) which sources `/etc/loft/deploy.env`. If the env file exists with valid credentials, a fresh installation token is minted per run and used as `Authorization: Bearer <token>` for both the metadata fetch and the asset download. If credentials are absent (or the script exits non-zero for any reason), `deploy-pull.sh` falls back to unauthenticated requests. So:

| Repo visibility | Auth file | Result |
|----------------|-----------|--------|
| Public | absent | Works (rate-limited to 60 req/h per IP, fine for hourly polls) |
| Public | present | Works (5000 req/h authenticated) |
| Private | absent | Fails — 404 on releases endpoint |
| Private | present | Works |

## Configuration

### Per-host: `DEPLOY_TARGETS` in `host.conf`

Each entry is a pipe-delimited string installed by [`setup.sh`](setup.md#configuration) into `/etc/cron.d/loft-deploy-<safe_name>`:

```bash
DEPLOY_TARGETS=(
  "pawst-hblake|hsimah-services/hblake|/opt/pawst/hblake-html|"
  "pawst-hsimah|hsimah-services/hsimah|/opt/pawst/hsimah-html|"
)
```

Format: `name|owner/repo|target_dir|optional_post_hook`. The fourth field can be empty (trailing `|`) or carry a shell snippet. The `name` is sanitized for the cron filename (`[^a-zA-Z0-9-]` → `-`).

Re-run `sudo bash setup.sh` after editing `DEPLOY_TARGETS` — phase 12 of `setup.sh` clears `/etc/cron.d/loft-deploy-*` and reinstalls from the current array, so removed entries stop being scheduled.

### `target_dir` ownership

The target dir must:

- Exist (or its parent must — `deploy-pull.sh` does `mkdir -p` on the parent only)
- Be writable by root (cron runs as root, so this is automatic)
- Live on the same filesystem as its parent (so the atomic swap is one inode rename)

The safest pattern is to add the directory to `CONFIG_DIRS` in `host.conf` so `setup.sh` creates it as `littledog:pack-member` 755 before the first deploy. `deploy-pull.sh` re-chowns the staging tree to `littledog:pack-member` before swap, so the post-swap ownership is consistent.

### `/etc/loft/deploy.env` (private repos only)

Required keys:

| Variable | Value |
|----------|-------|
| `LOFT_DEPLOY_APP_ID` | GitHub App ID |
| `LOFT_DEPLOY_INSTALLATION_ID` | Installation ID for the org/account |
| `LOFT_DEPLOY_KEY_PATH` | Absolute path to App private key PEM |

See [`github-app-token.sh`](github-app-token.md) for one-time setup. The env file and PEM should both be `chmod 600`, owned by root.

### Release contract (consumed by `deploy-pull.sh`)

Each repo's CI must publish a release with **at least one `.tar.gz` asset**. The first asset whose name ends in `.tar.gz` is used. The tarball can be either flat (files at root) or have a single top-level wrapper directory — the script unwraps the latter automatically. Draft releases are skipped (the `/releases/latest` endpoint ignores drafts).

Minimal `.github/workflows/release.yml` in an app repo:

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

## Operations

```bash
# Force a deploy without waiting for cron
sudo /srv/the-loft/control-plane/deploy-pull.sh \
  pawst-hblake hsimah-services/hblake /opt/pawst/hblake-html

# Inspect cron entries
ls /etc/cron.d/loft-deploy-*
cat /etc/cron.d/loft-deploy-pawst-hblake

# Tail the log (all targets, all hosts)
sudo tail -f /var/log/loft/deploy.log

# Check last-deployed tag
sudo cat /var/lib/loft/deploy/pawst-hblake.version
```

### Adding a new deploy target

1. Add a row to `DEPLOY_TARGETS` in `hosts/<hostname>/host.conf`.
2. Add the target dir to `CONFIG_DIRS` (if not already a bind mount that exists).
3. `sudo bash setup.sh` — reinstalls the cron files and creates the dir.
4. Tag and publish a release in the app repo so the first run has something to fetch.

### Re-deploying the current tag (force)

The script exits early when `tag == LAST_TAG`. To force a redeploy of the same tag:

```bash
sudo rm /var/lib/loft/deploy/<name>.version
sudo /srv/the-loft/control-plane/deploy-pull.sh <name> <repo> <target_dir>
```

### Rolling back to a previous tag

`deploy-pull.sh` only pulls `releases/latest`. To roll back, either re-tag the older commit as the new latest in the app repo, or untag/delete the bad release on GitHub so `latest` resolves to the previous one — then `rm` the state file and re-run.

## Related

- [`github-app-token.sh`](github-app-token.md) — sourced for the auth bearer
- [`setup.sh`](setup.md) — installs the cron entries from `DEPLOY_TARGETS`
- [pawst](../services/pawst.md) — primary consumer (`hbla.ke` + `hsimah.com`)
- [space-needle](../hosts/space-needle.md) — the only host with `DEPLOY_TARGETS` configured today
- Root [`README.md`](../../README.md) — Pull-Based Deploys section

## Debug & Troubleshooting

### `Already at <tag>, nothing to do.` but I just pushed a new release

**Cause:** The release is a draft, has no `.tar.gz` asset, or the tag name didn't actually change (e.g. you re-published the same tag). `releases/latest` skips drafts entirely.

**Fix:**

```bash
# Confirm the latest release tag from GitHub's side
curl -fsS https://api.github.com/repos/<owner>/<repo>/releases/latest | jq -r '.tag_name, [.assets[].name]'

# If the response shows a draft or missing tarball, publish a real release.
# If a fresh tag exists but deploy-pull keeps reporting old:
sudo cat /var/lib/loft/deploy/<name>.version
```

### `No .tar.gz asset on release <tag>`

**Cause:** The release was created without the artifact attached. Common when `softprops/action-gh-release` was disabled or the artifact step failed.

**Fix:** Re-run the failing job in the app repo, or attach the tarball manually to the release. Then re-run `deploy-pull.sh`.

### `Failed to query latest release for <repo>` on a private repo

**Cause:** Auth credentials missing or the GitHub App installation doesn't include the repo with `Contents: Read`.

**Fix:**

```bash
ls -l /etc/loft/deploy.env /etc/loft/loft-deploy-app.pem
sudo /srv/the-loft/control-plane/github-app-token.sh    # should print a token

# Confirm the App installation has access to the repo:
# https://github.com/organizations/<org>/settings/installations
# → Configure → Repository access → must include the deploy target repo
```

See [`github-app-token.sh`](github-app-token.md#debug--troubleshooting) for setup-side issues.

### Post-deploy hook logs `WARNING: post-deploy hook exited non-zero` but the deploy itself succeeded

**Cause:** The hook returned non-zero — that's logged but doesn't unwind the deploy. The file tree is already swapped in.

**Fix:** Read the log for the hook's stderr (it's interleaved with `[deploy:<name>]` lines), fix the hook, optionally re-run by deleting the state file and re-invoking.

### Stale `.<basename>.deploy.XXXXXX` or `.<basename>.old.<epoch>` directory

**Cause:** A previous run crashed (host reboot, OOM, `kill -9`) mid-swap.

**Fix:** Safe to `rm -rf` either one. Re-run `deploy-pull.sh` afterwards to ensure the target is consistent:

```bash
sudo ls -la <parent>
sudo rm -rf <parent>/.<basename>.{deploy.*,old.*}
sudo /srv/the-loft/control-plane/deploy-pull.sh <name> <repo> <target>
```

### `tar extract failed`

**Cause:** Corrupt download (network blip), an asset that's not actually a `.tar.gz` (e.g. someone uploaded a `.zip` with the wrong extension), or a tarball larger than `/tmp` has free space.

**Fix:**

```bash
df -h /tmp
# Try downloading by hand to inspect
TOKEN=$(sudo /srv/the-loft/control-plane/github-app-token.sh)
curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
  "<asset-url>" -o /tmp/probe.tar.gz
file /tmp/probe.tar.gz
```

### Atomic swap fails with `Device or resource busy`

**Cause:** Another process has the target dir as its cwd or has a file open inside it. Rare with web servers that re-open files per request (Nginx, Caddy); more common with `tail -f`, a hung shell, or a misconfigured service that long-holds open handles.

**Fix:**

```bash
sudo lsof +D <target_dir>
# Kill the holder or restart the consuming service
loft-ctl rebuild <consuming-service>
```

### Permission denied serving the new content

**Cause:** The pre-swap chown was suppressed (`chown … 2>/dev/null || true`) — if `littledog` doesn't exist on the host (forgot to run `setup.sh`), the chown silently fails and files end up root-owned. Nginx as `littledog` then can't read them.

**Fix:**

```bash
id littledog                          # confirm the user exists
sudo chown -R littledog:pack-member <target_dir>
loft-ctl rebuild <consuming-service>  # or just: sudo docker restart <container>
```
