// Resolves a layout-space point to the pane a drag would drop onto. The pane
// choice lives here; the zone choice inside that pane stays DropZone.swift's.
// AppKit view frames are not an input -- a pane the model does not display has
// no frame in the layout, so it cannot be a target.
import Foundation

/// Pairs the pane a drag would land on with what it would do there, so a target
/// without an intent (or an intent without a target) cannot be represented.
struct PaneDrop: Equatable {
    let target: PaneId
    let intent: PaneDropIntent
}

/// Projects the same pure layout the container presents into a drop decision, so
/// drop targeting and pane presentation can never disagree about what is on screen.
func resolvePaneDrop(at point: DropZonePoint, in layout: PaneLayout, source: PaneId) -> PaneDrop? {
    for (paneId, frame) in layout.paneFrames where paneId != source {
        guard frame.contains(point) else { continue }
        guard let intent = resolveDropZone(
            cursorInPane: DropZonePoint(x: point.x - frame.minX, y: point.y - frame.minY),
            paneSize: DropZoneSize(width: frame.width, height: frame.height)
        ) else { return nil }
        return PaneDrop(target: paneId, intent: intent)
    }
    return nil
}

extension PaneLayoutRect {
    /// Half-open on the far edges so neighboring boxes that touch (a divider the
    /// layout shrank to nothing) still claim any point exactly once.
    func contains(_ point: DropZonePoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}
