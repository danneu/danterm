// Behavioral proofs for deterministic terminal-color resolution and the baked theme.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderColorResolutionTests {
    @Test("Perceived brightness maps every gray to its component")
    func perceivedBrightnessGrayIdentity() {
        for component in UInt8.min...UInt8.max {
            let gray = RenderColor(red: component, green: component, blue: component)
            #expect(perceivedBrightness(of: gray) == Int(component))
        }
    }

    @Test("Minimum-separation resolution preserves qualifying seeds and pushes collisions")
    func minimumSeparationResolution() {
        let background = RenderColor(red: 100, green: 100, blue: 100)
        let preserved = RenderColor(red: 180, green: 180, blue: 180)
        let collision = RenderColor(red: 110, green: 110, blue: 110)

        #expect(resolveBrightnessSeparatedColor(
            seed: preserved,
            avoiding: [background],
            minimumSeparation: 40
        ) == preserved)

        let pushed = resolveBrightnessSeparatedColor(
            seed: collision,
            avoiding: [background],
            minimumSeparation: 40
        )
        #expect(brightnessSeparation(pushed, background) >= 40)
        #expect(pushed != collision)
    }

    @Test("Every overlay state separates its fill and text over a colliding background")
    func overlayStyleSeparation() throws {
        let collision = RenderColor(red: 80, green: 80, blue: 80)
        let theme = try makeTheme(
            defaultBackground: collision,
            selectionBackground: collision,
            selectionForeground: collision
        )
        let states: [RenderOverlayState] = [
            .selection,
            .activeSearchMatch,
            .selectionAndActiveSearchMatch,
            .searchMatch,
            .selectionAndSearchMatch,
        ]
        let styles = states.map {
            resolveOverlayStyle(
                state: $0,
                background: collision,
                foreground: collision,
                theme: theme
            )
        }
        let fills = [collision] + styles.prefix(4).map(\.fill)

        for first in fills.indices {
            for second in fills.indices where second > first {
                #expect(brightnessSeparation(fills[first], fills[second]) >= 40)
            }
        }
        for style in styles {
            #expect(brightnessSeparation(style.foreground, style.fill) >= 100)
        }
        #expect(styles[3].fill == styles[4].fill)
    }

    @Test("Cursor fill and text separate from the color beneath the cursor")
    func cursorStyleSeparation() throws {
        let collision = RenderColor(red: 96, green: 96, blue: 96)
        let theme = try makeTheme(cursor: collision, cursorText: collision)

        let style = resolveCursorStyle(background: collision, theme: theme)

        #expect(brightnessSeparation(style.fill, collision) >= 60)
        #expect(brightnessSeparation(style.foreground, style.fill) >= 100)
    }

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
        for index in 0..<16 {
            #expect(palette[index] == colors[index])
        }
        #expect(RenderANSIColors(exactly: Array(colors.dropLast())) == nil)
        #expect(RenderANSIColors(exactly: overlong) == nil)
    }

    // Intent: palette equality reads every one of the sixteen entries.
    // Why it exists: `RenderTheme` equality gates plan reuse in `PaneFramePlanner`,
    // and `RenderANSIColors` hand-writes `==` because `InlineArray` carries no
    // `Equatable` conformance. An `==` that skipped an entry would silently let
    // reuse accept a changed palette.
    // Scenario: for each index, a palette differing from a baseline only there.
    @Test("Palette equality distinguishes a change at any one index")
    func ansiPaletteEqualityPerIndex() throws {
        let baseline: [RenderColor] = (0..<16).map { (index: Int) -> RenderColor in
            RenderColor(red: UInt8(index), green: UInt8(index + 16), blue: UInt8(index + 32))
        }
        let unchanged: RenderANSIColors = try #require(RenderANSIColors(exactly: baseline))
        let rebuilt: RenderANSIColors = try #require(RenderANSIColors(exactly: baseline))
        #expect(rebuilt == unchanged)

        for index in 0..<16 {
            var altered: [RenderColor] = baseline
            altered[index] = RenderColor(red: 200, green: 201, blue: 202)
            let changed: RenderANSIColors = try #require(RenderANSIColors(exactly: altered))
            #expect(changed != unchanged)
        }
    }

    @Test("The baked dark theme retains its complete fixed palette")
    func bakedDarkThemeGoldenValues() {
        let theme = RenderTheme.dark

        let expectedPalette = [
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
        ]
        for index in 0..<16 {
            #expect(theme.ansiColors[index] == expectedPalette[index])
        }
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

    // Intent: the active-match hue seed is a renderer constant, so two themes
    // that agree on every color the ladder consults resolve the same match fill
    // however far apart the rest of their palettes are.
    // Why it exists: the seed used to be derived per theme. The derivation is
    // gone, and this stops a future one from creeping back in unnoticed.
    // Scenario: two themes share their surface and selection colors but differ
    // in all sixteen ANSI entries and both cursor colors.
    @Test("Search highlight keeps a stable hue seed independent of the rest of the theme")
    func searchHighlightSeed() throws {
        let background = RenderColor(red: 30, green: 30, blue: 30)
        let first = try makeTheme(
            ansiColors: Array(repeating: .init(red: 0, green: 0, blue: 0), count: 16),
            cursor: .init(red: 1, green: 1, blue: 1),
            cursorText: .init(red: 2, green: 2, blue: 2)
        )
        let second = try makeTheme(
            ansiColors: Array(repeating: .init(red: 255, green: 255, blue: 255), count: 16),
            cursor: .init(red: 254, green: 254, blue: 254),
            cursorText: .init(red: 253, green: 253, blue: 253)
        )

        #expect(
            resolveOverlayFill(state: .activeSearchMatch, background: background, theme: first)
                == resolveOverlayFill(
                    state: .activeSearchMatch,
                    background: background,
                    theme: second
                )
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
        selectionBackground: RenderColor = .init(red: 7, green: 8, blue: 9),
        selectionForeground: RenderColor = .init(red: 13, green: 14, blue: 15),
        cursor: RenderColor = .init(red: 16, green: 17, blue: 18),
        cursorText: RenderColor = .init(red: 19, green: 20, blue: 21)
    ) throws -> RenderTheme {
        RenderTheme(
            ansiColors: try #require(RenderANSIColors(exactly: ansiColors)),
            defaultForeground: .init(red: 10, green: 11, blue: 12),
            defaultBackground: defaultBackground,
            selectionForeground: selectionForeground,
            selectionBackground: selectionBackground,
            cursor: cursor,
            cursorText: cursorText
        )
    }
}
