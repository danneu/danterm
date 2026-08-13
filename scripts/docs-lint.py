#!/usr/bin/env python3
"""Machine-check two things about DanTerm's living documentation: that the code and doc paths it cites still exist, and that a design note's front matter says what the note actually is.

Both failures were observed. A rename moved Projections.swift and
ModelOperations.swift from `app/` into `lib/DanTermCore/`, and the design note that
lists them as its References kept pointing at `app/` -- telling every later reader
that view projections are app-layer code when they are pure core, which is the one
distinction core-purity-lint.sh exists to protect. Separately, four notes read
`Status: Accepted` directly above a block quote saying they had been superseded,
and one of those named no successor at all.

Checked invariants:

  D1  Every repo-relative path cited in backticks resolves to a real file or
      directory. A path is repo-relative when its first component is a top-level
      entry of this repo (derived from git, so it needs no upkeep) or one of
      DEAD_ROOTS below.
  D2  Every relative markdown link resolves. This subsumes intra-docs/ and
      intra-docs/design/ links; they are relative links like any other.
  D3  Every `docs/design/*.md` except `index.md` carries `- Status: ` on line 3 and
      `- Date: ` on line 4, as bullets, in that order. `` `Status`: `` and a bare
      `Status:` are rejected: the index's format section fixes one spelling, and
      three were in the tree before it did.
  D4  `Status` is Accepted, Superseded, or Draft.
  D5  `Status: Superseded` carries a `- Superseded by: ` field whose markdown link
      resolves to another note in `docs/design/`.
  D6  A `Superseded by` field requires `Status: Superseded`. This is the check that
      would have caught the original bug: the successor link was there and the
      status still said the note bound.
  D7  A note with a `> **` banner in its first 20 lines carries either
      `Status: Superseded` or an `- Amended: ` field. A banner means something below
      it is dead, and the front matter has to say which kind of dead.
  D8  `Supersedes` and `Superseded by` are symmetric. If A supersedes B, B names A.
  D9  `Date` matches the note filename's date prefix.
  D10 `index.md`'s note list and the directory agree exactly -- one row per note, no
      orphan rows -- each row's status word matches the note's `Status`, and the rows
      run newest last, as the list's own heading says.

Scope. D1 and D2 read AGENTS.md, CLAUDE.md, docs/**, and agent-docs/**, minus
docs/scratch/. They deliberately skip plans/ and docs/scratch/: those are dated
records whose links are meant to rot, so linting them would either falsify a
historical record or need an allowlist as long as the tree. docs/evidence/ and
docs/research/ are dated too, but they are cited from live documents by stable id,
so a reader follows their paths and has to be able to trust them; they are in, and
the few paths they name as gone carry a marker. Fenced code blocks are skipped
everywhere, because a path inside one is a template, not a citation. Link targets
under plans/, references/, and .build/ are not resolved, for the same reason plus
the fact that the last two are not tracked.

Escape hatch. A document sometimes names a deleted file on purpose -- a supersession
banner exists to say "this is gone". Such a document declares the paths it means to
leave dangling:

    <!-- docs-lint: allow-missing app/TerminalView.swift -->

The marker may list several paths, may repeat, and may sit anywhere in the file. It
exempts only those exact targets and only in the file that declares them, so a fresh
dangling citation in the same file still fails. A whole-file or whole-section escape
was the alternative; it hides every later mistake in its range, and a reader of the
file cannot see what it forgave.

Two things it deliberately does not check. A backticked token with no directory in
it: `Model.swift` names no location, so resolving it would mean guessing which one.
And the identifier half of the `file#identifier` form: resolving that means parsing
Swift, Python, shell, and markdown headings, and a miss there is a false positive on
a correct citation -- worse than the drift it would catch, so only the path half is
resolved. It also does not judge whether a citation names the *right* file, or
whether a banner's prose is accurate.

The self-test (scripts/tests/docs_lint_test.py) drives every invariant in both
directions.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import posixpath
import re
import subprocess
import sys
from pathlib import Path


# Top-level names that no longer exist but are still worth catching. Live roots come
# from git, so a citation into a directory that was deleted wholesale would otherwise
# stop being checked at the moment it went stale -- which is exactly when it starts
# lying. plan-terminal-engine/ was deleted on 2026-08-12.
DEAD_ROOTS = frozenset({"plan-terminal-engine"})

# Targets under these prefixes are never resolved, because nothing in the repo
# promises they are there. plans/ links are meant to rot (AGENTS.md: plan ids are not
# stable and are not cited); references/ holds gitignored external checkouts that may
# not be materialized; .build/ is build output. Anything else that is gone uses an
# allow-missing marker, so the document says so where a reader can see it.
UNRESOLVED_ROOTS = ("plans/", "references/", ".build/")

SCOPE_SKIP_PREFIXES = ("plans/", "references/", "docs/scratch/")
SCOPE_KEEP_PREFIXES = ("docs/", "agent-docs/")
SCOPE_KEEP_FILES = frozenset({"AGENTS.md", "CLAUDE.md"})

STATUS_WORDS = ("Accepted", "Superseded", "Draft")
LINK_FIELDS = ("Superseded by", "Supersedes")

FENCE_RE = re.compile(r"^[ \t]*(```|~~~)")
MARKER_RE = re.compile(r"<!--[ \t]*docs-lint:[ \t]*allow-missing[ \t]")
# A markdown link whose target has no spaces or nested parens. A title after the
# target is not a form this tree uses, so a space ends the target.
LINK_RE = re.compile(r"\]\(([^)( \t]*)\)")
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
BACKTICK_RE = re.compile(r"`([^`]+)`")
PATH_TOKEN_RE = re.compile(r"^[A-Za-z0-9_./+-]+$")
FIELD_LINK_RE = re.compile(r"\]\(([^)]+)\)")
BANNER_RE = re.compile(r"^> \*\*")
NOTE_ROW_RE = re.compile(r"^- \[")

TRAILER = """
=======================================================================
docs lint FAILED. Two contracts are checked here:

  Dangling citation -- a live document names a path that is gone. Fix
    the path. If the document names it as deliberately deleted (a
    supersession banner does exactly that), declare it in that file:
    <!-- docs-lint: allow-missing the/path -->

  Design note front matter -- lines 3 and 4 are `- Status: ` and
    `- Date: `, Status is Accepted / Superseded / Draft, a superseded
    note links its successor and the successor links back, a banner
    means Superseded or Amended, and docs/design/index.md lists every
    note once with the same status the note itself carries.
=======================================================================
"""


class LintSetupError(Exception):
    """The tree cannot be linted at all -- a missing docs/design/ or an empty scope.

    Distinct from a violation: it exits 2, because a vacuous pass on a tree the lint
    could not read is the one outcome worse than a false failure.
    """


@dataclass(frozen=True)
class Citation:
    """One cited path, located precisely enough to report as `file:line`.

    `target` is the text as written, which is what an allow-missing marker names and
    what the failure message quotes. `resolved` is that text made relative to the
    repo root, which is what gets tested for existence.
    """

    file: str
    line: int
    target: str
    resolved: str
    label: str


@dataclass
class Note:
    """A design note's front matter, gathered once so D8 and D10 can cross-read it.

    `status` is empty when line 3 was malformed. Downstream checks treat that as "no
    status known" and stay quiet rather than reporting a second, derived complaint.
    """

    name: str
    status: str = ""
    supersedes: list[str] = field(default_factory=list)
    superseded_by: list[str] = field(default_factory=list)


def first_word(text: str) -> str:
    """The run of non-whitespace at the start of `text`, or "" if it starts blank.

    This is the field-value reader for the front matter. It stops at whitespace on
    purpose: `- Date: 2026-08-06 -- amended` yields the date, not the sentence.
    """
    match = re.match(r"\S+", text)
    return match.group(0) if match else ""


def tracked_files(root: Path) -> list[str]:
    """Every path git tracks in `root`, as repo-relative posix strings.

    Git is the source of both halves of the scope: which documents to read, and which
    top-level names count as repo-relative when a document cites one.
    """
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return [entry for entry in result.stdout.split("\0") if entry]


def scoped_documents(tracked: list[str]) -> list[str]:
    """The markdown files D1 and D2 read. See the Scope paragraph in the module docstring."""
    found = []
    for path in tracked:
        if not path.endswith(".md"):
            continue
        if path.startswith(SCOPE_SKIP_PREFIXES):
            continue
        if path in SCOPE_KEEP_FILES or path.startswith(SCOPE_KEEP_PREFIXES):
            found.append(path)
    return sorted(found)


def repo_roots(tracked: list[str]) -> frozenset[str]:
    """Top-level names a citation may start with, live ones from git plus DEAD_ROOTS."""
    return frozenset(path.split("/", 1)[0] for path in tracked) | DEAD_ROOTS


def path_of(token: str) -> str:
    """A backticked citation reduced to its path half.

    The form carries a trailing line span (`file.swift:8-13,67-101`) or an identifier
    (`file.swift#name`), and prose puts sentence punctuation right against the closing
    backtick. All three are stripped; what is left is a path or nothing.
    """
    token = re.sub(r"#.*$", "", token)
    token = re.sub(r":[0-9][0-9,-]*$", "", token)
    return re.sub(r"[.,;:)]+$", "", token)


def scan_document(path: str, text: str, roots: frozenset[str]) -> tuple[list[Citation], set[str]]:
    """Every citation in one document, plus the set of paths its markers exempt.

    Markers are collected in the same pass but applied by the caller, so a marker
    placed after the citation it forgives still works -- placement is a readability
    choice, not a semantic one.
    """
    citations: list[Citation] = []
    allowed: set[str] = set()
    directory = posixpath.dirname(path)
    fenced = False

    for number, line in enumerate(text.split("\n"), start=1):
        if FENCE_RE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue

        marker = MARKER_RE.search(line)
        if marker is not None:
            rest = line[marker.end() :]
            rest = re.sub(r"-->.*$", "", rest)
            allowed.update(rest.split())

        for target in LINK_RE.findall(line):
            if not target or SCHEME_RE.match(target) or target[0] in "#/":
                continue
            target = re.sub(r"#.*$", "", target)
            if not target:
                continue
            resolved = posixpath.normpath(posixpath.join(directory, target))
            citations.append(
                Citation(path, number, target, resolved, f"link `{target}`")
            )

        for token in BACKTICK_RE.findall(line):
            if " " in token or "\t" in token or "*" in token or "..." in token:
                continue
            if not PATH_TOKEN_RE.match(token):
                continue
            token = path_of(token)
            # A bare `Model.swift` does not say where it lives, so only a token with
            # a directory in it is treated as a citation, and only when that
            # directory is a top-level name of this repo.
            first, _, _ = token.partition("/")
            if not first or first == token or first not in roots:
                continue
            citations.append(Citation(path, number, token, token, f"`{token}`"))

    return citations, allowed


def check_citations(root: Path, documents: list[str], roots: frozenset[str]) -> list[str]:
    """D1 and D2 over every document in scope."""
    violations: list[str] = []
    for document in documents:
        text = (root / document).read_text(encoding="utf-8")
        citations, allowed = scan_document(document, text, roots)
        for citation in citations:
            if citation.resolved.startswith(UNRESOLVED_ROOTS):
                continue
            if citation.target in allowed:
                continue
            if (root / citation.resolved.removesuffix("/")).exists():
                continue
            violations.append(
                f"{citation.file}:{citation.line}: {citation.label} does not exist"
            )
    return violations


def read_link_fields(
    design: Path, note: Note, lines: list[str], violations: list[str]
) -> None:
    """Fill in a note's Supersedes / Superseded by sets, reporting unusable ones.

    Both fields may repeat: one note can retire more than one predecessor, and the
    pair of fields is what D8 reads to decide whether the two notes agree.
    """
    relative = f"docs/design/{note.name}"
    for field in LINK_FIELDS:
        prefix = f"- {field}: "
        for number, line in enumerate(lines, start=1):
            if not line.startswith(prefix):
                continue
            match = FIELD_LINK_RE.search(line)
            if match is None:
                violations.append(
                    f"{relative}:{number}: `{field}` must be a markdown link to another design note"
                )
                continue
            target = match.group(1).split("#", 1)[0]
            if "/" in target or not (design / target).is_file():
                violations.append(
                    f"{relative}:{number}: `{field}` links `{target}`, which is not a note in docs/design/"
                )
                continue
            if field == "Superseded by":
                note.superseded_by.append(target)
            else:
                note.supersedes.append(target)


def check_note(design: Path, name: str, violations: list[str]) -> Note:
    """D3 through D7 and D9 for one note, returning what D8 and D10 need from it."""
    note = Note(name)
    relative = f"docs/design/{name}"
    lines = (design / name).read_text(encoding="utf-8").split("\n")

    def line_at(number: int) -> str:
        return lines[number - 1] if len(lines) >= number else ""

    line3 = line_at(3)
    line4 = line_at(4)

    if not line3.startswith("- Status: "):
        violations.append(
            f'{relative}:3: front matter must open with `- Status: <word>` on line 3, not "{line3}"'
        )
        return note

    has_date = line4.startswith("- Date: ")
    if not has_date:
        violations.append(
            f'{relative}:4: `- Date: YYYY-MM-DD` must be the line after Status, not "{line4}"'
        )

    note.status = first_word(line3[len("- Status: ") :])
    if note.status not in STATUS_WORDS:
        violations.append(
            f"{relative}:3: Status `{note.status}` is not one of Accepted, Superseded, Draft"
        )

    # D9 is only meaningful once line 4 is a Date bullet; otherwise the shape
    # violation above is the whole story and a second message would bury it.
    if has_date:
        date_field = first_word(line4[len("- Date: ") :])
        file_date = name[:10]
        if date_field != file_date:
            violations.append(
                f"{relative}:4: Date `{date_field}` does not match the filename date `{file_date}`"
            )

    read_link_fields(design, note, lines, violations)

    if note.status == "Superseded" and not note.superseded_by:
        violations.append(
            f"{relative}:3: Status is Superseded but no `- Superseded by: ` field names the successor"
        )
    if note.status != "Superseded" and note.superseded_by:
        violations.append(
            f"{relative}:3: a `Superseded by` field is present but Status is `{note.status}`;"
            " a note with a successor is Superseded"
        )

    banner_line = next(
        (number for number, line in enumerate(lines[:20], start=1) if BANNER_RE.match(line)),
        None,
    )
    amended = any(line.startswith("- Amended: ") for line in lines)
    if banner_line is not None and note.status != "Superseded" and not amended:
        violations.append(
            f"{relative}:{banner_line}: a banner says something here is dead,"
            " so the note needs `Status: Superseded` or an `- Amended: ` field"
        )

    return note


def check_symmetry(notes: dict[str, Note], violations: list[str]) -> None:
    """D8. Reported against the note that is missing its half of the pair."""
    for name, note in notes.items():
        for successor in note.superseded_by:
            other = notes.get(successor)
            if other is not None and name in other.supersedes:
                continue
            violations.append(
                f"docs/design/{successor}: does not name `{name}`,"
                " which says it is superseded by this note; add `- Supersedes: `"
            )
        for predecessor in note.supersedes:
            other = notes.get(predecessor)
            if other is not None and name in other.superseded_by:
                continue
            violations.append(
                f"docs/design/{predecessor}: does not name `{name}`,"
                " which says it supersedes this note; add `- Superseded by: `"
            )


def note_rows(index_lines: list[str]) -> list[tuple[int, str]]:
    """The `## Notes` list, as (line number, text).

    Scoping to that one section keeps a bullet link somewhere else in the index --
    the Format section is full of them -- from being read as a row.
    """
    rows: list[tuple[int, str]] = []
    in_notes = False
    for number, line in enumerate(index_lines, start=1):
        if line.rstrip("\t ") == "## Notes":
            in_notes = True
            continue
        if line.startswith("## "):
            in_notes = False
        if in_notes and NOTE_ROW_RE.match(line):
            rows.append((number, line))
    return rows


def row_text(index_lines: list[str], number: int) -> str:
    """One row's full text, following its wrapped continuation lines to the next row."""
    collected = [index_lines[number - 1]]
    for line in index_lines[number:]:
        if NOTE_ROW_RE.match(line):
            break
        collected.append(line)
    return " ".join(collected)


def check_index(design: Path, notes: dict[str, Note], violations: list[str]) -> None:
    """D10. The index and the directory have to say the same thing, in date order."""
    index_lines = (design / "index.md").read_text(encoding="utf-8").split("\n")
    seen: dict[str, int] = {}
    previous_date = ""

    for number, line in note_rows(index_lines):
        match = FIELD_LINK_RE.search(line)
        if match is None:
            continue
        target = match.group(1)
        if not (design / target).is_file():
            violations.append(
                f"docs/design/index.md:{number}: row links `{target}`, which is not a note in docs/design/"
            )
            continue
        if target in seen:
            violations.append(
                f"docs/design/index.md:{number}: `{target}` already has a row at line {seen[target]}"
            )
            continue
        seen[target] = number

        if previous_date and target[:10] < previous_date:
            violations.append(
                f"docs/design/index.md:{number}: `{target}` breaks the newest-last order of the note list"
            )
        previous_date = target[:10]

        # A note whose front matter is already reported as malformed has no status to
        # compare against; that violation stands on its own.
        want = notes[target].status if target in notes else ""
        if not want:
            continue
        text = row_text(index_lines, number)
        found = ""
        for word in STATUS_WORDS:
            if f" -- {word}" in text:
                found = word
        if not found:
            violations.append(
                f"docs/design/index.md:{number}: row for `{target}` names no status;"
                f" it must read `-- {want}`"
            )
        elif found != want:
            violations.append(
                f"docs/design/index.md:{number}: row for `{target}` says `{found}` but the note says `{want}`"
            )

    for name in notes:
        if name not in seen:
            violations.append(
                f"docs/design/index.md: `{name}` has no row in the note list"
            )


def collect_violations(root: Path) -> list[str]:
    """Every violation in `root`, in report order: citations, then notes, then the index.

    Returned rather than printed so the self-test can assert on the exact strings
    without parsing stderr, and so one traversal answers every invariant.
    """
    design = root / "docs" / "design"
    if not design.is_dir():
        raise LintSetupError(f"missing {design}")
    if not (design / "index.md").is_file():
        raise LintSetupError(f"missing {design / 'index.md'}")

    tracked = tracked_files(root)
    documents = scoped_documents(tracked)
    if not documents:
        raise LintSetupError(f"no documents in scope under {root}")

    violations = check_citations(root, documents, repo_roots(tracked))

    notes: dict[str, Note] = {}
    for note_path in sorted(design.glob("*.md")):
        if note_path.name == "index.md":
            continue
        notes[note_path.name] = check_note(design, note_path.name, violations)

    check_symmetry(notes, violations)
    check_index(design, notes, violations)
    return violations


def check(root: Path) -> int:
    violations = collect_violations(root)
    for violation in violations:
        print(f"docs-lint: {violation}", file=sys.stderr)
    if violations:
        print(TRAILER, file=sys.stderr, end="")
        return 1
    print("docs lint passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check documentation citations and design-note front matter."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=Path(__file__).resolve().parents[1],
        type=Path,
        help="repository root to lint (default: this checkout)",
    )
    args = parser.parse_args()
    try:
        return check(args.root.resolve())
    except LintSetupError as error:
        print(f"docs-lint: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
