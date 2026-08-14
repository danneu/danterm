#!/usr/bin/env python3
"""Scrub a live-pane terminal tape into a neutral replay fixture.

A tape is the version 3 raw JSON Lines stream printed by `danterm pane tape --pane
ID`, with or without `--follow`. Its events already use the neutral recording
schema, including real PTY chunk boundaries and resize ordering, so this script
only scrubs the byte payloads they carry in either direction, verifies that local
identifiers are gone, and marks the result as fixture-ready DanTerm evidence.

The stream must be exact replay evidence. A `--format inspect` stream, a stream
that reports a `gap`, a JSON-RPC envelope, and any older capture format are
refused unconditionally. So is a record whose sequence or byte offset does not
continue the stream, because a fixture is only evidence if it is the whole run of
bytes the pane saw. A finite capture must carry its `end` record; a `--follow`
capture may stop at EOF, because that is what surviving an app crash looks like.

    scripts/terminal-tape-to-fixture.py /tmp/tape.jsonl \\
        lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/my-case.json

The summary this prints (event count, resize count, resize geometries) helps
confirm that the dump contains the interaction that exposed the artifact.

Scrubbing is on by default and is not cosmetic: a tape is verbatim terminal
traffic, so it carries the recording machine's hostname and home directory in
every OSC 7 report, usually in the prompt itself, and again in any path the
operator typed at that prompt. Fixtures are committed, so they must be neutral.
After scrubbing, the script checks the result against this
machine's own hostname, username and home path and refuses to write a fixture
that still contains any of them -- a prompt framework can render an identifier
somewhere the OSC 7 rules never look. `--keep-identifiers` skips both steps for
a tape you are only replaying locally.

Anything else a prompt renders that should not be committed -- a cluster name, a
project path -- goes through `--replace OLD=NEW` with `--deviation` describing
it. The swap is length-preserving because a prompt framework pads to the pane
width: changing a segment's length would move every column after it and quietly
alter the wrapping the fixture exists to pin.
"""
import argparse
import base64
import binascii
import json
import os
import re
import socket
import sys

# OSC 7 reports the cwd as a file URL, so the host and the home path arrive as
# ASCII in the recorded bytes; a prompt that shows `user@host` or `~/...` puts
# them there a second time, and so does a path the operator typed. Replacements
# need not preserve length: chunk boundaries
# are the event split points, which are untouched either way.
SCRUBS = [
    (re.compile(rb"(?<=file://)[A-Za-z0-9._-]+"), b"host"),
    (re.compile(rb"/Users/[A-Za-z0-9._-]+"), b"/home/user"),
]


def scrub(raw: bytes) -> bytes:
    for pattern, replacement in SCRUBS:
        raw = pattern.sub(replacement, raw)
    return raw


def local_identifiers() -> list:
    """This machine's identifiers, as bytes, longest first.

    The scrub rules encode the two shapes seen so far. This is the backstop for
    the third: whatever a prompt framework decided to print.
    """
    host = socket.gethostname()
    candidates = {host, host.split(".")[0], os.path.expanduser("~"),
                  os.environ.get("USER", "")}
    # Two characters is below the length at which a match means anything.
    return sorted((c.encode() for c in candidates if len(c) > 2), key=len, reverse=True)


STREAM_VERSION = 3
START_KEYS = {
    "kind", "version", "capture", "format", "reconstructible", "provenance",
    "initial", "cursor",
}
CURSOR_KEYS = {"recorderLifetimeId", "sequence", "feedByteOffset", "writeByteOffset"}
EVENT_KEYS = {"kind", "sequence", "elapsedNanoseconds", "event"}
EVENT_OPTIONAL_KEYS = {"originElapsedNanoseconds", "byteOffset", "byteLength"}
# A finite capture always states its own end, so a missing one means the records stop
# somewhere the producer never chose. A follow capture legitimately stops at EOF.
END_REASONS = {"dump": {"dump-complete"}, "follow": {"pane-closed", "stream-failed"}}


def load_tape(path: str):
    """Loads one version 3 raw pane-tape replay stream as a flat neutral recording."""
    with open(path, encoding="utf-8") as handle:
        contents = handle.read()
    return load_replay_stream(parse_records(contents))


def parse_records(contents: str) -> list:
    """Reads the file as JSON Lines, naming the one older shape that is not."""
    lines = [line for line in contents.splitlines() if line.strip()]
    if not lines:
        raise ValueError("recording is empty")
    records = []
    for number, line in enumerate(lines, start=1):
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise ValueError(f"line {number} is not one JSON record: {error.msg}") from error
    if len(records) == 1 and isinstance(records[0], dict) and "kind" not in records[0]:
        raise ValueError("recording is a single JSON document, not a pane-tape stream")
    return records


def load_replay_stream(records: list):
    """Flattens one ordered pane-tape stream into a neutral recording, or refuses it.

    Every check here answers the same question: are these records the whole run of bytes
    the pane saw, stated by a producer that could still speak? Order, sequence, per-
    direction byte position, and the terminator all bear on it, so none of them is
    cosmetic and none of them has an override.
    """
    start = records[0]
    if not isinstance(start, dict) or start.get("kind") != "start":
        raise ValueError("recording does not begin with a start record")
    version = start.get("version")
    if isinstance(version, bool) or version != STREAM_VERSION:
        raise ValueError(f"unsupported pane-tape stream version: {version!r}")
    if set(start) != START_KEYS:
        raise ValueError("invalid start record")
    capture = start["capture"]
    if capture not in END_REASONS:
        raise ValueError(f"invalid capture mode: {capture!r}")
    if start["reconstructible"] is not False:
        raise ValueError("a reconstructible stream contains synthesized state, not raw evidence")
    stream_format = start["format"]
    if stream_format == "inspect":
        raise ValueError("an inspect stream is a derived view, not replay evidence")
    if stream_format != "replay":
        raise ValueError(f"invalid stream format: {stream_format!r}")
    provenance = start["provenance"]
    if not isinstance(provenance, dict) or provenance.get("source") != "danterm-live-capture":
        raise ValueError("recording is not a raw DanTerm live capture")
    initial = start["initial"]
    if (
        not isinstance(initial, dict)
        or set(initial) != {"columns", "rows"}
        or not all(integer(initial[key]) for key in initial)
    ):
        raise ValueError("invalid start geometry")
    cursor = start["cursor"]
    if (
        not isinstance(cursor, dict)
        or set(cursor) != CURSOR_KEYS
        or not isinstance(cursor["recorderLifetimeId"], str)
        or not cursor["recorderLifetimeId"]
        or not all(nonnegative_integer(cursor[key]) for key in CURSOR_KEYS - {"recorderLifetimeId"})
    ):
        raise ValueError("invalid start cursor")

    events = []
    expected_sequence = cursor["sequence"]
    # The start cursor is the baseline each direction's first offset must match, so a
    # capture that begins past the beginning is still checked against a stated origin.
    offsets = {"feed": cursor["feedByteOffset"], "write": cursor["writeByteOffset"]}
    ended = False
    for record in records[1:]:
        if not isinstance(record, dict) or not isinstance(record.get("kind"), str):
            raise ValueError("invalid stream record")
        if ended:
            raise ValueError("stream contains a record after end")
        kind = record["kind"]
        if kind == "gap":
            raise ValueError("stream reports dropped events")
        if kind == "start":
            raise ValueError("stream contains a second start record")
        if kind == "end":
            validate_end(record, capture)
            ended = True
            continue
        if kind != "event":
            raise ValueError(f"unsupported stream record: {kind}")
        events.append(read_event(record, expected_sequence, offsets))
        expected_sequence += 1

    if capture == "dump" and not ended:
        raise ValueError("finite capture stops without its end record")
    return {"initial": initial, "events": events}


def validate_end(record: dict, capture: str):
    """Require the terminator the capture that stated it is allowed to end with."""
    if set(record) != {"kind", "reason"}:
        raise ValueError("invalid end record")
    reason = record["reason"]
    if reason not in END_REASONS[capture]:
        raise ValueError(f"a {capture} capture cannot end with reason {reason!r}")


def read_event(record: dict, expected_sequence: int, offsets: dict) -> dict:
    """Check one event record against the stream's running position, then flatten it."""
    if not EVENT_KEYS <= set(record) <= EVENT_KEYS | EVENT_OPTIONAL_KEYS:
        raise ValueError("invalid event record")
    sequence = record["sequence"]
    if not nonnegative_integer(sequence):
        raise ValueError("invalid event record")
    if sequence != expected_sequence:
        raise ValueError(
            f"event sequence {sequence} does not continue the stream at {expected_sequence}"
        )
    elapsed = record["elapsedNanoseconds"]
    event = record["event"]
    if (
        not nonnegative_integer(elapsed)
        or not isinstance(event, dict)
        or not isinstance(event.get("type"), str)
        or "elapsedNanoseconds" in event
        or "originElapsedNanoseconds" in event
    ):
        raise ValueError("invalid event record")

    # The stream hoists both stamps above the event; the neutral shape carries them inside
    # it, and validate_event admits an origin on write events alone.
    flattened = {**event, "elapsedNanoseconds": elapsed}
    if "originElapsedNanoseconds" in record:
        origin = record["originElapsedNanoseconds"]
        if not nonnegative_integer(origin):
            raise ValueError("invalid event record")
        flattened["originElapsedNanoseconds"] = origin
    validate_event(flattened)
    read_payload_position(record, flattened, offsets)
    return flattened


def read_payload_position(record: dict, event: dict, offsets: dict):
    """Hold each direction's byte offsets to one contiguous run of that direction's bytes.

    Feed and write bytes are numbered apart, so a stream that continued a feed offset from
    the write total would still look monotonic. Only measuring each direction against its
    own running total catches a missing event, and only comparing the stated length with
    the decoded payload catches a payload that was rewritten after it was recorded.
    """
    stated = {"byteOffset", "byteLength"} & set(record)
    direction = event["type"] if event["type"] in offsets else None
    if direction is None:
        if stated:
            raise ValueError(f"a {event['type']} event carries no bytes to place")
        return
    if stated != {"byteOffset", "byteLength"}:
        raise ValueError(f"{direction} event is missing its byte position")
    offset = record["byteOffset"]
    length = record["byteLength"]
    if not nonnegative_integer(offset) or not nonnegative_integer(length):
        raise ValueError("invalid event byte position")
    if offset != offsets[direction]:
        raise ValueError(
            f"{direction} byteOffset {offset} does not continue that direction "
            f"at {offsets[direction]}"
        )
    _, raw = decode_payload(event)
    if length != len(raw):
        raise ValueError(f"{direction} byteLength {length} disagrees with its {len(raw)} bytes")
    offsets[direction] = offset + length


def decode_payload(event: dict):
    encodings = [key for key in ("base64", "text") if key in event]
    if len(encodings) != 1:
        raise ValueError("byte event must contain exactly one byte encoding")
    encoding = encodings[0]
    try:
        if encoding == "base64":
            return encoding, base64.b64decode(event[encoding], validate=True)
        return encoding, event[encoding].encode("utf-8")
    except (binascii.Error, ValueError, AttributeError) as error:
        raise ValueError(f"invalid {encoding} byte event") from error


def encode_payload(event: dict, encoding: str, raw: bytes):
    if encoding == "base64":
        event[encoding] = base64.b64encode(raw).decode("ascii")
    else:
        event[encoding] = raw.decode("utf-8")


def validate_event(event: dict):
    """Reject any neutral event outside its complete allowed object shape."""
    if not isinstance(event, dict) or not isinstance(event.get("type"), str):
        raise ValueError("invalid recording event")
    event_type = event["type"]
    elapsed = event.get("elapsedNanoseconds")
    if "elapsedNanoseconds" in event and not nonnegative_integer(elapsed):
        raise ValueError(f"invalid {event_type} event")

    if event_type in ("feed", "write"):
        encodings = [key for key in ("base64", "text") if key in event]
        if len(encodings) != 1:
            raise ValueError(f"invalid {event_type} event")
        encoding = encodings[0]
        # Only bytes travelling toward the child have an origin earlier than their transfer.
        optional = {"elapsedNanoseconds"}
        if event_type == "write":
            optional.add("originElapsedNanoseconds")
            if "originElapsedNanoseconds" in event and not nonnegative_integer(
                event["originElapsedNanoseconds"]
            ):
                raise ValueError("invalid write event")
        require_shape(event, {"type", encoding}, optional)
        if not isinstance(event[encoding], str):
            raise ValueError(f"invalid {event_type} event")
        return
    if event_type == "resize":
        require_shape(event, {"type", "columns", "rows"}, {"elapsedNanoseconds"})
        if not all(integer(event[key]) for key in ("columns", "rows")):
            raise ValueError("invalid resize event")
        return
    if event_type == "input":
        key = event.get("key")
        required = {"type", "key", "scalar"} if key == "character" else {"type", "key"}
        require_shape(event, required, {"modifiers", "elapsedNanoseconds"})
        if not isinstance(key, str) or ("scalar" in event and not isinstance(event["scalar"], str)):
            raise ValueError("invalid input event")
        validate_modifiers(event, event_type)
        return
    if event_type == "paste":
        require_shape(event, {"type", "text"}, {"elapsedNanoseconds"})
        if not isinstance(event["text"], str):
            raise ValueError("invalid paste event")
        return
    if event_type == "focus":
        require_shape(event, {"type", "focused"}, {"elapsedNanoseconds"})
        if not isinstance(event["focused"], bool):
            raise ValueError("invalid focus event")
        return
    if event_type == "mouse":
        require_shape(
            event,
            {"type", "action", "column", "row"},
            {"button", "modifiers", "clickCount", "elapsedNanoseconds"},
        )
        action = event["action"]
        if action not in ("down", "up", "move"):
            raise ValueError("invalid mouse event")
        if "button" in event and not integer(event["button"]):
            raise ValueError("invalid mouse event")
        if not integer(event["column"]) or not integer(event["row"]):
            raise ValueError("invalid mouse event")
        if "clickCount" in event and not integer(event["clickCount"]):
            raise ValueError("invalid mouse event")
        validate_modifiers(event, event_type)
        return
    if event_type == "viewport":
        action = event.get("action")
        required = {"type", "action"}
        if action in ("byRows", "toTopRow"):
            required.add("rows")
        require_shape(event, required, {"elapsedNanoseconds"})
        if action not in ("byRows", "toTopRow", "toBottom"):
            raise ValueError("invalid viewport event")
        if "rows" in event and not integer(event["rows"]):
            raise ValueError("invalid viewport event")
        return
    if event_type == "expect":
        require_shape(event, {"type"}, {"expect", "elapsedNanoseconds"})
        if "expect" in event and not isinstance(event["expect"], dict):
            raise ValueError("invalid expect event")
        return
    raise ValueError(f"unsupported recording event: {event_type}")


def require_shape(event: dict, required: set, optional: set):
    """Require one event's keys to match its closed schema."""
    keys = set(event)
    if not required <= keys or not keys <= required | optional:
        raise ValueError(f"invalid {event.get('type', 'recording')} event")


def integer(value) -> bool:
    """Recognize JSON integers without accepting Python's boolean subtype."""
    return isinstance(value, int) and not isinstance(value, bool)


def nonnegative_integer(value) -> bool:
    """Recognize the unsigned integer domain used by elapsed timing."""
    return integer(value) and value >= 0


def validate_modifiers(event: dict, event_type: str):
    """Validate an optional neutral modifier-name list shared by input events."""
    if "modifiers" not in event:
        return
    modifiers = event["modifiers"]
    if not isinstance(modifiers, list) or not all(
        modifier in ("shift", "alt", "control", "command") for modifier in modifiers
    ):
        raise ValueError(f"invalid {event_type} event")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tape", help="version 3 raw replay JSONL from `danterm pane tape`")
    parser.add_argument("fixture", help="fixture JSON to write")
    parser.add_argument("--keep-identifiers", action="store_true",
                        help="skip host/home scrubbing (local-only tapes)")
    parser.add_argument("--test", default="TerminalShellDialectTests",
                        help="behavioral test this recording is evidence for")
    parser.add_argument("--shell", default="", help="what was running in the pane")
    parser.add_argument("--stimulus", default="", help="what the operator did to it")
    parser.add_argument("--replace", action="append", default=[], metavar="OLD=NEW",
                        help="swap a neutral value in, same length so columns do not move")
    parser.add_argument("--deviation", action="append", default=[], metavar="TEXT",
                        help="how the fixture differs from the tape, one per --replace")
    args = parser.parse_args()

    swaps = []
    for pair in args.replace:
        old, _, new = pair.partition("=")
        if len(old) != len(new) or not old:
            print(f"--replace {pair}: both sides must be the same non-zero length",
                  file=sys.stderr)
            return 1
        swaps.append((old.encode(), new.encode()))

    try:
        tape = load_tape(args.tape)
    except (OSError, ValueError) as error:
        print(f"{args.tape}: {error}", file=sys.stderr)
        return 1

    events = tape["events"]
    identifiers = [] if args.keep_identifiers else local_identifiers()
    leftovers = set()
    for event in events:
        if event.get("type") not in ("feed", "write"):
            continue
        try:
            encoding, raw = decode_payload(event)
        except ValueError as error:
            print(f"{args.tape}: {error}", file=sys.stderr)
            return 1
        if not args.keep_identifiers:
            raw = scrub(raw)
            leftovers.update(i.decode() for i in identifiers if i in raw)
        for old, new in swaps:
            raw = raw.replace(old, new)
        try:
            encode_payload(event, encoding, raw)
        except UnicodeDecodeError:
            print(f"{args.tape}: replacement made a text payload invalid UTF-8", file=sys.stderr)
            return 1

    if leftovers:
        print(f"identifiers survived scrubbing: {sorted(leftovers)}", file=sys.stderr)
        print("extend SCRUBS, or pass --keep-identifiers to keep it local", file=sys.stderr)
        return 1

    resizes = [e for e in events if e.get("type") == "resize"]
    note = ("verbatim pane output; host and home path scrubbed to neutral values, "
            "no other bytes altered" if not args.keep_identifiers
            else "verbatim pane output, unscrubbed")
    # `source: danterm` plus an author and a test is what NeutralTerminalRecording's
    # own validation accepts, so the fixture replays through the shared decoder rather
    # than only through a test's local one.
    provenance = {"source": "danterm", "author": "DanTerm", "test": args.test,
                  "recordedDeviations": args.deviation, "note": note}
    if args.shell:
        provenance["shell"] = args.shell
    if args.stimulus:
        provenance["stimulus"] = args.stimulus

    fixture = {"version": 1, "initial": tape["initial"], "events": events,
               "provenance": provenance}
    with open(args.fixture, "w", encoding="utf-8") as handle:
        json.dump(fixture, handle)
        handle.write("\n")

    print(f"{len(events)} events, {len(resizes)} resizes, initial {tape['initial']}")
    if resizes:
        print("resize geometries:", [(r["columns"], r["rows"]) for r in resizes])
    print("wrote", args.fixture)
    return 0


if __name__ == "__main__":
    sys.exit(main())
