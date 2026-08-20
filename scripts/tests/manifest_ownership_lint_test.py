#!/usr/bin/env python3
"""Self-test for scripts/manifest-ownership-lint.py.

It builds fixture trees of tiny manifests, so each verdict is proved in
milliseconds and without a compile. The cases:

  1. A target declared by the manifest nearest its sources passes, and a nested
     package under an outer one is normal -- nesting is legal, reaching past a
     nearer manifest is not.
  2. The same target declared by an ancestor manifest fails. This is the shape
     the root carried for `DanTermProtocol`, `DanTermClient`, and
     `DanTermSupport`.
  3. A test target declared by an ancestor fails the same way, which is how a
     test escaped `scripts/ios-portability-gate.sh`.
  4. A symlink that lives inside a target's own declared path passes. This is
     the load-bearing case: `app/DanTermCore` points into
     `lib/DanTermCore/Sources`, and ownership is decided by the path a manifest
     declares, never by the files that path resolves to.
  5. A `path:` that is not a string literal fails rather than being guessed at.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

LINT = Path(__file__).resolve().parent.parent / "manifest-ownership-lint.py"

MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "{name}",
    targets: [
{targets}    ]
)
"""


def write_manifest(root: Path, package_dir: str, name: str, targets: list[str]) -> None:
    directory = root / package_dir if package_dir != "." else root
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "Package.swift").write_text(
        MANIFEST.format(name=name, targets="".join(f"        {t}\n" for t in targets))
    )


def run(root: Path) -> subprocess.CompletedProcess[str]:
    if not (root / ".git").is_dir():
        initialize_repository(root)
    environment = dict(os.environ, MANIFEST_OWNERSHIP_LINT_ROOT=str(root))
    return subprocess.run(
        [sys.executable, str(LINT)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def initialize_repository(root: Path) -> None:
    """Tracks the fixture state so discovery exercises the same path as the gate."""
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)


def fail(message: str, result: subprocess.CompletedProcess[str]) -> None:
    print(f"manifest_ownership_lint_test: {message}", file=sys.stderr)
    print(result.stdout + result.stderr, file=sys.stderr)
    sys.exit(1)


def check(name: str, root: Path, expect_ok: bool, expect_text: str | None = None) -> None:
    if not (root / ".git").is_dir():
        initialize_repository(root)
    result = run(root)
    if expect_ok and result.returncode != 0:
        fail(f"{name}: expected the lint to pass", result)
    if not expect_ok and result.returncode == 0:
        fail(f"{name}: expected the lint to fail", result)
    if expect_text and expect_text not in result.stdout + result.stderr:
        fail(f"{name}: expected the report to say {expect_text!r}", result)


# 1. Each target declared by the manifest nearest its sources. The outer package
#    keeps its own target under its own directory, so nesting itself is legal.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(root, ".", "Outer", ['.target(name: "Outer", path: "app"),'])
    write_manifest(
        root,
        "lib/Alpha",
        "Alpha",
        [
            '.target(name: "Alpha", path: "Sources/Alpha"),',
            '.testTarget(name: "AlphaTests", path: "Tests/AlphaTests"),',
        ],
    )
    check("nearest manifest owns its targets", root, expect_ok=True)

# 2. An ancestor manifest reaching past a nearer one into its sources.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(
        root,
        ".",
        "Outer",
        [
            '.target(name: "Outer", path: "app"),',
            '.target(name: "Alpha", path: "lib/Alpha/Sources/Alpha"),',
        ],
    )
    write_manifest(root, "lib/Alpha", "Alpha", ['.target(name: "Alpha", path: "Sources/Alpha"),'])
    check(
        "ancestor re-declares a target",
        root,
        expect_ok=False,
        expect_text="lib/Alpha/Package.swift",
    )

# 3. The same reach, for a test target -- the escape from the iOS portability gate.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(
        root,
        ".",
        "Outer",
        [
            '.target(name: "Outer", path: "app"),',
            '.testTarget(name: "AlphaTests", path: "lib/Alpha/Tests/AlphaTests"),',
        ],
    )
    write_manifest(root, "lib/Alpha", "Alpha", ['.target(name: "Alpha", path: "Sources/Alpha"),'])
    check("ancestor re-declares a test target", root, expect_ok=False, expect_text="AlphaTests")

# 4. A symlink inside a target's own declared path. Ownership reads the declared
#    path, so the app/DanTermCore shape stays legal.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(root, ".", "Outer", ['.target(name: "Outer", path: "app"),'])
    write_manifest(root, "lib/Alpha", "Alpha", ['.target(name: "Alpha", path: "Sources/Alpha"),'])
    (root / "lib/Alpha/Sources/Alpha").mkdir(parents=True, exist_ok=True)
    (root / "app").mkdir(parents=True, exist_ok=True)
    (root / "app/Alpha").symlink_to(root / "lib/Alpha/Sources/Alpha")
    check("symlink inside a declared path", root, expect_ok=True)

# 5. A computed `path:` is refused, not guessed at.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(root, ".", "Outer", [".target(name: \"Outer\", path: appRoot),"])
    check(
        "computed path",
        root,
        expect_ok=False,
        expect_text="not a string literal",
    )

# A tracked manifest outside the old roots becomes the nearest owner. Manifests
# under docs/ and manifests added after the fixture was tracked stay invisible.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(
        root,
        ".",
        "Outer",
        [
            '.target(name: "Outer", path: "app"),',
            '.target(name: "Tool", path: "tools/Tool/Sources/Tool"),',
            '.target(name: "DocsOnly", path: "docs/DocsOnly/Sources/DocsOnly"),',
            '.target(name: "Untracked", path: "scratch/Untracked/Sources/Untracked"),',
        ],
    )
    write_manifest(root, "tools/Tool", "Tool", ['.target(name: "Tool", path: "Sources/Tool"),'])
    write_manifest(root, "docs/DocsOnly", "DocsOnly", ['.target(name: "DocsOnly", path: "Sources/DocsOnly"),'])
    initialize_repository(root)
    write_manifest(root, "scratch/Untracked", "Untracked", ['.target(name: "Untracked", path: "Sources/Untracked"),'])
    result = run(root)
    report = result.stdout + result.stderr
    if result.returncode == 0 or "tools/Tool/Package.swift owns" not in report:
        fail("tracked package outside old roots: expected the nearest-owner failure", result)
    if "docs/DocsOnly/Package.swift owns" in report or "scratch/Untracked/Package.swift owns" in report:
        fail("excluded and untracked manifests must not become owners", result)

with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_manifest(root, "docs/DocsOnly", "DocsOnly", ['.target(name: "DocsOnly", path: "Sources/DocsOnly"),'])
    result = run(root)
    if result.returncode == 0 or "no first-party manifest found by tracked-file discovery" not in result.stderr:
        fail("empty discovery: expected a clear failure", result)

print("manifest_ownership_lint_test: ok")
