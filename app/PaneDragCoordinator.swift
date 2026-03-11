// Transient drag state manager for pane drag-to-split/swap operations.
// Owned exclusively by AppRuntime — never nils itself out of the runtime.
// Manages the overlay view for pane drop zones. Sidebar drops are handled
// natively by NSOutlineView via the NSDraggingSession started in ToolbarDragHandleView.

import Cocoa

class PaneDragCoordinator {
    let sourcePaneId: PaneId
    let overlayView: PaneDragOverlayView

    private(set) var currentTarget: PaneId?
    private(set) var currentIntent: PaneDropIntent?

    private let paneFrameProvider: (PaneId) -> NSRect?
    private let allTargetPaneIds: [PaneId]

    init(sourcePaneId: PaneId, contentView: NSView, paneFrameProvider: @escaping (PaneId) -> NSRect?, targetPaneIds: [PaneId]) {
        self.sourcePaneId = sourcePaneId
        self.paneFrameProvider = paneFrameProvider
        self.allTargetPaneIds = targetPaneIds

        // Create overlay covering the entire content area
        overlayView = PaneDragOverlayView(frame: contentView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        contentView.addSubview(overlayView)
    }

    /// Update drag state from cursor position (in window coordinates).
    func updateDrag(locationInWindow: NSPoint) {
        var hitTarget: PaneId?
        var hitIntent: PaneDropIntent?

        for paneId in allTargetPaneIds {
            guard let frame = paneFrameProvider(paneId) else { continue }
            if frame.contains(locationInWindow) {
                let localPoint = DropZonePoint(
                    x: locationInWindow.x - frame.origin.x,
                    y: locationInWindow.y - frame.origin.y
                )
                let size = DropZoneSize(width: frame.width, height: frame.height)
                if let intent = resolveDropZone(cursorInPane: localPoint, paneSize: size) {
                    hitTarget = paneId
                    hitIntent = intent
                }
                break
            }
        }

        currentTarget = hitTarget
        currentIntent = hitIntent

        if let target = hitTarget, let intent = hitIntent, let frame = paneFrameProvider(target) {
            // Convert frame from window coords to overlay (content view) coords
            let overlayFrame = overlayView.convert(frame, from: nil)
            let zoneRect = highlightRect(for: intent, in: overlayFrame)
            overlayView.update(rect: zoneRect, intent: intent)
        } else {
            overlayView.clear()
        }
    }

    /// Return current drop parameters if valid, else nil.
    func currentDrop() -> (source: PaneId, target: PaneId, intent: PaneDropIntent)? {
        guard let target = currentTarget, let intent = currentIntent else { return nil }
        return (sourcePaneId, target, intent)
    }

    /// Remove overlay. Does NOT nil out AppRuntime's reference.
    func teardown() {
        overlayView.removeFromSuperview()
        currentTarget = nil
        currentIntent = nil
    }

    // MARK: - Highlight Geometry

    /// Compute the highlighted sub-rect for a given intent within a pane frame.
    private func highlightRect(for intent: PaneDropIntent, in frame: NSRect) -> NSRect {
        switch intent {
        case .swap:
            return frame.insetBy(dx: 4, dy: 4)
        case .splitLeft:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width * 0.5, height: frame.height)
        case .splitRight:
            return NSRect(x: frame.midX, y: frame.minY, width: frame.width * 0.5, height: frame.height)
        case .splitBottom:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height * 0.5)
        case .splitTop:
            return NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height * 0.5)
        }
    }
}
