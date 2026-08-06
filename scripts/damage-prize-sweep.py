#!/usr/bin/env python3
"""Measure the prize damage clipping is playing for: full-frame vs clipped draw cost.

`terminal-headless-draw-compare.py` varies the *checkout* at one fixed scenario.
This varies the *scenario* on one checkout: it loads a full-frame arm and a
clipped arm into one process and interleaves them ABBA, so the ratio between
them is taken microseconds apart and the process-level drift that moves every
headless draw measurement together cancels out.

Scope, deliberately narrow -- inherited from the arm this reuses. The timed
region is `drawRenderFrame` on an already-scoped plan under an already-built
clip. It does NOT contain damage generation, `clipFramePlan`, CGContext clip
construction, or Core Animation replay. So it answers "how much drawing does
clipping avoid", which is the ceiling on what the damage machinery can win --
not whether the machinery pays for itself.

No decision rule is frozen for this instrument. It reports statistics and its
own control; the caller supplies the rule.

    python3 scripts/damage-prize-sweep.py --clip-rows 4 8 16 33 50 66
    python3 scripts/damage-prize-sweep.py --control     # both arms full-frame
"""
import argparse
import importlib.util
import json
import pathlib
import statistics
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPARE = importlib.util.spec_from_file_location(
    "terminal_headless_draw_compare",
    ROOT / "scripts" / "terminal-headless-draw-compare.py",
)
CMP = importlib.util.module_from_spec(COMPARE)
COMPARE.loader.exec_module(CMP)

ARTIFACTS = ROOT / ".build" / "damage-prize-sweep"

# The two arms must differ in module name or the ObjC runtime dedups their classes and both
# execute one arm's code -- the hazard CMP.validate_module_names exists to catch.
FULL_MODULE = "DrawArmFullFrame"
CLIPPED_MODULE = "DrawArmClipped"

# The canonical benchmark geometry. Every calibrated claim in docs/research is at 179x66,
# and the span-count exposure this doc cares about scales with row count, so the default
# must not silently be the arm's own 160x50.
DEFAULT_COLUMNS = 179
DEFAULT_ROWS = 66


def batch_count_for(arm, target_nanoseconds=CMP.TARGET_BATCH_NANOSECONDS):
    """Size one arm's batch to the occupancy floor independently of the other arm.

    The paired comparator takes the max over both arms so a direction swap cannot change
    the measurement. That is wrong here: the arms differ by design and by a large factor,
    so a shared count would run the full-frame arm for many seconds per batch to keep the
    clipped arm above the floor. Each arm clearing the floor on its own is what the floor
    is actually for -- keeping the thread ~100% occupied so the governor never demotes it.
    """
    count = 1
    while arm.batch(count) < target_nanoseconds:
        count *= 2
    return count


def interleaved_rounds(full, clipped, full_count, clipped_count, rounds):
    """Run ABBA rounds and return per-draw nanoseconds for each arm in each slot."""
    results = []
    for _ in range(rounds):
        first_full = full.batch(full_count) / full_count
        first_clipped = clipped.batch(clipped_count) / clipped_count
        second_clipped = clipped.batch(clipped_count) / clipped_count
        second_full = full.batch(full_count) / full_count
        results.append({
            "fullNanosecondsPerDraw": [first_full, second_full],
            "clippedNanosecondsPerDraw": [first_clipped, second_clipped],
            # Pair each batch with its adjacent neighbour, matching the comparator's quartet
            # rule, so a monotonic drift across the round cancels instead of loading onto
            # whichever arm ran first.
            "ratios": [first_full / first_clipped, second_full / second_clipped],
        })
    return results


def summarize(rounds):
    """Report the ratio distribution plus each arm's absolute per-draw cost."""
    ratios = [value for round_result in rounds for value in round_result["ratios"]]
    full = [v for r in rounds for v in r["fullNanosecondsPerDraw"]]
    clipped = [v for r in rounds for v in r["clippedNanosecondsPerDraw"]]
    return {
        "roundCount": len(rounds),
        "ratioCount": len(ratios),
        "medianRatio": statistics.median(ratios),
        "minRatio": min(ratios),
        "maxRatio": max(ratios),
        "ratioStandardDeviation": statistics.pstdev(ratios) if len(ratios) > 1 else 0.0,
        "fullFrameNanosecondsPerDraw": statistics.median(full),
        "clippedNanosecondsPerDraw": statistics.median(clipped),
    }


def measure(full, clipped, clip_rows, arguments):
    """Prepare both arms for one scenario and measure it."""
    full.prepare(arguments.columns, arguments.rows, 0, arguments.workload)
    clipped.prepare(arguments.columns, arguments.rows, clip_rows, arguments.workload)
    full_count = batch_count_for(full)
    clipped_count = batch_count_for(clipped)
    # One discarded batch each so neither arm enters measurement cold.
    full.batch(full_count)
    clipped.batch(clipped_count)
    rounds = interleaved_rounds(full, clipped, full_count, clipped_count, arguments.rounds)
    return {
        "clipRows": clip_rows,
        "damagedRowFraction": clip_rows / arguments.rows,
        "fullFrameBatchCount": full_count,
        "clippedBatchCount": clipped_count,
        "summary": summarize(rounds),
        "rounds": rounds,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--columns", type=int, default=DEFAULT_COLUMNS)
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    parser.add_argument(
        "--clip-rows", type=int, nargs="+", default=[4, 8, 16, 33, 50, 66],
        help="damaged row counts to sweep; each is measured against the full frame")
    parser.add_argument(
        "--workload", choices=CMP.WORKLOADS, default="btop-shaped",
        help="'btop-shaped' is dense sprite art the executor draws as rects; 'text-shaped' "
             "is the only one that reaches CoreText's glyph calls")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument(
        "--control", action="store_true",
        help="prepare BOTH arms full-frame. The ratio must land near 1.0; anything else "
             "means the two arms are not interchangeable and no sweep ratio can be read")
    arguments = parser.parse_args()

    CMP.validate_module_names(FULL_MODULE, CLIPPED_MODULE)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    full = CMP.Arm(CMP.build_arm(FULL_MODULE, CMP.DEFAULT_CORE, ARTIFACTS))
    clipped = CMP.Arm(CMP.build_arm(CLIPPED_MODULE, CMP.DEFAULT_CORE, ARTIFACTS))

    report = {
        "schemaVersion": 1,
        "geometry": {"columns": arguments.columns, "rows": arguments.rows},
        "workload": arguments.workload,
        "mode": "control" if arguments.control else "sweep",
        "note": (
            "medianRatio is full-frame per-draw cost divided by clipped per-draw cost: "
            "3.0 means clipping that many rows made the draw 3x cheaper. Timed region is "
            "drawRenderFrame only -- no damage generation, no clipFramePlan, no clip "
            "construction, no Core Animation replay."
        ),
    }
    if arguments.control:
        # clip_rows 0 on both arms: the change under test cannot reach this comparison.
        report["scenarios"] = [measure(full, clipped, 0, arguments)]
    else:
        report["scenarios"] = [
            measure(full, clipped, clip_rows, arguments)
            for clip_rows in arguments.clip_rows
        ]
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
