#!/usr/bin/env python3
"""Bahulam model screening — inference stage.

Runs on Railway (cheap container, no Docker). Sequence:
  1. Pre-flight: verify `tools` accepted by the gateway for this model
  2. Pre-flight: snapshot OpenRouter pricing for this model
  3. Invoke the standard swe-bench harness on the 30-instance screening set
  4. Emit predictions.json + probe.json + a partial screening-report.json

Docker eval + dashboard-verify + final gate check happen later on the VM
(see scripts/verify-and-report.py). This script deliberately does not
try to run Docker — Railway containers don't have it and we don't want them to.

Usage:
    python screen.py --model <slug> --output-dir /data/screen-<slug>-<date>
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

SCREEN_DIR = Path(__file__).resolve().parent
CONFIGS = SCREEN_DIR / "configs"
# Instance file is env-switchable so we can flip 5 → 30 → 300 without rebuilds.
# Accepts a bare filename (resolved under configs/) or an absolute path.
_ifile_env = os.environ.get("SCREENING_INSTANCE_FILE", "screening-30.txt")
INSTANCES_FILE = Path(_ifile_env) if os.path.isabs(_ifile_env) else CONFIGS / _ifile_env
GATES_FILE = CONFIGS / "gates.yaml"

GATEWAY_URL = os.environ.get("BAHULAM_GATEWAY_URL", "https://gateway.bahulam.ai/v1")
B0_TOKEN = os.environ.get("B0_TOKEN") or os.environ.get("BAHULAM_API_KEY")
BUNDLED_CLI_DIR = os.environ.get("BAHULAM_CLI_DIR", "/opt/bahulam-cli")
HARNESS_TIMEOUT_S = int(os.environ.get("HARNESS_TIMEOUT_S", "600"))
HARNESS_PARALLEL = int(os.environ.get("HARNESS_PARALLEL", "3"))


def _http_json(url: str, headers: dict, method: str = "GET", body: bytes | None = None, timeout: float = 30.0) -> tuple[int, Any]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {"error": str(e)}
    except Exception as e:
        return -1, {"error": str(e)}


def preflight_tools_accepted(model: str) -> dict:
    """Probe: does the gateway route `tools` through for this model?"""
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": "Use tools when asked."},
            {"role": "user", "content": "Call the read_file tool with path='/tmp/x'."},
        ],
        "tools": [{
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a file",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        }],
        "tool_choice": "auto",
        "max_tokens": 50,
    }).encode()
    status, resp = _http_json(
        f"{GATEWAY_URL}/chat/completions",
        {"Authorization": f"Bearer {B0_TOKEN}", "Content-Type": "application/json"},
        method="POST",
        body=body,
        timeout=60.0,
    )
    result = {
        "http": status,
        "passed": False,
        "reason": None,
        "sample_response": None,
    }
    if status != 200:
        result["reason"] = f"HTTP {status}: {json.dumps(resp)[:300]}"
        return result
    try:
        msg = resp["choices"][0]["message"]
        has_tool_calls = bool(msg.get("tool_calls"))
        finish = resp["choices"][0].get("finish_reason")
        result["sample_response"] = {
            "finish_reason": finish,
            "has_tool_calls": has_tool_calls,
            "provider": resp.get("provider"),
        }
        if not has_tool_calls:
            result["reason"] = (
                f"Model returned finish={finish!r} without emitting tool_calls. "
                "Either the provider strips `tools` or the model doesn't support "
                "function calling on this endpoint."
            )
            return result
        result["passed"] = True
    except (KeyError, IndexError) as e:
        result["reason"] = f"Malformed response: {e}"
    return result


def preflight_pricing(model: str) -> dict:
    """Fetch live pricing from OpenRouter for this model. Best-effort — the
    Bahulam Gateway proxies OpenRouter, so the same slug should resolve."""
    slug = model
    status, resp = _http_json(
        f"https://openrouter.ai/api/v1/models/{slug}/endpoints",
        {"Accept": "application/json"},
        timeout=15.0,
    )
    if status != 200:
        return {"http": status, "endpoints": [], "error": resp.get("error", "unknown")}
    endpoints = []
    for ep in (resp.get("data", {}) or {}).get("endpoints", []):
        pricing = ep.get("pricing", {}) or {}
        endpoints.append({
            "provider": ep.get("provider_name") or ep.get("name"),
            "input_usd_per_1m": float(pricing.get("prompt", 0)) * 1_000_000 if pricing.get("prompt") else None,
            "output_usd_per_1m": float(pricing.get("completion", 0)) * 1_000_000 if pricing.get("completion") else None,
            "cache_read_usd_per_1m": float(pricing.get("input_cache_read", 0)) * 1_000_000 if pricing.get("input_cache_read") else None,
            "context_length": ep.get("context_length"),
            "supports_tools": (ep.get("supported_parameters") or []).__contains__("tools"),
        })
    return {"http": 200, "endpoints": endpoints}


def run_harness(model: str, output_json: Path, log_path: Path) -> int:
    """Invoke the standard swe-bench harness against the 30-instance screen set."""
    harness_py = Path(BUNDLED_CLI_DIR) / "benchmark" / "swe-bench" / "harness.py"
    if not harness_py.exists():
        raise SystemExit(f"harness.py not found at {harness_py} — check BAHULAM_CLI_DIR")

    cmd = [
        "python3", str(harness_py),
        "--dataset", "lite",
        "--model", model,
        "--parallel", str(HARNESS_PARALLEL),
        "--timeout", str(HARNESS_TIMEOUT_S),
        "--instance-file", str(INSTANCES_FILE),
        "--output", str(output_json),
        "--skip-done",
    ]
    print(f"[screen] launching: {' '.join(cmd)}", flush=True)
    started = time.time()
    with open(log_path, "w") as logf:
        proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT)
        rc = proc.wait()
    dur = time.time() - started
    print(f"[screen] harness exited rc={rc} after {dur:.0f}s", flush=True)
    return rc


def _dist(values: list[float]) -> dict:
    """Mean/median/p95/min/max/sum for a numeric series. Zero-safe."""
    if not values:
        return {"n": 0, "mean": 0, "median": 0, "p95": 0, "min": 0, "max": 0, "sum": 0}
    s = sorted(values)
    p95_idx = min(len(s) - 1, int(round(0.95 * (len(s) - 1))))
    return {
        "n": len(values),
        "mean": round(sum(values) / len(values), 4),
        "median": round(statistics.median(values), 4),
        "p95": round(s[p95_idx], 4),
        "min": round(min(values), 4),
        "max": round(max(values), 4),
        "sum": round(sum(values), 4),
    }


def _cli_version() -> str:
    """Read @bahulam/code version from the globally-installed package."""
    try:
        pkg = Path(BUNDLED_CLI_DIR) / "package.json"
        return json.loads(pkg.read_text()).get("version", "unknown")
    except Exception as e:
        return f"unknown ({e})"


def _harness_git_sha() -> str:
    """The vendored harness's git provenance, if we baked a SHA in via ARG."""
    return os.environ.get("HARNESS_GIT_SHA", "vendored-unpinned")


def _env_metadata() -> dict:
    """Reproducibility fields — what container/deployment produced this run."""
    return {
        "hostname": socket.gethostname(),
        "railway_deployment_id": os.environ.get("RAILWAY_DEPLOYMENT_ID"),
        "railway_service_id": os.environ.get("RAILWAY_SERVICE_ID"),
        "railway_project_id": os.environ.get("RAILWAY_PROJECT_ID"),
        "railway_region": os.environ.get("RAILWAY_REGION"),
        "python": sys.version.split()[0],
    }


def build_partial_report(
    model: str,
    output_dir: Path,
    preflight: dict,
    pricing: dict,
    results_path: Path,
    run_started_at: str,
    run_finished_at: str,
) -> dict:
    """Aggregate everything the screen collected on Railway. Docker eval and
    dashboard verification happen later on the VM and get merged in by
    verify-and-report.py.

    schema_version=2 — per-metric distributions, tool breakdown, outcome counts,
    reproducibility metadata, and cross-run comparable totals."""
    wall_clock = None
    try:
        s = _dt.datetime.fromisoformat(run_started_at.replace("Z", "+00:00"))
        f = _dt.datetime.fromisoformat(run_finished_at.replace("Z", "+00:00"))
        wall_clock = round((f - s).total_seconds(), 1)
    except Exception:
        pass

    report = {
        "schema_version": 2,
        "run_id": None,  # filled by caller (needs model + date)
        "run_started_at": run_started_at,
        "run_finished_at": run_finished_at,
        "wall_clock_seconds": wall_clock,
        "stage": "railway-inference-complete",
        "gates_verdict": "PENDING-VM",
        "gates_pending_vm": [
            "resolve_rate",
            "resolve_per_patch",
            "dashboard_cost_usd",
            "cost_delta_pct",
        ],
        "model": {
            "slug": model,
        },
        "harness": {
            "cli_version": _cli_version(),
            "cli_package": f"@bahulam/code@{_cli_version()}",
            "harness_git_sha": _harness_git_sha(),
            "gateway_url": GATEWAY_URL,
            "dataset": "swe-bench-lite",
            "instance_file": str(INSTANCES_FILE.name),
            "instance_count": None,  # filled below
            "parallel": HARNESS_PARALLEL,
            "timeout_s": HARNESS_TIMEOUT_S,
        },
        "environment": _env_metadata(),
        "preflight": preflight,
        "pricing_snapshot_path": "pricing.json",
        "totals": {},
        "distributions": {},
        "cache": {},
        "tool_breakdown": {},
        "outcome_counts": {},
        "metrics": {},
    }

    if not results_path.exists():
        report["error"] = "harness produced no results.json — see harness.log"
        return report

    d = json.loads(results_path.read_text())
    results = d.get("results", [])
    n = len(results)
    report["harness"]["instance_count"] = n
    if n == 0:
        report["error"] = "results.json is empty"
        return report

    def _k(r, path, default=0):
        """Safe nested get: _k(r, 'kepler.usage.input_tokens')."""
        cur = r
        for p in path.split("."):
            cur = (cur or {}).get(p) if isinstance(cur, dict) else None
        return cur if cur is not None else default

    # per-instance series
    durations = [_k(r, "kepler.duration_s") for r in results]
    costs = [_k(r, "kepler.cost_usd") for r in results]
    inputs = [_k(r, "kepler.usage.input_tokens") for r in results]
    outputs = [_k(r, "kepler.usage.output_tokens") for r in results]
    cache_reads = [_k(r, "kepler.usage.cache_read") for r in results]
    cache_writes = [_k(r, "kepler.usage.cache_write") for r in results]
    reasoning = [_k(r, "kepler.usage.reasoning_tokens") for r in results]
    tools = [_k(r, "kepler.tools") for r in results]
    stagnations = [_k(r, "kepler.stagnation_triggers") for r in results]
    sub_agents_ct = [len(_k(r, "kepler.sub_agents", []) or []) for r in results]

    tot_in = sum(inputs)
    tot_out = sum(outputs)
    tot_cr = sum(cache_reads)
    tot_cw = sum(cache_writes)
    tot_reason = sum(reasoning)
    total_tools = sum(tools)
    harness_cost = sum(costs)

    patched = sum(1 for r in results if r.get("model_patch"))
    zero_tool_long = sum(
        1 for r in results
        if not r.get("model_patch")
        and _k(r, "kepler.tools") == 0
        and _k(r, "kepler.duration_s") >= 500
    )

    # tool breakdown aggregated across instances
    tool_agg: Counter = Counter()
    for r in results:
        for k, v in (_k(r, "kepler.tool_breakdown", {}) or {}).items():
            tool_agg[k] += v

    # outcome counts by status field
    outcomes = Counter(r.get("status", "unknown") for r in results)

    report["totals"] = {
        "input_tokens": tot_in,
        "output_tokens": tot_out,
        "cache_read_tokens": tot_cr,
        "cache_write_tokens": tot_cw,
        "reasoning_tokens": tot_reason,
        "tools_invoked": total_tools,
        "sub_agent_invocations": sum(sub_agents_ct),
        "harness_cost_usd": round(harness_cost, 4),
        "stagnation_triggers": sum(stagnations),
    }
    report["distributions"] = {
        "cost_usd": _dist(costs),
        "duration_s": _dist(durations),
        "input_tokens": _dist(inputs),
        "output_tokens": _dist(outputs),
        "tools_per_instance": _dist([float(t) for t in tools]),
    }
    report["cache"] = {
        "cache_read_tokens": tot_cr,
        "cache_write_tokens": tot_cw,
        "cache_hit_ratio_input": round(tot_cr / tot_in, 4) if tot_in else None,
    }
    report["tool_breakdown"] = dict(tool_agg)
    report["outcome_counts"] = dict(outcomes)
    report["metrics"] = {
        "instances_submitted": n,
        "patched": patched,
        "patch_rate": round(patched / n, 4),
        "tool_call_emission_rate": round((n - zero_tool_long) / n, 4),
        "zero_tool_timeout_count": zero_tool_long,
        "avg_duration_s": round(sum(durations) / n, 1),
        "avg_input_tokens": int(tot_in / n) if n else 0,
        "avg_output_tokens": int(tot_out / n) if n else 0,
        "cache_hit_pct": round(tot_cr / tot_in, 4) if tot_in else None,
        "reasoning_token_ratio": (
            round(tot_reason / max(tot_out - tot_reason, 1), 4) if tot_reason else 0
        ),
        "harness_cost_usd": round(harness_cost, 4),
        "harness_cost_per_patched_usd": (
            round(harness_cost / patched, 4) if patched else None
        ),
        "total_tools_invoked": total_tools,
    }
    return report


def _run_id(model: str, started_at: str) -> str:
    """Match published-run naming convention: <YYYY-MM-DD>_<vendor>-<slug>."""
    date = started_at.split("T", 1)[0]
    slug = model.replace("/", "-").replace(".", "-")
    return f"{date}_{slug}"


def _split_predictions(rich_path: Path, canonical_path: Path, model: str) -> None:
    """Split the harness's rich output into a canonical predictions.json
    (SWE-bench eval consumes {instance_id, model_patch, model_name_or_path})
    and leave the rich output alongside as predictions-raw.json."""
    d = json.loads(rich_path.read_text())
    results = d.get("results", [])
    canonical = [
        {
            "instance_id": r.get("instance_id"),
            "model_patch": r.get("model_patch") or "",
            "model_name_or_path": model,
        }
        for r in results
    ]
    canonical_path.write_text(json.dumps(canonical, indent=2))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="Model slug e.g. openai/gpt-5.6-sol")
    ap.add_argument("--output-dir", required=True, type=Path)
    ap.add_argument("--skip-preflight", action="store_true")
    args = ap.parse_args()

    if not B0_TOKEN:
        raise SystemExit("B0_TOKEN or BAHULAM_API_KEY must be set")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    run_started_at = _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")
    print(f"[screen] model={args.model} output_dir={args.output_dir}", flush=True)
    print(f"[screen] run_started_at={run_started_at}", flush=True)

    # 1. pre-flight: tools_param_accepted
    if not args.skip_preflight:
        print("[screen] pre-flight: tools_param_accepted", flush=True)
        preflight = preflight_tools_accepted(args.model)
        (args.output_dir / "preflight-tools.json").write_text(json.dumps(preflight, indent=2))
        if not preflight["passed"]:
            print(f"[screen] pre-flight FAILED: {preflight['reason']}", flush=True)
            report = {
                "schema_version": 2,
                "run_id": _run_id(args.model, run_started_at),
                "run_started_at": run_started_at,
                "run_finished_at": _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                "model": {"slug": args.model},
                "harness": {
                    "cli_version": _cli_version(),
                    "harness_git_sha": _harness_git_sha(),
                    "gateway_url": GATEWAY_URL,
                },
                "environment": _env_metadata(),
                "stage": "preflight-failed",
                "preflight": preflight,
                "gates_verdict": "REJECT",
                "gates_reason": "tools_param_accepted pre-flight failed — model cannot drive tool-use agents",
            }
            (args.output_dir / "screening-report.json").write_text(json.dumps(report, indent=2))
            sys.exit(2)
    else:
        preflight = {"skipped": True}

    # 2. pre-flight: pricing snapshot
    print("[screen] pre-flight: pricing snapshot", flush=True)
    pricing = preflight_pricing(args.model)
    (args.output_dir / "pricing.json").write_text(json.dumps(pricing, indent=2))

    # 3. harness — writes rich output; we split later into canonical + raw
    rich_predictions = args.output_dir / "predictions-raw.json"
    harness_log = args.output_dir / "harness.log"
    rc = run_harness(args.model, rich_predictions, harness_log)
    if rc != 0 and not rich_predictions.exists():
        raise SystemExit(f"harness failed rc={rc} — see {harness_log}")

    run_finished_at = _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")

    # 4. split: canonical predictions.json (for docker eval) + keep raw alongside
    canonical_predictions = args.output_dir / "predictions.json"
    try:
        _split_predictions(rich_predictions, canonical_predictions, args.model)
        print(f"[screen] wrote canonical {canonical_predictions.name} + rich {rich_predictions.name}", flush=True)
    except Exception as e:
        print(f"[screen] WARN: canonical split failed: {e}", flush=True)

    # 5. partial report v2
    report = build_partial_report(
        args.model, args.output_dir, preflight, pricing, rich_predictions,
        run_started_at, run_finished_at,
    )
    report["run_id"] = _run_id(args.model, run_started_at)
    (args.output_dir / "screening-report.json").write_text(json.dumps(report, indent=2))
    print(f"[screen] wrote {args.output_dir/'screening-report.json'} (schema_version=2)", flush=True)
    print(f"[screen] run_id={report['run_id']} wall_clock={report.get('wall_clock_seconds')}s", flush=True)
    print(f"[screen] totals: {report.get('totals')}", flush=True)
    print(f"[screen] metrics preview:", flush=True)
    for k, v in report.get("metrics", {}).items():
        print(f"    {k}: {v}", flush=True)
    print("[screen] DONE — inference stage complete. Run scripts/verify-and-report.py on VM to complete gate check.", flush=True)


if __name__ == "__main__":
    main()
