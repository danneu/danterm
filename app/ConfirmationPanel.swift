// Shared confirmation panel for model-owned close and quit transactions.
import Cocoa

/// The width the confirmation panel gives its text column. This is the only
/// width the panel states: the heading, the body sentence, and the command
/// document all wrap to it, and the window's width is that plus its padding.
let confirmationTextColumnWidth: CGFloat = 460

/// The tallest the command document may grow before it scrolls instead of
/// pushing the buttons off screen. Chosen so the whole panel stays well inside
/// the shortest display DanTerm supports, whatever the command list holds.
let confirmationCommandAreaMaxHeight: CGFloat = 220

/// Keeps confirmations non-modal while naming every answer with its transaction id.
final class ConfirmationPanel: NSPanel, NSWindowDelegate {
    weak var runtime: AppRuntime?
    private var transactionId: ConfirmationId?
    private let headingLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let confirmButton = NSButton(title: "", target: nil, action: nil)

    /// The commands this confirmation would end, exactly as projected. The copy
    /// action writes these, not what is drawn or selected, so a scrolled or
    /// partly selected document still yields the whole list.
    private var commands: [DisplayLine] = []

    // MARK: - Command document
    //
    // An explicit TextKit 1 stack, because the panel measures the laid-out text
    // to size itself and `NSLayoutManager.usedRect` is the exact answer. An
    // NSTextView built with `init()` would start on TextKit 2 and fall back the
    // moment `layoutManager` is touched.
    //
    // `NSLayoutManager` does not own its text storage, so the storage is held
    // here for the panel's lifetime; dropping it would leave the text view
    // laying out freed text.
    private let commandStorage = NSTextStorage()
    private let commandContainer = NSTextContainer()
    private let commandLayoutManager = NSLayoutManager()
    // The UI harness reads these four to prove the projected commands reach the
    // document, that it scrolls instead of growing past the bound, and that an
    // empty command list leaves no command area at all.
    let commandTextView: NSTextView
    let commandScrollView = NSScrollView()
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let commandArea = NSStackView()
    private var commandHeight: NSLayoutConstraint!

    /// Clipboard seam for the copy affordance. Production uses the general
    /// pasteboard; the UI harness injects a recorder.
    var pasteboard: TextPasteboard = NSPasteboard.general

    /// The command font, also the font the panel measures the document with.
    private static let commandFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )

    init(runtime: AppRuntime) {
        self.runtime = runtime
        commandStorage.addLayoutManager(commandLayoutManager)
        commandLayoutManager.addTextContainer(commandContainer)
        commandContainer.lineFragmentPadding = 0
        commandTextView = NSTextView(frame: .zero, textContainer: commandContainer)
        // A placeholder rect. The panel's real size comes from its content, so
        // no dimension is stated here.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
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

        headingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headingLabel.textColor = .labelColor
        headingLabel.lineBreakMode = .byWordWrapping
        headingLabel.maximumNumberOfLines = 0

        bodyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"

        buildCommandArea()

        confirmButton.target = self
        confirmButton.action = #selector(confirm(_:))
        confirmButton.bezelStyle = .push
        confirmButton.keyEquivalent = "\r"

        secondaryButton.target = self
        secondaryButton.action = #selector(chooseCloseTabs(_:))
        secondaryButton.bezelStyle = .push

        let buttonStack = NSStackView(views: [cancelButton, secondaryButton, confirmButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        // One vertical stack, so hiding the command area collapses the space it
        // used instead of leaving a gap (I5's "no command area at all").
        let column = NSStackView(views: [headingLabel, bodyLabel, commandArea, buttonStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(16, after: commandArea)
        contentView.addSubview(column)

        let padding: CGFloat = 20
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
            column.widthAnchor.constraint(equalToConstant: confirmationTextColumnWidth),
            // The three text rows fill the column; the buttons keep their natural
            // width and sit at its trailing edge.
            headingLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            commandArea.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            cancelButton.heightAnchor.constraint(equalTo: confirmButton.heightAnchor),
        ])
    }

    private func buildCommandArea() {
        commandTextView.isEditable = false
        commandTextView.isSelectable = true
        commandTextView.drawsBackground = false
        commandTextView.font = Self.commandFont
        commandTextView.textColor = .labelColor
        commandTextView.textContainerInset = .zero
        commandTextView.isVerticallyResizable = true
        commandTextView.isHorizontallyResizable = false
        commandTextView.autoresizingMask = [.width]

        commandScrollView.documentView = commandTextView
        commandScrollView.hasVerticalScroller = true
        commandScrollView.autohidesScrollers = true
        commandScrollView.drawsBackground = false
        // No border, so the clip view's width is exactly the column width the
        // panel measures the document against.
        commandScrollView.borderType = .noBorder
        commandHeight = commandScrollView.heightAnchor.constraint(equalToConstant: 0)

        copyButton.target = self
        copyButton.action = #selector(copyCommands(_:))
        copyButton.bezelStyle = .push
        copyButton.controlSize = .small

        // Gravity areas, not alignment: the button keeps its natural width and
        // still sits at the trailing edge of the full-width row.
        let header = NSStackView()
        header.orientation = .horizontal
        header.addView(copyButton, in: .trailing)

        commandArea.orientation = .vertical
        commandArea.alignment = .leading
        commandArea.spacing = 4
        commandArea.setViews([header, commandScrollView], in: .leading)
        NSLayoutConstraint.activate([
            commandHeight,
            header.widthAnchor.constraint(equalTo: commandArea.widthAnchor),
            commandScrollView.widthAnchor.constraint(equalTo: commandArea.widthAnchor),
        ])
    }

    /// Refreshes the reusable panel from one complete model projection.
    func configure(_ projection: ConfirmationProjection) {
        transactionId = projection.id
        title = projection.title.text
        headingLabel.stringValue = projection.title.text
        bodyLabel.stringValue = projection.informativeText
        confirmButton.title = projection.confirmTitle.text
        secondaryButton.title = projection.secondaryTitle?.text ?? ""
        secondaryButton.isHidden = projection.secondaryTitle == nil

        commands = projection.commands
        commandArea.isHidden = commands.isEmpty
        commandTextView.string = commandText
        // Replacing the string resets the run's attributes to the typing
        // defaults, so both are re-applied here rather than only at build time.
        commandTextView.font = Self.commandFont
        commandTextView.textColor = .labelColor
        // Size the document from the measured text rather than waiting for a
        // display pass: the visible height below is a cap, so a document left at
        // its old size would clip its own text instead of scrolling.
        let document = commandDocumentHeight()
        commandTextView.frame = NSRect(
            x: 0, y: 0, width: confirmationTextColumnWidth, height: document
        )
        commandHeight.constant = min(document, confirmationCommandAreaMaxHeight)
        sizeToContent()
    }

    /// The commands as one document: one per line, in projection order. Both the
    /// drawn text and the clipboard write use this, so they cannot disagree.
    private var commandText: String {
        commands.map(\.text).joined(separator: "\n")
    }

    /// The height the wrapped command text occupies at the column width.
    /// Measured through the layout manager rather than estimated, so the frame
    /// the panel asks for is the height the text actually needs.
    private func commandDocumentHeight() -> CGFloat {
        guard !commands.isEmpty else { return 0 }
        commandContainer.size = NSSize(
            width: confirmationTextColumnWidth,
            height: .greatestFiniteMagnitude
        )
        commandLayoutManager.ensureLayout(for: commandContainer)
        return ceil(commandLayoutManager.usedRect(for: commandContainer).height)
    }

    /// Resizes the panel to fit its content while holding the title bar still.
    /// A refresh that grows the copy must not walk the panel up the screen or
    /// out from under the pointer, so the top edge is the fixed point.
    private func sizeToContent() {
        guard let contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let wanted = frameRect(forContentRect: NSRect(origin: .zero, size: contentView.fittingSize))
        let top = frame.maxY
        setFrame(
            NSRect(x: frame.minX, y: top - wanted.height, width: wanted.width, height: wanted.height),
            display: true
        )
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

    @objc private func copyCommands(_ sender: Any?) {
        guard !commands.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(commandText, forType: .string)
    }
}
