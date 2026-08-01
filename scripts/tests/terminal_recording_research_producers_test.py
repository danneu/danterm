#!/usr/bin/env python3
"""Behavioral tests for the active OSC 133 recording producers."""

import base64
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def load_script(filename):
    path = ROOT / "docs" / "research" / "24-osc-133-dialect" / filename
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DRAG = load_script("capture-fish-drag.py")
SWEEP = load_script("capture-fish-sweep.py")


class TerminalRecordingResearchProducerTests(unittest.TestCase):
    def test_drag_capture_emits_a_complete_base64_snapshot(self):
        # Intent: the integration capture is directly consumable as a live snapshot and
        #   preserves arbitrary terminal bytes without a legacy hex representation.
        # Why it exists: the research producer must exercise the same canonical recording
        #   schema as the in-process flight recorder and conversion tool.
        # Scenario: a fish width-drag capture contains non-UTF-8 output before a resize.
        payload = b"\x00\x80\xffprompt\r\n"
        events = [
            DRAG.feed_event(payload),
            {"type": "resize", "columns": 79, "rows": 23},
        ]

        recording = DRAG.recording_document(
            initial={"columns": 80, "rows": 24},
            events=events,
            stimulus="fish integration width drag",
        )

        self.assertEqual(set(recording), {"version", "provenance", "initial", "events"})
        self.assertEqual(recording["version"], 1)
        self.assertEqual(recording["provenance"]["source"], "danterm-live-capture")
        self.assertEqual(recording["provenance"]["shell"], "fish")
        self.assertEqual(recording["initial"], {"columns": 80, "rows": 24})
        self.assertNotIn("hex", recording["events"][0])
        self.assertEqual(
            base64.b64decode(recording["events"][0]["base64"], validate=True),
            payload,
        )

    def test_sweep_variants_rewrite_base64_feeds_without_changing_snapshot_metadata(self):
        # Intent: neutral-value variants alter only matching feed bytes while retaining
        #   the complete snapshot envelope and every non-feed event.
        # Why it exists: the dialect experiment depends on variants being the same drive
        #   sequence rather than independently assembled partial recordings.
        # Scenario: fish's native OSC 133 A mark is compared with redraw=1 appended.
        marker = b"\x1b]133;A;click_events=1"
        payload = b"before" + marker + b"\x07\xffafter"
        recording = SWEEP.recording_document(
            initial={"columns": 100, "rows": 12},
            events=[
                SWEEP.feed_event(payload),
                {"type": "resize", "columns": 99, "rows": 12},
            ],
            stimulus="fish native mark width sweep",
        )

        variant = SWEEP.recording_variant(recording, marker, b";redraw=1")

        self.assertEqual(variant["version"], recording["version"])
        self.assertEqual(variant["provenance"], recording["provenance"])
        self.assertEqual(variant["initial"], recording["initial"])
        self.assertEqual(variant["events"][1], recording["events"][1])
        self.assertEqual(
            base64.b64decode(variant["events"][0]["base64"], validate=True),
            payload.replace(marker, marker + b";redraw=1"),
        )
        self.assertNotIn("hex", variant["events"][0])


if __name__ == "__main__":
    unittest.main()
