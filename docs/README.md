# `the-loft` docs

Per-thing deep-dive pages. The root [`README.md`](../README.md) is the index — start there for a fleet overview, then jump in here for the details on a specific host, service, or script.

Every page follows [`_template.md`](_template.md): Overview · Architecture · Configuration · Operations · Related · Debug & Troubleshooting.

## Hosts

| Host | Hardware | Role |
|------|----------|------|
| [space-needle](hosts/space-needle.md) | Minisforum MS-01 (i9, x86_64) | Primary server — runs everything |
| [viking](hosts/viking.md) | Raspberry Pi 3 B+ (arm64) | Snapcast client + per-host metrics |
| [fjord](hosts/fjord.md) | Raspberry Pi 3 B+ (arm64) | Snapcast client + per-host metrics |
| [calavera](hosts/calavera.md) | Surface Pro 2 (x86_64, touchscreen) | Vinyl kiosk + audio capture |

## Services

| Service | Purpose |
|---------|---------|
| [houstn](services/houstn.md) | Fleet observability — Beszel hub, Uptime Kuma, Homepage, per-host Glances |
| [howlr](services/howlr.md) | Music Assistant + Snapcast — whole-home audio |
| [mushr](services/mushr.md) | Caddy reverse proxy + Cloudflare Tunnel + LAN DNS |
| [pawpcorn](services/pawpcorn.md) | Plex Media Server |
| [pawst](services/pawst.md) | Static blogs `hbla.ke` and `hsimah.com` |
| [pupyrus](services/pupyrus.md) | WordPress (+ MariaDB + Redis) |
| [snoot](services/snoot.md) | Beszel agent on every host |
| [spinnik](services/spinnik.md) | Vinyl turntable streamer — DarkIce + Icecast + UI on calavera |
| [stellarr](services/stellarr.md) | *arr stack + Transmission + slskd, all behind NordVPN |

## Scripts

Script pages will land under `scripts/` as the rest of #66 lands.
