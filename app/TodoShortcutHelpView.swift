/// AppKit views for rendering todo popover keyboard shortcut help.
/// The rendered content is label-only so the help popover can be dismissed
/// without adding visible focusable controls.

import Cocoa

private let todoShortcutHelpLabel = "Keyboard shortcuts"
private let todoShortcutHelpWidth: CGFloat = 320
private let todoShortcutKeyColumnWidth: CGFloat = 84

/// Create the secondary hint shown below todo text-entry fields.
func makeTodoShortcutHintLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "Shift+Return for newline")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// Configure the shared image-only keyboard shortcut help button.
func configureTodoShortcutHelpButton(_ button: NSButton, target: AnyObject?, action: Selector) {
    button.target = target
    button.action = action
    button.bezelStyle = .accessoryBarAction
    button.imagePosition = .imageOnly
    button.toolTip = todoShortcutHelpLabel
    button.setAccessibilityLabel(todoShortcutHelpLabel)
    button.translatesAutoresizingMaskIntoConstraints = false

    if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: todoShortcutHelpLabel) {
        image.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
    } else {
        button.image = nil
        button.title = "?"
        button.imagePosition = .noImage
    }
}

private final class TodoShortcutDismissResponder: NSView {
    weak var popover: NSPopover?

    override var acceptsFirstResponder: Bool { true }

    // NSResponder: Esc should dismiss only the shortcut help popover.
    override func cancelOperation(_ sender: Any?) {
        popover?.performClose(nil)
    }

    /// Let Cmd+/ toggle the help popover closed while help owns key focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isHelpShortcut = event.charactersIgnoringModifiers == "/" || event.charactersIgnoringModifiers == "?"
        if isHelpShortcut, flags == [.command] || flags == [.command, .shift] {
            popover?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class TodoShortcutHelpView: NSView {
    init(sections: [TodoShortcutSection]) {
        let height = Self.preferredHeight(for: sections)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: todoShortcutHelpWidth, height: height)))
        setup(sections: sections)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Keep the help compact enough to sit beside the parent todo popover.
    private static func preferredHeight(for sections: [TodoShortcutSection]) -> CGFloat {
        let itemCount = sections.reduce(0) { $0 + $1.items.count }
        return 28 + CGFloat(sections.count) * 22 + CGFloat(itemCount) * 17
    }

    /// Build a sectioned, label-only shortcut grid.
    private func setup(sections: [TodoShortcutSection]) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for section in sections {
            stack.addArrangedSubview(makeSectionHeader(section.title))
            for item in section.items {
                stack.addArrangedSubview(makeShortcutRow(item))
            }
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    /// Attach the hidden responder that absorbs Esc while help is open.
    func installDismissResponder(_ responder: NSView) {
        responder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(responder)
        NSLayoutConstraint.activate([
            responder.widthAnchor.constraint(equalToConstant: 0),
            responder.heightAnchor.constraint(equalToConstant: 0),
            responder.topAnchor.constraint(equalTo: topAnchor),
            responder.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeShortcutRow(_ item: TodoShortcutItem) -> NSStackView {
        let keyLabel = NSTextField(labelWithString: item.keys)
        keyLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        keyLabel.textColor = .labelColor
        keyLabel.alignment = .right
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.widthAnchor.constraint(equalToConstant: todoShortcutKeyColumnWidth).isActive = true

        let actionLabel = NSTextField(labelWithString: item.action)
        actionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        actionLabel.textColor = .labelColor
        actionLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [keyLabel, actionLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }
}

final class TodoShortcutHelpViewController: NSViewController, NSPopoverDelegate {
    private let scope: TodoShortcutScope
    private weak var parentPopover: NSPopover?
    private weak var parentView: NSView?
    private weak var savedResponder: NSResponder?
    private let previousParentBehavior: NSPopover.Behavior
    private let onClose: () -> Void
    private let dismissResponder = TodoShortcutDismissResponder(frame: .zero)

    weak var popover: NSPopover? {
        didSet {
            dismissResponder.popover = popover
        }
    }

    init(
        scope: TodoShortcutScope,
        parentPopover: NSPopover,
        parentView: NSView,
        savedResponder: NSResponder?,
        onClose: @escaping () -> Void
    ) {
        self.scope = scope
        self.parentPopover = parentPopover
        self.parentView = parentView
        self.savedResponder = savedResponder
        self.previousParentBehavior = parentPopover.behavior
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let helpView = TodoShortcutHelpView(sections: todoShortcutSections(scope: scope))
        helpView.installDismissResponder(dismissResponder)
        view = helpView
        preferredContentSize = helpView.frame.size
    }

    // NSPopoverDelegate: move first responder to the invisible Esc handler.
    func popoverDidShow(_ notification: Notification) {
        view.window?.makeFirstResponder(dismissResponder)
    }

    // NSPopoverDelegate: restore parent transient behavior and caller focus.
    func popoverDidClose(_ notification: Notification) {
        parentPopover?.behavior = previousParentBehavior
        if let savedResponder = savedResponder, let window = parentView?.window {
            window.makeFirstResponder(savedResponder)
        }
        onClose()
    }
}
