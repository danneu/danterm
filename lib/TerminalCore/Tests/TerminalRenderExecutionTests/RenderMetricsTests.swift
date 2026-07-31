// Behavioral proofs for display-scale metrics, its styled font set, and
// overflow-safe frame sizing.
import AppKit
import CoreGraphics
import CoreText
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct RenderMetricsTests {
    @Test("Configured font size changes cell metrics and rejects invalid sizes")
    func configuredFontSizeChangesMetrics() throws {
        let defaultMetrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let largerMetrics = try #require(TerminalRenderMetrics(displayScale: 2, fontSize: 20))

        #expect(largerMetrics.baseFontSize == 20)
        #expect(largerMetrics.cellSize.width > defaultMetrics.cellSize.width)
        #expect(largerMetrics.cellSize.height > defaultMetrics.cellSize.height)
        for size in [0, -1, .nan, .infinity] as [CGFloat] {
            #expect(TerminalRenderMetrics(displayScale: 2, fontSize: size) == nil)
        }
    }

    @Test("An absent font family is the system-monospace path, unchanged")
    func absentFontFamilyKeepsTheSystemMonospacePath() throws {
        // Intent: omitting `fontFamily` and passing an explicit nil build the same
        //   metrics, and both stay on the system monospace face.
        // Why it exists: every existing caller omits the new parameter, so the
        //   default must be provably the old behavior rather than merely similar
        //   to it -- a config with no `font.family` key has to render byte-identically
        //   to the build before the family was configurable.
        // Scenario: spec-first -- a user who never sets `font.family` at all.
        let implicit = try #require(TerminalRenderMetrics(displayScale: 2))
        let explicitNil = try #require(TerminalRenderMetrics(displayScale: 2, fontFamily: nil))

        #expect(implicit == explicitNil)
        #expect(implicit.fonts == explicitNil.fonts)
        #expect(
            explicitNil.baseFontName
                == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        )
    }

    @Test("A named family builds that family's faces with usable whole-pixel cells")
    func namedFamilyBuildsThatFamily() throws {
        // Intent: a resolved family reaches the faces a draw reads, and the cell
        //   geometry derived from it is still whole-pixel and positive.
        // Why it exists: `CTFontCreateWithName` silently substitutes a last-resort
        //   face for a name it cannot match, so "the metrics were built" proves
        //   nothing on its own -- the family on the resulting face is the only
        //   evidence that the configured font is what the terminal will draw.
        // Scenario: spec-first -- a user sets `"font": {"family": "Menlo"}`.
        //   Menlo ships with every macOS, so the case needs no test fixture font.
        let menlo = try #require(TerminalRenderMetrics(displayScale: 2, fontFamily: "Menlo"))
        let systemMonospace = try #require(TerminalRenderMetrics(displayScale: 2))

        #expect(CTFontCopyFamilyName(menlo.fonts.regular.font) as String == "Menlo")
        #expect(menlo != systemMonospace)
        #expect(menlo.cellWidthPixels > 0)
        #expect(menlo.cellHeightPixels > 0)
        #expect(menlo.cellSize.width * 2 == CGFloat(menlo.cellWidthPixels))
        #expect(menlo.cellSize.height * 2 == CGFloat(menlo.cellHeightPixels))
    }

    @Test("Bold and italic still derive from the named family")
    func namedFamilyStillDerivesStyledFaces() throws {
        // Intent: choosing a family sets only the base face; the styled faces are
        //   still derived from it by trait.
        // Why it exists: I3 -- the schema deliberately has no per-style families, so
        //   the render layer must keep synthesizing bold and italic off whatever base
        //   family it was handed rather than treating the configured name as final.
        // Scenario: spec-first -- terminal output mixes styles under a custom family.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2, fontFamily: "Menlo"))
        let fonts = metrics.fonts

        #expect(CTFontGetSymbolicTraits(fonts.bold.font).contains(.boldTrait))
        #expect(CTFontGetSymbolicTraits(fonts.italic.font).contains(.italicTrait))
        for font in [fonts.regular.font, fonts.bold.font, fonts.italic.font, fonts.boldItalic.font] {
            #expect(CTFontCopyFamilyName(font) as String == "Menlo")
        }
    }

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
