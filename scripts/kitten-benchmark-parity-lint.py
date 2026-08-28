#!/usr/bin/env python3
"""Hold the Swift kitten-feed fixture to the pinned kitty benchmark sources.

`lib/TerminalCore/Sources/KittenFeedFixture` replays the byte streams kitten's
`__benchmark__ --render` writes, so the A/B ladder can put a verdict on the four arms
research 39 is chasing. The port is only worth what its fidelity is worth: if kitty
changes an alphabet, a payload size, a CSI band, or the escape codes its loop wraps a
benchmark in, and the port does not, the ladder keeps measuring a stimulus that no
longer corresponds to the external run the work is judged against -- and nothing else
in the tree would notice, because both physical arms would receive the same wrong bytes.

Checked invariants (IDs match the plan that introduced them):

- I1. The payload constants the port encodes -- alphabet, control characters, the two
  Unicode blocks, the three size expressions, the combining count, the seven CSI chunk
  strings with their probability bands, the ASCII run-length bound, the four description
  strings, the clear and reset strings, and the device-status-report count -- equal what
  `tools/cmd/benchmark/main.go` defines. An error, not a warning: a mismatch silently
  changes what the arm measures while every test still passes.
- I2. The setup and teardown byte sequences equal what the pinned `tools/tui/loop`
  source emits for kitten's option profile (alternate screen on, every other option at
  its zero value) plus the cursor hide and restore `benchmark_data` adds. An error
  because the wrapper decides which scroll branch the payload runs down (39/F1), so it
  is stimulus, not framing.
- I3. The reference file hashes recorded beside the port match the pinned checkout. An
  error because a pin bump can move something this script does not parse; the recorded
  hash is what forces a human to re-read the reference rather than trust the parser.

The port is asked for its own parameters through the benchmark executable's `describe`
command rather than by reading the Swift file, so the check reads what the port *does*,
not how its source is laid out.

`references/` is gitignored, so a fresh clone and CI have no checkout. That is reported
as "reference absent" with exit 0, never as a pass and never as a failure: the check has
no evidence either way, and failing would make `just fetch-references kitty` a
prerequisite for every gate run.

What it deliberately does not check: whether the port's *loops* match the reference's --
that a uniform draw is uniform, that the repetition structure is right, that the streams
parse. Those are behavioral claims with tests in
`lib/TerminalCore/Tests/KittenFeedFixtureTests`. This script only pins the constants,
and its own two directions are pinned by `scripts/tests/kitten-benchmark-parity-lint_test.sh`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

BENCHMARK_SOURCE = "tools/cmd/benchmark/main.go"
LOOP_SOURCE = "tools/tui/loop/terminal-state.go"
PORT_SOURCE = Path("lib/TerminalCore/Sources/KittenFeedFixture/KittenFeedFixture.swift")

CITATION_RE = re.compile(
    r"//\s*Adapted from (\S+) \(kitty \S+ [0-9a-f]{7,40}, body sha256:([0-9a-f]{12,64})\)"
)

# kitten's option profile for `__benchmark__`: `TerminalStateOptions{Alternate_screen:
# !opts.WithScrollback}` with every other field left at its Go zero value, and no
# `--with-scrollback`. The port replays that profile, so the wrapper this script rebuilds
# is the alt-screen one; a plan that adds a scrollback arm must extend both sides.
ALTERNATE_SCREEN = True

# The four Go benchmark names, mapped to the arm names the port and the ladder use.
ARM_NAMES = {
    "ascii": "ascii",
    "unicode": "unicode",
    "unique_unicode": "unique-unicode",
    "csi": "csi",
}


def go_string(literal: str) -> str:
    """Decode a Go interpreted string literal's body into the bytes it denotes."""
    return literal.encode("utf-8").decode("unicode_escape")


def go_const(source: str, name: str) -> str:
    """Read a `const <name> = "..."` interpreted string literal."""
    match = re.search(rf'const {name} = "((?:[^"\\]|\\.)*)"', source)
    if match is None:
        raise SystemExit(f"kitten parity lint: cannot find const {name}")
    return go_string(match.group(1))


def go_raw_const(source: str, name: str) -> str:
    """Read a `const <name> = ` + "`" + `...` + "`" + ` raw string literal, which keeps every byte as written."""
    match = re.search(rf"const {name} = `(.*?)`", source, re.DOTALL)
    if match is None:
        raise SystemExit(f"kitten parity lint: cannot find raw const {name}")
    return match.group(1)


def go_int(source: str, pattern: str) -> int:
    """Evaluate one integer expression written with literals, `*`, and `+`."""
    match = re.search(pattern, source)
    if match is None:
        raise SystemExit(f"kitten parity lint: cannot find integer for {pattern}")
    expression = match.group(1).strip()
    if not re.fullmatch(r"(0[xX][0-9a-fA-F]+|\d+)(\s*[+*]\s*(0[xX][0-9a-fA-F]+|\d+))*", expression):
        raise SystemExit(f"kitten parity lint: refusing to evaluate {expression!r}")
    return int(eval(expression, {"__builtins__": {}}, {}))  # noqa: S307


def benchmark_parameters(source: str) -> dict:
    """Extract everything `main.go` fixes about the four in-scope arms."""
    descriptions = {}
    for go_name, arm in ARM_NAMES.items():
        function = {
            "ascii": "simple_ascii",
            "unicode": "unicode",
            "unique_unicode": "unique_unicode",
            "csi": "ascii_with_csi",
        }[go_name]
        body = re.search(rf"func {function}\(\).*?\n}}\n", source, re.DOTALL)
        if body is None:
            raise SystemExit(f"kitten parity lint: cannot find func {function}")
        match = re.search(r'const desc = "((?:[^"\\]|\\.)*)"', body.group(0))
        if match is None:
            raise SystemExit(f"kitten parity lint: cannot find desc in {function}")
        descriptions[arm] = go_string(match.group(1))

    chunks = []
    for band in re.finditer(
        r"case \(?(?:q < (?P<open>\d+)|(?P<low>\d+) <= q && q < (?P<high>\d+))\)?:\n"
        r"\s*chunk = (?P<value>.*)\n",
        source,
    ):
        lower = 0 if band.group("open") else int(band.group("low"))
        upper = int(band.group("open") or band.group("high"))
        value = band.group("value").strip()
        literal = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', value)
        chunks.append(
            {
                "lowerBound": lower,
                "upperBound": upper,
                "text": go_string(literal.group(1)) if literal else None,
            }
        )

    return {
        "alphabet": go_const(source, "ascii_printable"),
        "controlCharacters": go_const(source, "control_chars"),
        "chineseLoremIpsum": go_raw_const(source, "chinese_lorem_ipsum"),
        "miscUnicode": go_raw_const(source, "misc_unicode"),
        "asciiPayloadSize": go_int(source, r"random_string_of_bytes\(([^,]+), ascii_printable\+control_chars\)\n\tduration"),
        "csiPayloadMinimumSize": go_int(source, r"const sz = (.+)\n"),
        "csiRunLengthBound": go_int(source, r"random_string_of_bytes\(rand\.IntN\((\d+)\)\+1"),
        "unicodeRepeatCount": go_int(source, r"strings\.Repeat\(chinese_lorem_ipsum\+misc_unicode\+control_chars, (\d+)\)"),
        "uniqueUnicodeCellCount": go_int(source, r"const cell_count = (.+)\n"),
        "uniqueUnicodeCombiningCount": go_int(source, r"const combining_count = (.+)\n"),
        "uniqueUnicodeMarksPerCell": go_int(source, r"data\.WriteByte\('a'\)\n\t\tfor range (\d+) \{"),
        "csiChunks": chunks,
        "descriptions": descriptions,
        "clearScreen": go_const(source, "clear_screen"),
        "resetSequence": go_const(source, "reset"),
        "deviceStatusReport": go_string(
            re.search(r'strings\.Repeat\("((?:[^"\\]|\\.)*)", count\)', source).group(1)
        ),
        "deviceStatusReportCount": go_int(source, r"const count = (\d+)\n"),
    }


def loop_modes(source: str) -> dict[str, int]:
    """Read `terminal-state.go`'s Mode table, keeping the private-mode bit."""
    modes = {}
    for match in re.finditer(r"^\t(\w+)\s+(?:Mode )?= (\d+)( \| private)?$", source, re.M):
        modes[match.group(1)] = (int(match.group(2)), bool(match.group(3)))
    return modes


def loop_escape(modes: dict, name: str, which: str) -> str:
    """Rebuild `Mode.escape_code`, which is the only way the loop spells a mode."""
    number, private = modes[name]
    return f"\x1b[{'?' if private else ''}{number}{which}"


def loop_wrapper(source: str) -> tuple[str, str]:
    """Rebuild the setup and teardown bytes for kitten's benchmark option profile.

    Everything that can drift is parsed: the named escape-code constants, the numeric
    Mode table, and the ordered mode lists the two builders pass to `set_modes` and
    `reset_modes`. What is asserted rather than parsed is the option profile itself
    (see ALTERNATE_SCREEN above) -- Go's zero values are not in the source to read.
    """
    if not ALTERNATE_SCREEN:
        raise SystemExit("kitten parity lint: only the alternate-screen profile is ported")
    constants = {
        name: go_string(value)
        for name, value in re.findall(r'^\t(\w+)\s+= "((?:[^"\\]|\\.)*)"$', source, re.M)
    }
    modes = loop_modes(source)

    def function_body(function: str) -> str:
        body = re.search(
            rf"func \(self \*TerminalStateOptions\) {function}\(\).*?\n}}\n", source, re.DOTALL
        )
        if body is None:
            raise SystemExit(f"kitten parity lint: cannot find func {function}")
        return body.group(0)

    def literal_write(function: str, after: str) -> str:
        """Read the first `sb.WriteString("...")` literal following a marker line.

        The keyboard-flag writes are spelled as literals in the builders rather than as
        the named constants beside them, so reading the constant would let the two drift
        apart without this script noticing.
        """
        body = function_body(function)
        index = body.find(after)
        if index < 0:
            raise SystemExit(f"kitten parity lint: cannot find {after!r} in {function}")
        match = re.search(r'sb\.WriteString\("((?:[^"\\]|\\.)*)"\)', body[index:])
        if match is None:
            raise SystemExit(f"kitten parity lint: cannot find a literal after {after!r}")
        return go_string(match.group(1))

    def mode_list(function: str, call: str) -> list[str]:
        match = re.search(rf"(?<![\w]){call}\(&sb,\s*(.*?)\)\n", function_body(function), re.DOTALL)
        if match is None:
            raise SystemExit(f"kitten parity lint: cannot find {call} in {function}")
        return [name.strip() for name in match.group(1).replace("\n", " ").split(",") if name.strip()]

    setup = constants["SAVE_CURSOR"] + constants["SAVE_PRIVATE_MODE_VALUES"]
    setup += constants["DECSACE_DEFAULT_REGION_SELECT"]
    for name in mode_list("SetStateEscapeCodes", "reset_modes"):
        setup += loop_escape(modes, name, "l")
    for name in mode_list("SetStateEscapeCodes", "set_modes"):
        setup += loop_escape(modes, name, "h")
    setup += loop_escape(modes, "ALTERNATE_SCREEN", "h") + constants["CLEAR_SCREEN"]
    setup += literal_write("SetStateEscapeCodes", "case LEGACY_KEYS:")
    # `benchmark_data` hides the cursor right after writing the state.
    setup += loop_escape(modes, "DECTCEM", "l")

    teardown = literal_write("ResetStateEscapeCodes", "!= NO_KEYBOARD_STATE_CHANGE {")
    teardown += loop_escape(modes, "ALTERNATE_SCREEN", "l")
    teardown += constants["RESTORE_PRIVATE_MODE_VALUES"] + constants["RESTORE_CURSOR"]
    teardown += loop_escape(modes, "DECTCEM", "h")
    return setup, teardown


def port_parameters(root: Path, run=subprocess.run) -> dict:
    """Ask the benchmark executable what the port encodes."""
    completed = run(
        [
            "swift", "run",
            "--package-path", str(root / "lib" / "TerminalCore"),
            "TerminalCoreBenchmark", "describe",
        ],
        capture_output=True,
    )
    if completed.returncode != 0:
        raise SystemExit(
            "kitten parity lint: `TerminalCoreBenchmark describe` failed:\n"
            + completed.stderr.decode(errors="replace")
        )
    return json.loads(completed.stdout)


def recorded_hashes(path: Path) -> dict[str, str]:
    """Read the reference hashes the port records in its own header."""
    return {
        match.group(1): match.group(2)
        for match in CITATION_RE.finditer(path.read_text(encoding="utf-8"))
    }


def check(root: Path, parameters_path: Path | None = None) -> int:
    checkout = root / "references" / "kitty"
    benchmark_path = checkout / BENCHMARK_SOURCE
    loop_path = checkout / LOOP_SOURCE
    if not benchmark_path.is_file() or not loop_path.is_file():
        print(
            f"kitten parity lint skipped: no kitty checkout at {checkout} "
            "(run `just fetch-references kitty`)"
        )
        return 0

    errors: list[str] = []

    def report(invariant: str, message: str) -> None:
        errors.append(f"[{invariant}] {message}")

    benchmark_source = benchmark_path.read_text(encoding="utf-8")
    loop_source = loop_path.read_text(encoding="utf-8")
    reference = benchmark_parameters(benchmark_source)
    setup, teardown = loop_wrapper(loop_source)
    reference["setupSequence"] = setup
    # `benchmark_data`'s deferred write appends main.go's own `reset` after the loop's.
    reference["teardownSequence"] = teardown + reference["resetSequence"]

    if parameters_path is not None:
        port = json.loads(parameters_path.read_text(encoding="utf-8"))
    else:
        port = port_parameters(root)

    def bands(value):
        return [(band["lowerBound"], band["upperBound"], band.get("text")) for band in value]

    wrapper_keys = {"setupSequence", "teardownSequence"}
    for key, expected in reference.items():
        actual = port.get(key)
        if key == "csiChunks":
            if actual is not None and bands(actual) == bands(expected):
                continue
        elif actual == expected:
            continue
        invariant = "I2" if key in wrapper_keys else "I1"
        report(invariant, f"{key}: port has {actual!r}, reference has {expected!r}")

    recorded = recorded_hashes(root / PORT_SOURCE)
    for relative, path in ((BENCHMARK_SOURCE, benchmark_path), (LOOP_SOURCE, loop_path)):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        claimed = recorded.get(relative)
        if claimed is None:
            report("I3", f"{relative}: the port records no reference hash")
        elif not digest.startswith(claimed):
            report("I3", f"{relative}: recorded sha256:{claimed}, checkout has sha256:{digest[:12]}")

    if not errors:
        print(f"kitten benchmark parity lint passed ({len(reference)} parameters checked)")
        return 0

    for error in errors:
        print(f"{PORT_SOURCE}: {error}", file=sys.stderr)
    print(
        "\n"
        "=====================================================================\n"
        "The kitten feed fixture no longer matches the pinned kitty sources.\n"
        "\n"
        "  I1  A payload constant drifted. Re-read\n"
        f"      references/kitty/{BENCHMARK_SOURCE} and correct the constant in\n"
        f"      {PORT_SOURCE}. Do not adjust the reference side of this\n"
        "      script to make the error go away.\n"
        "  I2  The alt-screen wrapper drifted. Re-read\n"
        f"      references/kitty/{LOOP_SOURCE}. The wrapper is stimulus: it decides\n"
        "      which scroll branch the payload runs down (39/F1).\n"
        "  I3  A recorded reference hash is stale, which usually means the kitty\n"
        "      pin moved. Read the new reference, confirm nothing this script\n"
        "      does not parse has changed, then update the `Adapted from` line\n"
        f"      in {PORT_SOURCE}.\n"
        "\n"
        "Any change to the generated bytes also changes each arm's fixture\n"
        "identity, so blocks collected under the old stimulus stop validating.\n"
        "That is intended: a rule frozen for one stimulus cannot judge another.\n"
        "=====================================================================",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "root",
        nargs="?",
        default=Path(__file__).resolve().parent.parent,
        type=Path,
        help="repository root to lint (defaults to this script's repository)",
    )
    parser.add_argument(
        "--parameters",
        type=Path,
        default=None,
        help="read the port's parameters from this JSON file instead of building it",
    )
    arguments = parser.parse_args()
    return check(arguments.root.resolve(), arguments.parameters)


if __name__ == "__main__":
    sys.exit(main())
