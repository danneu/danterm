// Pure Foundation parser for extracting preview colors from Ghostty theme files.
// Returns validated, normalized hex strings — no NSColor or Cocoa dependency,
// so this file can be compiled in the test target.
import Foundation

/// The three hex color strings extracted from a Ghostty theme file.
/// All values are lowercase "#rrggbb" (7 characters).
struct ThemeColorHex {
    let background: String
    let foreground: String
    let accent: String  // sourced from cursor-color
}

enum ThemeColorParser {
    /// Parse theme content string and extract background, foreground, and cursor-color.
    /// Returns nil if any of the three keys is missing or has an invalid hex value.
    ///
    /// Contract:
    /// 1. Split on newlines
    /// 2. For each line: trim whitespace, split on the first "=", trim both halves
    /// 3. Match key against "background", "foreground", "cursor-color"
    /// 4. Validate value is "#" followed by exactly 6 hex digits. Normalize to lowercase.
    /// 5. Return ThemeColorHex only when all three found with valid hex. Nil otherwise.
    static func parse(themeContent: String) -> ThemeColorHex? {
        var bg: String?
        var fg: String?
        var accent: String?

        for line in themeContent.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            guard let hex = validateHex(value) else { continue }

            switch key {
            case "background": bg = hex
            case "foreground": fg = hex
            case "cursor-color": accent = hex
            default: break
            }
        }

        guard let b = bg, let f = fg, let a = accent else { return nil }
        return ThemeColorHex(background: b, foreground: f, accent: a)
    }

    /// Read a theme file from disk and parse it.
    static func parse(themeFileAt path: String) -> ThemeColorHex? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return parse(themeContent: content)
    }

    /// Validate that a string is "#" followed by exactly 6 hex digits.
    /// Returns the normalized lowercase form, or nil if invalid.
    private static func validateHex(_ value: String) -> String? {
        guard value.count == 7,
              value.hasPrefix("#"),
              value.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return value.lowercased()
    }
}
