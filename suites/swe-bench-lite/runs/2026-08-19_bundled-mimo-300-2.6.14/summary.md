# 2026-08-19 SWE-bench Lite 300 — mimo v2.5 on `@bahulam/code@2.6.14` bundled CLI

**Result: 176 / 300 resolved (58.7 %)**

First result on the public `@bahulam/code` npm bundled runtime path — this is what an end user installing the CLI actually runs, not the cloud backend.

## Headline metrics

| Metric | Value |
|---|---|
| Instances submitted | 300 |
| **Resolved** | **176 (58.7 %)** |
| Unresolved | 67 |
| Empty patch (timeouts even at 900s) | 56 |
| Error | 1 |
| Patches produced | 244 / 300 (81.3 %) |
| Resolve rate over patches | 176 / 244 = 72.1 % |
| Cost harness estimate | $75 |
| Cost real (dashboard-calibrated ~×1/50) | ~$1.60 |
| Cache hit rate | 95 %+ |
| Avg per-instance wall-clock | ~4-5 min |

## Comparison to v8-mimo-300 (cloud backend, July 2026)

| Version | Runtime | Patched | Resolved | Rate |
|---|---|---|---|---|
| v8-mimo-300 | cloud backend | 289 / 300 (96.3 %) | **186 / 300** | **62.0 %** |
| **2026-08-19 bundled** | **`@bahulam/code@2.6.14`** | **244 / 300 (81.3 %)** | **176 / 300** | **58.7 %** |
| Delta | — | −45 patches | **−10 resolved** | **−3.3 pp** |

**Where the gap comes from:**
- Patch-rate deficit: 81% vs 96% = 45 fewer patches produced
- Of the 56 empty-patch instances, most are 900s timeouts (retried once with 900s budget; only 10 recovered)
- Resolve-per-patch rate is actually competitive: 72.1% here vs 64.4% for v8 baseline (186/289)

**Why the bundled path is publishable-important despite the ~3pp gap:**
- This is what end users install (`npm install @bahulam/code`)
- Publishing cloud-backend numbers overstates what customers experience
- 58.7% on public CLI is competitive with most non-frontier scaffolds

## Run history (this run took ~40 hours real-time with pauses)

1. **2026-08-17 18:23 UTC** — Kicked off `harness.py --dataset lite --model xiaomi/mimo-v2.5 --parallel 1 --timeout 600`
2. **2026-08-18 ~02:30 UTC** — Credits exhausted at ~instance 95 (silent 402s → empty patches for instances 96-172)
3. **2026-08-18 ~02:57 UTC** — Filtered credit-fail stubs from results.json, topped up credits, resumed with `--skip-done`
4. **2026-08-19 ~00:15 UTC** — Harness completed 300 (234 patched, 66 empty)
5. **2026-08-19 ~02:00 UTC** — 900s retry pass on 61 timeouts, `--parallel 3`
6. **2026-08-19 ~10:44 UTC** — Retry produced 10 new patches (16.4% recovery)
7. **2026-08-19 ~10:50 UTC** — Docker eval consolidation: 176 total resolved

## Where we resolved and where we didn't

- **Resolved 176** — spread across all repositories, strong on astropy, django, sympy
- **Unresolved 67** — most in matplotlib and sphinx (visual/documentation edge cases)
- **Empty 56** — hard timeouts, mostly requests/pytest/django-migrations (large-search-space instances)

## Configuration

- **Model:** `xiaomi/mimo-v2.5` (primary) via Bahulam Gateway → OpenRouter → Xiaomi native
- **Sub-agents:** available in schema (43-tool set including explore/plan/verify/debug/refactor) but mimo rarely invoked them in this run
- **Runtime:** `@bahulam/runtime-linux-x64@2.6.14` (matching CLI version, self-contained)
- **Compute:** 1× D16s_v3 (16 vCPU, 64 GB RAM), Ubuntu 22.04, centralus
- **Harness:** `benchmark/swe-bench/harness.py` (fresh runtime per instance)

## Reproduction

```bash
# 1. Install the CLI + runtime
npm install @bahulam/code@2.6.14 @bahulam/runtime-linux-x64@2.6.14

# 2. Auth (once) — writes ~/.bahulam/config.json
bahulam login    # or export BAHULAM_API_KEY=<your b0_ token>

# 3. Configure benchmark env
export BAHULAM_RUNTIME_MODE=bundled
export LLM_GATEWAY=BahulamGateway
export BAHULAM_GATEWAY_URL=https://gateway.bahulam.ai/v1

# 4. Run harness (from a clone of the source tree)
python3 benchmark/swe-bench/harness.py \
  --dataset lite \
  --model xiaomi/mimo-v2.5 \
  --parallel 1 \
  --timeout 600 \
  --output predictions.json

# 5. Optional: retry timeouts at 900s
python3 benchmark/swe-bench/harness.py \
  --dataset lite --model xiaomi/mimo-v2.5 \
  --parallel 3 --timeout 900 --skip-done \
  --output predictions.json

# 6. Docker eval
python3 -m swebench.harness.run_evaluation \
  --predictions_path predictions.json \
  --dataset_name princeton-nlp/SWE-bench_Lite \
  --run_id my-bundled-mimo-300 \
  --max_workers 4
```

## Artifacts

- `predictions.json` — 300 patches (244 non-empty)
- `docker-eval.json` — merged evaluator report (3 batches consolidated)
- `costs.json` — harness cost estimate, real dashboard cost, token totals
- `config.yaml` — full run configuration
