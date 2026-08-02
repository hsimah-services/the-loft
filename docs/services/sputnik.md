# `sputnik`

> Local open-weights LLM engine plus two assistant surfaces — a chat UI and a workflow runner — used to read and summarise Gmail and Google Calendar without sending any of it to a third-party model provider.

## Overview

`sputnik` runs a quantised open-weights model on [space-needle](../hosts/space-needle.md) via Ollama, and exposes it through two consumers: **Open WebUI** for conversational queries and **n8n** for scheduled work (morning inbox triage, calendar briefings, thread summaries). Google account access is held by n8n as an OAuth credential, scoped read-only.

The name is the obvious one: *sputnik* is Russian for "travelling companion", it was the first satellite, and Laika followed on Sputnik 2 — so it lands on both the space and dog theme pools, and "companion" is literally the job.

This is the fleet's first genuinely compute-hungry service. Unlike Plex, which offloads to QuickSync, inference here is memory-bandwidth-bound on the CPU and will compete with everything else on the box. See [Performance](#performance) before assuming a model size.

## Architecture

### Containers

`sputnik` is a **bundle** — three independent products under one umbrella name, like [houstn](houstn.md) and [stellarr](stellarr.md) — so each container is named for its own product rather than prefixed. Compose profiles select which run:

| Profile | Container | Image | Purpose |
|---------|-----------|-------|---------|
| `engine` | `ollama` | `ollama/ollama:0.32.5` | Inference server, OpenAI-compatible API + native tool calling |
| `chat` | `open-webui` | `ghcr.io/open-webui/open-webui:0.11.0` | Conversational UI |
| `agent` | `n8n` | `n8nio/n8n:2.32.7` | Scheduled workflows, holds the Google credential |

space-needle runs `COMPOSE_PROFILES=engine,chat,agent`. No other host runs sputnik — the Pi hosts ([viking](../hosts/viking.md), [fjord](../hosts/fjord.md), [calavera](../hosts/calavera.md)) cannot serve a model of any useful size.

```
                    ┌──────────────┐
  browser (LAN) ───▶│    Caddy     │──▶ sputnik.loft.hsimah.com ──▶ open-webui:8080
                    │   (mushr)    │──▶ n8n.loft.hsimah.com     ──▶ n8n:5678
                    └──────────────┘
                                              │            │
                                              └────┬───────┘
                                                   ▼
                                            ollama:11434
                                        (loft-proxy bridge +
                                         127.0.0.1 on the host)
                                                   │
                                                   ▼
                                      /mammoth/sputnik/models
```

### Why Ollama is not proxied

**Ollama has no authentication whatsoever.** Anything that can reach port 11434 can run inference, pull arbitrary models, and delete existing ones. It is therefore deliberately absent from [mushr](mushr.md)'s Caddyfile and published only on `127.0.0.1:11434` for host-side health checks. Its only real consumers reach it as `http://ollama:11434` over the `loft-proxy` bridge.

If a future host needs remote inference, put it behind a Caddy route with `basic_auth` rather than exposing 11434 directly.

### Public exposure

Both HTTPS routes exist in the Caddyfile, but that alone does **not** publish them to the internet. mushr's Cloudflare Tunnel is remotely managed via `TUNNEL_TOKEN`, so a hostname is only reachable externally once it is added as a public hostname in the Cloudflare dashboard. Leave `sputnik` and `n8n` out of that list to keep them LAN-only — mushr's dnsmasq resolves `*.loft.hsimah.com` to `192.168.86.28`, so LAN browsers still get a real Let's Encrypt cert.

Keeping n8n off the tunnel is the recommended posture: it stores a live Google OAuth refresh token.

### Storage layout

```
/mammoth/sputnik/models        Ollama model blobs (~20 GB for a Q4 30B MoE)
/opt/sputnik/open-webui        Open WebUI SQLite DB, users, chat history
/opt/sputnik/n8n               n8n SQLite DB + encrypted credentials
```

Model weights live on `/mammoth` because they dwarf every other service's config; the two small SQLite databases stay on the root disk under `/opt` with everything else.

## Configuration

### `.env`

```bash
cp services/sputnik/.env.example services/sputnik/.env
```

| Variable | Purpose |
|----------|---------|
| `COMPOSE_PROFILES` | `engine,chat,agent` on space-needle |
| `LOFT_DOMAIN` | Must match `services/mushr/.env` — interpolated into the n8n and Open WebUI hostnames |
| `TZ` | `America/Los_Angeles`, as elsewhere in the fleet |
| `OLLAMA_CONTEXT_LENGTH` | Token window. `16384` fits tool schemas plus a mail thread; KV cache scales with it |
| `WEBUI_SECRET_KEY` | `openssl rand -hex 32`. Rotating it logs everyone out |
| `ENABLE_SIGNUP` | `true` to create the first admin account, then flip to `false` |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 32`. **Back this up** — see below |

> **`N8N_ENCRYPTION_KEY` is the one irreplaceable secret here.** n8n encrypts every stored credential with it, including the Google refresh token. Lose the key and `/opt/sputnik/n8n` becomes unreadable and every Google connection must be re-authorised from scratch.

### Google OAuth

The full click-path is documented inline in [`services/sputnik/.env.example`](../../services/sputnik/.env.example). The parts that catch people out:

1. **Publishing status must be "Production", not "Testing".** Google expires refresh tokens after 7 days while the consent screen is in Testing, so the assistant silently dies every week. Publishing shows an "unverified app" interstitial you click through as the developer; formal verification is only needed to distribute to other people.
2. **The redirect URI is exact** — `https://n8n.loft.hsimah.com/rest/oauth2-credential/callback`, HTTPS, no trailing slash. This is why `N8N_EDITOR_BASE_URL` and `WEBHOOK_URL` must both be the public HTTPS origin.
3. **The OAuth flow works LAN-only.** Google never fetches the redirect URI — your browser does. Complete the connection from a machine on the LAN and dnsmasq plus Caddy handle it locally.

### Scopes

Currently provisioned **read-only**:

```
https://www.googleapis.com/auth/gmail.readonly
https://www.googleapis.com/auth/calendar.readonly
```

An 8B-class model acting on the contents of an untrusted inbox is a live prompt-injection surface — a crafted email is user input that the model cannot reliably distinguish from your instructions. Read-only means the worst case is a wrong summary rather than a sent email or a deleted event.

The natural next step, once its drafts have been watched for a while, is `gmail.compose` — drafts land in the Drafts folder and still require a human to press send. Adding a scope requires re-running the OAuth consent flow.

### Assistant persona

The system prompt lives in [`services/sputnik/Modelfile.assistant`](../../services/sputnik/Modelfile.assistant) and is baked into a derived model rather than typed into a chat UI or a workflow's prompt field — that way both surfaces get the same guardrails and neither can quietly drop them:

```bash
sudo docker exec -i ollama ollama create sputnik-assistant \
  -f /dev/stdin < services/sputnik/Modelfile.assistant
```

Re-run after every edit; `ollama create` overwrites in place. Select `sputnik-assistant` (not the raw base model) in Open WebUI and in n8n's Ollama node.

Two things it encodes that matter more than tone:

- **It states the read-only limit as a fact about its access**, not a policy it is choosing to follow, so the model reports "I can't send that" instead of hallucinating a sent message.
- **It frames all mail content as untrusted data.** An inbox is attacker-reachable input; a message can contain text crafted to read as instructions. The prompt tells the model to treat anything inside a body, subject, or sender name as text to summarise and never as a command — and to flag it as a likely phishing signal when it sees one. This is mitigation, not a guarantee: a sufficiently clever injection can still land, which is the underlying reason the OAuth scopes are read-only.

The `FROM` line is the model selector — change it to whatever [`bench.sh`](#measuring-actual-throughput) recommends for the RAM in the box.

## Performance

space-needle is a Minisforum MS-01 with an **i9-12900H, 31 GB RAM (27 GB typically free), no discrete GPU** (measured 2026-08-01), so inference is CPU-bound and limited by memory bandwidth. Rough expectations at Q4 — but measure rather than trust these:

**Measured** on `qwen3:30b-a3b` at 12 threads with a ~2070-token prompt (2026-08-01):

| Metric | Value |
|--------|-------|
| Prefill | ~45 tok/s |
| Generation | ~14.5 tok/s |
| Time to first token | ~45 s |
| Resident RAM | ~20 GB of 31 GB |

The mixture-of-experts model is what makes this viable at all: 30B-class quality at roughly 8B-class speed, because only ~3B params activate per token. The dense 8B and 14B alternatives were not benchmarked here — the MoE fit in RAM, so there was no reason to.

**Prefill is the wall, and it does not respond to tuning.** Across 6, 12 and 20 threads it measured 45.3 / 46.6 / 45.1 tok/s — flat inside noise, while generation moved 33%. That is bandwidth-bound behaviour, so the ~45 s wait before the first token is not a configuration problem and no amount of thread tuning will shift it. Only faster memory will.

**Prefill is the real bottleneck, not generation.** An agent turn carrying tool schemas plus an email thread is 2–5k tokens of prompt processing at roughly 30–80 tok/s on CPU, so expect 30–60 seconds before the first token. This is why `OLLAMA_KEEP_ALIVE=-1` is set — the default 5-minute eviction would otherwise add a full cold model load to every idle cron tick. It is also why n8n (scheduled, latency-insensitive) is a better fit than Open WebUI (interactive) until there is a GPU in the box.

### Measuring actual throughput

[`services/sputnik/bench.sh`](../../services/sputnik/bench.sh) reports the two numbers that actually decide the GPU question, per installed model:

```bash
bash services/sputnik/bench.sh                 # every installed model
bash services/sputnik/bench.sh qwen3:30b-a3b   # one model
```

It needs only `curl` and `python3` — it talks to the Ollama API on loopback, so no docker and no sudo. It prints the host's CPU/RAM/GPU, recommends a base model for the memory actually available (not total — the model has to stay resident alongside Plex, the *arr stack, WordPress and Music Assistant), then warms each model and measures:

- **prefill tok/s** — prompt processing. Dominates agent-loop latency and is what a GPU improves most.
- **gen tok/s** — token generation. Below ~10 makes interactive chat unpleasant; largely irrelevant to a 7am cron job.
- **first tok** — the wait before any text appears.

Run it before buying a card, and again after, to make the comparison on data rather than estimates.

### Thread count on a hybrid CPU

The i9-12900H is 6 P-cores + 8 E-cores, so `nproc` reports 20 threads and Ollama will use all of them by default. That is usually the wrong choice: inference splits work evenly per thread, so the P-cores finish early and idle while the slower E-cores straggle, and every token waits on the slowest thread. Capping to the P-cores often wins despite using fewer cores.

`Modelfile.assistant` sets `PARAMETER num_thread 6`. Confirm it on this workload rather than trusting it — build three variants and bench them:

```bash
# 6 = P-cores, 12 = P-core threads, and Ollama's own default for comparison
for n in 6 12; do
  printf 'FROM qwen3:30b-a3b\nPARAMETER num_thread %s\n' "$n" \
    | sudo docker exec -i ollama ollama create "thr-$n" -f /dev/stdin
done
bash services/sputnik/bench.sh qwen3:30b-a3b thr-6 thr-12
```

Take the winner's value into `Modelfile.assistant`, rebuild `sputnik-assistant`, then clean up:

```bash
sudo docker exec -it ollama ollama rm thr-6 thr-12
```

### The GPU question is a VRAM-capacity question

The measurements make the case for a card — but capacity, not speed, is the binding constraint, and it is easy to buy the wrong thing.

`qwen3:30b-a3b` at Q4 is ~19 GB of weights plus ~1.5 GB of KV cache at 16k context. To run it **fully** on a GPU you need roughly 22–24 GB of VRAM. The MS-01's slot only takes half-height, low-profile cards, which caps the realistic options well below that:

| Card | VRAM | Fits this model? |
|------|------|------------------|
| RTX 2000 Ada | 16 GB | **No** — 19 GB of weights alone overflows it |
| RTX 4000 SFF Ada | 20 GB | Borderline; no room for KV cache at 16k |

So a card does not straightforwardly mean "same model, much faster". The three honest options:

1. **Smaller model, fully resident** — e.g. a dense 14B at Q4 (~9 GB) sits comfortably on a 16 GB card and would be dramatically faster than anything here, at some quality cost versus the 30B MoE.
2. **Lower quantisation** — `qwen3:30b-a3b` at Q3 is ~15 GB and fits a 16 GB card, trading some output quality for the speed.
3. **Partial offload** — keep attention and shared experts on the GPU and leave the routed experts on CPU. Prefill improves a lot (it is compute-heavy and parallelises well) even without full residency. This is the option that preserves the current model, and it is also the fiddliest.

Benchmark option 1 against the current CPU numbers before spending anything — a fast 14B may beat a slow 30B for this workload, which would make the cheaper card the right one.

The other upgrade path: **Intel iGPU via Vulkan**, worth perhaps 1.5–2×, but it contends with Plex transcoding for `/dev/dri` and needs Ollama swapped for a llama.cpp server build.

## Operations

```bash
# First deploy
cp services/sputnik/.env.example services/sputnik/.env   # fill in the two keys
sudo bash setup.sh                                       # creates the directories
loft-ctl start sputnik

# Pull the model (one-off, ~20 GB — expect a long download)
sudo docker exec -it ollama ollama pull qwen3:30b-a3b

# Bake in the assistant persona + guardrails
sudo docker exec -i ollama ollama create sputnik-assistant \
  -f /dev/stdin < services/sputnik/Modelfile.assistant

# Confirm it is loaded and answering
sudo docker exec -it ollama ollama list
curl -s http://localhost:11434/api/tags | jq '.models[].name'

# Measure real throughput (informs both model choice and the GPU decision)
bash services/sputnik/bench.sh

# Health across all tiers
loft-ctl health sputnik

# Watch memory while a model is resident
sudo docker stats ollama --no-stream
```

### First-run sequence

1. `loft-ctl start sputnik`
2. `bash services/sputnik/bench.sh` — with no models pulled it still reports host RAM and recommends a base model; set that as the `FROM` line in `Modelfile.assistant`
3. Pull that model — nothing works until one exists
4. `ollama create sputnik-assistant` (above), then re-run `bench.sh` for real throughput numbers
5. Open `https://sputnik.loft.hsimah.com`, create the admin account, select **sputnik-assistant** as the model, then set `ENABLE_SIGNUP=false` and `loft-ctl rebuild sputnik`
6. Open `https://n8n.loft.hsimah.com`, create the owner account
7. In n8n → Credentials → Google OAuth2 API, paste the client ID and secret, click **Connect my account** from a LAN browser
8. Build the first workflow — node-by-node spec in [`services/sputnik/workflows/morning-briefing.md`](../../services/sputnik/workflows/morning-briefing.md)

## Related

- [space-needle](../hosts/space-needle.md) — the only host that runs this
- [mushr](mushr.md) — supplies the TLS routes and LAN DNS
- Root [`README.md`](../../README.md) — fleet service table

## Debug & Troubleshooting

### Google connection stops working after exactly a week

**Cause:** The OAuth consent screen is still in "Testing" publishing status. Google expires refresh tokens issued by unpublished apps after 7 days.

**Fix:** Google Cloud Console → APIs & Services → OAuth consent screen → **Publish app**, then re-authorise the credential in n8n. Click through the "unverified app" warning as the developer.

### n8n crash-loops with `EACCES: permission denied, mkdir '/.n8n'`

**Symptom:** `docker ps -a` shows `Restarting (1)`, `/opt/sputnik/n8n` is empty (link count 2 — no subdirectories), and the log reads:

```
Error: Failed to load command "start"
Error: EACCES: permission denied, mkdir '/.n8n'
```

**Cause:** Note the path — `/.n8n` at the filesystem **root**, not `/home/node/.n8n`. The compose file sets `user: "1003:1003"` to match the fleet's `littledog` convention, but uid 1003 has no entry in this image's `/etc/passwd`. Node's `os.homedir()` falls back to `/` for an unknown uid, so n8n resolves its data directory to `/.n8n`, fails to create it on a root filesystem it cannot write, and exits before touching the bind mount.

**Chowning the volume does nothing** — the mount at `/home/node/.n8n` was never in the resolved path. This is a `$HOME`-resolution bug, not a file-ownership one, and the empty data directory is the tell that distinguishes them: an ownership problem produces a *partially* written directory, this produces an untouched one.

**Fix:** `N8N_USER_FOLDER` and `HOME` are both pinned explicitly in `docker-compose.yml` so nothing depends on `$HOME` resolution. If they have been removed, restore them:

```yaml
environment:
  - N8N_USER_FOLDER=/home/node   # n8n appends ".n8n" → /home/node/.n8n
  - HOME=/home/node/.n8n         # writable dir for anything else
```

Then `loft-ctl rebuild sputnik`. The same trap applies to any image whose entrypoint assumes its own baked-in user — check for it whenever adding `user:` to a service that did not previously have one.

### Every request takes 60+ seconds even for a trivial prompt

**Cause:** Almost always the model being evicted and reloaded between requests, not slow inference.

**Fix:** Confirm `OLLAMA_KEEP_ALIVE=-1` is in effect and the model is resident:

```bash
sudo docker exec ollama ollama ps        # should list the model with "Forever"
sudo docker logs ollama | grep -i "loading model"
```

Repeated "loading model" lines mean the setting is not applied — check that `loft-ctl rebuild sputnik` was run after editing `.env`. If the model *is* resident and it is still slow, the cost is prompt prefill, which is expected on CPU (see [Performance](#performance)).

### Open WebUI shows no models in the dropdown

**Cause:** Either no model has been pulled, or Open WebUI cannot reach Ollama.

**Fix:**

```bash
sudo docker exec ollama ollama list                        # is anything pulled?
sudo docker exec open-webui curl -s http://ollama:11434/api/tags   # can it reach the engine?
```

An empty `models` array from the first command means pull one. A connection failure from the second means the two containers are not on the `loft-proxy` network — check `sudo docker network inspect loft-proxy`.

### The model invents email contents

**Cause:** Context truncation. `OLLAMA_CONTEXT_LENGTH` caps the window; when a workflow feeds in more mail than fits, the oldest tokens fall out silently and the model fills the gaps.

**Fix:** Reduce how many messages the Gmail node returns per run, or raise `OLLAMA_CONTEXT_LENGTH` if there is RAM headroom (KV cache grows with the window, on top of the model weights).
