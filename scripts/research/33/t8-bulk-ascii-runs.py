#!/usr/bin/env python3
"""Research doc 33, task T8: gate the bulk printable-ASCII run print path.

`T8` makes a maximal run of printable ASCII cost one pass of the bookkeeping the print path
used to pay per character. `F10` measured that bookkeeping before the change; this script
measures it on both sides of the change in one command, so the collapse is a before/after
reading rather than a prediction compared against a memory.

Two arms, both instrumented identically. The **before** arm is a detached worktree at
`--baseline`; the **after** arm is this working tree. Each arm's engine sources are copied to
scratch, one counter increment is injected at each named site, and the copy is compiled `-O`
as one module with the probe. No arm's working tree is ever edited.

Three claims, and the script says for each one whether it is measured or structural:

1. **Equivalence (measured, and a hard gate).** Both arms must consume exactly the same number
   of printed characters per corpus, and land on the same cursor, the same scrollback depth and
   the same screen text. `T8` changes the granularity of the work, not its result, so any
   movement here is a regression rather than a result. The behavioral proof is the suite --
   `TerminalASCIIRunTests` plus the 67-fixture chunk-invariance replay that splits feeds at
   7 bytes; this is the corroboration that costs nothing.
2. **The bookkeeping collapses (measured, and a hard gate).** Every site `F10` counted --
   `terminalUnicodeClassification`, `invalidateInspection`, `rememberOpenCluster`, the
   content-identity allocation, `currentStyleId`, and `feed`'s damage snapshot and diff -- must
   fall. A site that rises is `T8` failing, not `T8` costing less than hoped.
3. **The run length is F10's (measured, diagnostic).** `F10` predicted the collapse from a
   state machine over the byte stream, cutting where `T8` said it would cut. The real
   implementation cuts in at least as many places, so the measured factor is expected at or
   below the predicted one -- `F10` said so itself. This is printed beside the prediction as a
   diagnostic and issues no verdict: a shortfall here means the prediction was optimistic about
   the cut rules, which is a finding, not a failure.

No timing is taken. `just benchmark-confirm` is what decides direction, and `T8` carries `T7`
(`D5`), so the pair's verdict comes from there rather than from here.
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
PROBE = HERE / "t8-bulk-ascii-runs-probe.swift"
COUNTERS = HERE / "t8-bulk-ascii-runs-counters.swift"

# `F10`'s table, verbatim: the bookkeeping units per corpus before `T8`, and the units its
# state machine predicted would remain after. Comparing against a literal rather than against
# the before arm alone is deliberate -- a change that moved both arms together would still be
# caught on the way past.
F10 = {
    "scrollback-stream": {"prints": 1_500_000, "predictedUnits": 41_665},
    "styled-screen-redraw": {"prints": 4_189_500, "predictedUnits": 150_500},
    "unicode-wrapping": {"prints": 1_305_000, "predictedUnits": 147_537},
    "incremental-screen-updates": {"prints": 2_500_025, "predictedUnits": 300_001},
    "synchronized-frames": {"prints": 762_108, "predictedUnits": 197_879},
}

# Counters that must not rise. Each is a site `F10` counted once per printed character.
COLLAPSING_COUNTERS = [
    "bookkeepingUnits",
    "unicodeClassificationCalls",
    "invalidateInspectionCalls",
    "rememberOpenClusterCalls",
    "searchMatchCacheInvalidations",
    "damageActionSnapshotConstructions",
    "damageDiffs",
    "contentIdentityAllocationSites",
    "currentStyleIdCalls",
]

# Fields that must match exactly between the arms.
EQUIVALENCE_FIELDS = [
    "printedCharacters",
    "cursorRow",
    "cursorColumn",
    "scrollbackRowCount",
    "screenTextHash",
]

# (file, anchor, replacement). The anchor is the unmodified text at the site; the replacement is
# that same text with one counter increment added. Each anchor must occur exactly once in its
# file, so a source change that moves a site fails the run loudly instead of miscounting.
SHARED_PATCHES = [
    (
        "UnicodeProperties.generated.swift",
        "    let record = GeneratedPackedUnicodeTables.record(for: scalar.value)\n",
        "    t8Counters.unicodeClassificationCalls += 1\n"
        "    let record = GeneratedPackedUnicodeTables.record(for: scalar.value)\n",
    ),
    (
        "Terminal.swift",
        "    private var damageActionSnapshot: DamageActionSnapshot {\n"
        "        let projection = scrollProjection\n",
        "    private var damageActionSnapshot: DamageActionSnapshot {\n"
        "        t8Counters.damageActionSnapshotConstructions += 1\n"
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
        "        t8Counters.damageDiffs += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func notePrimaryHistoryDamage() {\n",
        "    private mutating func notePrimaryHistoryDamage() {\n"
        "        t8Counters.searchMatchCacheInvalidations += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func invalidateInspection(inViewportRows range: Range<Int>) {\n",
        "    private mutating func invalidateInspection(inViewportRows range: Range<Int>) {\n"
        "        t8Counters.invalidateInspectionCalls += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func rememberOpenCluster() {\n",
        "    private mutating func rememberOpenCluster() {\n"
        "        t8Counters.rememberOpenClusterCalls += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func allocateContentIdentity() -> ContentIdentity {\n",
        "    private mutating func allocateContentIdentity() -> ContentIdentity {\n"
        "        t8Counters.contentIdentityAllocationSites += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func currentStyleId() -> StyleId {\n"
        "        if let currentStyleIdCache { return currentStyleIdCache }\n",
        "    private mutating func currentStyleId() -> StyleId {\n"
        "        t8Counters.currentStyleIdCalls += 1\n"
        "        if let currentStyleIdCache { return currentStyleIdCache }\n"
        "        t8Counters.currentStyleIdMisses += 1\n",
    ),
    (
        "Terminal.swift",
        "    private mutating func print(_ scalar: Unicode.Scalar) {\n"
        "        let classification = terminalUnicodeClassification(for: scalar)\n",
        "    private mutating func print(_ scalar: Unicode.Scalar) {\n"
        "        t8Counters.observePrintedCharacter()\n"
        "        let classification = terminalUnicodeClassification(for: scalar)\n",
    ),
]

# Only the after arm has a bulk path, so only it carries these. The before arm's run counters
# stay zero, which is what makes its `bookkeepingUnits` exactly its printed-character count.
AFTER_ONLY_PATCHES = [
    (
        "Terminal.swift",
        "            let taken = printBulkASCII(bytes, from: index, limit: range.upperBound)\n",
        "            let taken = printBulkASCII(bytes, from: index, limit: range.upperBound)\n"
        "            t8Counters.observeBulkRun(taken)\n",
    ),
    (
        "Terminal.swift",
        "        let baseIdentity = nextContentIdentity\n",
        "        t8Counters.contentIdentityAllocationSites += 1\n"
        "        let baseIdentity = nextContentIdentity\n",
    ),
]


def git(*arguments, cwd=ROOT):
    return subprocess.run(
        ["git", *arguments], cwd=str(cwd), check=True, capture_output=True, text=True
    ).stdout.strip()


def remove_worktree(path):
    subprocess.run(
        ["git", "worktree", "remove", "--force", str(path)], cwd=str(ROOT), capture_output=True
    )


def instrument(scratch, arm_root, label, patches):
    """Copy one arm's engine sources and apply every anchored counter injection."""
    sources = scratch / f"{label}-TerminalCore"
    shutil.copytree(arm_root / "lib/TerminalCore/Sources/TerminalCore", sources)
    for name, anchor, replacement in patches:
        path = sources / name
        text = path.read_text(encoding="utf-8")
        occurrences = text.count(anchor)
        if occurrences != 1:
            raise SystemExit(
                f"[{label}] instrumentation anchor matched {occurrences} times in {name}; "
                "the engine moved and this probe must be re-anchored:\n" + anchor
            )
        path.write_text(text.replace(anchor, replacement), encoding="utf-8")
    return sources


def build(scratch, sources, label):
    """Compile the probe, the counters, and one instrumented engine copy as one module."""
    # `main.swift` by name, not by convention: top-level statements are only legal in a file
    # called that, so each arm gets its own directory rather than a distinguishing suffix.
    stage = scratch / f"{label}-probe"
    stage.mkdir()
    main = stage / "main.swift"
    shutil.copyfile(PROBE, main)
    counters = stage / "counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = scratch / f"t8-probe-{label}"
    subprocess.run(
        ["swiftc", "-O", "-swift-version", "6", "-o", str(binary), str(main), str(counters),
         *(str(path) for path in sorted(sources.glob("*.swift")))],
        check=True,
    )
    return binary


def frame(scratch, name, workload):
    """Write one corpus in the phase-and-length framing the probe reads."""
    path = scratch / f"{name}.framed"
    path.write_bytes(frame_chunks(iter_bytes(ROOT, workload)))
    return path


def run_probe(binary, framed):
    result = subprocess.run(
        [str(binary), *(f"{name}={path}" for name, path in framed)],
        check=True, capture_output=True,
    )
    return {entry["name"]: entry for entry in json.loads(result.stdout)["corpora"]}


def ratio(before, after):
    return f"{before / after:>6.1f}x" if after else "     --"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline", default="63c693da", help="revision the before arm is built from"
    )
    parser.add_argument("--json", action="store_true", help="print the raw two-arm report")
    arguments = parser.parse_args()

    failures = []
    corpus = load_corpus(ROOT)

    with tempfile.TemporaryDirectory(prefix="t8-bulk-ascii-") as directory:
        scratch = pathlib.Path(directory)
        baseline = scratch / "baseline"
        try:
            git("worktree", "add", "--detach", str(baseline), arguments.baseline)
            before_sources = instrument(scratch, baseline, "before", SHARED_PATCHES)
            after_sources = instrument(
                scratch, ROOT, "after", SHARED_PATCHES + AFTER_ONLY_PATCHES
            )
            framed = [(name, frame(scratch, name, workload)) for name, workload in corpus.items()]
            before = run_probe(build(scratch, before_sources, "before"), framed)
            after = run_probe(build(scratch, after_sources, "after"), framed)
        finally:
            remove_worktree(baseline)

    if arguments.json:
        print(json.dumps({"before": before, "after": after}, indent=2, sort_keys=True))
        return 0

    print(f"before arm: {arguments.baseline}    after arm: working tree")
    print()
    print("== claim 1 (measured, gate): both arms consume the same input to the same state ==")
    for name in corpus:
        mismatches = [
            f"{field} {before[name][field]:,} vs {after[name][field]:,}"
            for field in EQUIVALENCE_FIELDS
            if before[name][field] != after[name][field]
        ]
        status = "same" if not mismatches else "DIFFERS: " + "; ".join(mismatches)
        print(f"  {name:<28}{before[name]['printedCharacters']:>12,} characters   {status}")
        failures += [f"{name}: {entry}" for entry in mismatches]
        expected = F10.get(name, {}).get("prints")
        if expected is not None and before[name]["printedCharacters"] != expected:
            message = (
                f"{name}: before arm printed {before[name]['printedCharacters']:,} characters, "
                f"F10 recorded {expected:,}"
            )
            print(f"    {message}")
            failures.append(message)

    print()
    print("== claim 2 (measured, gate): every per-character site falls ==")
    header = f"  {'corpus':<28}{'counter':<34}{'before':>12}{'after':>12}{'factor':>9}"
    print(header)
    for name in corpus:
        for counter in COLLAPSING_COUNTERS:
            b, a = before[name][counter], after[name][counter]
            print(f"  {name:<28}{counter:<34}{b:>12,}{a:>12,}{ratio(b, a):>9}")
            if a > b:
                message = f"{name}: {counter} rose from {b:,} to {a:,}"
                failures.append(message)
        print()

    print("== claim 3 (measured, diagnostic): run length against F10's prediction ==")
    print(
        f"  {'corpus':<28}{'runs':>10}{'in runs':>12}{'mean':>8}{'longest':>9}"
        f"{'declined':>10}{'units':>10}{'F10 units':>11}{'factor':>9}{'F10':>7}"
    )
    for name in corpus:
        entry = after[name]
        predicted = F10.get(name, {}).get("predictedUnits", 0)
        units = entry["bookkeepingUnits"]
        characters = before[name]["printedCharacters"]
        print(
            f"  {name:<28}{entry['bulkRuns']:>10,}{entry['bulkCharacters']:>12,}"
            f"{entry['meanBulkRunLength']:>8.1f}{entry['longestBulkRun']:>9,}"
            f"{entry['declinedBulkAttempts']:>10,}{units:>10,}{predicted:>11,}"
            f"{characters / units if units else 0:>8.1f}x"
            f"{characters / predicted if predicted else 0:>6.1f}x"
        )
    print("  No verdict here by construction: F10 predicted from the byte stream, and the")
    print("  implementation cuts in at least as many places, so at-or-below is the expectation.")

    print()
    print("VERDICT on claims 1-2: " + ("PASS" if not failures else f"FAIL ({len(failures)})"))
    for failure in failures:
        print(f"  {failure}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
