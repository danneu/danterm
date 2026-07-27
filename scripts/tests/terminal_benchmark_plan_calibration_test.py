#!/usr/bin/env python3
"""Behavioral tests for plan-time A/A calibration collection and rule selection."""
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_plan_calibration",
    ROOT / "scripts" / "terminal-benchmark-plan-calibration.py",
)
PLAN_CALIBRATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN_CALIBRATION)


def _blocks(values, *, metric="planNanosecondsPerDraw"):
    """Build a collected-block series from per-block plan timings in schedule order."""
    roles = "ABBA" * (len(values) // 4)
    return [
        {
            "index": index,
            "measurementRole": roles[index],
            "physicalArm": "a",
            "quartet": index // 4,
            metric: value,
        }
        for index, value in enumerate(values)
    ]


class PlanCalibrationScheduleTests(unittest.TestCase):
    def test_both_roles_of_an_aa_schedule_resolve_to_one_arm(self):
        # A/A calibration measures machine and schedule noise with no code
        # difference present. If the two roles reached different binaries, the
        # spread would contain a real effect and every false-positive rate
        # derived from it would be understated.
        schedule = PLAN_CALIBRATION.make_aa_schedule(("content-churn",), 2)

        blocks = schedule["content-churn"]
        self.assertEqual({block["physicalArm"] for block in blocks}, {"a"})
        self.assertEqual(
            [block["measurementRole"] for block in blocks],
            list("ABBABAAB"),
        )

    def test_a_workload_without_a_plan_metric_is_refused(self):
        # terminal-feed never plans a frame; scheduling it would collect blocks
        # that can only fail later at pairing time, after the machine time is
        # already spent.
        with self.assertRaises(ValueError):
            PLAN_CALIBRATION.make_aa_schedule(("terminal-feed",), 1)

    def test_an_empty_or_partial_series_is_refused(self):
        with self.assertRaises(ValueError):
            PLAN_CALIBRATION.make_aa_schedule((), 1)
        with self.assertRaises(ValueError):
            PLAN_CALIBRATION.make_aa_schedule(("content-churn",), 0)


class PlanCalibrationPairingTests(unittest.TestCase):
    def test_pairing_groups_adjacent_differences_by_quartet(self):
        # Resampling draws whole quartets so adjacent pairs keep the thermal and
        # scheduling neighborhood they were measured in; flattening here would
        # assume an independence the measurement does not have.
        quartets = PLAN_CALIBRATION.plan_quartets(
            "incremental-mixed", _blocks([100, 100, 110, 100, 100, 100, 100, 100])
        )

        self.assertEqual(len(quartets), 2)
        self.assertEqual([len(quartet) for quartet in quartets], [2, 2])
        self.assertEqual(quartets[0][0], 0.0)
        self.assertAlmostEqual(
            quartets[0][1],
            PLAN_CALIBRATION.CALIBRATION.symmetric_difference(100, 110),
        )

    def test_blocks_from_an_arm_without_the_plan_timer_are_refused(self):
        # A baseline predating the plan timer reports no plan nanoseconds. The
        # draw comparison tolerates that by omitting the descriptive line;
        # calibration cannot, because a rule chosen from a partial series would
        # be silently based on fewer pairs than it claims.
        blocks = _blocks([100, 100, 100, 100])
        blocks[2]["planNanosecondsPerDraw"] = None

        with self.assertRaises(ValueError):
            PLAN_CALIBRATION.plan_quartets("content-churn", blocks)

    def test_an_incomplete_quartet_is_refused(self):
        with self.assertRaises(ValueError):
            PLAN_CALIBRATION.plan_quartets("content-churn", _blocks([100, 100, 100, 100])[:2])


class PlanCalibrationCollectionTests(unittest.TestCase):
    def test_an_invalid_quartet_is_discarded_whole_and_retried(self):
        # Intent: a quartet containing any invalid block contributes nothing, and
        #   the retry replaces all four blocks rather than the failed one.
        # Why it exists: at this harness's per-block failure rate, patching a
        #   quartet with a block collected minutes later under different thermal
        #   conditions is the cheap-looking mistake. Calibration measures exactly
        #   that kind of drift, so a spliced quartet corrupts the noise estimate
        #   it exists to produce.
        attempts = []

        def collector(blocks):
            attempts.append(list(blocks))
            failing = len(attempts) == 1
            return {
                "workload": "content-churn",
                "invalidationReasons": ["block-2-reset-not-settled"] if failing else [],
                "rawBlocks": _blocks([100, 100, 100, 100]),
            }

        kept, discarded = PLAN_CALIBRATION.collect_quartets(
            "content-churn", collector, quartets=1, maximum_attempts=3
        )

        self.assertEqual(discarded, 1)
        self.assertEqual(len(kept), 1)
        self.assertEqual(len(attempts), 2)
        self.assertEqual([len(attempt) for attempt in attempts], [4, 4])

    def test_a_quartet_whose_app_never_reports_is_retried_like_an_invalid_one(self):
        # Intent: a collector that raises because no result file ever appeared
        #   discards that quartet and retries, rather than aborting the series.
        # Why it exists: the paired comparison lets this abort the invocation,
        #   which is correct there -- a verdict must not be assembled around a
        #   block that vanished. No verdict is assembled here, and treating a
        #   timeout as fatal while an invalid block is retryable would make the
        #   series' completion depend on which way the same failure surfaced.
        attempts = []

        def collector(blocks):
            attempts.append(list(blocks))
            if len(attempts) == 1:
                raise TimeoutError("final-draw.json")
            return {
                "workload": "incremental-mixed",
                "invalidationReasons": [],
                "rawBlocks": _blocks([100, 100, 100, 100]),
            }

        kept, discarded = PLAN_CALIBRATION.collect_quartets(
            "incremental-mixed", collector, quartets=1, maximum_attempts=3
        )

        self.assertEqual(discarded, 1)
        self.assertEqual(len(kept), 1)
        self.assertEqual(len(attempts), 2)

    def test_a_quartet_that_never_validates_fails_the_run(self):
        # Silently returning fewer quartets than requested would quietly shrink
        # the series a rule is chosen from while the report still names the
        # requested count.
        def collector(blocks):
            return {
                "workload": "style-churn",
                "invalidationReasons": ["block-0-missing-producer-write"],
                "rawBlocks": _blocks([100, 100, 100, 100]),
            }

        with self.assertRaises(RuntimeError):
            PLAN_CALIBRATION.collect_quartets(
                "style-churn", collector, quartets=1, maximum_attempts=2
            )


class PlanCalibrationSelectionTests(unittest.TestCase):
    def test_a_quiet_series_earns_a_rule_at_the_pair_count_it_is_given(self):
        # Intent: a plan timer whose A/A noise is small yields a rule, decided at
        #   the pair count the caller fixed rather than one the search picked.
        # Why it exists: plan time is measured on the draw metric's own blocks, so
        #   the only pair count a plan rule can ever be applied at is the one that
        #   mode already collects. A search free to spend more pairs would propose
        #   rules the comparison has no schedule to run.
        quiet = [[0.05, -0.05], [-0.1, 0.1], [0.02, -0.02], [0.0, 0.03]]

        proposal = PLAN_CALIBRATION.propose_rule(
            quiet,
            pair_count=2,
            effect_percent=5,
            equivalence_band_percent=1.0,
            trials=400,
            seed=7,
        )

        selected = proposal["selected"]
        self.assertIsNotNone(selected)
        self.assertEqual(selected["pairCount"], 2)
        self.assertGreater(selected["directionalThresholdPercent"], 1.0)
        self.assertEqual(selected["conditions"]["aa"]["falsePositiveRate"], 0.0)

    def test_a_series_noisier_than_the_effect_yields_no_rule(self):
        # Intent: when A/A noise swamps the effect a mode claims to detect, the
        # search returns nothing instead of proposing a threshold it cannot back.
        # Why it exists: the whole reason plan time is descriptive today is that
        # no calibrated rule stands behind it. A search that always answered would
        # convert that honest gap into a fabricated verdict.
        noisy = [[40.0, -35.0], [-50.0, 45.0], [30.0, -60.0], [55.0, -25.0]]

        proposal = PLAN_CALIBRATION.propose_rule(
            noisy,
            pair_count=2,
            effect_percent=5,
            equivalence_band_percent=1.0,
            trials=400,
            seed=7,
        )

        self.assertIsNone(proposal["selected"])
        self.assertGreater(proposal["searchedCellCount"], 0)

    def test_a_proposed_rule_is_usable_at_the_mode_and_workload_it_names(self):
        # Intent: every rule this tool proposes names a pair count the comparison
        #   actually collects for that mode and workload.
        # Why it exists: an earlier version searched a free pair-count grid and
        #   proposed 4-, 8-, and 16-pair rules for a quick mode that collects 2.
        #   Those cells read as real rules -- gates cleared, rates reported -- but
        #   no comparison could ever apply one, so freezing any of them would have
        #   put a threshold in the table that silently never fires.
        # Scenario: spec-first -- a report is read straight into DECISION_RULES.
        quiet = [[0.05, -0.05], [-0.1, 0.1], [0.02, -0.02], [0.0, 0.03]]

        results = PLAN_CALIBRATION.analyze_series(
            {"content-churn": quiet}, trials=400, seed=3
        )

        for mode, proposal in results["content-churn"]["modes"].items():
            selected = proposal["selected"]
            if selected is None:
                continue
            with self.subTest(mode=mode):
                self.assertEqual(
                    selected["pairCount"],
                    PLAN_CALIBRATION.COMPARE.decision_rule(mode)["workloads"][
                        "content-churn"
                    ]["pairCount"],
                )

    def test_every_searched_threshold_clears_the_equivalence_band(self):
        # A threshold at or below the equivalence band would make the two regions
        # overlap, so a single estimate could read both equivalent and directional.
        proposal = PLAN_CALIBRATION.propose_rule(
            [[0.05, -0.05], [-0.1, 0.1]],
            pair_count=2,
            effect_percent=3,
            equivalence_band_percent=0.75,
            trials=200,
            seed=11,
        )

        selected = proposal["selected"]
        self.assertIsNotNone(selected)
        self.assertGreater(selected["directionalThresholdPercent"], 0.75)


if __name__ == "__main__":
    unittest.main()
