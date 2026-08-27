// Pure conversion from TerminalCore's semantic SGR colors and attributes into
// concrete frame colors. Keep run construction and cursor policy elsewhere.
import TerminalCore

/// Holds fully resolved cell presentation immediately before layer-specific
/// filtering and canonical run construction.
///
/// Stored `var`s so the hover, selection, and block-cursor overrides in
/// `plannedCell` can each set the one or three fields they own instead of
/// restating all eight in a fresh literal and risking a mis-threaded field.
struct ResolvedCellStyle: Equatable, Sendable {
    var foreground: RenderColor
    var background: RenderColor
    var bold: Bool
    var italic: Bool
    var underline: TerminalUnderlineStyle
    var underlineColor: RenderColor
    var hidden: Bool
    var strikethrough: Bool
}

/// Carries the fill and glyph color selected for one semantic overlay state.
struct ResolvedOverlayStyle: Equatable, Sendable {
    let fill: RenderColor
    let foreground: RenderColor
}

/// Carries the fill and glyph color selected for a cursor over one cell presentation.
struct ResolvedCursorStyle: Equatable, Sendable {
    let fill: RenderColor
    let foreground: RenderColor
}

let overlayFillMinimumBrightnessSeparation = 40
let overlayTextMinimumBrightnessSeparation = 100
let cursorFillMinimumBrightnessSeparation = 60

// Hue seeds for the three overlay rungs the theme does not name. The fourth
// seed is `RenderTheme.selectionBackground`, which a caller does choose, so it
// stays on the theme. Anything a caller cannot supply belongs here, in rung
// order, beside the separations the same ladder is resolved against.
private let activeSearchMatchSeed = RenderColor(red: 175, green: 128, blue: 20)
private let combinedActiveMatchSeed = RenderColor(red: 80, green: 127, blue: 235)
private let quietMatchSeed = RenderColor(red: 110, green: 90, blue: 45)

/// Maps an sRGB color to deterministic integer perceived brightness.
func perceivedBrightness(of color: RenderColor) -> Int {
    (77 * Int(color.red) + 151 * Int(color.green) + 28 * Int(color.blue)) >> 8
}

/// Measures absolute distance in the renderer's perceived-brightness metric.
func brightnessSeparation(_ first: RenderColor, _ second: RenderColor) -> Int {
    abs(perceivedBrightness(of: first) - perceivedBrightness(of: second))
}

/// Widest gap between a requested target brightness and the brightness the moved
/// color actually achieves. Component rounding contributes at most half a code
/// point each, and the weights sum to 256, so that is half a unit of brightness;
/// the `>> 8` truncation costs one more; and the seed's own truncated fraction
/// re-enters scaled by at most one. Three units, probed with one to spare.
private let brightnessQuantizationDrift = 4

/// Names which brightness pole gives selection one coherent meaning across a pane.
private enum BrightnessDirection {
    case lighter
    case darker

    var opposite: BrightnessDirection {
        switch self {
        case .lighter: .darker
        case .darker: .lighter
        }
    }

    func contains(_ brightness: Int, relativeTo background: Int, separation: Int) -> Bool {
        switch self {
        case .lighter: brightness >= background + separation
        case .darker: brightness <= background - separation
        }
    }
}

/// Keeps a qualifying seed exact or moves it to the nearest brightness that
/// clears every competing color, preferring the darker result on a tie.
///
/// Each competing color forbids one closed brightness interval, so the nearest
/// allowed brightness always sits against some interval's edge or at the ends of
/// the domain -- a set of size O(colors), not the whole 0...255 range. Requested
/// targets and achieved brightnesses diverge under 8-bit quantization, so each
/// edge is probed within `brightnessQuantizationDrift` and every candidate is
/// judged on what it achieved, never on what it asked for.
func resolveBrightnessSeparatedColor(
    seed: RenderColor,
    avoiding colors: [RenderColor],
    minimumSeparation: Int
) -> RenderColor {
    precondition((0...255).contains(minimumSeparation))
    guard let best = bestBrightnessSeparatedColor(
        seed: seed,
        avoiding: colors,
        minimumSeparation: minimumSeparation,
        on: nil
    ) else {
        // Unreachable for the ladders this planner builds -- the widest is five
        // points spaced by 40 in a 0...255 domain -- but a caller asking for a
        // separation no color can satisfy has no answer to be given.
        preconditionFailure("no color clears \(minimumSeparation) from every competing color")
    }
    return best
}

/// Finds the seed-nearest admissible color, optionally restricted to one side
/// of a background so selection can prefer one pole without changing other rungs.
private func bestBrightnessSeparatedColor(
    seed: RenderColor,
    avoiding colors: [RenderColor],
    minimumSeparation: Int,
    on side: (direction: BrightnessDirection, background: RenderColor)?
) -> RenderColor? {
    let seedBrightness = perceivedBrightness(of: seed)
    let competing = colors.map(perceivedBrightness(of:))
    let seedIsOnRequestedSide = side.map { side in
        side.direction.contains(
            seedBrightness,
            relativeTo: perceivedBrightness(of: side.background),
            separation: minimumSeparation
        )
    } ?? true
    guard !seedIsOnRequestedSide
        || competing.contains(where: { abs(seedBrightness - $0) < minimumSeparation })
    else {
        return seed
    }

    var best: RenderColor?
    var bestDistance = Int.max
    var bestBrightness = Int.max
    for edge in [0, 255] + competing.flatMap({
        [$0 - minimumSeparation, $0 + minimumSeparation]
    }) {
        for offset in -brightnessQuantizationDrift...brightnessQuantizationDrift {
            let target = edge + offset
            guard (0...255).contains(target) else { continue }
            let candidate = colorMoved(seed, toBrightness: target)
            let brightness = perceivedBrightness(of: candidate)
            guard competing.allSatisfy({ abs(brightness - $0) >= minimumSeparation }) else {
                continue
            }
            if let side,
               !side.direction.contains(
                   brightness,
                   relativeTo: perceivedBrightness(of: side.background),
                   separation: minimumSeparation
               )
            {
                continue
            }
            let distance = abs(brightness - seedBrightness)
            if distance < bestDistance
                || (distance == bestDistance && brightness < bestBrightness)
            {
                best = candidate
                bestDistance = distance
                bestBrightness = brightness
            }
        }
    }

    return best
}

/// Resolves selection against both its cell surface and the pane canvas on the
/// theme's ink-facing side, crossing sides only when the preferred gamut is empty.
private func resolveSelectionFill(background: RenderColor, theme: RenderTheme) -> RenderColor {
    let preferred: BrightnessDirection = perceivedBrightness(of: theme.defaultForeground)
        >= perceivedBrightness(of: theme.defaultBackground)
        ? .lighter
        : .darker
    let competitors = [background, theme.defaultBackground]
    if let fill = bestBrightnessSeparatedColor(
        seed: theme.selectionBackground,
        avoiding: competitors,
        minimumSeparation: overlayFillMinimumBrightnessSeparation,
        on: (preferred, background)
    ) {
        return fill
    }
    guard let fill = bestBrightnessSeparatedColor(
        seed: theme.selectionBackground,
        avoiding: competitors,
        minimumSeparation: overlayFillMinimumBrightnessSeparation,
        on: (preferred.opposite, background)
    ) else {
        preconditionFailure("selection has no brightness clear of its surface and canvas")
    }
    return fill
}

/// Resolves one overlay fill against the cell background and every earlier
/// visual identity so the fill ladder stays pairwise distinguishable.
///
/// Split from the glyph push because the two vary at different granularities:
/// a fill is fixed by the fragment it covers, while the push follows each run's
/// own foreground. The planner resolves one per fragment and the other per run,
/// so anything that folds them back together reintroduces per-cell resolution.
func resolveOverlayFill(
    state: RenderOverlayState,
    background: RenderColor,
    theme: RenderTheme
) -> RenderColor {
    let selection = resolveSelectionFill(background: background, theme: theme)
    if state == .selection {
        return selection
    }
    let match = resolveBrightnessSeparatedColor(
        seed: activeSearchMatchSeed,
        avoiding: [background, selection],
        minimumSeparation: overlayFillMinimumBrightnessSeparation
    )
    if state == .activeSearchMatch {
        return match
    }
    let combinedActiveMatch = resolveBrightnessSeparatedColor(
        seed: combinedActiveMatchSeed,
        avoiding: [background, selection, match],
        minimumSeparation: overlayFillMinimumBrightnessSeparation
    )
    if state == .selectionAndActiveSearchMatch {
        return combinedActiveMatch
    }
    let quietMatch = resolveBrightnessSeparatedColor(
        seed: quietMatchSeed,
        avoiding: [background, selection, match, combinedActiveMatch],
        minimumSeparation: overlayFillMinimumBrightnessSeparation
    )
    // Selection changes the quiet match's glyph source, not its fill. Keeping
    // the fill stable preserves selected-versus-unselected identity through
    // selection overlap without adding a ladder rung that has no total solution.
    return quietMatch
}

/// Moves one glyph color clear of the overlay fill it will be drawn over.
func overlayForeground(_ foreground: RenderColor, over fill: RenderColor) -> RenderColor {
    resolveBrightnessSeparatedColor(
        seed: foreground,
        avoiding: [fill],
        minimumSeparation: overlayTextMinimumBrightnessSeparation
    )
}

/// Pairs the two halves above for callers holding a single cell's presentation,
/// which is the form every overlay proof states its expectations in.
func resolveOverlayStyle(
    state: RenderOverlayState,
    background: RenderColor,
    foreground: RenderColor,
    theme: RenderTheme
) -> ResolvedOverlayStyle {
    let fill = resolveOverlayFill(state: state, background: background, theme: theme)
    return ResolvedOverlayStyle(
        fill: fill,
        foreground: overlayForeground(foreground, over: fill)
    )
}

/// Resolves a cursor fill against the topmost cell color and its glyph color against the fill.
func resolveCursorStyle(
    background: RenderColor,
    theme: RenderTheme
) -> ResolvedCursorStyle {
    let fill = resolveBrightnessSeparatedColor(
        seed: theme.cursor,
        avoiding: [background],
        minimumSeparation: cursorFillMinimumBrightnessSeparation
    )
    return ResolvedCursorStyle(
        fill: fill,
        foreground: resolveBrightnessSeparatedColor(
            seed: theme.cursorText,
            avoiding: [fill],
            minimumSeparation: overlayTextMinimumBrightnessSeparation
        )
    )
}

/// Scales darker colors toward black and brighter colors toward white without
/// floating point; component rounding stays within one stored code point.
func colorMoved(_ seed: RenderColor, toBrightness targetBrightness: Int) -> RenderColor {
    let sourceBrightness = perceivedBrightness(of: seed)
    guard targetBrightness != sourceBrightness else { return seed }
    if targetBrightness < sourceBrightness {
        guard sourceBrightness > 0 else { return seed }
        return RenderColor(
            red: scaled(seed.red, numerator: targetBrightness, denominator: sourceBrightness),
            green: scaled(seed.green, numerator: targetBrightness, denominator: sourceBrightness),
            blue: scaled(seed.blue, numerator: targetBrightness, denominator: sourceBrightness)
        )
    }

    let numerator = targetBrightness - sourceBrightness
    let denominator = 255 - sourceBrightness
    guard denominator > 0 else { return seed }
    return RenderColor(
        red: brightened(seed.red, numerator: numerator, denominator: denominator),
        green: brightened(seed.green, numerator: numerator, denominator: denominator),
        blue: brightened(seed.blue, numerator: numerator, denominator: denominator)
    )
}

private func scaled(_ component: UInt8, numerator: Int, denominator: Int) -> UInt8 {
    UInt8((Int(component) * numerator + denominator / 2) / denominator)
}

private func brightened(_ component: UInt8, numerator: Int, denominator: Int) -> UInt8 {
    let distance = 255 - Int(component)
    return UInt8(Int(component) + (distance * numerator + denominator / 2) / denominator)
}

/// Applies palette lookup, reverse, and dim in their pinned order while
/// retaining the attributes later planning stages need to select work.
func resolveCellStyle(_ style: TerminalStyle, theme: RenderTheme) -> ResolvedCellStyle {
    var foreground = resolveColor(
        style.foreground,
        defaultColor: theme.defaultForeground,
        theme: theme
    )
    var background = resolveColor(
        style.background,
        defaultColor: theme.defaultBackground,
        theme: theme
    )

    if style.reverse {
        swap(&foreground, &background)
    }
    if style.dim {
        foreground = RenderColor(
            red: foreground.red / 2,
            green: foreground.green / 2,
            blue: foreground.blue / 2
        )
    }
    let underlineColor = style.underlineColor == .default
        ? foreground
        : resolveColor(
            style.underlineColor,
            defaultColor: foreground,
            theme: theme
        )

    return ResolvedCellStyle(
        foreground: foreground,
        background: background,
        bold: style.bold,
        italic: style.italic,
        underline: style.underline,
        underlineColor: underlineColor,
        hidden: style.hidden,
        strikethrough: style.strikethrough
    )
}

/// Resolves one semantic terminal color without allowing palette indices or
/// defaults to cross into executor-facing values.
private func resolveColor(
    _ color: TerminalColor,
    defaultColor: RenderColor,
    theme: RenderTheme
) -> RenderColor {
    switch color {
    case .default:
        return defaultColor
    case let .indexed(index) where index < 16:
        return theme.ansiColors[Int(index)]
    case let .indexed(index) where index < 232:
        return xtermCubeColor(index: index)
    case let .indexed(index):
        let component = UInt8(8 + 10 * (Int(index) - 232))
        return RenderColor(red: component, green: component, blue: component)
    case let .rgb(red, green, blue):
        return RenderColor(red: red, green: green, blue: blue)
    }
}

/// Implements the standard xterm 6x6x6 component formula for indices 16-231.
private func xtermCubeColor(index: UInt8) -> RenderColor {
    let offset = Int(index) - 16
    return RenderColor(
        red: xtermCubeComponent(offset / 36),
        green: xtermCubeComponent((offset / 6) % 6),
        blue: xtermCubeComponent(offset % 6)
    )
}

/// Maps one xterm cube coordinate to its canonical eight-bit component.
private func xtermCubeComponent(_ coordinate: Int) -> UInt8 {
    coordinate == 0 ? 0 : UInt8(55 + coordinate * 40)
}
