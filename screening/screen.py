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
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

SCREEN_DIR = Path(__file__).resolve().parent
CONFIGS = SCREEN_DIR / "configs"
INSTANCES_FILE = CONFIGS / "screening-30.txt"
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


def build_partial_report(model: str, output_dir: Path, preflight: dict, pricing: dict, results_path: Path) -> dict:
    """Aggregate everything the screen collected on Railway. Docker eval and
    dashboard verification happen later on the VM and get merged in by
    verify-and-report.py."""
    report = {
        "schema_version": 1,
        "model": model,
        "stage": "railway-inference-complete",
        "gateway_url": GATEWAY_URL,
        "harness_timeout_s": HARNESS_TIMEOUT_S,
        "harness_parallel": HARNESS_PARALLEL,
        "preflight": preflight,
        "pricing": pricing,
        "metrics": {},
        "gates_pending_vm": ["resolve_rate", "resolve_per_patch", "dashboard_cost_usd", "cost_delta_pct"],
    }

    if not results_path.exists():
        report["error"] = "harness produced no results.json — see harness.log"
        return report

    d = json.loads(results_path.read_text())
    results = d.get("results", [])
    n = len(results)
    if n == 0:
        report["error"] = "results.json is empty"
        return report

    patched = sum(1 for r in results if r.get("model_patch"))
    zero_tool = sum(1 for r in results if not r.get("model_patch") and (r.get("kepler", {}).get("tools") or 0) == 0 and (r.get("kepler", {}).get("duration_s") or 0) >= 500)
    total_dur = sum((r.get("kepler", {}).get("duration_s") or 0) for r in results)
    tot_in = sum((r.get("kepler", {}).get("usage", {}).get("input_tokens") or 0) for r in results)
    tot_out = sum((r.get("kepler", {}).get("usage", {}).get("output_tokens") or 0) for r in results)
    tot_cr = sum((r.get("kepler", {}).get("usage", {}).get("cache_read") or 0) for r in results)
    reasoning_tok = sum((r.get("kepler", {}).get("usage", {}).get("reasoning_tokens") or 0) for r in results)
    harness_cost = sum((r.get("kepler", {}).get("cost_usd") or 0) for r in results)
    total_tools = sum((r.get("kepler", {}).get("tools") or 0) for r in results)

    report["metrics"] = {
        "instances_submitted": n,
        "patched": patched,
        "patch_rate": round(patched / n, 3),
        "tool_call_emission_rate": round((n - zero_tool) / n, 3),
        "zero_tool_timeout_count": zero_tool,
        "avg_duration_s": round(total_dur / n, 1),
        "avg_input_tokens": int(tot_in / n) if n else 0,
        "avg_output_tokens": int(tot_out / n) if n else 0,
        "cache_hit_pct": round(tot_cr / tot_in, 3) if tot_in else None,
        "reasoning_token_ratio": round(reasoning_tok / max(tot_out - reasoning_tok, 1), 3) if reasoning_tok else 0,
        "harness_cost_usd": round(harness_cost, 2),
        "total_tools_invoked": total_tools,
    }
    return report


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="Model slug e.g. openai/gpt-5.6-sol")
    ap.add_argument("--output-dir", required=True, type=Path)
    ap.add_argument("--skip-preflight", action="store_true")
    args = ap.parse_args()

    if not B0_TOKEN:
        raise SystemExit("B0_TOKEN or BAHULAM_API_KEY must be set")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    print(f"[screen] model={args.model} output_dir={args.output_dir}", flush=True)

    # 1. pre-flight: tools_param_accepted
    if not args.skip_preflight:
        print("[screen] pre-flight: tools_param_accepted", flush=True)
        preflight = preflight_tools_accepted(args.model)
        (args.output_dir / "preflight-tools.json").write_text(json.dumps(preflight, indent=2))
        if not preflight["passed"]:
            print(f"[screen] pre-flight FAILED: {preflight['reason']}", flush=True)
            report = {
                "schema_version": 1,
                "model": args.model,
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

    # 3. harness
    predictions_json = args.output_dir / "predictions.json"
    harness_log = args.output_dir / "harness.log"
    rc = run_harness(args.model, predictions_json, harness_log)
    if rc != 0 and not predictions_json.exists():
        raise SystemExit(f"harness failed rc={rc} — see {harness_log}")

    # 4. partial report
    report = build_partial_report(args.model, args.output_dir, preflight, pricing, predictions_json)
    (args.output_dir / "screening-report.json").write_text(json.dumps(report, indent=2))
    print(f"[screen] wrote {args.output_dir/'screening-report.json'}", flush=True)
    print(f"[screen] metrics preview:", flush=True)
    for k, v in report.get("metrics", {}).items():
        print(f"    {k}: {v}", flush=True)
    print("[screen] DONE — inference stage complete. Run scripts/verify-and-report.py on VM to complete gate check.", flush=True)


if __name__ == "__main__":
    main()
