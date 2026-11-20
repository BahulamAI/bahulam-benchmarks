#!/usr/bin/env bash
# One model per Railway service, each running the SAME instance set.
# Use this to screen several candidates side by side (e.g. OpenRouter free
# models). Contrast with dispatch-sharded.sh, which fans ONE model across
# the 5 numbered shards and needs merge-shards.sh afterwards.
#
# Service name = bahulam-screening-<model-slug> (vendor and ":free" dropped,
# "." ":" -> "-"), so the Railway dashboard reads as the model list. Services are
# created (with a /data volume) on first use and reused afterwards.
#
# Each service publishes its own run branch screening/<date>_<model-slug>
# with artifacts at the run-dir root (SHARD_ID is unset, so no merge step).
#
# Usage:
#   scripts/dispatch-models.sh <model-1> [model-2 ...]
#
# Env inputs (read from local files if not set):
#   B0_TOKEN               from ~/.bahulam/config.json
#   BENCHMARKS_GH_TOKEN    from ../../pass.md via sed
#
# Optional:
#   INSTANCE_FILE          default screening-300.txt (full SWE-bench Lite)
#   HARNESS_PARALLEL       default 3 (free-tier models rate-limit per model)
#   HARNESS_TIMEOUT_S      default 1200 (20 min)
set -euo pipefail

MODELS=("$@")
if [[ ${#MODELS[@]} -lt 1 ]]; then
  echo "usage: $0 <model-1> [model-2 ...]" >&2
  echo "example: $0 nvidia/nemotron-3-ultra-550b-a55b:free google/gemma-4-31b-it:free" >&2
  exit 2
fi

: "${B0_TOKEN:=$(jq -r .token ~/.bahulam/config.json)}"
: "${BENCHMARKS_GH_TOKEN:=$(sed -n 's/^Bahulam Benchmarks Railway PAT: //p' /Users/sree/Sites/Tarang-Orca/pass.md)}"
: "${INSTANCE_FILE:=screening-300.txt}"
: "${HARNESS_PARALLEL:=3}"
: "${HARNESS_TIMEOUT_S:=1200}"

if [[ -z "$B0_TOKEN" || -z "$BENCHMARKS_GH_TOKEN" ]]; then
  echo "B0_TOKEN or BENCHMARKS_GH_TOKEN missing" >&2
  exit 2
fi
if [[ ! -f "configs/$INSTANCE_FILE" ]]; then
  echo "configs/$INSTANCE_FILE not found (run from screening/)" >&2
  exit 2
fi

# Pre-flight: b0_ tokens expire 30 days after `bahulam login`. Verify the
# token against the gateway BEFORE baking it into the shard services.
GATEWAY_URL="${BAHULAM_GATEWAY_URL:-https://gateway.bahulam.ai/v1}"
# The gateway resolves tokens via the backend with a 10s timeout; a backend
# ReadTimeout surfaces as a spurious 401, so retry before declaring expiry.
TOKEN_HTTP=000
for attempt in 1 2 3; do
  TOKEN_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
    -H "Authorization: Bearer $B0_TOKEN" "$GATEWAY_URL/models" || echo 000)
  [[ "$TOKEN_HTTP" == "200" ]] && break
  echo "[pre-flight] attempt $attempt: HTTP $TOKEN_HTTP from $GATEWAY_URL/models — retrying" >&2
  sleep 3
done
if [[ "$TOKEN_HTTP" != "200" ]]; then
  echo "B0_TOKEN rejected by $GATEWAY_URL/models (HTTP $TOKEN_HTTP, 3 attempts)." >&2
  echo "Token is expired or invalid — run 'bahulam logout && bahulam login' and retry." >&2
  exit 2
fi
echo "[pre-flight] B0_TOKEN accepted by gateway (HTTP 200)"

service_name() {
  # nvidia/nemotron-3.5-super-vl:free -> bahulam-screening-nemotron-3-5-super-vl
  # Vendor prefix dropped: Railway rejects long names (>~50 chars).
  local slug name
  slug="$(echo "${1##*/}" | sed 's/:free$//' | tr '.:' '--' | tr -c 'a-z0-9-\n' '-')"
  name="bahulam-screening-${slug}"
  # Railway rejects names over ~50 chars: cut at 48 on a dash boundary.
  if [[ ${#name} -gt 48 ]]; then
    name="${name:0:48}"
    name="${name%-*}"
  fi
  echo "$name"
}

echo "==============================================================="
echo "  Per-service model dispatch"
echo "  instances:    $INSTANCE_FILE ($(wc -l < "configs/$INSTANCE_FILE") per model)"
echo "  parallel:     $HARNESS_PARALLEL per service"
echo "  timeout:      ${HARNESS_TIMEOUT_S}s per instance"
for MODEL in "${MODELS[@]}"; do
  echo "  $(service_name "$MODEL")  <-  $MODEL"
done
echo "==============================================================="

EXISTING=$(railway service list 2>&1 || true)

COMMON_VARS=(
  "B0_TOKEN=$B0_TOKEN"
  "BENCHMARKS_GH_TOKEN=$BENCHMARKS_GH_TOKEN"
  "BENCHMARKS_REPO=BahulamAI/bahulam-benchmarks"
  "BAHULAM_GATEWAY_URL=$GATEWAY_URL"
  "BAHULAM_RUNTIME_MODE=bundled"
  "LLM_GATEWAY=BahulamGateway"
  "HARNESS_TIMEOUT_S=$HARNESS_TIMEOUT_S"
  "HARNESS_PARALLEL=$HARNESS_PARALLEL"
  "SCREENING_INSTANCE_FILE=$INSTANCE_FILE"
  "SALVAGE_MODE=0"
)

for MODEL in "${MODELS[@]}"; do
  SVC="$(service_name "$MODEL")"

  # A service with no live deployment prints "name status: ○" on one line.
  if echo "$EXISTING" | grep -qE "^$SVC( |\$)"; then
    echo "[$SVC] exists — updating env vars"
    railway service link "$SVC" >/dev/null
    # Single model per service: no shard subdir, no seed.
    railway variable delete SHARD_ID 2>/dev/null || true
    railway variable delete SHARD_SEED_URL 2>/dev/null || true
    SET_ARGS=()
    for kv in "${COMMON_VARS[@]}" "CANDIDATE_MODEL=$MODEL"; do SET_ARGS+=(--set "$kv"); done
    railway variables "${SET_ARGS[@]}" >/dev/null
  else
    echo "[$SVC] missing — creating with /data volume"
    ADD_ARGS=()
    for kv in "${COMMON_VARS[@]}" "CANDIDATE_MODEL=$MODEL"; do ADD_ARGS+=(-v "$kv"); done
    # railway add echoes every -v value as a prompt line on stderr; keep
    # tokens out of the terminal.
    railway add --service "$SVC" "${ADD_ARGS[@]}" >/dev/null 2>&1 \
      || { echo "[$SVC] railway add failed" >&2; exit 1; }
    railway service link "$SVC" >/dev/null
    railway volume add --mount-path /data >/dev/null <<< '/data'
  fi

  echo "[$SVC] deploying"
  railway up --detach 2>&1 | grep -E "Build Logs|error" | head -3 || true
done

railway service link bahulam-screening-worker >/dev/null 2>&1 || true

echo "==============================================================="
echo "  ${#MODELS[@]} service(s) dispatched."
echo "  Monitor:  railway logs --service bahulam-screening-<model-slug>"
echo "  Each service pushes screening/<date>_<model-slug> when done."
echo "  Then on VM1: docker eval + scripts/verify-and-report.py per run."
echo "==============================================================="
