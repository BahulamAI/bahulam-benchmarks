#!/usr/bin/env python3
"""Aggregate a model-comparison run's per-model result.json files into
summary.csv and summary.md, ready to drop into an article or a repo run
directory. Run after dispatch-batch.sh finishes (or partway through, to
check progress).

Usage:
    python3 aggregate-results.py --run-dir /path/to/run
"""
import argparse
import csv
import json
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True, type=Path)
    args = ap.parse_args()

    results_dir = args.run_dir / "results"
    rows = []
    for result_file in sorted(results_dir.glob("*/result.json")):
        r = json.loads(result_file.read_text())
        ce = r.get("complete_event") or {}
        usage = ce.get("usage") or {}
        rows.append({
            "model": r["model"],
            "resolved": r["resolved"],
            "patch_lines": r["patch_lines"],
            "tools": ce.get("tools"),
            "turns": ce.get("turns"),
            "tool_breakdown": json.dumps(ce.get("tool_breakdown") or {}),
            "input_tokens": usage.get("input_tokens"),
            "output_tokens": usage.get("output_tokens"),
            "duration_s": ce.get("duration_s"),
            "wall_clock_s": r["wall_clock_s"],
            "cost_usd": ce.get("cost_usd"),
            "rc": r["rc"],
            "had_error": r.get("error_event") is not None,
            "had_timeout": r.get("timeout_event") is not None,
        })

    if not rows:
        print("no result.json files found yet under", results_dir)
        return

    # CSV: full detail, machine-readable.
    csv_path = args.run_dir / "summary.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    # Markdown: article/report-ready, sorted resolved-first then by cost.
    def sort_key(r):
        resolved_rank = {"resolved": 0, "unresolved": 1, "pending_eval": 2, "eval_error": 3, "no_patch": 4}.get(r["resolved"], 5)
        cost = r["cost_usd"] if r["cost_usd"] is not None else float("inf")
        return (resolved_rank, cost)

    rows_sorted = sorted(rows, key=sort_key)
    resolved_count = sum(1 for r in rows if r["resolved"] == "resolved")

    lines = []
    lines.append(f"# Model comparison — {len(rows)} models, {resolved_count} resolved")
    lines.append("")
    lines.append("| Model | Resolved | Turns | Tools | In tok | Out tok | Time (s) | Cost ($) |")
    lines.append("|---|---|---|---|---|---|---|---|")
    def cell(v, fmt=None):
        if v is None:
            return "—"
        return format(v, fmt) if fmt else str(v)

    for r in rows_sorted:
        mark = {"resolved": "✓", "unresolved": "✗", "pending_eval": "eval pending", "eval_error": "eval err", "no_patch": "no patch"}.get(r["resolved"], r["resolved"])
        lines.append(
            f"| {r['model']} | {mark} | {cell(r['turns'])} | {cell(r['tools'])} | {cell(r['input_tokens'])} "
            f"| {cell(r['output_tokens'])} | {cell(r['duration_s'])} | {cell(r['cost_usd'], '.4f')} |"
        )
    md_path = args.run_dir / "summary.md"
    md_path.write_text("\n".join(lines) + "\n")

    print(f"wrote {csv_path} and {md_path} ({len(rows)} models, {resolved_count} resolved)")


if __name__ == "__main__":
    main()
