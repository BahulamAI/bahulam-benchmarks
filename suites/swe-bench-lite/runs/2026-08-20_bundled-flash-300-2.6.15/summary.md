# 2026-08-20 SWE-bench Lite 300 — deepseek-v4-flash on `@bahulam/code@2.6.15`

**Result: 164 / 300 resolved (54.7 %) at ~$0.08 total cost**

The cost-efficiency row of the Bahulam model matrix: near-mimo resolution quality at **1/20th the cost**.

## Headline metrics

| Metric | Value |
|---|---|
| Instances submitted | 300 |
| **Resolved** | **164 (54.7 %)** |
| Unresolved | 49 |
| Empty patch (600s timeouts) | 84 |
| Error | 3 |
| Patches produced | 216 / 300 (72.0 %) |
| **Resolve rate over patches** | **164 / 216 = 75.9 %** (best of any run) |
| Cost harness estimate | $3.83 |
| **Cost real (dashboard)** | **~$0.08** |
| **Cost per resolved instance** | **~$0.0005** |
| Cache hit rate | ~94 % |
| Wall-clock (parallel 3) | 10.5 h |

## The cost story

| Model | Resolved | Total real cost | $/resolved |
|---|---|---|---|
| mimo-v2.5 (bundled 2.6.14) | 176 (58.7 %) | ~$1.60 | $0.009 |
| **flash (bundled 2.6.15)** | **164 (54.7 %)** | **~$0.08** | **$0.0005** |

Giving up 4 pp of resolution buys a **20× cost reduction**. For high-volume use (CI auto-fix, batch issue triage), flash is the economically rational default; escalate to mimo/pro only when flash fails.

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
