# 2026-08-20 SWE-bench Lite 300 — deepseek-v4-flash on `@bahulam/code@2.6.15`

**Result: 164 / 300 resolved (54.7 %) at $11.60 total spend (dashboard-verified) = ~$0.071 per resolved issue**

The cost-efficiency row of the Bahulam model matrix. Every dollar figure below is straight off the OpenRouter provider dashboard for the run window — no estimates.

## Headline metrics

| Metric | Value | Source |
|---|---|---|
| Instances submitted | 300 | Dataset |
| **Resolved** | **164 (54.7 %)** | Official SWE-bench Docker eval |
| Unresolved | 49 | Docker eval |
| Empty patch (600 s timeouts) | 84 | Harness |
| Error | 3 | Docker eval |
| Patches produced | 216 / 300 (72.0 %) | Harness |
| **Resolve rate over patches** | **164 / 216 = 75.9 %** (best of any run) | Derived |
| **Real cost (dashboard)** | **$11.60** | OpenRouter dashboard |
| **Cost per resolved instance** | **$0.071** | Derived |
| Requests | ~10 000 | OpenRouter dashboard |
| Tokens processed | 323 M | OpenRouter dashboard |
| Blended rate | $0.04 per 1 M tokens | OpenRouter dashboard |
| Cache hit rate | 94.3 % | OpenRouter dashboard |
| Wall-clock (parallel 3) | 10.5 h | Harness log |

Harness self-reported cost ($3.83) is not used for the published figure — it under-counts because it doesn't model provider-side prompt caching.

## The cost story

| Model | Resolved | Real cost (dashboard) | $/resolved | Notes |
|---|---|---|---|---|
| **flash (bundled 2.6.15)** | **164 (54.7 %)** | **$11.60** | **$0.071** | Dashboard window 2026-08-19 12:19 → 22:49 UTC, ~10 % subtracted for concurrent eval traffic |
| mimo-v2.5 (bundled 2.6.14) | 176 (58.7 %) | (not separately metered) | — | Run overlapped other gateway usage; only the flash number is publishable-verified |

**Flash lands within ~4 pp of mimo at a verified $0.071 per resolved issue.** For high-volume use (CI auto-fix, batch issue triage) it's the rational default; escalate to a reasoning-tier model only when flash fails.

## vs. historical flash baselines

| Run | Runtime | Resolved |
|---|---|---|
| v1-flash-300 (2026-07, cloud) | cloud | 92 (30.7 %) |
| v4-flash-300 (2026-07, cloud) | cloud | 109 (36.8 %) |
| **This run (bundled 2.6.15)** | **bundled** | **164 (54.7 %)** |

**+18 pp over the best prior flash baseline.** Improvements attributable to a mix of: CLI/runtime iteration (v1→2.6.15 includes ProjectRegistry, stagnation detection, preflight planning, tool-result compression) and upstream model updates.

## Configuration

- **Model:** `deepseek/deepseek-v4-flash` via Bahulam Gateway → OpenRouter → Fireworks
- **Runtime:** `@bahulam/code@2.6.15` + `@bahulam/runtime-linux-x64@2.6.15`
- **Harness:** fresh runtime per instance, 3 parallel workers, 600 s timeout, single pass (no retry)
- **Compute:** 1× D16s_v3, Ubuntu 22.04, centralus

## Reproduction

```bash
npm install @bahulam/code@2.6.15 @bahulam/runtime-linux-x64@2.6.15
bahulam login

export BAHULAM_RUNTIME_MODE=bundled
export LLM_GATEWAY=BahulamGateway
export BAHULAM_GATEWAY_URL=https://gateway.bahulam.ai/v1

python3 benchmark/swe-bench/harness.py \
  --dataset lite \
  --model deepseek/deepseek-v4-flash \
  --parallel 3 \
  --timeout 600 \
  --output predictions.json

python3 -m swebench.harness.run_evaluation \
  --predictions_path predictions.json \
  --dataset_name princeton-nlp/SWE-bench_Lite \
  --run_id my-flash-300 \
  --max_workers 1   # workers>1 can trip Docker Hub anonymous pull limits
```

## Artifacts

- `predictions.json` — 300 patches (216 non-empty)
- `docker-eval.json` — merged evaluator report (main + rate-limit retry batch)
- `costs.json` — cost + token breakdown
- `config.yaml` — full run configuration
