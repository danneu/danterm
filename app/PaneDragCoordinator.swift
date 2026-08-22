// Transient drag state manager for pane drag-to-split/swap operations.
// Owned exclusively by AppRuntime — never nils itself out of the runtime.
// Manages the overlay view for pane drop zones. Sidebar drops are handled
// natively by NSOutlineView via the NSDraggingSession started in ToolbarDragHandleView.
//
// This holds no geometry of its own: the drop decision is the pure
// `resolvePaneDrop` over the container's current layout, and every coordinate
// change goes through `NSView.convert`.

import Cocoa

@MainActor
class PaneDragCoordinator {
    let sourcePaneId: PaneId
    let overlayView: PaneDragOverlayView

    // Private: `currentDrop()` is the only reader, so the resolved value cannot be
    // observed half-updated.
    private var resolvedDrop: PaneDrop?

    // Weak: the container belongs to the tab, which can outlive or predecease a
    // drag. Reconcile cancels the drag on any visible-tab tree or zoom edit, so a
    // nil container here means the drag is already over.
    private weak var container: SplitContainerView?

    init(sourcePaneId: PaneId, contentView: NSView, container: SplitContainerView) {
        self.sourcePaneId = sourcePaneId
        self.container = container

        // Create overlay covering the entire content area
        overlayView = PaneDragOverlayView(frame: contentView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        contentView.addSubview(overlayView)
    }

    /// Update drag state from cursor position (in window coordinates).
    func updateDrag(locationInWindow: NSPoint) {
        guard let container else {
            resolvedDrop = nil
            overlayView.clear()
            return
        }

        let layout = container.currentPaneLayout()
        let pointInContainer = container.convert(locationInWindow, from: nil)
        let drop = resolvePaneDrop(
            at: DropZonePoint(x: pointInContainer.x, y: pointInContainer.y),
            in: layout,
            source: sourcePaneId
        )
        resolvedDrop = drop

        guard let drop, let rect = layout.placements[drop.target]?.visibleFrame else {
            overlayView.clear()
            return
        }
        let frameInContainer = NSRect(rect)
        let overlayFrame = overlayView.convert(frameInContainer, from: container)
        overlayView.update(rect: highlightRect(for: drop.intent, in: overlayFrame), intent: drop.intent)
    }

    /// Return current drop parameters if valid, else nil.
    func currentDrop() -> (source: PaneId, target: PaneId, intent: PaneDropIntent)? {
        guard let resolvedDrop else { return nil }
        return (sourcePaneId, resolvedDrop.target, resolvedDrop.intent)
    }

    /// Remove overlay. Does NOT nil out AppRuntime's reference.
    func teardown() {
        overlayView.removeFromSuperview()
        resolvedDrop = nil
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
