#!/usr/bin/env python3
"""Machine-check DanTerm's Alacritty inline-test ledger and citations against the pinned checkout.

Two artifacts here claim to track `alacritty_terminal/src/**` unit tests, and both go
stale silently unless something re-reads upstream:

  * `Fixtures/alacritty-inline-manifest.json` gives all 135 inline `#[test]` functions a
    disposition. Its value is being *complete*: a group summary like "all 14 storage
    cases are implementation-coupled" hides a name that upstream later turns into real
    behavior. Only a name-by-name comparison against the checkout can notice.
  * A test adapted from one of those functions names it and records a hash of its body,
    so an upstream revision surfaces as a lint failure -- a prompt to re-read -- rather
    than as silent compatibility drift.

This is the Rust-side sibling of scripts/kitty-parity-lint.py, and deliberately not an
extension of it: the citation shape differs (Alacritty has no release tag at this pin)
and the ledger invariants have no kitty counterpart. It is also deliberately not an
extension of `alacritty-manifest.json`, whose schema describes the 45 `tests/ref/`
recording directories -- a different population, already fully classified.

Checked invariants:

  L1  The manifest lists exactly the inline `#[test]` inventory found in the checkout:
      no missing name, no name that upstream no longer has, no duplicate. Both
      directions matter -- a missing entry is an unclassified test hiding behind a
      group summary, and a stale entry is a disposition nothing supports any more.
  L2  The manifest's `pin` matches the `alacritty` pin in scripts/fetch-references.py,
      and every disposition is one of the declared vocabulary with a non-empty
      rationale. An unpinned ledger cannot be re-derived.
  L3  Every `adapted` entry names a Swift destination that exists and carries a
      citation back to that entry, and every citation's upstream name is an `adapted`
      entry. The manifest and the tests must not disagree about what was ported.

  I1  Every `Adapted from alacritty_terminal/...#<name>` citation parses and resolves to
      a real `fn <name>` in that file inside `references/alacritty`. A near-miss line is
      an error rather than a skip: a citation the lint cannot see is worse than no
      citation, because the gate then passes while checking nothing.
  I2  The cited commit matches the pin. A citation left behind by a pin bump is an
      error, not a warning: it claims a body hash was taken against a revision that is
      no longer the one on disk.
  I3  The recorded body hash matches the upstream body, where "body" runs from the
      `fn <name>` line through its balance-matched closing brace. Braces inside string,
      char, raw-string, and comment tokens do not count toward the balance, which is
      what makes the hash a hash of the test rather than of the lexer's luck.
  I4  Every citation carries a `Divergence:` line, or an explicit `Divergence: none`.
      We adopt Alacritty's scenarios, never its verdicts, so a citation without one is
      an unstated claim of assertion-level parity.

`references/` is gitignored, so a fresh clone and CI have no checkout. Every invariant
above is unanswerable there, so the lint prints why and exits 0.

What it deliberately does not check: whether an adaptation is faithful, whether a
`Divergence:` text is accurate, or whether a `superseded` rationale is true. Those are
review's job. The self-test (scripts/tests/alacritty-parity-lint_test.sh) pins every
invariant in both directions.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import sys


# `.claude` holds agent worktrees (`.claude/worktrees/<name>`), which are full checkouts of
# this same repository. Without skipping it, a lint run from the main checkout also reads
# every in-progress worktree -- so a mistyped citation or a not-yet-recorded hash in someone
# else's branch fails `just test` here, for a file that is not on this branch.
SKIP_DIRS = {".git", ".claude", "references", "GhosttyKit.xcframework"}

UPSTREAM_SUBDIR = "alacritty_terminal/src"
MANIFEST_RELPATH = Path("lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/alacritty-inline-manifest.json")

CITATION_RE = re.compile(r"//\s*Adapted from (alacritty_terminal/[\w./-]+)#([\w]+)\s*$")
# A line that means to be a citation but does not parse as one. Without this, a typo
# silently drops the citation from the lint's view and the gate keeps passing while
# checking nothing -- the exact drift the lint exists to prevent.
LOOSE_CITATION_RE = re.compile(r"//.*Adapted from alacritty_terminal")
PROVENANCE_RE = re.compile(r"\(alacritty ([0-9a-f]{7,40}), body sha256:([0-9a-f]{12,64})\)")
DIVERGENCE_RE = re.compile(r"//\s*Divergence:\s*\S")
ALACRITTY_PIN_RE = re.compile(r'name="alacritty".*?pin="([0-9a-f]{40})"', re.DOTALL)

TEST_ATTRIBUTE_RE = re.compile(r"^\s*#\[test\]\s*$")
FN_RE = re.compile(r"^(\s*)(?:pub\s+)?(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)")

# A disposition says why a name is not (or is) a DanTerm test. The vocabulary is closed
# so a reviewer can count the ledger by class instead of reading 135 free-text lines.
DISPOSITIONS = {
    # Ported: a DanTerm test now tracks this scenario and cites it.
    "adapted",
    # The scenario reaches DanTerm behavior, but existing DanTerm tests already pin it
    # at least as strongly. Porting would add a duplicate, not a boundary.
    "superseded",
    # Specifies Alacritty's internal representation (storage ring, index arithmetic,
    # cell layout, iterators, serde). There is no DanTerm behavior underneath it.
    "implementation-coupled",
    # Requires a feature DanTerm does not offer (vi mode, block selection, SCS line
    # drawing, disabling reflow) or lives outside TerminalCore (tty/platform).
    "unsupported",
    # The scenario is reachable, but DanTerm's contract deliberately produces a
    # different result. Adopting the verdict would be adopting Alacritty's policy.
    "policy-divergence",
}


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

    A block is the `Adapted from` line plus the `//` comment lines immediately below it,
    which is where the provenance and `Divergence:` lines live. The next citation or the
    first non-comment line ends it.
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
                commit=provenance.group(1) if provenance else None,
                body_hash=provenance.group(2) if provenance else None,
                has_divergence=any(DIVERGENCE_RE.search(entry) for entry in block),
            )
        )
    return citations, malformed


def _skip_rust_token(text: str, index: int) -> int | None:
    """Index just past a comment or literal starting at `index`, or None if none starts there.

    Only these tokens can contain a brace that is not structural, so this is the whole
    reason `rust_fn_body` can count braces at all. Raw strings (`r#"..."#`) need the hash
    count because they are exactly the form whose terminator is not a bare quote.
    """
    if text.startswith("//", index):
        end = text.find("\n", index)
        return len(text) if end == -1 else end
    if text.startswith("/*", index):
        depth = 0
        cursor = index
        while cursor < len(text):
            if text.startswith("/*", cursor):
                depth += 1
                cursor += 2
            elif text.startswith("*/", cursor):
                depth -= 1
                cursor += 2
                if depth == 0:
                    return cursor
            else:
                cursor += 1
        return len(text)
    raw = re.compile(r"r(#*)\"").match(text, index)
    if raw is not None:
        terminator = '"' + raw.group(1)
        end = text.find(terminator, raw.end())
        return len(text) if end == -1 else end + len(terminator)
    if text[index] == '"':
        cursor = index + 1
        while cursor < len(text):
            if text[cursor] == "\\":
                cursor += 2
                continue
            if text[cursor] == '"':
                return cursor + 1
            cursor += 1
        return len(text)
    # A char literal, but not a lifetime (`&'a str`) -- only the literal can hide a brace.
    char = re.compile(r"'(?:\\.|[^\\'])'").match(text, index)
    if char is not None:
        return char.end()
    return None


def rust_fn_body(source: str, name: str) -> str | None:
    """The `fn <name>` declaration through its balance-matched closing brace, or None.

    Hashing the balanced body rather than "up to the next `fn`" keeps the hash stable
    against edits to neighbouring tests and to the attributes and comments between them,
    so a hash mismatch means upstream revised *this* test.
    """
    pattern = re.compile(r"^(\s*)(?:pub\s+)?(?:async\s+)?fn\s+" + re.escape(name) + r"\s*[(<]", re.MULTILINE)
    match = pattern.search(source)
    if match is None:
        return None
    start = match.start()
    cursor = source.find("{", match.end())
    if cursor == -1:
        return None
    depth = 0
    while cursor < len(source):
        skipped = _skip_rust_token(source, cursor)
        if skipped is not None:
            cursor = skipped
            continue
        char = source[cursor]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start : cursor + 1]
        cursor += 1
    return None


def inline_test_inventory(checkout: Path) -> tuple[list[str], list[str]]:
    """Every `#[test]` function under `alacritty_terminal/src` as `file#fn`, plus parse failures.

    A `#[test]` whose function the scan cannot name is reported rather than dropped: a
    silently skipped annotation would shrink the inventory and let L1 pass against a
    ledger that is missing that very name.
    """
    src = checkout / UPSTREAM_SUBDIR
    names: list[str] = []
    unparsed: list[str] = []
    for path in sorted(src.rglob("*.rs")):
        lines = path.read_text(encoding="utf-8").split("\n")
        relative = path.relative_to(checkout).as_posix()
        for index, line in enumerate(lines):
            if TEST_ATTRIBUTE_RE.match(line) is None:
                continue
            for follower in lines[index + 1 :]:
                stripped = follower.strip()
                # Further attributes (`#[cfg(...)]`, `#[should_panic]`) and comments may
                # sit between `#[test]` and the function it applies to.
                if not stripped or stripped.startswith("#[") or stripped.startswith("//"):
                    continue
                found = FN_RE.match(follower)
                if found is None:
                    unparsed.append(f"{relative}:{index + 1}: `#[test]` is not followed by a `fn`")
                else:
                    names.append(f"{relative}#{found.group(2)}")
                break
    return names, unparsed


def alacritty_pin(root: Path) -> str:
    """The pinned Alacritty commit, read from the one place that owns it."""
    source = root / "scripts" / "fetch-references.py"
    match = ALACRITTY_PIN_RE.search(source.read_text(encoding="utf-8"))
    if match is None:
        raise SystemExit(f"alacritty-parity lint: no alacritty pin found in {source}")
    return match.group(1)


def check(root: Path) -> int:
    checkout = root / "references" / "alacritty"
    if not checkout.is_dir():
        print(
            f"alacritty-parity lint skipped: no checkout at {checkout}"
            " (run `just fetch-references alacritty`)"
        )
        return 0

    pin = alacritty_pin(root)
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
                "line does not parse as `// Adapted from alacritty_terminal/<file>#<test>`,"
                " so the citation would go unchecked",
            )

    sources: dict[str, str] = {}
    for citation in citations:
        cited = f"{citation.upstream_file}#{citation.upstream_test}"

        if citation.commit is None or citation.body_hash is None:
            err(citation, "I2/I3", f"{cited} has no `(alacritty <commit>, body sha256:<hash>)` provenance line")
        elif not pin.startswith(citation.commit):
            err(
                citation,
                "I2",
                f"{cited} cites alacritty {citation.commit}, but the pin is {pin[: len(citation.commit)]}"
                " -- re-read the upstream test and re-record the hash",
            )

        if not citation.has_divergence:
            err(citation, "I4", f"{cited} has no `Divergence:` line (use `Divergence: none` if there is none)")

        upstream = checkout / citation.upstream_file
        if not upstream.is_file():
            err(citation, "I1", f"{citation.upstream_file} does not exist in {checkout}")
            continue
        if citation.upstream_file not in sources:
            sources[citation.upstream_file] = upstream.read_text(encoding="utf-8")
        body = rust_fn_body(sources[citation.upstream_file], citation.upstream_test)
        if body is None:
            err(citation, "I1", f"{cited} names no `fn {citation.upstream_test}` in the pinned checkout")
            continue
        if citation.body_hash is not None:
            actual = hashlib.sha256(body.encode("utf-8")).hexdigest()
            if not actual.startswith(citation.body_hash):
                err(
                    citation,
                    "I3",
                    f"{cited} records sha256:{citation.body_hash}, upstream is"
                    f" sha256:{actual[: len(citation.body_hash)]} -- upstream revised the test,"
                    " or the recorded hash is wrong",
                )

    errors.extend(check_manifest(root, checkout, pin, citations))

    for line in errors:
        print(line, file=sys.stderr)
    if errors:
        print(FAILURE_EXPLANATION, file=sys.stderr)
        return 1

    print(
        f"alacritty parity lint passed ({len(citations)} citations"
        f" against alacritty {pin[:7]})"
    )
    return 0


def check_manifest(root: Path, checkout: Path, pin: str, citations: list[Citation]) -> list[str]:
    """L1-L3: the ledger covers the pinned inventory exactly and agrees with the citations."""
    path = root / MANIFEST_RELPATH
    if not path.is_file():
        return [f"{MANIFEST_RELPATH}:1: [L1] the inline manifest does not exist"]

    errors: list[str] = []

    def fail(invariant: str, message: str) -> None:
        errors.append(f"{MANIFEST_RELPATH}:1: [{invariant}] {message}")

    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return [f"{MANIFEST_RELPATH}:1: [L2] is not valid JSON: {error}"]

    if manifest.get("pin") != pin:
        fail("L2", f"records pin {manifest.get('pin')!r}, but the alacritty pin is {pin}")

    entries = manifest.get("tests")
    if not isinstance(entries, list):
        return errors + [f"{MANIFEST_RELPATH}:1: [L1] has no `tests` array"]

    listed: list[str] = []
    adapted: dict[str, dict] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            fail("L1", f"tests[{index}] is not an object")
            continue
        name = entry.get("test")
        if not isinstance(name, str):
            fail("L1", f"tests[{index}] has no string `test` name")
            continue
        listed.append(name)
        disposition = entry.get("disposition")
        if disposition not in DISPOSITIONS:
            fail("L2", f"{name} has disposition {disposition!r}, not one of {sorted(DISPOSITIONS)}")
        if not isinstance(entry.get("rationale"), str) or not entry["rationale"].strip():
            fail("L2", f"{name} has no non-empty `rationale`")
        if disposition == "adapted":
            adapted[name] = entry

    inventory, unparsed = inline_test_inventory(checkout)
    for line in unparsed:
        errors.append(f"{line} [L1]")

    for name in sorted({name for name in listed if listed.count(name) > 1}):
        fail("L1", f"{name} is listed more than once")
    for name in sorted(set(inventory) - set(listed)):
        fail("L1", f"{name} is a pinned `#[test]` with no ledger entry")
    for name in sorted(set(listed) - set(inventory)):
        fail("L1", f"{name} is a ledger entry that the pinned checkout does not have")

    cited_names = {f"{one.upstream_file}#{one.upstream_test}" for one in citations}
    for name in sorted(set(adapted) - cited_names):
        fail("L3", f"{name} is marked `adapted` but no Swift test cites it")
    for name in sorted(cited_names - set(adapted)):
        fail("L3", f"{name} is cited by a Swift test but is not marked `adapted` in the ledger")
    for name, entry in sorted(adapted.items()):
        destination = entry.get("destination")
        if not isinstance(destination, str) or not destination.strip():
            fail("L3", f"{name} is `adapted` but names no `destination` Swift file")
        elif not (root / destination).is_file():
            fail("L3", f"{name} names destination {destination}, which does not exist")

    return errors


FAILURE_EXPLANATION = """
=======================================================================
alacritty-parity lint FAILED. The inline ledger classifies every pinned
`#[test]`, and each adapted test names one and hashes its body, so both
stay answerable:

  L1 inventory mismatch -- the ledger and the pinned checkout disagree
    about which inline tests exist. Add the missing names, or drop the
    entries upstream removed, after reading what changed.

  L2 ledger shape -- the recorded pin moved, or an entry has an unknown
    disposition or an empty rationale. A ledger nobody can re-derive is
    not evidence.

  L3 ledger/citation disagreement -- an `adapted` entry with no citing
    test, a citation with no `adapted` entry, or a missing destination
    file. Exactly one of the two artifacts is wrong; fix that one.

  I1 unresolved -- the citation does not parse, or upstream renamed,
    moved, or deleted the test. Fix the line, find where the test went,
    or drop the adaptation if the scenario is gone.

  I2 stale commit -- the alacritty pin moved since the hash was taken.
    Re-read the upstream test at the new pin, then re-record both the
    commit and the hash.

  I3 hash mismatch -- upstream revised the test body. That is the prompt
    this lint exists to raise: read the diff, decide whether our
    adaptation still holds, then re-record the hash.

  I4 missing Divergence -- we adopt Alacritty's scenarios, never its
    verdicts. Say what we assert instead, or `Divergence: none`.
=======================================================================""".strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "root",
        nargs="?",
        default=Path(__file__).resolve().parent.parent,
        type=Path,
        help="repository root to lint (defaults to this script's repository)",
    )
    parser.add_argument(
        "--print-hash",
        metavar="FILE#FN",
        help="print the body hash for one upstream test and exit, for recording a citation",
    )
    parser.add_argument(
        "--print-inventory",
        action="store_true",
        help="print the pinned inline `#[test]` inventory as `file#fn` lines and exit",
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    if arguments.print_inventory:
        names, unparsed = inline_test_inventory(root / "references" / "alacritty")
        print("\n".join(names))
        for line in unparsed:
            print(line, file=sys.stderr)
        return 1 if unparsed else 0

    if arguments.print_hash:
        upstream_file, _, name = arguments.print_hash.partition("#")
        source = (root / "references" / "alacritty" / upstream_file).read_text(encoding="utf-8")
        body = rust_fn_body(source, name)
        if body is None:
            print(f"no `fn {name}` in {upstream_file}", file=sys.stderr)
            return 1
        print(hashlib.sha256(body.encode("utf-8")).hexdigest()[:12])
        return 0

    return check(root)


if __name__ == "__main__":
    sys.exit(main())
