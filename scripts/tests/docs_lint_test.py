#!/usr/bin/env python3
"""Self-test for the documentation citation and design-note status lint.

Every case builds a fixture tree and asserts the verdict, so the lint is pinned in
both directions -- a lint that rejected everything would satisfy the negative cases
alone and then reject the first correct citation someone writes. The positive cases
carry as much weight as the negative ones here: they are what keep the lint from
firing on an external tree's paths, a `file:lines` citation, a fenced example, or a
link into plans/.

The fixture is a real git repository. The lint derives which top-level names count
as repo-relative from `git ls-files`, so a fixture that is not a repo would exercise
a different code path than the tree does.

CASES is a list rather than a method per case so the same table drives the unittest
and any differential run against another implementation of the same contract.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import unittest
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Callable


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "docs-lint.py"


def load_script():
    """Import the lint by path. It is registered in sys.modules first, because
    @dataclass resolves its own module during class creation and fails without it."""
    spec = importlib.util.spec_from_file_location("docs_lint", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


AGENTS_MD = """# Agents

The accept loop is in `app/Real.swift`. See
[docs/design/index.md](docs/design/index.md).
"""

OLD_NOTE = """# Old Decision

- Status: Superseded
- Date: 2026-01-01
- Superseded by: [New Decision](2026-02-02-new.md)

> **2026-02-02: superseded.** The mechanism is gone.

## Context
"""

NEW_NOTE = """# New Decision

- Status: Accepted
- Date: 2026-02-02
- Supersedes: [Old Decision](2026-01-01-old.md)

## Context

The old code lived in `app/Real.swift`.
"""

INDEX_MD = """# Design Decisions

## Notes

Newest last.

- [2026-01-01: Old Decision](2026-01-01-old.md) -- Superseded by
  [2026-02-02: New Decision](2026-02-02-new.md).
- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.
"""


def build_baseline(root: Path) -> None:
    """The valid tree every case starts from: one app file, AGENTS.md, a superseded pair, an index."""
    (root / "app").mkdir(parents=True)
    (root / "docs" / "design").mkdir(parents=True)
    (root / "app" / "Real.swift").write_text("// a real file\n", encoding="utf-8")
    (root / "AGENTS.md").write_text(AGENTS_MD, encoding="utf-8")
    design = root / "docs" / "design"
    (design / "2026-01-01-old.md").write_text(OLD_NOTE, encoding="utf-8")
    (design / "2026-02-02-new.md").write_text(NEW_NOTE, encoding="utf-8")
    (design / "index.md").write_text(INDEX_MD, encoding="utf-8")

    run = lambda *args: subprocess.run(args, cwd=root, check=True, capture_output=True)
    run("git", "init", "-q", ".")
    run("git", "config", "user.email", "test@example.com")
    run("git", "config", "user.name", "Test")
    run("git", "add", "-A")
    run("git", "commit", "-qm", "baseline")


def edit(root: Path, relative: str, old: str, new: str) -> None:
    path = root / relative
    text = path.read_text(encoding="utf-8")
    assert old in text, f"{relative} does not contain {old!r}"
    path.write_text(text.replace(old, new), encoding="utf-8")


def append(root: Path, relative: str, text: str) -> None:
    with (root / relative).open("a", encoding="utf-8") as handle:
        handle.write(text)


def add_note(root: Path, name: str, body: str, row: str) -> None:
    """Write a note and give it an index row, so a case tests one thing and not also D10."""
    (root / "docs" / "design" / name).write_text(body, encoding="utf-8")
    edit(
        root,
        "docs/design/index.md",
        "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n",
        "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n" + row,
    )


@dataclass(frozen=True)
class Case:
    """One mutation of the baseline tree and the verdict it must produce.

    `message` is a substring the failure has to contain. A case that only asserted
    the exit status would pass on a lint that reported the wrong thing, and the whole
    point of the message format is that someone can fix the file without reading the
    lint.
    """

    name: str
    mutate: Callable[[Path], None]
    should_pass: bool
    message: str = ""
    reason: str = ""


CASES: list[Case] = [
    # --- D1: a backticked repo-relative path must resolve. ---
    Case(
        "d1-dangling",
        lambda root: edit(root, "AGENTS.md", "app/Real.swift", "app/Gone.swift"),
        False,
        "AGENTS.md:3: `app/Gone.swift` does not exist",
        "a backticked path that does not exist should fail, naming file, line, and path",
    ),
    # The original bug: a design note's References survive a file's move to another
    # layer, and keep pointing at the layer it left.
    Case(
        "d1-moved-layer",
        lambda root: edit(
            root, "docs/design/2026-02-02-new.md", "app/Real.swift", "app/Projections.swift"
        ),
        False,
        "docs/design/2026-02-02-new.md:9: `app/Projections.swift` does not exist",
        "a References path left behind by a cross-layer move should fail",
    ),
    # The pre-S09 shape: a live document citing a file in a deleted directory. That
    # directory is no longer a top-level name, so this is the case DEAD_ROOTS covers.
    Case(
        "d1-dead-root",
        lambda root: edit(
            root, "AGENTS.md", "app/Real.swift", "plan-terminal-engine/12-testing-conformance.md"
        ),
        False,
        "`plan-terminal-engine/12-testing-conformance.md` does not exist",
        "a citation into the deleted plan-terminal-engine/ should fail",
    ),
    Case(
        "d1-foreign-path",
        lambda root: edit(root, "AGENTS.md", "app/Real.swift", "src/apprt/embedded.zig"),
        True,
        reason="a path rooted outside this repo should not be checked",
    ),
    Case(
        "d1-line-span",
        lambda root: edit(root, "AGENTS.md", "app/Real.swift", "app/Real.swift:8-13,67-101"),
        True,
        reason="a `file:lines` citation should resolve on its path half",
    ),
    Case(
        "d1-identifier",
        lambda root: edit(root, "AGENTS.md", "app/Real.swift", "app/Real.swift#someSymbol"),
        True,
        reason="a `file#identifier` citation should resolve on its path half",
    ),
    Case(
        "d1-fenced",
        lambda root: append(
            root, "AGENTS.md", "\n```\napp/Gone.swift\n`app/AlsoGone.swift`\n```\n"
        ),
        True,
        reason="paths inside a fenced code block should not be checked",
    ),
    Case(
        "d1-bare-filename",
        lambda root: edit(root, "AGENTS.md", "app/Real.swift", "Gone.swift"),
        True,
        reason="a bare filename names no location, so it should not be checked",
    ),
    # The escape hatch, in all three directions.
    Case(
        "d1-allow-missing",
        lambda root: (
            edit(root, "AGENTS.md", "app/Real.swift", "app/Gone.swift"),
            append(root, "AGENTS.md", "\n<!-- docs-lint: allow-missing app/Gone.swift -->\n"),
        ),
        True,
        reason="an allow-missing marker should exempt the path it names",
    ),
    Case(
        "d1-allow-missing-scoped",
        lambda root: (
            edit(root, "AGENTS.md", "app/Real.swift", "app/Gone.swift"),
            append(root, "AGENTS.md", "\n<!-- docs-lint: allow-missing app/Other.swift -->\n"),
        ),
        False,
        "AGENTS.md:3: `app/Gone.swift` does not exist",
        "an allow-missing marker must not exempt a path it does not name",
    ),
    Case(
        "d1-allow-missing-per-file",
        lambda root: (
            edit(root, "AGENTS.md", "app/Real.swift", "app/Gone.swift"),
            append(
                root,
                "docs/design/2026-02-02-new.md",
                "\n<!-- docs-lint: allow-missing app/Gone.swift -->\n",
            ),
        ),
        False,
        "AGENTS.md:3: `app/Gone.swift` does not exist",
        "an allow-missing marker in one file must not exempt another file",
    ),
    Case(
        "d1-allow-missing-several",
        lambda root: (
            edit(root, "AGENTS.md", "app/Real.swift", "app/Gone.swift"),
            append(
                root,
                "AGENTS.md",
                "\n<!-- docs-lint: allow-missing app/Other.swift app/Gone.swift -->\n",
            ),
        ),
        True,
        reason="one marker may name several paths",
    ),
    # --- D2: relative markdown links resolve. ---
    Case(
        "d2-dangling-link",
        lambda root: edit(root, "AGENTS.md", "(docs/design/index.md)", "(docs/design/gone.md)"),
        False,
        "link `docs/design/gone.md` does not exist",
        "a markdown link to a missing file should fail, naming the target",
    ),
    Case(
        "d2-relative-link",
        lambda root: append(
            root, "docs/design/index.md", "\nSee [the old note](../design/2026-01-01-old.md).\n"
        ),
        True,
        reason="a link that walks up and back down should resolve",
    ),
    Case(
        "d2-plans-link",
        lambda root: append(
            root, "docs/design/index.md", "\nSee [the plan](../../plans/impl/2026-01-01-gone.md).\n"
        ),
        True,
        reason="a link into plans/ should not be resolved; plan links are meant to rot",
    ),
    # --- D3: front matter shape. ---
    Case(
        "d3-backticked",
        lambda root: edit(
            root, "docs/design/2026-02-02-new.md", "- Status: Accepted", "`Status`: Accepted"
        ),
        False,
        "front matter must open with `- Status: <word>` on line 3",
        "a backticked `Status`: field should fail",
    ),
    Case(
        "d3-date-missing",
        lambda root: edit(
            root, "docs/design/2026-02-02-new.md", "- Date: 2026-02-02", "Date: 2026-02-02"
        ),
        False,
        "`- Date: YYYY-MM-DD` must be the line after Status",
        "a bare Date: line should fail",
    ),
    Case(
        "d3-order",
        lambda root: edit(
            root,
            "docs/design/2026-02-02-new.md",
            "- Status: Accepted\n- Date: 2026-02-02",
            "- Date: 2026-02-02\n- Status: Accepted",
        ),
        False,
        "front matter must open with `- Status: <word>` on line 3",
        "Date before Status should fail",
    ),
    # --- D4: the status vocabulary. ---
    Case(
        "d4-vocabulary",
        lambda root: edit(
            root, "docs/design/2026-02-02-new.md", "- Status: Accepted", "- Status: Current"
        ),
        False,
        "Status `Current` is not one of Accepted, Superseded, Draft",
        "an unknown status word should fail, listing the allowed words",
    ),
    # --- D5: Superseded needs a resolvable successor link. ---
    Case(
        "d5-no-successor",
        lambda root: (
            edit(
                root,
                "docs/design/2026-01-01-old.md",
                "- Superseded by: [New Decision](2026-02-02-new.md)\n",
                "",
            ),
            edit(
                root,
                "docs/design/2026-02-02-new.md",
                "- Supersedes: [Old Decision](2026-01-01-old.md)\n",
                "",
            ),
        ),
        False,
        "Status is Superseded but no `- Superseded by: ` field names the successor",
        "Superseded with no successor field should fail",
    ),
    Case(
        "d5-successor-outside",
        lambda root: edit(
            root, "docs/design/2026-01-01-old.md", "(2026-02-02-new.md)", "(../../AGENTS.md)"
        ),
        False,
        "`Superseded by` links `../../AGENTS.md`, which is not a note in docs/design/",
        "a successor link outside docs/design/ should fail",
    ),
    # --- D6: a successor link forces Superseded. This is the original bug. ---
    Case(
        "d6-accepted-with-successor",
        lambda root: edit(
            root, "docs/design/2026-01-01-old.md", "- Status: Superseded", "- Status: Accepted"
        ),
        False,
        "a `Superseded by` field is present but Status is `Accepted`; a note with a successor is Superseded",
        "Status: Accepted above a Superseded by field should fail",
    ),
    # --- D7: a banner forces Superseded or Amended. The pre-S08 state. ---
    Case(
        "d7-banner-accepted",
        lambda root: add_note(
            root,
            "2026-03-03-amended.md",
            "# Amended Note\n\n- Status: Accepted\n- Date: 2026-03-03\n\n"
            "> **2026-04-04: the mechanism is gone.** The rule still binds.\n\n## Context\n",
            "- [2026-03-03: Amended Note](2026-03-03-amended.md) -- Accepted.\n",
        ),
        False,
        "needs `Status: Superseded` or an `- Amended: ` field",
        "Status: Accepted under a banner with no Amended field should fail, naming both ways out",
    ),
    Case(
        "d7-banner-amended",
        lambda root: add_note(
            root,
            "2026-03-03-amended.md",
            "# Amended Note\n\n- Status: Accepted\n- Date: 2026-03-03\n"
            "- Amended: 2026-04-04 -- the mechanism is gone.\n\n"
            "> **2026-04-04: the mechanism is gone.** The rule still binds.\n\n## Context\n",
            "- [2026-03-03: Amended Note](2026-03-03-amended.md) -- Accepted.\n",
        ),
        True,
        reason="a banner plus an Amended field should pass",
    ),
    # --- D8: Supersedes and Superseded by are symmetric. ---
    Case(
        "d8-asymmetric",
        lambda root: edit(
            root,
            "docs/design/2026-02-02-new.md",
            "- Supersedes: [Old Decision](2026-01-01-old.md)\n",
            "",
        ),
        False,
        "add `- Supersedes: `",
        "a successor that does not name its predecessor should fail",
    ),
    Case(
        "d8-two-predecessors",
        lambda root: (
            add_note(
                root,
                "2026-01-15-third.md",
                "# Third Decision\n\n- Status: Superseded\n- Date: 2026-01-15\n"
                "- Superseded by: [New Decision](2026-02-02-new.md)\n\n## Context\n",
                "",
            ),
            edit(
                root,
                "docs/design/index.md",
                "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n",
                "- [2026-01-15: Third Decision](2026-01-15-third.md) -- Superseded by"
                " [New](2026-02-02-new.md).\n"
                "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n",
            ),
            edit(
                root,
                "docs/design/2026-02-02-new.md",
                "- Supersedes: [Old Decision](2026-01-01-old.md)",
                "- Supersedes: [Old Decision](2026-01-01-old.md)\n"
                "- Supersedes: [Third Decision](2026-01-15-third.md)",
            ),
        ),
        True,
        reason="a note may repeat Supersedes for each predecessor it retired",
    ),
    # --- D9: Date matches the filename. ---
    Case(
        "d9-date-mismatch",
        lambda root: edit(
            root, "docs/design/2026-02-02-new.md", "- Date: 2026-02-02", "- Date: 2026-02-03"
        ),
        False,
        "Date `2026-02-03` does not match the filename date `2026-02-02`",
        "a Date that disagrees with the filename should fail, naming both dates",
    ),
    # --- D10: the index and the directory agree. ---
    Case(
        "d10-orphan-note",
        lambda root: (root / "docs" / "design" / "2026-04-04-lonely.md").write_text(
            "# Lonely\n\n- Status: Accepted\n- Date: 2026-04-04\n\n## Context\n",
            encoding="utf-8",
        ),
        False,
        "`2026-04-04-lonely.md` has no row in the note list",
        "a note with no index row should fail",
    ),
    Case(
        "d10-orphan-row",
        lambda root: append(
            root, "docs/design/index.md", "- [2026-05-05: Ghost](2026-05-05-ghost.md) -- Accepted.\n"
        ),
        False,
        "row links `2026-05-05-ghost.md`, which is not a note in docs/design/",
        "an index row for a note that does not exist should fail",
    ),
    Case(
        "d10-status-mismatch",
        lambda root: edit(
            root,
            "docs/design/index.md",
            "(2026-02-02-new.md) -- Accepted.",
            "(2026-02-02-new.md) -- Superseded.",
        ),
        False,
        "says `Superseded` but the note says `Accepted`",
        "an index row whose status contradicts the note should fail, naming both",
    ),
    Case(
        "d10-no-status",
        lambda root: edit(
            root,
            "docs/design/index.md",
            "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.",
            "- [2026-02-02: New Decision](2026-02-02-new.md)",
        ),
        False,
        "names no status; it must read `-- Accepted`",
        "an index row with no status word should fail",
    ),
    Case(
        "d10-duplicate-row",
        lambda root: append(
            root,
            "docs/design/index.md",
            "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n",
        ),
        False,
        "already has a row at line",
        "two rows for one note should fail",
    ),
    Case(
        "d10-order",
        lambda root: edit(
            root,
            "docs/design/index.md",
            "- [2026-01-01: Old Decision](2026-01-01-old.md) -- Superseded by\n"
            "  [2026-02-02: New Decision](2026-02-02-new.md).\n"
            "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n",
            "- [2026-02-02: New Decision](2026-02-02-new.md) -- Accepted.\n"
            "- [2026-01-01: Old Decision](2026-01-01-old.md) -- Superseded by\n"
            "  [2026-02-02: New Decision](2026-02-02-new.md).\n",
        ),
        False,
        "breaks the newest-last order of the note list",
        "note rows out of date order should fail",
    ),
    Case(
        "d10-format-section-link",
        lambda root: edit(
            root,
            "docs/design/index.md",
            "## Notes",
            # Links a note that already has a real row, so if this bullet were read
            # as a row the duplicate-row check would fire.
            "## Format\n\n- [an example row](2026-02-02-new.md) -- Accepted.\n\n## Notes",
        ),
        True,
        reason="a bullet link outside the ## Notes list is not a row",
    ),
]


class DocsLintTests(unittest.TestCase):
    """Drives CASES against a fresh copy of the baseline tree."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script()
        cls._store = TemporaryDirectory()
        cls.baseline = Path(cls._store.name) / "baseline"
        cls.baseline.mkdir()
        build_baseline(cls.baseline)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._store.cleanup()

    def fixture(self, name: str) -> Path:
        target = Path(self._store.name) / name
        shutil.copytree(self.baseline, target)
        return target

    def test_baseline_tree_passes(self):
        self.assertEqual(self.module.collect_violations(self.fixture("baseline-copy")), [])

    def test_every_case_produces_its_verdict(self):
        for case in CASES:
            with self.subTest(case=case.name):
                root = self.fixture(case.name)
                case.mutate(root)
                violations = self.module.collect_violations(root)
                if case.should_pass:
                    self.assertEqual(violations, [], case.reason)
                else:
                    self.assertTrue(violations, case.reason)
                    joined = "\n".join(violations)
                    self.assertIn(case.message, joined, case.reason)

    def test_the_repository_itself_is_clean(self):
        self.assertEqual(self.module.collect_violations(ROOT), [])

    def test_the_command_line_reports_and_exits(self):
        clean = subprocess.run(
            [str(SCRIPT), str(self.fixture("cli-clean"))], capture_output=True, text=True
        )
        self.assertEqual(clean.returncode, 0)
        self.assertIn("docs lint passed", clean.stdout)

        broken = self.fixture("cli-broken")
        edit(broken, "AGENTS.md", "app/Real.swift", "app/Gone.swift")
        result = subprocess.run([str(SCRIPT), str(broken)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("docs-lint: AGENTS.md:3: `app/Gone.swift` does not exist", result.stderr)
        self.assertIn("docs lint FAILED", result.stderr)

    def test_a_tree_without_design_notes_is_a_setup_error_not_a_pass(self):
        empty = Path(self._store.name) / "empty"
        empty.mkdir()
        result = subprocess.run([str(SCRIPT), str(empty)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
