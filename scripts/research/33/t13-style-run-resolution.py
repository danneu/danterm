#!/usr/bin/env python3
"""Research doc 33, task T13: require one style resolution per style run.

Copies TerminalCore and TerminalRenderPlanning into a scratch directory, injects
counters into style resolution and the planner's semantic-style walk, compiles
the copy with the probe, and checks one canonical 179x66 frame. The production
tree is never instrumented.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t13-style-run-resolution-probe.swift"
COUNTERS = HERE / "t13-style-run-resolution-counters.swift"
SOURCE_TREES = [
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCore",
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalRenderPlanning",
]


def replace_once(text, anchor, replacement, label):
    occurrences = text.count(anchor)
    if occurrences != 1:
        raise SystemExit(
            f"instrumentation anchor matched {occurrences} times for {label}; "
            f"the planner moved and this probe must be re-anchored:\n{anchor}"
        )
    return text.replace(anchor, replacement)


def instrument(scratch):
    """Copy the engine and count both sides of the style-resolution seam."""
    sources = scratch / "engine"
    sources.mkdir()
    for tree in SOURCE_TREES:
        for path in sorted(tree.glob("*.swift")):
            destination = sources / path.name
            if destination.exists():
                raise SystemExit(f"source file name collides across trees: {path.name}")
            text = path.read_text(encoding="utf-8").replace("import TerminalCore\n", "")
            destination.write_text(text, encoding="utf-8")

    colors = sources / "RenderColorResolution.swift"
    text = colors.read_text(encoding="utf-8")
    anchor = "func resolveCellStyle(_ style: TerminalStyle, theme: RenderTheme) -> ResolvedCellStyle {\n"
    text = replace_once(
        text,
        anchor,
        anchor + "    t13Counters.resolveCellStyleCalls += 1\n",
        "resolveCellStyle entry",
    )
    colors.write_text(text, encoding="utf-8")

    planner = sources / "RenderFramePlanner.swift"
    text = planner.read_text(encoding="utf-8")
    visit_anchor = "            visit { columns, semanticStyle, visitCells in\n"
    text = replace_once(
        text,
        visit_anchor,
        visit_anchor + "                t13Counters.distinctStyleRuns += 1\n",
        "semantic style run count",
    )
    planner.write_text(text, encoding="utf-8")
    return sources


def build(scratch, sources):
    """Compile the probe and instrumented engine as one optimized module."""
    main = scratch / "main.swift"
    shutil.copyfile(PROBE, main)
    counters = scratch / "t13-counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / "t13-style-run-resolution-probe"
    subprocess.run(
        [
            "swiftc", "-O", "-swift-version", "6",
            "-module-cache-path", str(scratch / "swift-module-cache"),
            "-o", str(binary), str(main), str(counters),
            *(str(path) for path in sorted(sources.glob("*.swift"))),
        ],
        check=True,
    )
    return binary


def main():
    with tempfile.TemporaryDirectory(prefix="t13-style-run-resolution-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch, instrument(scratch))
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    report = json.loads(result.stdout)
    print(json.dumps(report, sort_keys=True))

    expected = {
        "planFrames": 1,
        "viewportCells": 179 * 66,
        "distinctStyleRuns": 66,
        "resolveCellStyleCalls": 66,
    }
    if report != expected:
        print(f"FAIL: expected {json.dumps(expected, sort_keys=True)}", file=sys.stderr)
        return 1
    print("PASS: each distinct semantic style run is resolved exactly once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
