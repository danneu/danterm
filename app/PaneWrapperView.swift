import Cocoa
import GhosttyKit

class PaneWrapperView: NSView {
    let paneId: PaneId
    let terminalView: TerminalView
    private let toolbarLabel: NSTextField
    private let closeButton: NSButton

    init(paneId: PaneId, terminalView: TerminalView) {
        self.paneId = paneId
        self.terminalView = terminalView
        self.toolbarLabel = NSTextField(labelWithString: "")
        self.closeButton = NSButton()
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
            toolbarLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

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
}
