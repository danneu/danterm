#!/usr/bin/env python3
"""Research doc 33, task T12: require one cell pass and no transient cell row.

Copies TerminalCore and TerminalRenderPlanning into a scratch directory, injects
counters into the planner's row traversal, compiles the copy with the probe, and
checks one canonical 179x66 frame. The production tree is never instrumented.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t12-row-fusion-probe.swift"
COUNTERS = HERE / "t12-row-fusion-counters.swift"
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
    """Copy the engine and instrument either the pre-fusion or fused structure."""
    sources = scratch / "engine"
    sources.mkdir()
    for tree in SOURCE_TREES:
        for path in sorted(tree.glob("*.swift")):
            destination = sources / path.name
            if destination.exists():
                raise SystemExit(f"source file name collides across trees: {path.name}")
            text = path.read_text(encoding="utf-8").replace("import TerminalCore\n", "")
            destination.write_text(text, encoding="utf-8")

    path = sources / "RenderFramePlanner.swift"
    text = path.read_text(encoding="utf-8")
    legacy_row_anchor = (
        "terminal.forEachViewportRow(rows: 0..<rowCount, where: replanning) { row, visit in\n"
    )
    fused_row_anchor = (
        "        terminal.forEachViewportRow(\n"
        "            rows: 0..<rowCount,\n"
        "            where: { reuseSource($0) == nil }\n"
        "        ) { row, visit in\n"
    )
    row_anchor = legacy_row_anchor if legacy_row_anchor in text else fused_row_anchor
    text = replace_once(
        text,
        row_anchor,
        row_anchor + "            t12Counters.cellRowPasses += 1\n",
        "viewport row pass",
    )

    allocation_anchor = "            var cells: [PlannedCell] = []\n"
    if allocation_anchor in text:
        text = replace_once(
            text,
            allocation_anchor,
            "            t12Counters.plannedCellRowAllocations += 1\n" + allocation_anchor,
            "planned-cell row allocation",
        )
        pass_anchors = [
            "    private func overlayFragments(\n",
            "    private func backgroundRuns(row: Int, cells: [PlannedCell]) -> [RenderBackgroundRun] {\n",
            "    private func textRuns(row: Int, cells: [PlannedCell]) -> [RenderTextRun] {\n",
            "    private func decorationRuns(row: Int, cells: [PlannedCell]) -> [RenderDecorationRun] {\n",
        ]
        for index, anchor in enumerate(pass_anchors):
            if index == 0:
                body = (
                    "        matched: Range<Int>?\n"
                    "    ) -> [OverlayFragment] {\n"
                )
                replacement = body + "        t12Counters.cellRowPasses += 1\n"
                text = replace_once(text, body, replacement, "overlay cell pass")
            else:
                text = replace_once(
                    text,
                    anchor,
                    anchor + "        t12Counters.cellRowPasses += 1\n",
                    f"cell pass {index + 1}",
                )

    path.write_text(text, encoding="utf-8")
    return sources


def build(scratch, sources):
    """Compile the probe and instrumented engine as one optimized module."""
    main = scratch / "main.swift"
    shutil.copyfile(PROBE, main)
    counters = scratch / "t12-counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / "t12-row-fusion-probe"
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
    with tempfile.TemporaryDirectory(prefix="t12-row-fusion-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch, instrument(scratch))
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    report = json.loads(result.stdout)
    print(json.dumps(report, sort_keys=True))

    expected = {
        "planFrames": 1,
        "viewportRows": 66,
        "plannedCellRowAllocations": 0,
        "cellRowPasses": 66,
    }
    if report != expected:
        print(f"FAIL: expected {json.dumps(expected, sort_keys=True)}", file=sys.stderr)
        return 1
    print("PASS: each planned row uses one cell pass and no transient cell row")
    return 0


if __name__ == "__main__":
    sys.exit(main())
