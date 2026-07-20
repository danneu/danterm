// Pixel-level proofs for opaque frame clearing and background-run geometry.
import CoreGraphics
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

struct BackgroundExecutionTests {
    @Test("Adjacent backgrounds tile without cracks at representative scales", arguments: [1.0, 2.0, 1.5])
    func adjacentBackgroundsTile(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        var terminal = try #require(Terminal(columns: 5, rows: 1))
        terminal.feed(Array("\u{1B}[41m  \u{1B}[42m  \u{1B}[49m ".utf8))
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let y = metrics.cellHeightPixels / 2

        for x in 0..<bitmap.width {
            let column = x / metrics.cellWidthPixels
            let expected: Pixel = switch column {
            case 0, 1: Pixel(RenderTheme.dark.ansiColors[1])
            case 2, 3: Pixel(RenderTheme.dark.ansiColors[2])
            default: Pixel(RenderTheme.dark.defaultBackground)
            }
            #expect(bitmap.pixel(x: x, yFromTop: y) == expected)
        }
    }

    @Test("Drawing an overflowing frame leaves the context untouched")
    func overflowingFrameDoesNoWork() throws {
        let metrics = try #require(largestOverflowingMetrics())
        let plan = try makeTwoColumnPlan()
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 37, count: 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: storage,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))

        drawRenderFrame(plan, metrics: metrics, in: context)

        #expect(Array(UnsafeRawBufferPointer(start: storage, count: 4)) == [37, 37, 37, 37])
    }
}

private func largestOverflowingMetrics() -> TerminalRenderMetrics? {
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

private func makeTwoColumnPlan() throws -> RenderFramePlan {
    let terminal = try #require(Terminal(columns: 2, rows: 1))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
    )
}
