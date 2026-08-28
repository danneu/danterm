#!/usr/bin/env python3
"""Research doc 33, task T2: count the per-printed-cell bookkeeping.

Copies `lib/TerminalCore/Sources/TerminalCore` into a scratch directory, injects one
counter increment at each bookkeeping site T2 names, compiles the copy as a single
optimized module with the probe, and reports per corpus how often each site runs against
how many printed characters and how many bulk-printable ASCII runs those characters form.

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

from terminal_benchmark_fixtures import frame_chunks, iter_bytes, load_corpus  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t2-print-bookkeeping-probe.swift"
COUNTERS = HERE / "t2-print-bookkeeping-counters.swift"
ENGINE_SOURCES = ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCore"

# (file, anchor, replacement). The anchor is the unmodified text at the site; the
# replacement is that same text with one counter increment added. Each anchor must occur
# exactly once in its file.
PATCHES = [
    (
        "UnicodeProperties.generated.swift",
        "    let record = GeneratedPackedUnicodeTables.record(for: scalar.value)\n",
        "    t2Counters.unicodeClassificationCalls += 1\n"
        "    let record = GeneratedPackedUnicodeTables.record(for: scalar.value)\n",
    ),
    (
        "Terminal.swift",
        "    private var damageActionSnapshot: DamageActionSnapshot {\n"
        "        let projection = scrollProjection\n",
        "    private var damageActionSnapshot: DamageActionSnapshot {\n"
        "        t2Counters.damageActionSnapshotConstructions += 1\n"
        "        let projection = scrollProjection\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func recordDamage(\n"
        "        from before: DamageActionSnapshot,\n"
        "        to after: DamageActionSnapshot\n"
        "    ) {\n",
        "    private mutating func recordDamage(\n"
        "        from before: DamageActionSnapshot,\n"
        "        to after: DamageActionSnapshot\n"
        "    ) {\n"
        "        t2Counters.damageDiffs += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func notePrimaryHistoryDamage() {\n",
        "    private mutating func notePrimaryHistoryDamage() {\n"
        "        t2Counters.searchMatchCacheInvalidations += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func invalidateInspection(inViewportRows range: Range<Int>) {\n",
        "    private mutating func invalidateInspection(inViewportRows range: Range<Int>) {\n"
        "        t2Counters.invalidateInspectionCalls += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func print(_ scalar: Unicode.Scalar) {\n"
        "        let classification = terminalUnicodeClassification(for: scalar)\n",
        "    private mutating func print(_ scalar: Unicode.Scalar) {\n"
        "        t2Counters.observePrint(\n"
        "            scalar: scalar,\n"
        "            row: cursor.row,\n"
        "            column: cursor.column,\n"
        "            isInsertMode: isInsertMode,\n"
        "            isPendingWrap: isPendingWrap,\n"
        "            overwritesWideOrSpacer: t2CellBlocksRun(\n"
        "                rows[cursor.row].cell(at: cursor.column).kind\n"
        "            )\n"
        "        )\n"
        "        let classification = terminalUnicodeClassification(for: scalar)\n",
    ),
    (
        "Terminal.swift",
        "        if isPendingWrap {\n"
        "            invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))\n"
        "            softWrap()\n",
        "        if isPendingWrap {\n"
        "            t2Counters.invalidateInspectionFromPendingWrap += 1\n"
        "            invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))\n"
        "            softWrap()\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func rememberOpenCluster() {\n",
        "    private mutating func rememberOpenCluster() {\n"
        "        t2Counters.rememberOpenClusterCalls += 1\n",
    ),
    (
        "Terminal.swift",
        "        let contentIdentity = allocateContentIdentity()\n"
        "        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))\n"
        "        if isInsertMode {\n",
        "        let contentIdentity = allocateContentIdentity()\n"
        "        t2Counters.invalidateInspectionFromPrintNarrow += 1\n"
        "        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))\n"
        "        if isInsertMode {\n",
    ),
    (
        "Terminal.swift",
        "        let contentIdentity = allocateContentIdentity()\n"
        "        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))\n"
        "        var preservesWrappedSpacer = false\n",
        "        let contentIdentity = allocateContentIdentity()\n"
        "        t2Counters.invalidateInspectionFromPrintWide += 1\n"
        "        invalidateInspection(inViewportRows: cursor.row..<(cursor.row + 1))\n"
        "        var preservesWrappedSpacer = false\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func allocateContentIdentity() -> ContentIdentity {\n",
        "    private mutating func allocateContentIdentity() -> ContentIdentity {\n"
        "        t2Counters.contentIdentityAllocations += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func currentStyleId() -> StyleId {\n"
        "        if let currentStyleIdCache { return currentStyleIdCache }\n",
        "    private mutating func currentStyleId() -> StyleId {\n"
        "        t2Counters.currentStyleIdCalls += 1\n"
        "        if let currentStyleIdCache { return currentStyleIdCache }\n"
        "        t2Counters.currentStyleIdMisses += 1\n",
    ),
    (
        "Terminal.swift",
        "        for action in actions {\n            switch action {\n",
        "        for action in actions {\n"
        "            if case .print = action {} else { t2Counters.observeNonPrintAction() }\n"
        "            switch action {\n",
    ),
]


def instrument(scratch):
    """Copy the engine sources and apply every anchored counter injection."""
    sources = scratch / "TerminalCore"
    shutil.copytree(ENGINE_SOURCES, sources)
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
    counters = scratch / "t2-counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / "t2-print-bookkeeping-probe"
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
    """Write one corpus in the phase-and-length framing the probe reads."""
    path = scratch / f"{name}.framed"
    path.write_bytes(frame_chunks(iter_bytes(ROOT, workload)))
    return path


def render(report):
    lines = [
        f"{'corpus':<28}{'bytes':>10}{'prints':>10}{'classify':>10}{'invalid':>10}"
        f"{'remember':>10}{'cacheInv':>10}{'snapshot':>10}{'ident':>10}{'styleId':>10}",
    ]
    for corpus in report["corpora"]:
        lines.append(
            f"{corpus['name']:<28}"
            f"{corpus['byteCount']:>10}"
            f"{corpus['printCalls']:>10}"
            f"{corpus['unicodeClassificationCalls']:>10}"
            f"{corpus['invalidateInspectionCalls']:>10}"
            f"{corpus['rememberOpenClusterCalls']:>10}"
            f"{corpus['searchMatchCacheInvalidations']:>10}"
            f"{corpus['damageActionSnapshotConstructions']:>10}"
            f"{corpus['contentIdentityAllocations']:>10}"
            f"{corpus['currentStyleIdCalls']:>10}"
        )
    lines.append("")
    lines.append(
        f"{'corpus':<28}{'prints':>10}{'runs':>10}{'runPrints':>11}{'mean':>8}"
        f"{'longest':>9}{'unitsAfter':>12}{'factor':>9}{'snapAfter':>11}{'snapFactor':>12}"
    )
    for corpus in report["corpora"]:
        after = corpus["predictedUnitsAfterBulkRuns"]
        factor = corpus["printCalls"] / after if after else 0
        snapshots = corpus["damageActionSnapshotConstructions"]
        snapshotsAfter = corpus["predictedSnapshotsAfterBulkRuns"]
        snapshotFactor = snapshots / snapshotsAfter if snapshotsAfter else 0
        lines.append(
            f"{corpus['name']:<28}"
            f"{corpus['printCalls']:>10}"
            f"{corpus['asciiRuns']:>10}"
            f"{corpus['asciiRunPrints']:>11}"
            f"{corpus['meanAsciiRunLength']:>8.1f}"
            f"{corpus['longestAsciiRun']:>9}"
            f"{after:>12}"
            f"{factor:>9.1f}"
            f"{snapshotsAfter:>11}"
            f"{snapshotFactor:>12.1f}"
        )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the raw report")
    arguments = parser.parse_args()

    corpus = load_corpus(ROOT)
    with tempfile.TemporaryDirectory(prefix="t2-print-bookkeeping-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch, instrument(scratch))
        framed = [(name, frame(scratch, name, workload)) for name, workload in corpus.items()]
        result = subprocess.run(
            [str(binary), *(f"{name}={path}" for name, path in framed)],
            check=True,
            capture_output=True,
        )
        report = json.loads(result.stdout)

    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
