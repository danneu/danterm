#!/usr/bin/env python3
"""One question: is the benchmark workload set closed and agreed on everywhere?

The producer emits stimulus, the harness gates invocations, and the paired
lifecycle schedules blocks -- three places that each name draw workloads. This
file exists so the three cannot drift apart, which is how orphaned workloads
(stimulus nothing measures, or a ladder entry nothing can produce) appear.
"""
import importlib.util
import pathlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PRODUCER = _load("terminal_benchmark_producer", "terminal-benchmark-producer.py")
VALIDATION = _load("terminal_benchmark_validation", "terminal-benchmark-validation.py")
COMPARE = _load("terminal_benchmark_compare", "terminal-benchmark-compare.py")

DRAW_WORKLOADS = (
    "full-screen-content-churn",
    "full-screen-style-churn",
    "full-screen-incremental-mixed-churn",
)


class TerminalBenchmarkWorkloadSetTests(unittest.TestCase):
    def test_producer_and_paired_lifecycle_name_the_same_draw_workloads(self):
        # Intent: the stimulus generator and the paired block scheduler accept
        #   exactly the same three full-screen draw workloads.
        # Why it exists: a workload present in only one of them is unreachable --
        #   either stimulus no comparison measures, or a schedulable block whose
        #   frames cannot be produced. Both fail late, inside a GUI run.
        # Scenario: spec-first; the paired ladder is the only decision surface, so
        #   every draw workload it names must be producible and vice versa.
        self.assertEqual(PRODUCER.REDRAW_WORKLOADS, DRAW_WORKLOADS)
        for workload in DRAW_WORKLOADS:
            with self.subTest(workload=workload):
                VALIDATION.PersistentDrawArms(
                    {"a": ROOT, "b": ROOT}, workload=workload, output=ROOT / ".build"
                )

    def test_every_calibrated_workload_carries_a_frozen_rule_in_both_modes(self):
        # Intent: membership in `WORKLOADS` and having a screened decision rule are
        #   the same fact, in both directions.
        # Why it exists: `WORKLOADS` is what `confirm` runs and what the
        #   predeclared manifest is sized from, while `DECISION_RULES` is what
        #   turns a block series into a verdict. A workload in one and not the
        #   other is either a comparison that raises mid-run after collecting real
        #   blocks, or a frozen threshold nothing can reach. Both were reachable
        #   states while `synchronized-frames` was being screened.
        # Scenario: spec-first; the corpus gained its sixth workload, which spent
        #   time deliberately collectable-but-undecidable and had to graduate
        #   cleanly rather than half-way.
        for mode in COMPARE.MODES:
            rule = COMPARE.decision_rule(mode)
            with self.subTest(mode=mode):
                self.assertEqual(
                    set(rule["workloads"]),
                    set(VALIDATION.WORKLOADS),
                    f"{mode} rules and WORKLOADS disagree",
                )
        # And a candidate is the exact complement: collectable, never decidable.
        for candidate in VALIDATION.CANDIDATE_WORKLOADS:
            with self.subTest(candidate=candidate):
                self.assertNotIn(candidate, VALIDATION.WORKLOADS)
                for mode in COMPARE.MODES:
                    self.assertNotIn(
                        candidate, COMPARE.decision_rule(mode)["workloads"]
                    )

    def test_the_captured_tui_workload_is_selectable_and_decidable(self):
        # Intent: `synchronized-frames` can be named by `quick`, is run by
        #   `confirm`, and carries the thresholds its A/A screen proposed.
        # Why it exists: pins the graduation from candidate to calibrated. The
        #   numbers are the conservative envelope across two replicating 48-pair
        #   screens (20/F11) -- not a hand-picked pair, which is the failure mode
        #   a frozen rule cannot recover from, since every later directional claim
        #   inherits it.
        # Scenario: spec-first; 20/D4 froze the rule after three screens.
        self.assertEqual(
            COMPARE.resolve_workloads("quick", "synchronized-frames"),
            ("synchronized-frames",),
        )
        self.assertIn("synchronized-frames", COMPARE.resolve_workloads("confirm"))
        quick = COMPARE.decision_rule("quick")["workloads"]["synchronized-frames"]
        confirm = COMPARE.decision_rule("confirm")["workloads"]["synchronized-frames"]
        self.assertEqual(quick["pairCount"], 6)
        self.assertEqual(quick["directionalThresholdPercent"], 2.65)
        self.assertEqual(confirm["pairCount"], 8)
        self.assertEqual(confirm["directionalThresholdPercent"], 2.15)

    def test_the_harness_rejects_a_draw_workload_outside_that_set(self):
        # Intent: `terminal-benchmark.sh` refuses any workload that is neither one
        #   of the three draw workloads nor a committed corpus entry.
        # Why it exists: the gate used to be a `full-screen-*-churn` glob, so a
        #   deleted or misspelled workload launched a real app and only failed once
        #   the producer raised -- after a build, a launch, and a window.
        # Scenario: spec-first; an operator names a workload that no longer exists.
        for workload in (
            "full-screen-symbol-churn",
            "full-screen-sprite-coverage-churn",
            "full-screen-mixed-churn",
            "full-screen-typo-churn",
        ):
            with self.subTest(workload=workload):
                completed = subprocess.run(
                    [str(ROOT / "scripts" / "terminal-benchmark.sh"), workload],
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(completed.returncode, 2)
                self.assertIn(f"Unknown workload: {workload}", completed.stderr)


if __name__ == "__main__":
    unittest.main()
