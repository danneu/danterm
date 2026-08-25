#!/usr/bin/env python3
"""Enforces the file comment that distinguishes each tracked Swift file from its declarations."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPO_ROOT = Path(
    os.environ.get("SWIFT_FILE_HEADER_LINT_ROOT") or SCRIPT_DIRECTORY.parent
).resolve()


def tracked_swift_paths() -> list[Path]:
    """Returns Git's NUL-delimited inventory without losing valid path characters."""
    try:
        inventory = subprocess.run(
            ["git", "-C", os.fspath(REPO_ROOT), "ls-files", "-z", "--", "*.swift"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
    except subprocess.CalledProcessError:
        print(
            f"swift-file-header-lint: tracked Swift discovery failed in {REPO_ROOT}",
            file=sys.stderr,
        )
        raise SystemExit(1) from None

    paths = [Path(os.fsdecode(path)) for path in inventory.split(b"\0") if path]
    return [path for path in paths if (REPO_ROOT / path).is_file()]


def violation_reason(path: Path) -> str | None:
    """Returns the rule violation on line 1, or None for a valid file comment."""
    try:
        with (REPO_ROOT / path).open("rb") as source:
            first_line = source.readline().decode("utf-8", errors="replace").rstrip("\r\n")
    except OSError as error:
        return f"cannot read tracked file: {error}"

    if not first_line.startswith("//"):
        return "line 1 is not an ordinary // file comment"
    if first_line.startswith("///"):
        return "line 1 starts declaration documentation (///), not a file comment"
    if first_line[2:].strip() == path.name:
        return "line 1 is only the file name, not a useful file comment"
    return None


def main() -> int:
    paths = tracked_swift_paths()
    if not paths:
        print(
            f"swift-file-header-lint: no tracked Swift files found in {REPO_ROOT}",
            file=sys.stderr,
        )
        return 1

    violations = [(path, violation_reason(path)) for path in paths]
    violations = [(path, reason) for path, reason in violations if reason is not None]
    if violations:
        for path, reason in violations:
            print(f"swift-file-header-lint: {path}: {reason}", file=sys.stderr)
        print(
            """Every tracked Swift file starts with an ordinary // file comment on line 1.
That comment explains the file's purpose. Keep declaration documentation (///)
with the declaration it documents, and replace filename-only Xcode banners with
a useful file comment. A // swift-tools-version: directive also satisfies the rule.""",
            file=sys.stderr,
        )
        return 1

    print(f"Swift file-header lint passed ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
