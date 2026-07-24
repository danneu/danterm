#!/usr/bin/env python3
"""Behavioral tests for benchmark geometry gating and timing order."""
import importlib.util
import os
import pathlib
import re
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_producer", ROOT / "scripts" / "terminal-benchmark-producer.py"
)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)


class TerminalBenchmarkProducerTests(unittest.TestCase):
    def test_localized_draw_updates_are_fixed_row_writes_without_full_screen_commands(self):
        first = PRODUCER.localized_draw_update(0, row=12)
        second = PRODUCER.localized_draw_update(1, row=12)

        self.assertTrue(first.startswith(b"\x1b[12;1H"))
        self.assertIn(b"DANTERM-BENCH-LOCALIZED-000000", first)
        self.assertIn(b"DANTERM-BENCH-LOCALIZED-000001", second)
        self.assertNotIn(b"\x1b[2J", first)
        self.assertNotIn(b"\x1b[r", first)
        self.assertNotIn(b"\n", first)
        self.assertIn(
            b"DANTERM-BENCH-LOCALIZED-READY",
            PRODUCER.localized_draw_ready(row=12),
        )

    def test_localized_draw_setup_fills_the_grid_without_triggering_autowrap(self):
        payload = PRODUCER.localized_draw_initial_screen("START-MARKER", 179, 66)
        visible_rows = [
            re.sub(rb"\x1b\[[0-9;]*[A-Za-z]", b"", row)
            for row in payload.removeprefix(b"\x1b[2J\x1b[H").split(b"\r\n")
        ]

        self.assertEqual(len(visible_rows), 66)
        self.assertTrue(all(len(row) == 178 for row in visible_rows))
        self.assertIn(b"START-MARKER", visible_rows[-1])

    def test_localized_draw_workload_waits_for_each_completed_draw_before_next_write(self):
        events = []

        PRODUCER.run_localized_draw_workload(
            update_count=3,
            row=12,
            write=lambda chunk: events.append(("write", chunk)),
            await_draw=lambda sequence: events.append(("draw", sequence)),
        )

        self.assertEqual(
            [event[0] for event in events],
            ["write", "draw", "write", "draw", "write", "draw"],
        )
        self.assertEqual(
            [event[1] for event in events if event[0] == "draw"],
            [0, 1, 2],
        )

    def test_redraw_frames_fill_66_rows_without_scrolling_or_autowrap(self):
        for workload in PRODUCER.REDRAW_WORKLOADS:
            with self.subTest(workload=workload):
                payload = PRODUCER.redraw_screen(
                    workload, sequence=3, columns=179, rows=66
                )
                body = payload.split(b"\x07\x1b[H", 1)[1]
                rows = body.split(b"\r\n")
                visible = [
                    re.sub(rb"\x1b\[[0-9;]*m", b"", row).decode()
                    for row in rows
                ]

                self.assertEqual(len(visible), 66)
                self.assertTrue(all(len(row) == 178 for row in visible))
                self.assertNotIn(b"\x1b[2J", payload)
                self.assertFalse(payload.endswith(b"\r\n"))

    def test_redraw_workloads_isolate_content_and_style_churn(self):
        content_first = PRODUCER.redraw_screen("full-screen-content-churn", 1)
        content_second = PRODUCER.redraw_screen("full-screen-content-churn", 2)
        style_first = PRODUCER.redraw_screen("full-screen-style-churn", 1)
        style_second = PRODUCER.redraw_screen("full-screen-style-churn", 2)

        strip_metadata = lambda payload: payload.split(b"\x07", 1)[1]
        strip_styles = lambda payload: re.sub(rb"\x1b\[[0-9;]*m", b"", strip_metadata(payload))
        styles = lambda payload: re.findall(rb"\x1b\[[0-9;]*m", strip_metadata(payload))

        self.assertNotEqual(strip_styles(content_first), strip_styles(content_second))
        self.assertEqual(styles(content_first), styles(content_second))
        self.assertEqual(strip_styles(style_first), strip_styles(style_second))
        self.assertNotEqual(styles(style_first), styles(style_second))

    def test_incremental_mixed_churn_changes_content_and_style_in_a_row_subset(self):
        first = PRODUCER.incremental_mixed_screen(sequence=1, columns=179, rows=66)
        second = PRODUCER.incremental_mixed_screen(sequence=2, columns=179, rows=66)

        self.assertNotEqual(first, second)
        self.assertIn(b"\x1b]0;DANTERM-BENCH-REDRAW-000001\x07", first)
        self.assertNotIn(b"\x1b[2J", first)
        self.assertEqual(PRODUCER.incremental_mixed_rows(66), (31, 32, 33, 34))

    def test_symbol_churn_models_btop_with_ninety_percent_braille(self):
        # Intent: the symbol workload remains the deterministic proxy for the
        #   measured btop regression: 90% braille and 10% box drawing.
        # Why it exists: keeps the standing regression tied to the real workload
        #   that motivated sprite rendering instead of replacing it with coverage.
        # Scenario: spec-first; btop's process-list scroll remains reproducible.
        first = PRODUCER.redraw_screen("full-screen-symbol-churn", 1)
        second = PRODUCER.redraw_screen("full-screen-symbol-churn", 2)
        strip_metadata = lambda payload: payload.split(b"\x07\x1b[H", 1)[1]
        strip_styles = lambda payload: re.sub(
            rb"\x1b\[[0-9;]*m", b"", strip_metadata(payload)
        ).decode().replace("\r\n", "")
        styles = lambda payload: re.findall(
            rb"\x1b\[[0-9;]*m", strip_metadata(payload)
        )

        visible = strip_styles(first)
        box_drawing = sum("\u2500" <= character <= "\u257f" for character in visible)
        braille = sum("\u2800" <= character <= "\u28ff" for character in visible)

        self.assertEqual(len(visible), 178 * 66)
        self.assertEqual(braille, 10_573)
        self.assertEqual(box_drawing, 1_175)
        self.assertNotEqual(strip_styles(first), strip_styles(second))
        self.assertEqual(styles(first), styles(second))

    def test_sprite_coverage_churn_mixes_curated_candidate_sets_evenly(self):
        # Intent: a separate coverage workload churns curated sprite candidates
        #   without changing the btop-shaped performance regression.
        # Why it exists: broad implementation coverage and the measured btop
        #   regression are different benchmark questions with distinct identities.
        # Scenario: spec-first; future sprite increments use this second yardstick.
        first = PRODUCER.redraw_screen("full-screen-sprite-coverage-churn", 1)
        second = PRODUCER.redraw_screen("full-screen-sprite-coverage-churn", 2)
        strip_metadata = lambda payload: payload.split(b"\x07\x1b[H", 1)[1]
        strip_styles = lambda payload: re.sub(
            rb"\x1b\[[0-9;]*m", b"", strip_metadata(payload)
        ).decode().replace("\r\n", "")
        styles = lambda payload: re.findall(
            rb"\x1b\[[0-9;]*m", strip_metadata(payload)
        )

        visible = strip_styles(first)
        box_drawing = sum("\u2500" <= character <= "\u257f" for character in visible)
        blocks = sum("\u2580" <= character <= "\u259f" for character in visible)
        geometric = sum("\u25a0" <= character <= "\u25ff" for character in visible)
        braille = sum("\u2800" <= character <= "\u28ff" for character in visible)

        self.assertEqual(len(visible), 178 * 66)
        self.assertEqual(box_drawing, 2_937)
        self.assertEqual(blocks, 2_937)
        self.assertEqual(geometric, 2_937)
        self.assertEqual(braille, 2_937)
        self.assertNotEqual(strip_styles(first), strip_styles(second))
        self.assertEqual(styles(first), styles(second))

    def test_redraw_workload_alternates_writes_and_exact_draw_acknowledgments(self):
        events = []

        PRODUCER.run_redraw_workload(
            workload="full-screen-mixed-churn",
            update_count=3,
            write=lambda chunk: events.append(("write", chunk)),
            await_draw=lambda sequence: events.append(("draw", sequence)),
        )

        self.assertEqual(
            [event[0] for event in events],
            ["write", "draw", "write", "draw", "write", "draw"],
        )
        self.assertEqual(
            [event[1] for event in events if event[0] == "draw"],
            [0, 1, 2],
        )
        self.assertTrue(all(
            b"DANTERM-BENCH-REDRAW-" not in re.sub(
                rb"\x1b\].*?\x07", b"", event[1]
            )
            for event in events if event[0] == "write"
        ))

    def test_geometry_gate_accepts_a_late_match_before_measurement(self):
        observations = iter((os.terminal_size((94, 35)), os.terminal_size((90, 30)), os.terminal_size((80, 24))))
        events = []

        observed = PRODUCER.wait_for_target_geometry(
            target=os.terminal_size((80, 24)),
            terminal_size=lambda: next(observations),
            monotonic=lambda: 0,
            sleep=lambda _interval: events.append("sleep"),
            timeout_seconds=1,
        )

        self.assertEqual(observed, os.terminal_size((80, 24)))
        self.assertEqual(events, ["sleep", "sleep"])

    def test_geometry_gate_rejects_persistent_mismatch_with_both_sizes(self):
        clock = iter((0, 0.5, 1.0))

        with self.assertRaisesRegex(SystemExit, "required 80x24, observed 94x35"):
            PRODUCER.wait_for_target_geometry(
                target=os.terminal_size((80, 24)),
                terminal_size=lambda: os.terminal_size((94, 35)),
                monotonic=lambda: next(clock),
                sleep=lambda _interval: None,
                timeout_seconds=1,
            )

    def test_measure_and_loop_wait_before_workload_writes_or_clock_start(self):
        for mode in ("measure", "loop"):
            with self.subTest(mode=mode):
                observations = iter((os.terminal_size((94, 35)), os.terminal_size((80, 24))))
                events = []

                PRODUCER.run_workload(
                    mode=mode,
                    target=os.terminal_size((80, 24)),
                    terminal_size=lambda: next(observations),
                    monotonic=lambda: 0,
                    monotonic_ns=lambda: events.append("clock") or 0,
                    sleep=lambda _interval: events.append("geometry-wait"),
                    write=lambda chunk: events.append(("write", chunk)),
                    workload_chunks=lambda: (b"payload",),
                    await_start_ack=lambda: None,
                    await_draw_result=lambda: None,
                    acknowledge_geometry=lambda: events.append("geometry-ready"),
                    write_result=lambda _elapsed, _geometry: events.append("result"),
                    backend="ghostty",
                    start_marker=b"start\n",
                    completion=b"complete\n",
                    max_loop_iterations=1,
                )

                payload_write = ("write", b"payload")
                self.assertLess(events.index("geometry-wait"), events.index(payload_write))
                self.assertLess(events.index("geometry-ready"), events.index(payload_write))
                if mode == "measure":
                    self.assertLess(events.index("geometry-wait"), events.index("clock"))
                    self.assertLess(events.index("geometry-ready"), events.index("clock"))
                    self.assertLess(events.index("clock"), events.index(payload_write))
                else:
                    self.assertNotIn("clock", events)

    def test_persistent_mode_converges_and_returns_without_starting_a_block(self):
        events = []

        PRODUCER.run_workload(
            mode="persistent",
            target=os.terminal_size((80, 24)),
            terminal_size=lambda: os.terminal_size((80, 24)),
            monotonic=lambda: 0,
            monotonic_ns=lambda: events.append("clock") or 0,
            sleep=lambda _interval: None,
            write=lambda chunk: events.append(("write", chunk)),
            workload_chunks=lambda: (b"payload",),
            await_start_ack=lambda: events.append("start-ack"),
            await_draw_result=lambda: events.append("draw-result"),
            acknowledge_geometry=lambda: events.append("geometry-ready"),
            write_result=lambda _elapsed, _geometry: events.append("result"),
            backend="swift",
            start_marker=b"start\n",
            completion=b"complete\n",
        )

        self.assertEqual(events, ["geometry-ready"])


if __name__ == "__main__":
    unittest.main()
