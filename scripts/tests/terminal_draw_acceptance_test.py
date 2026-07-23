#!/usr/bin/env python3
"""Behavioral tests for localized real-draw benchmark calibration and reporting."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_draw_acceptance", ROOT / "scripts" / "terminal-draw-acceptance.py"
)
ACCEPTANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ACCEPTANCE)


class TerminalDrawAcceptanceTests(unittest.TestCase):
    def test_calibration_scales_updates_to_the_draw_duration_floor(self):
        self.assertEqual(
            ACCEPTANCE.calibrated_update_count(
                measured_nanoseconds=100_000_000,
                measured_updates=10,
                target_nanoseconds=400_000_000,
            ),
            40,
        )

    def test_summary_normalizes_batches_and_preserves_dirty_row_evidence(self):
        batches = [
            {
                "cumulativeDrawNanoseconds": 450,
                "drawCount": 3,
                "dirtyRowCounts": [1, 1, 1],
            },
            {
                "cumulativeDrawNanoseconds": 420,
                "drawCount": 3,
                "dirtyRowCounts": [1, 2, 1],
            },
            {
                "cumulativeDrawNanoseconds": 480,
                "drawCount": 3,
                "dirtyRowCounts": [1, 1, 1],
            },
        ]

        summary = ACCEPTANCE.summarize_batches(batches, expected_updates=3)

        self.assertEqual(summary["drawCount"], {"min": 3, "median": 3, "max": 3})
        self.assertEqual(summary["nanosecondsPerDraw"], {"min": 140, "median": 150, "max": 160})
        self.assertEqual(summary["dirtyRowsPerDraw"], {"min": 1, "median": 1, "max": 2})

    def test_summary_rejects_coalesced_or_missing_draws(self):
        with self.assertRaisesRegex(ValueError, "expected 3 completed draws, got 2"):
            ACCEPTANCE.summarize_batches(
                [{
                    "cumulativeDrawNanoseconds": 400,
                    "drawCount": 2,
                    "dirtyRowCounts": [1, 1],
                }],
                expected_updates=3,
            )

    def test_redraw_arguments_select_all_or_one_workload_and_save_policy(self):
        self.assertEqual(
            ACCEPTANCE.parse_arguments([
                "workload=full-screen-style-churn",
                "save=1",
                "comment=baseline",
            ])[:3],
            ("full-screen-style-churn", True, "baseline"),
        )
        self.assertEqual(
            ACCEPTANCE.parse_arguments(["save=0"])[:3],
            (None, False, None),
        )
        self.assertEqual(
            ACCEPTANCE.parse_arguments(["15", "400"])[3:],
            (15, 400, False),
        )
        self.assertTrue(
            ACCEPTANCE.parse_arguments(["redraw=1"])[5],
        )
        self.assertEqual(
            ACCEPTANCE.parse_arguments([
                "workload=full-screen-symbol-churn",
                "save=0",
            ])[:2],
            ("full-screen-symbol-churn", False),
        )
        self.assertEqual(
            ACCEPTANCE.REDRAW_IDENTITIES["full-screen-symbol-churn"],
            "full-screen-symbol-churn-v1-btop-symbol-mix-80x24",
        )
        self.assertEqual(
            ACCEPTANCE.REDRAW_IDENTITIES["full-screen-sprite-coverage-churn"],
            "full-screen-sprite-coverage-churn-v1-curated-candidates-80x24",
        )

    def test_latest_committed_requires_every_redraw_compatibility_field(self):
        current = {
            field: field for field in ACCEPTANCE.REDRAW_COMPATIBILITY_FIELDS
        }
        compatible = {**current, "commit": "compatible", "summary": {}}
        incompatible = {**compatible, "displayScale": "different", "commit": "wrong"}
        completed = mock.Mock(
            returncode=0,
            stdout="\n".join((json.dumps(compatible), json.dumps(incompatible))),
        )

        with mock.patch.object(ACCEPTANCE.subprocess, "run", return_value=completed):
            self.assertEqual(ACCEPTANCE.latest_committed(current)["commit"], "compatible")

    def test_serialized_results_are_stable_exact_staged_bytes(self):
        result = {"workload": "full-screen-mixed-churn", "summary": {"median": 12}}
        serialized = ACCEPTANCE.serialize_result(result)

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "staged.jsonl"
            path.write_text(serialized, encoding="utf-8")
            self.assertEqual(path.read_bytes(), serialized.encode())

    def test_redraw_rejects_a_measured_batch_below_the_duration_floor(self):
        warmup = {
            "cumulativeDrawNanoseconds": 100,
            "drawCount": 1,
            "dirtyRowCounts": [24],
        }
        short = {
            "cumulativeDrawNanoseconds": 399_999_999,
            "drawCount": 5_000_000,
            "dirtyRowCounts": [24],
        }

        with mock.patch.object(ACCEPTANCE, "run_batch", side_effect=(warmup, short)):
            with self.assertRaisesRegex(SystemExit, "fell below draw-work duration floor"):
                ACCEPTANCE.run_redraw("full-screen-content-churn", 2, 400)

    def test_saved_history_uses_the_exact_completed_staged_bytes(self):
        result = {"workload": "full-screen-content-churn", "summary": {}}
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            staging = root / "staging"
            history = root / "history.jsonl"
            with mock.patch.object(sys, "argv", ["suite", "save=1"]), mock.patch.object(
                ACCEPTANCE, "STAGING_ROOT", staging
            ), mock.patch.object(ACCEPTANCE, "HISTORY_PATH", history), mock.patch.object(
                ACCEPTANCE, "REDRAW_WORKLOADS", ("full-screen-content-churn",)
            ), mock.patch.object(
                ACCEPTANCE, "run_redraw", return_value=result
            ), mock.patch.object(
                ACCEPTANCE, "latest_committed", return_value=None
            ), mock.patch.object(
                ACCEPTANCE, "require_ac_power"
            ):
                ACCEPTANCE.main()

            staged = next(staging.glob("*.jsonl"))
            self.assertEqual(history.read_bytes(), staged.read_bytes())


if __name__ == "__main__":
    unittest.main()
