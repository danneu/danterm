// Pane toolbar button for the TODO list.
// Displays as [count icon] or [✓ icon] inline in the pane toolbar.
// Always visible: neutral icon when empty, yellow count for incomplete, green check when all done.

import Cocoa

class TodoToolbarButton: PaneToolbarButton {
    private let countLabel: NSTextField
    private let iconView: NSImageView
    /// The full-strength color of the current count state. Held here because the
    /// hover step repaints the same state, and the counts that produced it are
    /// gone by then.
    private var stateColor: NSColor = .labelColor

    override init(frame: NSRect) {
        countLabel = NSTextField(labelWithString: "")
        iconView = NSImageView()
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .inline
        isBordered = false
        title = ""
        imagePosition = .noImage
        setContentHuggingPriority(.required, for: .horizontal)

        // Count / checkmark label
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(countLabel)

        // Checklist icon
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TODOs")?
            .withSymbolConfiguration(config)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),

            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Always visible so the TODO popover always has a stable toolbar anchor.
        isHidden = false
        toolTip = "To-Do List"
        applyToolbarTint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Update the button display based on task counts.
    func update(totalCount: Int, uncompletedCount: Int) {
        if totalCount == 0 {
            countLabel.stringValue = ""
            stateColor = .labelColor
        } else if uncompletedCount == 0 {
            // All done — green checkmark
            countLabel.stringValue = "✓"
            stateColor = .systemGreen
        } else {
            // Show remaining count — yellow
            countLabel.stringValue = "\(uncompletedCount)"
            stateColor = .systemYellow
        }
        applyToolbarTint()
    }

    // PaneToolbarButton: the count and the icon are subviews, so the hover step
    // has to reach them instead of contentTintColor.
    override func applyToolbarTint() {
        let tint = toolbarTint(stateColor)
        countLabel.textColor = tint
        iconView.contentTintColor = tint
    }

    // Route all hits within our bounds to self so subviews don't intercept clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
