# Reads the target declarations out of a `Package.swift` as text, for the two gate
# checks that reason about manifests: scripts/manifest-ownership-lint.py and
# scripts/gate-test-coverage-lint.py.
#
# It lives in its own module because both checks need the same answer to the same
# question -- which targets does this manifest declare, and where does it say their
# sources are -- and a second copy of a parser is how two checks come to disagree
# about the same file. Nothing here executes or imports a manifest: SwiftPM would
# have to build and run it, and a check that compiles the thing it polices cannot
# run as a cheap lint.

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

TARGET_KINDS = ("target", "executableTarget", "testTarget", "macro", "systemLibrary")


class LintError(Exception):
    """A malformed input a check refuses to interpret, as opposed to a lint verdict."""


@dataclass(frozen=True)
class TargetDeclaration:
    """One target a manifest declares: its kind, its name, and the path it claims.

    `path` is the literal the manifest wrote, or None when the manifest left it out
    and SwiftPM's default applies. It is never resolved against the filesystem --
    ownership and coverage are both claims about what a manifest says.
    """

    kind: str
    name: str
    path: str | None

    def declared_path(self) -> str:
        """The path this target claims, filling in SwiftPM's default when none was written."""
        if self.path is not None:
            return self.path
        return f"Tests/{self.name}" if self.kind == "testTarget" else f"Sources/{self.name}"


def strip_comments(text: str) -> str:
    """Removes `//` line comments without touching a `//` inside a string literal."""
    out: list[str] = []
    for line in text.splitlines():
        in_string = False
        escaped = False
        cut = len(line)
        for index, char in enumerate(line):
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == '"':
                in_string = not in_string
                continue
            if not in_string and char == "/" and line[index : index + 2] == "//":
                cut = index
                break
        out.append(line[:cut])
    return "\n".join(out)


def balanced_span(text: str, open_index: int) -> int:
    """Returns the index just past the `(` at open_index's matching `)`, ignoring parens in strings."""
    depth = 0
    in_string = False
    escaped = False
    for index in range(open_index, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    raise LintError("unbalanced parentheses in manifest")


def declared_targets(manifest: Path) -> list[TargetDeclaration]:
    """Every target a manifest declares, read from its text.

    A `path:` or `name:` that is not a string literal raises rather than being
    guessed at, so a computed path fails loudly instead of slipping past a check.
    """
    text = strip_comments(manifest.read_text())
    declarations: list[TargetDeclaration] = []
    for match in re.finditer(rf"\.({'|'.join(TARGET_KINDS)})\s*\(", text):
        body = text[match.start() : balanced_span(text, match.end() - 1)]
        path_match = re.search(r"\bpath\s*:\s*(.)", body)
        if path_match and path_match.group(1) != '"':
            raise LintError(
                f"{manifest}: a target declares a `path:` that is not a string literal. "
                "This check reads manifest text and will not guess at a computed path."
            )
        name_match = re.search(r'\bname\s*:\s*"([^"]+)"', body)
        if not name_match:
            raise LintError(f"{manifest}: a target declares no literal name.")
        path = None
        if path_match:
            literal = re.search(r'\bpath\s*:\s*"([^"]*)"', body)
            if not literal:
                raise LintError(f"{manifest}: a target declares an unreadable `path:`.")
            path = literal.group(1)
        declarations.append(
            TargetDeclaration(kind=match.group(1), name=name_match.group(1), path=path)
        )
    return declarations
