# stealth/ox-alpha — screening run 2026-08-22

**Verdict:** REJECT
**Reason:** tool_call_emission_rate failed

## Results

- Submitted: **300**
- Patched:   **194** (64.7% patch rate)
- **Resolved: 181** (60.3% resolve rate)
- Patched → tests-pass: **93.3%**
- Cache hit rate: 95.5%
- Wall clock: 5875.9 s
- CLI version: 0.1.1

## Cost

- **Real cost: $0** (`stealth/ox-alpha` is on OpenRouter's free tier for this run window)
- `harness_cost_usd` field reflects placeholder catalog pricing (input=$0.30/1M, output=$1/1M) — not real

## Gates

| Gate | Actual | Threshold | Verdict |
|---|---|---|---|
| `resolve_rate` | 0.6033 | >= 0.3 | **PASS** |
| `cache_hit_pct` | 0.9545 | >= 0.7 | **PASS** |
| `tool_call_emission_rate` | 0.8333 | >= 0.9 | **FAIL** |
| `cost_per_resolved_usd` | 0.0 | <= 2.0 | **PASS** |
| `dashboard_cost_usd` | — | — | SKIP (n/a for free-tier model) |
| `cost_delta_pct` | — | — | SKIP (n/a for free-tier model) |
| `resolve_per_patch` | 0.933 | >= 0.6 | **PASS** |
| `reasoning_token_ratio` | — | — | SKIP (n/a for non-reasoning model) |

## Run configuration

- Shards: 5 × 60 instances (round-robin split of SWE-Lite 300)
- Parallel per shard: 3 (initial) / 6 (resume)
- Timeout per instance: 1200 s
- Salvaged 39 in-flight instances from initial single-service run into shard seeds

## Files in this run

- `predictions.json` — canonical SWE-bench format for docker eval
- `predictions-raw.json` — full harness output with per-instance kepler data
- `screening-report.json` — machine-readable v2 report (this file's source)
- `docker-eval.json` — SWE-bench harness evaluator output
- `pricing.json` — OpenRouter pricing snapshot at run time
- `preflight-tools.json` — gateway tools-param probe result
- `shard-{1..5}/` — per-shard artifacts (used by merge-shards.sh)
- `shard-partial/` — pre-shard salvage of first run's 39 in-flight results
- `seeds/` — the 5 shard-N-seed.json files that pre-populated each shard
