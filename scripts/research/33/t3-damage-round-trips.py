#!/usr/bin/env python3
"""Research doc 33, task T3: count the damage representation's round trips per frame.

RETIRED by T9/T20 (research/33 D7): the sites this script counted -- the drain's
Set<Int> construction, `init(rows:)`'s sanitizer, `formUnion`'s set union, the
span sort -- were deleted with the word-backed shift-carrying representation, so
the anchors below no longer match and this script fails loudly by design. Its
successor is t9-shift-damage-structure.sh (structural absence) plus
t5-scroll-amplification.py (per-frame sizing). The F11 numbers this produced
remain the pre-change baseline.

Copies `lib/TerminalCore/Sources/TerminalCore` and `.../TerminalRenderPlanning` into a
scratch directory, injects one counter increment at each site on the damage path, compiles
the copy as a single optimized module with the probe, and reports per corpus what one
published frame costs: damaged rows, `Set<Int>` and array allocations, hash operations, and
whether the rows the span coalescer sorted were already in ascending order.

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
sys.path.insert(0, str(ROOT / "scripts"))

from terminal_benchmark_fixtures import iter_bytes, load_corpus  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t3-damage-round-trips-probe.swift"
COUNTERS = HERE / "t3-damage-round-trips-counters.swift"
SOURCE_TREES = [
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCore",
    ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalRenderPlanning",
]
# The PTY host reads and feeds at most 16 KiB per turn, so a delivery -- and therefore a
# frame -- is that large live. The corpus's own framing is the other run because it is what
# `terminal-feed` measures, and it brackets the answer from the many-small-frames side.
PTY_TURN_LIMIT = 16 * 1024

# (file, anchor, replacement). The anchor is the unmodified text at the site; the
# replacement is that same text with one counter increment added. Each anchor must occur
# exactly once in its file.
PATCHES = [
    (
        "TerminalDamage.swift",
        "    public init(rows: Set<Int>) {\n        isFull = false\n",
        "    public init(rows: Set<Int>) {\n"
        "        isFull = false\n"
        "        t3Counters.noteDamageInit(rowCount: rows.count)\n",
    ),
    (
        "TerminalDamage.swift",
        "            rows.formUnion(other.rows)\n",
        "            t3Counters.noteFormUnion(rowCount: other.rows.count)\n"
        "            rows.formUnion(other.rows)\n",
    ),
    (
        "TerminalDamage.swift",
        "    mutating func drain() -> TerminalDamage {\n        if isFull {\n",
        "    mutating func drain() -> TerminalDamage {\n"
        "        t3Counters.drainCalls += 1\n"
        "        if isFull {\n"
        "            t3Counters.drainFullCalls += 1\n",
    ),
    (
        "TerminalDamage.swift",
        "        var rows = Set<Int>()\n",
        "        t3Counters.noteDrainSet()\n        var rows = Set<Int>()\n",
    ),
    (
        "TerminalDamage.swift",
        "                rows.insert(wordIndex * 64 + bit)\n",
        "                t3Counters.drainRowInserts += 1\n"
        "                rows.insert(wordIndex * 64 + bit)\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func recordPresentationFullDamage() {\n"
        "        if damage.recordFull() { pendingConsumerWork.noteDamageChanged() }\n",
        "    private mutating func recordPresentationFullDamage() {\n"
        "        t3Counters.fullDamageCalls += 1\n"
        "        if damage.recordFull() {\n"
        "            t3Counters.fullDamageEscalations += 1\n"
        "            pendingConsumerWork.noteDamageChanged()\n"
        "        }\n",
    ),
    (
        "Terminal.swift",
        "        if before.isFollowing == false {\n"
        "            recordPresentationFullDamage()\n",
        "        if before.isFollowing == false {\n"
        "            t3Counters.fullFromNotFollowingBefore += 1\n"
        "            recordPresentationFullDamage()\n",
    ),
    (
        "Terminal.swift",
        "              before.isAlternateScreenActive == after.isAlternateScreenActive\n"
        "        else {\n"
        "            recordPresentationFullDamage()\n",
        "              before.isAlternateScreenActive == after.isAlternateScreenActive\n"
        "        else {\n"
        "            t3Counters.fullFromTopRowOrScreenChange += 1\n"
        "            recordPresentationFullDamage()\n",
    ),
    (
        "Terminal.swift",
        "        if after.isFollowing == false {\n"
        "            recordPresentationFullDamage()\n",
        "        if after.isFollowing == false {\n"
        "            t3Counters.fullFromNotFollowingAfter += 1\n"
        "            recordPresentationFullDamage()\n",
    ),
    (
        "TerminalDamageSpans.swift",
        "    guard rowCount > 0 else { return [] }\n    var expanded: Set<Int> = []\n",
        "    guard rowCount > 0 else { return [] }\n"
        "    t3Counters.noteHalo()\n"
        "    var expanded: Set<Int> = []\n",
    ),
    (
        "TerminalDamageSpans.swift",
        "    for row in rows where row >= 0 && row < rowCount {\n",
        "    for row in rows where row >= 0 && row < rowCount {\n"
        "        t3Counters.haloRowInserts += 3\n",
    ),
    (
        "TerminalDamageSpans.swift",
        "public func terminalDamageMaximalContiguousSpans(_ rows: Set<Int>) -> [Range<Int>] {\n"
        "    let sortedRows = rows.sorted()\n",
        "public func terminalDamageMaximalContiguousSpans(_ rows: Set<Int>) -> [Range<Int>] {\n"
        "    t3Counters.noteSpanSort(rows)\n"
        "    let sortedRows = rows.sorted()\n",
    ),
    (
        "RenderFramePlanner.swift",
        "            replanning: { reusable == nil || damage.rows.contains($0) },\n",
        "            replanning: {\n"
        "                if reusable == nil { return true }\n"
        "                t3Counters.plannerPredicateCalls += 1\n"
        "                return damage.rows.contains($0)\n"
        "            },\n",
    ),
    (
        "RenderFramePlanner.swift",
        "        for row in 0..<rowCount {\n"
        "            if let reusable, damage.rows.contains(row) == false {\n",
        "        for row in 0..<rowCount {\n"
        "            if reusable != nil { t3Counters.plannerRowCopyLookups += 1 }\n"
        "            if let reusable, damage.rows.contains(row) == false {\n",
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
    counters = scratch / "t3-counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / "t3-damage-round-trips-probe"
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


def frame(scratch, name, workload):
    """Write one corpus in the 8-byte big-endian length framing the probe reads."""
    path = scratch / f"{name}.framed"
    with path.open("wb") as handle:
        for chunk in iter_bytes(ROOT, workload):
            handle.write(len(chunk).to_bytes(8, byteorder="big"))
            handle.write(chunk)
    return path


def run(binary, limit, framed):
    result = subprocess.run(
        [str(binary), str(limit), *(f"{name}={path}" for name, path in framed)],
        check=True,
        capture_output=True,
    )
    return json.loads(result.stdout)


def render(report):
    lines = []
    for run_report in report["runs"]:
        limit = run_report["chunkLimit"]
        label = "corpus framing" if limit <= 0 else f"{limit}-byte delivery cap"
        lines.append(f"== {label} ==")
        lines.append(
            f"{'corpus':<28}{'feeds':>8}{'frames':>8}{'full':>6}{'held':>7}"
            f"{'rows/f':>8}{'maxRows':>8}{'sets/f':>8}{'arrays/f':>9}{'hashes/f':>9}"
        )
        for corpus in run_report["corpora"]:
            frames = corpus["publishedFrames"]
            per = (lambda key: corpus[key] / frames if frames else 0.0)
            lines.append(
                f"{corpus['name']:<28}"
                f"{corpus['feedCalls']:>8}"
                f"{frames:>8}"
                f"{corpus['fullDamageFrames']:>6}"
                f"{corpus['suppressedPublishes']:>7}"
                f"{per('damagedRows'):>8.1f}"
                f"{corpus['maximumDamagedRows']:>8}"
                f"{per('setAllocations'):>8.2f}"
                f"{per('arrayAllocations'):>9.2f}"
                f"{per('hashOperations'):>9.1f}"
            )
        lines.append("")
        lines.append(
            f"{'corpus':<28}{'drainIns':>10}{'initHash':>10}{'unionHash':>11}"
            f"{'haloIns':>10}{'planPred':>10}{'planCopy':>10}{'preHalo/f':>11}{'spans/f':>9}"
            f"{'sorted?':>18}{'inversions':>12}"
        )
        for corpus in run_report["corpora"]:
            calls = corpus["spanCalls"]
            ascending = corpus["spanSortAlreadyAscending"]
            lines.append(
                f"{corpus['name']:<28}"
                f"{corpus['drainRowInserts']:>10}"
                f"{corpus['damageInitRowHashes']:>10}"
                f"{corpus['formUnionRowHashes']:>11}"
                f"{corpus['haloRowInserts']:>10}"
                f"{corpus['plannerPredicateCalls']:>10}"
                f"{corpus['plannerRowCopyLookups']:>10}"
                f"{(corpus['spansBeforeHalo'] / calls if calls else 0):>11.2f}"
                f"{(corpus['spansEmitted'] / calls if calls else 0):>9.2f}"
                f"{f'{ascending}/{calls}':>18}"
                f"{corpus['spanSortInversions']:>12}"
            )
        lines.append("")
        lines.append(
            f"{'corpus':<28}{'fullCalls':>11}{'fullEscal':>11}{'notFollowBefore':>17}"
            f"{'topRowOrScreen':>16}{'notFollowAfter':>16}{'otherSite':>11}"
        )
        for corpus in run_report["corpora"]:
            named = (
                corpus["fullFromNotFollowingBefore"]
                + corpus["fullFromTopRowOrScreenChange"]
                + corpus["fullFromNotFollowingAfter"]
            )
            lines.append(
                f"{corpus['name']:<28}"
                f"{corpus['fullDamageCalls']:>11}"
                f"{corpus['fullDamageEscalations']:>11}"
                f"{corpus['fullFromNotFollowingBefore']:>17}"
                f"{corpus['fullFromTopRowOrScreenChange']:>16}"
                f"{corpus['fullFromNotFollowingAfter']:>16}"
                f"{corpus['fullDamageCalls'] - named:>11}"
            )
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the raw report")
    arguments = parser.parse_args()

    corpus = load_corpus(ROOT)
    with tempfile.TemporaryDirectory(prefix="t3-damage-round-trips-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch, instrument(scratch))
        framed = [(name, frame(scratch, name, workload)) for name, workload in corpus.items()]
        runs = []
        for limit in (PTY_TURN_LIMIT, 0):
            runs.extend(run(binary, limit, framed)["runs"])
        report = {"runs": runs}

    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
