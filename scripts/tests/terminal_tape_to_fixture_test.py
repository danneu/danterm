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
FOLLOW_SAMPLE = ROOT / "scripts" / "tests" / "fixtures" / "pane-tape-follow.jsonl"


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

    def test_follow_stream_flattens_wrappers_and_preserves_feed_encodings(self):
        # Intent: an unwrapped pane-tape follow stream becomes one neutral fixture
        #   while retaining event timing and the producer's chosen feed encoding.
        # Why it exists: the CLI's crash-surviving capture is useful as fixture
        #   evidence only if the converter consumes its actual persisted grammar.
        # Scenario: a developer redirects --follow, captures binary and readable
        #   output plus a resize, and closes the pane normally.
        records = [
            follow_start(),
            follow_event(41, {"type": "feed", "base64": "AP8="}, elapsed=12),
            follow_event(42, {"type": "feed", "text": "ready"}, elapsed=15),
            follow_event(43, {"type": "resize", "columns": 90, "rows": 30}, elapsed=20),
            {"kind": "end", "reason": "pane-closed"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.jsonl"
            destination = root / "fixture.json"
            source.write_text(json_lines(records), encoding="utf-8")

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(fixture["initial"], {"columns": 80, "rows": 24})
            self.assertEqual(
                fixture["events"],
                [
                    {"type": "feed", "base64": "AP8=", "elapsedNanoseconds": 12},
                    {"type": "feed", "text": "ready", "elapsedNanoseconds": 15},
                    {
                        "type": "resize",
                        "columns": 90,
                        "rows": 30,
                        "elapsedNanoseconds": 20,
                    },
                ],
            )

    def test_follow_stream_without_end_remains_convertible(self):
        records = [
            follow_start(),
            follow_event(7, {"type": "feed", "base64": "YQ=="}, elapsed=1),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.jsonl"
            destination = root / "fixture.json"
            source.write_text(json_lines(records), encoding="utf-8")

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(destination.exists())

    def test_follow_stream_rejects_gaps_sequence_jumps_and_malformed_order(self):
        cases = {
            "leading gap": [follow_start(), follow_gap()],
            "interior gap": [
                follow_start(),
                follow_event(4, {"type": "feed", "base64": "YQ=="}),
                follow_gap(),
            ],
            "sequence jump": [
                follow_start(),
                follow_event(41, {"type": "feed", "base64": "YQ=="}),
                follow_event(43, {"type": "feed", "base64": "Yg=="}),
            ],
            "event before start": [
                follow_event(1, {"type": "feed", "base64": "YQ=="}),
            ],
            "multiple starts": [follow_start(), follow_start()],
            "record after end": [follow_start(), {"kind": "end"}, {"kind": "end"}],
        }
        for name, records in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "capture.jsonl"
                destination = root / "fixture.json"
                source.write_text(json_lines(records), encoding="utf-8")

                result = self.run_converter(source, destination, "--keep-identifiers")

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())

    def test_follow_stream_rejects_json_rpc_notification_envelopes(self):
        envelope = {
            "jsonrpc": "2.0",
            "method": "pane.tape.event",
            "params": {
                "record": follow_event(
                    1,
                    {"type": "feed", "base64": "YQ=="},
                )
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.jsonl"
            destination = root / "fixture.json"
            source.write_text(json_lines([follow_start(), envelope]), encoding="utf-8")

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())

    def test_committed_follow_sample_is_convertible(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "fixture.json"

            result = self.run_converter(
                FOLLOW_SAMPLE,
                destination,
                "--keep-identifiers",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(
                fixture["events"][0],
                {"type": "feed", "base64": "SGk=", "elapsedNanoseconds": 2},
            )


def follow_start():
    return {
        "kind": "start",
        "version": 1,
        "provenance": {"source": "danterm-live-capture"},
        "initial": {"columns": 80, "rows": 24},
    }


def follow_event(sequence, event, elapsed=0):
    return {
        "kind": "event",
        "sequence": sequence,
        "elapsedNanoseconds": elapsed,
        "event": event,
    }


def follow_gap():
    return {"kind": "gap", "droppedEventCount": 1, "droppedPayloadBytes": 2}


def json_lines(records):
    return "".join(json.dumps(record) + "\n" for record in records)


if __name__ == "__main__":
    unittest.main()
