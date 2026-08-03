#!/usr/bin/env python3
"""One question: does a candidate screen carry the host conditions it was taken under?

A screen is a measurement whose whole output is a proposed decision rule, so the
conditions it was taken under decide whether a replicate may be compared against
it. 28/F5's screen 1 had to state those conditions in prose because the script
recorded none. This file pins the wiring that fixed it: the comparison driver's
preflight is sampled twice -- once at invocation, once immediately before the
first block -- persisted in the screen report, and rendered for the operator.

It does not test `sample_host_conditions` itself; that lives with the driver in
terminal_benchmark_compare_test.py.
"""
import importlib.util
import io
import json
import pathlib
import sys
import unittest
from contextlib import redirect_stdout


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SCREEN = _load("terminal_benchmark_candidate_screen",
               "terminal-benchmark-candidate-screen.py")

READING = {
    "available": True,
    "loadAverage": {"one": 2.5, "five": 2.6, "fifteen": 2.7},
    "processorCount": 10,
    "loadPerProcessor": 0.25,
    "topExternalProcesses": [{"pid": 1, "command": "/usr/bin/WindowServer",
                              "cpuPercent": 1.2}],
    "excludedHarnessProcessCount": 3,
}


class CandidateScreenHostConditionsTests(unittest.TestCase):
    def test_screen_samples_the_preflight_before_invocation_and_before_the_first_block(self):
        # Intent: `run_screen` takes two host readings -- one when it is invoked,
        #   one after arm materialization and immediately before collection -- and
        #   persists both in the report under `hostConditions`.
        # Why it exists: 28/F3 measured that load during a run is confounded by the
        #   run's own builds, so one reading taken at either end alone is
        #   uninterpretable. The pair is the annotation; a single sample is not.
        readings = iter([dict(READING, label="atInvocation"),
                         dict(READING, label="beforeFirstBlock")])
        order = []

        def sample():
            reading = next(readings)
            order.append(("sample", reading["label"]))
            return reading

        report = _run_stubbed_screen(sample, order)
        self.assertEqual(
            [entry for entry in order],
            [("sample", "atInvocation"), ("materialize", "arm"),
             ("sample", "beforeFirstBlock"), ("collect", "blocks")],
        )
        self.assertEqual(report["hostConditions"]["atInvocation"]["label"],
                         "atInvocation")
        self.assertEqual(report["hostConditions"]["beforeFirstBlock"]["label"],
                         "beforeFirstBlock")

    def test_persisted_report_carries_both_readings(self):
        # Intent: the on-disk `candidate-screen.json` carries the readings, not
        #   just the returned dict, so a screen's conditions outlive the terminal
        #   the operator ran it in.
        report = _run_stubbed_screen(lambda: dict(READING), [])
        persisted = json.loads(
            (pathlib.Path(report["artifacts"]) / "candidate-screen.json")
            .read_text(encoding="utf-8")
        )
        self.assertIn("atInvocation", persisted["hostConditions"])
        self.assertIn("beforeFirstBlock", persisted["hostConditions"])

    def test_render_report_shows_the_readings_without_a_verdict(self):
        # Intent: the operator-facing render states both readings and says no
        #   threshold is applied.
        # Why it exists: 28/D1 pitch 4 admitted the preflight scoped to
        #   annotate-only. A render that read like a pass/fail would smuggle in
        #   the uncalibrated gate the decision refused.
        rendered = SCREEN.render_report({
            "workload": "retained-browse",
            "metric": "planNanosecondsPerFrame",
            "tree": "abc123",
            "quartetsKept": 12,
            "quartetsDiscarded": 0,
            "hostConditions": {"atInvocation": dict(READING),
                               "beforeFirstBlock": None},
            "series": {
                "pairCount": 24, "medianPercent": 0.19,
                "standardDeviationPercent": 0.99,
                "trimmedStandardDeviationPercent": 0.90,
                "minimumPercent": -1.42, "maximumPercent": 2.00,
            },
            "modes": {},
        })
        self.assertIn("no threshold is applied", rendered)
        self.assertIn("load 2.50/2.60/2.70", rendered)
        self.assertIn("not measured", rendered)

    def test_a_failed_probe_reads_as_not_measured_rather_than_as_a_quiet_machine(self):
        # Intent: when the host probe fails, the screen report says so.
        # Why it exists: a dropped reading that renders as absent is
        #   indistinguishable from an idle machine to the next reader, which is
        #   the exact failure the annotation exists to prevent.
        report = _run_stubbed_screen(
            lambda: {"available": False, "reason": "host probe failed: boom"}, []
        )
        self.assertFalse(report["hostConditions"]["atInvocation"]["available"])
        self.assertIn("not measured", SCREEN.render_report(report))


class _Scratch:
    """A `.name`-shaped stand-in for TemporaryDirectory that never self-deletes."""

    def __init__(self, name):
        self.name = name


def _run_stubbed_screen(sample, order):
    """Drive `run_screen` with the arm snapshot and block collection stubbed out.

    Everything this file asserts is preflight bookkeeping, so the expensive parts
    -- materializing a git arm and running real blocks -- are replaced. The
    ordering probe writes into `order` so the two-reading sequence is checkable.
    """
    import tempfile

    original = (SCREEN.SNAPSHOT.resolve_baseline, SCREEN.SNAPSHOT.materialize_arm,
                SCREEN.COMPARE.production_collectors, SCREEN.collect_quartets,
                SCREEN.paired_differences, SCREEN.propose_rule)
    # Not a context manager: one test reads the written artifact after the call
    # returns, so the directory has to outlive this helper.
    temporary = _Scratch(tempfile.mkdtemp())
    try:
        SCREEN.SNAPSHOT.resolve_baseline = lambda *a, **k: {"tree": "abc123"}

        def materialize(*a, **k):
            order.append(("materialize", "arm"))
            return {"root": pathlib.Path(temporary.name)}

        def collect(*a, **k):
            order.append(("collect", "blocks"))
            return [[], []], 0

        SCREEN.SNAPSHOT.materialize_arm = materialize
        SCREEN.COMPARE.production_collectors = (
            lambda *a, **k: ({"retained-browse": None}, lambda: None)
        )
        SCREEN.collect_quartets = collect
        SCREEN.paired_differences = lambda workload, blocks: [0.1, -0.1]
        SCREEN.propose_rule = lambda *a, **k: None
        with redirect_stdout(io.StringIO()):
            return SCREEN.run_screen(
                workload="retained-browse", revision="HEAD", quartets=2,
                trials=10, seed=1, repository_root=ROOT,
                cache_root=pathlib.Path(temporary.name),
                artifacts_root=pathlib.Path(temporary.name) / "artifacts",
                sample_host_conditions=sample, emit=lambda *a, **k: None,
            )
    finally:
        (SCREEN.SNAPSHOT.resolve_baseline, SCREEN.SNAPSHOT.materialize_arm,
         SCREEN.COMPARE.production_collectors, SCREEN.collect_quartets,
         SCREEN.paired_differences, SCREEN.propose_rule) = original


if __name__ == "__main__":
    unittest.main()
