# Bahulam Model Screening

A cheap, fast pass/fail check that runs **before** any full-300 SWE-bench Lite run. Screens a candidate model on 30 representative instances and returns a `PASS` / `REJECT` verdict against 8 hard gates.

**Goal:** kill bad candidates in ≤ $5 and ≤ 2 hours instead of blowing $500 on a full run.

## Architecture

```
Railway container                     VM1 (swebench-eval-vm)
──────────────────                    ──────────────────────
1. probe: tools_param_accepted
2. probe: OpenRouter pricing
3. harness on 30 instances
   → predictions.json
   → screening-report.json (partial)
                            ─── copy across ───►
                                                4. swebench.harness.run_evaluation
                                                5. read OpenRouter dashboard cost
                                                6. verify-and-report.py runs all gates
                                                   → screening-report.json (final)
                                                   → verdict: PASS or REJECT
```

**Why the split?** Docker eval is CPU/disk heavy — belongs on the big VM. Model inference is IO-bound waiting on the gateway — a $0.008/hour Railway container beats a $0.77/hour D16s_v3 by 100×. And the Railway container fully isolates the screen from any other work happening on the VM.

## Cost target

| | Screen | Full-300 (for reference) |
|---|---|---|
| Wall-clock | ~90 min | 5-20 hours |
| Inference | ~$2 (30 instances × ~$0.07 real per instance) | $10-$500 |
| Docker eval | ~$0.05 (30 containers × ~90s CPU) | $0.50 |
| **Budget cap** | **$5** (gate: `dashboard_cost_usd`) | not gated |

Screening 40 candidate models = ~$200. Blowing one full-300 on a bad candidate = $500+.

## Gates

All in `configs/gates.yaml` — the source of truth. Two pre-flight checks (before spending money) + 8 metric gates (post-screen):

| # | Metric | Threshold | Kills |
|---|---|---|---|
| pre-flight 1 | `tools_param_accepted` | must be true | Models without native tool-use (would have caught minimax-m3 at step 0) |
| pre-flight 2 | `pricing_snapshot` | must fetch | Provides live cost baseline |
| 1 | `resolve_rate` | ≥ 30% | Below the July 2026 flash-cloud baseline |
| 2 | `cache_hit_pct` | ≥ 70% (80% for reasoning models) | Bad provider caching |
| 3 | `tool_call_emission_rate` | ≥ 90% | 0-tool timeouts (the flash-0731 failure mode) |
| 4 | `cost_per_resolved_usd` | ≤ $2.00 | Runaway cost |
| 5 | `dashboard_cost_usd` | ≤ $5.00 | Screen itself blowing budget |
| 6 | `cost_delta_pct` | ≤ 500% (harness vs dashboard) | Cost estimator drift too large to project full-300 |
| 7 | `resolve_per_patch` | ≥ 60% | Producing patches that don't fix anything |
| 8 | `reasoning_token_ratio` | ≤ 3.0 (reasoning models only) | OpenAI billing bug / MiniMax thinking-trace inflation |

## Files

```
screening/
├── README.md                 ← you are here
├── Dockerfile                ← Railway image
├── railway.json              ← Railway service config
├── screen.py                 ← inference stage (runs on Railway)
├── configs/
│   ├── screening-30.txt      ← 30-instance screen set (30 SWE-Lite IDs)
│   └── gates.yaml            ← pass/fail thresholds
└── scripts/
    ├── entrypoint.sh         ← Railway container entrypoint
    ├── dispatch.sh           ← launch a screen from your laptop
    └── verify-and-report.py  ← runs on VM: docker eval + gates + final report
```

## Usage

### Prereqs

- Railway CLI installed and logged in (`railway login`)
- A Railway project linked (`railway link`) with a service named `bahulam-screening`
- Local `~/.bahulam/config.json` or `B0_TOKEN` env var (used to seed the service)
- On VM1: `~/swebench-env` venv with `swebench` installed (existing from full-300 runs)

### Screen a candidate

```bash
# From your laptop — dispatches to Railway, streams logs
./scripts/dispatch.sh openai/gpt-5.6-sol

# Container exits when done. Predictions land at /data/screen-openai-gpt-5-6-sol-<date>/
# If pre-flight failed, the report says REJECT and no inference was billed.
```

### Verify on the VM

```bash
# SCP the screen dir from Railway persistent volume → VM1
scp -r railway:/data/screen-openai-gpt-5-6-sol-* azureuser@swebench-eval-vm:~/screening/

# On VM1
ssh azureuser@swebench-eval-vm
cd ~/screening/screen-openai-gpt-5-6-sol-<date>/

# Look up the exact dashboard cost for the run window on OpenRouter,
# then run the verifier:
python3 /path/to/verify-and-report.py \
    --screen-dir . \
    --dashboard-cost-usd 3.42

# Final screening-report.json is written back with PASS or REJECT.
```

### If REJECT

Do NOT run the full-300. Publish the screening report to `suites/screening/runs/<date>_<model>/` anyway — negative results have value. See the suite README for the format.

### If PASS

Consider proceeding to full-300 with the same harness config, on the same VM. The screen already gave you a decent cost projection (`full_300_projection` in the report).

## Adjusting the gates

Edit `configs/gates.yaml`. Every threshold has a `reason` field — update it with the empirical evidence when you change a number. If you tighten a gate, note which past run WOULD have failed at the new threshold.

## Cost calibration

The screen's `cost_delta_pct` gate catches large drift between harness self-cost and dashboard. If you consistently see harness under-reporting by 20-50× (as with the flash-2.6.15 run: $3.83 harness vs $11.60 dashboard), that's a known issue — harness doesn't model provider prompt caching. Don't reject a model on that alone.
