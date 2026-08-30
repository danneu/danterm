// The shaped-cluster cache and the value it holds: what one typesetting of a fallback
// cluster produced, kept so the draw pays for the typesetting once per (face, cluster)
// instead of once per cell per frame.
//
// Only the executor's fallback path reads or fills this. The mapped-glyph fast path never
// reaches it, and nothing here knows about colour or grid position: colour is the batch's
// fill, and a cell's position is added to the cached positions at submission, so one entry
// serves the cluster wherever and in whatever colour it appears.
//
// The extraction that fills an entry lives with the draw in TerminalRenderExecution; this
// file holds the storage and the shape of what is stored.
import CoreGraphics
import CoreText
import TerminalCore

/// One run of a typeset cluster: the font CoreText's cascade chose for it, the glyphs it
/// resolved, and where they sit.
///
/// A cluster is kept as its runs rather than as one glyph array because run order and a
/// run's own font both change pixels, and neither survives being flattened.
struct ShapedClusterRun {
    /// The concrete face the cascade picked, which is usually not the base face -- that is
    /// why the cluster reached the fallback path at all.
    let font: CTFont

    let glyphs: [CGGlyph]

    /// Glyph positions in CoreText's text space, measured from the line origin. A draw adds
    /// the cell's glyph origin and submits them unchanged, so they stay independent of
    /// where the cluster is shown.
    let positions: [CGPoint]

    /// True when CoreText marked this run `kCTRunStatusHasNonIdentityMatrix`, which is a
    /// property of the base face rather than of the cluster: the cascade hands the fallback
    /// font the base font's matrix. Such a run is replayed on its own instead of joining a
    /// batch, because a batch has one text matrix for every glyph in it.
    let hasNonIdentityMatrix: Bool

    /// `CTRunGetTextMatrix`'s linear part, translation dropped, for a run that carries one.
    /// The replay composes it onto the cell's own matrix and keeps the cell's translation.
    let textMatrix: CGAffineTransform

    /// The run face's `CGFont`, for the matrix replay only.
    ///
    /// A matrix run is submitted through `setFont`/`showGlyphs` rather than
    /// `CTFontDrawGlyphs`, because that wrapper applies the face's matrix itself and the
    /// matrix has to be in the text matrix to reproduce what `CTLineDraw` renders. Copied
    /// once at extraction so the replay costs no CoreText call.
    let graphicsFont: CGFont?
}

/// What one typesetting of one cluster produced, in a form the draw can submit without
/// creating a `CTLine` again.
struct ShapedCluster {
    /// The line's runs in line order. Empty runs are dropped at extraction, so a stored
    /// cluster with no runs is one that draws nothing.
    let runs: [ShapedClusterRun]

    /// The line's image bounds in text space -- x from the line origin, y up from the
    /// baseline -- so containment can be judged against whatever cell span the cluster is
    /// asked to fill rather than the one it was first shaped for.
    let inkBounds: CGRect

    /// True when the cluster's ink stays inside a cell span of this width, so submitting it
    /// without a clip cannot touch the cells beside it.
    func isContained(inCellOfWidth width: CGFloat, metrics: TerminalRenderMetrics) -> Bool {
        guard inkBounds.isNull == false else { return true }
        let above = metrics.baselineOffset
        let below = metrics.cellSize.height - metrics.baselineOffset
        return inkBounds.minX >= 0
            && inkBounds.maxX <= width
            && inkBounds.maxY <= above
            && inkBounds.minY >= -below
    }

    /// True when the cluster can join a batch of glyphs submitted under one font, one
    /// colour and one text matrix: its ink is contained, it has exactly one run, and that
    /// run needs no matrix of its own. Everything else is replayed inside its own clip.
    func isOrdinary(inCellOfWidth width: CGFloat, metrics: TerminalRenderMetrics) -> Bool {
        runs.count == 1
            && runs[0].hasNonIdentityMatrix == false
            && isContained(inCellOfWidth: width, metrics: metrics)
    }
}

/// Holds one typesetting per (face, cluster) for the life of a font set, so a fallback cell
/// costs a dictionary lookup and a glyph submission on every frame after its first.
///
/// Reference-typed and owned for exactly its lifetime by whatever owns the draw -- the
/// swapchain in the app, the harness in a benchmark, the test in a test -- and handed to
/// `drawRenderFrame`. It is deliberately not stored inside any `Sendable` render value and
/// is never global: entries are only valid for the font set they were shaped under, and a
/// process-wide cache would outlive it. `prepare(for:)` enforces that anyway, so an owner
/// that keeps a cache across a metrics change gets a correct frame rather than glyphs from
/// the old font set.
///
/// Main-thread only, like the draw it serves.
public final class ShapedClusterCache {
    /// Above one full 179x66 frame of distinct clusters (11,814) with headroom, so a single
    /// screen of unique content never evicts. Past the cap a cluster returns to per-cell
    /// typesetting on its next miss, which research/40 `AR1` accepts.
    public static let defaultCapacity = 16_384

    /// The face a cluster was shaped under. There are only four -- the styled faces of one
    /// font set -- and which one a fallback cell uses is fully determined by its run's
    /// emphasis, so the two bits stand in for the face identity. The font set itself is
    /// pinned by `metrics`.
    private struct Key: Hashable {
        let bold: Bool
        let italic: Bool
        let scalars: TerminalScalars
    }

    private let capacity: Int
    private var metrics: TerminalRenderMetrics
    private var entries: [Key: ShapedCluster] = [:]

    /// How many lookups had to typeset. A steady-state frame over cached clusters adds
    /// none, which is what research/40 `I6` claims.
    public private(set) var missCount = 0

    /// How many clusters are stored, never above the cap.
    public var entryCount: Int { entries.count }

    public init(metrics: TerminalRenderMetrics, capacity: Int = ShapedClusterCache.defaultCapacity) {
        precondition(capacity > 0, "a shaped-cluster cache needs room for one cluster")
        self.metrics = metrics
        self.capacity = capacity
    }

    /// Drops every entry shaped under a different font set. Called once per draw, so a
    /// cache cannot serve a frame the glyphs in it were not shaped for.
    func prepare(for metrics: TerminalRenderMetrics) {
        guard self.metrics != metrics else { return }
        self.metrics = metrics
        entries.removeAll(keepingCapacity: true)
    }

    /// The cluster's stored shaping, typesetting it through `shape` on a miss.
    ///
    /// The miss path stores the result and returns it rather than drawing the line it built,
    /// so a cell drawn on a miss and the same cell drawn on a hit submit the same glyphs.
    func cluster(
        scalars: TerminalScalars,
        bold: Bool,
        italic: Bool,
        shapedBy shape: () -> ShapedCluster?
    ) -> ShapedCluster? {
        let key = Key(bold: bold, italic: italic, scalars: scalars)
        if let stored = entries[key] { return stored }
        missCount += 1
        guard let shaped = shape() else { return nil }
        // Clearing at the cap rather than evicting one entry keeps the bound unfailable
        // without an ordering structure on the hot path. The cap sits above a full frame of
        // distinct clusters, so reaching it means a working set no real stream produces.
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = shaped
        return shaped
    }
}
