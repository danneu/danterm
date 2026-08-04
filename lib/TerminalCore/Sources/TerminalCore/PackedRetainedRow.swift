// The packed, immutable form a row takes once it leaves the live grid for history.
//
// This is doc 28's `C1`, selected by `D9`: a retained row is one byte blob holding a fixed
// **8-byte cell** per stored column, plus two column-sorted side tables (hyperlinks and
// `contentIdentity`) and the two row-level fields (`isSoftWrapped`, `semanticPrompt`) that
// no cell carries. It exists because doc 28's `F8` put 89.5% of saturated attributable
// footprint in stored cell bytes, and a retained cell was paying a 32-byte live-grid struct
// for content that needs eight.
//
// What belongs here: the encoding, the readers that decode it, and the byte accounting that
// prices it. What does not: anything about *when* a row is packed (that is admission, in
// Terminal.swift beside canonical trimming), and anything about the live grid, which `I1`
// closes -- `GridCell` is unchanged and this type never appears in it.
//
// Its own file because the encoding is a self-contained contract with a layout diagram, and
// burying the byte offsets in a 6,000-line Terminal.swift would make the one thing a reader
// needs -- the layout -- the hardest thing to find.
//
// **Why eight bytes and not one.** The predecessor here was `C6`: a per-row stride tier, a
// run-length style table, and three exception tables, priced at 128 B/row against this
// design's 528 B/row. It shipped, and it failed the deciding ladder -- `28/F16` measured
// `retained-browse` at +19.83%, `28/F17` fixed everything that was wiring and landed at
// +3.27%, and what remained was the decode itself at roughly 3.8 ns per cell. `D9` took the
// bytes back to buy the read. What makes that affordable is `D8`: both retained-history caps
// count *content* (327,680 stored cells, 16,384 rows), not bytes, so an 8-byte cell retains
// exactly the rows a 1-byte cell retained and the byte budget binds under neither. The
// exchange is memory alone -- `28/F18` has the arithmetic.
//
// **The read contract is `I5`, and under this shape most of it is structural.** A random cell
// read is one load at `base + column * 8`: no stride to resolve, no run to search, no
// exception table to consult. Only the two side tables need a binary search, and only for the
// rare cell that has an entry in one. Keep it that way; a linear fallback here gives up the
// reason this representation was chosen over the one it replaced.

extension Terminal {
    /// One retained row, stored as a single byte blob plus its multi-scalar spills.
    ///
    /// Two stored properties on purpose. `MemoryLayout<PackedRetainedRow>.stride` is the
    /// per-row slot cost in history's own buffer, which doc 28 priced at 16 bytes
    /// (`GRID_ROW_SLOT_BYTES`), and every row pays it whether or not it holds content. That
    /// is why `isSoftWrapped` and `semanticPrompt` live in a header byte inside the blob
    /// rather than as stored properties: as properties they would round the slot to 24
    /// bytes for every retained row, which at the depths this change unlocks costs more
    /// than the bit-packing saves.
    ///
    /// `spills` is empty for the 99.88% of rows with no multi-scalar cell (`F11`), and an
    /// empty Swift array allocates nothing, so the second word is free in the common case.
    struct PackedRetainedRow: Equatable, Sendable {
        /// The blob. Layout is documented on `Header` and fixed by `pack(_:)`/the readers.
        private(set) var storage: [UInt8]

        /// Scalar payloads for multi-scalar cells, reached by the index a cell's scalar
        /// field holds in place of a scalar. Held outside the blob because they are already
        /// separate allocations the budget charges, and inlining them would make the cell
        /// column variable-width -- giving up `I5` for the rarest cell in the corpus.
        private(set) var spills: [[Unicode.Scalar]]

        /// An empty row: no stored cells, no metadata. What an evicted slot holds.
        init() {
            storage = Header.emptyBlob
            spills = []
        }

        private init(storage: [UInt8], spills: [[Unicode.Scalar]]) {
            self.storage = storage
            self.spills = spills
        }

        // MARK: - Layout

        /// Byte offsets and field widths of the blob, in one place.
        ///
        /// After the header come three runs of fixed-width entries: the cell column, the
        /// hyperlink table, and the identity table. Fixed width per section is what makes
        /// the cell column indexable and the two tables binary-searchable, which is `I5`.
        ///
        /// **The cell word**, little-endian, is where `C1` differs from every candidate that
        /// stores a scalar and its metadata apart:
        ///
        ///     bits  0..20  scalar value, or a spill index when `cellSpillBit` is set
        ///     bits 21..23  kind, as `TerminalCellKind.packedCode`
        ///     bit  24      spill flag
        ///     bits 25..31  unused
        ///     bits 32..63  interned `StyleId`, full width
        ///
        /// 21 bits is exactly `U+10FFFF`, so **every scalar in Unicode is inline** -- there
        /// is no exception path for an emoji, which `C6` reached by promoting the whole
        /// row's stride. And `StyleId` keeps all 32 bits, so no style-table ceiling is
        /// introduced; `D5`'s sketch of this candidate narrowed it to 16 bits against a
        /// measured table size, which was risk for no gain and is deliberately not carried
        /// over. What is left over is 7 spare bits, and they are left spare.
        enum Header {
            /// flags(1) + storedCells(2) + hyperlinkEntries(2) + identityEntries(2)
            static let byteCount = 7

            static let cellBytes = 8
            static let hyperlinkEntryBytes = 4     // column(2) + hyperlinkId(2)
            static let identityRunEntryBytes = 8   // start(2) + extent(2) + base(4)
            static let identityCellBytes = 4       // identity(4)

            static let softWrapBit: UInt8 = 0x01
            static let promptShift: UInt8 = 1
            static let promptMask: UInt8 = 0x0E
            static let identityPerCellBit: UInt8 = 0x10

            static let cellScalarMask: UInt64 = 0x1F_FFFF
            static let cellKindShift: UInt64 = 21
            static let cellKindMask: UInt64 = 0x7
            static let cellSpillBit: UInt64 = 1 << 24
            static let cellStyleShift: UInt64 = 32

            static let emptyBlob = [UInt8](repeating: 0, count: byteCount)
        }

        // MARK: - Header reads

        private func u16(_ offset: Int) -> Int {
            Int(storage[offset]) | (Int(storage[offset + 1]) << 8)
        }

        private func u32(_ offset: Int) -> UInt32 {
            UInt32(storage[offset])
                | (UInt32(storage[offset + 1]) << 8)
                | (UInt32(storage[offset + 2]) << 16)
                | (UInt32(storage[offset + 3]) << 24)
        }

        private func u64(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for byte in 0..<8 {
                value |= UInt64(storage[offset + byte]) << (8 * byte)
            }
            return value
        }

        private var flags: UInt8 { storage[0] }

        /// Columns this row physically stores. Canonical trimming (`I2`) makes this a pure
        /// function of observable content, unchanged from the unpacked representation.
        var storedCellCount: Int { u16(1) }

        private var hyperlinkEntryCount: Int { u16(3) }
        private var identityEntryCount: Int { u16(5) }

        private var storesIdentityPerCell: Bool {
            flags & Header.identityPerCellBit != 0
        }

        var isSoftWrapped: Bool {
            get { flags & Header.softWrapBit != 0 }
            set {
                if newValue {
                    storage[0] |= Header.softWrapBit
                } else {
                    storage[0] &= ~Header.softWrapBit
                }
            }
        }

        var semanticPrompt: SemanticPromptRow {
            SemanticPromptRow(packedCode: (flags & Header.promptMask) >> Header.promptShift)
        }

        // MARK: - Section offsets

        private var cellColumnOffset: Int { Header.byteCount }

        private var hyperlinkOffset: Int {
            cellColumnOffset + storedCellCount * Header.cellBytes
        }

        private var identityOffset: Int {
            hyperlinkOffset + hyperlinkEntryCount * Header.hyperlinkEntryBytes
        }

        // MARK: - Reads

        /// Splits one cell word into the three fields it carries.
        ///
        /// Free-standing rather than a method so all four readers below decode a word the
        /// same way. They differ in *which* fields they then use, never in how the word is
        /// read -- which is what stops them drifting as the layout is tuned.
        private func decode(_ word: UInt64) -> (scalars: TerminalScalars, kind: TerminalCellKind, styleId: StyleId) {
            let kind = TerminalCellKind(
                packedCode: UInt8((word >> Header.cellKindShift) & Header.cellKindMask)
            )
            let styleId = StyleId(truncatingIfNeeded: word >> Header.cellStyleShift)
            let field = UInt32(word & Header.cellScalarMask)

            if word & Header.cellSpillBit != 0 {
                return (TerminalScalars(spills[Int(field)]), kind, styleId)
            }
            // A zero scalar field means "nothing was written here", the same convention the
            // unpacked row expresses as an empty `TerminalScalars`. NUL is not content.
            if field != 0, let scalar = Unicode.Scalar(field) {
                return (TerminalScalars(scalar), kind, styleId)
            }
            return (.empty, kind, styleId)
        }

        /// Reconstructs one column. One load for the cell, plus a bounded search of each
        /// side table -- see the `I5` note at the top of this file.
        ///
        /// Reads above `storedCellCount` return a default cell, which is what canonical
        /// trimming means: a column the row does not store is a column nobody wrote.
        func cell(at column: Int) -> GridCell {
            precondition(column >= 0)
            guard column < storedCellCount else { return GridCell() }

            let fields = decode(u64(cellColumnOffset + column * Header.cellBytes))
            var cell = GridCell()
            cell.scalars = fields.scalars
            cell.kind = fields.kind
            cell.styleId = fields.styleId

            if let entry = search(
                offset: hyperlinkOffset,
                count: hyperlinkEntryCount,
                width: Header.hyperlinkEntryBytes,
                for: column
            ) {
                cell.hyperlinkId = HyperlinkId(
                    UInt16(storage[entry + 2]) | (UInt16(storage[entry + 3]) << 8)
                )
            }

            cell.contentIdentity = contentIdentity(at: column)
            return cell
        }

        /// The identity stamped on `column`, or nil where nothing was printed.
        ///
        /// Two encodings, chosen per row by `pack(_:)`: a table of contiguous runs, or --
        /// when a row is fragmented enough that its run table would outgrow its cells --
        /// four bytes on every stored cell. `activationIdentity` reads this out of history,
        /// so neither form may lose a value (`I3`).
        private func contentIdentity(at column: Int) -> ContentIdentity? {
            let base = identityOffset
            if storesIdentityPerCell {
                let value = u32(base + column * Header.identityCellBytes)
                return value == 0 ? nil : value
            }
            var low = 0
            var high = identityEntryCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = base + mid * Header.identityRunEntryBytes
                let start = u16(entry)
                if column < start {
                    high = mid - 1
                    continue
                }
                let extent = u16(entry + 2)
                if column >= start + extent {
                    low = mid + 1
                    continue
                }
                return u32(entry + 4) &+ ContentIdentity(column - start)
            }
            return nil
        }

        /// Binary search a column-sorted fixed-width table, returning the entry's offset.
        private func search(offset: Int, count: Int, width: Int, for column: Int) -> Int? {
            var low = 0
            var high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = offset + mid * width
                let entryColumn = u16(entry)
                if entryColumn == column { return entry }
                if entryColumn < column {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return nil
        }

        /// Rebuilds the unpacked row. For the paths that inherently read every cell --
        /// width reflow, height transfer back into the live grid, whole-history text.
        func unpacked() -> GridRow {
            var cells = [GridCell]()
            cells.reserveCapacity(storedCellCount)
            forEachCell { cells.append($1) }

            var row = GridRow(cells: cells)
            row.isSoftWrapped = isSoftWrapped
            row.semanticPrompt = semanticPrompt
            return row
        }

        /// The linear walk, yielding each stored cell instead of collecting it. This is the
        /// shape every whole-row reader wants; `unpacked()` is just this plus an array.
        ///
        /// Split out because the render path reads every visible retained row once per frame
        /// and then discards it. Materializing first cost an allocation and a 32-byte
        /// `GridCell` write per stored cell -- work the pre-packing representation never did,
        /// since it could hand back its stored array by reference. `28/F17` measured that as
        /// the dominant term in the browsing regression, and the fix outlived the
        /// representation it was written for.
        ///
        /// Yields only columns the row *stores*: a content-sized row's padding tail is the
        /// caller's to synthesize, as it always was.
        func forEachCell(_ body: (_ column: Int, _ cell: GridCell) -> Void) {
            let stored = storedCellCount
            let cellBase = cellColumnOffset
            let linkBase = hyperlinkOffset
            let identityBase = identityOffset
            let perCellIdentity = storesIdentityPerCell

            var linkCursor = 0
            var identityCursor = 0

            for column in 0..<stored {
                let fields = decode(u64(cellBase + column * Header.cellBytes))
                var cell = GridCell()
                cell.scalars = fields.scalars
                cell.kind = fields.kind
                cell.styleId = fields.styleId

                if linkCursor < hyperlinkEntryCount {
                    let entry = linkBase + linkCursor * Header.hyperlinkEntryBytes
                    if u16(entry) == column {
                        cell.hyperlinkId = HyperlinkId(
                            UInt16(storage[entry + 2]) | (UInt16(storage[entry + 3]) << 8)
                        )
                        linkCursor += 1
                    }
                }

                if perCellIdentity {
                    let value = u32(identityBase + column * Header.identityCellBytes)
                    cell.contentIdentity = value == 0 ? nil : value
                } else {
                    while identityCursor < identityEntryCount {
                        let entry = identityBase + identityCursor * Header.identityRunEntryBytes
                        if column >= u16(entry) + u16(entry + 2) {
                            identityCursor += 1
                            continue
                        }
                        break
                    }
                    if identityCursor < identityEntryCount {
                        let entry = identityBase + identityCursor * Header.identityRunEntryBytes
                        let start = u16(entry)
                        if column >= start {
                            cell.contentIdentity = u32(entry + 4) &+ ContentIdentity(column - start)
                        }
                    }
                }

                body(column, cell)
            }
        }

        /// Walks the stored columns yielding only what the browsing render path draws:
        /// scalars and the interned style id.
        ///
        /// Exists because `forEachCell` also resolves a hyperlink id and a content identity
        /// for every cell, and the render walk discards both -- kind it takes from geometry,
        /// hyperlinks from `activatableLink(at:)`, and identity has no renderer at all.
        /// Skipping them drops two cursor advances and a `u32` read per cell from the
        /// hottest loop in frame planning.
        ///
        /// The cell column is read through an unsafe buffer here and nowhere else. It
        /// matters only in the one walk that runs per visible cell per frame, and the bounds
        /// it skips are ones the encoder established: `stored` is the count it wrote into
        /// the header, and it sized the column region at `stored * 8` bytes.
        func forEachContentCell(
            _ body: (_ column: Int, _ scalars: TerminalScalars, _ styleId: StyleId) -> Void
        ) {
            let stored = storedCellCount
            let cellBase = cellColumnOffset

            storage.withUnsafeBufferPointer { buffer in
                let bytes = buffer.baseAddress! + cellBase
                for column in 0..<stored {
                    var word: UInt64 = 0
                    let at = column * Header.cellBytes
                    for byte in 0..<8 {
                        word |= UInt64(bytes[at + byte]) << (8 * byte)
                    }

                    let styleId = StyleId(truncatingIfNeeded: word >> Header.cellStyleShift)
                    let field = UInt32(word & Header.cellScalarMask)

                    if word & Header.cellSpillBit != 0 {
                        body(column, TerminalScalars(spills[Int(field)]), styleId)
                    } else if field != 0, let scalar = Unicode.Scalar(field) {
                        body(column, TerminalScalars(scalar), styleId)
                    } else {
                        body(column, .empty, styleId)
                    }
                }
            }
        }

        /// Walks the stored columns yielding only each cell's kind.
        ///
        /// Exists because `Terminal.geometry` projects kinds and nothing else, and paying
        /// the full decode for them meant resolving a style, a hyperlink and a content
        /// identity per cell, plus retaining a `TerminalScalars` -- all discarded
        /// immediately. Under `C1` a kind is three bits of a word this reader already has to
        /// load, which is what keeps it allocation-free and ARC-free.
        func forEachKind(_ body: (_ column: Int, _ kind: TerminalCellKind) -> Void) {
            let stored = storedCellCount
            let cellBase = cellColumnOffset
            for column in 0..<stored {
                let word = u64(cellBase + column * Header.cellBytes)
                body(column, TerminalCellKind(
                    packedCode: UInt8((word >> Header.cellKindShift) & Header.cellKindMask)
                ))
            }
        }

        // MARK: - Packing

        /// Encodes an already-trimmed row. Called at scrollback admission, where canonical
        /// trimming already runs, so the caller owns `I2` and this owns only the encoding.
        ///
        /// Two passes and **one allocation**, which is what admission cost turned out to be
        /// about rather than how much classifying a row takes.
        ///
        /// Pass 1 collects only what the blob's size depends on -- the hyperlink entries,
        /// the `contentIdentity` runs, and the spills. Pass 2 writes every byte into a blob
        /// allocated at its exact final size, through one unsafe buffer, with no `append`
        /// anywhere. `28/F17` had measured `C6`'s encoder at 9.2% of feed self time and this
        /// design's whole claim on admission was that a translate-copy is cheaper than a
        /// classification pass -- but the first version of it measured **+6.19%** on
        /// `terminal-feed`, *worse* than `C6`, because it appended each cell byte by byte:
        /// eight `Array.append` calls per stored cell, each with a capacity and uniqueness
        /// check. Writing the same encoding into a pre-sized buffer took it to +2.05%, and
        /// removing the last intermediate array is the rest of it. **The cost was never the
        /// encoding; it was how the bytes got written.**
        static func pack(_ row: GridRow) -> PackedRetainedRow {
            let cells = row.cells
            let stored = cells.count

            var hyperlinkEntries: [(column: Int, id: HyperlinkId)] = []
            var identityRuns: [(start: Int, extent: Int, base: ContentIdentity)] = []
            var spills: [[Unicode.Scalar]] = []
            var previousIdentity: ContentIdentity?

            for (column, cell) in cells.enumerated() {
                if cell.scalars.count > 1 {
                    spills.append(Array(cell.scalars))
                }
                if let id = cell.hyperlinkId {
                    hyperlinkEntries.append((column, id))
                }
                if let identity = cell.contentIdentity {
                    // A run is a strict step of one, because that is the only shape a
                    // (base, start, extent) triple can reconstruct exactly. `printWide`
                    // stamps a head and its tail with a single identity, so a wide glyph
                    // opens a new run here -- which prices CJK-heavy rows above `D6`'s
                    // model, and is recorded as such rather than papered over.
                    if let last = previousIdentity,
                       identity == last &+ 1,
                       let open = identityRuns.last,
                       open.start + open.extent == column {
                        identityRuns[identityRuns.count - 1].extent += 1
                    } else {
                        identityRuns.append((column, 1, identity))
                    }
                    previousIdentity = identity
                } else {
                    previousIdentity = nil
                }
            }

            // The per-cell fallback, per `D6`: a row fragmented enough that its run table
            // costs more than four bytes on every stored cell writes the cells instead.
            let perCell = identityRuns.count * Header.identityRunEntryBytes
                > stored * Header.identityCellBytes
            let identityBytes = perCell
                ? stored * Header.identityCellBytes
                : identityRuns.count * Header.identityRunEntryBytes

            var flags: UInt8 = 0
            if row.isSoftWrapped { flags |= Header.softWrapBit }
            flags |= row.semanticPrompt.packedCode << Header.promptShift
            if perCell { flags |= Header.identityPerCellBit }

            let cellBase = Header.byteCount
            let linkBase = cellBase + stored * Header.cellBytes
            let identityBase = linkBase
                + hyperlinkEntries.count * Header.hyperlinkEntryBytes

            var blob = [UInt8](repeating: 0, count: identityBase + identityBytes)
            blob.withUnsafeMutableBufferPointer { bytes in
                func put16(_ at: Int, _ value: Int) {
                    bytes[at] = UInt8(truncatingIfNeeded: value)
                    bytes[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
                }
                func put32(_ at: Int, _ value: UInt32) {
                    for byte in 0..<4 {
                        bytes[at + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte))
                    }
                }

                bytes[0] = flags
                put16(1, stored)
                put16(3, hyperlinkEntries.count)
                put16(5, perCell ? stored : identityRuns.count)

                var spillIndex = 0
                for (column, cell) in cells.enumerated() {
                    var word = UInt64(cell.kind.packedCode) << Header.cellKindShift
                    word |= UInt64(cell.styleId) << Header.cellStyleShift
                    if cell.scalars.count == 1 {
                        word |= UInt64(cell.scalars[0].value)
                    } else if cell.scalars.count > 1 {
                        word |= Header.cellSpillBit | UInt64(spillIndex)
                        spillIndex += 1
                    }
                    let at = cellBase + column * Header.cellBytes
                    for byte in 0..<Header.cellBytes {
                        bytes[at + byte] = UInt8(truncatingIfNeeded: word >> (8 * byte))
                    }
                }

                for (index, entry) in hyperlinkEntries.enumerated() {
                    let at = linkBase + index * Header.hyperlinkEntryBytes
                    put16(at, entry.column)
                    put16(at + 2, Int(entry.id))
                }

                if perCell {
                    for run in identityRuns {
                        for offset in 0..<run.extent {
                            put32(
                                identityBase + (run.start + offset) * Header.identityCellBytes,
                                run.base &+ ContentIdentity(offset)
                            )
                        }
                    }
                } else {
                    for (index, run) in identityRuns.enumerated() {
                        let at = identityBase + index * Header.identityRunEntryBytes
                        put16(at, run.start)
                        put16(at + 2, run.extent)
                        put32(at + 4, run.base)
                    }
                }
            }

            return PackedRetainedRow(storage: blob, spills: spills)
        }

        // MARK: - Accounting

        /// Payload bytes this row's blob holds, header included. The quantity doc 28's
        /// pricing model predicts from public content, which is what `PO4` holds it against.
        var payloadByteCount: Int { storage.count }

        /// Scalars held outside the blob, so the budget can charge the spill allocations
        /// without decoding the row.
        var spillScalarCount: Int { spills.reduce(0) { $0 + $1.count } }

        var spillCount: Int { spills.count }
    }
}

// Little-endian appends, spelled out so the blob layout is readable at its call sites and
// so nothing here depends on `withUnsafeBytes` over a type whose layout Swift does not
// guarantee.
extension Array where Element == UInt8 {
    fileprivate mutating func appendUInt16(_ value: Int) {
        precondition(value >= 0 && value <= Int(UInt16.max))
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    fileprivate mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

extension TerminalCellKind {
    /// A stable one-byte encoding for the cell word's kind field. Written out rather than
    /// taken from a `RawRepresentable` conformance because the raw value would then be
    /// public API, and the blob's encoding is not something outside `TerminalCore` may
    /// depend on. Must stay within three bits -- see `Header`'s layout diagram.
    fileprivate var packedCode: UInt8 {
        switch self {
        case .padding: 0
        case .narrow: 1
        case .wideHead: 2
        case .wideTail: 3
        case .spacerHead: 4
        }
    }

    fileprivate init(packedCode: UInt8) {
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
    fileprivate var packedCode: UInt8 {
        switch self {
        case .none: 0
        case .prompt: 1
        case .continuation: 2
        case .output: 3
        case .vacated: 4
        }
    }

    fileprivate init(packedCode: UInt8) {
        switch packedCode {
        case 1: self = .prompt
        case 2: self = .continuation
        case 3: self = .output
        case 4: self = .vacated
        default: self = .none
        }
    }
}
