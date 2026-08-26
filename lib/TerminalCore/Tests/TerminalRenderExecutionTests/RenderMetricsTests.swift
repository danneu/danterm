// Behavioral proofs for display-scale metrics, its styled font set, and
// overflow-safe frame sizing.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct RenderMetricsTests {
    @Test("Configured font size changes cell metrics and rejects invalid sizes")
    func configuredFontSizeChangesMetrics() throws {
        let defaultMetrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let largerMetrics = try #require(TerminalRenderMetrics(displayScale: 2, fontChoice: TerminalFontChoice(size: 20)))

        #expect(largerMetrics.fontChoice.size == 20)
        #expect(largerMetrics.cellSize.width > defaultMetrics.cellSize.width)
        #expect(largerMetrics.cellSize.height > defaultMetrics.cellSize.height)
        for size in [0, -1, .nan, .infinity] as [CGFloat] {
            #expect(TerminalRenderMetrics(displayScale: 2, fontChoice: TerminalFontChoice(size: size)) == nil)
        }
    }

    @Test("Metrics republish every input their own rebuild needs", arguments: [nil, "Menlo"] as [String?])
    func metricsRoundTripTheirFontChoice(family: String?) throws {
        // Intent: reading a metrics value's font choice back and rebuilding from it at
        //   a different display scale gives the same value as building directly from
        //   that choice at that scale.
        // Why it exists: metrics are derived per surface and are only valid at the
        //   scale they name, so every embedder has to rebuild them when its window
        //   moves between displays. Before this, the font inputs were internal, and
        //   three surfaces each kept a shadow copy of them to rebuild from -- copies
        //   that drift, and did: MiniTerm rendered a moved window at the wrong scale.
        // Scenario: spec-first -- a window holding a pane is dragged from a 2x display
        //   to a 1x one, and the surface rebuilds its metrics from what it has.
        let choice = TerminalFontChoice(family: family, size: 17)
        let atTwo = try #require(TerminalRenderMetrics(displayScale: 2, fontChoice: choice))

        #expect(atTwo.fontChoice == choice)
        // An absent family resolves to a concrete system face, and must still report
        // the request rather than that resolution -- a caller that rebuilt from the
        // resolved name would stop following the system face.
        #expect(atTwo.fontChoice.family == family)

        let atOne = try #require(
            TerminalRenderMetrics(displayScale: 1, fontChoice: atTwo.fontChoice)
        )
        let direct = try #require(TerminalRenderMetrics(displayScale: 1, fontChoice: choice))

        #expect(atOne == direct)
        #expect(atOne.fontChoice == choice)
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
        let explicitNil = try #require(TerminalRenderMetrics(displayScale: 2, fontChoice: TerminalFontChoice(family: nil)))

        #expect(implicit == explicitNil)
        #expect(implicit.fonts == explicitNil.fonts)
        #expect(
            explicitNil.baseFontName
                == PlatformFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
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
        let menlo = try #require(TerminalRenderMetrics(displayScale: 2, fontChoice: TerminalFontChoice(family: "Menlo")))
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
        // Why it exists: only the availability probe's canonical family may reach
        //   rendering, and the schema deliberately has no per-style families, so the
        //   render layer must derive bold and italic from that verified base family.
        // Scenario: spec-first -- terminal output mixes styles under a custom family.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2, fontChoice: TerminalFontChoice(family: "Menlo")))
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
            #expect(CTFontGetSize(font) == metrics.fontChoice.size)
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
        let plan = try makePlan(input: "", columns: 7, rows: 3)
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
        let plan = try makePlan(input: "", columns: 2, rows: 1)
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
