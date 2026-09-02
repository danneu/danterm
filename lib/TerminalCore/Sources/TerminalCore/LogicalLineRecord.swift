// The on-arena record format for doc 31's logical-line scrollback store, and the pure fold
// that derives display rows from one record and a width.
//
// This is `research/31/D2` and `research/31/D3` in bytes: a logical line is one wrapped arena
// interval -- an 8-byte header, then the C1 cell words `CellWord` below defines, then the two
// column-sorted side tables. The interval may cross chunk boundaries and the arena end, and
// *nothing* in it depends on the pane's width (`I1`). The
// fold below is the other half of that bargain: everything a per-display-row store baked in
// at admission (where rows break, where a spacer sits, which rows are continuations) is
// recomputed here from (record, width). The trailing background-erase fill is the same bargain
// one step further: the *style* a line's tail is painted in is content, so the header carries a
// bit for it, while *which columns* that paint covers is width-relative and so is derived at
// read.
//
// What belongs here: the header's bit layout, the cell word's bit layout and the one-byte
// codings the two store enums in, a record's decoded shape and byte length, and the
// width-derived row walk. What does not: the arena, the ring, the derived index and the
// five mutating operations -- those are `LogicalLineStore`, which owns the bytes this file
// only describes. Keeping the two apart is what lets the fold be tested as arithmetic.
//
// Its own file because the layout is a contract with a diagram, and the one thing a reader
// needs is the hardest thing to find when it is buried in a store's operational code.

extension Terminal {
    /// One logical line's stored shape, as its 8-byte arena header describes it.
    ///
    /// A decoded view, not the storage: the store reads a header word out of the arena, turns
    /// it into one of these, and works in named fields from there. Every field is a **content**
    /// property -- `31/I1` is the whole design, so a width may never reach this struct.
    struct LogicalLineRecord: Equatable, Sendable {
        /// Cells the record currently stores. Reduced by a head trim (`research/31/D2` Decision 2
        /// step 3), which rewrites this header forward over the cells it drops.
        var cellCount: Int

        /// Entries in the record's hyperlink table.
        var hyperlinkCount: Int

        /// Selects one hyperlink id per represented cell instead of sparse keyed entries.
        var hyperlinkPerCell: Bool

        /// Entries in the record's identity table: runs, or one per originally stored cell
        /// when `identityPerCell` is set (`research/31/D3` Decision 6 gives identity two
        /// encodings). **Never reduced by a head trim**, because the table stays where it is
        /// and keeps its original keys.
        var identityEntryCount: Int

        /// Selects the identity table's encoding: one entry per contiguous identity run when
        /// clear, one entry per stored cell when set.
        var identityPerCell: Bool

        /// The one semantic mark a logical line carries (`research/31/F4` case 16). Continuation rows
        /// are stamped at read, never stored.
        var semanticPrompt: Terminal.SemanticPromptRow

        /// The line has not ended: it continues into the live grid, so admission may still
        /// append to this record and its last display row reads as soft-wrapped.
        var isOpen: Bool

        /// Some cell in the record is a wide head, so the fold must walk boundaries instead
        /// of dividing (`research/31/F4` Observation 1). Carried per record rather than per buffer
        /// (`research/31/DD4`), which is why one CJK line never downgrades the whole history.
        var hasWideCells: Bool

        /// This record does not start its logical line because its head was trimmed
        /// (`research/31/D2` Decision 5). Its first display row reads as a continuation.
        var startsMidLine: Bool

        /// The line's last display row is painted to the right margin, after its content ends,
        /// in a style the store holds in a side table keyed by this record. The trailing
        /// background-erase fill is an attribute, not cells.
        ///
        /// A bit rather than a table probe per read: the fill is reachable on a small
        /// minority of records, and the whole point of keeping the style outside the header is
        /// that a record without one pays nothing -- including the lookup.
        var hasTrailingFill: Bool

        // MARK: - Layout

        /// Field positions in the header word, in one place.
        ///
        /// One little-endian `UInt64`, and it has to stay one: `research/31/D2` Decision 1 prices a
        /// blank logical line at **8 arena bytes and 8 index bytes**, and the 1,048,576-record
        /// blank-history depth that whole decision rests on is that arithmetic. The 22-bit cell
        /// count covers the production arena. A table changes to per-cell storage before its
        /// 16-bit sparse-entry count overflows.
        ///
        ///     bits  0..21  cell count
        ///     bits 22..37  hyperlink table entries
        ///     bits 38..53  identity table entries
        ///     bits 54..56  semantic mark, as `SemanticPromptRow.packedCode`
        ///     bit  57      open
        ///     bit  58      hyperlink stored per cell
        ///     bit  59      has wide cells
        ///     bit  60      starts mid-line
        ///     bit  61      unused
        ///     bit  62      identity stored per cell
        ///     bit  63      has a trailing fill style (the style itself is a side table)
        enum Header {
            static let byteCount = 8
            static let cellCountBits: UInt64 = 22
            static let cellCountMask: UInt64 = (1 << cellCountBits) - 1
            static let maximumCellCount = Int(cellCountMask)
            static let tableCountBits: UInt64 = 16
            static let tableCountMask: UInt64 = (1 << tableCountBits) - 1
            static let maximumTableCount = Int(tableCountMask)

            static let cellCountShift: UInt64 = 0
            static let hyperlinkCountShift: UInt64 = 22
            static let identityCountShift: UInt64 = 38
            static let promptShift: UInt64 = 54
            static let promptMask: UInt64 = 0x7

            static let openBit: UInt64 = 1 << 57
            static let hyperlinkPerCellBit: UInt64 = 1 << 58
            static let wideCellsBit: UInt64 = 1 << 59
            static let midLineBit: UInt64 = 1 << 60
            static let identityPerCellBit: UInt64 = 1 << 62
            static let trailingFillBit: UInt64 = 1 << 63
        }

        /// Bytes one cell occupies: the `CellWord` below, which is why the two are edited
        /// together or not at all.
        static let cellBytes = 8

        /// original cell key(4) + hyperlinkId(2) + alignment(2).
        static let hyperlinkEntryBytes = 8

        /// hyperlinkId(2), with zero representing no hyperlink.
        static let hyperlinkCellBytes = 2

        /// Bytes a per-cell hyperlink table occupies before the 4-byte identity table.
        static func hyperlinkCellTableBytes(forCells cells: Int) -> Int {
            (cells * hyperlinkCellBytes + 3) & ~3
        }

        /// start(4) + extent(4) + base(4).
        static let identityRunEntryBytes = 12

        /// identity(4), in the per-cell identity encoding.
        static let identityCellBytes = 4

        init(
            cellCount: Int = 0,
            hyperlinkCount: Int = 0,
            hyperlinkPerCell: Bool = false,
            identityEntryCount: Int = 0,
            identityPerCell: Bool = false,
            semanticPrompt: Terminal.SemanticPromptRow = .none,
            isOpen: Bool = false,
            hasWideCells: Bool = false,
            startsMidLine: Bool = false,
            hasTrailingFill: Bool = false
        ) {
            self.cellCount = cellCount
            self.hyperlinkCount = hyperlinkCount
            self.hyperlinkPerCell = hyperlinkPerCell
            self.identityEntryCount = identityEntryCount
            self.identityPerCell = identityPerCell
            self.semanticPrompt = semanticPrompt
            self.isOpen = isOpen
            self.hasWideCells = hasWideCells
            self.startsMidLine = startsMidLine
            self.hasTrailingFill = hasTrailingFill
        }

        init(word: UInt64) {
            cellCount = Int((word >> Header.cellCountShift) & Header.cellCountMask)
            hyperlinkCount = Int((word >> Header.hyperlinkCountShift) & Header.tableCountMask)
            identityEntryCount = Int((word >> Header.identityCountShift) & Header.tableCountMask)
            semanticPrompt = Terminal.SemanticPromptRow(
                packedCode: UInt8((word >> Header.promptShift) & Header.promptMask)
            )
            identityPerCell = word & Header.identityPerCellBit != 0
            hyperlinkPerCell = word & Header.hyperlinkPerCellBit != 0
            isOpen = word & Header.openBit != 0
            hasWideCells = word & Header.wideCellsBit != 0
            startsMidLine = word & Header.midLineBit != 0
            hasTrailingFill = word & Header.trailingFillBit != 0
        }

        var word: UInt64 {
            precondition(cellCount >= 0 && cellCount <= Header.maximumCellCount)
            precondition(hyperlinkCount >= 0 && hyperlinkCount <= Header.maximumTableCount)
            precondition(identityEntryCount >= 0 && identityEntryCount <= Header.maximumTableCount)
            var value = UInt64(cellCount) << Header.cellCountShift
            value |= UInt64(hyperlinkCount) << Header.hyperlinkCountShift
            value |= UInt64(identityEntryCount) << Header.identityCountShift
            value |= UInt64(semanticPrompt.packedCode) << Header.promptShift
            if identityPerCell { value |= Header.identityPerCellBit }
            if hyperlinkPerCell { value |= Header.hyperlinkPerCellBit }
            if isOpen { value |= Header.openBit }
            if hasWideCells { value |= Header.wideCellsBit }
            if startsMidLine { value |= Header.midLineBit }
            if hasTrailingFill { value |= Header.trailingFillBit }
            return value
        }

        // MARK: - Geometry

        /// Bytes the identity table occupies after the hyperlink table.
        var identityByteCount: Int {
            identityPerCell
                ? cellCount * Self.identityCellBytes
                : identityEntryCount * Self.identityRunEntryBytes
        }

        /// Bytes the hyperlink table occupies after the cells.
        var hyperlinkByteCount: Int {
            hyperlinkPerCell
                ? Self.hyperlinkCellTableBytes(forCells: cellCount)
                : hyperlinkCount * Self.hyperlinkEntryBytes
        }

        /// Bytes this record occupies in the arena, header included, rounded to the 8-byte
        /// grain every offset in the store keeps.
        ///
        var byteLength: Int {
            let unaligned = Self.headerAndCells(cellCount)
                + hyperlinkByteCount
                + identityByteCount
            return (unaligned + 7) & ~7
        }

        static func headerAndCells(_ cells: Int) -> Int {
            Header.byteCount + cells * cellBytes
        }

    }

    /// The 8-byte word one stored cell occupies.
    ///
    /// Its own type beside `LogicalLineRecord.Header`, not inside it: that enum lays out
    /// the *record* header, a different 8-byte word, and a reader who conflates the two
    /// misreads both. This is `research/28/C1`, the one part of the per-display-row store the
    /// arena kept verbatim.
    ///
    ///     bits  0..20  scalar value, or a spill index when the spill bit is set
    ///     bits 21..23  kind, as `TerminalCellKind.packedCode`
    ///     bit  24      spill flag
    ///     bits 25..31  unused
    ///     bits 32..63  interned `StyleId`, full width
    ///
    /// 21 bits is exactly `U+10FFFF`, so **every scalar in Unicode is inline** -- there is no
    /// exception path for an emoji, and a cell stays a fixed width the store can index without
    /// a scan. `StyleId` keeps all 32 bits, so no style-table ceiling is introduced. What is
    /// left over is 7 spare bits, and they are left spare.
    ///
    /// The shifts and masks above live here and nowhere else. `LogicalLineStore` writes and
    /// reads cells only through this type, so a layout change is one edit rather than a sweep
    /// over a dozen hand-inlined sites, each of which could decode plausible garbage instead
    /// of failing to compile.
    struct CellWord: Equatable, Sendable {
        private static let scalarMask: UInt64 = 0x1F_FFFF
        static let maximumSpillIndex = Int(scalarMask)
        private static let kindShift: UInt64 = 21
        private static let kindMask: UInt64 = 0x7
        private static let spillBit: UInt64 = 1 << 24
        private static let styleShift: UInt64 = 32

        /// The word exactly as the arena holds it. The store's chunks are `UInt64`, so this is
        /// what a write stores and what a borrowed-pointer read loop loads back.
        let raw: UInt64

        /// Wraps a word read out of the arena.
        @inline(__always) init(raw: UInt64) {
            self.raw = raw
        }

        /// A cell with no scalar payload: a padding cell, a wide cell's tail, or a spacer.
        @inline(__always) init(kind: TerminalCellKind, styleId: Terminal.StyleId) {
            raw = Self.head(kind: kind, styleId: styleId)
        }

        /// A cell whose whole content is one scalar, which is every cell that is not a
        /// multi-scalar grapheme.
        @inline(__always) init(
            kind: TerminalCellKind,
            styleId: Terminal.StyleId,
            scalar: Unicode.Scalar
        ) {
            raw = Self.head(kind: kind, styleId: styleId) | UInt64(scalar.value)
        }

        /// A cell whose scalars live in the record's spill table at `spillIndex`.
        @inline(__always) init(
            kind: TerminalCellKind,
            styleId: Terminal.StyleId,
            spillIndex: Int
        ) {
            precondition(spillIndex >= 0 && spillIndex <= Int(Self.scalarMask))
            raw = Self.head(kind: kind, styleId: styleId) | Self.spillBit | UInt64(spillIndex)
        }

        @inline(__always) func replacing(kind: TerminalCellKind) -> Self {
            Self(raw: (raw & ~(Self.kindMask << Self.kindShift)) | UInt64(kind.packedCode) << Self.kindShift)
        }

        @inline(__always) func replacing(styleId: Terminal.StyleId) -> Self {
            Self(raw: (raw & UInt64(UInt32.max)) | UInt64(styleId) << Self.styleShift)
        }

        @inline(__always) private static func head(
            kind: TerminalCellKind,
            styleId: Terminal.StyleId
        ) -> UInt64 {
            UInt64(kind.packedCode) << kindShift | UInt64(styleId) << styleShift
        }

        @inline(__always) var kind: TerminalCellKind {
            TerminalCellKind(packedCode: UInt8((raw >> Self.kindShift) & Self.kindMask))
        }

        @inline(__always) var styleId: Terminal.StyleId {
            Terminal.StyleId(truncatingIfNeeded: raw >> Self.styleShift)
        }

        /// Whether the payload field names an entry in the record's spill table rather than
        /// holding a scalar inline.
        @inline(__always) var isSpilled: Bool {
            raw & Self.spillBit != 0
        }

        /// The spill table index, meaningful only when `isSpilled`.
        @inline(__always) var spillIndex: Int {
            Int(raw & Self.scalarMask)
        }

        /// The cell's single inline scalar, or nil when it has none -- a spilled cell, an empty
        /// payload, or a field no longer in the Unicode range.
        @inline(__always) var inlineScalar: Unicode.Scalar? {
            guard isSpilled == false else { return nil }
            let field = UInt32(raw & Self.scalarMask)
            guard field != 0 else { return nil }
            return Unicode.Scalar(field)
        }
    }

    /// The width-derived fold: how one record's cells break into display rows.
    ///
    /// Pure arithmetic over a cell count, a width and a "is this cell a wide head" probe, so
    /// it can be reasoned about and tested without an arena. This is the work a
    /// per-display-row store did once at admission and this design does at every read --
    /// which `research/31/F1` measured as the *cheaper* of the two, not the dearer.
    enum LogicalLineFold {
        /// Display rows the record occupies at `width`.
        ///
        /// `max(1, ceil((cells + spacers) / width))`. The floor is what makes a zero-cell
        /// record one display row (`research/31/DD15`); without it a blank history folds to nothing.
        /// The fast path is exact whenever no wide cell can meet a boundary, which is the
        /// `hasWideCells` bit's entire job (`research/31/F4` Observation 1, `research/31/DD4`).
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
        /// (`research/31/F4` case 1), which is what keeps a record's bytes width-free.
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
        /// stop at the answer: `research/31/D2` Decision 2 step 1 folds **one display row** per trim step
        /// -- `O(width)`, or `O(cells in that row)` on the wide path -- and the complexity that
        /// bound rests on is the reading `research/31/D4` froze its decision rule against.
        ///
        /// The *first* row is the one case `enumerateRows`' walk collapses to arithmetic: its
        /// column and its cell index advance together from zero, so the only boundary test that
        /// can fire is the one at the last column. One display row per trim step therefore costs
        /// one probe rather than a walk over the row -- which matters because eviction asks this
        /// once per dropped display row, and `research/31/D4` gate 7 measures exactly that step.
        ///
        /// `hasWideCells` skips even the probe for a record that cannot contain a wide head --
        /// the same fast path, and the same reason, as `rowCount`'s (`research/31/DD4`); it defaults to
        /// taking it, which is correct for every record.
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

extension TerminalCellKind {
    /// A stable one-byte encoding for the cell word's kind field. Written out rather than
    /// taken from a `RawRepresentable` conformance because the raw value would then be public
    /// API, and the stored encoding is not something outside `TerminalCore` may depend on.
    /// Must stay within three bits -- see `CellWord`'s layout diagram.
    var packedCode: UInt8 {
        switch self {
        case .padding: 0
        case .narrow: 1
        case .wideHead: 2
        case .wideTail: 3
        case .spacerHead: 4
        }
    }

    init(packedCode: UInt8) {
        switch packedCode {
        case 1: self = .narrow
        case 2: self = .wideHead
        case 3: self = .wideTail
        case 4: self = .spacerHead
        default: self = .padding
        }
    }
}

extension Terminal.SemanticPromptRow {
    /// The record header's semantic-mark field, for the same reason as above: three bits of a
    /// stored word, kept out of the public API.
    var packedCode: UInt8 {
        switch self {
        case .none: 0
        case .prompt: 1
        case .continuation: 2
        case .output: 3
        case .vacated: 4
        }
    }

    init(packedCode: UInt8) {
        switch packedCode {
        case 1: self = .prompt
        case 2: self = .continuation
        case 3: self = .output
        case 4: self = .vacated
        default: self = .none
        }
    }
}
