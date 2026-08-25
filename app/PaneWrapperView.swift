// Pane container view that owns the toolbar, drag handling, search overlay, the
// terminal view, and the single pane context-menu builder (makePaneMenu) behind
// the terminal right-click, the "..." toolbar button, and the drag-handle menu.
// It also owns the outline that names the pane while one of those menus tracks.
import ChipArtwork
import Cocoa
import DanTermProtocol

/// Offers every desired toolbar render without recording whether a wrapper was
/// present. The wrapper itself owns the last value it successfully applied.
@MainActor
func offerPaneToolbarRenders(
    _ renders: [PaneId: PaneToolbarRender],
    wrapperFor: (PaneId) -> PaneWrapperView?
) {
    for (paneId, render) in renders {
        wrapperFor(paneId)?.applyToolbarRender(render)
    }
}

class PaneWrapperView: NSView {
    /// Names the zoom button for the view tests. Its tooltip states the direction
    /// of the next click, so it is not a handle anything can match on.
    static let zoomButtonIdentifier = NSUserInterfaceItemIdentifier("paneZoomButton")

    let paneId: PaneId
    let terminalSession: any TerminalSession
    /// Owns the terminal area's frame math, the focus-ring gutter, and the ring
    /// itself. Retained by name because the ring is pushed through this wrapper.
    let scrollWrapper: ScrollableTerminalView
    private let toolbar: NSView
    /// The toolbar's horizontal margin, as one guide every occupant anchors to.
    ///
    /// The margin is a fact about the toolbar, not about any one thing inside
    /// it, so the leading and trailing edges cannot drift apart: a new control
    /// anchored to this guide is inset correctly without knowing the number.
    /// `dragHandle` still spans the toolbar itself -- it is the pane's grab
    /// area, so it deliberately ignores the margin.
    private let toolbarContent = NSLayoutGuide()
    /// Tighter than the system's standard spacing on purpose: the toolbar is
    /// 22pt tall, and the 8pt AppKit recommends reads as a hole beside it.
    private static let toolbarMargin: CGFloat = 4
    private let toolbarLabel: NonHitTestingLabel
    private let menuButton: NSButton
    /// The pane's zoom gesture, both ways: it enters zoom from a split pane and
    /// leaves it from a zoomed one. Shown from the toolbar projection alone, so a
    /// pane that can be zoomed always offers the way in beside the way out.
    private let zoomButton: PaneToolbarButton
    private var zoomWidthConstraint: NSLayoutConstraint?
    /// The pane's take-back gesture: one click ends a claimed grid. Shown from the
    /// toolbar projection's claim flag alone, so a claim is never left with no way
    /// out at the Mac.
    private let releaseGridClaimButton: PaneToolbarButton
    private var releaseGridClaimWidthConstraint: NSLayoutConstraint?
    private let todoButton: TodoToolbarButton
    /// The last render this wrapper applied. Nil is the explicit pre-render
    /// state used while a newly constructed host waits for reconciliation.
    private var lastToolbarRender: PaneToolbarRender?
    private weak var runtime: AppRuntime?
    /// Destination for the context menu's copy actions (cwd, pane id, agent session id).
    /// Defaults to the system pasteboard so a test can assign a scratch board and neither
    /// read nor destroy the developer's real clipboard; mirrors
    /// `SwiftTerminalSessionView.selectionPasteboard`.
    var menuPasteboard = NSPasteboard.general

    // Search overlay
    private(set) var searchOverlay: SearchOverlayView?

    // Leading accessories stack: [paneChip, alertBadge?, remoteAccessory?, agentAccessory?, progressIndicator?, toolbarLabel]
    private let leadingStack: NSStackView
    private let paneChip: ChipView
    private let alertBadge: BadgeLabel
    private let remoteAccessory: NSView
    private let remoteIcon: NSImageView
    private let remoteSessionLabel: NonHitTestingLabel
    private var compactRemoteConstraints: [NSLayoutConstraint] = []
    private var expandedRemoteConstraints: [NSLayoutConstraint] = []
    private let agentAccessory: NSView
    private let agentSessionLabel: NonHitTestingLabel
    // Tracks which remote constraint set is active so toolbar text churn does not
    // re-toggle layout constraints unless the compact/expanded mode changes.
    private var remoteExpanded = false
    private let progressIndicator: ProgressIndicatorView
    private var currentProgress: ProgressState?
    /// The context-menu outline, mounted exactly while a menu this wrapper built
    /// is tracking. Held by name so a second open cannot stack two of them and a
    /// close cannot miss one.
    private var contextMenuOutline: PaneContextMenuOutlineView?

    init(paneId: PaneId, terminalView: any TerminalSession, runtime: AppRuntime?) {
        self.paneId = paneId
        self.terminalSession = terminalView
        // Terminal view wrapped in scroll view for native scrollbar support
        self.scrollWrapper = ScrollableTerminalView(terminalSession: terminalView)
        self.toolbar = NSView()
        self.toolbarLabel = NonHitTestingLabel.make(truncating: .byTruncatingMiddle)
        self.runtime = runtime
        self.alertBadge = BadgeLabel()
        self.progressIndicator = ProgressIndicatorView()
        self.remoteAccessory = NSView()
        self.remoteIcon = NSImageView()
        self.remoteSessionLabel = NonHitTestingLabel.make()
        self.agentAccessory = NSView()
        self.agentSessionLabel = NonHitTestingLabel.make()
        self.paneChip = ChipView(kind: .terminal, edge: ChipArtwork.toolbarSize)
        self.leadingStack = NSStackView()

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

        // The persistent button follows the toolbar projection instead of wrapper
        // lifetime. Its glyph, tooltip, and fill are left to
        // applyZoomButtonPresentation, which is the one place that decides them.
        let zb = PaneToolbarButton()
        zb.translatesAutoresizingMaskIntoConstraints = false
        zb.identifier = PaneWrapperView.zoomButtonIdentifier
        zb.bezelStyle = .inline
        zb.isBordered = false
        zb.imageScaling = .scaleProportionallyDown
        zb.contentTintColor = NSColor.secondaryLabelColor
        zb.wantsLayer = true
        zb.setContentHuggingPriority(.required, for: .horizontal)
        self.zoomButton = zb

        // The take-back affordance. It names the claim rather than the size: the
        // pane is small because a client asked for that grid, and this ends it.
        let rb = PaneToolbarButton()
        rb.translatesAutoresizingMaskIntoConstraints = false
        rb.bezelStyle = .inline
        rb.isBordered = false
        rb.image = NSImage(
            systemSymbolName: "iphone",
            accessibilityDescription: "Release the claimed pane size"
        )
        rb.imageScaling = .scaleProportionallyDown
        rb.contentTintColor = NSColor.secondaryLabelColor
        rb.wantsLayer = true
        rb.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        rb.toolTip = "Release Claimed Size"
        rb.setContentHuggingPriority(.required, for: .horizontal)
        // Starts hidden and stays that way until the toolbar projection reports a
        // claim, which is the only thing that may show it.
        rb.isHidden = true
        self.releaseGridClaimButton = rb

        // TODO button (always visible to provide a stable popover anchor)
        self.todoButton = TodoToolbarButton()

        super.init(frame: .zero)
        terminalView.paneMenuProvider = { [weak self] in self?.makePaneMenu(includeClipboard: true) }

        menuButton.target = self
        menuButton.action = #selector(showPaneMenu)

        todoButton.target = self
        todoButton.action = #selector(toggleTodoPopover)

        zoomButton.target = self
        zoomButton.action = #selector(zoomPaneAction)

        releaseGridClaimButton.target = self
        releaseGridClaimButton.action = #selector(releaseGridClaimAction)

        // Toolbar container
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
        addSubview(toolbar)

        // Remote accessory: purple background with globe icon, hidden by default
        remoteAccessory.translatesAutoresizingMaskIntoConstraints = false
        remoteAccessory.wantsLayer = true
        remoteAccessory.layer?.backgroundColor = NSColor.systemPurple.cgColor
        remoteAccessory.isHidden = true
        remoteAccessory.setContentHuggingPriority(.required, for: .horizontal)

        remoteIcon.translatesAutoresizingMaskIntoConstraints = false
        remoteIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Remote session")
        remoteIcon.contentTintColor = .white
        remoteIcon.imageScaling = .scaleProportionallyDown
        remoteAccessory.addSubview(remoteIcon)

        remoteSessionLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteSessionLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        remoteSessionLabel.textColor = .white
        remoteSessionLabel.isHidden = true
        remoteSessionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteAccessory.addSubview(remoteSessionLabel)

        NSLayoutConstraint.activate([
            remoteIcon.centerYAnchor.constraint(equalTo: remoteAccessory.centerYAnchor),
            remoteIcon.widthAnchor.constraint(equalToConstant: 14),
            remoteIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
        compactRemoteConstraints = [
            remoteIcon.centerXAnchor.constraint(equalTo: remoteAccessory.centerXAnchor),
            remoteAccessory.widthAnchor.constraint(equalToConstant: 22),
        ]
        expandedRemoteConstraints = [
            remoteIcon.leadingAnchor.constraint(equalTo: remoteAccessory.leadingAnchor, constant: 4),
            remoteSessionLabel.leadingAnchor.constraint(equalTo: remoteIcon.trailingAnchor, constant: 4),
            remoteSessionLabel.trailingAnchor.constraint(equalTo: remoteAccessory.trailingAnchor, constant: -6),
            remoteSessionLabel.centerYAnchor.constraint(equalTo: remoteAccessory.centerYAnchor),
            remoteSessionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            remoteAccessory.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ]
        NSLayoutConstraint.activate(compactRemoteConstraints)

        // Agent accessory: names an attached agent that the chip cannot. The chip
        // already carries the kind for every agent DanTerm ships artwork for, so
        // this pill is shown only for the ones it does not -- which is also why it
        // has no icon and only one layout: it is always a label.
        agentAccessory.translatesAutoresizingMaskIntoConstraints = false
        agentAccessory.wantsLayer = true
        agentAccessory.layer?.backgroundColor = NSColor.systemIndigo.cgColor
        agentAccessory.isHidden = true
        agentAccessory.setContentHuggingPriority(.required, for: .horizontal)

        agentSessionLabel.translatesAutoresizingMaskIntoConstraints = false
        agentSessionLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        agentSessionLabel.textColor = .white
        agentSessionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentAccessory.addSubview(agentSessionLabel)

        NSLayoutConstraint.activate([
            agentSessionLabel.leadingAnchor.constraint(equalTo: agentAccessory.leadingAnchor, constant: 6),
            agentSessionLabel.trailingAnchor.constraint(equalTo: agentAccessory.trailingAnchor, constant: -6),
            agentSessionLabel.centerYAnchor.constraint(equalTo: agentAccessory.centerYAnchor),
            agentSessionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])

        // Progress indicator, hidden by default
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isHidden = true
        NSLayoutConstraint.activate([
            progressIndicator.widthAnchor.constraint(equalToConstant: 12),
            progressIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        // Label
        toolbarLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbarLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        toolbarLabel.textColor = NSColor.secondaryLabelColor
        toolbarLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Leading stack: arranges [alertBadge, remoteAccessory, progressIndicator, label] horizontally
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.orientation = .horizontal
        leadingStack.spacing = 4
        leadingStack.alignment = .centerY
        leadingStack.addArrangedSubview(paneChip)
        leadingStack.addArrangedSubview(alertBadge)
        leadingStack.addArrangedSubview(remoteAccessory)
        leadingStack.addArrangedSubview(agentAccessory)
        leadingStack.addArrangedSubview(progressIndicator)
        leadingStack.addArrangedSubview(toolbarLabel)
        toolbar.addSubview(leadingStack)

        // Drag handle: fills toolbar, sits above label but below buttons
        let dragHandle = ToolbarDragHandleView()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.runtime = runtime
        dragHandle.paneId = paneId
        dragHandle.alertBadge = alertBadge
        dragHandle.paneMenuProvider = { [weak self] in self?.makePaneMenu() }
        toolbar.addSubview(dragHandle)

        // Add buttons to toolbar (on top of drag handle)
        toolbar.addSubview(todoButton)
        toolbar.addSubview(menuButton)
        toolbar.addSubview(zoomButton)
        toolbar.addSubview(releaseGridClaimButton)

        toolbarContent.identifier = NSUserInterfaceItemIdentifier("PaneToolbarContent")
        toolbar.addLayoutGuide(toolbarContent)

        scrollWrapper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollWrapper)

        // Trailing button anchor for stack trailing constraint
        let stackTrailingAnchor = todoButton.leadingAnchor

        var constraints = [
            // Toolbar
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 22),

            // The one place the toolbar's horizontal margin is written.
            toolbarContent.leadingAnchor.constraint(
                equalTo: toolbar.leadingAnchor, constant: Self.toolbarMargin
            ),
            toolbarContent.trailingAnchor.constraint(
                equalTo: toolbar.trailingAnchor, constant: -Self.toolbarMargin
            ),
            toolbarContent.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarContent.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            // Leading stack
            leadingStack.leadingAnchor.constraint(equalTo: toolbarContent.leadingAnchor),
            leadingStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            leadingStack.trailingAnchor.constraint(lessThanOrEqualTo: stackTrailingAnchor, constant: -4),

            // Remote accessory fills toolbar height
            remoteAccessory.topAnchor.constraint(equalTo: toolbar.topAnchor),
            remoteAccessory.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            // Agent accessory fills toolbar height
            agentAccessory.topAnchor.constraint(equalTo: toolbar.topAnchor),
            agentAccessory.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            // Drag handle fills toolbar
            dragHandle.topAnchor.constraint(equalTo: toolbar.topAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),

            // TODO button (to the left of the take-back/unzoom/menu buttons)
            todoButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            todoButton.trailingAnchor.constraint(
                equalTo: releaseGridClaimButton.leadingAnchor, constant: -2
            ),

            // Menu button
            menuButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            menuButton.trailingAnchor.constraint(equalTo: toolbarContent.trailingAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 16),
            menuButton.heightAnchor.constraint(equalToConstant: 16),

            // Scroll wrapper (terminal + scrollbar) below toolbar
            scrollWrapper.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollWrapper.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollWrapper.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollWrapper.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]

        let zoomWidthConstraint = zoomButton.widthAnchor.constraint(equalToConstant: 0)
        self.zoomWidthConstraint = zoomWidthConstraint
        constraints.append(contentsOf: [
            zoomButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            zoomButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor),
            zoomWidthConstraint,
            zoomButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Collapsed to zero width while unclaimed, the way the zoom button is,
        // so a pane nobody claimed spends no toolbar width on the affordance.
        let releaseGridClaimWidthConstraint = releaseGridClaimButton.widthAnchor.constraint(
            equalToConstant: 0
        )
        self.releaseGridClaimWidthConstraint = releaseGridClaimWidthConstraint
        constraints.append(contentsOf: [
            releaseGridClaimButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            releaseGridClaimButton.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor),
            releaseGridClaimWidthConstraint,
            releaseGridClaimButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        NSLayoutConstraint.activate(constraints)
        applyZoomButtonPresentation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Pane chrome, so the reconciler reaches it the same way it reaches the
    /// toolbar and the search overlay: through the persistent wrapper.
    func setFocusRing(focused: Bool, hasBell: Bool) {
        scrollWrapper.setFocusRing(focused: focused, hasBell: hasBell)
    }

    /// Applies one complete toolbar projection and skips only a value this
    /// wrapper has already applied. Every string arrives composed by
    /// `desiredPaneToolbar`; composing text here would put untrusted
    /// terminal-reported values back together inside the view.
    func applyToolbarRender(_ render: PaneToolbarRender) {
        guard render != lastToolbarRender else { return }
        lastToolbarRender = render

        toolbarLabel.stringValue = render.label.text
        applyProgressState(render.progress)
        remoteAccessory.isHidden = !render.isRemote
        remoteSessionLabel.stringValue = render.remoteLabel?.text ?? ""
        remoteSessionLabel.isHidden = render.remoteLabel == nil
        let expanded = render.remoteLabel != nil
        if expanded != remoteExpanded {
            remoteExpanded = expanded
            if expanded {
                NSLayoutConstraint.deactivate(compactRemoteConstraints)
                NSLayoutConstraint.activate(expandedRemoteConstraints)
            } else {
                NSLayoutConstraint.deactivate(expandedRemoteConstraints)
                NSLayoutConstraint.activate(compactRemoteConstraints)
            }
        }
        paneChip.kind = render.chipKind
        // The chip's tooltip carries the session id, so it survives the pill
        // being hidden for an agent the chip can name on its own.
        paneChip.toolTip = render.chipTooltip?.text
        agentAccessory.isHidden = render.agentLabel == nil
        agentSessionLabel.stringValue = render.agentLabel?.text ?? ""
        alertBadge.updateBadge(count: render.unreadAlertCount)
        todoButton.update(
            totalCount: render.totalTodoCount,
            uncompletedCount: render.uncompletedTodoCount
        )
        applyZoomButtonPresentation()
        releaseGridClaimButton.isHidden = !render.isGridClaimed
        releaseGridClaimWidthConstraint?.constant = render.isGridClaimed ? 16 : 0
    }

    /// One button carries both directions, so everything the user reads off it --
    /// glyph, tooltip, accessibility description, and fill -- has to say which
    /// way the next click goes. Accent stays reserved for the zoomed state, where
    /// the button is the exit from a non-default state; on a merely split pane it
    /// is quiet chrome rather than permanent color on every toolbar.
    private func applyZoomButtonPresentation() {
        let isZoomed = lastToolbarRender?.isZoomed ?? false
        let hasSplits = lastToolbarRender?.hasSplits ?? false
        let visible = isZoomed || hasSplits
        zoomButton.isHidden = !visible
        zoomWidthConstraint?.constant = visible ? 16 : 0
        zoomButton.image = NSImage(
            systemSymbolName: isZoomed
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: isZoomed ? "Unzoom pane" : "Zoom pane"
        )
        zoomButton.toolTip = isZoomed ? "Unzoom Pane" : "Zoom Pane"
        zoomButton.layer?.backgroundColor = isZoomed
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }

    /// Anchor view for the TODO popover.
    var todoButtonView: NSView { todoButton }

    private func applyProgressState(_ state: ProgressState?) {
        guard state != currentProgress else { return }
        currentProgress = state

        guard let state = state else {
            progressIndicator.isHidden = true
            progressIndicator.removeSpinAnimation()
            return
        }

        progressIndicator.isHidden = false

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

    /// Builds the pane context menu fresh so dynamic item state reflects the current
    /// model. Single builder for all three entry points -- the terminal right-click
    /// (terminal-host right-click), the "..." toolbar button, and the drag-handle
    /// right-click -- so their compositions can't drift apart. Only the terminal entry
    /// point passes `includeClipboard: true` to prepend the Copy/Paste section.
    func makePaneMenu(includeClipboard: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // NSMenuItem.target is weak; representedObject is strong. Anchor this
        // runtime-owned wrapper to each item so a teardown mid-track can't nil the
        // targets (lifetime-safety doc, "AppKit target that can outlive its referent").
        func wrapperItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = self
            return mi
        }

        if includeClipboard {
            // Copy/Paste forward through the backend-neutral session. Copy is
            // disabled rather than hidden so the terminal menu's shape is
            // stable with and without a selection.
            let copy = wrapperItem("Copy", #selector(copySelectionAction(_:)))
            copy.isEnabled = terminalSession.hasSelection
            menu.addItem(copy)
            let paste = wrapperItem("Paste", #selector(pasteClipboardAction(_:)))
            menu.addItem(paste)
            menu.addItem(.separator())
        }

        let splitRight = wrapperItem("Split Right", #selector(splitRightAction))
        splitRight.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split Right")
        menu.addItem(splitRight)

        let splitDown = wrapperItem("Split Down", #selector(splitDownAction))
        splitDown.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Split Down")
        menu.addItem(splitDown)

        menu.addItem(.separator())

        let copyCwd = wrapperItem("Copy cwd", #selector(copyCwdAction))
        copyCwd.isEnabled = runtime?.model.pane(paneId)?.session?.cwd != nil
        menu.addItem(copyCwd)

        menu.addItem(wrapperItem("Copy Pane ID", #selector(copyPaneIdAction)))

        // Only shown when the pane reported an agent session. The toolbar chip renders
        // the compact kind label, so this menu item is the full-id copy affordance.
        if let agent = runtime?.model.pane(paneId)?.session?.agent, case .attached = agent {
            let copySessionId = wrapperItem("Copy Agent Session ID", #selector(copyAgentSessionIdAction))
            // The same chip the toolbar and sidebar show, so the menu names the
            // agent the way the rest of the window already does.
            let image = ChipKind(agent: agent).image()
            image.accessibilityDescription = "Agent session"
            copySessionId.image = image
            menu.addItem(copySessionId)
        }

        menu.addItem(.separator())

        let isZoomed = lastToolbarRender?.isZoomed ?? false
        let hasSplits = lastToolbarRender?.hasSplits ?? false
        let zoom = wrapperItem(isZoomed ? "Unzoom Pane" : "Zoom Pane", #selector(zoomPaneAction))
        zoom.isEnabled = hasSplits || isZoomed
        menu.addItem(zoom)

        menu.addItem(wrapperItem("Close Pane", #selector(closePaneAction)))
        if let runtime,
           let tab = tabForPane(paneId, in: runtime.model),
           isSinglePane(tab.paneTree.root) == false {
            menu.addItem(wrapperItem("Close Others", #selector(closeOtherPanesAction)))
        }

        // Every entry point gets the outline from here, so none of them can be
        // left without the sign of which pane the menu acts on.
        menu.delegate = self

        return menu
    }

    @objc private func copySelectionAction(_ sender: Any?) {
        terminalSession.copySelection()
    }

    @objc private func pasteClipboardAction(_ sender: Any?) {
        terminalSession.pasteClipboard()
    }

    @objc private func showPaneMenu() {
        let menu = makePaneMenu()
        let point = NSPoint(x: 0, y: menuButton.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: menuButton)
    }

    @objc private func closePaneAction() {
        runtime?.send(.requestClosePane(paneId: paneId))
    }

    @objc private func closeOtherPanesAction() {
        runtime?.send(.requestCloseOtherPanes(paneId: paneId))
    }

    @objc private func toggleTodoPopover() {
        runtime?.send(.toggleTodoPopover(owner: .pane(paneId)))
    }

    @objc private func splitRightAction() {
        runtime?.send(.splitPane(paneId: paneId, direction: .horizontal))
    }

    @objc private func splitDownAction() {
        runtime?.send(.splitPane(paneId: paneId, direction: .vertical))
    }

    @objc private func copyCwdAction() {
        guard let cwd = runtime?.model.pane(paneId)?.session?.cwd else { return }
        menuPasteboard.clearContents()
        menuPasteboard.setString(cwd, forType: .string)
    }

    @objc private func copyPaneIdAction() {
        menuPasteboard.clearContents()
        menuPasteboard.setString(paneId.rawValue.uuidString, forType: .string)
    }

    @objc private func copyAgentSessionIdAction() {
        guard case .attached(let session, _) = runtime?.model.pane(paneId)?.session?.agent else { return }
        menuPasteboard.clearContents()
        menuPasteboard.setString(session.sessionId, forType: .string)
    }

    /// Ends this pane's claimed grid. Pane-scoped for the same reason zoom is: a
    /// stale retained menu or a click landing after the focus moved must still
    /// take back the pane the user pointed at.
    @objc private func releaseGridClaimAction() {
        runtime?.send(.clearPaneGridOverride(paneId: paneId))
    }

    @objc private func zoomPaneAction() {
        // Pane-scoped (unlike the menubar's nil form) so a retained stale menu
        // zooms this pane's tab even if the selection changed while tracking.
        runtime?.send(.toggleZoomPane(paneId: paneId))
    }

}

// MARK: - Context-Menu Outline Lifetime

extension PaneWrapperView: NSMenuDelegate {
    // NSMenuDelegate: called when a menu built by makePaneMenu starts tracking.
    func menuWillOpen(_ menu: NSMenu) {
        guard contextMenuOutline == nil else { return }
        let outline = PaneContextMenuOutlineView(frame: bounds)
        // An autoresizing frame rather than constraints, so the overlay follows
        // the pane's size without joining the layout that sizes the pane.
        outline.autoresizingMask = [.width, .height]
        addSubview(outline, positioned: .above, relativeTo: nil)
        contextMenuOutline = outline
    }

    // NSMenuDelegate: called on dismissal and on selection alike, so the outline
    // has one removal path for both ways a menu ends.
    func menuDidClose(_ menu: NSMenu) {
        contextMenuOutline?.removeFromSuperview()
        contextMenuOutline = nil
    }
}

// MARK: - Toolbar Drag Handle

/// Pasteboard type for pane drag-and-drop (used by ToolbarDragHandleView and SidebarView).
let paneDragType = NSPasteboard.PasteboardType("com.danterm.pane")

/// Fills the toolbar area to capture mouse events for pane drag-to-split.
/// Initiates an NSDraggingSession so the sidebar can show native insertion markers.
class ToolbarDragHandleView: NSView, NSDraggingSource {
    weak var runtime: AppRuntime?
    var paneId: PaneId?
    weak var alertBadge: NSView?
    /// Supplies the pane context menu without coupling this drag handle to its owner.
    var paneMenuProvider: (() -> NSMenu?)?
    private var mouseDownEvent: NSEvent?
    private var dragOrigin: NSPoint?
    private var isDragging = false
    private var badgeClickCandidate = false

    // NSView: AppKit calls this on right-click / control-click and pops up the returned menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        paneMenuProvider?()
    }

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

        // Track whether the press started over the visible alert badge.
        if let badge = alertBadge, !badge.isHidden {
            let loc = convert(event.locationInWindow, from: nil)
            let badgeFrame = convert(badge.bounds, from: badge)
            badgeClickCandidate = badgeFrame.contains(loc)
        } else {
            badgeClickCandidate = false
        }

        // Do not call super — prevent propagation to toolbar/wrapper
    }

    // Clear alerts for this pane when the user clicks (press + release) on the alert badge.
    override func mouseUp(with event: NSEvent) {
        if badgeClickCandidate, !isDragging,
           let badge = alertBadge, !badge.isHidden, let paneId = paneId {
            let loc = convert(event.locationInWindow, from: nil)
            let badgeFrame = convert(badge.bounds, from: badge)
            if badgeFrame.contains(loc) {
                runtime?.send(.clearAlertsForPane(paneId: paneId))
            }
        }
        badgeClickCandidate = false
        dragOrigin = nil
        mouseDownEvent = nil
        isDragging = false
        NSCursor.openHand.set()
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

            // Allow the drag unless there's nowhere to drop: a single pane in the only tab.
            // A zoomed pane always has splits, so hasSplits is true and the drag starts; the
            // sidebar can then move it to another tab. In-tab split/swap targets resolve from
            // the pure layout, which frames only the panes the model displays, so a zoomed
            // tab's hidden siblings offer no drop.
            guard let tab = selectedTab(in: runtime.model) else { return }
            let hasSplits: Bool
            if case .split = tab.paneTree.root { hasSplits = true } else { hasSplits = false }
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
class NonHitTestingLabel: SingleLineLabel {
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

// MARK: - Context-Menu Outline

/// Draws the system focus ring over a whole pane while that pane's context menu
/// tracks, so the menu names the pane it acts on the way AppKit names a
/// right-clicked table row. Mounted and unmounted on the menu's own open/close
/// callbacks, never by layout: it uses an autoresizing frame rather than
/// constraints, and answers no hit test, so a pane laid out around it is
/// unchanged whether it is up or not.
///
/// The ring comes from AppKit's focus-ring machinery rather than a stroked
/// path, so it follows the accent color and the Increase Contrast setting
/// without this code naming a color.
class PaneContextMenuOutlineView: NSView {
    /// Wide enough that the exterior ring AppKit draws around the filled path
    /// stays inside this view's bounds instead of being clipped away.
    private static let ringInset: CGFloat = 3
    private static let cornerRadius: CGFloat = 4

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Built by hand rather than with `insetBy`, which returns a null rect
        // for a pane laid out narrower than the two insets it reserves.
        let rect = CGRect(
            x: Self.ringInset, y: Self.ringInset,
            width: bounds.width - 2 * Self.ringInset,
            height: bounds.height - 2 * Self.ringInset
        )
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSFocusRingPlacement.only.set()
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
