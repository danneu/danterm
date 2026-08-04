// The packed, immutable form a row takes once it leaves the live grid for history.
//
// This is doc 28's `C6`, selected by `D6`: a retained row is one byte blob holding a
// per-row fixed-stride scalar column, a run-length style table, three column-sorted
// exception tables, and a `contentIdentity` encoding -- plus the two row-level fields
// (`isSoftWrapped`, `semanticPrompt`) that no cell carries. It exists because doc 28's
// `F8` put 89.5% of saturated attributable footprint in stored cell bytes, and a
// retained cell was paying a 32-byte live-grid struct for content whose modal scalar
// fits in one byte.
//
// What belongs here: the encoding, the readers that decode it, and the byte accounting
// that prices it. What does not: anything about *when* a row is packed (that is
// admission, in Terminal.swift beside canonical trimming), and anything about the live
// grid, which `I1` closes -- `GridCell` is unchanged and this type never appears in it.
//
// Its own file because the encoding is a self-contained contract with a layout diagram,
// and burying 300 lines of byte offsets in a 6,000-line Terminal.swift would make the one
// thing a reader needs -- the layout -- the hardest thing to find.
//
// **The read contract is `I5`, and it is why this shape was chosen over a UTF-8 text
// form.** A random cell read is O(1) in the scalar column (fixed stride, so column ->
// offset is a multiply) plus O(log) binary searches over the column-ordered tables. It
// must never scan the row. A text form's scalar payload is variable-width, so reaching
// column N costs a decode of columns 0..<N -- which is what `retained-browse` would have
// paid. Keep every accessor below bounded that way; a linear fallback here silently
// gives up the reason this representation exists.

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

        /// Scalar payloads for multi-scalar cells, reached by index from the spill
        /// exception table. Held outside the blob because they are already separate
        /// allocations the budget charges, and inlining them would make the scalar column
        /// variable-width -- giving up `I5` for the rarest cell in the corpus.
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

        /// Byte offsets and field widths of the blob header, in one place.
        ///
        /// Everything after the header is a run of fixed-width entries, in this order:
        /// scalar column, style runs, kind exceptions, spill exceptions, hyperlink
        /// exceptions, identity table. Fixed width per table is what makes each one
        /// binary-searchable, which is `I5`.
        enum Header {
            /// flags(1) + storedCells(2) + styleRuns(2) + kindExceptions(2)
            /// + spillExceptions(2) + hyperlinkExceptions(2) + identityEntries(2)
            static let byteCount = 13

            static let styleRunEntryBytes = 6      // column(2) + styleId(4)
            static let kindEntryBytes = 3          // column(2) + kind(1)
            static let spillEntryBytes = 7         // column(2) + kind(1) + spillIndex(4)
            static let hyperlinkEntryBytes = 4     // column(2) + hyperlinkId(2)
            static let identityRunEntryBytes = 8   // start(2) + extent(2) + base(4)
            static let identityCellBytes = 4       // identity(4)

            static let softWrapBit: UInt8 = 0x01
            static let promptShift: UInt8 = 1
            static let promptMask: UInt8 = 0x0E
            static let strideShift: UInt8 = 4
            static let strideMask: UInt8 = 0x30
            static let identityPerCellBit: UInt8 = 0x40

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

        private var flags: UInt8 { storage[0] }

        /// Columns this row physically stores. Canonical trimming (`I2`) makes this a pure
        /// function of observable content, unchanged from the unpacked representation.
        var storedCellCount: Int { u16(1) }

        private var styleRunCount: Int { u16(3) }
        private var kindExceptionCount: Int { u16(5) }
        private var spillExceptionCount: Int { u16(7) }
        private var hyperlinkExceptionCount: Int { u16(9) }
        private var identityEntryCount: Int { u16(11) }

        /// Bytes per scalar slot, chosen per row from the widest single scalar it holds.
        var scalarStrideBytes: Int {
            switch (flags & Header.strideMask) >> Header.strideShift {
            case 0: 1
            case 1: 2
            default: 4
            }
        }

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

        private var scalarColumnOffset: Int { Header.byteCount }

        private var styleRunOffset: Int {
            scalarColumnOffset + storedCellCount * scalarStrideBytes
        }

        private var kindExceptionOffset: Int {
            styleRunOffset + styleRunCount * Header.styleRunEntryBytes
        }

        private var spillExceptionOffset: Int {
            kindExceptionOffset + kindExceptionCount * Header.kindEntryBytes
        }

        private var hyperlinkExceptionOffset: Int {
            spillExceptionOffset + spillExceptionCount * Header.spillEntryBytes
        }

        private var identityOffset: Int {
            hyperlinkExceptionOffset + hyperlinkExceptionCount * Header.hyperlinkEntryBytes
        }

        // MARK: - Reads

        /// Reconstructs one column. O(1) in the row's stored width plus O(log) in its run
        /// and exception counts -- see the `I5` note at the top of this file.
        ///
        /// Reads above `storedCellCount` return a default cell, which is what canonical
        /// trimming means: a column the row does not store is a column nobody wrote.
        func cell(at column: Int) -> GridCell {
            precondition(column >= 0)
            let stored = storedCellCount
            guard column < stored else { return GridCell() }

            var cell = GridCell()
            let stride = scalarStrideBytes
            let slotOffset = scalarColumnOffset + column * stride
            var slot: UInt32 = 0
            for byte in 0..<stride {
                slot |= UInt32(storage[slotOffset + byte]) << (8 * byte)
            }

            // Spill first: a multi-scalar cell parks a zero slot and holds its scalars
            // outside the blob, so the slot alone would read as never-written.
            if let entry = search(
                offset: spillExceptionOffset,
                count: spillExceptionCount,
                width: Header.spillEntryBytes,
                for: column
            ) {
                cell.scalars = TerminalScalars(spills[Int(u32(entry + 3))])
                cell.kind = TerminalCellKind(packedCode: storage[entry + 2])
            } else if slot != 0, let scalar = Unicode.Scalar(slot) {
                cell.scalars = TerminalScalars(scalar)
                cell.kind = .narrow
            }

            // A kind exception overrides the slot-derived kind. Wide geometry is the
            // designed case; a kind the slot cannot imply (a `.narrow` cell holding no
            // scalar) lands here too rather than being silently rewritten.
            if let entry = search(
                offset: kindExceptionOffset,
                count: kindExceptionCount,
                width: Header.kindEntryBytes,
                for: column
            ) {
                cell.kind = TerminalCellKind(packedCode: storage[entry + 2])
            }

            cell.styleId = styleId(at: column)

            if let entry = search(
                offset: hyperlinkExceptionOffset,
                count: hyperlinkExceptionCount,
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

        /// The interned style id covering `column`, from the run whose start is the
        /// greatest one not past it.
        private func styleId(at column: Int) -> StyleId {
            let runs = styleRunCount
            guard runs > 0 else { return Terminal.defaultStyleId }
            let base = styleRunOffset
            var low = 0
            var high = runs - 1
            var found = -1
            while low <= high {
                let mid = (low + high) / 2
                let entry = base + mid * Header.styleRunEntryBytes
                if u16(entry) <= column {
                    found = entry
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            guard found >= 0 else { return Terminal.defaultStyleId }
            return u32(found + 2)
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
            let runs = identityEntryCount
            var low = 0
            var high = runs - 1
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
        /// width reflow, height transfer back into the live grid, whole-history text --
        /// where paying one linear pass beats `storedCellCount` independent binary
        /// searches. A point query must use `cell(at:)`.
        ///
        /// Linear in the stored width, and deliberately so: it advances one cursor per
        /// table instead of re-searching, which is the second half of `I5`. A row with
        /// pathologically many style runs stays linear here rather than degrading to
        /// O(cells * log runs).
        func unpacked() -> GridRow {
            var cells = [GridCell]()
            cells.reserveCapacity(storedCellCount)
            forEachCell { cells.append($1) }

            var row = GridRow(cells: cells)
            row.isSoftWrapped = isSoftWrapped
            row.semanticPrompt = semanticPrompt
            return row
        }

        /// The linear cursor walk itself, yielding each stored cell instead of collecting
        /// it. This is the shape every whole-row reader wants; `unpacked()` is just this
        /// plus an array.
        ///
        /// Split out because the render path reads every visible retained row once per
        /// frame and then discards it. Materializing first cost an allocation and a
        /// 32-byte `GridCell` write per stored cell -- work the pre-packing representation
        /// never did, since it could hand back its stored array by reference. `28/F17`
        /// measured that as the dominant term in the browsing regression. Streaming keeps
        /// the same single decoder, so the two readers cannot drift.
        ///
        /// Yields only columns the row *stores*: a content-sized row's padding tail is the
        /// caller's to synthesize, as it always was.
        func forEachCell(_ body: (_ column: Int, _ cell: GridCell) -> Void) {
            let stored = storedCellCount
            let stride = scalarStrideBytes
            let scalarBase = scalarColumnOffset
            let styleBase = styleRunOffset
            let kindBase = kindExceptionOffset
            let spillBase = spillExceptionOffset
            let linkBase = hyperlinkExceptionOffset
            let identityBase = identityOffset
            let perCellIdentity = storesIdentityPerCell

            var styleCursor = 0
            var kindCursor = 0
            var spillCursor = 0
            var linkCursor = 0
            var identityCursor = 0
            var currentStyle = Terminal.defaultStyleId

            for column in 0..<stored {
                var cell = GridCell()

                var slot: UInt32 = 0
                let slotOffset = scalarBase + column * stride
                for byte in 0..<stride {
                    slot |= UInt32(storage[slotOffset + byte]) << (8 * byte)
                }

                if spillCursor < spillExceptionCount {
                    let entry = spillBase + spillCursor * Header.spillEntryBytes
                    if u16(entry) == column {
                        cell.scalars = TerminalScalars(spills[Int(u32(entry + 3))])
                        cell.kind = TerminalCellKind(packedCode: storage[entry + 2])
                        spillCursor += 1
                    }
                }
                if cell.scalars.isEmpty, slot != 0, let scalar = Unicode.Scalar(slot) {
                    cell.scalars = TerminalScalars(scalar)
                    cell.kind = .narrow
                }

                if kindCursor < kindExceptionCount {
                    let entry = kindBase + kindCursor * Header.kindEntryBytes
                    if u16(entry) == column {
                        cell.kind = TerminalCellKind(packedCode: storage[entry + 2])
                        kindCursor += 1
                    }
                }

                while styleCursor < styleRunCount {
                    let entry = styleBase + styleCursor * Header.styleRunEntryBytes
                    guard u16(entry) <= column else { break }
                    currentStyle = u32(entry + 2)
                    styleCursor += 1
                }
                cell.styleId = currentStyle

                if linkCursor < hyperlinkExceptionCount {
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
        /// Exists because `forEachCell` also resolves a hyperlink id and a content
        /// identity for every cell, and the render walk discards both -- kind it takes
        /// from geometry, hyperlinks from `activatableLink(at:)`, and identity has no
        /// renderer at all. Skipping them drops two cursor advances and a `u32` read per
        /// cell from the hottest loop in frame planning.
        ///
        /// This is the third walk over the same layout, and that repetition is the cost of
        /// each reader paying only for what it reads. What keeps them honest is
        /// `TerminalRetainedRowReadPathTests`, which asserts all three agree with the
        /// public row reader on content that exercises every exception table.
        func forEachContentCell(
            _ body: (_ column: Int, _ scalars: TerminalScalars, _ styleId: StyleId) -> Void
        ) {
            let stored = storedCellCount
            let stride = scalarStrideBytes
            let scalarBase = scalarColumnOffset
            let styleBase = styleRunOffset
            let spillBase = spillExceptionOffset

            var styleCursor = 0
            var spillCursor = 0
            var currentStyle = Terminal.defaultStyleId

            // The scalar column is read through an unsafe buffer, with the stride resolved
            // once outside the loop. Both matter only here, in the one walk that runs per
            // visible cell per frame: the generic `0..<stride` byte loop cannot be unrolled
            // when `stride` is a stored value, so every cell paid a loop plus a bounds
            // check per byte to reassemble what is, at the overwhelmingly common 1-byte
            // stride, a single load. The bounds this skips are ones the encoder already
            // established -- `stored` is the count it wrote into the header, and it sized
            // the column region at `stored * stride` bytes.
            storage.withUnsafeBufferPointer { buffer in
            let slots = buffer.baseAddress! + scalarBase

            for column in 0..<stored {
                var scalars = TerminalScalars.empty

                let at = column * stride
                var slot = UInt32(slots[at])
                if stride > 1 {
                    slot |= UInt32(slots[at + 1]) << 8
                    if stride > 2 {
                        slot |= UInt32(slots[at + 2]) << 16
                        slot |= UInt32(slots[at + 3]) << 24
                    }
                }

                if spillCursor < spillExceptionCount {
                    let entry = spillBase + spillCursor * Header.spillEntryBytes
                    if u16(entry) == column {
                        scalars = TerminalScalars(spills[Int(u32(entry + 3))])
                        spillCursor += 1
                    }
                }
                if scalars.isEmpty, slot != 0, let scalar = Unicode.Scalar(slot) {
                    scalars = TerminalScalars(scalar)
                }

                while styleCursor < styleRunCount {
                    let entry = styleBase + styleCursor * Header.styleRunEntryBytes
                    guard u16(entry) <= column else { break }
                    currentStyle = u32(entry + 2)
                    styleCursor += 1
                }

                body(column, scalars, currentStyle)
            }
            }
        }

        /// Walks the stored columns yielding only each cell's kind.
        ///
        /// Exists because `Terminal.geometry` projects kinds and nothing else, and paying
        /// the full decode for them meant resolving a style, a hyperlink, and a content
        /// identity per cell, plus retaining a `TerminalScalars` -- all discarded
        /// immediately. Kind depends on exactly three inputs: whether the column spills,
        /// whether its scalar slot is occupied, and whether a kind exception overrides
        /// both. This reads those and stops, which is what makes it allocation-free and
        /// ARC-free.
        ///
        /// Deliberately a second walk rather than a flag on `forEachCell`: the two have
        /// different costs, and a caller that wants kinds should not have to know that
        /// asking for them cheaply is possible.
        func forEachKind(_ body: (_ column: Int, _ kind: TerminalCellKind) -> Void) {
            let stored = storedCellCount
            let stride = scalarStrideBytes
            let scalarBase = scalarColumnOffset
            let kindBase = kindExceptionOffset
            let spillBase = spillExceptionOffset

            var kindCursor = 0
            var spillCursor = 0

            for column in 0..<stored {
                var kind = GridCell().kind

                var slot: UInt32 = 0
                let slotOffset = scalarBase + column * stride
                for byte in 0..<stride {
                    slot |= UInt32(storage[slotOffset + byte]) << (8 * byte)
                }

                // Same precedence `forEachCell` applies: spill, then an occupied slot,
                // then a kind exception overriding either.
                var spilled = false
                if spillCursor < spillExceptionCount {
                    let entry = spillBase + spillCursor * Header.spillEntryBytes
                    if u16(entry) == column {
                        kind = TerminalCellKind(packedCode: storage[entry + 2])
                        spillCursor += 1
                        spilled = true
                    }
                }
                if spilled == false, slot != 0, Unicode.Scalar(slot) != nil {
                    kind = .narrow
                }

                if kindCursor < kindExceptionCount {
                    let entry = kindBase + kindCursor * Header.kindEntryBytes
                    if u16(entry) == column {
                        kind = TerminalCellKind(packedCode: storage[entry + 2])
                        kindCursor += 1
                    }
                }

                body(column, kind)
            }
        }

        // MARK: - Packing

        /// Encodes an already-trimmed row. Called at scrollback admission, where canonical
        /// trimming already runs, so the caller owns `I2` and this owns only the encoding.
        static func pack(_ row: GridRow) -> PackedRetainedRow {
            let cells = row.cells
            let stored = cells.count

            // Stride tier from the widest *single-scalar* cell: a multi-scalar cell spills
            // whatever the tier is, so it must not promote the whole row's column.
            var widest: UInt32 = 0
            for cell in cells where cell.scalars.count == 1 {
                widest = max(widest, cell.scalars[0].value)
            }
            let strideBytes: Int
            let strideTier: UInt8
            switch widest {
            case ..<0x100: (strideBytes, strideTier) = (1, 0)
            case ..<0x1_0000: (strideBytes, strideTier) = (2, 1)
            default: (strideBytes, strideTier) = (4, 2)
            }

            var styleRuns: [(column: Int, styleId: StyleId)] = []
            var kindExceptions: [(column: Int, kind: TerminalCellKind)] = []
            var spillExceptions: [(column: Int, kind: TerminalCellKind, index: Int)] = []
            var hyperlinkExceptions: [(column: Int, id: HyperlinkId)] = []
            var identityRuns: [(start: Int, extent: Int, base: ContentIdentity)] = []
            var spills: [[Unicode.Scalar]] = []
            var scalarColumn = [UInt8](repeating: 0, count: stored * strideBytes)

            var previousStyle: StyleId?
            var previousIdentity: ContentIdentity?

            for (column, cell) in cells.enumerated() {
                if cell.scalars.count == 1 {
                    var value = cell.scalars[0].value
                    let offset = column * strideBytes
                    for byte in 0..<strideBytes {
                        scalarColumn[offset + byte] = UInt8(truncatingIfNeeded: value)
                        value >>= 8
                    }
                } else if cell.scalars.count > 1 {
                    spillExceptions.append((column, cell.kind, spills.count))
                    spills.append(Array(cell.scalars))
                }

                // A kind entry is owed whenever the cell's content cannot imply its kind.
                // The implication is: any cell carrying a scalar reads `.narrow`, a cell
                // carrying none reads `.padding`. Deliberately keyed on *content* rather
                // than on the slot, so a multi-scalar cell -- whose slot is zero because
                // its scalars spilled -- does not owe an entry for being ordinary. That is
                // what makes the kind table exactly the row's wide cells, which is the
                // quantity doc 28's pricing model predicts from public content.
                let impliedKind: TerminalCellKind = cell.scalars.isEmpty ? .padding : .narrow
                if cell.kind != impliedKind {
                    kindExceptions.append((column, cell.kind))
                }

                if previousStyle != cell.styleId {
                    styleRuns.append((column, cell.styleId))
                    previousStyle = cell.styleId
                }

                if let id = cell.hyperlinkId {
                    hyperlinkExceptions.append((column, id))
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

            var blob = [UInt8]()
            blob.reserveCapacity(
                Header.byteCount
                    + scalarColumn.count
                    + styleRuns.count * Header.styleRunEntryBytes
                    + kindExceptions.count * Header.kindEntryBytes
                    + spillExceptions.count * Header.spillEntryBytes
                    + hyperlinkExceptions.count * Header.hyperlinkEntryBytes
                    + (perCell
                        ? stored * Header.identityCellBytes
                        : identityRuns.count * Header.identityRunEntryBytes)
            )

            var flags: UInt8 = 0
            if row.isSoftWrapped { flags |= Header.softWrapBit }
            flags |= row.semanticPrompt.packedCode << Header.promptShift
            flags |= strideTier << Header.strideShift
            if perCell { flags |= Header.identityPerCellBit }

            blob.append(flags)
            blob.appendUInt16(stored)
            blob.appendUInt16(styleRuns.count)
            blob.appendUInt16(kindExceptions.count)
            blob.appendUInt16(spillExceptions.count)
            blob.appendUInt16(hyperlinkExceptions.count)
            blob.appendUInt16(perCell ? stored : identityRuns.count)
            blob.append(contentsOf: scalarColumn)

            for run in styleRuns {
                blob.appendUInt16(run.column)
                blob.appendUInt32(run.styleId)
            }
            for entry in kindExceptions {
                blob.appendUInt16(entry.column)
                blob.append(entry.kind.packedCode)
            }
            for entry in spillExceptions {
                blob.appendUInt16(entry.column)
                blob.append(entry.kind.packedCode)
                blob.appendUInt32(UInt32(entry.index))
            }
            for entry in hyperlinkExceptions {
                blob.appendUInt16(entry.column)
                blob.appendUInt16(Int(entry.id))
            }
            if perCell {
                var values = [ContentIdentity](repeating: 0, count: stored)
                for run in identityRuns {
                    for offset in 0..<run.extent {
                        values[run.start + offset] = run.base &+ ContentIdentity(offset)
                    }
                }
                for value in values { blob.appendUInt32(value) }
            } else {
                for run in identityRuns {
                    blob.appendUInt16(run.start)
                    blob.appendUInt16(run.extent)
                    blob.appendUInt32(run.base)
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
    /// A stable one-byte encoding for the exception tables. Written out rather than taken
    /// from a `RawRepresentable` conformance because the raw value would then be public
    /// API, and the blob's encoding is not something outside `TerminalCore` may depend on.
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
