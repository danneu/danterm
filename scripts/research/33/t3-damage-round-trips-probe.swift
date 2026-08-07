// Research doc 33, task T3: drives each committed corpus through an instrumented copy of
// the engine and reports what one published frame costs the damage representation.
//
// Compiled by `t3-damage-round-trips.py` into one module together with the patched
// `TerminalCore` and `TerminalRenderPlanning` sources and
// `t3-damage-round-trips-counters.swift`.
//
// The loop below is the production sequence, restated headlessly, because the three
// owners of the damage path do not share a module: `TerminalPaneSession.consume` and
// `planIfNeeded` (drain, accumulate, plan, publish) and `SwiftTerminalSessionView.publish`
// and `drawingDamage` (halo, accumulate, coalesce into clip spans). Every gate production
// applies before it publishes is applied here -- non-empty damage, a terminal that
// actually changed, and the synchronized-output hold -- so a suppressed publish
// accumulates damage here exactly as it does live.
//
// It holds measurement only. Corpus framing is the driver's job.
import Foundation

/// One corpus's damage-path totals under one delivery framing.
///
/// Every aggregate carries the count that produced it: a corpus that published no frame
/// reads as zero frames rather than as zero cost per frame.
struct CorpusReport: Encodable {
    let name: String
    let chunkLimit: Int
    let feedCalls: Int
    let byteCount: Int

    let publishedFrames: Int
    let fullDamageFrames: Int
    let suppressedPublishes: Int
    let damagedRows: Int
    let maximumDamagedRows: Int
    let viewportRows: Int

    let drainCalls: Int
    let drainsWithDamage: Int
    let drainFullCalls: Int
    let drainRowInserts: Int

    let fullDamageCalls: Int
    let fullDamageEscalations: Int
    let fullFromNotFollowingBefore: Int
    let fullFromTopRowOrScreenChange: Int
    let fullFromNotFollowingAfter: Int

    let setAllocations: Int
    let arrayAllocations: Int
    let drainSetAllocations: Int
    let damageInitSetAllocations: Int
    let damageInitArrayAllocations: Int
    let haloSetAllocations: Int
    let spanSortArrayAllocations: Int

    let hashOperations: Int
    let damageInitRowHashes: Int
    let formUnionCalls: Int
    let formUnionEmptyCalls: Int
    let formUnionRowHashes: Int
    let haloCalls: Int
    let haloRowInserts: Int
    let plannerPredicateCalls: Int
    let plannerRowCopyLookups: Int
    let plannerMembershipLookups: Int

    let spanCalls: Int
    let spanSortRows: Int
    let spanSortAlreadyAscending: Int
    let spanSortInversions: Int
    let spansEmitted: Int
    let spansBeforeHalo: Int
    let haloedRowInvalidations: Int
    let drainedSetAscending: Int
}

/// Reads the driver's framing: repeated 8-byte big-endian length followed by that many
/// bytes. Restated here because this probe compiles against the engine sources alone.
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

/// Re-splits corpus chunks at a byte cap, which is how the PTY host delivers: at most one
/// 16 KiB read turn per fence. `limit <= 0` keeps the corpus's own framing.
func rechunk(_ chunks: [[UInt8]], limit: Int) -> [[UInt8]] {
    guard limit > 0 else { return chunks }
    var result: [[UInt8]] = []
    var pending: [UInt8] = []
    for chunk in chunks {
        pending.append(contentsOf: chunk)
        while pending.count >= limit {
            result.append(Array(pending[0..<limit]))
            pending.removeFirst(limit)
        }
    }
    if pending.isEmpty == false { result.append(pending) }
    return result
}

/// Counts maximal contiguous runs without going through the instrumented engine helper, so
/// asking what the damage looked like *before* the halo does not perturb the counters that
/// describe what the draw path actually did.
func spanCount(of rows: Set<Int>) -> Int {
    var count = 0
    for row in rows where rows.contains(row - 1) == false { count += 1 }
    return count
}

let columns = 179
let viewportRows = 66

func measure(name: String, chunks: [[UInt8]], chunkLimit: Int) -> CorpusReport {
    t3Counters = T3Counters()
    guard var terminal = Terminal(columns: columns, rows: viewportRows) else {
        fatalError("fixed benchmark geometry must be valid")
    }
    var planner = PaneFramePlanner()
    let theme = RenderTheme.dark

    // `TerminalPaneSession` state.
    var pendingDamage = TerminalDamage.none
    var lastPlannedTerminal: Terminal?
    // `SwiftTerminalSessionView` state.
    var pendingDisplayDamage = TerminalDamage.none

    var byteCount = 0
    var publishedFrames = 0
    var fullDamageFrames = 0
    var suppressedPublishes = 0
    var damagedRows = 0
    var maximumDamagedRows = 0
    var drainsWithDamage = 0
    var spansEmitted = 0
    var spansBeforeHalo = 0
    var haloedRowInvalidations = 0
    var drainedSetAscending = 0

    for chunk in chunks {
        byteCount += chunk.count
        terminal.feed(chunk)

        // `TerminalPaneSession.consume`: the fence drains the engine's damage and folds it
        // into whatever an earlier suppressed publish left behind.
        let drained = terminal.drainDamage()
        if drained != .none {
            drainsWithDamage += 1
            if drained.isFull == false {
                var previous: Int?
                var ascending = true
                for row in drained.rows {
                    if let previous, row < previous { ascending = false }
                    previous = row
                }
                if ascending { drainedSetAscending += 1 }
            }
        }
        pendingDamage.formUnion(drained)

        // `TerminalPaneSession.planIfNeeded`, gate for gate.
        guard pendingDamage != .none else { continue }
        guard terminal != lastPlannedTerminal else { suppressedPublishes += 1; continue }
        let presentation = terminal.presentation
        guard presentation.isSynchronizedOutputActive == false else {
            suppressedPublishes += 1
            continue
        }
        let plan = planner.planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: theme,
                isCursorVisible: presentation.isCursorVisible,
                cursorShape: presentation.cursorShape
            ),
            damage: pendingDamage
        )
        lastPlannedTerminal = terminal
        let frameDamage = pendingDamage
        pendingDamage = .none
        publishedFrames += 1
        if frameDamage.isFull {
            fullDamageFrames += 1
            damagedRows += viewportRows
            maximumDamagedRows = max(maximumDamagedRows, viewportRows)
        } else {
            damagedRows += frameDamage.rows.count
            maximumDamagedRows = max(maximumDamagedRows, frameDamage.rows.count)
        }

        // `SwiftTerminalSessionView.publish`.
        if frameDamage.isFull {
            pendingDisplayDamage = .full
        } else {
            spansBeforeHalo += spanCount(of: frameDamage.rows)
            let haloed = terminalDamageRowsWithGlyphHalo(frameDamage.rows, rowCount: plan.rows)
            pendingDisplayDamage.formUnion(TerminalDamage(rows: haloed))
            haloedRowInvalidations += haloed.count
        }

        // `SwiftTerminalSessionView.drawingDamage` plus `spanClipRects`, modelled at one
        // draw per publish. Fewer draws than publishes would lower `spanCalls` while
        // raising the row count each surviving call sorts; every other counter is
        // unaffected, because they all run on the publish side.
        let drawingDamage = pendingDisplayDamage
        pendingDisplayDamage = .none
        if drawingDamage.isFull == false {
            spansEmitted += terminalDamageMaximalContiguousSpans(drawingDamage.rows).count
        }
    }

    let counters = t3Counters
    return CorpusReport(
        name: name,
        chunkLimit: chunkLimit,
        feedCalls: chunks.count,
        byteCount: byteCount,
        publishedFrames: publishedFrames,
        fullDamageFrames: fullDamageFrames,
        suppressedPublishes: suppressedPublishes,
        damagedRows: damagedRows,
        maximumDamagedRows: maximumDamagedRows,
        viewportRows: viewportRows,
        drainCalls: counters.drainCalls,
        drainsWithDamage: drainsWithDamage,
        drainFullCalls: counters.drainFullCalls,
        drainRowInserts: counters.drainRowInserts,
        fullDamageCalls: counters.fullDamageCalls,
        fullDamageEscalations: counters.fullDamageEscalations,
        fullFromNotFollowingBefore: counters.fullFromNotFollowingBefore,
        fullFromTopRowOrScreenChange: counters.fullFromTopRowOrScreenChange,
        fullFromNotFollowingAfter: counters.fullFromNotFollowingAfter,
        setAllocations: counters.totalSetAllocations,
        arrayAllocations: counters.totalArrayAllocations,
        drainSetAllocations: counters.drainSetAllocations,
        damageInitSetAllocations: counters.damageInitSetAllocations,
        damageInitArrayAllocations: counters.damageInitArrayAllocations,
        haloSetAllocations: counters.haloSetAllocations,
        spanSortArrayAllocations: counters.spanSortArrayAllocations,
        hashOperations: counters.totalHashOperations,
        damageInitRowHashes: counters.damageInitRowHashes,
        formUnionCalls: counters.formUnionCalls,
        formUnionEmptyCalls: counters.formUnionEmptyCalls,
        formUnionRowHashes: counters.formUnionRowHashes,
        haloCalls: counters.haloCalls,
        haloRowInserts: counters.haloRowInserts,
        plannerPredicateCalls: counters.plannerPredicateCalls,
        plannerRowCopyLookups: counters.plannerRowCopyLookups,
        plannerMembershipLookups: counters.plannerMembershipLookups,
        spanCalls: counters.spanCalls,
        spanSortRows: counters.spanSortRows,
        spanSortAlreadyAscending: counters.spanSortAlreadyAscending,
        spanSortInversions: counters.spanSortInversions,
        spansEmitted: spansEmitted,
        spansBeforeHalo: spansBeforeHalo,
        haloedRowInvalidations: haloedRowInvalidations,
        drainedSetAscending: drainedSetAscending
    )
}

struct RunReport: Encodable {
    let chunkLimit: Int
    let corpora: [CorpusReport]
}

struct Report: Encodable {
    let runs: [RunReport]
}

// Arguments: `<chunk limit> <name>=<framed path> ...`.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let chunkLimit = arguments.first.flatMap(Int.init), arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: probe <chunk limit> <name>=<path> ...\n".utf8))
    exit(2)
}

var reports: [CorpusReport] = []
for argument in arguments.dropFirst() {
    guard let separator = argument.firstIndex(of: "=") else {
        FileHandle.standardError.write(Data("expected <name>=<path>, got \(argument)\n".utf8))
        exit(2)
    }
    let name = String(argument[argument.startIndex..<separator])
    let path = String(argument[argument.index(after: separator)...])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let chunks = rechunk(decodeFramedChunks(data), limit: chunkLimit)
    reports.append(measure(name: name, chunks: chunks, chunkLimit: chunkLimit))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(
    try encoder.encode(Report(runs: [RunReport(chunkLimit: chunkLimit, corpora: reports)]))
)
FileHandle.standardOutput.write(Data([0x0A]))
