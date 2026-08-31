// Custom button that displays a bell icon with an overlaid badge count.
// Used in the window chrome bar for the alerts toggle.
import Cocoa

class BellToolbarButton: NSButton {
    private let badgeLabel: BadgeLabel

    init() {
        badgeLabel = BadgeLabel()
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

    func applyBadge(_ count: Int?) {
        badgeLabel.apply(count)
    }

    // Route all hits within our bounds to self, so the badge doesn't intercept clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
