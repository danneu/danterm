// Single-read runtime access to DanTerm's packed themes and AppKit preview projections.
import Cocoa

/// Resolved preview colors for a single complete theme, ready for browser rendering.
struct ThemeColors {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    let palette: [NSColor]  // ANSI colors 1-6: red, green, yellow, blue, magenta, cyan
}

/// Owns the process-wide decoded catalog and resolves names without performing per-name IO.
final class ThemeCatalog {
    static let shared = ThemeCatalog(data: ThemeCatalog.loadBundledCatalog())

    let names: [String]
    let colors: [String: ThemeColors]
    private let themesByName: [String: DanTermTheme]

    init(data: Data?) {
        guard let data, let catalog = ThemeCatalogDocument.decode(data) else {
            names = []
            colors = [:]
            themesByName = [:]
            return
        }
        names = catalog.names
        themesByName = Dictionary(uniqueKeysWithValues: catalog.themes.map { ($0.name, $0) })
        colors = Dictionary(uniqueKeysWithValues: catalog.themes.map { theme in
            (
                theme.name,
                ThemeColors(
                    background: Self.nsColor(theme.background),
                    foreground: Self.nsColor(theme.foreground),
                    accent: Self.nsColor(theme.cursor),
                    palette: Array(theme.ansiPalette[1...6]).map(Self.nsColor)
                )
            )
        })
    }

    /// Resolves only exact catalog keys, so untrusted names never become filesystem paths.
    func theme(named name: String) -> DanTermTheme? {
        themesByName[name]
    }

    private static func loadBundledCatalog(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "themes"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func nsColor(_ color: ThemeRGBColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
