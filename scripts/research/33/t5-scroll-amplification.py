#!/usr/bin/env python3
"""Research doc 33, task T5: count damaged rows and submitted glyphs per scroll event.

Copies `lib/TerminalCore/Sources/TerminalCore` and `.../TerminalRenderPlanning` into a
scratch directory, injects one counter increment at each site this task counts, compiles the
copy as a single optimized module with the probe, and reports -- for newlines fed at the
bottom of a full screen -- how many rows each published frame damages, how many glyph
occurrences the clipped plan hands the drawer, and how both compare against the measured
ideal a shift-carrying damage representation would produce.

The engine in the repo is never edited. Every injection is an exact-text anchor that must
match exactly once, so a source change that moves a site fails the run loudly instead of
silently miscounting.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t5-scroll-amplification-probe.swift"
COUNTERS = HERE / "t5-scroll-amplification-counters.swift"
SOURCE_TREES = [
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCore",
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalRenderPlanning",
]

# `text-line` writes 178 characters plus CR LF, so 91 of them is the 16 KiB read turn the
# PTY host caps a delivery at -- the live batch size. 1 is one line per delivery, which is
# the amplification's worst case, and 8 is the middle of the curve. The `-at-budget` arm
# is D7's frozen-topRow regime: the probe saturates a small scrollback budget first, so
# eviction cancels the append in `scrollProjection.topRow` on most scrolled lines.
BATCHES = (1, 8, 91)
SCENARIOS = ("bare-newline", "text-line", "rewrite-bottom-row", "text-line-at-budget")

# (file, anchor, replacement). The anchor is the unmodified text at the site; the
# replacement is that same text with one counter increment added. Each anchor must occur
# exactly once in its file.
PATCHES = [
    (
        "Terminal.swift",
        "    private mutating func recordPresentationFullDamage() {\n"
        "        if damage.recordFull() { pendingConsumerWork.noteDamageChanged() }\n",
        "    private mutating func recordPresentationFullDamage() {\n"
        "        t5Counters.fullDamageCalls += 1\n"
        "        if damage.recordFull() {\n"
        "            t5Counters.fullDamageEscalations += 1\n"
        "            pendingConsumerWork.noteDamageChanged()\n"
        "        }\n",
    ),
    (
        "Terminal.swift",
        "        if before.isFollowing == false {\n"
        "            recordPresentationFullDamage()\n",
        "        if before.isFollowing == false {\n"
        "            t5Counters.fullFromNotFollowingBefore += 1\n"
        "            recordPresentationFullDamage()\n",
    ),
    (
        "Terminal.swift",
        "              before.isAlternateScreenActive == after.isAlternateScreenActive\n"
        "        else {\n"
        "            recordPresentationFullDamage()\n",
        "              before.isAlternateScreenActive == after.isAlternateScreenActive\n"
        "        else {\n"
        "            t5Counters.fullFromTopRowOrScreenChange += 1\n"
        "            recordPresentationFullDamage()\n",
    ),
    (
        "Terminal.swift",
        "        if after.isFollowing == false {\n"
        "            recordPresentationFullDamage()\n",
        "        if after.isFollowing == false {\n"
        "            t5Counters.fullFromNotFollowingAfter += 1\n"
        "            recordPresentationFullDamage()\n",
    ),
    # The old drain-site injection (`rows.insert` into the public Set) is gone with the
    # representation: the drain builds no set at all, so the probe counts drained rows
    # from the drained value itself instead of patching the engine.
    (
        "RenderFramePlanner.swift",
        "                cells.append(cell)\n",
        "                t5Counters.plannerCellsInspected += 1\n"
        "                cells.append(cell)\n",
    ),
    (
        "RenderFramePlanner.swift",
        "            result[row] = cells\n",
        "            t5Counters.plannerRowsInspected += 1\n"
        "            result[row] = cells\n",
    ),
]


def instrument(scratch):
    """Copy both engine source trees into one flat directory and apply every injection."""
    sources = scratch / "engine"
    sources.mkdir()
    for tree in SOURCE_TREES:
        for path in sorted(tree.glob("*.swift")):
            destination = sources / path.name
            if destination.exists():
                raise SystemExit(f"source file name collides across trees: {path.name}")
            text = path.read_text(encoding="utf-8")
            # The two targets become one module here, and a module may not import itself.
            text = text.replace("import TerminalCore\n", "")
            destination.write_text(text, encoding="utf-8")
    for name, anchor, replacement in PATCHES:
        path = sources / name
        text = path.read_text(encoding="utf-8")
        occurrences = text.count(anchor)
        if occurrences != 1:
            raise SystemExit(
                f"instrumentation anchor matched {occurrences} times in {name}; "
                "the engine moved and this probe must be re-anchored:\n" + anchor
            )
        path.write_text(text.replace(anchor, replacement), encoding="utf-8")
    return sources


def build(scratch, sources):
    """Compile the probe, the counters, and the instrumented engine as one module."""
    main = scratch / "main.swift"
    shutil.copyfile(PROBE, main)
    counters = scratch / "t5-counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / "t5-scroll-amplification-probe"
    subprocess.run(
        [
            "swiftc",
            "-O",
            "-swift-version",
            "6",
            "-o",
            str(binary),
            str(main),
            str(counters),
            *(str(path) for path in sorted(sources.glob("*.swift"))),
        ],
        check=True,
    )
    return binary


def run(binary, events, requests):
    result = subprocess.run(
        [str(binary), str(events), *(f"{name}:{batch}" for name, batch in requests)],
        check=True,
        capture_output=True,
    )
    return json.loads(result.stdout)


def ratio(numerator, denominator):
    return f"{numerator / denominator:.1f}x" if denominator else "n/a"


def render(report):
    rows = report["viewportRows"]
    lines = [
        f"grid {report['columns']}x{rows}, line width {report['lineWidth']}",
        "",
        f"{'scenario':<24}{'lines/dlv':>10}{'dlv':>6}{'frames':>8}{'full':>6}{'shift':>7}"
        f"{'rows/f':>8}{'ideal/f':>9}{'rowAmp':>8}{'foldRows/f':>11}"
        f"{'glyphs/f':>10}{'idealG/f':>10}{'glyphAmp':>10}",
    ]
    for scenario in report["scenarios"]:
        frames = scenario["publishedFrames"]
        per = lambda key: scenario[key] / frames if frames else 0.0  # noqa: E731
        lines.append(
            f"{scenario['name']:<24}"
            f"{scenario['linesPerDelivery']:>10}"
            f"{scenario['deliveries']:>6}"
            f"{frames:>8}"
            f"{scenario['fullDamageFrames']:>6}"
            f"{scenario['shiftFrames']:>7}"
            f"{per('damagedRows'):>8.1f}"
            f"{per('idealDamagedRows'):>9.1f}"
            f"{ratio(scenario['damagedRows'], scenario['idealDamagedRows']):>8}"
            f"{per('foldedDamagedRows'):>11.1f}"
            f"{per('submittedGlyphOccurrences'):>10.0f}"
            f"{per('idealGlyphOccurrences'):>10.0f}"
            f"{ratio(scenario['submittedGlyphOccurrences'], scenario['idealGlyphOccurrences']):>10}"
        )
    lines.append("")
    lines.append(
        f"{'scenario':<24}{'lines/dlv':>10}{'scrollDlv':>10}{'fullCalls':>10}{'fullEscal':>10}"
        f"{'topRow/scr':>11}{'otherSite':>10}{'drainIns':>9}"
        f"{'planRows/f':>11}{'planCells/f':>12}"
    )
    for scenario in report["scenarios"]:
        frames = scenario["publishedFrames"]
        per = lambda key: scenario[key] / frames if frames else 0.0  # noqa: E731
        named = (
            scenario["fullFromNotFollowingBefore"]
            + scenario["fullFromTopRowOrScreenChange"]
            + scenario["fullFromNotFollowingAfter"]
        )
        lines.append(
            f"{scenario['name']:<24}"
            f"{scenario['linesPerDelivery']:>10}"
            f"{scenario['scrollingDeliveries']:>10}"
            f"{scenario['fullDamageCalls']:>10}"
            f"{scenario['fullDamageEscalations']:>10}"
            f"{scenario['fullFromTopRowOrScreenChange']:>11}"
            f"{scenario['fullDamageCalls'] - named:>10}"
            f"{scenario['drainRowInserts']:>9}"
            f"{per('plannerRowsInspected'):>11.1f}"
            f"{per('plannerCellsInspected'):>12.0f}"
        )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events", type=int, default=600, help="stimulus events per scenario")
    parser.add_argument("--json", action="store_true", help="print the raw report")
    arguments = parser.parse_args()

    requests = [(name, batch) for batch in BATCHES for name in SCENARIOS]
    with tempfile.TemporaryDirectory(prefix="t5-scroll-amplification-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch, instrument(scratch))
        report = run(binary, arguments.events, requests)

    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
