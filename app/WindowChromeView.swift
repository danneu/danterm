// Custom window chrome bar spanning the full window width at the top.
// Contains sidebar toggle, bell button, and title label. Replaces the native
// NSToolbar with a split-toolbar look where the sidebar visually extends to
// the very top of the window.
import Cocoa

class WindowChromeView: NSView {
    let toggleButton: NSButton
    let bellButton: BellToolbarButton
    let addTabButton: NSButton
    let addGroupButton: NSButton
    private let titleLabel: NSTextField
    private let dragView: TitlebarDragView

    // Height constraint driven by actual titlebar geometry
    private var heightConstraint: NSLayoutConstraint!

    // Leading inset for toggle button (after traffic lights)
    private var toggleLeadingConstraint: NSLayoutConstraint!

    // Bottom border leading tracks the content area start (sidebar width)
    private var borderLeadingConstraint: NSLayoutConstraint!

    // Title leading constraints: two anchors depending on sidebar state.
    // When expanded, title leads at the sidebar width offset.
    // When collapsed, title leads after the bell button.
    private var titleLeadingOffset: NSLayoutConstraint!
    private var titleLeadingToBell: NSLayoutConstraint!
    private var isSidebarCollapsed = false

    override init(frame: NSRect) {
        // Toggle sidebar button
        toggleButton = NSButton()
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.bezelStyle = .inline
        toggleButton.isBordered = false
        let toggleConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        toggleButton.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")?.withSymbolConfiguration(toggleConfig)
        toggleButton.imagePosition = .imageOnly

        // Bell button
        bellButton = BellToolbarButton()

        // New tab button
        addTabButton = NSButton()
        addTabButton.translatesAutoresizingMaskIntoConstraints = false
        addTabButton.bezelStyle = .inline
        addTabButton.isBordered = false
        let addTabConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?.withSymbolConfiguration(addTabConfig)
        addTabButton.imagePosition = .imageOnly
        addTabButton.toolTip = "New Tab"

        // New group button
        addGroupButton = NSButton()
        addGroupButton.translatesAutoresizingMaskIntoConstraints = false
        addGroupButton.bezelStyle = .inline
        addGroupButton.isBordered = false
        let addGroupConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addGroupButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Group")?.withSymbolConfiguration(addGroupConfig)
        addGroupButton.imagePosition = .imageOnly
        addGroupButton.toolTip = "New Group"

        // Title label
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Drag view (background, enables window dragging)
        dragView = TitlebarDragView()
        dragView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom border
        let bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor.black.cgColor

        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Add subviews: drag view first (background), then controls on top
        addSubview(dragView)
        addSubview(bottomBorder)
        addSubview(toggleButton)
        addSubview(bellButton)
        addSubview(addTabButton)
        addSubview(addGroupButton)
        addSubview(titleLabel)

        // Height: will be updated from titlebar geometry
        heightConstraint = heightAnchor.constraint(equalToConstant: 28)

        // Toggle leading: updated dynamically from traffic light positions
        toggleLeadingConstraint = toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78)

        // Bottom border leading tracks sidebar width
        borderLeadingConstraint = bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 200)

        // Title leading: offset from leading edge (expanded) or after bell (collapsed)
        titleLeadingOffset = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 208)
        titleLeadingToBell = titleLabel.leadingAnchor.constraint(equalTo: bellButton.trailingAnchor, constant: 8)

        // Default: sidebar expanded
        titleLeadingOffset.isActive = true

        NSLayoutConstraint.activate([
            heightConstraint,

            // Drag view fills entire chrome
            dragView.topAnchor.constraint(equalTo: topAnchor),
            dragView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dragView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Bottom border (content area only, not under sidebar)
            borderLeadingConstraint,
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),

            // Toggle button
            toggleLeadingConstraint,
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 28),
            toggleButton.heightAnchor.constraint(equalToConstant: 28),

            // Bell button (after toggle)
            bellButton.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 0),
            bellButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            // New group button (after bell)
            addGroupButton.leadingAnchor.constraint(equalTo: bellButton.trailingAnchor, constant: 0),
            addGroupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addGroupButton.widthAnchor.constraint(equalToConstant: 28),
            addGroupButton.heightAnchor.constraint(equalToConstant: 28),

            // New tab button (after new group)
            addTabButton.leadingAnchor.constraint(equalTo: addGroupButton.trailingAnchor, constant: 0),
            addTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addTabButton.widthAnchor.constraint(equalToConstant: 28),
            addTabButton.heightAnchor.constraint(equalToConstant: 28),

            // Title label
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        guard let window else { return }
        updateMetrics()

        nc.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didEnterFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didExitFullScreenNotification, object: window)
    }

    @objc private func windowDidResize(_ notification: Notification) {
        updateMetrics()
    }

    // MARK: - Geometry

    private func updateMetrics() {
        guard let window else { return }
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        heightConstraint.constant = max(titlebarHeight, 28)

        let trafficLightMaxX = window.standardWindowButton(.zoomButton)?.frame.maxX ?? 0
        toggleLeadingConstraint.constant = trafficLightMaxX > 0 ? trafficLightMaxX + 8 : 8
    }

    // MARK: - Public API

    /// Update layout when sidebar collapses or expands.
    func syncWithSidebarState(collapsed: Bool, sidebarWidth: CGFloat) {
        isSidebarCollapsed = collapsed
        addTabButton.isHidden = collapsed
        addGroupButton.isHidden = collapsed
        if collapsed {
            borderLeadingConstraint.constant = 0
        } else {
            borderLeadingConstraint.constant = sidebarWidth
            titleLeadingOffset.constant = sidebarWidth + 8
        }
        activateContentLeadingConstraints()
    }

    /// Keep the title position aligned with the NSSplitView divider during drag.
    func updateSeparatorPosition(_ sidebarWidth: CGFloat) {
        borderLeadingConstraint.constant = sidebarWidth
        titleLeadingOffset.constant = sidebarWidth + 8
    }

    /// Update the title label text.
    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    // Activate the correct title leading constraint based on sidebar collapsed state.
    private func activateContentLeadingConstraints() {
        titleLeadingOffset.isActive = false
        titleLeadingToBell.isActive = false

        if isSidebarCollapsed {
            titleLeadingToBell.isActive = true
        } else {
            titleLeadingOffset.isActive = true
        }
    }

    /// Forward badge count to the bell button.
    func updateBellBadge(count: Int) {
        bellButton.updateBadge(count: count)
    }
}
