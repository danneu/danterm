// Doc 31's retained-history store: one fixed-capacity byte arena of logical-line records, a
// derived index over it, and the read-time fold that turns both back into display rows.
//
// This is the store `31/D1` funded and `31/D2`/`31/D3` specified. History holds one record per
// logical line a program printed; wrapping is derived at read from (record, width); a width
// change rewrites no retained byte and evicts nothing, because there is no width in storage to
// rewrite (`I1`, `I3`). The arena's capacity *is* the byte budget, allocated once and never
// grown, compacted or shrunk (`I2`), so at steady state admission allocates nothing.
//
// What belongs here: the arena and its ring discipline, the five mutating operations `31/D2`
// Decision 2 enumerates (admit, close/reopen the tail, evict at the head, truncate the tail,
// clear), the derived index (per-block display-row totals plus one grand total), the side tables
// keyed by record -- spills and the trailing background-erase fill style -- and the two reads the
// fold serves: the content walk a copy takes and the painted walk a renderer takes. What does
// not: the record's byte layout and the fold's arithmetic, which are `LogicalLineRecord`; and
// every terminal-side concern -- anchors, selection, projection -- which stays in
// `Terminal.swift`. This type never sees a `TextAnchor`.
//
// **The middle is immutable** (`I5`). The head record's header and the tail record are the only
// writable bytes; everything between them is written once at admission and read forever. That is
// what makes each operation's cost bounded by the head and the tail alone, and it is the premise
// every reader in the design leans on.
//
// Its own file because it is the one data structure the whole design rests on, and because it is
// deliberately reachable without `Terminal`'s 6,000 lines of parser state -- the store's
// contracts are testable as a store.

extension Terminal {
    /// Retained history as logical-line records in one fixed-capacity arena.
    ///
    /// Owns its own width, because the derived index's totals are only meaningful at one
    /// (`31/D3` Decision 1). Callers change it through `setWidth(_:)`, which is the only entry
    /// point that recomputes the whole index; every other operation maintains it in O(1).
    struct LogicalLineStore: Sendable {
        // MARK: - Nested types

        /// One index block's cached display-row total (`31/D3` Decision 1).
        ///
        /// `rowStart` is an **absolute** stream position measured from the same monotone origin
        /// `evictedRowCount` counts against, which is what lets a head eviction touch only the
        /// head block: every later block's start is unchanged by definition.
        private struct Block: Sendable, Equatable {
            var rowStart: Int
            var rowCount: Int
        }

        /// A hyperlink id stamped at one cell offset within the record.
        private struct HyperlinkEntry: Sendable, Equatable {
            var offset: Int
            var id: Terminal.HyperlinkId
        }

        /// One contiguous `contentIdentity` run, keyed by cell offset within the record
        /// (`31/D3` Decision 6, `31/DD17`) rather than by column within a display row.
        private struct IdentityRun: Sendable, Equatable {
            var start: Int
            var extent: Int
            var base: Terminal.ContentIdentity
        }

        /// What the store charges against its budget, reported so capacity and bytes-in-use are
        /// separately visible (`31/DD11`, restating `15/F4`'s leak proof in arena terms).
        ///
        /// `chargedBytes` is the single quantity `31/I2` bounds. It is **not** resident bytes:
        /// once the ring's write cursor has cycled, every arena page has been touched, which is
        /// the reading `31/AR6` promotes to a gate rather than an assumption.
        struct Census: Equatable, Sendable {
            var capacityBytes: Int
            var arenaBytesInUse: Int
            var indexBytes: Int
            var sideTableBytes: Int

            var chargedBytes: Int { arenaBytesInUse + indexBytes + sideTableBytes }
        }

        /// A record's content-level shape, for callers that reason about logical lines rather
        /// than display rows -- copy, search, and the proofs that a split or a trim landed.
        struct RecordSummary: Equatable, Sendable {
            var cellCount: Int
            var displayRowCount: Int
            var isOpen: Bool
            var isForcedSplit: Bool
            var startsMidLine: Bool
            var hasWideCells: Bool
            var semanticPrompt: Terminal.SemanticPromptRow
            /// The style the line's tail is painted in past its content end, or nil when the
            /// tail is default-painted (`31/DD25` as amended). Never part of the line's cells.
            var trailingFillStyle: Terminal.StyleId?
        }

        /// A display row's address as (record, row within record).
        ///
        /// The transient `31/D3` Decision 2 keeps out of anchors: it is produced on demand and
        /// never stored, so the public coordinate stays an absolute display row. Readers get one
        /// from `locate(displayRow:)` and carry it forward with `advance(_:)`, which is how a
        /// frame plans with at most one locate (`31/D3` Decision 1 rule 2).
        struct DisplayRowCursor: Equatable, Sendable {
            var recordIndex: Int
            var rowWithinRecord: Int
        }

        // MARK: - Stored state

        /// The arena. Allocated once at `capacityBytes` and never resized -- `31/D2` Decision 1
        /// rejected both geometric growth (resident slack no charge model can see, the shape of
        /// `15/F4`'s leak) and `memmove` compaction (a 16 MiB copy on the admission path).
        private var arena: [UInt8]

        /// Byte offset of the oldest retained record's header.
        private var head = 0

        /// Byte offset where the next bytes are written. Wraps to 0 at the physical end.
        private var writeCursor = 0

        private var bytesInUse = 0

        /// One byte offset per live record, oldest first. Charged at capacity, which is the
        /// term that bounds the degenerate blank-line regime (`31/D2` Decision 1).
        private var offsets: RingBuffer<Int>

        /// Cached display-row totals, one per `blockSize` records.
        private var blocks: RingBuffer<Block>

        private var firstBlockNumber = 0
        private var firstRecordSequence = 0

        /// Cells trimmed off the head record's front, which rebases its side-table keys.
        ///
        /// Store-level rather than a header field because **only the head record is ever
        /// trimmed**, and the header word is full: `31/D2` Decision 1 prices a blank record at
        /// eight arena bytes, so a per-record trim field would have cost the blank-history depth
        /// the whole budget derivation rests on.
        private var headTrimmedCells = 0

        private(set) var grandDisplayRowTotal = 0

        /// Display rows dropped at the head, at the width in force when they were dropped, and
        /// only ever increasing (`31/D2` Decision 2's invariant, which replaces
        /// `isHistoryHeadTruncated`).
        private(set) var evictedRowCount = 0

        private(set) var width: Int

        private let capacity: Int
        private let forcedSplitCellCap: Int

        /// The open tail record's side tables, held outside the arena until it closes.
        ///
        /// A record's tables sit after its cells, so they cannot be written while admission is
        /// still appending cells over that space. Holding them here costs one flush per closed
        /// record and keeps the arena layout uniform for every record a reader will ever see
        /// except the tail.
        private var openHyperlinks: [HyperlinkEntry] = []
        private var openIdentityRuns: [IdentityRun] = []
        private var openPreviousIdentity: Terminal.ContentIdentity?

        /// Multi-scalar payloads, keyed by absolute record sequence. Outside the arena for the
        /// same reason `PackedRetainedRow` holds them outside its blob: inlining them would make
        /// a cell variable-width, and 99.88% of rows have none (`28/F11`).
        private var spillsBySequence: [Int: [[Unicode.Scalar]]] = [:]
        private var spillBytes = 0

        /// The trailing background-erase fill style, keyed by absolute record sequence
        /// (`31/DD25` as amended).
        ///
        /// A side table rather than a header field for the reason `31/D3` Decision 3 rejected a
        /// header style slot: it is reachable on a minority of records, and a 32-bit slot in
        /// every header would cost the blank-history depth `31/D2` Decision 1 rests on. Keyed
        /// like the spill table, so the two are evicted and charged by the same rules.
        private var fillStylesBySequence: [Int: Terminal.StyleId] = [:]

        /// Records per index block.
        ///
        /// `31/F1` Observation 4 measured sequential browse at 677 ns (32), 697 ns (64), 801 ns
        /// (128) and 870 ns (256) per display row: small blocks read faster because the in-block
        /// scan shortens faster than the binary search lengthens. 64 keeps that while charging
        /// 0.25 B per record for the block totals, against the 8 B the offsets cost.
        static let blockSize = 64

        // MARK: - Construction

        /// Reserves the whole budget up front, which is what makes the bound hold by
        /// construction rather than by a model checked against a second model.
        init(capacityBytes: Int = Terminal.productionScrollbackBudgetBytes, width: Int) {
            precondition(capacityBytes >= 1024 && capacityBytes % 8 == 0)
            precondition(width >= 1)
            capacity = capacityBytes
            arena = [UInt8](repeating: 0, count: capacityBytes)
            self.width = width
            forcedSplitCellCap = LogicalLineRecord.forcedSplitCellCount(forCapacity: capacityBytes)
            offsets = RingBuffer(filler: 0)
            blocks = RingBuffer(filler: Block(rowStart: 0, rowCount: 0))
        }

        // MARK: - Census

        var capacityBytes: Int { capacity }

        var recordCount: Int { offsets.count }

        var census: Census {
            Census(
                capacityBytes: capacity,
                arenaBytesInUse: bytesInUse,
                indexBytes: offsets.capacity * MemoryLayout<Int>.stride
                    + blocks.capacity * MemoryLayout<Block>.stride,
                sideTableBytes: spillBytes + openScratchBytes + fillStyleBytes
            )
        }

        private var openScratchBytes: Int {
            openHyperlinks.capacity * MemoryLayout<HyperlinkEntry>.stride
                + openIdentityRuns.capacity * MemoryLayout<IdentityRun>.stride
        }

        /// The fill table's charge, at the dictionary's *capacity* rather than its count --
        /// `15/D4`'s rule, the same one the index's 8-B-per-record charge follows: charge what
        /// the allocator gave. Only records that carry a fill move this term.
        private var fillStyleBytes: Int {
            fillStylesBySequence.capacity
                * (MemoryLayout<Int>.stride + MemoryLayout<Terminal.StyleId>.stride)
        }

        /// The record cap `31/I10` derives from the budget, exposed so a caller can drive a
        /// logical line past it without restating the derivation.
        static func forcedSplitCellCount(forCapacity capacity: Int) -> Int {
            LogicalLineRecord.forcedSplitCellCount(forCapacity: capacity)
        }

        // MARK: - Operation 1: admit a scrolled-off display row

        /// Appends one scrolled-off display row to the open tail record, opening one first when
        /// the previous logical line ended.
        ///
        /// The row's measurement rule is `reconstructLogicalLines`': a soft-wrapped row is
        /// measured to full width and a hard-ended row to its content end (`31/F4` case 17),
        /// and the `.spacerHead` a wrap left in the last column is dropped, because where a
        /// spacer sits is a function of the width and `31/I1` forbids storing one. A hard-ended
        /// row whose tail past the content is painted by a background erase contributes that
        /// paint as the record's **trailing fill style**, not as cells (`31/DD25` as amended).
        mutating func admit(_ row: Terminal.GridRow) {
            let admission = admissionContent(row)
            var cells = admission.cells

            // A hard-ended row with no content still occupies a display row when the line
            // already has cells, and a zero-cell append would fold that row away. One blank
            // cell restores it -- the same thing today's store holds for a blank row, and
            // `31/DD15`'s zero-cell record is untouched, because that case is an *empty*
            // record rather than an empty append. It takes the fill's style when there is one,
            // so the restored row is painted from its first column exactly as today's stored
            // row is (`31/DD34`).
            if row.isSoftWrapped == false, cells.isEmpty, openRecordCellCount > 0 {
                cells = [
                    Terminal.GridCell(
                        scalars: .empty,
                        kind: .padding,
                        styleId: admission.fillStyle ?? Terminal.defaultStyleId
                    )
                ]
            }

            // `31/DD3`: no record exceeds 1/32 of the budget. Splitting before the append keeps
            // the cut on a display-row boundary at the admitting width.
            if let open = openTailRecord(), open.cellCount + cells.count > forcedSplitCellCap {
                forceSplitOpenRecord()
            }

            makeRoom(forCells: cells.count)
            openRecordIfNeeded(mark: row.semanticPrompt)
            appendCells(cells)
            setTrailingFillOnTail(admission.fillStyle)

            // `31/DD5`: the display-row count is *counted* here, not derived -- admission knows
            // it consumed one row, so no `ceil` and no wide-cell scan runs on the write path.
            addDisplayRowsToTail(1)

            if row.isSoftWrapped == false {
                closeOpenRecord()
            }
            evictToBudget()
        }

        /// What a display row contributes to its logical line: cells, and a trailing fill style.
        ///
        /// `reconstructLogicalLines`' own rule (`31/F4` case 17): a soft-wrapped row is measured
        /// to full width, a hard-ended row to its **content** end. It is deliberately not
        /// `PackedRetainedRow.pack`'s canonical extent, which keeps the trailing
        /// background-erase-styled blanks past the content as *cells*: as a display row those
        /// are painted columns, but as line content they are cells the fold would re-wrap, so a
        /// painted tail on a hard-ended line would grow into whole extra display rows at a
        /// narrower width. There is no floor of one either -- a record's cell count is a content
        /// property and zero is representable (`31/DD15`).
        ///
        /// What `pack` sees and this splits (`31/DD25` as amended): the same predicate that
        /// extends `pack`'s canonical extent past the content -- a blank cell carrying a
        /// non-default style -- identifies the fill. The maximal run of such blanks reaching the
        /// right margin is the **trailing fill**, recorded as one style on the record and
        /// re-derived at read against whatever width is in force. Blanks that do *not* reach the
        /// margin stay cells: they sit between content and the fill, so their columns are
        /// positionally real and re-wrap with the rest of the line.
        private func admissionContent(
            _ row: Terminal.GridRow
        ) -> (cells: [Terminal.GridCell], fillStyle: Terminal.StyleId?) {
            var end = 0
            var fillStyle: Terminal.StyleId?
            if row.isSoftWrapped {
                // A soft-wrapped row occupies every column by definition, so it has no tail gap
                // for a fill to cover.
                end = width
            } else {
                for column in stride(from: min(width, row.cells.count) - 1, through: 0, by: -1) {
                    let kind = row.cells[column].kind
                    guard kind == .narrow || kind == .wideHead else { continue }
                    end = min(width, column + (kind == .wideHead ? 2 : 1))
                    break
                }
                let margin = row.cell(at: width - 1)
                if end < width, isFillBlank(margin) {
                    fillStyle = margin.styleId
                    var start = width - 1
                    while start > end, isFillBlank(row.cell(at: start - 1)),
                          row.cell(at: start - 1).styleId == margin.styleId
                    {
                        start -= 1
                    }
                    end = start
                }
            }
            if end > 0, row.cell(at: end - 1).kind == .spacerHead {
                end -= 1
            }
            return (end <= 0 ? [] : (0..<end).map { row.cell(at: $0) }, fillStyle)
        }

        /// Whether a cell is a blank that a background erase painted: `pack`'s canonical-extent
        /// predicate read the other way round, and nothing else may be folded into a fill.
        private func isFillBlank(_ cell: Terminal.GridCell) -> Bool {
            cell.scalars.isEmpty
                && cell.kind == .padding
                && cell.styleId != Terminal.defaultStyleId
                && cell.hyperlinkId == nil
                && cell.contentIdentity == nil
        }

        // MARK: - The trailing fill

        /// Records (or clears) the tail record's trailing fill style.
        ///
        /// Written after the row's cells so it lands on the record that holds the line's *end*,
        /// which is what makes a forced-split line's fill the **last** piece's by construction:
        /// a split closes the piece before these cells were appended (`31/DD33`).
        private mutating func setTrailingFillOnTail(_ styleId: Terminal.StyleId?) {
            guard offsets.count > 0 else { return }
            let index = offsets.count - 1
            let offset = offsets[index]
            var record = self.record(at: offset)
            guard let styleId else {
                guard record.hasTrailingFill else { return }
                record.hasTrailingFill = false
                writeHeader(record, at: offset)
                fillStylesBySequence.removeValue(forKey: firstRecordSequence + index)
                return
            }
            record.hasTrailingFill = true
            writeHeader(record, at: offset)
            fillStylesBySequence[firstRecordSequence + index] = styleId
        }

        /// The style painted after this record's content ends, on its last display row.
        ///
        /// Nil for every record that carries no fill, which is the overwhelming majority: the
        /// header bit answers that case without touching the side table.
        func trailingFillStyle(at recordIndex: Int) -> Terminal.StyleId? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            guard record(at: offsets[recordIndex]).hasTrailingFill else { return nil }
            return fillStylesBySequence[firstRecordSequence + recordIndex]
        }

        // MARK: - Operation 2: close / reopen the tail record

        /// Ends the open logical line, flushing the tail record's side tables into the arena.
        ///
        /// This is `severScrollbackWrapClaim` under the new store, and the whole of it is one
        /// header bit plus the tables the open record had been accumulating.
        mutating func closeOpenRecord() {
            guard var record = openTailRecord() else { return }
            let offset = offsets[offsets.count - 1]
            flushOpenTables(into: &record, at: offset)
            record.isOpen = false
            writeHeader(record, at: offset)
            bytesInUse += record.byteLength
                - LogicalLineRecord.headerAndCells(record.cellCount)
            writeCursor = offset + record.byteLength
            clearOpenScratch()
        }

        /// Resumes appending to the last record, which is `restoreWrapClaimBeforeCursor`.
        ///
        /// Reopening drops the trailing fill: the fill describes the paint after the *end* of a
        /// line, and a reopened line has no end yet -- its last display row is about to be
        /// extended, and admission re-derives the tail of whatever row finally closes it
        /// (`31/DD35`).
        mutating func reopenTailRecord() {
            guard offsets.count > 0 else { return }
            let offset = offsets[offsets.count - 1]
            var record = self.record(at: offset)
            guard record.isOpen == false, record.isForcedSplit == false else { return }
            loadOpenScratch(from: record, at: offset)
            if record.hasTrailingFill {
                record.hasTrailingFill = false
                fillStylesBySequence.removeValue(forKey: firstRecordSequence + offsets.count - 1)
            }
            let closedLength = record.byteLength
            record.isOpen = true
            record.hyperlinkCount = 0
            record.identityEntryCount = 0
            record.identityPerCell = false
            writeHeader(record, at: offset)
            bytesInUse -= closedLength - record.byteLength
            writeCursor = offset + record.byteLength
        }

        /// Materializes the styled blank a background-erase sever or spacer clear leaves behind
        /// (`31/D3` Decision 3).
        ///
        /// Asymmetric on purpose: today's `pack` trims a default-styled trailing blank and keeps
        /// a non-default one, so storing nothing in the default case is what *reproduces* today's
        /// output rather than a shortcut.
        mutating func repairClearedSpacer(styleId: Terminal.StyleId) {
            guard styleId != Terminal.defaultStyleId else { return }
            guard let record = openTailRecord() else { return }
            let offset = offsets[offsets.count - 1]
            var lastRowColumns = 0
            LogicalLineFold.enumerateRows(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { _, start, end, _ in
                lastRowColumns = end - start
            }
            guard lastRowColumns == width - 1 else { return }
            appendCells([Terminal.GridCell(scalars: .empty, kind: .padding, styleId: styleId)])
        }

        /// Cuts the open logical line here and lets the next admission continue it in a new
        /// record, which readers rejoin by adjacency (`31/DD6`).
        mutating func forceSplitOpenRecord() {
            guard var record = openTailRecord(), record.cellCount > 0 else { return }
            let offset = offsets[offsets.count - 1]
            flushOpenTables(into: &record, at: offset)
            record.isOpen = false
            record.isForcedSplit = true
            writeHeader(record, at: offset)
            bytesInUse += record.byteLength
                - LogicalLineRecord.headerAndCells(record.cellCount)
            writeCursor = offset + record.byteLength
            clearOpenScratch()
        }

        // MARK: - Operation 3: evict at the head

        /// Drops the oldest display row, trimming inside the head record when it holds more.
        ///
        /// Display-row granular by decision, not by convenience: `31/D2` Decision 2 took
        /// `31/DD2`'s recorded alternative so that no anchor and no scrollbar position moves
        /// further per admitted row than it does today. The termination measure is display rows
        /// rather than bytes -- a one-cell row frees eight bytes and spends eight on the
        /// rewritten header, so a step can free nothing and still make progress.
        @discardableResult
        mutating func evictOneDisplayRow() -> Bool {
            guard offsets.count > 0 else { return false }
            let offset = offsets[0]
            let record = self.record(at: offset)
            let cut = LogicalLineFold.firstRowCellEnd(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            )

            // The totals move first: `dropHeadRecord` may retire the head block once its last
            // record is gone, and the row being dropped belongs to the block as it stands now.
            evictedRowCount += 1
            grandDisplayRowTotal -= 1
            if blocks.count > 0 {
                blocks[0].rowCount -= 1
                blocks[0].rowStart += 1
            }

            if cut >= record.cellCount {
                dropHeadRecord(record, at: offset)
            } else {
                trimHeadRecord(record, at: offset, by: cut)
            }
            return true
        }

        /// Evicts until charged bytes are back inside the budget. Returns the rows dropped.
        @discardableResult
        mutating func evictToBudget() -> Int {
            var dropped = 0
            while census.chargedBytes > capacity, evictOneDisplayRow() {
                dropped += 1
            }
            return dropped
        }

        private mutating func trimHeadRecord(
            _ record: LogicalLineRecord,
            at offset: Int,
            by cut: Int
        ) {
            var trimmed = record
            trimmed.cellCount -= cut
            trimmed.startsMidLine = true
            // `31/D2` Decision 5: the mark referred to a line start that no longer exists. What
            // survives is the *continuation* reading the trimmed head had under today's store,
            // which is `.continuation` for a marked line and nothing at all for an unmarked one.
            trimmed.semanticPrompt = record.semanticPrompt == .none ? .none : .continuation
            let newOffset = offset + cut * LogicalLineRecord.cellBytes
            writeHeader(trimmed, at: newOffset)
            offsets[0] = newOffset
            head = newOffset
            bytesInUse -= cut * LogicalLineRecord.cellBytes
            headTrimmedCells += cut
        }

        private mutating func dropHeadRecord(_ record: LogicalLineRecord, at offset: Int) {
            // `31/D2` Decision 2 step 2 as amended: a dropped forced-split piece must stamp its
            // follower, or the follower reads as a fresh logical line -- the divergence from
            // `isHistoryHeadTruncated = lastEvictedIsSoftWrapped` that inherited condition 10
            // exists to prevent.
            if record.isForcedSplit, offsets.count > 1 {
                let followerOffset = offsets[1]
                var follower = self.record(at: followerOffset)
                follower.startsMidLine = true
                follower.semanticPrompt = .none
                writeHeader(follower, at: followerOffset)
            }

            spillBytes -= spillCost(of: spillsBySequence.removeValue(forKey: firstRecordSequence))
            fillStylesBySequence.removeValue(forKey: firstRecordSequence)
            offsets.removeFirst()
            firstRecordSequence += 1
            headTrimmedCells = 0
            bytesInUse -= record.byteLength

            if offsets.count == 0 {
                resetToEmptyArena()
                return
            }

            head = offset + record.byteLength
            skipHeadPads()
            retireEmptyHeadBlocks()
        }

        /// Steps the head up to the next live record, reclaiming the ring's pad records on the
        /// way -- they are bytes like any other and are charged like any other (`31/DD14`).
        private mutating func skipHeadPads() {
            if head >= capacity { head = 0 }
            while head != offsets[0] {
                let pad = record(at: head)
                bytesInUse -= pad.byteLength
                head += pad.byteLength
                if head >= capacity { head = 0 }
            }
        }

        private mutating func retireEmptyHeadBlocks() {
            while blocks.count > 0, firstBlockNumber < firstRecordSequence / Self.blockSize {
                blocks.removeFirst()
                firstBlockNumber += 1
            }
        }

        private mutating func retireEmptyTailBlocks() {
            guard offsets.count > 0 else { return }
            let lastBlockNumber = (firstRecordSequence + offsets.count - 1) / Self.blockSize
            while blocks.count > 0, firstBlockNumber + blocks.count - 1 > lastBlockNumber {
                blocks.removeLast()
            }
        }

        private mutating func resetToEmptyArena() {
            head = 0
            writeCursor = 0
            bytesInUse = 0
            headTrimmedCells = 0
            blocks.removeAll()
            spillsBySequence.removeAll()
            spillBytes = 0
            fillStylesBySequence.removeAll()
            clearOpenScratch()
        }

        // MARK: - Operation 4: truncate the tail

        /// Hands the last `displayRows` display rows back to the live grid, rewinding the write
        /// cursor to the cut.
        ///
        /// The only operation that shrinks the arena from the back, and the only one whose rows
        /// are not lost: they keep their absolute stream positions and merely change which side
        /// of the history/live seam they sit on, which is why `evictedRowCount` does not move.
        mutating func truncateTail(displayRows: Int) -> [Terminal.GridRow] {
            var handedBack: [Terminal.GridRow] = []
            for _ in 0..<displayRows {
                guard offsets.count > 0 else { break }
                guard let row = removeLastDisplayRow() else { break }
                handedBack.append(row)
            }
            return Array(handedBack.reversed())
        }

        private mutating func removeLastDisplayRow() -> Terminal.GridRow? {
            let index = offsets.count - 1
            let offset = offsets[index]
            let record = self.record(at: offset)
            var lastStart = 0
            var lastEnd = record.cellCount
            var rows = 0
            LogicalLineFold.enumerateRows(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { rowIndex, start, end, _ in
                lastStart = start
                lastEnd = end
                rows = rowIndex + 1
            }
            // Painted rather than content: the row is going back to the live grid, where the
            // erase paint is cells again, and re-admitting it re-derives the fill.
            let materialized = paintedRow(
                at: DisplayRowCursor(recordIndex: index, rowWithinRecord: rows - 1)
            )

            if rows == 1 {
                dropTailRecord(record, at: offset)
            } else {
                if record.isOpen == false {
                    reopenTailRecord()
                }
                cutTail(to: lastStart, from: lastEnd, at: offset)
            }

            grandDisplayRowTotal -= 1
            if blocks.count > 0 {
                blocks[blocks.count - 1].rowCount -= 1
            }
            return materialized
        }

        private mutating func dropTailRecord(_ record: LogicalLineRecord, at offset: Int) {
            let sequence = firstRecordSequence + offsets.count - 1
            spillBytes -= spillCost(of: spillsBySequence.removeValue(forKey: sequence))
            fillStylesBySequence.removeValue(forKey: sequence)
            clearOpenScratch()
            offsets.removeLast()
            bytesInUse -= record.byteLength
            writeCursor = offset
            if offsets.count == 0 {
                resetToEmptyArena()
                return
            }
            retireEmptyTailBlocks()
        }

        /// Rewinds the open tail record to `newCellCount`, dropping the side-table entries and
        /// spills the removed cells owned.
        private mutating func cutTail(to newCellCount: Int, from oldCellCount: Int, at offset: Int) {
            var removedSpills = 0
            for index in newCellCount..<oldCellCount where cellWord(recordAt: offset, cell: index)
                & PackedRetainedRow.Header.cellSpillBit != 0
            {
                removedSpills += 1
            }
            if removedSpills > 0 {
                let sequence = firstRecordSequence + offsets.count - 1
                if var spills = spillsBySequence[sequence] {
                    spillBytes -= spillCost(of: spills)
                    spills.removeLast(removedSpills)
                    spillBytes += spillCost(of: spills)
                    spillsBySequence[sequence] = spills
                }
            }

            openHyperlinks.removeAll { $0.offset >= newCellCount }
            while let last = openIdentityRuns.last, last.start >= newCellCount {
                openIdentityRuns.removeLast()
            }
            if var last = openIdentityRuns.last, last.start + last.extent > newCellCount {
                last.extent = newCellCount - last.start
                openIdentityRuns[openIdentityRuns.count - 1] = last
            }
            openPreviousIdentity = nil

            var record = self.record(at: offset)
            record.cellCount = newCellCount
            writeHeader(record, at: offset)
            bytesInUse -= (oldCellCount - newCellCount) * LogicalLineRecord.cellBytes
            writeCursor = offset + record.byteLength
        }

        // MARK: - Operation 5: clear all history

        mutating func removeAll() {
            evictedRowCount += grandDisplayRowTotal
            grandDisplayRowTotal = 0
            firstRecordSequence += offsets.count
            offsets.removeAll()
            resetToEmptyArena()
        }

        // MARK: - The width change

        /// Adopts a new width, pulling the open tail's partial display row back into the live
        /// refold and recomputing the whole index.
        ///
        /// Returns the cells the live grid must take as its continued line's prefix (`31/D3`
        /// Decision 4, `31/DD16`): without the pull-back a resize leaves a short display row in
        /// the *middle* of a logical line, which today's `reconstructLogicalLines` makes
        /// impossible and inherited condition 10 forbids diverging on.
        ///
        /// No retained byte outside the open tail is written. That is `31/I3` in one sentence:
        /// a width change evicts nothing, at any width down to the engine minimum.
        @discardableResult
        mutating func setWidth(_ newWidth: Int) -> [Terminal.GridCell] {
            precondition(newWidth >= 1)
            width = newWidth
            let pulled = pullBackOpenTailRemainder()
            recomputeIndex()
            return pulled
        }

        private mutating func pullBackOpenTailRemainder() -> [Terminal.GridCell] {
            guard let record = openTailRecord(), record.cellCount > 0 else { return [] }
            let offset = offsets[offsets.count - 1]
            var lastStart = 0
            var lastEnd = record.cellCount
            LogicalLineFold.enumerateRows(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { _, start, end, _ in
                lastStart = start
                lastEnd = end
            }
            guard lastEnd - lastStart < width else { return [] }

            let index = offsets.count - 1
            let suffix = (lastStart..<lastEnd).map { cell(recordIndex: index, cellOffset: $0) }
            if lastStart == 0 {
                dropTailRecord(record, at: offset)
            } else {
                cutTail(to: lastStart, from: lastEnd, at: offset)
            }
            return suffix
        }

        /// Rebuilds every block total and sets the grand total to their sum.
        ///
        /// Eager rather than lazy by measurement: `31/F2` read 0.016 ms at trial depth, `31/F7`
        /// 0.76 ms at the record count the budget admits, and `31/F9` 5.6 ms on the deepest wide
        /// history at the two-column minimum -- all inside one 60 Hz frame, so neither of
        /// `31/D3` Decision 7's mitigations ships.
        private mutating func recomputeIndex() {
            blocks.removeAll()
            firstBlockNumber = firstRecordSequence / Self.blockSize
            grandDisplayRowTotal = 0
            var rowStart = evictedRowCount
            var blockNumber = firstBlockNumber
            var current = Block(rowStart: rowStart, rowCount: 0)
            for index in 0..<offsets.count {
                let sequence = firstRecordSequence + index
                let number = sequence / Self.blockSize
                if number != blockNumber {
                    blocks.append(current)
                    rowStart += current.rowCount
                    blockNumber = number
                    current = Block(rowStart: rowStart, rowCount: 0)
                }
                let rows = displayRowCount(recordIndex: index)
                current.rowCount += rows
                grandDisplayRowTotal += rows
            }
            if offsets.count > 0 {
                blocks.append(current)
            }
        }

        /// Counts the retained display rows straight off the arena, ignoring every cached total.
        ///
        /// The independent oracle `31/I9` is stated against, and the only thing that catches a
        /// missed invalidation among the six trigger points (`31/AR4`).
        func independentDisplayRowRecount() -> Int {
            var total = 0
            for index in 0..<offsets.count {
                total += displayRowCount(recordIndex: index)
            }
            return total
        }

        // MARK: - Reads

        /// Converts an absolute-from-the-head display row into a record address.
        ///
        /// One binary search over the block totals, then a scan inside the block. A reader plans
        /// a frame with **one** of these and `advance(_:)` for the rest (`31/D3` Decision 1).
        func locate(displayRow: Int) -> DisplayRowCursor? {
            guard displayRow >= 0, displayRow < grandDisplayRowTotal else { return nil }
            let target = evictedRowCount + displayRow

            var low = 0
            var high = blocks.count - 1
            var found: Int?
            while low <= high {
                let mid = (low + high) / 2
                let block = blocks[mid]
                if target < block.rowStart {
                    high = mid - 1
                } else if target >= block.rowStart + block.rowCount {
                    low = mid + 1
                } else {
                    found = mid
                    break
                }
            }
            // No block claims a row the grand total says exists: that is a stale index rather
            // than a row somewhere else, so say nothing instead of scanning from the head.
            guard let blockIndex = found else { return nil }

            let blockNumber = firstBlockNumber + blockIndex
            let firstSequence = max(firstRecordSequence, blockNumber * Self.blockSize)
            var recordIndex = firstSequence - firstRecordSequence
            var remaining = target - blocks[blockIndex].rowStart
            while recordIndex < offsets.count {
                let rows = displayRowCount(recordIndex: recordIndex)
                if remaining < rows {
                    return DisplayRowCursor(recordIndex: recordIndex, rowWithinRecord: remaining)
                }
                remaining -= rows
                recordIndex += 1
            }
            return nil
        }

        /// The next display row after `cursor`, or nil at the end of history.
        func advance(_ cursor: DisplayRowCursor) -> DisplayRowCursor? {
            guard cursor.recordIndex < offsets.count else { return nil }
            let rows = displayRowCount(recordIndex: cursor.recordIndex)
            if cursor.rowWithinRecord + 1 < rows {
                return DisplayRowCursor(
                    recordIndex: cursor.recordIndex,
                    rowWithinRecord: cursor.rowWithinRecord + 1
                )
            }
            let next = cursor.recordIndex + 1
            guard next < offsets.count else { return nil }
            return DisplayRowCursor(recordIndex: next, rowWithinRecord: 0)
        }

        func displayRow(at index: Int) -> Terminal.GridRow? {
            guard let cursor = locate(displayRow: index) else { return nil }
            return gridRow(at: cursor)
        }

        /// Folds one display row out of its record. This is `31/I6`: the cells, kinds, styles,
        /// spacer placement, continuation stamping and soft-wrap marking today's stored rows
        /// carry, derived rather than stored.
        ///
        /// The **content walk**: it stops at the line's cells and never emits a trailing fill,
        /// which is what makes it the right read for copy, selection and search -- the fill is
        /// paint, not text (`31/DD25` as amended). Renderers want `paintedRow(at:)`.
        func gridRow(at cursor: DisplayRowCursor) -> Terminal.GridRow {
            gridRow(recordIndex: cursor.recordIndex, rowWithinRecord: cursor.rowWithinRecord)
        }

        /// The same display row as the renderer must paint it: content, then the trailing fill
        /// out to the right margin when this is the line's last display row and it carries one.
        ///
        /// The **painted walk**. At the width the row was admitted at this reproduces today's
        /// stored row column for column, including the background-erase paint today keeps as
        /// cells; at any other width the paint follows the content's new end, which is what a
        /// terminal of that width running the same bytes would show. A line with a fill and no
        /// content paints its whole single row, which is the ED-with-background case.
        func paintedRow(at cursor: DisplayRowCursor) -> Terminal.GridRow {
            var row = gridRow(at: cursor)
            guard let fill = trailingFillStyle(at: cursor.recordIndex),
                  cursor.rowWithinRecord == displayRowCount(recordIndex: cursor.recordIndex) - 1,
                  row.cells.count < width
            else { return row }
            row.cells.append(
                contentsOf: repeatElement(
                    Terminal.GridCell(scalars: .empty, kind: .padding, styleId: fill),
                    count: width - row.cells.count
                )
            )
            return row
        }

        func paintedDisplayRow(at index: Int) -> Terminal.GridRow? {
            guard let cursor = locate(displayRow: index) else { return nil }
            return paintedRow(at: cursor)
        }

        func recordSummary(at recordIndex: Int) -> RecordSummary? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let record = self.record(at: offsets[recordIndex])
            return RecordSummary(
                cellCount: record.cellCount,
                displayRowCount: displayRowCount(recordIndex: recordIndex),
                isOpen: record.isOpen,
                isForcedSplit: record.isForcedSplit,
                startsMidLine: record.startsMidLine,
                hasWideCells: record.hasWideCells,
                semanticPrompt: record.semanticPrompt,
                trailingFillStyle: trailingFillStyle(at: recordIndex)
            )
        }

        /// One logical line's stored cells, in order. Width-free by construction, which is what
        /// makes `scrollbackRowContentIdentityShape`'s contract literally true once it is
        /// re-denominated to the record (`31/D3` Decision 6).
        ///
        /// Content only: a trailing fill is never among these cells, so a caller that copies a
        /// logical line copies what the program printed and not what the erase painted.
        func recordCells(at recordIndex: Int) -> [Terminal.GridCell]? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let record = self.record(at: offsets[recordIndex])
            return (0..<record.cellCount).map { cell(recordIndex: recordIndex, cellOffset: $0) }
        }

        // MARK: - Fold

        private func displayRowCount(recordIndex: Int) -> Int {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            return LogicalLineFold.rowCount(
                cellCount: record.cellCount,
                width: width,
                hasWideCells: record.hasWideCells,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            )
        }

        private func gridRow(recordIndex: Int, rowWithinRecord: Int) -> Terminal.GridRow {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            var start = 0
            var end = record.cellCount
            var spacer = false
            var rows = 0
            LogicalLineFold.enumerateRows(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { rowIndex, cellStart, cellEnd, spacerAtEnd in
                rows = rowIndex + 1
                guard rowIndex == rowWithinRecord else { return }
                start = cellStart
                end = cellEnd
                spacer = spacerAtEnd
            }

            var cells = (start..<end).map { cell(recordIndex: recordIndex, cellOffset: $0) }
            if spacer, end < record.cellCount {
                // `Terminal.pack`'s rule: the spacer inherits the wide head it defers.
                let deferred = cell(recordIndex: recordIndex, cellOffset: end)
                cells.append(
                    Terminal.GridCell(
                        scalars: .empty,
                        kind: .spacerHead,
                        styleId: deferred.styleId,
                        hyperlinkId: deferred.hyperlinkId,
                        contentIdentity: deferred.contentIdentity
                    )
                )
            }

            var row = Terminal.GridRow(cells: cells)
            row.isSoftWrapped = rowWithinRecord + 1 < rows || record.isOpen || record.isForcedSplit
            if rowWithinRecord == 0 {
                row.semanticPrompt = record.semanticPrompt
            } else {
                row.semanticPrompt = record.semanticPrompt == .none ? .none : .continuation
            }
            return row
        }

        // MARK: - Cell decoding

        private func cell(recordIndex: Int, cellOffset: Int) -> Terminal.GridCell {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            let word = cellWord(recordAt: offset, cell: cellOffset)
            let sequence = firstRecordSequence + recordIndex
            let keyOffset = cellOffset + (recordIndex == 0 ? headTrimmedCells : 0)

            var cell = Terminal.GridCell()
            cell.kind = TerminalCellKind(
                packedCode: UInt8(
                    (word >> PackedRetainedRow.Header.cellKindShift)
                        & PackedRetainedRow.Header.cellKindMask
                )
            )
            cell.styleId = Terminal.StyleId(
                truncatingIfNeeded: word >> PackedRetainedRow.Header.cellStyleShift
            )
            let field = UInt32(word & PackedRetainedRow.Header.cellScalarMask)
            if word & PackedRetainedRow.Header.cellSpillBit != 0 {
                cell.scalars = TerminalScalars(spillsBySequence[sequence]?[Int(field)] ?? [])
            } else if field != 0, let scalar = Unicode.Scalar(field) {
                cell.scalars = TerminalScalars(scalar)
            }
            cell.hyperlinkId = hyperlinkId(record: record, at: offset, keyOffset: keyOffset)
            cell.contentIdentity = contentIdentity(record: record, at: offset, keyOffset: keyOffset)
            return cell
        }

        private func hyperlinkId(
            record: LogicalLineRecord,
            at offset: Int,
            keyOffset: Int
        ) -> Terminal.HyperlinkId? {
            if record.isOpen {
                var low = 0
                var high = openHyperlinks.count - 1
                while low <= high {
                    let mid = (low + high) / 2
                    let entry = openHyperlinks[mid]
                    if entry.offset == keyOffset { return entry.id }
                    if entry.offset < keyOffset { low = mid + 1 } else { high = mid - 1 }
                }
                return nil
            }
            let base = offset + LogicalLineRecord.headerAndCells(record.cellCount)
            var low = 0
            var high = record.hyperlinkCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = base + mid * LogicalLineRecord.hyperlinkEntryBytes
                let column = u16(entry)
                if column == keyOffset { return Terminal.HyperlinkId(u16(entry + 2)) }
                if column < keyOffset { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }

        private func contentIdentity(
            record: LogicalLineRecord,
            at offset: Int,
            keyOffset: Int
        ) -> Terminal.ContentIdentity? {
            if record.isOpen {
                var low = 0
                var high = openIdentityRuns.count - 1
                while low <= high {
                    let mid = (low + high) / 2
                    let run = openIdentityRuns[mid]
                    if keyOffset < run.start {
                        high = mid - 1
                    } else if keyOffset >= run.start + run.extent {
                        low = mid + 1
                    } else {
                        return run.base &+ Terminal.ContentIdentity(keyOffset - run.start)
                    }
                }
                return nil
            }
            let base = offset + LogicalLineRecord.headerAndCells(record.cellCount)
                + record.hyperlinkCount * LogicalLineRecord.hyperlinkEntryBytes
            if record.identityPerCell {
                guard keyOffset < record.identityEntryCount else { return nil }
                let value = u32(base + keyOffset * LogicalLineRecord.identityCellBytes)
                return value == 0 ? nil : value
            }
            var low = 0
            var high = record.identityEntryCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = base + mid * LogicalLineRecord.identityRunEntryBytes
                let start = u16(entry)
                if keyOffset < start {
                    high = mid - 1
                    continue
                }
                let extent = u16(entry + 2)
                if keyOffset >= start + extent {
                    low = mid + 1
                    continue
                }
                return u32(entry + 4) &+ Terminal.ContentIdentity(keyOffset - start)
            }
            return nil
        }

        // MARK: - Arena writing

        private mutating func openRecordIfNeeded(mark: Terminal.SemanticPromptRow) {
            if openTailRecord() != nil { return }
            // A record opened after a forced split continues the previous line, so the mark
            // stays on the piece that started it (`31/PO13`).
            var effectiveMark = mark
            if offsets.count > 0, record(at: offsets[offsets.count - 1]).isForcedSplit {
                effectiveMark = .none
            }
            let record = LogicalLineRecord(semanticPrompt: effectiveMark, isOpen: true)
            writeHeader(record, at: writeCursor)
            appendRecordOffset(writeCursor)
            writeCursor += LogicalLineRecord.Header.byteCount
            bytesInUse += LogicalLineRecord.Header.byteCount
            clearOpenScratch()
        }

        private mutating func appendCells(_ cells: [Terminal.GridCell]) {
            guard cells.isEmpty == false else { return }
            let offset = offsets[offsets.count - 1]
            var record = self.record(at: offset)
            let sequence = firstRecordSequence + offsets.count - 1
            var spills = spillsBySequence[sequence] ?? []
            spillBytes -= spillCost(of: spillsBySequence[sequence])

            for (index, cell) in cells.enumerated() {
                let cellOffset = record.cellCount + index
                var word = UInt64(cell.kind.packedCode) << PackedRetainedRow.Header.cellKindShift
                word |= UInt64(cell.styleId) << PackedRetainedRow.Header.cellStyleShift
                if cell.scalars.count == 1 {
                    word |= UInt64(cell.scalars[0].value)
                } else if cell.scalars.count > 1 {
                    word |= PackedRetainedRow.Header.cellSpillBit | UInt64(spills.count)
                    spills.append(Array(cell.scalars))
                }
                setWord(word, at: offset + LogicalLineRecord.headerAndCells(cellOffset))

                if let id = cell.hyperlinkId {
                    openHyperlinks.append(HyperlinkEntry(offset: cellOffset, id: id))
                }
                if let identity = cell.contentIdentity {
                    // A run is a strict step of one, matching `PackedRetainedRow.pack` -- the
                    // only shape a (base, start, extent) triple reconstructs exactly.
                    if let previous = openPreviousIdentity, identity == previous &+ 1,
                       let open = openIdentityRuns.last, open.start + open.extent == cellOffset
                    {
                        openIdentityRuns[openIdentityRuns.count - 1].extent += 1
                    } else {
                        openIdentityRuns.append(
                            IdentityRun(start: cellOffset, extent: 1, base: identity)
                        )
                    }
                    openPreviousIdentity = identity
                } else {
                    openPreviousIdentity = nil
                }
                if cell.kind == .wideHead { record.hasWideCells = true }
            }

            if spills.isEmpty == false { spillsBySequence[sequence] = spills }
            spillBytes += spillCost(of: spills)

            record.cellCount += cells.count
            writeHeader(record, at: offset)
            writeCursor += cells.count * LogicalLineRecord.cellBytes
            bytesInUse += cells.count * LogicalLineRecord.cellBytes
        }

        /// Writes the open record's side tables after its cells and stamps their counts into the
        /// header. The tables' position is `header + cellCount * 8`, which a later head trim
        /// leaves invariant: the trim moves the header forward by exactly the bytes it drops.
        private mutating func flushOpenTables(into record: inout LogicalLineRecord, at offset: Int) {
            let perCell = openIdentityRuns.count * LogicalLineRecord.identityRunEntryBytes
                > record.cellCount * LogicalLineRecord.identityCellBytes
            record.hyperlinkCount = openHyperlinks.count
            record.identityPerCell = perCell
            record.identityEntryCount = perCell ? record.cellCount : openIdentityRuns.count

            var at = offset + LogicalLineRecord.headerAndCells(record.cellCount)
            for entry in openHyperlinks {
                setU16(entry.offset, at: at)
                setU16(Int(entry.id), at: at + 2)
                at += LogicalLineRecord.hyperlinkEntryBytes
            }
            if perCell {
                for index in 0..<record.cellCount {
                    setU32(0, at: at + index * LogicalLineRecord.identityCellBytes)
                }
                for run in openIdentityRuns {
                    for step in 0..<run.extent where run.start + step < record.cellCount {
                        setU32(
                            run.base &+ Terminal.ContentIdentity(step),
                            at: at + (run.start + step) * LogicalLineRecord.identityCellBytes
                        )
                    }
                }
            } else {
                for run in openIdentityRuns {
                    setU16(run.start, at: at)
                    setU16(run.extent, at: at + 2)
                    setU32(run.base, at: at + 4)
                    at += LogicalLineRecord.identityRunEntryBytes
                }
            }
        }

        /// Reads a closed record's side tables back into the open-tail scratch, so appending can
        /// resume. Reads the tables themselves rather than probing each cell, which keeps
        /// reopening linear in the table rather than quadratic in the record.
        private mutating func loadOpenScratch(from record: LogicalLineRecord, at offset: Int) {
            clearOpenScratch()
            let linkBase = offset + LogicalLineRecord.headerAndCells(record.cellCount)
            for index in 0..<record.hyperlinkCount {
                let entry = linkBase + index * LogicalLineRecord.hyperlinkEntryBytes
                openHyperlinks.append(
                    HyperlinkEntry(offset: u16(entry), id: Terminal.HyperlinkId(u16(entry + 2)))
                )
            }

            let identityBase = linkBase
                + record.hyperlinkCount * LogicalLineRecord.hyperlinkEntryBytes
            guard record.identityPerCell else {
                for index in 0..<record.identityEntryCount {
                    let entry = identityBase + index * LogicalLineRecord.identityRunEntryBytes
                    openIdentityRuns.append(
                        IdentityRun(
                            start: u16(entry),
                            extent: u16(entry + 2),
                            base: u32(entry + 4)
                        )
                    )
                }
                openPreviousIdentity = openIdentityRuns.last.map {
                    $0.base &+ Terminal.ContentIdentity($0.extent - 1)
                }
                return
            }
            for index in 0..<record.identityEntryCount {
                let value = u32(identityBase + index * LogicalLineRecord.identityCellBytes)
                guard value != 0 else {
                    openPreviousIdentity = nil
                    continue
                }
                if let previous = openPreviousIdentity, value == previous &+ 1,
                   let open = openIdentityRuns.last, open.start + open.extent == index
                {
                    openIdentityRuns[openIdentityRuns.count - 1].extent += 1
                } else {
                    openIdentityRuns.append(IdentityRun(start: index, extent: 1, base: value))
                }
                openPreviousIdentity = value
            }
        }

        private mutating func clearOpenScratch() {
            openHyperlinks.removeAll(keepingCapacity: true)
            openIdentityRuns.removeAll(keepingCapacity: true)
            openPreviousIdentity = nil
        }

        // MARK: - Ring discipline

        /// Makes `cells` cells' worth of contiguous room at the write cursor, splitting the open
        /// tail at the physical end (`31/DD20`) and evicting at the head as needed.
        private mutating func makeRoom(forCells cells: Int) {
            while true {
                let openNow = openTailRecord() != nil
                let need = (openNow ? 0 : LogicalLineRecord.Header.byteCount)
                    + cells * LogicalLineRecord.cellBytes
                    + projectedTableBytes(addingCells: cells)
                if contiguousRoomAtCursor >= need, census.chargedBytes + need <= capacity {
                    return
                }
                if offsets.count == 0 {
                    resetToEmptyArena()
                    precondition(capacity >= need, "a record cannot exceed the arena")
                    return
                }
                if contiguousRoomAtCursor < need, writeCursorPrecedesHead == false {
                    wrapWriteCursorAtSeam()
                    continue
                }
                guard evictOneDisplayRow() else { return }
            }
        }

        /// True when the in-use region has wrapped, so the tail's room is bounded by the head
        /// rather than by the physical end.
        private var writeCursorPrecedesHead: Bool {
            bytesInUse > 0 && writeCursor <= head
        }

        private var contiguousRoomAtCursor: Int {
            if bytesInUse == 0 { return capacity - writeCursor }
            if writeCursor > head { return capacity - writeCursor }
            return head - writeCursor
        }

        /// `31/DD20`: the open tail is forced-split at the arena's physical end rather than
        /// reserved for.
        ///
        /// A pad needs a record's length at placement time, which is true of a closed record and
        /// false of the open tail -- admission grows it one display row at a time, long after it
        /// was placed. So the record is closed with the forced-split bit at its current end,
        /// which *is* a display-row boundary at the admitting width, a pad covers the sub-row
        /// remainder, and the continuation opens at offset 0. The two edges: an empty open record
        /// needs no split, and the pad is omitted when the remainder is zero.
        private mutating func wrapWriteCursorAtSeam() {
            if let open = openTailRecord() {
                if open.cellCount > 0 {
                    forceSplitOpenRecord()
                } else {
                    // An open record with no cells still folds to one display row (`31/DD15`'s
                    // floor), so discarding it has to give that row back or the index goes
                    // stale. Reachable only through `reopenTailRecord()` on a blank line.
                    let offset = offsets[offsets.count - 1]
                    grandDisplayRowTotal -= 1
                    if blocks.count > 0 { blocks[blocks.count - 1].rowCount -= 1 }
                    offsets.removeLast()
                    bytesInUse -= LogicalLineRecord.Header.byteCount
                    writeCursor = offset
                    clearOpenScratch()
                    retireEmptyTailBlocks()
                }
            }
            let remainder = capacity - writeCursor
            precondition(remainder % LogicalLineRecord.cellBytes == 0)
            if remainder >= LogicalLineRecord.Header.byteCount {
                let units = (remainder - LogicalLineRecord.Header.byteCount)
                    / LogicalLineRecord.cellBytes
                let pad = LogicalLineRecord(cellCount: units, isPad: true)
                writeHeader(pad, at: writeCursor)
                // Charged at the pad's own length, which is what the head subtracts when it
                // skips it, so the two can never drift.
                bytesInUse += pad.byteLength
            }
            writeCursor = 0
        }

        /// An upper bound on the bytes the open record's side tables will need when it closes.
        ///
        /// Reserved before every append so `31/DD20`'s split can always write them: the seam
        /// test keeps `writeCursor + tables <= capacity` true after each append, which is what
        /// makes "close the open record at its current end" a move that always fits.
        private func projectedTableBytes(addingCells cells: Int) -> Int {
            let openCells = openRecordCellCount + cells
            let runBytes = (openIdentityRuns.count + cells)
                * LogicalLineRecord.identityRunEntryBytes
            let perCellBytes = openCells * LogicalLineRecord.identityCellBytes
            return (openHyperlinks.count + cells) * LogicalLineRecord.hyperlinkEntryBytes
                + min(runBytes, perCellBytes)
                + LogicalLineRecord.cellBytes  // the record's own 8-byte alignment slack
        }

        // MARK: - Index maintenance

        private mutating func appendRecordOffset(_ offset: Int) {
            let sequence = firstRecordSequence + offsets.count
            offsets.append(offset)
            if offsets.count == 1 {
                firstBlockNumber = sequence / Self.blockSize
                blocks.removeAll()
                blocks.append(Block(rowStart: evictedRowCount, rowCount: 0))
                return
            }
            let number = sequence / Self.blockSize
            if number >= firstBlockNumber + blocks.count {
                let previous = blocks[blocks.count - 1]
                blocks.append(Block(rowStart: previous.rowStart + previous.rowCount, rowCount: 0))
            }
        }

        private mutating func addDisplayRowsToTail(_ rows: Int) {
            grandDisplayRowTotal += rows
            if blocks.count > 0 {
                blocks[blocks.count - 1].rowCount += rows
            }
        }

        // MARK: - Header and byte access

        private func record(at offset: Int) -> LogicalLineRecord {
            LogicalLineRecord(word: word(at: offset))
        }

        private func openTailRecord() -> LogicalLineRecord? {
            guard offsets.count > 0 else { return nil }
            let record = self.record(at: offsets[offsets.count - 1])
            return record.isOpen ? record : nil
        }

        private var openRecordCellCount: Int {
            openTailRecord()?.cellCount ?? 0
        }

        private mutating func writeHeader(_ record: LogicalLineRecord, at offset: Int) {
            setWord(record.word, at: offset)
        }

        private func isWideHead(recordAt offset: Int, cell index: Int) -> Bool {
            let word = cellWord(recordAt: offset, cell: index)
            let kind = (word >> PackedRetainedRow.Header.cellKindShift)
                & PackedRetainedRow.Header.cellKindMask
            return kind == UInt64(TerminalCellKind.wideHead.packedCode)
        }

        private func cellWord(recordAt offset: Int, cell index: Int) -> UInt64 {
            word(at: offset + LogicalLineRecord.headerAndCells(index))
        }

        private func word(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for byte in 0..<8 {
                value |= UInt64(arena[offset + byte]) << (8 * byte)
            }
            return value
        }

        private mutating func setWord(_ value: UInt64, at offset: Int) {
            for byte in 0..<8 {
                arena[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte))
            }
        }

        private func u16(_ offset: Int) -> Int {
            Int(arena[offset]) | (Int(arena[offset + 1]) << 8)
        }

        private func u32(_ offset: Int) -> UInt32 {
            UInt32(arena[offset])
                | (UInt32(arena[offset + 1]) << 8)
                | (UInt32(arena[offset + 2]) << 16)
                | (UInt32(arena[offset + 3]) << 24)
        }

        private mutating func setU16(_ value: Int, at offset: Int) {
            arena[offset] = UInt8(truncatingIfNeeded: value)
            arena[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }

        private mutating func setU32(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 {
                arena[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte))
            }
        }

        private func spillCost(of spills: [[Unicode.Scalar]]?) -> Int {
            guard let spills, spills.isEmpty == false else { return 0 }
            var total = Terminal.arrayStorageHeaderBytes
                + spills.capacity * MemoryLayout<[Unicode.Scalar]>.stride
            for spill in spills {
                total += Terminal.arrayStorageHeaderBytes
                    + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
            }
            return total
        }
    }

    /// A fixed-element ring the index deques are built on.
    ///
    /// Written out rather than reached for because the index's charge is
    /// `31/D2` Decision 1's "8 B per record, at the deque's *capacity*": a structure that
    /// charges what the allocator gave needs a capacity it can report, and one that never
    /// shrinks keeps `31/DD11`'s "capacity does not grow" checkable in one comparison.
    struct RingBuffer<Element: Sendable>: Sendable {
        private var storage: ContiguousArray<Element>
        private var start = 0
        private(set) var count = 0
        private let filler: Element

        init(filler: Element, minimumCapacity: Int = 16) {
            self.filler = filler
            storage = ContiguousArray(repeating: filler, count: minimumCapacity)
        }

        var capacity: Int { storage.count }

        subscript(index: Int) -> Element {
            get {
                precondition(index >= 0 && index < count)
                return storage[(start + index) % storage.count]
            }
            set {
                precondition(index >= 0 && index < count)
                storage[(start + index) % storage.count] = newValue
            }
        }

        mutating func append(_ element: Element) {
            if count == storage.count { grow() }
            storage[(start + count) % storage.count] = element
            count += 1
        }

        mutating func removeFirst() {
            precondition(count > 0)
            storage[start] = filler
            start = (start + 1) % storage.count
            count -= 1
        }

        mutating func removeLast() {
            precondition(count > 0)
            count -= 1
            storage[(start + count) % storage.count] = filler
        }

        mutating func removeAll() {
            for index in 0..<storage.count { storage[index] = filler }
            start = 0
            count = 0
        }

        private mutating func grow() {
            var next = ContiguousArray(repeating: filler, count: storage.count * 2)
            for index in 0..<count {
                next[index] = storage[(start + index) % storage.count]
            }
            storage = next
            start = 0
        }
    }
}
