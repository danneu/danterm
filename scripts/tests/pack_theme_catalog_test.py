#!/usr/bin/env python3
"""Behavioral tests for validating and packing DanTerm's runtime theme catalog."""

import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "pack-theme-catalog.py"
SPEC = importlib.util.spec_from_file_location("pack_theme_catalog", SCRIPT)
PACKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PACKER
SPEC.loader.exec_module(PACKER)


def fixture_theme(name="Fixture"):
    return {
        "ansiPalette": [f"#{index:02x}{index:02x}{index:02x}" for index in range(16)],
        "background": "#101112",
        "cursor": "#202122",
        "cursorText": "#303132",
        "foreground": "#404142",
        "name": name,
        "provenance": {
            "collection": "Fixture collection",
            "release": "fixture-release",
        },
        "schemaVersion": 1,
        "selectionBackground": "#505152",
        "selectionForeground": "#606162",
    }


class PackThemeCatalogTests(unittest.TestCase):
    def write_theme(self, directory, document, filename=None):
        path = directory / (filename or f"{document['name']}.json")
        path.write_text(json.dumps(document) + "\n", encoding="utf-8")
        return path

    def test_pack_is_deterministic_sorted_and_does_not_modify_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "themes"
            source.mkdir()
            self.write_theme(source, fixture_theme("zulu"))
            self.write_theme(source, fixture_theme("Alpha"))
            before = {path.name: path.read_bytes() for path in source.iterdir()}
            output = root / "bundle" / "theme-catalog.json"

            count = PACKER.pack_catalog(source, output)
            first = output.read_bytes()
            PACKER.pack_catalog(source, output)

            self.assertEqual(count, 2)
            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(
                {path.name: path.read_bytes() for path in source.iterdir()}, before
            )
            catalog = json.loads(first)
            self.assertEqual(catalog["schemaVersion"], 1)
            self.assertEqual(
                [theme["name"] for theme in catalog["themes"]], ["Alpha", "zulu"]
            )

    def test_every_required_field_and_provenance_field_is_validated(self):
        required = [
            "ansiPalette",
            "background",
            "cursor",
            "cursorText",
            "foreground",
            "name",
            "provenance",
            "schemaVersion",
            "selectionBackground",
            "selectionForeground",
        ]
        provenance_required = ["collection", "release"]

        for field in required:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                document = fixture_theme()
                del document[field]
                self.write_theme(root, document, filename="Fixture.json")
                with self.assertRaises(PACKER.ThemeCatalogError):
                    PACKER.pack_catalog(root, root / "catalog.json")

        for field in provenance_required:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                document = fixture_theme()
                del document["provenance"][field]
                self.write_theme(root, document)
                with self.assertRaises(PACKER.ThemeCatalogError):
                    PACKER.pack_catalog(root, root / "catalog.json")

    def test_invalid_schema_color_palette_and_filename_are_rejected_atomically(self):
        mutations = {
            "schema": lambda theme: theme.update(schemaVersion=2),
            "schema-type": lambda theme: theme.update(schemaVersion=True),
            "color": lambda theme: theme.update(foreground="#xyzxyz"),
            "palette": lambda theme: theme.update(ansiPalette=theme["ansiPalette"][:-1]),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                document = fixture_theme()
                mutate(document)
                self.write_theme(root, document)
                output = root / "output" / "theme-catalog.json"
                output.parent.mkdir()
                output.write_text("existing\n", encoding="utf-8")

                with self.assertRaises(PACKER.ThemeCatalogError):
                    PACKER.pack_catalog(root, output)

                self.assertEqual(output.read_text(encoding="utf-8"), "existing\n")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_theme(root, fixture_theme(), filename="Different.json")
            with self.assertRaises(PACKER.ThemeCatalogError):
                PACKER.pack_catalog(root, root / "catalog.json")

    def test_every_tracked_theme_packs_into_one_complete_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "theme-catalog.json"
            count = PACKER.pack_catalog(ROOT / "themes", output)
            catalog = json.loads(output.read_bytes())

            self.assertEqual(count, 592)
            self.assertEqual(len(catalog["themes"]), 592)
            self.assertTrue(
                all(len(theme["ansiPalette"]) == 16 for theme in catalog["themes"])
            )
            names = {theme["name"] for theme in catalog["themes"]}
            self.assertIn("Monokai Remastered", names)
            self.assertIn("Purplepeter", names)


class AssemblerContractTests(unittest.TestCase):
    def write_symbols_fixture(self, repository):
        symbols = (
            repository
            / "lib"
            / "TerminalCore"
            / "Sources"
            / "TerminalRenderExecution"
            / "Resources"
            / "NerdFontsSymbolsOnly"
        )
        symbols.mkdir(parents=True)
        (symbols / "SymbolsNerdFontMono-Regular.ttf").write_bytes(b"font fixture")
        (symbols / "LICENSE").write_text("license fixture\n", encoding="utf-8")

    def test_every_app_assembler_routes_through_the_shared_bundle_step(self):
        producers = [
            ROOT / "build-app.sh",
            ROOT / "dev-build.sh",
            ROOT / "scripts" / "terminal-benchmark.sh",
            ROOT / "scripts" / "terminal-viability.sh",
        ]

        for producer in producers:
            with self.subTest(producer=producer.name):
                source = producer.read_text(encoding="utf-8")
                self.assertEqual(source.count("assemble-app-bundle.sh"), 1)
                self.assertEqual(source.count("verify-bundle-layout.sh"), 1)
                self.assertNotIn("bundle-theme-resources.sh", source)
                self.assertNotIn("import-themes.py", source)
                self.assertNotIn("cp -R \"$REPO_ROOT/lib/ghostty-themes\"", source)
                self.assertNotIn("cp -R \"$THEMES_SRC\"", source)

    def test_ci_reimports_and_rejects_tracked_theme_drift(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("python3 ./scripts/import-themes.py", workflow)
        self.assertIn(
            "git status --porcelain --untracked-files=all -- themes", workflow
        )
        freshness_job = workflow.split("  theme-freshness:", 1)[1].split("\n  build:", 1)[0]
        self.assertNotIn(".ghostty-version", freshness_job)
        self.assertNotIn("lib/ghostty-themes", freshness_job)
        self.assertNotIn("build-lib.sh", freshness_job)

    def test_collection_notice_names_the_direct_pinned_release(self):
        notice = (ROOT / "themes" / "NOTICE.iTerm2-Color-Schemes").read_text(
            encoding="utf-8"
        )

        self.assertIn("release-20260720-153658-97e244c", notice)
        self.assertIn("mbadolato/iTerm2-Color-Schemes", notice)
        self.assertNotIn("bundled by Ghostty", notice)

    def test_shared_bundle_step_packs_runtime_catalog_and_symbol_font(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repo"
            shutil.copytree(ROOT / "themes", repository / "themes")
            self.write_symbols_fixture(repository)
            (repository / "scripts").mkdir()
            shutil.copy2(SCRIPT, repository / "scripts" / SCRIPT.name)
            helper = ROOT / "scripts" / "bundle-theme-resources.sh"
            shutil.copy2(helper, repository / "scripts" / helper.name)
            app = root / "Fixture.app"
            source_before = {
                path.relative_to(repository): path.read_bytes()
                for path in (repository / "themes").glob("*.json")
            }

            import subprocess

            subprocess.run([repository / "scripts" / helper.name, repository, app], check=True)

            catalog = json.loads(
                (app / "Contents" / "Resources" / "themes" / "catalog.json").read_bytes()
            )
            self.assertEqual(len(catalog["themes"]), 592)
            self.assertEqual(
                (
                    app
                    / "Contents"
                    / "Resources"
                    / "NerdFontsSymbolsOnly"
                    / "SymbolsNerdFontMono-Regular.ttf"
                ).read_bytes(),
                b"font fixture",
            )
            self.assertEqual(
                (
                    app
                    / "Contents"
                    / "Resources"
                    / "NerdFontsSymbolsOnly"
                    / "LICENSE"
                ).read_text(),
                "license fixture\n",
            )
            self.assertEqual(
                {
                    path.relative_to(repository): path.read_bytes()
                    for path in (repository / "themes").glob("*.json")
                },
                source_before,
            )

if __name__ == "__main__":
    unittest.main()
