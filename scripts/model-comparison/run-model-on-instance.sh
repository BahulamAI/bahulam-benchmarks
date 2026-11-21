#!/usr/bin/env bash
# Run ONE model against ONE SWE-bench instance via the Bahulam CLI (--local
# headless, calling Bahulam Gateway directly). Inference only — no Docker
# eval. Writes result.json (resolved: "pending_eval" | "no_patch") plus the
# raw event stream, patch, and instruction, everything evaluate-patch.sh
# needs later. Run evaluate-patch.sh as a separate pass afterward (see
# evaluate-batch.sh): Docker eval is CPU/disk-heavy in a completely
# different way than an agent loop is memory-heavy, so bundling them into
# one concurrency slot wastes a slot on eval work while the next model's
# inference could already be running, and stacks two different resource
# profiles on top of each other right when a batch is under the most
# pressure (2026-11-20: a 6-way concurrent batch that bundled both got
# killed for memory; splitting them was the fix, not just lowering
# concurrency).
#
# Generalized out of a one-off xarray experiment: nothing here is
# hardcoded to a specific instance, repo, or model list, so this is the
# piece to reuse next time, e.g. a new top-N model snapshot a month from
# now, point it at a fresh instance.json and a different model slug.
#
# Requires: a local bare clone of the instance's repo (see --repo-bare)
# and BAHULAM_CODE_DIR pointing at a codekepler-npm checkout (so this
# always runs the exact CLI source you want — a specific published
# version, or an unreleased fix — not whatever happens to be installed
# globally).
#
# Usage:
#   run-model-on-instance.sh --instance instance.json --model <slug> \
#     --repo-bare /path/to/repo.git --out-dir /path/to/results/<tag> \
#     [--timeout-s 1700] [--max-turns 999] [--codekepler-npm-dir DIR]
set -uo pipefail

TIMEOUT_S=1700
MAX_TURNS=999
CODEKEPLER_NPM_DIR="${BAHULAM_CODE_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --repo-bare) REPO_BARE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --timeout-s) TIMEOUT_S="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    --codekepler-npm-dir) CODEKEPLER_NPM_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${INSTANCE:?--instance required}"
: "${MODEL:?--model required}"
: "${REPO_BARE:?--repo-bare required}"
: "${OUT_DIR:?--out-dir required}"
: "${CODEKEPLER_NPM_DIR:?--codekepler-npm-dir or BAHULAM_CODE_DIR required}"

CLI="$CODEKEPLER_NPM_DIR/src/terminal/main.mjs"
[[ -f "$CLI" ]] || { echo "CLI entrypoint not found: $CLI" >&2; exit 2; }

T="${B0_TOKEN:-$(jq -r .token ~/.bahulam/config.json)}"
[[ -n "$T" && "$T" != "null" ]] || { echo "no B0_TOKEN and ~/.bahulam/config.json has none" >&2; exit 2; }

INSTANCE_ID=$(jq -r .instance_id "$INSTANCE")
BASE_COMMIT=$(jq -r .base_commit "$INSTANCE")

mkdir -p "$OUT_DIR"
TRIAL="$OUT_DIR/repo"
rm -rf "$TRIAL"
git clone --quiet "$REPO_BARE" "$TRIAL"
cd "$TRIAL"
git checkout --quiet "$BASE_COMMIT"
jq -r .test_patch "$INSTANCE" > "$OUT_DIR/test_patch.diff"
git apply "$OUT_DIR/test_patch.diff"

python3 -c "
import json
spec = json.load(open('$INSTANCE'))
problem = spec['problem_statement']
instruction = (
    f'Fix the following issue in the code at $TRIAL. '
    f'Use search_code to find the relevant file, read_file to understand the code, '
    f'then edit_file with ABSOLUTE paths to fix it. You MUST call edit_file.\n\n'
    f'After editing, run the tests to verify your fix. '
    f'If tests fail, read the error, fix your code, and re-test.\n\n'
    f'{problem}'
)
open('$OUT_DIR/instruction.txt', 'w').write(instruction)
"

START=$(date +%s)
B0_TOKEN="$T" LLM_GATEWAY=BahulamGateway \
  BAHULAM_GATEWAY_URL="${BAHULAM_GATEWAY_URL:-https://gateway.bahulam.ai/v1}" \
  BAHULAM_MAX_TURNS="$MAX_TURNS" \
  perl -e 'alarm $ARGV[0]; shift; exec @ARGV' "$((TIMEOUT_S + 50))" \
  node "$CLI" --headless --verbose --local --timeout "$TIMEOUT_S" \
  -m "$MODEL" -p "$(cat "$OUT_DIR/instruction.txt")" \
  > "$OUT_DIR/run.jsonl" 2> "$OUT_DIR/run.err"
RC=$?
END=$(date +%s)

cd "$TRIAL"
git diff -- . ':!*/tests/*' ':!doc/*' > "$OUT_DIR/patch.diff" 2>/dev/null
PATCH_LINES=$(wc -l < "$OUT_DIR/patch.diff" | tr -d ' ')
rm -rf "$TRIAL"  # reproducible from repo-bare + base_commit; drop it to save disk

jq -c 'select(.type=="complete")' "$OUT_DIR/run.jsonl" 2>/dev/null | tail -1 > "$OUT_DIR/complete-event.json"
jq -c 'select(.type=="error")' "$OUT_DIR/run.jsonl" 2>/dev/null | tail -1 > "$OUT_DIR/error-event.json"
jq -c 'select(.type=="timeout")' "$OUT_DIR/run.jsonl" 2>/dev/null | tail -1 > "$OUT_DIR/timeout-event.json"

RESOLVED="no_patch"
if [[ "$PATCH_LINES" -gt 0 ]]; then
  RESOLVED="pending_eval"
fi

python3 -c "
import json

def load(path):
    try:
        t = open(path).read().strip()
        return json.loads(t) if t else None
    except Exception:
        return None

out = {
    'model': '$MODEL',
    'instance_id': '$INSTANCE_ID',
    'rc': $RC,
    'wall_clock_s': $END - $START,
    'patch_lines': $PATCH_LINES,
    'resolved': '$RESOLVED',
    'complete_event': load('$OUT_DIR/complete-event.json'),
    'error_event': load('$OUT_DIR/error-event.json'),
    'timeout_event': load('$OUT_DIR/timeout-event.json'),
}
json.dump(out, open('$OUT_DIR/result.json', 'w'), indent=2)
"

echo "DONE $MODEL -> inference complete, resolved=$RESOLVED patch_lines=$PATCH_LINES rc=$RC wall=$((END-START))s"
