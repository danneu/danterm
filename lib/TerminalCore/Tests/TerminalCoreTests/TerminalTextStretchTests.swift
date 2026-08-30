// Behavioral pins for the text stretch: one action per stretch of printable text.
//
// The stream hands the grid one action for a maximal stretch of printable text of every
// classification -- GL bytes, bulk-printable scalars, and the joiners and marks no bulk writer can
// stamp -- and the printer walks it once, segmenting it by the kind each scalar was classified at
// (`research/39/D10`). That merges what used to be one action per cluster piece into one action
// per stretch, so everything a feed pays per action is now paid once for a whole stretch.
//
// The reference for every equivalence claim here is the same bytes fed one byte per call. One byte
// keeps a GL entry to a single byte and drives every non-ASCII scalar through the resumable
// decoder's pending prefix and out of the one-step path, so the reference runs the single-scalar
// print rather than the stretch's segment writers. A scalar-at-a-time feed would not: a complete
// scalar fed from ground state is a one-scalar stretch, so both sides would take the new writer and
// a segment defect could compare equal to itself.
//
// What does *not* belong here: proofs about how much per-action bookkeeping collapsed. That is a
// count, not a behavior, and the benchmark ladder in `research/39` is what reads it.
import Testing

@testable import TerminalCore

/// Holds the equivalence between a fed stretch and the same bytes fed one byte at a time, over the
/// cluster and character-set shapes only a stretch can now carry in one action.
struct TerminalTextStretchTests {
    /// One byte stream replayed two ways on the same geometry.
    struct Scenario: Sendable, CustomStringConvertible {
        let name: String
        let columns: Int
        let rows: Int
        let input: String

        var description: String { name }
    }

    static let scenarios: [Scenario] = [
        Scenario(
            name: "a base and its combining marks",
            columns: 8, rows: 3,
            input: "a\u{0301}\u{0302}\u{0303}b\u{0301}c\r\n"
        ),
        Scenario(
            name: "a wide base and its combining marks",
            columns: 8, rows: 3,
            input: "\u{65E5}\u{0301}\u{0302}\u{672C}\u{0301}x\r\n"
        ),
        Scenario(
            name: "a ZWJ emoji sequence",
            columns: 10, rows: 3,
            input: "ab\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}cd\r\n"
        ),
        Scenario(
            name: "a variation selector that changes the width mid-cluster",
            columns: 8, rows: 3,
            input: "x\u{00A9}\u{FE0F}y\u{261D}\u{FE0F}z\r\n"
        ),
        Scenario(
            name: "a regional-indicator pair",
            columns: 10, rows: 3,
            input: "a\u{1F1E6}\u{1F1E7}\u{1F1E8}\u{1F1E9}b\r\n"
        ),
        Scenario(
            name: "marks past the retained-byte limit",
            columns: 8, rows: 3,
            input: "a" + String(repeating: "\u{0301}", count: 96) + "b\r\n"
        ),
        Scenario(
            name: "a spacing mark and a prepend inside one stretch",
            columns: 9, rows: 3,
            input: "a\u{0903}b\u{0D4E}c\u{0D4E}\u{0D4E}d\r\n"
        ),
        Scenario(
            name: "ASCII inside a non-ASCII stretch under a non-ASCII GL character set",
            columns: 12, rows: 3,
            input: "\u{1B}(0abc\u{2500}def\u{65E5}ghi\u{1B}(Bjkl\r\n"
        ),
        Scenario(
            name: "ASCII inside a non-ASCII stretch under a pending single shift",
            columns: 12, rows: 3,
            input: "\u{1B}*0\u{2500}\u{1B}Nqq\u{65E5}\u{1B}Nqab\r\n"
        ),
        Scenario(
            name: "joiners arriving with no open cluster",
            columns: 8, rows: 3,
            input: "\u{0301}\u{200D}\u{0302}ab\r\n"
        ),
        Scenario(
            name: "joiners arriving on a cluster recovered from the grid",
            columns: 8, rows: 3,
            input: "ab\u{1B}[1;2H\u{0301}\u{0302}c\r\n"
        ),
        Scenario(
            name: "a stretch that wraps and one that scrolls",
            columns: 6, rows: 3,
            input: "a\u{0301}bcde\u{0301}fghij\u{65E5}\u{0301}klmnop\r\n"
        ),
        Scenario(
            name: "a stretch under insert mode",
            columns: 9, rows: 3,
            input: "abcdef\u{1B}[1;1H\u{1B}[4hx\u{0301}\u{2500}y\r\n"
        ),
        Scenario(
            name: "a stretch of every kind on the alternate screen",
            columns: 10, rows: 3,
            input: "\u{1B}[?1049ha\u{0301}\u{2500}\u{65E5}\u{0301}b\u{1B}[?1049lc\u{0301}\r\n"
        ),
        Scenario(
            name: "a stretch beginning at the right margin of a two-column terminal",
            columns: 2, rows: 3,
            input: "a\u{0301}\u{65E5}\u{0301}b\u{2500}\r\n"
        ),
    ]

    @Test("a fed stretch leaves the terminal the reference feed leaves", arguments: scenarios)
    func stretchMatchesTheReferenceFeed(scenario: Scenario) throws {
        // Intent: feeding a scenario whole leaves a terminal equal to feeding it one byte per call.
        // Why it exists: one action now carries a base, its marks and the ASCII around them, so
        //   every piece of state the four separate actions used to settle between -- the grid, the
        //   cursor, the wrap latch, the cluster context, the REP memory and the inspection state --
        //   is now settled inside one action's walk, and nothing but this comparison says it lands
        //   in the same place.
        let reference = try replay(scenario, chunkSize: 1)
        expectValidGrid(reference, context: "\(scenario.name) fed one byte at a time")

        let whole = try replay(scenario, chunkSize: scenario.input.utf8.count)
        #expect(
            whole == reference,
            "\(scenario.name) diverged: \(diagnosis(whole, reference))"
        )
        expectValidGrid(whole, context: "\(scenario.name) fed whole")
    }

    @Test("the damage a stretch drains is the damage the reference feed drains", arguments: scenarios)
    func stretchDamageMatchesTheReferenceFeed(scenario: Scenario) throws {
        // Intent: the damage drained after a whole-stretch feed equals the damage drained after the
        //   same bytes one byte at a time.
        // Why it exists: the damage snapshot and its diff now run once per stretch instead of once
        //   per cluster piece, and the diff reads the cursor's row -- so a stretch that wraps or
        //   scrolls mid-walk is exactly where a lost intermediate row would show up.
        var reference = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
        _ = reference.drainDamage()
        var whole = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
        _ = whole.drainDamage()

        let bytes = Array(scenario.input.utf8)
        for byte in bytes { reference.feed([byte]) }
        whole.feed(bytes)

        #expect(whole.drainDamage() == reference.drainDamage(), "\(scenario.name) damage differs")
    }

    @Test(
        "REP after a stretch repeats the cluster the stretch left open",
        arguments: [
            "a\u{0301}\u{0302}\u{0303}",
            "\u{65E5}\u{0301}",
            "x\u{1F468}\u{200D}\u{1F469}",
            "y\u{00A9}\u{FE0F}",
            "z\u{1F1E6}\u{1F1E7}",
            "b" + String(repeating: "\u{0301}", count: 96),
            "\u{2500}",
            "cd",
        ]
    )
    func repeatAfterAStretchMatchesTheReferenceFeed(payload: String) throws {
        // Intent: `CSI 3 b` after a stretch places the same three cells as typing the payload's
        //   last cluster three more times, at the width that cluster ended at.
        // Why it exists: the REP memory is written by whichever writer stamped the stretch's last
        //   cell, and a stretch now ends inside a walk rather than at an action boundary -- so a
        //   memory left mirroring the base instead of the whole cluster, or the wrong width, would
        //   only show up when REP spends it.
        let bytes = Array((payload + "\u{1B}[3b").utf8)

        var whole = try #require(Terminal(columns: 16, rows: 3))
        whole.feed(bytes)

        var reference = try #require(Terminal(columns: 16, rows: 3))
        for byte in bytes { reference.feed([byte]) }

        #expect(whole == reference, "\(payload.debugDescription) diverged: \(diagnosis(whole, reference))")
        expectValidGrid(whole, context: "REP after \(payload.debugDescription)")
    }

    @Test(
        "a terminal restored mid-stretch continues the cluster identically",
        arguments: [
            "a\u{0301}\u{0302}\u{0303}bc",
            "\u{65E5}\u{0301}\u{672C}\u{0302}",
            "x\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}y",
            "\u{2500}z\u{00A9}\u{FE0F}w",
        ]
    )
    func synchronizationRoundTripMidStretch(payload: String) throws {
        // Intent: cutting a stretch in half, synchronizing, and feeding the rest to the replica
        //   reaches the same terminal -- and the same pending decoder prefix -- as feeding it whole.
        // Why it exists: the synchronization stream restores the decoder's pending prefix, the open
        //   cluster context and the REP memory, and a stretch is now the unit that opens all three;
        //   a cut inside a multi-byte scalar of a stretch is the case that exercises every one.
        let bytes = Array(payload.utf8)
        for cut in 1..<bytes.count {
            var source = try #require(Terminal(columns: 12, rows: 3))
            source.feed(Array(bytes[..<cut]))

            let synchronization = source.stateSynchronization
            var replica = try #require(Terminal(
                columns: synchronization.columns,
                rows: synchronization.rows
            ))
            replica.feed(synchronization.bytes)
            // The restored terminal re-encodes to the same bytes, which is the pending prefix, the
            // open cluster context and the REP memory all read back at once.
            #expect(
                replica.stateSynchronization.bytes == synchronization.bytes,
                "\(payload.debugDescription) cut at \(cut) restored a different stream state"
            )

            let rest = Array(bytes[cut...])
            source.feed(rest)
            replica.feed(rest)

            #expect(
                replica.screenText == source.screenText,
                "\(payload.debugDescription) cut at \(cut) diverged: \(replica.screenText.debugDescription) vs \(source.screenText.debugDescription)"
            )
            #expect(
                replica.geometry.rows.map(\.cells) == source.geometry.rows.map(\.cells),
                "\(payload.debugDescription) cut at \(cut) diverged in cells"
            )
        }
    }

    @Test("a stretch of joined marks leaves the row's arena holding exactly its live clusters")
    func joinSegmentLeavesOnlyLiveClustersInTheArena() throws {
        // Intent: after one stretch of bases and marks, the row's arena holds one record per
        //   multi-scalar cell -- that cell's scalars in order, behind their count -- and nothing
        //   else.
        // Why it exists: a segment of joiners now shares one validation of the open cluster, so
        //   each mark must still land in the record the base opened. A join that re-interned the
        //   cluster, or wrote past the record it grew, would leave the same visible text with a
        //   dead copy behind it, and only the whole buffer can see that.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("a\u{0301}\u{0302}b\u{65E5}\u{0301}c".utf8))

        let row = try #require(terminal.liveRowForTesting(at: 0))
        #expect(row.arenaCensusForTesting == [
            Unicode.Scalar(UInt32(3))!, "a", "\u{0301}", "\u{0302}",
            Unicode.Scalar(UInt32(2))!, "\u{65E5}", "\u{0301}",
        ])
        // The census above is only a claim about clusters while these say which cells own them:
        // the two marked cells, and no others.
        #expect(row.cells.map(\.word.isSpilled) == [
            true, false, true, false, false, false, false, false,
        ])
    }

    private func replay(_ scenario: Scenario, chunkSize: Int) throws -> Terminal {
        var terminal = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
        let bytes = Array(scenario.input.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            terminal.feed(Array(bytes[index..<end]))
            index = end
        }
        return terminal
    }

    /// Names the first visible difference so a failure reads as a divergence rather than as
    /// "two opaque terminals are unequal".
    private func diagnosis(_ replayed: Terminal, _ reference: Terminal) -> String {
        if replayed.screenText != reference.screenText {
            return "screen text \(replayed.screenText.debugDescription) "
                + "vs \(reference.screenText.debugDescription)"
        }
        if replayed.geometry.cursor != reference.geometry.cursor {
            return "cursor \(String(describing: replayed.geometry.cursor)) "
                + "vs \(String(describing: reference.geometry.cursor))"
        }
        if replayed.geometry.rows.map(\.cells) != reference.geometry.rows.map(\.cells) {
            return "viewport cells differ at equal screen text"
        }
        return "state outside the viewport differs"
    }
}
