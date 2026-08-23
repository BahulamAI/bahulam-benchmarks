#!/usr/bin/env bash
# Concatenate shard-{1..N}/predictions.json + predictions-raw.json into
# canonical files at the run-dir root, then aggregate screening-report.json
# from the shard reports. Run on VM1 after all shards have pushed.
#
# Usage:
#   scripts/merge-shards.sh suites/screening/runs/<run_id>
set -euo pipefail

RUN_DIR="${1:-}"
if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  echo "usage: $0 <run-dir>" >&2
  exit 2
fi

SHARDS=("$RUN_DIR"/shard-*/)
if [[ ${#SHARDS[@]} -eq 0 || ! -d "${SHARDS[0]}" ]]; then
  echo "no shard-*/ subdirs found under $RUN_DIR" >&2
  exit 2
fi
echo "[merge] $RUN_DIR — ${#SHARDS[@]} shards"

# 1. Canonical predictions.json (SWE-bench eval format, dedup by instance_id).
python3 - "$RUN_DIR" << 'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
canonical = {}
for shard in sorted(run_dir.glob("shard-*/")):
    p = shard / "predictions.json"
    if not p.exists():
        print(f"  ! {shard.name}: missing predictions.json", file=sys.stderr)
        continue
    entries = json.loads(p.read_text())
    for e in entries:
        iid = e.get("instance_id")
        if iid and iid not in canonical:
            canonical[iid] = e
    print(f"  + {shard.name}: {len(entries)} entries")

merged = list(canonical.values())
out = run_dir / "predictions.json"
out.write_text(json.dumps(merged, indent=2))
patched = sum(1 for e in merged if e.get("model_patch"))
print(f"[merge] wrote {out} ({len(merged)} unique instances, {patched} patched)")
PY

# 2. Rich predictions-raw.json (full harness output, dedup by instance_id).
python3 - "$RUN_DIR" << 'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
merged = {}
first_meta = None
for shard in sorted(run_dir.glob("shard-*/")):
    p = shard / "predictions-raw.json"
    if not p.exists():
        continue
    d = json.loads(p.read_text())
    if first_meta is None:
        first_meta = {k: v for k, v in d.items() if k != "results"}
    for r in d.get("results", []):
        iid = r.get("instance_id")
        if iid and iid not in merged:
            merged[iid] = r

rich = dict(first_meta or {})
rich["results"] = list(merged.values())
rich["shards_merged"] = len([p for p in run_dir.glob("shard-*/predictions-raw.json")])
rich["total"] = len(merged)
out = run_dir / "predictions-raw.json"
out.write_text(json.dumps(rich, indent=2))
print(f"[merge] wrote {out} ({len(merged)} unique instances from {rich['shards_merged']} shards)")
PY

# 3. Aggregated screening-report.json (sum totals, weighted means, union tool_breakdown).
python3 - "$RUN_DIR" << 'PY'
import json
import sys
import statistics
from collections import Counter
from pathlib import Path

run_dir = Path(sys.argv[1])
shard_reports = []
for shard in sorted(run_dir.glob("shard-*/")):
    p = shard / "screening-report.json"
    if p.exists():
        shard_reports.append(json.loads(p.read_text()))

if not shard_reports:
    print("[merge] no shard reports found — skipping report aggregation", file=sys.stderr)
    sys.exit(0)

# Start from the first shard's shape; overwrite aggregated fields.
merged = dict(shard_reports[0])
merged["shards_merged"] = len(shard_reports)
merged["stage"] = "sharded-inference-complete"

# Sum totals.
totals_keys = [
    "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
    "reasoning_tokens", "tools_invoked", "sub_agent_invocations",
    "harness_cost_usd", "stagnation_triggers",
]
totals = {k: 0 for k in totals_keys}
for r in shard_reports:
    for k in totals_keys:
        totals[k] += (r.get("totals") or {}).get(k, 0) or 0
totals["harness_cost_usd"] = round(totals["harness_cost_usd"], 4)
merged["totals"] = totals

# Sum tool_breakdown.
tool_agg = Counter()
for r in shard_reports:
    for k, v in (r.get("tool_breakdown") or {}).items():
        tool_agg[k] += v
merged["tool_breakdown"] = dict(tool_agg)

# Sum outcome_counts.
outcome_agg = Counter()
for r in shard_reports:
    for k, v in (r.get("outcome_counts") or {}).items():
        outcome_agg[k] += v
merged["outcome_counts"] = dict(outcome_agg)

# Cache metrics.
if totals["input_tokens"]:
    merged["cache"] = {
        "cache_read_tokens": totals["cache_read_tokens"],
        "cache_write_tokens": totals["cache_write_tokens"],
        "cache_hit_ratio_input": round(totals["cache_read_tokens"] / totals["input_tokens"], 4),
    }

# Recompute distributions from the merged predictions-raw.json.
raw_p = run_dir / "predictions-raw.json"
if raw_p.exists():
    raw = json.loads(raw_p.read_text())
    results = raw.get("results", [])
    def _series(path):
        cur_list = []
        for r in results:
            cur = r
            for p in path.split("."):
                cur = (cur or {}).get(p) if isinstance(cur, dict) else None
            cur_list.append(cur if cur is not None else 0)
        return cur_list
    def _dist(vals):
        if not vals:
            return {"n": 0, "mean": 0, "median": 0, "p95": 0, "min": 0, "max": 0, "sum": 0}
        s = sorted(vals)
        idx = min(len(s) - 1, int(round(0.95 * (len(s) - 1))))
        return {
            "n": len(vals),
            "mean": round(sum(vals) / len(vals), 4),
            "median": round(statistics.median(vals), 4),
            "p95": round(s[idx], 4),
            "min": round(min(vals), 4),
            "max": round(max(vals), 4),
            "sum": round(sum(vals), 4),
        }
    merged["distributions"] = {
        "cost_usd": _dist(_series("kepler.cost_usd")),
        "duration_s": _dist(_series("kepler.duration_s")),
        "input_tokens": _dist(_series("kepler.usage.input_tokens")),
        "output_tokens": _dist(_series("kepler.usage.output_tokens")),
        "tools_per_instance": _dist([float(x) for x in _series("kepler.tools")]),
    }
    n = len(results)
    patched = sum(1 for r in results if r.get("model_patch"))
    # tool_call_emission_rate = fraction of instances where the CLI called
    # at least one tool. Aligns with screen.py's schema (zero-tool timeouts
    # are the "gave up" signal). Denominator is total submitted, not patched.
    zero_tool = sum(
        1 for r in results
        if ((r.get("kepler") or {}).get("tools") or 0) == 0
        and ((r.get("kepler") or {}).get("duration_s") or 0) >= 500
    )
    tool_emit_rate = round((n - zero_tool) / n, 4) if n else 0

    merged["metrics"] = {
        "instances_submitted": n,
        "patched": patched,
        "patch_rate": round(patched / n, 4) if n else 0,
        "tool_call_emission_rate": tool_emit_rate,
        "zero_tool_timeout_count": zero_tool,
        "avg_duration_s": round(sum(merged["distributions"]["duration_s"].get("sum") for _ in [1]) / n, 1) if n else 0,
        "avg_input_tokens": int(totals["input_tokens"] / n) if n else 0,
        "avg_output_tokens": int(totals["output_tokens"] / n) if n else 0,
        "cache_hit_pct": round(totals["cache_read_tokens"] / totals["input_tokens"], 4) if totals["input_tokens"] else None,
        "harness_cost_usd": totals["harness_cost_usd"],
        "harness_cost_per_patched_usd": round(totals["harness_cost_usd"] / patched, 4) if patched else None,
        "total_tools_invoked": totals["tools_invoked"],
    }
    merged["run_finished_at"] = max(
        (r.get("run_finished_at") for r in shard_reports if r.get("run_finished_at")),
        default=merged.get("run_finished_at"),
    )
    merged["run_started_at"] = min(
        (r.get("run_started_at") for r in shard_reports if r.get("run_started_at")),
        default=merged.get("run_started_at"),
    )

out = run_dir / "screening-report.json"
out.write_text(json.dumps(merged, indent=2))
print(f"[merge] wrote aggregated {out} — patched={merged['metrics'].get('patched')}/{merged['metrics'].get('instances_submitted')}")
PY

echo "[merge] DONE — canonical predictions.json ready for docker eval"
