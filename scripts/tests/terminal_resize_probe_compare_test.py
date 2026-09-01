#!/usr/bin/env python3
"""Behavioral tests for the paired resize-probe comparison owner.

Every test here is about a refusal or a verdict, never about how the script is
factored: the point of the comparison owner is that a landing decision cannot be
taken by eye, so what has to hold is that it decides when the evidence supports a
decision and refuses when it does not.
"""
import importlib.util
import json
import pathlib
import stat
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_resize_probe_compare",
    ROOT / "scripts" / "terminal-resize-probe-compare.py",
)
COMPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARE)


def direction(median, is_narrowing):
    return {
        "toColumns": 100 if is_narrowing else 179,
        "isNarrowing": is_narrowing,
        "distribution": {
            "sampleCount": 100,
            "medianNanoseconds": median,
            "p95Nanoseconds": int(median * 1.05),
        },
    }


def report(narrowing, widening=None, rows=1000, cells=170000):
    """One probe report, reduced to the fields the comparison reads.

    The widening resize is the cheaper one by default, in the ratio the `wide` recipe
    really shows, so a test that moves one direction is moving a real quantity.
    """
    widening = widening if widening is not None else int(narrowing * 0.56)
    return {
        "recipeIdentity": "saturated-wide-resize-v1-60000-lines-179x66-to-100",
        "retainedRowCountAtStart": rows,
        "retainedCellCountAtStart": cells,
        "directions": [direction(narrowing, True), direction(widening, False)],
    }


def series(pair_count=8, baseline=2_000_000, candidate=2_000_000, control=None,
           baseline_digest="aaa", candidate_digest="aaa", rows=1000, cells=170000,
           candidate_cells=None, samples=None, recipe="wide"):
    """A synthetic series, so a decision can be tested without running a probe."""
    control = control if control is not None else baseline
    pairs = []
    for index in range(pair_count):
        # A deterministic sawtooth stands in for machine noise: it spreads the paired
        # differences without making any test depend on a random draw.
        wobble = 1.0 + 0.004 * ((index % 4) - 1.5)
        pairs.append({
            "index": index,
            "order": "baseline-first" if index % 2 == 0 else "candidate-first",
            "baseline": report(int(baseline * wobble), rows=rows, cells=cells),
            "candidate": report(
                int(candidate / wobble), rows=rows,
                cells=candidate_cells if candidate_cells is not None else cells
            ),
            "controlBaseline": report(int(baseline * wobble), rows=rows, cells=cells),
            "controlRepeat": report(int(control / wobble), rows=rows, cells=cells),
        })
    payload = {
        "kind": COMPARE.SERIES_KIND,
        "label": "test",
        "recipe": recipe,
        "samplesPerRun": samples if samples is not None else COMPARE.SAMPLES_PER_RUN,
        "pairCount": pair_count,
        "baselineDigest": baseline_digest,
        "candidateDigest": candidate_digest,
        "baselineBinary": "baseline",
        "candidateBinary": "candidate",
        "machine": "test",
        "measuredAt": "2026-08-31T00:00:00+00:00",
        "pairs": pairs,
    }
    payload["seriesId"] = COMPARE.series_id(payload)
    return payload


def confirmed_rule(pair_count=8, threshold=2.0):
    return {
        "kind": COMPARE.RULE_KIND,
        "stage": "confirmed",
        "recipe": "wide",
        "samplesPerRun": COMPARE.SAMPLES_PER_RUN,
        "pairCount": pair_count,
        "thresholdPercent": {name: threshold for name in COMPARE.ESTIMATORS},
        "confirmationFalsePositiveLimit": COMPARE.CONFIRMATION_FALSE_POSITIVE_LIMIT,
    }


class ResizeProbeCompareTests(unittest.TestCase):
    def test_selection_needs_two_arms_of_one_binary(self):
        # A rule is calibrated from noise, so a series whose arms are different builds
        # carries an effect and cannot say what noise alone does.
        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.select_rule([series(candidate_digest="bbb")], ["aa"])
        self.assertIn("A/A", str(raised.exception))

    def test_selection_freezes_a_cell_from_the_declared_grids(self):
        selected = COMPARE.select_rule([series(pair_count=32)], ["aa"])

        self.assertEqual(selected["stage"], "selected")
        self.assertIn(selected["pairCount"], COMPARE.PAIR_COUNT_GRID)
        for name, threshold in selected["thresholdPercent"].items():
            self.assertIn(threshold, COMPARE.THRESHOLD_GRID_PERCENT, name)
        for name, rate in selected["selectionFalsePositiveRate"].items():
            self.assertLessEqual(rate, COMPARE.SELECTION_FALSE_POSITIVE_LIMIT, name)

    def test_confirmation_refuses_the_series_that_selected_the_rule(self):
        # The rule's own selection sample cannot validate it: a bound set at the extreme
        # of n replications is exceeded by a fresh run about one time in n+1.
        aa = series(pair_count=32)
        selected = COMPARE.select_rule([aa], ["aa"])

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.confirm_rule(selected, aa, "aa")
        self.assertIn("disjoint", str(raised.exception))

    def test_confirmation_passes_on_a_disjoint_series_of_the_same_noise(self):
        selected = COMPARE.select_rule([series(pair_count=32)], ["aa"])
        disjoint = series(pair_count=32, baseline=2_000_001)

        confirmed = COMPARE.confirm_rule(selected, disjoint, "aa2")

        self.assertEqual(confirmed["stage"], "confirmed")
        self.assertEqual(confirmed["pairCount"], selected["pairCount"])
        self.assertEqual(confirmed["thresholdPercent"], selected["thresholdPercent"])
        self.assertEqual(confirmed["confirmationSeriesId"], disjoint["seriesId"])

    def test_confirmation_refuses_a_rule_the_disjoint_series_cannot_hold(self):
        # The confirming series is far noisier than the selecting one, so the frozen
        # threshold fires on noise more often than the predeclared limit allows.
        selected = COMPARE.select_rule([series(pair_count=32)], ["aa"])
        noisy = series(pair_count=32)
        for index, pair in enumerate(noisy["pairs"]):
            swing = 1.0 + 0.25 * (1 if index % 2 else -1)
            pair["candidate"] = report(int(2_000_000 * swing))
        noisy["seriesId"] = COMPARE.series_id(noisy)

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.confirm_rule(selected, noisy, "aa2")
        self.assertIn("false-positive", str(raised.exception))

    def test_a_decision_needs_a_confirmed_rule(self):
        selected = COMPARE.select_rule([series(pair_count=32)], ["aa"])

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.decide(selected, series(candidate_digest="bbb"), "ab")
        self.assertIn("confirmed", str(raised.exception))

    def test_a_decision_refuses_a_series_whose_arms_are_one_binary(self):
        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.decide(confirmed_rule(), series(), "ab")
        self.assertIn("same binary", str(raised.exception))

    def test_a_decision_refuses_a_series_of_a_different_size_than_the_rule(self):
        # The schedule's size is fixed before the measurement exists, so a series that
        # ran more pairs than the rule decides is not the rule's evidence.
        moved = series(pair_count=16, candidate=1_000_000, candidate_digest="bbb")

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.decide(confirmed_rule(pair_count=8), moved, "ab")
        self.assertIn("8 pairs", str(raised.exception))

    def test_a_decision_refuses_a_series_measured_under_other_conditions(self):
        # The rule was calibrated on one recipe at one sample count. A series measured
        # under different conditions is a different measurement, and its noise is not
        # the noise the thresholds were frozen against.
        for changed, expected in (
            ({"recipe": "sparse"}, "recipe"),
            ({"samples": 20}, "sample count"),
        ):
            moved = series(candidate=1_600_000, candidate_digest="bbb", **changed)
            with self.assertRaises(COMPARE.ComparisonError) as raised:
                COMPARE.decide(confirmed_rule(), moved, "ab")
            self.assertIn(expected, str(raised.exception))

    def test_a_decision_refuses_arms_that_reflowed_different_cells(self):
        # The row counts match here and only the cells differ, which is the case a
        # row-only check would pass: a candidate that drops cells reads as a speedup.
        cheating = series(
            candidate=1_000_000, candidate_digest="bbb", candidate_cells=120_000
        )

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.decide(confirmed_rule(), cheating, "ab")
        self.assertIn("retainedCellCountAtStart", str(raised.exception))

    def test_a_decision_refuses_a_missing_count_rather_than_reading_it_as_zero(self):
        blind = series(candidate=1_000_000, candidate_digest="bbb")
        for pair in blind["pairs"]:
            del pair["candidate"]["retainedCellCountAtStart"]

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.decide(confirmed_rule(), blind, "ab")
        self.assertIn("missing required field", str(raised.exception))

    def test_a_decision_calls_a_real_improvement(self):
        faster = series(candidate=1_600_000, candidate_digest="bbb")

        result = COMPARE.decide(confirmed_rule(), faster, "ab")

        self.assertEqual(result["verdict"], "improved")
        self.assertTrue(all(result["improvedBy"].values()))
        self.assertFalse(any(result["regressedBy"].values()))
        self.assertLess(result["estimatePercent"]["narrowing-median"], -2.0)
        self.assertLess(result["estimatePercent"]["narrowing-p95"], -2.0)

    def test_a_decision_refuses_an_improvement_that_only_moved_the_median(self):
        # Both statistics of the reflowing direction gate the landing, so a change that
        # leaves the tail where it was is not an improvement this rule accepts.
        mixed = series(candidate=1_600_000, candidate_digest="bbb")
        for pair in mixed["pairs"]:
            for direction_report in pair["candidate"]["directions"]:
                if direction_report["isNarrowing"]:
                    direction_report["distribution"]["p95Nanoseconds"] = 2_100_000

        result = COMPARE.decide(confirmed_rule(), mixed, "ab")

        self.assertEqual(result["verdict"], "not-improved")
        self.assertTrue(result["improvedBy"]["narrowing-median"])
        self.assertFalse(result["improvedBy"]["narrowing-p95"])

    def test_a_widening_regression_blocks_a_narrowing_improvement(self):
        # The direction with little work to remove is held to "not worse". A candidate
        # that pays for a cheaper narrowing with a costlier widening has moved the cost,
        # not removed it, and the user's drag pays both.
        traded = series(candidate=1_600_000, candidate_digest="bbb")
        for pair in traded["pairs"]:
            for direction_report in pair["candidate"]["directions"]:
                if not direction_report["isNarrowing"]:
                    for name, value in list(direction_report["distribution"].items()):
                        if name.endswith("Nanoseconds"):
                            direction_report["distribution"][name] = int(value * 1.5)

        result = COMPARE.decide(confirmed_rule(), traded, "ab")

        self.assertEqual(result["verdict"], "not-improved")
        self.assertTrue(all(result["improvedBy"].values()))
        self.assertTrue(all(result["regressedBy"].values()))

    def test_a_decision_refuses_a_report_that_timed_one_direction(self):
        # A report with one direction cannot answer either half of the rule, and reading
        # its single group as though it were both would compare a narrowing against a
        # widening.
        half = series(candidate=1_600_000, candidate_digest="bbb")
        for pair in half["pairs"]:
            pair["candidate"]["directions"] = pair["candidate"]["directions"][:1]

        with self.assertRaises(COMPARE.ComparisonError) as raised:
            COMPARE.decide(confirmed_rule(), half, "ab")
        self.assertIn("both resize directions", str(raised.exception))

    def test_a_moved_control_voids_the_decision(self):
        # The control is the baseline binary against itself, so nothing in the candidate
        # can move it. When it moves anyway the session moved, and the effect beside it
        # is not attributable.
        drifting = series(
            candidate=1_600_000, control=1_600_000, candidate_digest="bbb"
        )

        result = COMPARE.decide(confirmed_rule(), drifting, "ab")

        self.assertEqual(result["verdict"], "void")
        self.assertIn("control", result["reason"])

    def test_a_series_interleaves_the_arms_and_alternates_which_goes_first(self):
        # Position balance is what keeps a drifting machine from charging its drift to
        # one arm, and it has to be visible in the artifact rather than assumed.
        calls = []

        def fake_probe(binary, recipe, samples):
            calls.append(pathlib.Path(binary).name)
            return report(2_000_000)

        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory) / "baseline"
            cand = pathlib.Path(directory) / "candidate"
            base.write_text("baseline build")
            cand.write_text("candidate build")
            measured = COMPARE.measure_series(
                base, cand, pair_count=2, label="test", probe=fake_probe
            )

        self.assertEqual(
            [pair["order"] for pair in measured["pairs"]],
            ["baseline-first", "candidate-first"],
        )
        self.assertEqual(
            calls,
            [
                "baseline", "candidate", "baseline", "baseline",
                "candidate", "baseline", "baseline", "baseline",
            ],
        )
        self.assertNotEqual(measured["baselineDigest"], measured["candidateDigest"])

    def test_the_command_line_measures_selects_confirms_and_decides(self):
        # The end-to-end path, through real probe processes: a fake probe binary stands
        # in for `TerminalResizeProbe` so the test never builds Swift, but everything
        # between the process boundary and the verdict is the shipped code.
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            baseline = self.write_fake_probe(work / "baseline", 2_000_000)
            twin = self.write_fake_probe(work / "twin", 2_000_000, comment="twin")
            faster = self.write_fake_probe(work / "faster", 1_500_000)

            for label, out in (("aa-select", "aa1.json"), ("aa-confirm", "aa2.json")):
                self.assertEqual(0, COMPARE.main([
                    "measure", "--baseline", str(baseline), "--candidate", str(baseline),
                    "--pairs", "12", "--label", label, "--out", str(work / out),
                ]))
            self.assertEqual(0, COMPARE.main([
                "select", "--series", str(work / "aa1.json"),
                "--out", str(work / "rule.json"),
            ]))
            rule = json.loads((work / "rule.json").read_text())
            self.assertEqual(0, COMPARE.main([
                "confirm", "--rule", str(work / "rule.json"),
                "--series", str(work / "aa2.json"),
                "--out", str(work / "confirmed.json"),
            ]))
            self.assertEqual(0, COMPARE.main([
                "measure", "--baseline", str(baseline), "--candidate", str(faster),
                "--pairs", str(rule["pairCount"]), "--label", "decision",
                "--out", str(work / "ab.json"),
            ]))
            self.assertEqual(0, COMPARE.main([
                "decide", "--rule", str(work / "confirmed.json"),
                "--series", str(work / "ab.json"), "--out", str(work / "verdict.json"),
            ]))
            verdict = json.loads((work / "verdict.json").read_text())
            self.assertEqual(verdict["verdict"], "improved")

            # A candidate that is only a rebuild of the baseline is not an improvement,
            # and the exit status says so without anyone reading the numbers.
            self.assertEqual(0, COMPARE.main([
                "measure", "--baseline", str(baseline), "--candidate", str(twin),
                "--pairs", str(rule["pairCount"]), "--label", "null",
                "--out", str(work / "null.json"),
            ]))
            self.assertEqual(1, COMPARE.main([
                "decide", "--rule", str(work / "confirmed.json"),
                "--series", str(work / "null.json"),
            ]))

    def test_a_series_survives_the_compressed_shape_it_is_kept_in(self):
        # A committed series keeps every raw sample, so it is stored compressed. What has
        # to hold is that the stored shape decides the same way the plain one does.
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "aa.json.gz"
            COMPARE.write_json(path, series(pair_count=8))

            self.assertEqual(COMPARE.read_json(path, "aa"), series(pair_count=8))

    def write_fake_probe(self, path, center, comment=""):
        """A stand-in probe binary: same report shape, timings drawn around `center`."""
        path.write_text(
            "#!/usr/bin/env python3\n"
            f"# {comment}\n"
            "import json, random\n"
            f"center = {center}\n"
            # Seeded, so two runs of one arm agree to the nanosecond. Machine noise is
            # what the synthetic-series tests above vary; this one is about the wiring,
            # and a run-to-run draw here would make its verdicts a coin toss.
            "generator = random.Random(11)\n"
            "def group(scale, narrowing):\n"
            "    samples = [max(1, int(generator.gauss(center * scale,"
            " center * 0.01))) for _ in range(100)]\n"
            "    ordered = sorted(samples)\n"
            "    return {'toColumns': 100 if narrowing else 179,\n"
            "        'isNarrowing': narrowing,\n"
            "        'distribution': {'sampleCount': len(samples),\n"
            "            'medianNanoseconds': ordered[49],\n"
            "            'p95Nanoseconds': ordered[94],\n"
            "            'samplesNanoseconds': samples}}\n"
            "print(json.dumps({\n"
            "    'recipeIdentity': 'fake', 'retainedRowCountAtStart': 1000,\n"
            "    'retainedCellCountAtStart': 170000,\n"
            "    'directions': [group(1.0, True), group(0.56, False)]}))\n"
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path


if __name__ == "__main__":
    unittest.main()
