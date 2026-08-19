// One running command inside a confirmation, with the copy action that takes
// only that command. It lives beside ConfirmationPanel rather than inside it
// because the copy is per-command state -- the command string and the clipboard
// it writes -- and holding that here is what keeps the panel from owning a
// whole-list copy at all. Nothing about the confirmation transaction belongs
// here: the item never talks to the runtime.
import Cocoa

/// A command line in a confirmation plus its own copy button, so one command can
/// be taken without touching the others. The item owns the command text it
/// copies, so what reaches the clipboard is independent of what is drawn,
/// scrolled, or selected.
final class ConfirmationCommandItemView: NSView {
    /// The command this item copies. It is the projected string, not the drawn
    /// or selected text, which is the whole point of the per-item design.
    let command: String
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let commandLabel = NSTextField(labelWithString: "")

    /// Clipboard seam, owned by the panel and pushed down on every configure.
    var pasteboard: TextPasteboard?

    private static let commandFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )

    init(command: String) {
        self.command = command
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func build() {
        copyButton.target = self
        copyButton.action = #selector(copyCommand(_:))
        copyButton.bezelStyle = .push
        copyButton.controlSize = .small
        copyButton.setAccessibilityLabel("Copy \(command)")

        commandLabel.stringValue = command
        commandLabel.font = Self.commandFont
        commandLabel.textColor = .labelColor
        commandLabel.isSelectable = true
        commandLabel.isEditable = false
        commandLabel.lineBreakMode = .byWordWrapping
        commandLabel.maximumNumberOfLines = 0

        // Vertical, leading: the button sits on its own line above the command
        // at the leading edge, so it never collides with wrapped text.
        let stack = NSStackView(views: [copyButton, commandLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            commandLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // NSView: the wrapping label's height is a function of the width the item is
    // actually given, which is known only once that width is laid out. Auto
    // Layout learns it from `preferredMaxLayoutWidth`, so it is restated here on
    // every width change and the item re-measured.
    override func layout() {
        super.layout()
        let width = commandLabel.bounds.width
        guard width > 0, commandLabel.preferredMaxLayoutWidth != width else { return }
        commandLabel.preferredMaxLayoutWidth = width
        commandLabel.invalidateIntrinsicContentSize()
    }

    @objc private func copyCommand(_ sender: Any?) {
        guard let pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }
}
