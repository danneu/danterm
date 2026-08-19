// Shared confirmation panel for model-owned close and quit transactions.
import Cocoa

/// The width the confirmation panel gives its text column. This is the only
/// width the panel states: the heading, the body sentence, and the command list
/// all wrap to it, and the window's width is that plus its padding.
let confirmationTextColumnWidth: CGFloat = 460

/// The tallest the command list may grow before it scrolls instead of pushing
/// the buttons off screen. Chosen so the whole panel stays well inside the
/// shortest display DanTerm supports, whatever the command list holds.
let confirmationCommandAreaMaxHeight: CGFloat = 220

/// Keeps confirmations non-modal while naming every answer with its transaction id.
final class ConfirmationPanel: NSPanel, NSWindowDelegate {
    weak var runtime: AppRuntime?
    private var transactionId: ConfirmationId?
    private let headingLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let confirmButton = NSButton(title: "", target: nil, action: nil)

    // MARK: - Command list
    //
    // The commands are a list of items, not one text document: each item owns
    // its command and its own copy action, so no affordance here can reach the
    // whole list. The UI harness reads these three to prove that every projected
    // command becomes an item, that the list scrolls instead of growing past the
    // bound, and that an empty command list leaves no command area at all.
    let commandScrollView = NSScrollView()
    let commandList = NSStackView()

    /// The item per running command, in projection order.
    var commandItems: [ConfirmationCommandItemView] {
        commandList.arrangedSubviews.compactMap { $0 as? ConfirmationCommandItemView }
    }

    /// Clipboard seam for the per-item copy actions. Production uses the general
    /// pasteboard; the UI harness injects a recorder. Pushing it down on every
    /// change frees callers from having to set it before the first configure.
    var pasteboard: TextPasteboard = NSPasteboard.general {
        didSet { for item in commandItems { item.pasteboard = pasteboard } }
    }

    init(runtime: AppRuntime) {
        self.runtime = runtime
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

        buildCommandList()

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

        // One vertical stack, so hiding the command list collapses the space it
        // used instead of leaving a gap: a confirmation with no running command
        // must show no command area at all.
        let column = NSStackView(views: [headingLabel, bodyLabel, commandScrollView, buttonStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(16, after: commandScrollView)
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
            commandScrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            cancelButton.heightAnchor.constraint(equalTo: confirmButton.heightAnchor),
        ])
    }

    private func buildCommandList() {
        commandList.orientation = .vertical
        commandList.alignment = .leading
        commandList.spacing = 10
        commandList.translatesAutoresizingMaskIntoConstraints = false

        commandScrollView.documentView = commandList
        commandScrollView.hasVerticalScroller = true
        commandScrollView.autohidesScrollers = true
        commandScrollView.drawsBackground = false
        commandScrollView.borderType = .noBorder

        // The list is pinned to the top of the clip view and takes the clip
        // view's real width -- narrowed by a visible scroller -- so each item
        // wraps to the width it is actually drawn at. Its height is free, which
        // is what makes the list scroll.
        let clip = commandScrollView.contentView
        // Optional, so the required bound below can break it: together the two
        // give the visible list the smaller of its content height and the bound.
        let fitsContent = commandScrollView.heightAnchor.constraint(
            equalTo: commandList.heightAnchor
        )
        fitsContent.priority = .defaultHigh
        NSLayoutConstraint.activate([
            commandList.topAnchor.constraint(equalTo: clip.topAnchor),
            commandList.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            commandList.widthAnchor.constraint(equalTo: clip.widthAnchor),
            commandScrollView.heightAnchor.constraint(
                lessThanOrEqualToConstant: confirmationCommandAreaMaxHeight
            ),
            fitsContent,
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

        // Fresh items every time, so an item at a position can only ever hold
        // the command that position now shows.
        commandScrollView.isHidden = projection.commands.isEmpty
        commandList.setViews(projection.commands.map { line in
            let item = ConfirmationCommandItemView(command: line.text)
            item.pasteboard = pasteboard
            return item
        }, in: .leading)
        // Leading alignment alone would give each item its natural width, and a
        // wrapping label has none worth having. Every item takes the list's full
        // width instead, which is the width its text must wrap to.
        NSLayoutConstraint.activate(commandItems.map {
            $0.widthAnchor.constraint(equalTo: commandList.widthAnchor)
        })
        sizeToContent()
    }

    /// Resizes the panel to fit its content while holding the title bar still.
    /// A refresh that grows the copy must not walk the panel up the screen or
    /// out from under the pointer, so the top edge is the fixed point.
    private func sizeToContent() {
        guard let contentView else { return }
        let top = frame.maxY
        // Repeat until the size settles. An item wraps to the width it is given,
        // so its height is only known after the panel has been laid out at that
        // width -- and that height is what the next size has to fit. A visible
        // scroller narrowing the list is the same story one step further on.
        for _ in 0..<4 {
            // Twice: the first pass is what gives each item its width, and
            // learning that width invalidates the item's height, so the size is
            // only readable after the second.
            contentView.layoutSubtreeIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            let wanted = frameRect(
                forContentRect: NSRect(origin: .zero, size: contentView.fittingSize)
            )
            if abs(wanted.height - frame.height) < 0.5, abs(wanted.width - frame.width) < 0.5 {
                break
            }
            setFrame(
                NSRect(
                    x: frame.minX, y: top - wanted.height,
                    width: wanted.width, height: wanted.height
                ),
                display: true
            )
        }
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

    // MARK: - Key handling

    /// The two answers the panel reserves for itself, whatever holds focus.
    private enum ReservedKey {
        case confirm
        case cancel
    }

    // NSWindow: the panel answers Return and Escape itself, before AppKit
    // routes the press anywhere else. Return reaches the default button only
    // through the responder chain, and a command item's selectable text holds
    // first responder and swallows it, so the confirm button's key equivalent is
    // not enough on its own. The panel holds no editable text, so those two keys
    // can only mean "the default answer" and "cancel", and this claims them for
    // any focus-taking subview added later.
    override func sendEvent(_ event: NSEvent) {
        switch reservedKey(for: event) {
        case .confirm:
            confirm(nil)
        case .cancel:
            cancel(nil)
        case nil:
            super.sendEvent(event)
        }
    }

    /// Classifies an unmodified Return or Escape press. Command, Option,
    /// Control, and Shift leave the event alone so it travels its ordinary
    /// path, the way a native default button behaves. Caps lock, the function
    /// flag, and the keypad flag are not choices the user made about this
    /// press, so they do not disqualify it -- which also makes keypad Enter
    /// count as Return.
    private func reservedKey(for event: NSEvent) -> ReservedKey? {
        guard event.type == .keyDown else { return nil }
        let incidental: NSEvent.ModifierFlags = [.capsLock, .function, .numericPad]
        let chosen = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(incidental)
        guard chosen.isEmpty else { return nil }
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": return .confirm
        case "\u{1b}": return .cancel
        default: return nil
        }
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
