#!/usr/bin/env bash
# Fan out one candidate model across 5 Railway shard services.
# Each shard runs 60 instances at parallel=6 → ~30 concurrent Kepler
# processes across the model → ~1h total wall-clock (paid models).
#
# Reuses services named bahulam-screening-shard-{1..5} — creates them
# on first invocation, updates env vars on subsequent runs.
#
# Usage:
#   scripts/dispatch-sharded.sh <candidate-model> [seed-url-base]
#
# Env inputs (read from local files if not set):
#   B0_TOKEN               from ~/.bahulam/config.json
#   BENCHMARKS_GH_TOKEN    from ../../pass.md via sed
#
# Optional:
#   SEED_URL_BASE          base URL for shard seed files. Each shard fetches
#                          <SEED_URL_BASE>/shard-<N>-seed.json. Skip if no seed.
#   HARNESS_PARALLEL       default 6
#   HARNESS_TIMEOUT_S      default 1200 (20 min)
set -euo pipefail

MODEL="${1:-}"
SEED_URL_BASE="${2:-${SEED_URL_BASE:-}}"

if [[ -z "$MODEL" ]]; then
  echo "usage: $0 <candidate-model> [seed-url-base]" >&2
  echo "example: $0 deepseek/deepseek-v4-flash-0731" >&2
  echo "         $0 stealth/ox-alpha https://raw.githubusercontent.com/BahulamAI/bahulam-benchmarks/screening/2026-08-22_stealth-ox-alpha/suites/screening/runs/2026-08-22_stealth-ox-alpha/seeds" >&2
  exit 2
fi

: "${B0_TOKEN:=$(jq -r .token ~/.bahulam/config.json)}"
: "${BENCHMARKS_GH_TOKEN:=$(sed -n 's/^Bahulam Benchmarks Railway PAT: //p' /Users/sree/Sites/Tarang-Orca/pass.md)}"
: "${HARNESS_PARALLEL:=6}"
: "${HARNESS_TIMEOUT_S:=1200}"

if [[ -z "$B0_TOKEN" || -z "$BENCHMARKS_GH_TOKEN" ]]; then
  echo "B0_TOKEN or BENCHMARKS_GH_TOKEN missing" >&2
  exit 2
fi

echo "==============================================================="
echo "  Sharded dispatch"
echo "  model:        $MODEL"
echo "  parallel:     $HARNESS_PARALLEL per shard"
echo "  timeout:      ${HARNESS_TIMEOUT_S}s per instance"
echo "  seed base:    ${SEED_URL_BASE:-none}"
echo "==============================================================="

EXISTING=$(railway service list 2>&1 || true)

for N in 1 2 3 4 5; do
  SVC="bahulam-screening-shard-$N"
  INSTANCE_FILE="screening-300-shard${N}.txt"
  SEED_URL=""
  if [[ -n "$SEED_URL_BASE" ]]; then
    SEED_URL="${SEED_URL_BASE}/shard-${N}-seed.json"
  fi

  if echo "$EXISTING" | grep -q "^$SVC"; then
    echo "[shard-$N] service exists — updating env vars"
    railway service link "$SVC" >/dev/null
    railway variables --set "B0_TOKEN=$B0_TOKEN" \
                      --set "BENCHMARKS_GH_TOKEN=$BENCHMARKS_GH_TOKEN" \
                      --set "BENCHMARKS_REPO=BahulamAI/bahulam-benchmarks" \
                      --set "BAHULAM_GATEWAY_URL=https://gateway.bahulam.ai/v1" \
                      --set "BAHULAM_RUNTIME_MODE=bundled" \
                      --set "LLM_GATEWAY=BahulamGateway" \
                      --set "HARNESS_TIMEOUT_S=$HARNESS_TIMEOUT_S" \
                      --set "HARNESS_PARALLEL=$HARNESS_PARALLEL" \
                      --set "CANDIDATE_MODEL=$MODEL" \
                      --set "SCREENING_INSTANCE_FILE=$INSTANCE_FILE" \
                      --set "SHARD_ID=$N" \
                      --set "SHARD_SEED_URL=$SEED_URL" \
                      --set "SALVAGE_MODE=0" >/dev/null
  else
    echo "[shard-$N] service missing — creating"
    railway add \
      --service "$SVC" \
      -v "B0_TOKEN=$B0_TOKEN" \
      -v "BENCHMARKS_GH_TOKEN=$BENCHMARKS_GH_TOKEN" \
      -v "BENCHMARKS_REPO=BahulamAI/bahulam-benchmarks" \
      -v "BAHULAM_GATEWAY_URL=https://gateway.bahulam.ai/v1" \
      -v "BAHULAM_RUNTIME_MODE=bundled" \
      -v "LLM_GATEWAY=BahulamGateway" \
      -v "HARNESS_TIMEOUT_S=$HARNESS_TIMEOUT_S" \
      -v "HARNESS_PARALLEL=$HARNESS_PARALLEL" \
      -v "CANDIDATE_MODEL=$MODEL" \
      -v "SCREENING_INSTANCE_FILE=$INSTANCE_FILE" \
      -v "SHARD_ID=$N" \
      -v "SHARD_SEED_URL=$SEED_URL" >/dev/null
    railway service link "$SVC" >/dev/null
    railway volume add --mount-path /data >/dev/null <<< '/data'
  fi

  echo "[shard-$N] deploying"
  railway up --detach 2>&1 | grep -E "Build Logs|error" | head -3 || true
done

# Return to the worker context by default.
railway service link bahulam-screening-worker >/dev/null || true

echo "==============================================================="
echo "  All 5 shards dispatched."
echo "  Monitor:  railway logs --service bahulam-screening-shard-N"
echo "  Wall-clock target: ~1h"
echo "  When all 5 complete, on VM1:"
echo "    git fetch origin screening/<run_id>"
echo "    git checkout screening/<run_id>"
echo "    scripts/merge-shards.sh suites/screening/runs/<run_id>"
echo "    # then run docker eval on the merged predictions.json"
echo "==============================================================="
