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

        # Sized from WORKLOADS rather than a literal count, because the literal
        # is what broke when the corpus gained its sixth workload while the
        # structural claim -- every workload gets all three quick conditions, and
        # both directions in confirm plus one suite-level A/A cell -- did not
        # change at all.
        workloads = len(VALIDATION.WORKLOADS)
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(len(manifest["quick"]), workloads * len(VALIDATION.DIRECTIONS) * 60)
        self.assertEqual(len(manifest["confirm"]), (1 + workloads * 2) * 60)
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
            {"pairCount": 2, "directionalThresholdPercent": 2.0},
        )
        self.assertEqual(
            rules["quick"]["workloads"]["style-churn"],
            {"pairCount": 2, "directionalThresholdPercent": 2.0},
        )
        self.assertEqual(
            rules["quick"]["workloads"]["incremental-mixed"],
            {"pairCount": 2},
        )
        self.assertEqual(
            rules["confirm"]["estimator"], "median",
        )
        self.assertEqual(rules["confirm"]["equivalenceBandPercent"], 0.75)
        self.assertEqual(
            rules["confirm"]["workloads"]["content-churn"],
            {"pairCount": 4, "directionalThresholdPercent": 1.5},
        )
        self.assertEqual(
            rules["confirm"]["workloads"]["style-churn"],
            {"pairCount": 4, "directionalThresholdPercent": 1.75},
        )
        self.assertEqual(
            rules["confirm"]["workloads"]["incremental-mixed"],
            {"pairCount": 6},
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

    def test_terminal_feed_collector_sizes_each_arm_for_a_large_improvement(self):
        # Intent: every source receives enough feed executions to clear the
        #   duration floor even when one source is substantially faster.
        # Why it exists: research/33/F16 is the incident -- candidate 90731fdc
        #   ran baseline 63c693da's fixed batch in under one second and voided
        #   the complete confirm invocation.
        # Scenario: the candidate needs six executions where the baseline needs
        #   four, and the position-balanced measured blocks use those arm-local
        #   counts while preserving normalized per-execution durations.
        blocks = [
            {"measurementRole": "A", "physicalArm": "a"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "A", "physicalArm": "a"},
        ]
        calls = []

        def run_benchmark(arm, *, execution_count):
            calls.append((arm, execution_count))
            if execution_count is None:
                batch_count = 4 if arm == "a" else 6
                per_execution = 300_000_000 if arm == "a" else 200_000_000
                return {
                    "batchCount": batch_count,
                    "feedDurationNanoseconds": [per_execution, per_execution],
                    "sampleDurationNanoseconds": [
                        batch_count * per_execution,
                        batch_count * per_execution,
                    ],
                }
            per_execution = 300_000_000 if arm == "a" else 200_000_000
            total = execution_count * per_execution
            return {
                "batchCount": execution_count,
                "feedDurationNanoseconds": [per_execution],
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

        self.assertEqual(calls[:2], [("a", None), ("b", None)])
        self.assertEqual(calls[2:], [("a", 4), ("b", 6), ("b", 6), ("a", 4)])
        self.assertEqual(
            {
                arm: entry["batchCount"]
                for arm, entry in evidence["calibration"]["arms"].items()
            },
            {"a": 4, "b": 6},
        )
        self.assertEqual(
            [block["batchCount"] for block in evidence["rawBlocks"]],
            [4, 6, 6, 4],
        )
        self.assertEqual(
            [block["feedDurationNanoseconds"] for block in evidence["rawBlocks"]],
            [300_000_000, 200_000_000, 200_000_000, 300_000_000],
        )
        self.assertTrue(evidence["valid"])
        self.assertEqual(evidence["invalidationReasons"], [])

    def test_terminal_feed_collector_keeps_identical_sources_identical(self):
        # Intent: arm-local sizing does not manufacture a directional difference
        #   when both physical arms execute byte-identical source.
        # Why it exists: research/31/F18 requires a whole-invocation A/A gate for
        #   every harness change that can affect directional verdicts.
        # Scenario: both arms calibrate to the same count and report the same
        #   normalized duration throughout an ABBA series.
        blocks = [
            {"measurementRole": "A", "physicalArm": "a"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "B", "physicalArm": "b"},
            {"measurementRole": "A", "physicalArm": "a"},
        ]
        calls = []

        def run_benchmark(arm, *, execution_count):
            calls.append((arm, execution_count))
            batch_count = 5 if execution_count is None else execution_count
            samples = 2 if execution_count is None else 1
            return {
                "batchCount": batch_count,
                "feedDurationNanoseconds": [250_000_000] * samples,
                "sampleDurationNanoseconds": [batch_count * 250_000_000] * samples,
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

        self.assertTrue(evidence["valid"])
        self.assertEqual(calls[:2], [("a", None), ("b", None)])
        self.assertEqual(set(evidence["calibration"]["arms"]), {"a", "b"})
        self.assertEqual(
            [block["feedDurationNanoseconds"] for block in evidence["rawBlocks"]],
            [250_000_000] * 4,
        )

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

    def test_fresh_replay_runner_reports_both_child_streams_for_invalid_json(self):
        # Intent: a successful fresh-app wrapper that emits invalid JSON preserves
        #   both captured streams in the error at a bounded size.
        # Why it exists: three confirm runs reached complete scrollback artifacts
        #   but reported only a generic JSON parse error; the runner discarded the
        #   only evidence that could distinguish interruption from contamination.
        # Scenario: an operator reruns `benchmark-confirm` after a fresh replay
        #   wrapper exits zero without a result and needs the failure to explain
        #   what the child actually emitted.
        calls = []

        def run_command(command, **options):
            calls.append((command, options))
            return subprocess.CompletedProcess(
                command,
                0,
                "",
                "wrapper reached app-ready but emitted no result",
            )

        runner = VALIDATION.make_scrollback_stream_runner(
            {"a": "/arm-a", "b": "/arm-b"},
            run_command=run_command,
        )

        with self.assertRaisesRegex(
            RuntimeError,
            "stdout=''.*stderr='wrapper reached app-ready but emitted no result'",
        ):
            runner("a")

        self.assertEqual(calls[0][0][0], "/arm-a/scripts/terminal-benchmark.sh")
        self.assertTrue(calls[0][1]["capture_output"])

    def test_fresh_replay_runner_accepts_historical_status_before_json(self):
        # Intent: a comparison can read a historical arm whose harness printed
        #   theme-packing status before its one JSON result.
        # Why it exists: immutable baseline arms execute their own harness, so
        #   fixing today's stdout contract cannot repair an older exported tree.
        # Scenario: `benchmark-confirm baseline=fa01b66` must compare terminal
        #   behavior even though that revision prefixes its result with `Packed`.
        def run_command(command, **_options):
            return subprocess.CompletedProcess(
                command,
                0,
                'Packed 592 themes into /tmp/catalog.json\n{"valid": true}\n',
                "",
            )

        runner = VALIDATION.make_scrollback_stream_runner(
            {"a": "/arm-a", "b": "/arm-b"},
            run_command=run_command,
        )

        self.assertEqual(runner("b"), {"valid": True})

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

    def test_scrollback_collector_promotes_consistent_fence_metrics(self):
        artifact = self._fixture_replay_artifact()
        fence_metrics = {
            "clock": "dispatch-uptime-nanoseconds",
            "totalWaitNanoseconds": 36,
            "totalCount": 6,
            "hostEntryCount": 6,
            "kinds": {
                "delivery": {"waitNanoseconds": 10, "count": 2},
                "checkpoint": {"waitNanoseconds": 20, "count": 1},
                "teardown": {"waitNanoseconds": 0, "count": 0},
                "initialization": {"waitNanoseconds": 0, "count": 0},
                "diagnostic": {"waitNanoseconds": 6, "count": 3},
            },
        }
        artifact["finalDraw"]["fenceMetrics"] = fence_metrics

        evidence = VALIDATION.collect_scrollback_stream(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda _arm: artifact,
        )

        self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
        self.assertEqual(evidence["rawBlocks"][0]["fenceMetrics"], fence_metrics)

    def test_absent_fence_metrics_are_not_promoted_as_zero(self):
        artifact = self._fixture_replay_artifact()

        evidence = VALIDATION.collect_scrollback_stream(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda _arm: artifact,
        )

        self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
        self.assertIsNone(evidence["rawBlocks"][0]["fenceMetrics"])

    def test_each_inconsistent_fence_aggregate_invalidates_the_block(self):
        consistent_metrics = {
            "clock": "dispatch-uptime-nanoseconds",
            "totalWaitNanoseconds": 30,
            "totalCount": 2,
            "hostEntryCount": 2,
            "kinds": {
                "delivery": {"waitNanoseconds": 10, "count": 1},
                "checkpoint": {"waitNanoseconds": 20, "count": 1},
                "teardown": {"waitNanoseconds": 0, "count": 0},
                "initialization": {"waitNanoseconds": 0, "count": 0},
                "diagnostic": {"waitNanoseconds": 0, "count": 0},
            },
        }
        for field in (
            "totalWaitNanoseconds", "totalCount", "hostEntryCount"
        ):
            with self.subTest(field=field):
                artifact = self._fixture_replay_artifact()
                metrics = json.loads(json.dumps(consistent_metrics))
                metrics[field] = 99
                artifact["finalDraw"]["fenceMetrics"] = metrics

                evidence = VALIDATION.collect_scrollback_stream(
                    [{"measurementRole": "A", "physicalArm": "a"}],
                    run_block=lambda _arm: artifact,
                )

                self.assertFalse(evidence["valid"])
                self.assertIn(
                    "block-0-inconsistent-fence-metrics",
                    evidence["invalidationReasons"],
                )
        self.assertNotIn(
            "fence", json.dumps(VALIDATION.DECISION_RULES).lower()
        )
        self.assertNotIn("fenceVerdict", evidence["rawBlocks"][0])

    def test_synchronized_frames_collector_holds_the_same_contract_as_scrollback(self):
        # Intent: the captured-replay workload is collected and validated by the
        #   same rules as the generated replay workload, against its own name and
        #   fixture identity.
        # Why it exists: `scrollback-stream`'s collector encodes the whole fresh-app
        #   replay contract -- fresh process, fresh session, matched markers,
        #   producer write preceding the final draw, machine state sampled. A
        #   second replay workload that got its own copy of that would drift from
        #   it silently, and the drift would show up as blocks that pass validation
        #   while measuring something subtly different.
        # Scenario: spec-first; the corpus gained `synchronized-frames`, whose
        #   blocks are collected exactly like scrollback's but must not be accepted
        #   when an artifact claims the other workload's identity.
        def artifact_for(workload, fixture_identity):
            return {
                "schemaVersion": 1,
                "backend": "swift",
                "workload": workload,
                "fixtureIdentity": fixture_identity,
                "processId": 101,
                "sessionId": "pane-1",
                "geometry": {"columns": 179, "rows": 66},
                "producerWrite": {
                    "event": "producer-final-write-returned",
                    "elapsedNanoseconds": 155_000_000,
                    "bytesWritten": 3_020_662,
                },
                "finalDraw": {
                    "available": True,
                    "event": "final-draw-completed",
                    "startMarker": "DANTERM-BENCH-START-7",
                    "expectedFinalState": "DANTERM-BENCH-FINAL-STATE-7",
                    "elapsedNanoseconds": 163_000_000,
                    "machineStateSamples": [{
                        "activeSpaceChanged": False,
                        "lowPowerMode": False,
                        "thermalState": "nominal",
                        "visible": True,
                    }],
                },
            }

        matching = VALIDATION.collect_synchronized_frames(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda _arm: artifact_for(
                "synchronized-frames", "synchronized-frames-v1-btop-95-frames"
            ),
        )
        self.assertTrue(matching["valid"], matching["invalidationReasons"])
        self.assertEqual(
            matching["rawBlocks"][0]["finalDrawNanoseconds"], 163_000_000
        )
        self.assertEqual(
            matching["rawBlocks"][0]["producerWriteBytes"], 3_020_662
        )

        # An artifact from the other replay workload must not satisfy this one.
        mismatched = VALIDATION.collect_synchronized_frames(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda _arm: artifact_for(
                "scrollback-stream", "scrollback-stream-v1-25000-lines"
            ),
        )
        self.assertFalse(mismatched["valid"])
        self.assertIn("block-0-wrong-workload", mismatched["invalidationReasons"])
        self.assertIn("block-0-wrong-fixture", mismatched["invalidationReasons"])

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
                    "surfaceBuffersSettled": True,
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
                "surfaceBuffersSettled": False,
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
        for collect, workload in (
            (VALIDATION.collect_content_churn, "content-churn"),
            (VALIDATION.collect_style_churn, "style-churn"),
            (VALIDATION.collect_incremental_mixed, "incremental-mixed"),
        ):
            with self.subTest(workload=workload):
                artifact = self._serialized_draw_artifact(workload)
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

    def test_draw_churn_collectors_normalize_process_cpu_over_the_same_draws(self):
        # Intent: when the app reports whole-process CPU, each block carries a
        #   `processCPUNanosecondsPerDraw` normalized over the same 50 draws as
        #   `drawNanosecondsPerDraw`, and reports none when the count disagrees.
        # Why it exists: the shared divisor is the whole reason the three metrics
        #   can be read side by side. The count guard matters more here than for
        #   plan time because the CPU series drops any interval whose reading was
        #   non-monotonic, so a short series is a real possibility rather than a
        #   theoretical one -- and dividing a short series by 50 would understate
        #   CPU per draw while looking perfectly well-formed.
        # Scenario: spec-first -- 50 intervals of 4ms CPU each against a block
        #   whose CPU series came up one interval short.
        for collect, workload in (
            (VALIDATION.collect_content_churn, "content-churn"),
            (VALIDATION.collect_style_churn, "style-churn"),
            (VALIDATION.collect_incremental_mixed, "incremental-mixed"),
        ):
            for count, expected in ((50, 4_000_000), (49, None)):
                with self.subTest(workload=workload, count=count):
                    artifact = self._serialized_draw_artifact(workload)
                    intervals = [4_000_000] * count
                    artifact["finalDraw"]["processCPUCount"] = count
                    artifact["finalDraw"]["cumulativeProcessCPUNanoseconds"] = sum(
                        intervals
                    )
                    artifact["finalDraw"]["processCPUDurationsNanoseconds"] = intervals

                    evidence = collect(
                        [{"measurementRole": "A", "physicalArm": "a"}],
                        run_block=lambda arm: artifact,
                    )

                    self.assertTrue(evidence["valid"])
                    self.assertEqual(
                        evidence["rawBlocks"][0]["processCPUNanosecondsPerDraw"],
                        expected,
                    )

    def test_a_block_without_process_cpu_stays_valid_and_reports_none(self):
        # Intent: an artifact produced before the CPU reading existed collects,
        #   validates, and simply reports no CPU metric.
        # Why it exists: same reason as plan time -- every paired comparison
        #   builds its baseline arm from an older revision, so for this metric a
        #   missing reading is the state of every baseline in existing history.
        #   Inventing a zero would fabricate an effect and invalidating the block
        #   would void every comparison against that history.
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
        self.assertIsNone(evidence["rawBlocks"][0]["processCPUNanosecondsPerDraw"])

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

    def test_incremental_mixed_collector_gates_on_its_engine_damage_shapes(self):
        # Intent: an incremental-mixed block is valid only when every accepted
        #   draw's published engine damage carried one of the two shapes its
        #   producer emits, and the rendered row count decides nothing.
        # Why it exists (research/33/F25): the rule used to require the render to
        #   cover exactly six rows. Once the pane owned its display surface a
        #   render brought a stale swapchain buffer current over composed damage,
        #   never covered six, and the workload stopped producing a valid block at
        #   all -- taking the whole invocation's verdict with it.
        # Scenario: spec-first; a settled four-row update rendered under a
        #   whole-grid clip is valid, and a wider stimulus is not.
        artifact = self._accepted_draw_topology_artifact("incremental-mixed")

        evidence = VALIDATION.collect_incremental_mixed(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
        self.assertEqual(evidence["workload"], "incremental-mixed")
        # The whole-grid rendered row count on a valid block is the point: it is
        # what the retired rule would have rejected.
        self.assertEqual(
            evidence["rawBlocks"][0]["acceptedDrawTopology"]["engineDamagedRowCounts"][0], 4
        )

        # The producer's first update after settling also damages the row the
        # cursor vacates, and that shape is enumerated rather than excluded.
        first_update = self._accepted_draw_topology_artifact("incremental-mixed")
        first_update["finalDraw"]["acceptedDrawTopology"]["engineDamagedRowCounts"][0] = 5
        first_update["finalDraw"]["acceptedDrawTopology"]["engineSpanCounts"][0] = 2
        self.assertTrue(
            VALIDATION.collect_incremental_mixed(
                [{"measurementRole": "A", "physicalArm": "a"}],
                run_block=lambda arm: first_update,
            )["valid"]
        )

        off_topology = self._accepted_draw_topology_artifact("incremental-mixed")
        off_topology["finalDraw"]["acceptedDrawTopology"]["engineDamagedRowCounts"][-1] = 9
        self.assertEqual(
            VALIDATION.collect_incremental_mixed(
                [{"measurementRole": "A", "physicalArm": "a"}],
                run_block=lambda arm: off_topology,
            )["invalidationReasons"],
            ["block-0-wrong-engine-damage-topology"],
        )

    def test_a_pre_instrument_baseline_arm_is_labeled_rather_than_invalidated(self):
        # Intent: a block from an arm whose source tree has no topology recorder is
        #   valid and labeled as ungated, while a block from an arm that does have
        #   one is invalid when the evidence is absent or malformed.
        # Why it exists (research/33/F25): the gate is newer than most baselines, so
        #   requiring it unconditionally would make every comparison against an older
        #   revision impossible. Inferring "old arm" from the artifact's silence would
        #   be worse -- a candidate whose publish path broke would read as an old arm
        #   and sail through. Coverage is therefore read from the arm's own tree.
        # Scenario: spec-first -- one pre-instrument baseline arm and one instrumented
        #   arm, each with the evidence absent.
        pre_instrument = self._accepted_draw_topology_artifact("incremental-mixed")
        del pre_instrument["finalDraw"]["acceptedDrawTopology"]

        evidence = VALIDATION.collect_incremental_mixed(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: pre_instrument,
            topology_instrumented={"a": False},
        )

        self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
        self.assertEqual(
            evidence["rawBlocks"][0]["acceptedDrawTopologyCoverage"], "pre-instrument-arm"
        )

        self.assertEqual(
            VALIDATION.collect_incremental_mixed(
                [{"measurementRole": "A", "physicalArm": "a"}],
                run_block=lambda arm: pre_instrument,
                topology_instrumented={"a": True},
            )["invalidationReasons"],
            ["block-0-missing-accepted-draw-topology"],
        )

        # Present but malformed is never excused, on either kind of arm: that is a
        # broken instrument rather than an absent one.
        malformed = self._accepted_draw_topology_artifact("incremental-mixed")
        malformed["finalDraw"]["acceptedDrawTopology"] = []
        self.assertEqual(
            VALIDATION.collect_incremental_mixed(
                [{"measurementRole": "A", "physicalArm": "a"}],
                run_block=lambda arm: malformed,
                topology_instrumented={"a": False},
            )["invalidationReasons"],
            ["block-0-missing-accepted-draw-topology"],
        )

    def test_arm_topology_coverage_is_read_from_the_arm_source_tree(self):
        # Intent: whether an arm publishes damage topology is decided by reading that
        #   arm's own `app/TerminalBenchmark.swift`, not by any artifact it produced.
        # Why it exists: this is the ground truth that lets a missing artifact key be
        #   read as "not measured" without opening a silent-pass path.
        # Scenario: spec-first -- two synthetic arm roots, one carrying the recorder.
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            instrumented = root / "instrumented" / "app"
            instrumented.mkdir(parents=True)
            (instrumented / "TerminalBenchmark.swift").write_text(
                "private var damageTopologyRecorder: "
                "TerminalBenchmarkDamageTopologyRecorder?\n"
            )
            older = root / "older" / "app"
            older.mkdir(parents=True)
            (older / "TerminalBenchmark.swift").write_text(
                "private var sparseSpanRecorder: "
                "TerminalBenchmarkSparseSpanRecorder?\n"
            )

            self.assertTrue(
                VALIDATION.arm_publishes_accepted_draw_topology(root / "instrumented")
            )
            self.assertFalse(VALIDATION.arm_publishes_accepted_draw_topology(root / "older"))
            self.assertFalse(VALIDATION.arm_publishes_accepted_draw_topology(root / "absent"))

    def test_sparse_span_collectors_accept_only_their_own_engine_topology(self):
        # Intent: a sparse-span block is valid only when every accepted draw's
        #   published engine damage carried the exact row and span counts the
        #   workload names, and the engine topology is what decides that.
        # Why it exists: AppKit's bounding dirty rectangle cannot tell the two
        #   workloads apart -- the rectangle a compound clip draws under is the
        #   union of its spans, so 2 spans and 17 present the same bounding row
        #   count. Validating on that rectangle would accept a block measuring a
        #   topology the workload does not name, and its numbers would look
        #   perfectly well-formed.
        # Scenario: spec-first; each verdict is impossible unless every measured
        #   draw carried its exact engine topology: 2 rows in 2 spans, or 17 rows
        #   in 17 spans.
        for collect, workload, engine_rows, engine_spans in (
            (VALIDATION.collect_sparse_spans_few, "sparse-spans-few", 2, 2),
            (VALIDATION.collect_sparse_spans_max, "sparse-spans-max", 17, 17),
        ):
            with self.subTest(workload=workload):
                artifact = self._accepted_draw_topology_artifact(workload)

                evidence = collect(
                    [{"measurementRole": "A", "physicalArm": "a"}],
                    run_block=lambda arm: artifact,
                )

                self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
                self.assertEqual(evidence["workload"], workload)
                block = evidence["rawBlocks"][0]
                self.assertEqual(block["drawNanosecondsPerDraw"], 300_000)
                self.assertEqual(block["processCPUNanosecondsPerDraw"], 4_000_000)
                self.assertEqual(
                    block["acceptedDrawTopology"],
                    artifact["finalDraw"]["acceptedDrawTopology"],
                )
                self.assertEqual(
                    block["acceptedDrawTopology"]["allowedEngineDamageShapes"],
                    [{"damagedRowCount": engine_rows, "spanCount": engine_spans}],
                )

                off_topology = self._accepted_draw_topology_artifact(workload)
                off_topology["finalDraw"]["acceptedDrawTopology"][
                    "engineSpanCounts"
                ][-1] = engine_spans - 1
                self.assertEqual(
                    collect(
                        [{"measurementRole": "A", "physicalArm": "a"}],
                        run_block=lambda arm: off_topology,
                    )["invalidationReasons"],
                    ["block-0-wrong-engine-damage-topology"],
                )

                other = self._accepted_draw_topology_artifact(
                    "sparse-spans-max" if workload == "sparse-spans-few"
                    else "sparse-spans-few"
                )
                reasons = collect(
                    [{"measurementRole": "A", "physicalArm": "a"}],
                    run_block=lambda arm: other,
                )["invalidationReasons"]
                self.assertIn("block-0-wrong-workload", reasons)
                self.assertIn("block-0-wrong-accepted-draw-topology-contract", reasons)

    def test_a_sparse_span_block_without_complete_topology_coverage_is_invalid(self):
        # Intent: missing topology evidence, or topology series shorter than the
        #   accepted draws, invalidates the block rather than being read as zero.
        # Why it exists: the timing and CPU series are only meaningful against
        #   proof that the draws behind them carried the named topology. Partial
        #   coverage silently turns that proof into a claim about some of the
        #   draws while the aggregate still describes all of them -- which is the
        #   one failure a reader cannot see in the number.
        # Scenario: spec-first; a block is invalid when draw, primary-metric, engine-
        #   topology, and renderer-behavior counts do not cover the same accepted
        #   draws.
        missing = self._accepted_draw_topology_artifact("sparse-spans-few")
        del missing["finalDraw"]["acceptedDrawTopology"]
        self.assertEqual(
            VALIDATION.collect_sparse_spans_few(
                [{"measurementRole": "A", "physicalArm": "a"}],
                run_block=lambda arm: missing,
            )["invalidationReasons"],
            ["block-0-missing-accepted-draw-topology"],
        )

        partial = self._accepted_draw_topology_artifact("sparse-spans-few")
        topology = partial["finalDraw"]["acceptedDrawTopology"]
        topology["sampleCount"] = 49
        for series in ("engineDamagedRowCounts", "engineSpanCounts",
                       "clipDamagedRowCounts", "clipSpanCounts"):
            topology[series] = topology[series][:49]
        self.assertEqual(
            VALIDATION.collect_sparse_spans_few(
                [{"measurementRole": "A", "physicalArm": "a"}],
                run_block=lambda arm: partial,
            )["invalidationReasons"],
            ["block-0-incomplete-topology-coverage"],
        )

    def test_a_sparse_span_block_must_cover_the_draws_its_own_metric_decides_on(self):
        # Intent: `sparse-spans-max` is invalid when its process-CPU series does
        #   not cover all 50 accepted draws, while `sparse-spans-few` -- which
        #   decides on draw time -- stays valid with no CPU evidence at all.
        # Why it exists: the CPU series silently drops any interval whose reading
        #   was non-monotonic, and a normalization over fewer draws is reported as
        #   None. For every other workload that is a descriptive line going
        #   missing; for this one it is the deciding metric, so pairing would be
        #   reduced to arithmetic on an absent number.
        # Scenario: spec-first; a block is invalid when its primary-metric coverage
        #   does not match its accepted draw set, and research/29/D2 is what makes
        #   whole-process CPU that metric here.
        short = self._accepted_draw_topology_artifact("sparse-spans-max")
        short["finalDraw"]["processCPUCount"] = 49
        short["finalDraw"]["processCPUDurationsNanoseconds"] = [4_000_000] * 49

        evidence = VALIDATION.collect_sparse_spans_max(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: short,
        )

        self.assertEqual(
            evidence["invalidationReasons"],
            ["block-0-incomplete-process-cpu-coverage"],
        )

        without_cpu = self._accepted_draw_topology_artifact("sparse-spans-few")
        for field in (
            "processCPUCount",
            "cumulativeProcessCPUNanoseconds",
            "processCPUDurationsNanoseconds",
        ):
            del without_cpu["finalDraw"][field]

        few = VALIDATION.collect_sparse_spans_few(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: without_cpu,
        )

        self.assertTrue(few["valid"], few["invalidationReasons"])
        self.assertIsNone(few["rawBlocks"][0]["processCPUNanosecondsPerDraw"])

    def test_a_sparse_span_block_records_renderer_deviation_without_rejecting_it(self):
        # Intent: dirty-rectangle fallback and full clip damage are carried on the
        #   block as measured behavior, and neither invalidates it.
        # Why it exists: a synthesized known-bad arm deviates exactly at damage
        #   resolution, so gating on renderer behavior would turn the regression
        #   being measured into an unmeasured block -- the instrument would refuse
        #   to observe the only thing it was built to observe.
        # Scenario: spec-first; a synthesized known-bad arm records its declared
        #   renderer deviation in provenance instead of failing stimulus validity.
        artifact = self._accepted_draw_topology_artifact("sparse-spans-max")
        artifact["finalDraw"]["acceptedDrawTopology"]["clipFullDamageCount"] = 50

        evidence = VALIDATION.collect_sparse_spans_max(
            [{"measurementRole": "A", "physicalArm": "a"}],
            run_block=lambda arm: artifact,
        )

        self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
        self.assertEqual(
            evidence["rawBlocks"][0]["acceptedDrawTopology"]["clipFullDamageCount"],
            50,
        )

    def test_the_ungated_draw_workloads_carry_no_topology_evidence(self):
        # Intent: a block from a workload with no damage contract keeps exactly
        #   the artifact shape its frozen rule was calibrated against.
        # Why it exists: those rules were screened against blocks with no topology
        #   accounting on the measured path, so adding a field or a check to them
        #   would silently change the thing the thresholds describe.
        # Scenario: spec-first; the two full-screen churn workloads publish no
        #   topology evidence and retain the artifact and metric contract their
        #   frozen rules cover.
        for collect, workload in (
            (VALIDATION.collect_content_churn, "content-churn"),
            (VALIDATION.collect_style_churn, "style-churn"),
        ):
            with self.subTest(workload=workload):
                evidence = collect(
                    [{"measurementRole": "A", "physicalArm": "a"}],
                    run_block=lambda arm, workload=workload:
                        self._serialized_draw_artifact(workload),
                )

                self.assertTrue(evidence["valid"], evidence["invalidationReasons"])
                self.assertNotIn("acceptedDrawTopology", evidence["rawBlocks"][0])

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
                "sparse-spans-few": [{"physicalArm": "b"}],
                "sparse-spans-max": [{"physicalArm": "a"}],
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
                    "sparse-spans-few",
                    "sparse-spans-max",
                ],
            )
            self.assertEqual(
                closed,
                [
                    "sparse-spans-max",
                    "sparse-spans-few",
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
                "swapchain-ready-ack",
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
                    (artifacts / "swapchain-ready-ack").touch()
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
                    "surfaceBuffersSettled": True,
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
                "surfaceBuffersSettled": True,
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

    def _serialized_draw_artifact(self, workload):
        """Build one valid block for any serialized-draw workload by name.

        Three of the five are topology-gated and three are not, and a caller that
        wants "a valid block for this workload" should not have to know which:
        that is exactly the distinction these tests keep moving.
        """
        if "engineDamageShapes" in VALIDATION.BLOCK_CONTRACTS[workload]:
            return self._accepted_draw_topology_artifact(workload)
        artifact_workload = f"full-screen-{workload}"
        return self._draw_churn_artifact(
            workload=artifact_workload,
            fixture=VALIDATION.PERSISTENT_DRAW_WORKLOADS[artifact_workload],
            dirty_rows=66,
        )

    def _accepted_draw_topology_artifact(self, workload):
        """Spell one on-contract topology-gated block the way the app publishes it.

        The rendered row count is deliberately not the drawn shape of the
        stimulus: for a compound clip AppKit reports the union of the halo spans,
        and since the pane owns its display surface a render also covers whatever
        damage the acquired buffer was stale by. That is exactly why these
        workloads validate on the engine topology beside it instead.
        """
        artifact_workload = {
            "incremental-mixed": "full-screen-incremental-mixed-churn",
        }.get(workload, workload)
        engine, clip, spans, dirty_rows = {
            "sparse-spans-few": (2, 6, 2, 57),
            "sparse-spans-max": (17, 50, 17, 66),
            "incremental-mixed": (4, 6, 1, 66),
        }[workload]
        artifact = self._draw_churn_artifact(
            workload=artifact_workload,
            fixture=VALIDATION.PERSISTENT_DRAW_WORKLOADS[artifact_workload],
            dirty_rows=dirty_rows,
        )
        intervals = [4_000_000] * 50
        artifact["finalDraw"]["processCPUCount"] = 50
        artifact["finalDraw"]["cumulativeProcessCPUNanoseconds"] = sum(intervals)
        artifact["finalDraw"]["processCPUDurationsNanoseconds"] = intervals
        artifact["finalDraw"]["acceptedDrawTopology"] = {
            "workload": artifact_workload,
            "allowedEngineDamageShapes":
                VALIDATION.BLOCK_CONTRACTS[workload]["engineDamageShapes"],
            "sampleCount": 50,
            "engineDamagedRowCounts": [engine] * 50,
            "engineSpanCounts": [spans] * 50,
            "clipDamagedRowCounts": [clip] * 50,
            "clipSpanCounts": [spans] * 50,
            "clipFullDamageCount": 0,
        }
        return artifact

    def _fixture_replay_artifact(self):
        return {
            "schemaVersion": 1,
            "backend": "swift",
            "workload": "scrollback-stream",
            "fixtureIdentity": "scrollback-stream-v1-25000-lines",
            "processId": 101,
            "sessionId": "pane-a",
            "geometry": {"columns": 179, "rows": 66},
            "producerWrite": {
                "event": "producer-final-write-returned",
                "elapsedNanoseconds": 155_000_000,
                "bytesWritten": 3_020_662,
            },
            "finalDraw": {
                "available": True,
                "event": "final-draw-completed",
                "startMarker": "DANTERM-BENCH-START-7",
                "expectedFinalState": "DANTERM-BENCH-FINAL-STATE-7",
                "elapsedNanoseconds": 163_000_000,
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
