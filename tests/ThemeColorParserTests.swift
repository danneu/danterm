// Tests for ThemeColorParser: validates the parser contract for extracting
// preview colors (bg, fg, cursor-color, palette 1-6) from Ghostty theme files.
import Foundation

/// A complete set of palette 1-6 lines for tests that need a valid full theme.
private let validPalette = """
palette = 1=#cc6566
palette = 2=#b6bd68
palette = 3=#f0c674
palette = 4=#82a2be
palette = 5=#b294bb
palette = 6=#8abeb7
"""

func themeColorParserTests() {
    print("ThemeColorParser")

    test("parses valid theme content") {
        let content = """
        palette = 0=#1d1f21
        \(validPalette)
        background = #282c34
        foreground = #f8f8f2
        cursor-color = #aabbcc
        selection-background = #44475a
        """
        let result = ThemeColorParser.parse(themeContent: content)
        try expect(result != nil, "expected non-nil result")
        try expectEqual(result!.background, "#282c34")
        try expectEqual(result!.foreground, "#f8f8f2")
        try expectEqual(result!.accent, "#aabbcc")
        try expectEqual(result!.palette.count, 6)
        try expectEqual(result!.palette[0], "#cc6566")
        try expectEqual(result!.palette[5], "#8abeb7")
    }

    test("returns nil when background is missing") {
        let content = """
        \(validPalette)
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil when foreground is missing") {
        let content = """
        \(validPalette)
        background = #282c34
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil when cursor-color is missing") {
        let content = """
        \(validPalette)
        background = #282c34
        foreground = #f8f8f2
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil when a palette color is missing") {
        let content = """
        palette = 1=#cc6566
        palette = 2=#b6bd68
        palette = 3=#f0c674
        palette = 4=#82a2be
        palette = 5=#b294bb
        background = #282c34
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil — palette 6 missing")
    }

    test("returns nil for malformed hex (non-hex chars)") {
        let content = """
        \(validPalette)
        background = #zzzzzz
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil for malformed hex (too short)") {
        let content = """
        \(validPalette)
        background = #12345
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("handles extra whitespace around keys and values") {
        let content = """
          \(validPalette)
          background  =  #282a36
          foreground  =  #f8f8f2
          cursor-color  =  #aabbcc
        """
        let result = ThemeColorParser.parse(themeContent: content)
        try expect(result != nil, "expected non-nil result")
        try expectEqual(result!.background, "#282a36")
        try expectEqual(result!.foreground, "#f8f8f2")
        try expectEqual(result!.accent, "#aabbcc")
    }

    test("normalizes uppercase hex to lowercase") {
        let content = """
        \(validPalette)
        background = #F8F8F2
        foreground = #AABBCC
        cursor-color = #11DD33
        """
        let result = ThemeColorParser.parse(themeContent: content)
        try expect(result != nil, "expected non-nil result")
        try expectEqual(result!.background, "#f8f8f2")
        try expectEqual(result!.foreground, "#aabbcc")
        try expectEqual(result!.accent, "#11dd33")
    }

    test("palette colors are ordered 1 through 6") {
        let content = """
        palette = 6=#666666
        palette = 1=#111111
        palette = 3=#333333
        palette = 5=#555555
        palette = 2=#222222
        palette = 4=#444444
        background = #000000
        foreground = #ffffff
        cursor-color = #aabbcc
        """
        let result = ThemeColorParser.parse(themeContent: content)
        try expect(result != nil, "expected non-nil result")
        try expectEqual(result!.palette[0], "#111111")
        try expectEqual(result!.palette[1], "#222222")
        try expectEqual(result!.palette[2], "#333333")
        try expectEqual(result!.palette[3], "#444444")
        try expectEqual(result!.palette[4], "#555555")
        try expectEqual(result!.palette[5], "#666666")
    }
}
