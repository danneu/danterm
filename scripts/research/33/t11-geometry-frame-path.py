#!/usr/bin/env python3
"""Research doc 33, task T11: require zero geometry projection work per planFrame.

Copies TerminalCore and TerminalRenderPlanning into a scratch directory, injects counters
into the geometry projection, compiles the copy with the probe, and checks that planning
one canonical 179x66 frame neither calls `presentedRowGeometry` nor allocates its rows.
The production tree is never instrumented.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t11-geometry-frame-path-probe.swift"
COUNTERS = HERE / "t11-geometry-frame-path-counters.swift"
SOURCE_TREES = [
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCore",
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalRenderPlanning",
]

PATCHES = [
    (
        "Terminal.swift",
        "    private var presentedRowGeometry: [TerminalRowGeometry] {\n"
        "        let topRow = scrollProjection.topRow\n",
        "    private var presentedRowGeometry: [TerminalRowGeometry] {\n"
        "        t11Counters.presentedRowGeometryCalls += 1\n"
        "        let topRow = scrollProjection.topRow\n",
    ),
    (
        "Terminal.swift",
        "        return (topRow..<(topRow + rowCount)).map { index in\n"
        "            var kinds = [TerminalCellGeometry](\n",
        "        return (topRow..<(topRow + rowCount)).map { index in\n"
        "            t11Counters.geometryRowAllocations += 1\n"
        "            var kinds = [TerminalCellGeometry](\n",
    ),
]


def instrument(scratch):
    """Copy the engine sources and inject each counter at one exact source anchor."""
    sources = scratch / "engine"
    sources.mkdir()
    for tree in SOURCE_TREES:
        for path in sorted(tree.glob("*.swift")):
            destination = sources / path.name
            if destination.exists():
                raise SystemExit(f"source file name collides across trees: {path.name}")
            text = path.read_text(encoding="utf-8").replace("import TerminalCore\n", "")
            destination.write_text(text, encoding="utf-8")

    for name, anchor, replacement in PATCHES:
        path = sources / name
        text = path.read_text(encoding="utf-8")
        occurrences = text.count(anchor)
        if occurrences != 1:
            raise SystemExit(
                f"instrumentation anchor matched {occurrences} times in {name}; "
                f"the engine moved and this probe must be re-anchored:\n{anchor}"
            )
        path.write_text(text.replace(anchor, replacement), encoding="utf-8")
    return sources


def build(scratch, sources):
    """Compile the probe and instrumented engine as one optimized module."""
    main = scratch / "main.swift"
    shutil.copyfile(PROBE, main)
    counters = scratch / "t11-counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / "t11-geometry-frame-path-probe"
    module_cache = scratch / "swift-module-cache"
    subprocess.run(
        [
            "swiftc",
            "-O",
            "-swift-version",
            "6",
            "-module-cache-path",
            str(module_cache),
            "-o",
            str(binary),
            str(main),
            str(counters),
            *(str(path) for path in sorted(sources.glob("*.swift"))),
        ],
        check=True,
    )
    return binary


def main():
    with tempfile.TemporaryDirectory(prefix="t11-geometry-frame-path-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch, instrument(scratch))
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    report = json.loads(result.stdout)
    print(json.dumps(report, sort_keys=True))

    expected = {
        "planFrames": 1,
        "presentedRowGeometryCalls": 0,
        "geometryRowAllocations": 0,
    }
    if report != expected:
        print(f"FAIL: expected {json.dumps(expected, sort_keys=True)}", file=sys.stderr)
        return 1
    print("PASS: planFrame performs no TerminalGeometry projection work")
    return 0


if __name__ == "__main__":
    sys.exit(main())
