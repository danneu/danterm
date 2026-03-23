// Runtime theme discovery: scans the app bundle's ghostty/themes/ directory
// and provides an alphabetized list of all available theme names plus cached
// preview colors (background, foreground, accent) for each theme.
import Cocoa

/// Resolved preview colors for a single theme, ready for rendering.
struct ThemeColors {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
}

class ThemeCatalog {
    static let shared = ThemeCatalog()
    let names: [String]  // all theme names, sorted alphabetically
    let colors: [String: ThemeColors]  // theme name → preview colors

    private init() {
        guard let themesURL = Bundle.main.url(
            forResource: "ghostty/themes", withExtension: nil
        ) else {
            names = []
            colors = [:]
            return
        }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: themesURL.path)) ?? []
        names = contents
            .filter { !$0.hasPrefix(".") }
            .sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        var parsed: [String: ThemeColors] = [:]
        for name in names {
            let path = themesURL.appendingPathComponent(name).path
            guard let hex = ThemeColorParser.parse(themeFileAt: path) else { continue }
            guard let bg = ThemeCatalog.colorFromHex(hex.background),
                  let fg = ThemeCatalog.colorFromHex(hex.foreground),
                  let accent = ThemeCatalog.colorFromHex(hex.accent) else { continue }
            parsed[name] = ThemeColors(background: bg, foreground: fg, accent: accent)
        }
        colors = parsed
    }

    /// Convert a validated "#rrggbb" hex string to an NSColor in sRGB.
    private static func colorFromHex(_ hex: String) -> NSColor? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
