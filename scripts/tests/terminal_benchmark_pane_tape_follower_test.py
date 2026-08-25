#!/usr/bin/env python3
"""Behavioral tests for the benchmark's draining pane-tape follower."""
import base64
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "terminal_benchmark_pane_tape_follower",
    ROOT / "scripts" / "terminal-benchmark-pane-tape-follower.py",
)
FOLLOWER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FOLLOWER)


class TapeProgressTests(unittest.TestCase):
    def test_completion_marker_can_cross_feed_event_boundaries(self):
        progress = FOLLOWER.TapeProgress(b"FINAL-MARKER")
        progress.accept({"kind": "start"})
        progress.accept({"kind": "event", "event": {
            "type": "feed", "base64": base64.b64encode(b"noise FINAL-").decode(),
        }})
        progress.accept({"kind": "event", "event": {
            "type": "feed", "base64": base64.b64encode(b"MARKER tail").decode(),
        }})

        self.assertTrue(progress.started)
        self.assertTrue(progress.completed)
        self.assertEqual(progress.event_count, 2)
        self.assertEqual(progress.feed_bytes, 23)


if __name__ == "__main__":
    unittest.main()
