#!/usr/bin/env bash
# Dispatch run-model-on-instance.sh across every model in a models.json,
# with bounded concurrency so a big batch doesn't overwhelm the gateway,
# the local Docker daemon, or disk.
#
# Usage:
#   dispatch-batch.sh --instance instance.json --models models.json \
#     --repo-bare /path/to/repo.git --run-dir /path/to/run \
#     [--concurrency 6] [--timeout-s 1700] [--max-turns 999]
set -uo pipefail

CONCURRENCY=6
TIMEOUT_S=1700
MAX_TURNS=999

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --repo-bare) REPO_BARE="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --timeout-s) TIMEOUT_S="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${INSTANCE:?--instance required}"
: "${MODELS:?--models required}"
: "${REPO_BARE:?--repo-bare required}"
: "${RUN_DIR:?--run-dir required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$RUN_DIR/results"
mkdir -p "$RESULTS_DIR"

# mapfile/readarray needs bash 4+; macOS ships bash 3.2, so read the slug
# list with a portable while-read loop into a temp file instead.
SLUGS_FILE=$(mktemp)
jq -r '.models[].slug' "$MODELS" > "$SLUGS_FILE"
TOTAL=$(wc -l < "$SLUGS_FILE" | tr -d ' ')
echo "dispatching $TOTAL models, concurrency=$CONCURRENCY, timeout=${TIMEOUT_S}s, max_turns=$MAX_TURNS"

# bash 3.2 (macOS's shipped bash) has neither `wait -n` nor arrays-from-
# process-substitution reliably, so track pids in a plain space-separated
# string and always wait on the oldest one once at the concurrency limit —
# bounds concurrency correctly even though it isn't strictly "whichever
# finishes first".
pids=""
while IFS= read -r slug; do
  [[ -z "$slug" ]] && continue
  tag="$(echo "$slug" | tr '/:' '--')"
  out="$RESULTS_DIR/$tag"
  if [[ -f "$out/result.json" ]]; then
    echo "[skip] $slug already has a result"
    continue
  fi
  (
    "$SCRIPT_DIR/run-model-on-instance.sh" \
      --instance "$INSTANCE" --model "$slug" --repo-bare "$REPO_BARE" \
      --out-dir "$out" --timeout-s "$TIMEOUT_S" --max-turns "$MAX_TURNS" \
      --codekepler-npm-dir "${BAHULAM_CODE_DIR:?set BAHULAM_CODE_DIR}" \
      > "$out.log" 2>&1
  ) &
  pids="$pids $!"
  set -- $pids
  if [[ $# -ge "$CONCURRENCY" ]]; then
    oldest="$1"
    shift
    pids="$*"
    wait "$oldest" 2>/dev/null
  fi
done < "$SLUGS_FILE"
wait
rm -f "$SLUGS_FILE"
echo "batch complete"
