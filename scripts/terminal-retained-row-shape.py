#!/usr/bin/env python3
"""Drive the retained-row shape probe over the committed stimulus corpus.

Doc 28's `F9` (blank-row frequency, sizing `H2`'s ceiling) and `F10` (allocator
behavior under ragged rows) both need one thing the Swift probe deliberately does
not own: real content. This driver supplies it from bytes that are already
committed and already used for other purposes -- the five benchmark-corpus
workloads, and every neutral recording under the TerminalCore test fixtures --
so nobody can shape a stimulus to flatter a hypothesis after the fact.

Recordings are replayed at the geometry they were recorded at, and generated
benchmark workloads at the benchmark geometry, because a blank-row frequency is a
property of content *at a width*. Feed events only: resize and mouse events are
skipped, and the count of skipped events is reported so a reader can see how much
of a recording was not replayed.

No threshold, no verdict, no pairing. This is a sizing measurement with one arm.
"""
import argparse
import base64
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / "lib" / "TerminalCore" / ".build" / "release" / "TerminalRetainedRowProbe"
RECORDING_DIRECTORIES = (
    "lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm",
    "lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/alacritty",
)
# The geometry the ladder's generated workloads are benchmarked at, so their row
# shapes are the ones every other doc-28 number describes.
BENCHMARK_COLUMNS = 179
BENCHMARK_ROWS = 66


def frame(chunks):
    """Length-frame chunks exactly as the Swift probe and benchmark both decode."""
    framed = bytearray()
    for chunk in chunks:
        framed.extend(len(chunk).to_bytes(8, byteorder="big"))
        framed.extend(chunk)
    return bytes(framed)


def recording_stimulus(path):
    """Read one neutral recording's feed bytes and its recorded geometry.

    Returns None for a recording with no feed events at all, which is a fixture
    that exercises something other than content and has nothing to contribute
    here.
    """
    document = json.loads(path.read_text(encoding="utf-8"))
    initial = document.get("initial") or {}
    columns, rows = initial.get("columns"), initial.get("rows")
    if not isinstance(columns, int) or not isinstance(rows, int):
        return None
    chunks, skipped = [], 0
    for event in document.get("events", []):
        if event.get("type") != "feed":
            skipped += 1
            continue
        encoded = event.get("base64")
        if encoded is None:
            # A recording that carries feed text in another encoding is outside
            # what this driver decodes; counting it as skipped keeps the report
            # honest rather than silently dropping content.
            skipped += 1
            continue
        chunks.append(base64.b64decode(encoded, validate=True))
    if not chunks:
        return None
    return {
        "stimulus": f"{path.parent.name}/{path.stem}",
        "kind": "recording",
        "columns": columns,
        "rows": rows,
        "chunks": chunks,
        "skippedEvents": skipped,
    }


def benchmark_stimuli(root):
    """Yield the committed benchmark-corpus workloads at the benchmark geometry."""
    sys.path.insert(0, str(root / "scripts"))
    from terminal_benchmark_fixtures import iter_bytes, load_corpus

    for name, workload in load_corpus(root).items():
        yield {
            "stimulus": f"benchmark/{name}",
            "kind": "benchmark",
            "columns": BENCHMARK_COLUMNS,
            "rows": BENCHMARK_ROWS,
            "chunks": list(iter_bytes(root, workload)),
            "skippedEvents": 0,
        }


def recording_stimuli(root):
    """Yield every neutral recording fixture that carries feed bytes."""
    for directory in RECORDING_DIRECTORIES:
        for path in sorted((root / directory).glob("*.json")):
            stimulus = recording_stimulus(path)
            if stimulus is not None:
                yield stimulus


# Lines of nothing but a newline, enough to saturate the production budget at the
# ~80-byte charge a canonical blank row carries.
BLANK_BOUND_LINE_COUNT = 200_000


def bound_stimuli():
    """Yield the one generated stimulus, and it is a bound rather than a sample.

    A history of nothing but blank lines is not realistic content and is not
    counted in either pool. It exists because `F9` is asked for `H2`'s ceiling in
    absolute bytes, and a ceiling has to be evaluated where the hypothesis is
    most favored -- the same way `F8` stated `H4`'s ceiling at zero per-row
    overhead, a condition nothing achieves either. Reported as `kind: bound` so no
    reader can mistake it for evidence about real sessions.
    """
    yield {
        "stimulus": "bound/all-blank-saturation",
        "kind": "bound",
        "columns": BENCHMARK_COLUMNS,
        "rows": BENCHMARK_ROWS,
        "chunks": [b"\r\n" * BLANK_BOUND_LINE_COUNT],
        "skippedEvents": 0,
    }


def reference_stimuli():
    """Yield `F8`'s payload, replicated so its per-row residual can be re-explained.

    `F8` measured 197.5 bytes of per-row overhead at 179 columns with the memory
    probe's `scrollback-plain` payload, and attributed it to an array header plus
    "roughly another 100-160 B" of size-class rounding -- stated there as a
    consistency check, explicitly not a measurement. Replaying the identical line
    format here turns that into arithmetic with a measured distribution behind it.
    The line is copied from `MemoryProbeMatrix.plainLine`; if the two ever drift,
    this stimulus stops reconciling and that is the signal to re-derive.
    """
    lines = b"".join(
        b"DANTERM-MEMORY-%05d plain ascii scrollback payload\r\n" % line
        for line in range(10_000)
    )
    yield {
        "stimulus": "reference/scrollback-plain",
        "kind": "reference",
        "columns": BENCHMARK_COLUMNS,
        "rows": BENCHMARK_ROWS,
        "chunks": [lines],
        "skippedEvents": 0,
    }


def iter_stimuli(root):
    """The whole corpus: benchmark workloads, recordings, then the two non-samples."""
    yield from benchmark_stimuli(root)
    yield from recording_stimuli(root)
    yield from reference_stimuli()
    yield from bound_stimuli()


def run_probe(stimulus, *, probe=PROBE, run=subprocess.run):
    """Invoke the probe once and return its report merged with driver metadata."""
    completed = run(
        [
            str(probe),
            "--columns", str(stimulus["columns"]),
            "--rows", str(stimulus["rows"]),
            "--stimulus", stimulus["stimulus"],
        ],
        input=frame(stimulus["chunks"]),
        capture_output=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"probe failed for {stimulus['stimulus']}: "
            f"{completed.stderr.decode(errors='replace').strip()}"
        )
    report = json.loads(completed.stdout)
    report["kind"] = stimulus["kind"]
    report["skippedEvents"] = stimulus["skippedEvents"]
    return report


def derive(report):
    """Re-derive the reductions in Python from the raw per-row counts.

    Every byte below is computed here from `storedCellCounts`, including a
    *modelled* size-class rounding. The probe's own `allocatedBytes` came from
    libmalloc, so `allocatorAgrees` holds the model against the allocator: if that
    is ever False, the model in `good_size` is wrong and the allocator's number is
    the one to quote.
    """
    stride = report["cellStrideBytes"]
    counts = report["storedCellCounts"]
    header = 32
    request = sum(header + count * stride for count in counts)
    allocated = sum(good_size(header + count * stride) for count in counts)
    full_width = len(counts) * good_size(header + report["columns"] * stride)
    blanks = report["blankRowCount"]
    per_blank = good_size(header + stride)
    return {
        "allocatorAgrees": allocated == report["allocatedBytes"],
        "retainedRowCount": len(counts),
        "blankRowCount": blanks,
        "blankRowFraction": (blanks / len(counts)) if counts else 0.0,
        "meanStoredCells": (sum(counts) / len(counts)) if counts else 0.0,
        "storedCellBytes": sum(counts) * stride,
        "requestBytes": request,
        "allocatedBytes": allocated,
        "roundingBytes": allocated - request,
        "roundingFractionOfAllocated": ((allocated - request) / allocated) if allocated else 0.0,
        "fullWidthAllocatedBytes": full_width,
        "fullWidthRequestBytes": len(counts) * (header + report["columns"] * stride),
        # The two halves of `F10`'s question: what ragged rows save on paper, and
        # what survives after both sides pass through the allocator.
        "paperSavingFraction": (
            1 - request / (len(counts) * (header + report["columns"] * stride))
        ) if counts else 0.0,
        "realizedSavingFraction": (1 - allocated / full_width) if full_width else 0.0,
        # `F8` measured this quantity independently, as a malloc `bytesInUse` delta
        # minus exact census bytes. Re-derived here from the size classes so the two
        # can be held against each other.
        "perRowOverheadBytes": (
            (allocated - sum(counts) * stride) / len(counts)
        ) if counts else 0.0,
        "sharedBlankCeilingBytes": max(blanks - 1, 0) * per_blank,
        "sharedBlankCeilingFractionOfAllocated": (
            (max(blanks - 1, 0) * per_blank / allocated) if allocated else 0.0
        ),
    }


# macOS malloc's published size classes, re-derived here rather than imported: the
# probe asks libmalloc directly via `malloc_good_size`, and this Python copy exists
# only so the driver's table is an independent second computation. A disagreement
# between the two is a finding, not a rounding detail, so the table prints both.
SMALL_ZONE_LIMIT_BYTES = 32 * 1024
LARGE_ALLOCATION_PAGE_BYTES = 16 * 1024


def good_size(request):
    """Round like macOS malloc: 16B steps to 256B, four buckets per octave, then pages.

    The middle regime is the one every retained row lands in, and it is what makes
    `F10` come out the way it does: four buckets per octave is ~12.5% granularity,
    so rounding is *proportional* to the request rather than a fixed quantum. Above
    the small zone's 32 KB limit the large allocator takes over and rounds to
    16 KB pages -- unreachable for a row at any sane width, and modelled anyway so
    the sweep in the test can prove the whole function rather than the part that
    happens to be exercised.
    """
    if request <= 0:
        return 0
    if request <= 256:
        return (request + 15) & ~15
    if request > SMALL_ZONE_LIMIT_BYTES:
        pages = -(-request // LARGE_ALLOCATION_PAGE_BYTES)
        return pages * LARGE_ALLOCATION_PAGE_BYTES
    octave = 1 << (request.bit_length() - 1)
    step = octave >> 2
    return (request + step - 1) // step * step


def summarize(reports):
    """Pool the corpus, and pool the recordings separately.

    Recordings are pooled on their own because they are the *recorded* half of the
    corpus -- the half `F9` treats as honest evidence about blank rows. The
    generated benchmark workloads contain whatever their templates contain, which
    is a fact about the template, not about real sessions.
    """
    pools = {
        "all": [r for r in reports if r["kind"] in {"benchmark", "recording"}],
        "recording": [r for r in reports if r["kind"] == "recording"],
    }
    summary = {}
    for name, pool in pools.items():
        rows = sum(len(r["storedCellCounts"]) for r in pool)
        blanks = sum(r["blankRowCount"] for r in pool)
        derived = [derive(r) for r in pool]
        allocated = sum(d["allocatedBytes"] for d in derived)
        request = sum(d["requestBytes"] for d in derived)
        summary[name] = {
            "stimulusCount": len(pool),
            "retainedRowCount": rows,
            "blankRowCount": blanks,
            "blankRowFraction": (blanks / rows) if rows else 0.0,
            "allocatedBytes": allocated,
            "requestBytes": request,
            "roundingFractionOfAllocated": ((allocated - request) / allocated) if allocated else 0.0,
            "sharedBlankCeilingBytes": sum(d["sharedBlankCeilingBytes"] for d in derived),
            "sharedBlankCeilingFractionOfAllocated": (
                sum(d["sharedBlankCeilingBytes"] for d in derived) / allocated
            ) if allocated else 0.0,
        }
    return summary


def render(reports, summary):
    """Print the table the findings quote, widest columns first."""
    header = (
        f"{'stimulus':44s} {'geom':>9s} {'rows':>6s} {'blank':>6s} "
        f"{'blank%':>7s} {'mean n':>7s} {'alloc KB':>9s} {'round%':>7s} "
        f"{'paper':>7s} {'real':>7s} {'B/row':>7s} {'H2 max B':>9s} {'census':>7s}"
    )
    print(header)
    print("-" * len(header))
    for report in reports:
        d = derive(report)
        print(
            f"{report['stimulus']:44s} "
            f"{report['columns']}x{report['rows']:<4d} "
            f"{d['retainedRowCount']:6d} {d['blankRowCount']:6d} "
            f"{100 * d['blankRowFraction']:6.1f}% {d['meanStoredCells']:7.1f} "
            f"{d['allocatedBytes'] / 1024:9.1f} "
            f"{100 * d['roundingFractionOfAllocated']:6.1f}% "
            f"{100 * d['paperSavingFraction']:6.1f}% "
            f"{100 * d['realizedSavingFraction']:6.1f}% "
            f"{d['perRowOverheadBytes']:7.1f} "
            f"{d['sharedBlankCeilingBytes']:9d} "
            f"{'ok' if report['derivationMatchesCensus'] and d['allocatorAgrees'] else 'MISMATCH':>7s}"
        )
    print()
    for name, pool in summary.items():
        print(
            f"pool {name}: {pool['stimulusCount']} stimuli, "
            f"{pool['retainedRowCount']} retained rows, "
            f"{pool['blankRowCount']} blank "
            f"({100 * pool['blankRowFraction']:.2f}%), "
            f"{pool['allocatedBytes'] / 1024:.1f} KB allocated, "
            f"rounding {100 * pool['roundingFractionOfAllocated']:.2f}%, "
            f"H2 ceiling {pool['sharedBlankCeilingBytes']} B "
            f"({100 * pool['sharedBlankCeilingFractionOfAllocated']:.3f}% of allocated)"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit the raw reports")
    parser.add_argument("--probe", default=str(PROBE), help="path to TerminalRetainedRowProbe")
    arguments = parser.parse_args()

    reports = [
        run_probe(stimulus, probe=pathlib.Path(arguments.probe))
        for stimulus in iter_stimuli(ROOT)
    ]
    summary = summarize(reports)
    if arguments.json:
        json.dump({"reports": reports, "summary": summary}, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        render(reports, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
