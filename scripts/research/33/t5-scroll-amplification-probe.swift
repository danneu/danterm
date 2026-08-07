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
    let scrollingDeliveries: Int

    let damagedRows: Int
    let idealDamagedRows: Int
    let maximumIdealDamagedRows: Int

    let submittedGlyphOccurrences: Int
    let idealGlyphOccurrences: Int
    let planGlyphOccurrences: Int

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
        visit { _, scalars, style in
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
/// nothing a translation cannot express.
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
    plan.textRuns.reduce(0) { total, run in
        guard let rows else { return total + run.cells.count }
        return rows.contains(run.row) ? total + run.cells.count : total
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
    guard var terminal = Terminal(columns: columns, rows: viewportRows) else {
        fatalError("fixed benchmark geometry must be valid")
    }
    var planner = PaneFramePlanner()
    let theme = RenderTheme.dark
    prefill(&terminal)

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
    var scrollingDeliveries = 0
    var damagedRows = 0
    var idealRowTotal = 0
    var maximumIdealRows = 0
    var submittedGlyphs = 0
    var idealGlyphs = 0
    var planGlyphs = 0

    var index = 0
    while index < events {
        let batch = min(linesPerDelivery, events - index)
        var chunk: [UInt8] = []
        for offset in 0..<batch { chunk += eventBytes(scenario: scenario, index: index + offset) }
        index += batch

        let before = snapshot(terminal)
        let beforeTop = terminal.scrollProjection.topRow
        bytes += chunk.count
        deliveries += 1
        terminal.feed(chunk)
        let afterTop = terminal.scrollProjection.topRow
        if afterTop != beforeTop { scrollingDeliveries += 1 }
        pendingIdealRows.formUnion(idealDamagedRows(
            before: before,
            beforeTop: beforeTop,
            after: snapshot(terminal),
            afterTop: afterTop
        ))

        // `TerminalPaneSession.consume` and `planIfNeeded`, gate for gate.
        pendingDamage.formUnion(terminal.drainDamage())
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
        } else {
            rowDamagedFrames += 1
            damagedRows += frameDamage.rows.count
        }
        idealRowTotal += frameIdealRows.count
        maximumIdealRows = max(maximumIdealRows, frameIdealRows.count)
        idealGlyphs += glyphOccurrences(plan, in: frameIdealRows)
        planGlyphs += glyphOccurrences(plan)

        // `SwiftTerminalSessionView.publish`, then its draw at one draw per publish.
        if frameDamage.isFull {
            pendingDisplayDamage = .full
        } else {
            pendingDisplayDamage.formUnion(TerminalDamage(
                rows: terminalDamageRowsWithGlyphHalo(frameDamage.rows, rowCount: plan.rows)
            ))
        }
        let drawingDamage = pendingDisplayDamage
        pendingDisplayDamage = .none
        let drawn = drawingDamage.isFull ? plan : clipFramePlan(plan, to: drawingDamage)
        submittedGlyphs += glyphOccurrences(drawn)
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
        scrollingDeliveries: scrollingDeliveries,
        damagedRows: damagedRows,
        idealDamagedRows: idealRowTotal,
        maximumIdealDamagedRows: maximumIdealRows,
        submittedGlyphOccurrences: submittedGlyphs,
        idealGlyphOccurrences: idealGlyphs,
        planGlyphOccurrences: planGlyphs,
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
