// Shared confirmation panel for model-owned close and quit transactions.
import Cocoa

/// The width the confirmation panel gives its text column, and the width it
/// states unless the buttons need more. The heading, the body sentence, and the
/// command list all wrap inside it, and the window's width is it plus padding.
let confirmationTextColumnWidth: CGFloat = 460

/// The tallest the command list may grow before it scrolls instead of pushing
/// the buttons off screen. Chosen so the whole panel stays well inside the
/// shortest display DanTerm supports, whatever the command list holds.
let confirmationCommandAreaMaxHeight: CGFloat = 220

/// The inset between the panel's content and its column, on every side.
private let confirmationPanelPadding: CGFloat = 20

/// The channel the command area keeps clear for a vertical scroller, whether or
/// not one is drawn. It is the legacy scroller's width by name rather than the
/// width of whatever style is in effect: a width read from the ambient style is
/// stale the moment the user changes the setting under an open panel, and
/// reading it would make a system preference an input to how a command wraps.
@MainActor private let confirmationScrollerChannelWidth = NSScroller.scrollerWidth(
    for: .regular, scrollerStyle: .legacy)

/// Keeps confirmations non-modal while naming every answer with its transaction id.
final class ConfirmationPanel: DialogPanel, NSWindowDelegate {
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

    /// The panel's one stated width, restated on every refresh. Every wrapping
    /// label is told the width it wraps to before the layout runs, so nothing
    /// below this constraint reports a width back up into it.
    private var columnWidth: NSLayoutConstraint!
    /// The width the command list is laid out at: the column less the scroller
    /// channel. Stated for the same reason, one level further down.
    private var commandListWidth: NSLayoutConstraint!

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
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

        let padding = confirmationPanelPadding
        // The column's width is stated, not negotiated: `configure` computes it
        // before anything wraps, so Auto Layout is left to solve heights only.
        columnWidth = column.widthAnchor.constraint(
            equalToConstant: confirmationTextColumnWidth)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
            columnWidth,
            // The text rows and the action row all fill the column; the row
            // itself puts the buttons at the trailing edge.
            headingLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            commandScrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func buildCommandList() {
        commandList.orientation = .vertical
        commandList.alignment = .leading
        commandList.spacing = 10
        commandList.translatesAutoresizingMaskIntoConstraints = false
        // The list is the content being scrolled, so it keeps the height its
        // items need whatever the area showing it does: a clipped area must
        // never squeeze the items into each other.
        commandList.setClippingResistancePriority(.required, for: .vertical)

        commandScrollView.documentView = commandList
        commandScrollView.hasVerticalScroller = true
        commandScrollView.autohidesScrollers = true
        commandScrollView.drawsBackground = false
        commandScrollView.borderType = .noBorder

        // The list is pinned to the top of the clip view and laid out at a
        // stated width, so a scroller appearing cannot narrow what an item
        // already wrapped to. Its height is free, which is what makes it scroll.
        let clip = commandScrollView.contentView
        commandListWidth = commandList.widthAnchor.constraint(
            equalToConstant: confirmationTextColumnWidth - confirmationScrollerChannelWidth)
        // The visible area is bounded from above twice over -- by the content's
        // height and by the bound that keeps the panel on screen -- and wants
        // the content's height. So it shows the smaller of the two, and the
        // list's clipping resistance keeps the bound off the items.
        let fitsContent = commandScrollView.heightAnchor.constraint(
            equalTo: commandList.heightAnchor)
        fitsContent.priority = .defaultHigh
        NSLayoutConstraint.activate([
            commandList.topAnchor.constraint(equalTo: clip.topAnchor),
            commandList.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            commandListWidth,
            commandScrollView.heightAnchor.constraint(
                lessThanOrEqualTo: commandList.heightAnchor
            ),
            commandScrollView.heightAnchor.constraint(
                lessThanOrEqualToConstant: confirmationCommandAreaMaxHeight
            ),
            fitsContent,
        ])
    }

    /// The width the panel states for this refresh. It is derived from the text
    /// column and the button row -- a button never wraps, so asking the row how
    /// wide it must be closes no loop -- and then held inside what the display
    /// can show. The bound is a computed minimum rather than a constraint the
    /// solver has to break, because a bound AppKit breaks for us is not a bound.
    private func statedColumnWidth() -> CGFloat {
        let onScreen = (screen ?? NSScreen.main)?.visibleFrame.width
            ?? confirmationTextColumnWidth
        let widest = max(confirmationTextColumnWidth,
                         onScreen - 2 * confirmationPanelPadding)
        return min(max(confirmationTextColumnWidth, actionRow.requiredWidth), widest)
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

        // The width is settled before anything wraps: the buttons are already
        // in place, so the row can be asked how wide it must be, and every
        // wrapping label below is told the width it wraps to.
        let width = statedColumnWidth()
        columnWidth.constant = width
        headingLabel.preferredMaxLayoutWidth = width
        bodyLabel.preferredMaxLayoutWidth = width
        let commandWidth = width - confirmationScrollerChannelWidth
        commandListWidth.constant = commandWidth

        // Fresh items every time, so an item at a position can only ever hold
        // the command that position now shows.
        commandScrollView.isHidden = projection.commands.isEmpty
        commandList.setViews(projection.commands.map { line in
            let item = ConfirmationCommandItemView(command: line.text, wrapWidth: commandWidth)
            item.pasteboard = pasteboard
            return item
        }, in: .leading)
        sizeToContent()
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
