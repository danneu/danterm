// Read-only terminal inspection values that keep mutable grid storage private.

/// Identifies how a viewport column participates in terminal text geometry.
public enum TerminalCellKind: Equatable, Sendable {
    case padding
    case narrow
    case wideHead
    case wideTail
    case spacerHead
}

/// Exposes one cell's scalar-exact content without leaking the grid representation.
public struct TerminalCell: Equatable, Sendable {
    /// Describes whether the cell is content, padding, or part of a wide-cell invariant.
    public let kind: TerminalCellKind

    /// Preserves the exact decoded scalar sequence without normalization.
    public let scalars: [Unicode.Scalar]
}

/// Preserves an off-screen primary row's exact cells and logical continuation identity.
public struct TerminalScrollbackRow: Equatable, Sendable {
    /// Exact retained cells distinguish written spaces from never-written padding.
    public let cells: [TerminalCell]

    /// True when this visual row continues into the following retained or viewport row.
    public let isSoftWrapped: Bool
}

/// Describes a cursor position together with VT100 deferred-wrap state.
public struct TerminalCursor: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based viewport column.
    public let column: Int

    /// Records that the next positive-width print must soft-wrap first.
    public let isPendingWrap: Bool

    /// Creates an inspection value suitable for deterministic state assertions.
    public init(row: Int, column: Int, isPendingWrap: Bool) {
        self.row = row
        self.column = column
        self.isPendingWrap = isPendingWrap
    }
}

/// Captures one viewport row's cell classes and logical continuation identity.
public struct TerminalRowGeometry: Equatable, Sendable {
    /// Cell roles distinguish written content from padding and wide-cell structure.
    public let cells: [TerminalCellGeometry]

    /// True when this visual row continues into the following row without a hard break.
    public let isSoftWrapped: Bool
}

/// Separates written cells from padding while omitting scalar content from geometry equality.
public struct TerminalCellGeometry: Equatable, Sendable {
    /// Identifies content width and wide-cell structural roles at this column.
    public let kind: TerminalCellKind
}

/// Provides stable viewport geometry for tests and future rendering boundaries.
public struct TerminalGeometry: Equatable, Sendable {
    /// Fixed number of columns in every row.
    public let columns: Int

    /// Viewport rows in top-to-bottom order.
    public let rows: [TerminalRowGeometry]

    /// Current cursor and deferred-wrap state.
    public let cursor: TerminalCursor
}
