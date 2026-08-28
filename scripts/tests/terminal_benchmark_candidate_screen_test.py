#!/usr/bin/env python3
"""Two questions about a candidate screen: what it records, and what confirms it.

The first is whether the screen carries the host conditions it was taken under.

A screen is a measurement whose whole output is a proposed decision rule, so the
conditions it was taken under decide whether a replicate may be compared against
it. research/28/F5's screen 1 had to state those conditions in prose because the script
recorded none. This file pins the wiring that fixed it: the comparison driver's
preflight is sampled twice -- once at invocation, once immediately before the
first block -- persisted in the screen report, and rendered for the operator.

It does not test `sample_host_conditions` itself; that lives with the driver in
terminal_benchmark_compare_test.py.

The second is whether the confirmation step re-runs the cell the screen selected
rather than a new search. A screen is not a freeze: the corpus protocol screens a
grid at 50,000 trials and then re-runs *that exact cell* at 100,000 with disjoint
fresh seeds, and `research/20/F15` is the case where skipping that left a cell
that looked verified and was only selected.
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
        # Why it exists: research/28/F3 measured that load during a run is confounded by the
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
        # Why it exists: research/28/D1 pitch 4 admitted the preflight scoped to
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


def _screened_report(**overrides):
    """A screen report shaped exactly as `run_screen` persists one."""
    cell = {
        "pairCount": 4,
        "effectPercent": 3,
        "directionalThresholdPercent": 1.25,
        "equivalenceBandPercent": 0.75,
        "trialCountPerCondition": 50_000,
        "seed": 20260730,
        "conditions": _conditions(),
    }
    report = {
        "schemaVersion": 1,
        "workload": "kitten-feed-unicode",
        "metric": "feedDurationNanoseconds",
        "tree": "abc123",
        "trials": 50_000,
        "seed": 20260730,
        "quartetsKept": 2,
        "series": {"pairCount": 4, "quartetsPercent": [[0.1, -0.1], [0.2, -0.2]]},
        "modes": {
            "quick": {"pairCount": 2, "selected": dict(cell, pairCount=2,
                                                       effectPercent=5,
                                                       equivalenceBandPercent=1.0,
                                                       directionalThresholdPercent=2.6)},
            "confirm": {"pairCount": 4, "selected": cell},
        },
    }
    report.update(overrides)
    return report


def _conditions(false_positive_rate=0.0, detection_rate=1.0,
                inconclusive_rate=0.0, wrong_direction_rate=0.0):
    return {
        "aa": {"falsePositiveRate": false_positive_rate},
        "positive": {"detectionRate": detection_rate,
                     "inconclusiveRate": inconclusive_rate,
                     "wrongDirectionRate": wrong_direction_rate},
        "negative": {"detectionRate": detection_rate,
                     "inconclusiveRate": inconclusive_rate,
                     "wrongDirectionRate": wrong_direction_rate},
    }


class CandidateSeriesShapeTests(unittest.TestCase):
    def test_the_screen_persists_the_series_as_the_unit_it_resamples(self):
        # Intent: the persisted series keeps its quartet grouping.
        # Why it exists: the resampling unit is a whole schedule quartet
        #   (`resample_quartets` refuses anything else), so a report that stores
        #   one flat list of pairs cannot be re-analyzed at all -- which is the
        #   one thing the field was added to allow. A confirmation would have to
        #   spend the machine time again.
        report = _run_stubbed_screen(lambda: dict(READING), [])
        self.assertEqual(report["series"]["quartetsPercent"], [[0.1, -0.1], [0.1, -0.1]])
        self.assertNotIn("pairsPercent", report["series"])


class CandidateConfirmationTests(unittest.TestCase):
    def test_confirmation_reruns_the_selected_cell_at_fresh_seeds_and_more_trials(self):
        # Intent: every parameter of the confirming run comes from the screen's
        #   selected cell, except the trial count and the seed.
        # Why it exists: "no parameter changed after screening" is the whole
        #   content of the confirmation. A confirm step that re-searched the grid
        #   would select a fresh winner and prove nothing about the first one.
        calls = []
        report = _confirm_stubbed(calls, _screened_report())
        self.assertEqual(
            [(call["pair_count"], call["directional_threshold"],
              call["effect_percent"], call["equivalence_band"]) for call in calls],
            [(2, 2.6, 5, 1.0), (4, 1.25, 3, 0.75)],
        )
        self.assertEqual({call["trial_count"] for call in calls}, {100_000})
        self.assertEqual([call["seed"] for call in calls], [20260828, 20260829])
        self.assertEqual(report["confirmedModeCount"], 2)
        self.assertTrue(report["accepted"])

    def test_confirmation_refuses_a_seed_the_screen_already_spent(self):
        # Intent: a seed base that reproduces the screen's own draws is rejected.
        # Why it exists: re-running the same pseudo-random stream is not a second
        #   look at the cell, and it passes by construction.
        with self.assertRaises(ValueError) as raised:
            _confirm_stubbed([], _screened_report(), seed_base=20260730)
        self.assertIn("disjoint", str(raised.exception))

    def test_confirmation_fails_the_cell_that_stops_clearing_the_gates(self):
        # Intent: the confirming run is judged by the same gates that selected
        #   the cell, and a cell that misses one is reported not accepted.
        # Why it exists: a confirmation that cannot fail is a formality. The
        #   audit names the gate so the operator sees which one moved.
        calls = []
        report = _confirm_stubbed(
            calls, _screened_report(),
            conditions=_conditions(detection_rate=0.5),
        )
        self.assertFalse(report["accepted"])
        self.assertFalse(report["modes"]["confirm"]["audit"]["checks"]["detectionRate"])
        self.assertTrue(report["modes"]["confirm"]["audit"]["checks"]["falsePositiveRate"])

    def test_a_mode_the_screen_proposed_nothing_for_is_not_confirmed(self):
        # Intent: a mode whose screen found no clearing cell is carried through
        #   as unconfirmed, and does not make the report look accepted.
        # Why it exists: `all([])` is True. A report that confirmed nothing and
        #   said "accepted" is the shape a freeze would be read off.
        screened = _screened_report()
        screened["modes"] = {"quick": None, "confirm": None}
        report = _confirm_stubbed([], screened)
        self.assertEqual(report["confirmedModeCount"], 0)
        self.assertFalse(report["accepted"])
        self.assertIsNone(report["modes"]["quick"])

    def test_confirmation_refuses_a_screen_whose_mode_rule_has_since_moved(self):
        # Intent: if the frozen mode rule no longer matches the cell's recorded
        #   effect or equivalence band, the confirmation stops.
        # Why it exists: the confirming run reads the effect and band from the
        #   live rule, so a rule edited between screen and confirm would silently
        #   change a parameter after screening -- exactly what the protocol forbids.
        screened = _screened_report()
        screened["modes"]["confirm"]["selected"]["equivalenceBandPercent"] = 0.5
        with self.assertRaises(ValueError) as raised:
            _confirm_stubbed([], screened)
        self.assertIn("equivalenceBandPercent", str(raised.exception))

    def test_confirmation_refuses_a_screen_that_kept_no_resampling_units(self):
        # Intent: a screen report without `quartetsPercent` is refused by name.
        # Why it exists: a missing field is not an empty series, and resampling
        #   an empty list raises somewhere far from the cause.
        screened = _screened_report()
        del screened["series"]["quartetsPercent"]
        with self.assertRaises(ValueError) as raised:
            _confirm_stubbed([], screened)
        self.assertIn("quartetsPercent", str(raised.exception))


def _confirm_stubbed(calls, screened, *, conditions=None, seed_base=20260828):
    """Drive `confirm_screen` with the resampling itself stubbed out.

    The Monte Carlo is `calibrate_mode`'s and is tested there; what this file
    pins is which cell gets handed to it, with which seed and trial count.
    """
    original = SCREEN.CALIBRATION.calibrate_mode

    def calibrate_mode(quartets, **keywords):
        calls.append(keywords)
        return {
            "pairCount": keywords["pair_count"],
            "directionalThresholdPercent": keywords["directional_threshold"],
            "conditions": conditions or _conditions(),
        }

    SCREEN.CALIBRATION.calibrate_mode = calibrate_mode
    try:
        return SCREEN.confirm_screen(screened, trials=100_000, seed_base=seed_base)
    finally:
        SCREEN.CALIBRATION.calibrate_mode = original


if __name__ == "__main__":
    unittest.main()
