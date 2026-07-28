// Primary-screen resize proofs for reflow, cursor attachment, and viewport transfer.
import Testing

@testable import TerminalCore

struct TerminalResizeTests {
    @Test("same-size and invalid resize requests are bit-identical no-ops")
    func invalidAndSameSizeResizeAreNoOps() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcdefghijkl".utf8))
        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.geometry.cursor?.isPendingWrap == true)
        let original = terminal

        terminal.resize(columns: 4, rows: 2)
        terminal.resize(columns: 1, rows: 2)
        terminal.resize(columns: 4, rows: 0)

        #expect(terminal == original)
    }

    @Test("no-op resize preserves partial stream and open-cluster state")
    func noOpResizePreservesPendingState() throws {
        var utf8 = try #require(Terminal(columns: 4, rows: 2))
        var uninterruptedUTF8 = utf8
        utf8.feed([0xE7, 0x95])
        uninterruptedUTF8.feed([0xE7, 0x95])
        utf8.resize(columns: 4, rows: 2)
        utf8.resize(columns: 1, rows: 2)
        utf8.feed([0x8C])
        uninterruptedUTF8.feed([0x8C])
        #expect(utf8 == uninterruptedUTF8)

        var csi = try #require(Terminal(columns: 4, rows: 2))
        var uninterruptedCSI = csi
        csi.feed(Array("\u{001B}[2;".utf8))
        uninterruptedCSI.feed(Array("\u{001B}[2;".utf8))
        csi.resize(columns: 4, rows: 2)
        csi.resize(columns: 4, rows: 0)
        csi.feed(Array("4Hq".utf8))
        uninterruptedCSI.feed(Array("4Hq".utf8))
        #expect(csi == uninterruptedCSI)

        var cluster = try #require(Terminal(columns: 4, rows: 2))
        var uninterruptedCluster = cluster
        cluster.feed(Array("a".utf8))
        uninterruptedCluster.feed(Array("a".utf8))
        cluster.resize(columns: 4, rows: 2)
        cluster.resize(columns: 1, rows: 2)
        cluster.feed(Array("\u{0301}".utf8))
        uninterruptedCluster.feed(Array("\u{0301}".utf8))
        #expect(cluster == uninterruptedCluster)
    }

    @Test("width reflow preserves logical text across narrow, wide, emoji, and spaces")
    func widthWalkConservesFullHistory() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 4))
        terminal.feed(Array("espan\u{0303}ol \u{754C} \u{1F469}\u{200D}\u{1F4BB}  fin\r\nlinea dos".utf8))
        let expected = terminal.fullHistoryText

        for width in Array(stride(from: 11, through: 2, by: -1)) + Array(3...12) {
            terminal.resize(columns: width, rows: 4)
            #expect(terminal.fullHistoryText == expected)
            expectValidGrid(terminal)
        }
    }

    @Test("height walks and combined resize sequences conserve full-history text")
    func heightAndCombinedWalksConserveFullHistory() throws {
        var terminal = try #require(Terminal(columns: 9, rows: 4))
        terminal.feed(Array("uno \u{754C}\r\ndos  \r\n\u{1F642} tres\r\ncuatro\r\ncinco".utf8))
        let expected = terminal.fullHistoryText

        for height in [3, 2, 1, 2, 5, 3, 6, 4] {
            terminal.resize(columns: terminal.geometry.columns, rows: height)
            #expect(terminal.fullHistoryText == expected)
            expectValidGrid(terminal)
        }
        for dimensions in [(7, 3), (3, 6), (2, 2), (11, 5), (9, 4)] {
            terminal.resize(columns: dimensions.0, rows: dimensions.1)
            #expect(terminal.fullHistoryText == expected)
            expectValidGrid(terminal)
        }
    }

    @Test("combined resize is exactly height then width")
    func combinedResizeUsesCanonicalOrder() throws {
        var combined = try #require(Terminal(columns: 6, rows: 3))
        combined.feed(Array("abcdefghi\r\nsecond".utf8))
        var sequential = combined

        combined.resize(columns: 4, rows: 2)
        sequential.resize(columns: 6, rows: 2)
        sequential.resize(columns: 4, rows: 2)

        #expect(combined == sequential)
    }

    @Test("height shrink trims filler then retains displaced top rows")
    func heightShrinkTransfersRows() throws {
        var filler = try #require(Terminal(columns: 4, rows: 3))
        filler.feed(Array("ab".utf8))
        filler.moveCursor(row: 0, column: 2)
        filler.resize(columns: 4, rows: 1)
        #expect(filler.scrollbackRowCount == 0)
        #expect(filler.screenText == "ab  ")

        var content = try #require(Terminal(columns: 4, rows: 3))
        content.feed(Array("a\r\nb\r\nc".utf8))
        content.resize(columns: 4, rows: 2)
        #expect(content.scrollbackRowCount == 1)
        #expect(content.screenText == "b   \nc   ")
        #expect(content.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
    }

    @Test("height growth pulls history only for a bottom-row cursor")
    func heightGrowthEligibility() throws {
        var bottom = try #require(Terminal(columns: 4, rows: 2))
        bottom.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        #expect(bottom.scrollbackRowCount == 2)
        bottom.resize(columns: 4, rows: 4)
        #expect(bottom.scrollbackRowCount == 0)
        #expect(bottom.screenText == "a   \nb   \nc   \nd   ")
        #expect(bottom.geometry.cursor?.row == 3)

        var aboveBottom = try #require(Terminal(columns: 4, rows: 2))
        aboveBottom.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        aboveBottom.moveCursor(row: 0, column: 1)
        aboveBottom.resize(columns: 4, rows: 4)
        #expect(aboveBottom.scrollbackRowCount == 2)
        #expect(aboveBottom.screenText == "c   \nd   \n    \n    ")
        #expect(aboveBottom.geometry.cursor?.row == 0)
    }

    @Test("height transfer preserves wrap flags and does not accrete filler blanks")
    func heightTransferPreservesFlagsAndFillerIdentity() throws {
        var wrapped = try #require(Terminal(columns: 4, rows: 2))
        wrapped.feed(Array("abcdefghi".utf8))
        #expect(wrapped.scrollbackRow(at: 0)?.isSoftWrapped == true)
        wrapped.resize(columns: 4, rows: 3)
        #expect(wrapped.scrollbackRowCount == 0)
        #expect(wrapped.geometry.rows.map(\.isSoftWrapped) == [true, true, false])

        var filler = try #require(Terminal(columns: 4, rows: 1))
        filler.feed(Array("x".utf8))
        let history = filler.fullHistoryText
        filler.resize(columns: 4, rows: 4)
        filler.resize(columns: 4, rows: 1)
        #expect(filler.scrollbackRowCount == 0)
        #expect(filler.fullHistoryText == history)

        var blankHistory = try #require(Terminal(columns: 4, rows: 3))
        blankHistory.moveCursor(row: 2, column: 0)
        blankHistory.resize(columns: 4, rows: 1)
        #expect(blankHistory.scrollbackRowCount == 2)
        #expect(blankHistory.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(blankHistory.scrollbackRow(at: 1)?.isSoftWrapped == false)
    }

    @Test("height shrink clamps a displaced cursor without losing its column or wrap")
    func heightShrinkClampsDisplacedCursor() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcd\r\nefgh\r\nijkl".utf8))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("Z".utf8))
        #expect(terminal.geometry.cursor?.isPendingWrap == true)

        terminal.resize(columns: 4, rows: 1)

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))
        #expect(terminal.scrollbackRowCount == 2)
    }

    @Test("cell anchors follow narrow, wide-tail, spacer, and interior padding cells")
    func cellAnchorsFollowReflowedCells() throws {
        var narrow = try #require(Terminal(columns: 6, rows: 3))
        narrow.feed(Array("abcdef".utf8))
        narrow.moveCursor(row: 0, column: 4)
        narrow.resize(columns: 4, rows: 3)
        #expect(narrow.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))

        var tail = try #require(Terminal(columns: 6, rows: 3))
        tail.feed(Array("ab\u{754C}c".utf8))
        tail.moveCursor(row: 0, column: 3)
        tail.resize(columns: 3, rows: 3)
        #expect(tail.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))

        var head = try #require(Terminal(columns: 6, rows: 3))
        head.feed(Array("ab\u{754C}c".utf8))
        head.moveCursor(row: 0, column: 2)
        head.resize(columns: 3, rows: 3)
        #expect(head.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))

        var spacer = try #require(Terminal(columns: 3, rows: 3))
        spacer.feed(Array("ab\u{754C}".utf8))
        spacer.moveCursor(row: 0, column: 2)
        spacer.resize(columns: 4, rows: 3)
        #expect(spacer.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))

        var padding = try #require(Terminal(columns: 5, rows: 3))
        padding.feed(Array("a".utf8))
        padding.moveCursor(row: 0, column: 3)
        padding.feed(Array("b".utf8))
        padding.moveCursor(row: 0, column: 1)
        padding.resize(columns: 3, rows: 3)
        #expect(padding.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))

        var softPadding = try #require(Terminal(columns: 4, rows: 3))
        softPadding.moveCursor(row: 0, column: 2)
        softPadding.feed(Array("abc".utf8))
        softPadding.moveCursor(row: 0, column: 0)
        softPadding.resize(columns: 3, rows: 3)
        #expect(softPadding.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))

        var writtenSpace = try #require(Terminal(columns: 4, rows: 2))
        writtenSpace.feed(Array("a b".utf8))
        writtenSpace.moveCursor(row: 0, column: 1)
        writtenSpace.resize(columns: 2, rows: 2)
        #expect(writtenSpace.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
        #expect(writtenSpace.cell(row: 0, column: 1)?.kind == .narrow)
    }

    @Test("trailing padding anchors preserve distance and clamp without creating rows")
    func trailingPaddingAnchorPreservesDistance() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("ab".utf8))
        terminal.moveCursor(row: 0, column: 4)

        terminal.resize(columns: 5, rows: 2)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: false))
        terminal.resize(columns: 3, rows: 2)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)

        var empty = try #require(Terminal(columns: 6, rows: 2))
        empty.moveCursor(row: 0, column: 5)
        empty.resize(columns: 3, rows: 2)
        #expect(empty.geometry.cursor?.column == 2)
    }

    @Test("pending-wrap boundary anchors become interior or remain pending at a row end")
    func boundaryAnchorFollowsReflowBoundary() throws {
        var wider = try #require(Terminal(columns: 6, rows: 3))
        wider.feed(Array("abcdef".utf8))
        wider.resize(columns: 8, rows: 3)
        #expect(wider.geometry.cursor == TerminalCursor(row: 0, column: 6, isPendingWrap: false))

        var narrower = try #require(Terminal(columns: 6, rows: 3))
        narrower.feed(Array("abcdef".utf8))
        narrower.resize(columns: 3, rows: 3)
        #expect(narrower.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: true))
    }

    @Test("width shrink uses viewport blanks before displacing content")
    func widthShrinkDoesNotSelfPush() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("abcdef".utf8))

        terminal.resize(columns: 4, rows: 3)

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.screenText == "abcd\nef  \n    ")
    }

    @Test("continuation growth above the cursor consumes its bottom-row distance")
    func widthShrinkCountsAllContinuationsAboveCursor() throws {
        // Intent: count reflow growth from every viewport line at or above
        //   the cursor when deriving its new distance from the bottom.
        // Why it exists: counting only the cursor's logical line appended an
        //   extra blank and displaced a second source row into scrollback.
        // Scenario: two full hard lines above a cursor each gain a continuation
        //   row when the viewport narrows from six columns to three.
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("abcdef\r\nghijkl\r\nm".utf8))
        #expect(terminal.geometry.cursor?.row == 2)

        terminal.resize(columns: 3, rows: 4)

        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.screenText == "def\nghi\njkl\nm  ")
        #expect(terminal.geometry.cursor?.row == 3)
    }

    @Test("post-clear shrink keeps history out and overflow shrink moves only top rows")
    func widthShrinkViewportBoundaries() throws {
        var cleared = try #require(Terminal(columns: 4, rows: 2))
        cleared.feed(Array("a\r\nb\r\nc".utf8))
        cleared.feed(Array("\u{001B}[2J".utf8))
        #expect(cleared.scrollbackRowCount == 1)
        cleared.resize(columns: 2, rows: 2)
        #expect(cleared.scrollbackRowCount == 1)
        #expect(cleared.screenText == "  \n  ")

        var overflow = try #require(Terminal(columns: 6, rows: 2))
        overflow.feed(Array("top\r\nabcdef".utf8))
        overflow.resize(columns: 3, rows: 2)
        #expect(overflow.scrollbackRowCount == 1)
        #expect(overflow.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(overflow.screenText == "abc\ndef")
    }

    @Test("odd and even widths create and remove spacer heads without splitting wide cells")
    func spacerRoundTripAcrossWidths() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("ab\u{754C}c".utf8))
        let expected = terminal.fullHistoryText

        terminal.resize(columns: 3, rows: 3)
        #expect(terminal.geometry.rows[0].cells.last?.kind == .spacerHead)
        expectValidGrid(terminal)
        terminal.resize(columns: 4, rows: 3)
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .wideHead, .wideTail,
        ])
        #expect(terminal.fullHistoryText == expected)
        expectValidGrid(terminal)

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var cluster = try #require(Terminal(columns: 6, rows: 3))
        cluster.feed(Array(("a" + family + "b").utf8))
        cluster.resize(columns: 2, rows: 3)
        #expect(cluster.geometry.rows[0].cells.last?.kind == .spacerHead)
        #expect(cluster.cell(row: 1, column: 0)?.scalars == TerminalScalars(family.unicodeScalars))
        expectValidGrid(cluster)
    }

    @Test("width growth pulls reflowed history into the viewport")
    func widthGrowthPullsHistory() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcdefgh".utf8))
        terminal.feed(Array("ij".utf8))
        #expect(terminal.scrollbackRowCount == 1)

        terminal.resize(columns: 8, rows: 2)

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.screenText == "abcdefgh\nij      ")
    }

    @Test("effective resize closes a cluster but preserves partial UTF-8 and CSI input")
    func effectiveResizeStreamSemantics() throws {
        var utf8 = try #require(Terminal(columns: 4, rows: 2))
        utf8.feed([0xE7, 0x95])
        utf8.resize(columns: 5, rows: 2)
        utf8.feed([0x8C])
        #expect(utf8.cell(row: 0, column: 0)?.scalars == ["\u{754C}".unicodeScalars.first!])

        var csi = try #require(Terminal(columns: 4, rows: 2))
        csi.feed(Array("x\u{001B}[2;".utf8))
        csi.resize(columns: 5, rows: 3)
        csi.feed(Array("5Hq".utf8))
        #expect(csi.cell(row: 1, column: 4)?.scalars == ["q".unicodeScalars.first!])

        var cluster = try #require(Terminal(columns: 4, rows: 2))
        cluster.feed(Array("a".utf8))
        cluster.resize(columns: 5, rows: 2)
        cluster.feed(Array("\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["a".unicodeScalars.first!])
    }

    @Test("interleaved random resize and input preserves a valid grid")
    func resizeFuzzMaintainsGridValidity() throws {
        let alphabet: [UInt8] = Array("ab \u{754C}\u{1F642}\r\n\u{001B}[2J".utf8)
        for seed in UInt64(1)...128 {
            var generator = Generator(state: seed)
            var terminal = try #require(Terminal(columns: 7, rows: 3))
            for _ in 0..<128 {
                if generator.next().isMultiple(of: 4) {
                    let history = terminal.fullHistoryText
                    terminal.resize(
                        columns: Int(generator.next() % 10),
                        rows: Int(generator.next() % 6)
                    )
                    #expect(terminal.fullHistoryText == history)
                } else {
                    terminal.feed([alphabet[Int(generator.next()) % alphabet.count]])
                }
                expectValidGrid(terminal)
            }
            terminal.feed([0x18, 0x7C])
            #expect(terminal.screenText.contains("|"))
        }
    }

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }
}
