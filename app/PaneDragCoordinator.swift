// Transient drag state manager for pane drag-to-split/swap operations.
// Owned exclusively by AppRuntime — never nils itself out of the runtime.
// Manages the overlay view and escape/resign event monitors.

import Cocoa

class PaneDragCoordinator {
    let sourcePaneId: PaneId
    let overlayView: PaneDragOverlayView

    private(set) var currentTarget: PaneId?
    private(set) var currentIntent: PaneDropIntent?
    private(set) var currentSidebarTabTarget: TabId?

    /// Called on escape or app resign. AppRuntime sets this to its cancelPaneDrag() method.
    var onCancel: (() -> Void)?
    /// Called when the cursor enters or leaves a sidebar tab row during drag.
    var onSidebarHighlight: ((TabId?) -> Void)?

    private let paneFrameProvider: (PaneId) -> NSRect?
    private let allTargetPaneIds: [PaneId]
    private let sidebarTabFrameProvider: ((TabId) -> NSRect?)?
    private let allSidebarTabIds: [TabId]
    private var keyMonitor: Any?
    private var resignObserver: Any?

    init(sourcePaneId: PaneId, contentView: NSView, paneFrameProvider: @escaping (PaneId) -> NSRect?, targetPaneIds: [PaneId], sidebarTabFrameProvider: ((TabId) -> NSRect?)? = nil, sidebarTabIds: [TabId] = []) {
        self.sourcePaneId = sourcePaneId
        self.paneFrameProvider = paneFrameProvider
        self.allTargetPaneIds = targetPaneIds
        self.sidebarTabFrameProvider = sidebarTabFrameProvider
        self.allSidebarTabIds = sidebarTabIds

        // Create overlay covering the entire content area
        overlayView = PaneDragOverlayView(frame: contentView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        contentView.addSubview(overlayView)

        // Escape key monitor
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.onCancel?()
                return nil // swallow the event
            }
            return event
        }

        // App resign monitor
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onCancel?()
        }
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

        // Sidebar tab hit-testing: only when no pane hit
        if hitTarget != nil {
            // Cursor is over a pane — clear any sidebar highlight
            if currentSidebarTabTarget != nil {
                currentSidebarTabTarget = nil
                onSidebarHighlight?(nil)
            }
        } else if let provider = sidebarTabFrameProvider {
            var hitSidebarTab: TabId?
            for tabId in allSidebarTabIds {
                guard let frame = provider(tabId) else { continue }
                if frame.contains(locationInWindow) {
                    hitSidebarTab = tabId
                    break
                }
            }
            if hitSidebarTab != currentSidebarTabTarget {
                currentSidebarTabTarget = hitSidebarTab
                onSidebarHighlight?(hitSidebarTab)
            }
        }

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

    /// Return current sidebar drop parameters if cursor is over a sidebar tab row.
    func currentSidebarDrop() -> (paneId: PaneId, tabId: TabId)? {
        guard let tabId = currentSidebarTabTarget else { return nil }
        return (sourcePaneId, tabId)
    }

    /// Remove overlay and event monitors. Does NOT nil out AppRuntime's reference.
    func teardown() {
        overlayView.removeFromSuperview()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        currentTarget = nil
        currentIntent = nil
        if currentSidebarTabTarget != nil {
            currentSidebarTabTarget = nil
            onSidebarHighlight?(nil)
        }
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
