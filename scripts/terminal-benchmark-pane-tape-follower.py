#!/usr/bin/env python3
"""Drain one benchmark pane-tape follow and checkpoint its completion evidence."""
import argparse
import base64
import json
import os
import pathlib
import subprocess
import tempfile
import time


class TapeProgress:
    """Track start, feed coverage, and a marker that may cross event boundaries."""

    def __init__(self, completion_marker):
        self.completion_marker = completion_marker
        self.started = False
        self.completed = False
        self.event_count = 0
        self.feed_bytes = 0
        self._tail = b""

    def accept(self, record):
        kind = record.get("kind")
        if kind == "start":
            self.started = True
            return
        if kind != "event":
            return
        self.event_count += 1
        event = record.get("event", {})
        if event.get("type") != "feed":
            return
        payload = base64.b64decode(event["base64"])
        self.feed_bytes += len(payload)
        combined = self._tail + payload
        if self.completion_marker in combined:
            self.completed = True
        keep = max(0, len(self.completion_marker) - 1)
        self._tail = combined[-keep:] if keep else b""


def write_json_atomically(path, value):
    """Publish a complete follower checkpoint at one filesystem edge."""
    path = pathlib.Path(path)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".follower-")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--pane", required=True)
    parser.add_argument("--ready", type=pathlib.Path, required=True)
    parser.add_argument("--summary", type=pathlib.Path, required=True)
    parser.add_argument("--completion-marker", required=True)
    args = parser.parse_args(argv)

    started = time.monotonic_ns()
    progress = TapeProgress(args.completion_marker.encode())
    process = subprocess.Popen(
        [args.cli, "pane", "tape", "--pane", args.pane, "--follow", "--raw", "--from-now"],
        stdout=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None
    for line in process.stdout:
        progress.accept(json.loads(line))
        if progress.started and not args.ready.exists():
            args.ready.touch()
        if progress.completed and not args.summary.exists():
            write_json_atomically(args.summary, {
                "startedNanoseconds": started,
                "completionNanoseconds": time.monotonic_ns(),
                "eventCount": progress.event_count,
                "feedBytes": progress.feed_bytes,
            })
    return process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
