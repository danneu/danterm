// Encodes a read-only terminal state snapshot into the synchronization byte stream.
// Mutation and synchronization decoding remain with Terminal; history selection, screen replay,
// control-state reconstruction, and byte writing belong here.

import BitCollections
import DequeModule

/// Owns state-synchronization history selection and byte encoding without write access to Terminal.
struct TerminalStateSynchronizationEncoder {
    /// Captures every serialization dependency in one immutable value.
    struct Input {
        let columnCount: Int
        let rowCount: Int
        let history: Terminal.LogicalLineStore
        let primaryScreenRows: Deque<Terminal.GridRow>
        let primaryScreenState: Terminal.ScreenState
        /// The alternate screen the source retains but is not showing, and only when re-entering
        /// it would show or restore something a never-entered screen would not.
        let retainedAlternateScreen: Terminal.ScreenState?
        let screen: Terminal.ScreenState
        let isAlternateScreenActive: Bool
        let scrollRegion: Range<Int>?
        let activeScrollRegion: Range<Int>
        let tabStops: BitSet
        let modes: Terminal.TerminalModes
        let currentStyle: TerminalStyle
        let hyperlinkTargets: [Terminal.HyperlinkId: TerminalHyperlink]
        let hyperlinkPen: Terminal.HyperlinkId?
        let styleTable: [Terminal.StyleId: TerminalStyle]
        let promptRedrawMode: Terminal.PromptRedrawMode
        let lastPrintedCluster: Terminal.LastPrintedCluster?
        let clusterContext: Terminal.ClusterContext?
        let charsets: TerminalCharsetState
        let inputSynchronizationPrefix: [UInt8]
    }

    private let input: Input

    /// Accepts the one terminal-owned snapshot that fences all state read by this encoding pass.
    init(input: Input) {
        self.input = input
    }

    private var columnCount: Int { input.columnCount }
    private var rowCount: Int { input.rowCount }
    private var history: Terminal.LogicalLineStore { input.history }
    private var historyRowCount: Int { history.grandDisplayRowTotal }
    private var primaryScreenRows: Deque<Terminal.GridRow> { input.primaryScreenRows }
    private var primaryScreenState: Terminal.ScreenState { input.primaryScreenState }
    private var screen: Terminal.ScreenState { input.screen }
    private var isAlternateScreenActive: Bool { input.isAlternateScreenActive }
    private var scrollRegion: Range<Int>? { input.scrollRegion }
    private var activeScrollRegion: Range<Int> { input.activeScrollRegion }
    private var tabStops: BitSet { input.tabStops }
    private var modes: Terminal.TerminalModes { input.modes }
    private var currentStyle: TerminalStyle { input.currentStyle }
    private var hyperlinkTargets: [Terminal.HyperlinkId: TerminalHyperlink] {
        input.hyperlinkTargets
    }
    private var hyperlinkPen: Terminal.HyperlinkId? { input.hyperlinkPen }
    /// The replay reconstructs the primary screen beneath whatever is showing, so every
    /// retained row is read through the primary stream: its seam is never severed.
    private var primaryDisplayRows: Terminal.DisplayRowProjector {
        Terminal.DisplayRowProjector(
            history: history,
            grid: primaryScreenRows,
            columns: columnCount,
            seam: .preserved
        )
    }
    private var promptRedrawMode: Terminal.PromptRedrawMode { input.promptRedrawMode }
    private var lastPrintedCluster: Terminal.LastPrintedCluster? { input.lastPrintedCluster }
    private var clusterContext: Terminal.ClusterContext? { input.clusterContext }
    private var charsets: TerminalCharsetState { input.charsets }
    private var inputSynchronizationPrefix: [UInt8] { input.inputSynchronizationPrefix }

    /// Encodes one synchronization, selecting only the complete retained suffix its budget admits.
    func encode(historyBudgetBytes: Int?) -> TerminalStateSynchronization {
        var historyStart = 0
        if let historyBudgetBytes {
            historyStart = boundedHistoryStart(budget: historyBudgetBytes)
        }
        while true {
            let encoded = encodeStateSynchronization(historyStart: historyStart)
            guard let historyBudgetBytes,
                  encoded.historyBytes > historyBudgetBytes,
                  historyStart < historyRowCount
            else { return encoded.synchronization }
            // The estimate measures rows separately. A joint encode can borrow a wide grapheme
            // across the history/grid seam, so drop one complete logical line and verify again.
            historyStart = alignedHistoryStart(historyStart + 1)
        }
    }

    private func style(for id: Terminal.StyleId) -> TerminalStyle {
        guard let style = input.styleTable[id] else {
            preconditionFailure("every live style id must resolve in the synchronization snapshot")
        }
        return style
    }

    /// Pairs one serialization with the byte cost of the history rows inside it, which is what
    /// the budget is denominated in.
    private struct EncodedStateSynchronization {
        let synchronization: TerminalStateSynchronization
        let historyBytes: Int
    }

    private func encodeStateSynchronization(
        historyStart: Int
    ) -> EncodedStateSynchronization {
        var writer = StateSynchronizationWriter()
        writer.append("\u{1B}c\u{1B}[3J\u{1B}]133;S;redraw=0\u{7}")

        Instrument.synchronizationRetainedRowVisit.record(count: historyRowCount - historyStart)
        let projector = primaryDisplayRows
        var primaryRows = history.paintedDisplayRows(in: historyStart..<historyRowCount)
        primaryRows.reserveCapacity(primaryRows.count + rowCount)
        for index in primaryRows.indices {
            primaryRows[index] = projector
                .project(primaryRows[index], projector.facts(forHistoryRow: historyStart + index))
                .materialized(to: columnCount)
        }
        primaryRows.append(contentsOf: primaryScreenRows.map { $0.materialized(to: columnCount) })
        let historyBytes = writer.appendRows(
            primaryRows,
            encoder: self,
            measuringFirst: historyRowCount - historyStart
        )

        // Strictly before the primary's own reconstruction: this replay switches screens, which
        // carries the live cursor across and drops pending wrap, and it paints an offscreen grid
        // with a neutral pen and neutral wrap, origin, and insert modes. Ordered after the
        // primary's reconstruction it would silently undo it.
        if let retained = input.retainedAlternateScreen {
            appendRetainedAlternateScreen(retained, to: &writer)
        }

        let primaryState = primaryScreenState
        appendControlState(for: primaryState, includeReplyEmittingModes: true, to: &writer)

        if isAlternateScreenActive {
            writer.append("\u{1B}[0m")
            // Named by hand, and it has to stay 1047: this is the one re-entry the policy value
            // cannot express. 1049 would save the live cursor into the primary slot the replay
            // has just reconstructed and destroy it.
            writer.append(decPrivateModeSequence(.alternateScreen, enabled: true))
            // Primary control reconstruction can enable modes that change how row bytes paint.
            // Switch screens first so neutralizing them cannot mutate the reconstructed primary
            // cursor; appendControlState restores the source modes after the rows are in place.
            writer.append(ansiModeSequence(.insert, enabled: false))
            writer.append(decPrivateModeSequence(.origin, enabled: false))
            writer.append(decPrivateModeSequence(.autoWrap, enabled: true))
            writer.append("\u{1B}[r")
            writer.append("\u{1B}[H")
            writer.appendRows(screen.rows.map { $0.materialized(to: columnCount) }, encoder: self)
            // The saved-cursor replay changes live cursor modes, so restore the shared modes.
            // A mode whose set emits a reply already holds its right value from the primary's
            // reconstruction, and re-emitting it would put a second reply on the wire.
            appendControlState(for: screen, includeReplyEmittingModes: false, to: &writer)
        }

        writer.append(promptRedrawSequence)
        appendGraphemeSynchronization(to: &writer)
        // Last, because the replica must stay all-ASCII while the encode replays graphic bytes:
        // stored cell scalars are already translated, so re-translating them would corrupt them.
        writer.append("\u{1B}]133;S;charset=\(charsetSynchronizationValue(charsets))\u{7}")
        writer.append(inputSynchronizationPrefix)
        return EncodedStateSynchronization(
            synchronization: TerminalStateSynchronization(
                columns: columnCount,
                rows: rowCount,
                bytes: writer.bytes,
                droppedHistoryRows: historyStart
            ),
            historyBytes: historyBytes
        )
    }

    /// Estimates the oldest history row a budget can afford, walking back from the newest.
    ///
    /// Each candidate is encoded on its own, which costs more than the joint encode of the
    /// same rows -- style state carries across rows there -- so the running total is an
    /// estimate the real encode is expected to come in under. The walk stops the moment the
    /// budget is exceeded, so its cost tracks the budget rather than the retained depth.
    private func boundedHistoryStart(budget: Int) -> Int {
        // The joint encode ends a hard-broken row with a style reset and CRLF; a row measured
        // alone has no following row and emits neither.
        let separatorAllowance = styleSequence(TerminalStyle()).utf8.count + 2
        let projector = primaryDisplayRows
        var spent = 0
        var start = historyRowCount
        while start > 0 {
            let candidate = start - 1
            Instrument.synchronizationRetainedRowVisit.record()
            guard let stored = history.paintedDisplayRow(at: candidate) else {
                preconditionFailure("retained history count must address every retained row")
            }
            let row = projector.project(stored, projector.facts(forHistoryRow: candidate))
            var writer = StateSynchronizationWriter()
            writer.appendRows([row.materialized(to: columnCount)], encoder: self)
            spent += writer.bytes.count + separatorAllowance
            guard spent <= budget else { break }
            start = candidate
        }
        return alignedHistoryStart(start)
    }

    /// Moves a candidate start forward until it is the first row of a logical line.
    ///
    /// A row whose predecessor continues into it is a wrap fragment with no head. Keeping one
    /// would give the replica an oldest line that never began, and a later reflow would rewrap
    /// that fragment as a line of its own.
    private func alignedHistoryStart(_ start: Int) -> Int {
        var aligned = start
        while aligned > 0, aligned < historyRowCount {
            Instrument.synchronizationRetainedRowVisit.record()
            guard let previous = history.paintedDisplayRow(at: aligned - 1) else {
                preconditionFailure("retained history count must address every retained row")
            }
            guard previous.logicallyContinues else { break }
            aligned += 1
        }
        return aligned
    }

    private func appendControlState(
        for targetScreen: Terminal.ScreenState,
        includeReplyEmittingModes: Bool,
        to writer: inout StateSynchronizationWriter
    ) {
        writer.append("\u{1B}[3g")
        for column in tabStops {
            writer.append(cursorPosition(row: 0, column: column, originMode: false))
            writer.append("\u{1B}H")
        }

        if let scrollRegion {
            writer.append("\u{1B}[" + TerminalSettingReport.setTopAndBottomMargins(scrollRegion))
        } else {
            writer.append("\u{1B}[r")
        }

        appendSavedCursor(targetScreen.control.savedCursor, in: targetScreen, to: &writer)
        appendModes(includeReplyEmittingModes: includeReplyEmittingModes, to: &writer)
        appendKittyKeyboardStack(for: targetScreen, to: &writer)
        writer.append(styleSequence(currentStyle))
        writer.append(hyperlinkSequence(hyperlinkPen.flatMap { hyperlinkTargets[$0] }))
        writer.append(cursorPosition(
            row: targetScreen.cursor.row,
            column: targetScreen.cursor.column,
            originMode: modes.isOriginMode
        ))
        if targetScreen.isPendingWrap {
            appendPendingWrap(
                at: targetScreen.cursor,
                in: targetScreen,
                originMode: modes.isOriginMode,
                to: &writer
            )
            writer.append(styleSequence(currentStyle))
            writer.append(hyperlinkSequence(hyperlinkPen.flatMap { hyperlinkTargets[$0] }))
        }
        appendSemanticState(targetScreen, to: &writer)
        writer.appendRowState(targetScreen.rows[targetScreen.cursor.row])
    }

    /// Replays an alternate screen the source retains but is not currently showing.
    ///
    /// Mode 47 is the only switch that neither saves the cursor nor clears a grid, which is
    /// exactly what painting an offscreen grid needs. Only what survives re-entry is worth
    /// sending -- the rows, the DECSC slot, the Kitty keyboard stack, and the semantic state --
    /// because the switch back carries the live cursor and drops pending wrap. Every live mode
    /// this disturbs is restored by the primary's reconstruction, which follows it.
    private func appendRetainedAlternateScreen(
        _ retained: Terminal.ScreenState,
        to writer: inout StateSynchronizationWriter
    ) {
        writer.append("\u{1B}[0m")
        writer.append(decPrivateModeSequence(.legacyAlternateScreen, enabled: true))
        writer.append(ansiModeSequence(.insert, enabled: false))
        writer.append(decPrivateModeSequence(.origin, enabled: false))
        writer.append(decPrivateModeSequence(.autoWrap, enabled: true))
        writer.append("\u{1B}[r")
        writer.append("\u{1B}[H")
        writer.appendRows(retained.rows.map { $0.materialized(to: columnCount) }, encoder: self)
        appendSavedCursor(retained.control.savedCursor, in: retained, to: &writer)
        appendKittyKeyboardStack(for: retained, to: &writer)
        appendSemanticState(retained, to: &writer)
        // The saved-cursor replay leaves the cursor on the saved row and may reprint the cell
        // that reached the margin there, so that row states itself again.
        writer.appendRowState(retained.rows[retained.control.savedCursor.position.row])
        writer.append(decPrivateModeSequence(.legacyAlternateScreen, enabled: false))
    }

    private func appendSavedCursor(
        _ saved: Terminal.SavedCursorState,
        in targetScreen: Terminal.ScreenState,
        to writer: inout StateSynchronizationWriter
    ) {
        writer.append(decPrivateModeSequence(.origin, enabled: saved.isOriginMode))
        writer.append(decPrivateModeSequence(.cursorVisible, enabled: saved.isCursorVisible))
        writer.append(cursorStyleSequence(
            shape: saved.cursorShape,
            blinking: saved.isCursorBlinking
        ))
        writer.append(styleSequence(saved.style))
        writer.append(cursorPosition(
            row: saved.position.row,
            column: saved.position.column,
            originMode: saved.isOriginMode
        ))
        if saved.isPendingWrap {
            appendPendingWrap(
                at: saved.position,
                in: targetScreen,
                originMode: saved.isOriginMode,
                to: &writer
            )
            writer.append(styleSequence(saved.style))
        }
        writer.append("\u{1B}7")
        // Strictly after the DECSC above: that recapture overwrites the replica's saved slot
        // with its live -- still reset-default -- charset state, so an earlier form would be
        // silently clobbered back to ASCII.
        writer.append("\u{1B}]133;S;charset-saved=\(charsetSynchronizationValue(saved.charsets))\u{7}")
    }

    private func appendPendingWrap(
        at position: Terminal.CellPosition,
        in targetScreen: Terminal.ScreenState,
        originMode: Bool,
        to writer: inout StateSynchronizationWriter
    ) {
        let addressedColumn = targetScreen.rows[position.row].cell(at: position.column).kind
            == .wideTail ? position.column - 1 : position.column
        let cell = targetScreen.rows[position.row].cell(at: addressedColumn)
        guard cell.kind == .narrow || cell.kind == .wideHead else {
            preconditionFailure("pending wrap must be backed by the cell that reached the margin")
        }
        writer.append(cursorPosition(
            row: position.row,
            column: addressedColumn,
            originMode: originMode
        ))
        writer.append(styleSequence(style(for: cell.styleId)))
        writer.append(hyperlinkSequence(cell.hyperlinkId.flatMap { hyperlinkTargets[$0] }))
        writer.append(Array(String(describing: targetScreen.rows[position.row].scalars(of: cell)).utf8))
    }

    private func appendModes(
        includeReplyEmittingModes: Bool,
        to writer: inout StateSynchronizationWriter
    ) {
        for mode in Terminal.ANSIMode.allCases {
            let enabled = switch mode {
            case .insert: modes.isInsertMode
            case .lineFeedNewLine: modes.isLineFeedNewLineMode
            }
            writer.append(ansiModeSequence(mode, enabled: enabled))
        }
        writer.append(modes.isApplicationKeypadMode ? "\u{1B}=" : "\u{1B}>")

        var didAppendMouseTracking = false
        for mode in Terminal.DECPrivateMode.allCases {
            let policy = mode.policy
            guard includeReplyEmittingModes || policy.setEffect.emitsReply == false else {
                continue
            }
            switch policy.state {
            case .stored(let keyPath):
                writer.append(decPrivateModeSequence(mode, enabled: modes[keyPath: keyPath]))
            case .mouseTracking:
                // The trio is mutually exclusive, so it is one block, not one sequence per
                // mode: a per-mode walk would reset whichever mode it had just selected.
                guard didAppendMouseTracking == false else { break }
                didAppendMouseTracking = true
                appendMouseTrackingModes(to: &writer)
            case .screenSwitch, .cursorSlot, .fixedStatus:
                // The live screen, the DECSC slot, and a fixed-status mode are all replayed
                // by something other than a mode sequence.
                break
            }
        }
        writer.append(cursorStyleSequence(
            shape: modes.cursorShape,
            blinking: modes.isCursorBlinking
        ))
    }

    /// Neutralizes every mouse-tracking mode, then selects the one the source holds.
    ///
    /// Reading the trio out of the declaration rather than naming the three modes keeps the
    /// block correct whatever order they are declared in.
    private func appendMouseTrackingModes(to writer: inout StateSynchronizationWriter) {
        var selected: Terminal.DECPrivateMode?
        for mode in Terminal.DECPrivateMode.allCases {
            guard case .mouseTracking(let tracking) = mode.policy.state else { continue }
            writer.append(decPrivateModeSequence(mode, enabled: false))
            if tracking == modes.mouseTrackingMode { selected = mode }
        }
        if let selected {
            writer.append(decPrivateModeSequence(selected, enabled: true))
        }
    }

    private func ansiModeSequence(_ mode: Terminal.ANSIMode, enabled: Bool) -> String {
        "\u{1B}[\(mode.rawValue)\(enabled ? "h" : "l")"
    }

    private func decPrivateModeSequence(_ mode: Terminal.DECPrivateMode, enabled: Bool) -> String {
        "\u{1B}[?\(mode.rawValue)\(enabled ? "h" : "l")"
    }

    private func appendKittyKeyboardStack(
        for targetScreen: Terminal.ScreenState,
        to writer: inout StateSynchronizationWriter
    ) {
        writer.append("\u{1B}[<u")
        for flags in targetScreen.control.kittyKeyboardStack {
            writer.append("\u{1B}[>\(flags.rawValue)u")
        }
    }

    private func appendSemanticState(
        _ targetScreen: Terminal.ScreenState,
        to writer: inout StateSynchronizationWriter
    ) {
        switch targetScreen.semanticContent {
        case .output:
            writer.append("\u{1B}]133;D\u{7}")
        case .prompt:
            writer.append("\u{1B}]133;P\u{7}")
        case .input:
            writer.append(targetScreen.semanticContentClearsAtEndOfLine
                ? "\u{1B}]133;I\u{7}"
                : "\u{1B}]133;B\u{7}")
        }
    }

    private var promptRedrawSequence: String {
        let value = switch promptRedrawMode {
        case .disabled: "0"
        case .full: "1"
        case .last: "last"
        }
        return "\u{1B}]133;S;redraw=\(value)\u{7}"
    }

    private func appendGraphemeSynchronization(to writer: inout StateSynchronizationWriter) {
        writer.append("\u{1B}]133;S;repeat=none\u{7}")
        if let lastPrintedCluster {
            let scalars = Array(lastPrintedCluster.scalars)
            let chunkSize = 4_096
            for start in stride(from: 0, to: scalars.count, by: chunkSize) {
                let end = min(start + chunkSize, scalars.count)
                let encoded = scalars[start..<end]
                    .map { String($0.value, radix: 16) }
                    .joined(separator: ",")
                writer.append(
                    "\u{1B}]133;S;repeat-add=\(lastPrintedCluster.cellWidth):\(encoded)\u{7}"
                )
            }
        }

        let clusterValue: String
        if let clusterContext {
            clusterValue = [
                String(clusterContext.target.row),
                String(clusterContext.target.column),
                String(clusterContext.previousClass.rawValue),
                String(graphemeBreakStateCode(clusterContext.breakState)),
            ].joined(separator: ",")
        } else {
            clusterValue = "none"
        }
        writer.append("\u{1B}]133;S;cluster=\(clusterValue)\u{7}")
    }

    /// Spells charset state as the four slots' SCS finals, the invoked slot, and the pending
    /// single shift -- exactly the VT420 list DECSC saves.
    ///
    /// Charset state rides this private form rather than real sequences because a pending
    /// single shift has no cancel sequence and the saved slot cannot be written without
    /// routing through live state.
    private func charsetSynchronizationValue(_ state: TerminalCharsetState) -> String {
        let designations = String(decoding: [
            state.g0.designationFinal,
            state.g1.designationFinal,
            state.g2.designationFinal,
            state.g3.designationFinal,
        ], as: UTF8.self)
        let shift = state.pendingSingleShift.map { String($0.rawValue) } ?? "none"
        return "\(designations),\(state.invokedSlot.rawValue),\(shift)"
    }

    private func graphemeBreakStateCode(_ state: GraphemeBreakState) -> UInt8 {
        switch state {
        case .initial: 0
        case .regionalIndicator: 1
        case .extendedPictographic: 2
        case .indicConjunctBreakConsonant: 3
        case .indicConjunctBreakLinker: 4
        }
    }

    private func cursorPosition(row: Int, column: Int, originMode: Bool) -> String {
        let reportedRow = originMode ? row - activeScrollRegion.lowerBound : row
        return "\u{1B}[\(reportedRow + 1);\(column + 1)H"
    }

    private func cursorStyleSequence(shape: TerminalCursorShape, blinking: Bool) -> String {
        "\u{1B}[" + TerminalSettingReport.setCursorStyle(shape: shape, blinking: blinking)
    }

    private func styleSequence(_ style: TerminalStyle) -> String {
        // The DECSCA is unconditional because the leading SGR 0 no longer clears protection, so
        // the run has to state it rather than inherit it. That keeps this encoder stateless per
        // run, which is what the saved-cursor and pending-wrap emitters rely on.
        "\u{1B}[" + TerminalSettingReport.selectGraphicRendition(style)
            + "\u{1B}[" + TerminalSettingReport.selectCharacterProtection(style.protected)
    }

    private func hyperlinkSequence(_ hyperlink: TerminalHyperlink?) -> String {
        guard let hyperlink else { return "\u{1B}]8;;\u{7}" }
        let parameter = hyperlink.explicitId.map { "id=\($0)" } ?? ""
        return "\u{1B}]8;\(parameter);\(hyperlink.uri)\u{7}"
    }

    /// Builds one canonical byte stream while suppressing redundant style and hyperlink changes.
    private struct StateSynchronizationWriter {
        var bytes: [UInt8] = []
        private var style: TerminalStyle?
        private var hyperlink: TerminalHyperlink?

        mutating func append(_ string: String) {
            bytes.append(contentsOf: string.utf8)
        }

        mutating func append(_ appended: [UInt8]) {
            bytes.append(contentsOf: appended)
        }

        /// Appends every row and reports what the first `measuringFirst` of them cost.
        ///
        /// The count is taken inside the loop because rows are not encoded independently:
        /// style state carries across a soft wrap, and a row ending in a spacer emits the
        /// wide grapheme that opens the row after it. Only the writer can say where one run
        /// of rows stopped paying and the next started.
        @discardableResult
        mutating func appendRows(
            _ rows: [Terminal.GridRow],
            encoder: TerminalStateSynchronizationEncoder,
            measuringFirst: Int = 0
        ) -> Int {
            style = nil
            let startByteCount = bytes.count
            var measuredBytes = 0
            var firstColumn = 0
            for rowIndex in rows.indices {
                let sourceRow = rows[rowIndex]
                let row = sourceRow.withGatedContinuation
                var column = firstColumn
                firstColumn = 0
                while column < encoder.columnCount {
                    let cell = row.cell(at: column)
                    switch cell.kind {
                    case .padding:
                        var end = column + 1
                        while end < encoder.columnCount,
                              row.cell(at: end).kind == .padding,
                              row.cell(at: end).styleId == cell.styleId
                        {
                            end += 1
                        }
                        let count = end - column
                        let cellStyle = encoder.style(for: cell.styleId)
                        if cellStyle != TerminalStyle() {
                            setStyle(cellStyle, encoder: encoder)
                            append("\u{1B}[\(count)X")
                        }
                        if end < encoder.columnCount {
                            append("\u{1B}[\(count)C")
                        }
                        column = end
                    case .narrow, .wideHead:
                        setStyle(encoder.style(for: cell.styleId), encoder: encoder)
                        setHyperlink(cell.hyperlinkId.flatMap { encoder.hyperlinkTargets[$0] })
                        append(Array(String(describing: row.scalars(of: cell)).utf8))
                        column += cell.kind == .wideHead ? 2 : 1
                    case .wideTail:
                        column += 1
                    case .spacerHead:
                        if column == encoder.columnCount - 1,
                           rowIndex + 1 < rows.count,
                           rows[rowIndex + 1].cell(at: 0).kind == .wideHead
                        {
                            let next = rows[rowIndex + 1].cell(at: 0)
                            setStyle(encoder.style(for: next.styleId), encoder: encoder)
                            setHyperlink(next.hyperlinkId.flatMap { encoder.hyperlinkTargets[$0] })
                            append(Array(String(describing: rows[rowIndex + 1].scalars(of: next)).utf8))
                            firstColumn = 2
                        }
                        column += 1
                    }
                }
                appendRowState(sourceRow)
                setHyperlink(nil)
                if rowIndex + 1 < rows.count, row.isSoftWrapped == false {
                    setStyle(TerminalStyle(), encoder: encoder)
                    append("\r\n")
                }
                if rowIndex + 1 == measuringFirst {
                    measuredBytes = bytes.count - startByteCount
                }
            }
            return measuredBytes
        }

        private mutating func setStyle(
            _ next: TerminalStyle,
            encoder: TerminalStateSynchronizationEncoder
        ) {
            guard next != style else { return }
            append(encoder.styleSequence(next))
            style = next
        }

        private mutating func setHyperlink(_ next: TerminalHyperlink?) {
            guard next != hyperlink else { return }
            if let next {
                let parameter = next.explicitId.map { "id=\($0)" } ?? ""
                append("\u{1B}]8;\(parameter);\(next.uri)\u{7}")
            } else {
                append("\u{1B}]8;;\u{7}")
            }
            hyperlink = next
        }

        mutating func appendRowState(_ row: Terminal.GridRow) {
            let mark = switch row.semanticPrompt {
            case .none: "none"
            case .prompt: "prompt"
            case .continuation: "continuation"
            case .output: "output"
            case .vacated: "vacated"
            }
            let wrap = row.isSoftWrapped
                ? (row.marginProvenance == .erase ? "stale" : "soft")
                : "hard"
            append("\u{1B}]133;S;mark=\(mark);wrap=\(wrap)\u{7}")
        }
    }
}
