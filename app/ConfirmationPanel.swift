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

/// The widest the panel's column may grow when a long button row asks for more
/// than the text width. Past this the row's alternate truncates instead.
let confirmationMaxColumnWidth: CGFloat = 640

/// Keeps confirmations non-modal while naming every answer with its transaction id.
final class ConfirmationPanel: NSPanel, NSWindowDelegate {
    weak var runtime: AppRuntime?
    /// The whole projection, not just its id: every answer the panel can send
    /// is named by a choice the model wrote down, so the view never infers one
    /// from what it drew.
    private var projection: ConfirmationProjection?
    private let headingLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    /// The buttons, in the app's one dialog order. The UI harness reads it to
    /// prove the drawn order and each button's message.
    let actionRow = DialogActionRow(actions: [])

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
        // A native alert has no title bar text; the heading in the content is
        // the whole title, and repeating it above would say it twice.
        title = ""
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

        buildCommandList()

        // One vertical stack, so hiding the command list collapses the space it
        // used instead of leaving a gap: a confirmation with no running command
        // must show no command area at all.
        let column = NSStackView(views: [headingLabel, bodyLabel, commandScrollView, actionRow])
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
            // A floor rather than a fixed width: a button row wider than the
            // text column widens the panel instead of breaking a constraint.
            column.widthAnchor.constraint(
                greaterThanOrEqualToConstant: confirmationTextColumnWidth),
            column.widthAnchor.constraint(
                lessThanOrEqualToConstant: confirmationMaxColumnWidth),
            // The text rows and the action row all fill the column; the row
            // itself puts the buttons at the trailing edge.
            headingLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            commandScrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        // The column wants to be exactly the text width; the floor above only
        // yields when the buttons need more.
        let preferredWidth = column.widthAnchor.constraint(
            equalToConstant: confirmationTextColumnWidth)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
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
        self.projection = projection
        headingLabel.stringValue = projection.title.text
        bodyLabel.stringValue = projection.informativeText
        actionRow.setActions(
            projection.alternatives.map { action(for: $0, role: .alternate) }
                + [action(for: projection.cancel, role: .cancel),
                   action(for: projection.confirm, role: .defaultAction)]
        )

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
        if let projection {
            answer(projection.cancel)
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
            if let projection { answer(projection.confirm) }
        case .cancel:
            if let projection { answer(projection.cancel) }
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

    private func action(for choice: ConfirmationChoice, role: DialogActionRole) -> DialogAction {
        DialogAction(
            title: choice.title.text,
            role: role,
            isDestructive: choice.isDestructive,
            perform: { [weak self] in self?.answer(choice) }
        )
    }

    /// The single seam between a model-owned answer and a Msg. A click and a
    /// reserved key press both come through here, so the two cannot diverge.
    private func answer(_ choice: ConfirmationChoice) {
        guard let id = projection?.id else { return }
        runtime?.send(.answerConfirmation(id: id, answer: choice.answer))
    }
}
