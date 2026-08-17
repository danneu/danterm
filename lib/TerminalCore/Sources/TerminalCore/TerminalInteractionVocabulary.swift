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

    /// Creates a normalized cell value for cross-layer input forwarding.
    public init(column: Int, row: Int, offsetX: Double = 0) {
        self.column = column
        self.row = row
        self.offsetX = offsetX
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
/// the right edge as the last column's trailing edge.
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
    return TerminalViewportCell(
        column: clampedColumn,
        row: min(max(Int(row), 0), rows - 1),
        offsetX: offsetX
    )
}

/// One platform-neutral pointer transition delivered to serialized interaction policy.
///
/// `offsetX` is the pointer's `0...1` position inside its own cell, carried only on the two
/// transitions that resolve a character boundary; release re-resolves nothing.
public enum TerminalPointerEvent: Equatable, Sendable {
    case down(
        TerminalMouseButton,
        column: Int,
        row: Int,
        offsetX: Double = 0,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    )
    case up(
        TerminalMouseButton,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    )
    case move(column: Int, row: Int, offsetX: Double = 0, modifiers: TerminalKeyModifiers = [])
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

/// Carries fractional vertical wheel motion and the metadata that determines its action.
public struct TerminalWheelEvent: Equatable, Sendable {
    /// Signed rows, where negative motion navigates toward retained history.
    public let rowDelta: Double
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
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        phase: TerminalWheelPhase = .standalone
    ) {
        self.rowDelta = rowDelta
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.phase = phase
    }
}
