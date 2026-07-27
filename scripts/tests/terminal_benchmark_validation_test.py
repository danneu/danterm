#!/usr/bin/env python3
"""Behavioral tests for held-out paired benchmark validation."""
import importlib.util
import hashlib
import io
import json
import pathlib
import signal
import subprocess
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

        first = VALIDATION.next_attempt(trial, ledger, collection_index=0)
        VALIDATION.record_attempt(
            ledger,
            trial=trial,
            collection_index=0,
            seed=first["seed"],
            valid=False,
            evidence={"block": "raw-first"},
            invalidation_reasons=["ac-power-changed"],
        )
        second = VALIDATION.next_attempt(trial, ledger, collection_index=0)

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
            collection_index=0,
            seed=11,
            valid=True,
            evidence={"block": "raw"},
            invalidation_reasons=[],
        )

        with self.assertRaisesRegex(ValueError, "already has a valid result"):
            VALIDATION.next_attempt(trial, valid_ledger, collection_index=0)
        with self.assertRaisesRegex(ValueError, "replacement schedule exhausted"):
            VALIDATION.next_attempt(trial, [{
                "collectionIndex": 0,
                "attempt": 0,
                "seed": 11,
                "valid": False,
                "evidence": {"block": "raw"},
                "invalidationReasons": ["thermal-state-changed"],
            }], collection_index=0)

    def test_manifest_freezes_workload_specific_block_contracts(self):
        manifest = VALIDATION.make_manifest(seed=2026072402, trials_per_cell=60)

        contracts = manifest["blockContracts"]
        self.assertEqual(
            contracts["terminal-feed"],
            {
                "metric": "feed-nanoseconds-per-fresh-terminal-execution",
                "measuredUnit": "duration-stable-fixed-execution-batch",
                "minimumBlockNanoseconds": 1_000_000_000,
                "reset": "fresh-179x66-terminal-per-execution",
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
            {"pairCount": 2, "directionalThresholdPercent": 4.05},
        )
        self.assertEqual(
            rules["confirm"]["estimator"], "median",
        )
        self.assertEqual(rules["confirm"]["equivalenceBandPercent"], 0.75)
        self.assertEqual(
            rules["confirm"]["workloads"]["incremental-mixed"],
            {"pairCount": 6, "directionalThresholdPercent": 1.85},
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
                collection_index=first["collectionIndex"],
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
            "collectionIndex": 0,
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

    def test_terminal_feed_state_sampler_compiles_once_and_samples_process_and_power_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            calls = []

            def run(command, **kwargs):
                calls.append((command, kwargs))
                if command[0:2] == ["xcrun", "swiftc"]:
                    return subprocess.CompletedProcess(command, 0, "", "")
                if command[0] == str(root / "terminal-feed-state-probe"):
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        '{"thermalState":"nominal","lowPowerMode":false}\n',
                        "",
                    )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    "Now drawing from 'AC Power'\n"
                    " -InternalBattery-0\t100%; discharging; present: true\n",
                    "",
                )

            sample = VALIDATION.make_terminal_feed_state_sampler(
                root,
                source_path=root / "probe.swift",
                run_command=run,
            )
            first = sample()
            second = sample()

            self.assertEqual(first, {
                "powerSource": "AC Power",
                "thermalState": "nominal",
                "lowPowerMode": False,
            })
            self.assertEqual(second, first)
            self.assertEqual(
                [call[0][0:2] for call in calls].count(["xcrun", "swiftc"]),
                1,
            )
            self.assertEqual(
                [call[0] for call in calls[1:]],
                [
                    [str(root / "terminal-feed-state-probe")],
                    ["pmset", "-g", "batt"],
                    [str(root / "terminal-feed-state-probe")],
                    ["pmset", "-g", "batt"],
                ],
            )

    def test_terminal_feed_state_sampler_rejects_unrecognized_power_output(self):
        def run(command, **_kwargs):
            if command[0:2] == ["xcrun", "swiftc"]:
                return subprocess.CompletedProcess(command, 0, "", "")
            if command[0].endswith("terminal-feed-state-probe"):
                return subprocess.CompletedProcess(
                    command,
                    0,
                    '{"thermalState":"nominal","lowPowerMode":false}',
                    "",
                )
            return subprocess.CompletedProcess(command, 0, "power unavailable", "")

        with tempfile.TemporaryDirectory() as directory:
            sample = VALIDATION.make_terminal_feed_state_sampler(
                directory,
                source_path=pathlib.Path(directory) / "probe.swift",
                run_command=run,
            )

            with self.assertRaisesRegex(ValueError, "power source"):
                sample()

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
                "geometry": {"columns": 179, "rows": 66},
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
            "geometry": {"columns": 179, "rows": 66},
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
                "geometry": {"columns": 179, "rows": 66},
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
                    "drawSequences": list(range(50)),
                    "drawDurationsNanoseconds": durations,
                    "dirtyRowCounts": [66] * 50,
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
            "geometry": {"columns": 179, "rows": 66},
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
                "drawSequences": list(range(49)),
                "drawDurationsNanoseconds": [300_000] * 49,
                "dirtyRowCounts": [66] * 48 + [65],
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

    def test_style_churn_collector_requires_full_screen_damage(self):
        artifact = self._draw_churn_artifact(
            workload="full-screen-style-churn",
            fixture="full-screen-style-churn",
            dirty_rows=66,
        )

        evidence = VALIDATION.collect_style_churn(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertTrue(evidence["valid"])
        self.assertEqual(evidence["workload"], "style-churn")
        self.assertEqual(
            evidence["rawBlocks"][0]["drawNanosecondsPerDraw"],
            300_000,
        )

    def test_draw_churn_collectors_normalize_reported_plan_time_per_draw(self):
        # Intent: when the app reports plan timings, each block carries a
        #   `planNanosecondsPerDraw` normalized over the same 50 draws as
        #   `drawNanosecondsPerDraw`.
        # Why it exists: the serialized-draw metric brackets only clipping and
        #   drawing, so planner work is invisible to it. Normalizing plan time
        #   by the same divisor is what makes the two directly comparable rather
        #   than two quantities with different denominators.
        # Scenario: spec-first -- a block whose 50 accepted draws each cost
        #   300us to draw and 900us to plan.
        for collect, workload, fixture, dirty_rows in (
            (VALIDATION.collect_content_churn, "full-screen-content-churn",
             "full-screen-content-churn", 66),
            (VALIDATION.collect_style_churn, "full-screen-style-churn",
             "full-screen-style-churn", 66),
            (VALIDATION.collect_incremental_mixed,
             "full-screen-incremental-mixed-churn",
             "full-screen-incremental-mixed-churn-"
             "v2-four-rows-six-damage-179x66", 6),
        ):
            with self.subTest(workload=workload):
                artifact = self._draw_churn_artifact(
                    workload=workload, fixture=fixture, dirty_rows=dirty_rows
                )
                plans = [900_000] * 50
                artifact["finalDraw"]["planCount"] = 50
                artifact["finalDraw"]["cumulativePlanNanoseconds"] = sum(plans)
                artifact["finalDraw"]["planDurationsNanoseconds"] = plans

                evidence = collect(
                    [{"measurementRole": "A", "physicalArm": "a"}],
                    run_block=lambda arm: artifact,
                )

                self.assertTrue(evidence["valid"])
                self.assertEqual(
                    evidence["rawBlocks"][0]["planNanosecondsPerDraw"], 900_000
                )

    def test_a_block_without_plan_timings_stays_valid_and_reports_none(self):
        # Intent: an artifact produced before the plan timer existed collects,
        #   validates, and simply reports no plan metric.
        # Why it exists: every paired comparison builds its baseline arm from an
        #   older revision, so missing plan evidence is the normal state of one
        #   arm rather than an error. Inventing a zero would fabricate an effect
        #   and adding an invalidation reason would void real comparisons.
        # Scenario: spec-first -- the exact artifact shape the app emitted before
        #   this change.
        artifact = self._draw_churn_artifact(
            workload="full-screen-content-churn",
            fixture="full-screen-content-churn",
            dirty_rows=66,
        )

        evidence = VALIDATION.collect_content_churn(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertTrue(evidence["valid"])
        self.assertEqual(evidence["invalidationReasons"], [])
        self.assertIsNone(evidence["rawBlocks"][0]["planNanosecondsPerDraw"])

    def test_incremental_mixed_collector_requires_six_row_halo_damage(self):
        artifact = self._draw_churn_artifact(
            workload="full-screen-incremental-mixed-churn",
            fixture=(
                "full-screen-incremental-mixed-churn-"
                "v2-four-rows-six-damage-179x66"
            ),
            dirty_rows=6,
        )

        evidence = VALIDATION.collect_incremental_mixed(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertTrue(evidence["valid"])
        self.assertEqual(evidence["workload"], "incremental-mixed")
        artifact["finalDraw"]["dirtyRowCounts"][-1] = 4
        invalid = VALIDATION.collect_incremental_mixed(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )
        self.assertEqual(
            invalid["invalidationReasons"],
            ["block-0-wrong-damage-row-count"],
        )

    def test_attempt_collector_runs_every_planned_workload_without_exposing_condition(self):
        calls = []
        plan = {
            workload: [{"measurementRole": "A", "physicalArm": "a"}]
            for workload in VALIDATION.WORKLOADS
        }
        collectors = {}
        for workload in VALIDATION.WORKLOADS:
            def collect(blocks, workload=workload):
                calls.append((workload, blocks))
                return {
                    "workload": workload,
                    "rawBlocks": [{"measurementRole": "A"}],
                    "valid": workload != "style-churn",
                    "invalidationReasons": (
                        ["block-0-window-occluded"]
                        if workload == "style-churn" else []
                    ),
                }
            collectors[workload] = collect

        evidence = VALIDATION.collect_attempt(plan, collectors=collectors)

        self.assertEqual([workload for workload, _ in calls], list(plan))
        self.assertNotIn("condition", str(evidence))
        self.assertFalse(evidence["valid"])
        self.assertEqual(
            evidence["invalidationReasons"],
            ["style-churn:block-0-window-occluded"],
        )
        self.assertEqual(set(evidence["workloads"]), set(plan))

    def test_collect_next_attempt_hash_pins_appends_and_returns_condition_free_status(self):
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
            root = pathlib.Path(directory)
            manifest_path = root / "manifest.json"
            ledger_path = root / "attempts.jsonl"
            manifest_path.write_bytes(manifest_bytes)
            closed = []

            def make_collectors(plan, attempt_directory):
                self.assertEqual(set(plan), {"terminal-feed"})
                self.assertEqual(
                    attempt_directory.name,
                    "collection-000000-attempt-00",
                )
                return ({
                    "terminal-feed": lambda blocks: {
                        "workload": "terminal-feed",
                        "rawBlocks": [{**blocks[0], "durationNanoseconds": 10}],
                        "valid": True,
                        "invalidationReasons": [],
                    },
                }, lambda: closed.append(True))

            status = VALIDATION.collect_next_attempt(
                manifest_path,
                ledger_path,
                expected_manifest_sha256=expected_hash,
                artifacts_root=root / "artifacts",
                make_collectors=make_collectors,
            )

            self.assertEqual(status["collectionIndex"], 0)
            self.assertEqual(status["attempt"], 0)
            self.assertEqual(status["seed"], manifest["quick"][0]["seed"])
            self.assertTrue(status["valid"])
            self.assertNotIn("condition", json.dumps(status))
            self.assertEqual(closed, [True])
            entries = [
                json.loads(line)
                for line in ledger_path.read_text().splitlines()
            ]
            self.assertEqual(len(entries), 1)
            self.assertEqual(
                entries[0]["collectionIndex"],
                status["collectionIndex"],
            )

    def test_collect_next_attempt_keeps_semantic_trial_identity_out_of_collection_surfaces(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=1,
            replacements_per_trial=1,
        )
        manifest_bytes = (
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        ).encode()

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = root / "manifest.json"
            ledger_path = root / "attempts.jsonl"
            manifest_path.write_bytes(manifest_bytes)
            attempt_directories = []

            def make_collectors(plan, attempt_directory):
                attempt_directories.append(attempt_directory)
                return ({
                    "terminal-feed": lambda blocks: {
                        "workload": "terminal-feed",
                        "rawBlocks": blocks,
                        "valid": True,
                        "invalidationReasons": [],
                    },
                }, lambda: None)

            status = VALIDATION.collect_next_attempt(
                manifest_path,
                ledger_path,
                expected_manifest_sha256=hashlib.sha256(
                    manifest_bytes
                ).hexdigest(),
                artifacts_root=root / "artifacts",
                make_collectors=make_collectors,
            )

            collection_surfaces = json.dumps({
                "status": status,
                "artifact": attempt_directories[0].name,
                "ledger": json.loads(ledger_path.read_text()),
            })
            semantic_id = manifest["quick"][0]["id"]
            self.assertNotIn(semantic_id, collection_surfaces)
            self.assertNotIn(manifest["quick"][0]["condition"], collection_surfaces)
            self.assertNotIn("trialId", collection_surfaces)
            self.assertEqual(status["collectionIndex"], 0)
            self.assertEqual(
                attempt_directories[0].name,
                "collection-000000-attempt-00",
            )

    def test_collect_next_attempt_closes_without_appending_incomplete_evidence(self):
        manifest = VALIDATION.make_manifest(
            seed=2026072402,
            trials_per_cell=1,
            replacements_per_trial=1,
        )
        manifest_bytes = (
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        ).encode()

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = root / "manifest.json"
            ledger_path = root / "attempts.jsonl"
            manifest_path.write_bytes(manifest_bytes)
            closed = []

            def make_collectors(_plan, _attempt_directory):
                def fail(_blocks):
                    raise RuntimeError("interrupted block")

                return ({
                    "terminal-feed": fail,
                }, lambda: closed.append(True))

            with self.assertRaisesRegex(RuntimeError, "interrupted block"):
                VALIDATION.collect_next_attempt(
                    manifest_path,
                    ledger_path,
                    expected_manifest_sha256=hashlib.sha256(
                        manifest_bytes
                    ).hexdigest(),
                    artifacts_root=root / "artifacts",
                    make_collectors=make_collectors,
                )

            self.assertEqual(closed, [True])
            self.assertFalse(ledger_path.exists())

    def test_collect_one_command_binds_production_dependencies_and_prints_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            calls = []
            stdout = io.StringIO()

            def collect(
                manifest_path,
                ledger_path,
                *,
                expected_manifest_sha256,
                artifacts_root,
                make_collectors,
            ):
                plan = {"terminal-feed": [{"physicalArm": "a"}]}
                attempt_directory = artifacts_root / "attempt-00"
                collectors, close = make_collectors(plan, attempt_directory)
                calls.append((
                    manifest_path,
                    ledger_path,
                    expected_manifest_sha256,
                    artifacts_root,
                    collectors,
                    close,
                ))
                return {
                    "complete": False,
                    "collectionIndex": 0,
                    "valid": True,
                }

            def make_sampler(output):
                calls.append(("sampler", output))
                return lambda: {"thermalState": "nominal"}

            def make_production(
                plan,
                attempt_directory,
                *,
                arm_roots,
                repository_root,
                sample_state,
            ):
                calls.append((
                    "production",
                    plan,
                    attempt_directory,
                    arm_roots,
                    repository_root,
                    sample_state(),
                ))
                return {"terminal-feed": object()}, lambda: None

            exit_code = VALIDATION.main(
                [
                    "collect-one",
                    "--manifest", str(root / "manifest.json"),
                    "--manifest-sha256", "frozen-hash",
                    "--ledger", str(root / "attempts.jsonl"),
                    "--artifacts", str(root / "artifacts"),
                    "--arm-a-root", str(root / "a"),
                    "--arm-b-root", str(root / "b"),
                    "--repository-root", str(root / "repository"),
                ],
                collect_next=collect,
                state_sampler_factory=make_sampler,
                production_collectors_factory=make_production,
                stdout=stdout,
            )

            self.assertEqual(exit_code, 0)
            self.assertEqual(
                json.loads(stdout.getvalue()),
                {
                    "complete": False,
                    "collectionIndex": 0,
                    "valid": True,
                },
            )
            self.assertEqual(calls[0][0], "sampler")
            self.assertEqual(
                calls[0][1],
                root / "artifacts" / "attempt-00" / "terminal-feed-state",
            )
            self.assertEqual(calls[1][0], "production")
            self.assertEqual(
                calls[1][3],
                {"a": root / "a", "b": root / "b"},
            )
            self.assertEqual(calls[2][2], "frozen-hash")

    def test_collect_one_command_does_not_compile_feed_probe_for_draw_only_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)

            def collect(
                _manifest,
                _ledger,
                *,
                expected_manifest_sha256,
                artifacts_root,
                make_collectors,
            ):
                collectors, close = make_collectors(
                    {"style-churn": [{"physicalArm": "b"}]},
                    artifacts_root / "attempt-00",
                )
                close()
                self.assertEqual(set(collectors), {"style-churn"})
                return {"complete": True}

            VALIDATION.main(
                [
                    "collect-one",
                    "--manifest", str(root / "manifest.json"),
                    "--manifest-sha256", "frozen-hash",
                    "--ledger", str(root / "attempts.jsonl"),
                    "--artifacts", str(root / "artifacts"),
                    "--arm-a-root", str(root / "a"),
                    "--arm-b-root", str(root / "b"),
                ],
                collect_next=collect,
                state_sampler_factory=lambda _output: self.fail(
                    "draw-only attempts must not compile the feed state probe"
                ),
                production_collectors_factory=lambda *args, **kwargs: (
                    {"style-churn": object()},
                    lambda: None,
                ),
                stdout=io.StringIO(),
            )

    def test_production_collectors_bind_only_the_planned_feed_workload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            feed_runs = []

            collectors, close = VALIDATION.make_production_collectors(
                {"terminal-feed": [{"physicalArm": "a"}]},
                root / "attempt",
                arm_roots={"a": root / "a", "b": root / "b"},
                repository_root=root,
                sample_state=lambda: {"state": "sample"},
                load_feed_fixture=lambda _root: b"framed",
                feed_runner_factory=lambda roots, fixture: (
                    lambda arm, *, execution_count: feed_runs.append(
                        (roots, fixture, arm, execution_count)
                    )
                ),
                lifecycle_factory=lambda *args, **kwargs: self.fail(
                    "feed-only collection must not launch draw apps"
                ),
            )

            close()

            self.assertEqual(set(collectors), {"terminal-feed"})
            self.assertEqual(feed_runs, [])

    def test_production_collectors_start_workload_specific_draw_lifecycles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            started = []
            closed = []

            class Lifecycle:
                def __init__(self, _roots, *, workload, output):
                    self.workload = workload
                    self.output = output

                def start(self):
                    started.append((self.workload, self.output.name))
                    return {
                        "a": {"pid": len(started) * 10 + 1},
                        "b": {"pid": len(started) * 10 + 2},
                    }

                def close(self):
                    closed.append(self.workload)

            plan = {
                "content-churn": [{"physicalArm": "a"}],
                "style-churn": [{"physicalArm": "b"}],
                "incremental-mixed": [{"physicalArm": "a"}],
            }
            collectors, close = VALIDATION.make_production_collectors(
                plan,
                root / "attempt",
                arm_roots={"a": root / "a", "b": root / "b"},
                repository_root=root,
                sample_state=lambda: {},
                lifecycle_factory=Lifecycle,
                draw_runner_factory=lambda identities, *, workload, root: (
                    lambda arm: {
                        "identityPid": identities[arm]["pid"],
                        "workload": workload,
                    }
                ),
            )

            close()

            self.assertEqual(set(collectors), set(plan))
            self.assertEqual(
                [item[0] for item in started],
                [
                    "full-screen-content-churn",
                    "full-screen-style-churn",
                    "full-screen-incremental-mixed-churn",
                ],
            )
            self.assertEqual(
                closed,
                [
                    "full-screen-incremental-mixed-churn",
                    "full-screen-style-churn",
                    "full-screen-content-churn",
                ],
            )

    def test_production_collectors_close_started_lifecycle_on_startup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            closed = []

            class Lifecycle:
                def __init__(self, _roots, *, workload, output):
                    self.workload = workload

                def start(self):
                    if self.workload == "full-screen-style-churn":
                        raise RuntimeError("style startup failed")
                    return {"a": {"pid": 1}, "b": {"pid": 2}}

                def close(self):
                    closed.append(self.workload)

            with self.assertRaisesRegex(RuntimeError, "style startup failed"):
                VALIDATION.make_production_collectors(
                    {
                        "content-churn": [{"physicalArm": "a"}],
                        "style-churn": [{"physicalArm": "b"}],
                    },
                    root / "attempt",
                    arm_roots={"a": root / "a", "b": root / "b"},
                    repository_root=root,
                    sample_state=lambda: {},
                    lifecycle_factory=Lifecycle,
                    draw_runner_factory=lambda *args, **kwargs: lambda arm: {},
                )

            self.assertEqual(
                closed,
                [
                    "full-screen-style-churn",
                    "full-screen-content-churn",
                ],
            )

    def test_persistent_draw_runner_reopens_block_and_retains_reset_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            stale = (
                "start-ack",
                "start-draw-ack",
                "ready-draw-ack",
                "final-draw.json",
                "block-state.json",
                "producer-write.json",
                "localized-draw-000000",
            )
            for name in stale:
                (artifacts / name).write_text("stale")
            identity = {
                "pid": 101,
                "artifacts": str(artifacts),
                "binary": str(root / "DanTerm Benchmark.app/Contents/MacOS/DanTerm Benchmark"),
                "geometry": {"columns": 179, "rows": 66},
            }
            sent = []

            def send_input(_identity, pane, arguments):
                sent.append((pane, arguments))
                if arguments == ["--", "Enter"]:
                    (artifacts / "start-draw-ack").touch()
                    (artifacts / "ready-draw-ack").touch()
                    (artifacts / "producer-write.json").write_text(json.dumps({
                        "event": "producer-final-write-returned",
                        "elapsedNanoseconds": 20,
                    }))
                    (artifacts / "final-draw.json").write_text(json.dumps({
                        "event": "final-draw-completed",
                        "drawCount": 50,
                    }))

            runner = VALIDATION.make_persistent_draw_runner(
                {"a": identity, "b": {**identity, "pid": 202}},
                workload="full-screen-style-churn",
                root=root,
                resolve_pane=lambda _identity: "pane-a",
                send_input=send_input,
                front_app=lambda pid: self.assertEqual(pid, 101),
                wait_for_path=lambda path, **_options: self.assertTrue(path.exists()),
            )

            artifact = runner("a")

            self.assertEqual(artifact["processId"], 101)
            self.assertEqual(artifact["sessionId"], "pane-a")
            self.assertEqual(artifact["workload"], "full-screen-style-churn")
            self.assertEqual(artifact["fixtureIdentity"], "full-screen-style-churn")
            self.assertEqual(
                artifact["resetEvidence"],
                {
                    "denseSetupAndStartDrawCompleted": True,
                    "settlingDrawCompleted": True,
                },
            )
            self.assertTrue(artifact["finalDraw"]["available"])
            self.assertIn(
                "DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES=50",
                sent[0][1][-1],
            )
            self.assertFalse((artifacts / "localized-draw-000000").exists())
            self.assertEqual(sent[1], ("pane-a", ["--", "Enter"]))

    def test_wait_for_path_terminates_on_its_deadline_and_on_its_liveness_abort(self):
        # Intent: both exits from `_wait_for_path` -- the deadline and the
        #   process-death abort -- terminate, and each names the path it waited on.
        # Why it exists: it is the single bound on every persistent-block wait,
        #   and a wait that could not end would hang a whole collection run with
        #   no evidence. It had no direct coverage.
        with tempfile.TemporaryDirectory() as directory:
            missing = pathlib.Path(directory) / "never-written"

            with self.assertRaises(TimeoutError) as timed_out:
                VALIDATION._wait_for_path(missing, timeout_seconds=0)
            self.assertIn(str(missing), str(timed_out.exception))

            with self.assertRaisesRegex(RuntimeError, "process exited before writing"):
                VALIDATION._wait_for_path(
                    missing, timeout_seconds=30, abort_if=lambda: True
                )

            present = pathlib.Path(directory) / "written"
            present.touch()
            self.assertIsNone(
                VALIDATION._wait_for_path(present, timeout_seconds=0, abort_if=lambda: True)
            )

    def test_persistent_draw_runner_reports_an_unavailable_final_draw_instead_of_raising(self):
        # Intent: when the app never writes `final-draw.json`, the runner returns
        #   a block marked unavailable and the collector invalidates it, rather
        #   than the wait raising and killing the whole invocation.
        # Why it exists: the app failing to draw is the exact failure this
        #   evidence exists to explain, and a traceback discards every other
        #   block's evidence with it. The block must still be invalid.
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            identity = {
                "pid": 101,
                "artifacts": str(artifacts),
                "binary": str(root / "DanTerm Benchmark.app/Contents/MacOS/DanTerm Benchmark"),
                "geometry": {"columns": 179, "rows": 66},
            }

            def send_input(_identity, _pane, arguments):
                if arguments == ["--", "Enter"]:
                    (artifacts / "start-draw-ack").touch()
                    (artifacts / "producer-write.json").write_text(json.dumps({
                        "error": "timed out waiting for localized settling draw",
                    }))

            def wait_for_path(path, **_options):
                if path.exists():
                    return None
                raise TimeoutError(str(path))

            runner = VALIDATION.make_persistent_draw_runner(
                {"a": identity, "b": {**identity, "pid": 202}},
                workload="full-screen-incremental-mixed-churn",
                root=root,
                resolve_pane=lambda _identity: "pane-a",
                send_input=send_input,
                front_app=lambda _pid: None,
                wait_for_path=wait_for_path,
            )

            artifact = runner("a")

            self.assertFalse(artifact["finalDraw"]["available"])
            self.assertEqual(
                artifact["producerWrite"]["error"],
                "timed out waiting for localized settling draw",
            )
            evidence = VALIDATION.collect_incremental_mixed(
                [{"measurementRole": "A", "physicalArm": "a", "quartet": 0}],
                run_block=lambda _arm: artifact,
            )
            self.assertFalse(evidence["valid"])
            self.assertIn(
                "block-0-missing-final-completed-draw", evidence["invalidationReasons"]
            )

    def test_persistent_arm_lifecycle_uses_shared_bundle_and_closes_owned_harnesses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "collection"
            launches = []
            processes = []

            class Process:
                def __init__(self):
                    self.signals = []
                    self.waits = []

                def poll(self):
                    return None

                def send_signal(self, value):
                    self.signals.append(value)

                def wait(self, timeout):
                    self.waits.append(timeout)
                    return 0

            def popen(command, **options):
                arm = ("a" if options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                       .endswith("a-identity.json") else "b")
                process = Process()
                processes.append(process)
                launches.append((arm, command, options))
                identity_path = pathlib.Path(
                    options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                )
                identity_path.write_text(json.dumps({
                    "schemaVersion": 1,
                    "pid": 100 + len(processes),
                    "workload": "full-screen-style-churn",
                    "backend": "swift",
                    "binary": str(
                        root / f"{arm}.app/Contents/MacOS/DanTerm Benchmark"
                    ),
                    "artifacts": str(root / f"{arm}-artifacts"),
                    "geometry": {"columns": 179, "rows": 66},
                    "profilingActive": False,
                }))
                return process

            lifecycle = VALIDATION.PersistentDrawArms(
                {"a": root / "arm-a", "b": root / "arm-b"},
                workload="full-screen-style-churn",
                output=output,
                popen=popen,
                wait_for_path=lambda path, **_options: self.assertTrue(path.exists()),
            )
            identities = lifecycle.start()
            lifecycle.close()

            self.assertEqual(set(identities), {"a", "b"})
            self.assertEqual(
                [launch[2]["env"]["DANTERM_BENCHMARK_BUNDLE_SUFFIX"]
                 for launch in launches],
                ["", ""],
            )
            self.assertTrue(all(
                launch[2]["env"]["DANTERM_BENCHMARK_MODE"] == "persistent"
                for launch in launches
            ))
            self.assertTrue(all(
                launch[2]["env"]["DANTERM_TERMINAL_BENCHMARK_COLUMNS"] == "179"
                and launch[2]["env"]["DANTERM_TERMINAL_BENCHMARK_ROWS"] == "66"
                for launch in launches
            ))
            self.assertEqual(
                [process.signals for process in processes],
                [[signal.SIGINT], [signal.SIGINT]],
            )
            self.assertEqual([process.waits for process in processes], [[30], [30]])

    def test_close_stops_the_app_whose_wrapper_had_to_be_killed(self):
        # Intent: closing a lifecycle whose harness wrapper does not exit on
        #   SIGINT still stops the benchmark app that wrapper launched.
        # Why it exists: `close()` SIGKILLs a wrapper that outlives its grace
        #   period, and a SIGKILLed shell never runs the EXIT trap that would
        #   terminate the app it owns. The app is then orphaned and keeps
        #   running after the series that launched it has finished.
        # Scenario: 2026-07-27, eight orphaned "DanTerm Benchmark" apps
        #   accumulated across one afternoon of benchmark sessions and were
        #   still running afterwards, adding uncontrolled background load to
        #   every later series collected in that same session -- which is
        #   exactly the condition the harness asks the operator to guarantee.
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            processes = []
            killed = []
            live_pids = set()

            class StubbornProcess:
                """A wrapper that ignores SIGINT and must be killed."""

                def __init__(self):
                    self.killed = False

                def poll(self):
                    return 0 if self.killed else None

                def send_signal(self, value):
                    pass

                def wait(self, timeout):
                    if not self.killed:
                        raise subprocess.TimeoutExpired("harness", timeout)
                    return -9

                def kill(self):
                    self.killed = True

            def popen(command, **options):
                arm = ("a" if options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                       .endswith("a-identity.json") else "b")
                process = StubbornProcess()
                processes.append(process)
                pid = 100 + len(processes)
                live_pids.add(pid)
                pathlib.Path(
                    options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                ).write_text(json.dumps({
                    "schemaVersion": 1,
                    "pid": pid,
                    "workload": "full-screen-style-churn",
                    "backend": "swift",
                    "binary": str(
                        root / f"{arm}.app/Contents/MacOS/DanTerm Benchmark"
                    ),
                    "artifacts": str(root / f"{arm}-artifacts"),
                    "geometry": {"columns": 179, "rows": 66},
                    "profilingActive": False,
                }))
                return process

            def kill(pid, number):
                if pid not in live_pids:
                    raise ProcessLookupError(pid)
                if number != 0:
                    killed.append(pid)
                    live_pids.discard(pid)

            lifecycle = VALIDATION.PersistentDrawArms(
                {"a": root / "arm-a", "b": root / "arm-b"},
                workload="full-screen-style-churn",
                output=root / "collection",
                popen=popen,
                wait_for_path=lambda path, **_options: self.assertTrue(path.exists()),
                kill=kill,
            )
            lifecycle.start()
            lifecycle.close()

            self.assertEqual(sorted(killed), [101, 102])
            self.assertEqual(live_pids, set())

    def test_close_leaves_an_app_its_wrapper_already_stopped_alone(self):
        # Intent: when the wrapper exits cleanly and tears down its own app,
        #   close() does not signal that app's pid a second time.
        # Why it exists: the orphan reaper kills by recorded pid, so it must
        #   fire only for a pid that is still alive. Killing unconditionally
        #   would risk signalling an unrelated process that reused the pid.
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            killed = []

            class TidyProcess:
                """A wrapper that exits on SIGINT, stopping its own app."""

                def __init__(self):
                    self.stopped = False

                def poll(self):
                    return 0 if self.stopped else None

                def send_signal(self, value):
                    self.stopped = True

                def wait(self, timeout):
                    return 0

            def popen(command, **options):
                arm = ("a" if options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                       .endswith("a-identity.json") else "b")
                pathlib.Path(
                    options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                ).write_text(json.dumps({
                    "schemaVersion": 1,
                    "pid": 200 if arm == "a" else 201,
                    "workload": "full-screen-style-churn",
                    "backend": "swift",
                    "binary": str(
                        root / f"{arm}.app/Contents/MacOS/DanTerm Benchmark"
                    ),
                    "artifacts": str(root / f"{arm}-artifacts"),
                    "geometry": {"columns": 179, "rows": 66},
                    "profilingActive": False,
                }))
                return TidyProcess()

            def kill(pid, number):
                if number == 0:
                    raise ProcessLookupError(pid)
                killed.append(pid)

            lifecycle = VALIDATION.PersistentDrawArms(
                {"a": root / "arm-a", "b": root / "arm-b"},
                workload="full-screen-style-churn",
                output=root / "collection",
                popen=popen,
                wait_for_path=lambda path, **_options: self.assertTrue(path.exists()),
                kill=kill,
            )
            lifecycle.start()
            lifecycle.close()

            self.assertEqual(killed, [])

    def test_arm_startup_outwaits_a_cold_build_and_aborts_on_a_dead_arm(self):
        # Intent: waiting for an arm's identity file allows enough time for the
        #   harness to compile, sign, launch, and converge geometry, while still
        #   failing immediately if that arm's process dies.
        # Why it exists: startup shared the 30s budget meant for a measured
        #   block's draw acknowledgment. The identity file is only written after a
        #   full release build, so a cold cache timed out at 30s and killed the
        #   whole invocation for a reason unrelated to the code under test. A
        #   longer budget is only safe with a liveness check, so both are pinned
        #   here together.
        # Scenario: `just benchmark-confirm baseline=HEAD` on 2026-07-24 died with
        #   `TimeoutError: .../content-churn/a-identity.json` after its harness
        #   log showed `Build complete! (31.46s)` -- 1.5 seconds over the budget.
        observed = {}

        class DeadProcess:
            def poll(self):
                return 1

            def send_signal(self, _signal):
                return None

            def wait(self, timeout):
                return 1

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)

            def wait_for_path(path, timeout_seconds=30, abort_if=None):
                observed["timeout"] = timeout_seconds
                observed["aborted"] = abort_if is not None and abort_if()
                raise RuntimeError(f"process exited before writing {path}")

            lifecycle = VALIDATION.PersistentDrawArms(
                {"a": root, "b": root},
                workload="full-screen-content-churn",
                output=root / "out",
                popen=lambda _command, **_options: DeadProcess(),
                wait_for_path=wait_for_path,
            )

            with self.assertRaisesRegex(RuntimeError, "process exited"):
                lifecycle.start()

        # A cold two-package release build alone runs past a minute, so the budget
        # has to clear that by a wide margin rather than by seconds.
        self.assertGreaterEqual(observed["timeout"], 300)
        self.assertTrue(observed["aborted"])

    def test_persistent_arm_lifecycle_rejects_wrong_identity_before_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)

            class Process:
                def poll(self):
                    return None

                def send_signal(self, _value):
                    pass

                def wait(self, timeout):
                    return 0

            def popen(_command, **options):
                identity_path = pathlib.Path(
                    options["env"]["DANTERM_BENCHMARK_IDENTITY_PATH"]
                )
                identity_path.write_text(json.dumps({
                    "schemaVersion": 1,
                    "pid": 101,
                    "workload": "full-screen-content-churn",
                    "backend": "swift",
                    "binary": "/tmp/app",
                    "artifacts": "/tmp/artifacts",
                    "geometry": {"columns": 179, "rows": 65},
                    "profilingActive": False,
                }))
                return Process()

            lifecycle = VALIDATION.PersistentDrawArms(
                {"a": root, "b": root},
                workload="full-screen-content-churn",
                output=root / "out",
                popen=popen,
                wait_for_path=lambda path, **_options: None,
            )

            with self.assertRaisesRegex(ValueError, "wrong geometry"):
                lifecycle.start()

    def _draw_churn_artifact(self, *, workload, fixture, dirty_rows):
        durations = [300_000] * 50
        return {
            "backend": "swift",
            "workload": workload,
            "fixtureIdentity": fixture,
            "processId": 101,
            "sessionId": "pane-a",
            "geometry": {"columns": 179, "rows": 66},
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
                "drawCount": 50,
                "cumulativeDrawNanoseconds": sum(durations),
                "drawSequences": list(range(50)),
                "drawDurationsNanoseconds": durations,
                "dirtyRowCounts": [dirty_rows] * 50,
                "machineStateSamples": [{
                    "activeSpaceChanged": False,
                    "lowPowerMode": False,
                    "thermalState": "nominal",
                    "visible": True,
                }],
            },
        }


if __name__ == "__main__":
    unittest.main()
