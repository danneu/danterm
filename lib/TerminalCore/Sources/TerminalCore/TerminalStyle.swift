// Semantic terminal presentation values, kept independent of renderer palette policy.

/// Retains a terminal color without resolving indexed entries through a renderer palette.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

/// Distinguishes the underline shapes that affect cell presentation.
public enum TerminalUnderlineStyle: Hashable, Sendable {
    case none
    case single
    case double
    case curly
    case dotted
    case dashed
}

/// Captures semantic SGR presentation state without resolving renderer policy.
///
/// `Hashable` rather than merely `Equatable` because the grid stores a style *id* per cell and
/// interns styles through a dictionary keyed on this type (`research/15/H3`); hashing is what makes
/// that intern O(1).
public struct TerminalStyle: Hashable, Sendable {
    /// Foreground remains semantic until a renderer applies palette policy.
    public internal(set) var foreground: TerminalColor

    /// Background remains semantic so erase behavior can retain the selected color.
    public internal(set) var background: TerminalColor

    /// Bold is independent from indexed-color brightness.
    public internal(set) var bold: Bool

    /// Dim remains independent from bold even though SGR 22 clears both.
    public internal(set) var dim: Bool

    /// Italic records presentation intent without selecting a font.
    public internal(set) var italic: Bool

    /// Underline shape remains semantic until render planning.
    public internal(set) var underline: TerminalUnderlineStyle

    /// Underline color remains independent from foreground and renderer palette policy.
    public internal(set) var underlineColor: TerminalColor

    /// Reverse is retained as an attribute rather than eagerly swapping colors.
    public internal(set) var reverse: Bool

    /// Hidden records presentation intent without removing cell content.
    public internal(set) var hidden: Bool

    /// Strikethrough records presentation intent independently of glyph shaping.
    public internal(set) var strikethrough: Bool

    /// Creates a semantic style for public inspection and deterministic expectations.
    public init(
        foreground: TerminalColor = .default,
        background: TerminalColor = .default,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: TerminalUnderlineStyle = .none,
        underlineColor: TerminalColor = .default,
        reverse: Bool = false,
        hidden: Bool = false,
        strikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.underlineColor = underlineColor
        self.reverse = reverse
        self.hidden = hidden
        self.strikethrough = strikethrough
    }
}
