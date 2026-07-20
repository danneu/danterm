// Behavioral proofs for display-scale metrics and overflow-safe frame sizing.
import CoreGraphics
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
        presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
    )
}
