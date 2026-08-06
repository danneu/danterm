// The pathological-input reading for doc 31's inherited condition 8: what does a real giant
// single logical line actually do to the landed store?
//
// `research/31/DD3` derived the forced-split cap as "no record exceeds 1/32 of the byte budget" -- 65,536
// cells at 16 MiB -- and `research/31/D2` ratified the rule rather than the number. The condition the
// campaign carried forward is that the cap is **derived, not measured**: no pathological input had
// been fed to a real engine to see what a session produces. `research/31/F4` named the shape from wezterm's
// own issue history ("1.5MB of json"). This file feeds it, through the real `Terminal` at the
// production budget, and reports what happens.
//
// Belongs here: pathological single-line stimuli, fed through the public `Terminal` API, and the
// four things the gate asks about -- how many records the line becomes, what it costs to admit,
// what browsing that region costs against an ordinary-content control, and whether copy still sees
// one logical line. Does not belong here: a threshold or a verdict (the gate's own words are "the
// cap bounds the hazard either way", so this reading is descriptive), and any edit to `F1`'s,
// `F2`'s, `F3`'s, `F7`'s, `F8`'s or `F9`'s probe files -- the isolation practice `F2` established
// and every probe since has kept. Nothing under `lib/TerminalCore/Sources/` is touched by it.
//
// Two stimuli, because the interesting question splits in two:
//
//   * `json` -- 1,500,000 bytes of minified JSON on one line, `research/31/F4`'s named shape. It is bigger
//     than the cap by ~23x and smaller than the arena, so it exercises the split rule with the
//     rest of history still present.
//   * `unbounded` -- one logical line of 24 MiB, larger than the whole arena. This is the case no
//     derivation covers: the line evicts its own head while it is still being printed, so the
//     store has to stay readable while the head record and the open tail record are pieces of the
//     same line.
//
// Both are fed in 4 KiB chunks, which is the memory probe's rule (`agent-docs/terminal-performance.md`:
// a single-shot feed materializes one action per token and puts tens of megabytes of transient
// blocks inside the window being measured).
//
// The browse reading is paired against a control terminal holding ordinary lines at the same
// display-row depth, in the same process, which is `agent-docs/measurement-discipline.md`'s
// "give every comparison a control the change cannot reach, measured in the same session". It is
// still one arm per case and carries no frozen rule, so it is descriptive: it says whether
// browsing the split region costs the same order as browsing ordinary history, not a percentage.
//
// Not part of the `just test` gate. Every measurement is skipped unless `DANTERM_LOGICAL_LINE_PROBE`
// is set. Run it as:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalLogicalLinePathologicalProbe
import Foundation
import Testing

@testable import TerminalCore

@Suite("Doc 31 pathological-input probe", .serialized)
struct TerminalLogicalLinePathologicalProbe {
    static let probeIsEnabled =
        ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil

    static let columns = 179
    static let rows = 66
    static let budget = Terminal.productionScrollbackBudgetBytes
    static let chunkBytes = 4096

    /// The cap the store derives for the production budget, read from the production code rather
    /// than transcribed, so a budget change moves this reading with it.
    static var forcedSplitCellCap: Int {
        Terminal.LogicalLineRecord.forcedSplitCellCount(forCapacity: budget)
    }

    // MARK: Stimuli

    /// `research/31/F4`'s named shape: minified JSON, one line, no newline until the end.
    ///
    /// Generated rather than captured so the probe is reproducible without a fixture, and shaped
    /// like real minified JSON (nested objects, quoted keys, numbers, no whitespace) so the cell
    /// stream is ordinary printable ASCII at one cell per byte.
    static func minifiedJSON(targetBytes: Int) -> [UInt8] {
        var text = "{\"records\":["
        var index = 0
        while text.utf8.count < targetBytes - 64 {
            if index > 0 { text += "," }
            text += """
                {"id":\(index),"name":"item-\(index)","tags":["alpha","beta","gamma"],\
                "value":\(index * 7919),"nested":{"a":\(index % 13),"b":\(index % 29),\
                "ok":\(index % 2 == 0 ? "true" : "false")}}
                """
            index += 1
        }
        text += "]}"
        return Array(text.utf8)
    }

    /// One logical line larger than the arena: the case where the line evicts its own head.
    static func unboundedLine(targetBytes: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(targetBytes)
        var index = 0
        while bytes.count < targetBytes {
            bytes.append(contentsOf: Array("segment-\(String(format: "%08d", index))-".utf8))
            index += 1
        }
        return bytes
    }

    /// Ordinary content at 179 columns: the control the browse reading is paired against.
    static func ordinaryLines(count: Int) -> [UInt8] {
        (0..<count).flatMap { line -> [UInt8] in
            let body = "ordinary history line \(String(format: "%07d", line)) "
            let filler = String(repeating: "abcdefghij", count: 16)
            return Array((body + filler + "\r\n").utf8)
        }
    }

    // MARK: Harness

    static func feed(_ terminal: inout Terminal, _ bytes: [UInt8]) {
        var start = 0
        while start < bytes.count {
            let end = min(start + chunkBytes, bytes.count)
            terminal.feed(Array(bytes[start..<end]))
            start = end
        }
    }

    static func nanoseconds(_ body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return DispatchTime.now().uptimeNanoseconds - start
    }

    /// One planned frame's worth of reads over retained history: the geometry pass and the cell
    /// pass, which is what `research/31/D3` Decision 1 rule 2 and `TerminalFrameLocateTests` call a
    /// viewport traversal.
    static func browseFrames(_ terminal: inout Terminal, topRow: Int, frames: Int) -> UInt64 {
        terminal.scroll(toTopRow: topRow)
        // Warm both read paths once so the timing measures a steady frame.
        _ = terminal.geometry
        terminal.forEachViewportCell(rows: 0..<rows) { _, _, _, _ in }
        var cells = 0
        let elapsed = nanoseconds {
            for _ in 0..<frames {
                _ = terminal.geometry
                terminal.forEachViewportCell(rows: 0..<rows) { _, _, _, _ in cells += 1 }
            }
        }
        precondition(cells > 0, "browse read no cells")
        return elapsed / UInt64(frames)
    }

    /// `admitNanoseconds` is nil when this state was reached without a timed feed -- printed as
    /// "not measured" rather than as zero, which is `agent-docs/measurement-discipline.md`'s
    /// first rule and the one a reader of a 0.0 would get exactly backwards.
    static func report(_ label: String, _ terminal: inout Terminal, admitNanoseconds: UInt64?) {
        let census = terminal.memoryCensus
        let admit = admitNanoseconds.map { String(format: "%.1f ms", Double($0) / 1_000_000) }
            ?? "not measured"
        print(
            """
            [31 condition 8] \(label)
              recordsRetained=\(census.scrollbackRecordCount) \
            displayRowsRetained=\(census.scrollbackRowCount)
              arenaBytesInUse=\(census.retainedArenaBytesInUse) \
            arenaCapacity=\(census.retainedArenaCapacityBytes) \
            budget=\(budget)
              retainedStoredCells=\(census.retainedStoredCellCount) \
            forcedSplitCellCap=\(forcedSplitCellCap)
              admit=\(admit)
            """
        )
    }

    // MARK: The reading

    @Test("Condition 8: a real giant single logical line", .enabled(if: probeIsEnabled))
    func pathologicalSingleLine() throws {
        print("[31 condition 8] load average before: \(loadAverageDescription())")
        print(
            "[31 condition 8] columns=\(Self.columns) rows=\(Self.rows) "
                + "budget=\(Self.budget) forcedSplitCellCap=\(Self.forcedSplitCellCap)"
        )

        // --- Stimulus 1: wezterm's 1.5 MB of JSON, on top of ordinary history.
        var json = try #require(Terminal(columns: Self.columns, rows: Self.rows))
        Self.feed(&json, Self.ordinaryLines(count: 2_000))
        let ordinaryRecordsBefore = json.memoryCensus.scrollbackRecordCount
        let ordinaryRowsBefore = json.memoryCensus.scrollbackRowCount
        let jsonBytes = Self.minifiedJSON(targetBytes: 1_500_000)
        let jsonAdmit = Self.nanoseconds { Self.feed(&json, jsonBytes) }
        json.feed(Array("\r\n".utf8))
        print(
            "[31 condition 8] json stimulus bytes=\(jsonBytes.count) "
                + "ordinaryRecordsBefore=\(ordinaryRecordsBefore) "
                + "ordinaryRowsBefore=\(ordinaryRowsBefore) "
                + "expectedPieces=\((jsonBytes.count + Self.forcedSplitCellCap - 1) / Self.forcedSplitCellCap)"
        )
        Self.report("json-1.5MB", &json, admitNanoseconds: jsonAdmit)

        // What copy sees: the split pieces must rejoin by adjacency into one logical line.
        let jsonText = json.primaryHistoryText
        let jsonLines = jsonText.split(separator: "\n", omittingEmptySubsequences: false)
        let longestJSONLine = jsonLines.map(\.count).max() ?? 0
        print(
            "[31 condition 8] json copy: textLines=\(jsonLines.count) "
                + "longestLine=\(longestJSONLine) "
                + "prefixMatches=\(jsonText.contains("{\"records\":[{\"id\":0,"))"
        )

        // Browsing the split region, against an ordinary-content control at the same depth, in
        // this same process -- and against the *same terminal's* ordinary region, which is the
        // control no difference between the two terminals can reach.
        let jsonRows = json.memoryCensus.scrollbackRowCount
        let jsonBrowse = Self.browseFrames(&json, topRow: max(0, jsonRows / 2), frames: 200)
        let jsonOwnOrdinaryBrowse = Self.browseFrames(&json, topRow: 0, frames: 200)
        var control = try #require(Terminal(columns: Self.columns, rows: Self.rows))
        Self.feed(&control, Self.ordinaryLines(count: jsonRows + 200))
        let controlRows = control.memoryCensus.scrollbackRowCount
        let controlBrowse = Self.browseFrames(&control, topRow: max(0, controlRows / 2), frames: 200)
        print(
            """
            [31 condition 8] browse (one frame: geometry + 66-row cell walk)
              json region: \(String(format: "%.1f", Double(jsonBrowse) / 1000)) us at \
            \(jsonRows) retained display rows
              same terminal, ordinary region (top): \
            \(String(format: "%.1f", Double(jsonOwnOrdinaryBrowse) / 1000)) us \
            (ratio=\(String(format: "%.1f", Double(jsonBrowse) / Double(jsonOwnOrdinaryBrowse)))x)
              separate ordinary control: \(String(format: "%.1f", Double(controlBrowse) / 1000)) us at \
            \(controlRows) retained display rows
              ratio=\(String(format: "%.3f", Double(jsonBrowse) / Double(controlBrowse)))x
            """
        )

        // The width change: the counting pass over a history whose records are near-cap, against
        // the same control.
        let jsonNarrow = Self.nanoseconds { json.resize(columns: 100, rows: Self.rows) }
        let jsonWiden = Self.nanoseconds { json.resize(columns: Self.columns, rows: Self.rows) }
        let controlNarrow = Self.nanoseconds { control.resize(columns: 100, rows: Self.rows) }
        let controlWiden = Self.nanoseconds { control.resize(columns: Self.columns, rows: Self.rows) }
        print(
            """
            [31 condition 8] width change 179 -> 100 -> 179
              json:    \(String(format: "%.2f", Double(jsonNarrow) / 1_000_000)) ms / \
            \(String(format: "%.2f", Double(jsonWiden) / 1_000_000)) ms \
            (records=\(json.memoryCensus.scrollbackRecordCount))
              control: \(String(format: "%.2f", Double(controlNarrow) / 1_000_000)) ms / \
            \(String(format: "%.2f", Double(controlWiden) / 1_000_000)) ms \
            (records=\(control.memoryCensus.scrollbackRecordCount))
            """
        )
        print(
            "[31 condition 8] json after resize cycle: "
                + "records=\(json.memoryCensus.scrollbackRecordCount) "
                + "rows=\(json.memoryCensus.scrollbackRowCount) "
                + "arenaBytesInUse=\(json.memoryCensus.retainedArenaBytesInUse)"
        )

        // --- Stimulus 2: one logical line larger than the whole arena.
        var unbounded = try #require(Terminal(columns: Self.columns, rows: Self.rows))
        Self.feed(&unbounded, Self.ordinaryLines(count: 500))
        let unboundedBytes = Self.unboundedLine(targetBytes: 24 * 1024 * 1024)
        let unboundedAdmit = Self.nanoseconds { Self.feed(&unbounded, unboundedBytes) }
        print(
            "[31 condition 8] unbounded stimulus bytes=\(unboundedBytes.count) "
                + "expectedPieces="
                + "\((unboundedBytes.count + Self.forcedSplitCellCap - 1) / Self.forcedSplitCellCap)"
        )
        Self.report("unbounded-24MiB-open", &unbounded, admitNanoseconds: unboundedAdmit)

        let unboundedRows = unbounded.memoryCensus.scrollbackRowCount
        let unboundedBrowse = Self.browseFrames(
            &unbounded, topRow: max(0, unboundedRows / 2), frames: 200
        )
        print(
            "[31 condition 8] unbounded browse: "
                + "\(String(format: "%.1f", Double(unboundedBrowse) / 1000)) us per frame at "
                + "\(unboundedRows) retained display rows"
        )
        let unboundedText = unbounded.primaryHistoryText
        let unboundedLines = unboundedText.split(separator: "\n", omittingEmptySubsequences: false)
        print(
            "[31 condition 8] unbounded copy: textLines=\(unboundedLines.count) "
                + "longestLine=\(unboundedLines.map(\.count).max() ?? 0) "
                + "ordinaryLineSurvivors="
                + "\(unboundedLines.filter { $0.hasPrefix("ordinary history line") }.count)"
        )

        let unboundedNarrow = Self.nanoseconds { unbounded.resize(columns: 100, rows: Self.rows) }
        let unboundedWiden = Self.nanoseconds {
            unbounded.resize(columns: Self.columns, rows: Self.rows)
        }
        print(
            "[31 condition 8] unbounded width change 179 -> 100 -> 179: "
                + "\(String(format: "%.2f", Double(unboundedNarrow) / 1_000_000)) ms / "
                + "\(String(format: "%.2f", Double(unboundedWiden) / 1_000_000)) ms, "
                + "rowsAfter=\(unbounded.memoryCensus.scrollbackRowCount)"
        )

        // Close the line and read the store back once more: the open tail becomes a closed
        // record, which is the state a session is left in after the flood ends.
        unbounded.feed(Array("\r\n".utf8))
        Self.report("unbounded-24MiB-closed", &unbounded, admitNanoseconds: nil)

        // --- The middle of the curve. Two points are not a trend
        // (`agent-docs/measurement-discipline.md`), and "browsing a near-cap record is 40x an
        // ordinary one" is a claim about a curve. This ladder holds the retained display-row
        // depth roughly constant and varies only the cells per logical line, so the only thing
        // that moves between rungs is how large the record a display row is folded out of is.
        print("[31 condition 8] browse cost against cells per logical line (depth held ~constant)")
        for cellsPerLine in [Self.columns, 512, 2_048, 8_192, 32_768, Self.forcedSplitCellCap] {
            var rung = try #require(Terminal(columns: Self.columns, rows: Self.rows))
            let lineCount = max(1, 900_000 / cellsPerLine)
            var bytes: [UInt8] = []
            for line in 0..<lineCount {
                let head = "line-\(String(format: "%06d", line))-"
                var body = head
                while body.utf8.count < cellsPerLine {
                    body += "0123456789abcdef"
                }
                bytes.append(contentsOf: Array(body.utf8.prefix(cellsPerLine)))
                bytes.append(contentsOf: Array("\r\n".utf8))
            }
            Self.feed(&rung, bytes)
            let rungRows = rung.memoryCensus.scrollbackRowCount
            let rungBrowse = Self.browseFrames(&rung, topRow: max(0, rungRows / 2), frames: 100)
            print(
                "  cellsPerLine=\(cellsPerLine) records=\(rung.memoryCensus.scrollbackRecordCount) "
                    + "rows=\(rungRows) frame="
                    + "\(String(format: "%.1f", Double(rungBrowse) / 1000)) us "
                    + "perRow=\(String(format: "%.2f", Double(rungBrowse) / 1000 / Double(Self.rows))) us"
            )
        }

        print("[31 condition 8] load average after: \(loadAverageDescription())")

        // The only assertions this probe makes are the store's own bound and its readability --
        // the gate asks what the input produces, not whether it clears a threshold.
        for terminal in [json, control, unbounded] {
            let census = terminal.memoryCensus
            #expect(census.retainedArenaBytesInUse <= census.retainedArenaCapacityBytes)
            #expect(census.retainedArenaCapacityBytes <= Self.budget)
        }
    }
}
