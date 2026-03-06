import Cocoa
import GhosttyKit

class PaneWrapperView: NSView {
    let paneId: PaneId
    let terminalView: TerminalView
    private let toolbarLabel: NSTextField
    private let closeButton: NSButton
    private weak var runtime: AppRuntime?

    init(paneId: PaneId, terminalView: TerminalView, isZoomed: Bool, hasSplits: Bool, runtime: AppRuntime?) {
        self.paneId = paneId
        self.terminalView = terminalView
        self.toolbarLabel = NSTextField(labelWithString: "")
        self.closeButton = NSButton()
        self.runtime = runtime
        super.init(frame: .zero)

        // Toolbar container
        let toolbar = NSView()
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

        // Close button
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = NSColor.secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePaneAction)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        toolbar.addSubview(closeButton)

        // Zoom toggle button
        let zoomButton = NSButton()
        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.bezelStyle = .inline
        zoomButton.isBordered = false
        if isZoomed {
            zoomButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Unzoom pane")
            zoomButton.wantsLayer = true
            zoomButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else {
            zoomButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Zoom pane")
        }
        zoomButton.imageScaling = .scaleProportionallyDown
        zoomButton.contentTintColor = NSColor.secondaryLabelColor
        zoomButton.target = self
        zoomButton.action = #selector(zoomPaneAction)
        zoomButton.isEnabled = hasSplits
        zoomButton.setContentHuggingPriority(.required, for: .horizontal)
        toolbar.addSubview(zoomButton)

        // Terminal view
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)

        NSLayoutConstraint.activate([
            // Toolbar
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 22),

            // Label within toolbar
            toolbarLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            toolbarLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomButton.leadingAnchor, constant: -4),

            // Zoom button within toolbar
            zoomButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            zoomButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 16),
            zoomButton.heightAnchor.constraint(equalToConstant: 16),

            // Close button within toolbar
            closeButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            // Terminal view below toolbar
            terminalView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func updateToolbar(title: String, cwd: String?) {
        toolbarLabel.stringValue = formatToolbarLabel(title: title, cwd: cwd)
    }

    @objc private func closePaneAction() {
        guard let surface = terminalView.surface else { return }
        ghostty_surface_request_close(surface)
    }

    @objc private func zoomPaneAction() {
        runtime?.send(.toggleZoomPane)
    }
}
