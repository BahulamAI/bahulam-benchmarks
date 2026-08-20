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

python3 /opt/screen/screen.py \
  --model "$CANDIDATE_MODEL" \
  --output-dir "$OUT"

echo "==============================================================="
echo "  Screen complete. Artifacts:"
ls -la "$OUT"
echo "==============================================================="

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
