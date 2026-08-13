// Shared confirmation panel for model-owned close and quit transactions.
import Cocoa

/// Keeps confirmations non-modal while naming every answer with its transaction id.
final class ConfirmationPanel: NSPanel, NSWindowDelegate {
    weak var runtime: AppRuntime?
    private var transactionId: ConfirmationId?
    private let headingLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let confirmButton = NSButton(title: "", target: nil, action: nil)

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Confirm"
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

        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        headingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headingLabel.textColor = .labelColor

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.maximumNumberOfLines = 1

        confirmButton.target = self
        confirmButton.action = #selector(confirm(_:))
        confirmButton.bezelStyle = .push
        confirmButton.keyEquivalent = "\r"

        secondaryButton.target = self
        secondaryButton.action = #selector(chooseCloseTabs(_:))
        secondaryButton.bezelStyle = .push

        let buttonStack = NSStackView(views: [cancelButton, secondaryButton, confirmButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        contentView.addSubview(headingLabel)
        contentView.addSubview(bodyLabel)
        contentView.addSubview(commandLabel)
        contentView.addSubview(buttonStack)

        let padding: CGFloat = 20
        NSLayoutConstraint.activate([
            headingLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            headingLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            headingLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            bodyLabel.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            bodyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            commandLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 8),
            commandLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            commandLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: commandLabel.bottomAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
            cancelButton.heightAnchor.constraint(equalTo: confirmButton.heightAnchor),
        ])
    }

    /// Refreshes the reusable panel from one complete model projection.
    func configure(_ projection: ConfirmationProjection) {
        transactionId = projection.id
        title = projection.title.text
        headingLabel.stringValue = projection.title.text
        bodyLabel.stringValue = projection.informativeText
        commandLabel.stringValue = projection.commandDetail?.text ?? ""
        commandLabel.isHidden = projection.commandDetail == nil
        confirmButton.title = projection.confirmTitle.text
        secondaryButton.title = projection.secondaryTitle?.text ?? ""
        secondaryButton.isHidden = projection.secondaryTitle == nil
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

    // NSWindowDelegate: closing the panel is an explicit transaction cancellation.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let transactionId {
            runtime?.send(.cancelConfirmation(id: transactionId))
        }
        return true
    }

    // MARK: - Actions

    @objc private func confirm(_ sender: Any?) {
        guard let transactionId else { return }
        if secondaryButton.isHidden {
            runtime?.send(.confirmConfirmation(id: transactionId))
        } else {
            runtime?.send(.chooseDeleteGroupConfirmation(id: transactionId, moveTabs: true))
        }
    }

    @objc private func chooseCloseTabs(_ sender: Any?) {
        guard let transactionId else { return }
        runtime?.send(.chooseDeleteGroupConfirmation(id: transactionId, moveTabs: false))
    }

    @objc private func cancel(_ sender: Any?) {
        guard let transactionId else { return }
        runtime?.send(.cancelConfirmation(id: transactionId))
    }
}
