#!/usr/bin/env python3
"""Capture the real fish + Starship prompt across a gradual width sweep (F13).

This reproduces the stimulus from the original staircase incident: many
intermediate widths with the shell's own SIGWINCH repaints interleaved, which is
what a split open/close produces (one resize per AppKit layout pass). The
prompt must be one that renders at (or near) the full pane width -- a
right-aligned segment padded to `$COLUMNS`, which is Starship's default. A
narrower prompt cannot exhibit the failure; that is what made F11 a false null.

Writes four complete live-capture snapshots for `TerminalCore.Terminal`: the
capture as-is, and three variants differing only in the option appended to
fish's own OSC 133 `A` mark.

To replay, feed each variant's events to a `Terminal` in order (feed bytes,
apply resizes) and count occurrences of the prompt's `repo:` token in
`fullHistoryText`. Expected, at commit 0695b7c: as-captured 1, `redraw=1` 1,
`redraw=0` 31 (10 visible on screen). Anything else means the parser's blanking
behavior moved.
"""
import base64, copy, os, pty, time, select, fcntl, termios, struct, re, json, sys

REPO = "/Users/dan/Code/danterm-terminal-engine"
FISH = "/etc/profiles/per-user/dan/bin/fish"
START_COLS = 100
END_COLS = 70
ROWS = 12


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


def recording_variant(recording, marker, suffix):
    """Derive a controlled byte-level variant without rebuilding its drive sequence."""
    variant = copy.deepcopy(recording)
    for event in variant["events"]:
        if event["type"] == "feed":
            raw = base64.b64decode(event["base64"], validate=True)
            event["base64"] = base64.b64encode(
                raw.replace(marker, marker + suffix)
            ).decode("ascii")
    return variant


def feed_bytes(events):
    """Reassemble captured feeds for byte counts and OSC diagnostics."""
    return b"".join(
        base64.b64decode(event["base64"], validate=True)
        for event in events
        if event["type"] == "feed"
    )


def set_size(fd, cols, rows=ROWS):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def main():
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        os.chdir(REPO)
        os.execve(FISH, ["fish", "-i"], env)
    set_size(fd, START_COLS)

    def respond(data):
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
            sel, _, _ = select.select([fd], [], [], 0.05)
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
    startup = drain(3.0)
    events.append(feed_event(startup))

    # Gradual shrink, one column at a time, letting fish repaint after each.
    for cols in range(START_COLS - 1, END_COLS - 1, -1):
        set_size(fd, cols)
        time.sleep(0.12)
        repaint = drain(0.35)
        events.append({"type": "resize", "columns": cols, "rows": ROWS})
        events.append(feed_event(repaint))

    os.write(fd, b"exit\n")
    drain(0.5)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    doc = recording_document(
        initial={"columns": START_COLS, "rows": ROWS},
        events=events,
        stimulus=f"fish native mark width sweep from {START_COLS} to {END_COLS} columns",
    )
    out_path = sys.argv[1] if len(sys.argv) > 1 else "fish_sweep.json"
    with open(out_path, "w") as f:
        json.dump(doc, f)

    # The three replay variants, differing only in the option on fish's own `A`.
    base = b"\x1b]133;A;click_events=1"
    for suffix, name in ((b"", "asis"), (b";redraw=0", "redraw0"), (b";redraw=1", "redraw1")):
        variant = recording_variant(doc, base, suffix)
        with open(out_path.replace(".json", f"_{name}.json"), "w") as f:
            json.dump(variant, f)

    feeds = [e for e in events if e["type"] == "feed"]
    blob = feed_bytes(feeds)
    total = len(blob)
    marks = re.findall(rb"\x1b\]133;[^\x07\x1b]*(?:\x07|\x1b\\)",
                       blob)
    print(f"wrote {out_path}: {len(events)} events, {total} bytes")
    print(f"OSC 133 marks seen: {len(marks)}")
    seen = sorted({m.decode('latin1') for m in marks})
    for s in seen:
        print(f"  {s!r}")
    empty = sum(1 for e in feeds if not e["base64"])
    print(f"resize steps that produced NO repaint bytes: {empty}/{len(feeds) - 1}")

if __name__ == "__main__":
    main()
