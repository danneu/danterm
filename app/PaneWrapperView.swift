import Cocoa
import GhosttyKit

class PaneWrapperView: NSView {
    let paneId: PaneId
    let terminalView: TerminalView
    private let toolbar: NSView
    private let toolbarLabel: NonHitTestingLabel
    private let menuButton: NSButton
    private let unzoomButton: PaneToolbarButton?
    private let isZoomed: Bool
    private let hasSplits: Bool
    private weak var runtime: AppRuntime?

    init(paneId: PaneId, terminalView: TerminalView, isZoomed: Bool, hasSplits: Bool, runtime: AppRuntime?) {
        self.paneId = paneId
        self.terminalView = terminalView
        self.toolbar = NSView()
        self.toolbarLabel = NonHitTestingLabel(labelWithString: "")
        self.isZoomed = isZoomed
        self.hasSplits = hasSplits
        self.runtime = runtime

        // Menu button (always visible)
        let mb = NSButton()
        mb.translatesAutoresizingMaskIntoConstraints = false
        mb.bezelStyle = .inline
        mb.isBordered = false
        mb.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Pane menu")
        mb.imageScaling = .scaleProportionallyDown
        mb.contentTintColor = NSColor.secondaryLabelColor
        mb.setContentHuggingPriority(.required, for: .horizontal)
        self.menuButton = mb

        // Unzoom button (only when zoomed)
        if isZoomed {
            let ub = PaneToolbarButton()
            ub.translatesAutoresizingMaskIntoConstraints = false
            ub.bezelStyle = .inline
            ub.isBordered = false
            ub.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Unzoom pane")
            ub.imageScaling = .scaleProportionallyDown
            ub.contentTintColor = NSColor.secondaryLabelColor
            ub.wantsLayer = true
            ub.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            ub.toolTip = "Unzoom Pane"
            ub.setContentHuggingPriority(.required, for: .horizontal)
            self.unzoomButton = ub
        } else {
            self.unzoomButton = nil
        }

        super.init(frame: .zero)

        menuButton.target = self
        menuButton.action = #selector(showPaneMenu)

        if let ub = unzoomButton {
            ub.target = self
            ub.action = #selector(zoomPaneAction)
        }

        // Toolbar container
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
        addSubview(toolbar)

        // Label
        toolbarLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbarLabel.font = NSFont.systemFont(ofSize: 11)
        toolbarLabel.textColor = NSColor.secondaryLabelColor
        toolbarLabel.lineBreakMode = .byTruncatingMiddle
        toolbarLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addSubview(toolbarLabel)

        // Drag handle: fills toolbar, sits above label but below buttons
        let dragHandle = ToolbarDragHandleView()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.runtime = runtime
        dragHandle.paneId = paneId
        toolbar.addSubview(dragHandle)

        // Add buttons to toolbar (on top of drag handle)
        toolbar.addSubview(menuButton)
        if let ub = unzoomButton {
            toolbar.addSubview(ub)
        }

        // Terminal view
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)

        // Label trailing anchors to the first trailing button
        let labelTrailingAnchor = unzoomButton?.leadingAnchor ?? menuButton.leadingAnchor

        var constraints = [
            // Toolbar
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 22),

            // Label within toolbar
            toolbarLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            toolbarLabel.trailingAnchor.constraint(lessThanOrEqualTo: labelTrailingAnchor, constant: -4),

            // Drag handle fills toolbar
            dragHandle.topAnchor.constraint(equalTo: toolbar.topAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),

            // Menu button
            menuButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            menuButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -4),
            menuButton.widthAnchor.constraint(equalToConstant: 16),
            menuButton.heightAnchor.constraint(equalToConstant: 16),

            // Terminal view below toolbar
            terminalView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]

        if let ub = unzoomButton {
            constraints.append(contentsOf: [
                ub.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                ub.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor),
                ub.widthAnchor.constraint(equalToConstant: 16),
                ub.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func updateToolbar(title: String, cwd: String?) {
        toolbarLabel.stringValue = formatToolbarLabel(title: title, cwd: cwd)
    }

    @objc private func showPaneMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let splitRight = NSMenuItem(title: "Split Right", action: #selector(splitRightAction), keyEquivalent: "")
        splitRight.target = self
        menu.addItem(splitRight)

        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitDownAction), keyEquivalent: "")
        splitDown.target = self
        menu.addItem(splitDown)

        menu.addItem(.separator())

        let copyCwd = NSMenuItem(title: "Copy cwd", action: #selector(copyCwdAction), keyEquivalent: "")
        copyCwd.target = self
        copyCwd.isEnabled = runtime?.model.panes[paneId]?.cwd != nil
        menu.addItem(copyCwd)

        menu.addItem(.separator())

        let zoomTitle = isZoomed ? "Unzoom Pane" : "Zoom Pane"
        let zoom = NSMenuItem(title: zoomTitle, action: #selector(zoomPaneAction), keyEquivalent: "")
        zoom.target = self
        zoom.isEnabled = hasSplits || isZoomed
        menu.addItem(zoom)

        let close = NSMenuItem(title: "Close Pane", action: #selector(closePaneAction), keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        let point = NSPoint(x: 0, y: menuButton.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: menuButton)
    }

    @objc private func closePaneAction() {
        guard let surface = terminalView.surface else { return }
        ghostty_surface_request_close(surface)
    }

    @objc private func splitRightAction() {
        runtime?.send(.splitPane(direction: .horizontal))
    }

    @objc private func splitDownAction() {
        runtime?.send(.splitPane(direction: .vertical))
    }

    @objc private func copyCwdAction() {
        guard let cwd = runtime?.model.panes[paneId]?.cwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
    }

    @objc private func zoomPaneAction() {
        runtime?.send(.toggleZoomPane)
    }
}

// MARK: - Toolbar Drag Handle

/// Fills the toolbar area to capture mouse events for pane drag-to-split.
/// Sits above the label (which is non-hit-testing) but below buttons.
class ToolbarDragHandleView: NSView {
    weak var runtime: AppRuntime?
    var paneId: PaneId?
    private var dragOrigin: NSPoint?
    private var isDragging = false

    // Show open hand on hover to indicate draggability.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        isDragging = false
        NSCursor.closedHand.set()
        // Do not call super — prevent propagation to toolbar/wrapper
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let paneId = paneId, let runtime = runtime else { return }

        if !isDragging {
            let loc = event.locationInWindow
            let dx = loc.x - origin.x
            let dy = loc.y - origin.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance > 5 else { return }

            // Don't start drag if tab is zoomed, or single-pane with no other tabs
            guard let tab = selectedTab(in: runtime.model) else { return }
            guard !tab.isZoomed else { return }
            let hasSplits: Bool
            if case .split = tab.rootNode { hasSplits = true } else { hasSplits = false }
            guard hasSplits || totalTabCount(runtime.model) > 1 else { return }

            runtime.startPaneDrag(paneId: paneId)
            isDragging = true
        }

        // Re-assert on every event to override cursor rect interference from other views.
        NSCursor.closedHand.set()
        runtime.updatePaneDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            runtime?.completePaneDrag()
        }
        dragOrigin = nil
        isDragging = false
        NSCursor.openHand.set()
    }
}

/// NSTextField subclass that never intercepts mouse events.
/// Used for the toolbar label so the drag handle underneath receives hits.
class NonHitTestingLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PaneToolbarButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet {
            contentTintColor = NSColor.secondaryLabelColor
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled {
            contentTintColor = NSColor.labelColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if isEnabled {
            contentTintColor = NSColor.secondaryLabelColor
        }
    }
}
