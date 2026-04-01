// NSTextField extension for red-circle badge labels used in the toolbar button and sidebar.
import Cocoa

extension NSTextField {
    /// Create a circle badge label with white count text.
    static func makeBadge(color: NSColor = .systemRed) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .boldSystemFont(ofSize: 10)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = color.cgColor
        label.layer?.cornerRadius = 7
        label.layer?.masksToBounds = true
        label.isHidden = true
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            label.heightAnchor.constraint(equalToConstant: 14),
        ])
        return label
    }

    /// Update badge count and visibility.
    func updateBadge(count: Int) {
        stringValue = "\(count)"
        isHidden = count == 0
    }
}

/// Returns the visible alert badge in a tab cell, or nil.
/// Looks for an NSStackView with identifier "tabAccessoryStack" containing
/// an unhidden badge with identifier "bellDot".
func visibleAlertBadge(in cell: NSView) -> NSView? {
    let stackId = NSUserInterfaceItemIdentifier("tabAccessoryStack")
    let badgeId = NSUserInterfaceItemIdentifier("bellDot")
    guard let stack = cell.subviews.first(where: { $0.identifier == stackId }) as? NSStackView,
          let badge = stack.arrangedSubviews.first(where: { $0.identifier == badgeId }),
          !badge.isHidden
    else { return nil }
    return badge
}
