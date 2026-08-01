#!/usr/bin/env bash
#
# sputnik/bench.sh — measure real inference throughput on this host.
#
# Prints prefill (prompt processing) and generation rates per model, which are
# the two numbers that decide whether this box needs a GPU. Estimates are not
# a substitute: prefill in particular varies several-fold with memory
# bandwidth, and it dominates agent-loop latency.
#
# Usage:
#   bash services/sputnik/bench.sh                  # every installed model
#   bash services/sputnik/bench.sh qwen3:30b-a3b    # just this one
#
# Needs only curl + python3 — it talks to the Ollama HTTP API on loopback, so
# no docker and no sudo.

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

# Roughly 1500-2500 tokens of prose, repeated to a stable size. Prefill rate is
# only meaningful over a prompt long enough to swamp per-request overhead, and
# this approximates a real agent turn (tool schemas + a mail thread).
build_prompt() {
  local unit="The quarterly review meeting has been moved to Thursday afternoon. \
Please confirm whether the updated figures from the finance team have been \
circulated, and note any outstanding items that need sign-off before the end \
of the month. The attached summary supersedes the previous version. "
  local out=""
  for _ in $(seq 1 40); do out+="$unit"; done
  printf '%s\nSummarise the above in one sentence.' "$out"
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ── Host facts ───────────────────────────────────────────────────────────────
printf '=== host ===\n'
printf '%-14s %s\n' "cpu" "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
printf '%-14s %s\n' "cores" "$(nproc)"

mem_total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
mem_total_gb=$(( mem_total_kb / 1024 / 1024 ))
mem_avail_gb=$(( mem_avail_kb / 1024 / 1024 ))
printf '%-14s %s GB total, %s GB available\n' "memory" "$mem_total_gb" "$mem_avail_gb"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  printf '%-14s %s\n' "gpu" "$(nvidia-smi -L | head -1)"
  gpu_present=yes
else
  printf '%-14s none detected (CPU inference)\n' "gpu"
  gpu_present=no
fi

# ── Model sizing guidance ────────────────────────────────────────────────────
# Based on available rather than total memory: this box also runs Plex, the
# *arr stack, WordPress and Music Assistant, and the model must stay resident.
printf '\n=== sizing ===\n'
if   [ "$mem_avail_gb" -ge 24 ]; then rec="qwen3:30b-a3b  (MoE, ~20 GB resident — best quality per token/sec on CPU)"
elif [ "$mem_avail_gb" -ge 12 ]; then rec="qwen3:14b      (~10 GB resident — expect slow agent loops)"
elif [ "$mem_avail_gb" -ge  8 ]; then rec="qwen3:8b       (~6 GB resident — weakest tool caller)"
else                                  rec="qwen3:4b       (tight; consider more RAM before more model)"
fi
printf 'with %s GB available, recommended base model:\n  %s\n' "$mem_avail_gb" "$rec"

# ── Which models to test ─────────────────────────────────────────────────────
curl -sf --max-time 5 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 \
  || die "cannot reach Ollama at $OLLAMA_URL — is the engine profile running? (loft-ctl start sputnik)"

if [ "$#" -gt 0 ]; then
  models=("$@")
else
  mapfile -t models < <(
    curl -sf "$OLLAMA_URL/api/tags" \
      | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin).get("models",[])]'
  )
fi

[ "${#models[@]}" -gt 0 ] \
  || die "no models installed — pull one first, e.g. sudo docker exec -it ollama ollama pull qwen3:30b-a3b"

prompt="$(build_prompt)"

# ── Benchmark ────────────────────────────────────────────────────────────────
printf '\n=== throughput ===\n'
printf '%-24s %12s %12s %10s\n' "model" "prefill t/s" "gen t/s" "first tok"
printf '%.0s-' {1..62}; printf '\n'

for model in "${models[@]}"; do
  # Warm-up: loads weights into RAM so the measured run excludes load time.
  # Without this the first model tested is penalised by a cold ~20 GB read.
  curl -sf --max-time 900 "$OLLAMA_URL/api/generate" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"prompt":"hi","stream":False}))' "$model")" \
    >/dev/null 2>&1 || { printf '%-24s %s\n' "$model" "(warm-up failed — skipped)"; continue; }

  payload=$(python3 -c '
import json, sys
print(json.dumps({"model": sys.argv[1], "prompt": sys.argv[2], "stream": False,
                  "options": {"num_predict": 128}}))' "$model" "$prompt")

  if ! resp=$(curl -sf --max-time 900 "$OLLAMA_URL/api/generate" -d "$payload" 2>/dev/null); then
    printf '%-24s %s\n' "$model" "(request failed — skipped)"
    continue
  fi

  printf '%s' "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
model = sys.argv[1]

def rate(count, ns):
    # Guard both: a cached prefill reports zero duration, and an empty
    # generation reports zero count. Either would divide by zero.
    return (count / (ns / 1e9)) if count and ns else 0.0

pf = rate(d.get("prompt_eval_count", 0), d.get("prompt_eval_duration", 0))
gen = rate(d.get("eval_count", 0), d.get("eval_duration", 0))
# Time to first token ~= load + prompt processing.
ttft = (d.get("load_duration", 0) + d.get("prompt_eval_duration", 0)) / 1e9

print(f"{model:<24} {pf:>12.1f} {gen:>12.1f} {ttft:>9.1f}s")
' "$model"
done

# ── Verdict ──────────────────────────────────────────────────────────────────
cat <<EOF

=== reading this ===
prefill t/s   Prompt processing. Dominates agent-loop latency, because every
              turn re-reads the tool schemas and the mail thread. This is the
              number a GPU improves most.
gen t/s       Token generation. Below ~10 makes interactive chat unpleasant;
              it matters much less for scheduled n8n workflows.
first tok     What you actually wait for before text appears.
EOF

if [ "$gpu_present" = no ]; then
  cat <<'EOF'

No GPU detected. Compare against the same run on a card before buying: the
decision hinges on whether "first tok" is tolerable for the interactive Open
WebUI surface. Scheduled n8n workflows are unaffected either way — nobody is
watching a 7am cron job wait 40 seconds.
EOF
fi
