import Cocoa
import GhosttyKit

class PaneWrapperView: NSView {
    let paneId: PaneId
    let terminalView: TerminalView
    private let toolbar: NSView
    private let toolbarLabel: NSTextField
    private let menuButton: NSButton
    private let unzoomButton: PaneToolbarButton?
    private let isZoomed: Bool
    private let hasSplits: Bool
    private weak var runtime: AppRuntime?

    init(paneId: PaneId, terminalView: TerminalView, isZoomed: Bool, hasSplits: Bool, runtime: AppRuntime?) {
        self.paneId = paneId
        self.terminalView = terminalView
        self.toolbar = NSView()
        self.toolbarLabel = NSTextField(labelWithString: "")
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

        // Add buttons to toolbar
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
