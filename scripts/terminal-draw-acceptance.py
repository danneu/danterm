#!/usr/bin/env python3
"""Measure localized real-AppKit draw cost as a diagnostic microbenchmark.

`just benchmark-draw-app` runs this: it calibrates one excluded warm-up to a
draw-work duration floor, then reports fresh optimized-app batches as JSON on
stdout. The report is diagnostic only. It is not paired, not recorded, and
cannot support a cross-session regression claim -- directional claims come from
`just benchmark-quick` / `just benchmark-confirm`, which compare two immutable
source snapshots inside one machine session.
"""
import json
import math
import os
import pathlib
import statistics
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_TARGET_MILLISECONDS = 400


def calibrated_update_count(measured_nanoseconds, measured_updates, target_nanoseconds):
    """Scale an excluded warm-up to the fixed draw-work duration target."""
    if measured_nanoseconds <= 0 or measured_updates <= 0:
        raise ValueError("calibration requires positive draw duration and update count")
    return max(1, math.ceil(target_nanoseconds * measured_updates / measured_nanoseconds))


def distribution(values):
    """Return the compact range and median used for local diagnostic reading."""
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
        "drawCount": distribution([batch["drawCount"] for batch in batches]),
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
    payload = json.loads(completed.stdout)
    draw = payload["finalDraw"]
    draw["geometry"] = payload["geometry"]
    draw["displayScale"] = payload["displayScale"]
    return draw


def parse_arguments(arguments):
    """Parse batch count and duration floor positionally or as named options."""
    batches = 15
    target_milliseconds = None
    positional_count = 0
    for argument in arguments:
        if argument.startswith("batches="):
            batches = int(argument.removeprefix("batches="))
        elif argument.startswith("target_ms="):
            target_milliseconds = int(argument.removeprefix("target_ms="))
        elif argument.isdigit():
            if positional_count == 0:
                batches = int(argument)
            elif positional_count == 1:
                target_milliseconds = int(argument)
            else:
                raise ValueError(f"unknown argument: {argument}")
            positional_count += 1
        else:
            raise ValueError(f"unknown argument: {argument}")
    if batches < 2 or (target_milliseconds is not None and target_milliseconds <= 0):
        raise ValueError("batches must be >=2 and target_ms must be >0")
    return batches, target_milliseconds


def main():
    """Run the localized draw microbenchmark and print its diagnostic report."""
    try:
        batches, target_milliseconds = parse_arguments(sys.argv[1:])
    except ValueError as error:
        raise SystemExit(str(error)) from error

    target_nanoseconds = (
        target_milliseconds or DEFAULT_TARGET_MILLISECONDS
    ) * 1_000_000
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
        "decisionEligible": False,
        "historyEligible": False,
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
