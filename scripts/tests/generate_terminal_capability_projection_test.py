#!/usr/bin/env python3
"""Self-test for scripts/generate-terminal-capability-projection.py.

Every case runs the generator against a fixture contract in a temporary tree, so
each verdict is proved without depending on what the real document happens to say
today. That matters more here than in most self-tests: the generator's whole job
is to make one document decide the engine's answers, so what has to be pinned is
the mapping from document text to projection -- not one snapshot of the output.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = REPO_ROOT / "scripts" / "generate-terminal-capability-projection.py"
CONTRACT_RELATIVE = "docs/terminal-capabilities.md"
PROJECTION_RELATIVE = (
    "lib/TerminalCore/Sources/TerminalCore/TerminalCapabilityProjection.generated.swift"
)

TERMINFO_HEADER = (
    "| id | kind | XTGETTCAP query | macOS 26 ncurses 6.0 | ncurses 1.1261 | evidence |\n"
    "|---|---|---|---|---|---|\n"
)
PSEUDO_HEADER = "| query | kind | value | disposition |\n|---|---|---|---|\n"

DEFAULT_TERMINFO_ROWS = [
    "| `am` | boolean | `am` | `true` | `true` | Suite |",
    "| `colors` | number | `colors` `Co` | `256` | `256` | Suite |",
    "| `pairs` | number | -- | `32767` | `65536` | Suite |",
    "| `el` | output | `el` | `\\x1b[K` | same | Suite |",
    "| `cup` | output-parameterized | `cup` | `\\x1b[%i%p1%dH` | same | Suite |",
]
DEFAULT_PSEUDO_ROWS = [
    "| `TN` `name` | string | `xterm-256color` | answered -- the TERM DanTerm owns |",
    "| `RGB` | number | -- | denied -- absent from both baselines |",
]

failures: list[str] = []


def contract(terminfo_rows: list[str], pseudo_rows: list[str]) -> str:
    return (
        "# Fixture contract\n\n## Terminfo claims\n\n"
        + TERMINFO_HEADER
        + "\n".join(terminfo_rows)
        + "\n\nProse between the tables.\n\n"
        + PSEUDO_HEADER
        + "\n".join(pseudo_rows)
        + "\n\nTrailing prose.\n"
    )


def tree(root: Path, contract_text: str, projection_text: str | None = None) -> None:
    (root / CONTRACT_RELATIVE).parent.mkdir(parents=True, exist_ok=True)
    (root / CONTRACT_RELATIVE).write_text(contract_text, encoding="utf-8")
    projection = root / PROJECTION_RELATIVE
    projection.parent.mkdir(parents=True, exist_ok=True)
    if projection_text is not None:
        projection.write_text(projection_text, encoding="utf-8")


def run(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GENERATOR), *arguments],
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "TERMINAL_CAPABILITY_PROJECTION_ROOT": str(root)},
        check=False,
    )


def expect(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def case_generated_projection_matches_the_contract() -> None:
    """A generated projection passes --check, and carries each value kind's wire form."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        tree(root, contract(DEFAULT_TERMINFO_ROWS, DEFAULT_PSEUDO_ROWS))
        expect(run(root).returncode == 0, "generating a fresh projection failed")
        rendered = (root / PROJECTION_RELATIVE).read_text(encoding="utf-8")

        expect('"am": ""' in rendered, "a boolean capability should project an empty value")
        expect('"colors": "256"' in rendered, "a number capability should project its digits")
        expect('"Co": "256"' in rendered, "a termcap alias should project the row's value")
        expect(
            '"el": "\\u{1B}[K"' in rendered,
            "an unparameterized string should project with its escapes decoded",
        )
        expect(
            '"cup": "\\\\E[%i%p1%dH"' in rendered,
            "a parameterized string should project in terminfo source form",
        )
        expect('"TN": "xterm-256color"' in rendered, "an answered pseudo-capability is projected")
        expect('"name":' in rendered, "a pseudo-capability projects under every name it answers to")
        expect('"pairs"' not in rendered, "a row the document does not answer is not projected")
        expect('"RGB"' not in rendered, "a denied pseudo-capability is not projected")

        expect(run(root, "--check").returncode == 0, "--check rejected a freshly generated file")


def case_hand_edited_projection_fails() -> None:
    """Editing the projection by hand is what the gate step exists to catch."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        tree(root, contract(DEFAULT_TERMINFO_ROWS, DEFAULT_PSEUDO_ROWS))
        run(root)
        projection = root / PROJECTION_RELATIVE
        projection.write_text(
            projection.read_text(encoding="utf-8").replace('"colors": "256"', '"colors": "16777216"'),
            encoding="utf-8",
        )
        result = run(root, "--check")
        expect(result.returncode != 0, "--check accepted a hand-edited projection")
        expect(
            CONTRACT_RELATIVE in result.stderr,
            "the failure should name the document the projection disagrees with",
        )


def case_unregenerated_contract_change_fails() -> None:
    """Adding a row to the document without regenerating fails, which is the other half."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        tree(root, contract(DEFAULT_TERMINFO_ROWS, DEFAULT_PSEUDO_ROWS))
        run(root)
        widened = DEFAULT_TERMINFO_ROWS + [
            "| `bold` | output | `bold` | `\\x1b[1m` | same | Suite |"
        ]
        (root / CONTRACT_RELATIVE).write_text(
            contract(widened, DEFAULT_PSEUDO_ROWS), encoding="utf-8"
        )
        expect(run(root, "--check").returncode != 0, "--check accepted a stale projection")
        expect(run(root).returncode == 0, "regenerating after a contract change failed")
        expect(run(root, "--check").returncode == 0, "--check rejected the regenerated projection")


def case_missing_projection_fails() -> None:
    """A projection that was never committed is a disagreement, not a crash."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        tree(root, contract(DEFAULT_TERMINFO_ROWS, DEFAULT_PSEUDO_ROWS))
        expect(run(root, "--check").returncode != 0, "--check accepted a missing projection")


def case_unprojectable_contract_is_reported() -> None:
    """A contract the generator cannot project fails loudly instead of guessing a value."""
    cases = [
        (
            "an answered row whose baselines disagree",
            ["| `pairs` | number | `pairs` | `32767` | `65536` | Suite |"],
            DEFAULT_PSEUDO_ROWS,
        ),
        (
            "a boolean row carrying a non-boolean value",
            ["| `am` | boolean | `am` | `maybe` | same | Suite |"],
            DEFAULT_PSEUDO_ROWS,
        ),
        (
            "a number row carrying a non-numeric value",
            ["| `colors` | number | `colors` | `many` | same | Suite |"],
            DEFAULT_PSEUDO_ROWS,
        ),
        (
            "two rows claiming one query name",
            [
                "| `am` | boolean | `am` | `true` | `true` | Suite |",
                "| `bce` | boolean | `am` | `true` | `true` | Suite |",
            ],
            DEFAULT_PSEUDO_ROWS,
        ),
        (
            "a pseudo-capability colliding with a terminfo row",
            DEFAULT_TERMINFO_ROWS,
            ["| `Co` | number | `256` | answered -- collides |"],
        ),
        # A skip here would take a capability off the wire silently: --check re-derives
        # both sides, so the two would go on agreeing about a roster nobody meant.
        (
            "a pseudo-capability whose disposition is neither answered nor denied",
            DEFAULT_TERMINFO_ROWS,
            ["| `TN` | string | `xterm-256color` | maybe -- unclear |"],
        ),
    ]
    for description, terminfo_rows, pseudo_rows in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tree(root, contract(terminfo_rows, pseudo_rows))
            result = run(root)
            expect(result.returncode != 0, f"{description} was projected instead of reported")
            expect(result.stderr.strip() != "", f"{description} was reported with no message")


def case_absent_table_is_reported() -> None:
    """A document that lost a table fails rather than projecting an empty engine roster."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        tree(root, "# Fixture contract\n\nNo tables at all.\n")
        expect(run(root).returncode != 0, "a contract with no tables was projected")


def main() -> int:
    case_generated_projection_matches_the_contract()
    case_hand_edited_projection_fails()
    case_unregenerated_contract_change_fails()
    case_missing_projection_fails()
    case_unprojectable_contract_is_reported()
    case_absent_table_is_reported()

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("generate-terminal-capability-projection self-test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
