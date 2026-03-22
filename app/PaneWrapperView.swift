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

    // Search overlay
    private(set) var searchOverlay: SearchOverlayView?

    // Progress indicator
    private let progressIndicator: ProgressIndicatorView
    private var currentProgress: ProgressState?
    // Constraint for label leading when indicator is visible vs hidden
    private var labelLeadingToIndicator: NSLayoutConstraint!
    private var labelLeadingToToolbar: NSLayoutConstraint!

    // Pane color stripe: 3px vertical bar on the left edge of the toolbar
    private let paneColorStripe: NSView

    init(paneId: PaneId, terminalView: TerminalView, isZoomed: Bool, hasSplits: Bool, runtime: AppRuntime?) {
        self.paneId = paneId
        self.terminalView = terminalView
        self.toolbar = NSView()
        self.toolbarLabel = NonHitTestingLabel(labelWithString: "")
        self.isZoomed = isZoomed
        self.hasSplits = hasSplits
        self.runtime = runtime
        self.progressIndicator = ProgressIndicatorView()
        self.paneColorStripe = NSView()

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

        // Pane color stripe: 3px vertical bar on toolbar left edge
        paneColorStripe.translatesAutoresizingMaskIntoConstraints = false
        paneColorStripe.wantsLayer = true
        paneColorStripe.isHidden = true
        toolbar.addSubview(paneColorStripe)

        // Progress indicator (before label)
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isHidden = true
        toolbar.addSubview(progressIndicator)

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

        // Terminal view wrapped in scroll view for native scrollbar support
        let scrollWrapper = ScrollableTerminalView(terminalView: terminalView)
        scrollWrapper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollWrapper)

        // Label trailing anchors to the first trailing button
        let labelTrailingAnchor = unzoomButton?.leadingAnchor ?? menuButton.leadingAnchor

        // Label leading constraints (swapped based on indicator visibility)
        labelLeadingToToolbar = toolbarLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8)
        labelLeadingToIndicator = toolbarLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 4)
        labelLeadingToToolbar.isActive = true

        var constraints = [
            // Toolbar
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 22),

            // Pane color stripe
            paneColorStripe.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            paneColorStripe.topAnchor.constraint(equalTo: toolbar.topAnchor),
            paneColorStripe.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            paneColorStripe.widthAnchor.constraint(equalToConstant: 3),

            // Progress indicator
            progressIndicator.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            progressIndicator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            progressIndicator.widthAnchor.constraint(equalToConstant: 12),
            progressIndicator.heightAnchor.constraint(equalToConstant: 12),

            // Label within toolbar
            toolbarLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
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

            // Scroll wrapper (terminal + scrollbar) below toolbar
            scrollWrapper.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollWrapper.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollWrapper.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollWrapper.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    func updateToolbar(title: String, cwd: String?, progress: ProgressState? = nil, isRemote: Bool = false) {
        toolbarLabel.stringValue = formatToolbarLabel(title: title, cwd: cwd)
        applyProgressState(progress)
        if isRemote {
            paneColorStripe.layer?.backgroundColor = NSColor.systemPurple.cgColor
            paneColorStripe.isHidden = false
        } else {
            paneColorStripe.isHidden = true
        }
    }

    private func applyProgressState(_ state: ProgressState?) {
        guard state != currentProgress else { return }
        currentProgress = state

        guard let state = state else {
            // Remove indicator
            progressIndicator.isHidden = true
            progressIndicator.removeSpinAnimation()
            labelLeadingToIndicator.isActive = false
            labelLeadingToToolbar.isActive = true
            return
        }

        progressIndicator.isHidden = false
        labelLeadingToToolbar.isActive = false
        labelLeadingToIndicator.isActive = true

        switch state {
        case .set(let percent):
            progressIndicator.showDeterminate(percent: percent, color: .controlAccentColor)
        case .indeterminate:
            progressIndicator.showIndeterminate(color: .controlAccentColor)
        case .error(let percent):
            if let percent = percent {
                progressIndicator.showDeterminate(percent: percent, color: .systemRed)
            } else {
                progressIndicator.showIndeterminate(color: .systemRed)
            }
        case .pause(let percent):
            if let percent = percent {
                progressIndicator.showDeterminate(percent: percent, color: .systemOrange)
            } else {
                progressIndicator.showDeterminate(percent: 100, color: .systemOrange)
            }
        }
    }

    // MARK: - Search Overlay

    /// Show or update the search overlay. Creates it if absent, otherwise updates from model.
    func showSearchOverlay(search: SearchModel, runtime: AppRuntime?) {
        if let overlay = searchOverlay {
            overlay.update(search: search)
            return
        }
        let overlay = SearchOverlayView(paneId: paneId, runtime: runtime)
        overlay.update(search: search)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        searchOverlay = overlay
    }

    /// Remove the search overlay from the view hierarchy.
    func hideSearchOverlay() {
        searchOverlay?.removeFromSuperview()
        searchOverlay = nil
    }

    @objc private func showPaneMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let splitRight = NSMenuItem(title: "Split Right", action: #selector(splitRightAction), keyEquivalent: "")
        splitRight.target = self
        splitRight.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split Right")
        menu.addItem(splitRight)

        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitDownAction), keyEquivalent: "")
        splitDown.target = self
        splitDown.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Split Down")
        menu.addItem(splitDown)

        menu.addItem(.separator())

        let copyCwd = NSMenuItem(title: "Copy cwd", action: #selector(copyCwdAction), keyEquivalent: "")
        copyCwd.target = self
        copyCwd.isEnabled = runtime?.model.panes[paneId]?.cwd != nil
        menu.addItem(copyCwd)

        menu.addItem(.separator())

        // Theme submenu
        let themeSubmenu = NSMenu()
        let currentTheme = runtime?.model.panes[paneId]?.theme
        let catalogNames = ThemeCatalog.shared.names

        // Show first ~15 theme names from catalog
        for name in catalogNames.prefix(15) {
            let item = NSMenuItem(title: name, action: #selector(setPaneThemeAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SetPaneThemeInfo(themeName: name)
            if currentTheme == name { item.state = .on }
            themeSubmenu.addItem(item)
        }

        themeSubmenu.addItem(.separator())

        let defaultItem = NSMenuItem(title: "Default", action: #selector(setPaneThemeAction(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = SetPaneThemeInfo(themeName: nil)
        if currentTheme == nil { defaultItem.state = .on }
        themeSubmenu.addItem(defaultItem)

        let browseItem = NSMenuItem(title: "Browse All Themes...", action: #selector(browseThemesAction), keyEquivalent: "")
        browseItem.target = self
        themeSubmenu.addItem(browseItem)

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeSubmenu
        menu.addItem(themeItem)

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
        runtime?.send(.splitPane(paneId: paneId, direction: .horizontal))
    }

    @objc private func splitDownAction() {
        runtime?.send(.splitPane(paneId: paneId, direction: .vertical))
    }

    @objc private func copyCwdAction() {
        guard let cwd = runtime?.model.panes[paneId]?.cwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
    }

    @objc private func zoomPaneAction() {
        runtime?.send(.toggleZoomPane)
    }

    @objc private func setPaneThemeAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? SetPaneThemeInfo else { return }
        runtime?.send(.setPaneTheme(paneId: paneId, themeName: info.themeName))
    }

    @objc private func browseThemesAction() {
        runtime?.toggleThemeBrowser()
    }
}

/// Wrapper to carry an optional theme name through NSMenuItem's representedObject.
class SetPaneThemeInfo: NSObject {
    let themeName: String?
    init(themeName: String?) { self.themeName = themeName }
}

// MARK: - Toolbar Drag Handle

/// Pasteboard type for pane drag-and-drop (used by ToolbarDragHandleView and SidebarView).
let paneDragType = NSPasteboard.PasteboardType("com.danterm.pane")

/// Fills the toolbar area to capture mouse events for pane drag-to-split.
/// Initiates an NSDraggingSession so the sidebar can show native insertion markers.
class ToolbarDragHandleView: NSView, NSDraggingSource {
    weak var runtime: AppRuntime?
    var paneId: PaneId?
    private var mouseDownEvent: NSEvent?
    private var dragOrigin: NSPoint?
    private var isDragging = false

    // Show open hand on hover to indicate draggability.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragOrigin = event.locationInWindow
        isDragging = false
        NSCursor.closedHand.set()
        // Do not call super — prevent propagation to toolbar/wrapper
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let paneId = paneId, let runtime = runtime,
              let mouseDownEvent = mouseDownEvent else { return }

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

            // Install overlay + coordinator for pane-area drops
            runtime.startPaneDrag(paneId: paneId)

            // Begin NSDraggingSession so the sidebar gets native drop validation
            let pbItem = NSPasteboardItem()
            pbItem.setString(paneId.rawValue.uuidString, forType: paneDragType)
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            dragItem.setDraggingFrame(bounds, contents: NSImage(size: bounds.size))
            let session = beginDraggingSession(with: [dragItem], event: mouseDownEvent, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false

            isDragging = true
        }
    }

    // NSDraggingSource: allow .move within the application.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .move : []
    }

    // NSDraggingSource: drive the pane overlay from the session's screen position.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        runtime?.updatePaneDrag(screenPoint: screenPoint)
    }

    // NSDraggingSource: finalize the drag when the session ends.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let runtime = runtime else { return }

        // Final position update so the coordinator reflects the exact release location
        runtime.updatePaneDrag(screenPoint: screenPoint)

        if operation != [] {
            // Sidebar accepted the drop via acceptDrop — just tear down the overlay
            runtime.endPaneDrag()
        } else if let drop = runtime.currentPaneDrop() {
            // Pane-area split/swap drop
            runtime.endPaneDrag()
            runtime.send(.movePane(source: drop.source, target: drop.target, intent: drop.intent))
        } else {
            // Cancelled (escape, dropped on nothing)
            runtime.endPaneDrag()
        }

        dragOrigin = nil
        mouseDownEvent = nil
        isDragging = false
    }
}

/// NSTextField subclass that never intercepts mouse events.
/// Used for the toolbar label so the drag handle underneath receives hits.
class NonHitTestingLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Progress Indicator

/// Small radial progress ring (12x12pt) for the pane toolbar.
/// Non-hit-testing so the drag handle underneath still receives events.
class ProgressIndicatorView: NSView {
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private let lineWidth: CGFloat = 1.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(arcLayer)

        trackLayer.fillColor = nil
        trackLayer.lineWidth = lineWidth
        trackLayer.lineCap = .round

        arcLayer.fillColor = nil
        arcLayer.lineWidth = lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // Start from top (12 o'clock), go clockwise
        let path = CGPath(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ), transform: nil)
        trackLayer.path = path
        arcLayer.path = path
        trackLayer.frame = bounds
        arcLayer.frame = bounds

        // Rotate so stroke starts at 12 o'clock (default ellipse starts at 3 o'clock)
        let rotation = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        trackLayer.transform = rotation
        // For arcLayer, preserve any existing spin animation transform
        if arcLayer.animation(forKey: "spin") == nil {
            arcLayer.transform = rotation
        }
    }

    func showDeterminate(percent: UInt8, color: NSColor) {
        removeSpinAnimation()
        trackLayer.isHidden = false
        trackLayer.strokeColor = color.withAlphaComponent(0.2).cgColor
        arcLayer.strokeColor = color.cgColor
        let rotation = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        arcLayer.transform = rotation

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        arcLayer.strokeEnd = CGFloat(percent) / 100
        CATransaction.commit()
    }

    func showIndeterminate(color: NSColor) {
        trackLayer.isHidden = true
        arcLayer.strokeColor = color.cgColor
        arcLayer.strokeEnd = 0.25

        guard arcLayer.animation(forKey: "spin") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -CGFloat.pi / 2
        rotation.toValue = -CGFloat.pi / 2 + CGFloat.pi * 2
        rotation.duration = 0.8
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        arcLayer.add(rotation, forKey: "spin")
    }

    func removeSpinAnimation() {
        arcLayer.removeAnimation(forKey: "spin")
    }
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
