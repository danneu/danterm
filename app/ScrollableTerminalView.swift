// Wraps a TerminalView in an NSScrollView to provide native macOS overlay scrollbar support.
// Closely follows Ghostty's SurfaceScrollView pattern: the NSScrollView manages a blank
// document view whose height represents total scrollback. The TerminalView is pinned to the
// visible rect so the renderer only draws what's on screen.

import Cocoa
import GhosttyKit

// MARK: - TerminalScrollView

/// Private NSScrollView subclass that forwards scroll wheel events directly to TerminalView,
/// preventing NSScrollView from fighting ghostty over scroll position. Keyboard focus stays
/// on TerminalView since acceptsFirstResponder returns false.
private class TerminalScrollView: NSScrollView {
    weak var terminalView: TerminalView?

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events directly to TerminalView so ghostty handles them.
        // NSScrollView must NOT consume these — ghostty owns scroll position.
        terminalView?.scrollWheel(with: event)
    }
}

// MARK: - ScrollableTerminalView

class ScrollableTerminalView: NSView {
    private let scrollView: TerminalScrollView
    private let documentView: NSView
    let terminalView: TerminalView
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false

    /// The last row position sent via scroll_to_row action. Avoids redundant
    /// actions when the user drags the scrollbar but stays on the same row.
    private var lastSentRow: Int?

    init(terminalView: TerminalView) {
        self.terminalView = terminalView

        // Set up scroll view with overlay scroller style
        scrollView = TerminalScrollView()
        scrollView.terminalView = terminalView
        scrollView.hasVerticalScroller = terminalView.scrollbarEnabled
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false

        // Blank document view — its height represents total scrollback in pixels
        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView

        // TerminalView is a child of documentView, pinned to the visible rect
        documentView.addSubview(terminalView)

        super.init(frame: .zero)

        addSubview(scrollView)

        // Set ourselves as the scroll delegate so TerminalView property changes notify us
        terminalView.scrollDelegate = self

        // If TerminalView already has cached state (e.g. after a view rebuild), sync now
        if terminalView.cellSize != .zero || terminalView.scrollbarState != nil {
            synchronizeScrollView()
        }

        // Listen for clip view bounds changes to keep surface pinned to visible rect
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeSurfaceView()
        })

        // Live scroll tracking
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        // Force overlay style even if system preference changes
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scrollView.scrollerStyle = .overlay
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        terminalView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    // MARK: - Scroll Delegate

    /// Called by TerminalView when cellSize or scrollbarState changes.
    func scrollbarStateDidChange() {
        synchronizeScrollView()
    }

    /// Called by TerminalView when scrollbarEnabled changes (config reload).
    func scrollbarConfigDidChange() {
        scrollView.hasVerticalScroller = terminalView.scrollbarEnabled
    }

    // MARK: - Synchronization

    /// Sizes the document view and scrolls the content view to match scrollbar state.
    private func synchronizeScrollView() {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = terminalView.cellSize.height

        if let sb = terminalView.scrollbarState {
            documentView.frame.size.height = scrollbarDocumentHeight(
                contentHeight: contentHeight, cellHeight: cellHeight,
                total: sb.total, len: sb.len
            )
        } else {
            documentView.frame.size.height = contentHeight
        }

        if !isLiveScrolling {
            if cellHeight > 0, let sb = terminalView.scrollbarState {
                let offsetY = scrollbarOffsetY(
                    total: sb.total, offset: sb.offset, len: sb.len,
                    cellHeight: cellHeight
                )
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(sb.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Pins terminalView origin to the visible rect so it fills the viewport.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        terminalView.frame.origin = visibleRect.origin
    }

    // MARK: - Live Scroll (Scrollbar Drag)

    /// Convert AppKit scroll position to a terminal row and send scroll_to_row action.
    private func handleLiveScroll() {
        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let docHeight = documentView.frame.height
        let row = scrollbarRowFromPosition(
            documentHeight: docHeight, visibleOriginY: visibleRect.origin.y,
            visibleHeight: visibleRect.height, cellHeight: cellHeight
        )

        guard row != lastSentRow else { return }
        lastSentRow = row

        guard let surface = terminalView.surface else { return }
        let action = "scroll_to_row:\(row)"
        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        // Flash scrollers for legacy scroller style so users can see and drag them
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()

        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }
}

