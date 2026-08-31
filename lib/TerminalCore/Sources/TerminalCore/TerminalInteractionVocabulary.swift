// The values a view speaks when it hands pointer and wheel input to interaction policy,
// plus the one pure function that produces them. Everything here is import-free and depends
// on nothing but the input-encoding vocabulary, which is what lets a host that cannot build
// the live `Terminal` -- the UI harness -- still compile the real declarations.
//
// The decisions made from these values live in `TerminalInteractionPolicy.swift`: anything
// that reads a `Terminal`, a `TerminalTextRange`, or a `TerminalResolvedLink` belongs there,
// not here.

/// Identifies a valid zero-based cell in the displayed terminal viewport, together with the
/// sub-cell horizontal position that flooring to a column would otherwise destroy. Character
/// selection resolves a boundary from it; every other arm reads only the column and row.
public struct TerminalViewportCell: Equatable, Sendable {
    /// Horizontal grid coordinate.
    public let column: Int
    /// Vertical grid coordinate.
    public let row: Int
    /// Horizontal position inside the cell, as a `0...1` fraction of its width. Clamped with
    /// the column as one value, so an off-grid point reads as the edge it left through.
    public let offsetX: Double
    /// Whether the point this cell was normalized from actually fell inside the grid. The
    /// column and row above are clamped, so they cannot say it; a caller that needs to know
    /// -- link interaction arms nothing under an off-grid pointer -- reads it here instead of
    /// re-deriving the grid extents with its own math. The default is `true` so a cell built
    /// from coordinates alone, such as one decoded from a recording made before insideness
    /// was carried, reads as measured inside.
    public let isInsideGrid: Bool

    /// Creates a normalized cell value for cross-layer input forwarding.
    public init(column: Int, row: Int, offsetX: Double = 0, isInsideGrid: Bool = true) {
        self.column = column
        self.row = row
        self.offsetX = offsetX
        self.isInsideGrid = isInsideGrid
    }
}

/// Keeps point-space coordinates explicit without importing CoreGraphics into TerminalCore.
public struct TerminalPoint: Equatable, Sendable {
    /// Horizontal point coordinate in a flipped terminal view.
    public let x: Double
    /// Vertical point coordinate in a flipped terminal view.
    public let y: Double

    /// Creates unchecked geometry that `terminalCell` validates as one unit.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Keeps point-space cell dimensions independent from platform geometry types.
public struct TerminalCellSize: Equatable, Sendable {
    /// Horizontal cell extent in points.
    public let width: Double
    /// Vertical cell extent in points.
    public let height: Double

    /// Creates unchecked geometry that `terminalCell` validates as one unit.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Floors a flipped-view point into the grid and clamps it to a valid viewport cell, keeping
/// the horizontal remainder. Clamping moves the remainder with the column rather than
/// independently, so a point off the left edge reads as that column's leading edge and one off
/// the right edge as the last column's trailing edge. The result also reports whether the
/// point was on the grid at all, so a caller never has to re-derive the extents to find out.
public func terminalCell(
    at point: TerminalPoint,
    cellSize: TerminalCellSize,
    columns: Int,
    rows: Int
) -> TerminalViewportCell? {
    guard point.x.isFinite, point.y.isFinite,
          cellSize.width.isFinite, cellSize.height.isFinite,
          cellSize.width > 0, cellSize.height > 0,
          columns > 0, rows > 0
    else { return nil }

    let scaledColumn = point.x / cellSize.width
    let column = scaledColumn.rounded(.down)
    let row = (point.y / cellSize.height).rounded(.down)
    guard column.isFinite, row.isFinite,
          column > Double(Int.min), column < Double(Int.max),
          row > Double(Int.min), row < Double(Int.max)
    else { return nil }
    let clampedColumn = min(max(Int(column), 0), columns - 1)
    let offsetX: Double = if Int(column) < clampedColumn {
        0
    } else if Int(column) > clampedColumn {
        1
    } else {
        min(max(scaledColumn - column, 0), 1)
    }
    // Insideness is the range test on the raw point, not a read-back of the clamp above:
    // the clamp compares a floored quotient, which can disagree with the range by one ULP
    // at an edge. The right and bottom extents are exclusive, so the first point past the
    // last cell is already outside.
    let isInsideGrid = point.x >= 0 && point.x < Double(columns) * cellSize.width
        && point.y >= 0 && point.y < Double(rows) * cellSize.height
    return TerminalViewportCell(
        column: clampedColumn,
        row: min(max(Int(row), 0), rows - 1),
        offsetX: offsetX,
        isInsideGrid: isInsideGrid
    )
}

/// One platform-neutral pointer transition delivered to serialized interaction policy.
///
/// All three cases carry the normalized cell whole, release included, even though release
/// re-resolves no character boundary and so reads no `offsetX`. One shape for every case is
/// what keeps the clamped coordinates and the measured insideness they were clamped from
/// travelling together: a case that carried loose scalars would drop insideness at the event
/// boundary and force the receiver to be told about it a second time.
public enum TerminalPointerEvent: Equatable, Sendable {
    case down(
        TerminalMouseButton,
        cell: TerminalViewportCell,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    )
    case up(
        TerminalMouseButton,
        cell: TerminalViewportCell,
        modifiers: TerminalKeyModifiers = []
    )
    case move(cell: TerminalViewportCell, modifiers: TerminalKeyModifiers = [])

    /// The pointed cell, for callers that route or measure an event without matching its case.
    public var cell: TerminalViewportCell {
        switch self {
        case let .down(_, cell, _, _): cell
        case let .up(_, cell, _): cell
        case let .move(cell, _): cell
        }
    }
}

/// Marks normalized wheel lifecycle so direct scrolling and momentum share one route.
public enum TerminalWheelPhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case momentumBegan
    case momentumChanged
    case momentumEnded
    case standalone
}

/// Carries fractional wheel motion and the metadata that determines its action.
public struct TerminalWheelEvent: Equatable, Sendable {
    /// Signed rows, where negative motion navigates toward retained history.
    public let rowDelta: Double
    /// Signed columns, where negative motion reports left and positive reports right.
    public let columnDelta: Double
    /// Zero-based pointed viewport column.
    public let column: Int
    /// Zero-based pointed viewport row.
    public let row: Int
    /// Modifier snapshot used at gesture routing and report encoding time.
    public let modifiers: TerminalKeyModifiers
    /// Normalized direct or momentum lifecycle boundary.
    public let phase: TerminalWheelPhase

    /// Creates one normalized wheel sample; phase-less ticks are standalone gestures.
    public init(
        rowDelta: Double,
        columnDelta: Double,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        phase: TerminalWheelPhase = .standalone
    ) {
        self.rowDelta = rowDelta
        self.columnDelta = columnDelta
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.phase = phase
    }

    /// Creates a vertical-only sample for producers that have no horizontal surface.
    public init(
        rowDelta: Double,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        phase: TerminalWheelPhase = .standalone
    ) {
        self.init(
            rowDelta: rowDelta,
            columnDelta: 0,
            column: column,
            row: row,
            modifiers: modifiers,
            phase: phase
        )
    }
}
