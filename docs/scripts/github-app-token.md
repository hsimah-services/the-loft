# `control-plane/github-app-token.sh`

> Mint a short-lived GitHub App installation token from a private key — the auth backbone for [`deploy-pull.sh`](deploy-pull.md) when pulling private repos.

## Overview

[`github-app-token.sh`](../../control-plane/github-app-token.sh) generates a fresh GitHub App installation access token on demand and prints it on stdout. The token is valid for ~1 hour and is what [`deploy-pull.sh`](deploy-pull.md) uses as `Authorization: Bearer <token>` when fetching release metadata and asset bytes. The script is a single shell file that builds an RS256-signed JWT and exchanges it via `POST /app/installations/<id>/access_tokens` — no `gh` CLI, no other deps beyond `openssl`, `curl`, and `jq`.

Auth is **opt-in**. If `/etc/loft/deploy.env` is missing or incomplete, the script returns non-zero and the caller (`deploy-pull.sh`) falls back to unauthenticated requests. This makes public-repo deploys work out of the box without any GitHub App setup.

## Architecture

### Flow per invocation

```
1. Source $LOFT_DEPLOY_ENV (default: /etc/loft/deploy.env)
2. Validate LOFT_DEPLOY_APP_ID / LOFT_DEPLOY_INSTALLATION_ID / LOFT_DEPLOY_KEY_PATH
3. Build a JWT:
     header  = {"alg":"RS256","typ":"JWT"}
     payload = {"iat":<now-60>, "exp":<now+600>, "iss":"<app id>"}
     signature = RS256(<header.payload>, <private key>)
4. POST https://api.github.com/app/installations/<id>/access_tokens
     Header: Authorization: Bearer <jwt>
5. Print .token from the response on stdout
```

The 60-second clock skew on `iat` is the GitHub-recommended buffer — without it, hosts whose clock is even slightly ahead get `'iat' claim timestamp must be in the past`.

### Output contract

- **Success:** Token printed on stdout, no newline. Exit 0.
- **Credentials unset / partial:** Exits 1 quickly, no error message printed (deliberately silent — `deploy-pull.sh` treats this as "no auth available" and falls back).
- **Key file missing:** Prints `ERROR: GitHub App key not found at <path>` on stderr, exits 1.
- **GitHub API rejects:** Prints `ERROR: Failed to obtain installation token: <response>` on stderr, exits 1. The raw API response is included so you can read the `message` field.

The silent-on-missing-credentials behavior is intentional: `deploy-pull.sh` uses `if TOKEN="$(github-app-token.sh 2>/dev/null)"; then …` to make auth optional. A noisy "credentials missing" message would clutter the deploy log on every public-repo run.

## Configuration

### `/etc/loft/deploy.env` (sourced)

| Variable | Purpose |
|----------|---------|
| `LOFT_DEPLOY_APP_ID` | GitHub App ID (numeric, from the App's settings page) |
| `LOFT_DEPLOY_INSTALLATION_ID` | Installation ID for the org/account (from the install URL: `/installations/<id>`) |
| `LOFT_DEPLOY_KEY_PATH` | Absolute path to the private key PEM (typically `/etc/loft/loft-deploy-app.pem`) |

All three must be set. Missing any one → silent exit 1.

`LOFT_DEPLOY_ENV` can override the source path (e.g. for testing); defaults to `/etc/loft/deploy.env`.

### File permissions

Both files should be locked down — they grant Contents: Read on whichever repos the App is installed into:

```bash
sudo chmod 600 /etc/loft/deploy.env /etc/loft/loft-deploy-app.pem
sudo chown root:root /etc/loft/deploy.env /etc/loft/loft-deploy-app.pem
```

### GitHub App setup (one-time)

1. Go to `https://github.com/organizations/<org>/settings/apps/new` (or the user-level equivalent).
2. **Webhook:** Uncheck (no webhooks needed — this is a pull-based deploy).
3. **Repository permissions:** `Contents: Read` (and nothing else — least privilege).
4. **Where can this App be installed?** Only on this account.
5. Save → note the **App ID** at the top of the settings page.
6. Scroll to "Private keys" → **Generate a private key** → downloads a `.pem`.
7. Install the App → **Only select repositories** → tick each repo `deploy-pull.sh` should fetch from.
8. After install, copy the **Installation ID** from the URL: `https://github.com/organizations/<org>/settings/installations/<this number>`.

Then on the deploying host:

```bash
sudo mkdir -p /etc/loft
sudo cp ~/Downloads/<app>.<date>.private-key.pem /etc/loft/loft-deploy-app.pem
sudo chmod 600 /etc/loft/loft-deploy-app.pem
sudo tee /etc/loft/deploy.env >/dev/null <<'EOF'
LOFT_DEPLOY_APP_ID=<app id>
LOFT_DEPLOY_INSTALLATION_ID=<installation id>
LOFT_DEPLOY_KEY_PATH=/etc/loft/loft-deploy-app.pem
EOF
sudo chmod 600 /etc/loft/deploy.env

# Smoke test
sudo /srv/the-loft/control-plane/github-app-token.sh && echo
```

Successful output is a long opaque string starting with `ghs_…` (or similar). Failure prints an error to stderr or exits silently if credentials are missing.

## Operations

```bash
# Mint a token by hand (e.g. for ad-hoc curl probes against private repo releases)
TOKEN="$(sudo /srv/the-loft/control-plane/github-app-token.sh)"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/<owner>/<repo>/releases/latest | jq .

# Verify auth without exposing the token
TOKEN="$(sudo /srv/the-loft/control-plane/github-app-token.sh)" && \
  curl -fsS -H "Authorization: Bearer $TOKEN" \
       -H "Accept: application/vnd.github+json" \
       https://api.github.com/installation/repositories | jq -r '.repositories[].full_name'
```

Tokens expire after ~1 hour. The script mints a new one every time — there's no caching, since cron-driven `deploy-pull.sh` runs hourly anyway. If you script around it, mint fresh each call rather than reusing.

### Rotating the private key

1. In the App's settings, **Generate a new private key**.
2. Replace `/etc/loft/loft-deploy-app.pem` on each host that uses it (currently only space-needle).
3. **Revoke the old key** in the App settings.
4. Run the script once by hand to confirm the new key works.

The App ID and Installation ID don't change during key rotation — only the PEM file.

## Related

- [`deploy-pull.sh`](deploy-pull.md) — the sole consumer; calls this as `if TOKEN="$(github-app-token.sh 2>/dev/null)"; then …`
- [space-needle](../hosts/space-needle.md) — the host that runs the deploy pullers
- Root [`README.md`](../../README.md) — Authenticating Private Repos section
- GitHub docs — [Authenticating as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)

## Debug & Troubleshooting

### Script exits silently with no output

**Cause:** `/etc/loft/deploy.env` is missing or one of the three required vars is empty. This is the script's "no credentials → bail quietly" path so callers can fall back to anonymous requests.

**Fix:** If you intended to be authenticated, populate the env file (see Configuration). If you intended this to be anonymous (public repo deploy), nothing's broken — `deploy-pull.sh` handles the non-zero exit and continues without auth.

```bash
sudo cat /etc/loft/deploy.env       # exists and complete?
sudo ls -l /etc/loft/loft-deploy-app.pem
```

### `ERROR: GitHub App key not found at <path>`

**Cause:** `LOFT_DEPLOY_KEY_PATH` points at a file that doesn't exist (or that root can't read).

**Fix:** Confirm the path is absolute and matches the actual PEM location:

```bash
sudo ls -l "$(sudo bash -c 'source /etc/loft/deploy.env && echo $LOFT_DEPLOY_KEY_PATH')"
```

### `ERROR: Failed to obtain installation token: {"message":"'iat' claim timestamp must be in the past"...}`

**Cause:** Host clock is ahead of GitHub's clock by more than ~60s.

**Fix:**

```bash
timedatectl status                  # check NTP sync
sudo timedatectl set-ntp true       # re-enable if disabled
```

### `ERROR: Failed to obtain installation token: {"message":"Bad credentials"...}`

**Cause:** The App ID is wrong, or the PEM doesn't match the App (e.g. an old key after rotation that you forgot to revoke and replace), or the App was deleted.

**Fix:**

```bash
# Verify the App ID matches the PEM
openssl rsa -in /etc/loft/loft-deploy-app.pem -pubout -outform DER 2>/dev/null | sha256sum
# Compare with the public key shown in the App's settings page under "Private keys"
```

If keys don't match, regenerate per the rotation procedure above.

### `ERROR: Failed to obtain installation token: {"message":"Not Found"...}`

**Cause:** `LOFT_DEPLOY_INSTALLATION_ID` is wrong, or the App is no longer installed for that account/org.

**Fix:**

```bash
# List installations for this App (use a JWT, not an installation token)
APP_ID="$(sudo bash -c 'source /etc/loft/deploy.env && echo $LOFT_DEPLOY_APP_ID')"
# Reconfirm the Installation ID from
#   https://github.com/organizations/<org>/settings/installations
```

### Token works but `deploy-pull.sh` still 404s on `releases/latest`

**Cause:** The App is installed for the org but **doesn't include the target repo** in its Repository access list. The App's permissions are global; the install's repo selection is what gates which repos the token can read.

**Fix:**

- Org settings → Installed GitHub Apps → the loft-deploy App → **Configure** → **Repository access** → add the missing repo (or switch to "All repositories").

### `jq: error: Cannot iterate over null`

**Cause:** GitHub returned an error object instead of `.token`. The error message extraction (`.token // empty`) caught it, the script's own check (`[[ -z "$token" || "$token" == "null" ]]`) flags it, and the raw response is printed on stderr. Read that response for the actual problem (usually one of the cases above).

### Permission denied reading the PEM

**Cause:** Running the script as a non-root user. The PEM is `chmod 600 root:root`; only root can read it.

**Fix:** Either invoke the script with `sudo` (cron runs as root, so cron-driven calls are fine), or relax permissions to `root:adminhabl 640` if you need `adminhabl` to mint tokens directly. The repo's default is "root only" because cron is the only legitimate caller.
