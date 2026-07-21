// Render-plan behavior when the engine presents retained-history windows.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

/// Proves complete frame planning consumes the engine-selected window and relative cursor.
struct ViewportRenderPlanningTests {
    @Test("scrolled frames plan the selected window and omit an off-window cursor")
    func scrolledWindowAndCursorOmission() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne".utf8))
        terminal.scroll(toTopRow: 0)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )

        #expect(plan.rows == 3)
        #expect(plan.textRuns.flatMap(\.cells).map(\.scalars) == [
            Array("a".unicodeScalars),
            Array("b".unicodeScalars),
            Array("c".unicodeScalars),
        ])
        #expect(plan.cursor == nil)
        assertCanonical(plan)
    }

    @Test("a retained-history-only window plans without live-grid cells")
    func scrollbackOnlyWindow() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng".utf8))
        terminal.scroll(toTopRow: 0)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )

        #expect(plan.textRuns.flatMap(\.cells).map(\.scalars) == [
            Array("a".unicodeScalars),
            Array("b".unicodeScalars),
            Array("c".unicodeScalars),
        ])
        #expect(plan.cursor == nil)
        assertCanonical(plan)
    }

    @Test("a cursor inside a browsing window uses window-relative coordinates")
    func browsingCursorCoordinates() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne".utf8))
        terminal.scroll(toTopRow: 0)
        let found = terminal.beginSearch("e")
        #expect(found)
        #expect(terminal.scrollProjection.isFollowing == false)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )

        #expect(plan.cursor == RenderCursor(
            row: 2,
            column: 1,
            columnWidth: 1,
            shape: .block,
            color: RenderTheme.dark.cursor
        ))
        assertCanonical(plan)
    }

    @Test("returning to follow produces the original complete frame")
    func followFrameRoundTrip() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: true,
            cursorShape: .block
        )
        let original = planFrame(for: terminal, presentation: presentation)

        terminal.scroll(toTopRow: 0)
        terminal.scrollToBottom()

        #expect(planFrame(for: terminal, presentation: presentation) == original)
    }
}
