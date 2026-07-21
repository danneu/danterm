// Pure conversion from TerminalCore's semantic SGR colors and attributes into
// concrete frame colors. Keep run construction and cursor policy elsewhere.
import TerminalCore

/// Holds fully resolved cell presentation immediately before layer-specific
/// filtering and canonical run construction.
struct ResolvedCellStyle: Equatable, Sendable {
    let foreground: RenderColor
    let background: RenderColor
    let bold: Bool
    let italic: Bool
    let underline: TerminalUnderlineStyle
    let underlineColor: RenderColor
    let hidden: Bool
    let strikethrough: Bool
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
