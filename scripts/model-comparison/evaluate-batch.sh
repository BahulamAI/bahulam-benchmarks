#!/usr/bin/env bash
# Run evaluate-patch.sh across every result in a run-dir whose result.json
# says resolved: "pending_eval". Separate, lighter-weight pass after
# dispatch-batch.sh's inference pass — see run-model-on-instance.sh for why.
#
# Usage:
#   evaluate-batch.sh --run-dir /path/to/run --dataset <name> \
#     --swebench-venv /path/to/venv [--concurrency 3]
set -uo pipefail

CONCURRENCY=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --dataset) DATASET="$2"; shift 2 ;;
    --swebench-venv) SWEBENCH_VENV="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${RUN_DIR:?--run-dir required}"
: "${DATASET:?--dataset required}"
: "${SWEBENCH_VENV:?--swebench-venv required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$RUN_DIR/results"

PENDING_FILE=$(mktemp)
for result in "$RESULTS_DIR"/*/result.json; do
  [[ -f "$result" ]] || continue
  if [[ "$(jq -r .resolved "$result")" == "pending_eval" ]]; then
    dirname "$result" >> "$PENDING_FILE"
  fi
done
TOTAL=$(wc -l < "$PENDING_FILE" | tr -d ' ')
echo "evaluating $TOTAL pending patches, concurrency=$CONCURRENCY"

pids=""
while IFS= read -r out; do
  [[ -z "$out" ]] && continue
  (
    "$SCRIPT_DIR/evaluate-patch.sh" --out-dir "$out" --dataset "$DATASET" \
      --swebench-venv "$SWEBENCH_VENV" \
      > "$out/eval-dispatch.log" 2>&1
  ) &
  pids="$pids $!"
  set -- $pids
  if [[ $# -ge "$CONCURRENCY" ]]; then
    oldest="$1"
    shift
    pids="$*"
    wait "$oldest" 2>/dev/null
  fi
done < "$PENDING_FILE"
wait
rm -f "$PENDING_FILE"
echo "evaluation batch complete"
