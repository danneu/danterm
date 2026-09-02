// Behavioral proof suite for doc 31's logical-line record arena (`research/31/D2`, `research/31/D3`).
//
// What belongs here: the store's own contracts -- the charged-byte bound (`I2`/`PO3`), the
// five mutating operations (`I5`), the derived index's agreement with the arena (`I9`), the
// whole-line retention (`I10`/`PO9`), ring cycling (`PO12`) and record-level fidelity
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
            let row = store.displayRow(at: index)!
            return row.cells.indices.map { row.scalars(at: $0).first }
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

        var expectedAddresses: [(recordIndex: Int, cellOffset: Int)] = []
        for recordIndex in 0..<store.recordCount {
            let summary = try #require(store.recordSummary(at: recordIndex))
            for rowWithinRecord in 0..<summary.displayRowCount {
                expectedAddresses.append((recordIndex, min(rowWithinRecord * 3, summary.cellCount)))
            }
        }
        #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
        #expect(store.grandDisplayRowTotal == expectedAddresses.count)
        for (displayRow, expected) in expectedAddresses.enumerated() {
            let address = try #require(store.address(ofDisplayRow: displayRow, column: 0))
            #expect(address.recordIndex == expected.recordIndex)
            #expect(address.cellOffset == expected.cellOffset)
        }
    }

    @Test("Display and content totals agree with independent recounts after every mutation")
    func maintainedTotalsAndContentRanksAgreeWithRecountsAfterEveryMutation() {
        // Intent: the row index and width-free content ranks match independent arena recounts
        //   after every mutation that can change record cells, boundaries, or ownership.
        // Why it exists: content ranks are incrementally maintained across more paths than the
        //   width-derived row index, so one missed delta can silently reorder nearest matches.
        // Scenario: a store admits, closes, reopens, trims and drops at both ends,
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
        store.closeOpenRecord()
        check("second close")
        store.admit(Self.shortRow(width: 16, count: 7, seed: 101))
        check("closed-record successor")

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
        store.closeOpenRecord()
        check("third close")

        store.removeAll()
        check("clear all")
        #expect(store.grandDisplayRowTotal == 0)
        #expect(store.recordCount == 0)
    }

    @Test("Wide content totals and ranks survive eviction")
    func wideContentTotalsAndRanksSurviveEviction() throws {
        // Intent: the maintained content counts keep matching full cell-materialization oracles
        //   while eviction trims and drops records that contain wide-cell pairs.
        // Why it exists: the narrow-record count can use a header fast path only if the retained
        //   wide-record walk remains correct through both forms of head eviction.
        // Scenario: the fold suite's six-wide-cluster line shape repeatedly fills an 11-column
        //   store past a small budget, then every retained record coordinate is recounted.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 13, width: 11)

        func check(_ label: Comment) {
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

        for index in 0..<200 {
            var wrappedCells: [Terminal.GridCell] = []
            for scalar in "界世界世界".unicodeScalars {
                wrappedCells.append(
                    Terminal.GridCell(scalars: TerminalScalars(scalar), kind: .wideHead)
                )
                wrappedCells.append(Terminal.GridCell(kind: .wideTail))
            }
            wrappedCells.append(Terminal.GridCell(kind: .spacerHead))
            var wrapped = Terminal.GridRow(cells: wrappedCells)
            wrapped.isSoftWrapped = true
            store.admit(wrapped)
            check("line \(index), wrapped row")

            var endingCells = [
                Terminal.GridCell(scalars: TerminalScalars("世"), kind: .wideHead),
                Terminal.GridCell(kind: .wideTail),
            ]
            endingCells.append(contentsOf: "x\(index)".unicodeScalars.map { Self.narrow($0) })
            endingCells.append(
                contentsOf: repeatElement(
                    Terminal.GridCell(),
                    count: 11 - endingCells.count
                )
            )
            store.admit(Terminal.GridRow(cells: endingCells))
            check("line \(index), ending row")
        }

        #expect(store.evictedRowCount > 2, "the stimulus must exercise trim and drop eviction")
    }

    @Test("Content ranks count projected cells and hard boundaries exactly")
    func contentRanksMatchSearchProjectionUnits() throws {
        // Intent: a narrow cell, wide pair and padding each advance rank once, while a
        //   hard-ended predecessor contributes one boundary.
        // Why it exists: rank subtraction is sound only if its unit is exactly the unit the
        //   search scanner consumes; display columns would count the wide pair twice.
        // Scenario: mixed-width content ends one record before a second hard-ended record.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        var mixed = Terminal.GridRow(cells: [
            Self.narrow("a"),
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Terminal.GridCell(kind: .padding),
        ])
        mixed.isSoftWrapped = true
        store.admit(mixed)
        store.admit(Self.shortRow(width: 4, count: 1, seed: 20))
        store.admit(Self.shortRow(width: 4, count: 1, seed: 21))

        let expectedMixedRanks = [0, 1, 2, 2, 3]
        for (offset, expected) in expectedMixedRanks.enumerated() {
            let coordinate = try #require(
                store.recordTextPosition(recordIndex: 0, cellOffset: offset)
            )
            #expect(store.contentRank(of: coordinate) == expected)
        }

        let hardBoundarySuccessor = try #require(
            store.recordTextPosition(recordIndex: 1, cellOffset: 0)
        )
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

    /// Every retained row that reports it continues must reach the margin: `width` projected
    /// cells, or `width - 1` ending in the spacer a wide head deferred (`31/I1`).
    /// Returns the continuing rows it checked, so a caller can prove the walk was not vacuous.
    @discardableResult
    private static func expectContinuingRowsReachTheMargin(
        _ store: Terminal.LogicalLineStore,
        _ label: Comment
    ) -> Int {
        let width = store.width
        var continuing = 0
        for index in 0..<store.grandDisplayRowTotal {
            guard let row = store.displayRow(at: index) else {
                Issue.record("\(label): row \(index) did not fold")
                continue
            }
            guard row.isSoftWrapped else { continue }
            continuing += 1
            let count = row.cells.count
            #expect(
                count == width || (count == width - 1 && row.cells.last?.kind == .spacerHead),
                "\(label): continuing row \(index) holds \(count) of \(width) columns"
            )
        }
        return continuing
    }

    @Test("Every continuing retained row reaches its margin at widths that do not divide the line")
    func continuingRowsReachTheMarginAtEveryWidth() {
        // Intent: `31/PO1` at the store level. A line long enough to straddle several chunk
        //   seams and circle the arena folds at four unrelated widths with no short row that
        //   still reports as continuing -- before eviction, after a head trim into the line, and
        //   after a tail truncation into it.
        // Why it exists: this is the shape that trapped the Mac app (DanTerm 0.1.25,
        //   2026-09-01). A cut inside a logical line is a display-row boundary frozen at the
        //   admitting width, so any other width shows it as a row that ends short of the margin
        //   while `isSoftWrapped` still says the line continues.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 20)
        for row in 0..<3_000 {
            store.admit(Self.filledRow(width: 20, seed: row, softWrapped: true))
        }
        store.admit(Self.shortRow(width: 20, count: 13, seed: 1))

        #expect(store.evictedRowCount > 0, "the stimulus must circle the arena")
        #expect(
            store.chunkStorageIdentitiesForTesting().count > 1,
            "the stimulus must straddle chunk seams"
        )

        func checkEveryWidth(_ label: Comment) {
            for width in [7, 13, 53, 179] {
                _ = store.setWidth(width)
                let continuing = Self.expectContinuingRowsReachTheMargin(
                    store,
                    "\(label) at width \(width)"
                )
                #expect(continuing > 0, "\(label) at width \(width): nothing continued")
                #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
            }
            _ = store.setWidth(20)
        }

        checkEveryWidth("as admitted")
        #expect(evictOne(&store))
        checkEveryWidth("after a head trim")
        _ = store.truncateTail(displayRows: 3)
        checkEveryWidth("after a tail truncation")
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

    /// One soft-wrapped row whose cells carry a hyperlink or a content identity every `stride`
    /// cells, keyed by the cell's position in the whole logical line so the strides survive the
    /// row boundary.
    private static func sparselyAttributedRow(
        width: Int,
        firstCell: Int,
        hyperlinkStride: Int?,
        identityStride: Int?
    ) -> Terminal.GridRow {
        var row = Terminal.GridRow(cells: (0..<width).map { column in
            let index = firstCell + column
            var cell = narrow(Unicode.Scalar(UInt32(97 + index % 26))!)
            if let hyperlinkStride, index % hyperlinkStride == 0 {
                cell.hyperlinkId = Terminal.HyperlinkId(1 + index % 60_000)
            }
            if let identityStride, index % identityStride == 0 {
                cell.contentIdentity = Terminal.ContentIdentity(1 + index)
            }
            return cell
        })
        row.isSoftWrapped = true
        return row
    }

    @Test("A line whose table entries overflow the header count stays inside its reservation")
    func overflowingTableEntryCountStaysInsideItsReservation() {
        // Intent: closing a logical line with more than 65,535 sparse table entries charges no
        //   more than admission reserved, and writes nothing over the head record.
        // Why it exists: the flush stores a table per cell as soon as its entry count would
        //   overflow the header's 16-bit field, even when the sparse runs are the cheaper
        //   encoding. The reservation priced the cheaper one, so the close wrote past the
        //   charge and the write cursor could pass the head -- silent ring corruption.
        // Scenario: a program prints one very long line whose attributes repeat every few
        //   cells, after filling the pane's history.
        func check(
            hyperlinkStride: Int?,
            identityStride: Int?,
            giantRows: Int,
            _ label: Comment
        ) {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 23, width: 200)
            // Enough history that the free space left in the ring is smaller than the
            // reservation the close will overrun; more than that only costs the suite time.
            for line in 0..<3_000 {
                store.admit(Self.filledRow(width: 200, seed: line, softWrapped: false))
            }
            for row in 0..<giantRows {
                store.admit(Self.sparselyAttributedRow(
                    width: 200,
                    firstCell: row * 200,
                    hyperlinkStride: hyperlinkStride,
                    identityStride: identityStride
                ))
            }

            let giant = store.recordCount - 1
            let openLinks = store.recordCells(at: giant)?.map(\.hyperlinkId)
            let openIdentities = store.recordCells(at: giant)?.map(\.contentIdentity)
            let headScalars = store.recordScalars(at: 0)?.map(\.first)
            let rowsBefore = store.independentDisplayRowRecount()
            let entries = hyperlinkStride == nil
                ? (openIdentities?.compactMap { $0 }.count ?? 0)
                : (openLinks?.compactMap { $0 }.count ?? 0)
            #expect(
                entries > 65_535,
                "\(label): the stimulus must overflow the header's table count"
            )

            store.closeOpenRecord()

            #expect(store.chargedBytes <= store.capacityBytes, label)
            #expect(store.census.chargedBytes <= store.census.capacityBytes, label)
            #expect(store.recordCells(at: giant)?.map(\.hyperlinkId) == openLinks, label)
            #expect(store.recordCells(at: giant)?.map(\.contentIdentity) == openIdentities, label)
            #expect(store.recordScalars(at: 0)?.map(\.first) == headScalars, label)
            #expect(store.independentDisplayRowRecount() == rowsBefore, label)
            #expect(store.grandDisplayRowTotal == rowsBefore, label)
        }

        // The two strides are the cheapest each table has: below them the sparse encoding is
        // already the dearer one and the flush would pick per-cell on bytes alone. The row
        // counts put each line's entry count past the header's field while its scratch still
        // fits, which is the only window where the reservation and the flush can disagree.
        check(
            hyperlinkStride: 5,
            identityStride: nil,
            giantRows: 2_000,
            "hyperlinks every fifth cell"
        )
        check(
            hyperlinkStride: nil,
            identityStride: 4,
            giantRows: 1_500,
            "identities every fourth cell"
        )
    }

    @Test("A row that fits an empty arena is admitted however long the open line is")
    func aRowIsAdmittedOnItsOwnSizeNotTheOpenLines() {
        // Intent: `31/I9`. The only row a store refuses is one that cannot fit an empty arena.
        //   A plain soft-wrapped line at a small budget keeps admitting rows, trimming its own
        //   head to pay for them.
        // Why it exists: the admission guard priced the row *plus* the whole open record's
        //   projected side tables, and returned before any eviction. A plain line carries no
        //   scratch charge, so nothing bounded the open record before the guard did -- one row
        //   was refused for the sake of the line it would have extended, and then every later
        //   row of that line was refused the same way. History froze at whatever it held, with
        //   no trace anywhere.
        // Scenario: a program prints one long unstyled line into a pane with a small scrollback
        //   budget.
        func check(width: Int, _ label: Comment) {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 10, width: width)
            // One distinct scalar per cell of the line, so the newest cell is identifiable.
            func row(_ index: Int) -> Terminal.GridRow {
                var row = Terminal.GridRow(cells: (0..<width).map { column in
                    Self.narrow(Unicode.Scalar(UInt32(0x4E00 + index * width + column))!)
                })
                row.isSoftWrapped = true
                return row
            }
            let rows = 10
            for index in 0..<rows { store.admit(row(index)) }

            let retained = (0..<store.recordCount)
                .compactMap { store.recordScalars(at: $0) }
                .flatMap { $0 }
                .compactMap(\.first)
            #expect(retained.isEmpty == false, label)
            #expect(
                retained.last == Unicode.Scalar(UInt32(0x4E00 + rows * width - 1))!,
                "\(label): history froze at \(retained.count) cells"
            )
            #expect(store.evictedRowCount > 0, "\(label): the line is trimmed, not refused")
            #expect(store.chargedBytes <= store.capacityBytes, label)
        }

        check(width: 50, "width 50")
        check(width: 34, "width 34")
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
            row.place(
                Terminal.GridCell(kind: .narrow),
                scalars: TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!]),
                at: 0
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
            row.place(
                Terminal.GridCell(kind: .narrow),
                scalars: TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!]),
                at: 3
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
        store.closeOpenRecord()
        check("close")

        store.reopenTailRecord()
        check("reopen")

        store.removeAll()
        check("clear all")
    }

    @Test("Admitting a spill row prices constant work regardless of the open line's spill depth")
    func spillAdmissionWorkIsIndependentOfOpenSpillDepth() {
        // Intent: admitting one spill-bearing row performs the same spill-charge work after one
        //   prior spill as it does after roughly one thousand prior spills.
        // Why it exists: keeping the open tail in the closed-record spill table makes each
        //   admission re-price the whole array and turns one long logical line quadratic.
        // Scenario: two open lines differ only in their existing spill depth, then each admits
        //   one more identical spill row under the engine's exact work instrument.
        func measuredWork(after existingSpills: Int) -> Int {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 1)
            var row = Terminal.GridRow(cells: [Terminal.GridCell(kind: .narrow)])
            row.place(
                row.cells[0],
                scalars: TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!]),
                at: 0
            )
            row.isSoftWrapped = true
            for _ in 0..<existingSpills { store.admit(row) }
            return Instrument.openSpillChargeWork.measure { store.admit(row) }
        }

        let shallow = measuredWork(after: 1)
        let deep = measuredWork(after: 1_000)

        #expect(shallow > 0)
        #expect(deep == shallow)
    }

    @Test("Closing and reopening a spill-heavy tail leaves no outer spill buffer in scratch")
    func spillOwnershipTransfersLeaveNoScratchAllocation() {
        // Intent: close and reopen transfer the outer spill-array allocation instead of leaving
        //   a duplicate or retained buffer in open scratch.
        // Why it exists: open scratch is charged by capacity, so retaining a large closed
        //   record's outer array would reduce history depth even after that record is evicted.
        // Scenario: one store first establishes the closed spill table's steady allocation with
        //   one spill, then cycles an otherwise identical all-spill record through reopen/close;
        //   after each record is evicted, the remaining side-table charge must be equal.
        let rowCount = 128
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 1)

        func admitRecord(spillOnEveryRow: Bool) {
            for index in 0..<rowCount {
                let spills = spillOnEveryRow || index == 0
                let scalars = spills
                    ? TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!])
                    : TerminalScalars(Unicode.Scalar(97)!)
                var row = Terminal.GridRow(cells: [Terminal.GridCell(kind: .narrow)])
                row.place(row.cells[0], scalars: scalars, at: 0)
                row.isSoftWrapped = index != rowCount - 1
                store.admit(row)
            }
        }

        admitRecord(spillOnEveryRow: false)
        store.admit(Self.shortRow(width: 1, count: 1, seed: 20))
        for _ in 0..<rowCount { _ = store.evictOneDisplayRow() }
        let sparseCharge = store.census.sideTableBytes

        admitRecord(spillOnEveryRow: true)
        store.reopenTailRecord()
        store.closeOpenRecord()
        store.admit(Self.shortRow(width: 1, count: 1, seed: 21))
        for _ in 0...rowCount { _ = store.evictOneDisplayRow() }
        let denseCharge = store.census.sideTableBytes

        #expect(denseCharge == sparseCharge)
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
            row.place(
                Terminal.GridCell(kind: .narrow, styleId: 9),
                scalars: TerminalScalars([
                    Unicode.Scalar(97 + UInt32(line % 26))!, Unicode.Scalar(0x0301)!,
                ]),
                at: 0
            )
            store.admit(row)
        }

        #expect(store.census.sideTableBytes > 0)
        #expect(store.chargedBytes <= store.capacityBytes)
        #expect(store.grandDisplayRowTotal == 219)
        #expect(store.evictedRowCount == 181)

        let oldest = store.displayRow(at: 0)
        #expect(oldest?.scalars(at: 0).count == 2)
        #expect(oldest?.scalars(at: 0).first == Unicode.Scalar(97 + UInt32(181 % 26))!)
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

    // MARK: - One record per logical line

    @Test("A logical line past the old cap remains one whole record")
    func logicalLinePastTheOldCapRemainsWhole() {
        let capacity = 1 << 16
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 32)
        let oldCap = (capacity / 32) / Terminal.LogicalLineRecord.cellBytes

        var admitted = 0
        while admitted < oldCap + 64 {
            store.admit(Self.filledRow(width: 32, seed: admitted, softWrapped: true))
            admitted += 32
        }

        #expect(store.recordCount == 1)
        let record = store.recordSummary(at: 0)!
        #expect(record.cellCount == admitted)
        #expect(record.isOpen)
        #expect(store.recordCells(at: 0)?.count == admitted)
        #expect(store.displayRow(at: record.displayRowCount - 1)?.isSoftWrapped == true)
    }

    @Test("Rebasing a record larger than the target arena retains its suffix")
    func rebasingOversizedRecordRetainsItsSuffix() {
        // Intent: rebasing a whole-line record larger than the target arena keeps admitting
        //   display rows and retains the newest suffix without trapping.
        // Why it exists: copying the source record as one admission asks the smaller arena to
        //   hold the entire line before it can perform display-row head eviction.
        // Scenario: an open 4,000-cell line is rebased from 64 KiB to 8 KiB.
        var source = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 32)
        var expected: [Unicode.Scalar] = []
        for row in 0..<125 {
            let cells = Self.filledRow(width: 32, seed: row, softWrapped: true)
            source.admit(cells)
            expected.append(contentsOf: cells.cells.compactMap { $0.word.inlineScalar })
        }

        let rebased = source.rebased(toBudgetBytes: 1 << 13)
        let retained = Self.readLogicalLines(rebased)

        #expect(retained.count == 1)
        #expect(Self.isSuffix(retained[0], of: expected))
        #expect(rebased.census.chargedBytes <= rebased.census.capacityBytes)
    }

    @Test("Rebasing at the same budget reproduces the store it copied")
    func rebasingAtTheSameBudgetReproducesTheSource() {
        // Intent: a multi-row logical line rebased at its own budget still reads as one line
        //   that starts where it started, and the copy compares equal to its source.
        // Why it exists: `rebased(toBudgetBytes:)` is the oracle
        //   `withUnlimitedScrollbackForTesting` compares against. Replay walks the source's
        //   display rows, and a copy that stamped every row after the first as a continuation
        //   turned one whole line into a line whose head had been trimmed -- so the oracle
        //   disagreed with the store it was supposed to reproduce.
        var source = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        source.admit(Self.filledRow(width: 8, seed: 0, softWrapped: true))
        source.admit(Self.shortRow(width: 8, count: 5, seed: 8))

        let rebased = source.rebased(toBudgetBytes: 1 << 16)

        #expect(rebased.recordCount == 1)
        #expect(rebased.recordSummary(at: 0)?.startsMidLine == false)
        #expect(rebased.recordSummary(at: 0)?.cellCount == 13)
        #expect(rebased == source)
    }

    @Test("Style liveness sees a style carried only past a chunk seam and only past the wrap")
    func styleLivenessSeesStylesPastASeamAndPastTheWrap() throws {
        // Intent: `31/PO2`'s style-liveness leg. `forEachStyleId` reports a style whose only
        //   retained cell sits after a backing-chunk seam, and one whose only retained cell sits
        //   after the arena's physical end, so reclamation cannot free either.
        // Why it exists: the liveness walk reads cell words straight out of the arena. A walk
        //   that hoisted one chunk pointer, or that stopped at the arena's end instead of
        //   wrapping, would still report every style in every other fixture here.
        //
        // Budget 1 << 17 reserves 122,880 bytes in two 64 KiB chunks, and each of these rows is
        // one record of exactly 8 + 16 * 8 = 136 bytes, so record n starts at 136n mod 122,880.
        // Record 481 spans [65,416, 65,552), which crosses the seam at 65,536 inside its last
        // two cells; record 903 spans [122,808, 122,944), which crosses the arena's end inside
        // its last eight. Both are still retained after 950 records.
        let seamRecord = 481
        let wrapRecord = 903
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 17, width: 16)
        for index in 0..<950 {
            var row = Self.filledRow(width: 16, seed: index, softWrapped: false)
            if index == seamRecord { row.cells[15].styleId = 4_242 }
            if index == wrapRecord { row.cells[15].styleId = 4_243 }
            store.admit(row)
        }

        #expect(store.chunkStorageIdentitiesForTesting().count > 1)
        #expect(store.evictedRowCount > 0, "the ring has to have passed the arena's end")
        #expect(store.recordCount < 950, "the head has to have been evicted")

        // Where those two records actually landed, rather than where the arithmetic above says
        // they should: a layout change fails the test instead of hollowing it.
        func index(ofStyle styleId: Terminal.StyleId) -> Int? {
            (0..<store.recordCount).first { index in
                store.recordCells(at: index)?.contains { $0.styleId == styleId } ?? false
            }
        }
        let chunk = store.chunkCapacityBytesForTesting
        let seamIndex = try #require(index(ofStyle: 4_242))
        let wrapIndex = try #require(index(ofStyle: 4_243))
        let seamSpan = try #require(store.recordArenaSpanForTesting(at: seamIndex))
        #expect(
            (seamSpan.start + seamSpan.length - 1) / chunk > seamSpan.start / chunk,
            "record 4242 has to cross a chunk seam: \(seamSpan), chunk \(chunk)"
        )
        let wrapSpan = try #require(store.recordArenaSpanForTesting(at: wrapIndex))
        #expect(
            wrapSpan.start + wrapSpan.length > store.capacityBytes,
            "record 4243 has to cross the arena's end: \(wrapSpan) of \(store.capacityBytes)"
        )

        var live = Set<Terminal.StyleId>()
        store.forEachStyleId { live.insert($0) }
        var materialized = Set<Terminal.StyleId>()
        for row in store.allPaintedDisplayRows() {
            for cell in row.cells { materialized.insert(cell.styleId) }
        }

        #expect(materialized.contains(4_242), "the seam-crossing record must still be retained")
        #expect(materialized.contains(4_243), "the wrap-crossing record must still be retained")
        #expect(live.contains(4_242))
        #expect(live.contains(4_243))
        #expect(live == materialized)
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

    @Test("A long whole record keeps its trailing fill through head eviction")
    func longWholeRecordKeepsItsTrailingFill() {
        let capacity = 1 << 16
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 32)
        let oldCap = (capacity / 32) / Terminal.LogicalLineRecord.cellBytes

        var admitted = 0
        while admitted + 32 <= oldCap {
            store.admit(Self.filledRow(width: 32, seed: admitted, softWrapped: true))
            admitted += 32
        }
        store.admit(Self.backgroundErasedRow(width: 32, count: 5, seed: 1, fillStyle: 21))

        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)!.trailingFillStyle == 21)
        #expect(evictOne(&store))
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
        // Why it exists: `31/PO12` requires the retained suffix to survive the ring's wrap
        //   without making the wrap part of the record's logical shape.
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
                scalars.append(contentsOf: row.cells.compactMap { $0.word.inlineScalar })
                seed += 1
            }
            let tailCount = 1 + (line % 11)
            let last = Self.shortRow(width: 12, count: tailCount, seed: seed)
            store.admit(last)
            scalars.append(contentsOf: last.cells.prefix(tailCount).compactMap { $0.word.inlineScalar })
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

    @Test("An open tail grows across the physical end as one record")
    func openTailCrossesThePhysicalEndAsOneRecord() {
        let capacity = 1 << 14
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 16)

        var expected: [Unicode.Scalar] = []
        var seed = 0
        for _ in 0..<400 {
            let row = Self.filledRow(width: 16, seed: seed, softWrapped: true)
            store.admit(row)
            expected.append(contentsOf: row.cells.compactMap { $0.word.inlineScalar })
            seed += 1
            #expect(store.census.chargedBytes <= capacity)
        }

        let lines = Self.readLogicalLines(store)
        #expect(lines.count == 1)
        let actual = lines[0]
        let suffix = Array(expected.suffix(actual.count))
        let mismatch = actual.indices.first { actual[$0] != suffix[$0] }
        let matchingStart = (0...max(0, expected.count - actual.count)).first { start in
            Array(expected[start..<min(expected.count, start + min(64, actual.count))])
                == Array(actual.prefix(64))
        }
        #expect(
            actual.count <= expected.count && mismatch == nil,
            "retained=\(actual.count), expected=\(expected.count), mismatch=\(String(describing: mismatch)), matchingStart=\(String(describing: matchingStart))"
        )
    }

    @Test("Hard-ended records cycle through the physical end")
    func hardEndedRecordsCycleThroughThePhysicalEnd() {
        let capacity = 1 << 13
        var store = Terminal.LogicalLineStore(budgetBytes: capacity, width: 16)

        // Hard-ended lines only: every record closes immediately, so the record that meets the
        // seam is always freshly opened and empty when the fit test runs.
        for line in 0..<600 {
            store.admit(Self.shortRow(width: 16, count: 9, seed: line))
            #expect(store.census.chargedBytes <= capacity)
        }

        #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
        #expect(store.grandContentUnitTotal == store.independentContentUnitRecount())
        #expect(
            store.contentBlockTotalsForTesting == store.independentContentBlockTotalsForTesting
        )
    }

    // MARK: - PO7 / I7: equality ignores placement, not state

    @Test("Stores fed the same rows from different ring positions compare equal")
    func storesFedTheSameRowsFromDifferentRingPositionsCompareEqual() {
        // Intent: `31/PO7` clause 1. Two stores holding the same retained lines compare equal
        //   even though their records sit at different arena offsets.
        // Why it exists: `31/I7` says equality is about what history holds, not where. The ring
        //   cursor is placement, and a comparison that reached it would make two panes fed the
        //   same output unequal for having been fed different output before it.
        func build(prefixCells: Int) -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 10)
            for line in 0..<100 {
                store.admit(Self.shortRow(width: 10, count: prefixCells, seed: line))
            }
            for line in 0..<100 {
                store.admit(Self.shortRow(width: 10, count: 6, seed: 1_000 + line))
            }
            for _ in 0..<100 { _ = store.evictOneDisplayRow() }
            return store
        }

        let compact = build(prefixCells: 3)
        let wide = build(prefixCells: 9)

        #expect(compact.recordCount == 100)
        #expect(compact.evictedRowCount == wide.evictedRowCount)
        #expect(compact == wide)
    }

    @Test("Stores reaching one retained suffix through different prefixes compare equal")
    func storesReachingTheSameRetainedSuffixCompareEqual() {
        // Intent: two stores at the same eviction origin whose head record was trimmed down to
        //   the same retained cells compare equal, whatever spills, hyperlinks and identities
        //   the evicted prefixes carried, and unequal once a retained payload differs.
        // Why it exists: `31/PO7`. A trimmed head keeps the spill base and the whole line's
        //   side tables, so its stored bytes describe a line neither store still holds -- the
        //   comparison has to fall back to what a reader sees, and that fallback has to work.
        func prefixRow(attributed: Bool) -> Terminal.GridRow {
            let cells = (0..<4).map { column -> Terminal.GridCell in
                var cell = Self.narrow(Unicode.Scalar(UInt32(100 + column))!)
                if attributed {
                    cell.hyperlinkId = Terminal.HyperlinkId(20 + column)
                    cell.contentIdentity = Terminal.ContentIdentity(900 + 5 * column)
                }
                return cell
            }
            var row = Terminal.GridRow(cells: cells)
            if attributed {
                for column in 0..<4 {
                    row.place(
                        row.cells[column],
                        scalars: TerminalScalars([
                            Unicode.Scalar(UInt32(100 + column))!,
                            Unicode.Scalar(0x0301)!,
                        ]),
                        at: column
                    )
                }
            }
            row.isSoftWrapped = true
            return row
        }
        func suffixRow(identity: Terminal.ContentIdentity, closed: Bool) -> Terminal.GridRow {
            var cells = (0..<4).map { Self.narrow(Unicode.Scalar(UInt32(97 + $0))!) }
            cells[1].hyperlinkId = 7
            cells[2].contentIdentity = identity
            var row = Terminal.GridRow(cells: cells)
            row.place(
                row.cells[0],
                scalars: TerminalScalars([Unicode.Scalar("z"), Unicode.Scalar(0x0301)!]),
                at: 0
            )
            row.isSoftWrapped = closed == false
            return row
        }
        func build(
            attributedPrefix: Bool,
            identity: Terminal.ContentIdentity,
            closed: Bool
        ) -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
            store.admit(prefixRow(attributed: attributedPrefix))
            store.admit(suffixRow(identity: identity, closed: closed))
            _ = store.evictOneDisplayRow()
            return store
        }

        for closed in [false, true] {
            let label: Comment = closed ? "closed line" : "open line"
            let attributed = build(attributedPrefix: true, identity: 500, closed: closed)
            let plain = build(attributedPrefix: false, identity: 500, closed: closed)
            let different = build(attributedPrefix: false, identity: 501, closed: closed)

            #expect(attributed.recordCount == 1, label)
            #expect(attributed.evictedRowCount == 1, label)
            #expect(attributed.recordSummary(at: 0)?.cellCount == 4, label)
            #expect(attributed == plain, label)
            #expect(attributed != different, label)
        }
    }

    @Test("A trimmed head's stale wide-cell bit does not split equal history")
    func storesReachingTheSameSuffixThroughAWideEvictedPrefixCompareEqual() {
        // Intent: two stores whose head record was trimmed down to the same retained cells
        //   compare equal even when only one of them evicted a wide cluster.
        // Why it exists: `31/PO7`. `hasWideCells` describes the whole line as it was admitted
        //   and a trim never clears it, so the bit outlives the cells that set it. Reading it as
        //   retained content makes two panes holding the same text disagree for good.
        // Scenario: one pane's oldest line opened with a CJK cluster and the other's did not;
        //   both lose that first display row.
        func build(wideStart: Bool, closed: Bool) -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
            var first = Terminal.GridRow(cells: wideStart
                ? [
                    Terminal.GridCell(
                        scalars: TerminalScalars(Unicode.Scalar(0x754C)!),
                        kind: .wideHead
                    ),
                    Terminal.GridCell(kind: .wideTail),
                    Self.narrow("a"),
                    Self.narrow("b"),
                ]
                : [Self.narrow("a"), Self.narrow("b"), Self.narrow("c"), Self.narrow("d")]
            )
            first.isSoftWrapped = true
            store.admit(first)
            var second = Terminal.GridRow(cells: [
                Self.narrow("c"), Self.narrow("d"), Self.narrow("e"), Self.narrow("f"),
            ])
            second.isSoftWrapped = closed == false
            store.admit(second)
            _ = store.evictOneDisplayRow()
            return store
        }

        for closed in [false, true] {
            let label: Comment = closed ? "closed line" : "open line"
            let wide = build(wideStart: true, closed: closed)
            let plain = build(wideStart: false, closed: closed)

            #expect(wide.recordSummary(at: 0)?.hasWideCells == true, label)
            #expect(plain.recordSummary(at: 0)?.hasWideCells == false, label)
            #expect(
                wide.recordScalars(at: 0)?.compactMap(\.first) == ["c", "d", "e", "f"],
                label
            )
            #expect(plain.recordScalars(at: 0)?.compactMap(\.first) == ["c", "d", "e", "f"], label)
            #expect(wide == plain, label)
        }
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
            if column == 4 {
                cell.hyperlinkId = 7
            }
            cells.append(cell)
        }
        var first = Terminal.GridRow(cells: cells)
        first.place(
            first.cells[2],
            scalars: TerminalScalars([Unicode.Scalar(0x1F600)!, Unicode.Scalar(0xFE0F)!]),
            at: 2
        )
        first.isSoftWrapped = true
        store.admit(first)
        store.admit(Self.shortRow(width: 6, count: 3, seed: 40))

        func assertSurvives(_ label: Comment, offsetBy trimmed: Int) {
            let record = store.recordCells(at: 0)!
            let scalars = store.recordScalars(at: 0)!
            #expect(record.count == 9 - trimmed, label)
            for column in 0..<6 where column - trimmed >= 0 {
                let cell = record[column - trimmed]
                #expect(cell.contentIdentity == Terminal.ContentIdentity(500 + column), label)
                if column == 2 {
                    #expect(scalars[column - trimmed].count == 2, label)
                    #expect(scalars[column - trimmed].first == Unicode.Scalar(0x1F600), label)
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

    @Test("Open-tail spills survive every ownership transfer and both read paths")
    func openTailSpillsSurviveOwnershipTransfers() throws {
        // Intent: spill payloads read identically while open, closed, and reopened through
        //   both materializing readers and the renderer's borrowed-cell seam.
        // Why it exists: open spills now have a different owner from closed spills, so every
        //   ownership transfer and every reader must select the same current home.
        // Scenario: one logical line gains spills before and after a close/reopen, then closes
        //   before a successor record gains a final spill.
        func spill(_ scalar: Unicode.Scalar, softWrapped: Bool) -> Terminal.GridRow {
            var row = Terminal.GridRow(cells: [Terminal.GridCell(kind: .narrow)])
            row.place(
                row.cells[0],
                scalars: TerminalScalars([scalar, Unicode.Scalar(0x0301)!]),
                at: 0
            )
            row.isSoftWrapped = softWrapped
            return row
        }
        func assertReads(
            _ store: Terminal.LogicalLineStore,
            _ expected: [Unicode.Scalar],
            _ label: Comment
        ) throws {
            let materialized = (0..<store.recordCount).flatMap {
                store.recordScalars(at: $0) ?? []
            }.compactMap(\.first)
            #expect(materialized == expected, label)

            let displayed = (0..<store.grandDisplayRowTotal).flatMap { index -> [TerminalScalars] in
                guard let row = store.displayRow(at: index) else { return [] }
                return row.cells.indices.map { row.scalars(at: $0) }
            }.compactMap(\.first)
            #expect(displayed == expected, label)

            let painted = (0..<store.grandDisplayRowTotal).flatMap { index -> [TerminalScalars] in
                guard let row = store.paintedDisplayRow(at: index) else { return [] }
                return row.cells.indices.map { row.scalars(at: $0) }
            }.compactMap(\.first)
            #expect(painted == expected, label)

            var borrowed: [Unicode.Scalar] = []
            for displayRow in 0..<store.grandDisplayRowTotal {
                let cursor = try #require(store.locate(displayRow: displayRow))
                store.forEachPaintedCell(at: cursor) { _, _, scalars, _ in
                    if let scalar = scalars.first { borrowed.append(scalar) }
                }
            }
            #expect(borrowed == expected, label)
        }

        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 1)
        store.admit(spill("a", softWrapped: true))
        store.admit(spill("b", softWrapped: true))
        try assertReads(store, ["a", "b"], "open")

        store.closeOpenRecord()
        try assertReads(store, ["a", "b"], "closed")
        store.reopenTailRecord()
        store.admit(spill("c", softWrapped: true))
        try assertReads(store, ["a", "b", "c"], "reopened")

        store.closeOpenRecord()
        store.admit(spill("d", softWrapped: false))
        try assertReads(store, ["a", "b", "c", "d"], "closed successor")
        #expect(store.independentDisplayRowRecount() == store.grandDisplayRowTotal)
        #expect(store.independentContentUnitRecount() == store.grandContentUnitTotal)
        #expect(store.chargedBytes == store.census.chargedBytes)
    }

    @Test("Reopening a table-bearing tail releases its flushed arena bytes")
    func reopeningTableBearingTailRewindsToItsCells() {
        // Intent: reopening moves the closed tail's side tables into scratch and makes their
        //   former arena bytes available to the next cells.
        // Why it exists: leaving the write cursor after the flushed tables creates a charged
        //   gap even though append overwrites the tables at the end of the retained cells.
        // Scenario: one attributed row closes with both table kinds, then resumes printing.
        func row(softWrapped: Bool) -> Terminal.GridRow {
            Self.attributedRow(
                width: 4,
                seed: 0,
                softWrapped: softWrapped,
                identity: { Terminal.ContentIdentity(100 + $0) }
            )
        }
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(row(softWrapped: false))
        let flushed = store.census.arenaBytesInUse

        // The same cells admitted as a line that never ended: what the arena holds for a record
        // whose tables have not been flushed, which is what reopening must get back to.
        var neverClosed = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        neverClosed.admit(row(softWrapped: true))

        store.reopenTailRecord()

        #expect(store.census.arenaBytesInUse < flushed)
        #expect(store.census.arenaBytesInUse == neverClosed.census.arenaBytesInUse)
        #expect(store.recordCells(at: 0)?.map(\.contentIdentity) == [100, 101, 102, 103])
        #expect(store.recordCells(at: 0)?.map(\.hyperlinkId) == [7, 7, 7, 7])
    }

    /// A full row whose every cell carries its own hyperlink id and a run-breaking identity, so
    /// a table read one cell off the right base returns a different value rather than the same one.
    private static func perCellAttributedRow(
        width: Int,
        seed: Int,
        softWrapped: Bool
    ) -> Terminal.GridRow {
        var row = Terminal.GridRow(cells: (0..<width).map { column in
            let key = seed + column
            return narrow(
                Unicode.Scalar(UInt32(97 + key % 26))!,
                hyperlinkId: Terminal.HyperlinkId(1 + key),
                contentIdentity: Terminal.ContentIdentity(1_000 + 7 * key)
            )
        })
        row.isSoftWrapped = softWrapped
        return row
    }

    @Test("Reopening a later tail keeps a trimmed closed head's table base")
    func reopeningALaterTailKeepsTheTrimmedHeadsTableBase() {
        // Intent: reopening the tail record leaves the head record's flushed per-cell tables
        //   reading at the base a head trim gave them.
        // Why it exists: the base is one store-level scalar shared by whichever record is the
        //   head. Reopening a *different* record must not reset it, or every table read on the
        //   trimmed head shifts by the cells the trim dropped -- silently returning another
        //   cell's hyperlink and identity.
        // Scenario: two closed attributed lines, the head trimmed by one display row, then the
        //   tail reopened because printing resumed on it.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(Self.perCellAttributedRow(width: 4, seed: 0, softWrapped: true))
        store.admit(Self.perCellAttributedRow(width: 4, seed: 4, softWrapped: false))
        store.admit(Self.perCellAttributedRow(width: 4, seed: 100, softWrapped: true))
        store.admit(Self.perCellAttributedRow(width: 4, seed: 104, softWrapped: false))

        #expect(evictOne(&store))
        let expectedLinks: [Terminal.HyperlinkId?] = [5, 6, 7, 8]
        let expectedIdentities: [Terminal.ContentIdentity?] = [1_028, 1_035, 1_042, 1_049]
        #expect(store.recordCells(at: 0)?.map(\.hyperlinkId) == expectedLinks)
        #expect(store.recordCells(at: 0)?.map(\.contentIdentity) == expectedIdentities)

        store.reopenTailRecord()

        #expect(store.recordCells(at: 0)?.map(\.hyperlinkId) == expectedLinks)
        #expect(store.recordCells(at: 0)?.map(\.contentIdentity) == expectedIdentities)
    }

    @Test("Clearing history resets the head record's table base")
    func clearingHistoryResetsTheHeadTableBase() {
        // Intent: after history is cleared, the first line admitted next reads its own hyperlink
        //   and identity tables.
        // Why it exists: the table base survives only as long as the head record it describes.
        //   Emptying the store leaves the next admitted line as head at offset 0, so a base the
        //   clear did not reset shifts every table read on a record that was never trimmed.
        // Scenario: ESC[3J clears the scrollback of a pane whose oldest line had been trimmed.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        store.admit(Self.perCellAttributedRow(width: 4, seed: 0, softWrapped: true))
        store.admit(Self.perCellAttributedRow(width: 4, seed: 4, softWrapped: false))
        #expect(evictOne(&store))

        store.removeAll()
        store.admit(Self.perCellAttributedRow(width: 4, seed: 200, softWrapped: false))

        #expect(store.recordCells(at: 0)?.map(\.hyperlinkId) == [201, 202, 203, 204])
        #expect(
            store.recordCells(at: 0)?.map(\.contentIdentity) == [2_400, 2_407, 2_414, 2_421]
        )
    }

    @Test("Open-tail spill indices survive both-end trims and an empty reset")
    func openTailSpillIndicesSurviveTrimsAndReset() {
        // Intent: trimming either end preserves surviving spill indices, and resetting an evicted
        //   single-record store leaves no payload visible to its replacement.
        // Why it exists: head trims deliberately keep original spill indices while tail trims
        //   remove a suffix, and the open scratch must follow those different rules exactly.
        // Scenario: an open four-row line loses its head, gains a spill, loses its tail, gains
        //   another spill, then is evicted to empty before unrelated content is admitted.
        func row(_ scalar: Unicode.Scalar) -> Terminal.GridRow {
            var row = Terminal.GridRow(cells: [Terminal.GridCell(kind: .narrow)])
            row.place(
                row.cells[0],
                scalars: TerminalScalars([scalar, Unicode.Scalar(0x0301)!]),
                at: 0
            )
            row.isSoftWrapped = true
            return row
        }
        func scalars(_ store: Terminal.LogicalLineStore) -> [Unicode.Scalar] {
            (0..<store.recordCount).flatMap { store.recordScalars(at: $0) ?? [] }
                .compactMap(\.first)
        }

        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 1)
        for scalar: Unicode.Scalar in ["a", "b", "c"] { store.admit(row(scalar)) }
        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        store.admit(row("d"))
        #expect(scalars(store) == ["b", "c", "d"])

        _ = store.truncateTail(displayRows: 1)
        store.admit(row("e"))
        #expect(scalars(store) == ["b", "c", "e"])

        while store.evictOneDisplayRow() {}
        store.admit(row("z"))
        #expect(scalars(store) == ["z"])
        #expect(store.chargedBytes == store.census.chargedBytes)
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
            spillBase: Unicode.Scalar = Unicode.Scalar(0x1F600)!,
            mutating change: (_ column: Int, _ cell: inout Terminal.GridCell) -> Void = { _, _ in }
        ) -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 6)
            var cells: [Terminal.GridCell] = []
            for column in 0..<6 {
                var cell = Self.narrow(Unicode.Scalar(UInt32(97 + column))!)
                cell.contentIdentity = Terminal.ContentIdentity(500 + column)
                if column == 4 { cell.hyperlinkId = 7 }
                change(column, &cell)
                cells.append(cell)
            }
            var row = Terminal.GridRow(cells: cells)
            row.place(
                row.cells[2],
                scalars: TerminalScalars([spillBase, Unicode.Scalar(0xFE0F)!]),
                at: 2
            )
            row.isSoftWrapped = true
            store.admit(row)
            store.admit(Self.shortRow(width: 6, count: 3, seed: 40))
            return store
        }

        #expect(store() == store())
        #expect(store() != store { column, cell in
            if column == 5 {
                cell.word = Terminal.CellWord(kind: cell.kind, styleId: cell.styleId, scalar: "z")
            }
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
        #expect(store() != store(spillBase: Unicode.Scalar(0x1F601)!))

        var openLeft = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 1)
        var openRight = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 1)
        var leftRow = Terminal.GridRow(cells: [Terminal.GridCell(kind: .narrow)])
        leftRow.place(
            leftRow.cells[0],
            scalars: TerminalScalars([Unicode.Scalar(97)!, Unicode.Scalar(0x0301)!]),
            at: 0
        )
        leftRow.isSoftWrapped = true
        var rightRow = leftRow
        openLeft.admit(leftRow)
        openRight.admit(rightRow)
        #expect(openLeft == openRight)
        rightRow.place(
            rightRow.cells[0],
            scalars: TerminalScalars([Unicode.Scalar(98)!, Unicode.Scalar(0x0301)!]),
            at: 0
        )
        openRight = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 1)
        openRight.admit(rightRow)
        #expect(openLeft != openRight)
    }

    @Test("Equality sees hyperlink and identity differences while the tail is open")
    func equalitySeesOpenTailTables() {
        func store(
            hyperlinkId: Terminal.HyperlinkId,
            identityBase: Terminal.ContentIdentity
        ) -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
            store.admit(Self.attributedRow(
                width: 4,
                seed: 0,
                softWrapped: true,
                hyperlinkId: hyperlinkId,
                identity: { identityBase + Terminal.ContentIdentity($0) }
            ))
            return store
        }

        #expect(store(hyperlinkId: 7, identityBase: 100) == store(hyperlinkId: 7, identityBase: 100))
        #expect(store(hyperlinkId: 7, identityBase: 100) != store(hyperlinkId: 9, identityBase: 100))
        #expect(store(hyperlinkId: 7, identityBase: 100) != store(hyperlinkId: 7, identityBase: 900))
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

    @Test("Side tables preserve entries past their sparse-count field")
    func sideTablesPreserveEntriesPastSparseCountField() throws {
        // Intent: a whole line longer than 65,535 cells preserves every hyperlink and identity.
        // Why it exists: both sparse table counts are 16 bits, so overflow must select the
        //   per-cell encoding instead of truncating the table or splitting the line.
        // Scenario: every cell has a hyperlink and a repeated identity, which makes both sparse
        //   tables exceed their count field before the line closes and reopens.
        let width = 256
        let cellCount = 65_536
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 24, width: width)
        for rowIndex in 0..<(cellCount / width) {
            let cells = (0..<width).map { column -> Terminal.GridCell in
                let offset = rowIndex * width + column
                return Self.narrow(
                    Unicode.Scalar(UInt32(97 + offset % 26))!,
                    hyperlinkId: Terminal.HyperlinkId(offset % 65_534 + 1),
                    contentIdentity: 77
                )
            }
            var row = Terminal.GridRow(cells: cells)
            row.isSoftWrapped = true
            store.admit(row)
        }
        store.closeOpenRecord()

        func assertTables(_ label: Comment, trimmed: Int = 0) throws {
            let cells = try #require(store.recordCells(at: 0), label)
            #expect(cells.count == cellCount - trimmed, label)
            for (index, cell) in cells.enumerated() {
                let offset = index + trimmed
                #expect(
                    cell.hyperlinkId == Terminal.HyperlinkId(offset % 65_534 + 1),
                    label
                )
                #expect(cell.contentIdentity == 77, label)
            }
        }

        try assertTables("closed")
        // Three display rows off the head. The tables stay where the close wrote them and keep
        // their original keys, so every read past this point goes through the base the trim
        // advanced -- which is the only thing standing between a per-cell table and the wrong
        // cell's hyperlink.
        for _ in 0..<3 { #expect(evictOne(&store)) }
        try assertTables("after a head trim", trimmed: 3 * width)
        store.reopenTailRecord()
        try assertTables("reopened after a head trim", trimmed: 3 * width)
    }

    @Test("A beyond-arena open line keeps every retained indexed payload")
    func beyondArenaOpenLineKeepsRetainedPayloads() throws {
        // Intent: repeated head trims of the sole open record preserve every retained spill,
        //   hyperlink, and content identity through close and reopen.
        // Why it exists: all three payload spaces use a head-relative base. A stale base appears
        //   only after the same logical line has consumed more cells than the arena can hold.
        // Scenario: a spill-bearing attributed line circles a small arena several times.
        let width = 32
        let rows = 400
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: width)
        for rowIndex in 0..<rows {
            var row = Terminal.GridRow(cells: Array(
                repeating: Terminal.GridCell(kind: .narrow),
                count: width
            ))
            for column in 0..<width {
                let offset = rowIndex * width + column
                let cell = Terminal.GridCell(
                    kind: .narrow,
                    hyperlinkId: Terminal.HyperlinkId(offset % 100 + 1),
                    contentIdentity: Terminal.ContentIdentity(offset + 1)
                )
                row.place(
                    cell,
                    scalars: TerminalScalars([
                        Unicode.Scalar(UInt32(97 + offset % 26))!,
                        Unicode.Scalar(0x0301)!,
                    ]),
                    at: column
                )
            }
            row.isSoftWrapped = true
            store.admit(row)
            #expect(store.chargedBytes <= store.capacityBytes)
        }

        func assertSuffix(_ label: Comment) throws {
            let cells = try #require(store.recordCells(at: 0), label)
            let scalars = try #require(store.recordScalars(at: 0), label)
            let firstOffset = rows * width - cells.count
            for index in cells.indices {
                let offset = firstOffset + index
                #expect(cells[index].hyperlinkId == Terminal.HyperlinkId(offset % 100 + 1), label)
                #expect(cells[index].contentIdentity == Terminal.ContentIdentity(offset + 1), label)
                #expect(scalars[index].count == 2, label)
            }
        }

        try assertSuffix("open")
        store.closeOpenRecord()
        try assertSuffix("closed")
        store.reopenTailRecord()
        try assertSuffix("reopened")
    }

    @Test("Trimming a beyond-arena open line's head costs the row, not the line")
    func openLineHeadTrimWorkIsIndependentOfRetainedSpills() {
        // Intent: admitting one more row into a logical line longer than the arena walks the
        //   spill payloads that leave, not the ones that stay.
        // Why it exists: the trim recomputed the open line's spill charge from every surviving
        //   payload, so one admitted row cost O(retained) and the line as a whole was
        //   quadratic. A deeper arena must not make one row dearer.
        func spillRow(_ rowIndex: Int, width: Int) -> Terminal.GridRow {
            var row = Terminal.GridRow(cells: Array(
                repeating: Terminal.GridCell(kind: .narrow),
                count: width
            ))
            for column in 0..<width {
                row.place(
                    Terminal.GridCell(kind: .narrow),
                    scalars: TerminalScalars([
                        Unicode.Scalar(UInt32(97 + (rowIndex * width + column) % 26))!,
                        Unicode.Scalar(0x0301)!,
                    ]),
                    at: column
                )
            }
            row.isSoftWrapped = true
            return row
        }
        func work(budgetBytes: Int) -> (spilled: Int, retained: Int) {
            let width = 32
            var store = Terminal.LogicalLineStore(budgetBytes: budgetBytes, width: width)
            for rowIndex in 0..<400 {
                store.admit(spillRow(rowIndex, width: width))
            }
            let retained = store.recordSummary(at: 0)?.cellCount ?? 0
            let spilled = Instrument.openSpillChargeWork.measure {
                store.admit(spillRow(400, width: width))
            }
            return (spilled, retained)
        }

        let shallow = work(budgetBytes: 1 << 14)
        let deep = work(budgetBytes: 1 << 16)

        #expect(shallow.spilled > 0, "the instrument must stay live on the append")
        #expect(deep.retained > shallow.retained * 2, "the two arenas must retain different depths")
        #expect(deep.spilled == shallow.spilled)
    }

    @Test("Evicting a beyond-arena open line removes exactly one display row per step")
    func evictingABeyondArenaOpenLineRemovesOneRowPerStep() {
        // Intent: `31/PO4`. Every eviction step against a logical line longer than the arena
        //   removes one display row and makes progress, and the maintained total agrees with an
        //   arena recount after each one -- down to the step that drops the record.
        // Why it exists: the line is one record that is both the retained head and the open
        //   tail, so every step trims inside the record the write path is still appending to.
        //   A step that trimmed two rows, or none, would show as an anchor that jumps or a
        //   pane that stops evicting.
        let width = 32
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: width)
        for row in 0..<400 {
            store.admit(Self.filledRow(width: width, seed: row, softWrapped: true))
        }
        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)?.isOpen == true)
        #expect(store.grandDisplayRowTotal > 1, "the line must still hold several rows")

        var steps = 0
        while store.grandDisplayRowTotal > 0 {
            let before = store.grandDisplayRowTotal
            #expect(evictOne(&store))
            #expect(store.grandDisplayRowTotal == before - 1, "step \(steps)")
            #expect(
                store.grandDisplayRowTotal == store.independentDisplayRowRecount(),
                "step \(steps)"
            )
            steps += 1
        }
        #expect(store.recordCount == 0)
        #expect(evictOne(&store) == false)
    }

    @Test("One eviction drops a sole open record shorter than a display row")
    func aSoleOpenRecordShorterThanARowIsDropped() {
        // Intent: `31/PO4`'s floor. A store whose only record is open and holds fewer cells
        //   than one display row is emptied by a single eviction step rather than trimmed to
        //   nothing.
        // Why it exists: the trim path rewrites a header forward over the cells it drops, which
        //   would leave a zero-cell record charging its header forever and an eviction loop that
        //   never makes progress.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        store.admit(Self.shortRow(width: 8, count: 5, seed: 0))
        store.reopenTailRecord()
        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)?.isOpen == true)
        #expect(store.recordSummary(at: 0)?.cellCount == 5)
        #expect(store.grandDisplayRowTotal == 1)

        #expect(evictOne(&store))

        #expect(store.recordCount == 0)
        #expect(store.grandDisplayRowTotal == 0)
        #expect(store.census.arenaBytesInUse == 0)
    }

    @Test("A coordinate on a beyond-arena line names the same cell through trims and widths")
    func recordCoordinateOnABeyondArenaLineResolvesTheSameCell() throws {
        // Intent: `31/PO6`. A `RecordTextPosition` taken on a cell of a logical line longer than
        //   the arena resolves to that same cell after the line has been closed, after twenty
        //   further head trims into it, and at three widths.
        // Why it exists: the coordinate is (record identity, original cell offset), and the
        //   original offset is only meaningful against the head-relative base a trim advances.
        //   A stale base moves a stored search match onto other text rather than failing.
        //   Reopening is the one operation that retires the coordinate instead of carrying it:
        //   the record's text becomes mutable again, and `TerminalSearch` reads the renewed
        //   identity as a regressed tail and drops the matches it had indexed into that record.
        //   Resolving to nothing is the contract there, so the last leg asserts exactly that.
        let width = 32
        // One distinct scalar per cell of the whole line, so resolving to a neighbouring cell
        // reads as a different character rather than as the same repeating letter.
        func row(_ index: Int) -> Terminal.GridRow {
            var row = Terminal.GridRow(cells: (0..<width).map { column in
                Self.narrow(Unicode.Scalar(UInt32(0x4E00 + index * width + column))!)
            })
            row.isSoftWrapped = true
            return row
        }
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: width)
        for index in 0..<400 { store.admit(row(index)) }
        store.closeOpenRecord()
        #expect(store.recordCount == 1)
        #expect(store.recordSummary(at: 0)?.startsMidLine == true, "the line lost its own head")

        let cellCount = try #require(store.recordSummary(at: 0)).cellCount
        let coordinate = try #require(
            store.recordTextPosition(recordIndex: 0, cellOffset: cellCount - 3)
        )
        let expected = try #require(Self.scalar(in: store, at: coordinate))

        func check(_ label: Comment) {
            #expect(Self.scalar(in: store, at: coordinate) == expected, label)
        }
        check("closed")

        for step in 0..<20 {
            #expect(evictOne(&store))
            check("after head trim \(step)")
        }
        for width in [13, 45, 32] {
            _ = store.setWidth(width)
            check("at width \(width)")
        }

        store.reopenTailRecord()
        #expect(
            store.position(of: coordinate) == nil,
            "a reopen retires every coordinate into the record it reopened"
        )
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

    @Test("A trimmed per-cell table grows across a chunk seam without losing entries")
    func trimmedPerCellTableGrowsAcrossChunkSeam() throws {
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

        #expect(store.recordCount == 1)
        var first = try #require(store.recordCells(at: 0))
        #expect(first.allSatisfy { $0.hyperlinkId == 7 })
        #expect(first.map(\.contentIdentity) == expected(4..<20))

        store.admit(attributed(5, softWrapped: false))
        store.admit(Self.shortRow(width: 4, count: 3, seed: 90))

        first = try #require(store.recordCells(at: 0))
        let following = try #require(store.recordCells(at: 1))
        #expect(first.allSatisfy { $0.hyperlinkId == 7 })
        #expect(first.map(\.contentIdentity) == expected(4..<24))
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
        #expect(handedBack.map { row in row.cells.indices.map { row.scalars(at: $0).first } }
            == Array(before.suffix(2)))
    }

    @Test("Tail truncation locates once and carries wide boundaries")
    func tailTruncationCarriesWideBoundaries() throws {
        // Intent: one locate supplies every cursor needed to read and cut a long tail.
        // Why it exists: locating and folding each pulled row independently makes height growth
        //   scale with both the row count and the length of the wide record it reaches into.
        // Scenario: the pull starts inside a wide record and crosses several folded rows.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 3)
        var wideRow = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Self.narrow("a"),
        ])
        wideRow.isSoftWrapped = true
        for _ in 0..<4 { store.admit(wideRow) }
        store.admit(Self.shortRow(width: 3, count: 2, seed: 20))
        let wideCellCount = try #require(store.recordSummary(at: 0)).cellCount
        let totalBefore = store.grandDisplayRowTotal
        let expected = (totalBefore - 3..<totalBefore).compactMap(store.paintedDisplayRow(at:))

        var handedBack: [Terminal.GridRow] = []
        let locates = Instrument.displayRowLocate.measure {
            let boundaryWork = Instrument.rowBoundaryCellWalk.measure {
                handedBack = store.truncateTail(displayRows: 3)
            }
            #expect(boundaryWork == wideCellCount)
        }

        #expect(locates >= 1)
        #expect(locates == 1)
        #expect(handedBack == expected)
        #expect(store.grandDisplayRowTotal == totalBefore - handedBack.count)
    }

    @Test(
        "A wide-record tail pull folds its boundaries once",
        arguments: 1...4
    )
    func wideRecordTailPullFoldsOnce(displayRows: Int) throws {
        // Intent: every pull length pays one full boundary walk through its wide tail record.
        // Why it exists: a repeated last-row fold turns an N-row pull into N scans from cell zero.
        // Scenario: each case pulls a different suffix from the same four-row wide record shape.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        var row = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Terminal.GridCell(scalars: TerminalScalars("世"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
        ])
        row.isSoftWrapped = true
        for _ in 0..<4 { store.admit(row) }
        let cellCount = try #require(store.recordSummary(at: 0)).cellCount

        let work = Instrument.rowBoundaryCellWalk.measure {
            _ = store.truncateTail(displayRows: displayRows)
        }

        #expect(work == cellCount)
    }

    @Test("A multi-row wide tail round-trips without changing charge")
    func multiRowWideTailRoundTrips() {
        // Intent: truncating and readmitting several rows preserves retained content and charge.
        // Why it exists: cursor-based cuts cross record ownership and side-table seams that a
        //   one-row round trip does not exercise.
        // Scenario: three rows leave a long wide tail and return in their original order.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        var row = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Self.narrow("a"),
            Self.narrow("b"),
        ])
        row.isSoftWrapped = true
        for _ in 0..<4 { store.admit(row) }
        for _ in 0..<3 { store.admit(row) }
        store.admit(Self.shortRow(width: 4, count: 2, seed: 30))
        let rowsBefore = Self.foldedScalars(store)
        let chargeBefore = store.census.arenaBytesInUse
        let totalBefore = store.grandDisplayRowTotal

        let handedBack = store.truncateTail(displayRows: 3)
        for handedBackRow in handedBack { store.admit(handedBackRow) }

        #expect(Self.foldedScalars(store) == rowsBefore)
        #expect(store.census.arenaBytesInUse == chargeBefore)
        #expect(store.grandDisplayRowTotal == totalBefore)
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

    @Test("Truncating a long record keeps its hyperlink and identity tables readable")
    func truncatingLongRecordKeepsItsSideTablesReadable() {
        // Intent: when truncation cuts into a long record, the surviving cells still read back
        //   their hyperlink ids and content identities.
        // Why it exists: a closed record's side tables are addressed off
        //   `offset + headerAndCells(cellCount)`, and `cutTail` rewrites `cellCount`.
        //   Reopening must move the tables back into scratch before shrinking `cellCount`.
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
        store.admit(Self.filledRow(width: 8, seed: 40, softWrapped: true))
        store.admit(Self.shortRow(width: 8, count: 4, seed: 50))
        #expect(store.recordCount == 1)
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

    // MARK: - Tail truncation across the arena wrap

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

    @Test("Dropping the tail record across the arena wrap preserves charge")
    func droppingTheTailAcrossArenaWrapPreservesCharge() {
        // Intent: a truncation that rewinds the write cursor past the arena wrap preserves
        //   charge, so a store that truncates and readmits the same rows retains exactly what
        //   a store that never truncated retains.
        // Why it exists: the arena charge used to be a maintained field, and `dropTailRecord`
        //   subtracted only the dropped record's own bytes, so any arena byte the rewind
        //   skipped stayed charged forever -- and resize and reflow, which both truncate the
        //   tail, then made history charge more than it held and evict early. The charge is the
        //   ring span now, and this is what keeps it that way.
        // Scenario: hard-ended eight-cell lines at width 16 in a budget the arena wraps inside,
        //   truncated two display rows at a time with the rows handed straight back.
        //
        // The line count places the tail one record past the wrap, so the rewind crosses it.
        // The 40 rounds are what push a per-round over-charge past an eviction boundary: one
        // round's is smaller than one record and changes nothing observable.
        let budget = 1 << 14
        let cellsPerLine = 8
        var control = Terminal.LogicalLineStore(budgetBytes: budget, width: 16)
        for line in 0..<213 {
            control.admit(Self.shortRow(width: 16, count: cellsPerLine, seed: line))
        }

        // The ring has wrapped here. Every retained record costs one header plus eight cells.
        let recordBytes = 8 + cellsPerLine * 8
        #expect(control.census.arenaBytesInUse == recordBytes * control.recordCount)

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

    @Test("Reopening a wrapped tail preserves charge")
    func reopeningAWrappedTailPreservesCharge() {
        // Intent: reopening a closed record whose cells cross the arena wrap preserves charge.
        // Why it exists: `reopenTailRecordForTruncation` rewinds the cursor to the reopened
        //   record's end, and the maintained charge subtracted only the record's flushed side
        //   tables -- so every arena byte past that end leaked on every truncation landing here,
        //   exactly as it did on the drop path.
        // Scenario: one never-terminated soft-wrapped line at width 12 crosses the arena wrap
        //   and is truncated three display rows at a time.
        //
        // The line count and the row count together land the third removal inside a record that
        // is reopened and cut rather than dropped, and the 40 rounds accumulate what one round
        // alone would not show.
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
        #expect(pulled.cells.count == 14)
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

        #expect(pulled.cells.isEmpty)
        #expect(store.recordSummary(at: 0)!.cellCount == 30)
    }

    @Test("A width change counts every record-start row-boundary fold")
    func widthChangeCountsEveryRecordStartFold() throws {
        // Intent: the tail-range read and the index rebuild each report their full-record walk.
        // Why it exists: an unrecorded tail-range fold makes the instrument report zero work for
        //   a real cell traversal and can hide a repeated wide-record scan.
        // Scenario: an open wide record ends on a complete row, so resize reads but does not cut it.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        var row = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Terminal.GridCell(scalars: TerminalScalars("世"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
        ])
        row.isSoftWrapped = true
        for _ in 0..<3 { store.admit(row) }
        let cellCount = try #require(store.recordSummary(at: 0)).cellCount

        let work = Instrument.rowBoundaryCellWalk.measure {
            _ = store.setWidth(4)
        }

        #expect(work == cellCount * 2)
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
            let row = store.gridRow(at: position)
            walked.append(row.cells.indices.map { row.scalars(at: $0).first })
            cursor = store.advance(position)
        }

        #expect(walked == Array(Self.foldedScalars(store).dropFirst(2)))
        #expect(store.locate(displayRow: store.grandDisplayRowTotal) == nil)
        #expect(store.locate(displayRow: -1) == nil)
    }

    @Test("A wide-record cursor pays one first-cell fold across a forward traversal")
    func wideRecordCursorCarriesItsFoldBoundary() throws {
        // Intent: locating any row and advancing through the rest of one wide record traverses
        //   that record from cell zero exactly once.
        // Why it exists: restarting the fold in each row reader or in `advance` restores the
        //   O(rows * cells) frame cost this cursor exists to remove.
        // Scenario: a viewport starts inside one long CJK-shaped retained record.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 8)
        let wideRow = Terminal.GridRow(cells: (0..<4).flatMap { pair in
            [
                Terminal.GridCell(
                    scalars: TerminalScalars(Unicode.Scalar(0x4E00 + pair)!),
                    kind: .wideHead
                ),
                Terminal.GridCell(kind: .wideTail),
            ]
        })
        for _ in 0..<40 {
            var continued = wideRow
            continued.isSoftWrapped = true
            store.admit(continued)
        }
        store.admit(Self.shortRow(width: 8, count: 1, seed: 0))
        let cellCount = try #require(store.recordSummary(at: 0)).cellCount

        var streamed: [Terminal.GridRow] = []
        let work = Instrument.rowBoundaryCellWalk.measure {
            var cursor = store.locate(displayRow: 3)
            while let current = cursor {
                streamed.append(store.paintedRow(at: current))
                cursor = store.advance(current)
            }
        }
        let indexed = (3..<store.grandDisplayRowTotal).compactMap(store.paintedDisplayRow(at:))

        #expect(work == cellCount)
        #expect(streamed == indexed)
    }

    @Test("A cursor from before a head trim cannot read past the shortened record")
    func staleCursorRangeIsBoundedAfterHeadTrim() throws {
        // Intent: a cursor whose cell range no longer fits after head eviction reads no cells.
        // Why it exists: cursors are transient but remain value-safe across mutation, so stale
        //   width-derived offsets must not reach beyond the retained record's current cells.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 8)
        for seed in 0..<3 {
            store.admit(Self.filledRow(width: 8, seed: seed, softWrapped: true))
        }
        store.admit(Self.shortRow(width: 8, count: 3, seed: 3))
        let stale = try #require(store.locate(displayRow: 2))

        #expect(evictOne(&store))
        #expect(store.gridRow(at: stale).cells.isEmpty)
    }

    @Test("Whole-history wide-row materialization advances from carried boundaries")
    func wholeHistoryWideMaterializationIsLinear() throws {
        // Intent: whole-history materialization keeps its row count, locates once, and advances
        //   from each carried boundary after folding the selected wide record once.
        // Why it exists: Select All, search and export use this path and need the same traversal
        //   bound as frame painting.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 18, width: 7)
        var row = Terminal.GridRow(cells: [
            Terminal.GridCell(scalars: TerminalScalars("界"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
            Self.narrow("a"), Self.narrow("b"), Self.narrow("c"),
            Terminal.GridCell(scalars: TerminalScalars("世"), kind: .wideHead),
            Terminal.GridCell(kind: .wideTail),
        ])
        row.isSoftWrapped = true
        for _ in 0..<30 { store.admit(row) }
        store.admit(Self.shortRow(width: 7, count: 1, seed: 0))
        let recordCellCount = try #require(store.recordSummary(at: 0)).cellCount

        var rows: [Terminal.GridRow] = []
        let locates = Instrument.displayRowLocate.measure {
            let materialized = Instrument.retainedRowMaterialization.measure {
                let work = Instrument.rowBoundaryCellWalk.measure {
                    rows = store.allPaintedDisplayRows()
                }
                #expect(work > 0)
                #expect(work == recordCellCount)
            }
            #expect(materialized == store.grandDisplayRowTotal)
        }

        #expect(locates == 1)
        #expect(rows.count == store.grandDisplayRowTotal)
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

    @Test("a published value copies both chunks touched by a straddling row")
    func publishedValueThenStraddlingAdmissionCopiesOnlyTouchedChunks() {
        // Intent: a row that crosses a chunk boundary copies both chunks it writes and leaves
        //   every other materialized chunk shared with the published value.
        // Why it exists: the whole-record layout permits straddling, while D1 still makes the
        //   chunk the copy-on-write unit rather than copying the complete arena.
        // Scenario: repeated full rows advance the cursor until one admission crosses a chunk.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)
        var copiedAtBoundary = 0
        for seed in 0..<300 {
            let published = store
            let before = published.chunkStorageIdentitiesForTesting()
            store.admit(Self.filledRow(width: 80, seed: seed, softWrapped: false))
            let after = store.chunkStorageIdentitiesForTesting()
            let changed = zip(before, after).count { $0.0 != $0.1 }
                + max(0, after.count - before.count)
            if changed >= 2 {
                copiedAtBoundary = changed
                break
            }
        }

        #expect(copiedAtBoundary >= 2, "the stimulus must cross a chunk boundary")
        #expect(
            copiedAtBoundary * store.chunkCapacityBytesForTesting <= store.capacityBytes / 4
        )
    }

    @Test("a zero-cell record whose header ends a chunk still folds and paints")
    func zeroCellRecordAtAChunkEndStillPaints() {
        // Intent: a blank logical line whose 8-byte header lands in the last word of a backing
        //   chunk reads through both borrowing readers like any other record.
        // Why it exists: the frame path derives a row's chunk from its first cell's byte. A
        //   zero-cell record has no cell, so that byte is the first byte of the *next* chunk,
        //   which has not materialized -- backing materializes as the write cursor reaches it.
        // Scenario: a program prints only newlines while the pane renders retained history. At
        //   the production budget the read trapped on blank record 65,533.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 17, width: 80)
        for seed in 0..<8_400 {
            store.admit(Self.shortRow(width: 80, count: 0, seed: seed))
            guard let cursor = store.locate(displayRow: store.grandDisplayRowTotal - 1) else {
                Issue.record("the record just admitted must locate")
                return
            }
            var kinds = 0
            store.forEachKind(at: cursor) { _, _ in kinds += 1 }
            var painted = -1
            store.withPaintedCells(at: cursor) { count, _, _ in painted = count }
            #expect(kinds == 0)
            #expect(painted == 0)
        }
        #expect(store.grandDisplayRowTotal == store.independentDisplayRowRecount())
    }

    @Test("history cycles the ring across chunk seams and reads back exactly")
    func ringCyclesAcrossChunkSeamsAndKeepsItsRetainedSuffix() {
        // Intent: at a budget spanning several backing chunks, feeding many full cycles of the
        //   ring leaves every reader returning the retained suffix cell for cell, and the charge
        //   inside capacity throughout.
        // Why it exists: `31/PO12` states this for the arena wrap, and `research/31/D5` adds
        //   chunk boundaries that must remain invisible to every reader.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 20, width: 80)
        var admitted: [[Unicode.Scalar]] = []
        var seed = 0
        for line in 0..<3_000 {
            var scalars: [Unicode.Scalar] = []
            for _ in 0..<(line % 7) {
                let row = Self.filledRow(width: 80, seed: seed, softWrapped: true)
                scalars.append(contentsOf: row.cells.compactMap { $0.word.inlineScalar })
                store.admit(row)
                seed += 1
            }
            let count = 1 + line % 79
            let last = Self.shortRow(width: 80, count: count, seed: seed)
            scalars.append(contentsOf: last.cells.prefix(count).compactMap { $0.word.inlineScalar })
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
        return row.scalars(at: resolved.column).first
    }

    /// Whether `candidate` is a trailing subsequence of `whole`.
    private static func isSuffix(_ candidate: [Unicode.Scalar], of whole: [Unicode.Scalar]) -> Bool {
        candidate.count <= whole.count && Array(whole.suffix(candidate.count)) == candidate
    }

    /// Reads the store back as logical lines.
    private static func readLogicalLines(_ store: Terminal.LogicalLineStore) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        for index in 0..<store.recordCount {
            let summary = store.recordSummary(at: index)!
            let scalars = store.recordScalars(at: index)!.compactMap(\.first)
            if summary.startsMidLine, lines.isEmpty == false {
                lines[lines.count - 1].append(contentsOf: scalars)
            } else {
                lines.append(scalars)
            }
        }
        return lines
    }
}
