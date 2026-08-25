// Read-only terminal inspection values that keep mutable grid storage private.

/// Identifies how a viewport column participates in terminal text geometry.
public enum TerminalCellKind: Equatable, Sendable {
    case padding
    case narrow
    case wideHead
    case wideTail
    case spacerHead
}

/// Names the three span rules in a coordinate-preserving viewport cell readout.
public enum TerminalViewportCellSpanKind: Equatable, Sendable {
    case narrow
    case wide
    case spacer
}

/// Compresses consecutive viewport graphemes that use the same terminal column-width rule.
public struct TerminalViewportCellSpan: Equatable, Sendable {
    /// Distinguishes one-column text, two-column text, and a wide-wrap spacer.
    public let kind: TerminalViewportCellSpanKind
    /// Zero-based viewport column where this span starts.
    public let column: Int
    /// Number of columns owned by each grapheme, or by each spacer entry.
    public let cellWidth: Int
    /// Exact decoded graphemes in order; absent for a spacer span.
    public let text: String?
    /// Zero-based UTF-8 byte offset of each grapheme in `text`; absent for a spacer span.
    public let utf8Offsets: [Int]?

    /// Creates one span whose text and offsets follow the selected width rule.
    public init(
        kind: TerminalViewportCellSpanKind,
        column: Int,
        cellWidth: Int,
        text: String?,
        utf8Offsets: [Int]?
    ) {
        self.kind = kind
        self.column = column
        self.cellWidth = cellWidth
        self.text = text
        self.utf8Offsets = utf8Offsets
    }
}

/// Carries the non-padding spans for one zero-based viewport row.
public struct TerminalViewportCellRow: Equatable, Sendable {
    /// Zero-based row in the current viewport.
    public let index: Int
    /// Ordered spans after leading and trailing padding are omitted.
    public let spans: [TerminalViewportCellSpan]

    /// Creates one row from its viewport-relative index and coordinate-bearing spans.
    public init(index: Int, spans: [TerminalViewportCellSpan]) {
        self.index = index
        self.spans = spans
    }
}

/// Reports the current viewport in terminal cell coordinates without exposing mutable grid state.
public struct TerminalViewportCells: Equatable, Sendable {
    /// Number of columns in every viewport row.
    public let columns: Int
    /// Number of rows in the current viewport.
    public let rowCount: Int
    /// The `pane rows` index matching viewport row zero in the same terminal state.
    public let paneRowsOrigin: Int
    /// Every viewport row in top-to-bottom order, including rows with no spans.
    public let rows: [TerminalViewportCellRow]

    /// Creates one coherent readout of a terminal viewport.
    public init(
        columns: Int,
        rowCount: Int,
        paneRowsOrigin: Int,
        rows: [TerminalViewportCellRow]
    ) {
        self.columns = columns
        self.rowCount = rowCount
        self.paneRowsOrigin = paneRowsOrigin
        self.rows = rows
    }
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

/// Reports one display row's line structure -- where its logical line ends and how far its
/// content reaches -- so a caller outside the engine can check wrap and reflow invariants.
///
/// Exists because a logical line holding more cells than its content needs renders correctly at
/// the width it was built for and garbled at every other width, so the defect only surfaces after
/// a resize and only as misplaced text. Text projections cannot distinguish it from legitimately
/// wrapped prose. The pair `(isSoftWrapped, contentEnd)` can: a real autowrap happens by printing
/// *at* the last column, so `isSoftWrapped` with `contentEnd < width` is unreachable by printing
/// and identifies a spurious wrap claim directly.
public struct TerminalRowStructure: Equatable, Sendable {
    /// Position in the whole stream, counting retained rows before live ones from zero.
    public let index: Int

    /// True when the row is a scrollback record rather than a live grid row, which is what
    /// separates a defect the printer introduced from one admission or reflow introduced.
    public let isRetained: Bool

    /// True when this row continues into the next one without a line break.
    public let isSoftWrapped: Bool

    /// One past the last column holding printed content, counting a wide glyph's tail. Zero on
    /// a row that has never been written, and never counts background-erase paint as content.
    public let contentEnd: Int

    /// Columns the row occupies, carried alongside `contentEnd` so the invariant reads without
    /// the caller having to source the pane width separately.
    public let width: Int

    /// The projected last-column kind. A wide glyph that cannot fit there leaves a stored blank
    /// and wraps early; while its wide head still follows, readers derive `.spacerHead` from
    /// those facts. Therefore `isSoftWrapped` with `contentEnd == width - 1` and a
    /// `.spacerHead` margin is a legitimate print outcome rather than a stale claim.
    public let marginCellKind: TerminalCellKind

    /// True while the row carries a wrap claim an erase left unwitnessed
    /// (`GridRow.marginProvenance`):
    /// the xterm-parity transient EL 1/2 create. Such a claim has no line-structure meaning --
    /// `isSoftWrapped` here already reports the gated value -- but the transient itself is what
    /// this projection exists to make visible. Always false on retained rows, whose wrap facts
    /// are derived from record structure rather than claimed.
    public let staleWrapClaim: Bool

    public init(
        index: Int,
        isRetained: Bool,
        isSoftWrapped: Bool,
        contentEnd: Int,
        width: Int,
        marginCellKind: TerminalCellKind,
        staleWrapClaim: Bool
    ) {
        self.index = index
        self.isRetained = isRetained
        self.isSoftWrapped = isSoftWrapped
        self.contentEnd = contentEnd
        self.width = width
        self.marginCellKind = marginCellKind
        self.staleWrapClaim = staleWrapClaim
    }
}

/// Reports how one retained row's per-cell content identities are laid out, without
/// exposing the identities themselves.
///
/// Exists for doc 28's `PR1`, which has to price preserving `contentIdentity` in a packed
/// retained row. The counter advances by one per printed cell, so a row printed
/// left-to-right holds an arithmetic sequence a per-run base encodes in a handful of bytes,
/// while a row assembled by cursor moves or overwrites fragments into many runs -- and the
/// two prices differ by enough to decide the representation. Counts rather than values,
/// because pricing needs the shape and nothing downstream may depend on an identity's
/// actual number.
public struct TerminalContentIdentityShape: Equatable, Sendable {
    /// Maximal spans of stored cells whose identities are contiguous in print order. Cells
    /// sharing one identity (a wide glyph's head and tail) stay inside a single run.
    public let runCount: Int

    /// Stored cells carrying an identity -- everything a run-based encoding must cover.
    public let identifiedCellCount: Int

    /// Stored cells carrying none: interior padding, wide tails of erased content, and cells
    /// made non-default by a background-erase style rather than by printing.
    public let unidentifiedCellCount: Int

    /// Maximal spans whose identities step by exactly one -- the runs the packed retained row
    /// really encodes.
    ///
    /// Distinct from `runCount`, and the difference is load-bearing rather than pedantic. A run
    /// entry is `(startColumn, extent, base)`, and the only value sequence that triple can
    /// reconstruct exactly is a strict arithmetic one, so a wide glyph -- whose head and tail
    /// share a single identity -- opens a new run in the encoder while `runCount` keeps them in
    /// one. `runCount` stays as `research/28/F12` defined and measured it; this is what the encoder
    /// charges, and what the probe's payload model must use to predict a row's packed size.
    public let strictRunCount: Int

    public init(
        runCount: Int,
        strictRunCount: Int,
        identifiedCellCount: Int,
        unidentifiedCellCount: Int
    ) {
        self.runCount = runCount
        self.strictRunCount = strictRunCount
        self.identifiedCellCount = identifiedCellCount
        self.unidentifiedCellCount = unidentifiedCellCount
    }
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

/// Describes a cursor position together with VT last-column state.
public struct TerminalCursor: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based viewport column.
    public let column: Int

    /// Records a margin write; a later positive-width print wraps first only when DECAWM is on.
    public let isPendingWrap: Bool

    /// Creates an inspection value suitable for deterministic state assertions.
    public init(row: Int, column: Int, isPendingWrap: Bool) {
        self.row = row
        self.column = column
        self.isPendingWrap = isPendingWrap
    }
}

/// Places the visible cursor on the leading cell of the grid span the renderer must draw.
public struct TerminalCursorPlacement: Equatable, Sendable {
    /// Zero-based viewport row.
    public let row: Int

    /// Zero-based leading column, including when the engine cursor occupies a wide tail.
    public let column: Int

    /// Number of grid columns covered by the cursor.
    public let columnWidth: Int
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
