#!/usr/bin/env python3
"""Calibrate fixed-N paired benchmark decisions from balanced A/A block series."""
import argparse
import itertools
import json
import pathlib
import random
import statistics


def symmetric_difference(baseline, candidate):
    """Express a paired change symmetrically so reversing labels only changes its sign."""
    if baseline <= 0 or candidate <= 0:
        raise ValueError("paired timings must be positive")
    return 200.0 * (candidate - baseline) / (candidate + baseline)


def inject_relative_effect(observed_symmetric_percent, relative_percent):
    """Apply an exact conventional relative change to the candidate side of a pair."""
    if abs(observed_symmetric_percent) >= 200:
        raise ValueError("symmetric percentage must be between -200 and 200")
    ratio = (200.0 + observed_symmetric_percent) / (
        200.0 - observed_symmetric_percent
    )
    injected_ratio = ratio * (1.0 + relative_percent / 100.0)
    if injected_ratio <= 0:
        raise ValueError("injected candidate timing must remain positive")
    return 200.0 * (injected_ratio - 1.0) / (injected_ratio + 1.0)


def detected_outlier_indices(values):
    """Identify extreme MAD outliers for reporting while retaining every observation."""
    if len(values) < 3:
        return []
    center = statistics.median(values)
    deviations = [abs(value - center) for value in values]
    mad = statistics.median(deviations)
    if mad == 0:
        return [
            index
            for index, deviation in enumerate(deviations)
            if deviation > 0
        ]
    return [
        index
        for index, deviation in enumerate(deviations)
        if 0.67448975 * deviation / mad > 3.5
    ]


def winsorized_mean(values, proportion=0.2):
    """Retain all pairs while limiting each measured tail's leverage."""
    if not values:
        raise ValueError("a winsorized mean requires at least one value")
    if not 0 <= proportion < 0.5:
        raise ValueError("winsorization proportion must be between zero and one half")
    ordered = sorted(values)
    tail_count = int(len(ordered) * proportion)
    if tail_count:
        lower = ordered[tail_count]
        upper = ordered[-tail_count - 1]
        ordered[:tail_count] = [lower] * tail_count
        ordered[-tail_count:] = [upper] * tail_count
    return statistics.fmean(ordered)


def decide(
    values,
    directional_threshold,
    equivalence_band,
    estimator="median",
):
    """Classify one fixed-N paired trial without deleting detected outliers."""
    if not values:
        raise ValueError("a decision requires at least one paired difference")
    if not 0 <= equivalence_band < directional_threshold:
        raise ValueError("equivalence band must be below the directional threshold")
    if estimator == "median":
        estimate = statistics.median(values)
    elif estimator == "winsorized-mean-20":
        estimate = winsorized_mean(values, proportion=0.2)
    else:
        raise ValueError(f"unknown estimator: {estimator}")
    return decision_from_estimate(
        estimate,
        len(values),
        detected_outlier_indices(values),
        directional_threshold,
        equivalence_band,
    )


def decision_from_estimate(
    estimate,
    sample_count,
    outlier_indices,
    directional_threshold,
    equivalence_band,
):
    """Reclassify a fixed estimate without repeating estimator work across a grid."""
    if estimate >= directional_threshold:
        decision = "slower"
    elif estimate <= -directional_threshold:
        decision = "faster"
    elif abs(estimate) <= equivalence_band:
        decision = "equivalent"
    else:
        decision = "inconclusive"
    return {
        "decision": decision,
        "estimatePercent": estimate,
        "sampleCount": sample_count,
        "usedSampleCount": sample_count,
        "outlierIndices": outlier_indices,
    }


def resample_quartets(quartets, pair_count, generator):
    """Draw complete two-pair schedule quartets so calibration retains local dependence."""
    if pair_count <= 0 or pair_count % 2:
        raise ValueError("pair count must be a positive multiple of two")
    if not quartets or any(len(quartet) != 2 for quartet in quartets):
        raise ValueError("calibration requires complete two-pair quartets")
    result = []
    while len(result) < pair_count:
        result.extend(generator.choice(quartets))
    return result


def condition_summary(decisions, correct_direction=None):
    counts = {
        name: sum(result["decision"] == name for result in decisions)
        for name in ("faster", "slower", "equivalent", "inconclusive")
    }
    summary = {
        "counts": counts,
        "rates": {
            name: count / len(decisions)
            for name, count in counts.items()
        },
    }
    if correct_direction is None:
        summary["falsePositiveRate"] = (
            counts["faster"] + counts["slower"]
        ) / len(decisions)
    else:
        summary["detectionRate"] = counts[correct_direction] / len(decisions)
        summary["wrongDirectionRate"] = counts[
            "faster" if correct_direction == "slower" else "slower"
        ] / len(decisions)
        summary["inconclusiveRate"] = (
            counts["equivalent"] + counts["inconclusive"]
        ) / len(decisions)
    return summary


def calibrate_mode(
    quartets,
    pair_count,
    effect_percent,
    directional_threshold,
    equivalence_band,
    trial_count,
    seed,
    estimator="median",
):
    """Run deterministic empirical A/A and injected-effect calibration trials."""
    return calibrate_threshold_grid(
        quartets,
        pair_count,
        effect_percent,
        [directional_threshold],
        equivalence_band,
        trial_count,
        seed,
        estimator=estimator,
    )[0]


def calibrate_threshold_grid(
    quartets,
    pair_count,
    effect_percent,
    directional_thresholds,
    equivalence_band,
    trial_count,
    seed,
    estimator="median",
):
    """Calibrate many thresholds from one deterministic set of resampled estimates."""
    if trial_count <= 0:
        raise ValueError("trial count must be positive")
    if not directional_thresholds:
        raise ValueError("threshold grid must not be empty")
    if any(
        not 0 <= equivalence_band < threshold
        for threshold in directional_thresholds
    ):
        raise ValueError("equivalence band must be below every directional threshold")
    generator = random.Random(seed)
    estimates = {"aa": [], "positive": [], "negative": []}
    for trial_index in range(trial_count):
        sample = resample_quartets(quartets, pair_count, generator)
        if trial_index % 2:
            sample = [-value for value in sample]
        condition_samples = {
            "aa": sample,
            "positive": [
                inject_relative_effect(value, effect_percent)
                for value in sample
            ],
            "negative": [
                inject_relative_effect(value, -effect_percent)
                for value in sample
            ],
        }
        for name, values in condition_samples.items():
            if estimator == "median":
                estimate = statistics.median(values)
            elif estimator == "winsorized-mean-20":
                estimate = winsorized_mean(values, proportion=0.2)
            else:
                raise ValueError(f"unknown estimator: {estimator}")
            estimates[name].append((
                estimate,
                detected_outlier_indices(values),
            ))
    reports = []
    for directional_threshold in directional_thresholds:
        conditions = {
            name: [
                decision_from_estimate(
                    estimate,
                    pair_count,
                    outlier_indices,
                    directional_threshold,
                    equivalence_band,
                )
                for estimate, outlier_indices in condition_estimates
            ]
            for name, condition_estimates in estimates.items()
        }
        reports.append({
            "pairCount": pair_count,
            "effectPercent": effect_percent,
            "directionalThresholdPercent": directional_threshold,
            "equivalenceBandPercent": equivalence_band,
            "trialCountPerCondition": trial_count,
            "seed": seed,
            "resamplingUnit": "balanced-schedule-quartet",
            "physicalArmMapping": "source-labels-swapped-on-alternating-trials",
            "estimator": (
                "median-symmetric-paired-percent"
                if estimator == "median"
                else "20-percent-winsorized-mean-symmetric-paired-percent"
            ),
            "outlierPolicy": "MAD-report-only-no-deletion",
            "conditions": {
                "aa": condition_summary(conditions["aa"]),
                "positive": condition_summary(
                    conditions["positive"], correct_direction="slower"
                ),
                "negative": condition_summary(
                    conditions["negative"], correct_direction="faster"
                ),
            },
        })
    return reports


def load_paired_summary_quartets(path):
    """Recover balanced quartets from a pilot's recorded paired-difference series."""
    summary = json.loads(path.read_text(encoding="utf-8"))
    values = summary["pairedSymmetricPercent"]["values"]
    pair_count = summary["pairCount"]
    schedule = summary["schedule"]
    if pair_count != len(values):
        raise ValueError("paired summary count does not match its recorded values")
    if len(values) % 2 or len(schedule) != len(values) * 2:
        raise ValueError("paired summary must contain complete four-block schedules")
    for offset in range(0, len(schedule), 4):
        block_group = schedule[offset:offset + 4]
        if sorted(block_group) != ["A", "A", "B", "B"]:
            raise ValueError("each schedule quartet must contain two A and two B blocks")
        if block_group[0] == block_group[1] or block_group[2] == block_group[3]:
            raise ValueError("each adjacent pair must contain one A and one B block")
    return [values[offset:offset + 2] for offset in range(0, len(values), 2)]


def summarize_suite(reports):
    """Expose the conservative suite error bound and worst injected-effect rates."""
    if not reports:
        raise ValueError("suite summary requires at least one workload")
    effect_conditions = [
        report["conditions"][condition]
        for report in reports.values()
        for condition in ("positive", "negative")
    ]
    return {
        "workloadCount": len(reports),
        "aaFalsePositiveUnionBound": sum(
            report["conditions"]["aa"]["falsePositiveRate"]
            for report in reports.values()
        ),
        "worstDetectionRate": min(
            condition["detectionRate"] for condition in effect_conditions
        ),
        "worstInconclusiveRate": max(
            condition["inconclusiveRate"] for condition in effect_conditions
        ),
        "worstWrongDirectionRate": max(
            condition["wrongDirectionRate"] for condition in effect_conditions
        ),
    }


def assess_frozen_suite(
    reports,
    projected_wall_seconds,
    maximum_wall_seconds,
    maximum_false_positive_union_bound=0.05,
    minimum_detection_rate=0.90,
    maximum_inconclusive_rate=0.10,
    maximum_wrong_direction_rate=0.05,
):
    """Accept a frozen suite only when every predeclared accuracy and runtime gate passes."""
    summary = summarize_suite(reports)
    gates = {
        "aaFalsePositiveUnionBound": (
            summary["aaFalsePositiveUnionBound"]
            <= maximum_false_positive_union_bound
        ),
        "detectionRate": (
            summary["worstDetectionRate"] >= minimum_detection_rate
        ),
        "inconclusiveRate": (
            summary["worstInconclusiveRate"] <= maximum_inconclusive_rate
        ),
        "wrongDirectionRate": (
            summary["worstWrongDirectionRate"] <= maximum_wrong_direction_rate
        ),
        "projectedWallSeconds": projected_wall_seconds <= maximum_wall_seconds,
    }
    return {
        "accepted": all(gates.values()),
        "failedGates": [name for name, passed in gates.items() if not passed],
        "gates": gates,
        "suiteSummary": summary,
        "projectedWallSeconds": projected_wall_seconds,
        "maximumWallSeconds": maximum_wall_seconds,
    }


def select_candidate(
    candidates,
    maximum_false_positive_rate,
    minimum_detection_rate,
    maximum_inconclusive_rate,
    maximum_wrong_direction_rate,
):
    """Choose the lowest fixed pair count that independently clears every target."""
    for candidate in sorted(
        candidates,
        key=lambda value: (
            value["pairCount"],
            value["directionalThresholdPercent"],
        ),
    ):
        conditions = candidate["conditions"]
        effects = (conditions["positive"], conditions["negative"])
        if (
            conditions["aa"]["falsePositiveRate"]
            <= maximum_false_positive_rate
            and all(
                condition["detectionRate"] >= minimum_detection_rate
                and condition["inconclusiveRate"] <= maximum_inconclusive_rate
                and condition["wrongDirectionRate"]
                <= maximum_wrong_direction_rate
                for condition in effects
            )
        ):
            return candidate
    return None


def select_suite_combination(
    candidates_by_workload,
    maximum_false_positive_union_bound,
):
    """Choose the fastest workload combination that controls suite false positives."""
    if not candidates_by_workload or any(
        not candidates for candidates in candidates_by_workload.values()
    ):
        raise ValueError("suite selection requires candidates for every workload")
    workload_names = list(candidates_by_workload)
    eligible = []
    for combination in itertools.product(
        *(candidates_by_workload[name] for name in workload_names)
    ):
        false_positive_union_bound = sum(
            candidate["conditions"]["aa"]["falsePositiveRate"]
            for candidate in combination
        )
        if false_positive_union_bound > maximum_false_positive_union_bound:
            continue
        projected_wall_seconds = sum(
            candidate["projectedWallSeconds"]
            for candidate in combination
        )
        total_pair_count = sum(
            candidate["pairCount"]
            for candidate in combination
        )
        eligible.append((
            (
                projected_wall_seconds,
                total_pair_count,
                tuple(
                    (
                        candidate["pairCount"],
                        candidate["directionalThresholdPercent"],
                    )
                    for candidate in combination
                ),
            ),
            {
                "workloads": dict(zip(workload_names, combination)),
                "projectedWallSeconds": projected_wall_seconds,
                "totalPairCount": total_pair_count,
                "aaFalsePositiveUnionBound": false_positive_union_bound,
            },
        ))
    if not eligible:
        return None
    return min(eligible, key=lambda item: item[0])[1]


def load_quartets(path):
    """Read a controller JSONL series and recover label-oriented paired differences."""
    rows = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if len(rows) % 4:
        raise ValueError("calibration series must contain complete four-block schedules")
    quartets = []
    for offset in range(0, len(rows), 4):
        block_group = rows[offset:offset + 4]
        if sorted(row["arm"] for row in block_group) != ["A", "A", "B", "B"]:
            raise ValueError("each schedule quartet must contain two A and two B blocks")
        pair_differences = []
        for first, second in zip(block_group[::2], block_group[1::2]):
            if first["arm"] == second["arm"]:
                raise ValueError("each adjacent pair must contain one A and one B block")
            values = {}
            for row in (first, second):
                draw = row.get("result", row.get("draw"))
                values[row["arm"]] = (
                    draw["cumulativeDrawNanoseconds"] / draw["drawCount"]
                )
            pair_differences.append(
                symmetric_difference(values["A"], values["B"])
            )
        quartets.append(pair_differences)
    return quartets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("series", type=pathlib.Path)
    parser.add_argument("--trials", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=20260724)
    parser.add_argument("--quick-threshold", type=float, default=2.75)
    parser.add_argument("--quick-equivalence", type=float, default=1.0)
    parser.add_argument("--confirm-threshold", type=float, default=1.75)
    parser.add_argument("--confirm-equivalence", type=float, default=0.75)
    arguments = parser.parse_args()
    quartets = load_quartets(arguments.series)
    report = {
        "schemaVersion": 1,
        "source": str(arguments.series),
        "sourceQuartetCount": len(quartets),
        "sourcePairCount": len(quartets) * 2,
        "quick": calibrate_mode(
            quartets,
            pair_count=8,
            effect_percent=5,
            directional_threshold=arguments.quick_threshold,
            equivalence_band=arguments.quick_equivalence,
            trial_count=arguments.trials,
            seed=arguments.seed,
        ),
        "confirm": calibrate_mode(
            quartets,
            pair_count=80,
            effect_percent=3,
            directional_threshold=arguments.confirm_threshold,
            equivalence_band=arguments.confirm_equivalence,
            trial_count=arguments.trials,
            seed=arguments.seed + 1,
        ),
    }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
