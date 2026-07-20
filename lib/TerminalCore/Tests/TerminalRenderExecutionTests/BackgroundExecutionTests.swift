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

private struct Pixel: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: RenderColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

private struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(x: Int, yFromTop: Int) -> Pixel {
        let memoryRow = height - yFromTop - 1
        let offset = (memoryRow * width + x) * 4
        return Pixel(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }
}

private func renderBitmap(plan: RenderFramePlan, metrics: TerminalRenderMetrics) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let pixelCount = size.pixelWidth.multipliedReportingOverflow(by: size.pixelHeight)
    try #require(pixelCount.overflow == false)
    let byteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
    try #require(byteCount.overflow == false)
    let bytesPerRow = size.pixelWidth * 4
    let data = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount.partialValue,
        alignment: MemoryLayout<UInt32>.alignment
    )
    defer { data.deallocate() }
    data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount.partialValue)

    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: data,
        width: size.pixelWidth,
        height: size.pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    ))
    context.translateBy(x: 0, y: CGFloat(size.pixelHeight))
    context.scaleBy(x: metrics.displayScale, y: -metrics.displayScale)
    drawRenderFrame(plan, metrics: metrics, in: context)

    return Bitmap(
        width: size.pixelWidth,
        height: size.pixelHeight,
        bytes: Array(UnsafeRawBufferPointer(start: data, count: byteCount.partialValue))
    )
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
