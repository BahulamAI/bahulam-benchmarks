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
mkdir -p "$OUT"

echo "==============================================================="
echo "  Bahulam Model Screening"
echo "  model:      $CANDIDATE_MODEL"
echo "  output_dir: $OUT"
echo "  timeout:    ${HARNESS_TIMEOUT_S}s"
echo "  parallel:   ${HARNESS_PARALLEL}"
echo "  bahulam-cli: $(cat /opt/bahulam-cli/package.json | jq -r .version)"
echo "==============================================================="

# Bahulam CLI writes .gitconfig-dependent tempdirs during headless runs.
git config --global user.email "screening@bahulam.ai" 2>/dev/null || true
git config --global user.name  "screening" 2>/dev/null || true

# ── Live tail of harness.log → container stdout, so `railway logs` streams
#    [n/30] instance completions in real time. `tail -F` retries until the
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
