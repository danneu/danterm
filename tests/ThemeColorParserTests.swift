// Tests for ThemeColorParser: validates the parser contract for extracting
// background, foreground, and cursor-color hex values from Ghostty theme files.
import Foundation

func themeColorParserTests() {
    print("ThemeColorParser")

    test("parses valid theme content") {
        let content = """
        palette = 0=#1d1f21
        palette = 4=#82a2be
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
    }

    test("returns nil when background is missing") {
        let content = """
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil when foreground is missing") {
        let content = """
        background = #282c34
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil when cursor-color is missing") {
        let content = """
        background = #282c34
        foreground = #f8f8f2
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil for malformed hex (non-hex chars)") {
        let content = """
        background = #zzzzzz
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("returns nil for malformed hex (too short)") {
        let content = """
        background = #12345
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        try expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    test("handles extra whitespace around keys and values") {
        let content = """
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
}
