#!/usr/bin/env python3
"""Behavioral tests for benchmark geometry gating and timing order."""
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile
import unittest
import unittest.mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_producer", ROOT / "scripts" / "terminal-benchmark-producer.py"
)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)


def _maximal_span_count(rows):
    """Count disjoint vertical runs the way the renderer's span helper does.

    Deliberately restated here rather than imported: the point of the sparse-span
    assertions is that the stimulus row set has the topology the Swift transform
    is proven against, so the test must not borrow that transform's own arithmetic.
    """
    ordered = sorted(rows)
    return sum(
        1
        for index, row in enumerate(ordered)
        if index == 0 or ordered[index - 1] != row - 1
    )


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
        # incremental-mixed only takes the full-screen path for its settling frame
        # (sequence -1); its measured frames are the row-subset updates covered by
        # test_incremental_mixed_churn_changes_content_and_style_in_a_row_subset.
        frames = {
            "full-screen-content-churn": 3,
            "full-screen-style-churn": 3,
            "full-screen-incremental-mixed-churn": -1,
        }
        for workload, sequence in frames.items():
            with self.subTest(workload=workload):
                payload = PRODUCER.redraw_screen(
                    workload, sequence=sequence, columns=179, rows=66
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

    def test_sparse_span_updates_address_exactly_their_protected_engine_rows(self):
        # Intent: each sparse-span workload writes exactly the source rows whose
        #   engine damage carries the topology that workload exists to protect --
        #   2 rows in 2 spans for `sparse-spans-few`, 17 rows in 17 spans for
        #   `sparse-spans-max` -- and writes them without autowrapping into a
        #   neighbouring row.
        # Why it exists: the whole instrument rests on the stimulus topology. One
        #   extra or missing source row silently changes the drawn shape (the halo
        #   turns these into 6 rows/2 spans and 50 rows/17 spans), which would
        #   leave both workloads measuring something other than the ideal-case win
        #   and the maximum compound clip.
        # Scenario: spec-first; the engine row sets pinned here are the same ones
        #   `TerminalDamageSpanTests` runs through the shared glyph-halo transform,
        #   which is what binds this stimulus to the protected drawing topology.
        expectations = (
            ("sparse-spans-few", (6, 61), 2),
            ("sparse-spans-max", tuple(range(1, 67, 4)), 17),
        )
        self.assertEqual(
            PRODUCER.SPARSE_SPAN_WORKLOADS, ("sparse-spans-few", "sparse-spans-max")
        )
        for workload, expected_rows, expected_spans in expectations:
            with self.subTest(workload=workload):
                self.assertEqual(PRODUCER.sparse_span_rows(workload, 66), expected_rows)

                engine_rows = [row - 1 for row in expected_rows]
                self.assertEqual(len(engine_rows), expected_spans)
                self.assertEqual(_maximal_span_count(engine_rows), expected_spans)

                payload = PRODUCER.sparse_span_screen(
                    workload, sequence=3, columns=179, rows=66
                )
                addressed = tuple(
                    int(row) for row in re.findall(rb"\x1b\[(\d+);1H", payload)
                )
                self.assertEqual(addressed, expected_rows)

                written = [
                    re.sub(rb"\x1b\[[0-9;]*m", b"", segment)
                    for segment in re.split(rb"\x1b\[\d+;1H", payload)[1:]
                ]
                self.assertTrue(all(len(segment) == 178 for segment in written))
                self.assertNotIn(b"\r\n", payload)
                self.assertNotIn(b"\n", payload)
                self.assertNotIn(b"\x1b[2J", payload)

        with self.assertRaisesRegex(ValueError, "unknown sparse-span workload"):
            PRODUCER.sparse_span_rows("sparse-spans-some", 66)

    def test_sparse_span_updates_are_deterministic_and_churn_content_and_style(self):
        # Intent: the same sequence always produces the same bytes, and successive
        #   sequences change both the text and the colors of every source row.
        # Why it exists: a measured draw is only accepted when the frame actually
        #   changed those rows -- a repeated update would publish no engine damage
        #   and stall the serialized handshake -- while non-determinism would make
        #   the two arms of a paired comparison run different stimulus.
        for workload in ("sparse-spans-few", "sparse-spans-max"):
            with self.subTest(workload=workload):
                first = PRODUCER.sparse_span_screen(workload, sequence=1)
                second = PRODUCER.sparse_span_screen(workload, sequence=2)

                self.assertEqual(first, PRODUCER.sparse_span_screen(workload, sequence=1))
                strip_metadata = lambda payload: payload.split(b"\x07", 1)[1]
                content = lambda payload: re.sub(
                    rb"\x1b\[[0-9;]*m", b"", strip_metadata(payload)
                )
                styles = lambda payload: re.findall(
                    rb"\x1b\[38;2;[0-9;]*m", strip_metadata(payload)
                )

                self.assertNotEqual(content(first), content(second))
                self.assertNotEqual(styles(first), styles(second))
                self.assertIn(b"\x1b]0;DANTERM-BENCH-REDRAW-000001\x07", first)
                # The sequence marker rides the OSC title, never the grid: drawing
                # it into a cell would damage a row outside the protected topology.
                self.assertNotIn(b"DANTERM-BENCH-REDRAW-", strip_metadata(first))

    def test_sparse_span_workloads_settle_on_a_dense_screen_before_measurement(self):
        # Intent: `redraw_screen` gives each sparse-span workload the same dense
        #   66-row settling frame the other draw workloads get, then routes every
        #   measured sequence to the sparse update.
        # Why it exists: the protected topology is a property of changing a few
        #   rows of an already-settled screen; measuring against a blank grid would
        #   let the first updates damage rows the stimulus never wrote.
        for workload in ("sparse-spans-few", "sparse-spans-max"):
            with self.subTest(workload=workload):
                settling = PRODUCER.redraw_screen(workload, sequence=-1, columns=179, rows=66)
                visible = [
                    re.sub(rb"\x1b\[[0-9;]*m", b"", row).decode()
                    for row in settling.split(b"\x07\x1b[H", 1)[1].split(b"\r\n")
                ]

                self.assertEqual(len(visible), 66)
                self.assertTrue(all(len(row) == 178 for row in visible))
                self.assertEqual(
                    PRODUCER.redraw_screen(workload, sequence=4, columns=179, rows=66),
                    PRODUCER.sparse_span_screen(workload, sequence=4, columns=179, rows=66),
                )

    def test_redraw_screen_rejects_a_workload_the_paired_ladder_does_not_measure(self):
        # Intent: the producer emits stimulus only for the three full-screen draw
        #   workloads the paired ladder measures.
        # Why it exists: an unreachable workload is dead stimulus that drifts out of
        #   sync with the ladder while still looking maintained; this keeps the set
        #   closed so adding stimulus forces adding a measured workload.
        # Scenario: spec-first; a caller asks for a workload no recipe can run.
        self.assertEqual(
            PRODUCER.REDRAW_WORKLOADS,
            (
                "full-screen-content-churn",
                "full-screen-style-churn",
                "full-screen-incremental-mixed-churn",
            ),
        )
        with self.assertRaisesRegex(ValueError, "unknown redraw workload"):
            PRODUCER.redraw_screen("full-screen-symbol-churn", 1)

    def test_redraw_workload_alternates_writes_and_exact_draw_acknowledgments(self):
        events = []

        PRODUCER.run_redraw_workload(
            workload="full-screen-content-churn",
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

    def test_redraw_settling_warms_both_detached_swapchain_buffers(self):
        # Intent: a redraw block serializes two excluded settling renders before
        #   its measured sequence starts.
        # Why it exists: the view owns a three-buffer swapchain. The start frame
        #   initializes the attached buffer, so both detached buffers must render
        #   once or the first measured update may pay an unpredictable full render.
        events = []

        readiness = iter((False, False, True))
        PRODUCER.run_redraw_settling(
            row=12,
            write=lambda chunk: events.append(("write", chunk)),
            prepare_ack=lambda: events.append(("prepare", None)),
            await_draw=lambda: events.append(("draw", None)),
            is_ready=lambda: next(readiness),
        )

        self.assertEqual(
            [event[0] for event in events],
            ["prepare", "write", "draw", "prepare", "write", "draw"],
        )
        writes = [event[1] for event in events if event[0] == "write"]
        self.assertNotEqual(writes[0], writes[1])
        self.assertTrue(all(b"DANTERM-BENCH-LOCALIZED-READY" in value for value in writes))

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
                    write_result=lambda _elapsed, _geometry, _written=None, _started=None: events.append("result"),
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

    def test_the_recorded_byte_count_is_exactly_what_the_timed_bracket_wrote(self):
        # Intent: the producer reports the number of bytes it wrote inside the
        #   timed region -- the workload chunks plus the completion marker, and
        #   not the start marker that precedes the clock.
        # Why it exists: research doc 20 turned this bracket into a reported
        #   throughput rate (`research/20/D1`), and a rate is only as trustworthy as its
        #   denominator. Deriving that denominator by re-reading the corpus at
        #   report time would silently misreport any block whose arm ran a
        #   different corpus, so the count has to come from the writer itself and
        #   has to match the bracket exactly.
        # Scenario: spec-first -- one measured block over a two-chunk workload.
        recorded = []

        PRODUCER.run_workload(
            mode="measure",
            target=os.terminal_size((80, 24)),
            terminal_size=lambda: os.terminal_size((80, 24)),
            monotonic=lambda: 0,
            monotonic_ns=lambda: 0,
            sleep=lambda _interval: None,
            write=lambda _chunk: None,
            workload_chunks=lambda: (b"first", b"second"),
            await_start_ack=lambda: None,
            await_draw_result=lambda: None,
            acknowledge_geometry=lambda: None,
            write_result=lambda _elapsed, _geometry, written, _started: recorded.append(written),
            start_marker=b"start-marker\n",
            completion=b"complete\n",
        )

        self.assertEqual(recorded, [len(b"first") + len(b"second") + len(b"complete\n")])

    def test_acknowledgment_log_names_what_was_seen_and_what_it_gave_up_on(self):
        # Intent: when a wait for an app-side acknowledgment expires, the log
        #   says which acknowledgments had already arrived and which one it was
        #   still waiting for.
        # Why it exists: a lost acknowledgment used to be reported only as
        #   "timed out waiting for <x>", which cannot distinguish a block that
        #   never started from one that stalled midway. The recorded set is the
        #   evidence that tells those apart in `run.json`.
        awaited = []

        def wait(path, timeout_message):
            awaited.append(path)
            if len(awaited) == 3:
                raise SystemExit(timeout_message)

        log = PRODUCER.AcknowledgmentLog(wait=wait)
        log.await_path("start-ack", "/artifacts/start-ack", "no start")
        log.await_path("start-draw-ack", "/artifacts/start-draw-ack", "no start draw")

        self.assertEqual(log.evidence(), {
            "observed": ["start-ack", "start-draw-ack"],
            "awaiting": None,
        })

        with self.assertRaisesRegex(SystemExit, "no settling draw"):
            log.await_path("ready-draw-ack", "/artifacts/ready-draw-ack", "no settling draw")

        self.assertEqual(log.evidence(), {
            "observed": ["start-ack", "start-draw-ack"],
            "awaiting": "ready-draw-ack",
        })

    def test_result_write_leaves_no_temporary_and_lands_in_the_destination_directory(self):
        # Intent: a successful result write publishes the payload at the
        #   destination and leaves the directory otherwise exactly as it was.
        # Why it exists: `os.replace` is only atomic within one filesystem, so
        #   the temporary has to be created in the destination's own directory;
        #   a temporary written to TMPDIR would silently degrade to a copy that
        #   can tear. This pins the precondition the atomicity claim rests on.
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "producer-write.json"
            observed = []
            real_replace = os.replace

            def spy(source, target):
                observed.append((pathlib.Path(source).parent, sorted(
                    path.name for path in pathlib.Path(directory).iterdir()
                )))
                real_replace(source, target)

            with unittest.mock.patch.object(PRODUCER.os, "replace", spy):
                PRODUCER.write_json_result(str(destination), {"event": "ok"})

            self.assertEqual(observed[0][0], pathlib.Path(directory))
            self.assertEqual(json.loads(destination.read_text()), {"event": "ok"})
            self.assertEqual(
                [path.name for path in pathlib.Path(directory).iterdir()],
                ["producer-write.json"],
            )

    def test_failed_serialization_never_truncates_the_destination(self):
        # Intent: a payload that cannot be serialized leaves the destination
        #   absent, or leaves pre-existing content byte-identical.
        # Why it exists: `open(path, "w")` truncates before the first byte is
        #   written, and the harness waits only on the destination's existence,
        #   so a reader could observe a zero-byte file it then fails to parse.
        #   Existence of the artifact must imply completeness of the artifact.
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "producer-write.json"

            with self.assertRaises(TypeError):
                PRODUCER.write_json_result(str(destination), {"event": object()})
            self.assertFalse(destination.exists())
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])

            PRODUCER.write_json_result(str(destination), {"event": "first"})
            with self.assertRaises(TypeError):
                PRODUCER.write_json_result(str(destination), {"event": object()})
            self.assertEqual(json.loads(destination.read_text()), {"event": "first"})
            self.assertEqual(
                [path.name for path in pathlib.Path(directory).iterdir()],
                ["producer-write.json"],
            )

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
            write_result=lambda _elapsed, _geometry, _written=None: events.append("result"),
            start_marker=b"start\n",
            completion=b"complete\n",
        )

        self.assertEqual(events, ["geometry-ready"])


class CompletionMarkerTests(unittest.TestCase):
    def test_the_completion_marker_leaves_drawing_enabled_after_a_synchronized_stimulus(self):
        # Intent: appending the completion marker to a stimulus that enabled
        #   synchronized output leaves the stream with synchronized output off.
        # Why it exists: `TerminalPaneSession.planIfNeeded` returns early while
        #   `isSynchronizedOutputActive`, so the marker exists to force a final
        #   visible draw and cannot do that through a flag it never clears. The
        #   prologue already resets SGR, the scroll region, and the alternate
        #   screen for exactly this reason; synchronized output was the one
        #   state-leaving-mode it missed, and the symptom is a harness that hangs
        #   waiting for a draw rather than one that fails.
        # Scenario: spec-first; the corpus gained its first captured workload, in
        #   which 100% of the bytes sit inside a DECSET 2026 bracket.
        stimulus = b"\x1b[?2026h" + b"payload"
        stream = stimulus + PRODUCER.completion_bytes("FINAL-STATE", "MARKER")
        self.assertGreater(
            stream.rfind(b"\x1b[?2026l"),
            stream.rfind(b"\x1b[?2026h"),
            "completion left synchronized output enabled, which suppresses the draw",
        )

    def test_the_completion_marker_carries_both_harness_markers(self):
        # Intent: the marker text the observer matches on survives the prologue.
        # Why it exists: the prologue is a pile of escape sequences and the two
        #   marker strings are the only part the harness actually reads; a
        #   prologue edit that ate one would be invisible until a run failed to
        #   detect its own completion.
        completion = PRODUCER.completion_bytes("FINAL-STATE", "MARKER")
        self.assertIn(b"FINAL-STATE", completion)
        self.assertIn(b"MARKER", completion)


if __name__ == "__main__":
    unittest.main()
