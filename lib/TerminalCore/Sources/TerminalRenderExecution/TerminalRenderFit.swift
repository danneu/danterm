// The scale a grid renders at inside a fixed pixel budget, shared by every
// presentation that has to show a grid its destination does not contain.
//
// The arithmetic lives here rather than at either call site because it is the one
// rule that keeps a scaled presentation from allocating pixels it never shows: the
// scale a cell box is quantized at decides the surface's pixel extent, so a
// destination-bounded drawing is a destination-bounded allocation. Nothing about a
// window, a view, or a phone belongs in this file -- callers arrive with a pixel
// budget already measured.
import CoreGraphics

/// The display scale one grid renders at inside a pixel budget.
///
/// Returns the native scale for every grid the budget contains, so a presentation
/// whose grid is derived from its own rectangle is untouched by this. A larger grid
/// returns a smaller scale, and the surface it renders into shrinks in the same
/// proportion, which is what keeps the whole grid visible without ever allocating
/// its native pixel extent.
///
/// One scale serves both axes, which is what makes the shrink uniform. It comes from
/// the whole pixels each cell may occupy rather than from the point extent, because a
/// cell box is ceiled to whole backing pixels: dividing the budget by the cell count
/// first is what keeps the ceiled box inside the budget instead of overshooting it by
/// up to a pixel per cell.
///
/// Returns nil when the grid has no presentable geometry at all -- a cell that cannot
/// own one whole pixel on some axis -- which leaves the caller with the frame it has.
/// It takes the native cell box as plain numbers rather than as metrics, because the
/// arithmetic needs nothing else from them and staying free of that type is what lets
/// the AppKit UI harness compile this exact file beside its own metrics stand-in.
public func fittedRenderScale(
    columns: Int,
    rows: Int,
    widthPixels: Int,
    heightPixels: Int,
    nativeCellSize: CGSize,
    nativeDisplayScale: CGFloat
) -> CGFloat? {
    guard columns > 0, rows > 0, widthPixels > 0, heightPixels > 0,
          nativeCellSize.width > 0, nativeCellSize.height > 0
    else { return nil }
    let cellWidthPixels = CGFloat(widthPixels / columns)
    let cellHeightPixels = CGFloat(heightPixels / rows)
    guard cellWidthPixels >= 1, cellHeightPixels >= 1 else { return nil }
    return min(
        nativeDisplayScale,
        cellWidthPixels / nativeCellSize.width,
        cellHeightPixels / nativeCellSize.height
    )
}
