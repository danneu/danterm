#!/usr/bin/env python3
"""Proves first-party manifest discovery against a real fixture repository."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

DISCOVERY = Path(__file__).resolve().parent.parent / "manifest_targets.py"


def write_manifest(root: Path, relative: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("// swift-tools-version: 6.2\n")


with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    for relative in (
        "Package.swift",
        "tools/Tool/Package.swift",
        "docs/Spike/Package.swift",
        "references/Vendor/Package.swift",
        "tools/FooPackage.swift",
    ):
        write_manifest(root, relative)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    write_manifest(root, "scratch/Untracked/Package.swift")
    result = subprocess.run(
        [sys.executable, str(DISCOVERY), "--list", "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(result.stderr)
    if result.stdout.splitlines() != ["Package.swift", "tools/Tool/Package.swift"]:
        sys.exit(f"manifest_targets_test: wrong discovery: {result.stdout!r}")

with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(root, "docs/Only/Package.swift")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    result = subprocess.run(
        [sys.executable, str(DISCOVERY), "--list", "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0 or "no first-party manifest" not in result.stderr:
        sys.exit("manifest_targets_test: empty discovery did not fail clearly")

print("manifest_targets_test: ok")
