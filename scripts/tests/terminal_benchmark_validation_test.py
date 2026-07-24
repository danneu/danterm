#!/usr/bin/env python3
"""Behavioral tests for held-out paired benchmark validation."""
import importlib.util
import hashlib
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_validation",
    ROOT / "scripts" / "terminal-benchmark-validation.py",
)
VALIDATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATION)


class TerminalBenchmarkValidationTests(unittest.TestCase):
    def test_manifest_predeclares_disjoint_balanced_trials(self):
        manifest = VALIDATION.make_manifest(seed=2026072402, trials_per_cell=60)

        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(len(manifest["quick"]), 5 * 3 * 60)
        self.assertEqual(len(manifest["confirm"]), (1 + 5 * 2) * 60)
        self.assertEqual(
            {trial["physicalCandidateArm"] for trial in manifest["quick"]},
            {"a", "b"},
        )
        seeds = [
            trial["seed"]
            for mode in ("quick", "confirm")
            for trial in manifest[mode]
        ]
        self.assertEqual(len(seeds), len(set(seeds)))

    def test_manifest_predeclares_replacement_seeds_for_every_trial(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=2,
            replacements_per_trial=3,
        )

        trials = manifest["quick"] + manifest["confirm"]
        all_seeds = [
            seed
            for trial in trials
            for seed in [trial["seed"], *trial["replacementSeeds"]]
        ]
        self.assertTrue(all(len(trial["replacementSeeds"]) == 3 for trial in trials))
        self.assertEqual(len(all_seeds), len(set(all_seeds)))

    def test_attempt_ledger_preserves_invalid_evidence_and_advances_seed(self):
        trial = {
            "id": "quick:terminal-feed:aa:00",
            "seed": 11,
            "replacementSeeds": [12, 13],
        }
        ledger = []

        first = VALIDATION.next_attempt(trial, ledger)
        VALIDATION.record_attempt(
            ledger,
            trial=trial,
            seed=first["seed"],
            valid=False,
            evidence={"block": "raw-first"},
            invalidation_reasons=["ac-power-changed"],
        )
        second = VALIDATION.next_attempt(trial, ledger)

        self.assertEqual(first, {"attempt": 0, "seed": 11})
        self.assertEqual(second, {"attempt": 1, "seed": 12})
        self.assertEqual(ledger[0]["evidence"], {"block": "raw-first"})
        self.assertEqual(ledger[0]["invalidationReasons"], ["ac-power-changed"])

    def test_attempt_ledger_refuses_rerun_after_valid_result_or_exhaustion(self):
        trial = {"id": "quick:terminal-feed:aa:00", "seed": 11, "replacementSeeds": []}
        valid_ledger = []
        VALIDATION.record_attempt(
            valid_ledger,
            trial=trial,
            seed=11,
            valid=True,
            evidence={"block": "raw"},
            invalidation_reasons=[],
        )

        with self.assertRaisesRegex(ValueError, "already has a valid result"):
            VALIDATION.next_attempt(trial, valid_ledger)
        with self.assertRaisesRegex(ValueError, "replacement schedule exhausted"):
            VALIDATION.next_attempt(trial, [{
                "trialId": trial["id"],
                "attempt": 0,
                "seed": 11,
                "valid": False,
                "evidence": {"block": "raw"},
                "invalidationReasons": ["thermal-state-changed"],
            }])

    def test_manifest_freezes_workload_specific_block_contracts(self):
        manifest = VALIDATION.make_manifest(seed=2026072402, trials_per_cell=60)

        contracts = manifest["blockContracts"]
        self.assertEqual(
            contracts["terminal-feed"],
            {
                "metric": "feed-nanoseconds-per-fresh-terminal-execution",
                "measuredUnit": "duration-stable-fixed-execution-batch",
                "minimumBlockNanoseconds": 1_000_000_000,
                "reset": "fresh-80x24-terminal-per-execution",
            },
        )
        self.assertEqual(
            contracts["scrollback-stream"],
            {
                "metric": "final-draw-nanoseconds-per-fixture-replay",
                "measuredUnit": "one-25000-line-fixture-replay",
                "reset": "fresh-optimized-app-and-terminal-session-per-block",
            },
        )
        for workload in ("content-churn", "style-churn", "incremental-mixed"):
            self.assertEqual(contracts[workload]["metric"], "draw-nanoseconds-per-draw")
            self.assertEqual(contracts[workload]["exactCompletedDraws"], 50)
            self.assertEqual(
                contracts[workload]["reset"],
                "settled-dense-screen-before-block",
            )

    def test_manifest_freezes_workload_specific_decision_rules(self):
        manifest = VALIDATION.make_manifest(seed=2026072402, trials_per_cell=60)

        rules = manifest["decisionRules"]
        self.assertEqual(rules["quick"]["estimator"], "median")
        self.assertEqual(rules["quick"]["equivalenceBandPercent"], 1.0)
        self.assertEqual(
            rules["quick"]["workloads"]["content-churn"],
            {"pairCount": 4, "directionalThresholdPercent": 3.2},
        )
        self.assertEqual(
            rules["confirm"]["estimator"], "winsorized-mean-20",
        )
        self.assertEqual(rules["confirm"]["equivalenceBandPercent"], 0.75)
        self.assertEqual(
            rules["confirm"]["workloads"]["incremental-mixed"],
            {"pairCount": 40, "directionalThresholdPercent": 2.1},
        )

    def test_quick_cell_applies_frozen_acceptance_counts(self):
        passing = ["slower"] * 54 + ["inconclusive"] * 6
        failing = ["slower"] * 53 + ["inconclusive"] * 7

        self.assertTrue(
            VALIDATION.evaluate_quick_cell(passing, expected_direction="slower")["pass"]
        )
        self.assertFalse(
            VALIDATION.evaluate_quick_cell(failing, expected_direction="slower")["pass"]
        )

    def test_confirm_effect_cell_rejects_unchanged_workload_claim(self):
        trials = [
            {
                "terminal-feed": "slower",
                "scrollback-stream": "equivalent",
                "content-churn": "equivalent",
                "style-churn": "equivalent",
                "incremental-mixed": "equivalent",
            }
            for _ in range(60)
        ]
        trials[0]["style-churn"] = "faster"

        result = VALIDATION.evaluate_confirm_effect_cell(
            trials,
            injected_workload="terminal-feed",
            expected_direction="slower",
        )

        self.assertFalse(result["pass"])
        self.assertEqual(result["unchangedDirectionalCount"], 1)

    def test_validation_rejects_calibration_seed_or_incomplete_cell(self):
        manifest = VALIDATION.make_manifest(seed=2026072402, trials_per_cell=60)
        trial = dict(manifest["quick"][0])
        trial["decision"] = "equivalent"

        with self.assertRaisesRegex(ValueError, "calibration seed"):
            VALIDATION.validate_results(
                manifest,
                [trial],
                calibration_seeds={trial["seed"]},
            )

        with self.assertRaisesRegex(ValueError, "missing"):
            VALIDATION.validate_results(manifest, [trial], calibration_seeds=set())

    def test_validation_accepts_only_the_declared_seed_for_each_completed_trial(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=1,
            replacements_per_trial=1,
        )
        results = [
            {
                **trial,
                "seed": trial["replacementSeeds"][0],
                "decision": "equivalent",
            }
            for mode in ("quick", "confirm")
            for trial in manifest[mode]
        ]

        self.assertTrue(
            VALIDATION.validate_results(
                manifest,
                results,
                calibration_seeds=set(),
            )
        )
        results[0]["seed"] = 2**63
        with self.assertRaisesRegex(ValueError, "undeclared seed"):
            VALIDATION.validate_results(
                manifest,
                results,
                calibration_seeds=set(),
            )

    def test_collection_plan_uses_complete_quartets_without_exposing_condition(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=1,
            replacements_per_trial=1,
        )
        quick_trial = next(
            trial for trial in manifest["quick"]
            if trial["workload"] == "content-churn"
        )
        confirm_trial = next(
            trial for trial in manifest["confirm"]
            if trial["workload"] == "terminal-feed"
        )

        quick = VALIDATION.make_collection_plan(
            manifest, quick_trial, quick_trial["seed"]
        )
        confirm = VALIDATION.make_collection_plan(
            manifest, confirm_trial, confirm_trial["seed"]
        )

        self.assertEqual(list(quick), ["content-churn"])
        self.assertEqual(list(confirm), list(VALIDATION.WORKLOADS))
        self.assertNotIn("condition", json.dumps(quick))
        for workload, blocks in quick.items():
            rule = manifest["decisionRules"]["quick"]["workloads"][workload]
            self.assertEqual(len(blocks), rule["pairCount"] * 2)
            for offset in range(0, len(blocks), 4):
                quartet = "".join(
                    block["measurementRole"] for block in blocks[offset:offset + 4]
                )
                self.assertIn(quartet, ("ABBA", "BAAB"))
        for workload, blocks in confirm.items():
            rule = manifest["decisionRules"]["confirm"]["workloads"][workload]
            self.assertEqual(len(blocks), rule["pairCount"] * 2)
            self.assertTrue(all(
                block["physicalArm"] in ("a", "b") for block in blocks
            ))

    def test_collection_resume_hash_pins_manifest_and_advances_invalid_attempt(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=1,
            replacements_per_trial=1,
        )
        manifest_bytes = (
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        ).encode()
        expected_hash = hashlib.sha256(manifest_bytes).hexdigest()

        with tempfile.TemporaryDirectory() as directory:
            manifest_path = pathlib.Path(directory) / "manifest.json"
            ledger_path = pathlib.Path(directory) / "attempts.jsonl"
            manifest_path.write_bytes(manifest_bytes)
            loaded = VALIDATION.load_collection(
                manifest_path, ledger_path, expected_manifest_sha256=expected_hash
            )
            first = VALIDATION.next_collection_attempt(
                loaded["manifest"], loaded["ledger"]
            )
            VALIDATION.append_collection_attempt(
                ledger_path,
                loaded["ledger"],
                trial=first["trial"],
                seed=first["seed"],
                valid=False,
                evidence={"rawBlocks": [{"durationNanoseconds": 10}]},
                invalidation_reasons=["thermal-state-changed"],
            )
            resumed = VALIDATION.load_collection(
                manifest_path, ledger_path, expected_manifest_sha256=expected_hash
            )
            replacement = VALIDATION.next_collection_attempt(
                resumed["manifest"], resumed["ledger"]
            )

            self.assertEqual(replacement["trial"]["id"], first["trial"]["id"])
            self.assertEqual(
                replacement["seed"], first["trial"]["replacementSeeds"][0]
            )
            self.assertEqual(len(resumed["ledger"]), 1)
            with self.assertRaisesRegex(ValueError, "manifest SHA-256"):
                VALIDATION.load_collection(
                    manifest_path, ledger_path,
                    expected_manifest_sha256="0" * 64,
                )

    def test_collection_resume_rejects_tampered_or_out_of_order_ledger(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=1,
            replacements_per_trial=1,
        )
        trial = manifest["quick"][0]
        bad_entry = {
            "trialId": trial["id"],
            "attempt": 1,
            "seed": trial["replacementSeeds"][0],
            "valid": False,
            "evidence": {"rawBlocks": []},
            "invalidationReasons": ["window-occluded"],
        }

        with tempfile.TemporaryDirectory() as directory:
            manifest_path = pathlib.Path(directory) / "manifest.json"
            ledger_path = pathlib.Path(directory) / "attempts.jsonl"
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n"
            )
            ledger_path.write_text(json.dumps(bad_entry) + "\n")

            with self.assertRaisesRegex(ValueError, "expected seed"):
                VALIDATION.load_collection(manifest_path, ledger_path)

    def test_terminal_feed_collector_calibrates_once_and_retains_raw_block_evidence(self):
        blocks = [
            {"measurementRole": "A", "physicalArm": "a"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "A", "physicalArm": "a"},
        ]
        calls = []
        totals = iter((1_200_000_000, 1_100_000_000, 1_300_000_000,
                       1_250_000_000))

        def run_benchmark(arm, *, execution_count):
            calls.append((arm, execution_count))
            if execution_count is None:
                return {
                    "batchCount": 4,
                    "feedDurationNanoseconds": [300_000_000, 310_000_000],
                    "sampleDurationNanoseconds": [1_200_000_000, 1_240_000_000],
                }
            total = next(totals)
            return {
                "batchCount": execution_count,
                "feedDurationNanoseconds": [total // execution_count],
                "sampleDurationNanoseconds": [total],
            }

        evidence = VALIDATION.collect_terminal_feed(
            blocks,
            minimum_block_nanoseconds=1_000_000_000,
            run_benchmark=run_benchmark,
            sample_state=lambda: {
                "powerSource": "AC Power",
                "lowPowerMode": False,
                "thermalState": "nominal",
            },
        )

        self.assertEqual(calls[0], ("a", None))
        self.assertEqual(calls[1:], [("a", 4), ("b", 4), ("b", 4), ("a", 4)])
        self.assertEqual(len(evidence["calibration"]["discardedSamples"]), 2)
        self.assertEqual(
            [block["sampleDurationNanoseconds"] for block in evidence["rawBlocks"]],
            [1_200_000_000, 1_100_000_000, 1_300_000_000, 1_250_000_000],
        )
        self.assertTrue(evidence["valid"])
        self.assertEqual(evidence["invalidationReasons"], [])

    def test_terminal_feed_collector_keeps_short_and_state_changed_blocks_invalid(self):
        states = iter((
            {"powerSource": "AC Power", "lowPowerMode": False,
             "thermalState": "nominal"},
            {"powerSource": "Battery Power", "lowPowerMode": False,
             "thermalState": "nominal"},
        ))

        evidence = VALIDATION.collect_terminal_feed(
            [{"measurementRole": "A", "physicalArm": "a"}],
            minimum_block_nanoseconds=1_000_000_000,
            run_benchmark=lambda arm, *, execution_count: (
                {
                    "batchCount": 4,
                    "feedDurationNanoseconds": [300_000_000, 310_000_000],
                    "sampleDurationNanoseconds": [1_200_000_000, 1_240_000_000],
                }
                if execution_count is None else
                {
                    "batchCount": 4,
                    "feedDurationNanoseconds": [225_000_000],
                    "sampleDurationNanoseconds": [900_000_000],
                }
            ),
            sample_state=lambda: next(states),
        )

        self.assertFalse(evidence["valid"])
        self.assertEqual(
            evidence["invalidationReasons"],
            ["block-0-below-duration-floor", "block-0-power-source-changed"],
        )
        self.assertEqual(evidence["rawBlocks"][0]["sampleDurationNanoseconds"],
                         900_000_000)

    def test_scrollback_collector_retains_fresh_session_marker_to_draw_evidence(self):
        blocks = [
            {"measurementRole": "A", "physicalArm": "a"},
            {"measurementRole": "B", "physicalArm": "b"},
        ]
        calls = []

        def run_block(arm):
            calls.append(arm)
            ordinal = len(calls)
            return {
                "schemaVersion": 1,
                "backend": "swift",
                "workload": "scrollback-stream",
                "fixtureIdentity": "scrollback-stream-v1-25000-lines",
                "processId": 100 + ordinal,
                "sessionId": f"pane-{ordinal}",
                "geometry": {"columns": 80, "rows": 24},
                "producerWrite": {
                    "event": "producer-final-write-returned",
                    "elapsedNanoseconds": 290_000_000 + ordinal,
                },
                "finalDraw": {
                    "available": True,
                    "event": "final-draw-completed",
                    "startMarker": f"DANTERM-BENCH-START-{ordinal}",
                    "expectedFinalState":
                        f"DANTERM-BENCH-FINAL-STATE-{ordinal}",
                    "elapsedNanoseconds": 305_000_000 + ordinal,
                    "machineStateSamples": [
                        {
                            "activeSpaceChanged": False,
                            "lowPowerMode": False,
                            "thermalState": "nominal",
                            "visible": True,
                        },
                        {
                            "activeSpaceChanged": False,
                            "lowPowerMode": False,
                            "thermalState": "nominal",
                            "visible": True,
                        },
                    ],
                },
            }

        evidence = VALIDATION.collect_scrollback_stream(
            blocks, run_block=run_block
        )

        self.assertEqual(calls, ["a", "b"])
        self.assertTrue(evidence["valid"])
        self.assertEqual(
            [block["finalDrawNanoseconds"] for block in evidence["rawBlocks"]],
            [305_000_001, 305_000_002],
        )
        self.assertEqual(
            [block["processId"] for block in evidence["rawBlocks"]],
            [101, 102],
        )
        self.assertEqual(
            evidence["rawBlocks"][0]["startMarker"],
            "DANTERM-BENCH-START-1",
        )

    def test_scrollback_collector_invalidates_bad_contract_without_dropping_raw_block(self):
        artifact = {
            "schemaVersion": 1,
            "backend": "swift",
            "workload": "scrollback-stream",
            "fixtureIdentity": "wrong-fixture",
            "processId": 101,
            "sessionId": "pane-1",
            "geometry": {"columns": 80, "rows": 24},
            "producerWrite": {
                "event": "producer-final-write-returned",
                "elapsedNanoseconds": 310_000_000,
            },
            "finalDraw": {
                "available": True,
                "event": "final-draw-completed",
                "startMarker": "wrong-start",
                "expectedFinalState": "wrong-final",
                "elapsedNanoseconds": 300_000_000,
                "machineStateSamples": [{
                    "activeSpaceChanged": True,
                    "lowPowerMode": False,
                    "thermalState": "nominal",
                    "visible": True,
                }],
            },
        }

        evidence = VALIDATION.collect_scrollback_stream(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertFalse(evidence["valid"])
        self.assertEqual(evidence["rawBlocks"][0]["artifact"], artifact)
        self.assertEqual(
            evidence["invalidationReasons"],
            [
                "block-0-wrong-fixture",
                "block-0-invalid-start-marker",
                "block-0-invalid-final-state-marker",
                "block-0-final-draw-preceded-producer-write",
                "block-0-active-space-changed",
            ],
        )

    def test_content_churn_collector_retains_settled_serialized_draw_evidence(self):
        blocks = [
            {"measurementRole": "A", "physicalArm": "a"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "A", "physicalArm": "a"},
        ]
        calls = []

        def run_block(arm):
            calls.append(arm)
            ordinal = len(calls)
            durations = [300_000 + ordinal] * 50
            return {
                "backend": "swift",
                "workload": "full-screen-content-churn",
                "fixtureIdentity": "full-screen-content-churn",
                "processId": {"a": 101, "b": 202}[arm],
                "sessionId": {"a": "pane-a", "b": "pane-b"}[arm],
                "geometry": {"columns": 80, "rows": 24},
                "resetEvidence": {
                    "denseSetupAndStartDrawCompleted": True,
                    "settlingDrawCompleted": True,
                },
                "producerWrite": {
                    "event": "producer-final-write-returned",
                    "elapsedNanoseconds": 400_000_000,
                },
                "finalDraw": {
                    "available": True,
                    "event": "final-draw-completed",
                    "startMarker": f"DANTERM-BENCH-START-{ordinal}",
                    "expectedFinalState":
                        f"DANTERM-BENCH-FINAL-STATE-{ordinal}",
                    "elapsedNanoseconds": 410_000_000,
                    "drawCount": 50,
                    "cumulativeDrawNanoseconds": sum(durations),
                    "drawSequences": list(range(1, 51)),
                    "drawDurationsNanoseconds": durations,
                    "dirtyRowCounts": [24] * 50,
                    "machineStateSamples": [{
                        "activeSpaceChanged": False,
                        "lowPowerMode": False,
                        "thermalState": "nominal",
                        "visible": True,
                    }],
                },
            }

        evidence = VALIDATION.collect_content_churn(
            blocks, run_block=run_block
        )

        self.assertEqual(calls, ["a", "b", "b", "a"])
        self.assertTrue(evidence["valid"])
        self.assertEqual(
            [block["drawNanosecondsPerDraw"]
             for block in evidence["rawBlocks"]],
            [300_001, 300_002, 300_003, 300_004],
        )
        self.assertEqual(
            [block["processId"] for block in evidence["rawBlocks"]],
            [101, 202, 202, 101],
        )
        self.assertTrue(
            evidence["rawBlocks"][0]["resetEvidence"][
                "settlingDrawCompleted"
            ]
        )

    def test_content_churn_collector_invalidates_bad_draw_contract_without_dropping_raw_block(self):
        artifact = {
            "backend": "swift",
            "workload": "full-screen-content-churn",
            "fixtureIdentity": "full-screen-content-churn",
            "processId": 101,
            "sessionId": "pane-a",
            "geometry": {"columns": 80, "rows": 24},
            "resetEvidence": {
                "denseSetupAndStartDrawCompleted": True,
                "settlingDrawCompleted": False,
            },
            "producerWrite": {
                "event": "producer-final-write-returned",
                "elapsedNanoseconds": 400_000_000,
            },
            "finalDraw": {
                "available": True,
                "event": "final-draw-completed",
                "startMarker": "DANTERM-BENCH-START-1",
                "expectedFinalState": "DANTERM-BENCH-FINAL-STATE-1",
                "elapsedNanoseconds": 410_000_000,
                "drawCount": 49,
                "cumulativeDrawNanoseconds": 15_000_000,
                "drawSequences": list(range(1, 50)),
                "drawDurationsNanoseconds": [300_000] * 49,
                "dirtyRowCounts": [24] * 48 + [23],
                "machineStateSamples": [],
            },
        }

        evidence = VALIDATION.collect_content_churn(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertFalse(evidence["valid"])
        self.assertEqual(evidence["rawBlocks"][0]["artifact"], artifact)
        self.assertEqual(
            evidence["invalidationReasons"],
            [
                "block-0-reset-not-settled",
                "block-0-wrong-draw-count",
                "block-0-draw-sequence-contract-violated",
                "block-0-cumulative-draw-mismatch",
                "block-0-incomplete-full-row-damage",
                "block-0-missing-machine-state",
            ],
        )


if __name__ == "__main__":
    unittest.main()
