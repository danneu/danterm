#!/usr/bin/env python3
"""Behavioral tests for benchmark geometry gating and timing order."""
import importlib.util
import os
import pathlib
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


if __name__ == "__main__":
    unittest.main()
