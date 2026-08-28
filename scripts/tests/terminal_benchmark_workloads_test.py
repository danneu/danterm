#!/usr/bin/env python3
"""One question: is the benchmark workload set closed and agreed on everywhere?

The producer emits stimulus, the harness gates invocations, and the paired
lifecycle schedules blocks -- three places that each name draw workloads. This
file exists so the three cannot drift apart, which is how orphaned workloads
(stimulus nothing measures, or a ladder entry nothing can produce) appear.
"""
import importlib.util
import pathlib
import re
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
SPARSE_SPAN_WORKLOADS = ("sparse-spans-few", "sparse-spans-max")


class TerminalBenchmarkWorkloadSetTests(unittest.TestCase):
    def test_producer_and_paired_lifecycle_name_the_same_draw_workloads(self):
        # Intent: the stimulus generator and the paired block scheduler accept
        #   exactly the same serialized-draw workloads -- the three full-screen
        #   ones and the two sparse-span ones.
        # Why it exists: a workload present in only one of them is unreachable --
        #   either stimulus no comparison measures, or a schedulable block whose
        #   frames cannot be produced. Both fail late, inside a GUI run.
        # Scenario: spec-first; the paired ladder is the only decision surface, so
        #   every draw workload it names must be producible and vice versa.
        self.assertEqual(PRODUCER.REDRAW_WORKLOADS, DRAW_WORKLOADS)
        self.assertEqual(PRODUCER.SPARSE_SPAN_WORKLOADS, SPARSE_SPAN_WORKLOADS)
        for workload in DRAW_WORKLOADS + SPARSE_SPAN_WORKLOADS:
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

    def test_the_captured_tui_workload_is_collectable_but_not_decidable(self):
        # Intent: `synchronized-frames` remains an instrument and candidate-screen
        #   input without participating in routine quick or confirm verdicts.
        # Why it exists: two fresh post-rewrite screens selected no confirm cell,
        #   so retaining the old thresholds would knowingly label noise while
        #   deleting the workload would lose unique synchronized-output coverage.
        # Scenario: research/23/D4 demotes the refused workload until fresh independent
        #   screens and a held-out confirmation can graduate it again.
        self.assertIn("synchronized-frames", VALIDATION.CANDIDATE_WORKLOADS)
        self.assertNotIn("synchronized-frames", VALIDATION.WORKLOADS)
        self.assertIn("synchronized-frames", VALIDATION.BLOCK_CONTRACTS)
        self.assertTrue(callable(VALIDATION.collect_synchronized_frames))
        for mode in COMPARE.MODES:
            self.assertNotIn(
                "synchronized-frames", COMPARE.decision_rule(mode)["workloads"]
            )
        with self.assertRaises(ValueError):
            COMPARE.resolve_workloads("quick", "synchronized-frames")
        self.assertNotIn(
            "synchronized-frames", COMPARE.resolve_workloads("confirm")
        )

    def test_the_sparse_span_workloads_are_collectable_but_not_decidable(self):
        # Intent: both sparse-span workloads can be launched, scheduled, and
        #   collected, and neither can produce a verdict in either mode.
        # Why it exists: their thresholds have not been screened yet, so anything
        #   that classified them would be inventing a rule. The opposite failure
        #   is just as real: a workload nothing can collect cannot be screened at
        #   all, and screening is what the next step needs from this one.
        # Scenario: spec-first; research/29/D3 admits the pair as candidates first and
        #   grants verdict authority only after an A/A screen and a held-out
        #   confirmation.
        for workload in SPARSE_SPAN_WORKLOADS:
            with self.subTest(workload=workload):
                self.assertIn(workload, VALIDATION.CANDIDATE_WORKLOADS)
                self.assertNotIn(workload, VALIDATION.WORKLOADS)
                self.assertIn(workload, VALIDATION.BLOCK_CONTRACTS)
                self.assertIn(workload, COMPARE.BLOCK_METRICS)
                with self.assertRaises(ValueError):
                    COMPARE.resolve_workloads("quick", workload)
                self.assertNotIn(workload, COMPARE.resolve_workloads("confirm"))

    def test_the_kitten_feed_arms_are_four_separate_screenable_candidates(self):
        # Intent: each of the four kitten arms is its own candidate workload --
        #   collectable, screenable, frozen in the manifest's block contracts, and
        #   incapable of producing a verdict in either mode.
        # Why it exists: research 39 needs a verdict per arm on every Phase 3 fix.
        #   One combined stream would average a win on `csi` against three flat
        #   arms and hide it, and a name that reached `DECISION_RULES` before a
        #   screen ran would be a threshold nobody measured.
        # Scenario: spec-first; the arms land as stimulus first, and a human moves
        #   each screened threshold across separately (research 39 Phase 2 task 2).
        manifest = VALIDATION.make_manifest(seed=2026072402, trials_per_cell=1)
        screenable = set(VALIDATION.WORKLOADS) | set(VALIDATION.CANDIDATE_WORKLOADS)
        for workload, arm in VALIDATION.KITTEN_FEED_ARMS.items():
            with self.subTest(workload=workload):
                self.assertIn(workload, VALIDATION.CANDIDATE_WORKLOADS)
                self.assertNotIn(workload, VALIDATION.WORKLOADS)
                self.assertIn(workload, screenable)
                self.assertEqual(workload, f"kitten-feed-{arm}")
                # Same contract as `terminal-feed`, plus the identity its
                # generated stimulus needs and the committed corpus does not.
                self.assertEqual(
                    manifest["blockContracts"][workload],
                    {
                        "metric": "feed-nanoseconds-per-fresh-terminal-execution",
                        "measuredUnit": "duration-stable-fixed-execution-batch",
                        "minimumBlockNanoseconds": 1_000_000_000,
                        "reset": "fresh-179x66-terminal-per-execution",
                        "stimulusIdentity": (
                            VALIDATION.KITTEN_FEED_FIXTURE_IDENTITIES[workload]
                        ),
                    },
                )
                self.assertEqual(
                    COMPARE.BLOCK_METRICS[workload], "feedDurationNanoseconds"
                )
                with self.assertRaises(ValueError):
                    COMPARE.resolve_workloads("quick", workload)
                self.assertNotIn(workload, COMPARE.resolve_workloads("confirm"))

    def test_each_kitten_feed_arm_carries_its_own_stimulus_identity(self):
        # Intent: the four frozen identities name their own arm, and no two arms
        #   share a digest.
        # Why it exists: a routing error that mapped one workload to another arm's
        #   stream would still collect, still validate, and still report -- it would
        #   just measure the wrong stimulus under a rule frozen for a different one.
        # Scenario: spec-first; four arms generated from one executable, told apart
        #   only by the argument each is generated with.
        identities = VALIDATION.KITTEN_FEED_FIXTURE_IDENTITIES
        self.assertEqual(set(identities), set(VALIDATION.KITTEN_FEED_ARMS))
        self.assertEqual(len(set(identities.values())), len(identities))
        for workload, identity in identities.items():
            with self.subTest(workload=workload):
                self.assertRegex(
                    identity, rf"^{workload}-r\d+-seed\d+-179x66-[0-9a-f]{{64}}$"
                )

    def test_each_sparse_span_workload_names_the_metric_its_defect_moves(self):
        # Intent: `sparse-spans-few` pairs on synchronous draw time and
        #   `sparse-spans-max` on whole-process CPU.
        # Why it exists: the two protect different failures. Losing exact sparse
        #   clipping widens the synchronous draw, which the draw bracket contains;
        #   per-row rectangle emission moves Core Animation clip replay, which
        #   happens after that bracket closes and is invisible to it at any size.
        #   Routing either to the other's metric would measure a workload with an
        #   instrument that structurally cannot see its regression.
        # Scenario: spec-first; research/29/D2 gives each workload the metric that observes
        #   its own failure mode, and that routing is workload-local.
        self.assertEqual(
            COMPARE.BLOCK_METRICS["sparse-spans-few"], "drawNanosecondsPerDraw"
        )
        self.assertEqual(
            COMPARE.BLOCK_METRICS["sparse-spans-max"],
            "processCPUNanosecondsPerDraw",
        )
        # And no existing workload gains CPU verdict authority from that routing.
        for workload in VALIDATION.WORKLOADS:
            self.assertNotEqual(
                COMPARE.BLOCK_METRICS[workload], "processCPUNanosecondsPerDraw"
            )

    def test_the_feed_harness_calibrates_against_the_contract_floor(self):
        # Intent: the floor the Swift harness calibrates against is the same number
        #   every feed block contract judges a block by.
        # Why it exists: the two live in different languages and were equal only by
        #   coincidence. If a contract floor moved, the harness would keep sizing
        #   batches for the old one and every block would be discarded, or -- worse
        #   -- silently accepted after being calibrated against a bar it no longer
        #   has to clear. The margin the harness adds is deliberate and lives in
        #   `measureDurationStable`; this pins only the floor the margin is taken
        #   from.
        # Scenario: spec-first; someone raises `minimumBlockNanoseconds` on the feed
        #   contracts and forgets `blockFloorNanoseconds` in the harness.
        source = (
            ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCoreBenchmark"
            / "main.swift"
        ).read_text(encoding="utf-8")
        declared = re.search(
            r"^let blockFloorNanoseconds: UInt64 = ([0-9_]+)$", source, re.MULTILINE
        )
        self.assertIsNotNone(
            declared, "the feed harness must declare `blockFloorNanoseconds`"
        )
        harness_floor = int(declared.group(1).replace("_", ""))

        floors = {
            workload: contract["minimumBlockNanoseconds"]
            for workload, contract in VALIDATION.BLOCK_CONTRACTS.items()
            if "minimumBlockNanoseconds" in contract
        }
        self.assertEqual(
            set(floors), {"terminal-feed"} | set(VALIDATION.KITTEN_FEED_ARMS)
        )
        for workload, floor in floors.items():
            with self.subTest(workload=workload):
                self.assertEqual(floor, harness_floor)

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
