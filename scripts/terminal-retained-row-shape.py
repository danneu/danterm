#!/usr/bin/env python3
"""Drive the retained-row shape probe over the committed stimulus corpus.

Doc 28's `F9` (blank-row frequency, sizing `H2`'s ceiling), `F10` (allocator
behavior under ragged rows) and `F11` (what retained rows are made of, and what a
packing scheme can therefore charge) all need one thing the Swift probe
deliberately does not own: real content. This driver supplies it from bytes that
are already committed and already used for other purposes -- the five
benchmark-corpus workloads, and every neutral recording under the TerminalCore
test fixtures -- so nobody can shape a stimulus to flatter a hypothesis after the
fact.

Recordings are replayed at the geometry they were recorded at, and generated
benchmark workloads at the benchmark geometry, because a blank-row frequency is a
property of content *at a width*. Feed events only: resize and mouse events are
skipped, and the count of skipped events is reported so a reader can see how much
of a recording was not replayed.

Three reductions, in the order the findings quote them:

  shape        -- lengths, blank rows, size-class rounding (`F9`, `F10`)
  composition  -- what the stored cells contain, and which row classes hold the
                  bytes (`F11`)
  packing      -- what each candidate `H3` representation would charge for those
                  exact rows, through the same allocator (`F11`, `D5`)

The third is arithmetic over the first two, not a measurement of an
implementation: no packing candidate exists in the engine, and pricing one here
before writing it is precisely what `D3`'s admission test demands.

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


# The production scrollback budget, and the cap on how far a stimulus is repeated
# to reach it. The cap exists so a stimulus that retains almost nothing per pass
# cannot turn into an unbounded feed; a run that hits it is reported with its
# repeat count, so a reader can see it did not saturate.
SCROLLBACK_BUDGET_BYTES = 10 * 1024 * 1024
MAX_SATURATION_REPEATS = 400
MAX_SATURATION_FEED_BYTES = 16 * 1024 * 1024


def saturated_stimulus(stimulus, report):
    """Repeat one stimulus's own committed bytes until its history saturates.

    `F8`'s split, `F9`'s blank fraction and `F10`'s rounding were all read at
    *depth*, but only two corpus stimuli reach depth in a single pass. `F11` asks
    what styled and multi-scalar rows cost at depth specifically -- and the
    styled content in this corpus lives in recordings and TUI workloads that
    retain a screenful or less per pass. Repeating the stimulus is the honest way
    to get depth without inventing content: every byte is still committed, and
    the only thing added is how many times it is replayed.

    Repeat count comes from the stimulus's own measured charge rather than from a
    guess: enough passes to fill the budget. A stimulus that retained *nothing* in
    one pass is repeated to the byte cap instead of skipped -- "this content never
    reaches history however long it runs" is the answer `F11` most needs from the
    styled TUI recordings, and skipping them would leave it unmeasured. Both caps
    bound the run; a report that hit one is still reported, with its repeat count
    and fed bytes, so a reader can see it did not saturate.

    Returns None when one pass already fills the budget, because repeating it would
    only re-measure the same evicted history.
    """
    charged = charged_bytes(report)
    wanted = (
        -(-SCROLLBACK_BUDGET_BYTES // charged) if charged > 0 else MAX_SATURATION_REPEATS
    )
    affordable = max(1, MAX_SATURATION_FEED_BYTES // max(report["fedByteCount"], 1))
    repeats = min(MAX_SATURATION_REPEATS, affordable, wanted)
    if repeats <= 1:
        return None
    return {
        "stimulus": f"saturated/{stimulus['stimulus']}",
        "kind": "saturated",
        "columns": stimulus["columns"],
        "rows": stimulus["rows"],
        "chunks": stimulus["chunks"] * repeats,
        "skippedEvents": stimulus["skippedEvents"] * repeats,
        "repeats": repeats,
    }


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
    report["repeats"] = stimulus.get("repeats", 1)
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


# The three constants the engine's own scrollback charge is built from
# (`Terminal.scrollbackByteCost`): a row's slot in history's buffer, a Swift array's
# storage header, and `Unicode.Scalar`'s stride in a spill array. Restated here so a
# candidate representation can be charged the *same* way the budget charges the real
# one -- a saving priced against a different cost model would not be a depth claim.
GRID_ROW_SLOT_BYTES = 16
ARRAY_HEADER_BYTES = 32
SCALAR_STRIDE_BYTES = 4


def row_facts(report):
    """Zip the parallel per-row arrays into one record per retained row.

    Everything downstream -- classification, pricing, pooling -- reads rows through
    this, so a probe field that stops being index-aligned fails loudly here rather
    than producing a plausible average.
    """
    composition = report["composition"]
    counts = report["storedCellCounts"]
    keys = (
        "styledCellCounts", "multiScalarCellCounts", "emptyScalarCellCounts",
        "scalarCounts", "nonASCIIScalarCounts", "utf8ByteCounts",
        "styleRunCounts", "distinctStyleCounts", "wideCellCounts",
        "hyperlinkCellCounts", "maxSingleScalarValues",
        "contentIdentityRunCounts", "identifiedCellCounts",
    )
    for key in keys:
        if len(composition[key]) != len(counts):
            raise RuntimeError(
                f"{report['stimulus']}: {key} has {len(composition[key])} entries "
                f"for {len(counts)} rows"
            )
    facts = []
    for index, stored in enumerate(counts):
        single = stored - composition["emptyScalarCellCounts"][index] \
            - composition["multiScalarCellCounts"][index]
        facts.append({
            "stored": stored,
            "styled": composition["styledCellCounts"][index],
            "multiScalar": composition["multiScalarCellCounts"][index],
            "emptyScalar": composition["emptyScalarCellCounts"][index],
            "scalars": composition["scalarCounts"][index],
            "nonASCII": composition["nonASCIIScalarCounts"][index],
            "utf8Bytes": composition["utf8ByteCounts"][index],
            "styleRuns": composition["styleRunCounts"][index],
            "distinctStyles": composition["distinctStyleCounts"][index],
            "wide": composition["wideCellCounts"][index],
            "hyperlinks": composition["hyperlinkCellCounts"][index],
            "maxSingleScalar": composition["maxSingleScalarValues"][index],
            "identityRuns": composition["contentIdentityRunCounts"][index],
            "identifiedCells": composition["identifiedCellCounts"][index],
            # Scalars living in spill arrays: everything not held by a single-scalar
            # cell. The engine charges each spill separately, and so does every
            # candidate below, so this term cancels in a saving -- it is carried
            # anyway because a candidate that *removed* spills would need it.
            "spillScalars": composition["scalarCounts"][index] - max(single, 0),
        })
    return facts


def spill_charge(fact):
    """What the engine charges for one row's multi-scalar spill arrays."""
    return fact["multiScalar"] * ARRAY_HEADER_BYTES + fact["spillScalars"] * SCALAR_STRIDE_BYTES


def row_charge(payload_bytes, fact):
    """Charge one row the way `Terminal.scrollbackByteCost` does.

    Slot plus the allocator's answer for `header + payload`, plus spills. Passing
    the payload in is what makes this reusable for a candidate representation: the
    budget's shape is fixed, only what a row asks for changes.
    """
    return (
        GRID_ROW_SLOT_BYTES
        + good_size(ARRAY_HEADER_BYTES + payload_bytes)
        + spill_charge(fact)
    )


def charged_bytes(report):
    """What the production budget charges for this stimulus's retained rows."""
    stride = report["cellStrideBytes"]
    return sum(row_charge(f["stored"] * stride, f) for f in row_facts(report))


# Row classes, on the two axes `D3` named as unmeasured. They are exhaustive and
# mutually exclusive, so the byte shares below sum to the whole history, and they
# are the two axes rather than a finer taxonomy because those are the two a packing
# scheme prices differently: a styled row needs style representation, a
# multi-scalar row cannot use a fixed-width scalar slot inline.
ROW_CLASSES = ("plain", "styled", "multiScalar", "styledMultiScalar")


def classify(fact):
    styled, multi = fact["styled"] > 0, fact["multiScalar"] > 0
    if styled and multi:
        return "styledMultiScalar"
    if styled:
        return "styled"
    if multi:
        return "multiScalar"
    return "plain"


def compose(report):
    """Reduce one stimulus's composition. See `compose_facts`."""
    return compose_facts(row_facts(report), report["cellStrideBytes"])


def compose_facts(facts, stride):
    """Reduce a row population's composition, including the per-class byte shares.

    Takes rows rather than a report so a *pool* reduces exactly as one stimulus
    does -- the pooled numbers a finding quotes must not come from a second
    implementation that could disagree with the per-stimulus one.

    `meanChargeBytes` per class is the quantity `F9`'s 1,808 B content-row figure
    is the plain-row instance of: what one retained row of that class costs the
    budget, and therefore what one row of that class costs in depth.
    """
    totals = {
        "retainedRowCount": len(facts),
        "storedCells": sum(f["stored"] for f in facts),
        "styledCells": sum(f["styled"] for f in facts),
        "multiScalarCells": sum(f["multiScalar"] for f in facts),
        "emptyScalarCells": sum(f["emptyScalar"] for f in facts),
        "scalars": sum(f["scalars"] for f in facts),
        "nonASCIIScalars": sum(f["nonASCII"] for f in facts),
        "utf8Bytes": sum(f["utf8Bytes"] for f in facts),
        "styleRuns": sum(f["styleRuns"] for f in facts),
        "wideCells": sum(f["wide"] for f in facts),
        "hyperlinkCells": sum(f["hyperlinks"] for f in facts),
        "chargedBytes": sum(row_charge(f["stored"] * stride, f) for f in facts),
    }
    classes = {}
    for name in ROW_CLASSES:
        members = [f for f in facts if classify(f) == name]
        charged = sum(row_charge(f["stored"] * stride, f) for f in members)
        classes[name] = {
            "rowCount": len(members),
            "rowFraction": (len(members) / len(facts)) if facts else 0.0,
            "meanStoredCells": (sum(f["stored"] for f in members) / len(members)) if members else 0.0,
            "chargedBytes": charged,
            "chargedFraction": (charged / totals["chargedBytes"]) if totals["chargedBytes"] else 0.0,
            "meanChargeBytes": (charged / len(members)) if members else 0.0,
        }
    return {
        "totals": totals,
        "classes": classes,
        # The per-cell shares a packing scheme is priced against. Denominated in
        # stored cells rather than rows, because that is what a cell-shaped
        # representation charges for.
        "styledCellFraction": (totals["styledCells"] / totals["storedCells"]) if totals["storedCells"] else 0.0,
        "multiScalarCellFraction": (totals["multiScalarCells"] / totals["storedCells"]) if totals["storedCells"] else 0.0,
        "emptyScalarCellFraction": (totals["emptyScalarCells"] / totals["storedCells"]) if totals["storedCells"] else 0.0,
        "nonASCIIScalarFraction": (totals["nonASCIIScalars"] / totals["scalars"]) if totals["scalars"] else 0.0,
        "wideCellFraction": (totals["wideCells"] / totals["storedCells"]) if totals["storedCells"] else 0.0,
        "meanStyleRunsPerRow": (totals["styleRuns"] / len(facts)) if facts else 0.0,
        # Denominated in rows, not runs: the `contentIdentity` encoding is chosen per
        # row, so the question is how many rows are cheap. A mean over runs would let
        # one pathologically fragmented row speak for a history of contiguous ones.
        # A row with no identities at all is single-run -- it costs the encoding nothing.
        "singleRunRowFraction": (
            sum(1 for f in facts if f["identityRuns"] <= 1) / len(facts)
        ) if facts else 0.0,
        "meanIdentityRunsPerRow": (
            sum(f["identityRuns"] for f in facts) / len(facts)
        ) if facts else 0.0,
        "meanUTF8BytesPerCell": (totals["utf8Bytes"] / totals["storedCells"]) if totals["storedCells"] else 0.0,
    }


# Candidate `H3` representations, priced as payload bytes per row from the measured
# composition. Each takes one row's facts and returns what that row's single cell
# allocation would ask malloc for -- the row slot, the array header, the spills and
# the size-class rounding are added identically by `row_charge`, because the point
# of the comparison is the payload and nothing else.
#
# These are proposals, not implementations: nothing in the engine packs anything.
# Pricing them here against real rows before any of them is built is exactly what
# `D3`'s admission test asks for, and the test it enforces -- more than one ~12.5%
# bucket step of shrink, or the saving can round back to zero -- is reported per
# candidate as `rowsDroppingAClass`.


# Metadata every candidate owes, whatever shape it stores cells in. Charged once in
# `price_facts` rather than inside each candidate, because the point is that none of
# them may be free of it: a field a retained row must preserve is a cost of retaining
# the row, not a property of the encoding that happens to mention it.
#
# `HYPERLINK_ENTRY_BYTES` -- 2 B column + 2 B `HyperlinkId`. No candidate below has
# room for a hyperlink in the per-cell storage it describes (C1's whole cell is 8 B and
# already spent), so each owes a side-table entry. The original C6 named hyperlink cells
# in its design and charged them nowhere, which is the defect this constant closes.
#
# `IDENTITY_CELL_BYTES` / `IDENTITY_RUN_ENTRY_BYTES` -- the two ways to preserve
# `contentIdentity`, which `activationIdentity` reads back out of retained rows and so
# cannot be dropped. Either 4 B on every stored cell, or, because the counter advances
# by one per printed cell, 4 B of run base plus 2 B start column and 2 B extent for each
# maximal contiguous run. Which one a candidate really pays is a property of recorded
# content, so both are priced and the measured contiguity selects.
HYPERLINK_ENTRY_BYTES = 4
IDENTITY_CELL_BYTES = 4
IDENTITY_RUN_ENTRY_BYTES = 8

# A spill reference: the index a packed row holds to reach a multi-scalar cell's own
# allocation, which `spill_charge` prices separately. Four bytes matches the index C1
# already assumes it can put in a cell's scalar slot.
SPILL_REFERENCE_BYTES = 4


def identity_charge(fact, variant):
    """What preserving one row's `contentIdentity` costs, under either variant.

    The run variant is capped at the flat per-cell form: a real encoder facing a row
    whose run table would outgrow its cells writes the cells instead. Without the cap the
    table would report the run variant as *dearer* than the floor on fragmented rows,
    which would be an artifact of this model rather than a fact about the design.
    """
    floor = fact["stored"] * IDENTITY_CELL_BYTES
    if variant == "floor":
        return floor
    return min(floor, fact["identityRuns"] * IDENTITY_RUN_ENTRY_BYTES)


def metadata_charge(fact, variant):
    """Storage every candidate owes for fields none of them encode in their cells."""
    return fact["hyperlinks"] * HYPERLINK_ENTRY_BYTES + identity_charge(fact, variant)


def pack_narrow_cell(fact):
    """C1: same array-of-cells, an 8-byte retained cell. **Selected by `D9`; shipped.**

    The shipped layout packs one 64-bit word: 21 bits of scalar (or spill index), 3 bits
    of kind, a spill flag, and a **full-width 32-bit** interned style id, with 7 bits
    spare. 21 bits is exactly `U+10FFFF`, so every scalar in Unicode is inline. An earlier
    version of this docstring described "4 B scalar + 1 B kind + 2 B style id + 1 B pad"
    and said `StyleId` narrows to 16 bits against a measured style-table size; the
    implementation does not narrow it, because the bits were there for free and a
    style-table ceiling is risk for no gain. Structure is unchanged, so column reads stay
    O(1) -- and under this shape a column read is one load with nothing to decode, which
    is what `28/F17` measured `C6` paying ~3.8 ns per cell to avoid needing.

    Hyperlink and `contentIdentity` storage are *not* in these 8 bytes and are charged
    separately, like every other candidate. An earlier version of this docstring claimed
    a retained cell's `contentIdentity` has no reader; that is false --
    `Terminal.activationIdentity` takes a max over a `ProjectionRows` range, which spans
    retained rows, so link activation reads it out of history.

    Like every candidate here it is charged no per-row header (`F13` Observation 2). C1's
    is 7 bytes; `28/F18` adds it back when pricing the pivot, and a reader pricing a new
    candidate against this table must do the same or the comparison tilts.
    """
    return fact["stored"] * 8


def pack_narrow_cell_ascii(fact):
    """C2: C1, plus a 4-byte per-cell form for rows that are entirely ASCII.

    1 B scalar + 1 B kind/flags + 2 B style id. Chosen per row from the row's own
    content, so a row with any non-ASCII or multi-scalar cell falls back to C1's
    8 bytes rather than to a mixed encoding.
    """
    if fact["nonASCII"] == 0 and fact["multiScalar"] == 0:
        return fact["stored"] * 4
    return pack_narrow_cell(fact)


def pack_text_runs(fact):
    """C3: UTF-8 text plus run-length styles.

    1 B per cell of descriptor (kind + this cell's UTF-8 length), the row's UTF-8
    bytes, and 6 B per style run (2 B run length + 4 B style id). Kitty's
    `PagerHistoryBuf` is the shape precedent; the descriptor byte is what keeps a
    column read a bounded in-row scan instead of a decode of the whole history.
    """
    return fact["stored"] + fact["utf8Bytes"] + fact["styleRuns"] * 6


def pack_text_runs_uniform(fact):
    """C4: C3, with the style table collapsed when a row holds one style.

    A row whose every stored cell shares one style carries a single 4 B style id
    instead of a run table. This is the variant that tests how much of C3's saving
    comes from run-length encoding at all, as opposed to from dropping the 32-byte
    cell.
    """
    if fact["distinctStyles"] <= 1:
        return fact["stored"] + fact["utf8Bytes"] + 4
    return pack_text_runs(fact)


def row_scalar_width(fact):
    """Bytes per scalar slot for a fixed-stride row: 1, 2, or 4, chosen per row.

    The tier is set by the widest scalar any *single-scalar* cell in the row holds,
    because multi-scalar cells take an indirection at every tier and so do not
    constrain it. The measured `maxSingleScalarValues` is what makes the one-byte
    tier a real option rather than a trick, and the two-byte tier is priced
    separately because box-drawing and Powerline glyphs -- the non-ASCII a shell
    prompt actually emits -- are BMP, while emoji are not.
    """
    widest = fact["maxSingleScalar"]
    if widest < 0x100:
        return 1
    if widest < 0x1_0000:
        return 2
    return 4


def pack_stride_runs_kindbyte(fact):
    """C5: fixed-stride scalar column, run-length styles, one kind byte per cell.

    The variant of C3 that keeps a column read O(1): every cell in a row occupies
    the same number of bytes, so column -> offset is multiplication rather than a
    scan. Costs `stride + 1` per cell against C3's `1 + utf8`, which is the same
    number whenever the row is ASCII -- which is what the composition says most
    rows are.
    """
    return fact["stored"] * (row_scalar_width(fact) + 1) + fact["styleRuns"] * 6


def pack_stride_runs_exceptions(fact):
    """C6: C5 with the per-cell kind byte replaced by an exception list.

    Padding needs no kind byte -- scalar slot zero is not a content scalar, so it
    encodes "never written" for free. What is left is wide-cell geometry and
    multi-scalar cells, in a per-row exception list. Priced because the measured share
    of those cells is small enough that paying per row for them may beat paying per
    cell.

    Entry width is per kind, not uniform: a wide cell needs 2 B column + 1 B kind, while
    a multi-scalar cell needs those plus the reference that reaches its spill
    allocation. Charging both at 3 B under-prices exactly the cells a fixed-width scalar
    slot cannot hold, which is the one place this candidate is structurally weakest.
    """
    return (
        fact["stored"] * row_scalar_width(fact)
        + fact["styleRuns"] * 6
        + fact["wide"] * 3
        + fact["multiScalar"] * (3 + SPILL_REFERENCE_BYTES)
    )


PACKINGS = {
    "C1 narrow-cell-8B": pack_narrow_cell,
    "C2 narrow-cell-4B-ascii": pack_narrow_cell_ascii,
    "C3 text+style-runs": pack_text_runs,
    "C4 text+uniform-style": pack_text_runs_uniform,
    "C5 stride+runs+kindbyte": pack_stride_runs_kindbyte,
    "C6 stride+runs+exceptions": pack_stride_runs_exceptions,
}


def price(report, identity="target"):
    """Charge every candidate representation for this stimulus's exact rows."""
    return price_facts(row_facts(report), report["cellStrideBytes"], identity=identity)


def price_facts(facts, stride, identity="target"):
    """Charge every candidate representation for a row population's exact rows.

    `identity` selects how `contentIdentity` is preserved -- `"floor"` charges 4 B on
    every stored cell, `"target"` charges per contiguous run. Both are reported, and the
    measured single-run fraction is what says which one a candidate really pays. Neither
    is a default answer: the floor is what recorded content forces if it is fragmented,
    and quoting the target without the contiguity number beside it would be the
    assumption `PR1` exists to remove.
    """
    if not facts:
        return {}
    current = [row_charge(f["stored"] * stride, f) for f in facts]
    current_total = sum(current)
    priced = {}
    for name, packing in PACKINGS.items():
        # Every candidate pays its own payload *plus* the metadata none of them encode.
        # Composed here rather than inside each candidate so a new candidate cannot be
        # added that quietly stores a retained row without a field the row must keep.
        def payload(fact, packing=packing):
            return packing(fact) + metadata_charge(fact, identity)

        charged = [row_charge(payload(f), f) for f in facts]
        total = sum(charged)
        # `D3`'s admission test, per row: did the request shrink enough to leave its
        # size class? A candidate that saves on paper but keeps rows in the same
        # bucket delivers exactly zero bytes, however clean its arithmetic.
        dropped = sum(
            1 for f, before in zip(facts, current)
            if good_size(ARRAY_HEADER_BYTES + payload(f))
            < good_size(ARRAY_HEADER_BYTES + f["stored"] * stride)
        )
        priced[name] = {
            "chargedBytes": total,
            "savingFraction": (1 - total / current_total) if current_total else 0.0,
            "meanChargeBytes": total / len(facts),
            "rowsDroppingAClass": dropped,
            "rowsDroppingAClassFraction": dropped / len(facts),
            # Depth is the point: the budget is denominated in bytes, so a saving is
            # a row count. Stated at the production budget for this stimulus's own
            # row mix, which is the only mix it can honestly be stated for.
            "depthAtBudget": int(SCROLLBACK_BUDGET_BYTES / (total / len(facts))),
            "depthMultiple": current_total / total if total else 0.0,
        }
        # `H4` composed in, per `D3`: an aggregate store removes the per-row array
        # header and its size-class rounding, leaving the row slot and the payload.
        # Priced on top of every candidate rather than alone, because that is the
        # only form `D3` left it alive in -- and because a packing scheme shrinks
        # the payload, which makes the fixed header a *larger* share than the 10.5%
        # `F8` measured against 32-byte cells.
        arena = sum(GRID_ROW_SLOT_BYTES + payload(f) + spill_charge(f) for f in facts)
        priced[name]["arenaChargedBytes"] = arena
        priced[name]["arenaSavingFraction"] = (1 - arena / current_total) if current_total else 0.0
        priced[name]["arenaMeanChargeBytes"] = arena / len(facts)
        priced[name]["arenaDepthAtBudget"] = int(SCROLLBACK_BUDGET_BYTES / (arena / len(facts)))
    priced["current"] = {
        "chargedBytes": current_total,
        "meanChargeBytes": current_total / len(facts),
        "depthAtBudget": int(SCROLLBACK_BUDGET_BYTES / (current_total / len(facts))),
    }
    return priced


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

    Saturated replays are pooled separately again, and are in neither of the other
    two: their content is committed but their *depth* is manufactured by repetition,
    so they answer "what does this content cost at depth" without being evidence
    about how often such content reaches depth.
    """
    pools = {
        "all": [r for r in reports if r["kind"] in {"benchmark", "recording"}],
        "recording": [r for r in reports if r["kind"] == "recording"],
        "saturated": [r for r in reports if r["kind"] == "saturated"],
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
        # Composition and pricing are pooled over the pool's rows directly, through
        # the same reductions one stimulus uses, so a pooled mean is a mean over
        # rows rather than a mean over stimuli.
        facts = [f for report in pool for f in row_facts(report)]
        stride = pool[0]["cellStrideBytes"] if pool else 32
        summary[name]["composition"] = compose_facts(facts, stride)
        # Both `contentIdentity` variants, side by side and neither privileged. The
        # pool's own `singleRunRowFraction` is what says which one its rows really pay,
        # so a reader who quotes a headline without it has skipped the selection.
        summary[name]["packing"] = price_facts(facts, stride, identity="target")
        summary[name]["packingIdentityFloor"] = price_facts(facts, stride, identity="floor")
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
    render_composition(reports, summary)
    render_packing(summary)


def render_composition(reports, summary):
    """Print what the stored cells contain -- `F11`'s first half."""
    print()
    header = (
        f"{'stimulus':44s} {'rows':>6s} {'styled%':>8s} {'multi%':>7s} "
        f"{'empty%':>7s} {'n-ascii%':>9s} {'wide%':>7s} {'runs/row':>9s} "
        f"{'utf8/cell':>10s} {'1-run%':>8s} {'runs/row':>9s} "
        f"{'plain rows':>11s} {'styled rows':>12s}"
    )
    print(header)
    print("-" * len(header))
    for report in reports:
        c = compose(report)
        classes = c["classes"]
        print(
            f"{report['stimulus']:44s} "
            f"{c['totals']['retainedRowCount']:6d} "
            f"{100 * c['styledCellFraction']:7.2f}% "
            f"{100 * c['multiScalarCellFraction']:6.2f}% "
            f"{100 * c['emptyScalarCellFraction']:6.2f}% "
            f"{100 * c['nonASCIIScalarFraction']:8.2f}% "
            f"{100 * c['wideCellFraction']:6.2f}% "
            f"{c['meanStyleRunsPerRow']:9.2f} "
            f"{c['meanUTF8BytesPerCell']:10.2f} "
            f"{100 * c['singleRunRowFraction']:7.2f}% "
            f"{c['meanIdentityRunsPerRow']:9.2f} "
            f"{100 * classes['plain']['rowFraction']:10.1f}% "
            f"{100 * (classes['styled']['rowFraction'] + classes['styledMultiScalar']['rowFraction']):11.1f}%"
        )
    print()
    for name, pool in summary.items():
        classes = pool["composition"]["classes"]
        print(f"pool {name} row classes (rows / share of rows / share of charged bytes / mean B per row):")
        for row_class in ROW_CLASSES:
            entry = classes[row_class]
            print(
                f"    {row_class:20s} {entry['rowCount']:8d} "
                f"{100 * entry['rowFraction']:7.2f}% "
                f"{100 * entry['chargedFraction']:7.2f}% "
                f"{entry['meanChargeBytes']:10.1f}"
            )


def render_packing(summary):
    """Print what each candidate representation would charge -- `F11`'s second half.

    Both `contentIdentity` variants are printed for every pool, with the pool's own
    single-run fraction above them, because that fraction is what selects between the
    two. Printing only one would be stating a headline the content may not support.
    """
    print()
    for name, pool in summary.items():
        for variant, key in (("run-encoded", "packing"), ("per-cell floor", "packingIdentityFloor")):
            packing = pool[key]
            if not packing:
                continue
            current = packing["current"]
            composition = pool["composition"]
            print(
                f"pool {name} packing, contentIdentity {variant} "
                f"(single-run rows {100 * composition['singleRunRowFraction']:.2f}%, "
                f"{composition['meanIdentityRunsPerRow']:.2f} runs/row; current: "
                f"{current['meanChargeBytes']:.1f} B/row, "
                f"depth {current['depthAtBudget']} rows at 10 MiB):"
            )
            header = (
                f"    {'candidate':26s} {'B/row':>8s} {'saving':>8s} {'depth':>8s} "
                f"{'x depth':>8s} {'drop class':>11s} {'+H4 B/row':>10s} {'+H4 depth':>10s}"
            )
            print(header)
            for candidate, entry in packing.items():
                if candidate == "current":
                    continue
                print(
                    f"    {candidate:26s} {entry['meanChargeBytes']:8.1f} "
                    f"{100 * entry['savingFraction']:7.1f}% "
                    f"{entry['depthAtBudget']:8d} "
                    f"{entry['depthMultiple']:7.2f}x "
                    f"{100 * entry['rowsDroppingAClassFraction']:10.1f}% "
                    f"{entry['arenaMeanChargeBytes']:10.1f} "
                    f"{entry['arenaDepthAtBudget']:10d}"
                )
            print()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit the raw reports")
    parser.add_argument("--probe", default=str(PROBE), help="path to TerminalRetainedRowProbe")
    parser.add_argument(
        "--saturated",
        action="store_true",
        help="also replay each stimulus until its retained history fills the budget",
    )
    arguments = parser.parse_args()

    probe = pathlib.Path(arguments.probe)
    reports = []
    for stimulus in iter_stimuli(ROOT):
        report = run_probe(stimulus, probe=probe)
        reports.append(report)
        # A saturated replay is derived from the pass that just ran, not guessed:
        # the repeat count comes from what that pass actually charged. Bounds and
        # references are excluded -- one already saturates and the other is a
        # ceiling, so repeating either measures nothing new.
        if arguments.saturated and stimulus["kind"] in {"benchmark", "recording"}:
            repeated = saturated_stimulus(stimulus, report)
            if repeated is not None:
                reports.append(run_probe(repeated, probe=probe))
    summary = summarize(reports)
    if arguments.json:
        json.dump({"reports": reports, "summary": summary}, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        render(reports, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
