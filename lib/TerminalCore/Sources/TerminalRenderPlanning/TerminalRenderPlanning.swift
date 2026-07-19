// Deterministic, grid-space frame values shared by the pure planner and its
// eventual executor. Pixel geometry and Apple framework types stay app-side.
import TerminalCore

/// Carries concrete sRGB components across the planning/execution boundary so
/// renderer policy is fully decided before platform drawing begins.
public struct RenderColor: Equatable, Sendable {
    /// Eight-bit red component.
    public let red: UInt8

    /// Eight-bit green component.
    public let green: UInt8

    /// Eight-bit blue component.
    public let blue: UInt8

    /// Creates an executor-ready color without introducing platform color types.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Fixes every palette input needed to turn semantic terminal colors into a
/// deterministic frame while configurable themes remain outside this slice.
public struct RenderTheme: Equatable, Sendable {
    /// The fixed 16-color ANSI palette used for indices 0 through 15.
    public let ansiColors: [RenderColor]

    /// Foreground used when a terminal cell retains semantic `.default`.
    public let defaultForeground: RenderColor

    /// Background used both for semantic `.default` and the frame clear.
    public let defaultBackground: RenderColor

    /// Filled-block cursor color applied before run coalescing.
    public let cursor: RenderColor

    /// Foreground used for visible content beneath the filled-block cursor.
    public let cursorText: RenderColor

    /// The single baked theme for the correctness-first renderer slice.
    public static let dark = RenderTheme(
        ansiColors: [
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
        ],
        defaultForeground: RenderColor(red: 229, green: 229, blue: 229),
        defaultBackground: RenderColor(red: 0, green: 0, blue: 0),
        cursor: RenderColor(red: 229, green: 229, blue: 229),
        cursorText: RenderColor(red: 0, green: 0, blue: 0)
    )

    private init(
        ansiColors: [RenderColor],
        defaultForeground: RenderColor,
        defaultBackground: RenderColor,
        cursor: RenderColor,
        cursorText: RenderColor
    ) {
        self.ansiColors = ansiColors
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.cursor = cursor
        self.cursorText = cursorText
    }
}

/// Bundles every presentation choice that may affect planning so repeated
/// calls never consult focus state, preferences, or another ambient source.
public struct RenderPresentation: Equatable, Sendable {
    /// Palette and cursor colors used to resolve semantic terminal cells.
    public let theme: RenderTheme

    /// Controls whether planning emits and applies the filled-block cursor.
    public let isCursorVisible: Bool

    /// Requires callers to make cursor visibility explicit for every planned frame.
    public init(theme: RenderTheme, isCursorVisible: Bool) {
        self.theme = theme
        self.isCursorVisible = isCursorVisible
    }
}

/// Isolates each executor pass so a complete frame can be replayed without
/// consulting terminal state or carrying state between frames.
public struct RenderFramePlan: Equatable, Sendable {
    /// Viewport width in terminal grid columns.
    public let columns: Int

    /// Viewport height in terminal grid rows.
    public let rows: Int

    /// Concrete color used to clear the full viewport before drawing runs.
    public let defaultBackground: RenderColor

    /// Non-default background spans in canonical row-major order.
    public let backgroundRuns: [RenderBackgroundRun]

    /// Glyph-bearing spans in canonical row-major order.
    public let textRuns: [RenderTextRun]

    /// Underline and strikethrough spans in canonical row-major order.
    public let decorationRuns: [RenderDecorationRun]

    /// Filled block to draw when cursor presentation is enabled.
    public let cursor: RenderCursor?

    init(
        columns: Int,
        rows: Int,
        defaultBackground: RenderColor,
        backgroundRuns: [RenderBackgroundRun],
        textRuns: [RenderTextRun],
        decorationRuns: [RenderDecorationRun],
        cursor: RenderCursor?
    ) {
        self.columns = columns
        self.rows = rows
        self.defaultBackground = defaultBackground
        self.backgroundRuns = backgroundRuns
        self.textRuns = textRuns
        self.decorationRuns = decorationRuns
        self.cursor = cursor
    }
}

/// Represents one maximal same-color background span in cell coordinates.
public struct RenderBackgroundRun: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column in the span.
    public let startColumn: Int

    /// Number of grid columns covered by the span.
    public let columnCount: Int

    /// Concrete background shared by every cell in the span.
    public let color: RenderColor

    init(row: Int, startColumn: Int, columnCount: Int, color: RenderColor) {
        self.row = row
        self.startColumn = startColumn
        self.columnCount = columnCount
        self.color = color
    }
}

/// Preserves a glyph cell's exact scalar payload and terminal-defined width so
/// font fallback cannot alter grid geometry during execution.
public struct RenderTextCell: Equatable, Sendable {
    /// Exact Unicode scalar sequence retained by TerminalCore.
    public let scalars: [Unicode.Scalar]

    /// Terminal grid width, either one for narrow cells or two for wide heads.
    public let columnWidth: Int

    init(scalars: [Unicode.Scalar], columnWidth: Int) {
        self.scalars = scalars
        self.columnWidth = columnWidth
    }
}

/// Represents one maximal row span sharing all foreground and font-affecting
/// inputs while retaining individual cell payloads for shaping.
public struct RenderTextRun: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based column occupied by the first text cell.
    public let startColumn: Int

    /// Exact cell payloads in display order.
    public let cells: [RenderTextCell]

    /// Concrete foreground shared by every cell in the run.
    public let foreground: RenderColor

    /// Selects the executor's bold font face without changing color.
    public let bold: Bool

    /// Selects the executor's italic font face.
    public let italic: Bool

    init(
        row: Int,
        startColumn: Int,
        cells: [RenderTextCell],
        foreground: RenderColor,
        bold: Bool,
        italic: Bool
    ) {
        self.row = row
        self.startColumn = startColumn
        self.cells = cells
        self.foreground = foreground
        self.bold = bold
        self.italic = italic
    }
}

/// Keeps underline shapes and strikethrough distinct so the executor performs
/// drawing work already selected by the pure planner.
public enum RenderDecorationKind: Equatable, Sendable {
    case underlineSingle
    case underlineDouble
    case underlineCurly
    case strikethrough
}

/// Represents one maximal same-kind, same-color decoration span in cell coordinates.
public struct RenderDecorationRun: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column in the span.
    public let startColumn: Int

    /// Number of grid columns covered by the span.
    public let columnCount: Int

    /// Decoration shape selected from semantic terminal attributes.
    public let kind: RenderDecorationKind

    /// Concrete post-reverse and post-dim decoration color.
    public let color: RenderColor

    init(
        row: Int,
        startColumn: Int,
        columnCount: Int,
        kind: RenderDecorationKind,
        color: RenderColor
    ) {
        self.row = row
        self.startColumn = startColumn
        self.columnCount = columnCount
        self.kind = kind
        self.color = color
    }
}

/// Records the terminal-defined filled-block span after wide-tail snapping so
/// execution never needs to inspect cell kinds.
public struct RenderCursor: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column after any wide-tail snap.
    public let column: Int

    /// Filled-block width in terminal columns.
    public let columnWidth: Int

    init(row: Int, column: Int, columnWidth: Int) {
        self.row = row
        self.column = column
        self.columnWidth = columnWidth
    }
}
