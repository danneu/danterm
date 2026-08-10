#!/usr/bin/env python3
"""Audit feed payload encodings across every committed recording family."""

import base64
import binascii
import gzip
import json
from pathlib import Path
import sys


def audit_feed_events(events, source):
    """Validate only feed encodings while leaving each family's other events opaque."""
    count = 0
    for index, event in enumerate(events):
        if not isinstance(event, dict) or event.get("type") != "feed":
            continue
        encodings = set(event).intersection({"base64", "text", "hex"})
        if encodings not in ({"base64"}, {"text"}):
            raise ValueError(
                f"{source}: feed event {index} must contain exactly one of base64 or text"
            )
        if "base64" in event:
            payload = event["base64"]
            if not isinstance(payload, str):
                raise ValueError(f"{source}: feed event {index} has non-string base64")
            try:
                base64.b64decode(payload, validate=True)
            except (binascii.Error, ValueError) as error:
                raise ValueError(
                    f"{source}: feed event {index} has malformed base64"
                ) from error
        elif not isinstance(event["text"], str):
            raise ValueError(f"{source}: feed event {index} has non-string text")
        count += 1
    return count


def audit_recording_corpus(root):
    """Load neutral, Ghostty, and benchmark corpora and return feed counts by family."""
    root = Path(root)
    counts = {"neutral": 0, "ghostty": 0, "benchmark": 0}
    fixtures = root / "lib" / "TerminalCore" / "Tests" / "TerminalCoreTests" / "Fixtures"
    for path in sorted(fixtures.rglob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict) or not isinstance(document.get("events"), list):
            continue
        counts["neutral"] += audit_feed_events(
            document["events"],
            path.relative_to(root),
        )

    ghostty_path = fixtures / "ghostty" / "inspection-recovery.json"
    ghostty = json.loads(ghostty_path.read_text(encoding="utf-8"))
    counts["ghostty"] = audit_feed_events(
        ghostty["replay"]["events"],
        ghostty_path.relative_to(root),
    )

    benchmark_path = (
        root
        / "benchmarks"
        / "fixtures"
        / "recordings"
        / "synchronized-frames-v1-btop-95-frames.json.gz"
    )
    with gzip.open(benchmark_path, "rt", encoding="utf-8") as handle:
        benchmark = json.load(handle)
    counts["benchmark"] = audit_feed_events(
        benchmark["events"],
        benchmark_path.relative_to(root),
    )

    missing = [family for family, count in counts.items() if count == 0]
    if missing:
        raise ValueError(f"recording families contain no feed events: {', '.join(missing)}")
    return counts


def main():
    """Audit the repository containing this script and report family coverage."""
    root = Path(__file__).resolve().parents[1]
    try:
        counts = audit_recording_corpus(root)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"terminal-recording-schema-audit: {error}", file=sys.stderr)
        return 1
    summary = ", ".join(f"{family}={count}" for family, count in counts.items())
    print(f"terminal-recording-schema-audit: ok ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
