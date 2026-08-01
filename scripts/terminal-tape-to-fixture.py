#!/usr/bin/env python3
"""Scrub a live-pane terminal tape into a neutral replay fixture.

A tape is normally the JSON document printed by `danterm pane tape --pane ID`.
It already uses the neutral recording schema, including real PTY chunk boundaries
and resize ordering, so this script only scrubs feed bytes, verifies that local
identifiers are gone, and marks the result as fixture-ready DanTerm evidence.
Legacy JSONL files written through `DANTERM_TAPE_PATH` remain accepted.

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
    """Loads either one live-capture document or the legacy JSONL stream."""
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
        return document, document.get("truncation")

    try:
        lines = [json.loads(line) for line in contents.splitlines() if line.strip()]
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid tape JSON: {error.msg}") from error
    if not lines or "initial" not in lines[0]:
        raise ValueError("no geometry header; not a tape")
    return {
        "version": 1,
        "initial": lines[0]["initial"],
        "events": lines[1:],
    }, None


def decode_feed(event: dict):
    encodings = [key for key in ("base64", "hex", "text") if key in event]
    if len(encodings) != 1:
        raise ValueError("feed event must contain exactly one byte encoding")
    encoding = encodings[0]
    try:
        if encoding == "base64":
            return encoding, base64.b64decode(event[encoding], validate=True)
        if encoding == "hex":
            return encoding, bytes.fromhex(event[encoding])
        return encoding, event[encoding].encode("utf-8")
    except (binascii.Error, ValueError, AttributeError) as error:
        raise ValueError(f"invalid {encoding} feed event") from error


def encode_feed(event: dict, encoding: str, raw: bytes):
    if encoding == "base64":
        event[encoding] = base64.b64encode(raw).decode("ascii")
    elif encoding == "hex":
        event[encoding] = raw.hex()
    else:
        event[encoding] = raw.decode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tape", help="JSON document from `danterm pane tape` (or legacy JSONL)")
    parser.add_argument("fixture", help="fixture JSON to write")
    parser.add_argument("--keep-identifiers", action="store_true",
                        help="skip host/home scrubbing (local-only tapes)")
    parser.add_argument("--allow-truncated", action="store_true",
                        help="convert despite dropped events, retaining truncation metadata")
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
    ) and not args.allow_truncated:
        print(
            f"{args.tape}: tape is truncated; pass --allow-truncated to convert incomplete evidence",
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
