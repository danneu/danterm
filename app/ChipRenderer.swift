// Draws a pane-kind chip into a CGContext.
//
// View-independent on purpose: no NSView, no AppKit. The sidebar cell, the pane
// toolbar, and the headless render check in icon/render-check all call this one
// function, so a chip cannot look different depending on where it is shown.
//
// The geometry here mirrors icon/chips/preview.html exactly -- the same aspect
// fit, the same optical `fill` fraction, the same dilation stroke. If you change
// one, change the other, or the preview stops predicting what ships.

import CoreGraphics

/// Which palette of a `ChipDefinition` to paint with. Named after the two
/// entries in chips.json rather than after an AppKit appearance, so the
/// renderer stays free of AppKit.
enum ChipAppearance {
    case light
    case dark
}

/// The one place chip drawing lives. Stateless; every call is self-contained.
enum ChipRenderer {
    /// Paints the chip's background and mark to fill `rect`.
    ///
    /// `flipped` describes the context, not the chip: pass true when y grows
    /// downward (an `NSView` whose `isFlipped` is true), false for a plain
    /// bottom-up CGContext. Only the mark cares; the background is symmetric.
    ///
    /// Nothing is clipped. A dilation stroke can reach a fraction of a point
    /// outside the mark's box, which matches the preview page's `overflow:
    /// visible` and keeps the mark's own edges from being shaved.
    ///
    static func draw(
        _ definition: ChipDefinition,
        in context: CGContext,
        rect: CGRect,
        appearance: ChipAppearance,
        flipped: Bool
    ) {
        draw(
            definition, in: context, rect: rect,
            palette: appearance == .light ? definition.light : definition.dark,
            flipped: flipped)
    }

    /// The same chip in colors that are not its own. A tab row's pane strip
    /// paints every chip from one shared palette, so the strip reads as "which
    /// pane" rather than as four brands competing for attention.
    static func draw(
        _ definition: ChipDefinition,
        in context: CGContext,
        rect: CGRect,
        palette: ChipPalette,
        flipped: Bool
    ) {
        context.saveGState()
        context.setFillColor(palette.background)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: rect.width * ChipArtwork.cornerRadius,
            cornerHeight: rect.height * ChipArtwork.cornerRadius,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()

        drawMark(definition, in: context, rect: rect, color: palette.foreground, flipped: flipped)
    }

    /// The mark alone, in an explicit color and with no background. Split out
    /// because a chip is not the only thing that may want the glyph, and
    /// because the render check compares marks without paint getting in the way.
    static func drawMark(
        _ definition: ChipDefinition,
        in context: CGContext,
        rect: CGRect,
        color: CGColor,
        flipped: Bool
    ) {
        let glyph = definition.glyph
        let box = markBox(glyph: glyph, in: rect, fill: definition.fill)
        let scale = box.width / glyph.viewBox.width

        context.saveGState()
        defer { context.restoreGState() }

        // Concatenate rather than transforming the path, so stroke widths stay
        // in viewBox units and scale with the mark the way SVG's do.
        if flipped {
            context.translateBy(x: box.minX, y: box.minY)
            context.scaleBy(x: scale, y: scale)
        } else {
            context.translateBy(x: box.minX, y: box.maxY)
            context.scaleBy(x: scale, y: -scale)
        }

        context.addPath(path(of: glyph))

        if let strokeWidth = glyph.strokeWidth {
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth)
            context.setLineCap(glyph.lineCap)
            context.setLineJoin(glyph.lineJoin)
            context.strokePath()
            return
        }

        context.setFillColor(color)
        // `dilate` is stated on a 24-unit box for every mark, so scale it into
        // this mark's own viewBox before using it as a stroke width.
        let dilation = definition.dilate * (glyph.viewBox.width / 24)
        guard dilation > 0 else {
            context.fillPath(using: glyph.usesEvenOddFill ? .evenOdd : .winding)
            return
        }
        context.setStrokeColor(color)
        context.setLineWidth(dilation)
        context.setLineJoin(.round)
        context.drawPath(using: glyph.usesEvenOddFill ? .eoFillStroke : .fillStroke)
    }

    /// Where the mark's viewBox lands inside the chip: centered, aspect
    /// preserved, and sized so its longer edge takes up `fill` of the chip.
    static func markBox(glyph: ChipGlyph, in rect: CGRect, fill: CGFloat) -> CGRect {
        let ratio = glyph.viewBox.width / glyph.viewBox.height
        let width: CGFloat
        let height: CGFloat
        if ratio >= 1 {
            width = rect.width * fill
            height = width / ratio
        } else {
            height = rect.height * fill
            width = height * ratio
        }
        return CGRect(
            x: rect.minX + (rect.width - width) / 2,
            y: rect.minY + (rect.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Rebuilds the flattened opcode stream into a CGPath, in viewBox units.
    static func path(of glyph: ChipGlyph) -> CGPath {
        let path = CGMutablePath()
        var index = 0
        func point() -> CGPoint {
            let p = CGPoint(x: glyph.points[index], y: glyph.points[index + 1])
            index += 2
            return p
        }
        for opcode in glyph.opcodes {
            switch opcode {
            case 0: path.move(to: point())
            case 1: path.addLine(to: point())
            case 2:
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
            default: path.closeSubpath()
            }
        }
        return path
    }
}
