// Research doc 33, task T8: the counter shim both instrumented engine copies increment.
//
// `t8-bulk-ascii-runs.py` copies an arm's `lib/TerminalCore/Sources/TerminalCore` into a scratch
// directory, injects one call to a member of this type at each bookkeeping site `T2` named, and
// compiles the result as one module with `t8-bulk-ascii-runs-probe.swift`. Nothing here is on a
// production path and no engine in any arm's working tree is edited.
//
// The same type serves both arms on purpose. The before arm never calls `observeBulkRun`, so its
// run counts stay zero and its `bookkeepingUnits` is exactly its printed-character count -- which
// is the claim `T8` is measured against, stated by the shim rather than by the driver.

/// Per-corpus tallies of the work the print path does, and of how many times it does it.
///
/// `printedCharacters` and `bookkeepingUnits` are deliberately separate. The first must be
/// identical between the two arms -- it is the equivalence cross-check, and any movement in it is
/// a changed token stream, not a result. The second is what `T8` claims to collapse.
struct T8Counters {
    /// Printable characters the grid actually consumed, however they arrived.
    var printedCharacters = 0
    /// Times the print path ran its per-unit bookkeeping: once per character before `T8`, once
    /// per accepted bulk run plus once per declined character after it.
    var bookkeepingUnits = 0

    var unicodeClassificationCalls = 0
    var invalidateInspectionCalls = 0
    var rememberOpenClusterCalls = 0
    var searchMatchCacheInvalidations = 0
    var damageActionSnapshotConstructions = 0
    var damageDiffs = 0
    var contentIdentityAllocationSites = 0
    var currentStyleIdCalls = 0
    var currentStyleIdMisses = 0

    /// Bulk runs the grid accepted, and the characters they carried. Zero in the before arm.
    var bulkRuns = 0
    var bulkCharacters = 0
    var longestBulkRun = 0
    /// Bulk attempts the grid declined, each of which costs one character on the slow path. This
    /// is the count that says how expensive the cut rules are in practice.
    var declinedBulkAttempts = 0

    /// One character through the per-character path, in either arm.
    mutating func observePrintedCharacter() {
        printedCharacters += 1
        bookkeepingUnits += 1
    }

    /// One `printBulkASCII` outcome: `taken` characters written in one pass, or 0 for a decline.
    mutating func observeBulkRun(_ taken: Int) {
        guard taken > 0 else {
            declinedBulkAttempts += 1
            return
        }
        bulkRuns += 1
        bulkCharacters += taken
        printedCharacters += taken
        bookkeepingUnits += 1
        longestBulkRun = max(longestBulkRun, taken)
    }

    var meanBulkRunLength: Double {
        bulkRuns == 0 ? 0 : Double(bulkCharacters) / Double(bulkRuns)
    }
}

nonisolated(unsafe) var t8Counters = T8Counters()
