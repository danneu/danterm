// Research doc 33, task T2: the counter shim the instrumented engine copy increments.
//
// `t2-print-bookkeeping.py` copies `lib/TerminalCore/Sources/TerminalCore` into a scratch
// directory, injects one call to a member of this type at each bookkeeping site T2 names,
// and compiles the result as one module with `t2-print-bookkeeping-probe.swift`. Nothing
// here is on a production path and the engine in the repo is never edited.
//
// It holds counting and the ASCII-run state machine only. Any decision about what the
// numbers mean belongs in the finding, not in this file.

/// Per-corpus tallies of the work `Terminal.print`/`printNarrow` does once per printed
/// character, plus the run structure that decides how much of it `T8` could hoist.
///
/// The run state machine lives here rather than in the driver because run boundaries are a
/// property of grid state at the moment of the print -- the cursor column, insert mode, the
/// pending-wrap latch, and the kind of the cell about to be overwritten -- none of which is
/// recoverable from the byte stream alone.
struct T2Counters {
    var printCalls = 0
    var unicodeClassificationCalls = 0
    var invalidateInspectionCalls = 0
    var invalidateInspectionFromPendingWrap = 0
    var invalidateInspectionFromPrintNarrow = 0
    var invalidateInspectionFromPrintWide = 0
    var rememberOpenClusterCalls = 0
    var searchMatchCacheInvalidations = 0
    var damageActionSnapshotConstructions = 0
    var damageDiffs = 0
    var contentIdentityAllocations = 0
    var currentStyleIdCalls = 0
    var currentStyleIdMisses = 0

    /// Number of maximal runs of printable ASCII that `T8` could print in bulk.
    var asciiRuns = 0
    /// Prints that belong to one of those runs; the rest stay per-character under `T8`.
    var asciiRunPrints = 0
    var longestAsciiRun = 0

    private var openRunLength = 0
    private var openRunRow = -1
    private var openRunColumn = -1

    /// Records one `Terminal.print` and advances the run state machine.
    ///
    /// The cut rules are `T8`'s own, restated as a predicate: a run continues only while the
    /// next print is printable ASCII, lands in the cell immediately right of the previous one
    /// in the same row, is not shifting cells under insert mode, is not the deferred wrap at
    /// the right margin, and is not overwriting a wide or spacer cell.
    mutating func observePrint(
        scalar: Unicode.Scalar,
        row: Int,
        column: Int,
        isInsertMode: Bool,
        isPendingWrap: Bool,
        overwritesWideOrSpacer: Bool
    ) {
        printCalls += 1
        let isPrintableASCII = scalar.value >= 0x20 && scalar.value <= 0x7E
        guard isPrintableASCII, !isInsertMode, !isPendingWrap, !overwritesWideOrSpacer else {
            closeRun()
            return
        }
        if openRunLength > 0, row == openRunRow, column == openRunColumn + 1 {
            openRunLength += 1
        } else {
            closeRun()
            asciiRuns += 1
            openRunLength = 1
        }
        openRunRow = row
        openRunColumn = column
        asciiRunPrints += 1
    }

    /// Any non-print action ends the open run: it may move the cursor, change the pen, or
    /// scroll, none of which a bulk print may straddle.
    mutating func observeNonPrintAction() {
        closeRun()
    }

    mutating func closeRun() {
        longestAsciiRun = max(longestAsciiRun, openRunLength)
        openRunLength = 0
        openRunRow = -1
        openRunColumn = -1
    }

    /// Bookkeeping units `T8` would still pay: one per ASCII run, plus one for every print
    /// that no run can absorb.
    var predictedUnitsAfterBulkRuns: Int {
        asciiRuns + (printCalls - asciiRunPrints)
    }
}

/// True for the cell kinds a bulk ASCII run may not overwrite in place.
func t2CellBlocksRun(_ kind: TerminalCellKind) -> Bool {
    switch kind {
    case .narrow, .padding: return false
    case .wideHead, .wideTail, .spacerHead: return true
    }
}

nonisolated(unsafe) var t2Counters = T2Counters()
