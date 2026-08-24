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
        var primaryRows = history
            .paintedDisplayRows(in: historyStart..<historyRowCount)
            .map { $0.materialized(to: columnCount) }
        primaryRows.reserveCapacity(primaryRows.count + rowCount)
        primaryRows.append(contentsOf: primaryScreenRows.map { $0.materialized(to: columnCount) })
        let historyBytes = writer.appendRows(
            primaryRows,
            encoder: self,
            measuringFirst: historyRowCount - historyStart
        )

        let primaryState = primaryScreenState
        appendControlState(for: primaryState, includeFocusReportingMode: true, to: &writer)

        if isAlternateScreenActive {
            writer.append("\u{1B}[0m")
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
            // Focus reporting already has its right value and enabling it again would add a reply.
            appendControlState(for: screen, includeFocusReportingMode: false, to: &writer)
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
        var spent = 0
        var start = historyRowCount
        while start > 0 {
            let candidate = start - 1
            Instrument.synchronizationRetainedRowVisit.record()
            guard let row = history.paintedDisplayRow(at: candidate) else {
                preconditionFailure("retained history count must address every retained row")
            }
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
        includeFocusReportingMode: Bool,
        to writer: inout StateSynchronizationWriter
    ) {
        writer.append("\u{1B}[3g")
        for column in tabStops {
            writer.append(cursorPosition(row: 0, column: column, originMode: false))
            writer.append("\u{1B}H")
        }

        if let scrollRegion {
            writer.append("\u{1B}[\(scrollRegion.lowerBound + 1);\(scrollRegion.upperBound)r")
        } else {
            writer.append("\u{1B}[r")
        }

        appendSavedCursor(targetScreen.control.savedCursor, in: targetScreen, to: &writer)
        appendModes(includeFocusReportingMode: includeFocusReportingMode, to: &writer)
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
        writer.append(Array(String(describing: cell.scalars).utf8))
    }

    private func appendModes(
        includeFocusReportingMode: Bool,
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

        for mode in Terminal.DECPrivateMode.allCases {
            let enabled: Bool?
            switch mode {
            case .applicationCursorKeys: enabled = modes.isApplicationCursorKeysMode
            case .origin: enabled = modes.isOriginMode
            case .autoWrap: enabled = modes.isAutoWrapMode
            case .cursorBlink: enabled = modes.isCursorBlinking
            case .cursorVisible: enabled = modes.isCursorVisible
            case .mouseClick:
                writer.append(decPrivateModeSequence(.mouseClick, enabled: false))
                writer.append(decPrivateModeSequence(.mouseDrag, enabled: false))
                writer.append(decPrivateModeSequence(.mouseAnyMotion, enabled: false))
                switch modes.mouseTrackingMode {
                case .off: break
                case .click: writer.append(decPrivateModeSequence(.mouseClick, enabled: true))
                case .drag: writer.append(decPrivateModeSequence(.mouseDrag, enabled: true))
                case .anyMotion:
                    writer.append(decPrivateModeSequence(.mouseAnyMotion, enabled: true))
                }
                enabled = nil
            case .mouseDrag, .mouseAnyMotion:
                enabled = nil
            case .focusReporting:
                enabled = includeFocusReportingMode ? modes.isFocusReportingMode : nil
            case .sgrMouseEncoding: enabled = modes.isSGRMouseEncodingMode
            case .alternateScreen, .savedCursor, .alternateScreenAndSavedCursor:
                enabled = nil
            case .bracketedPaste: enabled = modes.isBracketedPasteMode
            case .synchronizedOutput: enabled = modes.isSynchronizedOutputActive
            case .graphemeClusters:
                enabled = nil
            }
            if let enabled {
                writer.append(decPrivateModeSequence(mode, enabled: enabled))
            }
        }
        writer.append(cursorStyleSequence(
            shape: modes.cursorShape,
            blinking: modes.isCursorBlinking
        ))
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
            writer.append("\u{1B}[>\(flags)u")
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
        let parameter = switch (shape, blinking) {
        case (.block, true): 1
        case (.block, false): 2
        case (.underline, true): 3
        case (.underline, false): 4
        case (.bar, true): 5
        case (.bar, false): 6
        }
        return "\u{1B}[\(parameter) q"
    }

    private func styleSequence(_ style: TerminalStyle) -> String {
        var parameters = ["0"]
        if style.bold { parameters.append("1") }
        if style.dim { parameters.append("2") }
        if style.italic { parameters.append("3") }
        switch style.underline {
        case .none: break
        case .single: parameters.append("4")
        case .double: parameters.append("4:2")
        case .curly: parameters.append("4:3")
        case .dotted: parameters.append("4:4")
        case .dashed: parameters.append("4:5")
        }
        if style.reverse { parameters.append("7") }
        if style.hidden { parameters.append("8") }
        if style.strikethrough { parameters.append("9") }
        appendColor(style.foreground, selector: 38, to: &parameters)
        appendColor(style.background, selector: 48, to: &parameters)
        appendColor(style.underlineColor, selector: 58, to: &parameters)
        // The DECSCA is unconditional because the leading SGR 0 no longer clears protection, so
        // the run has to state it rather than inherit it. That keeps this encoder stateless per
        // run, which is what the saved-cursor and pending-wrap emitters rely on.
        return "\u{1B}[\(parameters.joined(separator: ";"))m\u{1B}[\(style.protected ? 1 : 0)\"q"
    }

    private func hyperlinkSequence(_ hyperlink: TerminalHyperlink?) -> String {
        guard let hyperlink else { return "\u{1B}]8;;\u{7}" }
        let parameter = hyperlink.explicitId.map { "id=\($0)" } ?? ""
        return "\u{1B}]8;\(parameter);\(hyperlink.uri)\u{7}"
    }

    private func appendColor(_ color: TerminalColor, selector: Int, to parameters: inout [String]) {
        switch color {
        case .default:
            if selector == 58 { parameters.append("59") }
        case .indexed(let index):
            parameters.append(contentsOf: [String(selector), "5", String(index)])
        case .rgb(let red, let green, let blue):
            parameters.append(contentsOf: [
                String(selector), "2", String(red), String(green), String(blue),
            ])
        }
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
                        append(Array(String(describing: cell.scalars).utf8))
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
                            append(Array(String(describing: next.scalars).utf8))
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
