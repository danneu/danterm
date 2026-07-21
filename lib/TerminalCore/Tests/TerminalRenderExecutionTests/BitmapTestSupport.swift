// Headless sRGB bitmap construction and cell-scoped pixel probes shared by executor tests.
import CoreGraphics
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

struct Pixel: Equatable {
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

struct PixelRect {
    let x: Range<Int>
    let y: Range<Int>
}

struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(x: Int, yFromTop: Int) -> Pixel {
        let memoryRow = yFromTop
        let offset = (memoryRow * width + x) * 4
        return Pixel(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }

    func pixels(in rect: PixelRect) -> [Pixel] {
        rect.y.flatMap { y in
            rect.x.map { x in pixel(x: x, yFromTop: y) }
        }
    }

    func bytes(in rect: PixelRect) -> [UInt8] {
        pixels(in: rect).flatMap { [$0.red, $0.green, $0.blue, $0.alpha] }
    }

    func inkCount(in rect: PixelRect, background: RenderColor = RenderTheme.dark.defaultBackground) -> Int {
        let backgroundPixel = Pixel(background)
        return pixels(in: rect).count { $0 != backgroundPixel }
    }

    func inkRows(in rect: PixelRect, background: RenderColor = RenderTheme.dark.defaultBackground) -> [Int] {
        let backgroundPixel = Pixel(background)
        return rect.y.filter { y in
            rect.x.contains { x in pixel(x: x, yFromTop: y) != backgroundPixel }
        }
    }
}

final class BitmapSurface {
    let width: Int
    let height: Int
    private(set) var context: CGContext?

    private let data: UnsafeMutableRawPointer
    private let byteCount: Int

    init(size: RenderFrameSize, metrics: TerminalRenderMetrics) throws {
        let pixelCount = size.pixelWidth.multipliedReportingOverflow(by: size.pixelHeight)
        try #require(pixelCount.overflow == false)
        let byteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        try #require(byteCount.overflow == false)

        let allocatedData = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount.partialValue,
            alignment: MemoryLayout<UInt32>.alignment
        )
        allocatedData.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: byteCount.partialValue
        )

        do {
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: allocatedData,
                width: size.pixelWidth,
                height: size.pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: size.pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.translateBy(x: 0, y: CGFloat(size.pixelHeight))
            context.scaleBy(x: metrics.displayScale, y: -metrics.displayScale)

            width = size.pixelWidth
            height = size.pixelHeight
            self.byteCount = byteCount.partialValue
            data = allocatedData
            self.context = context
        } catch {
            allocatedData.deallocate()
            throw error
        }
    }

    deinit {
        context = nil
        data.deallocate()
    }

    func bitmap() -> Bitmap {
        Bitmap(
            width: width,
            height: height,
            bytes: Array(UnsafeRawBufferPointer(start: data, count: byteCount))
        )
    }
}

func cellRect(
    row: Int,
    column: Int,
    columnCount: Int = 1,
    metrics: TerminalRenderMetrics
) -> PixelRect {
    PixelRect(
        x: column * metrics.cellWidthPixels..<(column + columnCount) * metrics.cellWidthPixels,
        y: row * metrics.cellHeightPixels..<(row + 1) * metrics.cellHeightPixels
    )
}

func renderBitmap(plan: RenderFramePlan, metrics: TerminalRenderMetrics) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)
    drawRenderFrame(plan, metrics: metrics, in: context)
    return surface.bitmap()
}

func renderIncrementalBitmap(
    previous: RenderFramePlan,
    current: RenderFramePlan,
    damage: TerminalDamage,
    metrics: TerminalRenderMetrics
) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: current, metrics: metrics))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)
    drawRenderFrame(previous, metrics: metrics, in: context)
    context.saveGState()
    for row in damage.rows where current.rows > row {
        context.addRect(CGRect(
            x: 0,
            y: CGFloat(row) * metrics.cellSize.height,
            width: size.pointSize.width,
            height: metrics.cellSize.height
        ))
    }
    context.clip()
    drawRenderFrame(clipFramePlan(current, to: damage), metrics: metrics, in: context)
    context.restoreGState()
    return surface.bitmap()
}

func makePlan(
    input: String,
    columns: Int,
    rows: Int,
    isCursorVisible: Bool = false
) throws -> RenderFramePlan {
    var terminal = try #require(Terminal(columns: columns, rows: rows))
    terminal.feed(Array(input.utf8))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(theme: .dark, isCursorVisible: isCursorVisible)
    )
}
