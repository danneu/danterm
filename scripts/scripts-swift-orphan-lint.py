#!/usr/bin/env python3
"""Keeps a Swift file that reaches first-party code out of `scripts/`, where nothing compiles it.

A `.swift` file under `scripts/` is outside every package manifest, so no `swift build`
reads it and no gate step type-checks it. That is invisible until the API it calls
changes shape, and then it is invisible for as long as nobody runs the tool by hand.
`scripts/terminal-headless-draw-arm.swift` sat unbuildable from `13db5f73` (2026-08-20)
until it moved into `lib/TerminalCore` -- and it is the harness four cost findings named
as the experiment that would decide them, so the lane lost its instrument and its gate
stayed green throughout.

The rule is on imports, not on the file's existence: a script that talks only to Foundation
or CoreGraphics cannot rot under us, because we do not change those. One that imports a
target this repository declares can, and the fix is always the same -- declare it as a
target of the package that owns the module, where SwiftPM compiles it like anything else.

The one live file this rule cannot see is `checkpoint-projection-cost-probe.swift`, which
imports nothing first-party yet is compiled together with DanTermCore's sources: DanTermCore
declares nothing `public`, so a probe that reaches `AppModel` has to be compiled same-module,
which no manifest can express. That one is covered by a gate step instead, and this lint
checks the step is still there.

`scripts/research/` is out of scope on purpose. Those probes are compiled the same
same-module way, but each one is pinned to a numbered research doc as the record of what
was measured at one revision. Re-pointing them at today's tree would destroy the thing they
are for, so they are allowed to stop building. A tool is gated; a record is not.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manifest_targets import LintError, declared_targets, first_party_manifests  # noqa: E402

LINT = "scripts-swift-orphan-lint"

# Test seam: the self-test points the lint at a fixture tree, so each verdict is proved
# without a compile. Nothing else sets this.
REPO_ROOT = Path(
    os.environ.get("SCRIPTS_SWIFT_ORPHAN_LINT_ROOT")
    or Path(__file__).resolve().parent.parent
).resolve()

IMPORT = re.compile(r"^[ \t]*(?:@testable[ \t]+)?import[ \t]+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
OPT_OUT = re.compile(r"^[ \t]*// gate: opt-out --[ \t]+(\S(?:.*\S)?)[ \t]*$", re.MULTILINE)

# The probe that cannot be a target, and the step that compiles it. Both spelled here so a
# rename of either is a failure rather than a silent gap.
# Frozen records rather than live tools -- see the module docstring.
RESEARCH = "scripts/research/"

SAME_MODULE_PROBE = Path("scripts/checkpoint-projection-cost-probe.swift")
SAME_MODULE_STEP = "./scripts/checkpoint-projection-cost.py --check"


def checked_nothing(*details: str) -> int:
    """Bails out of a run that could not read its subject, without printing the rule."""
    for detail in details:
        print(f"{LINT}: {detail}", file=sys.stderr)
    print("  this lint checked nothing. Point it at the moved path, or update the path here.",
          file=sys.stderr)
    return 1


def tracked(pattern: str) -> list[Path]:
    """Returns tracked repository-relative paths matching one git pathspec."""
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z", "--", pattern],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip() or "no diagnostic"
        raise LintError(f"tracked-file discovery failed: {detail}")
    return sorted(
        Path(raw.decode(errors="surrogateescape"))
        for raw in result.stdout.split(b"\0")
        if raw
    )


def first_party_modules() -> set[str]:
    """Every module name a first-party manifest declares, which is what may not be imported."""
    names: set[str] = set()
    for manifest in first_party_manifests(REPO_ROOT):
        for target in declared_targets(manifest):
            names.add(target.name)
    return names


def rationale() -> None:
    """Prints the rule and the fix, for the reader who just tripped this gate."""
    print(
        "\n"
        "scripts-swift-orphan lint FAILED: a Swift file under scripts/ imports a\n"
        "module this repository declares.\n"
        "\n"
        "Nothing compiles a .swift file under scripts/. No manifest declares it, so\n"
        "`swift build` never reads it and `just test` never type-checks it. It keeps\n"
        "compiling in the reader's head and nowhere else, until the day someone runs\n"
        "the tool and finds it has been broken since a refactor months earlier.\n"
        "\n"
        "That is not hypothetical. terminal-headless-draw-arm.swift called\n"
        "drawRenderFrame(plan, rows:) for six days after the parameter became\n"
        "restrictedTo: TerminalDamage?, and the gate was green every one of them --\n"
        "while four separate cost findings named that harness as the experiment that\n"
        "would settle them.\n"
        "\n"
        "Fix: declare it as a target of the package that owns the module it imports,\n"
        "and let its driver copy or invoke the built product. lib/TerminalCore's\n"
        "HeadlessDrawArm and TerminalRecordingReplay are both this shape.\n",
        file=sys.stderr,
    )


def main() -> int:
    try:
        scripts = tracked("scripts/**")
        modules = first_party_modules()
    except LintError as error:
        return checked_nothing(str(error))
    if not scripts:
        return checked_nothing("no tracked file under: scripts/")
    if not modules:
        return checked_nothing("no first-party manifest declares a target")

    complaints: list[str] = []
    imported_first_party = False
    swift = [
        path
        for path in scripts
        if path.suffix == ".swift" and not path.as_posix().startswith(RESEARCH)
    ]
    for path in swift:
        text = (REPO_ROOT / path).read_text()
        if OPT_OUT.search(text):
            continue
        offenders = sorted({name for name in IMPORT.findall(text) if name in modules})
        for name in offenders:
            imported_first_party = True
            complaints.append(f"{path}: imports the first-party module {name}")

    if SAME_MODULE_PROBE not in set(scripts):
        return checked_nothing(f"no such tracked file: {SAME_MODULE_PROBE}")
    runner = REPO_ROOT / "scripts/run-test-suite.sh"
    if not runner.is_file():
        return checked_nothing(f"no such file: {runner}")
    gate = runner.read_text()
    if SAME_MODULE_STEP not in gate:
        complaints.append(
            f"{SAME_MODULE_PROBE} is compiled same-module with DanTermCore and cannot be a "
            f"target, so the gate must run `{SAME_MODULE_STEP}`; it does not"
        )

    if complaints:
        for complaint in complaints:
            print(f"{LINT}: {complaint}", file=sys.stderr)
        # Only for the import rule: the gate-step complaint says its own reason, and the
        # rationale below would send that reader looking for an import that is not there.
        if imported_first_party:
            rationale()
        return 1
    print(
        f"{LINT}: {len(swift)} live Swift files under scripts/ import no first-party "
        f"module, and the gate compiles {SAME_MODULE_PROBE.name}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
