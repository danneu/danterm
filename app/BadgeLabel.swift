// Shared content-sized count badge construction and painting.
import Cocoa

/// Keeps every count pill at its padded rendered-text width while adjacent content flexes.
final class BadgeLabel: NSTextField {
    private static let height: CGFloat = 14
    private static let horizontalPadding: CGFloat = 3

    override var stringValue: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = attributedStringValue.size().width
        return NSSize(
            width: max(Self.height, ceil(textWidth + 2 * Self.horizontalPadding)),
            height: Self.height
        )
    }

    /// Creates a hidden badge with the shared typography, shape, and layout priorities.
    init(color: NSColor = .systemRed) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        font = .boldSystemFont(ofSize: 10)
        textColor = .white
        alignment = .center
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.masksToBounds = true
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Updates the displayed count and hides zero counts.
    func updateBadge(count: Int) {
        stringValue = "\(count)"
        isHidden = count == 0
    }
}
