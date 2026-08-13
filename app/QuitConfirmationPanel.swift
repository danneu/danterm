// Quit confirmation panel: a non-modal prompt that keeps terminal panes usable while open.
import Cocoa

final class QuitConfirmationPanel: NSPanel, NSWindowDelegate {
    weak var runtime: AppRuntime?
    private let bodyLabel = NSTextField(labelWithString: "")

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Quit DanTerm?"
        isReleasedWhenClosed = false
        level = .floating
        isExcludedFromWindowsMenu = true  // keep out of the Window menu's auto window list
        hidesOnDeactivate = false
        delegate = self
        buildUI()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Quit DanTerm?")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .labelColor

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelQuit(_:)))
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(confirmQuit(_:)))
        quitButton.bezelStyle = .push
        quitButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [cancelButton, quitButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        contentView.addSubview(titleLabel)
        contentView.addSubview(bodyLabel)
        contentView.addSubview(buttonStack)

        let padding: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            bodyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: bodyLabel.bottomAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
            cancelButton.heightAnchor.constraint(equalTo: quitButton.heightAnchor),
        ])
    }

    /// Refresh copy that can change while the reusable panel is visible.
    func configure(paneCount: Int) {
        let sessions = paneCount == 1 ? "1 terminal session" : "\(paneCount) terminal sessions"
        bodyLabel.stringValue = "This will close \(sessions)."
    }

    /// Position the panel centered over the main app window when possible.
    func center(on window: NSWindow?) {
        guard let window else {
            center()
            return
        }
        let windowFrame = window.frame
        let panelFrame = frame
        let origin = NSPoint(
            x: windowFrame.midX - panelFrame.width / 2,
            y: windowFrame.midY - panelFrame.height / 2
        )
        setFrameOrigin(origin)
    }

    // MARK: - NSWindowDelegate

    // NSWindowDelegate: closing the panel is an explicit quit cancellation.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        runtime?.send(.cancelConfirmation)
        return true
    }

    // MARK: - Actions

    @objc private func confirmQuit(_ sender: Any?) {
        runtime?.send(.confirmConfirmation)
    }

    @objc private func cancelQuit(_ sender: Any?) {
        runtime?.send(.cancelConfirmation)
    }
}
