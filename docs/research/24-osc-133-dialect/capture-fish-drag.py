#!/usr/bin/env python3
"""Capture a real fish + `danterm.fish` prompt across a width sweep that strands rows.

The `*-dialect-width-sweep` recordings guard the shipped emitters but cannot
discriminate the `redraw` value: replaying them at any value still leaves exactly
one prompt, because a sweep at a width that never strands a row has nothing to
show. This captures a sweep that does strand them, so that forcing another value
on the replay leaves a staircase and fish's declared value is pinned by a test.
`capture-fish-sweep.py` is the same idea against fish's *native* mark, from
before the emitter existed; this one runs the shipped integration.

Two things about the shell side are load-bearing. The prompt must render at (or
near) the full pane width -- a right-aligned segment padded to `$COLUMNS`, which
is Starship's default -- because a narrower prompt cannot exhibit the failure
(that is what made F11 a false null). And the pane must run the *shipped*
integration on top of the real config: fish emits its own `A;click_events=1`
natively, and DanTerm's contribution is only the second `A;redraw=1` beside it,
which is precisely the byte under test.

The defaults are the *settled* sweep -- SIGWINCH, pause, drain the repaint in
full -- because that is what discriminates for fish. `--settle 0 --drain 0.02`
gives the fast drag that discriminated for zsh, and for fish it does not: fish
diffs its repaint against its own screen model rather than rewriting the prompt,
and once the prompt no longer fits it truncates with a leading ellipsis
(`references/fish-shell/src/screen.rs#truncate_run`), so the fast capture ends up
with no full prompt on screen to strand copies of.

    docs/research/24-osc-133-dialect/capture-fish-drag.py /tmp/fish-drag.json

Writes a complete live-capture snapshot with base64 feed payloads. Scrubbing,
provenance normalization, and any neutral value swaps still go through the
committed converter:

    scripts/terminal-tape-to-fixture.py /tmp/fish-drag.json <fixture> \\
        --test TerminalShellDialectTests --shell fish --stimulus '...'
"""
import argparse, base64, os, pty, time, select, fcntl, termios, struct, re, json, sys

REPO = "/Users/dan/Code/danterm-terminal-engine"
FISH = "/etc/profiles/per-user/dan/bin/fish"
INTEGRATION = f"{REPO}/integrations/shell-integration/danterm.fish"


def feed_event(payload):
    """Encode PTY bytes in the canonical lossless producer representation."""
    return {
        "type": "feed",
        "base64": base64.b64encode(payload).decode("ascii"),
    }


def recording_document(*, initial, events, stimulus):
    """Wrap one direct PTY experiment as a converter-ready live snapshot."""
    return {
        "version": 1,
        "provenance": {
            "source": "danterm-live-capture",
            "author": "DanTerm",
            "test": "TerminalShellDialectTests",
            "recordedDeviations": [],
            "shell": "fish",
            "stimulus": stimulus,
        },
        "initial": initial,
        "events": events,
    }


def feed_bytes(events):
    """Reassemble captured feeds for byte counts and OSC diagnostics."""
    return b"".join(
        base64.b64decode(event["base64"], validate=True)
        for event in events
        if event["type"] == "feed"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tape", nargs="?", default="fish-drag.json")
    parser.add_argument("--start", type=int, default=100)
    parser.add_argument("--end", type=int, default=70)
    parser.add_argument("--rows", type=int, default=12)
    parser.add_argument("--settle", type=float, default=0.12,
                        help="pause after each SIGWINCH before reading")
    parser.add_argument("--drain", type=float, default=0.35,
                        help="how long to read the repaint; short values land the "
                             "next resize mid-repaint")
    args = parser.parse_args()
    START_COLS, END_COLS, ROWS = args.start, args.end, args.rows
    out_path = args.tape

    def set_size(fd, cols, rows=ROWS):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        # What the app sets, and what gates every emit in danterm.fish.
        env["DANTERM"] = "1"
        os.chdir(os.path.expanduser("~"))
        os.execve(FISH, ["fish", "-i", "-C", f"source {INTEGRATION}"], env)
    set_size(fd, START_COLS)

    def respond(data):
        """Answer the queries a real pane answers, so startup does not stall."""
        r = b""
        if re.search(rb"\x1b\]11;\?(\x07|\x1b\\)", data):
            r += b"\x1b]11;rgb:0000/0000/0000\x1b\\"
        if re.search(rb"\x1b\[>0?q", data):
            r += b"\x1bP>|DanTerm 0.1.0\x1b\\"
        if re.search(rb"\x1b\[\?u", data):
            r += b"\x1b[?0u"
        if re.search(rb"\x1b\[(0)?c", data):
            r += b"\x1b[?62;22c"
        for _ in re.findall(rb"\x1b\[6n", data):
            r += b"\x1b[1;1R"
        if r:
            os.write(fd, r)

    def drain(seconds):
        out = b""
        deadline = time.time() + seconds
        while time.time() < deadline:
            sel, _, _ = select.select([fd], [], [], min(0.01, seconds))
            if not sel:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            respond(chunk)
        return out

    events = []
    events.append(feed_event(drain(3.0)))

    for cols in range(START_COLS - 1, END_COLS - 1, -1):
        set_size(fd, cols)
        if args.settle:
            time.sleep(args.settle)
        repaint = drain(args.drain)
        events.append({"type": "resize", "columns": cols, "rows": ROWS})
        if repaint:
            events.append(feed_event(repaint))

    # The drag ends and the shell catches up, exactly as releasing the divider does.
    tail = drain(1.5)
    if tail:
        events.append(feed_event(tail))

    os.write(fd, b"exit\n")
    drain(0.5)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    recording = recording_document(
        initial={"columns": START_COLS, "rows": ROWS},
        events=events,
        stimulus=(
            f"fish integration width drag from {START_COLS} to {END_COLS} columns"
        ),
    )
    with open(out_path, "w") as f:
        json.dump(recording, f)

    feeds = [e for e in events if e["type"] == "feed"]
    resizes = [e for e in events if e["type"] == "resize"]
    blob = feed_bytes(feeds)
    marks = re.findall(rb"\x1b\]133;[^\x07\x1b]*(?:\x07|\x1b\\)", blob)
    print(f"wrote {out_path}: {len(events)} events, {len(resizes)} resizes, "
          f"{len(blob)} bytes")
    print(f"OSC 133 marks seen: {len(marks)}")
    for s in sorted({m.decode('latin1') for m in marks}):
        print(f"  {s!r}")
    # A drag that produced a repaint at every step is a settled sweep in disguise;
    # the stranding this fixture exists for needs steps that land mid-repaint.
    silent = len(resizes) - sum(1 for e in events if e["type"] == "feed") + 1
    print(f"resize steps that produced NO repaint bytes: {silent}/{len(resizes)}")


if __name__ == "__main__":
    sys.exit(main())
