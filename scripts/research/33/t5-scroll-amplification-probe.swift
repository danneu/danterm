// Research doc 33, task T5: drives a synthetic scroll at the bottom of a full screen
// through an instrumented copy of the engine and reports what one scroll event costs.
//
// Compiled by `t5-scroll-amplification.py` into one module together with the patched
// `TerminalCore` and `TerminalRenderPlanning` sources and
// `t5-scroll-amplification-counters.swift`.
//
// The loop below is the same production sequence `t3-damage-round-trips-probe.swift`
// restates -- `TerminalPaneSession.consume` and `planIfNeeded`, then
// `SwiftTerminalSessionView.publish` and its draw -- narrowed to one question: for a
// stimulus whose information content is a translation plus `k` new rows, how many rows does
// the frame damage and how many glyph occurrences does the clipped plan hand the drawer?
//
// The ideal is measured, not assumed. Every delivery snapshots the viewport before and
// after, and a row counts as ideally damaged only when its content differs from the row
// that translated into its place -- which is exactly the damage `T9`'s shift component
// would produce. The amplification is then the real count over that measured ideal.
import Foundation

let columns = 179
let viewportRows = 66
/// One column short of the grid so a line plus `CR LF` never triggers autowrap, which would
/// make the stimulus scroll twice per line and confuse the amplification denominator.
let lineWidth = 178

/// One cell's observable content, so a row can be compared against the row that translated
/// into its place without going through the planner.
struct CellSnapshot: Equatable {
    let scalars: TerminalScalars
    let style: TerminalStyle
}

/// One stimulus, its measured totals, and the counts that produced every average.
///
/// `publishedFrames` sits beside every per-frame aggregate deliberately: a scenario that
/// published nothing must read as zero frames, not as zero cost per frame.
struct ScenarioReport: Encodable {
    let name: String
    let linesPerDelivery: Int
    let events: Int
    let deliveries: Int
    let bytes: Int

    let publishedFrames: Int
    let suppressedPublishes: Int
    let fullDamageFrames: Int
    let rowDamagedFrames: Int
    let shiftFrames: Int
    let scrollingDeliveries: Int

    let damagedRows: Int
    let foldedDamagedRows: Int
    let idealDamagedRows: Int
    let maximumIdealDamagedRows: Int

    let submittedGlyphOccurrences: Int
    let idealGlyphOccurrences: Int
    let planGlyphOccurrences: Int

    let mirrorEstablishRenders: Int
    let mirrorAppliedFrames: Int
    let mirrorBlitRowTotal: Int

    let plannerRowsInspected: Int
    let plannerCellsInspected: Int

    let fullDamageCalls: Int
    let fullDamageEscalations: Int
    let fullFromNotFollowingBefore: Int
    let fullFromTopRowOrScreenChange: Int
    let fullFromNotFollowingAfter: Int
    let drainRowInserts: Int
}

func snapshot(_ terminal: Terminal) -> [[CellSnapshot]] {
    var rows = [[CellSnapshot]](repeating: [], count: viewportRows)
    terminal.forEachViewportRow(rows: 0..<viewportRows) { row, visit in
        var cells: [CellSnapshot] = []
        cells.reserveCapacity(columns)
        visit { _, _, scalars, style in
            cells.append(CellSnapshot(scalars: scalars, style: style))
        }
        rows[row] = cells
    }
    return rows
}

/// Rows whose content is not the translation of some row that was already on screen.
///
/// This is the damage a shift-carrying representation would publish: the viewport moved by
/// `afterTop - beforeTop`, so a row matching its source row across that shift changed
/// nothing a translation cannot express. The tops must be `absoluteViewportTopRow`, not
/// `scrollProjection.topRow`: at the history budget the append and the eviction cancel in
/// the retained-relative value while the content still translates (research/33 F19), and a
/// retained-relative delta would misread the whole at-budget arm as 66 changed rows.
func idealDamagedRows(
    before: [[CellSnapshot]],
    beforeTop: Int,
    after: [[CellSnapshot]],
    afterTop: Int
) -> Set<Int> {
    let delta = afterTop - beforeTop
    var rows: Set<Int> = []
    for row in 0..<viewportRows {
        let source = row + delta
        if source < 0 || source >= viewportRows || before[source] != after[row] {
            rows.insert(row)
        }
    }
    return rows
}

func glyphOccurrences(_ plan: RenderFramePlan, in rows: Set<Int>? = nil) -> Int {
    plan.rows.reduce(0) { total, row in
        total + row.textRuns.reduce(0) { runTotal, run in
            guard let rows else { return runTotal + run.cells.count }
            return rows.contains(run.row) ? runTotal + run.cells.count : runTotal
        }
    }
}

/// Builds one stimulus event's bytes.
///
/// - `bare-newline`: a lone `LF` at the bottom of a full screen -- the minimum-information
///   scroll, one translation and one blank row.
/// - `text-line`: a full line of text and `CR LF`, which is what streaming output actually
///   emits and the only stimulus whose screen stays full.
/// - `rewrite-bottom-row`: `CR` and a full line of text, the control that changes exactly as
///   many cells as `text-line` without moving the viewport window.
func eventBytes(scenario: String, index: Int) -> [UInt8] {
    let letter = UInt8(ascii: "a") + UInt8(index % 26)
    let line = [UInt8](repeating: letter, count: lineWidth)
    switch scenario {
    case "bare-newline":
        return [0x0A]
    case "text-line":
        return line + [0x0D, 0x0A]
    case "rewrite-bottom-row":
        return [0x0D] + line
    default:
        fatalError("unknown scenario \(scenario)")
    }
}

/// Fills every viewport row with text and leaves the cursor on the bottom row.
///
/// `text-line` and `rewrite-bottom-row` need the cursor at column 0 of a written bottom row,
/// so they end their prefill with `CR`; `bare-newline` wants a screen with no blank row on
/// it at all, and its `LF` does not care what column the cursor is in.
func prefill(_ terminal: inout Terminal) {
    var bytes: [UInt8] = []
    for row in 0..<viewportRows {
        bytes += [UInt8](repeating: UInt8(ascii: "A") + UInt8(row % 26), count: lineWidth)
        if row < viewportRows - 1 { bytes += [0x0D, 0x0A] }
    }
    bytes += [0x0D]
    terminal.feed(bytes)
    _ = terminal.drainDamage()
}

func measure(scenario: String, events: Int, linesPerDelivery: Int) -> ScenarioReport {
    // The `-at-budget` arm saturates a small scrollback budget first, so every
    // measured scroll runs in the frozen-topRow eviction regime a long-running
    // pane occupies (research/33 F19's second rider).
    let atBudget = scenario.hasSuffix("-at-budget")
    let stimulus = atBudget ? String(scenario.dropLast("-at-budget".count)) : scenario
    let made = atBudget
        ? Terminal(columns: columns, rows: viewportRows, scrollbackBudgetBytes: 64 * 1024)
        : Terminal(columns: columns, rows: viewportRows)
    guard var terminal = made else {
        fatalError("fixed benchmark geometry must be valid")
    }
    var planner = PaneFramePlanner()
    let theme = RenderTheme.dark
    prefill(&terminal)
    if atBudget {
        for index in 0..<600 {
            terminal.feed(eventBytes(scenario: "text-line", index: index))
        }
        _ = terminal.drainDamage()
    }

    // The prefill is not the measurement: plan one frame from it so the planner holds a
    // retained generation, exactly as it does mid-stream, and reset the counters after.
    _ = planner.planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: theme,
            isCursorVisible: terminal.presentation.isCursorVisible,
            cursorShape: terminal.presentation.cursorShape
        ),
        damage: .full
    )
    var lastPlannedTerminal: Terminal? = terminal
    t5Counters = T5Counters()

    var pendingDamage = TerminalDamage.none
    var pendingDisplayDamage = TerminalDamage.none
    var pendingIdealRows: Set<Int> = []

    var bytes = 0
    var deliveries = 0
    var publishedFrames = 0
    var suppressedPublishes = 0
    var fullDamageFrames = 0
    var rowDamagedFrames = 0
    var shiftFrames = 0
    var scrollingDeliveries = 0
    var damagedRows = 0
    var foldedDamagedRows = 0
    var idealRowTotal = 0
    var maximumIdealRows = 0
    var submittedGlyphs = 0
    var idealGlyphs = 0
    var planGlyphs = 0
    var mirrorValid = false
    var mirrorEstablishRenders = 0
    var mirrorAppliedFrames = 0
    var mirrorBlitRows = 0
    // The store's reach ledger, tracked gate for gate with
    // `TerminalFrameBackingStore` at the canonical 2x metrics: 31 px cell,
    // ASCII ink from 4 px below the row top to 2 px past its bottom
    // (`t14-ink-envelope-probe.swift`, research/33 D9).
    let cellHeightPixels = 31
    let inkEnvelope = RenderInkEnvelope(inkTopOffsetPixels: 4, inkBottomOffsetPixels: 2)
    var reachLedger = [RenderRowReach?](repeating: nil, count: viewportRows)

    var index = 0
    while index < events {
        let batch = min(linesPerDelivery, events - index)
        var chunk: [UInt8] = []
        for offset in 0..<batch { chunk += eventBytes(scenario: stimulus, index: index + offset) }
        index += batch

        let before = snapshot(terminal)
        let beforeTop = terminal.absoluteViewportTopRow
        bytes += chunk.count
        deliveries += 1
        terminal.feed(chunk)
        let afterTop = terminal.absoluteViewportTopRow
        if afterTop != beforeTop { scrollingDeliveries += 1 }
        pendingIdealRows.formUnion(idealDamagedRows(
            before: before,
            beforeTop: beforeTop,
            after: snapshot(terminal),
            afterTop: afterTop
        ))

        // `TerminalPaneSession.consume` and `planIfNeeded`, gate for gate.
        let drained = terminal.drainDamage()
        if drained.isFull == false { t5Counters.drainRowInserts += drained.damagedRowCount }
        pendingDamage.formUnion(drained)
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
        let frameIdealRows = pendingIdealRows
        pendingIdealRows = []

        publishedFrames += 1
        if frameDamage.isFull {
            fullDamageFrames += 1
            damagedRows += viewportRows
            foldedDamagedRows += viewportRows
        } else {
            rowDamagedFrames += 1
            if frameDamage.shift != nil { shiftFrames += 1 }
            damagedRows += frameDamage.damagedRowCount
            foldedDamagedRows += frameDamage.expandingShift().damagedRowCount
        }
        idealRowTotal += frameIdealRows.count
        maximumIdealRows = max(maximumIdealRows, frameIdealRows.count)
        idealGlyphs += glyphOccurrences(plan, in: frameIdealRows)
        planGlyphs += glyphOccurrences(plan)

        // The owned frame store's render, gate for gate with
        // `TerminalFrameBackingStore.apply` (research/33 T9 view half, T14
        // derived halo): while the store is current a shift is a translation
        // in owned memory, glyph submission is the derived apply shape --
        // erase spans from the damaged rows' bands plus their old and new ink
        // reach, plan rows from reach intersection, through the *same*
        // `renderApplyShape` the store calls -- and displaying submits
        // nothing. `.full` stales the store at zero cost, a shift-carrying
        // frame on a stale store pays one full establish render, and row
        // damage on a stale store folds exactly as before.
        if frameDamage.isFull {
            mirrorValid = false
            pendingDisplayDamage = .full
            let drawingDamage = pendingDisplayDamage
            pendingDisplayDamage = .none
            _ = drawingDamage
            submittedGlyphs += glyphOccurrences(plan)
        } else if mirrorValid || frameDamage.shift != nil {
            if mirrorValid {
                let indices = frameDamage.rowIndices
                var staleStrips: [Range<Int>] = []
                if let shift = frameDamage.shift {
                    // Strips on the pre-move ledger, then the ledger rides
                    // the translation exactly as the store's pixel memmove
                    // does; vacated entries stay stale and are rebuilt by
                    // the damaged-row render below.
                    staleStrips = renderTranslationStaleStrips(
                        region: shift.region,
                        delta: shift.delta,
                        cellHeightPixels: cellHeightPixels,
                        reaches: reachLedger
                    )
                    let survivors = shift.region.count - abs(shift.delta)
                    let destination = shift.delta > 0
                        ? shift.region.lowerBound + shift.delta
                        : shift.region.lowerBound
                    let source = shift.delta > 0
                        ? shift.region.lowerBound
                        : shift.region.lowerBound - shift.delta
                    let moved = Array(reachLedger[source..<(source + survivors)])
                    reachLedger.replaceSubrange(
                        destination..<(destination + survivors),
                        with: moved
                    )
                }
                let newReaches = renderRowReaches(
                    of: plan,
                    envelope: inkEnvelope,
                    cellHeightPixels: cellHeightPixels
                )
                let shape = renderApplyShape(
                    damagedRows: indices,
                    rowCount: viewportRows,
                    cellHeightPixels: cellHeightPixels,
                    oldReaches: reachLedger,
                    newReaches: newReaches,
                    extraEraseIntervals: staleStrips
                )
                submittedGlyphs += glyphOccurrences(
                    plan,
                    in: Set(shape.planDamage.expandingShift().rowIndices)
                )
                for row in indices where row < viewportRows {
                    reachLedger[row] = newReaches[row]
                }
                mirrorAppliedFrames += 1
            } else {
                submittedGlyphs += glyphOccurrences(plan)
                reachLedger = renderRowReaches(
                    of: plan,
                    envelope: inkEnvelope,
                    cellHeightPixels: cellHeightPixels
                )
                mirrorEstablishRenders += 1
                mirrorValid = true
            }
            mirrorBlitRows += frameDamage
                .expandingShift()
                .withGlyphHalo(rowCount: plan.rowCount)
                .damagedRowCount
        } else {
            pendingDisplayDamage.formUnion(
                frameDamage.expandingShift().withGlyphHalo(rowCount: plan.rowCount)
            )
            let drawingDamage = pendingDisplayDamage
            pendingDisplayDamage = .none
            submittedGlyphs += glyphOccurrences(
                plan,
                in: drawingDamage.isFull ? nil : Set(drawingDamage.expandingShift().rowIndices)
            )
        }
    }

    let counters = t5Counters
    return ScenarioReport(
        name: scenario,
        linesPerDelivery: linesPerDelivery,
        events: events,
        deliveries: deliveries,
        bytes: bytes,
        publishedFrames: publishedFrames,
        suppressedPublishes: suppressedPublishes,
        fullDamageFrames: fullDamageFrames,
        rowDamagedFrames: rowDamagedFrames,
        shiftFrames: shiftFrames,
        scrollingDeliveries: scrollingDeliveries,
        damagedRows: damagedRows,
        foldedDamagedRows: foldedDamagedRows,
        idealDamagedRows: idealRowTotal,
        maximumIdealDamagedRows: maximumIdealRows,
        submittedGlyphOccurrences: submittedGlyphs,
        idealGlyphOccurrences: idealGlyphs,
        planGlyphOccurrences: planGlyphs,
        mirrorEstablishRenders: mirrorEstablishRenders,
        mirrorAppliedFrames: mirrorAppliedFrames,
        mirrorBlitRowTotal: mirrorBlitRows,
        plannerRowsInspected: counters.plannerRowsInspected,
        plannerCellsInspected: counters.plannerCellsInspected,
        fullDamageCalls: counters.fullDamageCalls,
        fullDamageEscalations: counters.fullDamageEscalations,
        fullFromNotFollowingBefore: counters.fullFromNotFollowingBefore,
        fullFromTopRowOrScreenChange: counters.fullFromTopRowOrScreenChange,
        fullFromNotFollowingAfter: counters.fullFromNotFollowingAfter,
        drainRowInserts: counters.drainRowInserts
    )
}

struct Report: Encodable {
    let columns: Int
    let viewportRows: Int
    let lineWidth: Int
    let scenarios: [ScenarioReport]
}

// Arguments: `<events> <scenario>:<lines per delivery> ...`.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let events = arguments.first.flatMap(Int.init), arguments.count > 1 else {
    FileHandle.standardError.write(
        Data("usage: probe <events> <scenario>:<lines per delivery> ...\n".utf8)
    )
    exit(2)
}

var scenarios: [ScenarioReport] = []
for argument in arguments.dropFirst() {
    let parts = argument.split(separator: ":")
    guard parts.count == 2, let batch = Int(parts[1]), batch > 0 else {
        FileHandle.standardError.write(Data("expected <scenario>:<batch>, got \(argument)\n".utf8))
        exit(2)
    }
    scenarios.append(
        measure(scenario: String(parts[0]), events: events, linesPerDelivery: batch)
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(Report(
    columns: columns,
    viewportRows: viewportRows,
    lineWidth: lineWidth,
    scenarios: scenarios
)))
FileHandle.standardOutput.write(Data([0x0A]))
