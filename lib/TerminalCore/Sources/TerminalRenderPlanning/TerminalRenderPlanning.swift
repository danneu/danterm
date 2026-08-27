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

    fileprivate init(_ color: TerminalRGBColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

/// Wraps the fixed ANSI palette so `RenderTheme` keeps its synthesized
/// `Equatable`: `InlineArray` carries no `Equatable` conformance, so without
/// this wrapper every theme field would have to be compared by hand.
public struct RenderANSIColors: Sendable {
    private let storage: InlineArray<16, RenderColor>

    /// Admits only a complete ANSI palette, after which the arity is the storage type's.
    public init?(exactly colors: [RenderColor]) {
        guard colors.count == 16 else { return nil }
        storage = InlineArray<16, RenderColor> { colors[$0] }
    }

    /// Resolves a validated ANSI index without exposing variable-length storage.
    public subscript(index: Int) -> RenderColor {
        storage[index]
    }
}

extension RenderANSIColors: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        for index in lhs.storage.indices where lhs.storage[index] != rhs.storage[index] {
            return false
        }
        return true
    }
}

/// Fixes every palette and presentation input needed to turn semantic terminal
/// colors into a deterministic frame.
public struct RenderTheme: Equatable, Sendable {
    /// The fixed 16-color ANSI palette used for indices 0 through 15.
    public let ansiColors: RenderANSIColors

    /// Foreground used when a terminal cell retains semantic `.default`.
    public let defaultForeground: RenderColor

    /// Background used both for semantic `.default` and the frame clear.
    public let defaultBackground: RenderColor

    /// Background overlay used to distinguish the current local selection.
    public let selectionBackground: RenderColor

    /// Foreground forced onto selected text before cursor presentation is applied.
    public let selectionForeground: RenderColor

    /// Filled-block cursor color applied before run coalescing.
    public let cursor: RenderColor

    /// Foreground used for visible content beneath the filled-block cursor.
    public let cursorText: RenderColor

    /// Baked fallback for panes without a resolved per-pane theme.
    public static let dark = RenderTheme(
        ansiColors: RenderANSIColors(exactly: [
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
        ])!,
        defaultForeground: RenderColor(TerminalDefaultColors.baked.foreground),
        defaultBackground: RenderColor(TerminalDefaultColors.baked.background),
        selectionForeground: RenderColor(TerminalDefaultColors.baked.foreground),
        selectionBackground: RenderColor(red: 56, green: 88, blue: 140),
        cursor: RenderColor(red: 229, green: 229, blue: 229),
        cursorText: RenderColor(red: 0, green: 0, blue: 0)
    )

    /// Creates a complete renderer theme from the colors a caller chooses.
    public init(
        ansiColors: RenderANSIColors,
        defaultForeground: RenderColor,
        defaultBackground: RenderColor,
        selectionForeground: RenderColor,
        selectionBackground: RenderColor,
        cursor: RenderColor,
        cursorText: RenderColor
    ) {
        self.ansiColors = ansiColors
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.selectionForeground = selectionForeground
        self.selectionBackground = selectionBackground
        self.cursor = cursor
        self.cursorText = cursorText
    }
}

public extension RenderTheme {
    /// Projects renderer defaults back into the neutral pair used by terminal queries.
    var defaultColors: TerminalDefaultColors {
        TerminalDefaultColors(
            foreground: TerminalRGBColor(
                red: defaultForeground.red,
                green: defaultForeground.green,
                blue: defaultForeground.blue
            ),
            background: TerminalRGBColor(
                red: defaultBackground.red,
                green: defaultBackground.green,
                blue: defaultBackground.blue
            )
        )
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

/// Records the metrics-free drawing facts that determine one row's vertical
/// pixel reach when the executor later supplies its measured envelope.
public struct RenderRowInkClass: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Printable-ASCII single-scalar text submitted from measured glyph tables.
    public static let asciiText = RenderRowInkClass(rawValue: 1 << 0)

    /// Other single-scalar text submitted from the wider, unmeasured cmap.
    public static let generalText = RenderRowInkClass(rawValue: 1 << 1)

    /// Content clipped to or exactly contained by the row's cell band.
    public static let band = RenderRowInkClass(rawValue: 1 << 2)
}

/// Owns every drawing run and its metrics-free ink class for one viewport row
/// so publication and reuse share the same damage-sized unit (research/33 D9).
public struct RenderPlanRow: Equatable, Sendable {
    /// Non-default background spans in canonical within-row order.
    public let backgroundRuns: [RenderBackgroundRun]

    /// Selection and active-find overlays in canonical within-row order.
    public let overlayRuns: [RenderOverlayRun]

    /// Glyph-bearing spans in canonical within-row order.
    public let textRuns: [RenderTextRun]

    /// Underline and strikethrough spans in canonical within-row order.
    public let decorationRuns: [RenderDecorationRun]

    /// Facts derived with the runs that map to pixel reach at execution time.
    public let inkClass: RenderRowInkClass

    init(
        backgroundRuns: [RenderBackgroundRun],
        overlayRuns: [RenderOverlayRun],
        textRuns: [RenderTextRun],
        decorationRuns: [RenderDecorationRun],
        inkClass: RenderRowInkClass
    ) {
        self.backgroundRuns = backgroundRuns
        self.overlayRuns = overlayRuns
        self.textRuns = textRuns
        self.decorationRuns = decorationRuns
        self.inkClass = inkClass
    }
}

/// Isolates each executor pass so a complete frame can be replayed without
/// consulting terminal state or carrying state between frames.
public struct RenderFramePlan: Equatable, Sendable {
    /// Viewport width in terminal grid columns.
    public let columns: Int

    /// Viewport rows in canonical top-to-bottom order.
    public let rows: [RenderPlanRow]

    /// Viewport height derived from the only row storage.
    public var rowCount: Int { rows.count }

    /// Concrete color used to clear the full viewport before drawing runs.
    public let defaultBackground: RenderColor

    /// Geometry and color metadata for the cursor requested by this frame.
    public let cursor: RenderCursor?

    init(
        columns: Int,
        defaultBackground: RenderColor,
        rows: [RenderPlanRow],
        cursor: RenderCursor?
    ) {
        self.columns = columns
        self.defaultBackground = defaultBackground
        self.rows = rows
        self.cursor = cursor
    }
}

/// Identifies the semantic coverage represented by one overlay fragment.
public enum RenderOverlayState: Equatable, Sendable {
    /// Local selection without a search match.
    case selection

    /// A visible search match that is not the current navigation target.
    case searchMatch

    /// The current search navigation target outside the local selection.
    case activeSearchMatch

    /// A cell covered by both the local selection and a non-current search match.
    case selectionAndSearchMatch

    /// A cell covered by both the local selection and the current search target.
    case selectionAndActiveSearchMatch
}

/// Represents one maximal same-state, same-color overlay fragment.
public struct RenderOverlayRun: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based first column in the selected segment.
    public let startColumn: Int

    /// Number of overlaid grid columns in the fragment.
    public let columnCount: Int

    /// Selection and search coverage carried independently of paint policy.
    public let state: RenderOverlayState

    /// Concrete fill shared by every cell in the fragment.
    public let color: RenderColor

    init(
        row: Int,
        startColumn: Int,
        columnCount: Int,
        state: RenderOverlayState,
        color: RenderColor
    ) {
        self.row = row
        self.startColumn = startColumn
        self.columnCount = columnCount
        self.state = state
        self.color = color
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
