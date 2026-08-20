#!/usr/bin/env python3
"""Bahulam model screening — verification stage (runs on VM).

Sequence:
  1. Consume the partial screening-report.json + predictions.json from Railway
  2. Run swebench.harness.run_evaluation in Docker
  3. Query the OpenRouter dashboard for the run window (or accept a provided cost)
  4. Compute final metrics
  5. Run all gates from configs/gates.yaml
  6. Emit the final screening-report.json with a REJECT / PASS / PROVISIONAL verdict

Usage:
    python verify-and-report.py \\
        --screen-dir /path/to/screen-<model>-<date>/ \\
        --dashboard-cost-usd 3.42 \\
        [--force-reasoning-model]  # tightens gates for reasoning models

The dashboard cost is REQUIRED and MUST be pasted from the OpenRouter
dashboard for the exact run window. Harness self-reported cost is not trusted.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

SCREEN_DIR = Path(__file__).resolve().parent.parent
GATES_FILE = SCREEN_DIR / "configs" / "gates.yaml"


def load_yaml(p: Path) -> dict:
    """Tiny yaml loader — avoids adding PyYAML dependency for the VM script."""
    try:
        import yaml  # type: ignore
        return yaml.safe_load(p.read_text())
    except ImportError:
        raise SystemExit("PyYAML required for gate parsing: pip install pyyaml")


def run_docker_eval(predictions: Path, output_dir: Path, run_id: str) -> Path:
    """Invoke swebench.harness.run_evaluation. Returns path to the report JSON."""
    print(f"[verify] docker eval: {predictions} -> {output_dir}", flush=True)
    cmd = [
        "python", "-m", "swebench.harness.run_evaluation",
        "--predictions_path", str(predictions),
        "--dataset_name", "princeton-nlp/SWE-bench_Lite",
        "--run_id", run_id,
        "--max_workers", "1",
    ]
    log = output_dir / "docker-eval.log"
    with open(log, "w") as f:
        rc = subprocess.call(cmd, cwd=output_dir, stdout=f, stderr=subprocess.STDOUT)
    if rc != 0:
        print(f"[verify] docker eval rc={rc}, continuing to collect what landed", flush=True)
    # Find the report — swebench writes it next to cwd, filename = <model_name_or_path>.<run_id>.json
    candidates = list(output_dir.glob("*.json"))
    for c in candidates:
        try:
            d = json.loads(c.read_text())
            if "submitted_instances" in d and "resolved_instances" in d:
                return c
        except Exception:
            continue
    raise SystemExit(f"[verify] docker eval report not found in {output_dir}")


def evaluate_gates(metrics: dict, gates: list, is_reasoning: bool) -> tuple[list, str]:
    """Return (per-gate results, overall verdict)."""
    results = []
    all_pass = True
    for g in gates:
        applies = g.get("applies_to")
        if applies == "reasoning_models" and not is_reasoning:
            results.append({"metric": g["metric"], "skipped": True, "reason": "n/a for non-reasoning model"})
            continue

        threshold = g.get("reasoning_model_value") if is_reasoning and g.get("reasoning_model_value") is not None else g["value"]
        op = g["op"]
        actual = metrics.get(g["metric"])
        if actual is None:
            results.append({"metric": g["metric"], "actual": None, "threshold": threshold, "op": op, "passed": False, "reason": "metric missing from screen"})
            all_pass = False
            continue

        if op == ">=":
            passed = actual >= threshold
        elif op == "<=":
            passed = actual <= threshold
        elif op == ">":
            passed = actual > threshold
        elif op == "<":
            passed = actual < threshold
        else:
            raise ValueError(f"unknown op {op}")

        results.append({
            "metric": g["metric"],
            "actual": actual,
            "threshold": threshold,
            "op": op,
            "passed": bool(passed),
        })
        if not passed:
            all_pass = False

    verdict = "PASS" if all_pass else "REJECT"
    return results, verdict


def compute_full_300_projection(metrics: dict, gates_yaml: dict, is_reasoning: bool) -> dict:
    """Extrapolate screen cost/resolve to full-300."""
    mult = float(gates_yaml.get("projection", {}).get("full_300_cost_multiplier", 15.0))
    penalty = float(gates_yaml.get("projection", {}).get("cache_hit_scale_penalty_reasoning", 0.10))
    projected_cost = metrics.get("dashboard_cost_usd", 0) * mult
    projected_resolve = metrics.get("resolve_rate", 0) * 300
    projected_cache = metrics.get("cache_hit_pct", 0)
    if is_reasoning:
        projected_cache = max(0.0, projected_cache - penalty)
    return {
        "full_300_cost_usd": round(projected_cost, 2),
        "full_300_resolved": int(projected_resolve),
        "full_300_cost_per_resolved_usd": round(projected_cost / projected_resolve, 3) if projected_resolve else None,
        "full_300_cache_hit_pct": round(projected_cache, 3),
        "notes": f"cost * {mult}x (accounts for sympy/sphinx tail); cache penalty {penalty} for reasoning models",
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--screen-dir", required=True, type=Path, help="Dir containing predictions.json + screening-report.json from Railway")
    ap.add_argument("--dashboard-cost-usd", required=True, type=float, help="Real cost from OpenRouter dashboard for the run window")
    ap.add_argument("--force-reasoning-model", action="store_true", help="Apply reasoning-model-specific gates + cache penalty")
    ap.add_argument("--run-id", default=None, help="Override docker eval run_id (default: derives from screen-dir)")
    args = ap.parse_args()

    screen_dir = args.screen_dir
    partial_report_path = screen_dir / "screening-report.json"
    if not partial_report_path.exists():
        raise SystemExit(f"missing {partial_report_path} — did the Railway screen complete?")
    partial = json.loads(partial_report_path.read_text())

    if partial.get("gates_verdict") == "REJECT":
        print(f"[verify] pre-flight already rejected — nothing to verify. Reason: {partial['gates_reason']}", flush=True)
        return

    predictions = screen_dir / "predictions.json"
    if not predictions.exists():
        raise SystemExit(f"missing {predictions}")

    # 1. docker eval
    run_id = args.run_id or f"screen-{screen_dir.name}"
    docker_report_path = run_docker_eval(predictions, screen_dir, run_id)
    docker = json.loads(docker_report_path.read_text())
    print(f"[verify] docker eval: {docker.get('resolved_instances')} resolved / {docker.get('submitted_instances')} submitted", flush=True)

    # 2. merge metrics
    metrics = dict(partial.get("metrics", {}))
    n = metrics.get("instances_submitted", 30)
    resolved = docker.get("resolved_instances", 0)
    patched = metrics.get("patched", 1)
    metrics["resolved"] = resolved
    metrics["resolve_rate"] = round(resolved / n, 3) if n else 0
    metrics["resolve_per_patch"] = round(resolved / patched, 3) if patched else 0
    metrics["dashboard_cost_usd"] = args.dashboard_cost_usd
    metrics["cost_per_resolved_usd"] = round(args.dashboard_cost_usd / resolved, 3) if resolved else None
    harness_cost = metrics.get("harness_cost_usd") or 0
    metrics["cost_delta_pct"] = round(abs(args.dashboard_cost_usd - harness_cost) / max(harness_cost, 0.01) * 100, 1)

    # 3. gates
    gates_yaml = load_yaml(GATES_FILE)
    is_reasoning = args.force_reasoning_model or any(k in partial.get("model", "").lower() for k in ("sol", "o1", "o3", "o4", "reason", "-r1", "-mimo", "m3"))
    gate_results, verdict = evaluate_gates(metrics, gates_yaml["gates"], is_reasoning)
    projection = compute_full_300_projection(metrics, gates_yaml, is_reasoning)

    # 4. final report
    final = {
        **partial,
        "stage": "verified",
        "docker_eval": {
            "resolved_instances": resolved,
            "unresolved_instances": docker.get("unresolved_instances"),
            "empty_patch_instances": docker.get("empty_patch_instances"),
            "error_instances": docker.get("error_instances"),
            "report_path": docker_report_path.name,
        },
        "metrics": metrics,
        "is_reasoning_model": is_reasoning,
        "gate_results": gate_results,
        "gates_verdict": verdict,
        "full_300_projection": projection,
    }
    (screen_dir / "screening-report.json").write_text(json.dumps(final, indent=2))

    # 5. print summary
    print("\n" + "=" * 60)
    print(f"MODEL: {final['model']}")
    print(f"VERDICT: {verdict}")
    print(f"is_reasoning: {is_reasoning}")
    print("=" * 60)
    print("Metrics:")
    for k, v in metrics.items():
        print(f"  {k:30s} {v}")
    print()
    print("Gates:")
    for g in gate_results:
        if g.get("skipped"):
            print(f"  SKIP  {g['metric']:30s} — {g['reason']}")
            continue
        mark = "PASS" if g["passed"] else "FAIL"
        print(f"  {mark}  {g['metric']:30s} actual={g['actual']} {g['op']} {g['threshold']}")
    print()
    print("Full-300 projection:")
    for k, v in projection.items():
        print(f"  {k:30s} {v}")
    print("=" * 60)


if __name__ == "__main__":
    main()
