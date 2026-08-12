// Behavioral and bitmap proofs for the complete Unicode Box Drawing sprite family.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning
import TerminalSpriteGeometry

struct BoxDrawingSpriteExecutionTests {
    @Test("Sprite membership is exactly one scalar in the Box Drawing range")
    func exactSupportedSet() {
        for value in UInt32(0x2500)...UInt32(0x257F) {
            #expect(BoxDrawingSprite.pattern(for: Unicode.Scalar(value)!) != nil)
        }
        #expect(BoxDrawingSprite.pattern(for: "\u{24FF}") == nil)
        #expect(BoxDrawingSprite.pattern(for: "\u{2580}") == nil)
    }

    @Test("Every Box Drawing scalar has its exact canonical structural pattern")
    func exhaustivePatternMapping() {
        let actual = (UInt32(0x2500)...UInt32(0x257F)).map {
            patternSignature(BoxDrawingSprite.pattern(for: Unicode.Scalar($0)!)!)
        }.joined(separator: "/")
        #expect(actual == "nlnl/nhnh/lnln/hnhn/Hl3/Hh3/Vl3/Vh3/Hl4/Hh4/Vl4/Vh4/nlln/nhln/nlhn/nhhn/nnll/nnlh/nnhl/nnhh/llnn/lhnn/hlnn/hhnn/lnnl/lnnh/hnnl/hnnh/llln/lhln/hlln/llhn/hlhn/hhln/lhhn/hhhn/lnll/lnlh/hnll/lnhl/hnhl/hnlh/lnhh/hnhh/nlll/nllh/nhll/nhlh/nlhl/nlhh/nhhl/nhhh/llnl/llnh/lhnl/lhnh/hlnl/hlnh/hhnl/hhnh/llll/lllh/lhll/lhlh/hlll/llhl/hlhl/hllh/hhll/llhh/lhhl/hhlh/lhhh/hlhh/hhhl/hhhh/Hl2/Hh2/Vl2/Vh2/ndnd/dndn/ndln/nldn/nddn/nnld/nndl/nndd/ldnn/dlnn/ddnn/lnnd/dnnl/dnnd/ldln/dldn/dddn/lnld/dndl/dndd/ndld/nldl/nddd/ldnd/dlnl/ddnd/ldld/dldl/dddd/ATL/ATR/ABR/ABL/DR/DF/DX/nnnl/lnnn/nlnn/nnln/nnnh/hnnn/nhnn/nnhn/nhnl/lnhn/nlnh/hnln")
    }

    @Test("A box-drawing scalar carrying a combining mark is not reduced to its first scalar")
    func combiningMarkTakesFontPath() throws {
        // Intent: a multi-scalar cell whose first scalar is a box-drawing character must
        //   not be drawn as the procedural sprite for that first scalar; it must take the
        //   font path so the rest of the cluster can affect the result.
        // Why it exists: the executor gates procedural routing on the cell payload having
        //   exactly one scalar. That gate was pinned by a single test, in the Geometric
        //   Shapes family only, which left it resting on one family's behavior while the
        //   cell payload representation underneath it changed.
        // Scenario: rendering U+2500 followed by a combining acute must differ from the
        //   bare U+2500, which draws the procedural horizontal line.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let cell = cellRect(row: 0, column: 0, metrics: metrics)
        let bare = try renderBitmap(
            plan: makePlan(input: "\u{2500}", columns: 2, rows: 1),
            metrics: metrics
        )
        let combined = try renderBitmap(
            plan: makePlan(input: "\u{2500}\u{301}", columns: 2, rows: 1),
            metrics: metrics
        )
        #expect(bare.pixels(in: cell) != combined.pixels(in: cell))
    }

    @Test("All 128 Box Drawing scalars render as cell-local foreground sprites", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        for value in UInt32(0x2500)...UInt32(0x257F) {
            let bitmap = try renderBitmap(
                plan: makePlan(
                    input: "\u{1B}[31m\(String(Unicode.Scalar(value)!))",
                    columns: 2, rows: 1
                ),
                metrics: metrics
            )
            let background = Pixel(RenderTheme.dark.defaultBackground)
            #expect(bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
                .contains { $0 != background })
            #expect(bitmap.pixels(in: cellRect(row: 0, column: 1, metrics: metrics))
                .allSatisfy { $0 == background })
        }
    }

    @Test("Compatible neighboring lines meet while half-lines remain isolated")
    func adjacencyContracts() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let connected = try renderBitmap(
            plan: makePlan(input: "\u{2500}\u{2500}", columns: 2, rows: 1),
            metrics: metrics
        )
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let axis = (metrics.cellHeightPixels - 1) / 2
        #expect(connected.pixel(x: metrics.cellWidthPixels - 1, yFromTop: axis) != background)
        #expect(connected.pixel(x: metrics.cellWidthPixels, yFromTop: axis) != background)

        let isolated = try renderBitmap(
            plan: makePlan(input: "\u{2574}\u{2576}", columns: 2, rows: 1),
            metrics: metrics
        )
        #expect(isolated.pixel(x: metrics.cellWidthPixels - 1, yFromTop: axis) == background)
        #expect(isolated.pixel(x: metrics.cellWidthPixels, yFromTop: axis) == background)
    }

    @Test("Double junction bitmaps preserve center holes, track continuity, and edge contact")
    func doubleJunctionTopology() throws {
        for scale in [CGFloat(1), 2] {
            let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
            let bitmap = try renderBitmap(
                plan: makePlan(input: "\u{256C}\u{2550}", columns: 2, rows: 1),
                metrics: metrics
            )
            let background = Pixel(RenderTheme.dark.defaultBackground)
            let centerX = metrics.cellWidthPixels / 2
            let centerY = metrics.cellHeightPixels / 2
            #expect(bitmap.pixel(x: centerX, yFromTop: centerY) == background)
            let geometry = BoxDrawingSpriteGeometry.geometry(
                pattern: .lines(.init(up: .double, right: .double, down: .double, left: .double)),
                cellWidthPixels: metrics.cellWidthPixels,
                cellHeightPixels: metrics.cellHeightPixels,
                lightStrokePixels: max(
                    1,
                    Int((metrics.underlineThickness * metrics.displayScale).rounded())
                )
            )
            for rect in geometry.rects {
                #expect(bitmap.pixel(
                    x: rect.x + rect.width / 2,
                    yFromTop: rect.y + rect.height / 2
                ) != background)
            }
            let rightTracks = geometry.rects.filter { $0.x + $0.width == metrics.cellWidthPixels }
            for track in rightTracks {
                let y = track.y + track.height / 2
                #expect(bitmap.pixel(x: metrics.cellWidthPixels - 1, yFromTop: y) != background)
                #expect(bitmap.pixel(x: metrics.cellWidthPixels, yFromTop: y) != background)
            }
        }
    }

    @Test("Centered dashed neighbors preserve their deliberate boundary gap horizontally and vertically")
    func dashedAdjacency() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let horizontal = try renderBitmap(
            plan: makePlan(input: "\u{254D}\u{254D}", columns: 2, rows: 1),
            metrics: metrics
        )
        let y = metrics.cellHeightPixels / 2
        #expect(horizontal.pixel(x: metrics.cellWidthPixels - 1, yFromTop: y) == background)
        #expect(horizontal.pixel(x: metrics.cellWidthPixels, yFromTop: y) == background)

        let vertical = try renderBitmap(
            plan: makePlan(input: "\u{254F}\r\n\u{254F}", columns: 2, rows: 2),
            metrics: metrics
        )
        let x = metrics.cellWidthPixels / 2
        #expect(vertical.pixel(x: x, yFromTop: metrics.cellHeightPixels - 1) == background)
        #expect(vertical.pixel(x: x, yFromTop: metrics.cellHeightPixels) == background)
    }

    @Test("Sprite replacement and both incremental redraw paths match a fresh frame")
    func replacementAndIncrementalRedraws() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let previous = try makePlan(input: "\u{256C}\r\nkeep", columns: 4, rows: 2)
        for replacement in ["A", "\u{2573}"] {
            let current = try makePlan(input: "\(replacement)\r\nkeep", columns: 4, rows: 2)
            let full = try renderBitmap(plan: current, metrics: metrics)
            let damaged = try renderIncrementalBitmap(
                previous: previous, current: current,
                damage: TerminalDamage(rows: [0]), metrics: metrics
            )
            let dirty = try renderDirtyRectBitmap(
                previous: previous, current: current,
                dirtyRect: CGRect(
                    x: 0, y: 0, width: metrics.cellSize.width * 4,
                    height: metrics.cellSize.height
                ),
                metrics: metrics
            )
            expectBitmap(damaged, matches: full)
            expectBitmap(dirty, matches: full)
        }
    }
}

private func patternSignature(_ pattern: BoxDrawingPattern) -> String {
    switch pattern {
    case let .lines(lines):
        return [lines.up, lines.right, lines.down, lines.left].map {
            switch $0 {
            case .none: "n"
            case .light: "l"
            case .heavy: "h"
            case .double: "d"
            }
        }.joined()
    case let .dashed(axis, weight, count):
        return "\(axis == .horizontal ? "H" : "V")\(weight == .heavy ? "h" : "l")\(count)"
    case let .arc(corner):
        return switch corner {
        case .topLeft: "ATL"
        case .topRight: "ATR"
        case .bottomLeft: "ABL"
        case .bottomRight: "ABR"
        }
    case let .diagonal(diagonal):
        return switch diagonal {
        case .rising: "DR"
        case .falling: "DF"
        case .cross: "DX"
        }
    }
}
