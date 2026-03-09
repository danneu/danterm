// Geometry logic for determining drop intent from cursor position within a pane.
// Pure function — no AppKit dependency beyond NSPoint/NSSize types.

import Foundation

struct DropZoneSize {
    let width: CGFloat
    let height: CGFloat
}

struct DropZonePoint {
    let x: CGFloat
    let y: CGFloat
}

/// Determine drop intent from cursor position relative to pane bounds.
/// Returns nil for invalid inputs (zero-sized pane, cursor outside bounds).
func resolveDropZone(cursorInPane: DropZonePoint, paneSize: DropZoneSize) -> PaneDropIntent? {
    guard paneSize.width > 0, paneSize.height > 0 else { return nil }
    guard cursorInPane.x >= 0, cursorInPane.x <= paneSize.width,
          cursorInPane.y >= 0, cursorInPane.y <= paneSize.height else { return nil }

    let fx = cursorInPane.x / paneSize.width
    let fy = cursorInPane.y / paneSize.height

    let threshold: CGFloat = 0.25

    let inLeftBand = fx <= threshold
    let inRightBand = fx >= (1 - threshold)
    let inBottomBand = fy <= threshold
    let inTopBand = fy >= (1 - threshold)

    let inHEdge = inLeftBand || inRightBand
    let inVEdge = inBottomBand || inTopBand

    if inHEdge && inVEdge {
        // Corner: pick axis where cursor is closer to the edge
        let hDist = min(fx, 1 - fx)
        let vDist = min(fy, 1 - fy)
        if vDist < hDist {
            // Closer to top/bottom edge
            return inTopBand ? .splitTop : .splitBottom
        } else {
            // Closer to left/right edge, or equidistant (horizontal wins)
            return inLeftBand ? .splitLeft : .splitRight
        }
    }

    if inLeftBand { return .splitLeft }
    if inRightBand { return .splitRight }
    // Note: macOS coordinate system has Y=0 at bottom
    if inBottomBand { return .splitBottom }
    if inTopBand { return .splitTop }

    return .swap
}
