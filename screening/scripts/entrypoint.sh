#!/usr/bin/env bash
# Railway container entrypoint. Runs one screen for $CANDIDATE_MODEL,
# writes results under /data/screen-<slug>-<date>/, exits.
set -euo pipefail

if [[ -z "${CANDIDATE_MODEL:-}" ]]; then
  echo "CANDIDATE_MODEL env var required (e.g. openai/gpt-5.6-sol)" >&2
  exit 2
fi
if [[ -z "${B0_TOKEN:-}" ]]; then
  echo "B0_TOKEN env var required" >&2
  exit 2
fi

DATE="$(date -u +%Y%m%d-%H%M)"
SLUG="$(echo "$CANDIDATE_MODEL" | tr '/' '-' | tr '.' '-')"
OUT="${OUTPUT_DIR:-/data/screen-${SLUG}-${DATE}}"

# Bahulam CLI writes .gitconfig-dependent tempdirs during headless runs.
git config --global user.email "screening@bahulam.ai" 2>/dev/null || true
git config --global user.name  "screening" 2>/dev/null || true

# ── SALVAGE_MODE: don't run screen (and don't mkdir $OUT — we don't want to
#    create an empty candidate that shadows the real prior-run dir).
#    Scan /data for the screen dir with the biggest predictions-raw.json,
#    push its contents to the run branch under a shard-partial/ subdir,
#    then exit. Used to rescue in-flight results before sharded execution.
if [[ "${SALVAGE_MODE:-0}" == "1" ]]; then
  echo "==============================================================="
  echo "  SALVAGE MODE — pushing existing /data contents, no screen run"
  echo "==============================================================="
  # Prefer the dir whose predictions-raw.json is largest (most work done).
  EXISTING=""
  BEST_SIZE=0
  for d in /data/screen-*/; do
    d="${d%/}"
    [[ -d "$d" ]] || continue
    P="$d/predictions-raw.json"
    if [[ -f "$P" ]]; then
      SIZE=$(stat -c%s "$P" 2>/dev/null || wc -c < "$P")
      if [[ "$SIZE" -gt "$BEST_SIZE" ]]; then
        BEST_SIZE=$SIZE
        EXISTING=$d
      fi
    fi
  done
  if [[ -z "$EXISTING" || ! -d "$EXISTING" ]]; then
    echo "[salvage] no prior screen dir with predictions-raw.json found in /data"
    ls -la /data 2>/dev/null || true
    exit 0
  fi
  echo "[salvage] found $EXISTING (predictions-raw.json = $BEST_SIZE bytes)"
  ls -la "$EXISTING"
  DONE_COUNT=$(jq -r '.results | length' "$EXISTING/predictions-raw.json" 2>/dev/null || echo 0)
  PATCHED_COUNT=$(jq -r '[.results[] | select(.model_patch != "" and .model_patch != null)] | length' "$EXISTING/predictions-raw.json" 2>/dev/null || echo 0)
  echo "[salvage] $DONE_COUNT results collected ($PATCHED_COUNT patched)"
  # Push under shard-partial/ subdir on the same run branch.
  OUT="$EXISTING" CANDIDATE_MODEL="$CANDIDATE_MODEL" \
    SHARD_ID="partial" /opt/screen/push-to-benchmarks.sh || {
      echo "[salvage] push failed rc=$?"
      exit 1
    }
  echo "[salvage] DONE — partial results pushed"
  exit 0
fi

# Only create the output dir when we're actually going to run screen.
mkdir -p "$OUT"

echo "==============================================================="
echo "  Bahulam Model Screening"
echo "  model:      $CANDIDATE_MODEL"
echo "  output_dir: $OUT"
echo "  timeout:    ${HARNESS_TIMEOUT_S}s"
echo "  parallel:   ${HARNESS_PARALLEL}"
echo "  bahulam-cli: $(cat /opt/bahulam-cli/package.json | jq -r .version)"
echo "==============================================================="

# ── SHARD_SEED_URL: fetch a pre-computed predictions-raw.json (from a prior
#    salvage) into $OUT before running screen.py. The harness's --skip-done
#    then skips any instances already patched in the seed, so this shard
#    picks up only its remaining work.
if [[ -n "${SHARD_SEED_URL:-}" ]]; then
  echo "==============================================================="
  echo "  SEED — fetching pre-completed results from $SHARD_SEED_URL"
  echo "==============================================================="
  if curl -fsSL "$SHARD_SEED_URL" -o "$OUT/predictions-raw.json"; then
    SEED_COUNT=$(jq -r '.results | length' "$OUT/predictions-raw.json" 2>/dev/null || echo 0)
    SEED_PATCHED=$(jq -r '[.results[] | select(.model_patch != "")] | length' "$OUT/predictions-raw.json" 2>/dev/null || echo 0)
    echo "[seed] pre-loaded $SEED_COUNT results ($SEED_PATCHED patched) into $OUT/predictions-raw.json"
  else
    echo "[seed] fetch failed (curl rc=$?) — proceeding without seed"
    rm -f "$OUT/predictions-raw.json"
  fi
  echo "==============================================================="
fi

# ── Live tail of harness.log → container stdout, so `railway logs` streams
#    [n/N] instance completions in real time. `tail -F` retries until the
#    file appears (screen.py creates it once the subprocess launches).
#    Prefix each line with [harness] so it's easy to filter.
( tail -F "$OUT/harness.log" 2>/dev/null | sed -u 's/^/[harness] /' ) &
TAIL_PID=$!
trap 'kill $TAIL_PID 2>/dev/null || true' EXIT

python3 /opt/screen/screen.py \
  --model "$CANDIDATE_MODEL" \
  --output-dir "$OUT"

# Give tail 3s to drain the last lines before EXIT trap kills it.
sleep 3
kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

echo "==============================================================="
echo "  Screen complete. Artifacts:"
ls -la "$OUT"
echo "==============================================================="

# ── Push to bahulam-benchmarks on a per-run branch (no-op if no PAT set) ──
if [[ -x /opt/screen/push-to-benchmarks.sh ]]; then
  echo "==============================================================="
  echo "  Publishing to bahulam-benchmarks"
  echo "==============================================================="
  OUT="$OUT" CANDIDATE_MODEL="$CANDIDATE_MODEL" /opt/screen/push-to-benchmarks.sh || \
    echo "[entrypoint] push-to-benchmarks failed rc=$? — continuing anyway"
  echo "==============================================================="
fi

# Optional: upload the whole dir to a signed URL (S3, presigned bucket).
if [[ "${UPLOAD_ON_DONE:-0}" == "1" && -n "${UPLOAD_URL:-}" ]]; then
  echo "==============================================================="
  echo "  Packaging + uploading to $UPLOAD_URL"
  echo "==============================================================="
  TAR="/tmp/${SLUG}-${DATE}.tar.gz"
  tar czf "$TAR" -C "$(dirname "$OUT")" "$(basename "$OUT")"
  curl -sSL -X PUT -T "$TAR" "$UPLOAD_URL" -o /tmp/upload.out -w "upload HTTP %{http_code}\n"
  rm -f "$TAR"
fi

echo "DONE"
