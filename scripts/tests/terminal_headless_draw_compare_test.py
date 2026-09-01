#!/usr/bin/env python3
"""Behavioral tests for the headless interleaved two-arm draw comparison.

Covers the parts that decide correctness without building or measuring anything:
ABBA pairing, the module-name guard that keeps the ObjC runtime from collapsing
two arms into one, and the reported summary.
"""
import argparse
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_headless_draw_compare",
    ROOT / "scripts" / "terminal-headless-draw-compare.py",
)
COMPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARE)


class PairingTests(unittest.TestCase):
    def test_abba_round_yields_two_pairs_in_schedule_order(self):
        # Intent: one ABBA round becomes the two paired differences the frozen
        #   calibration machinery expects from a quartet.
        # Why it exists: pins the schedule contract. Pairing A against the far B
        #   instead of its adjacent one would silently load any within-round drift
        #   onto the estimate, which is the whole reason the schedule is ABBA.
        # Scenario: arm B is uniformly 10% slower than arm A within a round.
        rounds = [{"a": [100.0, 100.0], "b": [110.0, 110.0]}]
        quartets = COMPARE.paired_quartets(rounds)
        self.assertEqual(len(quartets), 1)
        self.assertEqual(len(quartets[0]), 2)
        for difference in quartets[0]:
            self.assertGreater(difference, 0)
            self.assertAlmostEqual(difference, quartets[0][0])

    def test_identical_arms_produce_zero_difference(self):
        rounds = [{"a": [500.0, 500.0], "b": [500.0, 500.0]}]
        self.assertEqual(COMPARE.paired_quartets(rounds), [[0.0, 0.0]])

    def test_a_slower_arm_b_is_positive_and_reversing_flips_the_sign(self):
        # Intent: the sign convention is "positive means the candidate arm B is
        #   slower", and it is symmetric under swapping the arms.
        forward = COMPARE.paired_quartets([{"a": [100.0, 100.0], "b": [120.0, 120.0]}])
        reversed_arms = COMPARE.paired_quartets(
            [{"a": [120.0, 120.0], "b": [100.0, 100.0]}]
        )
        self.assertGreater(forward[0][0], 0)
        self.assertAlmostEqual(forward[0][0], -reversed_arms[0][0])

    def test_a_round_missing_a_batch_is_rejected(self):
        with self.assertRaises(ValueError):
            COMPARE.paired_quartets([{"a": [100.0], "b": [100.0, 100.0]}])

    def test_a_zero_duration_batch_is_rejected(self):
        # A zero batch means the arm never ran; averaging it would silently
        # report a 200% difference rather than failing.
        with self.assertRaises(ValueError):
            COMPARE.paired_quartets([{"a": [0.0, 100.0], "b": [100.0, 100.0]}])


class AbsolutePairingTests(unittest.TestCase):
    def test_a_per_draw_difference_is_the_batch_difference_over_the_batch_count(self):
        # Intent: an absolute paired value is nanoseconds for one draw, not one batch.
        # Why it exists: research/11/F4 -- a batch total quoted as a per-draw duration is
        #   the exact error that put a physically impossible number in a finding, and
        #   nothing in the report let a reader divide it back out.
        # Scenario: the candidate arm costs 10ns more per draw across a 100-draw batch.
        rounds = [{"a": [1000.0, 1000.0], "b": [2000.0, 2000.0]}]
        values = COMPARE.paired_absolute_differences(rounds, batch_count=100)
        self.assertEqual(values, [10.0, 10.0])

    def test_reversing_the_arms_flips_the_sign(self):
        forward = COMPARE.paired_absolute_differences(
            [{"a": [1000.0, 1000.0], "b": [1200.0, 1200.0]}], batch_count=10
        )
        reverse = COMPARE.paired_absolute_differences(
            [{"a": [1200.0, 1200.0], "b": [1000.0, 1000.0]}], batch_count=10
        )
        self.assertEqual(forward, [20.0, 20.0])
        self.assertEqual(reverse, [-20.0, -20.0])

    def test_a_zero_batch_count_is_rejected(self):
        # Dividing by it would be an exception; reporting it would be a per-batch number
        # wearing a per-draw name.
        with self.assertRaises(ValueError):
            COMPARE.paired_absolute_differences(
                [{"a": [1.0, 1.0], "b": [1.0, 1.0]}], batch_count=0
            )

    def test_a_zero_duration_batch_is_rejected(self):
        with self.assertRaises(ValueError):
            COMPARE.paired_absolute_differences(
                [{"a": [0.0, 1.0], "b": [1.0, 1.0]}], batch_count=1
            )


def absolute_runs(forward_values, reverse_values, icon_cell_count=4000):
    """Two direction runs carrying known per-draw differences, and nothing else."""
    return [
        {
            "direction": direction,
            "report": {
                "absolute": {
                    "iconCellCount": icon_cell_count,
                    "pairedMeanNanosecondsPerDraw": (
                        sum(values) / len(values) if values else 0.0
                    ),
                    "pairedValuesNanosecondsPerDraw": values,
                },
            },
        }
        for direction, values in (
            ("forward", forward_values), ("reverse", reverse_values)
        )
    ]


class AbsoluteAntisymmetricTests(unittest.TestCase):
    def test_the_effect_is_antisymmetric_and_normalized_per_icon_cell(self):
        # Intent: the reported absolute effect is (forward - reverse) / 2, keeps the sign
        #   of the direction that ran the candidate second, and divides by the arm's own
        #   icon cell count.
        # Why it exists: D4. A one-direction absolute difference carries the same slot bias
        #   the percentage estimate exists to cancel -- the driver's first positive control
        #   read -1.797% one way and +0.101% the other -- so a nanosecond number taken from
        #   one direction is not the cost of anything.
        # Scenario: a true -40ns/draw saving sitting on top of a +10ns/draw slot bias, on a
        #   workload of 4000 icon cells.
        estimate = COMPARE.absolute_antisymmetric_estimate(
            absolute_runs([-30.0, -30.0], [50.0, 50.0], icon_cell_count=4000)
        )
        self.assertAlmostEqual(estimate["realEffectNanosecondsPerDraw"], -40.0)
        self.assertAlmostEqual(estimate["orderBiasNanosecondsPerDraw"], 10.0)
        self.assertEqual(estimate["iconCellCount"], 4000)
        self.assertAlmostEqual(
            estimate["realEffectNanosecondsPerIconCell"], -0.01
        )

    def test_a_pure_order_bias_reports_no_effect(self):
        estimate = COMPARE.absolute_antisymmetric_estimate(
            absolute_runs([12.0], [12.0])
        )
        self.assertAlmostEqual(estimate["realEffectNanosecondsPerDraw"], 0.0)
        self.assertAlmostEqual(estimate["orderBiasNanosecondsPerDraw"], 12.0)

    def test_a_workload_with_no_icon_cells_reports_no_per_icon_cost(self):
        # Intent: "not measurable here" is stated, not computed as zero.
        # Why it exists: agent-docs/measurement-discipline.md -- an instrument must say
        #   "not measured" apart from "measured zero". btop-shaped and text-shaped cannot
        #   reach the symbols path at all, so a per-icon-cell number from them would be a
        #   division by a denominator that does not exist.
        estimate = COMPARE.absolute_antisymmetric_estimate(
            absolute_runs([-4.0], [4.0], icon_cell_count=0)
        )
        self.assertAlmostEqual(estimate["realEffectNanosecondsPerDraw"], -4.0)
        self.assertIsNone(estimate["realEffectNanosecondsPerIconCell"])

    def test_both_directions_are_required(self):
        with self.assertRaises(ValueError):
            COMPARE.absolute_antisymmetric_estimate(absolute_runs([-4.0], []))

    def test_directions_that_drew_different_icon_counts_are_rejected(self):
        # Two runs of different corpora cannot be paired; an average of their
        # denominators would hide that they never measured the same thing.
        runs = absolute_runs([-4.0], [4.0])
        runs[1]["report"]["absolute"]["iconCellCount"] = 10
        with self.assertRaises(ValueError):
            COMPARE.absolute_antisymmetric_estimate(runs)


class ModuleNameGuardTests(unittest.TestCase):
    def test_identical_module_names_are_rejected(self):
        # Intent: refuse to run two arms built under the same Swift module name.
        # Why it exists: Swift classes register with the ObjC runtime, which dedups
        #   globally even under RTLD_LOCAL. Two arms sharing a module name can both
        #   execute one arm's code, turning any comparison into a tautology that
        #   still reports plausible numbers. Detected during the F22 pilot.
        # Scenario: a caller wires both arms to the default module name.
        with self.assertRaises(ValueError):
            COMPARE.validate_module_names("DrawArm", "DrawArm")

    def test_distinct_module_names_are_accepted(self):
        COMPARE.validate_module_names("DrawArmA", "DrawArmB")


class ManifestTests(unittest.TestCase):
    def test_manifest_binds_the_module_name_and_its_own_core_checkout(self):
        # Intent: each arm compiles its own module name against its own
        #   TerminalCore checkout, so two revisions can be built side by side.
        manifest = COMPARE.arm_manifest("DrawArmA", pathlib.Path("/tmp/revA/TerminalCore"))
        self.assertIn('name: "DrawArmA"', manifest)
        self.assertIn("/tmp/revA/TerminalCore", manifest)
        self.assertIn("type: .dynamic", manifest)

    def test_manifest_requires_the_core_checkout_to_keep_its_basename(self):
        # Intent: reject a checkout path SwiftPM cannot resolve the product from.
        # Why it exists: SwiftPM takes a path dependency's identity from the
        #   directory basename, so a copy named `coreA` fails to resolve
        #   `.product(package: "TerminalCore")`. Cost a build cycle in the F23
        #   pilot; failing early names the cause instead of surfacing a resolver
        #   error about an "unknown package".
        with self.assertRaises(ValueError):
            COMPARE.arm_manifest("DrawArmA", pathlib.Path("/tmp/coreA"))


class FakeArm:
    """Records every batch size it is asked for, at a fixed cost per draw."""

    def __init__(self, nanoseconds_per_draw, icon_cells=0):
        self.nanoseconds_per_draw = nanoseconds_per_draw
        self.icon_cells = icon_cells
        self.batches = []

    def prepare(self, columns, rows, clip_rows):
        pass

    def batch(self, count):
        self.batches.append(count)
        return count * self.nanoseconds_per_draw

    def icon_cell_count(self):
        return self.icon_cells


class IconCellCountTests(unittest.TestCase):
    def test_two_arms_that_agree_report_their_shared_count(self):
        self.assertEqual(
            COMPARE.shared_icon_cell_count([FakeArm(1, 4000), FakeArm(1, 4000)]), 4000
        )

    def test_two_arms_that_disagree_are_refused(self):
        # Intent: refuse a pair whose surfaces hold different numbers of icon cells.
        # Why it exists: the two arms are built from different checkouts, so a corpus
        #   change between them would be paired as if it were a speed change. A refusal
        #   names the cause; an average would publish it as a result.
        with self.assertRaises(RuntimeError):
            COMPARE.shared_icon_cell_count([FakeArm(1, 4000), FakeArm(1, 3999)])


class SymmetryTests(unittest.TestCase):
    def test_batch_count_does_not_depend_on_which_arm_is_baseline(self):
        # Intent: the measured batch size is a property of the pair, not of which
        #   arm happens to be in the baseline slot.
        # Why it exists: calibrating on the baseline arm alone made the batch size
        #   depend on comparison direction, so swapping the arms changed the
        #   measurement rather than just its sign. Found by the first positive
        #   control, where forward and reverse failed to sum to zero.
        # Scenario: two arms of genuinely different speed, compared both ways.
        slow, fast = FakeArm(100), FakeArm(50)
        forward = COMPARE.calibrate_batch_count([slow, fast], target_nanoseconds=1000)
        reverse = COMPARE.calibrate_batch_count([FakeArm(50), FakeArm(100)],
                                                target_nanoseconds=1000)
        self.assertEqual(forward, reverse)

    def test_batch_count_satisfies_the_floor_for_the_fastest_arm(self):
        # The floor exists to hold occupancy; the faster arm is the one that would
        # fall under it, so it is the binding constraint.
        slow, fast = FakeArm(100), FakeArm(50)
        count = COMPARE.calibrate_batch_count([slow, fast], target_nanoseconds=1000)
        self.assertGreaterEqual(count * 50, 1000)

    def test_warm_up_touches_every_arm_before_measurement(self):
        # Intent: no arm enters its first measured batch cold.
        # Why it exists: calibration ran batches on the baseline arm only, leaving
        #   the candidate's caches cold for its first measured batch. That biased
        #   the paired difference against whichever arm was the candidate -- a
        #   bias invisible to an A/A control, where both arms are the same code.
        arms = [FakeArm(100), FakeArm(50)]
        COMPARE.warm_up(arms, batch_count=7)
        for arm in arms:
            self.assertIn(7, arm.batches)


class DirectionScheduleTests(unittest.TestCase):
    def test_the_direction_schedule_is_abba(self):
        # Intent: neither direction is systematically the first measured.
        # Why it exists: running forward then reverse put forward immediately after
        #   the rebuild every time, which reintroduced the asymmetry the warm-up fix
        #   had just removed and showed up as a +0.511% reported order bias. ABBA at
        #   the direction level cancels a monotonic session drift the same way the
        #   batch schedule cancels it within a round.
        self.assertEqual(
            COMPARE.direction_schedule(),
            ["forward", "reverse", "reverse", "forward"],
        )

    def test_each_direction_is_measured_equally_often(self):
        schedule = COMPARE.direction_schedule()
        self.assertEqual(schedule.count("forward"), schedule.count("reverse"))


class AntisymmetricTests(unittest.TestCase):
    def test_a_pure_effect_with_no_bias_is_recovered_intact(self):
        estimate = COMPARE.antisymmetric_estimate([-2.0, -2.0], [2.0, 2.0])
        self.assertAlmostEqual(estimate["realEffectPercent"], -2.0)
        self.assertAlmostEqual(estimate["orderBiasPercent"], 0.0)

    def test_an_order_bias_is_separated_from_the_effect(self):
        # Intent: a bias that survives swapping the arms is reported apart from the
        #   effect that reverses with them.
        # Why it exists: the first positive control read -1.797% in one direction and
        #   +0.101% in the other. Averaging or trusting one direction would have
        #   published a bias as a performance claim.
        # Scenario: a true -1% effect sitting on top of a +0.5% order bias.
        estimate = COMPARE.antisymmetric_estimate([-0.5], [1.5])
        self.assertAlmostEqual(estimate["realEffectPercent"], -1.0)
        self.assertAlmostEqual(estimate["orderBiasPercent"], 0.5)

    def test_a_pure_bias_reports_no_effect(self):
        estimate = COMPARE.antisymmetric_estimate([0.8], [0.8])
        self.assertAlmostEqual(estimate["realEffectPercent"], 0.0)
        self.assertAlmostEqual(estimate["orderBiasPercent"], 0.8)

    def test_both_directions_are_required(self):
        with self.assertRaises(ValueError):
            COMPARE.antisymmetric_estimate([-1.0], [])


class SummaryTests(unittest.TestCase):
    def test_summary_reports_pair_count_and_spread(self):
        quartets = [[1.0, -1.0], [2.0, -2.0]]
        summary = COMPARE.summarize(quartets)
        self.assertEqual(summary["pairCount"], 4)
        self.assertEqual(summary["quartetCount"], 2)
        self.assertAlmostEqual(summary["pairedMeanPercent"], 0.0)
        self.assertGreater(summary["pairedStandardDeviationPercent"], 0)

    def test_summary_is_empty_safe(self):
        with self.assertRaises(ValueError):
            COMPARE.summarize([])


class FrozenRuleTests(unittest.TestCase):
    """The frozen fallback-shaped rule, and the reports that may not be read without it."""

    def test_the_fallback_shaped_rule_carries_d1s_frozen_numbers(self):
        # Intent: the rule the report prints is the one a human froze, not one the
        #   script invented.
        # Why it exists: research/40/D1 froze +/-1.00% on realEffectPercent from one
        #   --both-directions invocation at 8 rounds per direction, valid only below a
        #   2.5% order bias. A number that drifts from that is a different rule wearing
        #   the same name.
        rule = COMPARE.FROZEN_RULES["fallback-shaped"]
        self.assertEqual(rule["quantity"], "realEffectPercent")
        self.assertEqual(rule["mode"], "both-directions")
        self.assertEqual(rule["roundsPerDirection"], 8)
        self.assertAlmostEqual(rule["directionalThresholdPercent"], 1.00)
        self.assertAlmostEqual(rule["orderBiasGuardPercent"], 2.50)

    def test_a_verdict_carries_the_rule_and_its_guard_beside_it(self):
        # Intent: a report that states a verdict also states the threshold and the
        #   order-bias guard that produced it.
        # Why it exists: D1 requires that a fallback-shaped report cannot be read
        #   without its rule, so a verdict quoted out of context still carries the
        #   conditions under which it is a verdict.
        # Scenario: the expected magnitude of the shape-once cache, well past -80%.
        decision = COMPARE.frozen_decision(
            "fallback-shaped", rounds=8, mode="both-directions",
            estimate={"realEffectPercent": -84.0, "orderBiasPercent": 0.4},
        )
        self.assertEqual(decision["verdict"], "faster")
        self.assertAlmostEqual(decision["rule"]["directionalThresholdPercent"], 1.00)
        self.assertAlmostEqual(decision["rule"]["orderBiasGuardPercent"], 2.50)
        self.assertEqual(decision["rule"]["source"], "research/40/D1")

    def test_a_candidate_past_the_threshold_the_other_way_reads_slower(self):
        decision = COMPARE.frozen_decision(
            "fallback-shaped", rounds=8, mode="both-directions",
            estimate={"realEffectPercent": 4.2, "orderBiasPercent": 0.1},
        )
        self.assertEqual(decision["verdict"], "slower")

    def test_an_effect_inside_the_threshold_is_inconclusive_not_equivalent(self):
        # Intent: a small reading is refused as a claim in either direction.
        # Why it exists: D1 accepted the threshold as a false-positive floor and
        #   explicitly bounds detection not at all, so "inside the band" cannot mean
        #   "the two revisions are the same".
        decision = COMPARE.frozen_decision(
            "fallback-shaped", rounds=8, mode="both-directions",
            estimate={"realEffectPercent": -0.62, "orderBiasPercent": 1.3},
        )
        self.assertEqual(decision["verdict"], "inconclusive")

    def test_an_order_bias_at_or_above_the_guard_invalidates_the_run(self):
        # Intent: a run above the guard is invalid, and stays invalid however large
        #   its effect looks.
        # Why it exists: D1's guard is "re-run, never read". Reporting a huge effect
        #   beside a broken bias is exactly the reading that turns a slot asymmetry
        #   into a performance claim.
        decision = COMPARE.frozen_decision(
            "fallback-shaped", rounds=8, mode="both-directions",
            estimate={"realEffectPercent": -84.0, "orderBiasPercent": 2.5},
        )
        self.assertEqual(decision["verdict"], "invalid")

    def test_the_wrong_round_count_is_not_the_frozen_cell(self):
        # Intent: the rule holds at 8 rounds per direction and says so when it did
        #   not get them.
        # Why it exists: a frozen cell is a set of parameters, not just a number
        #   (agent-docs/measurement-discipline.md: a screen is not a freeze). Reading
        #   the same threshold off 2 rounds silently changes the false-positive rate
        #   the freeze bounded.
        decision = COMPARE.frozen_decision(
            "fallback-shaped", rounds=2, mode="both-directions",
            estimate={"realEffectPercent": -84.0, "orderBiasPercent": 0.2},
        )
        self.assertEqual(decision["verdict"], "invalid")

    def test_a_single_direction_run_of_fallback_shaped_is_descriptive(self):
        # Intent: the direction the default recipe still produces decides nothing.
        # Why it exists: D1 refuses a single-direction verdict at any magnitude,
        #   because the arm carries a +1.0 to +1.7% slot bias that only swapping the
        #   arms removes. The report has to say so itself; the reader may not know.
        decision = COMPARE.frozen_decision(
            "fallback-shaped", rounds=8, mode="single-direction",
        )
        self.assertEqual(decision["verdict"], "descriptive")
        self.assertAlmostEqual(decision["rule"]["directionalThresholdPercent"], 1.00)

    def test_a_workload_with_no_frozen_rule_reports_that_it_has_none(self):
        # Intent: "no rule frozen" is a stated answer, never a missing key.
        # Why it exists: agent-docs/measurement-discipline.md -- an instrument must be
        #   able to say "not measured" apart from "measured zero". An absent decision
        #   block reads as no opinion, which is how an uncalibrated number gets quoted.
        for workload in COMPARE.WORKLOADS:
            with self.subTest(workload=workload):
                decision = COMPARE.frozen_decision(
                    workload, rounds=8, mode="both-directions",
                    estimate={"realEffectPercent": -84.0, "orderBiasPercent": 0.2},
                )
                self.assertIn("verdict", decision)
                if workload not in COMPARE.FROZEN_RULES:
                    self.assertIsNone(decision["rule"])
                    self.assertEqual(decision["verdict"], "descriptive")


class ReportEnvelopeTests(unittest.TestCase):
    """What the script actually emits, which is the only thing anyone downstream sees."""

    def arguments(self, workload="fallback-shaped", rounds=8):
        core = pathlib.Path("/tmp/revA/TerminalCore")
        return argparse.Namespace(
            workload=workload, rounds=rounds, columns=179, rows=66, clip_rows=0,
            baseline_core=core, candidate_core=core,
        )

    def test_a_both_directions_report_carries_the_absolute_effect_and_its_bias(self):
        # Intent: the emitted report states the absolute per-draw effect, the per-icon-cell
        #   cost, and the order bias that sat beside them -- all from the direction runs it
        #   already carries.
        # Why it exists: D4. A percentage alone cannot say whether a saving is worth its
        #   memory, and a per-icon-cell number reconstructed outside the report is a number
        #   nobody can check. The bias travels with the effect for the same reason it does
        #   on the percentage side: without it, a slot asymmetry reads as a cost.
        # Scenario: a -40ns/draw effect on a 4000-icon-cell workload, over a +10ns bias.
        report = COMPARE.both_directions_report(
            self.arguments(),
            estimate={"realEffectPercent": -2.0, "orderBiasPercent": 0.4},
            runs=absolute_runs([-30.0], [50.0], icon_cell_count=4000),
        )
        absolute = report["absoluteEstimate"]
        self.assertAlmostEqual(absolute["realEffectNanosecondsPerDraw"], -40.0)
        self.assertAlmostEqual(absolute["orderBiasNanosecondsPerDraw"], 10.0)
        self.assertAlmostEqual(absolute["realEffectNanosecondsPerIconCell"], -0.01)
        self.assertEqual(absolute["iconCellCount"], 4000)

    def test_a_single_direction_report_carries_its_raw_absolute_values(self):
        # Intent: one direction's report holds the per-draw differences and the icon cell
        #   count the two-direction estimate is built from.
        # Why it exists: the two-direction run reads its sub-reports, so a dropped block
        #   there is a missing estimate here. Keeping the raw values also lets a reader
        #   recompute the estimate rather than trust it.
        report = COMPARE.single_direction_report(
            self.arguments(), batch_count=4, quartets=[[-84.0, -84.0]],
            absolute_differences=[-12.0, -8.0], icon_cell_count=4000,
        )
        self.assertEqual(
            report["absolute"]["pairedValuesNanosecondsPerDraw"], [-12.0, -8.0]
        )
        self.assertAlmostEqual(report["absolute"]["pairedMeanNanosecondsPerDraw"], -10.0)
        self.assertEqual(report["absolute"]["iconCellCount"], 4000)

    def test_a_both_directions_report_carries_the_verdict_and_the_rule(self):
        # Intent: the emitted report -- not just the helper behind it -- carries the
        #   frozen rule beside its verdict.
        # Why it exists: D1 requires that a fallback-shaped report cannot be read
        #   without its rule. A rule the report does not print protects nobody, and a
        #   dropped key would leave every unit test on the rule itself still green.
        report = COMPARE.both_directions_report(
            self.arguments(),
            estimate={"realEffectPercent": -84.0, "orderBiasPercent": 0.4},
            runs=absolute_runs([-30.0], [50.0]),
        )
        self.assertEqual(report["decision"]["verdict"], "faster")
        self.assertAlmostEqual(
            report["decision"]["rule"]["directionalThresholdPercent"], 1.00
        )
        self.assertAlmostEqual(
            report["decision"]["rule"]["orderBiasGuardPercent"], 2.50
        )
        self.assertEqual(report["workload"], "fallback-shaped")

    def test_a_single_direction_report_says_it_decides_nothing(self):
        # Intent: the report the default recipe emits labels itself descriptive.
        # Why it exists: that is the run an agent gets with no candidate checkout, so
        #   it is the one most likely to be quoted as a result.
        report = COMPARE.single_direction_report(
            self.arguments(), batch_count=4, quartets=[[-84.0, -84.0]],
            absolute_differences=[-10.0, -10.0], icon_cell_count=0,
        )
        self.assertEqual(report["decision"]["verdict"], "descriptive")
        self.assertEqual(report["workload"], "fallback-shaped")

    def test_every_report_carries_a_decision_block(self):
        # Intent: no workload and no mode emits a report without a stated opinion.
        # Why it exists: agent-docs/measurement-discipline.md -- an absent block reads
        #   as no opinion, and a number with no opinion beside it gets quoted as one.
        for workload in COMPARE.WORKLOADS:
            with self.subTest(workload=workload):
                arguments = self.arguments(workload=workload)
                both = COMPARE.both_directions_report(
                    arguments,
                    estimate={"realEffectPercent": -1.0, "orderBiasPercent": 0.1},
                    runs=absolute_runs([-1.0], [1.0]),
                )
                single = COMPARE.single_direction_report(
                    arguments, batch_count=4, quartets=[[-1.0, -1.0]],
                    absolute_differences=[-1.0, -1.0], icon_cell_count=0,
                )
                self.assertIn("verdict", both["decision"])
                self.assertIn("verdict", single["decision"])


if __name__ == "__main__":
    unittest.main()
