// Research doc 33, task T8: drives each committed corpus through one instrumented arm of the
// engine and reports how many times the print path ran its bookkeeping.
//
// Compiled by `t8-bulk-ascii-runs.py` into one module together with one arm's patched engine
// sources and `t8-bulk-ascii-runs-counters.swift`; the driver runs it once per arm and compares.
// It mirrors `measureFeedBatch`'s shape -- a fresh 179x66 terminal, the corpus's own chunk
// framing, no damage drain -- so the counts describe the same feed `terminal-feed` measures, and
// so they sit beside `F10`'s numbers without a conversion.
//
// It holds measurement only. Corpus framing is the driver's job, and so is every comparison.
import Foundation

/// One corpus's counts under one arm.
struct CorpusReport: Encodable {
    let name: String
    let feedCalls: Int
    let byteCount: Int
    let printedCharacters: Int
    let bookkeepingUnits: Int
    let unicodeClassificationCalls: Int
    let invalidateInspectionCalls: Int
    let rememberOpenClusterCalls: Int
    let searchMatchCacheInvalidations: Int
    let damageActionSnapshotConstructions: Int
    let damageDiffs: Int
    let contentIdentityAllocationSites: Int
    let currentStyleIdCalls: Int
    let currentStyleIdMisses: Int
    let bulkRuns: Int
    let bulkCharacters: Int
    let longestBulkRun: Int
    let meanBulkRunLength: Double
    let declinedBulkAttempts: Int
    /// A cheap end-state fingerprint. Two arms that printed the same characters but landed the
    /// cursor or the scrollback somewhere different are not equivalent, and the suite is the
    /// place that proves they are -- this is the corroborating check that costs nothing here.
    let cursorRow: Int
    let cursorColumn: Int
    let scrollbackRowCount: Int
    let screenTextHash: Int
}

/// Reads the driver's framing: repeated 8-byte big-endian length followed by that many bytes.
/// Restated here because this probe compiles against `TerminalCore` alone.
func decodeFramedChunks(_ data: Data) -> [[UInt8]] {
    var chunks: [[UInt8]] = []
    var offset = data.startIndex
    while offset < data.endIndex {
        precondition(data.distance(from: offset, to: data.endIndex) >= 8, "truncated length")
        var length = 0
        for byte in data[offset..<data.index(offset, offsetBy: 8)] {
            length = (length << 8) | Int(byte)
        }
        offset = data.index(offset, offsetBy: 8)
        precondition(data.distance(from: offset, to: data.endIndex) >= length, "truncated chunk")
        let end = data.index(offset, offsetBy: length)
        chunks.append(Array(data[offset..<end]))
        offset = end
    }
    return chunks
}

/// A stable hash of the visible screen, since `Hasher` is seeded per process and this value has
/// to be comparable between the driver's two separate probe runs.
func stableHash(_ text: String) -> Int {
    var value: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    return Int(bitPattern: UInt(truncatingIfNeeded: value))
}

func measure(name: String, chunks: [[UInt8]]) -> CorpusReport {
    t8Counters = T8Counters()
    guard var terminal = Terminal(columns: 179, rows: 66) else {
        fatalError("fixed benchmark geometry must be valid")
    }
    var byteCount = 0
    for chunk in chunks {
        byteCount += chunk.count
        terminal.feed(chunk)
    }
    let counters = t8Counters
    return CorpusReport(
        name: name,
        feedCalls: chunks.count,
        byteCount: byteCount,
        printedCharacters: counters.printedCharacters,
        bookkeepingUnits: counters.bookkeepingUnits,
        unicodeClassificationCalls: counters.unicodeClassificationCalls,
        invalidateInspectionCalls: counters.invalidateInspectionCalls,
        rememberOpenClusterCalls: counters.rememberOpenClusterCalls,
        searchMatchCacheInvalidations: counters.searchMatchCacheInvalidations,
        damageActionSnapshotConstructions: counters.damageActionSnapshotConstructions,
        damageDiffs: counters.damageDiffs,
        contentIdentityAllocationSites: counters.contentIdentityAllocationSites,
        currentStyleIdCalls: counters.currentStyleIdCalls,
        currentStyleIdMisses: counters.currentStyleIdMisses,
        bulkRuns: counters.bulkRuns,
        bulkCharacters: counters.bulkCharacters,
        longestBulkRun: counters.longestBulkRun,
        meanBulkRunLength: counters.meanBulkRunLength,
        declinedBulkAttempts: counters.declinedBulkAttempts,
        cursorRow: terminal.geometry.cursor?.row ?? -1,
        cursorColumn: terminal.geometry.cursor?.column ?? -1,
        scrollbackRowCount: terminal.scrollbackRowCount,
        screenTextHash: stableHash(terminal.screenText)
    )
}

struct Report: Encodable {
    let corpora: [CorpusReport]
}

// Arguments: `<name>=<framed path> ...`.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty == false else {
    FileHandle.standardError.write(Data("usage: probe <name>=<path> ...\n".utf8))
    exit(2)
}

var reports: [CorpusReport] = []
for argument in arguments {
    guard let separator = argument.firstIndex(of: "=") else {
        FileHandle.standardError.write(Data("expected <name>=<path>, got \(argument)\n".utf8))
        exit(2)
    }
    let name = String(argument[argument.startIndex..<separator])
    let path = String(argument[argument.index(after: separator)...])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    reports.append(measure(name: name, chunks: decodeFramedChunks(data)))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(Report(corpora: reports)))
FileHandle.standardOutput.write(Data([0x0A]))
