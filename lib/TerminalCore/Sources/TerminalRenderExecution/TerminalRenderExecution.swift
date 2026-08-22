// CoreText/CoreGraphics execution of deterministic terminal render plans. The one
// platform font type it needs is behind `PlatformFont`.
import CoreGraphics
import CoreText
import Foundation
import TerminalCore
import TerminalRenderPlanning
import TerminalSpriteGeometry

/// Fixes the grid geometry of one regular face -- the system monospace font, or a
/// caller-supplied family -- at one explicit size and display scale, so later font
/// choices cannot move terminal cell boundaries mid-frame.
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

    /// The decoration thickness as the whole backing-pixel count it was quantized from,
    /// which is also the light stroke width every sprite family draws with. Stored rather
    /// than re-derived at each sprite call site: `underlineThickness` is exactly this
    /// count divided by `displayScale`, so multiplying it back out was a round trip six
    /// sprite files each spelled out independently. Internal because the sprite files are
    /// same-module and no caller outside them needs pixel-space thickness.
    let lightStrokePixels: Int

    /// Top-edge offset for strikethrough in point space.
    public let strikethroughOffset: CGFloat

    /// The styled faces every draw served by these metrics reuses.
    let fonts: TerminalFontSet

    /// Measured union ink envelope of the four styled faces' printable-ASCII
    /// tables, in backing pixels, or nil when any face's table is incomplete
    /// or the measurement is degenerate -- the derived glyph halo then stays
    /// at the full-row fallback (research/33 T14, D9). The symbols face and
    /// the CTLine fallback are excluded because `drawTextCell` clips them to
    /// their cell; the styled faces' glyph batch is the only unclipped path.
    public let asciiInkEnvelope: RenderInkEnvelope?

    let baseFontName: String
    let baseFontSize: CGFloat
    let unquantizedLineHeight: CGFloat

    /// Returns nil when scale or any derived cell dimension cannot be represented safely.
    ///
    /// `fontFamily` is the family the caller has already verified is installed, or
    /// nil for the system monospace font. The metrics layer takes the name on
    /// trust -- `CTFontCreateWithName` substitutes a last-resort face rather than
    /// failing, so an unverified name would render proportionally with no signal.
    /// Passing the check is still not a guarantee of usable geometry, hence the
    /// existing nil return: a face without a nominal `M` glyph, or one whose cell
    /// box cannot be pixel-quantized, is refused here and the caller falls back.
    public init?(displayScale: CGFloat, fontSize: CGFloat = 13, fontFamily: String? = nil) {
        self.init(
            displayScale: displayScale,
            fontSize: fontSize,
            fontFamily: fontFamily,
            symbolsResource: NerdFontSymbolsResource.packaged
        )
    }

    /// Test seam for proving that an absent packaged symbols face preserves the old path.
    init?(
        displayScale: CGFloat,
        fontSize: CGFloat = 13,
        fontFamily: String? = nil,
        symbolsResource: NerdFontSymbolsResource?
    ) {
        guard displayScale.isFinite, displayScale > 0,
              fontSize.isFinite, fontSize > 0
        else { return nil }
        let baseName = fontFamily
            ?? PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).fontName
        let font = CTFontCreateWithName(baseName as CFString, fontSize, nil)
        self.init(
            displayScale: displayScale,
            baseName: baseName,
            font: font,
            symbolsResource: symbolsResource
        )
    }

    /// Test seam for a file-backed configured face that is not process-registered.
    init?(
        displayScale: CGFloat,
        baseFont: CTFont,
        symbolsResource: NerdFontSymbolsResource?
    ) {
        guard let grid = TerminalRenderMetrics(
            displayScale: displayScale,
            symbolsResource: symbolsResource
        ) else { return nil }
        let fonts = TerminalFontSet(
            regularFont: baseFont,
            symbolsResource: symbolsResource,
            symbolsSize: grid.cellSize.width
        )
        self.displayScale = grid.displayScale
        self.cellSize = grid.cellSize
        self.cellWidthPixels = grid.cellWidthPixels
        self.cellHeightPixels = grid.cellHeightPixels
        self.baselineOffset = grid.baselineOffset
        self.underlineOffset = grid.underlineOffset
        self.underlineThickness = grid.underlineThickness
        self.lightStrokePixels = grid.lightStrokePixels
        self.strikethroughOffset = grid.strikethroughOffset
        self.fonts = fonts
        self.asciiInkEnvelope = Self.measuredInkEnvelope(
            fonts: fonts,
            baselineOffset: grid.baselineOffset,
            cellHeightPixels: grid.cellHeightPixels,
            displayScale: grid.displayScale
        )
        self.baseFontName = CTFontCopyPostScriptName(baseFont) as String
        self.baseFontSize = CTFontGetSize(baseFont)
        self.unquantizedLineHeight = grid.unquantizedLineHeight
    }

    private init?(
        displayScale: CGFloat,
        baseName: String,
        font: CTFont,
        symbolsResource: NerdFontSymbolsResource?
    ) {
        let fontSize = CTFontGetSize(font)
        guard displayScale.isFinite, displayScale > 0,
              fontSize.isFinite, fontSize > 0
        else { return nil }
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
        self.lightStrokePixels = underlinePixels
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
        self.fonts = TerminalFontSet(
            regularFont: font,
            symbolsResource: symbolsResource,
            symbolsSize: self.cellSize.width
        )
        self.asciiInkEnvelope = Self.measuredInkEnvelope(
            fonts: self.fonts,
            baselineOffset: self.baselineOffset,
            cellHeightPixels: cellHeightPixels,
            displayScale: displayScale
        )
        self.baseFontName = baseName
        self.baseFontSize = fontSize
        self.unquantizedLineHeight = lineHeight
    }

    /// Unions the styled faces' measured ASCII ink boxes into cell-relative
    /// pixel offsets, rounding only outward (the margin floors, the overshoot
    /// ceils) so quantization can widen the derived reach but never narrow it.
    /// Clamped to one cell past either edge, which is the reach the derivation
    /// assumes as its worst case and the pre-T14 halo assumed globally.
    private static func measuredInkEnvelope(
        fonts: TerminalFontSet,
        baselineOffset: CGFloat,
        cellHeightPixels: Int,
        displayScale: CGFloat
    ) -> RenderInkEnvelope? {
        let faces = [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic]
        guard faces.allSatisfy(\.asciiTableComplete) else { return nil }
        guard let above = faces.map(\.asciiInkAboveBaseline).max(),
              let below = faces.map(\.asciiInkBelowBaseline).max(),
              above.isFinite, below.isFinite
        else { return nil }
        let baselinePixels = baselineOffset * displayScale
        let cellHeight = CGFloat(cellHeightPixels)
        let topOffset = (baselinePixels - above * displayScale).rounded(.down)
        let bottomOffset = (baselinePixels + below * displayScale - cellHeight).rounded(.up)
        guard topOffset.isFinite, bottomOffset.isFinite else { return nil }
        // Clamp before converting: a degenerate face (a test's astronomically
        // sized font) can produce finite offsets beyond Int's range, and
        // Int(_:) traps on those. The derivation never needs more than one
        // cell of reach in either direction anyway, and the boundary branches
        // return the already-valid Int rather than round-tripping a CGFloat
        // that may exceed exact integer range.
        func clamped(_ offset: CGFloat) -> Int {
            if offset <= -cellHeight { return -cellHeightPixels }
            if offset >= cellHeight { return cellHeightPixels }
            return Int(offset)
        }
        let clampedTop = clamped(topOffset)
        let clampedBottom = clamped(bottomOffset)
        // The non-degeneracy guard stays in floating point: the equivalent
        // integer sum can overflow at the same astronomical cell sizes the
        // clamp above exists for.
        guard CGFloat(clampedTop) < cellHeight + CGFloat(clampedBottom) else { return nil }
        return RenderInkEnvelope(
            inkTopOffsetPixels: clampedTop,
            inkBottomOffsetPixels: clampedBottom
        )
    }
}

/// The scalars each face precomputes glyphs for: printable ASCII, which is nearly
/// every cell a terminal draws. Control characters are excluded because they carry
/// no glyph, and the upper bound stops at ASCII because beyond it the table would
/// grow far faster than the hit rate.
let asciiGlyphTableRange: ClosedRange<UInt32> = 0x20...0x7E

/// True when a scalar belongs to one of Unicode's three private-use ranges.
private func isPrivateUse(_ scalarValue: UInt32) -> Bool {
    (0xE000...0xF8FF).contains(scalarValue)
        || (0xF0000...0xFFFFD).contains(scalarValue)
        || (0x100000...0x10FFFD).contains(scalarValue)
}

/// One font face together with its printable-ASCII glyphs, resolved eagerly at
/// construction so the draw loop never asks CoreText to map a character it has
/// already mapped. `CTFontGetGlyphsForCharacters` is documented as the font's
/// nominal cmap mapping (`CTFont.h`, `CTFontGetGlyphsForCharacters`) -- a pure
/// function of face and code unit, with no context, no shaping, and no state --
/// which is what makes caching it sound rather than merely convenient. The
/// alternative, a memo filled during draws, would put mutable state inside a
/// `Sendable` value; this stays immutable.
struct TerminalFace: @unchecked Sendable {
    let font: CTFont

    /// The face's point size, kept beside the font so the draw loop can set it on the
    /// context without a CoreText call per run.
    let pointSize: CGFloat

    /// The `CGFont` to hand `setFont` when drawing this face's mapped glyphs directly,
    /// or nil when the face must go through `CTFontDrawGlyphs`.
    ///
    /// `CTFontDrawGlyphs` is documented to apply the CTFont's size *and matrix* to the
    /// context and to leave them unrestored (`CTFont.h`, `CTFontDrawGlyphs`). The
    /// direct path applies the size but has no way to apply a matrix -- the text
    /// matrix it sets is the executor's own y-flip -- so a face carrying one is
    /// refused here rather than rendered without its transform. In practice every
    /// face of the monospaced system font is a real designed face with an identity
    /// matrix, so the common case
    /// qualifies; the refusal exists for a family with no true italic, where CoreText
    /// synthesizes the slant as a matrix.
    let directDrawFont: CGFont?

    /// `asciiGlyphTableRange`'s glyphs, indexed by `value - lowerBound`. A zero
    /// entry means the face cannot map that scalar and preserves the draw loop's
    /// existing meaning of glyph zero: send the cell to the fallback path.
    private let glyphs: [CGGlyph]

    /// Union ink extent of the table's mapped glyphs above the baseline, in
    /// font space (y up), for the derived glyph halo (research/33 T14). Zero
    /// glyphs are excluded so a `.notdef` box cannot enter the envelope.
    let asciiInkAboveBaseline: CGFloat

    /// Union ink extent below the baseline; see `asciiInkAboveBaseline`.
    let asciiInkBelowBaseline: CGFloat

    /// True when every scalar of `asciiGlyphTableRange` maps to a real glyph,
    /// so every printable-ASCII cell this face serves is submitted from the
    /// measured table and none reroutes to the clipped fallback. The measured
    /// ink envelope is only trusted when all styled faces hold this.
    let asciiTableComplete: Bool

    init(font: CTFont) {
        self.font = font
        self.pointSize = CTFontGetSize(font)
        self.directDrawFont = CTFontGetMatrix(font) == .identity
            ? CTFontCopyGraphicsFont(font, nil)
            : nil
        var characters = asciiGlyphTableRange.map { UniChar($0) }
        var resolved = [CGGlyph](repeating: 0, count: characters.count)
        // The return value is false when *any* character is unmapped, so it cannot
        // stand in for a per-entry check; the zeroed buffer already carries that.
        _ = CTFontGetGlyphsForCharacters(font, &characters, &resolved, characters.count)
        glyphs = resolved

        var boundingRects = [CGRect](repeating: .zero, count: resolved.count)
        var measured = resolved
        _ = CTFontGetBoundingRectsForGlyphs(
            font, .horizontal, &measured, &boundingRects, resolved.count
        )
        var above = -CGFloat.infinity
        var below = -CGFloat.infinity
        for (glyph, rect) in zip(resolved, boundingRects)
        where glyph != 0 && rect.isEmpty == false {
            above = max(above, rect.maxY)
            below = max(below, -rect.minY)
        }
        asciiInkAboveBaseline = above
        asciiInkBelowBaseline = below
        asciiTableComplete = resolved.allSatisfy { $0 != 0 }
    }

    /// The precomputed glyph, or nil when the scalar is outside the table and the
    /// caller must fall back to a live cmap lookup.
    func asciiGlyph(_ scalarValue: UInt32) -> CGGlyph? {
        guard asciiGlyphTableRange.contains(scalarValue) else { return nil }
        return glyphs[Int(scalarValue - asciiGlyphTableRange.lowerBound)]
    }

    /// Returns this face's nominal glyph without invoking font fallback or shaping.
    func nominalGlyph(_ scalarValue: UInt32) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
        var characters = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return glyphs[0] == 0 ? nil : glyphs[0]
    }
}

/// The four styled base faces and optional packaged symbols face a draw can need,
/// built once alongside the metrics that fix the grid rather than per draw. The
/// styled faces share one base family and size; the symbols face instead uses the
/// cell width as its size. Equality compares interchangeable font properties and
/// the packaged source URL, which keeps the metrics' synthesized `Equatable` a
/// comparison of geometry and font choice rather than object identity. The glyph
/// tables are derived from those same faces, so they stay outside that comparison.
///
/// `@unchecked` because CoreText does not annotate `CTFont` as `Sendable`, not
/// because the faces need care: they are immutable after `init` and CoreText
/// documents font objects as safe to read from multiple threads. The unchecked
/// conformance is what lets `TerminalRenderMetrics` stay `Sendable`.
struct TerminalFontSet: Equatable, @unchecked Sendable {
    let regular: TerminalFace
    let bold: TerminalFace
    let italic: TerminalFace
    let boldItalic: TerminalFace
    let symbols: TerminalFace?
    let symbolsResourceURL: URL?

    init(baseName: String, baseSize: CGFloat) {
        self.init(
            baseName: baseName,
            baseSize: baseSize,
            symbolsResource: nil,
            symbolsSize: baseSize
        )
    }

    init(
        baseName: String,
        baseSize: CGFloat,
        symbolsResource: NerdFontSymbolsResource?,
        symbolsSize: CGFloat
    ) {
        let regular = CTFontCreateWithName(baseName as CFString, baseSize, nil)
        self.init(
            regularFont: regular,
            symbolsResource: symbolsResource,
            symbolsSize: symbolsSize
        )
    }

    init(
        regularFont: CTFont,
        symbolsResource: NerdFontSymbolsResource?,
        symbolsSize: CGFloat
    ) {
        let regular = regularFont
        self.regular = TerminalFace(font: regular)
        self.bold = TerminalFace(font: regular.styled(with: .boldTrait))
        self.italic = TerminalFace(font: regular.styled(with: .italicTrait))
        self.boldItalic = TerminalFace(font: regular.styled(with: [.boldTrait, .italicTrait]))
        if let symbolsResource {
            let symbolsFont = symbolsResource.face(pointSize: symbolsSize)
            self.symbols = TerminalFace(font: symbolsFont)
            self.symbolsResourceURL = symbolsResource.sourceURL
        } else {
            self.symbols = nil
            self.symbolsResourceURL = nil
        }
    }

    /// The face for one run's style, so callers route on traits rather than
    /// reaching for a field and risking the wrong one.
    func face(bold: Bool, italic: Bool) -> TerminalFace {
        switch (bold, italic) {
        case (false, false): regular
        case (true, false): self.bold
        case (false, true): self.italic
        case (true, true): boldItalic
        }
    }

    static func == (lhs: TerminalFontSet, rhs: TerminalFontSet) -> Bool {
        CFEqual(lhs.regular.font, rhs.regular.font)
            && CFEqual(lhs.bold.font, rhs.bold.font)
            && CFEqual(lhs.italic.font, rhs.italic.font)
            && CFEqual(lhs.boldItalic.font, rhs.boldItalic.font)
            && optionalFontsEqual(lhs.symbols?.font, rhs.symbols?.font)
            && lhs.symbolsResourceURL == rhs.symbolsResourceURL
    }
}

/// Compares optional data-backed faces by the properties that affect drawing;
/// CoreText object equality is false for two descriptors built from the same bytes.
private func optionalFontsEqual(_ lhs: CTFont?, _ rhs: CTFont?) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        CTFontCopyPostScriptName(lhs) == CTFontCopyPostScriptName(rhs)
            && CTFontGetSize(lhs) == CTFontGetSize(rhs)
            && CTFontGetMatrix(lhs) == CTFontGetMatrix(rhs)
    case (nil, nil):
        true
    default:
        false
    }
}

private extension CTFont {
    /// Falls back to the untraited face when the family has no such variant, so
    /// a missing italic renders as upright text instead of nothing.
    func styled(with traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(
            self,
            0,
            nil,
            traits,
            [.boldTrait, .italicTrait]
        ) ?? self
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
    guard plan.columns > 0, plan.rowCount > 0 else { return nil }
    let width = metrics.cellWidthPixels.multipliedReportingOverflow(by: plan.columns)
    let height = metrics.cellHeightPixels.multipliedReportingOverflow(by: plan.rowCount)
    guard width.overflow == false, height.overflow == false,
          width.partialValue > 0, height.partialValue > 0
    else {
        return nil
    }

    let pointSize = CGSize(
        width: metrics.cellSize.width * CGFloat(plan.columns),
        height: metrics.cellSize.height * CGFloat(plan.rowCount)
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

/// The plan rows a draw restriction selects, walked straight out of the
/// damage bits so a restricted draw never materializes a row array.
///
/// A nil restriction selects the whole plan, and so does `.full`, which names
/// no rows precisely because it means every one of them. Rows the restriction
/// names outside the plan are ignored, and rows come out in ascending plan
/// order whatever order the damage was recorded in.
struct RenderPlanRowSelection: Sequence {
    let rows: [RenderPlanRow]
    let restriction: TerminalDamage?

    func selects(row: Int) -> Bool {
        guard let restriction, restriction.isFull == false else { return true }
        return restriction.contains(row: row)
    }

    func makeIterator() -> Iterator {
        Iterator(selection: self)
    }

    struct Iterator: IteratorProtocol {
        let selection: RenderPlanRowSelection
        private var index = 0

        init(selection: RenderPlanRowSelection) {
            self.selection = selection
        }

        mutating func next() -> RenderPlanRow? {
            while index < selection.rows.count {
                let row = index
                index += 1
                if selection.selects(row: row) { return selection.rows[row] }
            }
            return nil
        }
    }
}

/// Executes every planned layer in fixed order while borrowing the caller's
/// context without retaining or changing its state. A restriction is the row
/// damage the draw is clipped to; it must be shift-free, because a
/// translation is the caller's to realize before it asks for a draw.
public func drawRenderFrame(
    _ plan: RenderFramePlan,
    restrictedTo restriction: TerminalDamage? = nil,
    metrics: TerminalRenderMetrics,
    in context: CGContext
) {
    precondition(
        restriction?.shift == nil,
        "restrict a draw with folded damage; a shift is not row damage"
    )
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
    context.setFillColorSpace(colorSpace)
    context.setStrokeColorSpace(colorSpace)
    context.setFillColor(plan.defaultBackground)
    context.fill(CGRect(origin: .zero, size: frameSize.pointSize))

    let rows = RenderPlanRowSelection(rows: plan.rows, restriction: restriction)

    for row in rows {
        for run in row.backgroundRuns {
            context.setFillColor(run.color)
            context.fill(cellRect(
                row: run.row,
                startColumn: run.startColumn,
                columnCount: run.columnCount,
                metrics: metrics
            ))
        }
    }

    for row in rows {
        for run in row.overlayRuns {
            context.setFillColor(run.color)
            context.fill(cellRect(
                row: run.row,
                startColumn: run.startColumn,
                columnCount: run.columnCount,
                metrics: metrics
            ))
        }
    }

    // A block cursor is a cell presentation, not an overlay stroke. Repaint its
    // background after both highlight channels but before glyphs so selection and
    // search cannot hide it while the planned cursor-text foreground remains visible.
    let cursor = plan.cursor.flatMap { cursor in
        rows.selects(row: cursor.row) ? cursor : nil
    }
    if let cursor, cursor.shape == .block {
        context.setFillColor(cursor.color)
        context.fill(cellRect(
            row: cursor.row,
            startColumn: cursor.column,
            columnCount: cursor.columnWidth,
            metrics: metrics
        ))
    }

    context.drawTextRuns(
        rows,
        metrics: metrics,
        colorSpace: colorSpace
    )
    context.textMatrix = originalTextMatrix
    context.drawDecorationRuns(
        rows,
        metrics: metrics
    )
    if let cursor {
        context.drawCursor(cursor, metrics: metrics)
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
    var components: (CGFloat, CGFloat, CGFloat, CGFloat) {
        (
            CGFloat(red) / 255,
            CGFloat(green) / 255,
            CGFloat(blue) / 255,
            1
        )
    }

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

private extension Dictionary where Value == [CGRect] {
    /// Empties every bucket in place while retaining the keys, so a hoisted
    /// rect dictionary keeps both its hash table and each bucket's storage
    /// across runs. `removeAll(keepingCapacity:)` on the dictionary itself would
    /// discard the inner arrays, and the `[key, default: []]` subscript would
    /// then allocate a fresh one per run -- exactly what hoisting removes. The
    /// retained empty buckets stay invisible to the drawing loops, which all
    /// guard on `rects.isEmpty == false`.
    mutating func emptyValuesKeepingCapacity() {
        var index = startIndex
        while index != endIndex {
            values[index].removeAll(keepingCapacity: true)
            index = self.index(after: index)
        }
    }
}

/// Lowest scalar any sprite family claims, so `drawTextRuns` can reject a cell before
/// entering the family switch at all. Almost every cell a terminal draws is ASCII or Latin
/// text, and for those the switch's eight `ClosedRange.contains` calls are pure overhead --
/// they are also generic range-membership witnesses rather than inlined comparisons, which
/// made them measurable (~5% of the draw bracket; `research/18/F4`).
///
/// This duplicates where the families actually start, so it can drift out from under them:
/// a family claiming scalars below this floor would fall to the font path with no other
/// test failing. `SpriteRoutingGuardTests` ties the two together.
let spriteClassificationMinimumScalar: UInt32 = 0x2500

/// The baseline origin one glyph is submitted at. The negative `y` is not a sign
/// error: glyph submission runs under a y-flipped text matrix, so the position is
/// expressed in that flipped space while the rest of the executor stays in
/// top-left coordinates. Its own function because two paths -- the precomputed
/// ASCII table and the batched cmap residue -- now derive it, and they must not
/// drift apart by half a pixel.
/// The point-space rectangle a run of `columnCount` cells occupies on `row`. Its own
/// function for the same reason as `glyphOrigin`: seven sites -- background, selection,
/// search-match, the block-cursor fill, the cursor overlay, one text cell, one decoration
/// run -- derived this rectangle independently, and any of them could drift a half pixel
/// from the others while every test still passed.
private func cellRect(
    row: Int,
    startColumn: Int,
    columnCount: Int,
    metrics: TerminalRenderMetrics
) -> CGRect {
    CGRect(
        x: CGFloat(startColumn) * metrics.cellSize.width,
        y: CGFloat(row) * metrics.cellSize.height,
        width: CGFloat(columnCount) * metrics.cellSize.width,
        height: metrics.cellSize.height
    )
}

private func glyphOrigin(
    row: Int,
    column: Int,
    metrics: TerminalRenderMetrics
) -> CGPoint {
    CGPoint(
        x: CGFloat(column) * metrics.cellSize.width,
        y: -(CGFloat(row) * metrics.cellSize.height + metrics.baselineOffset)
    )
}

private extension CGContext {
    func setFillColor(_ color: RenderColor) {
        var components = color.components
        withUnsafePointer(to: &components) { pointer in
            pointer.withMemoryRebound(to: CGFloat.self, capacity: 4) {
                setFillColor($0)
            }
        }
    }

    func setStrokeColor(_ color: RenderColor) {
        var components = color.components
        withUnsafePointer(to: &components) { pointer in
            pointer.withMemoryRebound(to: CGFloat.self, capacity: 4) {
                setStrokeColor($0)
            }
        }
    }

    func drawCursor(
        _ cursor: RenderCursor,
        metrics: TerminalRenderMetrics
    ) {
        let cell = cellRect(
            row: cursor.row,
            startColumn: cursor.column,
            columnCount: cursor.columnWidth,
            metrics: metrics
        )
        let thickness = metrics.underlineThickness
        let overlayRect: CGRect
        switch cursor.shape {
        case .block:
            // A block cursor is drawn as a cell background fill in `drawRenderFrame`,
            // before glyphs, so there is no overlay stroke to add here.
            return
        case .underline:
            overlayRect = CGRect(
                x: cell.minX,
                y: cell.maxY - thickness,
                width: cell.width,
                height: thickness
            )
        case .bar:
            overlayRect = CGRect(
                x: cell.minX,
                y: cell.minY,
                width: thickness,
                height: cell.height
            )
        }

        saveGState()
        clip(to: cell)
        setBlendMode(.copy)
        setFillColor(cursor.color)
        fill(overlayRect)
        restoreGState()
    }

    func drawTextRuns(
        _ rows: RenderPlanRowSelection,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace
    ) {
        setBlendMode(.normal)
        // The faces come from the metrics, which built them once. Constructing
        // them here instead was a fixed per-draw cost, so it fell entirely on
        // the small damage-clipped draws that should be cheapest; removing it
        // measured -8.4% and -3.6% there and no verdict on full-frame draws.
        let fonts = metrics.fonts
        var colors: [UInt32: CGColor] = [:]
        // Built lazily on the first braille cell and reused for the rest of the
        // draw: the braille dot layout depends only on `metrics` (constant across
        // a draw), so this pays at most one `BraillePixelLayout` construction per
        // draw that contains braille, and none for text-only draws.
        var brailleLayout: BraillePixelLayout?
        // Per-run scratch, hoisted out of the loop so each buffer is grown at
        // most once per draw instead of once per run (a full frame carries
        // thousands). Emptied at the top of every iteration keeping capacity;
        // see the reset block below for the invariant that governs them.
        var characters: [UniChar] = []
        var candidateCells: [(cell: RenderTextCell, column: Int)] = []
        var fallbackCells: [(cell: RenderTextCell, column: Int)] = []
        var symbolsCells: [(cell: RenderTextCell, column: Int, glyph: CGGlyph)] = []
        var spriteRects: [CGRect] = []
        var shadedSpriteRects: [BlockElementShade: [CGRect]] = [:]
        var geometricShapeTriangles: [GeometricShapeRenderTriangle] = []
        var powerlinePaths: [PowerlineRenderPath] = []
        var branchDrawingGeometries: [BranchDrawingRenderGeometry] = []
        var legacySpriteRects: [UInt8: [CGRect]] = [:]
        var boxDrawingStrokes: [BoxDrawingRenderStroke] = []
        var glyphs: [CGGlyph] = []
        var mappedGlyphs: [CGGlyph] = []
        var positions: [CGPoint] = []

        for row in rows {
            for run in row.textRuns {
                // No hoisted buffer may carry one run's contents into the next: that
                // would redraw the earlier run's geometry in this run's foreground
                // color. Resetting here rather than at the end of the iteration keeps
                // that true even if a `continue` is ever added to the loop body, and
                // every buffer added to the loop must join this sweep.
                characters.removeAll(keepingCapacity: true)
                candidateCells.removeAll(keepingCapacity: true)
                fallbackCells.removeAll(keepingCapacity: true)
                symbolsCells.removeAll(keepingCapacity: true)
                spriteRects.removeAll(keepingCapacity: true)
                shadedSpriteRects.emptyValuesKeepingCapacity()
                geometricShapeTriangles.removeAll(keepingCapacity: true)
                powerlinePaths.removeAll(keepingCapacity: true)
                branchDrawingGeometries.removeAll(keepingCapacity: true)
                legacySpriteRects.emptyValuesKeepingCapacity()
                boxDrawingStrokes.removeAll(keepingCapacity: true)
                glyphs.removeAll(keepingCapacity: true)
                mappedGlyphs.removeAll(keepingCapacity: true)
                positions.removeAll(keepingCapacity: true)

                let face = fonts.face(bold: run.bold, italic: run.italic)
                let font = face.font
                let colorKey = UInt32(run.foreground.red) << 16
                    | UInt32(run.foreground.green) << 8
                    | UInt32(run.foreground.blue)
                let foreground: CGColor
                if let cached = colors[colorKey] {
                    foreground = cached
                } else {
                    foreground = run.foreground.cgColor(in: colorSpace)
                    colors[colorKey] = foreground
                }
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
                        // Ordinary text is the overwhelming majority of cells and no family
                        // claims a scalar below the floor, so reject it with one comparison
                        // instead of eight range-membership tests.
                        if scalar.value >= spriteClassificationMinimumScalar {
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
                        }
                        if classifiedAsSprite == false {
                            // Printable ASCII is nearly every cell, and its glyph was resolved
                            // once when the face was built, so it goes straight into the
                            // submission buffers and never reaches the batched cmap call below.
                            // Glyph zero keeps its existing meaning -- the face cannot map this
                            // scalar -- and takes the same fallback path the batch would give it.
                            if let glyph = face.asciiGlyph(scalar.value) {
                                if glyph == 0 {
                                    fallbackCells.append((cell, column))
                                } else {
                                    mappedGlyphs.append(glyph)
                                    positions.append(glyphOrigin(
                                        row: run.row,
                                        column: column,
                                        metrics: metrics
                                    ))
                                }
                            } else {
                                characters.append(contentsOf: String(scalar).utf16)
                                candidateCells.append((cell, column))
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
                // Grown from the emptied hoisted buffer rather than freshly allocated:
                // CoreText fills exactly `characters.count` elements, so the buffer
                // needs that many zeroed slots and no more.
                glyphs.append(contentsOf: repeatElement(CGGlyph(), count: characters.count))
                if characters.isEmpty == false {
                    CTFontGetGlyphsForCharacters(
                        font,
                        &characters,
                        &glyphs,
                        characters.count
                    )
                }
                var glyphIndex = 0
                for candidate in candidateCells {
                    let glyph = glyphs[glyphIndex]
                    glyphIndex += candidate.cell.scalars.first.map {
                        String($0).utf16.count
                    } ?? 0
                    guard glyph != 0 else {
                        if let scalar = candidate.cell.scalars.first,
                           candidate.cell.scalars.count == 1,
                           isPrivateUse(scalar.value),
                           let symbolsGlyph = fonts.symbols?.nominalGlyph(scalar.value)
                        {
                            symbolsCells.append((candidate.cell, candidate.column, symbolsGlyph))
                        } else {
                            fallbackCells.append(candidate)
                        }
                        continue
                    }
                    mappedGlyphs.append(glyph)
                    positions.append(glyphOrigin(
                        row: run.row,
                        column: candidate.column,
                        metrics: metrics
                    ))
                }

                if mappedGlyphs.isEmpty == false {
                    setFillColor(foreground)
                    // The text matrix is not part of the graphics state, and both branches
                    // below leave it modified (see `CTFontDrawGlyphs` in `CTFont.h` for
                    // the wrapper), so it is re-set per submission rather than hoisted
                    // out of the run loop.
                    textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    if let directDrawFont = face.directDrawFont {
                        // Same submission one level down: the wrapper's documented job is to
                        // set the context's font, size and matrix from the CTFont and then
                        // hand the arrays to CoreGraphics, and the face precomputed both
                        // values it would derive. `directDrawFont` is nil exactly when there
                        // is a matrix to apply, which this path cannot reproduce.
                        setFont(directDrawFont)
                        setFontSize(face.pointSize)
                        showGlyphs(mappedGlyphs, at: positions)
                    } else {
                        CTFontDrawGlyphs(
                            font,
                            mappedGlyphs,
                            positions,
                            mappedGlyphs.count,
                            self
                        )
                    }
                }
                if let symbolsFace = fonts.symbols, symbolsCells.isEmpty == false {
                    setFillColor(foreground)
                    textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    for symbolsCell in symbolsCells {
                        saveGState()
                        clip(to: cellRect(
                            row: run.row,
                            startColumn: symbolsCell.column,
                            columnCount: symbolsCell.cell.columnWidth,
                            metrics: metrics
                        ))
                        var glyph = symbolsCell.glyph
                        var position = glyphOrigin(
                            row: run.row,
                            column: symbolsCell.column,
                            metrics: metrics
                        )
                        CTFontDrawGlyphs(symbolsFace.font, &glyph, &position, 1, self)
                        restoreGState()
                    }
                }
                // Built inside the guard, not per run: only the fallback path reads
                // these attributes, and a run produces fallback cells only for
                // multi-scalar clusters, scalars above `UInt16.max`, or glyphs the
                // font cannot map -- so the overwhelming majority of runs would
                // build and tear down this boxed dictionary without ever reading it.
                if fallbackCells.isEmpty == false {
                    let attributes: [NSAttributedString.Key: Any] = [
                        kCTFontAttributeName as NSAttributedString.Key: font,
                        kCTForegroundColorAttributeName as NSAttributedString.Key: foreground,
                        kCTLigatureAttributeName as NSAttributedString.Key: 0,
                    ]
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
        let rect = cellRect(
            row: row,
            startColumn: column,
            columnCount: cell.columnWidth,
            metrics: metrics
        )
        var scalarView = String.UnicodeScalarView()
        scalarView.append(contentsOf: cell.scalars)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(scalarView),
            attributes: attributes
        ))

        saveGState()
        clip(to: rect)
        // CoreText expects y-up text space, so reflect the glyph outlines while
        // keeping the baseline measured down from the cell's top edge.
        textMatrix = CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: rect.minX,
            ty: rect.minY + metrics.baselineOffset
        )
        CTLineDraw(line, self)
        restoreGState()
    }

    func drawDecorationRuns(
        _ rows: RenderPlanRowSelection,
        metrics: TerminalRenderMetrics
    ) {
        for row in rows {
            for run in row.decorationRuns {
                let runRect = cellRect(
                    row: run.row,
                    startColumn: run.startColumn,
                    columnCount: run.columnCount,
                    metrics: metrics
                )
                saveGState()
                clip(to: runRect)
                setBlendMode(.copy)
                setFillColor(run.color)
                setStrokeColor(run.color)

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
                        setFillColor(run.strikethroughColor)
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
