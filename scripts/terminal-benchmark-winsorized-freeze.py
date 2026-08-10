#!/usr/bin/env python3
"""Freeze the predeclared five-workload winsorized confirm suite."""
import argparse
import importlib.util
import json
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCREEN_PATH = ROOT / "scripts" / "terminal-benchmark-winsorized-screen.py"
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_winsorized_screen",
    SCREEN_PATH,
)
SCREEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCREEN)

SELECTED_CELLS = {
    "terminalFeed": {"pairCount": 2, "directionalThresholdPercent": 2.50},
    "scrollbackStream": {"pairCount": 4, "directionalThresholdPercent": 2.15},
    "contentChurn": {"pairCount": 48, "directionalThresholdPercent": 1.65},
    "styleChurn": {"pairCount": 32, "directionalThresholdPercent": 2.00},
    "incrementalMixed": {"pairCount": 40, "directionalThresholdPercent": 2.10},
}


def main():
    """Calibrate only the screened cells with fresh seeds and audit acceptance."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--trials", type=int, default=100_000)
    parser.add_argument("--seed-base", type=int, default=20262100)
    arguments = parser.parse_args()
    workloads = {}
    projected_wall_seconds = 0.0
    for workload_index, (name, selected) in enumerate(SELECTED_CELLS.items()):
        configuration = SCREEN.WORKLOADS[name]
        source = ROOT / configuration["source"]
        loader = (
            SCREEN.CALIBRATION.load_paired_summary_quartets
            if configuration["loader"] == "summary"
            else SCREEN.CALIBRATION.load_quartets
        )
        pair_count = selected["pairCount"]
        projected_seconds = pair_count * configuration["secondsPerPair"]
        report = SCREEN.CALIBRATION.calibrate_mode(
            loader(source),
            pair_count=pair_count,
            effect_percent=3,
            directional_threshold=selected["directionalThresholdPercent"],
            equivalence_band=0.75,
            trial_count=arguments.trials,
            seed=arguments.seed_base + workload_index,
            estimator="winsorized-mean-20",
        )
        report["source"] = configuration["source"]
        report["secondsPerPair"] = configuration["secondsPerPair"]
        report["projectedWallSeconds"] = projected_seconds
        workloads[name] = report
        projected_wall_seconds += projected_seconds
    acceptance = SCREEN.CALIBRATION.assess_frozen_suite(
        workloads,
        projected_wall_seconds=projected_wall_seconds,
        maximum_wall_seconds=300.0,
    )
    result = {
        "schemaVersion": 1,
        "date": "2026-07-24",
        "design": {
            "mode": "confirm",
            "estimator": "20-percent-winsorized-mean-symmetric-paired-percent",
            "equivalenceBandPercent": 0.75,
            "effectPercent": 3,
            "trialCountPerCondition": arguments.trials,
            "seedBase": arguments.seed_base,
            "maximumAAFalsePositiveUnionBound": 0.05,
            "minimumDetectionRate": 0.90,
            "maximumNondirectionalRate": 0.10,
            "maximumWrongDirectionRate": 0.05,
            "maximumProjectedWallSeconds": 300.0,
        },
        "workloads": workloads,
        "acceptance": acceptance,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
