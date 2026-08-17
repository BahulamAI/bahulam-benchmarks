# SWE-bench Verified 500 — mimo v2.5 v8

**Result: 339 / 500 resolved (67.8 %)**

Best full-Verified run in the Bahulam benchmark series.

## Headline metrics

| Metric | Value |
|---|---|
| Instances submitted | 500 |
| **Resolved** | **339 (67.8 %)** |
| Unresolved | 114 (22.8 %) |
| Empty patch | 24 (4.8 %) |
| Error | 23 (4.6 %) |
| Patch rate (Kepler produced a patch) | 476 / 500 (95.2 %) |
| Resolve rate over patches produced | 71.2 % |
| Cost per instance | $0.0074 |
| **Cost per resolved instance** | **$0.011** |
| Avg wall-clock per instance | 5 min |
| Total gateway spend | $3.71 |

## Configuration

- **Model:** `xiaomi/mimo-v2.5` (primary), via Bahulam Gateway → OpenRouter → GMICloud
- **Sub-agent map:** explore + plan configured to `deepseek/deepseek-v4-flash` but only 4 delegations across 500 instances (effectively single-agent)
- **Runtime:** cloud backend (not bundled CLI). Predates the public `@bahulam/code` npm package.
- **Harness:** SWE-bench standard harness (fresh runtime per instance), 4 parallel workers
- **Timeout:** 600 s per instance
- **Compute:** 1× D16s_v3 (16 vCPU), centralus, ~24 h wall-clock

## What worked

- Mimo consistently produced patches: 95% patch rate is the highest of any tested model
- Cost per resolved instance ($0.011) is competitive with top-of-leaderboard entries
- Sub-agent tooling was available but the model preferred direct action — this workload doesn't benefit from delegation

## What to improve

- Cache hit rate 49% — cloud backend spawns fresh runtime per instance, so no cross-instance cache reuse. Persistent-runtime variants could reduce cost further.
- 23 hard errors + 24 empty patches (9.4% combined non-productive) — some improvement possible with better retry/fallback logic

## Reproduction

```bash
# 1. Install the exact runtime version
npm install @bahulam/code@<version>  # match framework 3.4.20 era

# 2. Configure env
export BAHULAM_API_KEY=<your b0_ token>
export EXPLORER_MODEL=deepseek/deepseek-v4-flash
export PLAN_MODEL=deepseek/deepseek-v4-flash

# 3. Run the harness
cd codekepler-npm
python3 benchmark/swe-bench/harness.py \
  --dataset verified \
  --model xiaomi/mimo-v2.5 \
  --parallel 4 \
  --timeout 600 \
  --output predictions.json

# 4. Docker eval (batched due to disk pressure — see docker-eval.log for the batch script)
python3 -m swebench.harness.run_evaluation \
  --predictions_path predictions.json \
  --dataset_name princeton-nlp/SWE-bench_Verified \
  --run_id my-verified-500 \
  --max_workers 4
```

## Artifacts

- `predictions.json` — 500 patches
- `docker-eval.json` — official evaluator report (final)
- `docker-eval-pre-retry.json` — pre-retry snapshot (see notes on batching in config.yaml)
- `costs.json` — cost + token breakdown
- `config.yaml` — full run configuration
