#!/usr/bin/env python3
"""Behavioral tests for localized real-draw benchmark calibration and reporting."""
import importlib.util
import pathlib
import unittest


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

        self.assertEqual(summary["drawCount"], 3)
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


if __name__ == "__main__":
    unittest.main()
