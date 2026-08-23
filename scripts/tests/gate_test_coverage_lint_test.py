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
 10. A display-bound test target -- one declaring DANTERM_REQUIRES_WINDOWSERVER --
     must be skipped by name, because the gate is headless and a lane that merely
     fails to reach it says nothing.
 11. Skipping a display-bound target still leaves the rest of the estate covered,
     so the lane beside it is a whole-estate lane and not a subset.
 12. Every tracked shell or Python self-test must appear in executable command
     position in the assembled gate, wherever it lives in the repository.
 13. Comments, strings, and ordinary command arguments do not establish coverage.
 14. A non-empty in-file opt-out excludes a test; missing and malformed opt-outs fail.
 15. Empty script-test discovery fails rather than reporting success over no files.
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

DISPLAY_BOUND_TEST_TARGET = """        .testTarget(
            name: "{name}",
            dependencies: [],
            path: "Tests/{name}",
            swiftSettings: [.define("DANTERM_REQUIRES_WINDOWSERVER")]
        ),
"""


def write_package(root: Path, name: str, tests: list[str]) -> None:
    package = root / "lib" / name
    package.mkdir(parents=True, exist_ok=True)
    blocks = "".join(
        (DISPLAY_BOUND_TEST_TARGET if test.endswith("!") else TEST_TARGET).format(
            name=test.rstrip("!")
        )
        for test in tests
    )
    (package / "Package.swift").write_text(
        MANIFEST.format(name=name, test_targets=blocks)
    )


def write_steps(root: Path, steps: list[str], include_script_test: bool = True) -> None:
    runner = root / "scripts" / "run-test-suite.sh"
    runner.parent.mkdir(parents=True, exist_ok=True)
    if include_script_test:
        baseline = root / "scripts/tests/baseline_test.py"
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_text("#!/usr/bin/env python3\n")
        steps = [*steps, "python3 ./scripts/tests/baseline_test.py"]
    body = "".join(f"    '{step}'\n" for step in steps)
    runner.write_text(
        "#!/usr/bin/env bash\n"
        "STEPS=(\n"
        + body
        + ")\n"
        + "if [[ \"${1:-}\" == \"--list-steps\" ]]; then\n"
        + "    printf '%s\\n' \"${STEPS[@]}\"\n"
        + "fi\n"
    )
    runner.chmod(0o755)


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

# 10. A display-bound target the gate does not skip: the gate is headless, so a lane
#     that happens not to reach it is not the same as saying it must not run.
case(
    "display-bound target not skipped",
    ["swift test --package-path lib/Alpha"],
    {"Alpha": ["AlphaTests", "AlphaUITests!"]},
    expect_ok=False,
    expect_text="carries DANTERM_REQUIRES_WINDOWSERVER",
)

# 11. Skipping only the display-bound target leaves a whole-estate lane behind it.
case(
    "display-bound target skipped by name",
    ["swift test --package-path lib/Alpha --skip AlphaUITests"],
    {"Alpha": ["AlphaTests", "AlphaUITests!"]},
    expect_ok=True,
)

# 12. A direct command and an interpreter script operand establish coverage. Discovery
# is repo-wide, so the second self-test deliberately lives outside scripts/tests.
case(
    "direct and interpreter script coverage",
    [
        "swift test --package-path lib/Alpha",
        "wide: ./scripts/tests/alpha_test.sh",
        "python3 ./tools/beta_test.py",
    ],
    {"Alpha": ["AlphaTests"]},
    expect_ok=True,
    extra={
        "scripts/tests/alpha_test.sh": "#!/usr/bin/env bash\n",
        "tools/beta_test.py": "#!/usr/bin/env python3\n",
    },
)

case(
    "orphaned script test",
    ["swift test --package-path lib/Alpha"],
    {"Alpha": ["AlphaTests"]},
    expect_ok=False,
    expect_text="scripts/tests/orphan_test.sh",
    extra={"scripts/tests/orphan_test.sh": "#!/usr/bin/env bash\n"},
)

# Repeated execution is valid. This lint closes omission and does not redefine the
# gate's existing meta-test relationships.
case(
    "repeated script test",
    [
        "swift test --package-path lib/Alpha",
        "./scripts/tests/repeated_test.sh",
        "bash ./scripts/tests/repeated_test.sh",
    ],
    {"Alpha": ["AlphaTests"]},
    expect_ok=True,
    extra={"scripts/tests/repeated_test.sh": "#!/usr/bin/env bash\n"},
)

# 13. A filename can occur in a step without being executed. None of these positions
# establishes reachability from the gate.
for name, step in (
    ("comment", "true # ./scripts/tests/orphan_test.sh"),
    ("inert string", "printf '%s\\n' ./scripts/tests/orphan_test.sh"),
    ("ordinary argument", "test -f ./scripts/tests/orphan_test.sh"),
    ("interpreter command argument", "python3 -c pass ./scripts/tests/orphan_test.sh"),
):
    case(
        f"script path in {name}",
        ["swift test --package-path lib/Alpha", step],
        {"Alpha": ["AlphaTests"]},
        expect_ok=False,
        expect_text="scripts/tests/orphan_test.sh",
        extra={"scripts/tests/orphan_test.sh": "#!/usr/bin/env bash\n"},
    )

# 14. The exclusion belongs to the file it excludes, and a reason is mandatory.
case(
    "script test with opt-out",
    ["swift test --package-path lib/Alpha"],
    {"Alpha": ["AlphaTests"]},
    expect_ok=True,
    extra={
        "scripts/tests/gui_test.sh": (
            "#!/usr/bin/env bash\n"
            "# gate: opt-out -- requires a GUI and runs through another gate\n"
        )
    },
)

for name, marker in (
    ("missing", ""),
    ("empty reason", "# gate: opt-out --\n"),
    ("wrong form", "# gate: opt-out requires a GUI\n"),
):
    case(
        f"script test with {name} opt-out",
        ["swift test --package-path lib/Alpha"],
        {"Alpha": ["AlphaTests"]},
        expect_ok=False,
        expect_text="scripts/tests/gui_test.sh",
        extra={"scripts/tests/gui_test.sh": "#!/usr/bin/env bash\n" + marker},
    )

# 15. Both discovery estates must be non-empty independently.
with tempfile.TemporaryDirectory() as raw:
    root = Path(raw)
    write_package(root, "Alpha", ["AlphaTests"])
    write_steps(root, ["swift test --package-path lib/Alpha"], include_script_test=False)
    result = run(root)
    if result.returncode == 0 or "no tracked shell or Python self-test" not in result.stderr:
        fail("empty script-test discovery: expected a clear failure", result)

# The production tree proves both discovery estates are non-empty and fully covered.
# Keep the exclusion set exact so a second opt-out cannot quietly weaken the gate.
environment = dict(os.environ)
environment.pop("GATE_TEST_COVERAGE_LINT_ROOT", None)
result = subprocess.run(
    [sys.executable, str(LINT)],
    cwd=LINT.parent.parent,
    env=environment,
    capture_output=True,
    text=True,
    check=False,
)
if result.returncode != 0:
    fail("production tree: expected every declared test to be covered", result)
expected_opt_out = "1 opted out: scripts/tests/danterm-cli_test.sh"
if expected_opt_out not in result.stdout:
    fail(f"production tree: expected {expected_opt_out!r}", result)

print("gate_test_coverage_lint_test: ok")
