# Owns first-party manifest discovery and reads target declarations from those
# manifests for the gate checks that reason about packages.
#
# It lives in its own module because both checks need the same answer to the same
# question -- which targets does this manifest declare, and where does it say their
# sources are -- and a second copy of a parser is how two checks come to disagree
# about the same file. Nothing here executes or imports a manifest: SwiftPM would
# have to build and run it, and a check that compiles the thing it polices cannot
# run as a cheap lint.

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

TARGET_KINDS = ("target", "executableTarget", "testTarget", "macro", "systemLibrary")


class LintError(Exception):
    """A malformed input a check refuses to interpret, as opposed to a lint verdict."""


def first_party_manifests(root: Path) -> list[Path]:
    """Returns every tracked Package.swift outside external and throwaway trees."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise LintError(f"cannot list tracked files under {root}: {detail}")
    manifests = [
        root / relative
        for raw in result.stdout.split(b"\0")
        if raw
        for relative in [Path(raw.decode(errors="surrogateescape"))]
        if relative.name == "Package.swift"
        and relative.parts[0] not in {"docs", "references"}
    ]
    if not manifests:
        raise LintError(
            "no first-party manifest found by tracked-file discovery, so this check "
            "would be checking nothing"
        )
    return manifests


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


def main() -> int:
    """Lists discovered manifests, or every target they declare, for shell consumers.

    `--list` prints one manifest path per line. `--targets` prints one
    `<kind><TAB><path>` line per declared target, the path root-relative, in
    manifest order -- so a shell check can visit the targets a manifest claims
    rather than the directories that happen to sit under `Sources/`.
    """
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true")
    mode.add_argument("--targets", action="store_true")
    parser.add_argument("--root", type=Path, required=True)
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    try:
        for manifest in first_party_manifests(root):
            if arguments.list:
                print(manifest.relative_to(root).as_posix())
                continue
            package = manifest.parent.relative_to(root)
            for target in declared_targets(manifest):
                print(f"{target.kind}\t{(package / target.declared_path()).as_posix()}")
    except LintError as error:
        print(f"manifest-targets: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
