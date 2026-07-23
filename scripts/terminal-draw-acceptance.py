#!/usr/bin/env python3
"""Calibrate and report local before/after measurements of the real AppKit draw path."""
import json
import math
import os
import pathlib
import statistics
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent


def calibrated_update_count(measured_nanoseconds, measured_updates, target_nanoseconds):
    """Scale an excluded warm-up to the fixed draw-work duration target."""
    if measured_nanoseconds <= 0 or measured_updates <= 0:
        raise ValueError("calibration requires positive draw duration and update count")
    return max(1, math.ceil(target_nanoseconds * measured_updates / measured_nanoseconds))


def distribution(values):
    """Return the compact range and median used for local A/B decisions."""
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def summarize_batches(batches, expected_updates):
    """Validate draw separation and normalize cumulative time for comparable batches."""
    normalized = []
    dirty_rows = []
    for batch in batches:
        count = batch["drawCount"]
        if count != expected_updates:
            raise ValueError(f"expected {expected_updates} completed draws, got {count}")
        if len(batch["dirtyRowCounts"]) != count:
            raise ValueError("dirty-row evidence does not match completed draw count")
        normalized.append(batch["cumulativeDrawNanoseconds"] // count)
        dirty_rows.extend(batch["dirtyRowCounts"])
    return {
        "batchCount": len(batches),
        "drawCount": expected_updates,
        "nanosecondsPerDraw": distribution(normalized),
        "dirtyRowsPerDraw": distribution(dirty_rows),
        "cumulativeDrawNanoseconds": distribution(
            [batch["cumulativeDrawNanoseconds"] for batch in batches]
        ),
    }


def run_batch(update_count):
    """Run one fresh optimized app batch and return its direct draw measurements."""
    environment = os.environ.copy()
    environment["DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES"] = str(update_count)
    completed = subprocess.run(
        (
            str(ROOT / "scripts" / "terminal-benchmark.sh"),
            "localized-draw-acceptance",
            "swift",
        ),
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(completed.stderr.strip())
    return json.loads(completed.stdout)["finalDraw"]


def main():
    """Calibrate an excluded warm-up, then print raw JSON for 15 duration-stable batches."""
    batches = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    target_milliseconds = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    if batches < 2 or target_milliseconds <= 0:
        raise SystemExit("usage: terminal-draw-acceptance.py [batches>=2] [target-ms>0]")
    target_nanoseconds = target_milliseconds * 1_000_000
    warmup_updates = 8
    print(
        f"[localized draw] excluded warm-up with {warmup_updates} updates",
        file=sys.stderr,
    )
    warmup = run_batch(warmup_updates)
    update_count = calibrated_update_count(
        warmup["cumulativeDrawNanoseconds"],
        warmup["drawCount"],
        target_nanoseconds * 5 // 4,
    )
    measured = []
    for index in range(batches):
        print(
            f"[localized draw] batch {index + 1}/{batches}, {update_count} updates",
            file=sys.stderr,
        )
        batch = run_batch(update_count)
        if batch["cumulativeDrawNanoseconds"] < target_nanoseconds:
            raise SystemExit(
                "calibrated batch fell below draw-work duration floor: "
                f"{batch['cumulativeDrawNanoseconds']} < {target_nanoseconds}"
            )
        measured.append(batch)
    report = {
        "schemaVersion": 1,
        "benchmark": "localized-real-app-draw",
        "targetBatchNanoseconds": target_nanoseconds,
        "calibration": {
            "excluded": True,
            "warmupUpdates": warmup_updates,
            "measuredUpdatesPerBatch": update_count,
        },
        "batches": measured,
        "summary": summarize_batches(measured, update_count),
    }
    json.dump(report, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
