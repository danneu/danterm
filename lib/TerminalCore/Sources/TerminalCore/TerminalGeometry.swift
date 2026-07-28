// Read-only terminal inspection values that keep mutable grid storage private.

/// Identifies how a viewport column participates in terminal text geometry.
public enum TerminalCellKind: Equatable, Sendable {
    case padding
    case narrow
    case wideHead
    case wideTail
    case spacerHead
}

/// Carries terminal-authored link metadata without granting it activation authority.
public struct TerminalHyperlink: Equatable, Sendable {
    /// Preserves the OSC 8 URI exactly as received after strict UTF-8 decoding.
    public let uri: String

    /// Preserves the optional OSC 8 `id` parameter used to join logical link regions.
    public let explicitId: String?

    /// Creates an inspection value shared by explicit cells and detected links.
    public init(uri: String, explicitId: String? = nil) {
        self.uri = uri
        self.explicitId = explicitId
    }
}

/// Couples a validated HTTP(S) target to the exact text run eligible for activation.
public struct TerminalResolvedLink: Equatable, Sendable {
    /// The validated target exposed to interaction policy and the AppKit boundary.
    public let hyperlink: TerminalHyperlink

    /// The contiguous explicit or detected run that must still match on pointer release.
    public let range: TerminalTextRange

    /// Distinguishes a live run from identical text recreated after pointer down.
    let activationIdentity: Int

    /// Creates a resolved value for clients that do not participate in private run identity.
    public init(hyperlink: TerminalHyperlink, range: TerminalTextRange) {
        self.hyperlink = hyperlink
        self.range = range
        activationIdentity = 0
    }

    /// Couples engine resolution to an opaque identity used only by interaction policy.
    init(hyperlink: TerminalHyperlink, range: TerminalTextRange, activationIdentity: Int) {
        self.hyperlink = hyperlink
        self.range = range
        self.activationIdentity = activationIdentity
    }

    /// Adds opaque cell generation to the public value comparison for safe activation only.
    func matchesActivation(_ other: Self) -> Bool {
        self == other && activationIdentity == other.activationIdentity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hyperlink == rhs.hyperlink && lhs.range == rhs.range
    }
}

/// Exposes one cell's scalar-exact content without leaking the grid representation.
public struct TerminalCell: Equatable, Sendable {
    /// Describes whether the cell is content, padding, or part of a wide-cell invariant.
    public let kind: TerminalCellKind

    /// Preserves the exact decoded scalar sequence without normalization.
    public let scalars: TerminalScalars

    /// Retains semantic presentation for written content or background-color erase padding.
    public let style: TerminalStyle

    /// Exposes retained OSC 8 metadata while leaving activation policy to `Terminal`.
    public let hyperlink: TerminalHyperlink?

    /// Creates a read-only inspection cell while keeping hyperlink absence source-compatible.
    public init(
        kind: TerminalCellKind,
        scalars: TerminalScalars,
        style: TerminalStyle,
        hyperlink: TerminalHyperlink? = nil
    ) {
        self.kind = kind
        self.scalars = scalars
        self.style = style
        self.hyperlink = hyperlink
    }
}

/// Preserves an off-screen primary row's exact cells and logical continuation identity.
public struct TerminalScrollbackRow: Equatable, Sendable {
    /// Exact retained cells distinguish written spaces from never-written padding.
    public let cells: [TerminalCell]

    /// True when this visual row continues into the following retained or viewport row.
    public let isSoftWrapped: Bool
}

/// Describes the local visual-row window without exposing the anchor used to preserve it.
public struct TerminalScrollProjection: Equatable, Sendable {
    /// Number of currently reflowed rows in the active screen's stream.
    public let totalRows: Int

    /// Zero-based current-stream row displayed at the top of the window.
    public let topRow: Int

    /// Number of visual rows displayed by the window.
    public let windowRows: Int

    /// True when output and reflow should keep the live grid at the bottom of the window.
    public let isFollowing: Bool

    /// Creates a value suitable for scrollbar state and deterministic assertions.
    public init(totalRows: Int, topRow: Int, windowRows: Int, isFollowing: Bool) {
        self.totalRows = totalRows
        self.topRow = topRow
        self.windowRows = windowRows
        self.isFollowing = isFollowing
    }
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
    /// Current number of columns in every row.
    public let columns: Int

    /// Viewport rows in top-to-bottom order.
    public let rows: [TerminalRowGeometry]

    /// Current cursor when its live-grid row intersects the selected window.
    public let cursor: TerminalCursor?
}
