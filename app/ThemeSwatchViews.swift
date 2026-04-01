// Shared theme preview components used by both the sidebar theme browser
// and the remote theme picker sheet.
import Cocoa

/// Tiny terminal thumbnail: bg-colored rounded rect with "test█" text in the upper area
/// and a 6-color ANSI palette bar flush against the bottom edge.
final class ColorSwatchView: NSView {
    var colors: (bg: NSColor, fg: NSColor, accent: NSColor, palette: [NSColor]) =
        (.clear, .clear, .clear, []) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 2)
        let cornerRadius: CGFloat = 3
        let barHeight: CGFloat = 3

        // Clip to rounded rect so the palette bar respects the corner radius.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

        // Background fill
        colors.bg.setFill()
        NSBezierPath.fill(rect)

        // Palette color bar flush against left/right/bottom edges
        if colors.palette.count == 6 {
            let barY = rect.minY
            let segWidth = rect.width / 6
            for (i, color) in colors.palette.enumerated() {
                color.setFill()
                // Last segment extends to the right edge to avoid rounding gaps.
                let x = rect.minX + segWidth * CGFloat(i)
                let w = (i == 5) ? rect.maxX - x : segWidth
                NSBezierPath.fill(NSRect(x: x, y: barY, width: w, height: barHeight))
            }
        }

        // "test█" sized to fill the area above the bar, with "test" bold.
        let textArea = NSRect(x: rect.minX, y: rect.minY + barHeight, width: rect.width, height: rect.height - barHeight)
        let padding: CGFloat = 3
        let available = textArea.width - padding * 2
        var fontSize: CGFloat = textArea.height
        var textSize = NSSize.zero
        var boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        var regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        while fontSize > 4 {
            boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let probe = NSMutableAttributedString(string: "test", attributes: [.font: boldFont])
            probe.append(NSAttributedString(string: "\u{2588}", attributes: [.font: regularFont]))
            textSize = probe.size()
            if textSize.width <= available && textSize.height <= textArea.height { break }
            fontSize -= 0.5
        }
        let text = NSMutableAttributedString(
            string: "test",
            attributes: [.font: boldFont, .foregroundColor: colors.fg]
        )
        text.append(NSAttributedString(
            string: "\u{2588}",
            attributes: [.font: regularFont, .foregroundColor: colors.accent]
        ))
        let textX = textArea.midX - textSize.width / 2
        let textY = textArea.midY - textSize.height / 2
        text.draw(at: NSPoint(x: textX, y: textY))

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Theme list cell that follows AppKit's selected/unselected text contrast rules.
final class ThemeBrowserCellView: NSTableCellView {
    var swatchView: ColorSwatchView?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    /// Use the system-selected text color for highlighted rows and the normal label color otherwise.
    func updateTextColor() {
        textField?.textColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : .labelColor
    }
}
