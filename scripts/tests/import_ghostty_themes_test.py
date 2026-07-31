#!/usr/bin/env python3
"""Behavioral tests for the one-way Ghostty theme importer.

The importer is DanTerm's only Ghostty-syntax reader, so these tests pin its
complete-value rejection rules and deterministic tracked output.
"""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "import-ghostty-themes.py"
SPEC = importlib.util.spec_from_file_location("import_ghostty_themes", SCRIPT)
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
    def test_provenance_rejects_a_different_pinned_ghostty_version(self):
        with tempfile.TemporaryDirectory() as directory:
            version_file = Path(directory) / ".ghostty-version"
            version_file.write_text("v9.9.9\n", encoding="utf-8")

            with self.assertRaisesRegex(
                IMPORTER.ThemeImportError, "update the importer provenance"
            ):
                IMPORTER.validate_provenance(version_file)

    def test_import_is_deterministic_and_removes_stale_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            output = root / "output"
            source.mkdir()
            output.mkdir()
            (source / "Zulu").write_text(theme_source(), encoding="utf-8")
            (source / "Alpha").write_text(theme_source(), encoding="utf-8")
            (output / "Stale.json").write_text("{}\n", encoding="utf-8")
            (output / "NOTICE").write_text("keep\n", encoding="utf-8")

            IMPORTER.import_catalog(source, output)
            first = {
                path.name: path.read_bytes() for path in sorted(output.glob("*.json"))
            }
            IMPORTER.import_catalog(source, output)
            second = {
                path.name: path.read_bytes() for path in sorted(output.glob("*.json"))
            }

            self.assertEqual(list(first), ["Alpha.json", "Zulu.json"])
            self.assertEqual(second, first)
            self.assertEqual((output / "NOTICE").read_text(), "keep\n")
            document = json.loads(first["Alpha.json"])
            self.assertEqual(document["schemaVersion"], 1)
            self.assertEqual(document["name"], "Alpha")
            self.assertEqual(document["provenance"], IMPORTER.PROVENANCE)

    def test_invalid_source_leaves_existing_output_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            output = root / "output"
            source.mkdir()
            output.mkdir()
            existing = output / "Existing.json"
            existing.write_text('{"old": true}\n', encoding="utf-8")
            (source / "Broken").write_text(
                theme_source(omit="selection-foreground"), encoding="utf-8"
            )

            with self.assertRaises(IMPORTER.ThemeImportError):
                IMPORTER.import_catalog(source, output)

            self.assertEqual(existing.read_text(), '{"old": true}\n')

    def test_every_pinned_source_theme_imports_to_a_complete_value(self):
        source = ROOT / "lib" / "ghostty-themes"
        self.assertTrue(source.is_dir(), "run ./build-lib.sh once before the test gate")

        documents = [
            IMPORTER.parse_theme(path.name, path.read_text(encoding="utf-8"))
            for path in sorted(source.iterdir())
            if path.is_file()
        ]

        self.assertEqual(len(documents), 463)
        self.assertTrue(all(len(document["ansiPalette"]) == 16 for document in documents))


if __name__ == "__main__":
    unittest.main()
