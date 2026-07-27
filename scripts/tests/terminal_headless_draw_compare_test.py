#!/usr/bin/env python3
"""Behavioral tests for the headless interleaved two-arm draw comparison.

Covers the parts that decide correctness without building or measuring anything:
ABBA pairing, the module-name guard that keeps the ObjC runtime from collapsing
two arms into one, and the reported summary.
"""
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


if __name__ == "__main__":
    unittest.main()
