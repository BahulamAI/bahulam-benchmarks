#!/usr/bin/env bash
# Docker-evaluate one model's already-produced patch (resolved:
# "pending_eval" in result.json) and update result.json in place with the
# real resolved/unresolved verdict. Separate pass from
# run-model-on-instance.sh on purpose — see that script's header for why.
#
# Usage:
#   evaluate-patch.sh --out-dir /path/to/results/<tag> --dataset <name> \
#     --swebench-venv /path/to/venv
#
# --swebench-venv is required, not left to PATH/activation: a background
# subshell doesn't inherit an interactive shell's one-off `source
# venv/bin/activate`, so `python` here can silently resolve to any other
# Python on PATH (e.g. an unrelated conda env with no `swebench` package
# installed) and fail with a confusing ModuleNotFoundError deep in a
# Docker-eval log instead of a clear error up front.
set -uo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --dataset) DATASET="$2"; shift 2 ;;
    --swebench-venv) SWEBENCH_VENV="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${OUT_DIR:?--out-dir required}"
: "${DATASET:?--dataset required}"
: "${SWEBENCH_VENV:?--swebench-venv required}"

PYBIN="$SWEBENCH_VENV/bin/python"
[[ -x "$PYBIN" ]] || { echo "no python at $PYBIN — is --swebench-venv correct?" >&2; exit 2; }
"$PYBIN" -c "import swebench" 2>/dev/null || { echo "$PYBIN has no swebench package installed" >&2; exit 2; }

RESULT="$OUT_DIR/result.json"
[[ -f "$RESULT" ]] || { echo "no result.json in $OUT_DIR" >&2; exit 2; }

INSTANCE_ID=$(jq -r .instance_id "$RESULT")
MODEL=$(jq -r .model "$RESULT")

MP_ESCAPED=$(python3 -c "import json; print(json.dumps(open('$OUT_DIR/patch.diff').read()))")
echo "[{\"instance_id\": \"$INSTANCE_ID\", \"model_name_or_path\": \"model\", \"model_patch\": $MP_ESCAPED}]" \
  > "$OUT_DIR/predictions.json"

export DOCKER_DEFAULT_PLATFORM=linux/amd64
cd "$OUT_DIR"
perl -e 'alarm 650; exec @ARGV' -- \
  "$PYBIN" -m swebench.harness.run_evaluation \
  --dataset_name "$DATASET" \
  --predictions_path predictions.json \
  --run_id eval -id eval --max_workers 1 \
  > docker-eval.log 2>&1

RESOLVED="eval_error"
VERDICT_FILE=$(ls model.eval.json 2>/dev/null | head -1)
if [[ -f "$VERDICT_FILE" ]]; then
  mv "$VERDICT_FILE" docker-eval.json
  RESOLVED=$(jq -r 'if (.resolved_ids|length) > 0 then "resolved" else "unresolved" end' docker-eval.json 2>/dev/null || echo "eval_error")
fi

python3 -c "
import json
r = json.load(open('$RESULT'))
r['resolved'] = '$RESOLVED'
json.dump(r, open('$RESULT', 'w'), indent=2)
"

echo "EVAL $MODEL -> resolved=$RESOLVED"
