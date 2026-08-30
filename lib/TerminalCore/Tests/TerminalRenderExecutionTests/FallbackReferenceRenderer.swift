// A test-only copy of the fallback draw path as it stood before a shaped-cluster cache,
// plus the cluster cases the parity suite renders through it.
//
// This file is the parity target, so it must keep reproducing the *old* path even after
// the executor stops typesetting per cell: it builds an attributed string, typesets a
// `CTLine`, clips to the cell, and draws. Nothing here may call the executor's fallback
// drawing, and no production shortcut may be folded in -- a reference that follows the
// implementation proves nothing. Only the presentation gate is shared, because the
// scalars a cell submits are the input to both paths and not part of what the cache
// changes.
//
// General bitmap and plan fixtures live in BitmapTestSupport; nothing but the fallback
// reference belongs here.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

/// Which base face a case renders through.
///
/// A case needs to name this because one of the three exceptional shaping conditions --
/// a run CoreText marks with `kCTRunStatusHasNonIdentityMatrix` -- is a property of the
/// base face, not of the cluster: the cascade hands the fallback font the base font's
/// matrix, so only a base face that carries one can produce the condition.
enum FallbackFaceSource: Sendable {
    case systemMonospace

    /// The system monospace face copied with an oblique matrix, through the metrics'
    /// file-backed-face initializer.
    ///
    /// This is the only base face on this host that produces a run matrix. Asking
    /// CoreText for the italic trait of a family with no designed italic returns the
    /// upright face unchanged rather than synthesizing a slant -- no installed family
    /// yields a matrix that way -- so the condition has to be reached through a face
    /// built with one.
    case obliqueBaseFont

    func metrics(displayScale: CGFloat) -> TerminalRenderMetrics? {
        switch self {
        case .systemMonospace:
            return TerminalRenderMetrics(displayScale: displayScale)
        case .obliqueBaseFont:
            guard let upright = TerminalRenderMetrics(displayScale: displayScale) else {
                return nil
            }
            var slant = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
            let font = upright.fonts.regular.font
            let oblique = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), &slant, nil)
            return TerminalRenderMetrics(
                displayScale: displayScale,
                baseFont: oblique,
                symbolsResource: NerdFontSymbolsResource.packaged
            )
        }
    }
}

/// One cluster the executor cannot draw from its mapped-glyph batch, named so a parity
/// failure says which kind of fallback content moved.
struct FallbackClusterCase: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let bold: Bool
    let italic: Bool
    let faceSource: FallbackFaceSource

    init(
        name: String,
        text: String,
        bold: Bool = false,
        italic: Bool = false,
        faceSource: FallbackFaceSource = .systemMonospace
    ) {
        self.name = name
        self.text = text
        self.bold = bold
        self.italic = italic
        self.faceSource = faceSource
    }

    var testDescription: String { name }

    /// The SGR prefix that puts the terminal in this case's style, so a plan built from
    /// `text` alone carries the run traits the case names.
    var stylePrefix: String {
        switch (bold, italic) {
        case (false, false): ""
        case (true, false): "\u{1B}[1m"
        case (false, true): "\u{1B}[3m"
        case (true, true): "\u{1B}[1;3m"
        }
    }

    func metrics(displayScale: CGFloat = 2) -> TerminalRenderMetrics? {
        faceSource.metrics(displayScale: displayScale)
    }
}

/// The scalars the executor submits for a cell: the payload plus the presentation
/// selector the gate states for a bare default-text base.
func referenceSubmittedString(for cell: RenderTextCell) -> String {
    var scalarView = String.UnicodeScalarView()
    scalarView.append(contentsOf: cell.scalars)
    if let selector = terminalPresentationSelectorToAppend(for: cell.scalars) {
        scalarView.append(selector)
    }
    return String(scalarView)
}

/// The attributes the pre-cache fallback path put on its one-cluster string.
func referenceAttributes(font: CTFont, foreground: CGColor) -> [NSAttributedString.Key: Any] {
    [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: foreground,
        kCTLigatureAttributeName as NSAttributedString.Key: 0,
    ]
}

/// The line the pre-cache fallback path typeset for one cell.
func referenceLine(for cell: RenderTextCell, font: CTFont, foreground: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(
        string: referenceSubmittedString(for: cell),
        attributes: referenceAttributes(font: font, foreground: foreground)
    ))
}

/// Renders `plan` with every text cell drawn the pre-cache way, as the bitmap the
/// executor's output must equal.
///
/// Requires a plan whose only content is text on the default background: the reference
/// reproduces the fallback text pass and the frame clear, and nothing else. A plan
/// carrying a background run, an overlay, a decoration, or a cursor fails here rather
/// than silently comparing against a frame with a layer missing.
func renderFallbackReferenceBitmap(
    plan: RenderFramePlan,
    metrics: TerminalRenderMetrics,
    frames: Int = 1,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Bitmap {
    try #require(plan.backgroundRuns.isEmpty, sourceLocation: sourceLocation)
    try #require(plan.overlayRuns.isEmpty, sourceLocation: sourceLocation)
    try #require(plan.decorationRuns.isEmpty, sourceLocation: sourceLocation)
    try #require(plan.cursor == nil, sourceLocation: sourceLocation)

    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)

    for _ in 0..<frames {
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColorSpace(colorSpace)
        context.setStrokeColorSpace(colorSpace)
        context.setFillColor(referenceColor(plan.defaultBackground, in: colorSpace))
        context.fill(CGRect(origin: .zero, size: size.pointSize))
        context.setBlendMode(.normal)

        for (rowIndex, row) in plan.rows.enumerated() {
            for run in row.textRuns {
                let face = metrics.fonts.face(bold: run.bold, italic: run.italic)
                let foreground = referenceColor(run.foreground, in: colorSpace)
                var column = run.startColumn
                for cell in run.cells {
                    defer { column += cell.columnWidth }
                    guard cell.scalars.isEmpty == false else { continue }
                    referenceDrawTextCell(
                        cell,
                        row: rowIndex,
                        column: column,
                        font: face.font,
                        foreground: foreground,
                        metrics: metrics,
                        in: context
                    )
                }
            }
        }
        context.restoreGState()
    }

    return surface.bitmap()
}

/// Draws one cell the way `drawTextCell` did before the cache: one attributed string,
/// one `CTLine`, clipped to the cell, on a text matrix that reflects the glyph outlines
/// and puts the baseline below the cell's top edge.
func referenceDrawTextCell(
    _ cell: RenderTextCell,
    row: Int,
    column: Int,
    font: CTFont,
    foreground: CGColor,
    metrics: TerminalRenderMetrics,
    in context: CGContext
) {
    let rect = referenceCellRect(
        row: row,
        startColumn: column,
        columnCount: cell.columnWidth,
        metrics: metrics
    )
    let line = referenceLine(for: cell, font: font, foreground: foreground)

    context.saveGState()
    context.clip(to: rect)
    context.textMatrix = CGAffineTransform(
        a: 1,
        b: 0,
        c: 0,
        d: -1,
        tx: rect.minX,
        ty: rect.minY + metrics.baselineOffset
    )
    CTLineDraw(line, context)
    context.restoreGState()
}

/// The point-space rectangle of a cell span, in the reference's own arithmetic so the
/// executor's private helper cannot carry a geometry change into the parity target.
func referenceCellRect(
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

func referenceColor(_ color: RenderColor, in colorSpace: CGColorSpace) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat(color.red) / 255,
            CGFloat(color.green) / 255,
            CGFloat(color.blue) / 255,
            1,
        ]
    )!
}

/// Renders `plan` through the executor `frames` times onto one surface, so a parity
/// check can ask what a cluster looks like on a later frame rather than only on its
/// first.
func renderRepeatedBitmap(
    plan: RenderFramePlan,
    metrics: TerminalRenderMetrics,
    frames: Int
) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)
    for _ in 0..<frames {
        drawRenderFrame(plan, metrics: metrics, in: context)
    }
    return surface.bitmap()
}
