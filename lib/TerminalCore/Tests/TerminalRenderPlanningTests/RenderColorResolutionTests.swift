// Behavioral proofs for deterministic terminal-color resolution and the baked theme.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderColorResolutionTests {
    @Test("The baked dark theme retains its complete fixed palette")
    func bakedDarkThemeGoldenValues() {
        let theme = RenderTheme.dark

        #expect(theme.ansiColors == [
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

    private func resolvedStyle(after escape: String) throws -> ResolvedCellStyle {
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\(escape)A".utf8))
        let cell = try #require(terminal.cell(row: 0, column: 0))
        return resolveCellStyle(cell.style, theme: .dark)
    }
}
