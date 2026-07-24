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
