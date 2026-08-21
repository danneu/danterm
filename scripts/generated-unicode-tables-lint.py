#!/usr/bin/env python3
"""Enforces that the committed Unicode tables are the ones the generator wrote.

`scripts/generate-terminal-unicode-tables.py` already pins every INPUT: it holds a
sha256 for each of the nine UCD files and refuses to run against data that does not
match. Nothing pinned the OUTPUT. Regenerating needs those nine files, which are not
in the tree, so no gate step can re-run the generator offline -- and that left a
hand-edit to any `*.generated.swift` passing `just test` in silence. A table is
thousands of machine-written lines that no reviewer reads closely, so a silent edit
there is the kind that survives.

This closes the other half: inputs pinned in the generator, outputs pinned in
`scripts/generated-unicode-tables.sha256`. The check is a hash compare, so it needs
no network, no Unicode data, and no compiler.

What it does NOT claim: it cannot tell you the tables are what the CURRENT pinned
inputs produce, because it never runs the generator. Someone who edits a table and
re-runs `--update` passes. That is deliberate -- the manifest diff then shows up in
review as an unexplained hash change with no generator run behind it, which is a
question a human can ask. The check guards against the accident, not the forgery.

The artifact list comes from the generator's GENERATED_ARTIFACTS rather than being
copied here, so a ninth artifact is covered the moment it is added there.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import sys
from pathlib import Path

SCRIPTS_DIRECTORY = Path(__file__).resolve().parent
GENERATOR = SCRIPTS_DIRECTORY / "generate-terminal-unicode-tables.py"
MANIFEST_RELATIVE_PATH = "scripts/generated-unicode-tables.sha256"

# Test seam: the self-test points the lint at a fixture tree so each verdict is
# proved without the pinned Unicode data. Nothing else sets this.
REPO_ROOT = Path(
    os.environ.get("GENERATED_UNICODE_TABLES_LINT_ROOT") or SCRIPTS_DIRECTORY.parent
).resolve()


def generated_artifacts() -> list[str]:
    """The generator's own list of what it writes, read without running it.

    The module guards its work behind `if __name__ == "__main__"`, so importing it
    costs nothing and cannot touch the tree.
    """
    spec = importlib.util.spec_from_file_location("_unicode_generator", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return sorted(module.GENERATED_ARTIFACTS.values())


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_manifest(path: Path) -> dict[str, str]:
    """Parses the `<sha256>  <repo-relative path>` lines shasum itself would emit."""
    entries: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            raise ValueError(f"{MANIFEST_RELATIVE_PATH}:{number}: not `<sha256>  <path>`")
        entries[parts[1].strip()] = parts[0]
    return entries


def write_manifest(path: Path, digests: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{digests[name]}  {name}" for name in sorted(digests)]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the manifest from the tree, after regenerating the tables",
    )
    arguments = parser.parse_args()

    artifacts = generated_artifacts()
    manifest_path = REPO_ROOT / MANIFEST_RELATIVE_PATH

    if not artifacts:
        print(
            "generated-unicode-tables-lint: the generator declares no artifacts, so "
            "this check is checking nothing.",
            file=sys.stderr,
        )
        return 1

    complaints: list[str] = []
    present: dict[str, str] = {}
    for name in artifacts:
        path = REPO_ROOT / name
        if not path.is_file():
            complaints.append(
                f"{name} is declared by the generator but missing from the tree. Run "
                "`python3 scripts/generate-terminal-unicode-tables.py` to write it."
            )
            continue
        present[name] = digest(path)

    if arguments.update:
        if complaints:
            for complaint in complaints:
                print(f"generated-unicode-tables-lint: {complaint}", file=sys.stderr)
            return 1
        write_manifest(manifest_path, present)
        print(
            f"generated-unicode-tables-lint: wrote {len(present)} hashes to "
            f"{MANIFEST_RELATIVE_PATH}"
        )
        return 0

    if not manifest_path.is_file():
        print(
            f"generated-unicode-tables-lint: {MANIFEST_RELATIVE_PATH} is missing, so "
            "nothing pins the generated tables. Regenerate them, confirm the diff, then "
            "run this script with --update.",
            file=sys.stderr,
        )
        return 1

    try:
        recorded = read_manifest(manifest_path)
    except ValueError as error:
        print(f"generated-unicode-tables-lint: {error}", file=sys.stderr)
        return 1

    for name in sorted(set(recorded) - set(artifacts)):
        complaints.append(
            f"{MANIFEST_RELATIVE_PATH} pins {name}, which the generator no longer "
            "writes. Drop the line, or restore the artifact."
        )

    for name in artifacts:
        if name not in present:
            continue
        if name not in recorded:
            complaints.append(
                f"{name} is generated but {MANIFEST_RELATIVE_PATH} does not pin it. Run "
                "this script with --update so the gate guards it too."
            )
            continue
        if recorded[name] != present[name]:
            complaints.append(
                f"{name} does not match the manifest: expected {recorded[name]}, found "
                f"{present[name]}. A generated table is written by "
                "scripts/generate-terminal-unicode-tables.py and never edited by hand. "
                "If the change is a real regeneration, run this script with --update in "
                "the same commit."
            )

    if complaints:
        for complaint in complaints:
            print(f"generated-unicode-tables-lint: {complaint}", file=sys.stderr)
        return 1

    print(
        f"generated-unicode-tables-lint: {len(artifacts)} generated artifacts match "
        f"{MANIFEST_RELATIVE_PATH}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
