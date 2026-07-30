// Behavioral proofs for display-scale metrics, its styled font set, and
// overflow-safe frame sizing.
import CoreGraphics
import CoreText
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct RenderMetricsTests {
    @Test("Cell dimensions are whole device pixels at representative scales", arguments: [1.0, 2.0, 1.5])
    func pixelIntegralCellDimensions(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))

        #expect(metrics.displayScale == scale)
        #expect(metrics.cellSize.width * scale == CGFloat(metrics.cellWidthPixels))
        #expect(metrics.cellSize.height * scale == CGFloat(metrics.cellHeightPixels))
        #expect(metrics.cellWidthPixels > 0)
        #expect(metrics.cellHeightPixels > 0)
        #expect(metrics.cellSize.height >= metrics.unquantizedLineHeight)
        #expect(metrics.baselineOffset > 0)
        #expect(metrics.baselineOffset <= metrics.cellSize.height)
        #expect(metrics.underlineThickness >= 1 / scale)
        #expect((metrics.underlineOffset * scale).rounded() == metrics.underlineOffset * scale)
        #expect(
            (metrics.strikethroughOffset * scale).rounded()
                == metrics.strikethroughOffset * scale
        )
    }

    @Test("Metrics carry one styled face per trait combination, all on the base family")
    func fontSetCoversEveryTraitCombination() throws {
        // Intent: the font set a draw reads holds four faces whose symbolic
        //   traits match the style each one serves, all from the base family.
        // Why it exists: the faces moved off the draw path and onto the metrics
        //   so a draw constructs no fonts. Once built once and reused forever, a
        //   face wired to the wrong traits can no longer be corrected by the next
        //   draw, and the styled-cell bitmap tests only catch it when the wrong
        //   face happens to render differently.
        // Scenario: spec-first -- terminal output mixes regular, bold, italic,
        //   and bold-italic runs within a single frame.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let fonts = metrics.fonts

        #expect(CTFontGetSymbolicTraits(fonts.regular.font).isDisjoint(with: [.boldTrait, .italicTrait]))
        #expect(CTFontGetSymbolicTraits(fonts.bold.font).contains(.boldTrait))
        #expect(CTFontGetSymbolicTraits(fonts.bold.font).contains(.italicTrait) == false)
        #expect(CTFontGetSymbolicTraits(fonts.italic.font).contains(.italicTrait))
        #expect(CTFontGetSymbolicTraits(fonts.italic.font).contains(.boldTrait) == false)
        #expect(CTFontGetSymbolicTraits(fonts.boldItalic.font).isSuperset(of: [.boldTrait, .italicTrait]))

        for font in [fonts.regular.font, fonts.bold.font, fonts.italic.font, fonts.boldItalic.font] {
            #expect(CTFontGetSize(font) == metrics.baseFontSize)
            #expect(CTFontCopyFamilyName(font) == CTFontCopyFamilyName(fonts.regular.font))
        }
    }

    @Test("Equal metrics carry interchangeable font sets")
    func equalMetricsCarryInterchangeableFontSets() throws {
        // Intent: two separately built metrics for the same display scale stay
        //   `==`, and their font sets are interchangeable.
        // Why it exists: the view rebuilds metrics on every geometry sync and
        //   repaints only when the new value differs from the old. Storing
        //   reference-typed faces on the metrics would break that comparison if
        //   equality ever narrowed to face identity, silently repainting the
        //   whole grid on every resize tick.
        // Scenario: spec-first -- a window resize that leaves the backing scale
        //   unchanged must not read as a metrics change.
        let first = try #require(TerminalRenderMetrics(displayScale: 2))
        let second = try #require(TerminalRenderMetrics(displayScale: 2))

        #expect(first == second)
        #expect(first.fonts == second.fonts)
        #expect(first != (try #require(TerminalRenderMetrics(displayScale: 1))))
    }

    @Test("Invalid and unrepresentable display scales refuse metrics")
    func invalidScalesRefuseMetrics() {
        for scale in [0, -1, .nan, .infinity, -.infinity] as [CGFloat] {
            #expect(TerminalRenderMetrics(displayScale: scale) == nil)
        }

        #expect(TerminalRenderMetrics(displayScale: .greatestFiniteMagnitude) == nil)
    }

    @Test("Frame sizing returns exact point and pixel extents")
    func frameSizing() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 1.5))
        let plan = try makePlan(columns: 7, rows: 3)
        let size = try #require(renderFrameSize(for: plan, metrics: metrics))

        #expect(size.pointSize == CGSize(
            width: metrics.cellSize.width * 7,
            height: metrics.cellSize.height * 3
        ))
        #expect(size.pixelWidth == metrics.cellWidthPixels * 7)
        #expect(size.pixelHeight == metrics.cellHeightPixels * 3)
    }

    @Test("Frame sizing refuses pixel extents that overflow")
    func frameSizingOverflow() throws {
        let plan = try makePlan(columns: 2, rows: 1)
        let metrics = try #require(largestMetricsWhoseTwoColumnFrameOverflows())

        #expect(renderFrameSize(for: plan, metrics: metrics) == nil)
    }

    @Test("Dirty rect selects every partially overlapping row")
    func dirtyRectSelectsPartialRows() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let height = metrics.cellSize.height
        let dirtyRect = CGRect(x: 0, y: height / 2, width: 10, height: height * 1.5)

        #expect(terminalRows(intersecting: dirtyRect, metrics: metrics, rowCount: 4) == 0..<2)
    }

    @Test("Dirty rect excludes a row that only abuts its edge")
    func dirtyRectExcludesAbuttingRow() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let height = metrics.cellSize.height
        let dirtyRect = CGRect(x: 0, y: height, width: 10, height: height)

        #expect(terminalRows(intersecting: dirtyRect, metrics: metrics, rowCount: 4) == 1..<2)
    }

    @Test("Dirty rect clips partial overlap to the grid")
    func dirtyRectClipsToGrid() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let height = metrics.cellSize.height
        let dirtyRect = CGRect(x: 0, y: -height / 2, width: 10, height: height)

        #expect(terminalRows(intersecting: dirtyRect, metrics: metrics, rowCount: 4) == 0..<1)
    }

    @Test(
        "Dirty rect outside the grid or without area selects no rows",
        arguments: [
            CGRect(x: 0, y: -20, width: 10, height: 5),
            CGRect(x: 0, y: 100, width: 10, height: 5),
            CGRect(x: 0, y: 0, width: 0, height: 10),
            CGRect(x: 0, y: 0, width: 10, height: 0),
        ]
    )
    func dirtyRectWithoutGridAreaSelectsNoRows(dirtyRect: CGRect) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))

        #expect(terminalRows(intersecting: dirtyRect, metrics: metrics, rowCount: 4).isEmpty)
    }

    @Test("Full-grid dirty rect selects the complete row range at display scale 2")
    func fullGridDirtyRectSelectsEveryRow() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let dirtyRect = CGRect(
            x: 0,
            y: 0,
            width: metrics.cellSize.width * 8,
            height: metrics.cellSize.height * 4
        )

        #expect(terminalRows(intersecting: dirtyRect, metrics: metrics, rowCount: 4) == 0..<4)
    }
}

private func largestMetricsWhoseTwoColumnFrameOverflows() -> TerminalRenderMetrics? {
    var accepted: CGFloat = 1
    var refused = CGFloat(Int.max)
    for _ in 0..<128 {
        let candidate = accepted + (refused - accepted) / 2
        if TerminalRenderMetrics(displayScale: candidate) == nil {
            refused = candidate
        } else {
            accepted = candidate
        }
    }
    let metrics = TerminalRenderMetrics(displayScale: accepted)
    return metrics.flatMap { $0.cellWidthPixels > Int.max / 2 ? $0 : nil }
}

private func makePlan(columns: Int, rows: Int) throws -> RenderFramePlan {
    let terminal = try #require(Terminal(columns: columns, rows: rows))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
    )
}
