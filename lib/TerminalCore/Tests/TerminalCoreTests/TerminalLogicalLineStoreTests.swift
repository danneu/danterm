// Behavioral proof suite for doc 31's logical-line record arena (`31/D2`, `31/D3`).
//
// What belongs here: the store's own contracts -- the charged-byte bound (`I2`/`PO3`), the
// five mutating operations (`I5`), the derived index's agreement with the arena (`I9`), the
// forced split and its rejoin (`I10`/`PO9`), ring cycling (`PO12`) and record-level fidelity
// for spills, hyperlinks, identity and semantic marks (`PO13`). What does not: anything about
// the terminal wiring the store to its readers, which is a later slice, and the fold's
// row-for-row reproduction of today's output, which is `TerminalLogicalLineFoldTests`.
//
// Every assertion is against the store's public behavior -- what it retains, what it charges,
// what it folds -- never against a byte offset or a header bit, so the record layout stays
// implementation discretion (`31/D2` "Scoped out of this decision").

import Testing

@testable import TerminalCore

@Suite("Logical-line record arena")
struct TerminalLogicalLineStoreTests {
    // MARK: - Fixtures

    /// A narrow content cell carrying one scalar, so a test row reads back distinguishably.
    private static func narrow(
        _ scalar: Unicode.Scalar,
        styleId: Terminal.StyleId = Terminal.defaultStyleId,
        hyperlinkId: Terminal.HyperlinkId? = nil,
        contentIdentity: Terminal.ContentIdentity? = nil
    ) -> Terminal.GridCell {
        Terminal.GridCell(
            scalars: TerminalScalars(scalar),
            kind: .narrow,
            styleId: styleId,
            hyperlinkId: hyperlinkId,
            contentIdentity: contentIdentity
        )
    }

    /// One display row of `width` narrow cells whose scalars step through a repeating
    /// alphabet, so a retained suffix can be identified by content alone.
    private static func filledRow(
        width: Int,
        seed: Int,
        softWrapped: Bool,
        semanticPrompt: Terminal.SemanticPromptRow = .none
    ) -> Terminal.GridRow {
        var row = Terminal.GridRow(cells: (0..<width).map { column in
            let value = UInt32(97 + (seed &+ column) % 26)
            return narrow(Unicode.Scalar(value)!)
        })
        row.isSoftWrapped = softWrapped
        row.semanticPrompt = semanticPrompt
        return row
    }

    /// A hard-ended row of `count` narrow cells padded out to `width`, which is the shape the
    /// live grid hands admission for a line that ends before the right margin.
    private static func shortRow(
        width: Int,
        count: Int,
        seed: Int,
        semanticPrompt: Terminal.SemanticPromptRow = .none
    ) -> Terminal.GridRow {
        var cells = (0..<count).map { column -> Terminal.GridCell in
            let value = UInt32(97 + (seed &+ column) % 26)
            return narrow(Unicode.Scalar(value)!)
        }
        cells.append(contentsOf: repeatElement(Terminal.GridCell(), count: width - count))
        var row = Terminal.GridRow(cells: cells)
        row.semanticPrompt = semanticPrompt
        return row
    }

    /// A hard-ended row whose columns past the content are blanks painted by a background
    /// erase -- what the live grid hands admission after `ESC[41m ... ESC[K`.
    private static func backgroundErasedRow(
        width: Int,
        count: Int,
        seed: Int,
        fillStyle: Terminal.StyleId
    ) -> Terminal.GridRow {
        var cells = (0..<count).map { column -> Terminal.GridCell in
            let value = UInt32(97 + (seed &+ column) % 26)
            return narrow(Unicode.Scalar(value)!, styleId: fillStyle)
        }
        cells.append(
            contentsOf: (0..<(width - count)).map { _ in
                Terminal.GridCell(scalars: .empty, kind: .padding, styleId: fillStyle)
            }
        )
        return Terminal.GridRow(cells: cells)
    }

    /// The scalars of every retained display row, in order, as the store folds them today.
    private static func foldedScalars(_ store: Terminal.LogicalLineStore) -> [[Unicode.Scalar?]] {
        (0..<store.grandDisplayRowTotal).map { index in
            store.displayRow(at: index)!.cells.map { $0.scalars.first }
        }
    }

    // MARK: - I9: the index agrees with the arena

    @Test("A zero-cell record folds to one display row at every width")
    func zeroCellRecordFoldsToOneDisplayRow() {
        // Intent: a blank logical line occupies exactly one display row however narrow the
        //   pane gets.
        // Why it exists: `31/DD15` stores a blank line as a *zero-cell* record, dropping the
        //   one-cell canonical floor `PackedRetainedRow.pack` applies. Without `31/I9`'s
        //   `max(1, ...)` floor in the fold, a blank history would fold to nothing and
        //   `31/D2` Decision 1's 1,048,576-records-to-rows reading would break.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for _ in 0..<5 {
            store.admit(Self.shortRow(width: 8, count: 0, seed: 0))
        }

        #expect(store.recordCount == 5)
        #expect(store.grandDisplayRowTotal == 5)
        for width in [2, 4, 8, 80] {
            _ = store.setWidth(width)
            #expect(store.grandDisplayRowTotal == 5)
            #expect(store.independentDisplayRowRecount() == 5)
        }
    }

    @Test("The grand total agrees with an independent recount after each of the six triggers")
    func grandTotalAgreesWithRecountAfterEveryTrigger() {
        // Intent: the derived index's grand display-row total matches a recount from the
        //   arena alone after a width change, an admission, a head eviction, a tail
        //   truncation, a forced split and a clear-all.
        // Why it exists: `31/AR4` names a stale index as the one new failure mode with no
        //   analogue today -- six invalidation points against an eagerly maintained truth --
        //   and this recount is the only thing that catches a missed one.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 16)

        func check(_ label: Comment) {
            #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount(), label)
        }

        for line in 0..<12 {
            store.admit(Self.filledRow(width: 16, seed: line, softWrapped: true))
            store.admit(Self.filledRow(width: 16, seed: line + 1, softWrapped: true))
            store.admit(Self.shortRow(width: 16, count: 5, seed: line + 2))
        }
        check("admission")

        for width in [16, 9, 40, 2] {
            _ = store.setWidth(width)
            check("width change to \(width)")
        }
        _ = store.setWidth(16)

        store.evictOneDisplayRow()
        check("head eviction")

        _ = store.truncateTail(displayRows: 2)
        check("tail truncation")

        store.admit(Self.filledRow(width: 16, seed: 3, softWrapped: true))
        store.forceSplitOpenRecord()
        check("forced split")

        store.removeAll()
        check("clear all")
        #expect(store.grandDisplayRowTotal == 0)
        #expect(store.recordCount == 0)
    }

    @Test("A blank history at a budget where the index ring must double keeps retaining rows")
    func blankHistoryAtTheIndexRingDoublingPointKeepsRetaining() {
        // Intent: feeding a degenerate blank-line history far past the depth at which the index
        //   ring would have to double leaves the store retaining rows, with its charge inside
        //   capacity -- at the budgets where that doubling is the term that binds.
        // Why it exists: `31/DD56`. A ring never shrinks, so a doubling taken while the charge
        //   was already near the capacity leaves metadata permanently over the bound, and
        //   eviction -- which drops records, not capacity -- can never get back under it: the
        //   pane retains nothing at all for the rest of its life. Whether that is reachable is a
        //   property of the *budget*, not of the design, which is why this sweeps rather than
        //   asserting one number. Measured with the charge-before-append guard removed, budget
        //   144,000 settles at 0 records with 135,320 charged against a 135,000 capacity, and
        //   288,000 at 0 with 270,568 against 270,000; the neighbours retain normally.
        // Scenario: a pane configured with a budget that happens to put a power-of-two ring
        //   capacity in the window where its doubling costs more than the arena can give back.
        let blank = Terminal.GridRow(cells: (0..<16).map { _ in Terminal.GridCell() })

        for budget in [136_000, 144_000, 152_000, 280_000, 288_000, 296_000] {
            var store = Terminal.LogicalLineStore(budgetBytes: budget, width: 16)
            for _ in 0..<60_000 {
                store.admit(blank)
            }

            #expect(store.recordCount > 4_000, "budget \(budget) retained nothing")
            #expect(store.grandDisplayRowTotal == store.recordCount)
            #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
            #expect(store.chargedBytes <= store.capacityBytes, "budget \(budget) is over capacity")
        }
    }

    @Test("Clearing all history adds the retained rows to the evicted count")
    func clearingAllHistoryAdvancesTheEvictedRowCount() {
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for line in 0..<4 {
            store.admit(Self.shortRow(width: 8, count: 3, seed: line))
        }
        let retained = store.grandDisplayRowTotal
        let evictedBefore = store.evictedRowCount

        store.removeAll()

        #expect(store.evictedRowCount == evictedBefore + retained)
    }

    // MARK: - I1: nothing width-dependent is stored

    @Test("A width change rewrites no retained bytes and evicts nothing")
    func widthChangeIsANoOpOnRetainedStorage() {
        // Intent: cycling the width down to the engine minimum and back leaves the arena's
        //   bytes and every retained logical line exactly as they were.
        // Why it exists: `31/I1` and `31/I3` are the design's whole premise -- a record's
        //   bytes are a function of content alone, so a narrow-then-widen cycle is
        //   unrepresentable as a loss rather than merely tested against.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 20)
        for line in 0..<10 {
            store.admit(Self.filledRow(width: 20, seed: line, softWrapped: true))
            store.admit(Self.shortRow(width: 20, count: 7, seed: line))
        }
        store.closeOpenRecord()

        let recordsBefore = (0..<store.recordCount).map { store.recordCells(at: $0)! }
        let bytesBefore = store.census.arenaBytesInUse
        let capacityBefore = store.census.capacityBytes

        for width in [2, 3, 5, 100, 20] {
            _ = store.setWidth(width)
        }

        #expect(store.recordCount == recordsBefore.count)
        #expect(store.census.arenaBytesInUse == bytesBefore)
        #expect(store.census.capacityBytes == capacityBefore)
        for index in recordsBefore.indices {
            #expect(store.recordCells(at: index)! == recordsBefore[index])
        }
    }

    // MARK: - PO3 / I2: the charged-byte bound

    @Test("Feeding past the budget leaves charged bytes at or under it, on content and on blanks")
    func chargedBytesStayUnderTheBudget() {
        // Intent: however much is fed, arena-in-use plus index plus side tables stays within
        //   the configured budget, and capacity never grows.
        // Why it exists: `31/I2` is the store's only bound, and `31/DD11`'s restatement of
        //   `15/F4`'s leak proof is exactly "bytes-in-use falls when records are evicted, and
        //   capacity does not grow" -- a charge that describes a model rather than an
        //   allocation was wrong by 2.2x once already.
        for blankHistory in [false, true] {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 24)
            let capacity = store.census.capacityBytes

            for line in 0..<4_000 {
                if blankHistory {
                    store.admit(Self.shortRow(width: 24, count: 0, seed: 0))
                } else {
                    store.admit(Self.filledRow(width: 24, seed: line, softWrapped: true))
                    store.admit(Self.shortRow(width: 24, count: 11, seed: line))
                }
                #expect(store.census.chargedBytes <= capacity)
                #expect(store.census.capacityBytes == capacity)
            }

            #expect(store.recordCount > 0)
            // The exact post-condition, not a bound: `removeAll` routes through
            // `resetToEmptyArena`, so a store that released all but one byte is a leak.
            #expect(store.census.arenaBytesInUse > 0)
            store.removeAll()
            #expect(store.census.arenaBytesInUse == 0)
            #expect(store.census.capacityBytes == capacity)
        }
    }

    @Test("The arena's capacity is allocated below the byte budget by the metadata reserve")
    func arenaCapacityIsHeldBelowTheBudget() {
        // Intent: the store reserves less than its budget for the arena, so the index and the
        //   side tables are resident inside the bound rather than on top of it, and the charge
        //   is tested against the arena's capacity rather than against the budget.
        // Why it exists: `31/F8` Observation 4 measured a cycled arena pane at 1.118x today's
        //   resident bytes for the same fed input, because the reservation is dirty from
        //   construction and the metadata sits on top of it. `31/D4`'s residency remedy is
        //   exactly this reserve, and without a test the two numbers can silently become one
        //   again -- which is the state `31/I2`'s original "the arena's capacity *is* that
        //   budget" describes.
        let budget = 1 << 16
        var store = Terminal.LogicalLineStore(budgetBytes: budget, width: 16)
        let reserve = Terminal.LogicalLineStore.metadataReserveBytes(forBudget: budget)

        #expect(reserve > 0)
        #expect(store.census.budgetBytes == budget)
        #expect(store.census.capacityBytes == budget - reserve)
        #expect(store.census.capacityBytes < store.census.budgetBytes)

        for line in 0..<4_000 {
            store.admit(Self.filledRow(width: 16, seed: line, softWrapped: true))
            store.admit(Self.shortRow(width: 16, count: 7, seed: line))
            #expect(store.census.chargedBytes <= store.census.capacityBytes)
        }
        #expect(store.recordCount > 0)
        #expect(store.census.capacityBytes == budget - reserve)
    }

    @Test("The spill table's own storage stays charged after the records that filled it are gone")
    func spillTableChargesWhatItAllocated() {
        // Intent: what the spill table charges follows what its dictionary allocated, not what
        //   its live entries weigh, so evicting every spill-bearing record leaves the retained
        //   bucket storage inside the charge.
        // Why it exists: `31/F8` Observation 4 found the census charging 1.931 MiB of side
        //   tables on `scrollback-mixed` against 4.375 MiB of resident excess, and named the gap
        //   as `spillsBySequence`'s own storage -- `15/F2`'s "a charge that describes a model
        //   rather than an allocation" recurring inside `31/I2`. A charge that falls back to
        //   zero the moment the entries go is that same error stated in the other direction.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 16)
        #expect(store.census.sideTableBytes == 0)

        for line in 0..<200 {
            var row = Self.filledRow(width: 16, seed: line, softWrapped: false)
            row.cells[0] = Terminal.GridCell(
                scalars: TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!]),
                kind: .narrow
            )
            store.admit(row)
        }
        let filled = store.census.sideTableBytes
        #expect(filled > 0)

        // Evict every spill-bearing record, leaving plain ones behind so the store is not
        // emptied -- the payloads are freed with their records, the table that held them is
        // not, and neither is its charge.
        for line in 0..<200 {
            store.admit(Self.filledRow(width: 16, seed: line, softWrapped: false))
        }
        for _ in 0..<200 { store.evictOneDisplayRow() }
        #expect(store.recordCount > 0)
        #expect(store.census.sideTableBytes > 0)
        #expect(store.census.sideTableBytes < filled)

        store.removeAll()
        #expect(store.census.sideTableBytes == 0)
    }

    @Test("The maintained charge agrees with a full recount after each of the six triggers")
    func maintainedChargeAgreesWithARecount() {
        // Intent: the O(1) charged total the write path tests against the capacity equals the
        //   census's from-scratch recount after every operation that can move it.
        // Why it exists: the charge is maintained incrementally for the same reason
        //   `grandDisplayRowTotal` is, and it inherits `31/AR4`'s failure mode -- a mutating
        //   operation that moves a metadata term without refreshing the total loosens `31/I2`'s
        //   bound silently. This is the recount that catches a missed refresh.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 16)

        func check(_ label: Comment) {
            #expect(store.chargedBytes == store.census.chargedBytes, label)
        }

        for line in 0..<12 {
            var row = Self.filledRow(width: 16, seed: line, softWrapped: true)
            row.cells[1].hyperlinkId = 7
            row.cells[2].contentIdentity = Terminal.ContentIdentity(line + 1)
            row.cells[3] = Terminal.GridCell(
                scalars: TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!]),
                kind: .narrow
            )
            store.admit(row)
            store.admit(Self.backgroundErasedRow(width: 16, count: 5, seed: line, fillStyle: 9))
            check("admission")
        }

        for width in [9, 40, 16] {
            _ = store.setWidth(width)
            check("width change to \(width)")
        }

        store.evictOneDisplayRow()
        check("head eviction")

        _ = store.truncateTail(displayRows: 2)
        check("tail truncation")

        store.admit(Self.filledRow(width: 16, seed: 3, softWrapped: true))
        store.forceSplitOpenRecord()
        check("forced split")

        store.reopenTailRecord()
        check("reopen")

        store.removeAll()
        check("clear all")
    }

    @Test("The census reports capacity and bytes-in-use as separate quantities")
    func censusSeparatesCapacityFromBytesInUse() {
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 16)
        #expect(store.census.capacityBytes > 0)
        #expect(store.census.arenaBytesInUse == 0)

        store.admit(Self.filledRow(width: 16, seed: 0, softWrapped: false))
        #expect(store.census.arenaBytesInUse > 0)
        #expect(store.census.arenaBytesInUse < store.census.capacityBytes)
        #expect(
            store.census.chargedBytes
                == store.census.arenaBytesInUse + store.census.indexBytes
                    + store.census.sideTableBytes
        )
    }

    // MARK: - I4 / PO5 (store half): head-granular eviction

    @Test("Eviction under a head record spanning many display rows drops one row per step")
    func evictionIsDisplayRowGranularAtTheHead() {
        // Intent: evicting under a single logical line that spans many display rows advances
        //   the retained history by exactly one display row per step.
        // Why it exists: `31/D2` Decision 2 took `31/DD2`'s recorded alternative precisely so
        //   that no anchor moves further per admitted row than it does today; a whole-record
        //   step would drop the entire line at once, which `31/F6` `HR5` found user-visible in
        //   four anchors and the scrollbar.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for chunk in 0..<10 {
            store.admit(Self.filledRow(width: 8, seed: chunk, softWrapped: true))
        }
        store.admit(Self.shortRow(width: 8, count: 4, seed: 99))

        #expect(store.recordCount == 1)
        let total = store.grandDisplayRowTotal
        #expect(total == 11)

        for step in 1...5 {
            #expect(evictOne(&store))
            #expect(store.grandDisplayRowTotal == total - step)
            #expect(store.evictedRowCount == step)
            #expect(store.independentDisplayRowRecount() == total - step)
        }
        #expect(store.recordCount == 1)
    }

    @Test("A trimmed head record reads as a mid-line continuation carrying no semantic mark")
    func trimmedHeadReadsAsAContinuation() {
        // Intent: after the head record's prefix is trimmed, its first display row reports a
        //   continuation and no prompt mark, and its remaining rows fold identically to the
        //   untrimmed record's tail.
        // Why it exists: `31/D2` Decision 5 and `31/DD13` chose this to *reproduce today's
        //   output* -- it is what `isHistoryHeadTruncated` described -- rather than the one
        //   bit cheaper alternative of folding the trimmed head as a fresh line start.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for chunk in 0..<4 {
            store.admit(
                Self.filledRow(
                    width: 8,
                    seed: chunk,
                    softWrapped: true,
                    semanticPrompt: chunk == 0 ? .prompt : .none
                )
            )
        }
        store.admit(Self.shortRow(width: 8, count: 3, seed: 4))

        let before = Self.foldedScalars(store)
        #expect(store.displayRow(at: 0)!.semanticPrompt == .prompt)

        #expect(evictOne(&store))

        #expect(store.recordSummary(at: 0)!.startsMidLine)
        #expect(store.displayRow(at: 0)!.semanticPrompt == .continuation)
        #expect(Self.foldedScalars(store) == Array(before.dropFirst()))
    }

    @Test("Trimming the head of a line with no prompt mark leaves no mark behind")
    func trimmedHeadOfAnUnmarkedLineCarriesNoMark() {
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for chunk in 0..<3 {
            store.admit(Self.filledRow(width: 8, seed: chunk, softWrapped: true))
        }
        store.admit(Self.shortRow(width: 8, count: 2, seed: 3))

        #expect(evictOne(&store))
        #expect(store.displayRow(at: 0)!.semanticPrompt == .none)
        #expect(store.recordSummary(at: 0)!.startsMidLine)
    }

    // MARK: - I10 / PO9: the forced split

    @Test("A logical line driven past the cap splits, and the pair rejoins by adjacency")
    func logicalLinePastTheCapSplits() {
        // Intent: a single logical line longer than the record cap becomes two adjacent
        //   records, the first carrying the forced-split marker and reading as soft-wrapped,
        //   and the two together hold every cell in order.
        // Why it exists: `31/I10` and `31/DD3` bound a record at 1/32 of the budget; `31/DD6`
        //   leaves no back-pointer, so a reader rejoining the pair has only adjacency and the
        //   marker to go on.
        let capacity = 1 << 16
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 32)
        let cap = Terminal.LogicalLineStore.forcedSplitCellCount(forCapacity: capacity)

        var admitted = 0
        while admitted < cap + 64 {
            store.admit(Self.filledRow(width: 32, seed: admitted, softWrapped: true))
            admitted += 32
        }

        #expect(store.recordCount == 2)
        let first = store.recordSummary(at: 0)!
        let second = store.recordSummary(at: 1)!
        #expect(first.isForcedSplit)
        #expect(first.cellCount == cap)
        #expect(second.isForcedSplit == false)
        #expect(second.isOpen)
        #expect(first.cellCount + second.cellCount == admitted)

        // The join reads as one logical line: the predecessor's last display row is
        // soft-wrapped, so a reader walking display rows never sees a line end there.
        let lastRowOfFirst = store.displayRow(at: first.displayRowCount - 1)!
        #expect(lastRowOfFirst.isSoftWrapped)
    }

    @Test("Evicting the first piece of a forced-split pair leaves the follower a continuation")
    func evictingASplitsFirstPieceStampsTheFollower() {
        // Intent: dropping the whole first record of a forced-split pair leaves the follower
        //   reading as a mid-line continuation with no semantic mark, not as a fresh line.
        // Why it exists: `31/D2` Decision 2 step 2 was amended by the external design review
        //   for exactly this -- dropping a `forcedSplit` record without stamping diverges from
        //   today's `isHistoryHeadTruncated = lastEvictedIsSoftWrapped`, which inherited
        //   condition 10 exists to prevent.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        store.admit(Self.filledRow(width: 8, seed: 0, softWrapped: true, semanticPrompt: .prompt))
        store.forceSplitOpenRecord()
        store.admit(Self.filledRow(width: 8, seed: 1, softWrapped: true))
        store.admit(Self.shortRow(width: 8, count: 4, seed: 2))

        #expect(store.recordCount == 2)
        #expect(store.recordSummary(at: 0)!.isForcedSplit)
        #expect(store.recordSummary(at: 1)!.startsMidLine == false)
        #expect(store.recordSummary(at: 1)!.semanticPrompt == .none)

        // The first piece is exactly one display row, so one step drops it whole.
        #expect(evictOne(&store))
        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)!.startsMidLine)
        #expect(store.displayRow(at: 0)!.semanticPrompt == .none)
    }

    @Test("A split logical line's semantic mark appears exactly once, on the piece that starts it")
    func splitLineCarriesItsMarkOnlyOnTheFirstPiece() {
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        store.admit(Self.filledRow(width: 8, seed: 0, softWrapped: true, semanticPrompt: .prompt))
        store.admit(Self.filledRow(width: 8, seed: 1, softWrapped: true))
        store.forceSplitOpenRecord()
        store.admit(Self.filledRow(width: 8, seed: 2, softWrapped: true))
        store.admit(Self.shortRow(width: 8, count: 3, seed: 3))

        #expect(store.recordSummary(at: 0)!.semanticPrompt == .prompt)
        #expect(store.recordSummary(at: 1)!.semanticPrompt == .none)
        #expect(store.displayRow(at: 0)!.semanticPrompt == .prompt)
        #expect(store.displayRow(at: 1)!.semanticPrompt == .continuation)
        #expect(store.displayRow(at: 2)!.semanticPrompt == .none)
    }

    // MARK: - `31/DD25` as amended: the trailing fill as a record attribute

    @Test("The trailing fill is charged as a side-table slot and released when its record goes")
    func trailingFillIsChargedAndReleased() {
        // Intent: records carrying a trailing fill charge more side-table bytes than records
        //   without one, the charged total stays inside the budget while fills are admitted,
        //   and clearing history releases the slots.
        // Why it exists: `31/D2` Decision 1 charges everything retained history allocates, and
        //   `31/DD11` restates `15/F4`'s leak proof as "bytes-in-use falls when records are
        //   evicted". A per-record style slot is a new allocation inside that bound, so it is
        //   only admissible if it is charged and released like the spill table beside it.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 24)
        #expect(store.census.sideTableBytes == 0)

        store.admit(Self.shortRow(width: 24, count: 6, seed: 0))
        let withoutFill = store.census.sideTableBytes

        store.admit(Self.backgroundErasedRow(width: 24, count: 6, seed: 1, fillStyle: 9))
        #expect(store.census.sideTableBytes > withoutFill)

        let capacity = store.census.capacityBytes
        for line in 0..<4_000 {
            store.admit(Self.backgroundErasedRow(width: 24, count: 11, seed: line, fillStyle: 9))
            #expect(store.census.chargedBytes <= capacity)
        }
        #expect(store.recordCount > 0)
        #expect(store.census.sideTableBytes > 0)

        store.removeAll()
        #expect(store.census.sideTableBytes == 0)
    }

    @Test("A head trim keeps the line's trailing fill, which belongs to its far end")
    func headTrimKeepsTheTrailingFill() {
        // Intent: trimming display rows off the front of a logical line leaves the fill on the
        //   record, so the line's last display row is still painted to the margin.
        // Why it exists: the fill is keyed to the line's *end* while a trim eats its *start*,
        //   and the two meet in the one record a trim rewrites (`31/D2` Decision 2 step 3). A
        //   trim that dropped the fill would repaint a still-visible line in the default colour.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for chunk in 0..<4 {
            store.admit(Self.filledRow(width: 8, seed: chunk, softWrapped: true))
        }
        store.admit(Self.backgroundErasedRow(width: 8, count: 3, seed: 4, fillStyle: 12))

        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == 12)

        #expect(evictOne(&store))

        #expect(store.recordSummary(at: 0)!.startsMidLine)
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == 12)
        let last = store.paintedDisplayRow(at: store.grandDisplayRowTotal - 1)!
        #expect(last.cells.count == 8)
        #expect(last.cell(at: 7).styleId == 12)
    }

    @Test("A forced split leaves the trailing fill on the last piece, and eviction keeps it there")
    func forcedSplitPutsTheTrailingFillOnTheLastPiece() {
        // Intent: a logical line driven past the record cap carries its trailing fill on the
        //   piece that holds the line's end, and evicting the first piece whole leaves the
        //   follower's fill intact.
        // Why it exists: the fill describes the paint after the line ends, so the *last* piece
        //   is its only coherent owner -- a fill on the first piece would paint a margin in the
        //   middle of a line. Ownership falls out of admission order (the split closes the piece
        //   before the closing row's cells are appended), and this pins it (`31/DD33`).
        let capacity = 1 << 16
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 32)
        let cap = Terminal.LogicalLineStore.forcedSplitCellCount(forCapacity: capacity)

        var admitted = 0
        while admitted + 32 <= cap {
            store.admit(Self.filledRow(width: 32, seed: admitted, softWrapped: true))
            admitted += 32
        }
        store.admit(Self.backgroundErasedRow(width: 32, count: 5, seed: 1, fillStyle: 21))

        #expect(store.recordCount == 2)
        #expect(store.recordSummary(at: 0)!.isForcedSplit)
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == nil)
        #expect(store.recordSummary(at: 1)!.trailingFillStyle == 21)

        // Drain the whole first piece one display row at a time; the follower keeps the fill.
        while store.recordCount > 1 {
            #expect(evictOne(&store))
        }
        #expect(store.recordSummary(at: 0)!.startsMidLine)
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == 21)
    }

    @Test("Reopening the tail record drops its trailing fill")
    func reopeningTheTailDropsItsTrailingFill() {
        // Intent: resuming a closed logical line clears the fill it carried.
        // Why it exists: a fill is the paint after a line's *end*, and a reopened line has no
        //   end -- its last display row is about to be extended by the next admission, which
        //   re-derives whatever tail finally closes it (`31/DD35`).
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        store.admit(Self.backgroundErasedRow(width: 8, count: 4, seed: 0, fillStyle: 15))
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == 15)

        store.reopenTailRecord()

        #expect(store.recordSummary(at: 0)!.isOpen)
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == nil)
        #expect(store.paintedDisplayRow(at: 0)!.cells.count == 4)
    }

    @Test("Truncating the tail hands the painted row back to the live grid")
    func truncatingTheTailHandsBackThePaintedRow() {
        // Intent: a `resizeHeight` grow that pulls a background-erased line out of history
        //   returns the row with its paint as cells.
        // Why it exists: the live grid has no fill attribute -- paint is cells there -- so the
        //   hand-back is exactly where the two representations meet. Returning the content walk
        //   would erase the line's background the moment the window grew, and re-admitting the
        //   painted row re-derives the same fill, which is what makes the round trip closed.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        store.admit(Self.shortRow(width: 8, count: 3, seed: 0))
        store.admit(Self.backgroundErasedRow(width: 8, count: 2, seed: 1, fillStyle: 18))

        let handedBack = store.truncateTail(displayRows: 1)

        #expect(handedBack.count == 1)
        #expect(handedBack[0].cells.count == 8)
        #expect(handedBack[0].cell(at: 7).styleId == 18)
        #expect(store.recordCount == 1)

        store.admit(handedBack[0])
        #expect(store.recordSummary(at: 1)!.trailingFillStyle == 18)
        #expect(store.recordSummary(at: 1)!.cellCount == 2)
    }

    // MARK: - PO12: cycling the ring

    @Test("Cycling variable-length records through several full wraps preserves the retained suffix")
    func cyclingTheRingPreservesTheRetainedSuffix() {
        // Intent: after the write cursor has wrapped the arena several times, with head trims
        //   interleaved, every reader returns exactly the expected retained suffix, cell for
        //   cell and in order.
        // Why it exists: `31/PO12` is the obligation the ring's wrap seam is built against --
        //   `31/DD14`'s pad for a closed record and `31/DD20`'s forced split for the open
        //   tail are both only correct if the retained suffix survives the seam untouched.
        let capacity = 1 << 15
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 12)

        // A shadow model of everything admitted, so "expected retained suffix" is derived
        // from the input rather than from the store's own arithmetic.
        var admittedLines: [[Unicode.Scalar]] = []

        var seed = 0
        for line in 0..<900 {
            let wrapped = line % 5
            var scalars: [Unicode.Scalar] = []
            for _ in 0..<wrapped {
                let row = Self.filledRow(width: 12, seed: seed, softWrapped: true)
                store.admit(row)
                scalars.append(contentsOf: row.cells.compactMap { $0.scalars.first })
                seed += 1
            }
            let tailCount = 1 + (line % 11)
            let last = Self.shortRow(width: 12, count: tailCount, seed: seed)
            store.admit(last)
            scalars.append(contentsOf: last.cells.prefix(tailCount).compactMap { $0.scalars.first })
            seed += 1
            admittedLines.append(scalars)

            if line % 7 == 0 {
                store.evictOneDisplayRow()
            }
            #expect(store.census.chargedBytes <= capacity)
        }

        // Read the store back as logical lines and match it against the tail of the shadow.
        let readBack = Self.readLogicalLines(store)
        #expect(readBack.count > 0)
        #expect(readBack.count <= admittedLines.count)
        let expected = Array(admittedLines.suffix(readBack.count))
        // The oldest retained line may be a trimmed suffix of its original; every line after
        // it must match whole.
        #expect(Array(readBack.dropFirst()) == Array(expected.dropFirst()))
        #expect(Self.isSuffix(readBack.first!, of: expected.first!))
    }

    @Test("An open tail that grows across the physical end forced-splits and keeps every cell")
    func openTailForcedSplitsAtThePhysicalEnd() {
        // Intent: an open record that reaches the arena's physical end is closed with the
        //   forced-split marker, the sub-row remainder is padded, and the continuation opens
        //   at offset 0 with no cell lost.
        // Why it exists: `31/DD20` was added by the external design review because `31/DD14`'s
        //   pad needs a record's length at placement time, which is false of the open tail;
        //   `31/PO12` already tested this shape and had no decision behind it until then.
        let capacity = 1 << 14
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 16)

        var expected: [Unicode.Scalar] = []
        var seed = 0
        var splits = 0
        for _ in 0..<400 {
            let row = Self.filledRow(width: 16, seed: seed, softWrapped: true)
            store.admit(row)
            expected.append(contentsOf: row.cells.compactMap { $0.scalars.first })
            seed += 1
            splits = max(splits, (0..<store.recordCount).count { store.recordSummary(at: $0)!.isForcedSplit })
            #expect(store.census.chargedBytes <= capacity)
        }

        #expect(splits >= 1, "the open tail must have crossed the physical end at least once")

        let lines = Self.readLogicalLines(store)
        // Every record is one piece of the same never-terminated logical line, so the rejoin
        // by adjacency yields exactly one line.
        #expect(lines.count == 1)
        #expect(Self.isSuffix(lines[0], of: expected))
    }

    @Test("An empty open record at the physical end is reopened at offset zero without a split")
    func emptyOpenRecordAtTheSeamNeedsNoSplit() {
        // Intent: when the record that meets the physical end holds no cells yet, no
        //   forced-split marker is set -- the pad covers the remainder and the record is
        //   simply (re)opened at offset 0.
        // Why it exists: `31/DD20` names this edge explicitly ("an empty open record needs no
        //   split") so it is not discovered later as a spurious split marker on a fresh line.
        let capacity = 1 << 13
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 16)

        // Hard-ended lines only: every record closes immediately, so the record that meets the
        // seam is always freshly opened and empty when the fit test runs.
        for line in 0..<600 {
            store.admit(Self.shortRow(width: 16, count: 9, seed: line))
            #expect(store.census.chargedBytes <= capacity)
        }

        let splitCount = (0..<store.recordCount).count { store.recordSummary(at: $0)!.isForcedSplit }
        #expect(splitCount == 0)
        #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
    }

    // MARK: - I5: the middle is immutable

    @Test("Admission, a head trim and a tail truncation leave every middle record untouched")
    func onlyTheHeadHeaderAndTheTailAreWritable() {
        // Intent: after an admission, a head trim and a tail truncation, every record that is
        //   neither the head nor the tail folds to exactly the cells it folded to before.
        // Why it exists: `31/I5` is what makes the arena's cost model honest -- if the middle
        //   were writable, no operation's cost would be bounded by the head and tail alone.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 12)
        for line in 0..<20 {
            store.admit(Self.filledRow(width: 12, seed: line, softWrapped: true))
            store.admit(Self.shortRow(width: 12, count: 5, seed: line))
        }

        let before = (0..<store.recordCount).map { store.recordCells(at: $0)! }
        // Everything but the first and last record: the head and the tail are the only two the
        // three operations below are allowed to touch.
        let middle = 1..<(before.count - 1)

        store.admit(Self.shortRow(width: 12, count: 4, seed: 99))
        store.evictOneDisplayRow()
        _ = store.truncateTail(displayRows: 1)

        for index in middle {
            #expect(store.recordCells(at: index)! == before[index], "record \(index)")
        }
    }

    // MARK: - PO13 / condition 9: record-level fidelity of the side tables

    @Test("Spills, hyperlink ids and content identity survive admission, a width change and a trim")
    func sideTablesSurviveEveryRecordOperation() {
        // Intent: a multi-scalar cluster, a hyperlink id and a content-identity run read back
        //   identically after the record is admitted, refolded at three widths and head-trimmed.
        // Why it exists: `31/D1` condition 9 left the spill, hyperlink and semantic-mark
        //   formats owed, and `31/D3` Decision 6 keyed identity by *cell offset in the logical
        //   line* rather than by column -- so a trim, which shifts the record's start, is
        //   exactly where a naive key would silently lose a value.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 6)

        var cells: [Terminal.GridCell] = []
        for column in 0..<6 {
            var cell = Self.narrow(Unicode.Scalar(UInt32(97 + column))!)
            cell.contentIdentity = Terminal.ContentIdentity(500 + column)
            if column == 2 {
                cell.scalars = TerminalScalars([Unicode.Scalar(0x1F600)!, Unicode.Scalar(0xFE0F)!])
            }
            if column == 4 {
                cell.hyperlinkId = 7
            }
            cells.append(cell)
        }
        var first = Terminal.GridRow(cells: cells)
        first.isSoftWrapped = true
        store.admit(first)
        store.admit(Self.shortRow(width: 6, count: 3, seed: 40))

        func assertSurvives(_ label: Comment, offsetBy trimmed: Int) {
            let record = store.recordCells(at: 0)!
            #expect(record.count == 9 - trimmed, label)
            for column in 0..<6 where column - trimmed >= 0 {
                let cell = record[column - trimmed]
                #expect(cell.contentIdentity == Terminal.ContentIdentity(500 + column), label)
                if column == 2 {
                    #expect(cell.scalars.count == 2, label)
                    #expect(cell.scalars.first == Unicode.Scalar(0x1F600), label)
                }
                #expect(cell.hyperlinkId == (column == 4 ? 7 : nil), label)
            }
        }

        assertSurvives("as admitted", offsetBy: 0)
        for width in [3, 12, 6] {
            _ = store.setWidth(width)
            assertSurvives("at width \(width)", offsetBy: 0)
        }

        _ = store.setWidth(6)
        #expect(evictOne(&store))
        assertSurvives("after a head trim", offsetBy: 6)
    }

    @Test("Equality separates histories that differ only in a side-table value")
    func equalitySeesEverySideTableValue() {
        // Intent: two stores fed the same rows compare equal, and stop comparing equal as soon
        //   as any one of a scalar, a style, a hyperlink id, a content identity or a
        //   multi-scalar spill payload differs -- including when the difference is in a table
        //   the arena holds beside the cells rather than in the cells themselves.
        // Why it exists: `31/F13` measured `LogicalLineStore.==` decoding every retained cell
        //   into a fresh array per record, so it now compares stored bytes instead. That is
        //   sound only because a record's bytes are a function of its content (`31/I1`), and
        //   this is what holds the two readings together: the side tables are exactly the part
        //   a byte comparison could get wrong by comparing the wrong region or skipping one.
        // Every variant keeps the record's *table shape* -- the same hyperlink entry count and
        // the same identity run count -- so a comparison that skipped the tables' bytes could
        // not fall back on the header word to catch it. That is what the mutation is about.
        func store(
            mutating change: (_ column: Int, _ cell: inout Terminal.GridCell) -> Void = { _, _ in }
        ) -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 6)
            var cells: [Terminal.GridCell] = []
            for column in 0..<6 {
                var cell = Self.narrow(Unicode.Scalar(UInt32(97 + column))!)
                cell.contentIdentity = Terminal.ContentIdentity(500 + column)
                if column == 2 {
                    cell.scalars = TerminalScalars([
                        Unicode.Scalar(0x1F600)!, Unicode.Scalar(0xFE0F)!,
                    ])
                }
                if column == 4 { cell.hyperlinkId = 7 }
                change(column, &cell)
                cells.append(cell)
            }
            var row = Terminal.GridRow(cells: cells)
            row.isSoftWrapped = true
            store.admit(row)
            store.admit(Self.shortRow(width: 6, count: 3, seed: 40))
            return store
        }

        #expect(store() == store())
        #expect(store() != store { column, cell in
            if column == 5 { cell.scalars = TerminalScalars("z" as Unicode.Scalar) }
        })
        #expect(store() != store { column, cell in
            if column == 5 { cell.styleId = 12 }
        })
        // The same one hyperlink entry, pointing at a different target.
        #expect(store() != store { column, cell in
            if column == 4 { cell.hyperlinkId = 9 }
        })
        // The same one identity run, rebased -- so the run count cannot give it away.
        #expect(store() != store { column, cell in
            cell.contentIdentity = Terminal.ContentIdentity(900 + column)
        })
        // The same one spill slot, holding different scalars.
        #expect(store() != store { column, cell in
            if column == 2 {
                cell.scalars = TerminalScalars([
                    Unicode.Scalar(0x1F601)!, Unicode.Scalar(0xFE0F)!,
                ])
            }
        })
    }

    @Test("A record fragmented enough to outgrow its identity run table still round-trips")
    func fragmentedIdentityFallsBackPerCellWithoutLoss() {
        // Intent: alternating identified and unidentified cells -- the shape whose run table
        //   costs more than four bytes per stored cell -- reads back every value.
        // Why it exists: `31/D3` Decision 6 keeps `PackedRetainedRow`'s two-encoding scheme,
        //   and `28/I3` requires that neither encoding lose a value, because
        //   `activationIdentity` reads this out of history.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 16)
        var cells: [Terminal.GridCell] = []
        for column in 0..<16 {
            var cell = Self.narrow(Unicode.Scalar(UInt32(97 + column % 26))!)
            if column % 2 == 0 {
                cell.contentIdentity = Terminal.ContentIdentity(1_000 + column * 13)
            }
            cells.append(cell)
        }
        var row = Terminal.GridRow(cells: cells)
        row.isSoftWrapped = false
        store.admit(row)

        let read = store.recordCells(at: 0)!
        #expect(read.count == 16)
        for column in 0..<16 {
            #expect(
                read[column].contentIdentity
                    == (column % 2 == 0 ? Terminal.ContentIdentity(1_000 + column * 13) : nil)
            )
        }
    }

    // MARK: - Operations 2 and 4

    @Test("Closing and reopening the tail record flips only the line's continuation reading")
    func closeAndReopenTheTailRecord() {
        // Intent: closing the open tail ends the logical line without touching a cell, and
        //   reopening it resumes the same record.
        // Why it exists: `31/D2` Decision 2's operation 2 is `severScrollbackWrapClaim` and
        //   `restoreWrapClaimBeforeCursor` under the new store; both must stay header-only so
        //   the "middle immutable" premise and the charge both hold.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        store.admit(Self.filledRow(width: 8, seed: 0, softWrapped: true))
        let cells = store.recordCells(at: 0)!
        #expect(store.displayRow(at: 0)!.isSoftWrapped)
        let bytes = store.census.arenaBytesInUse

        store.closeOpenRecord()
        #expect(store.displayRow(at: 0)!.isSoftWrapped == false)
        #expect(store.recordCells(at: 0)! == cells)
        #expect(store.census.arenaBytesInUse == bytes)

        store.reopenTailRecord()
        #expect(store.displayRow(at: 0)!.isSoftWrapped)
        #expect(store.recordCells(at: 0)! == cells)
        #expect(store.census.arenaBytesInUse == bytes)
    }

    @Test("Truncating the tail hands the last display rows back and leaves the totals consistent")
    func truncatingTheTailHandsRowsBack() {
        // Intent: a `resizeHeight` grow pulls the right display rows out of history, and the
        //   grand total, the recount and the charge all agree afterwards.
        // Why it exists: `31/D2` operation 4 is the only operation that shrinks the arena from
        //   the back, and `31/PO6` asks for exactly this consistency check.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for chunk in 0..<3 {
            store.admit(Self.filledRow(width: 8, seed: chunk, softWrapped: true))
        }
        store.admit(Self.shortRow(width: 8, count: 5, seed: 3))
        store.admit(Self.shortRow(width: 8, count: 6, seed: 9))

        let before = Self.foldedScalars(store)
        let total = store.grandDisplayRowTotal

        let handedBack = store.truncateTail(displayRows: 2)

        #expect(handedBack.count == 2)
        #expect(store.grandDisplayRowTotal == total - 2)
        #expect(store.independentDisplayRowRecount() == total - 2)
        #expect(Self.foldedScalars(store) == Array(before.dropLast(2)))
        #expect(handedBack.map { $0.cells.map(\.scalars.first) } == Array(before.suffix(2)))
    }

    @Test("Truncating away a record that is alone in its index block leaves every row addressable")
    func truncatingAcrossABlockBoundaryKeepsEveryRowAddressable() {
        // Intent: after a tail truncation retires the last index block, the block totals still
        //   sum to the grand total, so every remaining display row can still be located.
        // Why it exists: `removeLastDisplayRow` used to move the totals *after* dropping the
        //   record, so `retireEmptyTailBlocks` popped the block and the decrement then landed
        //   on the block before it -- one row subtracted twice from the index and once from the
        //   grand total. `31/I9` says the derived index agrees with the arena; the divergence
        //   does not self-heal, because later blocks seed their `rowStart` from the running sum.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        // One display row per record, so the record that is alone in the second index block is
        // also the only row `truncateTail` has to take to retire it.
        for line in 0..<(Terminal.LogicalLineStore.blockSize + 1) {
            store.admit(Self.shortRow(width: 8, count: 3, seed: line))
        }
        #expect(store.recordCount == Terminal.LogicalLineStore.blockSize + 1)

        _ = store.truncateTail(displayRows: 1)

        #expect(store.grandDisplayRowTotal == Terminal.LogicalLineStore.blockSize)
        #expect(store.independentDisplayRowRecount() == store.grandDisplayRowTotal)
        for index in 0..<store.grandDisplayRowTotal {
            #expect(store.displayRow(at: index) != nil, "row \(index) lost its index entry")
        }
    }

    @Test("Truncating into a forced-split record keeps its hyperlink and identity tables readable")
    func truncatingIntoAForcedSplitRecordKeepsItsSideTablesReadable() {
        // Intent: when truncation eats a forced split's continuation and then cuts into the
        //   split record itself, the cells that survive still read back their hyperlink ids and
        //   content identities.
        // Why it exists: a closed record's side tables are addressed off
        //   `offset + headerAndCells(cellCount)`, and `cutTail` rewrites `cellCount`.
        //   `reopenTailRecord` refuses a forced-split tail (it must -- its other caller resumes
        //   printing at a seam), so truncation used to shrink `cellCount` underneath tables that
        //   stayed where `flushOpenTables` put them, moving every later read into the cell words.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for chunk in 0..<3 {
            var row = Terminal.GridRow(cells: (0..<8).map { column in
                Self.narrow(
                    Unicode.Scalar(UInt32(97 + (chunk * 8 + column) % 26))!,
                    hyperlinkId: 7,
                    contentIdentity: Terminal.ContentIdentity(1_000 + chunk * 8 + column)
                )
            })
            row.isSoftWrapped = true
            store.admit(row)
        }
        store.forceSplitOpenRecord()
        // The continuation: two display rows, so truncating three eats it whole and then takes
        // one row out of the split record.
        store.admit(Self.filledRow(width: 8, seed: 40, softWrapped: true))
        store.admit(Self.shortRow(width: 8, count: 4, seed: 50))
        #expect(store.recordCount == 2)
        #expect(store.recordSummary(at: 0)!.isForcedSplit)
        #expect(store.grandDisplayRowTotal == 5)

        _ = store.truncateTail(displayRows: 3)

        #expect(store.recordCount == 1)
        let cells = store.recordCells(at: 0)!
        #expect(cells.count == 16)
        #expect(cells.allSatisfy { $0.hyperlinkId == 7 })
        #expect(
            cells.map(\.contentIdentity)
                == (0..<16).map { Terminal.ContentIdentity(1_000 + $0) }
        )
    }

    @Test("Tail truncation folds every handed-back row before cutting any of them")
    func truncatingTheTailHandsBackTheDerivedSpacers() {
        // Intent: a handed-back display row that ends in a derived `.spacerHead` still carries
        //   that cell, with the following wide head's style.
        // Why it exists: `truncateTail`'s fold-before-cut order is load-bearing -- a display
        //   row's trailing spacer is re-derived from the wide head that *follows* it (`31/I1`),
        //   so cutting one row at a time while folding drops exactly that column on a height
        //   grow. Every other `truncateTail` test feeds narrow ASCII, where no row can carry a
        //   derived spacer, so reversing the two loops stayed green.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 10)
        var cells: [Terminal.GridCell] = []
        for _ in 0..<5 {
            cells.append(
                Terminal.GridCell(
                    scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
                    kind: .wideHead,
                    styleId: 9
                )
            )
            cells.append(Terminal.GridCell(scalars: .empty, kind: .wideTail, styleId: 9))
        }
        store.admit(Terminal.GridRow(cells: cells))
        _ = store.setWidth(3)
        // Five 2-cell clusters at width 3: four rows of one cluster plus a spacer, then a last
        // row that holds the fifth cluster and defers nothing.
        #expect(store.grandDisplayRowTotal == 5)

        let handedBack = store.truncateTail(displayRows: 2)

        #expect(handedBack.count == 2)
        // The earlier of the two precedes a wide head that the later one starts with, so its
        // last column is a spacer the fold has to synthesize before the cut removes that head.
        #expect(handedBack[0].cell(at: 2).kind == .spacerHead)
        #expect(handedBack[0].cell(at: 2).styleId == 9)
        #expect(handedBack[1].cell(at: 0).kind == .wideHead)
        #expect(store.grandDisplayRowTotal == 3)
        #expect(store.independentDisplayRowRecount() == 3)
    }

    @Test("A width change pulls the open tail's partial display row back into the live refold")
    func widthChangePullsBackTheOpenTailsPartialRow() {
        // Intent: widening while a logical line straddles the history/live seam hands the
        //   open tail's sub-row remainder back, so no short display row is left inside that
        //   line.
        // Why it exists: `31/D3` Decision 4 and `31/DD16` -- today `reconstructLogicalLines`
        //   repacks the retained tail with the live rows so no such row exists; under this
        //   store history does not refold, so it would.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 10)
        for chunk in 0..<3 {
            store.admit(Self.filledRow(width: 10, seed: chunk, softWrapped: true))
        }
        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)!.isOpen)

        let pulled = store.setWidth(16)

        // 30 cells at width 16 is one whole display row plus a 14-cell remainder.
        #expect(pulled.count == 14)
        #expect(store.recordSummary(at: 0)!.cellCount == 16)
        #expect(store.grandDisplayRowTotal == 1)
        #expect(store.independentDisplayRowRecount() == 1)
    }

    @Test("A width change leaves a closed tail record alone")
    func widthChangeLeavesAClosedTailAlone() {
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 10)
        for chunk in 0..<3 {
            store.admit(Self.filledRow(width: 10, seed: chunk, softWrapped: true))
        }
        store.closeOpenRecord()

        let pulled = store.setWidth(16)

        #expect(pulled.isEmpty)
        #expect(store.recordSummary(at: 0)!.cellCount == 30)
    }

    // MARK: - Reader contract shape (`31/D3` Decision 1)

    @Test("A forward cursor walks the retained display rows with one locate")
    func forwardCursorWalksWithOneLocate() {
        // Intent: `locate` converts one display row into a record address, and `advance`
        //   carries it forward without another conversion.
        // Why it exists: `31/D3` Decision 1 rule 2 -- a planned frame performs at most one
        //   display-row-to-record locate -- is a contract the API shape has to make natural,
        //   because nothing in the type system stops a per-row lookup (`31/AR5`).
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for line in 0..<6 {
            store.admit(Self.filledRow(width: 8, seed: line, softWrapped: true))
            store.admit(Self.shortRow(width: 8, count: 3, seed: line))
        }

        var cursor = store.locate(displayRow: 2)
        var walked: [[Unicode.Scalar?]] = []
        while let position = cursor {
            walked.append(store.gridRow(at: position).cells.map { $0.scalars.first })
            cursor = store.advance(position)
        }

        #expect(walked == Array(Self.foldedScalars(store).dropFirst(2)))
        #expect(store.locate(displayRow: store.grandDisplayRowTotal) == nil)
        #expect(store.locate(displayRow: -1) == nil)
    }

    // MARK: - Chunked backing (`31/D5`)

    @Test("a published value and the next admission share every chunk but the one written")
    func publishedValueThenAdmitCopiesOneChunkNotTheWholeArena() {
        // Intent: after the store's value has been copied -- which is what publishing a frame
        //   does -- the next admission copies only the backing chunk it writes into, not the
        //   whole arena.
        // Why it exists: this is `31/D5`'s whole mechanism, observably. `31/F13` M1 measured the
        //   single-allocation arena being copied whole on every published frame (`memcpy` at
        //   12.1%-16.1% of whole-process CPU under `admit`), and a timing assertion would not
        //   say *why*; chunk storage identity says exactly which backing was copied and which
        //   was shared through.
        // Scenario: `TerminalPTYHost.drainedFrameState()` puts the `Terminal` value into a frame
        //   the pane session holds until the next publish, so every admitted row between two
        //   published frames writes into a non-uniquely-referenced arena.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)
        for seed in 0..<3_000 {
            store.admit(Self.filledRow(width: 80, seed: seed, softWrapped: false))
        }

        let published = store
        let before = published.chunkStorageIdentitiesForTesting()
        store.admit(Self.filledRow(width: 80, seed: 4_001, softWrapped: false))
        let after = store.chunkStorageIdentitiesForTesting()

        let copied = zip(before, after).reduce(into: 0) { $0 += $1.0 == $1.1 ? 0 : 1 }
        #expect(before.count > 1, "the production-shaped budget must have more than one chunk")
        #expect(copied >= 1, "the admission has to have written somewhere")
        #expect(
            copied * store.chunkCapacityBytesForTesting <= store.capacityBytes / 4,
            "one admission after a publish copied \(copied) of \(before.count) chunks"
        )
    }

    @Test("history cycles the ring across chunk seams and reads back exactly")
    func ringCyclesAcrossChunkSeamsAndKeepsItsRetainedSuffix() {
        // Intent: at a budget spanning several backing chunks, feeding many full cycles of the
        //   ring leaves every reader returning the retained suffix cell for cell, and the charge
        //   inside capacity throughout.
        // Why it exists: `31/PO12` states this for the arena's one physical seam; `31/D5` adds a
        //   seam per chunk boundary, which is where the open tail is force-split and a pad
        //   covers the remainder. This is that obligation at the new seam count.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)
        var admitted: [[Unicode.Scalar]] = []
        var seed = 0
        for line in 0..<3_000 {
            var scalars: [Unicode.Scalar] = []
            for _ in 0..<(line % 7) {
                let row = Self.filledRow(width: 80, seed: seed, softWrapped: true)
                scalars.append(contentsOf: row.cells.compactMap { $0.scalars.first })
                store.admit(row)
                seed += 1
            }
            let count = 1 + line % 79
            let last = Self.shortRow(width: 80, count: count, seed: seed)
            scalars.append(contentsOf: last.cells.prefix(count).compactMap { $0.scalars.first })
            store.admit(last)
            seed += 1
            admitted.append(scalars)
            #expect(store.census.chargedBytes <= store.capacityBytes)
        }

        let retained = Self.readLogicalLines(store)
        #expect(retained.isEmpty == false)
        #expect(store.independentDisplayRowRecount() == store.grandDisplayRowTotal)
        // The retained lines are a suffix of what was fed, with the oldest one possibly trimmed
        // at the head (`31/I4`) and every later one whole.
        let tail = Array(admitted.suffix(retained.count))
        #expect(retained.count > 1)
        #expect(Array(retained.dropFirst()) == Array(tail.dropFirst()))
        #expect(Self.isSuffix(retained[0], of: tail[0]))
    }

    // MARK: - Helpers

    /// Steps eviction outside `#expect`, whose macro expansion binds its operand immutably and
    /// so cannot call a mutating member.
    private func evictOne(_ store: inout Terminal.LogicalLineStore) -> Bool {
        store.evictOneDisplayRow()
    }

    /// Whether `candidate` is a trailing subsequence of `whole`.
    private static func isSuffix(_ candidate: [Unicode.Scalar], of whole: [Unicode.Scalar]) -> Bool {
        candidate.count <= whole.count && Array(whole.suffix(candidate.count)) == candidate
    }

    /// Reads the store back as logical lines, rejoining forced-split and mid-line records by
    /// adjacency exactly as `31/DD6` requires a reader to.
    private static func readLogicalLines(_ store: Terminal.LogicalLineStore) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        for index in 0..<store.recordCount {
            let summary = store.recordSummary(at: index)!
            let scalars = store.recordCells(at: index)!.compactMap { $0.scalars.first }
            if summary.startsMidLine, lines.isEmpty == false {
                lines[lines.count - 1].append(contentsOf: scalars)
            } else if index > 0, store.recordSummary(at: index - 1)!.isForcedSplit {
                lines[lines.count - 1].append(contentsOf: scalars)
            } else {
                lines.append(scalars)
            }
        }
        return lines
    }
}
