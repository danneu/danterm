// Wraps a terminal session host in an NSScrollView to provide native macOS overlay
// scrollbar support. A blank document view represents total scrollback; the host is pinned to the
// visible rect so the renderer only draws what's on screen.

import Cocoa

// MARK: - TerminalScrollView

/// Forwards scroll wheels to the terminal host so NSScrollView does not own terminal scrolling.
private class TerminalScrollView: NSScrollView {
    weak var terminalSession: (any TerminalSession)?

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        terminalSession?.hostView.scrollWheel(with: event)
    }
}

// MARK: - ScrollableTerminalView

class ScrollableTerminalView: NSView, TerminalSessionStateObserver {
    /// One number for two jobs: the width of the focus ring and the width of the
    /// gutter reserved for it on every side. A `CALayer` border draws inward from
    /// its bounds, so a narrower gutter would put the ring back on top of glyphs.
    static let focusRingWidth: CGFloat = 2

    private let scrollView: TerminalScrollView
    private let documentView: NSView
    let terminalSession: any TerminalSession
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false

    /// The last row position sent via scroll_to_row action. Avoids redundant
    /// actions when the user drags the scrollbar but stays on the same row.
    private var lastSentRow: Int?

    init(terminalSession: any TerminalSession) {
        self.terminalSession = terminalSession

        // Set up scroll view with overlay scroller style
        scrollView = TerminalScrollView()
        scrollView.terminalSession = terminalSession
        scrollView.hasVerticalScroller = terminalSession.state.scrollbarEnabled
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = true

        // Blank document view — its height represents total scrollback in pixels
        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView

        // The stable terminal host is pinned to the visible rect.
        documentView.addSubview(terminalSession.hostView)

        super.init(frame: .zero)

        wantsLayer = true
        // The gutter sits outside the terminal view, so it cannot inherit that
        // view's theme-colored layer background; it paints the session's current
        // one from construction rather than from the first theme change.
        layer?.backgroundColor = terminalSession.state.background

        addSubview(scrollView)

        terminalSession.stateObserver = self

        // If the session already has cached state after reparenting, sync now.
        if terminalSession.state.cellHeight > 0 || terminalSession.state.scrollPosition != nil {
            synchronizeScrollView()
        }

        // Listen for clip view bounds changes to keep the session view pinned to visible rect
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeSessionView()
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

        // Force overlay style even if system preference changes. AppKit documents
        // this notification's object as private, so this observer filters on the
        // name alone. It is the one registration here that cannot rely on the
        // poster's thread: `queue: .main` makes NotificationCenter deliver on the
        // main thread, and the hop makes that delivery guarantee something the
        // compiler can check before we touch main-actor scroller state.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scrollView.scrollerStyle = .overlay
            }
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // `isolated deinit` because the tokens are main-actor state on a main-actor view;
    // a nonisolated deinit cannot touch them.
    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrollView.frame = gutteredBounds()
        terminalSession.hostView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeSessionView()
    }

    /// The terminal area: this view's bounds minus the ring gutter on all four
    /// sides. Reserved whether or not a ring is showing, so focus and alert
    /// changes never reflow the grid. Built by hand rather than with `insetBy`,
    /// which returns a null rect when a pane is laid out narrower than the two
    /// gutters it reserves; this clamps to an empty terminal area instead.
    private func gutteredBounds() -> CGRect {
        let inset = Self.focusRingWidth
        return CGRect(
            x: inset, y: inset,
            width: max(0, bounds.width - 2 * inset),
            height: max(0, bounds.height - 2 * inset)
        )
    }

    // MARK: - Focus Ring

    /// Draws or clears the pane's focus/alert ring inside the reserved gutter.
    /// Focus wins over an alert, and a pane with neither draws no ring.
    func setFocusRing(focused: Bool, hasBell: Bool) {
        guard let layer else { return }
        if focused {
            layer.borderWidth = Self.focusRingWidth
            layer.borderColor = NSColor.systemGreen.cgColor
        } else if hasBell {
            layer.borderWidth = Self.focusRingWidth
            layer.borderColor = NSColor.systemRed.cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }

    // MARK: - Scroll Delegate

    func terminalSessionStateDidChange(_ state: TerminalSessionState) {
        scrollView.hasVerticalScroller = state.scrollbarEnabled
        layer?.backgroundColor = state.background
        synchronizeScrollView()
    }

    // MARK: - Synchronization

    /// Sizes the document view and scrolls the content view to match scrollbar state.
    private func synchronizeScrollView() {
        let contentHeight = scrollView.contentSize.height
        let state = terminalSession.state
        let cellHeight = state.cellHeight

        if let sb = state.scrollPosition {
            documentView.frame.size.height = scrollbarDocumentHeight(
                contentHeight: contentHeight, cellHeight: cellHeight,
                total: sb.total, len: sb.length
            )
        } else {
            documentView.frame.size.height = contentHeight
        }

        if !isLiveScrolling {
            if cellHeight > 0, let sb = state.scrollPosition {
                let offsetY = scrollbarOffsetY(
                    total: sb.total, offset: sb.offset, len: sb.length,
                    cellHeight: cellHeight
                )
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(sb.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Pins the terminal host origin to the visible rect so it fills the viewport.
    private func synchronizeSessionView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        terminalSession.hostView.frame.origin = visibleRect.origin
    }

    // MARK: - Live Scroll (Scrollbar Drag)

    /// Convert AppKit scroll position to a terminal row and send scroll_to_row action.
    private func handleLiveScroll() {
        let cellHeight = terminalSession.state.cellHeight
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let docHeight = documentView.frame.height
        let row = scrollbarRowFromPosition(
            documentHeight: docHeight, visibleOriginY: visibleRect.origin.y,
            visibleHeight: visibleRect.height, cellHeight: cellHeight
        )

        guard row != lastSentRow else { return }
        lastSentRow = row

        terminalSession.scroll(toRow: row)
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
