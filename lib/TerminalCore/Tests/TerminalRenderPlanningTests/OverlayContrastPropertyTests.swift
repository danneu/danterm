// Fleet-wide and exhaustive-domain proofs for adaptive overlay color contracts.
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct OverlayContrastPropertyTests {
    @Test("Every bundled theme satisfies overlay and cursor contrast over truecolor inputs")
    func bundledThemeContrastSweep() throws {
        let themes = try loadBundledThemes()
        try #require(themes.count == 592)
        let lattice: [UInt8] = [0, 127, 255]
        let latticeColors = lattice.flatMap { red in
            lattice.flatMap { green in
                lattice.map { blue in RenderColor(red: red, green: green, blue: blue) }
            }
        }

        for theme in themes {
            let backgrounds = latticeColors + adversarialColors(for: theme)
            for background in backgrounds {
                let styles = [
                    resolveOverlayStyle(
                        state: .selection,
                        background: background,
                        foreground: theme.selectionForeground,
                        theme: theme
                    ),
                    resolveOverlayStyle(
                        state: .activeSearchMatch,
                        background: background,
                        foreground: theme.defaultForeground,
                        theme: theme
                    ),
                    resolveOverlayStyle(
                        state: .selectionAndActiveSearchMatch,
                        background: background,
                        foreground: theme.selectionForeground,
                        theme: theme
                    ),
                ]
                let fills = [background] + styles.map(\.fill)
                for first in fills.indices {
                    for second in fills.indices where second > first {
                        try requireSeparation(fills[first], fills[second], minimum: 40)
                    }
                }
                for style in styles {
                    try requireSeparation(style.foreground, style.fill, minimum: 100)
                }
                #expect(resolveBrightnessSeparatedColor(
                    seed: styles[0].fill,
                    avoiding: [background],
                    minimumSeparation: 40
                ) == styles[0].fill)
                #expect(resolveBrightnessSeparatedColor(
                    seed: styles[1].fill,
                    avoiding: [background, styles[0].fill],
                    minimumSeparation: 40
                ) == styles[1].fill)
                #expect(resolveBrightnessSeparatedColor(
                    seed: styles[2].fill,
                    avoiding: [background, styles[0].fill, styles[1].fill],
                    minimumSeparation: 40
                ) == styles[2].fill)
                for cursorBackground in fills {
                    let cursor = resolveCursorStyle(background: cursorBackground, theme: theme)
                    try requireSeparation(cursor.fill, cursorBackground, minimum: 60)
                    try requireSeparation(cursor.foreground, cursor.fill, minimum: 100)
                    #expect(resolveBrightnessSeparatedColor(
                        seed: cursor.fill,
                        avoiding: [cursorBackground],
                        minimumSeparation: 60
                    ) == cursor.fill)
                }

                if brightnessSeparation(theme.selectionBackground, background) >= 40 {
                    #expect(styles[0].fill == theme.selectionBackground)
                }
                if brightnessSeparation(theme.cursor, background) >= 60 {
                    #expect(resolveCursorStyle(background: background, theme: theme).fill == theme.cursor)
                }
            }
        }
    }

    @Test("Darkening preserves one channel ratio within one code point over all RGB seeds")
    func darkeningRoundingBoundOverFullColorDomain() {
        for red in UInt8.min...UInt8.max {
            for green in UInt8.min...UInt8.max {
                for blue in UInt8.min...UInt8.max {
                    let seed = RenderColor(red: red, green: green, blue: blue)
                    let sourceBrightness = perceivedBrightness(of: seed)
                    guard sourceBrightness > 0 else { continue }
                    let targetBrightness = sourceBrightness / 2
                    let moved = colorMoved(seed, toBrightness: targetBrightness)
                    let channels = [
                        (seed.red, moved.red),
                        (seed.green, moved.green),
                        (seed.blue, moved.blue),
                    ]
                    for (source, result) in channels {
                        let roundingError = abs(
                            Int(result) * sourceBrightness - Int(source) * targetBrightness
                        )
                        if roundingError > sourceBrightness {
                            Issue.record("Darkening exceeded one code point for \(seed)")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test("A fixed seed changes push direction at most once across background brightness")
    func pushDirectionHasSingleDiscontinuity() {
        let seed = RenderColor(red: 48, green: 132, blue: 216)
        let seedBrightness = perceivedBrightness(of: seed)
        var previousDirection: Int?
        var flips = 0

        for component in UInt8.min...UInt8.max {
            let background = RenderColor(red: component, green: component, blue: component)
            let resolved = resolveBrightnessSeparatedColor(
                seed: seed,
                avoiding: [background],
                minimumSeparation: 40
            )
            let direction = perceivedBrightness(of: resolved) - seedBrightness
            guard direction != 0 else { continue }
            let normalized = direction < 0 ? -1 : 1
            if let previousDirection, previousDirection != normalized {
                flips += 1
            }
            previousDirection = normalized
        }

        #expect(flips <= 1)
    }

    // Intent: the resolver returns an admissible color at the minimum achieved-
    // brightness distance from its seed, breaking ties toward the darker result.
    // Why it exists: every other proof here checks that the answer clears its
    // separations, never that it is the *nearest* answer that does. A resolver
    // that derives candidates from forbidden-interval edges plus a bounded
    // quantization probe would still pass all of them while silently returning a
    // farther color whenever the drift exceeded its probe.
    // Scenario: an independent oracle enumerates the whole requested-target
    // domain, judges admissibility on achieved post-quantization brightness, and
    // is run over the avoidance-set sizes and separations the planner passes.
    @Test("Brightness resolution matches a full-domain oracle's nearest admissible result")
    func nearestAdmissibleMatchesFullDomainOracle() {
        for seed in oracleSeeds() {
            for probe in oracleProbes() {
                let avoided = probe.avoided.map(perceivedBrightness(of:))
                let resolved = resolveBrightnessSeparatedColor(
                    seed: seed,
                    avoiding: probe.avoided,
                    minimumSeparation: probe.separation
                )
                let resolvedBrightness = perceivedBrightness(of: resolved)
                let seedBrightness = perceivedBrightness(of: seed)

                guard let expected = oracleOutcome(
                    seed: seed,
                    avoided: avoided,
                    separation: probe.separation
                ) else {
                    Issue.record("No admissible color exists for \(seed) vs \(probe.avoided)")
                    return
                }

                // A seed already clearing every separation must come back untouched,
                // not merely at distance zero: the identity is what makes overlay
                // resolution idempotent.
                if expected.distance == 0 && resolved != seed {
                    Issue.record("Qualifying seed \(seed) was not preserved")
                    return
                }
                let actual = OracleOutcome(
                    distance: abs(resolvedBrightness - seedBrightness),
                    brightness: resolvedBrightness
                )
                if actual != expected {
                    let message: String = "Resolving \(seed) against \(probe.avoided)"
                        + " at \(probe.separation) gave \(actual), oracle says \(expected)"
                    Issue.record(Comment(rawValue: message))
                    return
                }
                if avoided.contains(where: { abs(resolvedBrightness - $0) < probe.separation }) {
                    Issue.record("Resolved \(resolved) violates its own separation")
                    return
                }
            }
        }
    }

    /// The behavioral tuple the resolver's contract fixes. Exact RGB is not part
    /// of it: several targets can reach one achieved brightness, and which color
    /// carries it is an implementation detail of the quantization.
    private struct OracleOutcome: Equatable {
        let distance: Int
        let brightness: Int
    }

    /// Re-derives the contract by brute force over the requested-target domain,
    /// sharing nothing with the resolver but `colorMoved` and the brightness metric.
    private func oracleOutcome(
        seed: RenderColor,
        avoided: [Int],
        separation: Int
    ) -> OracleOutcome? {
        var best: OracleOutcome?
        let seedBrightness = perceivedBrightness(of: seed)
        for target in 0...255 {
            let brightness = perceivedBrightness(of: colorMoved(seed, toBrightness: target))
            guard avoided.allSatisfy({ abs(brightness - $0) >= separation }) else { continue }
            let outcome = OracleOutcome(
                distance: abs(brightness - seedBrightness),
                brightness: brightness
            )
            guard let current = best else {
                best = outcome
                continue
            }
            if outcome.distance < current.distance
                || (outcome.distance == current.distance && outcome.brightness < current.brightness)
            {
                best = outcome
            }
        }
        return best
    }

    /// Seeds spanning the planner's own (theme colors, glyph colors) plus ones
    /// whose weighted sum truncates hard, where target and achieved diverge most.
    private func oracleSeeds() -> [RenderColor] {
        [
            RenderColor(red: 0, green: 0, blue: 0),
            RenderColor(red: 255, green: 255, blue: 255),
            RenderColor(red: 1, green: 0, blue: 0),
            RenderColor(red: 0, green: 0, blue: 1),
            RenderColor(red: 2, green: 1, blue: 3),
            RenderColor(red: 254, green: 255, blue: 253),
            RenderColor(red: 80, green: 127, blue: 235),
            RenderColor(red: 220, green: 220, blue: 220),
            RenderColor(red: 255, green: 108, blue: 0),
            RenderColor(red: 17, green: 3, blue: 250),
        ]
    }

    /// The avoidance sets the planner actually builds: one color for the glyph
    /// push and the cursor fill, and the progressively grown fill ladder.
    private func oracleProbes() -> [(avoided: [RenderColor], separation: Int)] {
        var probes: [(avoided: [RenderColor], separation: Int)] = []
        for component in UInt8.min...UInt8.max {
            let background = RenderColor(red: component, green: 255 - component, blue: component)
            for separation in [40, 60, 100] {
                probes.append(([background], separation))
            }
        }
        for component in UInt8.min...UInt8.max {
            let background = RenderColor(
                red: component,
                green: component,
                blue: 255 - component
            )
            let selection = resolveBrightnessSeparatedColor(
                seed: RenderColor(red: 220, green: 220, blue: 220),
                avoiding: [background],
                minimumSeparation: 40
            )
            let match = resolveBrightnessSeparatedColor(
                seed: RenderColor(red: 246, green: 190, blue: 0),
                avoiding: [background, selection],
                minimumSeparation: 40
            )
            probes.append(([background, selection], 40))
            probes.append(([background, selection, match], 40))
        }
        return probes
    }

    private func requireSeparation(
        _ first: RenderColor,
        _ second: RenderColor,
        minimum: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try #require(
            brightnessSeparation(first, second) >= minimum,
            sourceLocation: sourceLocation
        )
    }

    private func loadBundledThemes() throws -> [RenderTheme] {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repository.deleteLastPathComponent()
        }
        let themeDirectory = repository.appending(path: "themes", directoryHint: .isDirectory)
        let paths = try FileManager.default.contentsOfDirectory(
            at: themeDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        return try paths.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { path in
            let source = try JSONDecoder().decode(ThemeSource.self, from: Data(contentsOf: path))
            return try source.renderTheme()
        }
    }

    private func adversarialColors(for theme: RenderTheme) -> [RenderColor] {
        [
            theme.defaultBackground,
            theme.selectionBackground,
            theme.cursor,
            theme.defaultForeground,
        ].flatMap { color in
            [color] + perturbed(color)
        }
    }

    private func perturbed(_ color: RenderColor) -> [RenderColor] {
        var colors: [RenderColor] = []
        for channel in 0..<3 {
            for offset in [-1, 1] {
                var components = [Int(color.red), Int(color.green), Int(color.blue)]
                let changed = components[channel] + offset
                guard (0...255).contains(changed) else { continue }
                components[channel] = changed
                colors.append(RenderColor(
                    red: UInt8(components[0]),
                    green: UInt8(components[1]),
                    blue: UInt8(components[2])
                ))
            }
        }
        return colors
    }
}

private struct ThemeSource: Decodable {
    let ansiPalette: [String]
    let background: String
    let cursor: String
    let cursorText: String
    let foreground: String
    let selectionBackground: String
    let selectionForeground: String

    func renderTheme() throws -> RenderTheme {
        let palette = try ansiPalette.map(RenderColor.init(hex:))
        return RenderTheme(
            ansiColors: try #require(RenderANSIColors(exactly: palette)),
            defaultForeground: try RenderColor(hex: foreground),
            defaultBackground: try RenderColor(hex: background),
            selectionForeground: try RenderColor(hex: selectionForeground),
            selectionBackground: try RenderColor(hex: selectionBackground),
            cursor: try RenderColor(hex: cursor),
            cursorText: try RenderColor(hex: cursorText)
        )
    }
}

private extension RenderColor {
    init(hex: String) throws {
        let value = try #require(UInt32(hex.dropFirst(), radix: 16))
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }
}
