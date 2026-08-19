#!/usr/bin/env python3
"""Behavioral tests for converting live-pane recordings into neutral fixtures."""

import base64
import importlib.util
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "terminal-tape-to-fixture.py"
PANE_TAPE_STREAM_SOURCE = (
    ROOT / "lib" / "DanTermProtocol" / "Sources" / "DanTermProtocol" / "PaneTapeStream.swift"
)


def load_converter():
    """Imports the converter for its constants. Its filename is not an identifier."""
    spec = importlib.util.spec_from_file_location("tape_to_fixture", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Read from the converter rather than restated here. A test that carried its own copy
# would keep passing against a version the app stopped emitting, which is exactly how
# this pair sat at 3 while `paneTapeStreamVersion` reached 5.
STREAM_VERSION = load_converter().STREAM_VERSION
FOLLOW_SAMPLE = ROOT / "scripts" / "tests" / "fixtures" / "pane-tape-follow.jsonl"

PROMPT_BYTES = b"\x1b]7;file://workstation/Users/alice/project\x07prompt\r\n"
SCRUBBED_PROMPT = b"\x1b]7;file://host/home/user/project\x07prompt\r\n"


class StreamVersionTests(unittest.TestCase):
    # Intent: the version the converter accepts is the version the app emits.
    # Why it exists: the converter refuses any other version outright, so a bump to
    #   `paneTapeStreamVersion` turns every live capture into an unconvertible file. The
    #   only thing that used to exercise the pair end to end was the opt-in
    #   `just test-cli`, so the converter sat two versions behind for the whole life of
    #   the pinned-geometry and bounded-sync-history changes without a run noticing.
    # Scenario: someone bumps the stream version and does not revisit this script.
    def test_converter_accepts_the_version_the_app_emits(self):
        source = PANE_TAPE_STREAM_SOURCE.read_text(encoding="utf-8")
        match = re.search(r"^public let paneTapeStreamVersion = (\d+)$", source, re.MULTILINE)
        self.assertIsNotNone(match, f"no paneTapeStreamVersion in {PANE_TAPE_STREAM_SOURCE}")
        self.assertEqual(
            STREAM_VERSION,
            int(match.group(1)),
            "terminal-tape-to-fixture.py is pinned to a different pane-tape stream version "
            "than the app emits. Read what the new version changed, update the record shape "
            "checks, then bump STREAM_VERSION.",
        )


class TerminalTapeToFixtureTests(unittest.TestCase):
    def run_converter(self, source, destination, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(source), str(destination), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    def convert(self, records, *arguments):
        """Runs the converter over one stream and returns the result with the fixture path."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        source = root / "capture.jsonl"
        destination = root / "fixture.json"
        source.write_text(json_lines(records), encoding="utf-8")
        return self.run_converter(source, destination, *arguments), destination

    def refuse(self, records, *arguments):
        """Asserts one stream is refused without leaving a fixture behind."""
        result, destination = self.convert(records, "--keep-identifiers", *arguments)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(destination.exists())
        return result

    def accept(self, records, *arguments):
        """Asserts one stream converts, and returns the fixture it wrote."""
        result, destination = self.convert(records, *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(destination.read_text(encoding="utf-8"))

    def test_capture_is_scrubbed_without_changing_boundaries_or_metadata(self):
        # Intent: a finite replay capture becomes admissible DanTerm evidence while
        #   retaining event boundaries, geometry, and timing.
        # Why it exists: conversion must not erase the exact drive sequence, and the
        #   fixture is only usable if its provenance says DanTerm rather than raw capture.
        # Scenario: a developer dumps a healthy dev pane after spotting a prompt artifact.
        fixture = self.accept(
            [
                stream_start(),
                byte_event(0, "feed", PROMPT_BYTES, offset=0, elapsed=12),
                plain_event(1, {"type": "resize", "columns": 79, "rows": 23, "pinned": False}, elapsed=25),
                stream_end("dump-complete"),
            ],
            "--test",
            "TerminalPromptRegressionTests",
            "--shell",
            "fish",
            "--stimulus",
            "dragged divider",
        )

        self.assertEqual(fixture["version"], 1)
        self.assertEqual(fixture["provenance"]["source"], "danterm")
        self.assertEqual(fixture["provenance"]["test"], "TerminalPromptRegressionTests")
        self.assertEqual(fixture["provenance"]["shell"], "fish")
        self.assertEqual(fixture["provenance"]["stimulus"], "dragged divider")
        self.assertEqual(fixture["initial"], {"columns": 80, "rows": 24})
        self.assertNotIn("truncation", fixture)
        self.assertEqual(
            fixture["events"],
            [
                {
                    "type": "feed",
                    "base64": base64.b64encode(SCRUBBED_PROMPT).decode("ascii"),
                    "elapsedNanoseconds": 12,
                },
                {"type": "resize", "columns": 79, "rows": 23, "pinned": False, "elapsedNanoseconds": 25},
            ],
        )

    def test_finite_and_followed_captures_convert_to_the_same_events(self):
        # Intent: the two captures are one recording contract, so the same events reach the
        #   fixture whichever one recorded them.
        # Why it exists: the stream carries the capture mode, and a converter that read the
        #   two modes through separate paths could quietly diverge on one of them.
        # Scenario: a developer reproduces a case once with a dump and once under --follow.
        events = [
            byte_event(0, "feed", b"hi", offset=0, elapsed=4),
            byte_event(1, "write", b"q", offset=0, elapsed=9, origin=7),
            plain_event(2, {"type": "resize", "columns": 90, "rows": 30, "pinned": False}, elapsed=11),
        ]
        finite = self.accept(
            [stream_start(), *events, stream_end("dump-complete")], "--keep-identifiers"
        )
        followed = self.accept(
            [stream_start("follow"), *events, stream_end("pane-closed")], "--keep-identifiers"
        )

        self.assertEqual(finite["events"], followed["events"])
        self.assertEqual(finite["initial"], followed["initial"])
        self.assertEqual(
            finite["events"],
            [
                {"type": "feed", "base64": "aGk=", "elapsedNanoseconds": 4},
                {
                    "type": "write",
                    "base64": "cQ==",
                    "elapsedNanoseconds": 9,
                    "originElapsedNanoseconds": 7,
                },
                {"type": "resize", "columns": 90, "rows": 30, "pinned": False, "elapsedNanoseconds": 11},
            ],
        )

    def test_follow_capture_is_evidence_however_it_stopped(self):
        # Intent: a followed capture converts when it ends at EOF, when the pane closed, and
        #   when the stream failed; each is exact evidence up to where it stopped.
        # Why it exists: a redirected follow exists to survive a crash, so demanding a clean
        #   terminator from it would throw away the recording it was taken for.
        events = [byte_event(0, "feed", b"a", offset=0, elapsed=1)]
        endings = {
            "eof": [],
            "pane-closed": [stream_end("pane-closed")],
            "stream-failed": [stream_end("stream-failed")],
        }
        for name, ending in endings.items():
            with self.subTest(ending=name):
                fixture = self.accept(
                    [stream_start("follow"), *events, *ending], "--keep-identifiers"
                )
                self.assertEqual(
                    fixture["events"],
                    [{"type": "feed", "base64": "YQ==", "elapsedNanoseconds": 1}],
                )

    def test_written_input_is_scrubbed_and_its_identifiers_still_refuse_conversion(self):
        # Intent: a write event's payload is scrubbed and identifier-checked exactly as a
        #   feed's is, and its origin stamp survives conversion untouched.
        # Why it exists: a tape records both directions, and a typed command line carries the
        #   same home path and hostname the prompt does. A converter that only scrubbed output
        #   would commit them anyway.
        # Scenario: a developer converts a tape in which they typed `cd /Users/alice/project`.
        typed = b"cd /Users/alice/project\r"
        fixture = self.accept(
            [
                stream_start("follow"),
                byte_event(0, "write", typed, offset=0, elapsed=30, origin=28),
            ]
        )

        self.assertEqual(
            base64.b64decode(fixture["events"][0]["base64"]), b"cd /home/user/project\r"
        )
        self.assertEqual(fixture["events"][0]["elapsedNanoseconds"], 30)
        self.assertEqual(fixture["events"][0]["originElapsedNanoseconds"], 28)

        leaked = b"echo " + local_identifier().encode()
        result, destination = self.convert(
            [stream_start("follow"), byte_event(0, "write", leaked, offset=0)]
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("identifiers survived scrubbing", result.stderr)
        self.assertFalse(destination.exists())

    def test_replacements_must_preserve_length_and_reach_both_directions(self):
        # Intent: --replace swaps a neutral value into either direction's payload, and a swap
        #   that would move the columns after it is an argument error.
        # Why it exists: a prompt framework pads to the pane width, so a length change would
        #   alter the wrapping the fixture exists to pin.
        records = [
            stream_start("follow"),
            byte_event(0, "feed", b"cluster-a ready", offset=0),
            byte_event(1, "write", b"ssh cluster-a", offset=0),
        ]
        fixture = self.accept(
            records,
            "--keep-identifiers",
            "--replace",
            "cluster-a=cluster-x",
            "--deviation",
            "cluster name replaced",
        )

        self.assertEqual(
            [base64.b64decode(event["base64"]) for event in fixture["events"]],
            [b"cluster-x ready", b"ssh cluster-x"],
        )
        self.assertEqual(fixture["provenance"]["recordedDeviations"], ["cluster name replaced"])

        result, destination = self.convert(
            records, "--keep-identifiers", "--replace", "cluster-a=x"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same non-zero length", result.stderr)
        self.assertFalse(destination.exists())

    def test_neutral_event_vocabulary_survives_conversion(self):
        # Intent: an event the neutral schema allows but the byte directions do not use --
        #   here a mouse move with its optional button -- reaches the fixture unchanged.
        fixture = self.accept(
            [
                stream_start(),
                plain_event(
                    0,
                    {"type": "mouse", "action": "move", "button": 1, "column": 3, "row": 2},
                ),
                stream_end("dump-complete"),
            ],
            "--keep-identifiers",
        )

        self.assertEqual(
            fixture["events"],
            [
                {
                    "type": "mouse",
                    "action": "move",
                    "button": 1,
                    "column": 3,
                    "row": 2,
                    "elapsedNanoseconds": 0,
                }
            ],
        )

    def test_inspect_streams_are_refused(self):
        # Intent: the derived readable view is never fixture evidence, even though every
        #   record around its payload is identical to the replay record's.
        # Why it exists: spans cannot be replayed, so admitting one would produce a fixture
        #   that silently lost the bytes it claims to pin.
        event = plain_event(0, {"type": "feed", "spans": [{"text": "hi"}]})
        event["byteOffset"] = 0
        event["byteLength"] = 2
        result = self.refuse(
            [stream_start(format="inspect"), event, stream_end("dump-complete")]
        )

        self.assertIn("inspect", result.stderr)

    def test_gaps_are_refused_wherever_the_producer_reports_them(self):
        # Intent: a stream that lost bytes is refused, whether the loss precedes the first
        #   retained event or interrupts a live follow.
        # Why it exists: an evicted recording no longer covers the run it appears to, so
        #   replay conclusions drawn from it can be unsound. There is no override.
        gap = {
            "kind": "gap",
            "droppedEventCount": 3,
            "droppedFeedBytes": 47,
            "droppedWriteBytes": 2,
        }
        cases = {
            "leading gap": [stream_start("follow"), gap],
            "interior gap": [
                stream_start("follow"),
                byte_event(0, "feed", b"a", offset=0),
                gap,
            ],
            # A finite dump can only lose bytes before its oldest retained event, so its gap
            # arrives right after the start and its terminator still says the dump completed.
            # That capture is a whole, successful dump of a partial recording, and it is the
            # one shape most likely to be mistaken for evidence of the whole run.
            "truncated finite dump": [
                stream_start("dump"),
                gap,
                byte_event(3, "feed", b"a", offset=47),
                stream_end("dump-complete"),
            ],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                result = self.refuse(records)
                self.assertIn("dropped events", result.stderr)

        # The escape hatch is absent rather than merely unused: the converter defines no flag
        # that admits a lossy tape, so asking for one is an argument error. Assert that
        # specific rejection -- a bare "it failed" would also pass if the flag existed.
        result, destination = self.convert(
            cases["leading gap"], "--keep-identifiers", "--allow-truncated"
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments: --allow-truncated", result.stderr)
        self.assertFalse(destination.exists())

    def test_superseded_capture_formats_are_refused(self):
        # Intent: neither the old single-document snapshot nor the version 1 JSONL stream is
        #   a tape any more, and each is refused by name rather than by accident.
        # Why it exists: both shapes still exist in old files and old scratch directories,
        #   and silently misreading one would produce a fixture with no byte accounting.
        snapshot_document = {
            "version": 1,
            "provenance": {"source": "danterm-live-capture"},
            "initial": {"columns": 80, "rows": 24},
            "events": [{"type": "feed", "base64": "YQ=="}],
        }
        version_one_start = {
            "kind": "start",
            "version": 1,
            "provenance": {"source": "danterm-live-capture"},
            "initial": {"columns": 80, "rows": 24},
        }
        bare_event_lines = [
            {"initial": {"columns": 4, "rows": 2}},
            {"type": "feed", "hex": "6162"},
        ]

        document = self.refuse([snapshot_document])
        self.assertIn("single JSON document", document.stderr)

        version_one = self.refuse(
            [version_one_start, plain_event(0, {"type": "feed", "base64": "YQ=="})]
        )
        self.assertIn("version", version_one.stderr)

        self.refuse(bare_event_lines)

    def test_json_rpc_envelopes_are_refused(self):
        # Intent: the socket transport's notification wrapper is not a persisted recording.
        envelope = {
            "jsonrpc": "2.0",
            "method": "pane.tape.event",
            "params": {"record": byte_event(0, "feed", b"a", offset=0)},
        }
        self.refuse([stream_start("follow"), envelope])

    def test_records_out_of_order_are_refused(self):
        cases = {
            "event before start": [byte_event(0, "feed", b"a", offset=0)],
            "second start": [stream_start("follow"), stream_start("follow")],
            "record after end": [
                stream_start("follow"),
                stream_end("pane-closed"),
                byte_event(0, "feed", b"a", offset=0),
            ],
            "second end": [
                stream_start("follow"),
                stream_end("pane-closed"),
                stream_end("pane-closed"),
            ],
            "unknown record": [stream_start("follow"), {"kind": "note", "text": "x"}],
            "empty stream": [],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                self.refuse(records)

    def test_a_finite_capture_without_its_end_record_is_refused(self):
        # Intent: a snapshot that stops before its terminator is an incomplete delivery, not
        #   a short recording, and the follow capture's EOF allowance does not cover it.
        # Why it exists: a finite dump is fenced, so nothing can arrive later to extend it.
        #   Records that simply stop mean the connection died mid-delivery.
        result = self.refuse([stream_start(), byte_event(0, "feed", b"a", offset=0)])

        self.assertIn("end record", result.stderr)

    def test_end_reasons_must_match_the_capture_that_stated_them(self):
        cases = {
            "dump ends as a follow": [
                stream_start(),
                stream_end("pane-closed"),
            ],
            "follow ends as a dump": [
                stream_start("follow"),
                stream_end("dump-complete"),
            ],
            "unknown reason": [stream_start("follow"), stream_end("bored")],
            "reasonless end": [stream_start("follow"), {"kind": "end"}],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                self.refuse(records)

    def test_sequence_must_continue_the_streams_stated_cursor(self):
        # Intent: the first event continues the start cursor, and each later event continues
        #   the one before it.
        # Why it exists: a missing event is exactly what a fixture cannot survive, and a
        #   stream that begins past the beginning states the baseline for it.
        cases = {
            "jump from the cursor": [
                stream_start("follow", sequence=41),
                byte_event(43, "feed", b"a", offset=0),
            ],
            "jump between events": [
                stream_start("follow"),
                byte_event(0, "feed", b"a", offset=0),
                byte_event(2, "feed", b"b", offset=1),
            ],
            "repeated sequence": [
                stream_start("follow"),
                byte_event(0, "feed", b"a", offset=0),
                byte_event(0, "feed", b"b", offset=1),
            ],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                result = self.refuse(records)
                self.assertIn("does not continue the stream", result.stderr)

        accepted = self.accept(
            [
                stream_start("follow", sequence=41, feed_offset=700),
                byte_event(41, "feed", b"a", offset=700),
                byte_event(42, "feed", b"b", offset=701),
            ],
            "--keep-identifiers",
        )
        self.assertEqual(len(accepted["events"]), 2)

    def test_byte_offsets_must_continue_their_own_direction(self):
        # Intent: each direction's offsets are checked against that direction's running
        #   total, starting from the start cursor's own baseline for that direction.
        # Why it exists: feed and write bytes are numbered apart. A converter that kept one
        #   combined total would accept a feed offset that continued the write stream, and
        #   miss a lost event in either direction.
        cases = {
            "feed skips ahead": [
                stream_start("follow"),
                byte_event(0, "feed", b"a", offset=0),
                byte_event(1, "feed", b"b", offset=5),
            ],
            "write continues the feed total": [
                stream_start("follow"),
                byte_event(0, "feed", b"abc", offset=0),
                byte_event(1, "write", b"q", offset=3),
            ],
            "feed ignores the start baseline": [
                stream_start("follow", feed_offset=700),
                byte_event(0, "feed", b"a", offset=0),
            ],
            "feed continues the write baseline": [
                stream_start("follow", feed_offset=700, write_offset=40),
                byte_event(0, "feed", b"a", offset=40),
            ],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                result = self.refuse(records)
                self.assertIn("does not continue that direction", result.stderr)

        # The two directions advance independently from their own baselines, so a stream
        # that interleaves them keeps two separate running totals.
        accepted = self.accept(
            [
                stream_start("follow", feed_offset=700, write_offset=40),
                byte_event(0, "feed", b"abc", offset=700),
                byte_event(1, "write", b"q", offset=40),
                byte_event(2, "feed", b"de", offset=703),
                byte_event(3, "write", b"r", offset=41),
            ],
            "--keep-identifiers",
        )
        self.assertEqual(len(accepted["events"]), 4)

    def test_byte_positions_belong_to_byte_carrying_events_alone(self):
        cases = {
            "feed without a position": [
                stream_start("follow"),
                plain_event(0, {"type": "feed", "base64": "YQ=="}),
            ],
            "feed without a length": [
                stream_start("follow"),
                {
                    "kind": "event",
                    "sequence": 0,
                    "elapsedNanoseconds": 0,
                    "byteOffset": 0,
                    "event": {"type": "feed", "base64": "YQ=="},
                },
            ],
            "resize with a position": [
                stream_start("follow"),
                {
                    "kind": "event",
                    "sequence": 0,
                    "elapsedNanoseconds": 0,
                    "byteOffset": 0,
                    "byteLength": 0,
                    "event": {"type": "resize", "columns": 8, "rows": 2, "pinned": False},
                },
            ],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                self.refuse(records)

        # An empty payload still states its position: it is an event that carried bytes,
        # and zero of them is a fact about the transfer rather than the absence of one.
        accepted = self.accept(
            [stream_start("follow"), byte_event(0, "feed", b"", offset=0)],
            "--keep-identifiers",
        )
        self.assertEqual(accepted["events"], [{"type": "feed", "base64": "", "elapsedNanoseconds": 0}])

    def test_payload_length_and_encoding_must_match_the_stated_bytes(self):
        cases = {
            "length too short": [
                stream_start("follow"),
                byte_event(0, "feed", b"abc", offset=0, length=2),
            ],
            "length too long": [
                stream_start("follow"),
                byte_event(0, "feed", b"abc", offset=0, length=4),
            ],
            "negative length": [
                stream_start("follow"),
                byte_event(0, "feed", b"abc", offset=0, length=-3),
            ],
        }
        for name, records in cases.items():
            with self.subTest(name=name):
                self.refuse(records)

        malformed = self.refuse(
            [
                stream_start("follow"),
                {
                    "kind": "event",
                    "sequence": 0,
                    "elapsedNanoseconds": 0,
                    "byteOffset": 0,
                    "byteLength": 1,
                    "event": {"type": "feed", "base64": "not base64!"},
                },
            ]
        )
        self.assertIn("base64", malformed.stderr)

        not_json = self.refuse_text("{\"kind\":\"start\"\n")
        self.assertIn("not one JSON record", not_json.stderr)

    def test_invalid_event_shapes_are_refused_in_both_directions(self):
        invalid_events = {
            "missing payload": {"type": "feed"},
            "multiple payloads": {"type": "feed", "base64": "YQ==", "text": "a"},
            "hex payload": {"type": "feed", "hex": "61"},
            "unknown field": {"type": "feed", "base64": "YQ==", "note": "x"},
            "origin on output": {"type": "feed", "base64": "YQ=="},
            "write missing payload": {"type": "write"},
            "write hex payload": {"type": "write", "hex": "61"},
            "write unknown field": {"type": "write", "base64": "YQ==", "note": "x"},
            "unsupported type": {"type": "telepathy"},
        }
        for name, event in invalid_events.items():
            with self.subTest(name=name):
                record = {
                    "kind": "event",
                    "sequence": 0,
                    "elapsedNanoseconds": 0,
                    "byteOffset": 0,
                    "byteLength": 1,
                    "event": event,
                }
                if name == "origin on output":
                    # An origin belongs only to bytes travelling toward the child: child
                    # output is read and recorded in one turn, so a second stamp on it would
                    # restate the first.
                    record["originElapsedNanoseconds"] = 1
                self.refuse([stream_start("follow"), record])

    def test_stream_metadata_outside_its_stated_shape_is_refused(self):
        cases = {
            "not a live capture": [stream_start("follow", provenance={"source": "danterm"})],
            "unknown capture mode": [stream_start("spelunk")],
            "unknown format": [stream_start("follow", format="hex")],
            "extra start field": [stream_start("follow", note="x")],
            "missing cursor": [start_without("cursor")],
            "partial cursor": [
                stream_start("follow", cursor={"sequence": 0, "feedByteOffset": 0})
            ],
            "negative cursor": [
                stream_start(
                    "follow",
                    cursor={"sequence": 0, "feedByteOffset": -1, "writeByteOffset": 0},
                )
            ],
            "geometry with extra keys": [
                stream_start("follow", initial={"columns": 80, "rows": 24, "depth": 1})
            ],
            "geometry that is not numbers": [
                stream_start("follow", initial={"columns": "80", "rows": 24})
            ],
            "negative elapsed": [
                stream_start("follow"),
                byte_event(0, "feed", b"a", offset=0, elapsed=-1),
            ],
            "timing inside the event": [
                stream_start("follow"),
                byte_event(0, "feed", b"a", offset=0),
            ],
        }
        cases["timing inside the event"][1]["event"]["elapsedNanoseconds"] = 5
        for name, records in cases.items():
            with self.subTest(name=name):
                self.refuse(records)

    def test_committed_follow_sample_is_convertible(self):
        # Intent: the checked-in sample stays a valid follow capture at the stream version
        #   the converter accepts, so the shape this suite builds by hand is anchored to
        #   one whole recording.
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "fixture.json"

            result = self.run_converter(FOLLOW_SAMPLE, destination, "--keep-identifiers")

            self.assertEqual(result.returncode, 0, result.stderr)
            fixture = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(
                fixture["events"],
                [
                    {"type": "feed", "base64": "SGk=", "elapsedNanoseconds": 2},
                    {
                        "type": "resize",
                        "columns": 90,
                        "rows": 30,
                        "pinned": False,
                        "elapsedNanoseconds": 5,
                    },
                    {
                        "type": "write",
                        "base64": "cQ==",
                        "elapsedNanoseconds": 9,
                        "originElapsedNanoseconds": 7,
                    },
                ],
            )

    def refuse_text(self, contents: str):
        """Asserts one file the JSON Lines reader cannot even parse is refused."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        source = root / "capture.jsonl"
        destination = root / "fixture.json"
        source.write_text(contents, encoding="utf-8")

        result = self.run_converter(source, destination, "--keep-identifiers")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        return result


def local_identifier():
    """This machine's hostname, which the scrub rules only reach inside an OSC 7 URL."""
    return socket.gethostname()


def stream_start(capture="dump", *, sequence=0, feed_offset=0, write_offset=0, **overrides):
    record = {
        "kind": "start",
        "version": STREAM_VERSION,
        "capture": capture,
        "format": "replay",
        "reconstructible": False,
        "provenance": {
            "source": "danterm-live-capture",
            "author": "DanTerm",
            "test": "live-pane-tape",
            "recordedDeviations": [],
        },
        "initial": {"columns": 80, "rows": 24, "pinned": False},
        "cursor": {
            "recorderLifetimeId": "11111111-1111-4111-8111-111111111111",
            "sequence": sequence,
            "feedByteOffset": feed_offset,
            "writeByteOffset": write_offset,
        },
    }
    record.update(overrides)
    return record


def start_without(key):
    record = stream_start("follow")
    del record[key]
    return record


def byte_event(sequence, direction, raw, *, offset, elapsed=0, origin=None, length=None):
    record = {
        "kind": "event",
        "sequence": sequence,
        "elapsedNanoseconds": elapsed,
        "byteOffset": offset,
        "byteLength": len(raw) if length is None else length,
        "event": {"type": direction, "base64": base64.b64encode(raw).decode("ascii")},
    }
    if origin is not None:
        record["originElapsedNanoseconds"] = origin
    return record


def plain_event(sequence, event, elapsed=0):
    return {
        "kind": "event",
        "sequence": sequence,
        "elapsedNanoseconds": elapsed,
        "event": event,
    }


def stream_end(reason):
    return {"kind": "end", "reason": reason}


def json_lines(records):
    return "".join(json.dumps(record) + "\n" for record in records)


if __name__ == "__main__":
    unittest.main()
