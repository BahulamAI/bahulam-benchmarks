# xiaomi/mimo-v2.5 — screening run 2026-08-23

**Verdict:** PASS

## Results (best Bahulam Code + bundled-CLI result to date)

- Submitted: **300**
- Patched:   **265** (88.3% patch rate)
- **Resolved: 189** (63.0% resolve rate)
- Resolve / patched: 71.3%
- Cache hit rate: 95.7%
- Wall clock: 4339.3 s (Railway inference)
- CLI version: 0.1.1

## Head-to-head

| Model | Resolve rate | Patch rate | Resolve/patched |
|---|---|---|---|
| **xiaomi/mimo-v2.5 (this run)** | **63.0%** | 88.3% | 71.3% |
| v8-mimo-v2.5 (proprietary multi-model harness, Jul 2026) | 62.0% | 96.3% | 64.4% |
| stealth/ox-alpha (free) | 60.3% | 64.7% | 93.3% |
| deepseek/deepseek-v4-flash (published) | 54.7% | 72.0% | 75.9% |

## Gates

| Gate | Actual | Threshold | Verdict |
|---|---|---|---|
| `resolve_rate` | 0.63 | >= 0.3 | **PASS** |
| `cache_hit_pct` | 0.9574 | >= 0.7 | **PASS** |
| `tool_call_emission_rate` | 0.9267 | >= 0.9 | **PASS** |
| `cost_per_resolved_usd` | 0.0 | <= 2.0 | **PASS** |
| `dashboard_cost_usd` | — | — | SKIP (n/a for free-tier model) |
| `cost_delta_pct` | — | — | SKIP (n/a for free-tier model) |
| `resolve_per_patch` | 0.7132 | >= 0.6 | **PASS** |
| `reasoning_token_ratio` | — | — | SKIP (n/a for non-reasoning model) |
