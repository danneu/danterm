#!/usr/bin/env python3
"""Convert a live-pane terminal tape into a neutral replay fixture.

A tape is what `TerminalTapeRecorder` writes when a DanTerm build runs with
`DANTERM_TAPE_PATH` set: one JSON object per line, the first carrying the pane's
initial geometry and every later one a feed or resize in the order `Terminal`
actually saw it, with real PTY chunk boundaries preserved. That ordering and
those boundaries are the whole value of a tape -- a corruption that only appears
in a live pane is usually sensitive to where the chunks fell -- so this script
rewraps rather than rewrites: no event is merged, split, or reordered.

    scripts/terminal-tape-to-fixture.py /tmp/danterm-tape.51234.jsonl \\
        lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/my-case.json

Each pane writes its own PID-suffixed file; the summary this prints (event
count, resize count, resize geometries) is how you pick the one whose drag
matches the artifact you reproduced.

Scrubbing is on by default and is not cosmetic: a tape is verbatim terminal
output, so it carries the recording machine's hostname and home directory in
every OSC 7 report, and usually in the prompt itself. Fixtures are committed, so
they must be neutral. After scrubbing, the script checks the result against this
machine's own hostname, username and home path and refuses to write a fixture
that still contains any of them -- a prompt framework can render an identifier
somewhere the OSC 7 rules never look. `--keep-identifiers` skips both steps for
a tape you are only replaying locally.
"""
import argparse
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tape", help="JSONL file written by TerminalTapeRecorder")
    parser.add_argument("fixture", help="fixture JSON to write")
    parser.add_argument("--keep-identifiers", action="store_true",
                        help="skip host/home scrubbing (local-only tapes)")
    parser.add_argument("--source", default="live DanTerm Dev pane, recorded via the terminal drive tape")
    parser.add_argument("--shell", default="", help="what was running in the pane")
    parser.add_argument("--stimulus", default="", help="what the operator did to it")
    args = parser.parse_args()

    with open(args.tape) as handle:
        lines = [json.loads(line) for line in handle if line.strip()]
    if not lines or "initial" not in lines[0]:
        print(f"{args.tape}: no geometry header; not a tape", file=sys.stderr)
        return 1

    head, events = lines[0], lines[1:]
    identifiers = [] if args.keep_identifiers else local_identifiers()
    leftovers = set()
    for event in events:
        if event.get("type") != "feed":
            continue
        raw = bytes.fromhex(event["hex"])
        if not args.keep_identifiers:
            raw = scrub(raw)
            leftovers.update(i.decode() for i in identifiers if i in raw)
        event["hex"] = raw.hex()

    if leftovers:
        print(f"identifiers survived scrubbing: {sorted(leftovers)}", file=sys.stderr)
        print("extend SCRUBS, or pass --keep-identifiers to keep it local", file=sys.stderr)
        return 1

    resizes = [e for e in events if e.get("type") == "resize"]
    note = ("verbatim pane output; host and home path scrubbed to neutral values, "
            "no other bytes altered" if not args.keep_identifiers
            else "verbatim pane output, unscrubbed")
    provenance = {"source": args.source, "note": note}
    if args.shell:
        provenance["shell"] = args.shell
    if args.stimulus:
        provenance["stimulus"] = args.stimulus

    with open(args.fixture, "w") as handle:
        json.dump({"version": 1, "initial": head["initial"], "events": events,
                   "provenance": provenance}, handle)

    print(f"{len(events)} events, {len(resizes)} resizes, initial {head['initial']}")
    if resizes:
        print("resize geometries:", [(r["columns"], r["rows"]) for r in resizes])
    print("wrote", args.fixture)
    return 0


if __name__ == "__main__":
    sys.exit(main())
