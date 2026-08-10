#!/usr/bin/env python3
"""Behavioral tests for the pinned iTerm2-Color-Schemes theme importer.

The importer is the only thing standing between an upstream archive and the
tracked theme catalog, so these tests pin the archive verification boundary,
complete-value rejection, and atomic output.
"""

import hashlib
import io
import importlib.util
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "import-themes.py"
SPEC = importlib.util.spec_from_file_location("import_themes", SCRIPT)
IMPORTER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = IMPORTER
SPEC.loader.exec_module(IMPORTER)


NAMED_COLORS = {
    "background": "#101112",
    "foreground": "#202122",
    "cursor-color": "#303132",
    "cursor-text": "#404142",
    "selection-background": "#505152",
    "selection-foreground": "#606162",
}


def theme_source(*, palette_order=range(16), omit=None, replacement=None):
    lines = [
        f"palette = {index}=#{index:02x}{index:02x}{index:02x}"
        for index in palette_order
        if omit != f"palette-{index}"
    ]
    lines.extend(
        f"{key} = {replacement[1] if replacement and replacement[0] == key else value}"
        for key, value in NAMED_COLORS.items()
        if key != omit
    )
    return "\n".join(lines) + "\n"


def fixture_archive(themes):
    """Builds an offline Ghostty-format release fixture from committed values."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        directory = tarfile.TarInfo("ghostty/")
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        for name, content in themes.items():
            encoded = content.encode("utf-8")
            member = tarfile.TarInfo(f"ghostty/{name}")
            member.size = len(encoded)
            archive.addfile(member, io.BytesIO(encoded))
    return buffer.getvalue()


class ParseThemeTests(unittest.TestCase):
    def test_palette_indices_not_source_order_define_output_order(self):
        ascending = IMPORTER.parse_theme("Fixture", theme_source())
        shuffled = IMPORTER.parse_theme(
            "Fixture", theme_source(palette_order=[7, 0, 15, 4, 2, 10, 1, 9, 3, 8, 5, 14, 6, 13, 11, 12])
        )

        self.assertEqual(shuffled, ascending)
        self.assertEqual(
            shuffled["ansiPalette"],
            [f"#{index:02x}{index:02x}{index:02x}" for index in range(16)],
        )
        self.assertEqual(shuffled["background"], NAMED_COLORS["background"])
        self.assertEqual(shuffled["foreground"], NAMED_COLORS["foreground"])
        self.assertEqual(shuffled["cursor"], NAMED_COLORS["cursor-color"])
        self.assertEqual(shuffled["cursorText"], NAMED_COLORS["cursor-text"])
        self.assertEqual(
            shuffled["selectionBackground"], NAMED_COLORS["selection-background"]
        )
        self.assertEqual(
            shuffled["selectionForeground"], NAMED_COLORS["selection-foreground"]
        )

    def test_every_named_color_is_required(self):
        for key in NAMED_COLORS:
            with self.subTest(key=key):
                with self.assertRaisesRegex(IMPORTER.ThemeImportError, key):
                    IMPORTER.parse_theme("Fixture", theme_source(omit=key))

    def test_every_palette_index_is_required(self):
        for index in range(16):
            with self.subTest(index=index):
                with self.assertRaisesRegex(
                    IMPORTER.ThemeImportError, f"palette index {index}"
                ):
                    IMPORTER.parse_theme(
                        "Fixture", theme_source(omit=f"palette-{index}")
                    )

    def test_invalid_named_and_palette_colors_are_rejected(self):
        with self.assertRaisesRegex(IMPORTER.ThemeImportError, "foreground"):
            IMPORTER.parse_theme(
                "Fixture",
                theme_source(replacement=("foreground", "#xyzxyz")),
            )

        invalid_palette = theme_source().replace(
            "palette = 6=#060606", "palette = 6=#xyzxyz"
        )
        with self.assertRaisesRegex(IMPORTER.ThemeImportError, "palette index 6"):
            IMPORTER.parse_theme("Fixture", invalid_palette)

    def test_duplicate_palette_index_is_rejected(self):
        duplicate = theme_source() + "palette = 4=#abcdef\n"
        with self.assertRaisesRegex(IMPORTER.ThemeImportError, "duplicate palette index 4"):
            IMPORTER.parse_theme("Fixture", duplicate)


class ImportCatalogTests(unittest.TestCase):
    def snapshot(self, output):
        return {
            path.name: path.read_bytes()
            for path in sorted(output.iterdir())
            if path.is_file()
        }

    def test_pinned_release_names_direct_upstream_without_ghostty(self):
        self.assertEqual(
            IMPORTER.PROVENANCE,
            {
                "collection": "iTerm2-Color-Schemes",
                "release": "release-20260720-153658-97e244c",
            },
        )
        self.assertEqual(
            IMPORTER.ARCHIVE_SHA256,
            "7329d0e2e958ee8404e516a6550bd07334edc611334a73f84d50477daa459f0c",
        )
        self.assertIn(IMPORTER.PROVENANCE["release"], IMPORTER.ARCHIVE_URL)
        self.assertTrue(IMPORTER.ARCHIVE_URL.endswith("/ghostty-themes.tgz"))

    def test_import_is_deterministic_and_removes_stale_json(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.mkdir()
            (output / "Stale.json").write_text("{}\n", encoding="utf-8")
            (output / "NOTICE").write_text("keep\n", encoding="utf-8")
            archive = fixture_archive(
                {"Zulu": theme_source(), "Alpha": theme_source()}
            )
            digest = hashlib.sha256(archive).hexdigest()

            IMPORTER.import_archive(archive, digest, output)
            first = self.snapshot(output)
            IMPORTER.import_archive(archive, digest, output)
            second = self.snapshot(output)

            self.assertEqual(list(first), ["Alpha.json", "NOTICE", "Zulu.json"])
            self.assertEqual(second, first)
            document = json.loads(first["Alpha.json"])
            self.assertEqual(document["schemaVersion"], 1)
            self.assertEqual(document["name"], "Alpha")
            self.assertEqual(document["provenance"], IMPORTER.PROVENANCE)

    def test_digest_mismatch_leaves_existing_output_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            (output / "Existing.json").write_text('{"old": true}\n', encoding="utf-8")
            before = self.snapshot(output)

            with self.assertRaisesRegex(IMPORTER.ThemeImportError, "SHA-256"):
                IMPORTER.import_archive(
                    fixture_archive({"Fixture": theme_source()}), "0" * 64, output
                )

            self.assertEqual(self.snapshot(output), before)

    def test_corrupt_archive_leaves_existing_output_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            (output / "Existing.json").write_text('{"old": true}\n', encoding="utf-8")
            before = self.snapshot(output)
            archive = b"not a tar archive"

            with self.assertRaisesRegex(IMPORTER.ThemeImportError, "archive"):
                IMPORTER.import_archive(
                    archive, hashlib.sha256(archive).hexdigest(), output
                )

            self.assertEqual(self.snapshot(output), before)

    def test_incomplete_archive_theme_leaves_existing_output_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            (output / "Existing.json").write_text('{"old": true}\n', encoding="utf-8")
            before = self.snapshot(output)
            archive = fixture_archive(
                {"Broken": theme_source(omit="selection-foreground")}
            )

            with self.assertRaisesRegex(IMPORTER.ThemeImportError, "selection-foreground"):
                IMPORTER.import_archive(
                    archive, hashlib.sha256(archive).hexdigest(), output
                )

            self.assertEqual(self.snapshot(output), before)


if __name__ == "__main__":
    unittest.main()
