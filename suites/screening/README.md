# Screening

Publishable screening reports for candidate models. Every model considered for the harness "approved list" lands here — **passes and failures both**. Negative results are how we save budget.

## What is a screen?

A 30-instance SWE-bench Lite pass/fail check that decides whether a candidate model is worth a full-300 run. Full workflow lives in `../../screening/` (the harness code, gates config, Railway image). This directory is where the resulting reports get published.

**Cost:** ~$2 per screen. **Wall-clock:** ~90 min. **Signal:** high enough to reject most bad candidates.

## Run format

```
suites/screening/runs/2026-08-21_openai-gpt-5.6-sol/
├── screening-report.json     ← the machine-readable verdict + all metrics
├── predictions.json          ← 30-instance model outputs (raw)
├── docker-eval.json          ← official evaluator report
├── pricing.json              ← live OpenRouter pricing at screen time
├── preflight-tools.json      ← the tools-param probe result
└── summary.md                ← human-readable one-pager (PASS/REJECT + reasons)
```

Naming: `<YYYY-MM-DD>_<vendor>-<model-slug>`. The `-` replaces `/` and `.` from the raw slug.

## Verdict format

The report ends with one of:

- **`PASS`** — proceed to full-300 with confidence. All 8 gates cleared.
- **`REJECT`** — model failed one or more gates. Full-300 blocked. Report notes which gate(s) tripped so we can revisit if the underlying issue is fixed upstream (bad provider hint, model bug, pricing change).

## Currently screened

None yet. Screened models get a row in the top-level [`../../README.md`](../../README.md) once the first screen lands.

## Adding a new screen

See [`../../screening/README.md`](../../screening/README.md) for the dispatch instructions. Once `verify-and-report.py` finishes on the VM:

```bash
# Copy the screen dir into this suite
DATE=$(date -u +%Y-%m-%d)
SLUG=$(echo "openai/gpt-5.6-sol" | tr '/' '-' | tr '.' '-')
DEST=suites/screening/runs/${DATE}_${SLUG}
mkdir -p $DEST
scp azureuser@vm:~/screening/screen-*/{screening-report.json,predictions.json,pricing.json,preflight-tools.json,docker-eval.json} $DEST/

# Write summary.md (see any prior run for the template)
# Update manifest.json (add a new entry with suite="screening")
python3 scripts/generate-readme.py
git commit + push
```
