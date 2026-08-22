#!/usr/bin/env bash
# Push a completed screen dir to the public bahulam-benchmarks repo.
# One branch per candidate model (screening/<run_id>). Sharded runs
# push their artifacts into a shard-<N>/ subdir under the same branch,
# with retry-on-race so concurrent shards don't collide on the ref.
# Called from entrypoint.sh after screen.py finishes. Skips silently
# if BENCHMARKS_GH_TOKEN is missing.
#
# Env inputs:
#   BENCHMARKS_GH_TOKEN   Fine-grained PAT with Contents:write on the repo
#   CANDIDATE_MODEL       model slug
#   OUT                   /data/screen-<slug>-<date> (set by entrypoint.sh)
#
# Optional env:
#   BENCHMARKS_REPO       default BahulamAI/bahulam-benchmarks
#   BENCHMARKS_BASE       default main
#   BENCHMARKS_GH_USER    default screening-bot
#   BENCHMARKS_GH_EMAIL   default screening@bahulam.ai
#   SHARD_ID              1..N — when set, artifacts go to shard-<N>/
#                         subdir and commit uses retry-on-race push
set -euo pipefail

if [[ -z "${BENCHMARKS_GH_TOKEN:-}" ]]; then
  echo "[push] BENCHMARKS_GH_TOKEN not set — skipping benchmarks push"
  exit 0
fi
if [[ -z "${OUT:-}" || ! -d "$OUT" ]]; then
  echo "[push] OUT not set or missing ($OUT) — nothing to push" >&2
  exit 0
fi
if [[ -z "${CANDIDATE_MODEL:-}" ]]; then
  echo "[push] CANDIDATE_MODEL missing" >&2
  exit 0
fi

REPO="${BENCHMARKS_REPO:-BahulamAI/bahulam-benchmarks}"
BASE="${BENCHMARKS_BASE:-main}"
GH_USER="${BENCHMARKS_GH_USER:-screening-bot}"
GH_EMAIL="${BENCHMARKS_GH_EMAIL:-screening@bahulam.ai}"
SHARD="${SHARD_ID:-}"

# Prefer the run_id already present in screening-report.json (single source of truth).
RUN_ID=""
if [[ -f "$OUT/screening-report.json" ]]; then
  RUN_ID="$(jq -r '.run_id // empty' "$OUT/screening-report.json" 2>/dev/null || true)"
fi
if [[ -z "$RUN_ID" ]]; then
  DATE="$(date -u +%Y-%m-%d)"
  SLUG="$(echo "$CANDIDATE_MODEL" | tr '/' '-' | tr '.' '-')"
  RUN_ID="${DATE}_${SLUG}"
fi

BRANCH="screening/${RUN_ID}"
RUN_DIR_REL="suites/screening/runs/${RUN_ID}"
if [[ -n "$SHARD" ]]; then
  DEST_REL="${RUN_DIR_REL}/shard-${SHARD}"
else
  DEST_REL="$RUN_DIR_REL"
fi
WORK="/tmp/benchmarks-push"
rm -rf "$WORK"

echo "[push] repo=$REPO base=$BASE branch=$BRANCH shard=${SHARD:-none} dest=$DEST_REL"

# Shallow clone to keep bandwidth low; the token stays only in the remote URL
# for this working copy (never committed, never printed).
REMOTE="https://x-access-token:${BENCHMARKS_GH_TOKEN}@github.com/${REPO}.git"
git clone --quiet --depth 1 --branch "$BASE" "$REMOTE" "$WORK"

cd "$WORK"
git config user.email "$GH_EMAIL"
git config user.name  "$GH_USER"

# If a shard branch already exists on origin (another shard got there first),
# check it out and add our shard-N/ subdir. Otherwise create the branch off BASE.
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  git fetch --quiet --depth 1 origin "$BRANCH":"$BRANCH"
  git checkout --quiet "$BRANCH"
  echo "[push] branch $BRANCH already exists — adding shard on top"
else
  git checkout --quiet -b "$BRANCH"
fi

mkdir -p "$DEST_REL"

# Copy artifacts we care about (skip harness.log if it's huge — >5MB).
for f in predictions.json predictions-raw.json screening-report.json pricing.json preflight-tools.json; do
  if [[ -f "$OUT/$f" ]]; then
    cp "$OUT/$f" "$DEST_REL/$f"
    echo "[push]   + $f ($(stat -c%s "$OUT/$f" 2>/dev/null || wc -c < "$OUT/$f") bytes)"
  fi
done
if [[ -f "$OUT/harness.log" ]]; then
  SIZE=$(stat -c%s "$OUT/harness.log" 2>/dev/null || wc -c < "$OUT/harness.log")
  if [[ "$SIZE" -lt 5242880 ]]; then
    cp "$OUT/harness.log" "$DEST_REL/harness.log"
    echo "[push]   + harness.log ($SIZE bytes)"
  else
    echo "[push]   ~ harness.log skipped ($SIZE bytes > 5MB); use volume access if needed"
  fi
fi

git add "$DEST_REL"
if git diff --cached --quiet; then
  echo "[push] no changes to commit — exiting"
  exit 0
fi

VERDICT="$(jq -r '.gates_verdict // "UNKNOWN"' "$DEST_REL/screening-report.json" 2>/dev/null || echo UNKNOWN)"
PATCHED="$(jq -r '.metrics.patched // 0' "$DEST_REL/screening-report.json" 2>/dev/null || echo 0)"
SUBMITTED="$(jq -r '.metrics.instances_submitted // 0' "$DEST_REL/screening-report.json" 2>/dev/null || echo 0)"
COST="$(jq -r '.metrics.harness_cost_usd // 0' "$DEST_REL/screening-report.json" 2>/dev/null || echo 0)"

if [[ -n "$SHARD" ]]; then
  MSG="screening: ${RUN_ID} shard-${SHARD} (${VERDICT}, patched=${PATCHED}/${SUBMITTED}, harness=\$${COST})"
else
  MSG="screening: ${RUN_ID} (${VERDICT}, patched=${PATCHED}/${SUBMITTED}, harness=\$${COST})"
fi

git commit --quiet -m "$MSG" \
  -m "Auto-pushed by Railway screening service. Docker eval + gate verdict pending on VM." \
  -m "Signed-off-by: ${GH_USER} <${GH_EMAIL}>"

# Retry-on-race: another shard may have pushed between our fetch and now.
# Rebase our commit on top and try again, up to 5 times.
echo "[push] pushing to origin ${BRANCH}"
push_ok=0
for attempt in 1 2 3 4 5; do
  if git push --quiet --set-upstream origin "$BRANCH" 2>/tmp/push.err; then
    push_ok=1
    break
  fi
  if grep -qE "non-fast-forward|fetch first|Updates were rejected" /tmp/push.err; then
    echo "[push] attempt $attempt: race with another shard, rebasing"
    git pull --quiet --rebase origin "$BRANCH" || {
      echo "[push] rebase failed — aborting"
      cat /tmp/push.err
      exit 1
    }
    # Backoff jitter so shards don't collide immediately.
    sleep $((RANDOM % 5 + 1))
  else
    echo "[push] push failed with non-race error:"
    cat /tmp/push.err
    exit 1
  fi
done

if [[ "$push_ok" -ne 1 ]]; then
  echo "[push] gave up after 5 attempts"
  exit 1
fi

echo "[push] DONE — branch ready for VM verify + PR merge"
echo "[push] compare: https://github.com/${REPO}/compare/${BASE}...${BRANCH}"
