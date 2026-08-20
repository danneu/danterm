// Terminal-semantics cases adapted from WezTerm's `term/src/test/` corpus. Separate from
// TerminalResizeTests and the libvterm fixtures -- which pin behavior DanTerm chose or
// inherited from a spec suite -- because everything here is tracked against an external
// implementation: each test names the upstream test it follows so a pin bump that renames
// or revises that test is a reviewable event rather than silent compatibility drift.
//
// We adopt WezTerm's scenarios, never its verdict by default. WezTerm asserts through a
// `Line`/stable-row/`seqno` model and a one-past-end cursor that DanTerm does not have, so
// every citation carries a `Divergence:` line saying what we assert instead. The
// per-case disposition ledger for the full 56-test corpus lives in
// docs/scratch/wezterm-test-portage.md.
import Testing

@testable import TerminalCore

/// Tracks the slice of WezTerm's terminal tests that survived the portage audit as DanTerm
/// behavior, so upstream revisions surface here instead of drifting unnoticed.
struct TerminalWezTermAdaptedTests {
    /// Feeds `bytes` whole, one byte at a time, and at every single split point, applying
    /// `after` to each resulting terminal before handing it to `check`. A reflow bug that
    /// only appears when a control sequence straddles a chunk boundary is invisible to a
    /// single whole-stream feed, and this scenario exists precisely to put a control
    /// sequence next to a boundary.
    private func expectAcrossFeedSplits(
        columns: Int,
        rows: Int,
        _ bytes: [UInt8],
        after: (inout Terminal) -> Void = { _ in },
        check: (Terminal, Comment) -> Void
    ) throws {
        var chunkings: [(Comment, [[UInt8]])] = [
            ("whole", [bytes]),
            ("bytewise", bytes.map { [$0] }),
        ]
        for split in 1..<bytes.count {
            chunkings.append(("split at \(split)", [Array(bytes[..<split]), Array(bytes[split...])]))
        }

        for (label, chunks) in chunkings {
            var terminal = try #require(Terminal(columns: columns, rows: rows))
            for chunk in chunks { terminal.feed(chunk) }
            after(&terminal)
            check(terminal, label)
        }
    }

    @Test(
        "a control between an exactly-full row and its CRLF still yields a hard boundary",
        arguments: [
            ("no control", "====\r\nSS\r\n", "===="),
            ("DECTCM around the text", "\u{1B}[?25l====\u{1B}[?25h\r\nSS\r\n", "===="),
            ("SGR reset before the CR", "====\u{1B}[0m\r\nSS\r\n", "===="),
            (
                "DEC Special Graphics run, then back to ASCII",
                "\u{1B}(0qqqq\u{1B}(B\r\nSS\r\n",
                "\u{2500}\u{2500}\u{2500}\u{2500}"
            ),
        ]
    )
    func exactWidthHardBoundarySurvivesInterveningControl(
        label: String,
        stream: String,
        firstRow: String
    ) throws {
        // Intent: when text exactly fills the final column and a supported control sequence
        //   is dispatched before the CR/LF that ends the row, the row is still a hard line
        //   end -- so widening the terminal must not pull the next row up into it.
        // Why it exists: printing into the last column leaves the cursor in deferred-wrap
        //   state rather than on the next row, and it is that state which decides whether
        //   the following CR/LF records a hard break or a soft one. Any control that
        //   incidentally clears or commits the deferred wrap converts the boundary to a
        //   soft one, and the corruption stays invisible until a later widen joins two
        //   unrelated logical lines. The unwidened grid looks correct either way.
        // Scenario: a program hides the cursor (or resets SGR) around a line of output that
        //   happens to be exactly as wide as the window, then the user widens the window.
        //
        // Honest TDD note: this passed the first time it ran -- DanTerm marks a row wrapped
        //   lazily, at the next print, so the eager-flag bug WezTerm hit here is structurally
        //   absent. It is kept as a compositional regression boundary, not as a fix. Each
        //   link (a control preserves pending wrap, CR clears it, an exact-width CRLF is a
        //   hard boundary, a widen does not join hard rows) has its own stronger proof --
        //   `SGR preserves pending wrap and open grapheme assembly`,
        //   Fixtures/libvterm/flow-hard-boundary.json, and
        //   `rewrap never joins two rows that were not soft-wrapped together` -- but nothing
        //   pinned them end to end. Verified non-tautological by three injected mutations
        //   (eager wrap-flagging in printNarrow, dispatchCSI committing a deferred wrap, and
        //   reflow inferring a join from row fullness); this test failed under all three.
        //   The DEC Special Graphics leg also passed first run, and the mutation aimed at its
        //   own dispatch path -- `dispatchEscape` clearing pending motion state before an SCS
        //   designation -- did *not* fail it, for the same lazy-flag reason. So that leg's
        //   claim is narrower than the others: it pins that a row of translated, non-ASCII
        //   scalars reaches the margin and reflows exactly as the ASCII rows do, not that SCS
        //   dispatch is a hazard to the boundary. The reflow-join mutation does fail it.
        //
        // Adapted from term/src/test/mod.rs#test_resize_wrap_dectcm_issue_978 and
        //   term/src/test/mod.rs#test_resize_wrap_escape_code_issue_978 (WezTerm d69264d),
        //   with the control-free leg from #test_resize_wrap_issue_971 as the control case.
        //   Divergence: WezTerm asserts rendered `visible_lines()` text only; we also assert
        //   per-row `isSoftWrapped` and the cursor, which is what actually distinguishes a
        //   hard boundary from a soft one that happens to render the same before the widen.
        //   The fourth leg is #test_resize_wrap_sgc_issue_978, where the intervening controls
        //   are the SCS designations that switch G0 to DEC Special Graphics and back, and the
        //   exactly-full row is line-drawing glyphs rather than ASCII. Divergence: none beyond
        //   the shared one above.
        try expectAcrossFeedSplits(columns: 4, rows: 4, Array(stream.utf8)) { terminal, chunking in
            #expect(terminal.screenText == "\(firstRow)\nSS  \n    \n    ", "\(label), \(chunking)")
            #expect(
                terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false, false],
                "\(label), \(chunking)"
            )
            #expect(
                terminal.geometry.cursor == TerminalCursor(row: 2, column: 0, isPendingWrap: false),
                "\(label), \(chunking)"
            )
            expectValidGrid(terminal)
        }

        try expectAcrossFeedSplits(
            columns: 4,
            rows: 4,
            Array(stream.utf8),
            after: { $0.resize(columns: 6, rows: 4) }
        ) { terminal, chunking in
            #expect(
                terminal.screenText == "\(firstRow)  \nSS    \n      \n      ",
                "\(label), \(chunking)"
            )
            #expect(
                terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false, false],
                "\(label), \(chunking)"
            )
            #expect(terminal.scrollbackRowCount == 0, "\(label), \(chunking)")
            expectValidGrid(terminal)
        }
    }

    @Test("the cursor at the end of a long line survives a shrink-and-rewiden walk")
    func cursorAnchorSurvivesNarrowAndRewidenWalk() throws {
        // Intent: with the cursor parked just past the last character of a line that is one
        //   column short of the width, narrowing and then widening again must land the
        //   cursor back on that same character boundary, not drift away from it.
        // Why it exists: narrowing pushes the tail onto a continuation row, so the cursor's
        //   anchor has to survive being expressed against a wrapped line and then folded
        //   back. Existing anchor coverage proves each single transition; a drift that only
        //   accumulates when the walk returns to a wider width would pass all of them.
        // Scenario: a shell prompt sits at the end of its line and the user resizes the
        //   window narrower and then back, or drags a split divider through both.
        //
        // Adapted from term/src/test/mod.rs#test_resize_2162,
        //   #test_resize_2162_by_2 and #test_resize_2162_by_2_then_up_1 (WezTerm d69264d),
        //   collapsed into one walk because DanTerm's resize is order-canonical
        //   (see `combinedResizeUsesCanonicalOrder`), so the by-2-then-up-1 variant adds a
        //   height leg rather than a distinct width transition.
        //   Divergence: WezTerm consumes trailing blanks on the narrow leg. DanTerm preserves
        //   them, so the wrapped head moves to scrollback and the cursor stays with the live tail.
        //   WezTerm also asserts a one-past-end cursor (`x == cols`) and a `seqno`; DanTerm has
        //   no such position, so that state uses the last cell plus `isPendingWrap: true`.
        var terminal = try #require(Terminal(columns: 20, rows: 4))
        terminal.feed(Array("some long long text".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false, false])

        // WezTerm's by-1 leg: 19 characters exactly fill 19 columns, so its one-past-end
        // cursor (19, 0) becomes DanTerm's last cell with the wrap deferred.
        terminal.resize(columns: 19, rows: 4)
        #expect(terminal.screenText.split(separator: "\n")[0] == "some long long text")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 18, isPendingWrap: true))

        // WezTerm's by-2 leg: the tail moves to a continuation row and the cursor follows it.
        terminal.resize(columns: 18, rows: 4)
        #expect(terminal.scrollbackRowCount == 1)
        #expect(displayedRows(of: terminal) == [
            "some long long tex|wrap",
            "t                 ",
            "                  ",
            "                  ",
            "                  ",
        ])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))

        // The height leg from #test_resize_2162_by_2_then_up_1, folded back to full width.
        terminal.resize(columns: 20, rows: 3)
        #expect(terminal.screenText.split(separator: "\n")[0] == "some long long text ")
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))

        terminal.resize(columns: 20, rows: 4)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))
        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.fullHistoryText == "some long long text")
        expectValidGrid(terminal)
    }

    /// Runs one press-drag-release at character granularity through the real pointer seam,
    /// returning both the range policy computed and the text a Copy would then yield. Written
    /// against `decideTerminalPointer` rather than `setSelection` on purpose: these scenarios
    /// are about which *boundary* a pointer coordinate names, the step `setSelection` skips.
    /// The two offsets are the pointer's position inside its own cell; both default to that
    /// cell's leading edge, which is the boundary before its character.
    ///
    /// Both halves are reported because a caller can consume either one. `setSelection`
    /// re-snaps its endpoints, so a policy range that split a wide cell would still copy the
    /// right text while painting a highlight through the middle of an emoji.
    private func dragSelect(
        _ terminal: inout Terminal,
        from: (column: Int, row: Int),
        fromOffsetX: Double = 0,
        to: (column: Int, row: Int),
        toOffsetX: Double = 0
    ) -> (range: TerminalTextRange?, text: String?) {
        var state = TerminalInteractionState()
        var policyRange: TerminalTextRange?
        for event: TerminalPointerEvent in [
            .down(.left, cell: .init(column: from.column, row: from.row, offsetX: fromOffsetX)),
            .move(cell: .init(column: to.column, row: to.row, offsetX: toOffsetX)),
            .up(.left, cell: .init(column: to.column, row: to.row)),
        ] {
            let decision = decideTerminalPointer(event, terminal: terminal, state: &state)
            switch decision.selectionMutation {
            case .clear:
                policyRange = nil
            case let .set(range, _):
                policyRange = range
            case nil:
                break
            }
            applyTerminalPointerDecision(decision, to: &terminal)
        }
        return (policyRange, terminal.selectedText)
    }

    @Test("a character drag names whole cells and survives ends outside the viewport")
    func characterDragSnapsWideCellsAndClampsOutOfBounds() throws {
        // Intent: a press-drag-release at character granularity copies the text between the
        //   two boundaries its ends resolve to, where a boundary always falls outside a whole
        //   display cell -- a wide character is never half-selected -- and an endpoint outside
        //   the grid resolves to the nearest real content instead of trapping.
        // Why it exists: the two ends of a drag reach the stream by different routes. The
        //   anchor is pinned at pointer-down and the moving end is resolved fresh on every
        //   move, and only the moving end's route is guarded against out-of-viewport input
        //   (the link arm checks `isViewportPosition`; the selection arm does not, and relies
        //   entirely on `normalizedCellPosition` clamping). Nothing pinned that reliance, and
        //   an unclamped row would be an out-of-bounds index, not a wrong answer.
        // Scenario: a user drags across a line containing an emoji and flings the pointer off
        //   the bottom-right of the pane before releasing.
        //
        // Honest TDD note: every leg passed on first run. The off-grid legs are what earn the
        //   test: dropping the row clamp in `normalizedCellPosition` traps here on "Index out
        //   of range", and the whole of TerminalInteractionPolicyTests, TerminalSelectionTests,
        //   TerminalSelectionUnitTests, and TerminalHyperlinkInteractionTests still passes
        //   under that mutation -- no other test drags to a coordinate outside the grid.
        //   The wide-cell legs do not discriminate on atomicity and are not claimed to: DanTerm
        //   enforces cluster snapping at three independent layers (`characterBoundary`, the
        //   pin/resolve round trip the drag anchor takes, and `setSelection`), so removing any
        //   one still yields boundaries outside the cluster. They are kept as the executable
        //   statement of the divergence below, which is otherwise only a comment.
        //
        // Adapted from term/src/test/selection.rs#drag_selection (WezTerm d69264d).
        //   Convergence, wide cells: both drop the emoji when the drag starts on its second
        //   column and yield "skul", but for different reasons. WezTerm's rule is per-cell;
        //   DanTerm's is that a boundary is chosen across the character's whole width, so the
        //   emoji's second column is past its visual center and snaps to the boundary after
        //   it. Starting one column earlier -- the left half of the same character -- selects
        //   the emoji whole. Neither drag can name a position inside the cluster.
        //   Divergence, off-grid end: WezTerm's drag past the last row picks up the blank row
        //   below and copies a trailing "\n"; DanTerm clamps to the last retained content, the
        //   rule `a stripped trailing blank endpoint clamps to retained content` already
        //   states. Both are non-panicking, which is what the upstream case is really for.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("hello world\r\n".utf8))
        terminal.feed(Array("\u{1F480}skull\r\n".utf8))
        #expect(terminal.screenText == "hello world \n\u{1F480}skull     \n            ")

        #expect(dragSelect(
            &terminal, from: (1, 0), to: (4, 0), toOffsetX: 1
        ).text == "ello")

        // Row 1 is `[skull-head][skull-tail]s k u l l`, so column 1 is the emoji's tail and the
        // emoji's visual center is the seam between columns 0 and 1. Each drag must produce a
        // *range* on a cluster boundary, not merely the right text -- splitting a cluster is
        // the half `setSelection` cannot rescue.
        let fromTail = dragSelect(&terminal, from: (1, 1), to: (5, 1), toOffsetX: 1)
        #expect(fromTail.range == TerminalTextRange(
            start: TerminalTextPosition(row: 1, column: 2),
            end: TerminalTextPosition(row: 1, column: 6)
        ))
        #expect(fromTail.text == "skul")
        let fromHead = dragSelect(&terminal, from: (0, 1), to: (5, 1), toOffsetX: 1)
        #expect(fromHead.range == TerminalTextRange(
            start: TerminalTextPosition(row: 1, column: 0),
            end: TerminalTextPosition(row: 1, column: 6)
        ))
        #expect(fromHead.text == "\u{1F480}skul")

        // Across a hard line break: the newline is the break, and row 0's trailing blank
        // column is not part of the text.
        #expect(dragSelect(
            &terminal, from: (1, 0), to: (6, 1), toOffsetX: 1
        ).text == "ello world\n\u{1F480}skull")
        #expect(dragSelect(
            &terminal, from: (6, 0), to: (3, 1), toOffsetX: 1
        ).text == "world\n\u{1F480}sk")

        // Dragging back the way it came selects the same text: the two ends are boundaries and
        // the gesture orders them, so direction is symmetric rather than special-cased.
        #expect(dragSelect(
            &terminal, from: (4, 0), fromOffsetX: 1, to: (1, 0)
        ).text == "ello")

        // Off-grid ends. A real caller normalizes through `terminalCell(at:)`, which clamps,
        // but the policy seam is public and takes raw coordinates, so each end has to be
        // safe on its own. The claim is that each still names real content -- where exactly a
        // blank row past the end clamps to is not pinned here, only that it holds no text.
        let whole = "hello world\n\u{1F480}skull"
        #expect(dragSelect(&terminal, from: (0, 0), to: (15, 3)).text == whole)
        #expect(dragSelect(&terminal, from: (0, 0), to: (9999, 9999)).text == whole)
        #expect(dragSelect(&terminal, from: (99, 9), to: (2, 0)).text == "llo world\n\u{1F480}skull")
        // The press names the boundary before the emoji and the drag never crossed back over
        // its center, so the emoji itself is outside the span.
        #expect(dragSelect(&terminal, from: (0, 1), to: (-5, -5)).text == "hello world\n")
    }
}
