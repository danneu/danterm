// Narrow app boundary that maps decoded neutral themes into renderer-owned values.
import TerminalRenderPlanning

extension ThemeCatalog {
    /// Resolves and converts a complete catalog entry without exposing renderer types to core.
    func renderTheme(named name: String) -> RenderTheme? {
        guard let theme = theme(named: name) else { return nil }
        let palette = theme.ansiPalette.map(Self.renderColor)
        guard let ansiColors = RenderANSIColors(exactly: palette) else { return nil }
        return RenderTheme(
            ansiColors: ansiColors,
            defaultForeground: Self.renderColor(theme.foreground),
            defaultBackground: Self.renderColor(theme.background),
            selectionForeground: Self.renderColor(theme.selectionForeground),
            selectionBackground: Self.renderColor(theme.selectionBackground),
            cursor: Self.renderColor(theme.cursor),
            cursorText: Self.renderColor(theme.cursorText)
        )
    }

    private static func renderColor(_ color: ThemeRGBColor) -> RenderColor {
        RenderColor(red: color.red, green: color.green, blue: color.blue)
    }
}
