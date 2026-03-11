// Badge helpers and toolbar button for alert counts.
import Cocoa

/// Create a red circle badge label with white count text.
func makeBadgeLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .boldSystemFont(ofSize: 10)
    label.textColor = .white
    label.alignment = .center
    label.wantsLayer = true
    label.layer?.backgroundColor = NSColor.systemRed.cgColor
    label.layer?.cornerRadius = 7
    label.layer?.masksToBounds = true
    label.isHidden = true
    NSLayoutConstraint.activate([
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
        label.heightAnchor.constraint(equalToConstant: 14),
    ])
    return label
}

/// Update a badge label's count and visibility.
func updateBadgeLabel(_ label: NSTextField, count: Int) {
    label.stringValue = "\(count)"
    label.isHidden = count == 0
}

// Custom button that displays a bell icon with an overlaid badge count.
// Used in the window chrome bar for the alerts toggle.
class BellToolbarButton: NSButton {
    private let badgeLabel: NSTextField

    init() {
        badgeLabel = makeBadgeLabel()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .inline
        isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Alerts")?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        imageScaling = .scaleNone

        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            // Badge at top-right of button
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func updateBadge(count: Int) {
        updateBadgeLabel(badgeLabel, count: count)
    }

    // Route all hits within our bounds to self, so the badge doesn't intercept clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
