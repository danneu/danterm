// AppKit/CoreText/CoreGraphics execution of deterministic terminal render plans.
import AppKit
import CoreGraphics
import CoreText
import TerminalRenderPlanning

/// Fixes the regular 13 pt system-monospace grid geometry for one explicit
/// display scale so later font choices cannot move terminal cell boundaries.
public struct TerminalRenderMetrics: Equatable, Sendable {
    /// The caller-provided point-to-backing-pixel scale.
    public let displayScale: CGFloat

    /// Pixel-quantized cell dimensions expressed in point space.
    public let cellSize: CGSize

    /// Cell width as an exact whole backing-pixel count.
    public let cellWidthPixels: Int

    /// Cell height as an exact whole backing-pixel count.
    public let cellHeightPixels: Int

    /// Top-edge-to-baseline distance in point space.
    public let baselineOffset: CGFloat

    /// Top-edge offset for the primary underline in point space.
    public let underlineOffset: CGFloat

    /// Pixel-snapped decoration thickness, never less than one backing pixel.
    public let underlineThickness: CGFloat

    /// Top-edge offset for strikethrough in point space.
    public let strikethroughOffset: CGFloat

    let baseFontName: String
    let unquantizedLineHeight: CGFloat

    /// Returns nil when scale or any derived cell dimension cannot be represented safely.
    public init?(displayScale: CGFloat) {
        guard displayScale.isFinite, displayScale > 0 else { return nil }

        let appKitFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let font = CTFontCreateWithName(appKitFont.fontName as CFString, 13, nil)
        var character = UniChar(0x004D)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return nil }

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        guard let cellWidthPixels = quantizedPixelCount(advance.width, scale: displayScale),
              let cellHeightPixels = quantizedPixelCount(lineHeight, scale: displayScale),
              let baselinePixels = quantizedPixelCount(ascent, scale: displayScale),
              let underlinePixels = quantizedPixelCount(
                  max(CTFontGetUnderlineThickness(font), 1 / displayScale),
                  scale: displayScale
              )
        else {
            return nil
        }

        self.displayScale = displayScale
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
        self.cellSize = CGSize(
            width: CGFloat(cellWidthPixels) / displayScale,
            height: CGFloat(cellHeightPixels) / displayScale
        )
        self.baselineOffset = min(
            CGFloat(baselinePixels) / displayScale,
            CGFloat(cellHeightPixels) / displayScale
        )
        self.underlineThickness = CGFloat(underlinePixels) / displayScale
        self.underlineOffset = min(
            self.cellSize.height - self.underlineThickness,
            max(0, self.baselineOffset - CTFontGetUnderlinePosition(font))
        )
        self.strikethroughOffset = min(
            self.cellSize.height - self.underlineThickness,
            max(0, self.baselineOffset - CTFontGetXHeight(font) / 2)
        )
        self.baseFontName = appKitFont.fontName
        self.unquantizedLineHeight = lineHeight
    }
}

/// Pairs a frame's point-space extent with the exact backing-pixel allocation
/// required by the metrics, refusing integer multiplication overflow.
public struct RenderFrameSize: Equatable, Sendable {
    /// Frame extent in the executor's point-space coordinate system.
    public let pointSize: CGSize

    /// Backing-store width in whole pixels.
    public let pixelWidth: Int

    /// Backing-store height in whole pixels.
    public let pixelHeight: Int

    init(pointSize: CGSize, pixelWidth: Int, pixelHeight: Int) {
        self.pointSize = pointSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Derives the complete frame extent without trapping on a plan whose grid
/// dimensions overflow the metrics' backing-pixel counts.
public func renderFrameSize(
    for plan: RenderFramePlan,
    metrics: TerminalRenderMetrics
) -> RenderFrameSize? {
    guard plan.columns > 0, plan.rows > 0 else { return nil }
    let width = metrics.cellWidthPixels.multipliedReportingOverflow(by: plan.columns)
    let height = metrics.cellHeightPixels.multipliedReportingOverflow(by: plan.rows)
    guard width.overflow == false, height.overflow == false,
          width.partialValue > 0, height.partialValue > 0
    else {
        return nil
    }

    let pointSize = CGSize(
        width: metrics.cellSize.width * CGFloat(plan.columns),
        height: metrics.cellSize.height * CGFloat(plan.rows)
    )
    guard pointSize.width.isFinite, pointSize.height.isFinite else { return nil }
    return RenderFrameSize(
        pointSize: pointSize,
        pixelWidth: width.partialValue,
        pixelHeight: height.partialValue
    )
}

/// Executes the opaque frame clear and planned background spans while borrowing
/// the caller's context without retaining or changing its graphics state.
public func drawRenderFrame(
    _ plan: RenderFramePlan,
    metrics: TerminalRenderMetrics,
    in context: CGContext
) {
    guard let frameSize = renderFrameSize(for: plan, metrics: metrics),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
        return
    }

    let originalTextMatrix = context.textMatrix
    context.saveGState()
    defer {
        context.textMatrix = originalTextMatrix
        context.restoreGState()
    }

    context.setBlendMode(.copy)
    context.setFillColor(plan.defaultBackground.cgColor(in: colorSpace))
    context.fill(CGRect(origin: .zero, size: frameSize.pointSize))

    for run in plan.backgroundRuns {
        context.setFillColor(run.color.cgColor(in: colorSpace))
        context.fill(CGRect(
            x: CGFloat(run.startColumn) * metrics.cellSize.width,
            y: CGFloat(run.row) * metrics.cellSize.height,
            width: CGFloat(run.columnCount) * metrics.cellSize.width,
            height: metrics.cellSize.height
        ))
    }
}

private func quantizedPixelCount(_ pointValue: CGFloat, scale: CGFloat) -> Int? {
    guard pointValue.isFinite, pointValue > 0 else { return nil }
    let scaled = pointValue * scale
    guard scaled.isFinite, scaled > 0 else { return nil }
    let rounded = scaled.rounded(.up)
    guard rounded.isFinite, rounded < CGFloat(Int.max) else { return nil }
    let pixels = Int(rounded)
    guard pixels > 0, CGFloat(pixels) == rounded else { return nil }
    return pixels
}

private extension RenderColor {
    func cgColor(in colorSpace: CGColorSpace) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat(red) / 255,
                CGFloat(green) / 255,
                CGFloat(blue) / 255,
                1,
            ]
        )!
    }
}
