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
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
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

    @Test("Background rows follow the same top-left grid as text")
    func backgroundRowOrder() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "\u{1B}[41m  \u{1B}[2;1H\u{1B}[42m  ",
            columns: 3,
            rows: 2
        )
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let x = metrics.cellWidthPixels / 2
        let rowZeroY = metrics.cellHeightPixels / 2
        let rowOneY = metrics.cellHeightPixels + rowZeroY

        #expect(bitmap.pixel(x: x, yFromTop: rowZeroY) == Pixel(RenderTheme.dark.ansiColors[1]))
        #expect(bitmap.pixel(x: x, yFromTop: rowOneY) == Pixel(RenderTheme.dark.ansiColors[2]))
    }

    @Test("Drawing an overflowing frame leaves the context untouched")
    func overflowingFrameDoesNoWork() throws {
        let metrics = try #require(largestMetricsWhoseTwoColumnFrameOverflows())
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

private func makeTwoColumnPlan() throws -> RenderFramePlan {
    let terminal = try #require(Terminal(columns: 2, rows: 1))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
    )
}
