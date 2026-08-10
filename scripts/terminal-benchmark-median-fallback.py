#!/usr/bin/env python3
"""Screen and freeze the predeclared 179x66 median fallback calibration."""
import argparse
import importlib.util
import json
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
CALIBRATION_PATH = ROOT / "scripts" / "terminal-benchmark-calibration.py"
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_calibration",
    CALIBRATION_PATH,
)
CALIBRATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CALIBRATION)

PAIR_COUNTS = (2, 4, 6, 8, 12, 16, 24, 32, 40, 48, 64, 80, 100)
# The grids reach down to 0.30% because an instrument can be more precise than
# the screen's search space, and then the screen reports its own floor as if it
# were the instrument's resolution. F22 hit exactly that: the headless draw
# comparison pinned on 1.05% and 0.80%, which were the old floors. Both floors
# sat one GRID_STEP above their mode's equivalence band, since
# `calibrate_threshold_grid` refuses a band that is not strictly below every
# threshold -- so opening the grid downward is inseparable from giving the new
# cells a smaller band. See `screen_equivalence_band`, which does that without
# touching any threshold the frozen rules already express.
GRID_STEP = 0.05
GRID_FLOOR = 0.30
MAXIMUM_FALSE_POSITIVE_RATE = 0.05
MODES = {
    "quick": {
        "effectPercent": 5,
        "equivalenceBandPercent": 1.0,
        "thresholds": tuple(
            round(GRID_FLOOR + GRID_STEP * index, 2) for index in range(85)
        ),
        "minimumDetectionRate": 0.80,
        "maximumNondirectionalRate": 0.20,
        "maximumWrongDirectionRate": 0.05,
    },
    "confirm": {
        "effectPercent": 3,
        "equivalenceBandPercent": 0.75,
        "thresholds": tuple(
            round(GRID_FLOOR + GRID_STEP * index, 2) for index in range(45)
        ),
        "minimumDetectionRate": 0.90,
        "maximumNondirectionalRate": 0.10,
        "maximumWrongDirectionRate": 0.05,
    },
}
WORKLOADS = {
    "terminalFeed": {
        "source": ".build/terminal-benchmark-phase4-derived/2026-07-24/terminalFeed.json",
        "loader": "summary",
        "secondsPerPair": 3.493125,
    },
    "scrollbackStream": {
        "source": ".build/terminal-benchmark-phase4-derived/2026-07-24/scrollbackStream.json",
        "loader": "summary",
        "secondsPerPair": 11.6126750989375,
    },
    "contentChurn": {
        "source": ".build/terminal-benchmark-phase4-content-shared-bundle-calibration/2026-07-24/blocks.jsonl",
        "loader": "blocks",
        "secondsPerPair": 2.4790475199791664,
    },
    "styleChurn": {
        "source": ".build/terminal-benchmark-phase4-style-shared-bundle-calibration/2026-07-24/blocks.jsonl",
        "loader": "blocks",
        "secondsPerPair": 2.5075803671875,
    },
    "incrementalMixed": {
        "source": ".build/terminal-benchmark-phase4-incremental-shared-bundle-calibration/2026-07-24/blocks.jsonl",
        "loader": "blocks",
        "secondsPerPair": 2.2219746267500002,
    },
}


def load_workload_quartets(configuration):
    """Load either core/session summaries or app draw block evidence."""
    path = ROOT / configuration["source"]
    if configuration["loader"] == "summary":
        return CALIBRATION.load_paired_summary_quartets(path)
    return CALIBRATION.load_quartets(path)


def screen_equivalence_band(threshold, mode):
    """Give a screened threshold the widest equivalence band it legally leaves room for.

    Every threshold the frozen rules can already express -- anything above the
    mode's own band -- keeps that band exactly, so extending the grid downward
    cannot redefine what `quick` or `confirm` decide. Only the new cells below it
    get a narrower band, one GRID_STEP under their threshold, which is the same
    gap the old grid floors carried.
    """
    return min(MODES[mode]["equivalenceBandPercent"], round(threshold - GRID_STEP, 2))


def screen_threshold_grid(
    quartets,
    *,
    mode,
    pair_count,
    trial_count,
    seed,
    estimator="median",
):
    """Calibrate a mode's whole grid, batching the thresholds that share a band.

    `calibrate_threshold_grid` takes one band per call, and the extension below a
    mode's band needs a different one per threshold. Batching by band keeps the
    frozen-band cells in a single call with an unchanged seed, so their reports
    are identical to what the pre-extension screen produced.

    Cost: the extension adds one call per new threshold (15 for `quick`, 10 for
    `confirm`), and each call re-resamples, so a full screen runs minutes rather
    than seconds. That is affordable because this is an offline tool an operator
    invokes deliberately; it is not in `just test`.
    """
    rule = MODES[mode]
    groups = {}
    for threshold in rule["thresholds"]:
        groups.setdefault(screen_equivalence_band(threshold, mode), []).append(threshold)
    reports = []
    for band, thresholds in groups.items():
        reports.extend(CALIBRATION.calibrate_threshold_grid(
            quartets,
            pair_count=pair_count,
            effect_percent=rule["effectPercent"],
            directional_thresholds=thresholds,
            equivalence_band=band,
            trial_count=trial_count,
            seed=seed,
            estimator=estimator,
        ))
    reports.sort(key=lambda report: report["directionalThresholdPercent"])
    return reports


def tightest_threshold_clearing_false_positives(
    reports,
    mode,
    maximum_false_positive_rate=MAXIMUM_FALSE_POSITIVE_RATE,
):
    """Report the smallest threshold that passes the gates and the A/A bound, or None.

    This is the readout that describes an instrument's resolution, as opposed to
    `reduced_candidates`, which picks the cell a mode should be frozen at. They
    disagree on purpose: the frozen selection prefers the *loosest* eligible
    threshold because it has the fewest false positives, while an instrument's
    capability is the *tightest* one it can still be trusted at. Only the latter
    can bottom out on the grid, which is why the grid floor matters at all.
    """
    eligible = [
        report["directionalThresholdPercent"]
        for report in reports
        if cell_is_eligible(report, mode)
        and report["conditions"]["aa"]["falsePositiveRate"]
        <= maximum_false_positive_rate
    ]
    return min(eligible) if eligible else None


def cell_is_eligible(report, mode):
    """Apply research/7/D1's fixed per-workload injected-effect gates."""
    rule = MODES[mode]
    effects = (report["conditions"]["positive"], report["conditions"]["negative"])
    return (
        mode != "quick"
        or report["conditions"]["aa"]["falsePositiveRate"] <= 0.05
    ) and all(
        condition["detectionRate"] >= rule["minimumDetectionRate"]
        and condition["inconclusiveRate"]
        <= rule["maximumNondirectionalRate"]
        and condition["wrongDirectionRate"]
        <= rule["maximumWrongDirectionRate"]
        for condition in effects
    )


def reduced_candidates(reports, mode, seconds_per_pair):
    """Keep the lowest-false-positive eligible threshold at each fixed count."""
    result = []
    for pair_count in PAIR_COUNTS:
        eligible = [
            report
            for report in reports
            if report["pairCount"] == pair_count and cell_is_eligible(report, mode)
        ]
        if eligible:
            candidate = min(
                eligible,
                key=lambda report: (
                    report["conditions"]["aa"]["falsePositiveRate"],
                    -report["directionalThresholdPercent"],
                ),
            )
            candidate["projectedWallSeconds"] = pair_count * seconds_per_pair
            result.append(candidate)
    return result


def screen(arguments):
    """Screen both median modes without consuming the later freeze seeds."""
    screened_modes = {}
    for mode_index, (mode, rule) in enumerate(MODES.items()):
        workloads = {}
        candidates = {}
        for workload_index, (name, configuration) in enumerate(WORKLOADS.items()):
            reports = []
            quartets = load_workload_quartets(configuration)
            tightest = {}
            for count_index, pair_count in enumerate(PAIR_COUNTS):
                count_reports = screen_threshold_grid(
                    quartets,
                    mode=mode,
                    pair_count=pair_count,
                    trial_count=arguments.trials,
                    seed=(
                        arguments.seed_base
                        + mode_index * 10_000
                        + workload_index * 100
                        + count_index
                    ),
                )
                reports.extend(count_reports)
                tightest[pair_count] = tightest_threshold_clearing_false_positives(
                    count_reports, mode
                )
            candidates[name] = reduced_candidates(
                reports, mode, configuration["secondsPerPair"]
            )
            workloads[name] = {
                "source": configuration["source"],
                "secondsPerPair": configuration["secondsPerPair"],
                "cells": reports,
                # Recorded so a floor answer is visible in the report itself. A
                # value equal to min(thresholds) means the screen ran out of grid
                # and the number describes this file, not the instrument.
                "tightestThresholdClearingFalsePositives": tightest,
                "gridFloorPercent": min(rule["thresholds"]),
            }
        if mode == "quick":
            selection = {
                "workloads": {
                    name: min(
                        values,
                        key=lambda candidate: (
                            candidate["projectedWallSeconds"],
                            candidate["pairCount"],
                            candidate["conditions"]["aa"]["falsePositiveRate"],
                            -candidate["directionalThresholdPercent"],
                        ),
                    )
                    for name, values in candidates.items()
                }
            }
            selection["projectedWallSeconds"] = sum(
                value["projectedWallSeconds"]
                for value in selection["workloads"].values()
            )
            selection["maximumWorkloadWallSeconds"] = max(
                value["projectedWallSeconds"]
                for value in selection["workloads"].values()
            )
        else:
            selection = CALIBRATION.select_suite_combination(
                candidates,
                maximum_false_positive_union_bound=0.05,
            )
        screened_modes[mode] = {
            "rule": rule,
            "workloads": workloads,
            "selected": selection,
        }
    return {
        "schemaVersion": 1,
        "date": "2026-07-24",
        "estimator": "median-symmetric-paired-percent",
        "pairCounts": PAIR_COUNTS,
        "trialCountPerCondition": arguments.trials,
        "seedBase": arguments.seed_base,
        "modes": screened_modes,
    }


def freeze(arguments):
    """Freeze only the exact cells selected by a prior screen report."""
    screened = json.loads(arguments.screen.read_text(encoding="utf-8"))
    modes = {}
    for mode_index, (mode, rule) in enumerate(MODES.items()):
        reports = {}
        selected = screened["modes"][mode]["selected"]["workloads"]
        for workload_index, (name, configuration) in enumerate(WORKLOADS.items()):
            cell = selected[name]
            report = CALIBRATION.calibrate_mode(
                load_workload_quartets(configuration),
                pair_count=cell["pairCount"],
                effect_percent=rule["effectPercent"],
                directional_threshold=cell["directionalThresholdPercent"],
                equivalence_band=rule["equivalenceBandPercent"],
                trial_count=arguments.trials,
                seed=arguments.seed_base + mode_index * 100 + workload_index,
                estimator="median",
            )
            report["source"] = configuration["source"]
            report["secondsPerPair"] = configuration["secondsPerPair"]
            report["projectedWallSeconds"] = (
                report["pairCount"] * configuration["secondsPerPair"]
            )
            reports[name] = report
        if mode == "quick":
            passed_cells = {
                name: (
                    report["conditions"]["aa"]["falsePositiveRate"] <= 0.05
                    and cell_is_eligible(report, mode)
                    and report["projectedWallSeconds"] <= 60.0
                )
                for name, report in reports.items()
            }
            acceptance = {
                "accepted": all(passed_cells.values()),
                "workloadGates": passed_cells,
                "maximumWorkloadWallSeconds": max(
                    report["projectedWallSeconds"] for report in reports.values()
                ),
            }
        else:
            acceptance = CALIBRATION.assess_frozen_suite(
                reports,
                projected_wall_seconds=sum(
                    report["projectedWallSeconds"] for report in reports.values()
                ),
                maximum_wall_seconds=300.0,
            )
        modes[mode] = {"workloads": reports, "acceptance": acceptance}
    return {
        "schemaVersion": 1,
        "date": "2026-07-24",
        "estimator": "median-symmetric-paired-percent",
        "screen": str(arguments.screen),
        "trialCountPerCondition": arguments.trials,
        "seedBase": arguments.seed_base,
        "modes": modes,
        "accepted": all(value["acceptance"]["accepted"] for value in modes.values()),
    }


def main():
    """Write a deterministic screen or fresh-seed freeze report."""
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    screen_parser = subparsers.add_parser("screen")
    screen_parser.add_argument("--output", required=True, type=pathlib.Path)
    screen_parser.add_argument("--trials", type=int, default=5_000)
    screen_parser.add_argument("--seed-base", type=int, default=20264000)
    freeze_parser = subparsers.add_parser("freeze")
    freeze_parser.add_argument("--screen", required=True, type=pathlib.Path)
    freeze_parser.add_argument("--output", required=True, type=pathlib.Path)
    freeze_parser.add_argument("--trials", type=int, default=100_000)
    freeze_parser.add_argument("--seed-base", type=int, default=20265000)
    arguments = parser.parse_args()
    report = screen(arguments) if arguments.command == "screen" else freeze(arguments)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
