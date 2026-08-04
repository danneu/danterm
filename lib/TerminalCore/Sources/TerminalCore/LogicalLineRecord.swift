// The on-arena record format for doc 31's logical-line scrollback store, and the pure fold
// that derives display rows from one record and a width.
//
// This is doc 31's `D2`/`D3` in bytes: a logical line is one contiguous arena record -- an
// 8-byte header, then the C1 cell words `PackedRetainedRow` already defines, then the two
// column-sorted side tables -- and *nothing* in it depends on the pane's width (`I1`). The
// fold below is the other half of that bargain: everything a per-display-row store baked in
// at admission (where rows break, where a spacer sits, which rows are continuations) is
// recomputed here from (record, width). The trailing background-erase fill is the same bargain
// one step further: the *style* a line's tail is painted in is content, so the header carries a
// bit for it, while *which columns* that paint covers is width-relative and so is derived at
// read (`31/DD25` as amended).
//
// What belongs here: the header's bit layout, a record's decoded shape and byte length, and
// the width-derived row walk. What does not: the arena, the ring, the derived index and the
// five mutating operations -- those are `LogicalLineStore`, which owns the bytes this file
// only describes. Keeping the two apart is what lets the fold be tested as arithmetic.
//
// Its own file for the same reason `PackedRetainedRow` has one: the layout is a contract with
// a diagram, and the one thing a reader needs is the hardest thing to find when it is buried
// in a store's operational code.

extension Terminal {
    /// One logical line's stored shape, as its 8-byte arena header describes it.
    ///
    /// A decoded view, not the storage: the store reads a header word out of the arena, turns
    /// it into one of these, and works in named fields from there. Every field is a **content**
    /// property -- `31/I1` is the whole design, so a width may never reach this struct.
    struct LogicalLineRecord: Equatable, Sendable {
        /// Cells the record currently stores. Reduced by a head trim (`31/D2` Decision 2
        /// step 3), which rewrites this header forward over the cells it drops.
        var cellCount: Int

        /// Entries in the record's column-sorted hyperlink table.
        var hyperlinkCount: Int

        /// Entries in the record's identity table: runs, or one per originally stored cell
        /// when `identityPerCell` is set (`31/D3` Decision 6 keeps `PackedRetainedRow`'s two
        /// encodings). **Never reduced by a head trim**, because the table stays where it is
        /// and keeps its original keys.
        var identityEntryCount: Int

        /// Selects the identity table's encoding, exactly as `PackedRetainedRow`'s flag does.
        var identityPerCell: Bool

        /// The one semantic mark a logical line carries (`31/F4` case 16). Continuation rows
        /// are stamped at read, never stored.
        var semanticPrompt: Terminal.SemanticPromptRow

        /// The line has not ended: it continues into the live grid, so admission may still
        /// append to this record and its last display row reads as soft-wrapped.
        var isOpen: Bool

        /// The line was cut here by the cap (`31/DD3`) or by the arena's physical end
        /// (`31/DD20`), and continues in the next record. Readers rejoin by adjacency --
        /// `31/DD6` leaves no back-pointer.
        var isForcedSplit: Bool

        /// Some cell in the record is a wide head, so the fold must walk boundaries instead
        /// of dividing (`31/F4` Observation 1). Carried per record rather than per buffer
        /// (`31/DD4`), which is why one CJK line never downgrades the whole history.
        var hasWideCells: Bool

        /// This record does not start its logical line: its head was trimmed (`31/D2`
        /// Decision 5) or the forced-split piece before it was evicted (`31/D2` Decision 2
        /// step 2 as amended). Its first display row reads as a continuation.
        var startsMidLine: Bool

        /// Filler placed before the ring's wrap point so a record stays contiguous
        /// (`31/DD14`). Skipped by the head like any other bytes, and charged like them.
        var isPad: Bool

        /// The line's last display row is painted to the right margin, after its content ends,
        /// in a style the store holds in a side table keyed by this record (`31/DD25` as
        /// amended: the trailing background-erase fill is an attribute, not cells).
        ///
        /// A bit rather than a table probe per read: the fill is reachable on a small
        /// minority of records, and the whole point of keeping the style outside the header is
        /// that a record without one pays nothing -- including the lookup.
        var hasTrailingFill: Bool

        // MARK: - Layout

        /// Field positions in the header word, in one place.
        ///
        /// One little-endian `UInt64`, and it has to stay one: `31/D2` Decision 1 prices a
        /// blank logical line at **8 arena bytes and 8 index bytes**, and the 1,048,576-record
        /// blank-history depth that whole decision rests on is that arithmetic. Three 18-bit
        /// counts, a 3-bit mark and seven flags is exactly 64 bits, and the word is now **full**:
        /// `31/DD25`'s amendment spent the spare bit on the trailing fill, so the next flag costs
        /// either a narrower count field or a ninth byte no blank record can afford.
        ///
        ///     bits  0..17  cell count
        ///     bits 18..35  hyperlink table entries
        ///     bits 36..53  identity table entries
        ///     bits 54..56  semantic mark, as `SemanticPromptRow.packedCode`
        ///     bit  57      open
        ///     bit  58      forced split
        ///     bit  59      has wide cells
        ///     bit  60      starts mid-line
        ///     bit  61      pad
        ///     bit  62      identity stored per cell
        ///     bit  63      has a trailing fill style (the style itself is a side table)
        enum Header {
            static let byteCount = 8
            static let countBits: UInt64 = 18
            static let countMask: UInt64 = (1 << countBits) - 1
            static let maximumCount = Int(countMask)

            static let cellCountShift: UInt64 = 0
            static let hyperlinkCountShift: UInt64 = 18
            static let identityCountShift: UInt64 = 36
            static let promptShift: UInt64 = 54
            static let promptMask: UInt64 = 0x7

            static let openBit: UInt64 = 1 << 57
            static let forcedSplitBit: UInt64 = 1 << 58
            static let wideCellsBit: UInt64 = 1 << 59
            static let midLineBit: UInt64 = 1 << 60
            static let padBit: UInt64 = 1 << 61
            static let identityPerCellBit: UInt64 = 1 << 62
            static let trailingFillBit: UInt64 = 1 << 63
        }

        /// Bytes one cell occupies -- the same C1 word `PackedRetainedRow` stores, verbatim,
        /// which is what makes the two stores' cell decoding one implementation.
        static let cellBytes = PackedRetainedRow.Header.cellBytes
        static let hyperlinkEntryBytes = PackedRetainedRow.Header.hyperlinkEntryBytes
        static let identityRunEntryBytes = PackedRetainedRow.Header.identityRunEntryBytes
        static let identityCellBytes = PackedRetainedRow.Header.identityCellBytes

        init(
            cellCount: Int = 0,
            hyperlinkCount: Int = 0,
            identityEntryCount: Int = 0,
            identityPerCell: Bool = false,
            semanticPrompt: Terminal.SemanticPromptRow = .none,
            isOpen: Bool = false,
            isForcedSplit: Bool = false,
            hasWideCells: Bool = false,
            startsMidLine: Bool = false,
            isPad: Bool = false,
            hasTrailingFill: Bool = false
        ) {
            self.cellCount = cellCount
            self.hyperlinkCount = hyperlinkCount
            self.identityEntryCount = identityEntryCount
            self.identityPerCell = identityPerCell
            self.semanticPrompt = semanticPrompt
            self.isOpen = isOpen
            self.isForcedSplit = isForcedSplit
            self.hasWideCells = hasWideCells
            self.startsMidLine = startsMidLine
            self.isPad = isPad
            self.hasTrailingFill = hasTrailingFill
        }

        init(word: UInt64) {
            cellCount = Int((word >> Header.cellCountShift) & Header.countMask)
            hyperlinkCount = Int((word >> Header.hyperlinkCountShift) & Header.countMask)
            identityEntryCount = Int((word >> Header.identityCountShift) & Header.countMask)
            semanticPrompt = Terminal.SemanticPromptRow(
                packedCode: UInt8((word >> Header.promptShift) & Header.promptMask)
            )
            identityPerCell = word & Header.identityPerCellBit != 0
            isOpen = word & Header.openBit != 0
            isForcedSplit = word & Header.forcedSplitBit != 0
            hasWideCells = word & Header.wideCellsBit != 0
            startsMidLine = word & Header.midLineBit != 0
            isPad = word & Header.padBit != 0
            hasTrailingFill = word & Header.trailingFillBit != 0
        }

        var word: UInt64 {
            precondition(cellCount >= 0 && cellCount <= Header.maximumCount)
            precondition(hyperlinkCount >= 0 && hyperlinkCount <= Header.maximumCount)
            precondition(identityEntryCount >= 0 && identityEntryCount <= Header.maximumCount)
            var value = UInt64(cellCount) << Header.cellCountShift
            value |= UInt64(hyperlinkCount) << Header.hyperlinkCountShift
            value |= UInt64(identityEntryCount) << Header.identityCountShift
            value |= UInt64(semanticPrompt.packedCode) << Header.promptShift
            if identityPerCell { value |= Header.identityPerCellBit }
            if isOpen { value |= Header.openBit }
            if isForcedSplit { value |= Header.forcedSplitBit }
            if hasWideCells { value |= Header.wideCellsBit }
            if startsMidLine { value |= Header.midLineBit }
            if isPad { value |= Header.padBit }
            if hasTrailingFill { value |= Header.trailingFillBit }
            return value
        }

        // MARK: - Geometry

        /// Bytes the identity table occupies after the hyperlink table.
        var identityByteCount: Int {
            identityPerCell
                ? identityEntryCount * Self.identityCellBytes
                : identityEntryCount * Self.identityRunEntryBytes
        }

        /// Bytes this record occupies in the arena, header included, rounded to the 8-byte
        /// grain every offset in the store keeps.
        ///
        /// A pad borrows the cell-count field for its own length, so the head skips it with
        /// the same arithmetic it uses for a real record.
        var byteLength: Int {
            guard isPad == false else { return Self.headerAndCells(cellCount) }
            let unaligned = Self.headerAndCells(cellCount)
                + hyperlinkCount * Self.hyperlinkEntryBytes
                + identityByteCount
            return (unaligned + 7) & ~7
        }

        static func headerAndCells(_ cells: Int) -> Int {
            Header.byteCount + cells * cellBytes
        }

        /// The cap `31/I10` states as "no record exceeds 1/32 of the byte budget", derived
        /// from the arena's capacity rather than frozen as a literal.
        ///
        /// `31/DD3` ratified the **rule**, not the number: at the 16 MiB budget it is 65,536
        /// cells, and it moves if the budget does. Clamped to what the header can express, so
        /// a budget larger than 64 MiB narrows the cap instead of silently truncating a count.
        static func forcedSplitCellCount(forCapacity capacity: Int) -> Int {
            max(1, min(Header.maximumCount, (capacity / 32) / cellBytes))
        }
    }

    /// The width-derived fold: how one record's cells break into display rows.
    ///
    /// Pure arithmetic over a cell count, a width and a "is this cell a wide head" probe, so
    /// it can be reasoned about and tested without an arena. This is the work a
    /// per-display-row store did once at admission and this design does at every read --
    /// which `31/F1` measured as the *cheaper* of the two, not the dearer.
    enum LogicalLineFold {
        /// Display rows the record occupies at `width`.
        ///
        /// `max(1, ceil((cells + spacers) / width))`. The floor is what makes a zero-cell
        /// record one display row (`31/DD15`); without it a blank history folds to nothing.
        /// The fast path is exact whenever no wide cell can meet a boundary, which is the
        /// `hasWideCells` bit's entire job (`31/F4` Observation 1, `31/DD4`).
        static func rowCount(
            cellCount: Int,
            width: Int,
            hasWideCells: Bool,
            isWideHead: (Int) -> Bool
        ) -> Int {
            precondition(width >= 1)
            guard hasWideCells, width >= 2 else {
                return max(1, (cellCount + width - 1) / width)
            }
            return enumerateRows(
                cellCount: cellCount,
                width: width,
                isWideHead: isWideHead
            ) { _, _, _, _ in }
        }

        /// Walks the record's display rows in order, reporting each one's cell range and
        /// whether a `.spacerHead` fills its last column. Returns the row count.
        ///
        /// The spacer rule is `Terminal.pack(line:columns:)`'s, restated: a 2-cell cluster
        /// that meets a row with one column left does not split -- a spacer fills the column
        /// and the cluster starts the next row. The spacer is derived here and never stored
        /// (`31/F4` case 1), which is what keeps a record's bytes width-free.
        @discardableResult
        static func enumerateRows(
            cellCount: Int,
            width: Int,
            isWideHead: (Int) -> Bool,
            _ body: (_ row: Int, _ cellStart: Int, _ cellEnd: Int, _ spacerAtEnd: Bool) -> Void
        ) -> Int {
            precondition(width >= 1)
            var rows = 0
            var rowStart = 0
            var column = 0
            var index = 0

            while index < cellCount {
                if width >= 2, column == width - 1, isWideHead(index) {
                    body(rows, rowStart, index, true)
                    rows += 1
                    rowStart = index
                    column = 0
                }
                column += 1
                index += 1
                if column == width {
                    body(rows, rowStart, index, false)
                    rows += 1
                    rowStart = index
                    column = 0
                }
            }

            if rowStart < cellCount || rows == 0 {
                body(rows, rowStart, cellCount, false)
                rows += 1
            }
            return rows
        }

        /// The cell offset that begins the record's *second* display row, or its cell count when
        /// it has only one.
        ///
        /// Split out from `enumerateRows` because eviction asks exactly this question and must
        /// stop at the answer: `31/D2` Decision 2 step 1 folds **one display row** per trim step
        /// -- `O(width)`, or `O(cells in that row)` on the wide path -- and the complexity that
        /// bound rests on is the reading `31/D4` froze its decision rule against.
        ///
        /// The `hasWideCells` fast path is the same one `rowCount` takes and for the same reason
        /// (`31/DD4`): without a wide cell no boundary test can fail, so the answer is arithmetic
        /// and the walk is `O(1)` rather than `O(width)` -- which matters because eviction asks
        /// The *first* row is the one case `enumerateRows`' walk collapses to arithmetic: its
        /// column and its cell index advance together from zero, so the only boundary test that
        /// can fire is the one at the last column. One display row per trim step therefore costs
        /// one probe rather than a walk over the row -- which matters because eviction asks this
        /// once per dropped display row, and `31/D4` gate 7 measures exactly that step.
        ///
        /// `hasWideCells` skips even the probe for a record that cannot contain a wide head
        /// (`31/DD4`); it defaults to taking it, which is correct for every record.
        static func firstRowCellEnd(
            cellCount: Int,
            width: Int,
            hasWideCells: Bool = true,
            isWideHead: (Int) -> Bool
        ) -> Int {
            precondition(width >= 1)
            guard hasWideCells, width >= 2, cellCount >= width, isWideHead(width - 1) else {
                return min(cellCount, width)
            }
            // A 2-cell cluster meeting the last column does not split: the spacer fills the
            // column and the cluster starts the next row.
            return width - 1
        }
    }
}
