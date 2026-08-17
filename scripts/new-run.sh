#!/usr/bin/env bash
# Scaffold a new run directory inside a suite.
#
# Usage: scripts/new-run.sh <suite> <run-slug>
# Example: scripts/new-run.sh swe-bench-lite 2026-08-17_bundled-mimo-300
#
# Creates:
#   suites/<suite>/runs/<run-slug>/
#     config.yaml     ← template you MUST edit
#     summary.md      ← template you MUST edit after the run
#   (predictions.json, docker-eval.json, costs.json get dropped in after execution)

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <suite> <run-slug>" >&2
  echo "  suite examples: swe-bench-lite, swe-bench-verified, terminal-bench, humaneval, mbpp" >&2
  exit 1
fi

SUITE=$1
SLUG=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUITE_DIR="$ROOT/suites/$SUITE"
RUN_DIR="$SUITE_DIR/runs/$SLUG"

if [[ ! -d $SUITE_DIR ]]; then
  echo "unknown suite: $SUITE" >&2
  echo "existing suites:" >&2
  ls "$ROOT/suites" >&2
  exit 1
fi

if [[ -d $RUN_DIR ]]; then
  echo "run dir already exists: $RUN_DIR" >&2
  exit 1
fi

mkdir -p "$RUN_DIR"

cat >"$RUN_DIR/config.yaml" <<EOF
run_id: $SLUG
suite: $SUITE
dataset: princeton-nlp/SWE-bench_Lite    # <-- FIX for your suite
subset: full-300                          # <-- e.g. hard-10, full-500
instances_submitted: 300                  # <-- match subset

harness:
  name: swe-bench-harness                 # or run-persistent, terminal-bench
  config: ../../../../configs/harness/swe-harness.yaml
  instance_timeout_s: 600
  parallel_workers: 4

agent:
  pattern: single-agent                   # or multi-agent-delegate
  config: ../../../../configs/agent/single-agent.yaml
  primary_model: xiaomi/mimo-v2.5

runtime:
  type: bundled                           # or cloud-backend
  bahulam_version: '2.6.13'               # omit for cloud-backend

gateway:
  url: https://gateway.bahulam.ai/v1
  provider: openrouter

infrastructure:
  vm_size: Standard_D16s_v3
  vm: swebench-eval-vm
  region: centralus

timing:
  harness_started_at: null                # ISO 8601, fill after run
  harness_completed_at: null
  docker_eval_completed_at: null

notes: |
  <describe intent of this run — what's being tested, what varies vs prior runs>
EOF

cat >"$RUN_DIR/summary.md" <<EOF
# $SLUG

**Result: N / N resolved (X.X %)** ← fill in after Docker eval

Brief 1-line description of the run.

## Headline metrics

| Metric | Value |
|---|---|
| Instances submitted | |
| **Resolved** | |
| Unresolved | |
| Empty patch | |
| Error | |
| Patch rate | |
| Cost per instance | |
| **Cost per resolved instance** | |
| Avg wall-clock per instance | |
| Total gateway spend | |

## Configuration

See \`config.yaml\` — key axes: model, runtime, agent pattern.

## What worked / What to improve

- ...

## Reproduction

\`\`\`bash
# TODO: exact commands
\`\`\`

## Artifacts

- \`predictions.json\` — model outputs per instance
- \`docker-eval.json\` — official evaluator report
- \`costs.json\` — cost + token breakdown
- \`config.yaml\` — full run configuration
EOF

echo "scaffolded $RUN_DIR"
echo "next:"
echo "  1. edit $RUN_DIR/config.yaml"
echo "  2. run the harness (see suite README)"
echo "  3. drop predictions.json + docker-eval.json + costs.json into $RUN_DIR/"
echo "  4. fill in summary.md"
echo "  5. add an entry under 'runs' in manifest.json"
echo "  6. python3 scripts/generate-readme.py"
