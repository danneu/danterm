// AppKit/CoreText/CoreGraphics execution of deterministic terminal render plans.
import AppKit
import CoreGraphics
import CoreText
import TerminalRenderPlanning
import TerminalSpriteGeometry

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

/// Converts AppKit's point-space repaint region into the exact grid rows whose
/// contents must be present in a clipped frame plan.
public func terminalRows(
    intersecting dirtyRect: CGRect,
    metrics: TerminalRenderMetrics,
    rowCount: Int
) -> Range<Int> {
    guard rowCount > 0, dirtyRect.isEmpty == false,
          dirtyRect.minY.isFinite, dirtyRect.maxY.isFinite
    else {
        return 0..<0
    }

    let gridHeight = metrics.cellSize.height * CGFloat(rowCount)
    guard gridHeight.isFinite else { return 0..<0 }
    let clippedMinY = max(0, dirtyRect.minY)
    let clippedMaxY = min(gridHeight, dirtyRect.maxY)
    guard clippedMinY < clippedMaxY else { return 0..<0 }

    let lowerRow = max(0, Int(floor(clippedMinY / metrics.cellSize.height)))
    let upperRow = min(
        rowCount,
        Int(ceil(clippedMaxY / metrics.cellSize.height))
    )
    return lowerRow..<max(lowerRow, upperRow)
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
        let regularFont = metrics.font(bold: false, italic: false)
        let boldFont = metrics.font(bold: true, italic: false)
        let italicFont = metrics.font(bold: false, italic: true)
        let boldItalicFont = metrics.font(bold: true, italic: true)
        var colors: [UInt32: CGColor] = [:]
        // Built lazily on the first braille cell and reused for the rest of the
        // draw: the braille dot layout depends only on `metrics` (constant across
        // a draw), so this pays at most one `BraillePixelLayout` construction per
        // draw that contains braille, and none for text-only draws.
        var brailleLayout: BraillePixelLayout?

        for run in runs {
            let font = switch (run.bold, run.italic) {
            case (false, false): regularFont
            case (true, false): boldFont
            case (false, true): italicFont
            case (true, true): boldItalicFont
            }
            let colorKey = UInt32(run.foreground.red) << 16
                | UInt32(run.foreground.green) << 8
                | UInt32(run.foreground.blue)
            let foreground = colors[colorKey] ?? run.foreground.cgColor(in: colorSpace)
            colors[colorKey] = foreground
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: foreground,
                kCTLigatureAttributeName as NSAttributedString.Key: 0,
            ]
            var characters: [UniChar] = []
            var candidateCells: [(cell: RenderTextCell, column: Int)] = []
            var fallbackCells: [(cell: RenderTextCell, column: Int)] = []
            var spriteRects: [CGRect] = []
            var shadedSpriteRects: [BlockElementShade: [CGRect]] = [:]
            var geometricShapeTriangles: [GeometricShapeRenderTriangle] = []
            var powerlinePaths: [PowerlineRenderPath] = []
            var branchDrawingGeometries: [BranchDrawingRenderGeometry] = []
            var legacySpriteRects: [UInt8: [CGRect]] = [:]
            var boxDrawingStrokes: [BoxDrawingRenderStroke] = []
            var column = run.startColumn
            for cell in run.cells {
                // Direct single-scalar family routing. A cell can only be a sprite when it is
                // exactly one scalar, and every supported family occupies a scalar range
                // disjoint from the others, so route to the single family whose range can
                // contain the scalar instead of testing all eight in order. Exact membership
                // and pattern decoding stay inside each family: a routed family that returns
                // nil (a sparse gap inside its range, e.g. an unmapped Geometric or Powerline
                // scalar, or a Geometric pattern with no representable triangle) falls through
                // to the font path exactly as the former ordered chain did, because no other
                // family's range could have matched it either. Multi-scalar and out-of-range
                // cells skip classification entirely.
                var classifiedAsSprite = false
                if cell.scalars.count == 1, let scalar = cell.scalars.first {
                    switch scalar.value {
                    case BoxDrawingSprite.coarseRange:
                        if let pattern = BoxDrawingSprite.pattern(for: scalar) {
                            BoxDrawingSprite.append(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics,
                                rects: &spriteRects,
                                strokes: &boxDrawingStrokes
                            )
                            classifiedAsSprite = true
                        }
                    case BlockElementSprite.coarseRange:
                        if let pattern = BlockElementSprite.pattern(for: scalar) {
                            let shade = BlockElementSprite.shade(for: pattern)
                            BlockElementSprite.appendRects(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics,
                                to: &shadedSpriteRects[shade, default: []]
                            )
                            classifiedAsSprite = true
                        }
                    case GeometricShapeSprite.coarseRange:
                        if let pattern = GeometricShapeSprite.pattern(for: scalar),
                           let triangle = GeometricShapeSprite.triangle(
                               pattern: pattern,
                               row: run.row,
                               column: column,
                               metrics: metrics
                           )
                        {
                            geometricShapeTriangles.append(triangle)
                            classifiedAsSprite = true
                        }
                    case BrailleSprite.coarseRange:
                        if let pattern = BrailleSprite.pattern(for: scalar) {
                            let layout = brailleLayout ?? BrailleSpriteGeometry.layout(
                                cellWidthPixels: metrics.cellWidthPixels,
                                cellHeightPixels: metrics.cellHeightPixels
                            )
                            brailleLayout = layout
                            BrailleSprite.appendRects(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics,
                                layout: layout,
                                to: &spriteRects
                            )
                            classifiedAsSprite = true
                        }
                    case PowerlineSprite.coarseRange:
                        if let pattern = PowerlineSprite.pattern(for: scalar) {
                            powerlinePaths += PowerlineSprite.paths(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics
                            )
                            classifiedAsSprite = true
                        }
                    case BranchDrawingSprite.coarseRange:
                        if let pattern = BranchDrawingSprite.pattern(for: scalar) {
                            branchDrawingGeometries.append(BranchDrawingSprite.geometry(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics
                            ))
                            classifiedAsSprite = true
                        }
                    // Coarse ranges spanning each multi-range family; the family returns nil
                    // for the interior gaps, which then fall through to the font path.
                    case LegacyComputingSupplementSprite.coarseRange:
                        if let pattern = LegacyComputingSupplementSprite.pattern(for: scalar) {
                            LegacyComputingSupplementSprite.appendRects(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics,
                                to: &spriteRects
                            )
                            classifiedAsSprite = true
                        }
                    case LegacyComputingSprite.coarseRange:
                        if let pattern = LegacyComputingSprite.pattern(for: scalar) {
                            LegacyComputingSprite.appendRects(
                                pattern: pattern,
                                row: run.row,
                                column: column,
                                metrics: metrics,
                                to: &legacySpriteRects
                            )
                            classifiedAsSprite = true
                        }
                    default:
                        break
                    }
                    if classifiedAsSprite == false {
                        if scalar.value <= UInt16.max {
                            characters.append(UniChar(scalar.value))
                            candidateCells.append((cell, column))
                        } else {
                            fallbackCells.append((cell, column))
                        }
                    }
                } else {
                    fallbackCells.append((cell, column))
                }
                column += cell.columnWidth
            }

            if spriteRects.isEmpty == false {
                setFillColor(foreground)
                fill(spriteRects)
            }
            if boxDrawingStrokes.isEmpty == false {
                setStrokeColor(foreground)
                for stroke in boxDrawingStrokes {
                    drawBoxDrawingStroke(stroke, metrics: metrics)
                }
            }
            for (shade, rects) in shadedSpriteRects where rects.isEmpty == false {
                let alpha = CGFloat(shade.rawValue) / 255
                setFillColor(foreground.copy(alpha: alpha) ?? foreground)
                fill(rects)
            }
            if geometricShapeTriangles.isEmpty == false {
                setFillColor(foreground)
                setStrokeColor(foreground)
                for triangle in geometricShapeTriangles {
                    drawGeometricShapeTriangle(triangle, metrics: metrics)
                }
            }
            if powerlinePaths.isEmpty == false {
                setFillColor(foreground)
                setStrokeColor(foreground)
                for path in powerlinePaths {
                    drawPowerlinePath(path, metrics: metrics)
                }
            }
            for geometry in branchDrawingGeometries {
                drawBranchDrawingGeometry(geometry, metrics: metrics, foreground: foreground)
            }
            for (alpha, rects) in legacySpriteRects where rects.isEmpty == false {
                setFillColor(foreground.copy(alpha: CGFloat(alpha) / 255) ?? foreground)
                fill(rects)
            }
            var glyphs = Array(repeating: CGGlyph(), count: characters.count)
            if characters.isEmpty == false {
                CTFontGetGlyphsForCharacters(
                    font,
                    &characters,
                    &glyphs,
                    characters.count
                )
            }
            var mappedGlyphs: [CGGlyph] = []
            var positions: [CGPoint] = []
            for (index, candidate) in candidateCells.enumerated() {
                let glyph = glyphs[index]
                guard glyph != 0 else {
                    fallbackCells.append(candidate)
                    continue
                }
                mappedGlyphs.append(glyph)
                positions.append(CGPoint(
                    x: CGFloat(candidate.column) * metrics.cellSize.width,
                    y: -(CGFloat(run.row) * metrics.cellSize.height
                        + metrics.baselineOffset)
                ))
            }

            if mappedGlyphs.isEmpty == false {
                setFillColor(foreground)
                textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                CTFontDrawGlyphs(
                    font,
                    mappedGlyphs,
                    positions,
                    mappedGlyphs.count,
                    self
                )
            }
            for fallback in fallbackCells {
                drawTextCell(
                    fallback.cell,
                    row: run.row,
                    column: fallback.column,
                    attributes: attributes,
                    metrics: metrics
                )
            }
        }
    }

    func drawGeometricShapeTriangle(
        _ triangle: GeometricShapeRenderTriangle,
        metrics: TerminalRenderMetrics
    ) {
        let scale = metrics.displayScale
        let origin = triangle.cellOrigin
        func cgPoint(_ point: SpritePixelPoint) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(point.x) / scale,
                y: origin.y + CGFloat(point.y) / scale
            )
        }
        let cellRect = CGRect(
            origin: triangle.cellOrigin,
            size: metrics.cellSize
        )

        saveGState()
        defer { restoreGState() }
        clip(to: cellRect)
        setShouldAntialias(true)
        setAllowsAntialiasing(true)
        beginPath()
        move(to: cgPoint(triangle.geometry.v0))
        addLine(to: cgPoint(triangle.geometry.v1))
        addLine(to: cgPoint(triangle.geometry.v2))
        closePath()

        switch triangle.geometry.renderStyle {
        case .fill:
            fillPath()
        case let .innerStroke(widthPixels):
            guard let trianglePath = path else { return }
            addPath(trianglePath)
            clip()
            addPath(trianglePath)
            setLineWidth(CGFloat(widthPixels * 2) / scale)
            setLineCap(.butt)
            setLineJoin(.miter)
            strokePath()
        }
    }

    func drawPowerlinePath(
        _ path: PowerlineRenderPath,
        metrics: TerminalRenderMetrics
    ) {
        let scale = metrics.displayScale
        func point(_ point: PowerlinePixelPoint) -> CGPoint {
            CGPoint(
                x: path.cellOrigin.x + CGFloat(point.x) / scale,
                y: path.cellOrigin.y + CGFloat(point.y) / scale
            )
        }

        saveGState()
        defer { restoreGState() }
        clip(to: CGRect(origin: path.cellOrigin, size: metrics.cellSize))
        setShouldAntialias(true)
        setAllowsAntialiasing(true)
        setLineCap(.butt)
        setLineJoin(.miter)
        beginPath()
        for command in path.geometry.commands {
            switch command {
            case let .move(destination):
                move(to: point(destination))
            case let .line(destination):
                addLine(to: point(destination))
            case let .cubic(control1, control2, end):
                addCurve(
                    to: point(end),
                    control1: point(control1),
                    control2: point(control2)
                )
            case .close:
                closePath()
            }
        }

        switch path.geometry.style {
        case .fill:
            fillPath()
        case let .stroke(widthPixels):
            setLineWidth(CGFloat(widthPixels) / scale)
            strokePath()
        case let .innerStroke(widthPixels):
            guard let shape = self.path else { return }
            addPath(shape)
            clip()
            addPath(shape)
            setLineWidth(CGFloat(widthPixels * 2) / scale)
            strokePath()
        }
    }

    func drawBranchDrawingGeometry(
        _ renderGeometry: BranchDrawingRenderGeometry,
        metrics: TerminalRenderMetrics,
        foreground: CGColor
    ) {
        let scale = metrics.displayScale
        let origin = renderGeometry.cellOrigin
        func point(_ point: SpritePixelPoint) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(point.x) / scale, y: origin.y + CGFloat(point.y) / scale)
        }
        saveGState()
        defer { restoreGState() }
        clip(to: CGRect(origin: origin, size: metrics.cellSize))

        for item in renderGeometry.geometry.rects {
            setFillColor(foreground.copy(alpha: CGFloat(item.alpha) / 255) ?? foreground)
            fill(CGRect(
                x: origin.x + CGFloat(item.rect.x) / scale,
                y: origin.y + CGFloat(item.rect.y) / scale,
                width: CGFloat(item.rect.width) / scale,
                height: CGFloat(item.rect.height) / scale
            ))
        }
        setStrokeColor(foreground)
        setShouldAntialias(true)
        setAllowsAntialiasing(true)
        setLineCap(.butt)
        for arc in renderGeometry.geometry.arcs {
            setLineWidth(CGFloat(arc.width) / scale)
            beginPath()
            move(to: point(arc.start))
            addQuadCurve(to: point(arc.end), control: point(arc.control))
            strokePath()
        }
        if let node = renderGeometry.geometry.node {
            let rect = CGRect(
                x: origin.x + CGFloat(node.centerX - node.radius) / scale,
                y: origin.y + CGFloat(node.centerY - node.radius) / scale,
                width: CGFloat(node.radius * 2) / scale,
                height: CGFloat(node.radius * 2) / scale
            )
            if node.filled {
                setFillColor(foreground)
                fillEllipse(in: rect)
            } else if node.radius >= Double(node.strokeWidth) / 2 {
                setStrokeColor(foreground)
                setLineWidth(CGFloat(node.strokeWidth) / scale)
                let inset = CGFloat(node.strokeWidth) / (2 * scale)
                strokeEllipse(in: rect.insetBy(dx: inset, dy: inset))
            }
        }
    }

    func drawBoxDrawingStroke(
        _ stroke: BoxDrawingRenderStroke,
        metrics: TerminalRenderMetrics
    ) {
        let scale = metrics.displayScale
        let points = stroke.geometry.points.map {
            CGPoint(
                x: stroke.cellOrigin.x + CGFloat($0.x) / scale,
                y: stroke.cellOrigin.y + CGFloat($0.y) / scale
            )
        }
        guard let first = points.first, let last = points.last else { return }
        saveGState()
        defer { restoreGState() }
        clip(to: CGRect(origin: stroke.cellOrigin, size: metrics.cellSize))
        setShouldAntialias(true)
        setAllowsAntialiasing(true)
        setLineCap(.butt)
        setLineWidth(CGFloat(stroke.geometry.width) / scale)
        beginPath()
        move(to: first)
        if stroke.geometry.isCurved, points.count == 3 {
            addQuadCurve(to: last, control: points[1])
        } else {
            for point in points.dropFirst() { addLine(to: point) }
        }
        strokePath()
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
                case .underlineDotted:
                    fillPatternedUnderline(in: runRect, metrics: metrics, dashPixels: 1)
                case .underlineDashed:
                    fillPatternedUnderline(in: runRect, metrics: metrics, dashPixels: 3)
                case .strikethrough:
                    setFillColor(run.strikethroughColor.cgColor(in: colorSpace))
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

    func fillPatternedUnderline(
        in runRect: CGRect,
        metrics: TerminalRenderMetrics,
        dashPixels: Int
    ) {
        let pixel = 1 / metrics.displayScale
        let dashWidth = CGFloat(dashPixels) * pixel
        let period = CGFloat(dashPixels + 2) * pixel
        let firstIndex = Int((runRect.minX / period).rounded(.down))
        let lastIndex = Int((runRect.maxX / period).rounded(.up))
        let top = CGFloat(runRect.minY) + metrics.underlineOffset
        for index in firstIndex...lastIndex {
            let start = CGFloat(index) * period
            let clippedStart = max(start, runRect.minX)
            let clippedEnd = min(start + dashWidth, runRect.maxX)
            guard clippedStart < clippedEnd else { continue }
            fillDecorationBar(
                in: CGRect(
                    x: clippedStart,
                    y: runRect.minY,
                    width: clippedEnd - clippedStart,
                    height: runRect.height
                ),
                top: top,
                thickness: metrics.underlineThickness
            )
        }
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
