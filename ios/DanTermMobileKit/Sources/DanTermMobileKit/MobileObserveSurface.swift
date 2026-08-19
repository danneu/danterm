// The pixels the phone draws one pane's grid into.
//
// The phone shows whatever grid the Mac runs the pane at, which is routinely far wider
// than a handset can draw at native cell metrics. This value answers the whole question
// that raises -- what metrics that grid is drawn with, and how many pixels the frame
// stores therefore occupy -- so the shell reads its own extent and allocates what it is
// told. Nothing here decides what the phone claims; `MobileSurfaceGrid` owns that.
import CoreGraphics
import TerminalRenderExecution

/// The render metrics and pixel extent one grid resolves to inside one phone view.
///
/// The shrink happens while drawing rather than afterwards: the scale the cell box is
/// quantized at decides the frame store's pixel extent, so a grid too large for the
/// view is allocated small and shown whole. Scaling a natively sized surface with a
/// layer transform would look the same and would let one remote resize allocate every
/// pixel that grid implies.
public struct MobileObserveSurface: Equatable, Sendable {
    /// The metrics every frame store and every draw of this grid uses.
    public let metrics: TerminalRenderMetrics

    /// The backing pixels one frame store for this grid occupies.
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Returns nil when the view cannot draw this grid at all -- no room for a whole
    /// pixel per cell, or a font size the metrics layer refuses -- which leaves the
    /// caller with the surfaces it already has.
    ///
    /// The extent comes from the content box rather than from the caller's own reading
    /// of the view, so the pixels drawn and the grid claimed cannot describe different
    /// regions of it.
    public init?(columns: Int, rows: Int, contentBox: MobileContentBox, fontSize: CGFloat) {
        let displayScale = contentBox.displayScale
        guard columns > 0, rows > 0,
              let native = TerminalRenderMetrics(displayScale: displayScale, fontSize: fontSize),
              let scale = fittedRenderScale(
                  columns: columns,
                  rows: rows,
                  widthPixels: contentBox.widthPixels,
                  heightPixels: contentBox.heightPixels,
                  nativeCellSize: native.cellSize,
                  nativeDisplayScale: displayScale
              )
        else { return nil }
        if scale >= displayScale {
            metrics = native
        } else if let fitted = TerminalRenderMetrics(displayScale: scale, fontSize: fontSize) {
            metrics = fitted
        } else {
            return nil
        }
        pixelWidth = metrics.cellWidthPixels * columns
        pixelHeight = metrics.cellHeightPixels * rows
    }

    /// The grid this surface holds, recovered from the pixels rather than stored: the
    /// extent is an exact whole number of cells by construction, so the two readings
    /// cannot disagree.
    public var columns: Int { pixelWidth / metrics.cellWidthPixels }
    public var rows: Int { pixelHeight / metrics.cellHeightPixels }

    /// One cell in the point space of the view the box was measured in.
    ///
    /// The divisor is the box's scale, not the metrics' own: a grid too large to draw
    /// natively is rendered at a smaller scale and then shown one backing pixel per
    /// device pixel, so the drawn cell is smaller in points than the metrics describe.
    public func cellSize(in box: MobileContentBox) -> CGSize {
        CGSize(
            width: CGFloat(metrics.cellWidthPixels) / box.displayScale,
            height: CGFloat(metrics.cellHeightPixels) / box.displayScale
        )
    }

    /// The drawn pixels below one viewport row's bottom edge -- the slack a keyboard
    /// lift may consume before that row must move. A row outside the grid answers zero,
    /// which the placement treats as no slack and lifts fully.
    public func slackPixels(belowRow row: Int) -> Int {
        guard (0..<rows).contains(row) else { return 0 }
        return (rows - 1 - row) * metrics.cellHeightPixels
    }

    /// The rectangle the drawn cells occupy in the view's own coordinates.
    ///
    /// Bottom-pinned to the placement's visible bottom edge, so new output stays put at
    /// the bar's top whether or not the keyboard is up. Anything that has to line up
    /// with the cells -- a scroll viewport, a hit test -- reads it here rather than
    /// assuming the view's bounds, which is what keeps all three moving together.
    public func drawnFrame(in placement: MobileSurfacePlacement) -> CGRect {
        let scale = placement.contentBox.displayScale
        let width = CGFloat(pixelWidth) / scale
        let height = CGFloat(pixelHeight) / scale
        return CGRect(
            x: placement.originX,
            y: placement.maxY - height,
            width: width,
            height: height
        )
    }

    /// The cell one point in the view's coordinates falls on, clamped to the grid.
    ///
    /// Clamped rather than optional: the caller is a gesture that started somewhere on
    /// the terminal, and the nearest real cell is a better answer for a mouse report
    /// than no position at all.
    public func cell(
        at point: CGPoint,
        in placement: MobileSurfacePlacement
    ) -> (column: Int, row: Int) {
        let frame = drawnFrame(in: placement)
        let cell = cellSize(in: placement.contentBox)
        return (
            column: clampedIndex((point.x - frame.minX) / cell.width, count: columns),
            row: clampedIndex((point.y - frame.minY) / cell.height, count: rows)
        )
    }
}

/// Turns a fractional cell position into an index inside a grid of `count` cells.
private func clampedIndex(_ position: CGFloat, count: Int) -> Int {
    guard count > 0 else { return 0 }
    guard position.isFinite, position > 0 else { return 0 }
    let floored = position.rounded(.down)
    guard floored < CGFloat(count) else { return count - 1 }
    return Int(floored)
}
