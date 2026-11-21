#!/usr/bin/env python3
"""Fetch one SWE-bench instance into a self-contained spec JSON.

Decouples the eval pipeline from the `datasets` library / HF Hub at run
time: fetch once, then every model run and every future re-run reads the
same frozen spec, so "reproduce this run" never depends on a dataset
snapshot or network access changing under you.

Usage:
    python3 fetch-instance.py --instance-id pydata__xarray-6992 \
        --dataset SWE-bench/SWE-bench_Verified \
        --out instance.json
"""
import argparse
import json
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--instance-id", required=True)
    ap.add_argument("--dataset", default="SWE-bench/SWE-bench_Verified")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    from datasets import load_dataset  # deferred: only needed here, not at run time

    d = load_dataset(args.dataset, split="test")
    for inst in d:
        if inst["instance_id"] == args.instance_id:
            spec = {
                "instance_id": inst["instance_id"],
                "dataset": args.dataset,
                "repo": inst["repo"],
                "repo_url": f"https://github.com/{inst['repo']}.git",
                "base_commit": inst["base_commit"],
                "test_patch": inst["test_patch"],
                "problem_statement": inst["problem_statement"],
                "fail_to_pass": inst.get("FAIL_TO_PASS"),
                "pass_to_pass": inst.get("PASS_TO_PASS"),
                "difficulty": inst.get("difficulty"),
            }
            args.out.write_text(json.dumps(spec, indent=2))
            print(f"wrote {args.out} ({args.instance_id}, difficulty={spec['difficulty']})")
            return
    raise SystemExit(f"instance {args.instance_id} not found in {args.dataset}")


if __name__ == "__main__":
    main()
