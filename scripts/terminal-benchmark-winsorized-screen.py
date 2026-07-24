#!/usr/bin/env python3
"""Run the predeclared five-workload winsorized-confirm calibration screen."""
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
THRESHOLDS = tuple(round(0.80 + 0.05 * index, 2) for index in range(35))
WORKLOADS = {
    "terminalFeed": {
        "source": ".build/terminal-benchmark-phase3-feed-pilot/2026-07-24/summary.json",
        "loader": "summary",
        "secondsPerPair": 40.927873998 / 16,
    },
    "scrollbackStream": {
        "source": ".build/terminal-benchmark-phase3-scrollback-pilot/2026-07-24/summary.json",
        "loader": "summary",
        "secondsPerPair": 183.552620042 / 16,
    },
    "contentChurn": {
        "source": ".build/terminal-benchmark-phase3-calibration/2026-07-24/blocks.jsonl",
        "loader": "blocks",
        "secondsPerPair": 92.442 / 48,
    },
    "styleChurn": {
        "source": ".build/terminal-benchmark-phase3-style-calibration/2026-07-24/blocks.jsonl",
        "loader": "blocks",
        "secondsPerPair": 92.31064225 / 48,
    },
    "incrementalMixed": {
        "source": ".build/terminal-benchmark-phase3-incremental-calibration/2026-07-24/blocks.jsonl",
        "loader": "blocks",
        "secondsPerPair": 91.868081542 / 48,
    },
}


def cell_is_eligible(report):
    """Apply the predeclared per-workload confirm accuracy gates."""
    effects = (
        report["conditions"]["positive"],
        report["conditions"]["negative"],
    )
    return all(
        condition["detectionRate"] >= 0.90
        and condition["inconclusiveRate"] <= 0.10
        and condition["wrongDirectionRate"] <= 0.05
        for condition in effects
    )


def main():
    """Write the complete screen and its deterministic suite selection."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--trials", type=int, default=5_000)
    parser.add_argument("--seed-base", type=int, default=20261500)
    arguments = parser.parse_args()
    screened = {}
    suite_candidates = {}
    for workload_index, (name, configuration) in enumerate(WORKLOADS.items()):
        source = ROOT / configuration["source"]
        loader = (
            CALIBRATION.load_paired_summary_quartets
            if configuration["loader"] == "summary"
            else CALIBRATION.load_quartets
        )
        quartets = loader(source)
        workload_reports = []
        reduced_candidates = []
        for count_index, pair_count in enumerate(PAIR_COUNTS):
            reports = CALIBRATION.calibrate_threshold_grid(
                quartets,
                pair_count=pair_count,
                effect_percent=3,
                directional_thresholds=THRESHOLDS,
                equivalence_band=0.75,
                trial_count=arguments.trials,
                seed=arguments.seed_base + workload_index * 100 + count_index,
                estimator="winsorized-mean-20",
            )
            workload_reports.extend(reports)
            eligible = [report for report in reports if cell_is_eligible(report)]
            if eligible:
                candidate = min(
                    eligible,
                    key=lambda report: (
                        report["conditions"]["aa"]["falsePositiveRate"],
                        -report["directionalThresholdPercent"],
                    ),
                )
                candidate["projectedWallSeconds"] = (
                    pair_count * configuration["secondsPerPair"]
                )
                reduced_candidates.append(candidate)
        screened[name] = {
            "source": configuration["source"],
            "secondsPerPair": configuration["secondsPerPair"],
            "cells": workload_reports,
        }
        suite_candidates[name] = reduced_candidates
    selection = CALIBRATION.select_suite_combination(
        suite_candidates,
        maximum_false_positive_union_bound=0.05,
    )
    report = {
        "schemaVersion": 1,
        "date": "2026-07-24",
        "design": {
            "mode": "confirm",
            "estimator": "20-percent-winsorized-mean-symmetric-paired-percent",
            "pairCounts": PAIR_COUNTS,
            "directionalThresholdPercents": THRESHOLDS,
            "equivalenceBandPercent": 0.75,
            "effectPercent": 3,
            "trialCountPerCondition": arguments.trials,
            "seedBase": arguments.seed_base,
            "maximumAAFalsePositiveUnionBound": 0.05,
            "minimumDetectionRate": 0.90,
            "maximumNondirectionalRate": 0.10,
            "maximumWrongDirectionRate": 0.05,
        },
        "workloads": screened,
        "selectedSuite": selection,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
