// Behavioral proofs for deterministic terminal-color resolution and the baked theme.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderColorResolutionTests {
    @Test("ANSI palettes accept exactly 16 entries")
    func ansiPaletteArity() throws {
        let colors: [RenderColor] = (0..<16).map { index in
            let red = UInt8(index)
            let green = UInt8(index + 16)
            let blue = UInt8(index + 32)
            return RenderColor(red: red, green: green, blue: blue)
        }
        let overlong: [RenderColor] = colors + [RenderColor(red: 1, green: 2, blue: 3)]

        let palette = try #require(RenderANSIColors(exactly: colors))
        #expect(palette.colors == colors)
        #expect(RenderANSIColors(exactly: Array(colors.dropLast())) == nil)
        #expect(RenderANSIColors(exactly: overlong) == nil)
    }

    @Test("The baked dark theme retains its complete fixed palette")
    func bakedDarkThemeGoldenValues() {
        let theme = RenderTheme.dark

        #expect(theme.ansiColors.colors == [
            RenderColor(red: 0, green: 0, blue: 0),
            RenderColor(red: 205, green: 0, blue: 0),
            RenderColor(red: 0, green: 205, blue: 0),
            RenderColor(red: 205, green: 205, blue: 0),
            RenderColor(red: 0, green: 0, blue: 238),
            RenderColor(red: 205, green: 0, blue: 205),
            RenderColor(red: 0, green: 205, blue: 205),
            RenderColor(red: 229, green: 229, blue: 229),
            RenderColor(red: 127, green: 127, blue: 127),
            RenderColor(red: 255, green: 0, blue: 0),
            RenderColor(red: 0, green: 255, blue: 0),
            RenderColor(red: 255, green: 255, blue: 0),
            RenderColor(red: 92, green: 92, blue: 255),
            RenderColor(red: 255, green: 0, blue: 255),
            RenderColor(red: 0, green: 255, blue: 255),
            RenderColor(red: 255, green: 255, blue: 255),
        ])
        #expect(theme.defaultForeground == RenderColor(red: 229, green: 229, blue: 229))
        #expect(theme.defaultBackground == RenderColor(red: 0, green: 0, blue: 0))
        #expect(theme.cursor == RenderColor(red: 229, green: 229, blue: 229))
        #expect(theme.cursorText == RenderColor(red: 0, green: 0, blue: 0))
    }

    @Test("Custom themes replace ANSI colors without changing the extended xterm palette")
    func customThemePaletteBoundary() throws {
        let colors: [RenderColor] = (0..<16).map { index in
            let red = UInt8(index + 1)
            let green = UInt8(index + 33)
            let blue = UInt8(index + 65)
            return RenderColor(red: red, green: green, blue: blue)
        }
        let theme = try makeTheme(ansiColors: colors)
        let ansiCases = (0..<16).map { index in
            (escape: "\u{1B}[38;5;\(index)m", expected: colors[index])
        }

        for item in ansiCases {
            #expect(try resolvedStyle(after: item.escape, theme: theme).foreground == item.expected)
        }
        #expect(
            try resolvedStyle(after: "\u{1B}[38;5;16m", theme: theme).foreground
                == resolvedStyle(after: "\u{1B}[38;5;16m", theme: .dark).foreground
        )
        #expect(
            try resolvedStyle(after: "\u{1B}[38;5;255m", theme: theme).foreground
                == resolvedStyle(after: "\u{1B}[38;5;255m", theme: .dark).foreground
        )
    }

    @Test("Search highlight derivation is deterministic and never weaker than the baked color")
    func searchHighlightDerivation() throws {
        // Intent: derived search colors are stable, distinct from both competing
        //   backgrounds, and at least as separated as the previous baked highlight.
        // Why it exists: every bundled theme must get a usable search channel even
        //   when one of its backgrounds equals a derivation candidate.
        // Scenario: a theme deliberately uses the old baked search color as its
        //   default and the baked selection color as its selection background.
        let defaultBackground = RenderColor(red: 175, green: 128, blue: 20)
        let selectionBackground = RenderColor(red: 56, green: 88, blue: 140)
        let first = try makeTheme(
            defaultBackground: defaultBackground,
            selectionBackground: selectionBackground
        )
        let second = try makeTheme(
            defaultBackground: defaultBackground,
            selectionBackground: selectionBackground
        )
        let baked = RenderColor(red: 175, green: 128, blue: 20)

        #expect(first.searchMatchBackground == second.searchMatchBackground)
        #expect(first.searchMatchBackground != defaultBackground)
        #expect(first.searchMatchBackground != selectionBackground)
        #expect(
            separationScore(
                first.searchMatchBackground,
                from: defaultBackground,
                and: selectionBackground
            ) >= separationScore(baked, from: defaultBackground, and: selectionBackground)
        )
    }

    @Test("Default and ANSI colors resolve through the baked theme")
    func defaultsAndANSIColors() throws {
        let cases: [(escape: String, expected: RenderColor)] = [
            ("", .init(red: 229, green: 229, blue: 229)),
            ("\u{1B}[30m", .init(red: 0, green: 0, blue: 0)),
            ("\u{1B}[31m", .init(red: 205, green: 0, blue: 0)),
            ("\u{1B}[32m", .init(red: 0, green: 205, blue: 0)),
            ("\u{1B}[33m", .init(red: 205, green: 205, blue: 0)),
            ("\u{1B}[34m", .init(red: 0, green: 0, blue: 238)),
            ("\u{1B}[35m", .init(red: 205, green: 0, blue: 205)),
            ("\u{1B}[36m", .init(red: 0, green: 205, blue: 205)),
            ("\u{1B}[37m", .init(red: 229, green: 229, blue: 229)),
            ("\u{1B}[90m", .init(red: 127, green: 127, blue: 127)),
            ("\u{1B}[91m", .init(red: 255, green: 0, blue: 0)),
            ("\u{1B}[92m", .init(red: 0, green: 255, blue: 0)),
            ("\u{1B}[93m", .init(red: 255, green: 255, blue: 0)),
            ("\u{1B}[94m", .init(red: 92, green: 92, blue: 255)),
            ("\u{1B}[95m", .init(red: 255, green: 0, blue: 255)),
            ("\u{1B}[96m", .init(red: 0, green: 255, blue: 255)),
            ("\u{1B}[97m", .init(red: 255, green: 255, blue: 255)),
        ]

        for item in cases {
            let resolved = try resolvedStyle(after: item.escape)
            #expect(resolved.foreground == item.expected)
            #expect(resolved.background == RenderTheme.dark.defaultBackground)
        }
    }

    @Test("The xterm cube and grayscale formulas resolve their boundaries")
    func xtermFormulaColors() throws {
        let cases: [(index: UInt8, expected: RenderColor)] = [
            (16, .init(red: 0, green: 0, blue: 0)),
            (21, .init(red: 0, green: 0, blue: 255)),
            (46, .init(red: 0, green: 255, blue: 0)),
            (196, .init(red: 255, green: 0, blue: 0)),
            (231, .init(red: 255, green: 255, blue: 255)),
            (232, .init(red: 8, green: 8, blue: 8)),
            (255, .init(red: 238, green: 238, blue: 238)),
        ]

        for item in cases {
            let resolved = try resolvedStyle(after: "\u{1B}[38;5;\(item.index)m")
            #expect(resolved.foreground == item.expected)
        }
    }

    @Test("RGB passes through and bold does not brighten indexed colors")
    func rgbAndBoldColorIndependence() throws {
        let rgb = try resolvedStyle(after: "\u{1B}[38;2;12;34;56m")
        let bold = try resolvedStyle(after: "\u{1B}[1;31m")

        #expect(rgb.foreground == RenderColor(red: 12, green: 34, blue: 56))
        #expect(bold.foreground == RenderTheme.dark.ansiColors[1])
        #expect(bold.bold)
    }

    @Test("Reverse handles defaults and precedes dim while hidden remains explicit")
    func reverseDimAndHiddenPipeline() throws {
        let defaultReverse = try resolvedStyle(after: "\u{1B}[7m")
        let resolved = try resolvedStyle(
            after: "\u{1B}[1;2;7;8;38;2;100;80;60;48;2;20;40;60m"
        )

        #expect(defaultReverse.foreground == RenderTheme.dark.defaultBackground)
        #expect(defaultReverse.background == RenderTheme.dark.defaultForeground)
        #expect(resolved.foreground == RenderColor(red: 10, green: 20, blue: 30))
        #expect(resolved.background == RenderColor(red: 100, green: 80, blue: 60))
        #expect(resolved.bold)
        #expect(resolved.hidden)
    }

    private func resolvedStyle(
        after escape: String,
        theme: RenderTheme = .dark
    ) throws -> ResolvedCellStyle {
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\(escape)A".utf8))
        let cell = try #require(terminal.cell(row: 0, column: 0))
        return resolveCellStyle(cell.style, theme: theme)
    }

    private func makeTheme(
        ansiColors: [RenderColor] = Array(repeating: .init(red: 1, green: 2, blue: 3), count: 16),
        defaultBackground: RenderColor = .init(red: 4, green: 5, blue: 6),
        selectionBackground: RenderColor = .init(red: 7, green: 8, blue: 9)
    ) throws -> RenderTheme {
        RenderTheme(
            ansiColors: try #require(RenderANSIColors(exactly: ansiColors)),
            defaultForeground: .init(red: 10, green: 11, blue: 12),
            defaultBackground: defaultBackground,
            selectionForeground: .init(red: 13, green: 14, blue: 15),
            selectionBackground: selectionBackground,
            cursor: .init(red: 16, green: 17, blue: 18),
            cursorText: .init(red: 19, green: 20, blue: 21)
        )
    }

    private func separationScore(
        _ candidate: RenderColor,
        from first: RenderColor,
        and second: RenderColor
    ) -> Int {
        min(squaredDistance(candidate, first), squaredDistance(candidate, second))
    }

    private func squaredDistance(_ first: RenderColor, _ second: RenderColor) -> Int {
        let red = Int(first.red) - Int(second.red)
        let green = Int(first.green) - Int(second.green)
        let blue = Int(first.blue) - Int(second.blue)
        return red * red + green * green + blue * blue
    }
}
