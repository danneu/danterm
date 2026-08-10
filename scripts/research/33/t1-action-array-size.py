#!/usr/bin/env python3
"""Research doc 33, task T1: size the parser's intermediate action array in situ.

Frames each committed benchmark corpus exactly as the `terminal-feed` workload does,
feeds it through the real `TerminalInputStream.feed`, and reports per corpus the token
count, the peak `[TerminalStreamAction]` capacity, the total bytes handed to the
allocator for that array, and the reallocation count.

The probe is compiled into one module with the unmodified engine sources, so it reaches
the internal parser without any edit to `lib/TerminalCore`. Nothing here is on a
production path.
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

PROBE = pathlib.Path(__file__).resolve().parent / "t1-action-array-probe.swift"
ENGINE_SOURCES = ROOT / "lib" / "TerminalCore" / "Sources" / "TerminalCore"
# The PTY host reads and feeds at most 16 KiB per turn, so this is the delivery size the
# live app actually hands the parser. The corpus's own framing is the other run, because
# that is what `terminal-feed` measures.
PTY_TURN_LIMIT = 16 * 1024


def build(scratch):
    """Compile the probe together with the engine sources as a single optimized module."""
    main = scratch / "main.swift"
    shutil.copyfile(PROBE, main)
    binary = scratch / "t1-action-array-probe"
    sources = sorted(ENGINE_SOURCES.glob("*.swift"))
    subprocess.run(
        [
            "swiftc",
            "-O",
            "-swift-version",
            "6",
            "-o",
            str(binary),
            str(main),
            *(str(path) for path in sources),
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
    lines = [
        f"TerminalStreamAction: size {report['actionSize']}, stride {report['actionStride']}",
        "array growth capacities: "
        + ", ".join(str(capacity) for capacity in report["growthCapacities"][:12])
        + (" ..." if len(report["growthCapacities"]) > 12 else ""),
        "",
    ]
    for run_report in report["runs"]:
        limit = run_report["chunkLimit"]
        if limit == 0:
            label = "corpus framing"
        elif limit < 0:
            label = "single-shot feed (whole corpus in one call)"
        else:
            label = f"{limit}-byte chunk cap"
        lines.append(f"== {label} ==")
        lines.append(
            f"{'corpus':<28}{'feeds':>7}{'bytes':>12}{'tokens':>12}{'tok/byte':>10}"
            f"{'peak cap':>10}{'peak KB':>9}{'alloc MB':>10}{'reallocs':>10}{'bad cap':>9}"
        )
        for corpus in run_report["corpora"]:
            lines.append(
                f"{corpus['name']:<28}"
                f"{corpus['feedCalls']:>7}"
                f"{corpus['byteCount']:>12}"
                f"{corpus['tokenCount']:>12}"
                f"{corpus['tokensPerByte']:>10.3f}"
                f"{corpus['peakCapacity']:>10}"
                f"{corpus['peakLiveBytes'] / 1024:>9.1f}"
                f"{corpus['totalBytesAllocated'] / 1_000_000:>10.2f}"
                f"{corpus['reallocationCount']:>10}"
                f"{corpus['capacityMismatches']:>9}"
            )
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the raw report")
    arguments = parser.parse_args()

    corpus = load_corpus(ROOT)
    with tempfile.TemporaryDirectory(prefix="t1-action-array-") as directory:
        scratch = pathlib.Path(directory)
        binary = build(scratch)
        framed = [(name, frame(scratch, name, workload)) for name, workload in corpus.items()]
        runs = []
        merged = None
        for limit in (0, PTY_TURN_LIMIT, -1):
            report = run(binary, limit, framed)
            runs.extend(report["runs"])
            merged = report
        merged["runs"] = runs

    if arguments.json:
        print(json.dumps(merged, indent=2, sort_keys=True))
    else:
        print(render(merged))

    mismatches = sum(
        corpus_report["capacityMismatches"]
        for run_report in merged["runs"]
        for corpus_report in run_report["corpora"]
    )
    if mismatches:
        print(f"FAIL: {mismatches} feed calls disagreed with the replayed growth table")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
