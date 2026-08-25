#!/usr/bin/env python3
"""Machine-check that the windows-terminal adoption ledger covers the whole pinned corpus.

DanTerm adopts cases from external test suites through a manifest that gives every
upstream case a disposition and a rationale. The manifest is the record of what was
judged. Its failure mode is not a wrong entry -- review catches those -- but a
*missing* one: a file nobody read looks exactly like a file with nothing worth
taking, because absence says nothing at all.

That failure happened. Research doc 26 pinned windows-terminal, classified 71 cases
in three of its sixteen test files, and left the other thirteen out of the manifest
with no marker. The JSON read as complete, the coverage test asserted the three
files it knew about, and 128 cases stayed unweighed for a month while the engine
changed underneath them. Doc 36 closed the gap; this lint is what stops it
reopening.

Checked invariants (IDs match research doc 36's D2):

  I1  The manifest's `pinnedCommit` matches the `windows-terminal` pin in
      scripts/fetch-references.py. A ledger judged against one revision says
      nothing about another, and a pin bump must force a re-read rather than
      silently re-point the claims.
  I2  Every upstream case in the pinned tree has a manifest entry. This is the
      invariant the incident violated.
  I3  Every manifest entry names a case that exists upstream. A phantom entry is a
      claim about nothing, and it also hides a real gap by inflating the count.
  I4  Every file in the pinned tree that holds cases has a manifest entry. A file
      missing entirely is I2's failure in bulk, and reporting it per-case would
      bury the one fact that matters.

`references/` is gitignored, so a fresh clone and CI have no checkout. Every
invariant here except I1 is unanswerable without one, and a partial verdict on a
completeness check is worse than none -- it would report "no unclassified cases
found" after looking at nothing. So the lint prints why and exits 0.

What it deliberately does not check: whether a disposition is correct, or whether a
rationale is true. Those are review's job, and research doc 36 records why reading
alone cannot settle them -- three reading-based verdicts in that census were
overturned by mutation testing, so a lint that tried would be confidently wrong.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_REL = (
    "lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/windows-terminal-manifest.json"
)

TEST_METHOD = re.compile(r"TEST_METHOD\(([A-Za-z0-9_]+)\)")

# ReflowTests.cpp holds one TEST_METHOD driving a table of named scenarios. The
# scenario is the unit that carries a disposition, so the ledger records those
# names instead of the method's. Nothing else in the corpus is table-driven this
# way; if a second file becomes so, it needs an entry here rather than a general
# rule, because "find the string table" is not something to guess at.
SCENARIO_TABLES = {
    "src/buffer/out/ut_textbuffer/ReflowTests.cpp": re.compile(
        r'^\s{12}L"((?:[^"\\]|\\.)+)",$', re.MULTILINE
    ),
}


def pinned_commit(fetch: Path) -> str | None:
    text = fetch.read_text()
    block = re.search(
        r'name="windows-terminal".*?pin="([0-9a-f]{40})"', text, re.DOTALL
    )
    return block.group(1) if block else None


def upstream_cases(path: Path, relative: str) -> list[str]:
    text = path.read_text(errors="replace")
    table = SCENARIO_TABLES.get(relative)
    if table:
        return [m.group(1) for m in table.finditer(text)]
    return [m.group(1) for m in TEST_METHOD.finditer(text)]


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_ROOT
    reference = root / "references" / "windows-terminal"
    manifest = json.loads((root / MANIFEST_REL).read_text())
    errors: list[str] = []

    expected = pinned_commit(root / "scripts" / "fetch-references.py")
    if expected is None:
        errors.append("could not read the windows-terminal pin from fetch-references.py")
    elif manifest["pinnedCommit"] != expected:
        errors.append(
            "I1 manifest pinnedCommit %s does not match the fetched pin %s.\n"
            "    The ledger was judged against a different revision. Re-read the\n"
            "    corpus before re-pointing it."
            % (manifest["pinnedCommit"], expected)
        )

    if not reference.is_dir():
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print(
            "external-corpus-ledger-lint: no references/windows-terminal checkout; "
            "I2-I4 skipped (run `just fetch-references windows-terminal` to check them)"
        )
        return 0

    ledger = {entry["path"]: entry for entry in manifest["files"]}

    found: dict[str, list[str]] = {}
    for path in sorted(reference.glob("src/**/ut_*/*.cpp")):
        relative = str(path.relative_to(reference))
        cases = upstream_cases(path, relative)
        if cases:
            found[relative] = cases

    for relative, cases in found.items():
        entry = ledger.get(relative)
        if entry is None:
            errors.append(
                "I4 %s holds %d cases and has no manifest entry.\n"
                "    A file absent from the ledger is not a file with nothing worth\n"
                "    taking -- it is a file nobody judged. Classify it or record it."
                % (relative, len(cases))
            )
            continue
        classified = {case["name"] for case in entry["cases"]}
        for name in cases:
            if name not in classified:
                errors.append("I2 %s case %s has no disposition" % (relative, name))
        for name in sorted(classified - set(cases)):
            errors.append(
                "I3 %s classifies %s, which does not exist upstream at this pin"
                % (relative, name)
            )

    for relative in ledger:
        if relative not in found:
            errors.append(
                "I3 the manifest classifies %s, which holds no cases at this pin"
                % relative
            )

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    total = sum(len(cases) for cases in found.values())
    print(
        "external-corpus-ledger-lint: windows-terminal complete -- "
        "%d files, %d cases, all classified" % (len(found), total)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
