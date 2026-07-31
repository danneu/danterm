#!/usr/bin/env python3
"""Import Ghostty's bundled theme syntax into DanTerm's tracked JSON schema.

This is the only DanTerm-authored Ghostty theme parser. Runtime and build paths
consume the committed JSON collection and must never call this importer.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import tempfile


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "lib" / "ghostty-themes"
DEFAULT_OUTPUT = ROOT / "themes"
DEFAULT_GHOSTTY_VERSION_FILE = ROOT / ".ghostty-version"
PROVENANCE = {
    "collection": "iTerm2-Color-Schemes via Ghostty",
    "release": "ghostty-themes-release-20260216-151611-fc73ce3",
    "ghosttyVersion": "v1.3.1",
}
NAMED_COLOR_FIELDS = {
    "background": "background",
    "foreground": "foreground",
    "cursor-color": "cursor",
    "cursor-text": "cursorText",
    "selection-background": "selectionBackground",
    "selection-foreground": "selectionForeground",
}
COLOR_PATTERN = re.compile(r"#[0-9A-Fa-f]{6}")
ASSIGNMENT_PATTERN = re.compile(r"^\s*([a-z-]+)\s*=\s*(.*?)\s*$")
PALETTE_PATTERN = re.compile(r"^\s*palette\s*=\s*(\d+)\s*=\s*(\S+)\s*$")


class ThemeImportError(ValueError):
    """Rejects a source theme before incomplete data can enter the tracked catalog."""


def require_color(theme_name: str, field: str, value: str) -> str:
    """Accepts only complete RGB literals so runtime decoding needs no fallback."""
    if COLOR_PATTERN.fullmatch(value) is None:
        raise ThemeImportError(f"{theme_name}: invalid {field} color {value!r}")
    return value.lower()


def parse_theme(theme_name: str, content: str) -> dict[str, object]:
    """Converts one complete source theme without depending on source line order."""
    named: dict[str, str] = {}
    palette: dict[int, str] = {}

    for line in content.splitlines():
        palette_match = PALETTE_PATTERN.fullmatch(line)
        if palette_match is not None:
            index = int(palette_match.group(1))
            if not 0 <= index < 16:
                raise ThemeImportError(f"{theme_name}: palette index {index} is outside 0...15")
            if index in palette:
                raise ThemeImportError(f"{theme_name}: duplicate palette index {index}")
            palette[index] = require_color(
                theme_name, f"palette index {index}", palette_match.group(2)
            )
            continue

        assignment_match = ASSIGNMENT_PATTERN.fullmatch(line)
        if assignment_match is None:
            continue
        source_key, value = assignment_match.groups()
        if source_key not in NAMED_COLOR_FIELDS:
            continue
        if source_key in named:
            raise ThemeImportError(f"{theme_name}: duplicate {source_key}")
        named[source_key] = require_color(theme_name, source_key, value)

    for source_key in NAMED_COLOR_FIELDS:
        if source_key not in named:
            raise ThemeImportError(f"{theme_name}: missing {source_key}")
    for index in range(16):
        if index not in palette:
            raise ThemeImportError(f"{theme_name}: missing palette index {index}")

    document: dict[str, object] = {
        "schemaVersion": 1,
        "name": theme_name,
        "provenance": PROVENANCE,
        "ansiPalette": [palette[index] for index in range(16)],
    }
    document.update(
        {
            output_key: named[source_key]
            for source_key, output_key in NAMED_COLOR_FIELDS.items()
        }
    )
    return document


def encoded_theme(document: dict[str, object]) -> bytes:
    """Produces stable reviewable bytes for freshness checks and color-level diffs."""
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def validate_provenance(version_file: Path) -> None:
    """Stops a Ghostty upgrade from stamping the previous catalog's provenance."""
    pinned_version = version_file.read_text(encoding="utf-8").strip()
    if pinned_version != PROVENANCE["ghosttyVersion"]:
        raise ThemeImportError(
            f"Ghostty is pinned to {pinned_version!r}, but importer provenance names "
            f"{PROVENANCE['ghosttyVersion']!r}; update the importer provenance first"
        )


def import_catalog(source: Path, output: Path) -> int:
    """Validates every source before replacing the tracked JSON collection."""
    if not source.is_dir():
        raise ThemeImportError(f"theme source directory does not exist: {source}")
    source_files = sorted(path for path in source.iterdir() if path.is_file())
    if not source_files:
        raise ThemeImportError(f"theme source directory is empty: {source}")

    rendered = {
        f"{path.name}.json": encoded_theme(
            parse_theme(path.name, path.read_text(encoding="utf-8"))
        )
        for path in source_files
    }

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".theme-import-", dir=output.parent) as staged:
        staged_path = Path(staged)
        for name, content in rendered.items():
            (staged_path / name).write_bytes(content)
        for path in output.glob("*.json"):
            if path.name not in rendered:
                path.unlink()
        for name in sorted(rendered):
            (staged_path / name).replace(output / name)
    return len(rendered)


def main() -> int:
    """Runs the explicit source-to-tracked update command."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--ghostty-version-file", type=Path, default=DEFAULT_GHOSTTY_VERSION_FILE
    )
    arguments = parser.parse_args()
    try:
        validate_provenance(arguments.ghostty_version_file)
        count = import_catalog(arguments.source, arguments.output)
    except (OSError, UnicodeError, ThemeImportError) as error:
        parser.error(str(error))
    print(f"Imported {count} themes into {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
