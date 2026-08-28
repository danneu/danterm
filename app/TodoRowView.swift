// Reusable todo row view: [checkbox | label | delete button]. It lives apart
// from the TODO popover scopes so the pane list and the tab list can both
// build it without either depending on the other.

import Cocoa

let todoRowId = NSUserInterfaceItemIdentifier("TodoRow")

class TodoRowView: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let textField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()
    let deleteButton: NSButton = {
        let btn = NSButton()
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete task")
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .tertiaryLabelColor
        return btn
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)

        let stack = NSStackView(views: [checkbox, textField, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 16),
            deleteButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func configure(with item: TodoItem) {
        checkbox.state = item.isDone ? .on : .off
        textField.toolTip = item.text.value

        // Collapse multiline text to single display line
        let oneLine = item.text.value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if item.isDone {
            textField.attributedStringValue = NSAttributedString(string: oneLine, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ])
        } else {
            textField.stringValue = oneLine
            textField.textColor = .labelColor
        }
    }
}
