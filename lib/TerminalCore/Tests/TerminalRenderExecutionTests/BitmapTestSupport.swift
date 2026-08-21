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

/// Compares two rendered surfaces and reports a mismatch without diffing them.
///
/// Never write `#expect(a.bytes == b.bytes)` here. Swift Testing renders a failed
/// comparison of two collections by computing
/// `BidirectionalCollection.difference(from:)`, whose cost grows about
/// quadratically -- four seconds at 32 KiB. A 60x20 grid at `displayScale: 2` is
/// about 2.4 million bytes per side, and a diff that size does not finish: the
/// test process spins at full CPU, no `.timeLimit` can unwind it because the diff
/// never yields, and the run has to be killed from outside. That is how the
/// TerminalPTY lane was wedging before its own megabyte comparison was replaced.
///
/// The first differing pixel is also a better answer than an edit script, since
/// these surfaces differ by a region rather than by an insertion.
///
/// Returns whether the surfaces matched, for the callers that stop at the first
/// divergence rather than reporting every one.
@discardableResult
func expectBitmap(
    _ actual: Bitmap,
    matches expected: Bitmap,
    _ label: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    guard
        actual.width != expected.width
            || actual.height != expected.height
            || actual.bytes != expected.bytes
    else { return true }

    let prefix = label.map { "\($0): " } ?? ""
    guard actual.width == expected.width, actual.height == expected.height else {
        let sizes = "\(actual.width)x\(actual.height) != \(expected.width)x\(expected.height)"
        Issue.record("\(prefix)surfaces differ in size: \(sizes)", sourceLocation: sourceLocation)
        return false
    }

    var index = 0
    while index < min(actual.bytes.count, expected.bytes.count),
        actual.bytes[index] == expected.bytes[index]
    {
        index += 1
    }
    let pixelIndex = index / 4
    let x = pixelIndex % max(actual.width, 1)
    let y = pixelIndex / max(actual.width, 1)
    let where_ = "pixel (\(x), \(y)) of \(actual.width)x\(actual.height)"
    let values = "\(actual.pixel(x: x, yFromTop: y)) != \(expected.pixel(x: x, yFromTop: y))"
    Issue.record("\(prefix)first differs at \(where_): \(values)", sourceLocation: sourceLocation)
    return false
}

final class BitmapSurface {
    let width: Int
    let height: Int
    private(set) var context: CGContext?

    private let data: UnsafeMutableRawPointer
    private let byteCount: Int

    init(
        size: RenderFrameSize,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace? = nil
    ) throws {
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
            let colorSpace = try #require(
                colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
            )
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
    // The incremental consumer here models the view before research/33 T9's view
    // half: it cannot translate its backing store, so a carried shift folds into
    // region-wide row damage before clipping.
    damage.expandingShift().forEachRow { row in
        guard current.rowCount > row else { return }
        context.addRect(CGRect(
            x: 0,
            y: CGFloat(row) * metrics.cellSize.height,
            width: size.pointSize.width,
            height: metrics.cellSize.height
        ))
    }
    context.clip()
    drawRenderFrame(
        current,
        restrictedTo: damage.expandingShift(),
        metrics: metrics,
        in: context
    )
    context.restoreGState()
    return surface.bitmap()
}

func renderDirtyRectBitmap(
    previous: RenderFramePlan,
    current: RenderFramePlan,
    dirtyRect: CGRect,
    metrics: TerminalRenderMetrics
) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: current, metrics: metrics))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)
    drawRenderFrame(previous, metrics: metrics, in: context)
    let rows = terminalRows(
        intersecting: dirtyRect,
        metrics: metrics,
        rowCount: current.rowCount
    )
    context.saveGState()
    context.clip(to: dirtyRect)
    drawRenderFrame(
        current,
        restrictedTo: rows == 0..<current.rowCount
            ? nil
            : TerminalDamage(rows: rows, rowCount: current.rowCount),
        metrics: metrics,
        in: context
    )
    context.restoreGState()
    return surface.bitmap()
}

func makePlan(
    input: String,
    columns: Int,
    rows: Int,
    isCursorVisible: Bool = false,
    cursorShape: TerminalCursorShape = .block
) throws -> RenderFramePlan {
    var terminal = try #require(Terminal(columns: columns, rows: rows))
    terminal.feed(Array(input.utf8))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: isCursorVisible,
            cursorShape: cursorShape
        )
    )
}
