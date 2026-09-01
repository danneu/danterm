// Non-modal panel for the oldest user-visible notice projected from AppModel.
import Cocoa

/// Renders one notice projection and sends only the answer the chosen button names.
final class NoticePanel: DialogPanel, NSWindowDelegate {
    weak var runtime: AppRuntime?
    private var projection: NoticeProjection?
    let headingLabel = NSTextField(labelWithString: "")
    let bodyLabel = NSTextField(wrappingLabelWithString: "")
    let actionRow = DialogActionRow(actions: [])

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
        delegate = self
        buildUI()
    }

    private func buildUI() {
        guard let contentView else { return }
        headingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        bodyLabel.textColor = .secondaryLabelColor

        let column = NSStackView(views: [headingLabel, bodyLabel, actionRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(16, after: bodyLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        let padding = dialogPanelPadding
        // The column's width is stated, not negotiated: `DialogPanel` computes
        // it before anything wraps, so Auto Layout is left to solve heights
        // only and a long title grows the panel down instead of sideways.
        let columnWidth = column.widthAnchor.constraint(
            equalToConstant: dialogTextColumnWidth)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
            columnWidth,
            headingLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        statesWidth(columnWidth, wrapping: [headingLabel, bodyLabel], actionRow: actionRow)
    }

    /// Refreshes the reusable panel from the complete FIFO-head projection.
    func configure(_ projection: NoticeProjection) {
        self.projection = projection
        headingLabel.stringValue = projection.title.text
        bodyLabel.stringValue = projection.message
        let secondary = projection.secondary.map { [action(for: $0, role: .cancel)] } ?? []
        actionRow.setActions(secondary + [action(for: projection.primary, role: .defaultAction)])
        sizeToContent()
    }

    // NSWindowDelegate: closing means the non-default answer, or dismiss for one-button notices.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let projection {
            answer(projection.secondary ?? projection.primary)
        }
        return false
    }

    // NSWindow: Return chooses the primary action and Escape chooses the secondary action.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let projection
        else {
            super.sendEvent(event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": answer(projection.primary)
        case "\u{1b}": answer(projection.secondary ?? projection.primary)
        default: super.sendEvent(event)
        }
    }

    private func action(for choice: NoticeChoice, role: DialogActionRole) -> DialogAction {
        DialogAction(
            title: choice.title.text,
            role: role,
            isDestructive: false,
            perform: { [weak self] in self?.answer(choice) }
        )
    }

    private func answer(_ choice: NoticeChoice) {
        guard let id = projection?.id else { return }
        runtime?.send(.noticeAnswered(id: id, answer: choice.answer))
    }
}
