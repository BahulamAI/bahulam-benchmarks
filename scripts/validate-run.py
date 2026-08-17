#!/usr/bin/env python3
"""Validate that a run directory has the required files with the expected shape.

Usage: scripts/validate-run.py suites/<suite>/runs/<run-slug>
"""

import json
import sys
from pathlib import Path

REQUIRED_FILES = {
    "config.yaml": "run configuration",
    "predictions.json": "model outputs (SWE-bench format for SWE suites)",
    "docker-eval.json": "official evaluator report",
    "summary.md": "human-readable results",
    "costs.json": "cost + token breakdown",
}


def main():
    if len(sys.argv) != 2:
        print("usage: validate-run.py <run-dir>", file=sys.stderr)
        sys.exit(1)

    run_dir = Path(sys.argv[1])
    if not run_dir.is_dir():
        print(f"not a directory: {run_dir}", file=sys.stderr)
        sys.exit(1)

    errors = []
    for name, description in REQUIRED_FILES.items():
        p = run_dir / name
        if not p.exists():
            errors.append(f"missing: {name} ({description})")
            continue
        if name.endswith(".json"):
            try:
                json.load(open(p))
            except Exception as e:
                errors.append(f"invalid JSON: {name} — {e}")

    # SWE-bench-specific: predictions.json shape
    preds_path = run_dir / "predictions.json"
    if preds_path.exists() and "swe-bench" in str(run_dir):
        preds = json.load(open(preds_path))
        if not isinstance(preds, list):
            errors.append("predictions.json must be a list of {instance_id, model_patch, model_name_or_path}")
        else:
            for i, p in enumerate(preds[:3]):
                for k in ("instance_id", "model_patch", "model_name_or_path"):
                    if k not in p:
                        errors.append(f"predictions.json[{i}] missing key: {k}")

    if errors:
        for e in errors:
            print(f"  ✗ {e}")
        print(f"\n{len(errors)} error(s) in {run_dir}")
        sys.exit(2)
    print(f"  ✓ {run_dir} is valid")


if __name__ == "__main__":
    main()
