#!/usr/bin/env python3
"""Behavioral tests for the paired quick/confirm comparison runner and its frozen rule."""
import importlib.util
import inspect
import io
import json
import pathlib
import statistics
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


def _load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMPARE = _load("terminal_benchmark_compare", "scripts/terminal-benchmark-compare.py")
VALIDATION = _load(
    "terminal_benchmark_validation", "scripts/terminal-benchmark-validation.py"
)


def block_value(workload, value):
    """Spell one collected block's normalized metric the way its collector reports it."""
    return {COMPARE.BLOCK_METRICS[workload]: value}


def raw_blocks(workload, schedule, values):
    """Attach measured values to a planned schedule in block order."""
    return [
        {"index": index, **planned, **block_value(workload, value)}
        for index, (planned, value) in enumerate(zip(schedule, values))
    ]


def workload_evidence(workload, schedule, values, reasons=()):
    return {
        "workload": workload,
        "rawBlocks": raw_blocks(workload, schedule, values),
        "valid": not reasons,
        "invalidationReasons": list(reasons),
    }


def collection(evidence_by_workload):
    """Shape workload evidence the way the research collector's collect_attempt does."""
    reasons = [
        f"{workload}:{reason}"
        for workload, evidence in evidence_by_workload.items()
        for reason in evidence["invalidationReasons"]
    ]
    return {
        "workloads": dict(evidence_by_workload),
        "valid": not reasons,
        "invalidationReasons": reasons,
    }


def constant_pair_values(workload, schedule, difference_percent):
    """Produce block values whose every adjacent pair has an exact symmetric difference."""
    baseline = 1_000_000.0
    ratio = (200.0 + difference_percent) / (200.0 - difference_percent)
    return [
        baseline * ratio if planned["measurementRole"] == "B" else baseline
        for planned in schedule
    ]


class WorkloadSelectionTests(unittest.TestCase):
    def test_quick_selects_exactly_one_named_workload(self):
        # Intent: `quick` measures one workload and refuses to guess which.
        # Why it exists: the 60-second quick budget only holds for a single
        #   workload, and silently defaulting to one would attach the operator's
        #   directional claim to a path they did not choose.
        # Scenario: an operator runs benchmark-quick with, and without, workload=.
        for workload in VALIDATION.WORKLOADS:
            self.assertEqual(
                COMPARE.resolve_workloads("quick", workload), (workload,)
            )
        with self.assertRaises(ValueError):
            COMPARE.resolve_workloads("quick", None)
        with self.assertRaises(ValueError):
            COMPARE.resolve_workloads("quick", "no-such-workload")

    def test_confirm_runs_the_complete_five_workload_ladder(self):
        self.assertEqual(
            COMPARE.resolve_workloads("confirm", None), VALIDATION.WORKLOADS
        )
        with self.assertRaises(ValueError):
            COMPARE.resolve_workloads("confirm", "terminal-feed")

    def test_unknown_modes_are_rejected(self):
        with self.assertRaises(ValueError):
            COMPARE.resolve_workloads("exhaustive", "terminal-feed")


class ScheduleTests(unittest.TestCase):
    def test_every_schedule_uses_the_frozen_fixed_pair_count(self):
        # Intent: block counts come from the frozen decision table, not from the runner.
        # Why it exists: completed comparisons forbid early stopping and optional
        #   peeking; the only protection against both is fixing the schedule size
        #   before any measurement exists.
        # Scenario: quick and confirm schedules are built for every workload.
        for mode, rule in VALIDATION.DECISION_RULES.items():
            for workload, workload_rule in rule["workloads"].items():
                schedule = COMPARE.make_schedule(
                    mode, (workload,), physical_candidate_arm="b"
                )[workload]
                self.assertEqual(
                    len(schedule), workload_rule["pairCount"] * 2,
                    f"{mode}/{workload}",
                )

    def test_every_quartet_is_position_balanced(self):
        # Intent: each group of four blocks is ABBA or BAAB, so source assignment
        #   is balanced against block order.
        # Why it exists: source assignment must not be confounded with block order;
        #   an unbalanced run would let warm-up or drift masquerade as a difference.
        # Scenario: the largest frozen schedule (confirm incremental-mixed, six
        #   pairs) is inspected quartet by quartet.
        schedule = COMPARE.make_schedule(
            "confirm", ("incremental-mixed",), physical_candidate_arm="b"
        )["incremental-mixed"]
        self.assertEqual(len(schedule) % 4, 0)
        for offset in range(0, len(schedule), 4):
            quartet = [
                planned["measurementRole"]
                for planned in schedule[offset:offset + 4]
            ]
            self.assertIn("".join(quartet), {"ABBA", "BAAB"})
            self.assertEqual(sorted(quartet), ["A", "A", "B", "B"])

    def test_adjacent_blocks_form_complete_baseline_candidate_pairs(self):
        for mode in VALIDATION.DECISION_RULES:
            for workload in VALIDATION.WORKLOADS:
                schedule = COMPARE.make_schedule(
                    mode, (workload,), physical_candidate_arm="a"
                )[workload]
                for offset in range(0, len(schedule), 2):
                    roles = {
                        planned["measurementRole"]
                        for planned in schedule[offset:offset + 2]
                    }
                    self.assertEqual(roles, {"A", "B"}, f"{mode}/{workload}")

    def test_the_candidate_role_always_occupies_the_chosen_physical_arm(self):
        # Intent: the measured candidate source is the one bound to the physical
        #   arm the invocation selected, for every block.
        # Why it exists: a single mis-mapped block would silently swap the two
        #   sources inside one pair and invert that pair's sign.
        # Scenario: schedules are built for both physical assignments.
        for candidate_arm, baseline_arm in (("a", "b"), ("b", "a")):
            schedule = COMPARE.make_schedule(
                "confirm",
                ("scrollback-stream",),
                physical_candidate_arm=candidate_arm,
            )["scrollback-stream"]
            for planned in schedule:
                expected = (
                    candidate_arm
                    if planned["measurementRole"] == "B"
                    else baseline_arm
                )
                self.assertEqual(planned["physicalArm"], expected)

    def test_the_summary_keeps_each_workload_s_warmup_blocks(self):
        # Intent: the discarded warm-up blocks reach the run record beside the
        #   measured ones, and pair into nothing.
        # Why it exists: a warm-up that is run but not recorded leaves the cold
        #   cost it absorbed invisible, and a reader could not tell a warmed run
        #   from an unwarmed one from the artifact alone.
        # Scenario: one workload's evidence carries two warm-up blocks.
        workload = "style-churn"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = raw_blocks(
            workload, schedule, constant_pair_values(workload, schedule, 0.0)
        )
        warmups = [
            {"physicalArm": "a", "drawCount": 50, "drawNanosecondsPerDraw": 3_300_000},
            {"physicalArm": "b", "drawCount": 50, "drawNanosecondsPerDraw": 3_250_000},
        ]
        evidence = collection({
            workload: {
                "workload": workload,
                "rawBlocks": blocks,
                "warmupBlocks": warmups,
                "valid": True,
                "invalidationReasons": [],
            }
        })

        summary = COMPARE.summarize_comparison("quick", evidence)

        self.assertEqual(summary["workloads"][workload]["warmupBlocks"], warmups)
        self.assertEqual(
            len(summary["workloads"][workload]["pairedSymmetricPercent"]),
            len(schedule) // 2,
        )

    def test_the_quartet_phase_is_derived_from_the_candidate_tree(self):
        # Intent: which pattern a run's first quartet uses, ABBA or BAAB, is a
        #   reproducible function of the candidate tree, independent of the
        #   bit that picks the physical arm.
        # Why it exists: quick mode is one quartet. Alternating patterns only
        #   across quartets left every quick run ABBA, so the baseline always
        #   owned the first block and a first-position cost never reversed
        #   (research/38/F2). Phasing by tree makes the alternation hold across
        #   invocations while keeping the schedule inspectable from the record.
        # Scenario: four trees covering both values of the two low bits.
        for suffix, arm, phase in (("0", "b", 0), ("1", "a", 0), ("2", "b", 1), ("3", "a", 1)):
            tree = "c" * 39 + suffix
            self.assertEqual(COMPARE.physical_candidate_arm(tree), arm)
            self.assertEqual(COMPARE.quartet_phase(tree), phase)
        for phase, first in ((0, "ABBA"), (1, "BAAB")):
            schedule = COMPARE.make_schedule(
                "confirm", ("content-churn",), physical_candidate_arm="b",
                quartet_phase=phase,
            )["content-churn"]
            quartets = [
                "".join(planned["measurementRole"] for planned in schedule[offset:offset + 4])
                for offset in range(0, len(schedule), 4)
            ]
            self.assertEqual(quartets[0], first)
            self.assertEqual(len(set(quartets)), 2)

    def test_confirm_schedules_every_workload_in_one_invocation(self):
        schedule = COMPARE.make_schedule(
            "confirm", VALIDATION.WORKLOADS, physical_candidate_arm="b"
        )
        self.assertEqual(tuple(schedule), VALIDATION.WORKLOADS)

    def test_the_physical_candidate_arm_is_derived_from_the_candidate_tree(self):
        # Intent: which physical slot holds the candidate is a reproducible
        #   function of the candidate's tree identity, not a constant.
        # Why it exists: source assignment must not be confounded with physical
        #   position. Both arms are launched once per invocation, so the slot
        #   cannot alternate within a run; deriving it from the tree keeps the
        #   assignment reproducible, reportable, and varying across candidates.
        # Scenario: two candidate trees with opposite leading-digit parity.
        self.assertEqual(COMPARE.physical_candidate_arm("a" * 39 + "1"), "a")
        self.assertEqual(COMPARE.physical_candidate_arm("a" * 39 + "0"), "b")
        self.assertEqual(
            COMPARE.physical_candidate_arm("deadbeef" + "0" * 32),
            COMPARE.physical_candidate_arm("deadbeef" + "0" * 32),
        )


class PairedDifferenceTests(unittest.TestCase):
    def test_a_slower_candidate_produces_a_positive_symmetric_difference(self):
        # Intent: pair orientation is source-oriented -- positive means the
        #   candidate is slower than the baseline.
        # Why it exists: the frozen rule's sign carries the entire directional
        #   claim; an inverted pair would report every regression as a speedup.
        # Scenario: a candidate block measures 10% slower than its baseline block.
        schedule = COMPARE.make_schedule(
            "quick", ("content-churn",), physical_candidate_arm="b"
        )["content-churn"]
        values = [
            1_100_000.0 if planned["measurementRole"] == "B" else 1_000_000.0
            for planned in schedule
        ]
        differences = COMPARE.paired_differences(
            "content-churn", raw_blocks("content-churn", schedule, values)
        )
        self.assertEqual(len(differences), 2)
        for difference in differences:
            self.assertAlmostEqual(difference, 200.0 * 100_000 / 2_100_000)

    def test_a_faster_candidate_produces_a_negative_symmetric_difference(self):
        schedule = COMPARE.make_schedule(
            "quick", ("terminal-feed",), physical_candidate_arm="a"
        )["terminal-feed"]
        values = [
            900_000.0 if planned["measurementRole"] == "B" else 1_000_000.0
            for planned in schedule
        ]
        differences = COMPARE.paired_differences(
            "terminal-feed", raw_blocks("terminal-feed", schedule, values)
        )
        for difference in differences:
            self.assertLess(difference, 0)

    def test_pairing_reads_each_workloads_own_normalized_metric(self):
        # Intent: every workload is paired on the metric its collector normalizes,
        #   never on a raw cumulative total.
        # Why it exists: each workload must preserve its named normalization;
        #   pairing a per-draw workload on a cumulative field would compare
        #   different quantities across arms.
        # Scenario: each workload's blocks carry only its own metric key.
        for workload in VALIDATION.WORKLOADS:
            schedule = COMPARE.make_schedule(
                "quick", (workload,), physical_candidate_arm="b"
            )[workload]
            blocks = raw_blocks(workload, schedule, [1_000_000.0] * len(schedule))
            self.assertEqual(
                COMPARE.paired_differences(workload, blocks),
                [0.0] * (len(schedule) // 2),
            )

    def test_a_sparse_span_candidate_pairs_on_its_own_metric_and_decides_nothing(self):
        # Intent: both sparse-span workloads reduce to paired differences on the
        #   metric routed to them, and neither can be classified in either mode.
        # Why it exists: pairing is what a screen consumes, so a candidate needs
        #   it before any rule exists -- while classification is exactly what must
        #   stay impossible until a screened threshold is frozen. Reading the
        #   wrong metric would be invisible: a block carries draw time and process
        #   CPU side by side, so the paired series would still look well-formed.
        # Scenario: spec-first; research/29/D3 begins each workload collectable and
        #   undecidable: each pairs on its own metric and refuses classification
        #   before a frozen rule exists.
        schedule = [
            {"measurementRole": role, "physicalArm": "a", "quartet": 0}
            for role in ("A", "B", "B", "A")
        ]
        for workload, decided, ignored in (
            ("sparse-spans-few",
             "drawNanosecondsPerDraw", "processCPUNanosecondsPerDraw"),
            ("sparse-spans-max",
             "processCPUNanosecondsPerDraw", "drawNanosecondsPerDraw"),
        ):
            with self.subTest(workload=workload):
                blocks = [
                    {
                        **planned,
                        decided: (
                            1_100_000.0
                            if planned["measurementRole"] == "B"
                            else 1_000_000.0
                        ),
                        ignored: 1_000_000.0,
                    }
                    for planned in schedule
                ]

                differences = COMPARE.paired_differences(workload, blocks)

                self.assertEqual(len(differences), 2)
                for difference in differences:
                    self.assertAlmostEqual(
                        difference, 200.0 * 100_000 / 2_100_000
                    )
                for mode in COMPARE.MODES:
                    with self.assertRaises(ValueError):
                        COMPARE.decide_workload(mode, workload, differences)

    def test_incomplete_or_unpaired_block_series_are_rejected(self):
        schedule = COMPARE.make_schedule(
            "quick", ("style-churn",), physical_candidate_arm="b"
        )["style-churn"]
        blocks = raw_blocks("style-churn", schedule, [1.0] * len(schedule))
        with self.assertRaises(ValueError):
            COMPARE.paired_differences("style-churn", blocks[:-1])
        unpaired = [dict(block) for block in blocks]
        unpaired[1]["measurementRole"] = unpaired[0]["measurementRole"]
        with self.assertRaises(ValueError):
            COMPARE.paired_differences("style-churn", unpaired)


class FrozenDecisionTests(unittest.TestCase):
    def test_the_frozen_table_matches_the_plans_decision_contract(self):
        # Intent: the runner decides with exactly the calibrated pair counts,
        #   thresholds, and equivalence bands the plan freezes.
        # Why it exists: these values are calibration output for the fixed 179x66
        #   geometry on one Mac; a drifted constant would silently invalidate every
        #   claim the command makes without any test failing elsewhere.
        # Scenario: the frozen table in the plan is restated here and compared.
        expected = {
            "quick": (1.0, {
                "terminal-feed": (2, 4.5),
                "scrollback-stream": (2, None),
                "content-churn": (2, 2.0),
                "style-churn": (2, 2.0),
                "incremental-mixed": (2, None),
            }),
            "confirm": (0.75, {
                "terminal-feed": (2, 2.5),
                "scrollback-stream": (4, None),
                "content-churn": (4, 1.5),
                "style-churn": (4, 1.75),
                "incremental-mixed": (6, None),
            }),
        }
        for mode, (equivalence, workloads) in expected.items():
            rule = COMPARE.decision_rule(mode)
            self.assertEqual(rule["equivalenceBandPercent"], equivalence)
            self.assertEqual(rule["estimator"], "median")
            for workload, (pairs, threshold) in workloads.items():
                self.assertEqual(
                    (
                        rule["workloads"][workload]["pairCount"],
                        rule["workloads"][workload].get("directionalThresholdPercent"),
                    ),
                    (pairs, threshold),
                    f"{mode}/{workload}",
                )

    def test_every_classification_is_reachable_for_every_mode_and_workload(self):
        # Intent: each frozen cell classifies slower, faster, equivalent, and
        #   inconclusive at the exact boundaries the plan states.
        # Why it exists: the frozen decision rule must be proven at its boundaries
        #   rather than only in its interior, because a `>` written
        #   where the plan says "at or beyond" changes real verdicts.
        # Scenario: deterministic pair series placed exactly on each boundary.
        for mode in ("quick", "confirm"):
            rule = COMPARE.decision_rule(mode)
            equivalence = rule["equivalenceBandPercent"]
            for workload, workload_rule in rule["workloads"].items():
                if "directionalThresholdPercent" not in workload_rule:
                    continue
                threshold = workload_rule["directionalThresholdPercent"]
                pair_count = workload_rule["pairCount"]
                midpoint = (equivalence + threshold) / 2
                cases = {
                    threshold: "slower",
                    -threshold: "faster",
                    threshold + 1.0: "slower",
                    -threshold - 1.0: "faster",
                    equivalence: "equivalent",
                    -equivalence: "equivalent",
                    0.0: "equivalent",
                    midpoint: "inconclusive",
                    -midpoint: "inconclusive",
                }
                for estimate, expected in cases.items():
                    decision = COMPARE.decide_workload(
                        mode, workload, [estimate] * pair_count
                    )
                    self.assertEqual(
                        decision["decision"], expected,
                        f"{mode}/{workload} at {estimate}",
                    )
                    self.assertAlmostEqual(
                        decision["estimatePercent"], estimate
                    )

    def test_a_decision_requires_exactly_the_frozen_number_of_pairs(self):
        # Intent: neither a short nor a long pair series can produce a decision.
        # Why it exists: completed comparisons forbid early stopping and selective
        #   extension; the fixed-N rule is only fixed if the runner refuses any
        #   other N.
        # Scenario: a confirm content-churn decision is attempted with three
        #   and five pairs instead of the frozen four.
        for pair_count in (3, 5):
            with self.assertRaises(ValueError):
                COMPARE.decide_workload(
                    "confirm", "content-churn", [0.0] * pair_count
                )

    def test_incremental_mixed_reports_no_directional_decision(self):
        self.assertIsNone(
            COMPARE.decide_workload("confirm", "incremental-mixed", [12.0] * 6)
        )

    def test_detected_outliers_are_reported_without_being_deleted(self):
        # Intent: an extreme pair is flagged but still counted in the estimate.
        # Why it exists: completed comparisons forbid silent outlier deletion --
        #   the calibrated error rates belong to the median of all pairs, not to a
        #   trimmed set.
        # Scenario: one confirm content-churn pair is wildly larger than its three
        #   siblings.
        values = [1.0, 1.0, 1.0, 50.0]
        decision = COMPARE.decide_workload("confirm", "content-churn", values)
        self.assertEqual(decision["outlierIndices"], [3])
        self.assertEqual(decision["sampleCount"], 4)
        self.assertEqual(decision["usedSampleCount"], 4)
        self.assertAlmostEqual(
            decision["estimatePercent"], statistics.median(values)
        )


class InvalidationTests(unittest.TestCase):
    def _quick_evidence(self, workload, reasons=()):
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        values = constant_pair_values(workload, schedule, 9.0)
        return schedule, collection({
            workload: workload_evidence(workload, schedule, values, reasons)
        })

    def test_a_valid_invocation_decides_every_scheduled_workload(self):
        schedule, evidence = self._quick_evidence("content-churn")
        summary = COMPARE.summarize_comparison("quick", evidence)

        self.assertTrue(summary["decisionEligible"])
        self.assertEqual(
            summary["workloads"]["content-churn"]["decision"]["decision"],
            "slower",
        )
        self.assertEqual(
            len(summary["workloads"]["content-churn"]["rawBlocks"]),
            len(schedule),
        )

    def test_an_invalid_block_at_any_position_voids_the_whole_invocation(self):
        # Intent: one invalid block anywhere in the schedule leaves the entire
        #   invocation without a decision, while keeping all of its evidence.
        # Why it exists: one invalid block invalidates the complete invocation.
        #   Deciding from the survivors would silently change the calibrated pair
        #   count, while re-running only the bad block would be a selective rerun.
        # Scenario: each schedule position in turn fails its machine-state check.
        workload = "incremental-mixed"
        schedule = COMPARE.make_schedule(
            "confirm", (workload,), physical_candidate_arm="a"
        )[workload]
        values = constant_pair_values(workload, schedule, 9.0)
        for position in range(len(schedule)):
            reason = f"block-{position}-thermal-pressure-serious"
            evidence = collection({
                workload: workload_evidence(
                    workload, schedule, values, [reason]
                )
            })

            summary = COMPARE.summarize_comparison("confirm", evidence)

            self.assertFalse(summary["decisionEligible"], position)
            self.assertIsNone(
                summary["workloads"][workload]["decision"], position
            )
            self.assertEqual(
                summary["invalidationReasons"], [f"{workload}:{reason}"]
            )
            self.assertEqual(
                len(summary["workloads"][workload]["rawBlocks"]),
                len(schedule),
                position,
            )

    def test_one_invalid_workload_voids_the_other_confirm_workloads(self):
        # Intent: a confirm suite reports no decision for any workload once any
        #   single workload is invalid.
        # Why it exists: invalidation covers the complete invocation, not one
        #   workload; reporting the four clean workloads would let an operator
        #   harvest a decision from a run the contract already rejected.
        # Scenario: scrollback-stream is occluded while the other four are clean.
        evidence_by_workload = {}
        for workload in VALIDATION.WORKLOADS:
            schedule = COMPARE.make_schedule(
                "confirm", (workload,), physical_candidate_arm="b"
            )[workload]
            values = constant_pair_values(workload, schedule, 0.0)
            reasons = (
                ["block-1-window-occluded"]
                if workload == "scrollback-stream"
                else []
            )
            evidence_by_workload[workload] = workload_evidence(
                workload, schedule, values, reasons
            )

        summary = COMPARE.summarize_comparison(
            "confirm", collection(evidence_by_workload)
        )

        self.assertFalse(summary["decisionEligible"])
        for workload in VALIDATION.WORKLOADS:
            self.assertIsNone(summary["workloads"][workload]["decision"])
            self.assertTrue(summary["workloads"][workload]["rawBlocks"])

    def test_an_invalid_invocation_reports_no_decision_in_its_render(self):
        _, evidence = self._quick_evidence(
            "style-churn", ["block-0-not-on-ac-power"]
        )
        summary = COMPARE.summarize_comparison("quick", evidence)

        rendered = COMPARE.render_decisions(summary)

        self.assertIn("no decision", rendered.lower())
        self.assertIn("block-0-not-on-ac-power", rendered)


class ReportTests(unittest.TestCase):
    def test_the_decision_report_is_source_oriented(self):
        # Intent: the operator-facing verdict speaks in baseline/candidate terms.
        # Why it exists: the final report must remain source-oriented. Physical
        #   arms are an internal scheduling detail; naming them in the verdict
        #   invites the operator to read a position as a source.
        # Scenario: a valid quick comparison is rendered.
        workload = "terminal-feed"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="a"
        )[workload]
        values = constant_pair_values(workload, schedule, -6.0)
        summary = COMPARE.summarize_comparison(
            "quick",
            collection({workload: workload_evidence(workload, schedule, values)}),
        )

        rendered = COMPARE.render_decisions(summary)

        self.assertIn("candidate", rendered.lower())
        self.assertIn("faster", rendered)
        self.assertNotIn("physical arm", rendered.lower())


class RunComparisonTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.baseline = {
            "role": "baseline",
            "revision": "HEAD~1",
            "commit": "c" * 40,
            "tree": "1" * 40,
        }
        self.candidate = {
            "role": "candidate",
            "baseCommit": "d" * 40,
            "tree": "4" + "0" * 39,
            "paths": ["app/TerminalView.swift", "plans/wip/note.md"],
        }

    def _materialize(self, repository_root, snapshot, *, cache_root, **kwargs):
        self.events.append(("materialize", snapshot["role"]))
        return {
            "role": snapshot["role"],
            "snapshot": snapshot,
            "cacheKey": snapshot["tree"],
            "cacheHit": True,
            "root": str(pathlib.Path(cache_root) / snapshot["role"] / "source"),
            "binaries": [],
        }

    def _run(self, *, artifacts_root, cache_root, difference_percent=0.0,
             reasons_by_workload=None, mode="quick", workload="content-churn",
             sample_host_conditions=None):
        reasons_by_workload = reasons_by_workload or {}
        self.collector_calls = []

        def make_collectors(schedule, attempt_directory, *, arm_roots, **kwargs):
            self.events.append(("collect", dict(arm_roots)))

            def collector_for(name):
                def collect(blocks):
                    self.collector_calls.append(name)
                    values = constant_pair_values(
                        name, blocks, difference_percent
                    )
                    return workload_evidence(
                        name, blocks, values,
                        reasons_by_workload.get(name, []),
                    )
                return collect

            return {name: collector_for(name) for name in schedule}, lambda: None

        clock = iter(range(0, 200, 1))
        return COMPARE.run_comparison(
            mode=mode,
            baseline_revision="HEAD~1",
            workload=workload,
            repository_root=ROOT,
            cache_root=cache_root,
            artifacts_root=artifacts_root,
            resolve_baseline=lambda root, revision: self.baseline,
            snapshot_candidate=lambda root: self.candidate,
            materialize=self._materialize,
            make_collectors=make_collectors,
            emit=lambda text: self.events.append(("emit", text)),
            monotonic=lambda: float(next(clock)),
            # A stub by default: the real probe forks `ps`, and no unit test
            # should depend on the host it happens to run on.
            sample_host_conditions=(
                sample_host_conditions
                or (lambda: {"available": False, "reason": "stubbed in tests"})
            ),
        )

    def test_both_source_identities_are_reported_before_anything_is_built(self):
        # Intent: the operator sees exactly what each arm will contain before the
        #   command spends any time building or measuring it.
        # Why it exists: both tree identities and every captured candidate path
        #   must be reported before building, so a surprising
        #   snapshot (a stray untracked file, the wrong baseline) is caught while
        #   cancelling is still free.
        # Scenario: a quick comparison whose candidate captured two paths.
        with tempfile.TemporaryDirectory() as directory:
            self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
            )

        kinds = [kind for kind, _ in self.events]
        first_materialize = kinds.index("materialize")
        preamble = "\n".join(
            payload for kind, payload in self.events[:first_materialize]
            if kind == "emit"
        )
        self.assertIn(self.baseline["tree"], preamble)
        self.assertIn(self.candidate["tree"], preamble)
        for path in self.candidate["paths"]:
            self.assertIn(path, preamble)

    def test_each_source_is_materialized_into_its_own_arm_root(self):
        # Intent: baseline and candidate never share a source or build directory.
        # Why it exists: each measured binary must come from its intended immutable
        #   tree; a shared root would let one arm's build products
        #   answer for the other.
        # Scenario: a quick comparison materializes both arms.
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
            )

        roots = {arm["role"]: arm["root"] for arm in result["arms"].values()}
        self.assertEqual(len(set(roots.values())), 2)
        self.assertEqual(
            [role for kind, role in self.events if kind == "materialize"],
            ["baseline", "candidate"],
        )

    def test_the_candidate_source_is_bound_to_its_derived_physical_arm(self):
        # Intent: the physical arm the schedule assigns to the candidate is the
        #   arm the collectors actually launch the candidate build in.
        # Why it exists: the schedule's role labels only mean something if the
        #   arm-to-root binding agrees with them; a mismatch would invert every
        #   pair while leaving the report internally consistent.
        # Scenario: a candidate tree whose identity selects physical arm b.
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
            )

        expected_arm = COMPARE.physical_candidate_arm(self.candidate["tree"])
        self.assertEqual(result["physicalCandidateArm"], expected_arm)
        arm_roots = next(
            payload for kind, payload in self.events if kind == "collect"
        )
        self.assertEqual(
            arm_roots[expected_arm], result["arms"]["candidate"]["root"]
        )
        self.assertEqual(len(set(arm_roots.values())), 2)

    def test_the_run_records_the_quartet_phase_its_schedule_used(self):
        # Intent: the record names the phase and the schedule agrees with it.
        # Why it exists: a phase that is applied but not recorded cannot be
        #   checked against the blocks, and a later reader could not tell a
        #   BAAB run from an ABBA one without re-deriving it from the tree.
        # Scenario: a quick comparison on the fixture candidate tree.
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
            )

        phase = COMPARE.quartet_phase(self.candidate["tree"])
        self.assertEqual(result["quartetPhase"], phase)
        first = "".join(
            planned["measurementRole"]
            for planned in result["schedule"]["content-churn"][:4]
        )
        self.assertEqual(first, COMPARE.QUARTET_PATTERNS[phase])

    def test_phase_and_total_wall_times_are_reported_separately(self):
        # Intent: snapshot, cache population, cached comparison, and total command
        #   time are each reported as their own number.
        # Why it exists: the under-60-second quick and under-five-minute confirm
        #   budgets cover only the cached comparison phase. A single total would
        #   let a cold compile hide inside the number checked against those
        #   budgets.
        # Scenario: any completed quick comparison.
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
            )

        timings = result["timings"]
        for phase in (
            "snapshotSeconds",
            "cachePopulationSeconds",
            "cachedComparisonSeconds",
            "totalSeconds",
        ):
            self.assertIsInstance(timings[phase], float, phase)
        self.assertGreaterEqual(
            timings["totalSeconds"], timings["cachedComparisonSeconds"]
        )

    def test_every_invocation_retains_its_complete_evidence_on_disk(self):
        # Intent: one artifact directory per run holds identities, schedule, raw
        #   blocks, the frozen rule, the decision, and the timings.
        # Why it exists: no durable benchmark history exists, so the per-run
        #   artifact is the only place a decision's evidence survives; a missing
        #   field there cannot be recovered later.
        # Scenario: a completed quick comparison writes its run record.
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
                difference_percent=9.0,
            )
            record = json.loads(
                pathlib.Path(result["artifacts"], "run.json").read_text()
            )

        self.assertEqual(record["baseline"]["tree"], self.baseline["tree"])
        self.assertEqual(record["candidate"]["paths"], self.candidate["paths"])
        self.assertEqual(record["mode"], "quick")
        self.assertTrue(record["schedule"]["content-churn"])
        self.assertTrue(
            record["summary"]["workloads"]["content-churn"]["rawBlocks"]
        )
        self.assertEqual(
            record["summary"]["workloads"]["content-churn"]["decision"]["decision"],
            "slower",
        )
        self.assertEqual(
            record["decisionRule"], COMPARE.decision_rule("quick")
        )
        self.assertIn("totalSeconds", record["timings"])

    def test_an_invalid_block_stops_the_run_without_a_replacement_attempt(self):
        # Intent: an invalid workload ends the invocation with no decision and no
        #   second collection of anything.
        # Why it exists: invalid invocations forbid replacement blocks and partial
        #   continuation; a retry loop would quietly convert an invalid run into a
        #   valid-looking one and reintroduce the selective-rerun path.
        # Scenario: the only scheduled workload reports an occluded window.
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
                reasons_by_workload={"content-churn": ["block-2-window-occluded"]},
            )
            record = json.loads(
                pathlib.Path(result["artifacts"], "run.json").read_text()
            )

        self.assertFalse(result["summary"]["decisionEligible"])
        self.assertEqual(self.collector_calls, ["content-churn"])
        self.assertEqual(
            record["summary"]["invalidationReasons"],
            ["content-churn:block-2-window-occluded"],
        )
        self.assertTrue(
            record["summary"]["workloads"]["content-churn"]["rawBlocks"]
        )

    def test_confirm_collects_all_five_workloads_in_one_invocation(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
                mode="confirm",
                workload=None,
            )

        self.assertEqual(
            sorted(self.collector_calls), sorted(VALIDATION.WORKLOADS)
        )
        self.assertTrue(result["summary"]["decisionEligible"])

    def test_a_candidate_identical_to_its_baseline_is_refused(self):
        # Intent: a comparison whose two sides resolve to the same tree stops
        #   instead of measuring one build against itself.
        # Why it exists: both arms key the same cache entry, so every block would
        #   run the identical binary and the command would answer "equivalent"
        #   with full confidence for a change it never contained -- the most
        #   convincing wrong answer this runner can produce.
        # Scenario: an operator passes baseline=HEAD with a clean working tree.
        self.candidate = {**self.candidate, "tree": self.baseline["tree"], "paths": []}

        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError) as raised:
                self._run(
                    artifacts_root=pathlib.Path(directory) / "artifacts",
                    cache_root=pathlib.Path(directory) / "cache",
                )

        self.assertIn("nothing to compare", str(raised.exception))
        self.assertNotIn("materialize", [kind for kind, _ in self.events])

    def test_the_baseline_revision_is_resolved_once_for_the_whole_invocation(self):
        # Intent: a confirm run resolves its baseline a single time.
        # Why it exists: every workload in one invocation must compare the same
        #   immutable pair; re-resolving mid-run would let a concurrent
        #   branch move redefine what "baseline" meant partway through.
        # Scenario: a five-workload confirm run counts baseline resolutions.
        resolutions = []
        original = self.baseline

        def resolve(root, revision):
            resolutions.append(revision)
            return original

        with tempfile.TemporaryDirectory() as directory:
            clock = iter(range(0, 200))

            def make_collectors(schedule, attempt_directory, *, arm_roots, **kwargs):
                return {
                    name: (
                        lambda blocks, name=name: workload_evidence(
                            name, blocks,
                            constant_pair_values(name, blocks, 0.0),
                        )
                    )
                    for name in schedule
                }, lambda: None

            COMPARE.run_comparison(
                mode="confirm",
                baseline_revision="v1.2.3",
                workload=None,
                repository_root=ROOT,
                cache_root=pathlib.Path(directory) / "cache",
                artifacts_root=pathlib.Path(directory) / "artifacts",
                resolve_baseline=resolve,
                snapshot_candidate=lambda root: self.candidate,
                materialize=self._materialize,
                make_collectors=make_collectors,
                emit=lambda text: None,
                monotonic=lambda: float(next(clock)),
            )

        self.assertEqual(resolutions, ["v1.2.3"])


class FeedPrebuildContractTests(unittest.TestCase):
    def test_the_cache_prebuilds_every_product_a_headless_workload_runs(self):
        # Intent: the arm cache compiles every headless benchmark product with
        #   exactly the package, configuration, and build path `swift run` will
        #   look in when the workload executes.
        # Why it exists: the headless workloads measure a separate package
        #   through `swift run`, which uses SwiftPM's default build path. If the
        #   prebuild diverges, or a newly added product is left out of it, every
        #   "cache hit" silently compiles inside the timed phase and the
        #   60-second quick budget measures a build.
        # Scenario: the cache's prebuild list is compared against each headless
        #   runner. Generalized from terminal-feed alone when research/28/D1 pitch 1 added
        #   `retained-browse` as a second product out of the same package.
        build_source = inspect.getsource(COMPARE.SNAPSHOT.build_arm)
        headless_runners = {
            COMPARE.SNAPSHOT.TERMINAL_FEED_PRODUCT: (
                VALIDATION.make_terminal_feed_runner
            ),
            "TerminalBrowseBenchmark": VALIDATION.make_retained_browse_runner,
        }

        self.assertEqual(COMPARE.SNAPSHOT.TERMINAL_FEED_PACKAGE, "lib/TerminalCore")
        self.assertEqual(
            set(COMPARE.SNAPSHOT.HEADLESS_PRODUCTS), set(headless_runners)
        )
        self.assertIn("HEADLESS_PRODUCTS", build_source)
        self.assertIn("TERMINAL_FEED_PACKAGE", build_source)
        for product, factory in headless_runners.items():
            runner_source = inspect.getsource(factory)
            self.assertIn('"lib" / "TerminalCore"', runner_source, product)
            self.assertIn(product, runner_source)
            # `swift run` resolves the default build path, so the prebuild must
            # not redirect this package's products with --build-path.
            self.assertNotIn("--build-path", runner_source, product)
        feed_build = build_source.split("TERMINAL_FEED_PACKAGE")[1].split("]")[0]
        self.assertNotIn("--build-path", feed_build)
        self.assertIn(COMPARE.SNAPSHOT.CONFIGURATION, runner_source)


class CommandLineTests(unittest.TestCase):
    def test_a_mistyped_workload_selection_reports_a_usage_error(self):
        # Intent: naming no workload for quick, or one for confirm, exits with a
        #   usage error instead of a traceback -- and without starting a run.
        # Why it exists: selection is the one failure an operator reaches by
        #   typing, and a traceback here would read as a broken command rather
        #   than a fixable invocation.
        # Scenario: `benchmark-quick` is run without workload=.
        errors = io.StringIO()

        status = COMPARE.main(
            ["quick", "--baseline", "HEAD~1"], stderr=errors
        )

        self.assertEqual(status, 2)
        self.assertIn("quick requires workload=", errors.getvalue())

    def test_confirm_rejects_a_workload_argument_as_a_usage_error(self):
        errors = io.StringIO()

        status = COMPARE.main(
            ["confirm", "--baseline", "HEAD~1", "--workload", "style-churn"],
            stderr=errors,
        )

        self.assertEqual(status, 2)
        self.assertIn("complete ladder", errors.getvalue())


class AuxiliaryPlanMetricTests(unittest.TestCase):
    """The descriptive plan-time estimate, which reports but never decides."""

    def _blocks(self, workload, schedule, draw_percent, plan_percent):
        draw_values = constant_pair_values(workload, schedule, draw_percent)
        plan_values = constant_pair_values(workload, schedule, plan_percent)
        blocks = raw_blocks(workload, schedule, draw_values)
        metric = COMPARE.AUXILIARY_BLOCK_METRICS[workload]
        for block, plan_value in zip(blocks, plan_values):
            block[metric] = plan_value
        return blocks

    def _evidence(self, blocks, workload):
        return collection({
            workload: {
                "workload": workload,
                "rawBlocks": blocks,
                "valid": True,
                "invalidationReasons": [],
            }
        })

    def test_the_plan_estimate_is_reported_for_every_draw_workload(self):
        # Intent: each serialized-draw workload reports a symmetric plan-time
        #   estimate next to its draw verdict.
        # Why it exists: `drawDurationNanoseconds` brackets only clip + draw, so
        #   the draw metric structurally cannot observe `planFrame`. Without a
        #   second reported quantity a planner change is unmeasurable, which is
        #   how an O(n^2) coalescing fix classified `equivalent` on all three of
        #   these workloads.
        # Scenario: spec-first -- a candidate that plans 20% faster while drawing
        #   at exactly baseline speed.
        for workload in ("content-churn", "style-churn"):
            with self.subTest(workload=workload):
                schedule = COMPARE.make_schedule(
                    "quick", (workload,), physical_candidate_arm="b"
                )[workload]
                blocks = self._blocks(workload, schedule, 0.0, -20.0)

                differences = COMPARE.auxiliary_differences(workload, blocks)

                self.assertEqual(len(differences), len(schedule) // 2)
                self.assertAlmostEqual(statistics.median(differences), -20.0)

    def test_the_plan_estimate_never_changes_the_draw_verdict(self):
        # Intent: adding plan-time evidence leaves the frozen decision rule's
        #   output bit-identical.
        # Why it exists: the plan metric is uncalibrated, so it must be additive.
        #   If it could move a verdict it would silently redefine the decision
        #   rule that `terminal-performance.md` freezes against recalibration.
        # Scenario: spec-first -- a large plan-time regression alongside an
        #   unchanged draw time must still read as an unchanged draw time.
        workload = "content-churn"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        without_plan = raw_blocks(
            workload, schedule, constant_pair_values(workload, schedule, 9.0)
        )
        with_plan = self._blocks(workload, schedule, 9.0, 150.0)

        bare = COMPARE.summarize_comparison("quick", self._evidence(without_plan, workload))
        annotated = COMPARE.summarize_comparison("quick", self._evidence(with_plan, workload))

        self.assertEqual(
            annotated["workloads"][workload]["decision"],
            bare["workloads"][workload]["decision"],
        )
        self.assertIsNone(bare["workloads"][workload]["auxiliary"])
        self.assertEqual(
            annotated["workloads"][workload]["auxiliary"]["metric"],
            "planNanosecondsPerFullPlan",
        )

    def test_blocks_without_plan_evidence_report_no_estimate(self):
        # Intent: artifacts collected before the plan timer existed still pair,
        #   decide, and render, reporting no plan estimate at all.
        # Why it exists: the paired harness compares one revision against another,
        #   so a baseline arm predating the timer is the normal case for the first
        #   several comparisons. Failing or fabricating a zero there would either
        #   block the comparison or invent an effect.
        # Scenario: spec-first -- baseline blocks carry no plan metric.
        workload = "style-churn"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = self._blocks(workload, schedule, 5.0, -10.0)
        for block in blocks:
            if block["measurementRole"] == "A":
                del block["planNanosecondsPerFullPlan"]

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks, workload))

        self.assertIsNone(COMPARE.auxiliary_differences(workload, blocks))
        self.assertIsNone(summary["workloads"][workload]["auxiliary"])
        self.assertIn("style-churn: slower", COMPARE.render_decisions(summary))

    def test_the_render_marks_the_plan_estimate_as_carrying_no_verdict(self):
        # Intent: the rendered plan line states that it is descriptive.
        # Why it exists: every other percentage in this report carries a
        #   calibrated classification. An unlabeled fourth number invites reading
        #   the plan estimate as a verdict it has no thresholds to support.
        # Scenario: spec-first -- an operator reads a quick comparison.
        workload = "style-churn"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = self._blocks(workload, schedule, 0.0, -30.0)

        render = COMPARE.render_decisions(
            COMPARE.summarize_comparison("quick", self._evidence(blocks, workload))
        )

        self.assertIn("plan time", render)
        self.assertIn("-30.00%", render)
        self.assertIn("no verdict", render)

    def test_no_mode_carries_a_plan_rule_until_one_is_frozen(self):
        # Intent: the plan line is descriptive in both modes, on every workload.
        # Why it exists: the quick rules that stood here were calibrated on the
        #   per-draw plan sum, a quantity that no longer exists. A rule frozen
        #   for one number must not be applied to another; the A/A series on
        #   the median full plan is what a human freezes the next one from.
        # Scenario: spec-first -- a candidate that plans 40% faster while
        #   drawing at exactly baseline speed reads a bare percentage.
        for mode in ("quick", "confirm"):
            self.assertNotIn("planWorkloads", COMPARE.decision_rule(mode))
        workload = "content-churn"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = self._blocks(workload, schedule, 0.0, -40.0)

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks, workload))

        auxiliary = summary["workloads"][workload]["auxiliary"]
        self.assertIsNone(auxiliary["decision"])
        self.assertAlmostEqual(auxiliary["estimatePercent"], -40.0)
        self.assertEqual(summary["workloads"][workload]["decision"]["decision"], "equivalent")
        render = COMPARE.render_decisions(summary)
        self.assertIn("plan time", render)
        self.assertIn("no verdict", render)

    def test_a_workload_that_never_plans_a_full_viewport_carries_no_plan_line(self):
        # Intent: `incremental-mixed` has no plan metric at all.
        # Why it exists: it replans four or five rows per update, so a
        #   full-viewport median has nothing to select; its old per-draw line
        #   was already refused a rule (A/A SD 5.75%), and a line that can only
        #   ever print noise is worse than none.
        # Scenario: spec-first -- the frozen table is read directly and a block
        #   series for the workload summarizes with no auxiliary entry.
        workload = "incremental-mixed"
        self.assertNotIn(workload, COMPARE.AUXILIARY_BLOCK_METRICS)
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = raw_blocks(
            workload, schedule, constant_pair_values(workload, schedule, 0.0)
        )

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks, workload))

        self.assertIsNone(summary["workloads"][workload]["auxiliary"])
        self.assertNotIn("plan time", COMPARE.render_decisions(summary))

    def test_a_plan_rule_never_decides_on_the_wrong_number_of_pairs(self):
        # Intent: a plan rule applies only to a series of exactly the pair count
        #   it was calibrated at.
        # Why it exists: a rule's false-positive and detection rates were measured
        #   at one fixed N. Applying it to a longer or shorter series would claim
        #   error rates that series was never measured to have -- the same peeking
        #   the fixed schedule exists to prevent.
        # Scenario: spec-first -- a rule calibrated at 2 pairs meets a 4-pair
        #   confirm series for the same workload.
        workload = "content-churn"
        schedule = COMPARE.make_schedule(
            "confirm", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = self._blocks(workload, schedule, 0.0, -40.0)
        confirm = COMPARE.VALIDATION.DECISION_RULES["confirm"]
        self.assertNotIn("planWorkloads", confirm)
        confirm["planWorkloads"] = {
            workload: {
                "pairCount": 2,
                "directionalThresholdPercent": 2.5,
                "equivalenceBandPercent": 1.0,
            }
        }
        try:
            self.assertNotEqual(len(schedule) // 2, 2)

            summary = COMPARE.summarize_auxiliary("confirm", workload, blocks)

            self.assertIsNone(summary["decision"])
        finally:
            del confirm["planWorkloads"]

    def test_confirm_reports_plan_time_descriptively(self):
        # Intent: confirm carries no plan-time rule for any workload and says so.
        # Why it exists: its 4-pair schedule cannot detect the 3% effect it claims
        #   at any threshold that also holds A/A false positives under 1% -- the
        #   best cell measured 0.0198 false positives or 0.633 detection. Freezing
        #   a rule there anyway would put the mode's stated accuracy in writing
        #   without the evidence to back it.
        # Scenario: spec-first -- an operator escalates to confirm and reads the
        #   plan line.
        workload = "content-churn"
        schedule = COMPARE.make_schedule(
            "confirm", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = self._blocks(workload, schedule, 0.0, -40.0)

        summary = COMPARE.summarize_comparison(
            "confirm", self._evidence(blocks, workload)
        )

        self.assertIsNone(summary["workloads"][workload]["auxiliary"]["decision"])
        self.assertIn("no verdict", COMPARE.render_decisions(summary))

    def test_only_the_serialized_draw_workloads_carry_a_plan_metric(self):
        # Intent: the auxiliary table covers exactly the workloads whose decision
        #   metric excludes planning.
        # Why it exists: `terminal-feed` never runs this app and `scrollback-stream`
        #   decides on a wall clock that already contains planning, so a plan
        #   estimate there would be redundant at best and double-counted at worst.
        # Scenario: spec-first -- the frozen table is read directly.
        self.assertEqual(
            set(COMPARE.AUXILIARY_BLOCK_METRICS),
            {"content-churn", "style-churn"},
        )
        self.assertTrue(
            set(COMPARE.AUXILIARY_BLOCK_METRICS) <= set(COMPARE.BLOCK_METRICS)
        )


class UncalibratedProcessCPUMetricTests(unittest.TestCase):
    """Whole-process CPU: reported beside the verdict, never able to become one."""

    def _blocks(self, workload, schedule, draw_percent, cpu_percent):
        blocks = raw_blocks(
            workload, schedule, constant_pair_values(workload, schedule, draw_percent)
        )
        metric = COMPARE.UNCALIBRATED_BLOCK_METRICS[workload]
        cpu_values = constant_pair_values(workload, schedule, cpu_percent)
        for block, cpu_value in zip(blocks, cpu_values):
            block[metric] = cpu_value
        return blocks

    def _evidence(self, blocks, workload):
        return collection({
            workload: {
                "workload": workload,
                "rawBlocks": blocks,
                "valid": True,
                "invalidationReasons": [],
            }
        })

    def test_process_cpu_is_reported_for_every_serialized_draw_workload(self):
        # Intent: each serialized-draw workload reports a symmetric process-CPU
        #   estimate beside its draw verdict.
        # Why it exists: the draw metric times elapsed main-thread work between
        #   two points, so work on any other thread is invisible to it at any
        #   size. `research/17/F6` located the app's largest single cost -- Core
        #   Animation recomputing per-glyph bounds during display-list replay, at
        #   16.78% of one workload's on-CPU total -- inside that blind spot, where
        #   only a diagnostic-only profiler could see it. This metric is what lets
        #   a decision block see it at all.
        # Scenario: spec-first -- a candidate that burns 30% less CPU while its
        #   main-thread draw time is unchanged, which is exactly the shape a fix
        #   to replay-thread work would take.
        for workload in ("content-churn", "style-churn", "incremental-mixed"):
            with self.subTest(workload=workload):
                schedule = COMPARE.make_schedule(
                    "quick", (workload,), physical_candidate_arm="b"
                )[workload]
                blocks = self._blocks(workload, schedule, 0.0, -30.0)

                summary = COMPARE.summarize_comparison(
                    "quick", self._evidence(blocks, workload)
                )
                reported = summary["workloads"][workload]["uncalibrated"]

                self.assertEqual(reported["metric"], "processCPUNanosecondsPerDraw")
                self.assertAlmostEqual(reported["estimatePercent"], -30.0)
                decision = summary["workloads"][workload]["decision"]
                if workload == "incremental-mixed":
                    self.assertIsNone(decision)
                else:
                    self.assertEqual(decision["decision"], "equivalent")

    def test_process_cpu_never_carries_a_verdict_in_either_mode(self):
        # Intent: the process-CPU summary reports `decision: None` and renders as
        #   descriptive text, in `quick` and `confirm` alike.
        # Why it exists: no A/A screening pass has calibrated this metric, so any
        #   threshold applied to it would be invented rather than measured. The
        #   risk is specifically that it sits one line under a classified draw
        #   result and gets read as a third verdict.
        # Scenario: spec-first -- a CPU swing far larger than any plausible
        #   directional threshold must still classify nothing.
        workload = "content-churn"
        for mode in ("quick", "confirm"):
            with self.subTest(mode=mode):
                schedule = COMPARE.make_schedule(
                    mode, (workload,), physical_candidate_arm="b"
                )[workload]
                blocks = self._blocks(workload, schedule, 0.0, -80.0)

                summary = COMPARE.summarize_comparison(
                    mode, self._evidence(blocks, workload)
                )
                rendered = COMPARE.render_decisions(summary)

                self.assertIsNone(
                    summary["workloads"][workload]["uncalibrated"]["decision"]
                )
                self.assertFalse(
                    summary["workloads"][workload]["uncalibrated"]["calibrated"]
                )
                self.assertIn("process CPU:", rendered)
                self.assertIn("no verdict", rendered)

    def test_process_cpu_never_changes_the_draw_verdict(self):
        # Intent: adding process-CPU evidence leaves the frozen decision rule's
        #   output bit-identical.
        # Why it exists: the metric is additive by construction, and this is the
        #   assertion that keeps it additive. Its measurement is strictly wider
        #   than the draw bracket -- it includes parsing, planning, replay, and
        #   the observer -- so folding any part of it into the draw verdict would
        #   redefine the calibrated metric rather than sharpen it.
        # Scenario: spec-first -- a large CPU regression alongside an unchanged
        #   draw time must still read as an unchanged draw time.
        workload = "style-churn"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        without_cpu = raw_blocks(
            workload, schedule, constant_pair_values(workload, schedule, 1.0)
        )
        with_cpu = self._blocks(workload, schedule, 1.0, 150.0)

        bare = COMPARE.summarize_comparison(
            "quick", self._evidence(without_cpu, workload)
        )
        annotated = COMPARE.summarize_comparison(
            "quick", self._evidence(with_cpu, workload)
        )

        self.assertEqual(
            annotated["workloads"][workload]["decision"],
            bare["workloads"][workload]["decision"],
        )
        self.assertIsNone(bare["workloads"][workload]["uncalibrated"])

    def test_blocks_without_process_cpu_evidence_report_no_estimate(self):
        # Intent: artifacts collected before the CPU reading existed still pair,
        #   decide, and render, reporting no CPU estimate at all.
        # Why it exists: the paired harness compares one revision against another,
        #   so a baseline arm predating this reading is the normal case for every
        #   comparison made against existing history. Failing or substituting zero
        #   there would either block the comparison or invent an effect.
        # Scenario: spec-first -- baseline blocks carry no CPU metric.
        workload = "incremental-mixed"
        schedule = COMPARE.make_schedule(
            "quick", (workload,), physical_candidate_arm="b"
        )[workload]
        blocks = self._blocks(workload, schedule, 5.0, -10.0)
        for block in blocks:
            if block["measurementRole"] == "A":
                del block["processCPUNanosecondsPerDraw"]

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks, workload))

        self.assertIsNone(summary["workloads"][workload]["uncalibrated"])
        self.assertNotIn("process CPU:", COMPARE.render_decisions(summary))

    def test_the_cpu_metric_stays_out_of_the_calibrated_plan_table(self):
        # Intent: the CPU metric is absent from `AUXILIARY_BLOCK_METRICS` and its
        #   workloads still fall inside the decision table.
        # Why it exists: `AUXILIARY_BLOCK_METRICS` is the plan calibrator's input
        #   (`PLAN_WORKLOADS`) and drives the `planWorkloads` rule lookup, so an
        #   entry there is a claim that a frozen rule exists for that metric.
        #   Adding this one to that table is precisely how it would acquire a
        #   verdict it has not earned.
        # Scenario: spec-first -- both frozen tables are read directly.
        self.assertEqual(
            set(COMPARE.UNCALIBRATED_BLOCK_METRICS),
            {"content-churn", "style-churn", "incremental-mixed"},
        )
        self.assertTrue(
            set(COMPARE.UNCALIBRATED_BLOCK_METRICS) <= set(COMPARE.BLOCK_METRICS)
        )
        self.assertTrue(
            set(COMPARE.UNCALIBRATED_BLOCK_METRICS.values()).isdisjoint(
                COMPARE.AUXILIARY_BLOCK_METRICS.values()
            )
        )


class ThroughputCompositionTests(unittest.TestCase):
    """The descriptive drain/draw-tail split, which reports absolute cost and never decides.

    Research doc 20 found `producerWriteNanoseconds` recorded in every `scrollback-stream`
    block since the harness was written and referenced by no metric table (`research/20/F2`):
    it is 95.7% of `finalDrawNanoseconds`, so the workload's verdict
    has always been ~96% a PTY drain measurement with a ~9.5 ms draw tail on the
    end. These tests pin the split that makes that composition visible.
    """

    WORKLOAD = "scrollback-stream"
    CORPUS_BYTES = 1_525_000

    def _blocks(self, schedule, drain_share=0.96, final_draw_nanoseconds=None):
        """Build a block series whose drain is a fixed share of its final draw."""
        final_draw = final_draw_nanoseconds or 200_000_000.0
        blocks = raw_blocks(
            self.WORKLOAD,
            schedule,
            [final_draw] * len(schedule),
        )
        for block in blocks:
            block["producerWriteNanoseconds"] = final_draw * drain_share
            block["producerWriteBytes"] = self.CORPUS_BYTES
            block["producerWriteGeometry"] = {"columns": 179, "rows": 66}
        return blocks

    def _evidence(self, blocks):
        return collection({
            self.WORKLOAD: {
                "workload": self.WORKLOAD,
                "rawBlocks": blocks,
                "valid": True,
                "invalidationReasons": [],
            }
        })

    def _schedule(self):
        return COMPARE.make_schedule(
            "quick", (self.WORKLOAD,), physical_candidate_arm="b"
        )[self.WORKLOAD]

    def test_the_drain_and_draw_tail_are_reported_beside_the_verdict(self):
        # Intent: a `scrollback-stream` result reports how its measured block
        #   decomposes into PTY drain and the draw tail that follows it.
        # Why it exists: the verdict is one number for two very different costs.
        #   `research/20/F2` measured the drain at 95.7% of the block, which means a change
        #   touching only the draw path can move this workload by at most ~4% --
        #   so a flat verdict on a real drawing win is the expected reading, not a
        #   failure. Nothing reported that until now.
        # Scenario: spec-first -- an operator reads a block that is 96% drain.
        schedule = self._schedule()
        blocks = self._blocks(schedule, drain_share=0.96)

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks))
        composition = summary["workloads"][self.WORKLOAD]["composition"]

        self.assertEqual(composition["corpusBytes"], self.CORPUS_BYTES)
        for arm in ("baseline", "candidate"):
            with self.subTest(arm=arm):
                self.assertAlmostEqual(
                    composition["arms"][arm]["drainNanoseconds"], 192_000_000.0
                )
                self.assertAlmostEqual(
                    composition["arms"][arm]["tailNanoseconds"], 8_000_000.0
                )
                self.assertAlmostEqual(
                    composition["arms"][arm]["tailPercent"], 4.0
                )
                self.assertAlmostEqual(
                    composition["arms"][arm]["drainMegabytesPerSecond"],
                    self.CORPUS_BYTES / 0.192 / 1e6,
                )

    def test_the_composition_never_changes_the_paired_estimate(self):
        # Intent: adding the split leaves the paired estimate bit-identical.
        # Why it exists: this quantity is 95.7% the same number as the deciding
        #   metric (`research/20/F2`), which is exactly why it must decide nothing --
        #   `research/20/D1` rejected a second verdict on it as double-counting evidence.
        #   The estimate rather than the verdict is asserted because this cell's
        #   directional rule is vacated (`research/39/F8`) and its verdict is
        #   `None` either way, which would make a verdict comparison vacuous.
        # Scenario: spec-first -- two block series with identical deciding
        #   metrics and wildly different drain shares must estimate identically.
        schedule = self._schedule()
        drain_heavy = self._blocks(schedule, drain_share=0.98)
        draw_heavy = self._blocks(schedule, drain_share=0.50)

        heavy = COMPARE.summarize_comparison("quick", self._evidence(drain_heavy))
        light = COMPARE.summarize_comparison("quick", self._evidence(draw_heavy))

        self.assertEqual(
            heavy["workloads"][self.WORKLOAD]["pairedSymmetricPercent"],
            light["workloads"][self.WORKLOAD]["pairedSymmetricPercent"],
        )
        self.assertIsNone(heavy["workloads"][self.WORKLOAD]["decision"])

    def test_blocks_without_drain_evidence_report_no_composition(self):
        # Intent: a block series missing the byte count still pairs and renders,
        #   reporting no composition at all.
        # Why it exists: the paired harness compares one revision against another,
        #   so a baseline arm predating the byte counter is the normal case for
        #   the first several comparisons after it lands. Fabricating a rate from
        #   an assumed corpus size would silently misreport whichever arm ran a
        #   different corpus.
        # Scenario: spec-first -- baseline blocks carry no recorded byte count.
        schedule = self._schedule()
        blocks = self._blocks(schedule)
        for block in blocks:
            if block["measurementRole"] == "A":
                del block["producerWriteBytes"]

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks))

        self.assertIsNone(summary["workloads"][self.WORKLOAD]["composition"])
        self.assertTrue(
            summary["workloads"][self.WORKLOAD]["pairedSymmetricPercent"]
        )
        self.assertNotIn("drain (", COMPARE.render_decisions(summary))

    def test_disagreeing_byte_counts_report_no_rate(self):
        # Intent: two arms that wrote different byte totals report no composition.
        # Why it exists: the rate's denominator is the corpus, and a paired
        #   comparison is only meaningful when both arms drained the same bytes.
        #   Averaging across two corpora would produce a rate belonging to
        #   neither arm while looking exactly like a valid one.
        # Scenario: spec-first -- an arm pair straddling a corpus change.
        schedule = self._schedule()
        blocks = self._blocks(schedule)
        for block in blocks:
            if block["measurementRole"] == "B":
                block["producerWriteBytes"] = self.CORPUS_BYTES * 2

        summary = COMPARE.summarize_comparison("quick", self._evidence(blocks))

        self.assertIsNone(summary["workloads"][self.WORKLOAD]["composition"])

    def test_the_rendered_split_names_its_denominator_and_carries_no_verdict(self):
        # Intent: the rendered lines state the corpus and geometry the rate is
        #   derived from, and say in words that they decide nothing.
        # Why it exists: `research/17/D6` established that a bare number printed under a
        #   classified verdict reads as a second verdict. A rate is worse than a
        #   percentage here, because "10.5 MB/s" is meaningless without the corpus
        #   and geometry that produced it -- doc 20's investigation rules require
        #   both to appear beside any rate.
        # Scenario: spec-first -- an operator reads the report and can reconstruct
        #   the arithmetic from the line itself.
        schedule = self._schedule()
        summary = COMPARE.summarize_comparison(
            "quick", self._evidence(self._blocks(schedule))
        )

        render = COMPARE.render_decisions(summary)

        self.assertIn("drain (baseline):", render)
        self.assertIn("drain (candidate):", render)
        self.assertIn("draw tail (baseline):", render)
        self.assertIn("MB/s", render)
        self.assertIn("MB corpus", render)
        self.assertIn("179x66", render)
        self.assertIn("descriptive, no verdict", render)

    def test_the_split_is_confined_to_the_workload_that_measures_throughput(self):
        # Intent: no serialized-draw workload reports a drain composition.
        # Why it exists: those three workloads write one update and then wait for
        #   that exact draw, so their producer write time measures the handshake,
        #   not throughput. Reporting a rate there would invite exactly the
        #   comparison the numbers cannot support -- doc 20's caveats say so in
        #   as many words.
        # Scenario: spec-first -- both frozen tables are read directly.
        self.assertEqual(COMPARE.COMPOSITION_WORKLOADS, {"scrollback-stream"})
        self.assertTrue(
            COMPARE.COMPOSITION_WORKLOADS <= set(COMPARE.BLOCK_METRICS)
        )
        self.assertTrue(
            COMPARE.COMPOSITION_WORKLOADS.isdisjoint(
                COMPARE.AUXILIARY_BLOCK_METRICS
            )
        )


class HostIdlenessPreflightTests(unittest.TestCase):
    """The pre-launch host reading that research/28/D1 pitch 4 admitted, and its placement."""

    def _processes(self):
        return [
            (453, 1, 43.9, "WindowServer"),
            (4185, 1, 19.1, "claude"),
            (900, 4185, 12.0, "python3"),
            (901, 900, 8.0, "swift-frontend"),
            (77, 1, 2.0, "bluetoothd"),
        ]

    def test_a_reading_names_the_load_and_the_external_processes_behind_it(self):
        # Intent: one sample reports the load average, the per-processor load, and
        #   the busiest processes that are not this comparison's own children.
        # Why it exists: research/28/F2 is the incident -- a confirm run taken at load
        #   4.73/5.89/8.92 with WindowServer at ~49% reported four `slower`
        #   verdicts with `invalidations: []`, and three did not survive
        #   re-measurement. The harness could not see the one stated condition it
        #   had violated, so the reading has to name both the number and who
        #   caused it; a bare load average would not have identified WindowServer.
        # Scenario: spec-first -- a host at load 4.73 with a known process table.
        reading = COMPARE.sample_host_conditions(
            load_average=lambda: (4.73, 5.89, 8.92),
            processor_count=lambda: 10,
            list_processes=self._processes,
            driver_pid=900,
        )

        self.assertTrue(reading["available"])
        self.assertEqual(reading["loadAverage"]["one"], 4.73)
        self.assertEqual(reading["loadAverage"]["fifteen"], 8.92)
        self.assertAlmostEqual(reading["loadPerProcessor"], 0.473, places=3)
        commands = [entry["command"] for entry in reading["topExternalProcesses"]]
        self.assertEqual(commands[0], "WindowServer")
        self.assertIn("claude", commands)

    def test_the_harness_own_process_tree_is_excluded_from_the_external_list(self):
        # Intent: the driver and its descendants never appear as external load.
        # Why it exists: research/28/F3 measured the confound directly -- load sampled
        #   during a run climbed 3.23 -> 9.68 because the benchmark's own builds
        #   and GUI app were most of it. A reading that counted the harness
        #   against itself would report every run as contaminated and be ignored,
        #   which is worse than no reading at all.
        # Scenario: the driver (pid 900) has one build child (pid 901).
        reading = COMPARE.sample_host_conditions(
            load_average=lambda: (1.0, 1.0, 1.0),
            processor_count=lambda: 10,
            list_processes=self._processes,
            driver_pid=900,
        )

        commands = [entry["command"] for entry in reading["topExternalProcesses"]]
        self.assertNotIn("python3", commands)
        self.assertNotIn("swift-frontend", commands)
        self.assertEqual(reading["excludedHarnessProcessCount"], 2)

    def test_a_probe_failure_reports_not_measured_rather_than_an_idle_host(self):
        # Intent: when the probe cannot read the host, the reading says so
        #   explicitly instead of omitting the field or reporting zero.
        # Why it exists: the measurement-discipline rule this doc binds itself to
        #   requires an instrument that can say "not measured" distinctly from
        #   "measured idle". Those two collapse into the same artifact if a failed
        #   probe just drops the key, and a future reader would then read silence
        #   as a clean machine.
        # Scenario: `ps` is unavailable, as it is in a restricted sandbox.
        def explode():
            raise OSError("ps: command not found")

        reading = COMPARE.sample_host_conditions(
            load_average=lambda: (1.0, 1.0, 1.0),
            processor_count=lambda: 10,
            list_processes=explode,
            driver_pid=900,
        )

        self.assertFalse(reading["available"])
        self.assertIn("ps", reading["reason"])
        self.assertNotIn("loadPerProcessor", reading)

    def test_the_preflight_samples_before_the_blocks_and_never_between_them(self):
        # Intent: host sampling happens twice -- once at invocation and once after
        #   the builds, immediately before collection -- and never once collection
        #   has started.
        # Why it exists: this doc's measurement-machinery rule (precedents
        #   `6747e82`, `2eaac68`) forbids instrumentation on a measured path. A
        #   `ps` fork between blocks would be exactly that, and it would perturb
        #   the very quantity it claims to observe.
        # Scenario: a quick comparison records the order of its own phases.
        runner = RunComparisonTests("test_confirm_collects_all_five_workloads_in_one_invocation")
        runner.setUp()
        samples = []

        def sample():
            samples.append(len(runner.events))
            return COMPARE.sample_host_conditions(
                load_average=lambda: (1.0, 1.0, 1.0),
                processor_count=lambda: 10,
                list_processes=self._processes,
                driver_pid=900,
            )

        with tempfile.TemporaryDirectory() as directory:
            result = runner._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
                sample_host_conditions=sample,
            )

        kinds = [kind for kind, _ in runner.events]
        collect_index = kinds.index("collect")
        self.assertEqual(len(samples), 2)
        self.assertTrue(all(index <= collect_index for index in samples))
        conditions = result["summary"]["hostConditions"]
        self.assertIn("atInvocation", conditions)
        self.assertIn("beforeFirstBlock", conditions)

    def test_an_invalid_run_still_carries_its_host_reading(self):
        # Intent: the conditions annotation survives an invocation that produced
        #   no decision.
        # Why it exists: an invalid run is exactly when a reader most needs to
        #   know what else the machine was doing -- the reading is the evidence
        #   that separates "the harness caught a real defect" from "the host was
        #   busy". Dropping it on the invalid path would lose it when it matters.
        # Scenario: the only scheduled workload reports an occluded window.
        runner = RunComparisonTests("test_confirm_collects_all_five_workloads_in_one_invocation")
        runner.setUp()

        with tempfile.TemporaryDirectory() as directory:
            result = runner._run(
                artifacts_root=pathlib.Path(directory) / "artifacts",
                cache_root=pathlib.Path(directory) / "cache",
                reasons_by_workload={"content-churn": ["block-2-window-occluded"]},
            )
            record = json.loads(
                pathlib.Path(result["artifacts"], "run.json").read_text()
            )

        self.assertFalse(record["summary"]["decisionEligible"])
        self.assertIn("atInvocation", record["summary"]["hostConditions"])

    def test_the_rendered_verdict_reports_the_reading_and_claims_no_threshold(self):
        # Intent: the operator sees the load and the busiest external process
        #   beside the verdicts, marked as an observation rather than a gate.
        # Why it exists: research/28/D1 admitted this scoped to annotate-and-record and
        #   explicitly refused a refusal threshold, because no evidence exists yet
        #   for what load actually perturbs a verdict. Rendering it as a pass/fail
        #   would smuggle in the uncalibrated gate the decision declined.
        # Scenario: a summary carrying a busy pre-launch reading is rendered.
        workload = "content-churn"
        schedule = COMPARE.make_schedule(
            "quick", [workload], physical_candidate_arm="b"
        )[workload]
        values = constant_pair_values(workload, schedule, 0.0)
        summary = COMPARE.summarize_comparison(
            "quick",
            collection({workload: workload_evidence(workload, schedule, values)}),
            host_conditions={
                "atInvocation": COMPARE.sample_host_conditions(
                    load_average=lambda: (4.73, 5.89, 8.92),
                    processor_count=lambda: 10,
                    list_processes=self._processes,
                    driver_pid=900,
                ),
                "beforeFirstBlock": {"available": False, "reason": "probe failed"},
            },
        )

        rendered = COMPARE.render_decisions(summary)

        self.assertIn("4.73", rendered)
        self.assertIn("WindowServer", rendered)
        self.assertIn("not measured", rendered)
        self.assertIn("no verdict", rendered)


if __name__ == "__main__":
    unittest.main()
