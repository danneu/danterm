// Pure Foundation parser for extracting preview colors from Ghostty theme files.
// Returns validated, normalized hex strings — no NSColor or Cocoa dependency,
// so this file can be compiled in the test target.
import Foundation

/// Hex color strings extracted from a Ghostty theme file for preview rendering.
/// All values are lowercase "#rrggbb" (7 characters).
struct ThemeColorHex {
    let background: String
    let foreground: String
    let accent: String      // sourced from cursor-color
    let palette: [String]   // ANSI colors 1-6: red, green, yellow, blue, magenta, cyan
}

enum ThemeColorParser {
    /// Parse theme content string and extract preview colors.
    /// Returns nil if background, foreground, or cursor-color is missing/invalid,
    /// or if any of palette colors 1-6 are missing/invalid.
    ///
    /// Contract:
    /// 1. Split on newlines
    /// 2. For each line: trim whitespace, split on the first "=", trim both halves
    /// 3. Match key against "background", "foreground", "cursor-color", and "palette"
    /// 4. For palette lines, parse "N=<hex>" or "N#<hex>" to extract index and color
    /// 5. Validate all hex values are "#" followed by exactly 6 hex digits. Normalize to lowercase.
    /// 6. Return ThemeColorHex only when all required keys found with valid hex. Nil otherwise.
    static func parse(themeContent: String) -> ThemeColorHex? {
        var bg: String?
        var fg: String?
        var accent: String?
        var paletteColors: [Int: String] = [:]

        for line in themeContent.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            if key == "palette" {
                // Value is like "4=#aabbcc" or "4#aabbcc"
                if let parsed = parsePaletteEntry(value), (1...6).contains(parsed.index) {
                    paletteColors[parsed.index] = parsed.hex
                }
            } else {
                guard let hex = validateHex(value) else { continue }
                switch key {
                case "background": bg = hex
                case "foreground": fg = hex
                case "cursor-color": accent = hex
                default: break
                }
            }
        }

        guard let b = bg, let f = fg, let a = accent else { return nil }
        // Require all 6 palette colors (1-6)
        var palette: [String] = []
        for i in 1...6 {
            guard let hex = paletteColors[i] else { return nil }
            palette.append(hex)
        }
        return ThemeColorHex(background: b, foreground: f, accent: a, palette: palette)
    }

    /// Read a theme file from disk and parse it.
    static func parse(themeFileAt path: String) -> ThemeColorHex? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return parse(themeContent: content)
    }

    /// Parse a palette entry value like "4=#aabbcc" or "4#aabbcc" into index + validated hex.
    private static func parsePaletteEntry(_ value: String) -> (index: Int, hex: String)? {
        // Find where the digit(s) end and the hex begins
        let s = value.trimmingCharacters(in: .whitespaces)
        var numEnd = s.startIndex
        while numEnd < s.endIndex && s[numEnd].isNumber { numEnd = s.index(after: numEnd) }
        guard numEnd > s.startIndex, let idx = Int(s[s.startIndex..<numEnd]) else { return nil }
        var rest = s[numEnd...]
        if rest.hasPrefix("=") { rest = rest.dropFirst() }
        guard let hex = validateHex(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (idx, hex)
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
