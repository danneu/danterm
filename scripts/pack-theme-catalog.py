#!/usr/bin/env python3
"""Validate DanTerm's tracked themes and pack them into one runtime catalog."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import tempfile


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "themes"
COLOR_FIELDS = (
    "background",
    "cursor",
    "cursorText",
    "foreground",
    "selectionBackground",
    "selectionForeground",
)
THEME_FIELDS = frozenset(
    (*COLOR_FIELDS, "ansiPalette", "name", "provenance", "schemaVersion")
)
PROVENANCE_FIELDS = frozenset(("collection", "release"))
COLOR_PATTERN = re.compile(r"#[0-9a-f]{6}")


class ThemeCatalogError(ValueError):
    """Rejects incomplete tracked data before it can enter an app bundle."""


def require_object(value: object, label: str) -> dict[str, object]:
    """Narrows decoded JSON objects while preserving useful validation errors."""
    if not isinstance(value, dict):
        raise ThemeCatalogError(f"{label} must be a JSON object")
    return value


def validate_keys(
    document: dict[str, object], expected: frozenset[str], label: str
) -> None:
    """Keeps the private packed schema complete and unambiguous."""
    actual = set(document)
    if actual == expected:
        return
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    details = []
    if missing:
        details.append(f"missing {', '.join(missing)}")
    if unexpected:
        details.append(f"unexpected {', '.join(unexpected)}")
    raise ThemeCatalogError(f"{label}: {'; '.join(details)}")


def require_color(value: object, label: str) -> str:
    """Accepts only the canonical lowercase RGB representation."""
    if not isinstance(value, str) or COLOR_PATTERN.fullmatch(value) is None:
        raise ThemeCatalogError(f"{label} must be a lowercase #rrggbb color")
    return value


def validate_theme(path: Path) -> dict[str, object]:
    """Validates one complete tracked theme without supplying runtime fallbacks."""
    try:
        decoded = json.loads(path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ThemeCatalogError(f"{path.name}: cannot decode JSON: {error}") from error

    document = require_object(decoded, path.name)
    validate_keys(document, THEME_FIELDS, path.name)
    if type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
        raise ThemeCatalogError(f"{path.name}: unsupported schemaVersion")
    name = document["name"]
    if not isinstance(name, str) or not name:
        raise ThemeCatalogError(f"{path.name}: name must be a non-empty string")
    if path.name != f"{name}.json":
        raise ThemeCatalogError(f"{path.name}: filename does not match theme name {name!r}")

    for field in COLOR_FIELDS:
        require_color(document[field], f"{path.name}: {field}")
    palette = document["ansiPalette"]
    if not isinstance(palette, list) or len(palette) != 16:
        raise ThemeCatalogError(f"{path.name}: ansiPalette must contain 16 colors")
    for index, color in enumerate(palette):
        require_color(color, f"{path.name}: ansiPalette[{index}]")

    provenance = require_object(document["provenance"], f"{path.name}: provenance")
    validate_keys(provenance, PROVENANCE_FIELDS, f"{path.name}: provenance")
    for field in sorted(PROVENANCE_FIELDS):
        if not isinstance(provenance[field], str) or not provenance[field]:
            raise ThemeCatalogError(
                f"{path.name}: provenance.{field} must be a non-empty string"
            )
    return document


def encoded_catalog(themes: list[dict[str, object]]) -> bytes:
    """Produces stable bytes for a single-read runtime resource."""
    catalog = {"schemaVersion": 1, "themes": themes}
    return (json.dumps(catalog, indent=2, sort_keys=True) + "\n").encode("utf-8")


def pack_catalog(source: Path, output: Path) -> int:
    """Validates the full collection before atomically replacing packed output."""
    if not source.is_dir():
        raise ThemeCatalogError(f"theme source directory does not exist: {source}")
    paths = sorted(source.glob("*.json"), key=lambda path: (path.stem.casefold(), path.stem))
    if not paths:
        raise ThemeCatalogError(f"theme source directory contains no JSON themes: {source}")

    themes = [validate_theme(path) for path in paths]
    names = [theme["name"] for theme in themes]
    if len(set(names)) != len(names):
        raise ThemeCatalogError("theme names must be unique")
    content = encoded_catalog(themes)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f".{output.name}.", dir=output.parent, delete=False
    ) as temporary:
        temporary.write(content)
        temporary_path = Path(temporary.name)
    temporary_path.replace(output)
    return len(themes)


def main() -> int:
    """Runs the build-time validate-and-pack step."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        count = pack_catalog(arguments.source, arguments.output)
    except (OSError, ThemeCatalogError) as error:
        parser.error(str(error))
    print(f"Packed {count} themes into {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
