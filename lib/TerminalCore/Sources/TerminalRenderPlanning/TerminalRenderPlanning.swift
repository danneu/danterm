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

    /// Background overlay used to distinguish the current local selection.
    public let selectionBackground: RenderColor

    /// Background overlay for the active find match. Deliberately unlike
    /// `selectionBackground`: the two can cover the same cells, and the whole point of
    /// the match highlight is to be findable among selected text.
    public let searchMatchBackground: RenderColor

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
        selectionBackground: RenderColor(red: 56, green: 88, blue: 140),
        searchMatchBackground: RenderColor(red: 175, green: 128, blue: 20),
        cursor: RenderColor(red: 229, green: 229, blue: 229),
        cursorText: RenderColor(red: 0, green: 0, blue: 0)
    )

    private init(
        ansiColors: [RenderColor],
        defaultForeground: RenderColor,
        defaultBackground: RenderColor,
        selectionBackground: RenderColor,
        searchMatchBackground: RenderColor,
        cursor: RenderColor,
        cursorText: RenderColor
    ) {
        self.ansiColors = ansiColors
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.selectionBackground = selectionBackground
        self.searchMatchBackground = searchMatchBackground
        self.cursor = cursor
        self.cursorText = cursorText
    }
}

/// Bundles every presentation choice that may affect planning so repeated
/// calls never consult focus state, preferences, or another ambient source.
public struct RenderPresentation: Equatable, Sendable {
    /// Palette and cursor colors used to resolve semantic terminal cells.
    public let theme: RenderTheme

    /// Controls whether planning emits and applies the requested cursor.
    public let isCursorVisible: Bool

    /// Selects the terminal-requested cursor geometry for this frame.
    public let cursorShape: TerminalCursorShape

    /// Requires callers to make every cursor presentation input explicit.
    public init(
        theme: RenderTheme,
        isCursorVisible: Bool,
        cursorShape: TerminalCursorShape
    ) {
        self.theme = theme
        self.isCursorVisible = isCursorVisible
        self.cursorShape = cursorShape
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

    /// Concrete color used for every local-selection overlay span.
    public let selectionBackground: RenderColor

    /// Concrete color used for the active find match's overlay spans.
    public let searchMatchBackground: RenderColor

    /// Non-default background spans in canonical row-major order.
    public let backgroundRuns: [RenderBackgroundRun]

    /// Local-selection overlay spans in canonical row-major order.
    public let selectionRuns: [RenderSelectionRun]

    /// Active-find-match overlay spans in canonical row-major order. Drawn after
    /// `selectionRuns`, so an overlap reads as the match.
    public let searchMatchRuns: [RenderSelectionRun]

    /// Glyph-bearing spans in canonical row-major order.
    public let textRuns: [RenderTextRun]

    /// Underline and strikethrough spans in canonical row-major order.
    public let decorationRuns: [RenderDecorationRun]

    /// Geometry and color metadata for the cursor requested by this frame.
    public let cursor: RenderCursor?

    init(
        columns: Int,
        rows: Int,
        defaultBackground: RenderColor,
        selectionBackground: RenderColor,
        searchMatchBackground: RenderColor,
        backgroundRuns: [RenderBackgroundRun],
        selectionRuns: [RenderSelectionRun],
        searchMatchRuns: [RenderSelectionRun],
        textRuns: [RenderTextRun],
        decorationRuns: [RenderDecorationRun],
        cursor: RenderCursor?
    ) {
        self.columns = columns
        self.rows = rows
        self.defaultBackground = defaultBackground
        self.selectionBackground = selectionBackground
        self.searchMatchBackground = searchMatchBackground
        self.backgroundRuns = backgroundRuns
        self.selectionRuns = selectionRuns
        self.searchMatchRuns = searchMatchRuns
        self.textRuns = textRuns
        self.decorationRuns = decorationRuns
        self.cursor = cursor
    }
}

/// Represents one viewport-row segment covered by the local selection overlay.
public struct RenderSelectionRun: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column in the selected segment.
    public let startColumn: Int

    /// Number of selected grid columns in the segment.
    public let columnCount: Int

    init(row: Int, startColumn: Int, columnCount: Int) {
        self.row = row
        self.startColumn = startColumn
        self.columnCount = columnCount
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
    public let scalars: TerminalScalars

    /// Terminal grid width, either one for narrow cells or two for wide heads.
    public let columnWidth: Int

    init(scalars: TerminalScalars, columnWidth: Int) {
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
    case underlineDotted
    case underlineDashed
    case strikethrough
}

/// Represents one maximal same-decoration-set, same-color span without making
/// simultaneous underline and strikethrough work overlap in the canonical plan.
public struct RenderDecorationRun: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column in the span.
    public let startColumn: Int

    /// Number of grid columns covered by the span.
    public let columnCount: Int

    /// Ordered decoration kinds selected from semantic terminal attributes.
    public let kinds: [RenderDecorationKind]

    /// Resolved underline color, or the effective foreground when no underline exists.
    public let color: RenderColor

    /// Foreground-derived color used only when strikethrough shares the run.
    public let strikethroughColor: RenderColor

    init(
        row: Int,
        startColumn: Int,
        columnCount: Int,
        kinds: [RenderDecorationKind],
        color: RenderColor,
        strikethroughColor: RenderColor? = nil
    ) {
        self.row = row
        self.startColumn = startColumn
        self.columnCount = columnCount
        self.kinds = kinds
        self.color = color
        self.strikethroughColor = strikethroughColor ?? color
    }
}

/// Records the terminal-defined cursor after wide-tail snapping so execution
/// can overlay non-block shapes without inspecting terminal state or cell kinds.
public struct RenderCursor: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column after any wide-tail snap.
    public let column: Int

    /// Cursor width in terminal columns.
    public let columnWidth: Int

    /// Terminal-requested cursor geometry.
    public let shape: TerminalCursorShape

    /// Concrete color used by both baked block cursors and cursor overlays.
    public let color: RenderColor

    init(
        row: Int,
        column: Int,
        columnWidth: Int,
        shape: TerminalCursorShape,
        color: RenderColor
    ) {
        self.row = row
        self.column = column
        self.columnWidth = columnWidth
        self.shape = shape
        self.color = color
    }
}
