#!/usr/bin/env python3
"""Behavioral tests for converting live-pane recordings into neutral fixtures."""

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "terminal-tape-to-fixture.py"


def live_capture(*, truncated=False):
    raw = b"\x1b]7;file://workstation/Users/alice/project\x07prompt\r\n"
    return {
        "version": 1,
        "provenance": {
            "source": "danterm-live-capture",
            "author": "DanTerm",
            "test": "live-pane-tape",
            "recordedDeviations": [],
        },
        "initial": {"columns": 80, "rows": 24},
        "events": [
            {
                "type": "feed",
                "base64": base64.b64encode(raw).decode("ascii"),
                "elapsedNanoseconds": 12,
            },
            {
                "type": "resize",
                "columns": 79,
                "rows": 23,
                "elapsedNanoseconds": 25,
            },
        ],
        "truncation": {
            "isTruncated": truncated,
            "droppedEventCount": 3 if truncated else 0,
            "droppedPayloadBytes": 47 if truncated else 0,
        },
    }


class TerminalTapeToFixtureTests(unittest.TestCase):
    def run_converter(self, source, destination, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(source), str(destination), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_live_capture_is_scrubbed_without_changing_boundaries_or_metadata(self):
        # Intent: a fixture-shaped live dump becomes admissible DanTerm evidence while
        #   retaining event boundaries, timing, and honest truncation metadata.
        # Why it exists: capture conversion must not erase the exact drive sequence or
        #   silently discard metadata that determines whether the recording is trustworthy.
        # Scenario: a developer dumps a healthy dev pane after spotting a prompt artifact.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.json"
            destination = root / "fixture.json"
            source.write_text(json.dumps(live_capture()), encoding="utf-8")

            result = self.run_converter(
                source,
                destination,
                "--test",
                "TerminalPromptRegressionTests",
                "--shell",
                "fish",
                "--stimulus",
                "dragged divider",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(fixture["provenance"]["source"], "danterm")
            self.assertEqual(
                fixture["provenance"]["test"], "TerminalPromptRegressionTests"
            )
            self.assertEqual(fixture["provenance"]["shell"], "fish")
            self.assertEqual(fixture["provenance"]["stimulus"], "dragged divider")
            self.assertEqual(fixture["initial"], {"columns": 80, "rows": 24})
            self.assertEqual(fixture["events"][0]["elapsedNanoseconds"], 12)
            self.assertEqual(fixture["events"][1]["elapsedNanoseconds"], 25)
            self.assertEqual(fixture["truncation"], live_capture()["truncation"])
            scrubbed = base64.b64decode(fixture["events"][0]["base64"])
            self.assertEqual(
                scrubbed,
                b"\x1b]7;file://host/home/user/project\x07prompt\r\n",
            )

    def test_truncated_capture_is_refused_unless_explicitly_allowed(self):
        # Intent: truncation is a blocking conversion error unless the caller opts into
        #   incomplete evidence, and the override does not hide the dropped-data counts.
        # Why it exists: an evicted recording no longer begins at pane birth, so silently
        #   treating it as a complete fixture can make replay conclusions unsound.
        # Scenario: a long-lived pane exceeds its recorder budget before a dump is taken.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.json"
            destination = root / "fixture.json"
            source.write_text(json.dumps(live_capture(truncated=True)), encoding="utf-8")

            refused = self.run_converter(source, destination, "--keep-identifiers")

            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("truncated", refused.stderr)
            self.assertFalse(destination.exists())

            accepted = self.run_converter(
                source,
                destination,
                "--keep-identifiers",
                "--allow-truncated",
            )

            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(fixture["truncation"], live_capture(truncated=True)["truncation"])

    def test_legacy_streaming_tape_remains_convertible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.jsonl"
            destination = root / "fixture.json"
            source.write_text(
                "\n".join(
                    [
                        json.dumps({"initial": {"columns": 4, "rows": 2}}),
                        json.dumps({"type": "feed", "hex": "6162"}),
                        json.dumps({"type": "resize", "columns": 3, "rows": 2}),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(fixture["initial"], {"columns": 4, "rows": 2})
            self.assertEqual([event["type"] for event in fixture["events"]], ["feed", "resize"])


if __name__ == "__main__":
    unittest.main()
