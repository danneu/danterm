#!/usr/bin/env python3
"""Self-test for scripts/gate-test-coverage-lint.py.

It builds fixture trees of tiny manifests and synthetic step lists, so each verdict
is proved in milliseconds rather than by running the real gate. The cases:

  1. A package with a lane over its whole estate passes.
  2. A package with no lane at all fails -- the hole that let `lib/DanTermClient`
     ship a test suite nothing ever ran.
  3. A package named only by a step that builds it fails. A mention is not a lane.
  4. A package with two whole-estate lanes fails, because its tests run twice.
  5. A package whose only lane carries `--filter` fails: a subset leaves the rest
     of the estate unrun.
  6. A package whose lanes partition the estate -- `--filter X` beside `--skip X`
     -- passes. Cases 5 and 6 are separate fixtures on purpose: written from case 5
     alone, the check would reject `scripts/test-terminal-pty.sh`, a working lane
     pair the real gate depends on.
  7. A wrapper script named by a step counts as a lane, which is the only way the
     gate reaches `lib/TerminalPTY`.
  8. A `--filter` naming the package's whole estate is a whole-estate lane, not a
     subset. This is the dead `--filter` on the protocol step.
  9. A target whose `path:` is not a string literal fails rather than being guessed
     at.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

LINT = Path(__file__).resolve().parent.parent / "gate-test-coverage-lint.py"

MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "{name}",
    targets: [
        .target(name: "{name}", path: "Sources/{name}"),
{test_targets}    ]
)
"""

TEST_TARGET = """        .testTarget(name: "{name}", dependencies: [], path: "Tests/{name}"),
"""


def write_package(root: Path, name: str, tests: list[str]) -> None:
    package = root / "lib" / name
    package.mkdir(parents=True, exist_ok=True)
    blocks = "".join(TEST_TARGET.format(name=test) for test in tests)
    (package / "Package.swift").write_text(
        MANIFEST.format(name=name, test_targets=blocks)
    )


def write_steps(root: Path, steps: list[str]) -> None:
    runner = root / "scripts" / "run-test-suite.sh"
    runner.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(f"    '{step}'\n" for step in steps)
    runner.write_text("#!/usr/bin/env bash\nSTEPS=(\n" + body + ")\n")


def initialize_repository(root: Path) -> None:
    """Tracks the fixture state so discovery exercises the same path as the gate."""
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)


def run(root: Path) -> subprocess.CompletedProcess[str]:
    if not (root / ".git").is_dir():
        initialize_repository(root)
    environment = dict(os.environ, GATE_TEST_COVERAGE_LINT_ROOT=str(root))
    return subprocess.run(
        [sys.executable, str(LINT)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def fail(message: str, result: subprocess.CompletedProcess[str]) -> None:
    print(f"gate_test_coverage_lint_test: {message}", file=sys.stderr)
    print(result.stdout + result.stderr, file=sys.stderr)
    sys.exit(1)


def case(name: str, steps: list[str], packages: dict[str, list[str]], expect_ok: bool,
         expect_text: str | None = None, extra: dict[str, str] | None = None) -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        for package, tests in packages.items():
            write_package(root, package, tests)
        for relative, contents in (extra or {}).items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(contents)
            target.chmod(0o755)
        write_steps(root, steps)
        result = run(root)
        if expect_ok and result.returncode != 0:
            fail(f"{name}: expected the check to pass", result)
        if not expect_ok and result.returncode == 0:
            fail(f"{name}: expected the check to fail", result)
        if expect_text and expect_text not in result.stdout + result.stderr:
            fail(f"{name}: expected the report to say {expect_text!r}", result)


# 1. A whole-estate lane is coverage.
case(
    "whole-estate lane",
    ["swift test --package-path lib/Alpha"],
    {"Alpha": ["AlphaTests"]},
    expect_ok=True,
)

# 2. No lane at all: the hole this check exists to close.
case(
    "no lane",
    ["swift test --package-path lib/Alpha"],
    {"Alpha": ["AlphaTests"], "Beta": ["BetaTests"]},
    expect_ok=False,
    expect_text="lib/Beta declares BetaTests and no gate lane runs them",
)

# 3. A mention is not a lane: building a package leaves its tests unrun.
case(
    "build is not a lane",
    ["swift test --package-path lib/Alpha", "swift build --package-path lib/Beta --build-tests"],
    {"Alpha": ["AlphaTests"], "Beta": ["BetaTests"]},
    expect_ok=False,
    expect_text="no gate lane runs them",
)

# 4. Two whole-estate lanes run every test twice.
case(
    "two whole-estate lanes",
    ["swift test --package-path lib/Alpha", "swift test --package-path lib/Alpha --scratch-path x"],
    {"Alpha": ["AlphaTests"]},
    expect_ok=False,
    expect_text="each run its whole estate",
)

# 5. A lone subset lane leaves the rest of the estate unrun.
case(
    "lone subset lane",
    ["swift test --package-path lib/Alpha --filter slowCase"],
    {"Alpha": ["AlphaTests", "AlphaSlowTests"]},
    expect_ok=False,
    expect_text="carve its estate down",
)

# 6. A filter/skip pair over one selector partitions the estate.
case(
    "partitioned estate",
    [
        "swift test --package-path lib/Alpha --skip slowCase",
        "swift test --package-path lib/Alpha --filter slowCase",
    ],
    {"Alpha": ["AlphaTests", "AlphaSlowTests"]},
    expect_ok=True,
)

# 7. A shell wrapper named by a step carries the lane.
case(
    "lane inside a wrapper script",
    ["./scripts/run-alpha.sh"],
    {"Alpha": ["AlphaTests"]},
    expect_ok=True,
    extra={
        "scripts/run-alpha.sh": (
            "#!/usr/bin/env bash\n"
            'REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"\n'
            'SWIFT="${DANTERM_SWIFT:-swift}"\n'
            'ALPHA="$REPO_ROOT/lib/Alpha"\n'
            '"$SWIFT" test --package-path "$ALPHA" \\\n'
            '    --scratch-path "$ALPHA/.build-gate"\n'
        )
    },
)

# 8. A `--filter` naming every test target the package has selects the whole estate.
case(
    "filter naming the whole estate",
    ["swift test --package-path lib/Alpha --filter AlphaTests"],
    {"Alpha": ["AlphaTests"]},
    expect_ok=True,
)

# 9. A computed `path:` is refused, not guessed at.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_package(root, "Alpha", ["AlphaTests"])
    manifest = root / "lib/Alpha/Package.swift"
    manifest.write_text(
        manifest.read_text().replace('path: "Tests/AlphaTests"', "path: testsRoot")
    )
    write_steps(root, ["swift test --package-path lib/Alpha"])
    result = run(root)
    if result.returncode == 0:
        fail("computed path: expected the check to fail", result)
    if "not a string literal" not in result.stderr:
        fail("computed path: expected the report to name the literal requirement", result)

# A tracked package outside the old roots must enter the estate, while excluded
# and untracked manifests stay invisible.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_package(root, "Alpha", ["AlphaTests"])
    write_package(root, "Tool", ["ToolTests"])
    (root / "tools").mkdir()
    (root / "lib/Tool").rename(root / "tools/Tool")
    write_package(root, "DocsOnly", ["DocsOnlyTests"])
    (root / "docs").mkdir()
    (root / "lib/DocsOnly").rename(root / "docs/DocsOnly")
    write_steps(root, ["swift test --package-path lib/Alpha"])
    initialize_repository(root)
    write_package(root, "Untracked", ["UntrackedTests"])
    result = run(root)
    report = result.stdout + result.stderr
    if result.returncode == 0 or "tools/Tool declares ToolTests" not in report:
        fail("tracked package outside old roots: expected its missing lane to fail", result)
    if "DocsOnlyTests" in report or "UntrackedTests" in report:
        fail("excluded and untracked manifests must not enter the estate", result)

with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_package(root, "DocsOnly", ["DocsOnlyTests"])
    (root / "docs").mkdir()
    (root / "lib/DocsOnly").rename(root / "docs/DocsOnly")
    write_steps(root, [])
    result = run(root)
    if result.returncode == 0 or "no first-party manifest found by tracked-file discovery" not in result.stderr:
        fail("empty discovery: expected a clear failure", result)

print("gate_test_coverage_lint_test: ok")
