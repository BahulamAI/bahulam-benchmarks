#!/usr/bin/env bash
# Dispatch a screening run to Railway.
#
# Usage:
#   scripts/dispatch.sh <model-slug> [<railway-service-name>]
#
# Requires:
#   railway CLI installed + logged in (`railway login`)
#   A Railway project linked (`railway link`) OR RAILWAY_PROJECT_ID env
#   B0_TOKEN available locally to seed the service env var
#
# What it does:
#   1. Sets CANDIDATE_MODEL env on the target service
#   2. Ensures B0_TOKEN + gateway URL are set
#   3. Triggers a new deployment
#   4. Streams logs until the container exits
#   5. Prints the /data/screen-<slug>-<date>/ path (for the VM verify step)

set -euo pipefail

MODEL="${1:-}"
SERVICE="${2:-bahulam-screening}"

if [[ -z "$MODEL" ]]; then
  echo "usage: $0 <model-slug> [service-name]" >&2
  exit 2
fi

if [[ -z "${B0_TOKEN:-}" ]]; then
  if [[ -f "$HOME/.bahulam/config.json" ]]; then
    B0_TOKEN="$(python3 -c "import json;print(json.load(open('$HOME/.bahulam/config.json'))['token'])")"
    export B0_TOKEN
  else
    echo "B0_TOKEN not set and ~/.bahulam/config.json not found" >&2
    exit 2
  fi
fi

if ! command -v railway >/dev/null; then
  echo "railway CLI not installed — https://docs.railway.com/develop/cli" >&2
  exit 3
fi

echo "[dispatch] service=$SERVICE model=$MODEL"

railway variables --service "$SERVICE" \
  --set "CANDIDATE_MODEL=$MODEL" \
  --set "B0_TOKEN=$B0_TOKEN" \
  --set "BAHULAM_GATEWAY_URL=${BAHULAM_GATEWAY_URL:-https://gateway.bahulam.ai/v1}" \
  --set "BAHULAM_RUNTIME_MODE=bundled" \
  --set "LLM_GATEWAY=BahulamGateway" \
  --set "HARNESS_TIMEOUT_S=${HARNESS_TIMEOUT_S:-600}" \
  --set "HARNESS_PARALLEL=${HARNESS_PARALLEL:-3}" \
  >/dev/null

echo "[dispatch] triggering redeploy"
railway redeploy --service "$SERVICE" --yes

echo "[dispatch] streaming logs — Ctrl-C to detach (container keeps running)"
railway logs --service "$SERVICE"
