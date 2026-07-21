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
    let baseFontSize: CGFloat
    let unquantizedLineHeight: CGFloat

    /// Returns nil when scale or any derived cell dimension cannot be represented safely.
    public init?(displayScale: CGFloat) {
        guard displayScale.isFinite, displayScale > 0 else { return nil }

        let fontSize: CGFloat = 13
        let appKitFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let font = CTFontCreateWithName(appKitFont.fontName as CFString, fontSize, nil)
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
        self.underlineOffset = pixelAlignedOffset(
            self.baselineOffset - CTFontGetUnderlinePosition(font),
            scale: displayScale,
            cellPixels: cellHeightPixels,
            thicknessPixels: underlinePixels
        )
        self.strikethroughOffset = pixelAlignedOffset(
            self.baselineOffset - CTFontGetXHeight(font) / 2,
            scale: displayScale,
            cellPixels: cellHeightPixels,
            thicknessPixels: underlinePixels
        )
        self.baseFontName = appKitFont.fontName
        self.baseFontSize = fontSize
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

/// Executes every planned layer in fixed order while borrowing the caller's
/// context without retaining or changing its state.
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

    context.setFillColor(plan.selectionBackground.cgColor(in: colorSpace))
    for run in plan.selectionRuns {
        context.fill(CGRect(
            x: CGFloat(run.startColumn) * metrics.cellSize.width,
            y: CGFloat(run.row) * metrics.cellSize.height,
            width: CGFloat(run.columnCount) * metrics.cellSize.width,
            height: metrics.cellSize.height
        ))
    }

    context.drawTextRuns(
        plan.textRuns,
        metrics: metrics,
        colorSpace: colorSpace
    )
    context.textMatrix = originalTextMatrix
    context.drawDecorationRuns(
        plan.decorationRuns,
        metrics: metrics,
        colorSpace: colorSpace
    )
    if let cursor = plan.cursor {
        context.drawCursor(cursor, metrics: metrics, colorSpace: colorSpace)
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

/// Quantizes a decoration's top edge without allowing its thickness outside the row.
private func pixelAlignedOffset(
    _ pointValue: CGFloat,
    scale: CGFloat,
    cellPixels: Int,
    thicknessPixels: Int
) -> CGFloat {
    let maximum = CGFloat(cellPixels - thicknessPixels)
    let pixels = min(maximum, max(0, (pointValue * scale).rounded()))
    return pixels / scale
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

private extension TerminalRenderMetrics {
    func font(bold: Bool, italic: Bool) -> CTFont {
        let regular = CTFontCreateWithName(baseFontName as CFString, baseFontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        guard traits.isEmpty == false else { return regular }
        return CTFontCreateCopyWithSymbolicTraits(
            regular,
            0,
            nil,
            traits,
            [.boldTrait, .italicTrait]
        ) ?? regular
    }
}

private extension CGContext {
    func drawCursor(
        _ cursor: RenderCursor,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace
    ) {
        guard cursor.shape != .block else { return }
        let cellRect = CGRect(
            x: CGFloat(cursor.column) * metrics.cellSize.width,
            y: CGFloat(cursor.row) * metrics.cellSize.height,
            width: CGFloat(cursor.columnWidth) * metrics.cellSize.width,
            height: metrics.cellSize.height
        )
        let thickness = metrics.underlineThickness
        let overlayRect: CGRect
        switch cursor.shape {
        case .block:
            return
        case .underline:
            overlayRect = CGRect(
                x: cellRect.minX,
                y: cellRect.maxY - thickness,
                width: cellRect.width,
                height: thickness
            )
        case .bar:
            overlayRect = CGRect(
                x: cellRect.minX,
                y: cellRect.minY,
                width: thickness,
                height: cellRect.height
            )
        }

        saveGState()
        clip(to: cellRect)
        setBlendMode(.copy)
        setFillColor(cursor.color.cgColor(in: colorSpace))
        fill(overlayRect)
        restoreGState()
    }

    func drawTextRuns(
        _ runs: [RenderTextRun],
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace
    ) {
        setBlendMode(.normal)
        for run in runs {
            let font = metrics.font(bold: run.bold, italic: run.italic)
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    run.foreground.cgColor(in: colorSpace),
                kCTLigatureAttributeName as NSAttributedString.Key: 0,
            ]
            var column = run.startColumn
            for cell in run.cells {
                drawTextCell(
                    cell,
                    row: run.row,
                    column: column,
                    attributes: attributes,
                    metrics: metrics
                )
                column += cell.columnWidth
            }
        }
    }

    func drawTextCell(
        _ cell: RenderTextCell,
        row: Int,
        column: Int,
        attributes: [NSAttributedString.Key: Any],
        metrics: TerminalRenderMetrics
    ) {
        let cellRect = CGRect(
            x: CGFloat(column) * metrics.cellSize.width,
            y: CGFloat(row) * metrics.cellSize.height,
            width: CGFloat(cell.columnWidth) * metrics.cellSize.width,
            height: metrics.cellSize.height
        )
        var scalarView = String.UnicodeScalarView()
        scalarView.append(contentsOf: cell.scalars)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(scalarView),
            attributes: attributes
        ))

        saveGState()
        clip(to: cellRect)
        // CoreText expects y-up text space, so reflect the glyph outlines while
        // keeping the baseline measured down from the cell's top edge.
        textMatrix = CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: cellRect.minX,
            ty: cellRect.minY + metrics.baselineOffset
        )
        CTLineDraw(line, self)
        restoreGState()
    }

    func drawDecorationRuns(
        _ runs: [RenderDecorationRun],
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace
    ) {
        for run in runs {
            let runRect = CGRect(
                x: CGFloat(run.startColumn) * metrics.cellSize.width,
                y: CGFloat(run.row) * metrics.cellSize.height,
                width: CGFloat(run.columnCount) * metrics.cellSize.width,
                height: metrics.cellSize.height
            )
            saveGState()
            clip(to: runRect)
            setBlendMode(.copy)
            setFillColor(run.color.cgColor(in: colorSpace))
            setStrokeColor(run.color.cgColor(in: colorSpace))

            for kind in run.kinds {
                switch kind {
                case .underlineSingle:
                    fillDecorationBar(
                        in: runRect,
                        top: CGFloat(run.row) * metrics.cellSize.height
                            + metrics.underlineOffset,
                        thickness: metrics.underlineThickness
                    )
                case .underlineDouble:
                    let upperOffset = metrics.underlineOffset
                        - metrics.underlineThickness * 2
                    fillDecorationBar(
                        in: runRect,
                        top: CGFloat(run.row) * metrics.cellSize.height + upperOffset,
                        thickness: metrics.underlineThickness
                    )
                    fillDecorationBar(
                        in: runRect,
                        top: CGFloat(run.row) * metrics.cellSize.height
                            + metrics.underlineOffset,
                        thickness: metrics.underlineThickness
                    )
                case .underlineCurly:
                    strokeCurlyUnderline(in: runRect, metrics: metrics)
                case .strikethrough:
                    fillDecorationBar(
                        in: runRect,
                        top: CGFloat(run.row) * metrics.cellSize.height
                            + metrics.strikethroughOffset,
                        thickness: metrics.underlineThickness
                    )
                }
            }
            restoreGState()
        }
    }

    func fillDecorationBar(in runRect: CGRect, top: CGFloat, thickness: CGFloat) {
        fill(CGRect(x: runRect.minX, y: top, width: runRect.width, height: thickness))
    }

    func strokeCurlyUnderline(in runRect: CGRect, metrics: TerminalRenderMetrics) {
        let deviceStep = 1 / metrics.displayScale
        let amplitude = max(metrics.underlineThickness, deviceStep)
        let period = max(metrics.cellSize.width, deviceStep * 4)
        let centerY = runRect.minY + metrics.underlineOffset - amplitude
        let firstValue = (runRect.minX / deviceStep).rounded(.down)
        let lastValue = (runRect.maxX / deviceStep).rounded(.up)
        guard firstValue.isFinite, lastValue.isFinite,
              firstValue >= 0, lastValue >= 0,
              firstValue < CGFloat(Int.max), lastValue < CGFloat(Int.max)
        else {
            return
        }
        let firstResult = Int(firstValue).subtractingReportingOverflow(1)
        let lastResult = Int(lastValue).addingReportingOverflow(1)
        guard firstResult.overflow == false, lastResult.overflow == false else { return }
        let firstSample = firstResult.partialValue
        let lastSample = lastResult.partialValue
        let path = CGMutablePath()

        for sample in firstSample...lastSample {
            let x = CGFloat(sample) * deviceStep
            let y = centerY + amplitude * sin(2 * .pi * x / period)
            if sample == firstSample {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        addPath(path)
        setLineWidth(metrics.underlineThickness)
        setLineCap(.butt)
        setLineJoin(.round)
        strokePath()
    }
}
