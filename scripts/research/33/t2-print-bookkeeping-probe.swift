// Research doc 33, task T2: drives each committed corpus through an instrumented copy of
// the engine and reports the per-printed-cell bookkeeping counts.
//
// Compiled by `t2-print-bookkeeping.py` into one module together with the patched engine
// sources and `t2-print-bookkeeping-counters.swift`. It mirrors `measureFeedBatch`'s shape
// -- a fresh 179x66 terminal, the corpus's own chunk framing, no damage drain -- so the
// counts describe the same feed the `terminal-feed` workload measures.
//
// It holds measurement only. Corpus framing is the driver's job.
import Foundation

/// One corpus's counts. Every ratio carries the count that produced it, so a corpus that
/// printed nothing reads as zero prints rather than as a divide-by-zero.
struct CorpusReport: Encodable {
    let name: String
    let feedCalls: Int
    let byteCount: Int
    let printCalls: Int
    let unicodeClassificationCalls: Int
    let invalidateInspectionCalls: Int
    let invalidateInspectionFromPendingWrap: Int
    let invalidateInspectionFromPrintNarrow: Int
    let invalidateInspectionFromPrintWide: Int
    let rememberOpenClusterCalls: Int
    let searchMatchCacheInvalidations: Int
    let damageActionSnapshotConstructions: Int
    let damageDiffs: Int
    let contentIdentityAllocations: Int
    let currentStyleIdCalls: Int
    let currentStyleIdMisses: Int
    let asciiRuns: Int
    let asciiRunPrints: Int
    let longestAsciiRun: Int
    let meanAsciiRunLength: Double
    let predictedUnitsAfterBulkRuns: Int
    let nonPrintActions: Int
    let predictedSnapshotsAfterBulkRuns: Int
}

/// Reads the driver's framing: repeated 8-byte big-endian length followed by that many
/// bytes. Restated here because this probe compiles against `TerminalCore` alone.
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

func measure(name: String, chunks: [[UInt8]]) -> CorpusReport {
    t2Counters = T2Counters()
    guard var terminal = Terminal(columns: 179, rows: 66) else {
        fatalError("fixed benchmark geometry must be valid")
    }
    var byteCount = 0
    for chunk in chunks {
        byteCount += chunk.count
        terminal.feed(chunk)
    }
    t2Counters.closeRun()
    let counters = t2Counters
    // `damageDiffs` is one per parsed action, so it is the token count and its difference
    // from the print count is the non-print action count. Under `T8` a whole run is one
    // action, so `feed` would take one snapshot per run, per non-print action, and one
    // carried-forward snapshot per feed call.
    let nonPrintActions = counters.damageDiffs - counters.printCalls
    return CorpusReport(
        name: name,
        feedCalls: chunks.count,
        byteCount: byteCount,
        printCalls: counters.printCalls,
        unicodeClassificationCalls: counters.unicodeClassificationCalls,
        invalidateInspectionCalls: counters.invalidateInspectionCalls,
        invalidateInspectionFromPendingWrap: counters.invalidateInspectionFromPendingWrap,
        invalidateInspectionFromPrintNarrow: counters.invalidateInspectionFromPrintNarrow,
        invalidateInspectionFromPrintWide: counters.invalidateInspectionFromPrintWide,
        rememberOpenClusterCalls: counters.rememberOpenClusterCalls,
        searchMatchCacheInvalidations: counters.searchMatchCacheInvalidations,
        damageActionSnapshotConstructions: counters.damageActionSnapshotConstructions,
        damageDiffs: counters.damageDiffs,
        contentIdentityAllocations: counters.contentIdentityAllocations,
        currentStyleIdCalls: counters.currentStyleIdCalls,
        currentStyleIdMisses: counters.currentStyleIdMisses,
        asciiRuns: counters.asciiRuns,
        asciiRunPrints: counters.asciiRunPrints,
        longestAsciiRun: counters.longestAsciiRun,
        meanAsciiRunLength: counters.asciiRuns == 0
            ? 0
            : Double(counters.asciiRunPrints) / Double(counters.asciiRuns),
        predictedUnitsAfterBulkRuns: counters.predictedUnitsAfterBulkRuns,
        nonPrintActions: nonPrintActions,
        predictedSnapshotsAfterBulkRuns: counters.predictedUnitsAfterBulkRuns
            + nonPrintActions
            + chunks.count
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
