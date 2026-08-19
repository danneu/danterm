// One content box paired with the cell metrics its display scale resolves to.
//
// Building the metrics means building a CoreText font world -- five faces and their
// printable-ASCII glyph tables -- which is far too expensive to do per applied tape
// record. The metrics are a pure function of (display scale, font size), so this value
// exists to be resolved where those inputs move (a layout pass) and read everywhere
// else. Nothing here decides what grid is claimed beyond the native one this box holds;
// the fit for an oversized remote grid stays in `MobileObserveSurface`.
import CoreGraphics
import TerminalRenderExecution

/// A content box and the metrics resolved for it, which cannot disagree by construction.
///
/// The box is a cheap pixel description and stays one; pairing them here rather than
/// storing metrics inside the box keeps `MobileContentBox` trivially `Equatable`, which
/// is what lets a holder decide whether a re-resolve is needed at all.
public struct MobileCellMetrics: Equatable, Sendable {
    /// The region these metrics were resolved for. Reading it back from here rather than
    /// re-measuring the view is what keeps the claimed grid and the drawn pixels one
    /// reading of one extent.
    public let contentBox: MobileContentBox

    /// The metrics one cell is drawn with at the box's own display scale.
    public let metrics: TerminalRenderMetrics

    /// The size the metrics were resolved at, kept because a grid too wide to draw
    /// natively has to re-resolve the same font at a smaller scale.
    public let fontSize: CGFloat

    /// Returns nil when the metrics layer refuses the box's scale or the font size,
    /// which leaves the holder with no pairing and therefore no grid to answer for.
    public init?(contentBox: MobileContentBox, fontSize: CGFloat) {
        guard let metrics = TerminalRenderMetrics(
            displayScale: contentBox.displayScale,
            fontSize: fontSize
        ) else { return nil }
        self.contentBox = contentBox
        self.metrics = metrics
        self.fontSize = fontSize
    }

    /// The whole-cell grid this box shows at native cell metrics, which is the grid the
    /// claim gesture asks the pane to run at. Nil when the box has no room for a whole
    /// cell.
    public var nativeGrid: MobileSurfaceGrid? {
        MobileSurfaceGrid(
            widthPixels: contentBox.widthPixels,
            heightPixels: contentBox.heightPixels,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels
        )
    }
}
