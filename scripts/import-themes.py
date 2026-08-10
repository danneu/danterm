#!/usr/bin/env python3
"""Import a pinned iTerm2-Color-Schemes archive into DanTerm's JSON schema.

DanTerm tracks the upstream collection's `ghostty-themes.tgz` variant purely
because its `key = value` syntax is the easiest of the published formats to
parse; nothing here depends on Ghostty. The archive's own file and directory
names are quoted verbatim below so the pinned download keeps resolving.

Explicit updates download and verify the pinned archive; runtime and build
paths consume the committed JSON this produces.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "themes"
RELEASE = "release-20260720-153658-97e244c"
ARCHIVE_URL = (
    "https://github.com/mbadolato/iTerm2-Color-Schemes/releases/download/"
    f"{RELEASE}/ghostty-themes.tgz"
)
ARCHIVE_SHA256 = "7329d0e2e958ee8404e516a6550bd07334edc611334a73f84d50477daa459f0c"
PROVENANCE = {
    "collection": "iTerm2-Color-Schemes",
    "release": RELEASE,
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


def download_archive(url: str = ARCHIVE_URL) -> bytes:
    """Downloads the explicitly pinned release asset for an update or CI check."""
    request = Request(url, headers={"User-Agent": "DanTerm-theme-importer"})
    with urlopen(request) as response:
        return response.read()


def archive_sources(content: bytes) -> dict[str, str]:
    """Reads only flat regular files from the archive's single upstream directory."""
    sources: dict[str, str] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(content), mode="r:gz") as archive:
            for member in archive.getmembers():
                parts = Path(member.name).parts
                if member.isdir() and parts == ("ghostty",):
                    continue
                if not member.isfile() or len(parts) != 2 or parts[0] != "ghostty":
                    raise ThemeImportError(
                        f"theme archive contains unexpected entry {member.name!r}"
                    )
                name = parts[1]
                if name in sources:
                    raise ThemeImportError(f"theme archive contains duplicate theme {name!r}")
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise ThemeImportError(f"theme archive cannot read {member.name!r}")
                sources[name] = extracted.read().decode("utf-8")
    except (tarfile.TarError, UnicodeError) as error:
        raise ThemeImportError(f"cannot read theme archive: {error}") from error
    if not sources:
        raise ThemeImportError("theme archive contains no themes")
    return sources


def replace_catalog(rendered: dict[str, bytes], output: Path) -> None:
    """Swaps a fully rendered collection into place while preserving notices."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".theme-import-", dir=output.parent
    ) as workspace_name:
        workspace = Path(workspace_name)
        staged = workspace / "themes"
        if output.is_dir():
            shutil.copytree(output, staged)
        else:
            staged.mkdir()
        for path in staged.glob("*.json"):
            path.unlink()
        for name, content in rendered.items():
            (staged / name).write_bytes(content)

        if not output.exists():
            staged.replace(output)
            return
        previous = workspace / "previous"
        output.replace(previous)
        try:
            staged.replace(output)
        except OSError:
            previous.replace(output)
            raise


def import_archive(content: bytes, expected_sha256: str, output: Path) -> int:
    """Verifies and validates the complete archive before replacing tracked JSON."""
    actual_sha256 = hashlib.sha256(content).hexdigest()
    if actual_sha256 != expected_sha256:
        raise ThemeImportError(
            f"theme archive SHA-256 is {actual_sha256}, expected {expected_sha256}"
        )
    sources = archive_sources(content)
    rendered = {
        f"{name}.json": encoded_theme(parse_theme(name, source))
        for name, source in sources.items()
    }
    replace_catalog(rendered, output)
    return len(rendered)


def main() -> int:
    """Runs the explicit source-to-tracked update command."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--archive",
        type=Path,
        help="use a local copy of the pinned asset instead of downloading it",
    )
    arguments = parser.parse_args()
    try:
        content = (
            arguments.archive.read_bytes()
            if arguments.archive is not None
            else download_archive()
        )
        count = import_archive(content, ARCHIVE_SHA256, arguments.output)
    except (OSError, UnicodeError, ThemeImportError) as error:
        parser.error(str(error))
    print(f"Imported {count} themes into {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
