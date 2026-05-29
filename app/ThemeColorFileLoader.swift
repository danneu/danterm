// App-side file-read wrapper around the pure ThemeColorParser. `parse(themeFileAt:)`
// reads a theme file off disk (FileManager) and hands its bytes to the pure
// `ThemeColorParser.parse(themeContent:)` in DanTermCore. The disk read is why it
// lives in app/ and not the core, which stays IO-free. Kept as an extension on
// ThemeColorParser so its one caller (ThemeCatalog) retains the `parse(themeFileAt:)`
// name. Earns its own file as the app-side IO half of the theme color parser.
import Foundation

extension ThemeColorParser {
    /// Read a theme file from disk and parse it. App-side (FileManager); delegates
    /// to the pure `parse(themeContent:)`.
    static func parse(themeFileAt path: String) -> ThemeColorHex? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return parse(themeContent: content)
    }
}
