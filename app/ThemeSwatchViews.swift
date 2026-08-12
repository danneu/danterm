// Shared theme preview components and row-cell construction used by both the
// sidebar theme browser and the remote theme picker sheet.
import Cocoa

/// Resolved preview colors for a single complete theme, ready for swatch rendering.
struct ThemeColors {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    let palette: [NSColor]  // ANSI colors 1-6: red, green, yellow, blue, magenta, cyan
}

extension ThemeCatalog {
    /// Projects a catalog entry into AppKit preview colors here, at the only consumer,
    /// so the shared catalog itself holds no non-`Sendable` state.
    func swatchColors(named name: String) -> ThemeColors? {
        guard let theme = theme(named: name) else { return nil }
        return ThemeColors(
            background: Self.swatchColor(theme.background),
            foreground: Self.swatchColor(theme.foreground),
            accent: Self.swatchColor(theme.cursor),
            palette: theme.ansiPalette[1...6].map(Self.swatchColor)
        )
    }

    private static func swatchColor(_ color: ThemeRGBColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}

/// Bold/regular monospaced fonts at the size where "test\u{2588}" just fits a swatch's
/// text area, plus the rendered size used to center it.
fileprivate struct SwatchTextFit {
    let bold: NSFont
    let regular: NSFont
    let textSize: NSSize
}

/// Largest monospaced size at which "test\u{2588}" fits within the swatch text area.
fileprivate func swatchTextFit(textAreaSize: NSSize, padding: CGFloat = 3) -> SwatchTextFit {
    let available = textAreaSize.width - padding * 2
    var fontSize: CGFloat = textAreaSize.height
    var textSize = NSSize.zero
    var boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    var regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    while fontSize > 4 {
        boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let probe = NSMutableAttributedString(string: "test", attributes: [.font: boldFont])
        probe.append(NSAttributedString(string: "\u{2588}", attributes: [.font: regularFont]))
        textSize = probe.size()
        if textSize.width <= available && textSize.height <= textAreaSize.height { break }
        fontSize -= 0.5
    }
    return SwatchTextFit(bold: boldFont, regular: regularFont, textSize: textSize)
}

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
        let fit = swatchTextFit(textAreaSize: textArea.size)
        let text = NSMutableAttributedString(
            string: "test",
            attributes: [.font: fit.bold, .foregroundColor: colors.fg]
        )
        text.append(NSAttributedString(
            string: "\u{2588}",
            attributes: [.font: fit.regular, .foregroundColor: colors.accent]
        ))
        let textX = textArea.midX - fit.textSize.width / 2
        let textY = textArea.midY - fit.textSize.height / 2
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

extension ThemeBrowserCellView {
    /// Owns the shared theme-row rendering contract while each caller keeps a
    /// distinct reuse identifier and selection behavior.
    static func themeCell(
        in tableView: NSTableView,
        reuseIdentifier: NSUserInterfaceItemIdentifier,
        themeName: String,
        isCurrentTheme: Bool
    ) -> ThemeBrowserCellView {
        let cell: ThemeBrowserCellView
        if let existing = tableView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? ThemeBrowserCellView {
            cell = existing
        } else {
            cell = ThemeBrowserCellView()
            cell.identifier = reuseIdentifier

            let swatch = ColorSwatchView()
            swatch.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(swatch)
            cell.swatchView = swatch

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text

            NSLayoutConstraint.activate([
                swatch.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                swatch.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                swatch.widthAnchor.constraint(equalToConstant: 50),
                swatch.heightAnchor.constraint(equalTo: cell.heightAnchor),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: swatch.leadingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        if isCurrentTheme {
            cell.textField?.stringValue = "\u{2713} \(themeName)"
        } else {
            cell.textField?.stringValue = themeName
        }
        cell.updateTextColor()
        if let tc = ThemeCatalog.shared.swatchColors(named: themeName) {
            cell.swatchView?.colors = (tc.background, tc.foreground, tc.accent, tc.palette)
        } else {
            cell.swatchView?.colors = (.clear, .clear, .clear, [])
        }
        return cell
    }
}
