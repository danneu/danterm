#!/usr/bin/env python3
"""Scrub a live-pane terminal tape into a neutral replay fixture.

A tape is normally the JSON document printed by `danterm pane tape --pane ID`.
It already uses the neutral recording schema, including real PTY chunk boundaries
and resize ordering, so this script only scrubs feed bytes, verifies that local
identifiers are gone, and marks the result as fixture-ready DanTerm evidence.
The input may instead be the JSONL stream written by `danterm pane tape --follow`.

    scripts/terminal-tape-to-fixture.py /tmp/tape.json \\
        lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/my-case.json

The summary this prints (event count, resize count, resize geometries) helps
confirm that the dump contains the interaction that exposed the artifact.

Scrubbing is on by default and is not cosmetic: a tape is verbatim terminal
output, so it carries the recording machine's hostname and home directory in
every OSC 7 report, and usually in the prompt itself. Fixtures are committed, so
they must be neutral. After scrubbing, the script checks the result against this
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
# ASCII in the feed bytes; a prompt that shows `user@host` or `~/...` puts them
# there a second time. Replacements need not preserve length: chunk boundaries
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


def load_tape(path: str):
    """Loads a complete live-capture snapshot or an ordered follow stream."""
    with open(path, encoding="utf-8") as handle:
        contents = handle.read()
    try:
        document = json.loads(contents)
    except json.JSONDecodeError:
        document = None

    if isinstance(document, dict) and all(
        key in document for key in ("version", "provenance", "initial", "events")
    ):
        provenance = document.get("provenance")
        if not isinstance(provenance, dict) or provenance.get("source") != "danterm-live-capture":
            raise ValueError("recording is not a raw DanTerm live capture")
        events = document.get("events")
        if not isinstance(events, list):
            raise ValueError("invalid snapshot events")
        for event in events:
            validate_event(event)
        return document, document.get("truncation")

    try:
        lines = [json.loads(line) for line in contents.splitlines() if line.strip()]
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid tape JSON: {error.msg}") from error
    if lines and isinstance(lines[0], dict) and lines[0].get("kind") == "start":
        return load_follow_stream(lines), None
    raise ValueError("recording is neither a snapshot nor a follow stream")


def load_follow_stream(records: list):
    """Flatten one ordered pane-tape follow stream into a snapshot-shaped value."""
    start = records[0]
    if set(start) != {"kind", "version", "provenance", "initial"}:
        raise ValueError("invalid follow start record")
    if isinstance(start["version"], bool) or start["version"] != 1:
        raise ValueError("unsupported follow stream version")
    provenance = start["provenance"]
    if not isinstance(provenance, dict) or provenance.get("source") != "danterm-live-capture":
        raise ValueError("recording is not a raw DanTerm live capture")
    initial = start["initial"]
    if not isinstance(initial, dict) or set(initial) != {"columns", "rows"}:
        raise ValueError("invalid follow start geometry")

    events = []
    previous_sequence = None
    ended = False
    for record in records[1:]:
        if not isinstance(record, dict) or not isinstance(record.get("kind"), str):
            raise ValueError("invalid follow stream record")
        if ended:
            raise ValueError("follow stream contains a record after end")
        kind = record["kind"]
        if kind == "gap":
            raise ValueError("follow stream dropped events")
        if kind == "end":
            if (
                set(record) not in ({"kind"}, {"kind", "reason"})
                or ("reason" in record and not isinstance(record["reason"], str))
            ):
                raise ValueError("invalid follow end record")
            ended = True
            continue
        if kind != "event" or set(record) != {
            "kind", "sequence", "elapsedNanoseconds", "event"
        }:
            raise ValueError("invalid follow stream order")

        sequence = record["sequence"]
        elapsed = record["elapsedNanoseconds"]
        event = record["event"]
        if (
            isinstance(sequence, bool)
            or not isinstance(sequence, int)
            or sequence < 0
            or isinstance(elapsed, bool)
            or not isinstance(elapsed, int)
            or elapsed < 0
            or not isinstance(event, dict)
            or not isinstance(event.get("type"), str)
            or "elapsedNanoseconds" in event
        ):
            raise ValueError("invalid follow event record")
        if previous_sequence is not None and sequence != previous_sequence + 1:
            raise ValueError("follow stream event sequence is not contiguous")
        previous_sequence = sequence
        flattened = {**event, "elapsedNanoseconds": elapsed}
        validate_event(flattened)
        events.append(flattened)

    return {
        "version": start["version"],
        "provenance": provenance,
        "initial": initial,
        "events": events,
    }


def decode_feed(event: dict):
    encodings = [key for key in ("base64", "text") if key in event]
    if len(encodings) != 1:
        raise ValueError("feed event must contain exactly one byte encoding")
    encoding = encodings[0]
    try:
        if encoding == "base64":
            return encoding, base64.b64decode(event[encoding], validate=True)
        return encoding, event[encoding].encode("utf-8")
    except (binascii.Error, ValueError, AttributeError) as error:
        raise ValueError(f"invalid {encoding} feed event") from error


def encode_feed(event: dict, encoding: str, raw: bytes):
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

    if event_type == "feed":
        encodings = [key for key in ("base64", "text") if key in event]
        if len(encodings) != 1:
            raise ValueError("invalid feed event")
        encoding = encodings[0]
        require_shape(event, {"type", encoding}, {"elapsedNanoseconds"})
        if not isinstance(event[encoding], str):
            raise ValueError("invalid feed event")
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
    parser.add_argument("tape", help="snapshot JSON or follow JSONL from `danterm pane tape`")
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
        tape, truncation = load_tape(args.tape)
    except (OSError, ValueError) as error:
        print(f"{args.tape}: {error}", file=sys.stderr)
        return 1
    if truncation and (
        truncation.get("isTruncated")
        or truncation.get("droppedEventCount", 0) > 0
        or truncation.get("droppedPayloadBytes", 0) > 0
    ):
        print(
            f"{args.tape}: tape is truncated and cannot become fixture evidence",
            file=sys.stderr,
        )
        return 1

    events = tape["events"]
    identifiers = [] if args.keep_identifiers else local_identifiers()
    leftovers = set()
    for event in events:
        if event.get("type") != "feed":
            continue
        try:
            encoding, raw = decode_feed(event)
        except ValueError as error:
            print(f"{args.tape}: {error}", file=sys.stderr)
            return 1
        if not args.keep_identifiers:
            raw = scrub(raw)
            leftovers.update(i.decode() for i in identifiers if i in raw)
        for old, new in swaps:
            raw = raw.replace(old, new)
        try:
            encode_feed(event, encoding, raw)
        except UnicodeDecodeError:
            print(f"{args.tape}: replacement made a text feed invalid UTF-8", file=sys.stderr)
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
    if truncation is not None:
        fixture["truncation"] = truncation
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
