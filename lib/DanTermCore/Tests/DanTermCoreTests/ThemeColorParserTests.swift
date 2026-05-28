// Swift Testing migration of the legacy `tests/ThemeColorParserTests.swift`
// harness suite. Pins the parser contract for extracting the preview colors
// (background, foreground, cursor-color/accent, palette 1-6) the Theme
// Browser displays from Ghostty's theme files.
import Foundation
import Testing

@testable import DanTermCore

/// A complete set of palette 1-6 lines for tests that need a valid full theme.
private let validPalette = """
palette = 1=#cc6566
palette = 2=#b6bd68
palette = 3=#f0c674
palette = 4=#82a2be
palette = 5=#b294bb
palette = 6=#8abeb7
"""

@Suite struct ThemeColorParserTests {
    @Test("parses valid theme content")
    func parsesValidThemeContent() {
        // Intent: a complete theme (palette 0 + 1-6 + background + foreground
        //   + cursor-color) yields a populated ThemeColors result.
        // Why it exists: pins the happy path so the Theme Browser preview
        //   actually has values to render after a refactor of the parser.
        // Scenario: spec-first happy path -- a well-formed Ghostty theme file
        //   parses into background/foreground/accent/palette[0..5].
        let content = """
        palette = 0=#1d1f21
        \(validPalette)
        background = #282c34
        foreground = #f8f8f2
        cursor-color = #aabbcc
        selection-background = #44475a
        """
        let result = ThemeColorParser.parse(themeContent: content)
        #expect(result != nil, "expected non-nil result")
        #expect(result!.background == "#282c34")
        #expect(result!.foreground == "#f8f8f2")
        #expect(result!.accent == "#aabbcc")
        #expect(result!.palette.count == 6)
        #expect(result!.palette[0] == "#cc6566")
        #expect(result!.palette[5] == "#8abeb7")
    }

    @Test("returns nil when background is missing")
    func returnsNilWhenBackgroundIsMissing() {
        // Intent: a theme missing `background` returns nil (incomplete preview).
        // Why it exists: pins the "all required keys present" precondition so
        //   the Theme Browser does not render half-themes.
        // Scenario: spec-first guard check -- a theme file with palette +
        //   foreground + cursor-color but no background line.
        let content = """
        \(validPalette)
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        #expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    @Test("returns nil when foreground is missing")
    func returnsNilWhenForegroundIsMissing() {
        // Intent: a theme missing `foreground` returns nil.
        // Why it exists: pins the symmetric missing-required-key guard.
        // Scenario: spec-first guard check -- a theme file with palette +
        //   background + cursor-color but no foreground line.
        let content = """
        \(validPalette)
        background = #282c34
        cursor-color = #aabbcc
        """
        #expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    @Test("returns nil when cursor-color is missing")
    func returnsNilWhenCursorColorIsMissing() {
        // Intent: a theme missing `cursor-color` returns nil.
        // Why it exists: pins the third required-key guard (Ghostty themes
        //   surface the accent color via cursor-color).
        // Scenario: spec-first guard check -- a theme file with palette +
        //   background + foreground but no cursor-color line.
        let content = """
        \(validPalette)
        background = #282c34
        foreground = #f8f8f2
        """
        #expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    @Test("returns nil when a palette color is missing")
    func returnsNilWhenAPaletteColorIsMissing() {
        // Intent: a theme missing any palette[1..6] entry returns nil.
        // Why it exists: pins the palette-completeness check so the preview
        //   strip cannot render a hole.
        // Scenario: spec-first guard check -- palette 1..5 present but
        //   palette 6 missing.
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
        #expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil -- palette 6 missing")
    }

    @Test("returns nil for malformed hex (non-hex chars)")
    func returnsNilForMalformedHexNonHexChars() {
        // Intent: a value with non-hex characters (e.g. `#zzzzzz`) fails the
        //   hex validation and the whole theme returns nil.
        // Why it exists: pins the strict-hex validation so the preview cannot
        //   crash later on a corrupted/typo'd color value.
        // Scenario: spec-first validation check -- a typo'd background hex.
        let content = """
        \(validPalette)
        background = #zzzzzz
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        #expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    @Test("returns nil for malformed hex (too short)")
    func returnsNilForMalformedHexTooShort() {
        // Intent: a hex value shorter than 6 chars fails validation.
        // Why it exists: pins the length check distinct from the chars check
        //   so a 3-or-5-char value cannot slip through.
        // Scenario: spec-first validation check -- a 5-char #12345 hex value.
        let content = """
        \(validPalette)
        background = #12345
        foreground = #f8f8f2
        cursor-color = #aabbcc
        """
        #expect(ThemeColorParser.parse(themeContent: content) == nil, "expected nil")
    }

    @Test("handles extra whitespace around keys and values")
    func handlesExtraWhitespaceAroundKeysAndValues() {
        // Intent: extra spaces around `=` and leading whitespace per line are
        //   tolerated; the value is still extracted correctly.
        // Why it exists: pins lenient whitespace handling so hand-edited
        //   themes do not become invalid for a single stray space.
        // Scenario: spec-first robustness check -- a theme with `key  =  value`
        //   spacing and leading indentation.
        let content = """
          \(validPalette)
          background  =  #282a36
          foreground  =  #f8f8f2
          cursor-color  =  #aabbcc
        """
        let result = ThemeColorParser.parse(themeContent: content)
        #expect(result != nil, "expected non-nil result")
        #expect(result!.background == "#282a36")
        #expect(result!.foreground == "#f8f8f2")
        #expect(result!.accent == "#aabbcc")
    }

    @Test("normalizes uppercase hex to lowercase")
    func normalizesUppercaseHexToLowercase() {
        // Intent: uppercase hex digits (#F8F8F2) normalize to lowercase
        //   (#f8f8f2) in the result.
        // Why it exists: pins canonical lowercase storage so equality checks
        //   on colors (e.g. cache lookups, diffs) stay consistent.
        // Scenario: spec-first canonicalization check -- a theme with all
        //   uppercase hex values surfaces as lowercase.
        let content = """
        \(validPalette)
        background = #F8F8F2
        foreground = #AABBCC
        cursor-color = #11DD33
        """
        let result = ThemeColorParser.parse(themeContent: content)
        #expect(result != nil, "expected non-nil result")
        #expect(result!.background == "#f8f8f2")
        #expect(result!.foreground == "#aabbcc")
        #expect(result!.accent == "#11dd33")
    }

    @Test("palette colors are ordered 1 through 6")
    func paletteColorsAreOrderedOneThroughSix() {
        // Intent: palette[0..5] in the result is ordered by palette index
        //   (1..6), regardless of the order keys appear in the file.
        // Why it exists: pins the sorting contract so the Theme Browser swatch
        //   row renders in a stable visual order independent of file layout.
        // Scenario: spec-first ordering check -- a theme that lists palette
        //   entries 6, 1, 3, 5, 2, 4 (out of order); result is in 1..6 order.
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
        #expect(result != nil, "expected non-nil result")
        #expect(result!.palette[0] == "#111111")
        #expect(result!.palette[1] == "#222222")
        #expect(result!.palette[2] == "#333333")
        #expect(result!.palette[3] == "#444444")
        #expect(result!.palette[4] == "#555555")
        #expect(result!.palette[5] == "#666666")
    }
}
