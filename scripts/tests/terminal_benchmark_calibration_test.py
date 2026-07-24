#!/usr/bin/env python3
"""Behavioral tests for the fixed-N paired benchmark calibration analysis."""
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_calibration",
    ROOT / "scripts" / "terminal-benchmark-calibration.py",
)
CALIBRATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CALIBRATION)


class TerminalBenchmarkCalibrationTests(unittest.TestCase):
    def test_winsorized_mean_clamps_twenty_percent_of_each_tail(self):
        values = [-100.0, 0.0, 1.0, 10.0, 100.0]

        estimate = CALIBRATION.winsorized_mean(values, proportion=0.2)
        decision = CALIBRATION.decide(
            values,
            directional_threshold=3.0,
            equivalence_band=0.75,
            estimator="winsorized-mean-20",
        )

        self.assertEqual(estimate, 4.2)
        self.assertEqual(decision["estimatePercent"], 4.2)
        self.assertEqual(decision["decision"], "slower")
        self.assertEqual(decision["usedSampleCount"], 5)

    def test_symmetric_difference_is_label_oriented_and_reversible(self):
        self.assertAlmostEqual(CALIBRATION.symmetric_difference(100, 105), 4.8780487805)
        self.assertAlmostEqual(CALIBRATION.symmetric_difference(105, 100), -4.8780487805)

    def test_relative_injection_scales_the_candidate_before_recomputing_effect(self):
        observed = CALIBRATION.symmetric_difference(100, 102)

        injected = CALIBRATION.inject_relative_effect(observed, 5)

        self.assertAlmostEqual(injected, CALIBRATION.symmetric_difference(100, 107.1))

    def test_decision_uses_median_without_deleting_a_detected_outlier(self):
        result = CALIBRATION.decide(
            [2.2, 2.4, 2.6, 2.8, 90.0],
            directional_threshold=2.25,
            equivalence_band=1.0,
        )

        self.assertEqual(result["decision"], "slower")
        self.assertEqual(result["estimatePercent"], 2.6)
        self.assertEqual(result["sampleCount"], 5)
        self.assertEqual(result["usedSampleCount"], 5)
        self.assertEqual(result["outlierIndices"], [4])

    def test_decision_reserves_the_gap_between_equivalence_and_directional_bands(self):
        equivalent = CALIBRATION.decide(
            [-0.8, 0.1, 0.7],
            directional_threshold=2.25,
            equivalence_band=1.0,
        )
        inconclusive = CALIBRATION.decide(
            [1.1, 1.5, 2.0],
            directional_threshold=2.25,
            equivalence_band=1.0,
        )

        self.assertEqual(equivalent["decision"], "equivalent")
        self.assertEqual(inconclusive["decision"], "inconclusive")

    def test_bootstrap_preserves_two_pair_balanced_quartets_and_is_reproducible(self):
        quartets = [[-1.0, 1.0], [-2.0, 2.0], [-3.0, 3.0]]

        first = CALIBRATION.calibrate_mode(
            quartets,
            pair_count=8,
            effect_percent=5,
            directional_threshold=2.25,
            equivalence_band=1.0,
            trial_count=200,
            seed=17,
        )
        second = CALIBRATION.calibrate_mode(
            quartets,
            pair_count=8,
            effect_percent=5,
            directional_threshold=2.25,
            equivalence_band=1.0,
            trial_count=200,
            seed=17,
        )

        self.assertEqual(first, second)
        self.assertEqual(first["resamplingUnit"], "balanced-schedule-quartet")
        self.assertEqual(
            first["physicalArmMapping"],
            "source-labels-swapped-on-alternating-trials",
        )
        self.assertEqual(first["pairCount"], 8)
        self.assertEqual(first["trialCountPerCondition"], 200)
        self.assertEqual(
            set(first["conditions"]),
            {"aa", "positive", "negative"},
        )

    def test_threshold_grid_matches_an_independently_calibrated_cell(self):
        arguments = {
            "quartets": [[-2.0, 1.0], [-1.0, 3.0], [-4.0, 2.0]],
            "pair_count": 6,
            "effect_percent": 3,
            "equivalence_band": 0.75,
            "trial_count": 200,
            "seed": 41,
            "estimator": "winsorized-mean-20",
        }

        grid = CALIBRATION.calibrate_threshold_grid(
            directional_thresholds=[1.0, 1.5],
            **arguments,
        )
        independent = CALIBRATION.calibrate_mode(
            directional_threshold=1.5,
            **arguments,
        )

        self.assertEqual(grid[1], independent)

    def test_paired_summary_loader_preserves_complete_schedule_quartets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "summary.json"
            path.write_text(json.dumps({
                "pairCount": 4,
                "schedule": "ABBABAAB",
                "pairedSymmetricPercent": {
                    "values": [1.0, -2.0, 3.0, -4.0],
                },
            }))

            quartets = CALIBRATION.load_paired_summary_quartets(path)

        self.assertEqual(quartets, [[1.0, -2.0], [3.0, -4.0]])

    def test_suite_summary_reports_union_bound_and_worst_effect_rates(self):
        reports = {
            "quiet": {
                "conditions": {
                    "aa": {"falsePositiveRate": 0.01},
                    "positive": {
                        "detectionRate": 0.96,
                        "inconclusiveRate": 0.04,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.94,
                        "inconclusiveRate": 0.06,
                        "wrongDirectionRate": 0.0,
                    },
                },
            },
            "noisy": {
                "conditions": {
                    "aa": {"falsePositiveRate": 0.02},
                    "positive": {
                        "detectionRate": 0.91,
                        "inconclusiveRate": 0.09,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.92,
                        "inconclusiveRate": 0.08,
                        "wrongDirectionRate": 0.001,
                    },
                },
            },
        }

        summary = CALIBRATION.summarize_suite(reports)

        self.assertAlmostEqual(summary["aaFalsePositiveUnionBound"], 0.03)
        self.assertEqual(summary["worstDetectionRate"], 0.91)
        self.assertEqual(summary["worstInconclusiveRate"], 0.09)
        self.assertEqual(summary["worstWrongDirectionRate"], 0.001)

    def test_frozen_suite_acceptance_requires_accuracy_union_and_runtime_gates(self):
        passing = {
            "quiet": {
                "conditions": {
                    "aa": {"falsePositiveRate": 0.01},
                    "positive": {
                        "detectionRate": 0.92,
                        "inconclusiveRate": 0.08,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.91,
                        "inconclusiveRate": 0.09,
                        "wrongDirectionRate": 0.0,
                    },
                },
            },
            "noisy": {
                "conditions": {
                    "aa": {"falsePositiveRate": 0.03},
                    "positive": {
                        "detectionRate": 0.90,
                        "inconclusiveRate": 0.10,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.93,
                        "inconclusiveRate": 0.07,
                        "wrongDirectionRate": 0.0,
                    },
                },
            },
        }

        accepted = CALIBRATION.assess_frozen_suite(
            passing,
            projected_wall_seconds=299.0,
            maximum_wall_seconds=300.0,
        )
        too_slow = CALIBRATION.assess_frozen_suite(
            passing,
            projected_wall_seconds=301.0,
            maximum_wall_seconds=300.0,
        )

        self.assertTrue(accepted["accepted"])
        self.assertEqual(accepted["failedGates"], [])
        self.assertFalse(too_slow["accepted"])
        self.assertEqual(too_slow["failedGates"], ["projectedWallSeconds"])

    def test_injected_inconclusive_rate_includes_equivalent_nondetections(self):
        decisions = [
            {"decision": "slower"},
            {"decision": "equivalent"},
            {"decision": "inconclusive"},
            {"decision": "faster"},
        ]

        summary = CALIBRATION.condition_summary(
            decisions,
            correct_direction="slower",
        )

        self.assertEqual(summary["detectionRate"], 0.25)
        self.assertEqual(summary["wrongDirectionRate"], 0.25)
        self.assertEqual(summary["inconclusiveRate"], 0.5)

    def test_select_candidate_uses_lowest_pair_count_that_clears_all_targets(self):
        candidates = [
            {
                "pairCount": 4,
                "directionalThresholdPercent": 2.0,
                "conditions": {
                    "aa": {"falsePositiveRate": 0.009},
                    "positive": {
                        "detectionRate": 0.89,
                        "inconclusiveRate": 0.11,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.95,
                        "inconclusiveRate": 0.05,
                        "wrongDirectionRate": 0.0,
                    },
                },
            },
            {
                "pairCount": 6,
                "directionalThresholdPercent": 2.25,
                "conditions": {
                    "aa": {"falsePositiveRate": 0.008},
                    "positive": {
                        "detectionRate": 0.92,
                        "inconclusiveRate": 0.08,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.94,
                        "inconclusiveRate": 0.06,
                        "wrongDirectionRate": 0.0,
                    },
                },
            },
            {
                "pairCount": 8,
                "directionalThresholdPercent": 2.0,
                "conditions": {
                    "aa": {"falsePositiveRate": 0.004},
                    "positive": {
                        "detectionRate": 0.98,
                        "inconclusiveRate": 0.02,
                        "wrongDirectionRate": 0.0,
                    },
                    "negative": {
                        "detectionRate": 0.98,
                        "inconclusiveRate": 0.02,
                        "wrongDirectionRate": 0.0,
                    },
                },
            },
        ]

        selected = CALIBRATION.select_candidate(
            candidates,
            maximum_false_positive_rate=0.01,
            minimum_detection_rate=0.90,
            maximum_inconclusive_rate=0.10,
            maximum_wrong_direction_rate=0.01,
        )

        self.assertEqual(selected["pairCount"], 6)
        self.assertEqual(selected["directionalThresholdPercent"], 2.25)

    def test_select_suite_combination_minimizes_runtime_under_union_bound(self):
        candidates = {
            "feed": [
                {
                    "name": "feed-fast",
                    "pairCount": 2,
                    "directionalThresholdPercent": 1.0,
                    "projectedWallSeconds": 5.0,
                    "conditions": {"aa": {"falsePositiveRate": 0.03}},
                },
                {
                    "name": "feed-quiet",
                    "pairCount": 4,
                    "directionalThresholdPercent": 1.2,
                    "projectedWallSeconds": 10.0,
                    "conditions": {"aa": {"falsePositiveRate": 0.01}},
                },
            ],
            "scrollback": [
                {
                    "name": "scroll-fast",
                    "pairCount": 2,
                    "directionalThresholdPercent": 1.0,
                    "projectedWallSeconds": 5.0,
                    "conditions": {"aa": {"falsePositiveRate": 0.03}},
                },
                {
                    "name": "scroll-quiet",
                    "pairCount": 4,
                    "directionalThresholdPercent": 1.2,
                    "projectedWallSeconds": 10.0,
                    "conditions": {"aa": {"falsePositiveRate": 0.01}},
                },
            ],
        }

        selected = CALIBRATION.select_suite_combination(
            candidates,
            maximum_false_positive_union_bound=0.05,
        )

        self.assertEqual(selected["projectedWallSeconds"], 15.0)
        self.assertEqual(selected["totalPairCount"], 6)
        self.assertEqual(selected["workloads"]["feed"]["name"], "feed-fast")
        self.assertEqual(
            selected["workloads"]["scrollback"]["name"],
            "scroll-quiet",
        )
        self.assertAlmostEqual(selected["aaFalsePositiveUnionBound"], 0.04)


if __name__ == "__main__":
    unittest.main()
