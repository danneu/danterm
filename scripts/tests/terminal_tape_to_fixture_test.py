#!/usr/bin/env python3
"""Behavioral tests for converting live-pane recordings into neutral fixtures."""

import base64
import json
from pathlib import Path
import socket
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

    def test_written_input_is_scrubbed_and_its_identifiers_still_refuse_conversion(self):
        # Intent: a write event's payload is scrubbed and identifier-checked exactly as a
        #   feed's is, and its inert origin stamp survives conversion untouched.
        # Why it exists: a tape records both directions, and a typed command line carries the
        #   same home path and hostname the prompt does. A converter that only scrubbed output
        #   would commit them anyway.
        # Scenario: a developer converts a tape in which they typed `cd /Users/alice/project`.
        typed = b"cd /Users/alice/project\r"
        capture = live_capture()
        capture["events"] = [
            {
                "type": "write",
                "base64": base64.b64encode(typed).decode("ascii"),
                "elapsedNanoseconds": 30,
                "originElapsedNanoseconds": 28,
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.json"
            destination = root / "fixture.json"
            source.write_text(json.dumps(capture), encoding="utf-8")

            result = self.run_converter(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(
                base64.b64decode(fixture["events"][0]["base64"]),
                b"cd /home/user/project\r",
            )
            self.assertEqual(fixture["events"][0]["elapsedNanoseconds"], 30)
            self.assertEqual(fixture["events"][0]["originElapsedNanoseconds"], 28)

        leaked = live_capture()
        leaked["events"] = [
            {
                "type": "write",
                "base64": base64.b64encode(
                    b"echo " + local_identifier().encode()
                ).decode("ascii"),
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.json"
            destination = root / "fixture.json"
            source.write_text(json.dumps(leaked), encoding="utf-8")

            refused = self.run_converter(source, destination)

            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("identifiers survived scrubbing", refused.stderr)
            self.assertFalse(destination.exists())

    def test_write_events_reject_shapes_the_feed_vocabulary_rejects(self):
        invalid_events = {
            "missing payload": {"type": "write"},
            "multiple payloads": {"type": "write", "base64": "YQ==", "text": "a"},
            "hex payload": {"type": "write", "hex": "61"},
            "unknown field": {"type": "write", "base64": "YQ==", "note": "x"},
            "negative origin": {
                "type": "write",
                "base64": "YQ==",
                "originElapsedNanoseconds": -1,
            },
            "origin on output": {
                "type": "feed",
                "base64": "YQ==",
                "originElapsedNanoseconds": 1,
            },
        }
        for name, event in invalid_events.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "capture.json"
                destination = root / "fixture.json"
                capture = live_capture()
                capture["events"] = [event]
                source.write_text(json.dumps(capture), encoding="utf-8")

                result = self.run_converter(source, destination, "--keep-identifiers")

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())

    def test_truncated_capture_is_refused_without_an_override(self):
        # Intent: truncation is always a blocking conversion error with no escape hatch.
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

            # The escape hatch is absent rather than merely unused: the converter defines no
            # flag that admits a truncated tape, so asking for one is an argument error. Assert
            # that specific rejection -- a bare "it failed" would also pass if the flag existed
            # and wrote the fixture while failing for some later reason.
            override = self.run_converter(
                source,
                destination,
                "--keep-identifiers",
                "--allow-truncated",
            )

            self.assertEqual(override.returncode, 2)
            self.assertIn("unrecognized arguments: --allow-truncated", override.stderr)
            self.assertFalse(destination.exists())

    def test_legacy_bare_jsonl_and_hex_feeds_are_rejected(self):
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

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())

    def test_snapshot_and_stream_reject_invalid_event_shapes(self):
        invalid_events = {
            "missing payload": {"type": "feed"},
            "multiple payloads": {"type": "feed", "base64": "YQ==", "text": "a"},
            "hex payload": {"type": "feed", "hex": "61"},
            "unknown field": {"type": "resize", "columns": 8, "rows": 2, "note": "x"},
        }
        for name, event in invalid_events.items():
            for shape in ("snapshot", "stream"):
                with (
                    self.subTest(name=name, shape=shape),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = Path(directory)
                    source = root / "capture.json"
                    destination = root / "fixture.json"
                    if shape == "snapshot":
                        capture = live_capture()
                        capture["events"] = [event]
                        contents = json.dumps(capture)
                    else:
                        contents = json_lines([follow_start(), follow_event(1, event)])
                    source.write_text(contents, encoding="utf-8")

                    result = self.run_converter(source, destination, "--keep-identifiers")

                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(destination.exists())

    def test_snapshot_and_stream_require_raw_live_capture_provenance(self):
        for shape in ("snapshot", "stream"):
            with self.subTest(shape=shape), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "capture.json"
                destination = root / "fixture.json"
                if shape == "snapshot":
                    capture = live_capture()
                    capture["provenance"]["source"] = "danterm"
                    contents = json.dumps(capture)
                else:
                    start = follow_start()
                    start["provenance"]["source"] = "danterm"
                    contents = json_lines([start])
                source.write_text(contents, encoding="utf-8")

                result = self.run_converter(source, destination, "--keep-identifiers")

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())

    def test_snapshot_preserves_optional_mouse_button_on_move(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.json"
            destination = root / "fixture.json"
            capture = live_capture()
            capture["events"] = [
                {
                    "type": "mouse",
                    "action": "move",
                    "button": 1,
                    "column": 3,
                    "row": 2,
                }
            ]
            source.write_text(json.dumps(capture), encoding="utf-8")

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(fixture["events"], capture["events"])

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

    def test_follow_stream_carries_an_input_events_origin_into_the_fixture(self):
        # Intent: a stream record's hoisted origin stamp lands inside the converted event,
        #   beside the transfer stamp, and a record without one converts unchanged.
        # Why it exists: the origin is what separates time the app owned from time the child
        #   owned, so a converter that dropped it would turn evidence into a plain byte log.
        # Scenario: a developer follows a pane while typing, then converts the capture.
        records = [
            follow_start(),
            follow_event(3, {"type": "write", "text": "ls"}, elapsed=90, origin_elapsed=12),
            follow_event(4, {"type": "feed", "text": "ls"}, elapsed=95),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.jsonl"
            destination = root / "fixture.json"
            source.write_text(json_lines(records), encoding="utf-8")

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(
                fixture["events"],
                [
                    {
                        "type": "write",
                        "text": "ls",
                        "elapsedNanoseconds": 90,
                        "originElapsedNanoseconds": 12,
                    },
                    {"type": "feed", "text": "ls", "elapsedNanoseconds": 95},
                ],
            )

    def test_follow_stream_rejects_an_origin_stamp_on_child_output(self):
        # Intent: only bytes travelling toward the child may carry an origin, in the stream
        #   grammar as well as in the event schema.
        # Why it exists: child output is read and recorded in one turn, so a second stamp on
        #   it would restate the first and invite a reader to compare two identical numbers.
        records = [
            follow_start(),
            follow_event(3, {"type": "feed", "text": "hi"}, elapsed=90, origin_elapsed=12),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "capture.jsonl"
            destination = root / "fixture.json"
            source.write_text(json_lines(records), encoding="utf-8")

            result = self.run_converter(source, destination, "--keep-identifiers")

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())

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


def local_identifier():
    """This machine's hostname, which the scrub rules only reach inside an OSC 7 URL."""
    return socket.gethostname()


def follow_start():
    return {
        "kind": "start",
        "version": 1,
        "provenance": {"source": "danterm-live-capture"},
        "initial": {"columns": 80, "rows": 24},
    }


def follow_event(sequence, event, elapsed=0, origin_elapsed=None):
    record = {
        "kind": "event",
        "sequence": sequence,
        "elapsedNanoseconds": elapsed,
        "event": event,
    }
    if origin_elapsed is not None:
        record["originElapsedNanoseconds"] = origin_elapsed
    return record


def follow_gap():
    return {"kind": "gap", "droppedEventCount": 1, "droppedPayloadBytes": 2}


def json_lines(records):
    return "".join(json.dumps(record) + "\n" for record in records)


if __name__ == "__main__":
    unittest.main()
