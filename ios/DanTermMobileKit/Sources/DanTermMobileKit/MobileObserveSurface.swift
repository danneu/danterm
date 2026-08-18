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
    public init?(
        columns: Int,
        rows: Int,
        widthPixels: Int,
        heightPixels: Int,
        displayScale: CGFloat,
        fontSize: CGFloat
    ) {
        guard columns > 0, rows > 0,
              let native = TerminalRenderMetrics(displayScale: displayScale, fontSize: fontSize),
              let scale = fittedRenderScale(
                  columns: columns,
                  rows: rows,
                  widthPixels: widthPixels,
                  heightPixels: heightPixels,
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
}
