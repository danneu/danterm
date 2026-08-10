#!/usr/bin/env python3
"""Machine-check the adapted-kitty citations in DanTerm's tests against the pinned checkout.

A test adapted from `kitty_tests/` names the upstream test it tracks and records a
hash of that test's body. The point of recording the hash is that a pin bump makes
upstream revisions surface as a lint failure -- a prompt to re-read -- instead of
as silent compatibility drift. Nothing else in the repository can notice that
kitty rewrote a test we claim to follow.

Checked invariants (IDs match the plan that introduced them):

  I1  Every `Adapted from kitty_tests/...#<name>` citation parses and resolves to
      a real `def <name>` in that file inside `references/kitty`. A near-miss line
      is an error rather than a skip: a citation the lint cannot see is worse than
      no citation, because the gate then passes while checking nothing.
  I2  The cited commit matches the `kitty` pin in scripts/fetch-references.py. A
      citation left behind by a pin bump is an error, not a warning: it claims a
      body hash was taken against a revision that is no longer the one on disk.
  I3  The recorded body hash matches the upstream body, where "body" runs from the
      `def <name>(` line to the next line at the same or lower indentation
      beginning `def ` or `class `.
  I4  Every citation carries a `Divergence:` line, or an explicit
      `Divergence: none`. We adopt kitty's scenarios, never its assertions, so a
      citation without one is an unstated claim of assertion-level parity.

`references/` is gitignored, so a fresh clone and CI have no checkout. I1 and I3
are unanswerable there, and the rest are not worth a partial verdict, so the lint
prints why and exits 0.

What it deliberately does not check: whether the adaptation is faithful, or
whether the `Divergence:` text is accurate -- both are review's job. The self-test
(scripts/tests/kitty-parity-lint_test.sh) pins every invariant in both directions.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path
import re
import sys


# `.claude` holds agent worktrees (`.claude/worktrees/<name>`), which are full checkouts of
# this same repository. Without skipping it, a lint run from the main checkout also reads
# every in-progress worktree -- so a mistyped citation or a not-yet-recorded hash in someone
# else's branch fails `just test` here, for a file that is not on this branch.
SKIP_DIRS = {".git", ".claude", "references"}

CITATION_RE = re.compile(r"//\s*Adapted from (kitty_tests/[\w./-]+)#([\w]+)\s*$")
# A line that means to be a citation but does not parse as one. Without this, a
# typo silently drops the citation from the lint's view and the gate keeps passing
# while checking nothing -- the exact drift the lint exists to prevent.
LOOSE_CITATION_RE = re.compile(r"//.*Adapted from kitty_tests")
PROVENANCE_RE = re.compile(r"\(kitty (\S+) ([0-9a-f]{7,40}), body sha256:([0-9a-f]{12,64})\)")
DIVERGENCE_RE = re.compile(r"//\s*Divergence:\s*\S")
KITTY_PIN_RE = re.compile(r'name="kitty".*?pin="([0-9a-f]{40})"', re.DOTALL)


@dataclass(frozen=True)
class Citation:
    """One `Adapted from` block, located precisely enough to report as `path:line`."""

    path: Path
    line: int
    upstream_file: str
    upstream_test: str
    commit: str | None
    body_hash: str | None
    has_divergence: bool


def swift_sources(root: Path) -> list[Path]:
    """Every tracked-ish Swift file under `root`, skipping vendored, build, and worktree trees.

    The skip test runs on each path's components *below `root`*, never its absolute ones.
    Linting a checkout that itself lives under a skipped name -- which is exactly what an
    agent worktree at `.claude/worktrees/<name>` is -- must lint that checkout normally
    rather than skip every file in it and report a vacuous pass.
    """
    found: list[Path] = []
    for path in sorted(root.rglob("*.swift")):
        relative = path.relative_to(root)
        if any(part in SKIP_DIRS or part.startswith(".build") for part in relative.parts):
            continue
        found.append(path)
    return found


def parse_citations(path: Path) -> tuple[list[Citation], list[int]]:
    """Extract every citation block from one Swift file, plus any malformed lines.

    A block is the `Adapted from` line plus the `//` comment lines immediately
    below it, which is where the provenance and `Divergence:` lines live. The next
    citation or the first non-comment line ends it.
    """
    citations: list[Citation] = []
    malformed: list[int] = []
    lines = path.read_text(encoding="utf-8").split("\n")
    for index, line in enumerate(lines):
        match = CITATION_RE.search(line)
        if match is None:
            if LOOSE_CITATION_RE.search(line):
                malformed.append(index + 1)
            continue
        block = [line]
        for follower in lines[index + 1 :]:
            stripped = follower.strip()
            if not stripped.startswith("//") or CITATION_RE.search(follower):
                break
            block.append(follower)
        joined = "\n".join(block)
        provenance = PROVENANCE_RE.search(joined)
        citations.append(
            Citation(
                path=path,
                line=index + 1,
                upstream_file=match.group(1),
                upstream_test=match.group(2),
                commit=provenance.group(2) if provenance else None,
                body_hash=provenance.group(3) if provenance else None,
                has_divergence=any(DIVERGENCE_RE.search(entry) for entry in block),
            )
        )
    return citations, malformed


def upstream_body(path: Path, name: str) -> bytes | None:
    """The source text of `def <name>` in `path`, or None when there is no such def.

    The end of the body is the next non-blank line at the same or lower indentation
    that begins a `def` or `class`. Decorators and comments between defs therefore
    stay attached to the following definition rather than terminating this one --
    which is what makes the hash stable against edits that do not touch the test.
    """
    lines = path.read_bytes().split(b"\n")
    pattern = re.compile(rb"^(\s*)def " + re.escape(name.encode()) + rb"\s*\(")
    start = None
    indent = 0
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if match is not None:
            start = index
            indent = len(match.group(1))
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        stripped = line.lstrip()
        if not stripped:
            continue
        leading = len(line) - len(stripped)
        if leading <= indent and (stripped.startswith(b"def ") or stripped.startswith(b"class ")):
            end = index
            break
    return b"\n".join(lines[start:end])


def kitty_pin(root: Path) -> str:
    """The pinned kitty commit, read from the one place that owns it."""
    source = root / "scripts" / "fetch-references.py"
    match = KITTY_PIN_RE.search(source.read_text(encoding="utf-8"))
    if match is None:
        raise SystemExit(f"kitty-parity lint: no kitty pin found in {source}")
    return match.group(1)


def check(root: Path) -> int:
    checkout = root / "references" / "kitty"
    if not checkout.is_dir():
        print(f"kitty-parity lint skipped: no checkout at {checkout} (run `just fetch-references kitty`)")
        return 0

    pin = kitty_pin(root)
    errors: list[str] = []

    def report(path: Path, line: int, invariant: str, message: str) -> None:
        location = path.relative_to(root) if path.is_relative_to(root) else path
        errors.append(f"{location}:{line}: [{invariant}] {message}")

    def err(citation: Citation, invariant: str, message: str) -> None:
        report(citation.path, citation.line, invariant, message)

    citations: list[Citation] = []
    for path in swift_sources(root):
        parsed, malformed = parse_citations(path)
        citations.extend(parsed)
        for line in malformed:
            report(
                path,
                line,
                "I1",
                "line does not parse as `// Adapted from kitty_tests/<file>#<test>`,"
                " so the citation would go unchecked",
            )

    for citation in citations:
        cited = f"{citation.upstream_file}#{citation.upstream_test}"

        if citation.commit is None or citation.body_hash is None:
            err(
                citation,
                "I2/I3",
                f"{cited} has no `(kitty <tag> <commit>, body sha256:<hash>)` provenance line",
            )
        else:
            if not pin.startswith(citation.commit):
                err(
                    citation,
                    "I2",
                    f"{cited} cites kitty {citation.commit}, but the pin is {pin[:len(citation.commit)]}"
                    " -- re-read the upstream test and re-record the hash",
                )

        if not citation.has_divergence:
            err(citation, "I4", f"{cited} has no `Divergence:` line (use `Divergence: none` if there is none)")

        upstream = checkout / citation.upstream_file
        if not upstream.is_file():
            err(citation, "I1", f"{citation.upstream_file} does not exist in {checkout}")
            continue
        body = upstream_body(upstream, citation.upstream_test)
        if body is None:
            err(citation, "I1", f"{cited} names no `def {citation.upstream_test}` in the pinned checkout")
            continue
        if citation.body_hash is not None:
            actual = hashlib.sha256(body).hexdigest()
            if not actual.startswith(citation.body_hash):
                err(
                    citation,
                    "I3",
                    f"{cited} records sha256:{citation.body_hash}, upstream is"
                    f" sha256:{actual[: len(citation.body_hash)]} -- upstream revised the test,"
                    " or the recorded hash is wrong",
                )

    for line in errors:
        print(line, file=sys.stderr)
    if errors:
        print(
            "\n"
            "=======================================================================\n"
            "kitty-parity lint FAILED. Each adapted test names an upstream kitty\n"
            "test and hashes its body, so the citations stay answerable:\n"
            "\n"
            "  I1 unresolved -- the citation does not parse, or upstream renamed,\n"
            "    moved, or deleted the test. Fix the line, find where the test\n"
            "    went, or drop the adaptation if the scenario is gone.\n"
            "\n"
            "  I2 stale commit -- the kitty pin moved since the hash was taken.\n"
            "    Re-read the upstream test at the new pin, then re-record both\n"
            "    the commit and the hash.\n"
            "\n"
            "  I3 hash mismatch -- upstream revised the test body. That is the\n"
            "    prompt this lint exists to raise: read the diff, decide whether\n"
            "    our adaptation still holds, then re-record the hash.\n"
            "\n"
            "  I4 missing Divergence -- we adopt kitty's scenarios, never its\n"
            "    assertions. Say what we assert instead, or `Divergence: none`.\n"
            "=======================================================================",
            file=sys.stderr,
        )
        return 1

    print(f"kitty parity lint passed ({len(citations)} citations against kitty {pin[:7]})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "root",
        nargs="?",
        default=Path(__file__).resolve().parent.parent,
        type=Path,
        help="repository root to lint (defaults to this script's repository)",
    )
    return check(parser.parse_args().root.resolve())


if __name__ == "__main__":
    sys.exit(main())
