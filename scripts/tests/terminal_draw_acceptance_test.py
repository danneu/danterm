#!/usr/bin/env python3
"""Behavioral tests for localized real-draw microbenchmark calibration and reporting."""
import importlib.util
import io
import pathlib
import sys
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

    def test_arguments_accept_positional_and_named_batch_and_floor_spellings(self):
        self.assertEqual(ACCEPTANCE.parse_arguments(["15", "400"]), (15, 400))
        self.assertEqual(
            ACCEPTANCE.parse_arguments(["batches=20", "target_ms=125"]),
            (20, 125),
        )
        self.assertEqual(ACCEPTANCE.parse_arguments([]), (15, None))
        with self.assertRaisesRegex(ValueError, "batches must be >=2"):
            ACCEPTANCE.parse_arguments(["1"])

    def test_history_and_save_arguments_are_no_longer_accepted(self):
        # Intent: the surviving microbenchmark rejects every argument that used to
        #   route a result into durable redraw history.
        # Why it exists: surviving microbenchmarks cannot form durable benchmark
        #   history. A stale `workload=`/`save=`/`comment=`/`redraw=1` invocation
        #   must fail loudly rather than silently degrade into an unrecorded run.
        for argument in (
            "redraw=1",
            "workload=full-screen-content-churn",
            "save=1",
            "comment=baseline",
        ):
            with self.assertRaisesRegex(ValueError, "unknown argument"):
                ACCEPTANCE.parse_arguments([argument])

    def test_report_is_diagnostic_only_and_writes_no_history(self):
        # Intent: a completed microbenchmark run prints one self-describing
        #   diagnostic report and touches no durable file.
        # Why it exists: this diagnostic cannot form durable benchmark history.
        #   The module keeps no history path and no staging promotion, so there is
        #   nothing a future caller could re-point at a committed JSONL.
        batch = {
            "cumulativeDrawNanoseconds": 500_000_000,
            "drawCount": 10,
            "dirtyRowCounts": [1] * 10,
        }
        stdout = io.StringIO()

        with mock.patch.object(sys, "argv", ["draw", "2"]), mock.patch.object(
            ACCEPTANCE, "run_batch", side_effect=(batch, batch, batch)
        ), mock.patch.object(sys, "stdout", stdout):
            ACCEPTANCE.main()

        self.assertIn('"historyEligible": false', stdout.getvalue())
        self.assertIn('"decisionEligible": false', stdout.getvalue())
        self.assertFalse(hasattr(ACCEPTANCE, "HISTORY_PATH"))
        self.assertFalse(hasattr(ACCEPTANCE, "latest_committed"))


if __name__ == "__main__":
    unittest.main()
