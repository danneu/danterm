#!/usr/bin/env python3
"""Render TerminalCore's XTGETTCAP projection from the capability contract.

`docs/terminal-capabilities.md` is the authored contract and stays canonical.
Answering XTGETTCAP makes it a wire contract too, and the engine cannot read a
Markdown file at runtime: `TerminalCore` has no resource bundle and `swift build`
has no prebuild step. So the engine carries a committed *projection* of the
document, and this script is the only thing allowed to write it.

The point is that a second authored list would drift from the first and the drift
would be invisible -- a program would receive a claim DanTerm never made. Here the
document is the sole authored source, and `--check` fails the gate the moment the
committed projection stops agreeing with it. Generator and lint are one script on
purpose: two files could disagree about what the document says, which is the
failure this is meant to remove.

That is why this differs from `generated-unicode-tables-lint.py`, which can only
hash its outputs: those tables are generated from nine UCD files that are not in
the tree, so nothing offline can re-run their generator. This generator's input is
a tracked file, so `--check` re-derives the projection outright rather than
trusting a recorded digest.

What it does NOT do: decide the contract. Which rows exist, which names they
answer to, and what value each carries are all authored in the document. This
script only applies the two mechanical rules the document states -- a row is
answerable only when its two baselines agree, and a string value goes on the wire
in terminfo source form when it carries a `%` parameter.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# Test seam: the self-test points the generator at a fixture tree so each verdict is
# proved against a contract it authors, without touching the real document. Nothing
# else sets this.
REPO_ROOT = Path(
    os.environ.get("TERMINAL_CAPABILITY_PROJECTION_ROOT")
    or Path(__file__).resolve().parent.parent
).resolve()
CONTRACT = REPO_ROOT / "docs/terminal-capabilities.md"
PROJECTION = REPO_ROOT / "lib/TerminalCore/Sources/TerminalCore/TerminalCapabilityProjection.generated.swift"

TERMINFO_TABLE_HEADER = (
    "| id | kind | XTGETTCAP query | macOS 26 ncurses 6.0 | ncurses 1.1261 | evidence |"
)
PSEUDO_TABLE_HEADER = "| query | kind | value | disposition |"

# The document's `kind` column is a documentation vocabulary; XTGETTCAP knows only
# three value kinds. Everything that is not a flag or a count is a string.
BOOLEAN_KINDS = frozenset({"boolean"})
NUMBER_KINDS = frozenset({"number"})

NOT_ANSWERED = "--"

# The pseudo-capability table's disposition vocabulary. An unrecognized word is an error
# rather than a skip: a silent skip would take a capability off the wire without anyone
# noticing, because --check re-derives both sides and would go on agreeing.
ANSWERED = "answered"
DENIED = "denied"


class ContractError(Exception):
    """A contract the generator cannot project, reported with the offending row."""


def cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def unquote(cell: str) -> str:
    """Strips the document's backticks from a single-value cell."""
    if cell.startswith("`") and cell.endswith("`") and len(cell) >= 2:
        return cell[1:-1]
    return cell


def query_names(cell: str) -> list[str]:
    """The names a row answers to, or an empty list for a row the document records only."""
    if cell == NOT_ANSWERED:
        return []
    return [unquote(name) for name in cell.split()]


def table_rows(text: str, header: str) -> list[list[str]]:
    """Every body row of the one table that opens with `header`."""
    lines = text.splitlines()
    try:
        start = lines.index(header)
    except ValueError as error:
        raise ContractError(f"{CONTRACT.name} has no table headed {header!r}") from error
    rows = []
    for line in lines[start + 2 :]:
        if not line.startswith("|"):
            break
        rows.append(cells(line))
    if not rows:
        raise ContractError(f"the table headed {header!r} has no rows")
    return rows


def wire_value(kind: str, value: str) -> str:
    """The exact bytes a reply carries for one capability, as a Python string.

    Escape decoding is deliberately partial: a string carrying a `%` parameter goes
    out in terminfo source form, which is what xterm's original key-only interface
    grew into once kitty widened it to parameterized capabilities. Both peers
    implement exactly this split -- `references/kitty/kitty/terminfo.py`'s
    `get_capabilities` and `references/ghostty/src/terminfo/Source.zig`'s
    `xtgettcapMap` -- and external compatibility is the one place DanTerm matches a
    peer rather than picking the more consistent rule.
    """
    if kind in BOOLEAN_KINDS:
        if value != "true":
            raise ContractError(f"boolean capability has non-boolean value {value!r}")
        return ""
    if kind in NUMBER_KINDS:
        if not value.isdigit():
            raise ContractError(f"number capability has non-numeric value {value!r}")
        return value
    if "%" in value:
        return value.replace("\\x1b", "\\E")
    return value.replace("\\x1b", "\x1b")


def projected_capabilities() -> list[tuple[str, str]]:
    """Every (query name, wire value) pair the engine answers, in document order.

    A boolean capability's value is the empty string, which is how the reply path
    knows to send the name with no `=`.
    """
    text = CONTRACT.read_text()
    projected: list[tuple[str, str]] = []
    seen: dict[str, str] = {}

    def record(name: str, value: str, where: str) -> None:
        if name in seen:
            raise ContractError(f"{where}: query name {name!r} is claimed twice")
        seen[name] = value
        projected.append((name, value))

    for row in table_rows(text, TERMINFO_TABLE_HEADER):
        identifier, kind, query, macos, ncurses, _evidence = row
        names = query_names(query)
        if not names:
            continue
        # The document says a row is answerable only when its two baselines agree,
        # so the check lives here rather than in a reviewer's head: a future row
        # whose baselines diverge stops being answered the moment it is written.
        if ncurses not in ("same", macos):
            raise ContractError(
                f"{identifier}: baselines disagree ({macos} vs {ncurses}),"
                " so the row cannot carry one runtime value"
            )
        value = wire_value(kind, unquote(macos))
        for name in names:
            record(name, value, identifier)

    for row in table_rows(text, PSEUDO_TABLE_HEADER):
        query, kind, value, disposition = row
        verdict = disposition.split(maxsplit=1)[0] if disposition else ""
        if verdict not in (ANSWERED, DENIED):
            raise ContractError(
                f"{query}: disposition {disposition!r} is neither {ANSWERED!r} nor {DENIED!r}"
            )
        if verdict == DENIED:
            continue
        for name in query_names(query):
            record(name, wire_value(kind, unquote(value)), name)

    return projected


def swift_literal(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + re.sub(r"[\x00-\x1f\x7f]", lambda m: f"\\u{{{ord(m.group()):02X}}}", escaped) + '"'


def render(projected: list[tuple[str, str]]) -> str:
    entries = "\n".join(
        f"        {swift_literal(name)}: {swift_literal(value)},"
        for name, value in projected
    )
    return f"""// Generated by scripts/generate-terminal-capability-projection.py; do not edit.
// Projected from docs/terminal-capabilities.md, which is the authored contract.
//
// This file exists so XTGETTCAP answers from the published contract rather than
// from a second list inside the engine. Editing it by hand makes the engine
// promise something the contract never did, which is why the generator's --check
// mode is a gate step.

/// The capability values XTGETTCAP answers with, keyed by the names each answers to.
///
/// A value is the exact byte string a reply carries. An empty value means a boolean
/// capability, whose reply is the requested name with no `=` and no value.
enum TerminalCapabilityProjection {{
    static let values: [String: String] = [
{entries}
    ]
}}
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when the committed projection is not what the contract renders",
    )
    arguments = parser.parse_args()

    try:
        rendered = render(projected_capabilities())
    except ContractError as error:
        print(f"{CONTRACT.relative_to(REPO_ROOT)}: {error}", file=sys.stderr)
        return 1

    relative = PROJECTION.relative_to(REPO_ROOT)
    if arguments.check:
        committed = PROJECTION.read_text() if PROJECTION.exists() else None
        if committed != rendered:
            print(
                f"{relative} does not match {CONTRACT.relative_to(REPO_ROOT)}."
                f" Run: python3 scripts/{Path(__file__).name}",
                file=sys.stderr,
            )
            return 1
        return 0

    PROJECTION.write_text(rendered)
    print(f"wrote {relative}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
