#!/usr/bin/env python3
"""Self-test for scripts/scripts-swift-orphan-lint.py.

Builds fixture repositories rather than running against this one, so every verdict is
proved in milliseconds and the failing cases are provable at all -- the real tree is
supposed to be clean, and a lint whose red path is only ever checked by hand is the
same defect this lint exists to prevent. The cases:

  1. A scripts/ Swift file importing only system frameworks passes.
  2. A scripts/ Swift file importing a module a first-party manifest declares fails.
     This is `terminal-headless-draw-arm.swift` from 2026-08-20 to 2026-08-26.
  3. The same file under lib/ passes -- a package compiles it, so the rule is about
     position, not about the import.
  4. `@testable import` of a first-party module fails too.
  5. An in-file opt-out with a reason excludes a file; the bare marker does not.
  6. `scripts/research/` is exempt: those probes are records pinned to a research
     doc, not tools, and are allowed to stop building.
  7. The gate must run every same-module probe's `--check`; dropping one step fails,
     even with the other still present.
  8. Losing one probe file fails as "checked nothing" rather than passing.
  9. A repository with no tracked file under scripts/ fails rather than reporting
     success over no files, and so does a gate runner that moved.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

LINT = Path(__file__).resolve().parent.parent / "scripts-swift-orphan-lint.py"

MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalCore",
    targets: [
        .target(name: "TerminalCore", path: "Sources/TerminalCore"),
    ]
)
"""

PROBES = [
    "scripts/checkpoint-projection-cost-probe.swift",
    "scripts/reducer-dispatch-cost-probe.swift",
]
GATE_STEPS = [
    "python3 ./scripts/checkpoint-projection-cost.py --check",
    "python3 ./scripts/reducer-dispatch-cost.py --check",
]

failures: list[str] = []


def build(root: Path, files: dict[str, str], gate_steps: list[str] = GATE_STEPS,
          probes: list[str] = PROBES, runner: bool = True) -> None:
    """Writes one fixture repository and tracks it, so discovery runs the real path."""
    (root / "lib/TerminalCore").mkdir(parents=True)
    (root / "lib/TerminalCore/Package.swift").write_text(MANIFEST)
    for probe in probes:
        files.setdefault(probe, "import Foundation\n")
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    if runner:
        path = root / "scripts/run-test-suite.sh"
        path.parent.mkdir(parents=True, exist_ok=True)
        body = "".join(f"    '{step}'\n" for step in gate_steps)
        path.write_text(f"LINT_STEPS=(\n{body})\n")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)


def case(name: str, files: dict[str, str], expect_ok: bool, expect: str = "",
         **kwargs: object) -> None:
    with tempfile.TemporaryDirectory(prefix="scripts-swift-orphan-") as directory:
        root = Path(directory)
        build(root, dict(files), **kwargs)  # type: ignore[arg-type]
        result = subprocess.run(
            [sys.executable, str(LINT)],
            capture_output=True,
            text=True,
            env={**os.environ, "SCRIPTS_SWIFT_ORPHAN_LINT_ROOT": str(root)},
            check=False,
        )
        ok = result.returncode == 0
        output = result.stdout + result.stderr
        if ok != expect_ok:
            failures.append(
                f"{name}: expected {'pass' if expect_ok else 'failure'}, got exit "
                f"{result.returncode}\n{output}"
            )
        elif expect and expect not in output:
            failures.append(f"{name}: expected {expect!r} in output\n{output}")


case(
    "a system-only script passes",
    {"scripts/tool.swift": "import Foundation\nimport CoreGraphics\n"},
    expect_ok=True,
)
case(
    "a script importing a declared module fails",
    {"scripts/tool.swift": "import Foundation\nimport TerminalCore\n"},
    expect_ok=False,
    expect="imports the first-party module TerminalCore",
)
case(
    "the same import under lib/ passes",
    {"lib/TerminalCore/Sources/TerminalCore/Arm.swift": "import TerminalCore\n"},
    expect_ok=True,
)
case(
    "@testable import is caught too",
    {"scripts/tool.swift": "@testable import TerminalCore\n"},
    expect_ok=False,
    expect="imports the first-party module TerminalCore",
)
case(
    "an opt-out with a reason excludes the file",
    {"scripts/tool.swift": "// gate: opt-out -- pinned to a dead revision\nimport TerminalCore\n"},
    expect_ok=True,
)
case(
    "a bare opt-out marker does not",
    {"scripts/tool.swift": "// gate: opt-out --\nimport TerminalCore\n"},
    expect_ok=False,
    expect="imports the first-party module TerminalCore",
)
case(
    "research probes are exempt",
    {"scripts/research/33/t1-probe.swift": "import TerminalCore\n"},
    expect_ok=True,
)
case(
    "the gate must still run every same-module probe",
    {"scripts/tool.swift": "import Foundation\n"},
    expect_ok=False,
    expect="the gate must run",
    gate_steps=[GATE_STEPS[0], "python3 ./scripts/reducer-dispatch-cost.py"],
)
case(
    "a missing same-module probe checks nothing",
    {"scripts/tool.swift": "import Foundation\n"},
    expect_ok=False,
    expect="this lint checked nothing",
    probes=PROBES[:1],
)
case(
    "a scripts/ tree that tracks nothing checks nothing",
    {"lib/TerminalCore/Sources/TerminalCore/Arm.swift": "import TerminalCore\n"},
    expect_ok=False,
    expect="no tracked file under: scripts/",
    probes=[],
    runner=False,
)
case(
    "a moved gate runner checks nothing",
    {"scripts/tool.swift": "import Foundation\n"},
    expect_ok=False,
    expect="this lint checked nothing",
    runner=False,
)

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"scripts_swift_orphan_lint_test: {len(failures)} case(s) FAILED", file=sys.stderr)
    raise SystemExit(1)
print("scripts_swift_orphan_lint_test: 11 cases passed")
