// Behavioral proof suite for doc 31's logical-line record arena (`research/31/D2`, `research/31/D3`).
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
// implementation discretion (`research/31/D2` "Scoped out of this decision").

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

    /// A full row whose cells carry one hyperlink and caller-supplied identities.
    private static func attributedRow(
        width: Int,
        seed: Int,
        softWrapped: Bool,
        hyperlinkId: Terminal.HyperlinkId = 7,
        identity: (Int) -> Terminal.ContentIdentity?
    ) -> Terminal.GridRow {
        var row = Terminal.GridRow(cells: (0..<width).map { column in
            let value = UInt32(97 + (seed &+ column) % 26)
            return narrow(
                Unicode.Scalar(value)!,
                hyperlinkId: hyperlinkId,
                contentIdentity: identity(column)
            )
        })
        row.isSoftWrapped = softWrapped
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
        // Why it exists: `research/31/DD15` stores a blank line as a *zero-cell* record, dropping the
        //   one-cell canonical floor a per-display-row store applies. Without `31/I9`'s
        //   `max(1, ...)` floor in the fold, a blank history would fold to nothing and
        //   `research/31/D2` Decision 1's 1,048,576-records-to-rows reading would break.
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

    @Test("Width changes rebuild every retained block after a partial head eviction")
    func widthChangeRebuildsBlocksAfterPartialHeadEviction() throws {
        // Intent: a width change rebuilds row totals and addresses from every retained record,
        //   including the partial first block and the final partial block.
        // Why it exists: the block-to-record mapping clamps both ends. Previous coverage changed
        //   width only while every retained record occupied one block with an untrimmed head.
        // Scenario: two blocks are retained, one record retires from the first block, and every
        //   reflowed row is checked against a record-by-record recount.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 8)
        for line in 0..<(Terminal.LogicalLineStore.blockSize + 2) {
            store.admit(Self.shortRow(width: 8, count: 7, seed: line))
        }
        #expect(store.recordCount == Terminal.LogicalLineStore.blockSize + 2)

        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        #expect(store.recordCount == Terminal.LogicalLineStore.blockSize + 1)

        _ = store.setWidth(3)

        var expectedAddresses: [Terminal.LogicalLineStore.DisplayRowCursor] = []
        for recordIndex in 0..<store.recordCount {
            let summary = try #require(store.recordSummary(at: recordIndex))
            for rowWithinRecord in 0..<summary.displayRowCount {
                expectedAddresses.append(
                    .init(recordIndex: recordIndex, rowWithinRecord: rowWithinRecord)
                )
            }
        }
        #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
        #expect(store.grandDisplayRowTotal == expectedAddresses.count)
        for (displayRow, expected) in expectedAddresses.enumerated() {
            #expect(store.locate(displayRow: displayRow) == expected)
        }
    }

    @Test("Display and content totals agree with independent recounts after every mutation")
    func maintainedTotalsAndContentRanksAgreeWithRecountsAfterEveryMutation() {
        // Intent: the row index and width-free content ranks match independent arena recounts
        //   after every mutation that can change record cells, boundaries, or ownership.
        // Why it exists: content ranks are incrementally maintained across more paths than the
        //   width-derived row index, so one missed delta can silently reorder nearest matches.
        // Scenario: a store admits, closes, reopens, splits, trims and drops at both ends,
        //   changes width, and clears while every cached total and retained coordinate is checked.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 16)

        func check(_ label: Comment) {
            #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount(), label)
            #expect(store.grandContentUnitTotal == store.independentContentUnitRecount(), label)
            #expect(
                store.contentBlockTotalsForTesting
                    == store.independentContentBlockTotalsForTesting,
                label
            )
            for recordIndex in 0..<store.closedRecordCount {
                guard let summary = store.recordSummary(at: recordIndex) else { continue }
                for offset in Set([0, summary.cellCount / 2, summary.cellCount]) {
                    guard let coordinate = store.recordTextPosition(
                        recordIndex: recordIndex,
                        cellOffset: offset
                    ) else { continue }
                    #expect(
                        store.contentRank(of: coordinate)
                            == store.independentContentRank(of: coordinate),
                        "\(label): record \(recordIndex), offset \(offset)"
                    )
                }
            }
        }

        for line in 0..<12 {
            store.admit(Self.filledRow(width: 16, seed: line, softWrapped: true))
            store.admit(Self.filledRow(width: 16, seed: line + 1, softWrapped: true))
            store.admit(Self.shortRow(width: 16, count: 5, seed: line + 2))
        }
        check("admission")

        store.admit(Self.filledRow(width: 16, seed: 100, softWrapped: true))
        check("open admission")
        store.closeOpenRecord()
        check("close")
        store.reopenTailRecord()
        check("reopen")
        store.forceSplitOpenRecord()
        check("forced split")
        store.admit(Self.shortRow(width: 16, count: 7, seed: 101))
        check("forced-split successor")

        let contentBeforeWidths = store.grandContentUnitTotal
        let blockContentBeforeWidths = store.contentBlockTotalsForTesting
        for width in [16, 9, 40, 2] {
            _ = store.setWidth(width)
            check("width change to \(width)")
            #expect(store.grandContentUnitTotal == contentBeforeWidths)
            #expect(store.contentBlockTotalsForTesting == blockContentBeforeWidths)
        }
        _ = store.setWidth(16)

        store.evictOneDisplayRow()
        check("head trim")

        let recordsBeforeWholeEviction = store.recordCount
        while store.recordCount == recordsBeforeWholeEviction {
            guard store.evictOneDisplayRow() else { break }
        }
        check("whole-record eviction")

        _ = store.truncateTail(displayRows: 1)
        check("tail record removal")

        _ = store.truncateTail(displayRows: 1)
        check("tail cut and reopen")

        store.admit(Self.filledRow(width: 16, seed: 3, softWrapped: true))
        store.forceSplitOpenRecord()
        check("second forced split")

        store.removeAll()
        check("clear all")
        #expect(store.grandDisplayRowTotal == 0)
        #expect(store.recordCount == 0)
    }

    @Test("Content ranks count projected cells and hard boundaries exactly")
    func contentRanksMatchSearchProjectionUnits() throws {
        // Intent: a narrow cell, wide pair and padding each advance rank once, while a forced
        //   split contributes no boundary and a hard-ended predecessor contributes one.
        // Why it exists: rank subtraction is sound only if its unit is exactly the unit the
        //   search scanner consumes; display columns would count the wide pair twice.
        // Scenario: mixed-width content crosses a forced split, then a hard record boundary.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        var mixed = Terminal.GridRow(cells: [
            Self.narrow("a"),
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Terminal.GridCell(kind: .padding),
        ])
        mixed.isSoftWrapped = true
        store.admit(mixed)
        store.forceSplitOpenRecord()
        store.admit(Self.shortRow(width: 4, count: 1, seed: 20))
        store.admit(Self.shortRow(width: 4, count: 1, seed: 21))

        let expectedMixedRanks = [0, 1, 2, 2, 3]
        for (offset, expected) in expectedMixedRanks.enumerated() {
            let coordinate = try #require(
                store.recordTextPosition(recordIndex: 0, cellOffset: offset)
            )
            #expect(store.contentRank(of: coordinate) == expected)
        }

        let forcedSplitSuccessor = try #require(
            store.recordTextPosition(recordIndex: 1, cellOffset: 0)
        )
        let hardBoundarySuccessor = try #require(
            store.recordTextPosition(recordIndex: 2, cellOffset: 0)
        )
        #expect(store.contentRank(of: forcedSplitSuccessor) == 3)
        #expect(store.contentRank(of: hardBoundarySuccessor) == 5)
        #expect(store.grandContentUnitTotal == 6)
    }

    /// A blank-line history fed until the store visibly stopped getting deeper, plus how many
    /// admissions that took.
    ///
    /// Separate from "the search ran out of admissions": an unsettled store is no evidence at
    /// all about the doubling, so the two cases must not be confused at the call site.
    private struct SettledBlankHistory {
        var store: Terminal.LogicalLineStore
        let admits: Int
    }

    /// Feeds blank rows until the store has evicted and then spent one whole ring block without
    /// reaching a new depth, or gives up after `admitLimit`.
    ///
    /// The two conditions are both load-bearing. Every blank admission opens a record, so depth
    /// climbs on literally every admission until the first eviction -- without the eviction test
    /// a stall in the count could only mean the store had not started yet. And the block ring's
    /// growth term is only tested when a record opens a new block (`indexGrowthBytes`), i.e.
    /// once per `blockSize` records, so a full block of post-eviction admissions is the shortest
    /// suffix that is guaranteed to put that arm of the doubling charge through the ceiling.
    /// "No new depth" rather than "no change in depth": at these budgets the count keeps
    /// oscillating by a row or two forever (budget 288,000 moves on every single admission out
    /// to 60,000), so a stability test on equality never fires, while the high-water mark stops
    /// moving at the first eviction.
    private static func settledBlankHistory(
        budgetBytes: Int,
        width: Int,
        admitLimit: Int
    ) -> SettledBlankHistory? {
        let blank = Terminal.GridRow(cells: (0..<width).map { _ in Terminal.GridCell() })
        var store = Terminal.LogicalLineStore(budgetBytes: budgetBytes, width: width)
        var deepestRecordCount = 0
        var admitsSinceNewDepth = 0

        for admit in 1...admitLimit {
            store.admit(blank)
            if store.recordCount > deepestRecordCount {
                deepestRecordCount = store.recordCount
                admitsSinceNewDepth = 0
            } else {
                admitsSinceNewDepth += 1
            }
            if store.evictedRowCount > 0,
               admitsSinceNewDepth >= Terminal.LogicalLineStore.blockSize
            {
                return SettledBlankHistory(store: store, admits: admit)
            }
        }
        return nil
    }

    @Test("A blank history at a budget where the index ring must double keeps retaining rows")
    func blankHistoryAtTheIndexRingDoublingPointKeepsRetaining() throws {
        // Intent: feeding a degenerate blank-line history until it settles at the depth where the
        //   index ring would have to double leaves the store retaining rows, with its charge
        //   inside capacity -- at the budgets where that doubling is the term that binds.
        // Why it exists: `research/31/DD56`. A ring never shrinks, so a doubling taken while the charge
        //   was already near the capacity leaves metadata permanently over the bound, and
        //   eviction -- which drops records, not capacity -- can never get back under it: the
        //   pane retains nothing at all for the rest of its life. Whether that is reachable is a
        //   property of the *budget*, not of the design, which is why this sweeps rather than
        //   asserting one number. Measured with the charge-before-append guard removed, budget
        //   144,000 settles at 0 records with 135,320 charged against a 135,000 capacity, and
        //   288,000 at 0 with 270,568 against 270,000; the neighbours retain normally.
        // Scenario: a pane configured with a budget that happens to put a power-of-two ring
        //   capacity in the window where its doubling costs more than the arena can give back.
        // Each budget's settled depth lands inside its own doubling window
        // (`capacity / 24.25 ..< capacity / 16.25`, `LogicalLineStore.indexGrowthBytes`), so the
        // 60,000 is a hard search limit rather than the stimulus: failing to settle within it is
        // a failure, not an assumed ceiling.
        for budget in [136_000, 144_000, 152_000, 280_000, 288_000, 296_000] {
            let settled = try #require(
                Self.settledBlankHistory(budgetBytes: budget, width: 16, admitLimit: 60_000),
                "budget \(budget) never settled within 60,000 admits"
            )
            let store = settled.store

            #expect(store.recordCount > 4_000, "budget \(budget) retained nothing")
            #expect(store.grandDisplayRowTotal == store.recordCount)
            #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
            #expect(store.chargedBytes <= store.capacityBytes, "budget \(budget) is over capacity")
        }
    }

    @Test("A history that never fills its budget is not a settled blank history")
    func unsaturatedBlankHistoryIsNotSettled() {
        // Intent: the settle detector reports nothing for a store that is still growing.
        // Why it exists: blank admissions leave the record count flat whenever an eviction
        //   happens to match an admission, so a detector keyed on "the count stopped moving"
        //   alone could stop before the index ring is anywhere near its doubling point and let
        //   `blankHistoryAtTheIndexRingDoublingPointKeepsRetaining` pass without ever charging
        //   for a doubling.
        // Scenario: a budget with room for far more blank rows than the search will admit.
        #expect(Self.settledBlankHistory(budgetBytes: 1 << 22, width: 16, admitLimit: 2_000) == nil)
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
        // Why it exists: `31/I2` is the store's only bound, and `research/31/DD11`'s restatement of
        //   `research/15/F4`'s leak proof is exactly "bytes-in-use falls when records are evicted, and
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

    @Test("The arena's capacity is reserved below the byte budget by the metadata reserve")
    func arenaCapacityIsHeldBelowTheBudget() {
        // Intent: the store reserves less than its budget for the arena, so the index and the
        //   side tables are resident inside the bound rather than on top of it, and the charge
        //   is tested against the arena's capacity rather than against the budget.
        // Why it exists: `research/31/F8` Observation 4 measured a cycled arena pane at 1.118x today's
        //   resident bytes for the same fed input, because the eager reservation was dirty from
        //   construction and the metadata sat on top of it. `research/31/D4`'s residency remedy is
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
        // Why it exists: `research/31/F8` Observation 4 found the census charging 1.931 MiB of side
        //   tables on `scrollback-mixed` against 4.375 MiB of resident excess, and named the gap
        //   as `spillsBySequence`'s own storage -- `research/15/F2`'s "a charge that describes a model
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

    @Test("A spill-and-fill history retains an exact depth at a budget the side tables decide")
    func sideTableChargeDecidesRetentionDepth() {
        // Intent: a history whose side tables carry a real share of the charge retains an exact
        //   number of display rows, and the oldest retained row holds exact content.
        // Why it exists: the charge tests around it prove the maintained total agrees with a
        //   recount and stays under capacity, which an implementation that consistently
        //   *over*charges a side table also satisfies -- while evicting history the store should
        //   have kept. Only a pinned depth catches that, so this fixture is what makes moving the
        //   side tables and their charge behind one owner a behavior-preserving change.
        // Scenario: spec-first. Every admitted row carries a multi-scalar spill and a trailing
        //   background-erase fill, so both sequence-keyed tables are populated on every record,
        //   at a budget small enough that their charge sets the eviction boundary.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 16)
        for line in 0..<400 {
            var row = Self.backgroundErasedRow(width: 16, count: 10, seed: line, fillStyle: 9)
            row.cells[0] = Terminal.GridCell(
                scalars: TerminalScalars([Unicode.Scalar(97 + UInt32(line % 26))!,
                                          Unicode.Scalar(0x0301)!]),
                kind: .narrow,
                styleId: 9
            )
            store.admit(row)
        }

        #expect(store.census.sideTableBytes > 0)
        #expect(store.chargedBytes <= store.capacityBytes)
        #expect(store.grandDisplayRowTotal == 242)
        #expect(store.evictedRowCount == 158)

        let oldest = store.displayRow(at: 0)
        #expect(oldest?.cells.first?.scalars.count == 2)
        #expect(oldest?.cells.first?.scalars.first == Unicode.Scalar(97 + UInt32(158 % 26))!)
    }

    // MARK: - I4 / PO5 (store half): head-granular eviction

    @Test("Eviction under a head record spanning many display rows drops one row per step")
    func evictionIsDisplayRowGranularAtTheHead() {
        // Intent: evicting under a single logical line that spans many display rows advances
        //   the retained history by exactly one display row per step.
        // Why it exists: `research/31/D2` Decision 2 took `research/31/DD2`'s recorded alternative precisely so
        //   that no anchor moves further per admitted row than it does today; a whole-record
        //   step would drop the entire line at once, which `research/31/F6` `HR5` found user-visible in
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
        // Why it exists: `research/31/D2` Decision 5 and `research/31/DD13` chose this to *reproduce today's
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
        // Why it exists: `31/I10` and `research/31/DD3` bound a record at 1/32 of the budget; `research/31/DD6`
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
        // Why it exists: `research/31/D2` Decision 2 step 2 was amended by the external design review
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

    // MARK: - The trailing fill as a record attribute

    @Test("Packed live-id walks equal painted-row materialization")
    func packedLiveIdsEqualPaintedRows() {
        // Intent: direct retained-arena walks report exactly the style and hyperlink ids that
        //   the existing painted-row projection reports.
        // Why it exists: reclamation may only stop materializing retained rows if it still sees
        //   stored cells, a derived spacer head, and a trailing-fill style. Missing any one can
        //   reclaim metadata that a retained row still needs.
        // Scenario: retained wrapped content carries two links and several styles, then ends in
        //   a short background-erased row whose fill exists only in the record side table.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 6)
        var wrapped = Self.filledRow(width: 6, seed: 0, softWrapped: true)
        wrapped.cells[0] = Self.narrow("a", styleId: 3, hyperlinkId: 11)
        wrapped.cells[5] = Terminal.GridCell(
            scalars: TerminalScalars("\u{1F600}"),
            kind: .wideHead,
            styleId: 5,
            hyperlinkId: 12
        )
        store.admit(wrapped)
        var ending = Self.backgroundErasedRow(width: 6, count: 2, seed: 1, fillStyle: 7)
        ending.cells[0] = Terminal.GridCell(kind: .wideTail, styleId: 5, hyperlinkId: 12)
        store.admit(ending)

        var materializedStyles = Set<Terminal.StyleId>()
        var materializedLinks = Set<Terminal.HyperlinkId>()
        for row in store.allPaintedDisplayRows() {
            for cell in row.cells {
                materializedStyles.insert(cell.styleId)
                if let id = cell.hyperlinkId { materializedLinks.insert(id) }
            }
        }

        var packedStyles = Set<Terminal.StyleId>()
        store.forEachStyleId { packedStyles.insert($0) }
        var packedLinks = Set<Terminal.HyperlinkId>()
        store.forEachHyperlinkId { packedLinks.insert($0) }

        #expect(packedStyles == materializedStyles)
        #expect(packedLinks == materializedLinks)
        #expect(packedStyles.contains(7))
        #expect(packedLinks == [11, 12])
        #expect(
            store.allPaintedDisplayRows().contains { row in
                row.cells.contains { $0.kind == .spacerHead && $0.styleId == 5 }
            }
        )

        // A head trim deliberately leaves the closed record's side table in place. The packed
        // walk must ignore the dead prefix entries even though their bytes remain in the arena.
        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        materializedLinks.removeAll(keepingCapacity: true)
        for row in store.allPaintedDisplayRows() {
            for cell in row.cells where cell.hyperlinkId != nil {
                materializedLinks.insert(cell.hyperlinkId!)
            }
        }
        packedLinks.removeAll(keepingCapacity: true)
        store.forEachHyperlinkId { packedLinks.insert($0) }
        #expect(packedLinks == materializedLinks)
        #expect(packedLinks == [12])
    }

    @Test("The trailing fill is charged as a side-table slot and released when its record goes")
    func trailingFillIsChargedAndReleased() {
        // Intent: records carrying a trailing fill charge more side-table bytes than records
        //   without one, the charged total stays inside the budget while fills are admitted,
        //   and clearing history releases the slots.
        // Why it exists: `research/31/D2` Decision 1 charges everything retained history allocates, and
        //   `research/31/DD11` restates `research/15/F4`'s leak proof as "bytes-in-use falls when records are
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
        //   and the two meet in the one record a trim rewrites (`research/31/D2` Decision 2 step 3). A
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
        //   before the closing row's cells are appended), and this pins the ordering.
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
        //   re-derives whatever tail finally closes it.
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
        //   `research/31/DD14`'s pad for a closed record and `research/31/DD20`'s forced split for the open
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
        // Why it exists: `research/31/DD20` was added by the external design review because `research/31/DD14`'s
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
        // Why it exists: `research/31/DD20` names this edge explicitly ("an empty open record needs no
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
        #expect(store.grandContentUnitTotal == store.independentContentUnitRecount())
        #expect(
            store.contentBlockTotalsForTesting == store.independentContentBlockTotalsForTesting
        )
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
        // Why it exists: `research/31/D1` condition 9 left the spill, hyperlink and semantic-mark
        //   formats owed, and `research/31/D3` Decision 6 keyed identity by *cell offset in the logical
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

    @Test("a head trim keeps the head record's identity and the text its coordinate names")
    func headTrimPreservesHeadRecordIdentity() throws {
        // Intent: trimming cells off the front of the head record leaves that record's identity
        //   alone, so a coordinate stored against it still names the same character.
        // Why it exists: the identity and the arena offset share one packed index word, and the
        //   trim rewrites that word. `position(of:)` binary-searches on the identity it reads
        //   back, so an identity the trim disturbed would resolve a stored search match onto the
        //   wrong text instead of failing outright.
        // Scenario: a six-cell closed record loses its first four-cell display row while a
        //   coordinate names the first cell of the retained suffix.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(Self.filledRow(width: 4, seed: 0, softWrapped: true))
        store.admit(Self.shortRow(width: 4, count: 2, seed: 4))
        let identity = try #require(store.recordIdentity(at: 0))
        let coordinate = try #require(store.recordTextPosition(recordIndex: 0, cellOffset: 4))
        let named = try #require(Self.scalar(in: store, at: coordinate))

        #expect(evictOne(&store))

        #expect(store.recordIdentity(at: 0) == identity)
        #expect(Self.scalar(in: store, at: coordinate) == named)
    }

    @Test("a record coordinate survives a head trim without moving")
    func recordCoordinateSurvivesHeadTrim() throws {
        // Intent: a coordinate names its original cell after eviction trims earlier cells from
        //   the same record.
        // Why it exists: rewriting surviving coordinates on every head trim would make eviction
        //   cost grow with the number of indexed search matches.
        // Scenario: a six-cell closed record loses its first four-cell display row while a
        //   coordinate continues to name the first cell of the retained suffix.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(Self.filledRow(width: 4, seed: 0, softWrapped: true))
        store.admit(Self.shortRow(width: 4, count: 2, seed: 4))
        let coordinate = try #require(
            store.recordTextPosition(recordIndex: 0, cellOffset: 4)
        )

        _ = store.setWidth(3)
        var resolved = try #require(store.position(of: coordinate))
        #expect(resolved.displayRow == 1)
        #expect(resolved.column == 1)
        _ = store.setWidth(4)

        #expect(evictOne(&store))

        resolved = try #require(store.position(of: coordinate))
        #expect(resolved.displayRow == 0)
        #expect(resolved.column == 0)
    }

    @Test("a retired record coordinate never resolves to newly admitted text")
    func recordCoordinateIsNotReusedAfterTailDrop() throws {
        // Intent: once tail truncation removes a record, its coordinate stays invalid even when
        //   the next admission occupies the same sequence position and arena bytes.
        // Why it exists: position-derived identity reused both today, which would let a stored
        //   search match silently retarget from removed text onto unrelated new text.
        // Scenario: one closed record is handed back, then a different closed record replaces it.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(Self.shortRow(width: 4, count: 1, seed: 0))
        let retired = try #require(
            store.recordTextPosition(recordIndex: 0, cellOffset: 0)
        )

        _ = store.truncateTail(displayRows: 1)
        store.admit(Self.shortRow(width: 4, count: 1, seed: 10))

        #expect(store.position(of: retired) == nil)
        #expect(store.recordIndexEntryBytesForTesting == MemoryLayout<Int>.stride)
    }

    @Test("record identity exhaustion retires history before restarting its ordinal")
    func recordIdentityExhaustionRetiresHistory() throws {
        // Intent: exhausting the bits packed beside an arena offset invalidates every old
        //   coordinate before any ordinal can repeat.
        // Why it exists: an untrusted output stream may run indefinitely, so the bounded
        //   identity representation needs a non-crashing retirement rule at its limit.
        // Scenario: a test primes the otherwise unreachable limit, then admits a replacement.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(Self.shortRow(width: 4, count: 1, seed: 0))
        let retired = try #require(
            store.recordTextPosition(recordIndex: 0, cellOffset: 0)
        )
        store.exhaustRecordIdentitySpaceForTesting()

        store.admit(Self.shortRow(width: 4, count: 1, seed: 10))

        #expect(store.recordCount == 1)
        #expect(store.position(of: retired) == nil)
    }

    @Test("a record coordinate costs one identity word and one offset")
    func recordCoordinateStaysTwoWords() {
        // Intent: naming a cell boundary in retained history costs two words, and the identity
        //   inside it costs one.
        // Why it exists: a search index stores two coordinates per occurrence, so a third word
        //   in this type is a 50% tax on every match a dense needle finds across all of history.
        //   A retirement generation kept beside each ordinal is exactly that third word, which is
        //   why it is composed into the identity instead.
        #expect(MemoryLayout<Terminal.LogicalLineStore.RecordIdentity>.stride == 8)
        #expect(MemoryLayout<Terminal.LogicalLineStore.RecordTextPosition>.stride == 16)
    }

    @Test("content ranks widen block metadata without widening record storage")
    func contentRanksUseOnlyBlockMetadata() {
        // Intent: content ranks add two words per 64-record block while every record keeps its
        //   existing one-word index entry.
        // Why it exists: a dense per-record prefix would reduce the blank-history depth that the
        //   store's budget contract prices explicitly.
        // Scenario: the storage-pricing seam reports both fixed strides directly.
        let store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        #expect(store.recordIndexEntryBytesForTesting == MemoryLayout<Int>.stride)
        #expect(
            Terminal.LogicalLineStore.blockMetadataBytesForTesting
                == 4 * MemoryLayout<Int>.stride
        )
    }

    @Test("Equality separates histories that differ only in a side-table value")
    func equalitySeesEverySideTableValue() {
        // Intent: two stores fed the same rows compare equal, and stop comparing equal as soon
        //   as any one of a scalar, a style, a hyperlink id, a content identity or a
        //   multi-scalar spill payload differs -- including when the difference is in a table
        //   the arena holds beside the cells rather than in the cells themselves.
        // Why it exists: `research/31/F13` measured `LogicalLineStore.==` decoding every retained cell
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
        // Why it exists: `research/31/D3` Decision 6 gives identity two encodings -- a run
        //   table and a per-cell table -- and both must preserve every stored value because
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

    @Test("Cells appended after an open-head trim keep their side-table values")
    func cellsAppendedAfterOpenHeadTrimKeepSideTableValues() throws {
        // Intent: side-table keys remain ordered and identify each retained cell after the sole
        //   open record loses one display row and then grows again.
        // Why it exists: open scratch entries used retained offsets after a head trim, while
        //   readers queried original offsets. New keys then collided with surviving entries.
        // Scenario: STORE-4 trims one of two soft-wrapped rows from the open head, appends a
        //   third row, and reads all retained cells through the open-record path.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        for row in 0..<2 {
            store.admit(Self.attributedRow(
                width: 4,
                seed: row * 4,
                softWrapped: true,
                identity: { Terminal.ContentIdentity(1_000 + row * 4 + $0) }
            ))
        }

        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        store.admit(Self.attributedRow(
            width: 4,
            seed: 8,
            softWrapped: true,
            identity: { Terminal.ContentIdentity(1_008 + $0) }
        ))

        let cells = try #require(store.recordCells(at: 0))
        #expect(cells.count == 8)
        #expect(cells.allSatisfy { $0.hyperlinkId == 7 })
        #expect(cells.map(\.contentIdentity) == (1_004..<1_012).map(Terminal.ContentIdentity.init))
    }

    @Test("Closing a trimmed open head keeps its side-table runs readable")
    func closingTrimmedOpenHeadKeepsSideTableRunsReadable() throws {
        // Intent: closing an open record after a head trim preserves every retained hyperlink
        //   and contiguous identity through the closed-record side-table reader.
        // Why it exists: fixing only the open scratch would leave the flush free to encode a
        //   retained-base key that the closed reader interprets as original-base.
        // Scenario: STORE-4 repeats the open-head trim, appends once while open, then admits a
        //   hard-ended row that closes the record with the identity-run encoding.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        for row in 0..<2 {
            store.admit(Self.attributedRow(
                width: 4,
                seed: row * 4,
                softWrapped: true,
                identity: { Terminal.ContentIdentity(1_000 + row * 4 + $0) }
            ))
        }
        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        for row in 2..<4 {
            store.admit(Self.attributedRow(
                width: 4,
                seed: row * 4,
                softWrapped: row == 2,
                identity: { Terminal.ContentIdentity(1_000 + row * 4 + $0) }
            ))
        }

        let cells = try #require(store.recordCells(at: 0))
        #expect(store.recordSummary(at: 0)?.isOpen == false)
        #expect(cells.allSatisfy { $0.hyperlinkId == 7 })
        #expect(cells.map(\.contentIdentity) == (1_004..<1_016).map(Terminal.ContentIdentity.init))
    }

    @Test("Per-cell identities survive closing and reopening a trimmed open head")
    func perCellIdentitiesSurviveClosingAndReopeningTrimmedOpenHead() throws {
        // Intent: the per-cell identity encoding uses the original span before and after a tail
        //   truncation reloads it into the open scratch.
        // Why it exists: the per-cell table is positional, so original-base run keys are not
        //   enough. Its encoded length, write bounds, and reload positions must share that base.
        // Scenario: STORE-4 alternates identity and nil, trims the sole open record, closes it,
        //   truncates its final row to reopen it, and admits that row again.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        func row(_ row: Int, softWrapped: Bool) -> Terminal.GridRow {
            Self.attributedRow(
                width: 4,
                seed: row * 4,
                softWrapped: softWrapped,
                identity: { column in
                    let offset = row * 4 + column
                    return offset.isMultiple(of: 2)
                        ? Terminal.ContentIdentity(2_000 + offset)
                        : nil
                }
            )
        }
        func expected(_ offsets: Range<Int>) -> [Terminal.ContentIdentity?] {
            offsets.map { offset in
                offset.isMultiple(of: 2) ? Terminal.ContentIdentity(2_000 + offset) : nil
            }
        }

        store.admit(row(0, softWrapped: true))
        store.admit(row(1, softWrapped: true))
        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        store.admit(row(2, softWrapped: false))

        var cells = try #require(store.recordCells(at: 0))
        #expect(store.recordSummary(at: 0)?.isOpen == false)
        #expect(cells.allSatisfy { $0.hyperlinkId == 7 })
        #expect(cells.map(\.contentIdentity) == expected(4..<12))

        let handedBack = store.truncateTail(displayRows: 1)
        let rowToReadmit = try #require(handedBack.first)
        store.admit(rowToReadmit)

        cells = try #require(store.recordCells(at: 0))
        #expect(cells.allSatisfy { $0.hyperlinkId == 7 })
        #expect(cells.map(\.contentIdentity) == expected(4..<12))
    }

    @Test("A trimmed per-cell table is reserved before a region seam closes it")
    func trimmedPerCellTableIsReservedBeforeRegionSeamClosesIt() throws {
        // Intent: seam placement reserves the original-sized per-cell table before it closes a
        //   trimmed open head, and the record after the seam remains intact.
        // Why it exists: once flush writes the original span, pricing only retained cells can
        //   admit one row too many and leave too little room for the forced-split tables.
        // Scenario: STORE-4 positions a sole open record 328 bytes before a 64 KiB chunk end,
        //   trims its first row, and grows fragmented identities until the fifth row must start
        //   the forced-split successor.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 4)
        for seed in 0..<1_630 {
            store.admit(Self.shortRow(width: 4, count: 4, seed: seed))
        }
        store.admit(Self.shortRow(width: 4, count: 0, seed: 0))

        func attributed(_ row: Int, softWrapped: Bool) -> Terminal.GridRow {
            Self.attributedRow(
                width: 4,
                seed: row * 4,
                softWrapped: softWrapped,
                identity: { column in
                    let offset = row * 4 + column
                    return offset.isMultiple(of: 2)
                        ? Terminal.ContentIdentity(3_000 + offset)
                        : nil
                }
            )
        }
        func expected(_ offsets: Range<Int>) -> [Terminal.ContentIdentity?] {
            offsets.map { offset in
                offset.isMultiple(of: 2) ? Terminal.ContentIdentity(3_000 + offset) : nil
            }
        }

        store.admit(attributed(0, softWrapped: true))
        store.admit(attributed(1, softWrapped: true))
        for _ in 0..<1_631 {
            let evicted = store.evictOneDisplayRow()
            #expect(evicted)
        }
        #expect(store.recordCount == 1)
        let trimmed = store.evictOneDisplayRow()
        #expect(trimmed)

        store.admit(attributed(2, softWrapped: true))
        store.admit(attributed(3, softWrapped: true))
        store.admit(attributed(4, softWrapped: true))

        #expect(store.recordCount == 2)
        #expect(store.recordSummary(at: 0)?.isForcedSplit == true)
        var first = try #require(store.recordCells(at: 0))
        #expect(first.allSatisfy { $0.hyperlinkId == 7 })
        #expect(first.map(\.contentIdentity) == expected(4..<16))

        store.admit(attributed(5, softWrapped: false))
        store.admit(Self.shortRow(width: 4, count: 3, seed: 90))

        first = try #require(store.recordCells(at: 0))
        let successor = try #require(store.recordCells(at: 1))
        let following = try #require(store.recordCells(at: 2))
        #expect(first.map(\.contentIdentity) == expected(4..<16))
        #expect(successor.allSatisfy { $0.hyperlinkId == 7 })
        #expect(successor.map(\.contentIdentity) == expected(16..<24))
        #expect(following.count == 3)
    }

    @Test("A wide cell's two columns share one identity and both read it back")
    func wideCellIdentityRepeatSurvivesTheRunEncoding() {
        // Intent: a wide head and its tail carry the same identity inside an otherwise
        //   ascending row, and every column -- the pair included -- reads its value back.
        // Why it exists: the run encoding stores (start, extent, base) and reconstructs a
        //   run as base + step, so it holds only a strict step of one. A wide pair repeats a
        //   value instead of stepping, which is the one shape a run cannot express, so the
        //   writer has to break the run there. A writer that folded the repeat into the open
        //   run would hand back base + 1 on the tail -- a neighbouring cell's identity, which
        //   `activationIdentity` would then read as part of the wrong span.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 6)
        let cells: [Terminal.GridCell] = [
            Self.narrow("a", contentIdentity: 500),
            Self.narrow("b", contentIdentity: 501),
            Terminal.GridCell(
                scalars: TerminalScalars("界"),
                kind: .wideHead,
                contentIdentity: 502
            ),
            Terminal.GridCell(kind: .wideTail, contentIdentity: 502),
            Self.narrow("c", contentIdentity: 503),
            Self.narrow("d", contentIdentity: 504),
        ]
        var row = Terminal.GridRow(cells: cells)
        row.isSoftWrapped = false
        store.admit(row)

        let read = store.recordCells(at: 0)!
        #expect(read.map(\.contentIdentity) == [500, 501, 502, 502, 503, 504])
    }

    // MARK: - Operations 2 and 4

    @Test("Closing and reopening the tail record flips only the line's continuation reading")
    func closeAndReopenTheTailRecord() {
        // Intent: closing the open tail ends the logical line without touching a cell, and
        //   reopening it resumes the same record.
        // Why it exists: `research/31/D2` Decision 2's operation 2 is `severScrollbackWrapClaim` and
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
        // Why it exists: `research/31/D2` operation 4 is the only operation that shrinks the arena from
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
            let cells: [Terminal.GridCell] = (0..<8).map { (column: Int) -> Terminal.GridCell in
                let index: Int = chunk * 8 + column
                let scalarValue: UInt32 = UInt32(97 + index % 26)
                let identity: Terminal.ContentIdentity = Terminal.ContentIdentity(1_000 + index)
                return Self.narrow(
                    Unicode.Scalar(scalarValue)!,
                    hyperlinkId: 7,
                    contentIdentity: identity
                )
            }
            var row = Terminal.GridRow(cells: cells)
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
        #expect(cells.allSatisfy { (cell: Terminal.GridCell) -> Bool in cell.hyperlinkId == 7 })
        let identities: [Terminal.ContentIdentity?] = cells.map(\.contentIdentity)
        let expectedIdentities: [Terminal.ContentIdentity?] = (0..<16).map {
            (offset: Int) -> Terminal.ContentIdentity? in
            Terminal.ContentIdentity(1_000 + offset)
        }
        #expect(identities == expectedIdentities)
    }

    // MARK: - A tail truncation across a wrap seam gives the pad's bytes back

    /// Runs `cycles` truncate-and-readmit rounds of `displayRows` rows each, handing every
    /// truncated row straight back.
    ///
    /// One round is a no-op on a store that charges what it holds: the rows leave and the same
    /// rows return, so the arena ends where it started. Repeating it is what turns a per-round
    /// leak into a charge big enough to move the eviction boundary.
    private static func truncateAndReadmit(
        _ store: inout Terminal.LogicalLineStore,
        displayRows: Int,
        cycles: Int
    ) {
        for _ in 0..<cycles {
            let handedBack = store.truncateTail(displayRows: displayRows)
            for row in handedBack { store.admit(row) }
        }
    }

    @Test("Dropping the tail record across a seam pad gives the pad's bytes back")
    func droppingTheTailAcrossASeamPadReclaimsIt() {
        // Intent: a truncation that rewinds the write cursor past a wrap seam's pad reclaims
        //   the pad, so a store that truncates and readmits the same rows retains exactly what
        //   a store that never truncated retains.
        // Why it exists: the arena charge used to be a maintained field, and `dropTailRecord`
        //   subtracted only the dropped record's own bytes. When that record was the one
        //   *before* a pad, the pad the rewind skipped stayed charged forever, and the next
        //   wrap charged a fresh pad over the same region -- so resize and reflow, which both
        //   truncate the tail, made history charge more than it held and evict early.
        // Scenario: hard-ended eight-cell lines at width 16 in a budget the arena wraps inside,
        //   truncated two display rows at a time with the rows handed straight back.
        //
        // The line count places the tail one record past the wrap seam, so removing two display
        // rows drops the record after the pad and then the record before it -- the rewind that
        // skips the pad. The 40 rounds are what push the leaked pads past an eviction boundary:
        // one round's over-charge is smaller than one record and changes nothing observable.
        let budget = 1 << 14
        let cellsPerLine = 8
        var control = Terminal.LogicalLineStore(budgetBytes: budget, width: 16)
        for line in 0..<213 {
            control.admit(Self.shortRow(width: 16, count: cellsPerLine, seed: line))
        }

        // The ring has wrapped here, so this pins the charge on the wrapped branch, which no
        // other exact-byte test reaches: every retained record costs an 8-byte header plus
        // eight 8-byte cells, and the one seam pad this fixture's geometry leaves is 96 bytes.
        let recordBytes = 8 + cellsPerLine * 8
        let seamPadBytes = 96
        #expect(
            control.census.arenaBytesInUse == recordBytes * control.recordCount + seamPadBytes
        )

        // A value type, so this is the same store rather than a rebuilt one: the two copies
        // share their physical placement exactly, which is what makes their charges comparable.
        var subject = control
        Self.truncateAndReadmit(&subject, displayRows: 2, cycles: 40)

        #expect(subject.census.arenaBytesInUse == control.census.arenaBytesInUse)

        for line in 213..<253 {
            let row = Self.shortRow(width: 16, count: cellsPerLine, seed: line)
            subject.admit(row)
            control.admit(row)
        }

        #expect(subject.grandDisplayRowTotal == control.grandDisplayRowTotal)
        #expect(Self.foldedScalars(subject) == Self.foldedScalars(control))
    }

    @Test("Reopening a forced-split tail across a seam pad gives the pad's bytes back")
    func reopeningAForcedSplitTailAcrossASeamPadReclaimsIt() {
        // Intent: the other rewind that crosses a pad -- reopening a closed forced-split record
        //   so its last display row can be cut -- reclaims the pad too.
        // Why it exists: `reopenTailRecordForTruncation` rewinds the cursor to the reopened
        //   record's end, which is before the pad the seam wrote after it. The maintained
        //   charge subtracted only the record's flushed side tables, so the pad leaked on every
        //   truncation that landed here, exactly as it did on the drop path.
        // Scenario: one never-terminated soft-wrapped line at width 12, force-split at the
        //   record cap and again at the wrap seam, truncated three display rows at a time.
        //
        // The line count and the row count together land the third removal inside the record
        // that precedes the pad, so it is reopened and cut rather than dropped, and the 40
        // rounds accumulate the leak the way the drop-path test's do.
        let budget = 1 << 14
        var control = Terminal.LogicalLineStore(budgetBytes: budget, width: 12)
        for line in 0..<157 {
            control.admit(Self.filledRow(width: 12, seed: line, softWrapped: true))
        }

        var subject = control
        Self.truncateAndReadmit(&subject, displayRows: 3, cycles: 40)

        #expect(subject.census.arenaBytesInUse == control.census.arenaBytesInUse)

        for line in 157..<197 {
            let row = Self.filledRow(width: 12, seed: line, softWrapped: true)
            subject.admit(row)
            control.admit(row)
        }

        #expect(subject.grandDisplayRowTotal == control.grandDisplayRowTotal)
        #expect(Self.foldedScalars(subject) == Self.foldedScalars(control))
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
        // Why it exists: `research/31/D3` Decision 4 and `research/31/DD16` -- today `reconstructLogicalLines`
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

    // MARK: - Reader contract shape (`research/31/D3` Decision 1)

    @Test("A forward cursor walks the retained display rows with one locate")
    func forwardCursorWalksWithOneLocate() {
        // Intent: `locate` converts one display row into a record address, and `advance`
        //   carries it forward without another conversion.
        // Why it exists: `research/31/D3` Decision 1 rule 2 -- a planned frame performs at most one
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

    // MARK: - Chunked backing (`research/31/D5`)

    @Test("arena backing materializes only when a record is first written")
    func arenaBackingMaterializesOnFirstWrite() {
        // Intent: a fresh store owns no backing chunks, and admitting one record materializes
        //   exactly the chunk that holds it while leaving the logical capacity unchanged.
        // Why it exists: eager construction dirties the full per-pane arena before the pane has
        //   any history, turning a logical capacity bound into a fixed resident-memory cost.
        // Scenario: a newly created pane receives its first hard-ended scrollback row.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)
        let capacity = store.capacityBytes

        #expect(store.chunkStorageIdentitiesForTesting().isEmpty)
        #expect(store.capacityBytes == capacity)

        store.admit(Self.shortRow(width: 80, count: 20, seed: 0))

        #expect(store.chunkStorageIdentitiesForTesting().count == 1)
        #expect(store.capacityBytes == capacity)
    }

    @Test("materialization high-water does not affect content, equality, or census")
    func materializationHighWaterIsUnobservable() {
        // Intent: stores with equal retained content compare equal, read identically, and report
        //   the same census even when one has materialized more arena backing.
        // Why it exists: lazy backing is a physical high-water only; letting it enter equality or
        //   the fixed metadata charge would make allocation history observable to callers.
        // Scenario: two stores grow identical index capacity through compact versus wide records,
        //   clear, then retain the same new line after reaching different backing chunks.
        var shallow = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)
        var deep = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)

        for seed in 0..<128 {
            shallow.admit(Self.shortRow(width: 80, count: 0, seed: seed))
            deep.admit(Self.filledRow(width: 80, seed: seed, softWrapped: false))
        }
        shallow.removeAll()
        deep.removeAll()

        #expect(shallow.chunkStorageIdentitiesForTesting().count == 1)
        #expect(deep.chunkStorageIdentitiesForTesting().count > 1)

        let common = Self.shortRow(width: 80, count: 20, seed: 1_000)
        shallow.admit(common)
        deep.admit(common)

        #expect(shallow == deep)
        #expect(shallow.recordCells(at: 0) == deep.recordCells(at: 0))
        #expect(shallow.census == deep.census)
    }

    @Test("a published value and the next admission share every chunk but the one written")
    func publishedValueThenAdmitCopiesOneChunkNotTheWholeArena() {
        // Intent: after the store's value has been copied -- which is what publishing a frame
        //   does -- the next admission copies only the backing chunk it writes into, not the
        //   whole arena.
        // Why it exists: this is `research/31/D5`'s whole mechanism, observably. `research/31/F13` M1 measured the
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
        // Why it exists: `31/PO12` states this for the arena's one physical seam; `research/31/D5` adds a
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
        let fullChunkCount = (store.capacityBytes + store.chunkCapacityBytesForTesting - 1)
            / store.chunkCapacityBytesForTesting
        #expect(store.chunkStorageIdentitiesForTesting().count <= fullChunkCount)
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

    /// The scalar a record coordinate resolves to, read back through the display projection a
    /// highlight would use.
    private static func scalar(
        in store: Terminal.LogicalLineStore,
        at coordinate: Terminal.LogicalLineStore.RecordTextPosition
    ) -> Unicode.Scalar? {
        guard let resolved = store.position(of: coordinate),
              let row = store.displayRow(at: resolved.displayRow),
              row.cells.indices.contains(resolved.column)
        else { return nil }
        return row.cells[resolved.column].scalars.first
    }

    /// Whether `candidate` is a trailing subsequence of `whole`.
    private static func isSuffix(_ candidate: [Unicode.Scalar], of whole: [Unicode.Scalar]) -> Bool {
        candidate.count <= whole.count && Array(whole.suffix(candidate.count)) == candidate
    }

    /// Reads the store back as logical lines, rejoining forced-split and mid-line records by
    /// adjacency exactly as `research/31/DD6` requires a reader to.
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
